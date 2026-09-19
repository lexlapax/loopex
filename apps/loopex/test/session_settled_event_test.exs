Code.require_file("support/m1_runtime_helper.exs", __DIR__)
Code.require_file("support/agent_loop_helper.exs", __DIR__)

defmodule Loopex.SessionSettledEventTest do
  @moduledoc """
  ## Concept

  A session that ends a run with nothing queued behind it publishes one
  `session.settled` fact, distinct from the run's own ending. A session whose
  queued follow-up was promoted publishes none, because it still owes work.

  ## Technical depth

  Accepted ADR 0011 fixes both. The terminal transaction publishes
  `run.finished`, resolves the steer slot, and then either promotes the queued
  follow-up or publishes `session.settled`; the two facts stay distinct exactly
  as the vision requires. These cases read the durable event history the Store
  holds, so what they assert is what a later reader replays, and they reattach
  from the beginning to prove a replay produces the same two facts rather than
  a second copy of either.
  """

  use ExUnit.Case, async: true

  alias Loopex.AgentLoopFixture, as: Fixture
  alias Loopex.Runtime.SessionState

  test "a no follow up terminal atomically emits one run finished then one distinct session settled and replay or reattach never duplicates either" do
    fixture = start(script: [%{text: "done", calls: []}])
    {session_id, attachment} = session(fixture)

    assert {:accepted, "p1"} =
             Loopex.command(attachment, %{type: :prompt, command_id: "p1", content: "the task"})

    assert :settled = settle(fixture, session_id)

    events = Fixture.events(fixture, session_id)
    finished = Enum.filter(events, &(&1.kind == "run.finished"))
    settled = Enum.filter(events, &(&1.kind == "session.settled"))

    assert length(finished) == 1
    assert length(settled) == 1

    [finished] = finished
    [settled] = settled

    # The settled fact is its own event, about the run that ended, published in
    # the same transaction and therefore at the next sequence: nothing may be
    # interleaved between a run ending and the session settling.
    assert settled["run_id"] == finished["run_id"]
    assert settled.event_id != finished.event_id
    assert settled.event_sequence == finished.event_sequence + 1

    # A reader replaying from the beginning sees each fact once.
    {:ok, replay} = Loopex.attach(fixture.runtime, session_id, after_event_sequence: 0)
    replayed = drain(replay)

    assert Enum.count(replayed, &(&1.kind == "run.finished")) == 1
    assert Enum.count(replayed, &(&1.kind == "session.settled")) == 1
    assert Enum.map(replayed, & &1.event_id) == Enum.map(events, & &1.event_id)
  end

  test "a promoted follow up emits no session settled before its successor finishes" do
    parent = self()

    fixture =
      start(
        script: [
          %{text: "first", calls: [], hold: parent},
          %{text: "second", calls: []}
        ]
      )

    {session_id, attachment} = session(fixture)

    assert {:accepted, "p1"} =
             Loopex.command(attachment, %{type: :prompt, command_id: "p1", content: "the task"})

    # The follow-up is queued while the first run is genuinely active, so the
    # terminal transaction has something to promote.
    assert_receive {:holding, model}, 2_000

    assert {:accepted, "f1"} =
             Loopex.command(attachment, %{type: :follow_up, command_id: "f1", content: "next"})

    send(model, :release)
    assert :settled = settle(fixture, session_id)

    events = Fixture.events(fixture, session_id)
    finished = Enum.filter(events, &(&1.kind == "run.finished"))
    settled = Enum.filter(events, &(&1.kind == "session.settled"))

    # Two runs ended: the first promoted the follow-up and published no settled
    # fact, and only the successor's ending settled the session.
    assert length(finished) == 2
    assert length(settled) == 1

    [first_finished, second_finished] = finished
    [settled] = settled

    assert settled["run_id"] == second_finished["run_id"]
    assert settled["run_id"] != first_finished["run_id"]
    assert settled.event_sequence > first_finished.event_sequence

    # Nothing between the first ending and the successor's start claims the
    # session settled.
    between =
      Enum.filter(
        events,
        &(&1.event_sequence > first_finished.event_sequence and
            &1.event_sequence < second_finished.event_sequence)
      )

    assert Enum.all?(between, &(&1.kind != "session.settled"))
  end

  test "a session recorded before the settled fact existed still recovers" do
    fixture = start(script: [%{text: "done", calls: []}])
    {session_id, attachment} = session(fixture)

    assert {:accepted, "p1"} =
             Loopex.command(attachment, %{type: :prompt, command_id: "p1", content: "the task"})

    assert :settled = settle(fixture, session_id)

    records = Fixture.records(fixture, session_id)
    events = Fixture.events(fixture, session_id)
    assert Enum.any?(events, &(&1.kind == "session.settled"))

    # An older history is exactly this one without the fact core never used to
    # publish. Recovery must read it, because those rows are immutable and no
    # migration can add a fact that was never written.
    older = Enum.reject(events, &(&1.kind == "session.settled"))
    assert {:ok, recovered} = SessionState.recover(session_id, records, older)
    assert recovered.event_sequence == List.last(older).event_sequence

    # What a reader may not do is invent history: an event replay does not
    # expect is still refused.
    last = List.last(older)

    invented =
      older ++
        [
          %{
            last
            | event_sequence: last.event_sequence + 1,
              event_id: "event-invented",
              kind: "assistant.message_appended"
          }
        ]

    assert {:error, :private_public_projection_mismatch} =
             SessionState.recover(session_id, records, invented)
  end

  defp start(options) do
    fixture = Fixture.start(options)
    on_exit(fn -> Fixture.stop(fixture) end)
    fixture
  end

  defp session(fixture) do
    {:ok, session_id} = Loopex.create_session(fixture.runtime, %{}, command_id: "cs")
    {:ok, attachment} = Loopex.attach(fixture.runtime, session_id, after_event_sequence: 0)
    {session_id, attachment}
  end

  defp settle(fixture, session_id, attempts \\ 300) do
    case Loopex.session_status(fixture.runtime, session_id) do
      {:ok, %{active_run_id: nil}} ->
        :settled

      _other when attempts > 0 ->
        Process.sleep(10)
        settle(fixture, session_id, attempts - 1)

      _other ->
        :active
    end
  end

  defp drain(attachment, collected \\ []) do
    case Loopex.next_event(attachment) do
      {:ok, event} -> drain(attachment, [event | collected])
      _other -> Enum.reverse(collected)
    end
  end
end
