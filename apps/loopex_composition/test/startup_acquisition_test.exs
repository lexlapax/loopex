defmodule LoopexComposition.StartupAcquisitionTest do
  use ExUnit.Case, async: true

  alias Loopex.LLM.ReqLLM.{CredentialCustody, CredentialRegistry, CredentialToken}
  alias Loopex.Trace.Capability

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
      model_options: [
        credential_token: token,
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
      path = unquote(path)
      backend = unquote(backend)
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
      assert {:ok, %{state: :starting}} = Loopex.creation_startup_status(runtime, 1_000)
      {:ok, children} = Loopex.Runtime.children(runtime)
      owned_workers = Task.Supervisor.children(children.workers)
      assert length(owned_workers) >= 2
      refute_receive {:acquired, _}, 40
      refute_received {:callback, _}
      send(worker, :release_startup)

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
          :ok = Loopex.stop(runtime)
          stop_edges(edges)
      end

      for worker <- owned_workers, do: refute(Process.alive?(worker))

      send(caller, :finish)
      assert_receive {:DOWN, ^caller_down, :process, ^caller, :normal}, 1_000
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
    owner_down = Process.monitor(owner)
    runtime_down = Process.monitor(runtime.supervisor)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^runtime_down, :process, _, _}, 3_000
    assert_receive {:DOWN, ^owner_down, :process, ^owner, _}, 3_000
    refute_received :unexpected_callback
  end

  for lost <- [:owner, :store] do
    test "#{lost} loss interrupts actual held Local acquisition", %{options: options} do
      lost = unquote(lost)
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
      owner_down = Process.monitor(owner)
      runtime_down = Process.monitor(runtime.supervisor)
      victim = if lost == :owner, do: owner, else: store
      Process.exit(victim, :kill)
      assert_receive {:DOWN, ^runtime_down, :process, _, _}, 3_000
      assert_receive {:DOWN, ^owner_down, :process, ^owner, _}, 3_000
      assert_receive {:refused, {:error, _}}, 3_000
      refute_received :unexpected_callback
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
    assert_receive {:runtime_owned, _owner, runtime}, 1_000
    assert_receive {:startup_read, _worker, _}, 1_000
    {:ok, children} = Loopex.Runtime.children(runtime)
    owned_workers = Task.Supervisor.children(children.workers)
    assert length(owned_workers) >= 2
    worker_monitors = Enum.map(owned_workers, &{&1, Process.monitor(&1)})
    :atomics.put(stop, 1, 1)
    assert_receive {:interrupted, {:error, {:stop, :operator_stop}, edges}}, 500
    assert edges.runtime == runtime
    :ok = Loopex.stop(runtime)

    for {worker, monitor} <- worker_monitors do
      assert_receive {:DOWN, ^monitor, :process, ^worker, _}, 1_000
    end

    stop_edges(edges)
    send(caller, :finish)
  end

  defp observe(test, backend \\ :local, adapter \\ HeldStore) do
    reads = :atomics.new(1, [])

    Process.put(@edge, fn
      Loopex.Store.Local, :start_link, [_options] when backend == :memory ->
        Loopex.Store.Memory.start_link([])

      Loopex, :start_link, [options] ->
        store = Keyword.fetch!(options, :store)
        store = if backend == :memory, do: %{store | adapter: Loopex.Store.Memory}, else: store
        {:ok, held} = Loopex.Store.new(adapter, %{store: store, test: test, reads: reads})
        result = Loopex.start_link(Keyword.put(options, :store, held))

        case result do
          {:ok, runtime} -> send(test, {:runtime_owned, self(), runtime})
          _ -> :ok
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
