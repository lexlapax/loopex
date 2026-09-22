Code.require_file("support/m1_runtime_helper.exs", __DIR__)

defmodule Loopex.RuntimeQuiesceTest do
  @moduledoc """
  ## Concept

  Orderly runtime shutdown begins with one terminal admission gate. The gate
  freezes the sessions that have ever owned a writer in this runtime and makes
  later session creation, activation, attachment and command routes refuse.

  ## Technical depth

  These foundation cases exercise the serialized Control transition directly.
  Later cases in this module drive the complete `Runtime.quiesce/1` phase owner,
  drain and fence path while retaining these cut-order witnesses.
  """

  use ExUnit.Case, async: true

  alias Loopex.M1RuntimeTestStore
  alias Loopex.Runtime
  alias Loopex.Runtime.Control
  alias Loopex.Runtime.Quiesce
  alias Loopex.Runtime.SessionCoordinator
  alias Loopex.Runtime.SessionState
  alias Loopex.Store

  test "the first gate freezes writer domains and later admission refuses before Store access" do
    fixture = fixture("quiesce-gate")
    session_id = create_session(fixture.runtime, "create")
    {:ok, attachment} = Loopex.attach(fixture.runtime, session_id)
    {:ok, %{control: control}} = Runtime.children(fixture.runtime)

    assert {:ok,
            [
              %{
                session_id: ^session_id,
                status: :active,
                coordinator: coordinator,
                owner: owner,
                writer_started?: true
              }
            ]} = Control.begin_quiesce(control, fixture.runtime.token, "drain-one", 5_000)

    assert is_pid(coordinator)
    assert is_map(owner)

    before = M1RuntimeTestStore.inspect_state(fixture.store_pid)

    assert {:error, :runtime_unavailable} =
             Runtime.create_session_detailed(fixture.runtime, "after-gate", %{})

    assert {:error, :runtime_unavailable} =
             Runtime.resume_session_detailed(fixture.runtime, session_id, "after-gate")

    assert {:error, :runtime_unavailable} = Loopex.attach(fixture.runtime, session_id)

    assert {:error, :runtime_unavailable} =
             Loopex.command(attachment, %{
               type: :prompt,
               command_id: "after-gate",
               content: "must not be admitted"
             })

    assert {:error, :runtime_unavailable} = Runtime.session_status(fixture.runtime, session_id)
    assert before == M1RuntimeTestStore.inspect_state(fixture.store_pid)

    assert {:ok, [%{session_id: ^session_id}]} =
             Control.quiesce_projection(control, fixture.runtime.token, "drain-one", 5_000)

    assert {:error, :runtime_unavailable} =
             Control.begin_quiesce(control, fixture.runtime.token, "drain-two", 5_000)

    assert :sys.get_state(control).quiescing == "drain-one"
  end

  test "the projection omits dormant no-writer rows and refuses an impossible 65-writer census" do
    dormant = fixture("quiesce-dormant")
    session_id = create_session(dormant.runtime, "create")
    {:ok, %{control: dormant_control}} = Runtime.children(dormant.runtime)

    dormant_rows =
      Map.new(1..70, fn index ->
        {"dormant-#{index}", %{status: :unavailable, durable: nil, generation: "none"}}
      end)

    :sys.replace_state(dormant_control, fn state ->
      %{state | sessions: Map.merge(state.sessions, dormant_rows)}
    end)

    assert {:ok, [%{session_id: ^session_id}]} =
             Control.begin_quiesce(
               dormant_control,
               dormant.runtime.token,
               "bounded-dormant",
               5_000
             )

    oversized = fixture("quiesce-oversized")
    {:ok, %{control: oversized_control}} = Runtime.children(oversized.runtime)
    writer_domains = MapSet.new(Enum.map(1..65, &"writer-#{&1}"))

    :sys.replace_state(oversized_control, fn state ->
      %{state | writer_domains: writer_domains}
    end)

    assert {:error, :runtime_unavailable} =
             Control.begin_quiesce(
               oversized_control,
               oversized.runtime.token,
               "bounded-refusal",
               5_000
             )

    state = :sys.get_state(oversized_control)
    assert state.quiescing == "bounded-refusal"
    assert state.sessions == %{}
  end

  test "an idle drain refusal closes ordinary coordinator admission" do
    fixture = fixture("quiesce-idle-admission")
    session_id = create_session(fixture.runtime, "create")
    {:ok, %{control: control}} = Runtime.children(fixture.runtime)

    assert {:ok, [%{coordinator: coordinator, owner: owner}]} =
             Control.begin_quiesce(control, fixture.runtime.token, "idle-drain", 5_000)

    assert :rejected_no_active_run =
             SessionCoordinator.admit_quiesce_abort(
               coordinator,
               owner,
               "idle-drain",
               self()
             )

    assert {:error, :runtime_unavailable} =
             SessionCoordinator.command(coordinator, owner, %{
               type: :prompt,
               command_id: "late-prompt",
               content: "must remain outside the journal"
             })

    command_id = SessionState.drain_abort_command_id(session_id, owner.owner_epoch)
    assert command_id == SessionState.drain_abort_command_id(session_id, owner.owner_epoch)
    refute command_id == SessionState.drain_abort_command_id(session_id, owner.owner_epoch + 1)

    {:ok, records} = M1RuntimeTestStore.load_records(fixture.store_pid, session_id, 0, 1_024)
    command_records = Enum.filter(records, &(&1.payload[:kind] == "command_admitted"))

    assert [%{payload: rejected}] = command_records
    assert rejected["command_id"] == command_id
    assert rejected["command_type"] == "abort"
    assert rejected["admission"] == "rejected_no_active_run"
  end

  test "an active drain abort pauses cleanup until the phase owner releases it" do
    fixture = fixture("quiesce-paused-cleanup")
    session_id = create_session(fixture.runtime, "create")
    {:ok, attachment} = Loopex.attach(fixture.runtime, session_id)

    assert {:accepted, "prompt"} =
             Loopex.command(attachment, %{
               type: :prompt,
               command_id: "prompt",
               content: "remain active until drain release"
             })

    {:ok, %{control: control}} = Runtime.children(fixture.runtime)

    assert {:ok, [%{coordinator: coordinator, owner: owner}]} =
             Control.begin_quiesce(control, fixture.runtime.token, "active-drain", 5_000)

    assert {:admitted,
            %{
              command_id: command_id,
              run_id: run_id,
              cleanup_grace_ms: cleanup_grace_ms,
              owner_epoch: owner_epoch
            }} =
             SessionCoordinator.admit_quiesce_abort(
               coordinator,
               owner,
               "active-drain",
               self()
             )

    assert command_id == SessionState.drain_abort_command_id(session_id, owner.owner_epoch)
    assert owner_epoch == owner.owner_epoch
    assert is_binary(run_id)
    assert is_integer(cleanup_grace_ms) and cleanup_grace_ms > 0

    paused = :sys.get_state(coordinator)
    assert paused.drain.status == :paused
    assert paused.drain.run_id == run_id
    assert paused.pending_cleanup == %{}
    assert paused.executor_reserves == %{}

    assert {:error, :runtime_unavailable} =
             SessionCoordinator.command(coordinator, owner, %{
               type: :prompt,
               command_id: "after-drain",
               content: "must not pass the coordinator cut"
             })

    phase_owner = self()

    release =
      Task.async(fn ->
        SessionCoordinator.release_quiesce_cleanup(
          coordinator,
          owner,
          "active-drain",
          phase_owner
        )
      end)

    assert :ok = Task.await(release)

    assert_eventually(fn ->
      case SessionCoordinator.session_status(coordinator, owner) do
        {:ok, %{active_run_id: nil, pending_work_ids: []}} -> true
        _other -> false
      end
    end)
  end

  test "an ambiguous drain abort is presented once and releases no cleanup" do
    fixture = fixture("quiesce-ambiguous-admission")
    session_id = create_session(fixture.runtime, "create")
    {:ok, attachment} = Loopex.attach(fixture.runtime, session_id)

    assert {:accepted, "prompt"} =
             Loopex.command(attachment, %{
               type: :prompt,
               command_id: "prompt",
               content: "hold for an ambiguous drain"
             })

    after_linearization = {:session_journal_commit, :after_linearization_before_result}
    recovery_representation = {:session_journal_commit, :recovery_representation}
    :ok = M1RuntimeTestStore.inject(fixture.store_pid, after_linearization)
    :ok = M1RuntimeTestStore.inject(fixture.store_pid, recovery_representation)

    {:ok, %{control: control}} = Runtime.children(fixture.runtime)

    assert {:ok, [%{coordinator: coordinator, owner: owner}]} =
             Control.begin_quiesce(control, fixture.runtime.token, "unknown-drain", 5_000)

    assert {:unknown, %{command_id: command_id, head: head}} =
             SessionCoordinator.admit_quiesce_abort(
               coordinator,
               owner,
               "unknown-drain",
               self()
             )

    assert command_id == SessionState.drain_abort_command_id(session_id, owner.owner_epoch)
    assert head.owner_epoch == owner.owner_epoch
    assert is_integer(head.journal_version)

    observed = M1RuntimeTestStore.observed(fixture.store_pid)
    assert MapSet.member?(observed, after_linearization)
    refute MapSet.member?(observed, recovery_representation)

    state = :sys.get_state(coordinator)
    assert state.drain.status == {:unknown, head}
    assert state.pending_cleanup == %{}

    assert {:error, :runtime_unavailable} =
             SessionCoordinator.release_quiesce_cleanup(
               coordinator,
               owner,
               "unknown-drain",
               self()
             )
  end

  test "the phase owner retains the exact abort candidate before Store linearization" do
    fixture = fixture("quiesce-retained-abort-candidate")
    session_id = create_session(fixture.runtime, "create")
    {:ok, attachment} = Loopex.attach(fixture.runtime, session_id)

    assert {:accepted, "prompt"} =
             Loopex.command(attachment, %{
               type: :prompt,
               command_id: "prompt",
               content: "leave an abort Store call in flight"
             })

    :ok =
      M1RuntimeTestStore.hold_next_record_before_linearization(
        fixture.store_pid,
        "command_admitted",
        self()
      )

    {:ok, %{control: control}} = Runtime.children(fixture.runtime)

    assert {:ok, [%{coordinator: coordinator, owner: owner}]} =
             Control.begin_quiesce(control, fixture.runtime.token, "retained-candidate", 5_000)

    phase_owner = self()

    {caller, caller_monitor} =
      spawn_monitor(fn ->
        SessionCoordinator.admit_quiesce_abort(
          coordinator,
          owner,
          "retained-candidate",
          phase_owner
        )
      end)

    assert_receive {:loopex_quiesce_candidate, "retained-candidate", ^session_id, ^coordinator,
                    %{command_id: command_id, head: head, run_id: run_id} = candidate},
                   5_000

    assert_receive {:record_held_before_linearization, waiter, store_pid, "command_admitted",
                    transaction},
                   5_000

    assert store_pid == fixture.store_pid
    assert command_id == SessionState.drain_abort_command_id(session_id, owner.owner_epoch)
    assert transaction.tx_id == command_id
    assert head.owner_epoch == owner.owner_epoch
    assert is_binary(run_id)

    Process.exit(coordinator, :kill)
    assert_receive {:DOWN, ^caller_monitor, :process, ^caller, _reason}, 5_000
    M1RuntimeTestStore.release(waiter)

    assert_eventually(fn ->
      Store.transaction_status(fixture.store, session_id, "session", command_id) ==
        {:terminal, :committed}
    end)

    assert {:ok, [record]} =
             Store.load_records(fixture.store, session_id, head.journal_version, 1)

    assert SessionState.drain_abort_record?(record, command_id, head, candidate.run_id)
  end

  test "the private phase owner drains an idle session without changing caller flags" do
    fixture = fixture("quiesce-private-owner-idle")
    session_id = create_session(fixture.runtime, "create")
    {:trap_exit, caller_flag} = Process.info(self(), :trap_exit)

    assert {:ok,
            %{
              settled: [^session_id],
              unsettled: [],
              absent: [],
              budget_ms: 0,
              drain_id: drain_id,
              termination_entries: [%{coordinator: coordinator}],
              fences: %{^session_id => :committed},
              control: control
            }} = Quiesce.run(fixture.runtime.supervisor, fixture.runtime.token)

    assert is_binary(drain_id) and byte_size(drain_id) == 32
    refute Process.alive?(coordinator)
    assert :sys.get_state(control).quiesce_fences == %{}
    assert {:trap_exit, ^caller_flag} = Process.info(self(), :trap_exit)
  end

  test "the private phase owner releases one active cleanup and reads its terminal cursor" do
    fixture = fixture("quiesce-private-owner-active")
    session_id = create_session(fixture.runtime, "create")
    {:ok, attachment} = Loopex.attach(fixture.runtime, session_id)

    assert {:accepted, "prompt"} =
             Loopex.command(attachment, %{
               type: :prompt,
               command_id: "prompt",
               content: "drain through the private owner"
             })

    assert {:ok,
            %{
              settled: [^session_id],
              unsettled: [],
              absent: [],
              budget_ms: budget_ms,
              release_results: %{^session_id => :ok},
              termination_entries: [%{coordinator: coordinator}],
              fences: %{^session_id => :committed}
            }} = Quiesce.run(fixture.runtime.supervisor, fixture.runtime.token)

    assert is_integer(budget_ms) and budget_ms >= 10_000
    refute Process.alive?(coordinator)
  end

  test "the one-shot fence advances the durable head under deterministic identities" do
    fixture = fixture("quiesce-fence-identity")
    session_id = create_session(fixture.runtime, "create")
    assert {:ok, before_head} = Store.ownership_head(fixture.store, session_id, "session")

    assert {:ok, %{fences: %{^session_id => :committed}}} =
             Quiesce.run(fixture.runtime.supervisor, fixture.runtime.token)

    assert {:ok, after_head} = Store.ownership_head(fixture.store, session_id, "session")
    assert after_head.owner_epoch == before_head.owner_epoch + 1
    assert after_head.journal_version == before_head.journal_version + 2

    {:ok, records} =
      M1RuntimeTestStore.load_records(
        fixture.store_pid,
        session_id,
        before_head.journal_version,
        10
      )

    assert [abort, fence] = records
    assert abort.payload["command_type"] == "abort"
    assert fence.payload[:kind] == "owner_advanced"

    assert fence.payload["owner_transaction_id"] ==
             SessionCoordinator.drain_fence_transaction_id(
               session_id,
               before_head.owner_epoch
             )

    assert fence.payload["owner_incarnation_id"] ==
             SessionCoordinator.drain_fence_incarnation_id(
               session_id,
               before_head.owner_epoch
             )

    refute SessionCoordinator.drain_fence_transaction_id(session_id, before_head.owner_epoch) ==
             SessionCoordinator.drain_fence_incarnation_id(session_id, before_head.owner_epoch)
  end

  test "an ambiguous committed abort is reloaded exactly and remains unsettled before fencing" do
    fixture = fixture("quiesce-fence-abort-unknown")
    session_id = create_session(fixture.runtime, "create")
    {:ok, attachment} = Loopex.attach(fixture.runtime, session_id)

    assert {:accepted, "prompt"} =
             Loopex.command(attachment, %{
               type: :prompt,
               command_id: "prompt",
               content: "hold cleanup behind ambiguous admission"
             })

    :ok =
      M1RuntimeTestStore.inject(
        fixture.store_pid,
        {:session_journal_commit, :after_linearization_before_result}
      )

    assert {:ok,
            %{
              settled: [],
              unsettled: [^session_id],
              absent: [],
              budget_ms: 0,
              fences: %{^session_id => :committed}
            }} = Quiesce.run(fixture.runtime.supervisor, fixture.runtime.token)

    {:ok, records} = M1RuntimeTestStore.load_records(fixture.store_pid, session_id, 0, 1_024)
    kinds = Enum.map(records, & &1.payload[:kind])

    assert 1 ==
             Enum.count(records, fn record ->
               record.payload[:kind] == "command_admitted" and
                 record.payload["command_type"] == "abort"
             end)

    refute "run_terminal_committed" in kinds
  end

  test "concurrent private owners produce one drain and one refusal" do
    fixture = fixture("quiesce-private-owner-race")
    session_id = create_session(fixture.runtime, "create")
    parent = self()
    release = make_ref()

    calls =
      for _index <- 1..2 do
        Task.async(fn ->
          send(parent, {:quiesce_ready, self()})

          receive do
            {:release_quiesce, ^release} -> :ok
          end

          Quiesce.run(fixture.runtime.supervisor, fixture.runtime.token)
        end)
      end

    assert_receive {:quiesce_ready, _first}
    assert_receive {:quiesce_ready, _second}
    Enum.each(calls, &send(&1.pid, {:release_quiesce, release}))

    results = calls |> Enum.map(&Task.await(&1, 5_000)) |> Enum.sort()

    assert [
             {:error, :runtime_unavailable},
             {:ok, %{settled: [^session_id], unsettled: [], absent: []}}
           ] = results

    {:ok, records} = M1RuntimeTestStore.load_records(fixture.store_pid, session_id, 0, 1_024)

    assert 1 ==
             Enum.count(records, fn record ->
               record.payload[:kind] == "command_admitted" and
                 record.payload["command_type"] == "abort"
             end)
  end

  test "the runtime facade returns only the seven-key plain-data contract" do
    fixture = fixture("quiesce-public-contract")
    session_id = create_session(fixture.runtime, "create")

    assert {:ok, result} = Runtime.quiesce(fixture.runtime)

    assert Map.keys(result) |> Enum.sort() ==
             Enum.sort([
               :settled,
               :unsettled,
               :absent,
               :budget_ms,
               :fence_budget_ms,
               :drain_id,
               :fences
             ])

    assert result.settled == [session_id]
    assert result.unsettled == []
    assert result.absent == []
    assert result.budget_ms == 0
    assert result.fence_budget_ms == 130_000
    assert result.fences == %{session_id => :committed}
    assert is_binary(result.drain_id) and byte_size(result.drain_id) == 32
    refute contains_process_term?(result)
  end

  test "a commit-unknown fence is re-presented once under its exact binding" do
    fixture = fixture("quiesce-fence-represent")
    session_id = create_session(fixture.runtime, "create")
    transition = :session_journal_advance_owner

    :ok =
      M1RuntimeTestStore.inject(
        fixture.store_pid,
        {transition, :after_linearization_before_result}
      )

    assert {:ok, %{settled: [^session_id], fences: %{^session_id => :committed}}} =
             Runtime.quiesce(fixture.runtime)

    observed = M1RuntimeTestStore.observed(fixture.store_pid)
    assert MapSet.member?(observed, {transition, :after_linearization_before_result})
    assert MapSet.member?(observed, {transition, :recovery_representation})
  end

  test "a second unknown fence answer stays explicit and demotes settlement" do
    fixture = fixture("quiesce-fence-double-unknown")
    session_id = create_session(fixture.runtime, "create")
    transition = :session_journal_advance_owner

    :ok =
      M1RuntimeTestStore.inject(
        fixture.store_pid,
        {transition, :after_linearization_before_result}
      )

    :ok = M1RuntimeTestStore.inject(fixture.store_pid, {transition, :recovery_representation})

    assert {:ok,
            %{
              settled: [],
              unsettled: [^session_id],
              fences: %{^session_id => {:unknown, :fence, head}}
            }} = Runtime.quiesce(fixture.runtime)

    assert is_integer(head.owner_epoch)
    assert is_integer(head.journal_version)
  end

  test "a pre-bound fence identity never causes an alternate fence attempt" do
    fixture = fixture("quiesce-fence-id-conflict")
    session_id = create_session(fixture.runtime, "create")
    assert {:ok, head} = Store.ownership_head(fixture.store, session_id, "session")
    tx_id = SessionCoordinator.drain_fence_transaction_id(session_id, head.owner_epoch)

    assert {:ok, conflicting} =
             Store.advance_owner(
               session_id,
               "session",
               tx_id,
               head.owner_epoch,
               head.journal_version + 10,
               "prebound_conflicting_incarnation"
             )

    assert {:not_committed, :stale_journal_version} = Store.transact(fixture.store, conflicting)

    assert {:ok,
            %{
              settled: [],
              unsettled: [^session_id],
              fences: %{^session_id => {:unknown, :fence, fence_head}}
            }} = Runtime.quiesce(fixture.runtime)

    assert fence_head.owner_epoch == head.owner_epoch

    {:ok, records} = M1RuntimeTestStore.load_records(fixture.store_pid, session_id, 0, 1_024)

    refute Enum.any?(records, fn record ->
             record.payload[:kind] == "owner_advanced" and
               record.payload["owner_transaction_id"] == tx_id
           end)
  end

  test "an unavailable fence head is explicit and starts no mutation" do
    fixture = fixture("quiesce-fence-no-head")
    session_id = create_session(fixture.runtime, "create")
    :ok = M1RuntimeTestStore.fail_reads(fixture.store_pid, true)

    assert {:ok,
            %{
              settled: [],
              unsettled: [^session_id],
              fences: %{^session_id => {:unknown, :no_head}}
            }} = Runtime.quiesce(fixture.runtime)

    :ok = M1RuntimeTestStore.fail_reads(fixture.store_pid, false)
    {:ok, records} = M1RuntimeTestStore.load_records(fixture.store_pid, session_id, 0, 1_024)
    assert Enum.count(records, &(&1.payload[:kind] == "owner_advanced")) == 1
  end

  test "a stale-owner fence is superseded without a second attempt" do
    fixture = fixture("quiesce-fence-stale-owner")
    session_id = create_session(fixture.runtime, "create")

    :ok =
      M1RuntimeTestStore.hold_next_transition_before_linearization(
        fixture.store_pid,
        :session_journal_advance_owner,
        self()
      )

    quiesce = Task.async(fn -> Runtime.quiesce(fixture.runtime) end)

    assert_receive {:record_held_before_linearization, waiter, store_pid,
                    :session_journal_advance_owner, fence_transaction},
                   5_000

    assert store_pid == fixture.store_pid
    assert {:ok, head} = Store.ownership_head(fixture.store, session_id, "session")

    assert {:ok, competing} =
             Store.advance_owner(
               session_id,
               "session",
               "competing_owner_advance",
               head.owner_epoch,
               head.journal_version,
               "competing_owner_incarnation"
             )

    assert {:committed, "competing_owner_advance", _receipt} =
             Store.transact(fixture.store, competing)

    M1RuntimeTestStore.release(waiter)

    assert {:ok,
            %{
              settled: [],
              unsettled: [^session_id],
              fences: %{^session_id => :superseded}
            }} = Task.await(quiesce, 5_000)

    assert fence_transaction.tx_id ==
             SessionCoordinator.drain_fence_transaction_id(session_id, head.owner_epoch)

    assert {:terminal, {:not_committed, :stale_owner_epoch}} =
             Store.transaction_status(
               fixture.store,
               session_id,
               "session",
               fence_transaction.tx_id
             )
  end

  test "a stale-journal fence is superseded without a second attempt" do
    fixture = fixture("quiesce-fence-stale-journal")
    session_id = create_session(fixture.runtime, "create")

    :ok =
      M1RuntimeTestStore.hold_next_transition_before_linearization(
        fixture.store_pid,
        :session_journal_advance_owner,
        self()
      )

    quiesce = Task.async(fn -> Runtime.quiesce(fixture.runtime) end)

    assert_receive {:record_held_before_linearization, waiter, _store_pid,
                    :session_journal_advance_owner, fence_transaction},
                   5_000

    {:ok, records} = M1RuntimeTestStore.load_records(fixture.store_pid, session_id, 0, 1_024)
    {:ok, events} = M1RuntimeTestStore.load_events(fixture.store_pid, session_id, 0, 1_024)
    assert {:ok, durable} = SessionState.recover(session_id, records, events)

    assert {:ok, proposal} =
             SessionState.propose(durable, %{
               type: :abort,
               command_id: "same-epoch-straggler"
             })

    assert {:ok, straggler} =
             Store.session_commit(
               session_id,
               "session",
               proposal.tx_id,
               durable.owner_epoch,
               durable.owner_incarnation_id,
               durable.journal_version,
               proposal.records,
               proposal.events
             )

    assert {:committed, "same-epoch-straggler", _receipt} =
             Store.transact(fixture.store, straggler)

    M1RuntimeTestStore.release(waiter)

    assert {:ok,
            %{
              settled: [],
              unsettled: [^session_id],
              fences: %{^session_id => :superseded}
            }} = Task.await(quiesce, 5_000)

    assert {:terminal, {:not_committed, :stale_journal_version}} =
             Store.transaction_status(
               fixture.store,
               session_id,
               "session",
               fence_transaction.tx_id
             )
  end

  defp fixture(runtime_id) do
    {store_pid, store} = M1RuntimeTestStore.start_store(label: runtime_id)

    {:ok, runtime} =
      Loopex.start_link(
        context_token_budget: 8_192,
        runtime_id: runtime_id,
        store: store
      )

    on_exit(fn ->
      if Runtime.alive?(runtime), do: Loopex.stop(runtime)
      if Process.alive?(store_pid), do: GenServer.stop(store_pid)
    end)

    %{runtime: runtime, store: store, store_pid: store_pid}
  end

  defp create_session(runtime, command_id) do
    assert {:ok, session_id} = Runtime.create_session(runtime, command_id, %{})
    session_id
  end

  defp assert_eventually(assertion, attempts \\ 200)
  defp assert_eventually(_assertion, 0), do: flunk("condition did not become true")

  defp assert_eventually(assertion, attempts) do
    if assertion.() do
      :ok
    else
      Process.sleep(5)
      assert_eventually(assertion, attempts - 1)
    end
  end

  defp contains_process_term?(term) when is_pid(term) or is_port(term) or is_reference(term),
    do: true

  defp contains_process_term?(term) when is_map(term),
    do:
      Enum.any?(term, fn {key, value} ->
        contains_process_term?(key) or contains_process_term?(value)
      end)

  defp contains_process_term?(term) when is_list(term),
    do: Enum.any?(term, &contains_process_term?/1)

  defp contains_process_term?(term) when is_tuple(term),
    do: term |> Tuple.to_list() |> Enum.any?(&contains_process_term?/1)

  defp contains_process_term?(_term), do: false
end
