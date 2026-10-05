Code.require_file("support/m1_runtime_helper.exs", __DIR__)
Code.require_file("support/agent_loop_helper.exs", __DIR__)
Code.require_file("support/configured_genesis_helper.exs", __DIR__)

defmodule Loopex.NativeCompactStatusTest do
  use ExUnit.Case, async: false

  alias Loopex.AgentLoopFixture, as: Fixture
  alias Loopex.ConfiguredGenesisFixture, as: Genesis
  alias Loopex.M1RuntimeTestStore, as: TestStore
  alias Loopex.Runtime.SessionState
  alias Loopex.Store

  # Concept: hold recovery of an actual uncertain Store transaction.
  # Technical depth: the adapter delegates every outcome to the real fault Store.
  # The gate delays only re-presentation of the preallocated compact transaction;
  # no callback substitutes an admission, a status result or a public event.
  defmodule GatedStore do
    @moduledoc false
    @behaviour Store
    @impl Store
    def transact({store, gate}, transaction) do
      state = Agent.get(gate, & &1)
      tx_id = Map.get(transaction, :tx_id)

      if state.block and is_binary(tx_id) and state.tx_id == tx_id do
        send(state.observer, {:held_compact_recovery, self(), transaction})

        receive do
          :release -> :ok
        end
      end

      result = TestStore.transact(store, transaction)

      if match?({:commit_unknown, _}, result) and
           Enum.any?(
             Map.get(transaction, :records, []),
             &(&1.kind == "compact_command_admitted_v1")
           ) do
        Agent.update(gate, &%{&1 | tx_id: transaction.tx_id})
        send(state.observer, {:actual_compact_unknown, transaction})
      end

      result
    end

    @impl Store
    def transaction_status({store, _}, session, domain, id),
      do: TestStore.transaction_status(store, session, domain, id)

    @impl Store
    def ownership_head({store, _}, session, domain),
      do: TestStore.ownership_head(store, session, domain)

    @impl Store
    def runtime_command({store, _}, command), do: TestStore.runtime_command(store, command)
    @impl Store
    def load_records({store, _}, session, after_version, limit),
      do: TestStore.load_records(store, session, after_version, limit)

    @impl Store
    def load_events({store, _}, session, after_sequence, limit),
      do: TestStore.load_events(store, session, after_sequence, limit)
  end

  test "native pending includes pre-episode preparation, external admission, paused succession and abort until committed completion" do
    {fixture, session, attachment} = start()
    assert {:ok, %{compact_pending: false}} = Loopex.session_status(fixture.runtime, session)
    predecessor = owner(fixture, session)
    hold_first_worker(:sys.get_state(predecessor).owner_workers)
    external = Task.async(fn -> Loopex.command(attachment, compact()) end)
    assert Task.await(external, 5_000) == {:accepted, "compact"}
    assert_receive {:held_compact_preparation, worker}, 5_000
    worker_monitor = Process.monitor(worker)
    before = Fixture.records(fixture, session)
    assert {:ok, preparing} = Loopex.session_status(fixture.runtime, session)
    assert preparing.compact_pending === true
    assert preparing.active_run_id == nil and preparing.active_bounds == nil
    assert preparing.pending_work_ids == [] and preparing.active_maintenance == nil
    assert preparing.event_sequence == 0
    assert Fixture.events(fixture, session) == []
    assert Fixture.records(fixture, session) == before
    assert recover(fixture, session).maintenance_episodes == %{}
    owner_monitor = Process.monitor(predecessor)
    Process.exit(predecessor, :kill)
    assert_receive {:DOWN, ^owner_monitor, :process, ^predecessor, :killed}, 5_000
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, _}, 5_000

    assert {:ok, {:prepared, _activation}} =
             Loopex.prepare_resume_session(fixture.runtime, session, "observe")

    {:ok, successor} = Loopex.attach(fixture.runtime, session, after_event_sequence: 0)
    current = owner(fixture, session)
    assert {:ok, paused} = Loopex.session_status(fixture.runtime, session)
    assert paused.compact_pending === true
    assert paused.owner_epoch > preparing.owner_epoch
    assert paused.active_run_id == nil and paused.active_maintenance == nil
    assert paused.event_sequence == preparing.event_sequence
    assert :sys.get_state(current).in_flight == %{}
    assert Task.Supervisor.children(:sys.get_state(current).owner_workers) == []
    assert recover(fixture, session).pending_compact["command_id"] == "compact"
    assert {:accepted, "abort"} = Loopex.command(successor, %{type: :abort, command_id: "abort"})
    completed = await_completion(fixture, session)
    assert completed["result"]["failure"]["category"] == "cancelled"
    assert completed["result"]["cleanup"] == "confirmed"
    assert {:ok, final} = Loopex.session_status(fixture.runtime, session)
    assert final.compact_pending === false
    assert final.event_sequence == completed.event_sequence
    assert recover(fixture, session).pending_compact == nil
    assert Task.Supervisor.children(:sys.get_state(current).owner_workers) == []
  end

  test "unchanged and preparation-failed completion clear pending only at their committed result" do
    for history? <- [false, true] do
      {fixture, session, attachment} = start()

      if history? do
        assert {:accepted, "old"} =
                 Loopex.command(
                   attachment,
                   %{type: :prompt, command_id: "old", content: "retained fact"}
                 )

        assert {:accepted, "finish"} =
                 Loopex.command(
                   attachment,
                   %{type: :abort, command_id: "finish"}
                 )

        _settled = await_kind(fixture, session, "session.settled")
      end

      assert {:accepted, "compact"} = Loopex.command(attachment, compact())
      completed = await_completion(fixture, session)
      assert completed["result"]["disposition"] == if(history?, do: "failed", else: "unchanged")
      assert {:ok, final} = Loopex.session_status(fixture.runtime, session)
      assert final.compact_pending === false
      assert final.event_sequence == completed.event_sequence
      assert recover(fixture, session).pending_compact == nil
      assert recover(fixture, session).maintenance_episodes == %{}
      rows = Fixture.records(fixture, session)
      assert Enum.count(rows, &(&1.payload.kind == "compact_command_completed_v1")) == 1
      assert Map.has_key?(List.last(rows).payload, "result")
      assert :sys.get_state(owner(fixture, session)).in_flight == %{}
    end
  end

  for phase <- [
        :before_linearization,
        :after_linearization_before_result,
        :recovery_representation
      ] do
    @phase phase
    test "native reads refuse throughout actual #{@phase} admission uncertainty without renewing or dispatching" do
      {fixture, session, attachment} = start(gated: true)
      assert :ok = TestStore.inject(fixture.store, {:session_journal_commit, @phase})
      assert {:error, :commit_unknown} = Loopex.command(attachment, compact())
      assert_receive {:actual_compact_unknown, transaction}, 5_000
      assert_receive {:held_compact_recovery, worker, ^transaction}, 5_000
      monitor = Process.monitor(worker)
      coordinator = owner(fixture, session)
      captured = :sys.get_state(coordinator)
      cutoff = captured.unknown_admission.deadline
      records = Fixture.records(fixture, session)
      assert Loopex.session_status(fixture.runtime, session) == {:error, :session_unavailable}
      assert Loopex.session_status(fixture.runtime, session) == {:error, :session_unavailable}
      assert :sys.get_state(coordinator).unknown_admission.deadline == cutoff
      assert Fixture.records(fixture, session) == records
      assert Fixture.events(fixture, session) == []
      assert :sys.get_state(coordinator).in_flight == %{}
      assert :sys.get_state(coordinator).durable.maintenance_episodes == %{}
      Agent.update(fixture.gate, &%{&1 | block: false})
      send(worker, :release)
      assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 5_000
      completed = await_completion(fixture, session)
      assert completed["result"]["disposition"] == "unchanged"
      assert {:ok, final} = Loopex.session_status(fixture.runtime, session)
      assert final.compact_pending === false
      assert final.event_sequence == completed.event_sequence

      assert Enum.count(
               Fixture.records(fixture, session),
               &(&1.payload.kind == "compact_command_admitted_v1")
             ) == 1

      assert MapSet.member?(TestStore.observed(fixture.store), {:session_journal_commit, @phase})
      assert Task.Supervisor.children(:sys.get_state(coordinator).owner_workers) == []
    end
  end

  @tag :long_bound
  test "expired unknown admission remains unavailable after its exact recovery worker is joined" do
    {fixture, session, attachment} = start(gated: true, cleanup_grace_ms: 1)

    assert :ok =
             TestStore.inject(
               fixture.store,
               {:session_journal_commit, :after_linearization_before_result}
             )

    assert {:error, :commit_unknown} = Loopex.command(attachment, compact())
    assert_receive {:actual_compact_unknown, _transaction}, 5_000
    assert_receive {:held_compact_recovery, worker, _same_transaction}, 5_000
    monitor = Process.monitor(worker)
    coordinator = owner(fixture, session)
    captured = :sys.get_state(coordinator)
    assert {:ok, bounds} = Loopex.Executor.cancellation_bounds(1)
    assert Loopex.session_status(fixture.runtime, session) == {:error, :session_unavailable}
    assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}, bounds.cli_backstop_ms + 5_000
    assert System.monotonic_time(:millisecond) >= captured.unknown_admission.deadline
    expired = :sys.get_state(coordinator)
    assert expired.unknown_admission.expired
    assert expired.unknown_admission.deadline == captured.unknown_admission.deadline
    assert expired.unknown_admission.worker == nil
    assert Loopex.session_status(fixture.runtime, session) == {:error, :session_unavailable}
    assert Fixture.events(fixture, session) == []

    refute Enum.any?(
             Fixture.records(fixture, session),
             &(&1.payload.kind == "compact_command_completed_v1")
           )

    assert expired.in_flight == %{}
    assert Task.Supervisor.children(expired.owner_workers) == []
  end

  defp start(options \\ []) do
    {pid, direct_store} = TestStore.start_store()
    observer = self()
    {:ok, gate} = Agent.start_link(fn -> %{observer: observer, tx_id: nil, block: true} end)
    {:ok, gated_store} = Store.new(GatedStore, {pid, gate})
    store = if Keyword.get(options, :gated, false), do: gated_store, else: direct_store

    {:ok, runtime} =
      Loopex.start_link(runtime_id: "native-compact", store: store, context_token_budget: 8_192)

    fixture = %{runtime: runtime, store: pid, gate: gate}

    on_exit(fn ->
      Fixture.stop(fixture)
      if Process.alive?(gate), do: Agent.stop(gate)
    end)

    grace = Keyword.get(options, :cleanup_grace_ms, 5_000)
    genesis = Genesis.genesis([]) |> put_in(["runtime_configuration", "cleanup_grace_ms"], grace)
    {:ok, session} = Loopex.create_session(runtime, %{}, command_id: "create", genesis: genesis)
    {:ok, attachment} = Loopex.attach(runtime, session, after_event_sequence: 0)
    {fixture, session, attachment}
  end

  defp compact,
    do: %{
      type: :compact,
      command_id: "compact",
      bounds: %{max_attempts: 4, deadline_ms: 60_000, token_budget: 32_768}
    }

  defp owner(fixture, session) do
    {:ok, children} = Loopex.Runtime.children(fixture.runtime)
    :sys.get_state(children.control).sessions[session].coordinator
  end

  defp recover(fixture, session) do
    assert {:ok, state} =
             SessionState.recover(
               session,
               Fixture.records(fixture, session),
               Fixture.events(fixture, session)
             )

    state
  end

  defp await_completion(fixture, session),
    do: await_kind(fixture, session, "context.compaction_finished")

  defp await_kind(fixture, session, kind, remaining \\ 5_000) do
    case Enum.find(Fixture.events(fixture, session), &(&1.kind == kind)) do
      nil when remaining > 0 ->
        Process.sleep(20)
        await_kind(fixture, session, kind, remaining - 20)

      nil ->
        flunk("no #{kind} event arrived")

      event ->
        event
    end
  end

  defp hold_first_worker(supervisor) do
    observer = self()

    hook = fn
      :armed, {:out, {:ok, worker}, _, _}, _ when is_pid(worker) ->
        true = :erlang.suspend_process(worker)
        send(observer, {:held_compact_preparation, worker})
        :held

      state, _, _ ->
        state
    end

    assert :ok = :sys.install(supervisor, {hook, :armed})

    on_exit(fn ->
      if Process.alive?(supervisor) do
        try do
          :sys.remove(supervisor, hook)
        catch
          :exit, _ -> :ok
        end
      end
    end)
  end
end
