defmodule LoopexComposition.DurableBindingsStartupTest do
  use ExUnit.Case, async: false
  @moduletag capture_log: true

  alias LoopexComposition.CredentialHost

  alias Loopex.LLM.ReqLLM.{
    CredentialCustody,
    CredentialRegistry,
    CredentialToken,
    ProviderConfiguration
  }

  @edge :"$loopex_composition_edge_observer"
  @effect :"$loopex_composition_effect_observer"
  @names ~w(LOOPEX_PROVIDER_API_KEY M7_START_A M7_START_B)

  defmodule Policy do
    @moduledoc false
    @behaviour Loopex.Policy
    @impl true
    def decide(_), do: {:deny, :test}
  end

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "loopex-durable-bindings-#{System.unique_integer([:positive])}"
      )

    workspace = Path.join(root, "workspace")
    File.mkdir_p!(workspace)
    prior = Map.new(@names, &{&1, System.get_env(&1)})
    System.put_env("M7_START_A", "first-start-canary")
    System.put_env("M7_START_B", "second-start-canary")
    System.put_env("LOOPEX_PROVIDER_API_KEY", "unused-start-canary")

    on_exit(fn ->
      for {name, value} <- prior do
        if value, do: System.put_env(name, value), else: System.delete_env(name)
      end

      File.rm_rf!(root)
    end)

    %{
      root: root,
      options: [
        state_root: Path.join(root, "state"),
        workspace: workspace,
        runtime_id: "durable-bindings",
        policy: Policy,
        model: "openai:test"
      ]
    }
  end

  test "direct startup loads all routes and privately forwards immutable exclusions", %{
    options: options
  } do
    parent = self()

    Process.put(@edge, fn module, function, [opts] = arguments ->
      if module in [Loopex.Store.Local, Loopex.Executor.Local],
        do: send(parent, {:launch_options, module, opts[:excluded_env_names]})

      result = apply(module, function, arguments)
      send(parent, {:owned_edge, result})
      result
    end)

    assert :done =
             LoopexComposition.with_runtime(
               options ++
                 [provider_bindings: bindings(), maintenance_model: "anthropic:claude-haiku-4-5"],
               fn runtime ->
                 assert Enum.all?(@names, &(System.get_env(&1) == nil))
                 assert_runtime(runtime)
                 assert_receive {:launch_options, Loopex.Store.Local, @names}
                 assert_receive {:launch_options, Loopex.Executor.Local, @names}
                 :done
               end
             )

    owned = collect_owned([])
    assert length(owned) == 9
    assert Enum.all?(owned, &(not Process.alive?(&1)))
  end

  test "partial direct loading failure joins custody before returning", %{options: options} do
    System.delete_env("M7_START_B")
    parent = self()

    Process.put(@edge, fn module, function, arguments ->
      result = apply(module, function, arguments)
      send(parent, {:owned_edge, result})
      result
    end)

    assert {:error, :provider_credential_required} =
             invoke(:with_runtime, options ++ [provider_bindings: bindings()])

    owned = collect_owned([])
    assert length(owned) == 2
    assert Enum.all?(owned, &(not Process.alive?(&1)))
  end

  test "all constructors borrow exact routes without rereading reintroduced values", %{
    options: options
  } do
    {:ok, host} = CredentialHost.open(bindings())
    host_pids = host_pids(host)
    on_exit(fn -> Enum.each(host_pids, &stop/1) end)
    System.put_env("M7_START_A", "replacement-must-not-be-read")
    System.put_env("M7_START_B", "replacement-must-not-be-read")

    for entry <- [:start, :with_runtime, :start_edges] do
      {:ok, plane} = CredentialHost.plane(host)

      options =
        options ++ [credential_plane: plane, maintenance_model: "anthropic:claude-haiku-4-5"]

      case entry do
        :start ->
          assert {:ok, runtime} = LoopexComposition.start(options)
          assert_runtime(runtime)
          assert :ok = Loopex.stop(runtime)
          await_store_release(options[:state_root])

        :with_runtime ->
          assert :ok = LoopexComposition.with_runtime(options, &assert_runtime/1)

        :start_edges ->
          assert {:ok, edges} = LoopexComposition.start_edges(options)
          assert_runtime(edges.runtime)
          assert :ok = Loopex.stop(edges.runtime)
          edges |> Map.drop([:runtime, :runtime_supervisor]) |> Map.values() |> Enum.each(&stop/1)
      end

      assert :ok = CredentialHost.release_plane(plane)
      assert Enum.all?(host_pids, &Process.alive?/1)
      assert System.get_env("M7_START_A") == "replacement-must-not-be-read"
      assert System.get_env("M7_START_B") == "replacement-must-not-be-read"
    end
  end

  test "invalid complete planes and conflicting bindings refuse before owned effects", %{
    options: options
  } do
    {:ok, host} = CredentialHost.open(bindings())
    {:ok, plane} = CredentialHost.plane(host)

    pids = host_pids(host)

    on_exit(fn ->
      CredentialHost.release_plane(plane)
      Enum.each(pids, &stop/1)
    end)

    routes = plane.model_options[:provider_routes]

    invalid_planes = [
      Map.put(plane, :extra, true),
      Map.put(plane, :version, 1),
      Map.put(plane, :excluded_env_names, []),
      Map.put(plane, :excluded_env_names, ["HOME" | @names]),
      Map.put(plane, :capability_pid, self()),
      Map.put(plane, :model_options, [:bad]),
      %{plane | model_options: plane.model_options ++ [credential_token: CredentialToken.new()]},
      %{
        plane
        | model_options:
            Keyword.put(
              plane.model_options,
              :provider_routes,
              Map.put(routes, "anthropic", CredentialToken.new())
            )
      },
      %{plane | model_options: Keyword.put(plane.model_options, :tracing_capability, nil)}
    ]

    parent = self()

    for key <- [@edge, @effect],
        do:
          Process.put(key, fn _, _, _ ->
            send(parent, :unexpected_start)
            {:error, :unexpected}
          end)

    for entry <- [:start, :with_runtime, :start_edges], invalid <- invalid_planes do
      assert {:error, {:invalid_composition_option, :credential_plane}} =
               invoke(entry, options ++ [credential_plane: invalid])

      refute_receive :unexpected_start, 0
    end

    for entry <- [:start, :with_runtime, :start_edges] do
      assert {:error, {:invalid_composition_option, :provider_bindings}} =
               invoke(entry, options ++ [credential_plane: plane, provider_bindings: bindings()])
    end

    refute File.exists?(options[:state_root])
  end

  test "missing ordinary or maintenance routes and local bindings refuse before consumption", %{
    options: options
  } do
    parent = self()

    for key <- [@edge, @effect],
        do:
          Process.put(key, fn _, _, _ ->
            send(parent, :unexpected_start)
            {:error, :unexpected}
          end)

    for extra <- [
          [provider_bindings: Map.take(bindings(), ["anthropic"])],
          [
            provider_bindings: Map.take(bindings(), ["openai"]),
            maintenance_model: "anthropic:claude-haiku-4-5"
          ]
        ] do
      assert {:error, :provider_route_unavailable} = invoke(:with_runtime, options ++ extra)
    end

    assert {:error, {:composition, :durable_model_unsupported}} =
             invoke(
               :start,
               options ++
                 [
                   provider_bindings:
                     Map.put(bindings(), "ollama", %{"credential" => %{"none" => true}})
                 ]
             )

    assert {:error, :maintenance_reasoning_unsupported} =
             invoke(
               :start,
               options ++
                 [provider_bindings: bindings(), maintenance_model: "anthropic:claude-fable-5-1"]
             )

    assert {:error, {:invalid_composition_option, :provider_launch}} =
             invoke(
               :start,
               options ++ [provider_launch: [provider_routes: %{}]]
             )

    assert System.get_env("M7_START_A") == "first-start-canary"
    assert System.get_env("M7_START_B") == "second-start-canary"
    assert System.get_env("LOOPEX_PROVIDER_API_KEY") == "unused-start-canary"
    refute File.exists?(options[:state_root])
    refute_receive :unexpected_start, 0
  end

  defp assert_runtime(runtime) do
    {:ok, children} = Loopex.Runtime.children(runtime)
    state = :sys.get_state(children.control)
    config = Map.new(state.model.options)
    assert config.excluded_env_names == @names

    for {model, expected} <- [
          {"openai:test", "first-start-canary"},
          {"anthropic:test", "second-start-canary"}
        ] do
      assert {:ok, selected} = ProviderConfiguration.select_route(config, model)

      assert {:ok, custody} =
               CredentialRegistry.route(selected.credential_registry, selected.credential_token)

      assert {:ok, %{credential: ^expected}} = CredentialCustody.resolve(custody)
    end

    assert state.maintenance_model["model"] == "anthropic:claude-haiku-4-5-20251001"
    assert state.maintenance_model["reasoning"] == "none"
    {:ok, public} = Loopex.Runtime.configuration(runtime)
    refute inspect(public) =~ "M7_START"
    refute Map.has_key?(public, :maintenance_model)
    :ok
  end

  defp invoke(:start, options), do: LoopexComposition.start(options)

  defp invoke(:with_runtime, options),
    do: LoopexComposition.with_runtime(options, fn _ -> flunk("callback ran") end)

  defp invoke(:start_edges, options) do
    assert {:error, reason, %{}} = LoopexComposition.start_edges(options)
    {:error, reason}
  end

  defp bindings,
    do: %{
      "openai" => %{"credential" => %{"env" => "M7_START_A"}},
      "anthropic" => %{"credential" => %{"env" => "M7_START_B"}}
    }

  defp host_pids(host) do
    [
      host.registry.pid
      | Enum.map(host.provider_routes, fn {_, token} ->
          {:ok, custody} = CredentialRegistry.route(host.registry, token)
          custody.pid
        end)
    ]
    |> Enum.uniq()
  end

  defp stop(pid) do
    if Process.alive?(pid) do
      Process.unlink(pid)
      GenServer.stop(pid)
    end
  end

  defp collect_owned(pids) do
    receive do
      {:owned_edge, {:ok, %{supervisor: pid}}} -> collect_owned([pid | pids])
      {:owned_edge, {:ok, pid}} when is_pid(pid) -> collect_owned([pid | pids])
    after
      0 -> pids
    end
  end

  defp await_store_release(root) do
    deadline = System.monotonic_time(:millisecond) + 5_000
    await_store_release(root, deadline)
  end

  defp await_store_release(root, deadline) do
    if File.exists?(Path.join(root, "store.log.writer")) do
      assert System.monotonic_time(:millisecond) < deadline
      Process.sleep(5)
      await_store_release(root, deadline)
    end
  end
end
