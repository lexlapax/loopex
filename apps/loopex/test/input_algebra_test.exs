Code.require_file("support/m1_runtime_helper.exs", __DIR__)
Code.require_file("support/agent_loop_helper.exs", __DIR__)
Code.require_file("support/shutdown_witness.exs", __DIR__)

defmodule Loopex.InputAlgebraTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Loopex.AgentLoopFixture, as: Fixture
  alias Loopex.AgentLoopTestModel
  alias Loopex.M1RuntimeTestStore
  alias Loopex.Runtime.SessionState

  defp call(id), do: %{id: id, name: "write", arguments: %{"path" => id}}

  defp start(options) do
    fixture = Fixture.start(options)
    on_exit(fn -> Fixture.stop(fixture) end)
    fixture
  end

  # Concept: begin a run and stop inside its first turn.
  #
  # Technical depth: the adapter blocks in its supervised task, so every command
  # below is admitted against a session that is genuinely active rather than one
  # that merely has not been observed settling yet.
  defp start_held(script_tail \\ [%{text: "done", calls: []}]) do
    parent = self()
    script = [%{text: "working", calls: [call("c1")], hold: parent} | script_tail]
    fixture = start(script: script)

    {:ok, session_id} = Loopex.create_session(fixture.runtime, %{"t" => "x"}, command_id: "cs")
    {:ok, attachment} = Loopex.attach(fixture.runtime, session_id, after_event_sequence: 0)

    {:accepted, "p1"} =
      Loopex.command(attachment, %{type: :prompt, command_id: "p1", content: "the task"})

    assert_receive {:holding, model}, 5_000
    run_id = run_id_of(fixture, session_id)

    {fixture, attachment, session_id, run_id, model}
  end

  defp run_id_of(fixture, session_id) do
    {:ok, %{active_run_id: run_id}} = Loopex.session_status(fixture.runtime, session_id)
    run_id
  end

  defp settle(fixture, session_id, attempts \\ 300) do
    case Loopex.session_status(fixture.runtime, session_id) do
      {:ok, %{active_run_id: nil}} ->
        :settled

      _other when attempts > 0 ->
        Process.sleep(10)
        settle(fixture, session_id, attempts - 1)

      _other ->
        :never_settled
    end
  end

  defp await_dispatch_count(fixture, wanted, attempts \\ 300) do
    cond do
      length(AgentLoopTestModel.dispatched(fixture.model)) >= wanted ->
        true

      attempts > 0 ->
        Process.sleep(10)
        await_dispatch_count(fixture, wanted, attempts - 1)

      true ->
        false
    end
  end

  defp coordinator_of(runtime) do
    {:ok, children} = Loopex.Runtime.Supervisor.children(runtime.supervisor)

    [{_id, pid, _type, _modules} | _rest] = DynamicSupervisor.which_children(children.sessions)
    pid
  end

  test "a prompt starts a run only while the session is settled and is otherwise refused" do
    {fixture, attachment, session_id, _run_id, model} = start_held()

    # A second prompt while a run is active is durably refused, not queued.
    assert {:error, :run_active} =
             Loopex.command(attachment, %{type: :prompt, command_id: "p2", content: "another"})

    send(model, :release)
    assert :settled = settle(fixture, session_id)

    # Once settled, a prompt starts a run again.
    assert {:accepted, "p3"} =
             Loopex.command(attachment, %{type: :prompt, command_id: "p3", content: "next"})
  end

  test "the runtime never infers whether new input is steering or follow up and a steer must name its active run" do
    {_fixture, attachment, _session_id, run_id, _model} = start_held()

    # A steer naming no run is refused rather than resolved from session state.
    assert {:error, :invalid_command} =
             Loopex.command(attachment, %{type: :steer, command_id: "s0", content: "no run"})

    # A steer naming a different run is refused rather than retargeted onto the
    # one that happens to be active.
    assert {:error, :run_mismatch} =
             Loopex.command(attachment, %{
               type: :steer,
               command_id: "s1",
               run_id: "run_someone_else",
               content: "wrong run"
             })

    # Naming the active run is accepted.
    assert {:accepted, "s2"} =
             Loopex.command(attachment, %{
               type: :steer,
               command_id: "s2",
               run_id: run_id,
               content: "actually, do it differently"
             })

    # The queue is one deep, and a second steer is refused with its own reason
    # rather than replacing or coalescing with the first.
    assert {:error, :steer_pending} =
             Loopex.command(attachment, %{
               type: :steer,
               command_id: "s3",
               run_id: run_id,
               content: "and another thing"
             })
  end

  test "a steer joins the active run after the current tool batch and before the next model request" do
    {fixture, attachment, session_id, run_id, model} = start_held()

    {:accepted, "s1"} =
      Loopex.command(attachment, %{
        type: :steer,
        command_id: "s1",
        run_id: run_id,
        content: "STEERED"
      })

    # The turn in flight is untouched: its request was committed before the
    # steer was admitted and its bytes cannot change.
    [first] = AgentLoopTestModel.dispatched(fixture.model)
    refute Enum.any?(first.messages, &(&1["content"] == "STEERED"))

    send(model, :release)
    assert :settled = settle(fixture, session_id)

    # The next request carries it, after the turn's tool result and before the
    # model was asked anything else.
    [_first, second | _rest] = AgentLoopTestModel.dispatched(fixture.model)
    assert Enum.any?(second.messages, &(&1["content"] == "STEERED"))

    steer_index = Enum.find_index(second.messages, &(&1["content"] == "STEERED"))
    tool_index = Enum.find_index(second.messages, &(&1["role"] == "tool"))
    assert tool_index < steer_index
  end

  test "a steer is recorded applied only when a committed request carried it" do
    {fixture, attachment, session_id, run_id, model} = start_held()

    {:accepted, "s1"} =
      Loopex.command(attachment, %{
        type: :steer,
        command_id: "s1",
        run_id: run_id,
        content: "STEERED"
      })

    send(model, :release)
    assert :settled = settle(fixture, session_id)

    resolutions = steer_resolutions(fixture, attachment)
    assert [%{"command_id" => "s1", "disposition" => "applied"}] = resolutions

    # The request that carried it is the one that committed with it, so the
    # record of what was said and the record of what was sent agree.
    [_first, second | _rest] = AgentLoopTestModel.dispatched(fixture.model)
    assert Enum.any?(second.messages, &(&1["content"] == "STEERED"))
    assert :ok = Loopex.Model.validate_request(second)
  end

  test "a steer that arrives after its run is terminal commits unapplied with a reason and is never promoted" do
    # The run ends at its turn bound, so the steer never reaches a request.
    parent = self()

    fixture =
      start(script: [%{text: "one", calls: [call("c1")], hold: parent}], bounds_max_turns: 1)

    {:ok, session_id} = Loopex.create_session(fixture.runtime, %{"t" => "x"}, command_id: "cs")
    {:ok, attachment} = Loopex.attach(fixture.runtime, session_id, after_event_sequence: 0)

    {:accepted, "p1"} =
      Loopex.command(attachment, %{type: :prompt, command_id: "p1", content: "go"})

    assert_receive {:holding, model}, 5_000
    run_id = run_id_of(fixture, session_id)

    {:accepted, "s1"} =
      Loopex.command(attachment, %{
        type: :steer,
        command_id: "s1",
        run_id: run_id,
        content: "too late"
      })

    send(model, :release)
    assert :settled = settle(fixture, session_id)

    # It resolves unapplied, naming the bound that ended the run, and is never
    # auto-promoted into a follow-up.
    assert [%{"command_id" => "s1", "disposition" => "unapplied", "reason" => reason}] =
             steer_resolutions(fixture, attachment)

    assert reason == "max_turns"

    # Only one request was ever dispatched, so nothing carried the steer.
    assert length(AgentLoopTestModel.dispatched(fixture.model)) == 1

    # And a steer submitted once the session is settled is refused outright.
    assert {:error, :no_active_run} =
             Loopex.command(attachment, %{
               type: :steer,
               command_id: "s2",
               run_id: run_id,
               content: "later still"
             })
  end

  test "a follow up starts a new run only after the active run and its steering settle" do
    {fixture, attachment, session_id, _run_id, model} = start_held()

    assert {:accepted, "f1"} =
             Loopex.command(attachment, %{
               type: :follow_up,
               command_id: "f1",
               content: "then do this"
             })

    # One deep here too.
    assert {:error, :follow_up_pending} =
             Loopex.command(attachment, %{
               type: :follow_up,
               command_id: "f2",
               content: "and this"
             })

    # It has not started while the first run is still active.
    {:ok, %{active_run_id: active}} = Loopex.session_status(fixture.runtime, session_id)
    assert is_binary(active)

    send(model, :release)
    # Technical depth: settling is the successor's end, so every event of both
    # runs is already published; a fixed sleep raced them on a loaded host.
    assert :settled = settle(fixture, session_id)

    # Promotion happened in the same transaction that ended the first run, so
    # the session never looked settled while work was still owed.
    events = drain_events(attachment)
    prompts = Enum.filter(events, &(&1.kind == "user.message_appended"))
    assert Enum.map(prompts, & &1["command_id"]) == ["p1", "f1"]
  end

  test "a promoted follow up fixes its deadline when its first request stages" do
    # Concept: promotion inherits the duration chosen for the active run, not an
    # already-ticking instant. A follow-up that has become durable but has staged
    # no request receives the full duration once its first provider request is
    # committed.
    #
    # Technical depth: the first run's terminal transaction also performs the
    # deterministic promotion. Pausing that exact record after linearization,
    # killing the owner and waiting longer than the duration leaves the successor
    # run durable but unstaged. Recovery must dispatch it once with a deadline
    # derived at staging; carrying the predecessor's instant or inventing one at
    # promotion would instead end it before the provider call.
    # The duration must outlast a loaded machine's first model request; the
    # case then waits longer than it, so it proves the same thing at 5 s as
    # it did at 200 ms. At 2 s a floor-pair run with ten suites at once starved
    # the first run past its own deadline before its model was scheduled.
    parent = self()
    duration_ms = 5_000

    fixture =
      start(
        script: [
          %{text: "first done", calls: [], hold: parent},
          %{text: "follow up done", calls: []}
        ],
        bounds_deadline_ms: duration_ms
      )

    {:ok, session_id} = Loopex.create_session(fixture.runtime, %{"t" => "x"}, command_id: "cs")
    {:ok, attachment} = Loopex.attach(fixture.runtime, session_id, after_event_sequence: 0)

    {:accepted, "p1"} =
      Loopex.command(attachment, %{type: :prompt, command_id: "p1", content: "first"})

    assert_receive {:holding, model}, duration_ms + 5_000

    assert {:accepted, "f1"} =
             Loopex.command(attachment, %{
               type: :follow_up,
               command_id: "f1",
               content: "then this"
             })

    :ok =
      Loopex.M1RuntimeTestStore.delay_after_record(
        fixture.store,
        "run_terminal_committed",
        self()
      )

    send(model, :release)

    assert_receive {:record_linearized, waiter, _store, "run_terminal_committed",
                    :session_journal_commit, {:committed, _tx, _receipt}},
                   5_000

    # The terminal-and-promotion record has linearized but no request for the
    # promoted run has staged. Rebuilding those same durable bytes must preserve
    # that distinction: replay is a pure function of the record and cannot
    # sample a fresh absolute instant that merely looks correct after recovery.
    records = Fixture.records(fixture, session_id)
    public_events = Fixture.events(fixture, session_id)
    assert {:ok, rebuilt} = SessionState.recover(session_id, records, public_events)
    promoted_run_id = rebuilt.active_run_id
    admitted = Enum.find(records, &(&1.payload[:kind] == "command_admitted"))
    first_run_id = admitted.payload["run_id"]
    {first_bounds, _charged} = SessionState.accounting(rebuilt, first_run_id)
    {promoted_bounds, _charged} = SessionState.accounting(rebuilt, promoted_run_id)

    assert Map.take(promoted_bounds, [:max_turns, :token_budget, :deadline_ms]) ==
             Map.take(first_bounds, [:max_turns, :token_budget, :deadline_ms]),
           "promotion did not inherit all three declared bounds together"

    assert promoted_bounds.deadline_ms == duration_ms

    assert promoted_bounds.deadline == nil,
           "promotion replay installed an absolute deadline before first request staging"

    assert length(AgentLoopTestModel.dispatched(fixture.model)) == 1,
           "the promoted run dispatched before its terminal-and-promotion transaction returned"

    coordinator = coordinator_of(fixture.runtime)
    coordinator_reference = Process.monitor(coordinator)
    Process.exit(coordinator, :kill)
    assert_receive {:DOWN, ^coordinator_reference, :process, ^coordinator, _reason}, 5_000
    Loopex.M1RuntimeTestStore.release(waiter)

    Process.sleep(duration_ms + 100)
    staging_floor = System.system_time(:millisecond)

    assert {:ok, ^session_id} =
             Loopex.resume_session(fixture.runtime, session_id, command_id: "resume-1")

    assert await_dispatch_count(fixture, 2),
           "a promoted run with only pre-staging downtime was treated as expired"

    assert :settled = settle(fixture, session_id)

    assert [first, promoted] = AgentLoopTestModel.dispatched(fixture.model)

    staged_run_ids =
      fixture
      |> Fixture.records(session_id)
      |> Enum.filter(&(&1.payload[:kind] == "model_request_committed_v2"))
      |> Enum.map(& &1.payload["run_id"])

    assert length(Enum.uniq(staged_run_ids)) == 2,
           "the follow-up was not staged under a distinct promoted run"

    assert first.deadline < staging_floor
    assert promoted.deadline >= staging_floor + duration_ms
    assert promoted.deadline <= System.system_time(:millisecond) + duration_ms
  end

  test "a follow up submitted while the session is settled is refused" do
    fixture = start(script: [%{text: "done", calls: []}])
    {:ok, session_id} = Loopex.create_session(fixture.runtime, %{"t" => "x"}, command_id: "cs")
    {:ok, attachment} = Loopex.attach(fixture.runtime, session_id, after_event_sequence: 0)

    assert {:error, :no_active_run} =
             Loopex.command(attachment, %{
               type: :follow_up,
               command_id: "f1",
               content: "nothing to follow"
             })

    assert :settled = settle(fixture, session_id)
  end

  test "an abort resolves any unapplied steer and queued follow up as cancelled" do
    {fixture, attachment, session_id, run_id, model} = start_held()

    {:accepted, "s1"} =
      Loopex.command(attachment, %{
        type: :steer,
        command_id: "s1",
        run_id: run_id,
        content: "steer"
      })

    {:accepted, "f1"} =
      Loopex.command(attachment, %{type: :follow_up, command_id: "f1", content: "follow"})

    assert {:accepted, "a1"} =
             Loopex.command(attachment, %{type: :abort, command_id: "a1"})

    send(model, :release)
    # Technical depth: settling follows the abort's terminal transaction, which
    # resolves both queue entries; a fixed sleep raced it on a loaded host.
    assert :settled = settle(fixture, session_id)

    events = drain_events(attachment)

    # Each queue entry is resolved truthfully against its own command_id rather
    # than silently discarded with the run.
    assert Enum.any?(
             events,
             &(&1.kind == "steer.resolved" and &1["command_id"] == "s1" and
                 &1["disposition"] == "cancelled")
           )

    assert Enum.any?(
             events,
             &(&1.kind == "follow_up.resolved" and &1["command_id"] == "f1" and
                 &1["disposition"] == "cancelled")
           )

    # The cancelled follow-up never became a run.
    prompts = Enum.filter(events, &(&1.kind == "user.message_appended"))
    assert Enum.map(prompts, & &1["command_id"]) == ["p1"]
    assert :settled = settle(fixture, session_id)
  end

  test "a replayed abort answers from its record and touches neither the active run nor its queues" do
    # An abort id already bound to a record is a replay, whatever else has
    # happened since. Deciding that before acting is the whole point: the run the
    # id names is long gone, and everything live now belongs to a different run
    # that the operator never asked to stop.
    parent = self()

    fixture =
      start(
        script: [
          %{text: "first", calls: [call("c1")], hold: parent},
          %{text: "second", calls: [call("c2")], hold: parent},
          %{text: "done", calls: []}
        ]
      )

    {:ok, session_id} = Loopex.create_session(fixture.runtime, %{"t" => "x"}, command_id: "cs")
    {:ok, attachment} = Loopex.attach(fixture.runtime, session_id, after_event_sequence: 0)

    {:accepted, "p1"} =
      Loopex.command(attachment, %{type: :prompt, command_id: "p1", content: "first"})

    assert_receive {:holding, first_model}, 5_000
    {:accepted, "a1"} = Loopex.command(attachment, %{type: :abort, command_id: "a1"})
    send(first_model, :release)
    assert :settled = settle(fixture, session_id)

    {:accepted, "p2"} =
      Loopex.command(attachment, %{type: :prompt, command_id: "p2", content: "second"})

    assert_receive {:holding, second_model}, 5_000
    second_run = run_id_of(fixture, session_id)

    {:accepted, "s1"} =
      Loopex.command(attachment, %{
        type: :steer,
        command_id: "s1",
        run_id: second_run,
        content: "steer"
      })

    {:accepted, "f1"} =
      Loopex.command(attachment, %{type: :follow_up, command_id: "f1", content: "later"})

    # The replay is answered from the record the first run left behind.
    assert {:accepted, "a1"} = Loopex.command(attachment, %{type: :abort, command_id: "a1"})

    # And the second run's queues are untouched: both are still one deep, which
    # they would not be had the replay resolved them as an admitted abort does.
    assert {:error, :steer_pending} =
             Loopex.command(attachment, %{
               type: :steer,
               command_id: "s2",
               run_id: second_run,
               content: "another"
             })

    assert {:error, :follow_up_pending} =
             Loopex.command(attachment, %{type: :follow_up, command_id: "f2", content: "another"})

    # The second run is still the active one, still working.
    assert run_id_of(fixture, session_id) == second_run

    send(second_model, :release)
  end

  test "at most one unapplied steer and one queued follow up exist and both survive owner succession" do
    # ADR 0018 combination 4: an exact `not_dispatched` attempt one selects retry while no
    # termination has won, so the succession below lands on a retry-permitted run that
    # survives; combination 3 would settle an attempt still open at succession `owner_loss`
    # and terminal, ending the run before either queue could be observed again.
    fixture =
      start(
        script: [
          %{hold: self(), raw_result: {:error, {:not_dispatched, "model_call_failed"}}},
          %{text: "still working", calls: [call("c2")], hold: self()},
          %{text: "still working", calls: [call("c3")], hold: self()}
        ]
      )

    {:ok, session_id} = Loopex.create_session(fixture.runtime, %{"t" => "x"}, command_id: "cs")
    {:ok, attachment} = Loopex.attach(fixture.runtime, session_id, after_event_sequence: 0)

    {:accepted, "p1"} =
      Loopex.command(attachment, %{type: :prompt, command_id: "p1", content: "the task"})

    assert_receive {:holding, model}, 5_000
    run_id = run_id_of(fixture, session_id)

    {:accepted, "s1"} =
      Loopex.command(attachment, %{
        type: :steer,
        command_id: "s1",
        run_id: run_id,
        content: "steer"
      })

    {:accepted, "f1"} =
      Loopex.command(attachment, %{type: :follow_up, command_id: "f1", content: "follow"})

    # Both queues are one deep and refuse a second entry.
    assert {:error, :steer_pending} =
             Loopex.command(attachment, %{
               type: :steer,
               command_id: "s2",
               run_id: run_id,
               content: "second"
             })

    assert {:error, :follow_up_pending} =
             Loopex.command(attachment, %{type: :follow_up, command_id: "f2", content: "second"})

    # ADR 0018: the settlement is held after linearization, so the succession sees a
    # journal whose attempt one is settled `retry` and whose run is still active.
    :ok =
      M1RuntimeTestStore.delay_after_record(
        fixture.store,
        "model_attempt_settled_v3",
        self()
      )

    send(model, :release)

    assert_receive {:record_linearized, settlement_waiter, _store, "model_attempt_settled_v3",
                    _transition, {:committed, _tx_id, _receipt}},
                   5_000

    # A fresh owner rebuilds both from the journal, so the refusals still hold
    # after succession rather than the queues quietly emptying with the process.
    assert {:ok, ^session_id} =
             Loopex.resume_session(fixture.runtime, session_id, command_id: "resume-1")

    M1RuntimeTestStore.release(settlement_waiter)
    assert_receive {:holding, _successor_model}, 5_000

    {:ok, resumed} = Loopex.attach(fixture.runtime, session_id, after_event_sequence: 0)

    assert {:error, :steer_pending} =
             Loopex.command(resumed, %{
               type: :steer,
               command_id: "s3",
               run_id: run_id,
               content: "third"
             })

    assert {:error, :follow_up_pending} =
             Loopex.command(resumed, %{type: :follow_up, command_id: "f3", content: "third"})
  end

  defp drain_events(attachment, acc \\ []) do
    case Loopex.next_event(attachment) do
      {:ok, event} -> drain_events(attachment, [event | acc])
      _other -> Enum.reverse(acc)
    end
  end

  defp steer_resolutions(_fixture, attachment) do
    attachment
    |> drain_events()
    |> Enum.filter(&(&1.kind == "steer.resolved"))
  end
