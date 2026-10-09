Code.require_file("../../loopex/test/support/configured_genesis_helper.exs", __DIR__)

defmodule LoopexComposition.ProviderCleanupNotificationTest do
  use ExUnit.Case, async: false

  alias Loopex.Runtime
  alias Loopex.Runtime.OwnerGroup
  alias Loopex.Store.Local

  defmodule Model do
    @moduledoc false
    @behaviour Loopex.Model

    @impl Loopex.Model
    def complete(request, options, _progress) do
      observer = Keyword.fetch!(options, :observer)
      guard = Process.get(:loopex_provider_cleanup_guard)
      send(observer, {:callback_ready, self(), guard})

      receive do
        {:release_callback, ^observer} -> :ok
      after
        5_000 -> exit(:callback_release_missing)
      end

      {:ok,
       %{
         completion: "unknown",
         continuation: nil,
         text: "ordinary answer",
         identity: %{provider: "scripted", model: request.model, endpoint: "in-process"},
         usage: %{input_tokens: 1, output_tokens: 1},
         tool_calls: [],
         delta_count: 0,
         streamed: false,
         provider_response_id: nil,
         canonical_request_bytes: request.canonical_request_bytes,
         staged_request_digest: request.staged_request_digest
       }}
    end
  end

  defmodule Executor do
    @moduledoc false
    @behaviour Loopex.Executor

    @impl Loopex.Executor
    def execute(_, _, _, _, _), do: raise("no tools were offered")

    @impl Loopex.Executor
    def cancel(_, _), do: raise("no tools were offered")
  end

  # Concept: a successful callback leaves its real session owner available.
  # Technical depth: Local commits the actual two runs. Original monitors are
  # established while callbacks are held, before their normal cleanup and exits.
  test "ordinary cleanup completes two real runs without notifying or replacing the coordinator" do
    root =
      Path.join(System.tmp_dir!(), "loopex-cleanup-notice-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    {:ok, store_pid} = Local.start_link(path: Path.join(root, "store.log"))
    {:ok, store} = Loopex.Store.new(Local, store_pid)

    {:ok, runtime} =
      Loopex.start_link(
        runtime_id: "cleanup-notice",
        context_token_budget: 8_192,
        store: store,
        model: %{
          module: Model,
          model: "scripted:v1",
          options: [observer: self(), max_tokens: 1_024]
        },
        executor: %{
          module: Executor,
          reference: self(),
          identity: "unused",
          epoch: 1,
          fencing_token: 1,
          workspace_ref: "unused",
          workspace_lease: "unused"
        },
        grant_decision: {:host_policy, :allow}
      )

    supervisor_monitor = Process.monitor(runtime.supervisor)
    store_monitor = Process.monitor(store_pid)

    try do
      assert :ok =
               LoopexComposition.StartupGate.publication(
                 LoopexComposition.StartupGate.await(runtime)
               )

      assert {:ok, session} =
               Runtime.create_session_with_genesis(
                 runtime,
                 "create",
                 %{},
                 Loopex.ConfiguredGenesisFixture.genesis([])
               )

      assert {:ok, attachment} = Loopex.attach(runtime, session, after_event_sequence: 0)
      assert {:ok, children} = Runtime.children(runtime)
      [{_, coordinator, _, _}] = DynamicSupervisor.which_children(children.sessions)
      [{_, group, _, _}] = Supervisor.which_children(children.owner_groups)
      assert {:ok, workers} = OwnerGroup.workers(group)

      owned =
        for pid <- [coordinator, group, workers], do: {pid, Process.monitor(pid)}

      cutoff = System.monotonic_time(:millisecond) + 5_000

      for command_id <- ["first", "second"] do
        assert {:accepted, ^command_id} =
                 Loopex.command(attachment, %{
                   type: :prompt,
                   command_id: command_id,
                   content: command_id
                 })

        assert_receive {:callback_ready, callback, guard}, left(cutoff)
        assert is_pid(guard)
        %{providers: providers} = :sys.get_state(group, left(cutoff))
        [{_, provider}] = Map.to_list(providers)
        assert provider.guard == guard
        assert provider.retainer == coordinator
        assert provider.caretaker == nil
        assert is_pid(provider.worker)

        invocation =
          for pid <- [callback, guard, provider.worker], do: {pid, Process.monitor(pid)}

        send(callback, {:release_callback, self()})
        events = until_finished(attachment, cutoff, [])
        assert Enum.any?(events, &(&1.kind == "assistant.message_appended"))
        assert List.last(events)["outcome"] == "completed"

        for {pid, monitor} <- invocation do
          assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, left(cutoff)
          refute Process.alive?(pid)
        end

        assert Process.alive?(coordinator)
        assert [{_, ^coordinator, _, _}] = DynamicSupervisor.which_children(children.sessions)
        assert %{providers: providers} = :sys.get_state(group, left(cutoff))
        assert providers == %{}
        assert Task.Supervisor.children(workers) == []
      end

      assert {:ok, events} = Local.load_events(store_pid, session, 0, 1_000)
      assert Enum.count(events, &(&1.kind == "run.finished")) == 2
      assert :ok = Loopex.stop(runtime)

      for {pid, monitor} <- owned ++ [{runtime.supervisor, supervisor_monitor}] do
        assert_receive {:DOWN, ^monitor, :process, ^pid, _reason}, left(cutoff)
        refute Process.alive?(pid)
      end

      assert :ok = GenServer.stop(store_pid)
      assert_receive {:DOWN, ^store_monitor, :process, ^store_pid, :normal}, left(cutoff)
    after
      if Process.alive?(runtime.supervisor), do: Loopex.stop(runtime)
      if Process.alive?(store_pid), do: GenServer.stop(store_pid)
      File.rm_rf!(root)
    end
  end

  # Concept: a distinct invocation caretaker retains its shared cleanup window.
  # Technical depth: the real Group receives authenticated native calls from
  # its retained Task; guard/worker/caretaker notices use their exact identity.
  test "the native group still notifies the distinct caretaker and both provider actors" do
    observer = self()
    cutoff = System.monotonic_time(:millisecond) + 1_000
    reference = make_ref()
    bound = {:monotonic, cutoff}
    coordinator = spawn(fn -> receive do: (:finish -> :ok) end)
    coordinator_monitor = Process.monitor(coordinator)
    {:ok, group} = GenServer.start(OwnerGroup, [])
    group_monitor = Process.monitor(group)
    assert :ok = OwnerGroup.attach(group, coordinator)
    assert {:ok, workers} = OwnerGroup.workers(group)
    workers_monitor = Process.monitor(workers)

    try do
      guard = actor(workers, observer, :guard, group, reference)
      worker = actor(workers, observer, :worker, group, reference)

      {:ok, caretaker} =
        Task.Supervisor.start_child(workers, fn ->
          :ok = OwnerGroup.retain_provider(group, guard, reference, 1, bound)
          :ok = OwnerGroup.bind_provider(group, reference, worker, bound)
          send(observer, {:caretaker_ready, self()})

          receive do
            {:select_window, window} ->
              {:ok, ^window} = OwnerGroup.provider_cleanup(group, reference, window)

              receive do
                {:loopex_provider_cleanup_window, ^group, ^reference, ^window} ->
                  send(observer, {:window_received, :caretaker, self(), window})
              end
          end

          receive do: (:finish -> :ok)
        end)

      monitors = for pid <- [guard, worker, caretaker], do: {pid, Process.monitor(pid)}
      assert_receive {:caretaker_ready, ^caretaker}, left(cutoff)
      {:ok, %{executor_observe_ms: observation}} = Loopex.Executor.cancellation_bounds(1)
      started = System.monotonic_time(:millisecond)
      window = %{cooperative_deadline: started + 1, observation_deadline: started + observation}
      send(caretaker, {:select_window, window})

      for {role, pid} <- [guard: guard, worker: worker, caretaker: caretaker] do
        assert_receive {:window_received, ^role, ^pid, ^window}, left(cutoff)
      end

      assert {:messages, []} = Process.info(coordinator, :messages)

      for {pid, monitor} <- monitors do
        send(pid, :finish)
        assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, left(cutoff)
      end

      assert :ok = GenServer.stop(group, :normal, left(cutoff))
      assert_receive {:DOWN, ^group_monitor, :process, ^group, :normal}, left(cutoff)
      assert_receive {:DOWN, ^workers_monitor, :process, ^workers, _reason}, left(cutoff)
      assert_receive {:DOWN, ^coordinator_monitor, :process, ^coordinator, _reason}, left(cutoff)
    after
      if Process.alive?(coordinator), do: send(coordinator, :finish)
      if Process.alive?(group), do: GenServer.stop(group, :normal, left(cutoff))
    end
  end

  defp actor(workers, observer, role, group, reference) do
    {:ok, pid} =
      Task.Supervisor.start_child(workers, fn ->
        receive do
          {:loopex_provider_cleanup_window, ^group, ^reference, window} ->
            send(observer, {:window_received, role, self(), window})
        end

        receive do: (:finish -> :ok)
      end)

    pid
  end

  defp until_finished(attachment, cutoff, events) do
    assert System.monotonic_time(:millisecond) < cutoff

    case Loopex.next_event(attachment) do
      {:ok, %{kind: "run.finished"} = event} ->
        Enum.reverse([event | events])

      {:ok, event} ->
        until_finished(attachment, cutoff, [event | events])

      _ ->
        Process.sleep(5)
        until_finished(attachment, cutoff, events)
    end
  end

  defp left(cutoff), do: max(cutoff - System.monotonic_time(:millisecond), 0)
end
