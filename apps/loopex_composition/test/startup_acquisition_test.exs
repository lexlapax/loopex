defmodule LoopexComposition.StartupAcquisitionTest do
  use ExUnit.Case, async: true

  alias Loopex.LLM.ReqLLM.{CredentialCustody, CredentialRegistry, CredentialToken}
  alias Loopex.Trace.Capability
  alias LoopexComposition.StartupGate

  alias LoopexComposition.StartupAcquisitionTest.{HeldStore, WithoutStartupRead}

  @edge :"$loopex_composition_edge_observer"

  defmodule Policy do
    @moduledoc false
    @behaviour Loopex.Policy
    @impl true
    def decide(_request), do: {:deny, :policy_denied}
  end

  setup do
    root =
      Path.join(System.tmp_dir!(), "loopex-startup-gate-#{System.unique_integer([:positive])}")

    workspace = Path.join(root, "workspace")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, registry_pid} = CredentialRegistry.start_link([])
    {:ok, registry} = CredentialRegistry.handle(registry_pid)
    {:ok, custody_pid} = CredentialCustody.start_link(credential: "startup-gate-test-key")
    {:ok, custody} = CredentialCustody.reference(custody_pid)
    token = CredentialToken.new()
    :ok = CredentialRegistry.put(registry, token, custody)
    {:ok, capability_pid} = Capability.start_link([])
    {:ok, capability} = Capability.handle(capability_pid)

    plane = %{
      capability: capability,
      version: 2,
      excluded_env_names: ["LOOPEX_PROVIDER_API_KEY"],
      model_options: [
        provider_routes: %{"anthropic" => token},
        credential_registry: registry,
        tracing_capability: capability
      ]
    }

    options = [
      runtime_id: "startup-gate",
      state_root: Path.join(root, "state"),
      workspace: workspace,
      policy: Policy,
      credential_plane: plane
    ]

    %{options: options}
  end

  for backend <- [:local, :memory], path <- [:start, :with_runtime, :start_edges] do
    test "#{path} cannot publish before actual #{backend} startup completes", %{options: options} do
      held_acquisition(options, unquote(path), unquote(backend))
    end
  end

  for target <- [:root, :workers], action <- [:caller_loss, :interrupt, :initial_cap] do
    test "#{target} bootstrap remains bounded through #{action}", %{options: options} do
      held_bootstrap(options, unquote(target), unquote(action))
    end
  end

  test "an adapter missing startup custody observation cannot publish or enter a bracket", %{
    options: options
  } do
    test = self()
    Process.put(@edge, nil)
    observe(test, :local, WithoutStartupRead)

    try do
      assert {:error, :runtime_unavailable} =
               LoopexComposition.with_runtime(options, fn _ ->
                 send(test, :unexpected_callback)
               end)

      assert_receive {:runtime_owned, owner, runtime}, 1_000
      owner_down = Process.monitor(owner)
      assert_receive {:DOWN, ^owner_down, :process, ^owner, _}, 2_000
      refute Loopex.Runtime.alive?(runtime)
      refute_received :unexpected_callback
    after
      Process.delete(@edge)
    end
  end

  test "caller death during actual held Local startup enters owned cleanup", %{options: options} do
    test = self()

    caller =
      spawn(fn ->
        observe(test)
        LoopexComposition.with_runtime(options, fn _ -> send(test, :unexpected_callback) end)
      end)

    assert_receive {:runtime_owned, owner, runtime}, 1_000
    assert_receive {:startup_read, _worker, _}, 1_000
    assert_receive {:startup_task, observer, ^owner, _initial}, 1_000
    assert_receive {:startup_first_read, ^observer, ^runtime}, 1_000

    assert_receive {:startup_snapshot_pinned, ^owner, ^observer, {:ok, %{state: :starting}}},
                   1_000

    observer_down = Process.monitor(observer)
    owner_down = Process.monitor(owner)
    runtime_down = Process.monitor(runtime.supervisor)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^runtime_down, :process, _, _}, 3_000
    assert_receive {:DOWN, ^owner_down, :process, ^owner, _}, 3_000
    assert_receive {:DOWN, ^observer_down, :process, ^observer, _}, 1_000
    refute_received :unexpected_callback
  end

  for lost <- [:owner, :store] do
    test "#{lost} loss interrupts actual held Local acquisition", %{options: options} do
      held_acquisition_loss(options, unquote(lost))
    end
  end

  test "tracked host interrupt remains responsive during actual held startup", %{options: options} do
    test = self()
    stop = :atomics.new(1, [])

    caller =
      spawn(fn ->
        Process.flag(:trap_exit, true)
        observe(test)

        interrupt = fn ->
          if :atomics.get(stop, 1) == 0, do: :continue, else: {:stop, :operator_stop}
        end

        send(test, {:interrupted, LoopexComposition.start_edges(options, interrupt: interrupt)})
        receive do: (:finish -> :ok)
      end)

    on_exit(fn -> if Process.alive?(caller), do: Process.exit(caller, :kill) end)
    assert_receive {:runtime_owned, owner, runtime}, 1_000
    assert_receive {:startup_read, creation_worker, _}, 1_000
    assert_receive {:startup_task, observer, ^owner, _initial}, 1_000
    assert_receive {:startup_first_read, ^observer, ^runtime}, 1_000

    assert_receive {:startup_snapshot_pinned, ^owner, ^observer, {:ok, %{state: :starting}}},
                   1_000

    {:ok, children} = Loopex.Runtime.children(runtime)
    owned_workers = Task.Supervisor.children(children.workers)
    assert length(owned_workers) >= 2
    assert observer in owned_workers
    {carrier, group} = held_creation_carrier(creation_worker, owned_workers)
    assert carrier in owned_workers

    actor_monitors =
      Enum.map([creation_worker, group | owned_workers], &{&1, Process.monitor(&1)})

    {^observer, observer_monitor} = List.keyfind(actor_monitors, observer, 0)
    :atomics.put(stop, 1, 1)
    assert_receive {:interrupted, {:error, {:stop, :operator_stop}, edges}}, 500
    assert edges.runtime == runtime
    assert_receive {:DOWN, ^observer_monitor, :process, ^observer, _}, 1_000
    :ok = Loopex.stop(runtime)

    for {actor, monitor} <- actor_monitors, actor != observer do
      assert_receive {:DOWN, ^monitor, :process, ^actor, _}, 1_000
    end

    stop_edges(edges)
    send(caller, :finish)
  end

  defp held_acquisition(options, path, backend) do
    test = self()

    {caller, caller_down} =
      spawn_monitor(fn ->
        Process.flag(:trap_exit, true)
        observe(test, backend)

        result =
          case path do
            :start ->
              LoopexComposition.start(options)

            :with_runtime ->
              LoopexComposition.with_runtime(options, fn runtime ->
                send(test, {:callback, runtime})
                :callback_result
              end)

            :start_edges ->
              LoopexComposition.start_edges(options)
          end

        send(test, {:acquired, result})
        receive do: (:finish -> :ok)
      end)

    on_exit(fn -> if Process.alive?(caller), do: Process.exit(caller, :kill) end)
    assert_receive {:runtime_owned, owner, runtime}, 1_000
    assert_receive {:startup_read, worker, %{command_id: nil}}, 1_000
    assert_receive {:startup_task, observer, ^owner, _initial}, 1_000
    assert_receive {:startup_first_read, ^observer, ^runtime}, 1_000

    assert_receive {:startup_snapshot_pinned, ^owner, ^observer, {:ok, %{state: :starting}}},
                   1_000

    observer_down = Process.monitor(observer)

    assert {:ok, %{state: :starting, startup_id: startup_id, startup_deadline_ms: cutoff}} =
             Loopex.creation_startup_status(runtime, 1_000)

    {:ok, children} = Loopex.Runtime.children(runtime)
    owned_workers = Task.Supervisor.children(children.workers)
    assert length(owned_workers) >= 2
    assert observer in owned_workers
    {carrier, group} = held_creation_carrier(worker, owned_workers)
    assert carrier in owned_workers

    actor_monitors =
      Enum.map([worker, group | owned_workers -- [observer]], &{&1, Process.monitor(&1)})

    refute_receive {:acquired, _}, 40
    refute_received {:callback, _}
    send(worker, :release_startup)
    assert_receive {:DOWN, ^observer_down, :process, ^observer, _}, 1_000

    case path do
      :start ->
        assert_receive {:acquired, {:ok, ^runtime}}, 1_000
        assert {:ok, _} = Loopex.create_session(runtime, %{}, command_id: "once")
        :ok = Loopex.stop(runtime)
        owner_down = Process.monitor(owner)
        assert_receive {:DOWN, ^owner_down, :process, ^owner, _}, 2_000

      :with_runtime ->
        assert_receive {:callback, ^runtime}, 1_000
        assert_receive {:acquired, :callback_result}, 2_000
        refute Loopex.Runtime.alive?(runtime)

      :start_edges ->
        assert_receive {:acquired, {:ok, edges}}, 1_000
        assert edges.runtime == runtime
        assert Process.alive?(runtime.supervisor)

        assert {:ok, %{state: :ready, startup_id: ^startup_id, startup_deadline_ms: ^cutoff}} =
                 Loopex.creation_startup_status(runtime, 1_000)

        :ok = Loopex.stop(runtime)
        stop_edges(edges)
    end

    for worker <- owned_workers, do: refute(Process.alive?(worker))

    for {actor, monitor} <- actor_monitors do
      assert_receive {:DOWN, ^monitor, :process, ^actor, _}, 1_000
    end

    send(caller, :finish)
    assert_receive {:DOWN, ^caller_down, :process, ^caller, :normal}, 1_000
  end

  # Concept: the held callback body and its owning carrier are distinct actors.
  # Technical depth: the direct Workers child monitors the original body and
  # private group; that group links both. No private Control state is read.
  defp held_creation_carrier(body, owned_workers) do
    {:monitored_by, body_monitors} = Process.info(body, :monitored_by)
    [carrier] = Enum.filter(owned_workers, &(&1 in body_monitors))
    {:monitors, carrier_monitors} = Process.info(carrier, :monitors)
    assert {:process, body} in carrier_monitors
    {:links, body_links} = Process.info(body, :links)
    [group] = for {:process, pid} <- carrier_monitors, pid in body_links, do: pid
    {:links, group_links} = Process.info(group, :links)
    assert body in group_links
    assert carrier in group_links
    refute body in owned_workers
    refute group in owned_workers
    {carrier, group}
  end

  defp held_bootstrap(options, target, action) do
    test = self()
    stop = :atomics.new(1, [])

    caller =
      spawn(fn ->
        Process.flag(:trap_exit, true)
        observe(test, :local, HeldStore, target)

        Process.put(:"$loopex_composition_effect_observer", fn module, function, arguments ->
          if module == Loopex and function == :stop,
            do: send(test, {:cleanup_started, self(), hd(arguments)})

          apply(module, function, arguments)
        end)

        if action == :caller_loss do
          send(
            test,
            {:bootstrap_result,
             LoopexComposition.with_runtime(options, fn _ -> send(test, :unexpected_callback) end)}
          )
        else
          interrupt = fn ->
            if :atomics.get(stop, 1) == 0, do: :continue, else: {:stop, :operator_stop}
          end

          send(
            test,
            {:bootstrap_result, LoopexComposition.start_edges(options, interrupt: interrupt)}
          )
        end

        receive do: (:finish -> :ok)
      end)

    on_exit(fn -> if Process.alive?(caller), do: Process.exit(caller, :kill) end)
    assert_receive {:bootstrap_held, owner, suspended, runtime, original_workers}, 1_000

    on_exit(fn ->
      try do
        :sys.resume(suspended)
      catch
        :exit, _ -> :ok
      end

      if Process.alive?(runtime.supervisor), do: Process.exit(runtime.supervisor, :kill)
    end)

    operation = if target == :root, do: :resolve, else: :admit
    assert_receive {:startup_request, ^owner, ^suspended, ^operation}, 1_000
    runtime_down = Process.monitor(runtime.supervisor)
    worker_monitors = Enum.map(original_workers, &{&1, Process.monitor(&1)})

    if action == :caller_loss do
      owner_down = Process.monitor(owner)
      Process.exit(caller, :kill)
      assert_receive {:cleanup_started, ^owner, ^runtime}, 500
      :sys.resume(suspended)
      assert_receive {:DOWN, ^runtime_down, :process, _, _}, 3_000
      assert_receive {:DOWN, ^owner_down, :process, ^owner, _}, 3_000
    else
      if action == :interrupt, do: :atomics.put(stop, 1, 1)
      expected = if action == :interrupt, do: {:stop, :operator_stop}, else: :runtime_unavailable
      bound = if action == :interrupt, do: 500, else: 1_500
      assert_receive {:bootstrap_result, {:error, ^expected, edges}}, bound
      assert edges.runtime == runtime
      refute_received {:startup_first_read, _, ^runtime}
      :sys.resume(suspended)

      late =
        if target == :workers do
          assert_receive {:startup_task, pid, ^owner, initial}, 1_000
          # The gate spends its cap in whole milliseconds and treats a
          # sub-millisecond remainder as expired, so the refusal can precede
          # `initial` by less than one millisecond, never by more.
          if action == :initial_cap,
            do:
              assert(
                System.monotonic_time() + System.convert_time_unit(1, :millisecond, :native) >
                  initial
              )

          monitor = Process.monitor(pid)

          if action == :initial_cap do
            assert_receive {:DOWN, ^monitor, :process, ^pid, _}, 1_000
            nil
          else
            {pid, monitor}
          end
        end

      :ok = Loopex.stop(runtime)
      assert_receive {:DOWN, ^runtime_down, :process, _, _}, 1_000

      if late do
        {pid, monitor} = late
        assert_receive {:DOWN, ^monitor, :process, ^pid, _}, 1_000
      end

      stop_edges(edges)
      send(caller, :finish)
    end

    for {worker, monitor} <- worker_monitors do
      assert_receive {:DOWN, ^monitor, :process, ^worker, _}, 1_000
    end

    refute_received {:startup_first_read, _, ^runtime}
    refute_received :unexpected_callback
  end

  defp held_acquisition_loss(options, lost) do
    test = self()

    caller =
      spawn(fn ->
        observe(test)

        result =
          LoopexComposition.with_runtime(options, fn _ -> send(test, :unexpected_callback) end)

        send(test, {:refused, result})
      end)

    on_exit(fn -> if Process.alive?(caller), do: Process.exit(caller, :kill) end)
    assert_receive {:edge_owned, Loopex.Store.Local, store}, 1_000
    assert_receive {:runtime_owned, owner, runtime}, 1_000
    assert_receive {:startup_read, _worker, _}, 1_000
    assert_receive {:startup_task, observer, ^owner, _initial}, 1_000
    assert_receive {:startup_first_read, ^observer, ^runtime}, 1_000

    assert_receive {:startup_snapshot_pinned, ^owner, ^observer, {:ok, %{state: :starting}}},
                   1_000

    observer_down = Process.monitor(observer)
    owner_down = Process.monitor(owner)
    runtime_down = Process.monitor(runtime.supervisor)
    victim = if lost == :owner, do: owner, else: store
    Process.exit(victim, :kill)
    assert_receive {:DOWN, ^runtime_down, :process, _, _}, 3_000
    assert_receive {:DOWN, ^owner_down, :process, ^owner, _}, 3_000
    assert_receive {:DOWN, ^observer_down, :process, ^observer, _}, 1_000
    assert_receive {:refused, {:error, _}}, 3_000
    refute_received :unexpected_callback
  end

  defp observe(test, backend \\ :local, adapter \\ HeldStore, suspend \\ nil) do
    reads = :atomics.new(1, [])
    Process.put({StartupGate, :test_listener}, test)

    Process.put(@edge, fn
      Loopex.Store.Local, :start_link, [_options] when backend == :memory ->
        Loopex.Store.Memory.start_link([])

      Loopex, :start_link, [options] ->
        Process.put({StartupGate, :test_listener}, test)
        store = Keyword.fetch!(options, :store)
        store = if backend == :memory, do: %{store | adapter: Loopex.Store.Memory}, else: store
        {:ok, held} = Loopex.Store.new(adapter, %{store: store, test: test, reads: reads})
        result = Loopex.start_link(Keyword.put(options, :store, held))

        case result do
          {:ok, runtime} ->
            if suspend do
              {:ok, children} = Loopex.Runtime.children(runtime)
              original_workers = Task.Supervisor.children(children.workers)
              suspended = if suspend == :root, do: runtime.supervisor, else: children.workers
              :ok = :sys.suspend(suspended)
              send(test, {:bootstrap_held, self(), suspended, runtime, original_workers})
            end

            send(test, {:runtime_owned, self(), runtime})

          _ ->
            :ok
        end

        result

      module, function, arguments ->
        result = apply(module, function, arguments)

        if function == :start_link do
          case result do
            {:ok, pid} when is_pid(pid) -> send(test, {:edge_owned, module, pid})
            _ -> :ok
          end
        end

        result
    end)
  end

  defp stop_edges(edges) do
    for {_key, pid} <- Map.drop(edges, [:runtime, :runtime_supervisor]) do
      Process.unlink(pid)
      if Process.alive?(pid), do: GenServer.stop(pid)
    end
  end
end