end

defmodule Loopex.InputSuccessorShutdownTest do
  @moduledoc false
  use ExUnit.Case, async: false

  alias Loopex.AgentLoopFixture, as: Fixture
  alias Loopex.AgentLoopTestModel
  alias Loopex.M1RuntimeTestStore
  alias Loopex.Runtime.{OwnerGroup, SessionState}
  alias Loopex.ShutdownWitness

  @filter :loopex_input_successor_shutdown_witness

  setup do
    saved = ShutdownWitness.install_logger(@filter, self())
    on_exit(fn -> ShutdownWitness.restore_logger(saved) end)
    :ok
  end

  test "public stop joins a held retry successor with its queued steer and follow up" do
    observer = self()
    fixture = Fixture.start(script: [
      %{hold: observer, raw_result: {:error, {:not_dispatched, "model_call_failed"}}},
      %{text: "still working", calls: [call("c2")], hold: observer},
      %{text: "still working", calls: [call("c3")], hold: observer}
    ])
    on_exit(fn -> cleanup_fixture(fixture) end)

    {:ok, session_id} = Loopex.create_session(fixture.runtime, %{"t" => "x"}, command_id: "cs")
    {:ok, attachment} = Loopex.attach(fixture.runtime, session_id, after_event_sequence: 0)
    assert {:accepted, "p1"} =
      Loopex.command(attachment, %{type: :prompt, command_id: "p1", content: "the task"})
    assert_receive {:holding, predecessor_callback}, 5_000
    {:ok, %{active_run_id: run_id}} = Loopex.session_status(fixture.runtime, session_id)
    assert {:ok, before_children} = Loopex.Runtime.children(fixture.runtime)
    [{_, predecessor, _, _}] = Supervisor.which_children(before_children.sessions)
    predecessor_monitor = Process.monitor(predecessor)

    assert {:accepted, "s1"} = Loopex.command(attachment, %{
      type: :steer, command_id: "s1", run_id: run_id, content: "steer"
    })
    assert {:accepted, "f1"} = Loopex.command(attachment, %{
      type: :follow_up, command_id: "f1", content: "follow"
    })
    assert {:error, :steer_pending} = Loopex.command(attachment, %{
      type: :steer, command_id: "s2", run_id: run_id, content: "second"
    })
    assert {:error, :follow_up_pending} = Loopex.command(attachment, %{
      type: :follow_up, command_id: "f2", content: "second"
    })
    assert :ok == M1RuntimeTestStore.delay_after_record(
      fixture.store, "model_attempt_settled_v3", observer)
    send(predecessor_callback, :release)
    assert_receive {:record_linearized, settlement_waiter, _store, "model_attempt_settled_v3",
                    _transition, {:committed, _tx_id, _receipt}}, 5_000
    settlement_monitor = Process.monitor(settlement_waiter)
    settlement_cutoff = System.monotonic_time(:millisecond) + 5_000

    {before_state, successor_hold_cutoff} =
      try do
        records = Fixture.records(fixture, session_id)
        settlement = Enum.find(Enum.reverse(records), &(&1.payload[:kind] == "model_attempt_settled_v3"))
        assert settlement.payload["next"] == "retry" and settlement.payload["run_id"] == run_id
        assert {:ok, before_state} = SessionState.recover(session_id, records, Fixture.events(fixture, session_id))
        assert before_state.active_run_id == run_id
        assert before_state.pending_work[run_id].stage == "model_retry_permitted"
        assert before_state.steer[run_id].command_id == "s1"
        assert before_state.follow_up.command_id == "f1"

        # Concept: the successor remains held through the complete stop observation.
        # Technical depth: its natural five-second timeout cannot begin before resume.
        successor_hold_cutoff = System.monotonic_time(:millisecond) + 5_000
        assert {:ok, ^session_id} =
          Loopex.resume_session(fixture.runtime, session_id, command_id: "resume-1")
        {before_state, successor_hold_cutoff}
      after
        # Concept: setup owns the actual unlinked settlement waiter even on failure.
        # Technical depth: release and join its original monitor in this test process;
        # an expired setup join kills that same helper, joins it and remains a failure.
        M1RuntimeTestStore.release(settlement_waiter)
        settlement_receive_started = System.monotonic_time(:millisecond)
        receive do
          {:DOWN, ^settlement_monitor, :process, ^settlement_waiter, reason} ->
            assert settlement_receive_started < settlement_cutoff
            assert System.monotonic_time(:millisecond) < settlement_cutoff
            assert reason == :normal
        after
          max(settlement_cutoff - System.monotonic_time(:millisecond), 0) ->
            if Process.alive?(settlement_waiter), do: Process.exit(settlement_waiter, :kill)
            assert_receive {:DOWN, ^settlement_monitor, :process, ^settlement_waiter, _}, 1_000
            flunk("the original settlement waiter exceeded its five-second setup cutoff")
        end
      end
    assert_receive {:DOWN, ^predecessor_monitor, :process, ^predecessor, _}, 5_000
    assert_receive {:holding, callback}, 5_000
    refute callback == predecessor_callback
    assert length(AgentLoopTestModel.dispatched(fixture.model)) == 2
    assert {:ok, resumed} = Loopex.attach(fixture.runtime, session_id, after_event_sequence: 0)
    assert {:error, :steer_pending} = Loopex.command(resumed, %{
      type: :steer, command_id: "s3", run_id: run_id, content: "third"
    })
    assert {:error, :follow_up_pending} = Loopex.command(resumed, %{
      type: :follow_up, command_id: "f3", content: "third"
    })
    assert {:ok, %{active_run_id: ^run_id}} = Loopex.session_status(fixture.runtime, session_id)
    assert {:ok, successor_state} = SessionState.recover(
      session_id, Fixture.records(fixture, session_id), Fixture.events(fixture, session_id))
    assert successor_state.owner_epoch > before_state.owner_epoch
    assert successor_state.steer[run_id].command_id == "s1"
    assert successor_state.follow_up.command_id == "f1"

    assert {:ok, children} = Loopex.Runtime.children(fixture.runtime)
    [{_, coordinator, _, _}] = Supervisor.which_children(children.sessions)
    refute coordinator == predecessor
    [{_, group, _, _}] = Supervisor.which_children(children.owner_groups)
    assert {:ok, workers} = OwnerGroup.workers(group)
    tasks = Task.Supervisor.children(workers)
    assert {:links, callback_links} = Process.info(callback, :links)
    [guard] = Enum.filter(tasks, &(&1 in callback_links))
    refute callback in tasks
    assert callback in elem(Process.info(guard, :links), 1)

    {stopper, stopper_monitor} = spawn_monitor(fn ->
      receive do
        :explicit_stop ->
          result = Loopex.stop(fixture.runtime)
          assert result == :ok
          send(observer, {:explicit_stop_returned, self()})
          receive do: (:stop -> :ok)
      end
    end)
    on_exit(fn -> cleanup_actor(stopper, stopper_monitor) end)

    roles = Map.new(children, fn {name, actor} -> {actor, "runtime_" <> Atom.to_string(name)} end)
      |> Map.merge(Map.new(tasks, &{&1, "task"}))
      |> Map.merge(%{callback => "callback", guard => "guard", workers => "private_supervisor",
        group => "owner_group", coordinator => "coordinator", children.sessions => "sessions",
        children.owner_groups => "owner_groups", fixture.runtime.supervisor => "runtime",
        stopper => "stop_caller"})
    monitors = Map.new(roles, fn {actor, role} ->
      monitor = if actor == stopper, do: stopper_monitor, else: Process.monitor(actor)
      assert Process.alive?(actor)
      assert observer in elem(Process.info(actor, :monitored_by), 1)
      {monitor, {actor, role}}
    end)
    assert Process.alive?(callback) and guard in elem(Process.info(callback, :links), 1)
    run = %{fixture: fixture, owner: stopper, owner_monitor: stopper_monitor,
      workers: workers, group: group, owner_groups: children.owner_groups,
      sessions: children.sessions, roles: roles, monitors: monitors}

    assert System.monotonic_time(:millisecond) + 1_000 < successor_hold_cutoff
    evidence = ShutdownWitness.observe([run], :explicit_stop, "input-held-successor", true, fn _ -> [] end)
    assert System.monotonic_time(:millisecond) < successor_hold_cutoff
    refute Enum.any?(evidence, &(&1["event"] == "supervisor_report"))
    downs = Enum.filter(evidence, &(&1["event"] == "original_down"))
    assert length(downs) == map_size(roles)
    assert length(Enum.uniq_by(downs, & &1["pid"])) == map_size(roles)
    assert length(Enum.uniq_by(downs, & &1["monitor"])) == map_size(roles)
    for down <- downs do
      assert down["reason"] in ["normal", "shutdown", "killed"]
      assert Enum.any?(evidence, &(&1["event"] == "actor_exit" and
        &1["pid"] == down["pid"] and &1["reason"] == down["reason"]))
    end
    assert Enum.any?(evidence, &(&1["event"] == "explicit_stop_returned" and
      &1["pid"] == ShutdownWitness.identity(stopper)))
  end

  defp call(id), do: %{id: id, name: "write", arguments: %{"path" => id}}

  # Concept: failed evidence still retires every fixture actor, without a second stop.
  # Technical depth: cleanup uses one separate fixed fixture cutoff for original
  # runtime/model/executor/Store actors. It never releases the held successor or
  # turns its joins into a successful 1,000-ms observation.
  defp cleanup_fixture(fixture) do
    cutoff = System.monotonic_time(:millisecond) + 1_000
    actors = [fixture.runtime.supervisor, fixture.model, fixture.executor, fixture.store]
    owned = for actor <- actors, do: {actor, Process.monitor(actor)}
    ShutdownWitness.cleanup(
      Enum.map(owned, fn {actor, _} ->
        fn -> if Process.alive?(actor), do: Process.exit(actor, :kill) end
      end) ++ Enum.map(owned, fn {actor, monitor} ->
        fn -> assert_receive {:DOWN, ^monitor, :process, ^actor, _},
          max(cutoff - System.monotonic_time(:millisecond), 0) end
      end)
    )
  end

  defp cleanup_actor(actor, original_monitor) do
    monitor = Process.monitor(actor)
    cutoff = System.monotonic_time(:millisecond) + 1_000
    ShutdownWitness.cleanup([
      fn -> if Process.alive?(actor), do: Process.exit(actor, :kill) end,
      fn -> assert_receive {:DOWN, ^monitor, :process, ^actor, _},
        max(cutoff - System.monotonic_time(:millisecond), 0) end,
      fn -> Process.demonitor(original_monitor, [:flush]) end
    ])
  end
end
