defmodule LoopexCli.OfflineProviderBindingsTest do
  use ExUnit.Case, async: false
  @moduletag capture_log: true

  alias LoopexCli.CredentialCache
  alias LoopexComposition.{Placement, ProjectResources}
  alias Loopex.LLM.ReqLLM.{CredentialCustody, CredentialRegistry}

  @names ~w(LOOPEX_PROVIDER_API_KEY M7_OFFLINE_A M7_OFFLINE_B)
  @edge :"$loopex_composition_edge_observer"

  setup do
    root = Path.join(System.tmp_dir!(), "lob-" <> Base.encode16(:crypto.strong_rand_bytes(8)))
    workspace = Path.join(root, "workspace")
    File.mkdir_p!(workspace)
    File.write!(Path.join(workspace, "AGENTS.md"), "Retain project facts.\n")
    previous = Map.new(@names, &{&1, System.get_env(&1)})
    System.put_env("LOOPEX_PROVIDER_API_KEY", "unused-offline-canary")
    System.put_env("M7_OFFLINE_A", "offline-first-canary")
    System.put_env("M7_OFFLINE_B", "offline-second-canary")

    on_exit(fn ->
      LoopexCli.release_placement()

      for {name, value} <- previous do
        if value, do: System.put_env(name, value), else: System.delete_env(name)
      end

      File.rm_rf!(root)
    end)

    %{root: root, workspace: workspace, state_root: Path.join(root, "state")}
  end

  test "repeated real offline composition borrows routes and preserves launch exclusions",
       context do
    test = self()
    observe_launches(test)

    Process.put(@edge, fn
      Loopex, :start_link, [options] ->
        send(test, {:runtime_options, options})
        {:error, :observed_offline_runtime}

      module, function, arguments ->
        apply(module, function, arguments)
    end)

    host_options = [
      provider_bindings: bindings(),
      model: "openai:test",
      maintenance_model: "anthropic:claude-haiku-4-5",
      sampling: %{"max_tokens" => 2048},
      active_tools: []
    ]

    planes =
      for iteration <- 1..2 do
        assert {:error, :observed_offline_runtime} =
                 LoopexCli.dispatch(argv(context), host_options)

        assert_receive {:runtime_options, options}
        model = options[:model]
        assert model.model == "openai:test"
        assert options[:sampling] == %{"max_tokens" => 2048}
        assert options[:active_tools] == []
        assert options[:maintenance_model]["reasoning"] == "none"
        assert model.module == LoopexComposition.Model
        assert Keyword.fetch!(model.options, :adapter) == Loopex.LLM.ReqLLM
        adapter_options = Keyword.fetch!(model.options, :adapter_options)
        assert adapter_options[:excluded_env_names] == @names

        assert_receive {:launch_call,
                        {ProjectResources, :discover, [_, [excluded_env_names: @names]]}}

        assert_receive {:launch_call, {Placement, :process_incarnation, [_, "/bin/ps", @names]}}
        assert :ok = LoopexCli.release_placement()
        if iteration == 1, do: System.put_env("M7_OFFLINE_A", "replacement-must-stay-unused")
        adapter_options
      end

    [first, second] = planes
    assert first[:provider_routes] == second[:provider_routes]
    refute first[:tracing_capability] == second[:tracing_capability]
    refute Process.alive?(first[:tracing_capability].pid)
    refute Process.alive?(second[:tracing_capability].pid)
    assert System.get_env("M7_OFFLINE_A") == "replacement-must-stay-unused"
    assert System.get_env("M7_OFFLINE_B") == nil
    assert System.get_env("LOOPEX_PROVIDER_API_KEY") == nil
    {:ok, host} = CredentialCache.host()

    custodians =
      Enum.map(host.provider_routes, fn {provider, token} ->
        {:ok, custody} = CredentialRegistry.route(host.registry, token)
        assert {:ok, %{credential: key}} = CredentialCustody.resolve(custody)

        assert key ==
                 if(provider == "openai",
                   do: "offline-first-canary",
                   else: "offline-second-canary"
                 )

        custody.pid
      end)

    on_exit(fn ->
      for pid <- [host.registry.pid | custodians] do
        monitor = Process.monitor(pid)
        Process.exit(pid, :kill)
        assert_receive {:DOWN, ^monitor, :process, ^pid, _}, 1_000
      end
    end)
  end

  test "unbound selection refuses before credential consumption or placement", context do
    assert {:error, :provider_route_unavailable} =
             LoopexCli.dispatch(argv(context),
               provider_bindings: bindings(),
               model: "openrouter:missing"
             )

    assert System.get_env("M7_OFFLINE_A") == "offline-first-canary"
    assert System.get_env("M7_OFFLINE_B") == "offline-second-canary"
    assert System.get_env("LOOPEX_PROVIDER_API_KEY") == "unused-offline-canary"
    refute File.exists?(context.state_root)
  end

  defp argv(context),
    do: [
      "run",
      "--policy",
      "allow-all",
      "--state-root",
      context.state_root,
      "--workspace",
      context.workspace,
      "Inspect this project."
    ]

  defp bindings,
    do: %{
      "openai" => %{"credential" => %{"env" => "M7_OFFLINE_A"}},
      "anthropic" => %{"credential" => %{"env" => "M7_OFFLINE_B"}}
    }

  defp observe_launches(parent) do
    observer = spawn(fn -> forward(parent) end)
    trace = :trace.session_create(:m7_offline_launches, observer, [])

    for {module, _, _} = function <- [
          {Placement, :process_incarnation, 3},
          {ProjectResources, :discover, 2}
        ] do
      Code.ensure_loaded!(module)
      assert :trace.function(trace, function, true, [:local]) == 1
    end

    assert :trace.process(trace, self(), true, [:call]) == 1

    on_exit(fn ->
      :trace.session_destroy(trace)
      Process.exit(observer, :kill)
    end)
  end

  defp forward(parent) do
    receive do
      {:trace, _, :call, call} ->
        send(parent, {:launch_call, call})
        forward(parent)
    end
  end
end
