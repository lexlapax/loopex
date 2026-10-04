defmodule LoopexDaemon.ProviderBindingsTest do
  use ExUnit.Case, async: false
  @moduletag capture_log: true

  alias LoopexDaemon.{ExitStatus, Sentinel, Service}
  alias LoopexComposition.{CredentialPlane, Placement}
  alias Loopex.LLM.ReqLLM.{CredentialCustody, CredentialRegistry, ProviderConfiguration}

  @names ~w(LOOPEX_PROVIDER_API_KEY M7_DAEMON_A M7_DAEMON_B)

  defmodule Policy do
    @moduledoc false
    @behaviour Loopex.Policy
    @impl true
    def decide(_), do: {:deny, :test}
  end

  setup do
    root = Loopex.TestTmp.Daemon.path("ldb-")
    workspace = Path.join(root, "w")
    File.mkdir_p!(workspace)
    previous = Map.new(@names, &{&1, System.get_env(&1)})
    seed_credentials()

    on_exit(fn ->
      for {name, value} <- previous do
        if value, do: System.put_env(name, value), else: System.delete_env(name)
      end

      File.rm_rf!(root)
    end)

    state_root = Path.join(root, "s")

    %{
      options: [
        state_root: state_root,
        socket_path: Path.join([state_root, "daemon", "d.sock"]),
        workspace: workspace,
        policy: Policy,
        model: "openai:test",
        provider_bindings: bindings(),
        admission_wait_ms: 200
      ]
    }
  end

  test "daemon owns both routes, forwards configuration and joins orderly cleanup", %{
    options: options
  } do
    trace = trace_calls([{Placement, :process_incarnation, 3}])

    options =
      options ++
        [
          maintenance_model: "anthropic:claude-haiku-4-5",
          maintenance_instructions: %{"version" => "daemon-v1", "body" => "Retain facts."},
          active_tools: [],
          sampling: %{"max_tokens" => 2048},
          bounds: %{max_turns: 3}
        ]

    {task, sentinel, ref, owner} = ready(options)
    state = :sys.get_state(owner)
    assert Enum.all?(@names, &(System.get_env(&1) == nil))
    assert length(custodies(state)) == 2
    assert state.excluded_env_names == @names
    {:ok, children} = Loopex.Runtime.children(state.edges.runtime)
    control = :sys.get_state(children.control)
    assert control.model.model == "openai:test"
    assert control.active_tools == []
    assert control.sampling == %{"max_tokens" => 2048}
    assert control.bounds.max_turns == 3
    defaults = control.session_creation_defaults
    assert defaults == state.options[:session_creation_defaults]

    assert Enum.sort(Map.keys(defaults)) ==
             ~w(initial_configuration policy_defer_mode runtime_configuration tool_selection)

    assert defaults["initial_configuration"]["model"] == "openai:test"
    assert defaults["initial_configuration"]["max_tokens"] == 2048

    assert defaults["tool_selection"] == %{
             "definitions" => [],
             "names" => %{},
             "artifact_read" => nil
           }

    assert defaults["runtime_configuration"] == %{"cleanup_grace_ms" => 5_000}

    assert {:ok, instructions} =
             Loopex.Runtime.MaintenanceConfiguration.capture_instructions(
               options[:maintenance_instructions]
             )

    assert control.maintenance_instructions == instructions
    config = Map.new(control.model.options)
    assert config.excluded_env_names == @names
    assert control.maintenance_model["model"] == "anthropic:claude-haiku-4-5-20251001"
    assert control.maintenance_model["reasoning"] == "none"

    for {model, key} <- [
          {"openai:test", "daemon-first-canary"},
          {"anthropic:test", "daemon-second-canary"}
        ] do
      assert {:ok, selected} = ProviderConfiguration.select_route(config, model)

      assert {:ok, custody} =
               CredentialRegistry.route(selected.credential_registry, selected.credential_token)

      assert {:ok, %{credential: ^key}} = CredentialCustody.resolve(custody)
    end

    {:ok, public} = Loopex.Runtime.configuration(state.edges.runtime)
    refute inspect(public) =~ "M7_DAEMON"
    refute inspect(:sys.get_status(owner)) =~ "M7_DAEMON"
    System.put_env("M7_DAEMON_A", "reintroduced-first-canary")
    send(sentinel, {:daemon_signal, ref, :sigterm})
    assert Task.await(task, 60_000) == 0
    assert Enum.all?(Map.values(state.pids), &(not Process.alive?(&1)))

    assert_receive {:trace, ^owner, :call,
                    {Placement, :process_incarnation, [_, "/bin/ps", @names]}}

    assert_receive {:trace, release_worker, :call,
                    {Placement, :process_incarnation, [_, "/bin/ps", @names]}}
                   when release_worker != owner

    :trace.session_destroy(trace)
  end

  test "shared references create one custody and keep both provider tokens", %{options: options} do
    shared = Map.put(bindings(), "anthropic", bindings()["openai"])
    {task, sentinel, ref, owner} = ready(Keyword.put(options, :provider_bindings, shared))
    state = :sys.get_state(owner)
    assert length(custodies(state)) == 1
    routes = state.components.credential_plane.model_options[:provider_routes]
    assert routes["openai"] == routes["anthropic"]
    assert System.get_env("M7_DAEMON_A") == nil
    assert System.get_env("M7_DAEMON_B") == "daemon-second-canary"
    send(sentinel, {:daemon_signal, ref, :sigterm})
    assert Task.await(task, 60_000) == 0
    assert Enum.all?(Map.values(state.pids), &(not Process.alive?(&1)))
  end

  test "conflicting, malformed and unbound inputs refuse before environment or placement effects",
       %{options: options} do
    cases = [
      Keyword.put(options, :credential, "conflicting-canary"),
      Keyword.put(options, :provider_bindings, %{
        "openai" => %{"credential" => %{"env" => "HOME"}}
      }),
      Keyword.put(options, :provider_bindings, %{}),
      Keyword.put(options, :provider_bindings, nil),
      Keyword.put(options, :model, "openrouter:unbound"),
      Keyword.put(options, :maintenance_model, "openrouter:unbound"),
      Keyword.put(
        options,
        :provider_bindings,
        Map.put(bindings(), "ollama", %{"credential" => %{"none" => true}})
      )
    ]

    {:ok, failed} = ExitStatus.fetch(:credential_plane_start_failed)

    for candidate <- cases do
      {:ok, output} = StringIO.open("")
      assert Sentinel.run(candidate, output: output, install_signals: false) == failed
      assert StringIO.contents(output) == {"", ""}
      refute File.exists?(options[:state_root])
      assert System.get_env("M7_DAEMON_A") == "daemon-first-canary"
      assert System.get_env("M7_DAEMON_B") == "daemon-second-canary"
      assert System.get_env("LOOPEX_PROVIDER_API_KEY") == "unused-daemon-canary"
    end
  end

  test "missing second value joins the shared loader's partial custody", %{options: options} do
    trace = trace_calls([{CredentialPlane, :stop_bindings, 1}])
    System.delete_env("M7_DAEMON_B")
    {:ok, failed} = ExitStatus.fetch(:credential_plane_start_failed)
    {:ok, output} = StringIO.open("")
    assert Sentinel.run(options, output: output, install_signals: false) == failed
    assert_receive {:trace, _, :call, {CredentialPlane, :stop_bindings, [loaded]}}
    assert length(loaded.pids) == 2
    assert Enum.all?(loaded.pids, &(not Process.alive?(&1)))
    refute File.exists?(Path.join(options[:state_root], "store.log"))
    assert Enum.all?(@names, &(System.get_env(&1) == nil))
    :trace.session_destroy(trace)
  end

  test "failure after binding bootstrap joins every acquired credential process", %{
    options: options
  } do
    trace = trace_calls([{Service, :finish_startup_failure, 2}])
    {:ok, output} = StringIO.open("")
    {:ok, failed} = ExitStatus.fetch(:composition_start_failed)

    assert Sentinel.run(Keyword.put(options, :policy, nil),
             output: output,
             install_signals: false
           ) == failed

    assert_receive {:trace, _, :call,
                    {Service, :finish_startup_failure,
                     [state, {:fatal, :composition_start_failed}]}}

    assert length(custodies(state)) == 2
    assert Map.has_key?(state.pids, :credential_registry)
    assert Map.has_key?(state.pids, :capability)
    assert map_size(state.pids) == 4
    assert Enum.all?(Map.values(state.pids), &(not Process.alive?(&1)))
    assert Enum.all?(@names, &(System.get_env(&1) == nil))
    refute File.exists?(Path.join(options[:state_root], "store.log"))
    :trace.session_destroy(trace)
  end

  test "loss of either custody retains the daemon's custody_lost class", %{options: options} do
    {:ok, failed} = ExitStatus.fetch(:custody_lost)

    for index <- 0..1 do
      seed_credentials()
      root = options[:state_root] <> Integer.to_string(index)

      candidate =
        Keyword.merge(options,
          state_root: root,
          socket_path: Path.join([root, "daemon", "d.sock"])
        )

      {task, _sentinel, _ref, owner} = ready(candidate)
      state = :sys.get_state(owner)

      on_exit(fn ->
        for pid <- Map.values(state.pids) do
          Process.exit(pid, :kill)
          await_down(pid)
        end
      end)

      custody = Enum.at(custodies(state), index)
      Process.exit(custody, :kill)
      assert Task.await(task, 60_000) == failed
      await_down(custody)
      # Fail-stop leaves the other custody for the CLI's VM halt. This in-process
      # fixture joins those remaining children in on_exit, as the legacy tests do.
    end
  end

  defp ready(options) do
    {:ok, output} = StringIO.open("")
    test = self()

    task =
      Task.async(fn ->
        Sentinel.run(options, output: output, install_signals: false, notify: test)
      end)

    assert_receive {:loopex_daemon_sentinel, sentinel, ref, owner}, 5_000

    on_exit(fn ->
      if Process.alive?(owner), do: send(sentinel, {:daemon_signal, ref, :sigterm})
    end)

    await_ready(output, System.monotonic_time(:millisecond) + 10_000)
    {task, sentinel, ref, owner}
  end

  defp await_ready(output, deadline) do
    case StringIO.contents(output) do
      {"", line} when byte_size(line) > 0 ->
        :ok

      _ ->
        assert System.monotonic_time(:millisecond) < deadline, "daemon never announced readiness"
        Process.sleep(5)
        await_ready(output, deadline)
    end
  end

  defp await_down(pid) do
    monitor = Process.monitor(pid)
    assert_receive {:DOWN, ^monitor, :process, ^pid, _}, 5_000
  end

  defp custodies(state), do: for({{:custody, _}, pid} <- Enum.sort(state.pids), do: pid)

  defp trace_calls(functions) do
    trace = :trace.session_create(:m7_daemon_bindings, self(), [])

    for {module, _, _} = function <- functions do
      Code.ensure_loaded!(module)
      assert :trace.function(trace, function, true, [:local]) == 1
    end

    assert :trace.process(trace, self(), true, [:call, :set_on_spawn]) == 1

    on_exit(fn ->
      try do
        :trace.session_destroy(trace)
      catch
        :error, :badarg -> :ok
      end
    end)

    trace
  end

  defp bindings,
    do: %{
      "openai" => %{"credential" => %{"env" => "M7_DAEMON_A"}},
      "anthropic" => %{"credential" => %{"env" => "M7_DAEMON_B"}}
    }

  defp seed_credentials do
    System.put_env("M7_DAEMON_A", "daemon-first-canary")
    System.put_env("M7_DAEMON_B", "daemon-second-canary")
    System.put_env("LOOPEX_PROVIDER_API_KEY", "unused-daemon-canary")
  end
end
