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

  test "quiescing consumes an awaiting owner barrier without starting a successor" do
    fixture = fixture("quiesce-owner-barrier")
    session_id = create_session(fixture.runtime, "create")
    {:ok, %{control: control, sessions: session_supervisor}} = Runtime.children(fixture.runtime)
    entry = :sys.get_state(control).sessions[session_id]
    coordinator_monitor = Process.monitor(entry.coordinator)
    :ok = :sys.suspend(entry.owner_group)

    Process.exit(entry.coordinator, :kill)
    assert_receive {:DOWN, ^coordinator_monitor, :process, _coordinator, :killed}, 5_000
    assert Process.alive?(entry.owner_group)

    waiter_pid = self()
    waiter_tag = make_ref()

    :sys.replace_state(control, fn state ->
      current = state.sessions[session_id]

      awaiting =
        current
        |> Map.put(:status, :awaiting_owner_barrier)
        |> Map.put(:succession_id, "quiesce-owner-barrier-succession")
        |> Map.put(:owner_command, nil)
        |> Map.put(:prepared, nil)
        |> Map.put(:waiting, [
          %{
            from: {waiter_pid, waiter_tag},
            mode: :detailed,
            disposition: :activated
          }
        ])

      %{state | sessions: Map.put(state.sessions, session_id, awaiting)}
    end)

    assert {:ok, [%{session_id: ^session_id, status: :awaiting_owner_barrier}]} =
             Control.begin_quiesce(
               control,
               fixture.runtime.token,
               "owner-barrier-drain",
               5_000
             )

    owner_group_monitor = Process.monitor(entry.owner_group)
    Process.exit(entry.owner_group, :kill)
    assert_receive {:DOWN, ^owner_group_monitor, :process, _owner_group, :killed}, 5_000

    assert_receive {^waiter_tag,
                    {:error, :runtime_unavailable,
                     %{disposition: :activated, control_entry: :dormant}}},
                   5_000

    assert_eventually(fn ->
      :sys.get_state(control).sessions[session_id].status == :unavailable
    end)

    assert {:ok, [%{session_id: ^session_id, status: :unavailable}]} =
             Control.quiesce_projection(
               control,
               fixture.runtime.token,
               "owner-barrier-drain",
               5_000
             )

    refute Enum.any?(DynamicSupervisor.which_children(session_supervisor), fn
             {_id, pid, _type, modules} ->
               is_pid(pid) and Loopex.Runtime.SessionCoordinator in modules

             _other ->
               false
           end)
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

  test "replacement activation resolves bounded drain identities before ordinary succession" do
    fixture = fixture("quiesce-restart-recovery")
    session_id = create_session(fixture.runtime, "create")

    refute Enum.any?(
             M1RuntimeTestStore.inspect_state(fixture.store_pid).status_queries,
             fn {_session_id, _domain, tx_id} ->
               String.starts_with?(tx_id, "drain_ab") or
                 String.starts_with?(tx_id, "drain_fence")
             end
           )

    assert {:ok, %{fences: %{^session_id => :committed}}} =
             Runtime.quiesce(fixture.runtime)

    assert {:ok, drained_head} = Store.ownership_head(fixture.store, session_id, "session")
    before_queries = M1RuntimeTestStore.inspect_state(fixture.store_pid).status_queries
    :ok = Loopex.stop(fixture.runtime)

    {:ok, restarted} =
      Loopex.start_link(
        context_token_budget: 8_192,
        runtime_id: fixture.runtime_id,
        store: fixture.store
      )

    on_exit(fn -> if Runtime.alive?(restarted), do: Loopex.stop(restarted) end)

    assert {:ok, ^session_id} =
             Runtime.resume_session(restarted, session_id, "resume-after-drain")

    recovery_queries =
      M1RuntimeTestStore.inspect_state(fixture.store_pid).status_queries
      |> Enum.drop(length(before_queries))

    current_epoch = drained_head.owner_epoch
    predecessor_epoch = current_epoch - 1

    assert [
             {^session_id, "session", prior_owner_tx},
             {^session_id, "session", current_abort},
             {^session_id, "session", predecessor_abort},
             {^session_id, "session", current_fence},
             {^session_id, "session", predecessor_fence}
           ] = recovery_queries

    assert prior_owner_tx ==
             SessionCoordinator.drain_fence_transaction_id(session_id, predecessor_epoch)

    assert current_abort == SessionState.drain_abort_command_id(session_id, current_epoch)

    assert predecessor_abort ==
             SessionState.drain_abort_command_id(session_id, predecessor_epoch)

    assert current_fence ==
             SessionCoordinator.drain_fence_transaction_id(session_id, current_epoch)

    assert predecessor_fence ==
             SessionCoordinator.drain_fence_transaction_id(session_id, predecessor_epoch)

    assert {:ok, resumed_head} = Store.ownership_head(fixture.store, session_id, "session")
    assert resumed_head.owner_epoch == current_epoch + 1
  end

  test "replacement activation attributes a fence whose reply died with the runtime" do
    fixture = fixture("quiesce-lost-fence-reply")
    session_id = create_session(fixture.runtime, "create")

    :ok =
      M1RuntimeTestStore.delay_after_commit(
        fixture.store_pid,
        :session_journal_advance_owner,
        self()
      )

    quiesce = Task.async(fn -> Runtime.quiesce(fixture.runtime) end)

    assert_receive {:transaction_linearized, waiter, _store, :session_journal_advance_owner,
                    {:committed, fence_tx_id, fence_receipt}},
                   5_000

    assert fence_tx_id ==
             SessionCoordinator.drain_fence_transaction_id(
               session_id,
               fence_receipt.owner_epoch - 1
             )

    Process.unlink(fixture.runtime.supervisor)
    root_monitor = Process.monitor(fixture.runtime.supervisor)
    Process.exit(fixture.runtime.supervisor, :kill)
    assert_receive {:DOWN, ^root_monitor, :process, _root, :killed}, 5_000
    M1RuntimeTestStore.release(waiter)
    assert {:error, :runtime_unavailable} = Task.await(quiesce, 5_000)

    {:ok, restarted} =
      Loopex.start_link(
        context_token_budget: 8_192,
        runtime_id: fixture.runtime_id,
        store: fixture.store
      )

    on_exit(fn -> if Runtime.alive?(restarted), do: Loopex.stop(restarted) end)

    assert {:ok, ^session_id} =
             Runtime.resume_session(restarted, session_id, "resume-lost-fence")

    assert {:ok, resumed_head} = Store.ownership_head(fixture.store, session_id, "session")
    assert resumed_head.owner_epoch == fence_receipt.owner_epoch + 1
  end

  test "replacement activation attributes an abort whose reply died with the runtime" do
    fixture = fixture("quiesce-lost-abort-reply")
    session_id = create_session(fixture.runtime, "create")
    assert {:ok, before_head} = Store.ownership_head(fixture.store, session_id, "session")

    :ok =
      M1RuntimeTestStore.delay_after_commit(
        fixture.store_pid,
        :session_journal_commit,
        self()
      )

    quiesce = Task.async(fn -> Runtime.quiesce(fixture.runtime) end)

    assert_receive {:transaction_linearized, waiter, _store, :session_journal_commit,
                    {:committed, abort_tx_id, _abort_receipt}},
                   5_000

    assert abort_tx_id ==
             SessionState.drain_abort_command_id(session_id, before_head.owner_epoch)

    Process.unlink(fixture.runtime.supervisor)
    root_monitor = Process.monitor(fixture.runtime.supervisor)
    Process.exit(fixture.runtime.supervisor, :kill)
    assert_receive {:DOWN, ^root_monitor, :process, _root, :killed}, 5_000
    M1RuntimeTestStore.release(waiter)
    assert {:error, :runtime_unavailable} = Task.await(quiesce, 5_000)

    {:ok, restarted} =
      Loopex.start_link(
        context_token_budget: 8_192,
        runtime_id: fixture.runtime_id,
        store: fixture.store
      )

    on_exit(fn -> if Runtime.alive?(restarted), do: Loopex.stop(restarted) end)

    assert {:ok, ^session_id} =
             Runtime.resume_session(restarted, session_id, "resume-lost-abort")

    {:ok, records} = M1RuntimeTestStore.load_records(fixture.store_pid, session_id, 0, 1_024)

    assert 1 ==
             Enum.count(records, fn record ->
               record.payload[:kind] == "command_admitted" and
                 record.payload["command_id"] == abort_tx_id
             end)

    assert {:ok, resumed_head} = Store.ownership_head(fixture.store, session_id, "session")
    assert resumed_head.owner_epoch == before_head.owner_epoch + 1
  end

  test "replacement activation distinguishes command collisions under both drain identities" do
    fixture = fixture("quiesce-drain-identity-collisions")
    abort_session = create_session(fixture.runtime, "create-abort-collision")
    fence_session = create_session(fixture.runtime, "create-fence-collision")

    assert {:ok, abort_head} = Store.ownership_head(fixture.store, abort_session, "session")
    assert {:ok, fence_head} = Store.ownership_head(fixture.store, fence_session, "session")
    {:ok, abort_attachment} = Loopex.attach(fixture.runtime, abort_session)
    {:ok, fence_attachment} = Loopex.attach(fixture.runtime, fence_session)

    abort_collision =
      SessionState.drain_abort_command_id(abort_session, abort_head.owner_epoch)

    fence_collision =
      SessionCoordinator.drain_fence_transaction_id(fence_session, fence_head.owner_epoch)

    assert {:accepted, ^abort_collision} =
             Loopex.command(abort_attachment, %{
               type: :prompt,
               command_id: abort_collision,
               content: "bind the drain-abort identity to a different command"
             })

    assert {:error, :no_active_run} =
             Loopex.command(fence_attachment, %{
               type: :abort,
               command_id: fence_collision
             })

    :ok = Loopex.stop(fixture.runtime)

    {:ok, restarted} =
      Loopex.start_link(
        context_token_budget: 8_192,
        runtime_id: fixture.runtime_id,
        store: fixture.store
      )

    on_exit(fn -> if Runtime.alive?(restarted), do: Loopex.stop(restarted) end)

    assert {:ok, ^abort_session} =
             Runtime.resume_session(restarted, abort_session, "resume-abort-collision")

    assert {:ok, ^fence_session} =
             Runtime.resume_session(restarted, fence_session, "resume-fence-collision")
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

  test "the production phase bounds are fixed and invalid injected sets refuse" do
    assert Quiesce.bounds() == %{
             admission_ms: 70_000,
             initial_gate_ms: 5_000,
             worker_reap_ms: 5_000,
             status_census_ms: 10_000,
             status_work_ms: 5_000,
             coordinator_termination_ms: 330_000,
             termination_projection_ms: 5_000,
             fence_budget_ms: 130_000,
             fence_reap_ms: 5_000
           }

    fixture = fixture("quiesce-invalid-bounds")

    assert {:error, :runtime_unavailable} =
             Quiesce.run(
               fixture.runtime.supervisor,
               fixture.runtime.token,
               Map.delete(Quiesce.bounds(), :fence_reap_ms)
             )

    assert {:error, :runtime_unavailable} =
             Quiesce.run(
               fixture.runtime.supervisor,
               fixture.runtime.token,
               %{Quiesce.bounds() | admission_ms: 5_000, worker_reap_ms: 5_000}
             )

    assert {:error, :runtime_unavailable} =
             Quiesce.run(
               fixture.runtime.supervisor,
               fixture.runtime.token,
               %{Quiesce.bounds() | admission_ms: 70_001}
             )
  end

  test "sixty-four blocked admissions share one injected work cutoff" do
    fixture = fixture("quiesce-admission-population-bound")

    {_control, session_ids, coordinators} =
      install_probe_entries(fixture.runtime, 64, :block_admission)

    bounds = fast_bounds(%{admission_ms: 500, worker_reap_ms: 100})
    started_at = System.monotonic_time(:millisecond)

    assert {:ok, result} =
             Quiesce.run(fixture.runtime.supervisor, fixture.runtime.token, bounds)

    elapsed_ms = System.monotonic_time(:millisecond) - started_at
    calls = receive_probe_calls(:admit, session_ids)

    assert Map.keys(calls) |> Enum.sort() == session_ids
    assert result.unsettled == session_ids
    assert result.settled == []
    assert result.absent == []
    assert elapsed_ms >= bounds.admission_ms - bounds.worker_reap_ms
    assert elapsed_ms < 3_000
    assert Enum.all?(coordinators, &(not Process.alive?(&1)))
  end

  @tag :long_bound
  @tag timeout: 80_000
  test "production admission cuts sixty-four blocked calls at sixty-five seconds" do
    fixture = fixture("quiesce-admission-production-bound")

    {control, session_ids, _coordinators} =
      install_probe_entries(fixture.runtime, 64, :block_admission)

    started_at = System.monotonic_time(:millisecond)
    quiesce = Task.async(fn -> Quiesce.run(fixture.runtime.supervisor, fixture.runtime.token) end)
    calls = receive_probe_calls(:admit, session_ids)
    :ok = await_pids_down(Map.values(calls), 70_000)
    elapsed_ms = System.monotonic_time(:millisecond) - started_at

    assert elapsed_ms >= 65_000
    assert elapsed_ms <= 70_000

    Process.exit(control, :kill)
    assert {:error, :runtime_unavailable} = Task.await(quiesce, 10_000)
  end

  test "sixty-four status reads share one injected census cutoff" do
    fixture = fixture("quiesce-status-population-bound")

    {_control, session_ids, coordinators} =
      install_probe_entries(fixture.runtime, 64, :block_status)

    bounds =
      fast_bounds(%{
        status_census_ms: 400,
        status_work_ms: 300
      })

    started_at = System.monotonic_time(:millisecond)

    assert {:ok, result} =
             Quiesce.run(fixture.runtime.supervisor, fixture.runtime.token, bounds)

    elapsed_ms = System.monotonic_time(:millisecond) - started_at
    assert Map.keys(receive_probe_calls(:admit, session_ids)) |> Enum.sort() == session_ids
    assert Map.keys(receive_probe_calls(:release, session_ids)) |> Enum.sort() == session_ids
    assert Map.keys(receive_probe_calls(:status, session_ids)) |> Enum.sort() == session_ids
    assert result.unsettled == session_ids
    assert result.settled == []
    assert result.absent == []
    assert elapsed_ms >= bounds.status_work_ms
    assert elapsed_ms < 3_000
    assert Enum.all?(coordinators, &(not Process.alive?(&1)))
  end

  @tag :long_bound
  @tag timeout: 20_000
  test "production status census gives sixty-four unanswered reads one five-second cutoff" do
    fixture = fixture("quiesce-status-production-bound")

    {control, session_ids, _coordinators} =
      install_probe_entries(fixture.runtime, 64, :block_status)

    started_at = System.monotonic_time(:millisecond)
    quiesce = Task.async(fn -> Quiesce.run(fixture.runtime.supervisor, fixture.runtime.token) end)
    _admissions = receive_probe_calls(:admit, session_ids)
    _releases = receive_probe_calls(:release, session_ids)
    calls = receive_probe_calls(:status, session_ids)
    :ok = await_pids_down(Map.values(calls), 10_000)
    elapsed_ms = System.monotonic_time(:millisecond) - started_at

    assert elapsed_ms >= 5_000
    assert elapsed_ms <= 10_000

    Process.exit(control, :kill)
    assert {:error, :runtime_unavailable} = Task.await(quiesce, 10_000)
  end

  test "sixty-four coordinators share one injected termination cutoff" do
    fixture = fixture("quiesce-termination-population-bound")

    {_control, session_ids, coordinators} =
      install_probe_entries(fixture.runtime, 64, :settled_status)

    bounds =
      fast_bounds(%{
        coordinator_termination_ms: 500,
        termination_projection_ms: 50,
        worker_reap_ms: 100
      })

    started_at = System.monotonic_time(:millisecond)

    assert {:ok, result} =
             Quiesce.run(fixture.runtime.supervisor, fixture.runtime.token, bounds)

    elapsed_ms = System.monotonic_time(:millisecond) - started_at
    assert Map.keys(receive_probe_calls(:admit, session_ids)) |> Enum.sort() == session_ids
    assert Map.keys(receive_probe_calls(:release, session_ids)) |> Enum.sort() == session_ids
    assert Map.keys(receive_probe_calls(:status, session_ids)) |> Enum.sort() == session_ids
    assert result.unsettled == session_ids
    assert elapsed_ms >= bounds.coordinator_termination_ms - bounds.worker_reap_ms
    assert elapsed_ms < 3_000
    assert Enum.all?(coordinators, &(not Process.alive?(&1)))
  end

  @tag :long_bound
  @tag timeout: 345_000
  test "production termination kills sixty-four surviving coordinators at its work cutoff" do
    fixture = fixture("quiesce-termination-production-bound")

    {_control, session_ids, coordinators} =
      install_probe_entries(fixture.runtime, 64, :settled_status)

    started_at = System.monotonic_time(:millisecond)
    quiesce = Task.async(fn -> Quiesce.run(fixture.runtime.supervisor, fixture.runtime.token) end)
    _admissions = receive_probe_calls(:admit, session_ids)
    _releases = receive_probe_calls(:release, session_ids)
    _statuses = receive_probe_calls(:status, session_ids)
    :ok = await_pids_down(coordinators, 330_000)
    elapsed_ms = System.monotonic_time(:millisecond) - started_at

    assert elapsed_ms >= 325_000
    assert elapsed_ms <= 330_000
    assert {:ok, %{unsettled: ^session_ids}} = Task.await(quiesce, 10_000)
  end

  test "sixty-three blocked fences share one cutoff while one sibling completes" do
    fixture = fixture("quiesce-fence-population-bound")

    session_ids =
      Enum.map(1..64, fn index ->
        create_session(fixture.runtime, "create-fence-bound-#{index}")
      end)
      |> Enum.sort()

    {blocked_ids, [sibling_id]} = Enum.split(session_ids, 63)

    :ok =
      M1RuntimeTestStore.delay_ownership_heads(
        fixture.store_pid,
        blocked_ids,
        self()
      )

    # Only the fence budget and reap are under test; every other phase gets a
    # bound of seconds, within the relations `Quiesce` validates, so a loaded
    # machine cannot end the drain on a bound this case does not examine.
    bounds =
      fast_bounds(%{
        admission_ms: 4_000,
        initial_gate_ms: 2_000,
        worker_reap_ms: 500,
        status_census_ms: 2_000,
        status_work_ms: 1_000,
        coordinator_termination_ms: 4_000,
        termination_projection_ms: 2_000,
        fence_budget_ms: 500,
        fence_reap_ms: 100
      })

    started_at = System.monotonic_time(:millisecond)

    assert {:ok, result} =
             Quiesce.run(fixture.runtime.supervisor, fixture.runtime.token, bounds)

    elapsed_ms = System.monotonic_time(:millisecond) - started_at
    delayed = receive_ownership_head_delays(blocked_ids)
    Enum.each(delayed, fn {_session_id, %{waiter: waiter}} -> Process.exit(waiter, :kill) end)

    assert result.settled == [sibling_id]
    assert result.unsettled == blocked_ids
    assert result.absent == []
    assert result.fences[sibling_id] == :committed

    assert Enum.all?(blocked_ids, fn session_id ->
             result.fences[session_id] == {:unknown, :no_head}
           end)

    # One shared cutoff: at least the budget, and far below the 31.5 s that
    # sixty-three sequential cutoffs of 500 ms would take.
    assert elapsed_ms >= bounds.fence_budget_ms - bounds.fence_reap_ms
    assert elapsed_ms < 10_000
    assert Enum.all?(delayed, fn {_id, %{caller: caller}} -> not Process.alive?(caller) end)

    {:ok, %{control: control}} = Runtime.children(fixture.runtime)
    assert :sys.get_state(control).quiesce_fences == %{}
  end

  @tag :long_bound
  @tag timeout: 145_000
  test "production fence cutoff reaps sixty-three blocked paths and permits one sibling" do
    fixture = fixture("quiesce-fence-production-bound")

    session_ids =
      Enum.map(1..64, fn index ->
        create_session(fixture.runtime, "create-production-fence-bound-#{index}")
      end)
      |> Enum.sort()

    {blocked_ids, [sibling_id]} = Enum.split(session_ids, 63)

    :ok =
      M1RuntimeTestStore.delay_ownership_heads(
        fixture.store_pid,
        blocked_ids,
        self()
      )

    started_at = System.monotonic_time(:millisecond)
    quiesce = Task.async(fn -> Quiesce.run(fixture.runtime.supervisor, fixture.runtime.token) end)
    delayed = receive_ownership_head_delays(blocked_ids)
    :ok = await_pids_down(Enum.map(delayed, fn {_id, row} -> row.caller end), 130_000)
    assert {:ok, result} = Task.await(quiesce, 10_000)
    elapsed_ms = System.monotonic_time(:millisecond) - started_at

    Enum.each(delayed, fn {_session_id, %{waiter: waiter}} -> Process.exit(waiter, :kill) end)

    assert elapsed_ms >= 125_000
    assert elapsed_ms <= 130_000
    assert result.settled == [sibling_id]
    assert result.unsettled == blocked_ids
    assert result.fences[sibling_id] == :committed
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

    %{runtime: runtime, runtime_id: runtime_id, store: store, store_pid: store_pid}
  end

  defp create_session(runtime, command_id) do
    assert {:ok, session_id} = Runtime.create_session(runtime, command_id, %{})
    session_id
  end

  defp fast_bounds(overrides) do
    Quiesce.bounds()
    |> Map.merge(%{
      admission_ms: 300,
      initial_gate_ms: 50,
      worker_reap_ms: 50,
      status_census_ms: 200,
      status_work_ms: 100,
      coordinator_termination_ms: 150,
      termination_projection_ms: 50,
      fence_budget_ms: 150,
      fence_reap_ms: 50
    })
    |> Map.merge(overrides)
  end

  defp install_probe_entries(runtime, count, mode) do
    {:ok, %{control: control}} = Runtime.children(runtime)
    observer = self()

    rows =
      Map.new(1..count, fn index ->
        suffix = index |> Integer.to_string() |> String.pad_leading(2, "0")
        session_id = "bound-#{mode}-#{suffix}"
        coordinator = spawn(fn -> quiesce_probe(observer, session_id, mode) end)
        on_exit(fn -> if Process.alive?(coordinator), do: Process.exit(coordinator, :kill) end)

        owner = %{
          owner_epoch: 1,
          owner_incarnation_id: "probe-owner-#{index}"
        }

        {session_id, %{status: :active, coordinator: coordinator, owner: owner}}
      end)

    :sys.replace_state(control, fn state ->
      %{
        state
        | sessions: Map.merge(state.sessions, rows),
          writer_domains: rows |> Map.keys() |> MapSet.new()
      }
    end)

    session_ids = rows |> Map.keys() |> Enum.sort()
    coordinators = Enum.map(session_ids, &rows[&1].coordinator)
    {control, session_ids, coordinators}
  end

  defp quiesce_probe(observer, session_id, mode) do
    receive do
      {:"$gen_call", from, {:admit_quiesce_abort, _owner, drain_id, phase_owner}} ->
        send(observer, {:quiesce_probe_call, :admit, session_id, elem(from, 0)})

        unless mode == :block_admission do
          GenServer.reply(
            from,
            {:admitted,
             %{
               command_id: "abort-#{session_id}",
               run_id: "run-#{session_id}",
               cleanup_grace_ms: 1,
               owner_epoch: 1
             }}
          )
        end

        quiesce_probe(observer, session_id, mode, drain_id, phase_owner)
    end
  end

  defp quiesce_probe(observer, session_id, mode, drain_id, phase_owner) do
    receive do
      {:"$gen_call", from, {:release_quiesce_cleanup, _owner, ^drain_id, ^phase_owner}} ->
        send(observer, {:quiesce_probe_call, :release, session_id, elem(from, 0)})
        GenServer.reply(from, :ok)

        send(
          phase_owner,
          {:loopex_quiesce_terminal, drain_id, session_id, "run-#{session_id}", self()}
        )

        quiesce_probe(observer, session_id, mode, drain_id, phase_owner)

      {:"$gen_call", from, {:session_status, _owner}} ->
        send(observer, {:quiesce_probe_call, :status, session_id, elem(from, 0)})

        unless mode == :block_status do
          GenServer.reply(from, {:ok, %{active_run_id: nil, pending_work_ids: []}})
        end

        quiesce_probe(observer, session_id, mode, drain_id, phase_owner)
    end
  end

  defp receive_probe_calls(phase, session_ids) do
    Map.new(session_ids, fn expected_id ->
      receive do
        {:quiesce_probe_call, ^phase, session_id, caller} ->
          {session_id, caller}
      after
        5_000 -> flunk("missing #{phase} call for #{expected_id}")
      end
    end)
  end

  defp receive_ownership_head_delays(session_ids) do
    Map.new(session_ids, fn expected_id ->
      receive do
        {:ownership_head_delayed, waiter, caller, _store, session_id} ->
          {session_id, %{waiter: waiter, caller: caller}}
      after
        5_000 -> flunk("missing delayed ownership-head read for #{expected_id}")
      end
    end)
  end

  defp await_pids_down(pids, timeout_ms) do
    monitors = Map.new(pids, &{Process.monitor(&1), &1})
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    await_monitors_down(monitors, deadline)
  end

  defp await_monitors_down(monitors, _deadline) when map_size(monitors) == 0, do: :ok

  defp await_monitors_down(monitors, deadline) do
    receive do
      {:DOWN, monitor, :process, pid, _reason} ->
        case Map.pop(monitors, monitor) do
          {^pid, remaining} -> await_monitors_down(remaining, deadline)
          {nil, _same} -> await_monitors_down(monitors, deadline)
        end
    after
      max(deadline - System.monotonic_time(:millisecond), 0) ->
        flunk("#{map_size(monitors)} processes survived the shared deadline")
    end
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
