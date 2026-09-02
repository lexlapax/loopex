Code.require_file("support/m1_runtime_helper.exs", __DIR__)

defmodule Loopex.SlowControl do
  @moduledoc false

  # Concept: a control process that is alive and correct but slow to answer.
  #
  # Technical depth: the real control cannot be made late on demand without a
  # hook that exists only for the test, so the boundary is exercised through a
  # stand-in that answers exactly what control answers, only later. A delay of
  # zero makes it an ordinary process this file can then stop, which is how the
  # absent case gets a pid that is genuinely gone rather than never started.

  use GenServer

  def start_link(delay_ms), do: GenServer.start_link(__MODULE__, delay_ms)

  @impl GenServer
  def init(delay_ms), do: {:ok, delay_ms}

  @impl GenServer
  def handle_call({:current_owner, _session_id, _owner}, _from, delay_ms) do
    Process.sleep(delay_ms)
    {:reply, :ok, delay_ms}
  end
end

defmodule Loopex.SessionLifecycleTest do
  use ExUnit.Case, async: false

  alias Loopex.SlowControl

  alias Loopex.M1RuntimeTestStore
  alias Loopex.Runtime
  alias Loopex.Runtime.Control
  alias Loopex.Runtime.SessionCoordinator
  alias Loopex.Store.Transitions

  setup do
    fixture = start_fixture("session-runtime")
    on_exit(fn -> stop_fixture(fixture) end)
    fixture
  end

  # Concept: the two ways an ownership question can fail to be a "yes" are not
  # the same answer, and neither of them is latency.
  #
  # Technical depth: this bound the control call at five seconds and read every
  # failure -- including its own timeout -- as "not the owner". A control that
  # was merely busy therefore fenced a live owner out of its own session, and
  # because the coordinator records that verdict as `superseded`, the session was
  # bricked for good by nothing but scheduling. Both halves are asserted here: a
  # control slower than the old bound still answers, and a control that is gone
  # reports unavailability rather than a supersession no one decided.
  test "a slow control still answers and an absent one reports unavailability rather than supersession",
       fixture do
    {:ok, session_id} =
      Loopex.create_session(fixture.runtime, %{"workspace" => "fence"},
        command_id: "create-fence"
      )

    entry = current_entry(fixture.runtime, session_id)

    # Alive, healthy, and slower to reply than the bound this call used to
    # impose on itself. The owner it is asked about is the current one, so the
    # only answer that is true is `:ok`.
    slow = start_supervised!({SlowControl, 6_000})

    assert Control.current_owner(slow, session_id, entry.owner) == :ok

    # A control that is genuinely gone is unavailable. Reporting supersession
    # here would claim a successor exists when none does.
    absent = start_supervised!({SlowControl, 0}, id: :absent_control)
    :ok = stop_supervised!(:absent_control)
    refute Process.alive?(absent)

    assert Control.current_owner(absent, session_id, entry.owner) ==
             {:error, :runtime_unavailable}

    # And unavailability leaves no mark: the live owner is still the owner.
    {:ok, %{control: control}} = Runtime.children(fixture.runtime)
    assert Control.current_owner(control, session_id, entry.owner) == :ok
  end

  test "progress reports runtime unavailability without inventing owner supersession",
       fixture do
    {:ok, session_id} =
      Loopex.create_session(fixture.runtime, %{"workspace" => "progress-fence"},
        command_id: "create-progress-fence"
      )

    entry = current_entry(fixture.runtime, session_id)
    absent = start_supervised!({SlowControl, 0}, id: :absent_progress_control)
    :ok = stop_supervised!(:absent_progress_control)
    refute Process.alive?(absent)

    assert Control.project_progress(
             absent,
             session_id,
             entry.owner,
             self(),
             %{kind: :test_progress}
           ) == {:error, :runtime_unavailable}

    # Unavailability made no ownership decision: the real owner is unchanged.
    {:ok, %{control: control}} = Runtime.children(fixture.runtime)
    assert Control.current_owner(control, session_id, entry.owner) == :ok
  end

  test "progress closure reports runtime unavailability without inventing owner supersession",
       fixture do
    {:ok, session_id} =
      Loopex.create_session(fixture.runtime, %{"workspace" => "closure-fence"},
        command_id: "create-closure-fence"
      )

    entry = current_entry(fixture.runtime, session_id)
    absent = start_supervised!({SlowControl, 0}, id: :absent_closure_control)
    :ok = stop_supervised!(:absent_closure_control)
    refute Process.alive?(absent)

    assert Control.close_progress(
             absent,
             session_id,
             entry.owner,
             self(),
             :abandoned
           ) == {:error, :runtime_unavailable}

    # Unavailability made no ownership decision: the real owner is unchanged.
    {:ok, %{control: control}} = Runtime.children(fixture.runtime)
    assert Control.current_owner(control, session_id, entry.owner) == :ok
  end

  test "post commit reports runtime unavailability without inventing owner supersession",
       fixture do
    # Concept: losing the runtime's Control process proves no successor exists.
    # The post-commit fence therefore reports an unavailable authority rather
    # than manufacturing a stale-owner verdict for a still-current owner.
    #
    # Technical depth: exercise the public Control boundary against a pid that
    # was real and is now gone, matching the current-owner and progress cases
    # above. The positions and receipt never reach a dead process; only the
    # catch normalization is under test. The unchanged real Control must still
    # recognize the session's owner afterwards.
    {:ok, session_id} =
      Loopex.create_session(fixture.runtime, %{"workspace" => "post-commit-fence"},
        command_id: "create-post-commit-fence"
      )

    entry = current_entry(fixture.runtime, session_id)
    absent = start_supervised!({SlowControl, 0}, id: :absent_post_commit_control)
    :ok = stop_supervised!(:absent_post_commit_control)
    refute Process.alive?(absent)

    assert Control.post_commit(absent, session_id, entry.owner, %{}, %{}) ==
             {:error, :runtime_unavailable}

    # Unavailability made no ownership decision: the live owner is unchanged.
    {:ok, %{control: control}} = Runtime.children(fixture.runtime)
    assert Control.current_owner(control, session_id, entry.owner) == :ok
  end

  test "session creation atomically records its runtime command mapping and genesis re-presents identical bytes idempotently and conflicts on changed bytes",
       fixture do
    assert {:ok, session_id} =
             Loopex.create_session(fixture.runtime, %{"workspace" => "one"},
               command_id: "create-session"
             )

    first = M1RuntimeTestStore.inspect_state(fixture.store_pid)
    mapping = Map.fetch!(first.runtime_commands, {fixture.runtime_id, "create-session"})
    session = Map.fetch!(first.sessions, session_id)

    assert mapping.session_id == session_id
    assert {:committed, "create-session", %{session_id: ^session_id}} = mapping.outcome

    assert [genesis, owner] = session.records
    assert genesis.journal_version == 1
    assert genesis.owner_epoch == 0
    assert genesis.owner_incarnation_id == nil
    assert genesis.payload.kind == "session_genesis_v2"
    assert genesis.payload["options"] == %{"workspace" => "one"}
    assert owner.journal_version == 2
    assert owner.payload.kind == "owner_advanced"

    assert {:ok, ^session_id} =
             Loopex.create_session(fixture.runtime, %{"workspace" => "one"},
               command_id: "create-session"
             )

    assert durable_store_projection(first) ==
             durable_store_projection(M1RuntimeTestStore.inspect_state(fixture.store_pid))

    assert {:error, :tx_id_conflict} =
             Loopex.create_session(fixture.runtime, %{"workspace" => "changed"},
               command_id: "create-session"
             )

    assert durable_store_projection(first) ==
             durable_store_projection(M1RuntimeTestStore.inspect_state(fixture.store_pid))
  end

  test "initial and resumed coordinators commit advance_owner before admitting commands",
       fixture do
    :ok =
      M1RuntimeTestStore.delay_after_commit(
        fixture.store_pid,
        :session_journal_advance_owner,
        self()
      )

    create =
      Task.async(fn ->
        Loopex.create_session(fixture.runtime, %{}, command_id: "create-delayed")
      end)

    assert_receive {:transaction_linearized, initial_waiter, _store,
                    :session_journal_advance_owner, {:committed, _tx, initial_receipt}}

    assert initial_receipt.owner_epoch == 1
    assert Task.yield(create, 0) == nil

    initial_session =
      fixture.store_pid
      |> M1RuntimeTestStore.inspect_state()
      |> Map.fetch!(:sessions)
      |> Map.fetch!("s_test_1")

    assert Enum.map(initial_session.records, & &1.payload.kind) == [
             "session_genesis_v2",
             "owner_advanced"
           ]

    M1RuntimeTestStore.release(initial_waiter)
    assert {:ok, session_id} = Task.await(create)
    {:ok, attachment} = Loopex.attach(fixture.runtime, session_id, after_event_sequence: 0)

    :ok =
      M1RuntimeTestStore.delay_after_commit(
        fixture.store_pid,
        :session_journal_advance_owner,
        self()
      )

    resume =
      Task.async(fn ->
        Loopex.resume_session(fixture.runtime, session_id, command_id: "resume-delayed")
      end)

    assert_receive {:transaction_linearized, resume_waiter, _store,
                    :session_journal_advance_owner, {:committed, _tx, resume_receipt}}

    assert resume_receipt.owner_epoch == 2

    command =
      Task.async(fn ->
        Loopex.command(attachment, %{
          type: :prompt,
          command_id: "queued-command",
          content: "must wait"
        })
      end)

    assert Task.yield(resume, 0) == nil
    assert Task.yield(command, 0) == nil

    before_release =
      fixture.store_pid
      |> M1RuntimeTestStore.inspect_state()
      |> Map.fetch!(:sessions)
      |> Map.fetch!(session_id)

    assert List.last(before_release.records).payload.kind == "owner_advanced"
    refute Enum.any?(before_release.records, &(&1.payload.kind == "command_admitted"))

    M1RuntimeTestStore.release(resume_waiter)
    assert {:ok, ^session_id} = Task.await(resume)
    assert {:error, :session_unavailable} = Task.await(command)

    {:ok, resumed_attachment} =
      Loopex.attach(fixture.runtime, session_id, after_event_sequence: 0)

    assert {:accepted, "after-resume"} =
             Loopex.command(resumed_attachment, %{
               type: :prompt,
               command_id: "after-resume",
               content: "now admitted"
             })

    records =
      fixture.store_pid
      |> M1RuntimeTestStore.inspect_state()
      |> Map.fetch!(:sessions)
      |> Map.fetch!(session_id)
      |> Map.fetch!(:records)

    assert Enum.map(records, & &1.payload.kind) == [
             "session_genesis_v2",
             "owner_advanced",
             "owner_advanced",
             "prompt_admitted_v2"
           ]
  end

  test "a superseded owner cannot newly commit or use a delayed result to update cache publish dispatch or authorize",
       fixture do
    session_id = create_session!(fixture, "create-supersession")
    {:ok, old_attachment} = Loopex.attach(fixture.runtime, session_id, after_event_sequence: 0)
    old = current_entry(fixture.runtime, session_id)

    :ok =
      M1RuntimeTestStore.delay_after_commit(
        fixture.store_pid,
        :session_journal_commit,
        self()
      )

    delayed =
      Task.async(fn ->
        Loopex.command(old_attachment, %{
          type: :prompt,
          command_id: "old-owner-command",
          content: "durable before reply"
        })
      end)

    assert_receive {:transaction_linearized, waiter, _store, :session_journal_commit,
                    {:committed, "old-owner-command", _receipt}}

    assert current_entry(fixture.runtime, session_id).event_sequence == 0

    assert {:ok, ^session_id} =
             Loopex.resume_session(fixture.runtime, session_id,
               command_id: "resume-after-old-commit"
             )

    current = current_entry(fixture.runtime, session_id)
    assert current.coordinator != old.coordinator
    assert current.owner.owner_epoch == old.owner.owner_epoch + 1
    assert current.event_sequence == 1

    eventually(fn -> Loopex.next_event(old_attachment) == {:error, :stale_attachment} end)

    {:ok, current_attachment} =
      Loopex.attach(fixture.runtime, session_id, after_event_sequence: 0)

    delivered = drain_events(current_attachment)
    assert Enum.map(delivered, & &1.event_sequence) == [1]
    assert Enum.map(delivered, & &1.kind) == ["user.message_appended", "run.started"]

    control_before_reply = control_projection(fixture.runtime, session_id)
    store_before_reply = M1RuntimeTestStore.inspect_state(fixture.store_pid)
    old_reference = Process.monitor(old.coordinator)

    M1RuntimeTestStore.release(waiter)

    assert {:error, {:superseded_after_commit, {:accepted, "old-owner-command"}}} =
             Task.await(delayed)

    assert control_before_reply == control_projection(fixture.runtime, session_id)
    assert store_before_reply == M1RuntimeTestStore.inspect_state(fixture.store_pid)
    assert {:error, :empty} = Loopex.next_event(current_attachment)

    assert_receive {:DOWN, ^old_reference, :process, old_coordinator, :normal}, 5_000
    assert old_coordinator == old.coordinator

    assert {:error, :session_unavailable} =
             SessionCoordinator.command(old.coordinator, old.owner, %{
               type: :abort,
               command_id: "old-owner-authority"
             })

    assert {:ok, %{pending_work_ids: [pending], active_run_id: pending}} =
             Loopex.session_status(fixture.runtime, session_id)
  end

  test "declared injected and observed transition and fault point pairs are equal", _fixture do
    {injected, observed} =
      Enum.reduce(Transitions.declared_pairs(), {MapSet.new(), MapSet.new()}, fn pair,
                                                                                 {all_injected,
                                                                                  all_observed} ->
        transition = elem(pair, 0)
        isolated = start_fixture("fault-#{transition}-#{elem(pair, 1)}")

        try do
          drive_fault_pair(isolated, pair)

          {
            MapSet.union(all_injected, M1RuntimeTestStore.injected(isolated.store_pid)),
            MapSet.union(all_observed, M1RuntimeTestStore.observed(isolated.store_pid))
          }
        after
          stop_fixture(isolated)
        end
      end)

    declared = MapSet.new(Transitions.declared_pairs())
    assert injected == declared
    assert observed == declared
  end

  test "a prompt cannot start a second active run", fixture do
    session_id = create_session!(fixture, "create-single-run")
    {:ok, attachment} = Loopex.attach(fixture.runtime, session_id, after_event_sequence: 0)

    first =
      Task.async(fn ->
        Loopex.command(attachment, %{
          type: :prompt,
          command_id: "prompt-1",
          content: "one"
        })
      end)

    second =
      Task.async(fn ->
        Loopex.command(attachment, %{
          type: :prompt,
          command_id: "prompt-2",
          content: "two"
        })
      end)

    replies = [Task.await(first), Task.await(second)]
    assert Enum.count(replies, &match?({:accepted, _command_id}, &1)) == 1
    assert Enum.count(replies, &(&1 == {:error, :run_active})) == 1

    accepted_id =
      Enum.find_value(replies, fn
        {:accepted, command_id} -> command_id
        _other -> nil
      end)

    rejected_id = if accepted_id == "prompt-1", do: "prompt-2", else: "prompt-1"
    rejected_content = if rejected_id == "prompt-1", do: "one", else: "two"
    before_retry = M1RuntimeTestStore.inspect_state(fixture.store_pid)

    assert {:error, :run_active} =
             Loopex.command(attachment, %{
               type: :prompt,
               command_id: rejected_id,
               content: rejected_content
             })

    assert before_retry == M1RuntimeTestStore.inspect_state(fixture.store_pid)

    assert {:accepted, "abort-run"} =
             Loopex.command(attachment, %{type: :abort, command_id: "abort-run"})

    assert {:error, :run_active} =
             Loopex.command(attachment, %{
               type: :prompt,
               command_id: rejected_id,
               content: rejected_content
             })

    session = M1RuntimeTestStore.inspect_state(fixture.store_pid).sessions[session_id]
    assert Enum.count(session.events, &(&1.kind == "run.started")) == 0
    assert Enum.count(session.events, &(&1.kind == "run.finished")) == 1
    assert Enum.count(session.records, &(&1.payload.kind == "command_admitted")) == 2
    assert Enum.count(session.records, &(&1.payload.kind == "prompt_admitted_v2")) == 1
  end

  test "only one coordinator owns a session at a time after durable succession", fixture do
    session_id = create_session!(fixture, "create-owner-series")
    first = current_entry(fixture.runtime, session_id)
    first_reference = Process.monitor(first.coordinator)

    assert {:ok, ^session_id} =
             Loopex.resume_session(fixture.runtime, session_id, command_id: "resume-owner-2")

    second = current_entry(fixture.runtime, session_id)
    second_reference = Process.monitor(second.coordinator)

    assert {session_id, "session", first.owner.transaction_id} in M1RuntimeTestStore.inspect_state(
             fixture.store_pid
           ).status_queries

    assert {:ok, ^session_id} =
             Loopex.resume_session(fixture.runtime, session_id, command_id: "resume-owner-3")

    third = current_entry(fixture.runtime, session_id)

    assert {session_id, "session", second.owner.transaction_id} in M1RuntimeTestStore.inspect_state(
             fixture.store_pid
           ).status_queries

    assert Enum.map([first, second, third], & &1.owner.owner_epoch) == [1, 2, 3]

    assert MapSet.size(
             MapSet.new(Enum.map([first, second, third], & &1.owner.owner_incarnation_id))
           ) == 3

    assert_receive {:DOWN, ^first_reference, :process, _coordinator, :normal},
                   5_000,
                   "the first superseded coordinator was not reaped"

    assert_receive {:DOWN, ^second_reference, :process, _coordinator, :normal},
                   5_000,
                   "the second superseded coordinator was not reaped"

    assert Process.alive?(third.coordinator)

    {:ok, %{control: control}} = Runtime.children(fixture.runtime)

    assert Control.current_owner(control, session_id, first.owner) ==
             {:error, :superseded_owner}

    assert Control.current_owner(control, session_id, second.owner) ==
             {:error, :superseded_owner}

    assert Control.current_owner(control, session_id, third.owner) == :ok

    # Control retains the authoritative ownership verdict independently of the
    # obsolete processes. Calling a reaped coordinator itself can only report
    # that the process is unavailable; neither answer can authorize work.
    assert {:error, :session_unavailable} =
             SessionCoordinator.command(first.coordinator, first.owner, %{
               type: :prompt,
               command_id: "stale-first",
               content: "refused"
             })

    assert {:error, :session_unavailable} =
             SessionCoordinator.command(second.coordinator, second.owner, %{
               type: :prompt,
               command_id: "stale-second",
               content: "refused"
             })

    {:ok, attachment} = Loopex.attach(fixture.runtime, session_id, after_event_sequence: 0)

    assert {:accepted, "current-command"} =
             Loopex.command(attachment, %{
               type: :prompt,
               command_id: "current-command",
               content: "accepted"
             })

    session = M1RuntimeTestStore.inspect_state(fixture.store_pid).sessions[session_id]
    owner_records = Enum.filter(session.records, &(&1.payload.kind == "owner_advanced"))
    assert Enum.map(owner_records, & &1.owner_epoch) == [1, 2, 3]
    assert session.owner_epoch == 3
    assert session.owner_incarnation_id == third.owner.owner_incarnation_id
  end

  # Concept: a Store that is down ends an acquisition with the truth, once,
  # rather than leaving the caller waiting for a recovery that will never happen.
  #
  # Technical depth: `create_session/3` and `resume_session/3` wait on control
  # with no bound, and the coordinator re-armed its Store reads on a flat timer
  # with nothing counting them, so a Store that stayed unavailable produced a live
  # coordinator, tens of reads a second, and a caller that was never answered at
  # all. The retry budget is what ends it. Two things are asserted about the
  # ending. The reason is the one that is true -- `:store_unavailable`, not the
  # `:owner_recovery_failed` the monitor reports for an owner that merely died --
  # and the caller's mailbox is empty afterwards, because control replying and the
  # `:DOWN` behind it replying again would both land there before the call
  # deactivates its alias, which is how a double reply becomes observable.
  test "a persistently unavailable Store ends owner acquisition with the truthful reason exactly once",
       fixture do
    session_id = create_session!(fixture, "unavailable-baseline")
    :ok = M1RuntimeTestStore.fail_reads(fixture.store_pid, true)
    started = System.monotonic_time(:millisecond)

    caller =
      Task.async(fn ->
        result =
          Loopex.resume_session(fixture.runtime, session_id, command_id: "unavailable-resume")

        Process.sleep(250)
        {result, Process.info(self(), :messages)}
      end)

    {:ok, %{control: control}} = Runtime.children(fixture.runtime)
    assert eventually(fn -> current_entry(fixture.runtime, session_id).status == :acquiring end)
    acquiring = current_entry(fixture.runtime, session_id)
    coordinator_reference = Process.monitor(acquiring.coordinator)

    # The cleanup-group DOWN and the coordinator's reason come from different
    # senders, so the group signal may be observed first even though the
    # coordinator sent its reason before it exited. Hold Control and queue that
    # legal ordering explicitly. Only the direct coordinator monitor may answer
    # acquisition failure; the group monitor is the cleanup barrier.
    :ok = :sys.suspend(control)

    on_exit(fn ->
      if Process.alive?(control) do
        try do
          :sys.resume(control)
        catch
          :exit, _reason -> :ok
        end
      end
    end)

    send(
      control,
      {:DOWN, acquiring.owner_group_monitor, :process, acquiring.owner_group, :normal}
    )

    assert_receive {:DOWN, ^coordinator_reference, :process, _coordinator, :normal}, 30_000
    :ok = :sys.resume(control)

    assert {{:error, :store_unavailable}, {:messages, []}} = Task.await(caller, 30_000)
    elapsed = System.monotonic_time(:millisecond) - started

    # It spent a retry budget rather than refusing the first unavailable read,
    # and it still ended well inside what a blocked caller can wait for.
    assert elapsed >= 1_000
    assert elapsed < 30_000

    # The session is left recoverable rather than bricked: control holds no
    # waiter, and a Store that comes back is enough to acquire an owner again.
    entry = current_entry(fixture.runtime, session_id)
    assert entry.status == :unavailable
    assert Map.get(entry, :waiting) == nil

    :ok = M1RuntimeTestStore.fail_reads(fixture.store_pid, false)

    assert {:ok, ^session_id} =
             Loopex.resume_session(fixture.runtime, session_id, command_id: "recovered-resume")
  end

  # Concept: a status query may give up on an owner that is not answering. The
  # calls that commit may not.
  #
  # Technical depth: `session_status/2` used `:infinity` like its neighbours, so
  # a wedged owner held a read-only question open with no way out of it. The bound
  # is safe for exactly one reason: this call proposes nothing, commits nothing,
  # and installs nothing, so its deadline cannot become a durable fact or an
  # ownership verdict. `command/3`, `reconciliation_query/2`, and `reconcile/3`
  # keep `:infinity` for that same reason read the other way. This case asserts
  # the split -- a bounded honest unavailability here, an owner that is still the
  # owner immediately afterwards -- so a later reader does not resolve the
  # difference by making them all match.
  test "a status query on a wedged owner is bounded and decides nothing about ownership",
       fixture do
    session_id = create_session!(fixture, "wedged-status")
    entry = current_entry(fixture.runtime, session_id)

    :sys.suspend(entry.coordinator)

    {result, elapsed} =
      try do
        started = System.monotonic_time(:millisecond)
        result = Loopex.session_status(fixture.runtime, session_id)
        {result, System.monotonic_time(:millisecond) - started}
      after
        :sys.resume(entry.coordinator)
      end

    assert result == {:error, :session_unavailable}

    # It waited its declared bound rather than calling a slow owner unavailable
    # at once, and it did give up rather than waiting forever.
    assert elapsed >= 1_000
    assert elapsed < 30_000

    # Nothing durable was decided: the same owner answers again as soon as it is
    # running, and control still routes to it.
    assert {:ok, %{status: :active, owner_epoch: epoch}} =
             Loopex.session_status(fixture.runtime, session_id)

    assert epoch == entry.owner.owner_epoch

    {:ok, %{control: control}} = Runtime.children(fixture.runtime)
    assert Control.current_owner(control, session_id, entry.owner) == :ok
  end

  defp drive_fault_pair(fixture, {:runtime_control_create_session, _phase} = pair) do
    :ok = M1RuntimeTestStore.inject(fixture.store_pid, pair)

    eventually_match(
      fn ->
        Loopex.create_session(fixture.runtime, %{}, command_id: "faulted-create")
      end,
      &match?({:ok, _session_id}, &1)
    )
  end

  defp drive_fault_pair(fixture, {:runtime_control_stage_owner_attempt, _phase} = pair) do
    session_id = create_session!(fixture, "stage-baseline")
    prior_epoch = current_entry(fixture.runtime, session_id).owner.owner_epoch
    :ok = M1RuntimeTestStore.inject(fixture.store_pid, pair)

    assert Loopex.resume_session(fixture.runtime, session_id, command_id: "faulted-stage") in [
             {:ok, session_id},
             {:error, :owner_acquiring}
           ]

    eventually(fn ->
      case Loopex.session_status(fixture.runtime, session_id) do
        {:ok, %{owner_epoch: epoch}} -> epoch == prior_epoch + 1
        _other -> false
      end
    end)
  end

  defp drive_fault_pair(fixture, {:session_journal_advance_owner, _phase} = pair) do
    session_id = create_session!(fixture, "advance-baseline")
    prior_epoch = current_entry(fixture.runtime, session_id).owner.owner_epoch
    :ok = M1RuntimeTestStore.inject(fixture.store_pid, pair)

    assert Loopex.resume_session(fixture.runtime, session_id, command_id: "faulted-advance") in [
             {:ok, session_id},
             {:error, :owner_acquiring}
           ]

    eventually(fn ->
      case Loopex.session_status(fixture.runtime, session_id) do
        {:ok, %{owner_epoch: epoch}} -> epoch == prior_epoch + 1
        _other -> false
      end
    end)
  end

  defp drive_fault_pair(fixture, {:session_journal_commit, _phase} = pair) do
    session_id = create_session!(fixture, "commit-baseline")
    {:ok, attachment} = Loopex.attach(fixture.runtime, session_id, after_event_sequence: 0)
    :ok = M1RuntimeTestStore.inject(fixture.store_pid, pair)

    eventually_match(
      fn ->
        Loopex.command(attachment, %{
          type: :prompt,
          command_id: "faulted-command",
          content: "commit"
        })
      end,
      &(&1 == {:accepted, "faulted-command"})
    )
  end

  defp start_fixture(runtime_id) do
    {store_pid, store} = M1RuntimeTestStore.start_store(label: runtime_id)

    {:ok, runtime} =
      Loopex.start_link(context_token_budget: 8_192, runtime_id: runtime_id, store: store)

    %{runtime: runtime, runtime_id: runtime_id, store: store, store_pid: store_pid}
  end

  defp stop_fixture(fixture) do
    if Runtime.alive?(fixture.runtime), do: Loopex.stop(fixture.runtime)
    if Process.alive?(fixture.store_pid), do: GenServer.stop(fixture.store_pid)
  end

  defp create_session!(fixture, command_id) do
    assert {:ok, session_id} = Loopex.create_session(fixture.runtime, %{}, command_id: command_id)
    session_id
  end

  defp current_entry(runtime, session_id) do
    {:ok, %{control: control}} = Runtime.children(runtime)
    :sys.get_state(control).sessions |> Map.fetch!(session_id)
  end

  defp control_projection(runtime, session_id) do
    entry = current_entry(runtime, session_id)

    Map.take(entry, [
      :status,
      :coordinator,
      :owner,
      :journal_version,
      :event_sequence,
      :attachment
    ])
  end

  defp durable_store_projection(state) do
    Map.take(state, [:next_session, :runtime_commands, :sessions, :resolutions])
  end

  defp drain_events(attachment, accumulated \\ []) do
    case Loopex.next_event(attachment) do
      {:ok, event} -> drain_events(attachment, [event | accumulated])
      {:error, :empty} -> Enum.reverse(accumulated)
    end
  end

  defp eventually(assertion, attempts \\ 400)

  defp eventually(assertion, attempts) when attempts > 0 do
    if assertion.() do
      :ok
    else
      Process.sleep(5)
      eventually(assertion, attempts - 1)
    end
  end

  defp eventually(_assertion, 0), do: flunk("condition did not become true")

  defp eventually_match(operation, accepted, attempts \\ 400)

  defp eventually_match(operation, accepted, attempts) when attempts > 0 do
    result = operation.()

    if accepted.(result) do
      result
    else
      Process.sleep(5)
      eventually_match(operation, accepted, attempts - 1)
    end
  end

  defp eventually_match(_operation, _accepted, 0),
    do: flunk("operation did not reach its terminal result")
end
