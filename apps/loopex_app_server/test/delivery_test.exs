Code.require_file("../../loopex/test/support/m1_runtime_helper.exs", __DIR__)
Code.require_file("../../loopex/test/support/agent_loop_helper.exs", __DIR__)

defmodule Loopex.AppServer.DeliveryTest do
  @moduledoc """
  ## Concept

  Durable events and transient progress travel to a client on separate terms.
  An event advances the client's cursor and is never dropped quietly; progress
  does not and may be. A writer that cannot keep up with durable history is
  detached at the exact cursor it reached.

  ## Technical depth

  Accepted ADR 0023 bounds the two planes separately, and the asymmetry is the
  point: a lost durable event leaves a client's view permanently wrong, while
  lost progress costs only smoothness. The cases drive the real committed events
  of a real run through the queue, so the projection is checked against what the
  runtime actually publishes rather than against a shape this test invented.
  """

  use ExUnit.Case, async: false

  alias Loopex.AgentLoopFixture, as: Fixture
  alias Loopex.AppServer.Delivery
  alias LoopexProtocol.Wire

  test "a durable event becomes one record carrying its kind, identity and sequence" do
    [event | _rest] = committed_events()

    queue = Delivery.new("s_1", 0)
    {[record], _drained} = queue |> Delivery.event(event) |> Delivery.take()

    assert record["type"] == "event"
    assert {:ok, "s_1"} = Wire.identity(record["session_id"])

    body = record["event"]
    assert body["kind"] == event.kind
    assert {:ok, event.event_id} == Wire.identity(body["event_id"])
    assert {:ok, event.event_sequence} == Wire.u64(body["event_sequence"])

    # The envelope carries the identity and the sequence; the data carries what
    # the kind itself says and keeps its own member names.
    refute Map.has_key?(body["data"], :kind)
    refute Map.has_key?(body["data"], :event_id)
    refute Map.has_key?(body["data"], :event_sequence)
  end

  test "only a durable event advances the cursor" do
    [event | _rest] = committed_events()

    queue = Delivery.new("s_1", 0)
    assert Delivery.cursor(queue) == 0

    advanced = Delivery.event(queue, event)
    assert Delivery.cursor(advanced) == event.event_sequence

    unchanged = Delivery.progress(advanced, %{kind: "text_delta", text: "x"})
    assert Delivery.cursor(unchanged) == event.event_sequence
  end

  test "durable records are emitted ahead of progress" do
    [event | _rest] = committed_events()

    {records, _drained} =
      Delivery.new("s_1", 0)
      |> Delivery.progress(%{kind: "text_delta", text: "first offered"})
      |> Delivery.event(event)
      |> Delivery.take()

    assert Enum.map(records, & &1["type"]) == ["event", "progress"]
  end

  test "a writer that cannot keep up detaches at the cursor it reached" do
    [event | _rest] = committed_events()

    queue =
      Enum.reduce(1..100, Delivery.new("s_1", 0), fn index, queue ->
        Delivery.event(queue, %{event | event_sequence: index})
      end)

    assert Delivery.detached?(queue)

    # The cursor is the last one completely queued, not the last one offered.
    cursor = Delivery.cursor(queue)
    assert cursor > 0
    assert cursor < 100

    detachment = Delivery.detachment(queue)
    assert detachment["type"] == "error"
    assert detachment["code"] == "detached"
    assert {:ok, ^cursor} = Wire.u64(detachment["event_cursor"])

    # Nothing is delivered after the detachment.
    assert Delivery.event(queue, event) == queue
    assert Delivery.progress(queue, %{kind: "text_delta"}) == queue
  end

  test "progress that does not fit is dropped and never detaches the writer" do
    queue =
      Enum.reduce(1..200, Delivery.new("s_1", 0), fn index, queue ->
        Delivery.progress(queue, %{kind: "text_delta", text: "item #{index}"})
      end)

    refute Delivery.detached?(queue)

    {records, _drained} = Delivery.take(queue)
    assert length(records) <= 32
    assert Enum.all?(records, &(&1["type"] == "progress"))
  end

  test "a progress record places itself against durable history without advancing it" do
    queue =
      Delivery.progress(Delivery.new("s_1", 7), %{
        kind: "text_delta",
        stream_domain_id: "domain-1",
        base_event_sequence: 7,
        text: "a delta"
      })

    {[record], _drained} = Delivery.take(queue)

    body = record["progress"]
    assert {:ok, "domain-1"} = Wire.identity(body["stream_domain_id"])
    assert {:ok, 7} = Wire.u64(body["base_event_sequence"])
    assert Delivery.cursor(queue) == 7
  end

  test "taking twice does not deliver the same record twice" do
    [event | _rest] = committed_events()

    {first, drained} = Delivery.new("s_1", 0) |> Delivery.event(event) |> Delivery.take()
    {second, _again} = Delivery.take(drained)

    assert length(first) == 1
    assert second == []
  end

  # Concept: events a real run actually committed.
  #
  # Technical depth: taken from the Store rather than written here, so the
  # projection is checked against what the runtime publishes. A shape invented
  # by this test would keep passing after the runtime changed its own.
  defp committed_events do
    fixture = Fixture.start(script: [%{text: "done", calls: []}])
    on_exit(fn -> Fixture.stop(fixture) end)

    {:ok, session_id} = Loopex.create_session(fixture.runtime, %{}, command_id: "cs")
    {:ok, attachment} = Loopex.attach(fixture.runtime, session_id, after_event_sequence: 0)

    {:accepted, _id} =
      Loopex.command(attachment, %{type: :prompt, command_id: "p1", content: "the task"})

    settle(fixture, session_id)

    events = Fixture.events(fixture, session_id)
    assert events != []
    events
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
end
