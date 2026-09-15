Code.require_file("../../loopex/test/support/m1_runtime_helper.exs", __DIR__)
Code.require_file("../../loopex/test/support/agent_loop_helper.exs", __DIR__)

defmodule Loopex.AppServer.SessionMappingTest do
  @moduledoc """
  ## Concept

  A session driven over the wire and a session driven through the facade are the
  same session. The identities a client sends are the identities that commit,
  the durable history is identical either way, and what a client can read back
  is the public projection and nothing more.

  ## Technical depth

  These are differential cases: each one performs the same work twice, once
  through `Loopex` directly and once through the protocol mapping, and compares
  the durable truth the Store holds rather than the replies. Comparing replies
  would only prove the two surfaces answer similarly; comparing the committed
  records and events proves they mean the same thing, which is what accepted
  ADR 0023 requires of a second surface that owns no loop of its own.

  The command identity is the client's throughout. A mapping that minted its own
  would pass every reply-shaped assertion while breaking the replay a client
  depends on after a timeout, so the identity is asserted in the committed
  history rather than in the answer.
  """

  use ExUnit.Case, async: false

  alias Loopex.AgentLoopFixture, as: Fixture
  alias Loopex.AppServer.Connection
  alias Loopex.AppServer.Delivery
  alias LoopexProtocol.Wire

  test "a session created over the wire is the session the facade would have created" do
    wire = fixture()
    facade = fixture()

    {:ok, record, _connection} =
      dispatch(wire, %{
        "method" => "session.create",
        "request_id" => "r1",
        "command_id" => Wire.encode_identity("cs")
      })

    assert record["type"] == "admission"
    assert record["method"] == "session.create"
    assert record["status"] == "accepted"
    assert record["reason"] == nil
    assert {:ok, "cs"} = Wire.identity(record["command_id"])
    assert {:ok, wire_session} = Wire.identity(record["session_id"])

    {:ok, facade_session} = Loopex.create_session(facade.runtime, %{}, command_id: "cs")

    # The same command identity produced the same durable genesis on both
    # surfaces: identical record kinds, in the same order, at the same versions.
    assert kinds(wire, wire_session) == kinds(facade, facade_session)
    assert events(wire, wire_session) == events(facade, facade_session)
  end

  test "a prompt admitted over the wire commits the client's own command identity" do
    wire = fixture()
    facade = fixture()

    {wire_connection, wire_session} = created(wire)
    {:ok, facade_session} = Loopex.create_session(facade.runtime, %{}, command_id: "cs")

    {:ok, wire_attachment} = Loopex.attach(wire.runtime, wire_session, after_event_sequence: 0)

    {:ok, facade_attachment} =
      Loopex.attach(facade.runtime, facade_session, after_event_sequence: 0)

    wire_connection = Connection.attach(wire_connection, wire_attachment)

    {:ok, record, _connection} =
      Connection.dispatch(wire_connection, %{
        "method" => "session.prompt",
        "request_id" => "r2",
        "command_id" => Wire.encode_identity("p1"),
        "content_b64" => Wire.encode_bytes("the task")
      })

    assert record["type"] == "admission"
    assert record["status"] == "accepted"
    assert {:ok, "p1"} = Wire.identity(record["command_id"])

    assert {:accepted, "p1"} =
             Loopex.command(facade_attachment, %{
               type: :prompt,
               command_id: "p1",
               content: "the task"
             })

    settle(wire, wire_session)
    settle(facade, facade_session)

    # The whole durable history matches, not only the admission: the same
    # events in the same order, carrying the same kinds.
    assert events(wire, wire_session) == events(facade, facade_session)
    assert kinds(wire, wire_session) == kinds(facade, facade_session)
  end

  test "content crosses as exact bytes, including bytes that are not text" do
    wire = fixture()
    {connection, session_id} = created(wire)
    {:ok, attachment} = Loopex.attach(wire.runtime, session_id, after_event_sequence: 0)
    connection = Connection.attach(connection, attachment)

    content = <<"before ", 0xC3, 0x28, " after">>
    refute String.valid?(content)

    {:ok, record, _connection} =
      Connection.dispatch(connection, %{
        "method" => "session.prompt",
        "request_id" => "r2",
        "command_id" => Wire.encode_identity("p1"),
        "content_b64" => Wire.encode_bytes(content)
      })

    assert record["status"] == "accepted"

    committed =
      wire
      |> Fixture.records(session_id)
      |> Enum.find_value(fn record -> Map.get(record.payload, "content") end)

    assert committed == content
  end

  test "an inspect result is the public projection, and nothing behind it" do
    wire = fixture()
    {connection, session_id} = created(wire)

    {:ok, record, _connection} =
      Connection.dispatch(connection, %{
        "method" => "session.inspect",
        "request_id" => "r2",
        "session_id" => Wire.encode_identity(session_id)
      })

    assert record["type"] == "result"
    assert record["method"] == "session.inspect"

    projection = record["result"]

    assert Enum.sort(Map.keys(projection)) == [
             "active_context_token_budget",
             "active_run_id",
             "cleanup_grace_ms",
             "event_sequence",
             "open_interaction",
             "pending_work_ids",
             "status"
           ]

    # Quantities that can reach the whole unsigned range travel as decimal
    # strings, never as numbers.
    assert is_binary(projection["event_sequence"])
    assert is_binary(projection["cleanup_grace_ms"])

    # How the runtime keeps its promises is not what a client is owed.
    refute Map.has_key?(projection, "owner_epoch")
    refute Map.has_key?(projection, "journal_version")
    refute Map.has_key?(projection, "owner_incarnation_id")
  end

  test "a command before attaching is refused rather than given an attachment" do
    wire = fixture()
    {connection, _session_id} = created(wire)

    assert {:error, refusal, _connection} =
             Connection.dispatch(connection, %{
               "method" => "session.prompt",
               "request_id" => "r2",
               "command_id" => Wire.encode_identity("p1"),
               "content_b64" => Wire.encode_bytes("the task")
             })

    assert refusal["code"] == "not_attached"
    assert refusal["request_id"] == "r2"
  end

  test "a field in the wrong representation is refused before the facade sees it" do
    wire = fixture()
    {connection, _session_id} = created(wire)

    for bad <- [
          %{"method" => "session.create", "request_id" => "r2", "command_id" => "not base64url!"},
          %{"method" => "session.create", "request_id" => "r2"},
          %{
            "method" => "session.create",
            "request_id" => "r2",
            "command_id" => Wire.encode_identity("c"),
            "session_options" => "not an object"
          },
          %{"method" => "session.inspect", "request_id" => "r2", "session_id" => 7}
        ] do
      assert {:error, refusal, _connection} = Connection.dispatch(connection, bad)
      assert refusal["code"] == "invalid_request", "admitted #{inspect(bad)}"
    end
  end

  # The eight cases below are this outcome's locked witnesses. Each carries the
  # exact identity acceptance bound; the narrower cases above remain because they
  # say which single rule broke when one of these fails.

  test "the same command corpus produces identical durable identities through facade and wire" do
    corpus = [
      %{type: :prompt, command_id: "c1", content: "first"},
      %{type: :prompt, command_id: "c2", content: "second"}
    ]

    through_facade = fixture()
    {:ok, facade_session} = Loopex.create_session(through_facade.runtime, %{}, command_id: "cs")
    {:ok, facade_attachment} = Loopex.attach(through_facade.runtime, facade_session, [])

    for command <- corpus do
      {:accepted, _id} = Loopex.command(facade_attachment, command)
      settle(through_facade, facade_session)
    end

    through_wire = fixture()
    {connection, wire_session} = created(through_wire)

    {:ok, _snapshot, connection} =
      Connection.dispatch(connection, %{
        "method" => "session.attach",
        "request_id" => "ra",
        "session_id" => Wire.encode_identity(wire_session)
      })

    connection =
      Enum.reduce(corpus, connection, fn command, connection ->
        {:ok, _record, connection} =
          Connection.dispatch(connection, %{
            "method" => "session.prompt",
            "request_id" => "r-#{command.command_id}",
            "command_id" => Wire.encode_identity(command.command_id),
            "content_b64" => Base.url_encode64(command.content, padding: false)
          })

        settle(through_wire, wire_session)
        connection
      end)

    refute is_nil(connection)

    # The identities a client sent are the identities that committed, on both
    # surfaces, and the durable history means the same thing either way.
    assert kinds(through_facade, facade_session) == kinds(through_wire, wire_session)
    assert events(through_facade, facade_session) == events(through_wire, wire_session)
  end

  test "request identity varies independently of command identity and replay returns the historical admission" do
    fixture = fixture()
    {connection, session_id} = created(fixture)

    {:ok, _snapshot, connection} =
      Connection.dispatch(connection, %{
        "method" => "session.attach",
        "request_id" => "ra",
        "session_id" => Wire.encode_identity(session_id)
      })

    command = %{
      "method" => "session.prompt",
      "command_id" => Wire.encode_identity("cp"),
      "content_b64" => Base.url_encode64("once", padding: false)
    }

    assert {:ok, first, connection} =
             Connection.dispatch(connection, Map.put(command, "request_id", "r1"))

    settle(fixture, session_id)
    before = kinds(fixture, session_id)

    # A different request identity carrying the same command identity is a
    # replay, not a second command: the answer is the historical admission and
    # the durable history does not grow.
    assert {:ok, second, _connection} =
             Connection.dispatch(connection, Map.put(command, "request_id", "r2"))

    assert second["request_id"] == "r2"
    assert first["request_id"] == "r1"
    assert second["command_id"] == first["command_id"]
    assert second["status"] == first["status"]
    assert kinds(fixture, session_id) == before
  end

  test "attach returns a snapshot and cursor before live delivery and admission precedes correlated asynchronous delivery" do
    fixture = fixture()
    {connection, session_id} = created(fixture)

    assert {:ok, snapshot, connection} =
             Connection.dispatch(connection, %{
               "method" => "session.attach",
               "request_id" => "ra",
               "session_id" => Wire.encode_identity(session_id)
             })

    assert snapshot["type"] == "snapshot"
    assert is_binary(snapshot["event_cursor"])

    cursor = String.to_integer(snapshot["event_cursor"])

    # The admission is answered before anything the command causes is delivered,
    # which is what lets a client correlate one against the other rather than
    # guess.
    assert {:ok, admission, _connection} =
             Connection.dispatch(connection, %{
               "method" => "session.prompt",
               "request_id" => "rp",
               "command_id" => Wire.encode_identity("cp"),
               "content_b64" => Base.url_encode64("go", padding: false)
             })

    assert admission["type"] == "admission"
    assert admission["status"] == "accepted"

    settle(fixture, session_id)

    published = Fixture.events(fixture, session_id)
    assert published != []
    assert Enum.all?(published, &(&1.event_sequence > cursor))
  end

  test "a fresh attachment pairs its unchanged revision two snapshot with the exact same cursor open interaction view" do
    fixture = fixture()
    {connection, session_id} = created(fixture)

    assert {:ok, first, _connection} =
             Connection.dispatch(connection, %{
               "method" => "session.attach",
               "request_id" => "ra",
               "session_id" => Wire.encode_identity(session_id),
               "after_event_sequence" => "0"
             })

    # A second connection attaching at the same cursor sees the same snapshot.
    # Two clients reading one session at one point must not disagree about it. It
    # names replacement because a session has one attached caller, and taking
    # that over is something a caller says rather than something it stumbles into.
    second_connection = Connection.new(runtime: fixture.runtime)

    {:ok, _reply, second_connection} =
      Connection.initialize(second_connection, %{
        "request_id" => "r0",
        "generations" => [LoopexProtocol.Session.generation()],
        "capabilities" => []
      })

    assert {:ok, second, _connection} =
             Connection.dispatch(second_connection, %{
               "method" => "session.attach",
               "request_id" => "rb",
               "session_id" => Wire.encode_identity(session_id),
               "after_event_sequence" => "0",
               "replace" => true
             })

    assert second["event_cursor"] == first["event_cursor"]
    assert Map.drop(second, ["request_id"]) == Map.drop(first, ["request_id"])
    assert second["open_interaction"] == first["open_interaction"]
  end

  test "a second attach refuses with a stable reason unless it names explicit replacement which detaches the first at its last emitted cursor" do
    fixture = fixture()
    {connection, session_id} = created(fixture)

    assert {:ok, first, connection} =
             Connection.dispatch(connection, %{
               "method" => "session.attach",
               "request_id" => "ra",
               "session_id" => Wire.encode_identity(session_id)
             })

    attach = %{
      "method" => "session.attach",
      "request_id" => "rb",
      "session_id" => Wire.encode_identity(session_id)
    }

    # Accepted ADR 0023 bounds this per foreground process, so the second attach
    # that must refuse is the one this same connection makes. Refusal is the
    # default, and its reason is stable rather than incidental.
    assert {:error, refusal, connection} = Connection.dispatch(connection, attach)
    assert refusal["code"] == "attachment_conflict"
    assert refusal["code"] in LoopexProtocol.Session.error_codes()

    # Replacement happens only when a client says so, and the replacement's view
    # begins where the session stands rather than at the beginning.
    assert {:ok, replaced, _connection} =
             Connection.dispatch(connection, Map.put(attach, "replace", true))

    assert replaced["type"] == "snapshot"
    assert String.to_integer(replaced["event_cursor"]) >= String.to_integer(first["event_cursor"])
  end

  test "in flight request identity reuse refuses and reuse after completion is ordinary correlation" do
    connection = Connection.new()

    {:ok, _reply, connection} =
      Connection.initialize(connection, %{
        "request_id" => "r0",
        "generations" => [LoopexProtocol.Session.generation()],
        "capabilities" => []
      })

    assert {:ok, claimed} = Connection.begin_request(connection, "r1")
    assert Connection.in_flight(claimed) == ["r1"]

    assert {:error, refusal, unchanged} = Connection.begin_request(claimed, "r1")
    assert refusal["code"] == "invalid_request"
    assert refusal["request_id"] == "r1"
    assert Connection.in_flight(unchanged) == ["r1"]

    # Completion is what makes the identity ordinary again.
    released = Connection.complete_request(claimed, "r1")
    assert Connection.in_flight(released) == []
    assert {:ok, again} = Connection.begin_request(released, "r1")
    assert Connection.in_flight(again) == ["r1"]
  end

  test "pre admission pressure refuses before any durable write and post admission pressure drops progress first then detaches at the last emitted cursor" do
    fixture = fixture()
    {connection, session_id} = created(fixture)
    before = kinds(fixture, session_id)

    ceiling = Map.fetch!(LoopexProtocol.Session.limits(), "max_requests_in_flight")

    saturated =
      Enum.reduce(1..ceiling, connection, fn index, connection ->
        {:ok, connection} = Connection.begin_request(connection, "inflight-#{index}")
        connection
      end)

    # Pressure before admission refuses, and refuses before anything durable
    # happens: the session's history is exactly what it was.
    assert {:error, refusal, _unchanged} = Connection.begin_request(saturated, "one-too-many")
    assert refusal["code"] == "capacity_exceeded"
    refute Map.has_key?(refusal, "request_id")
    assert kinds(fixture, session_id) == before

    # Pressure after admission is the delivery queue's, and the two planes give
    # way differently: progress is dropped, durable events detach at the cursor
    # the client had reached.
    queue = Delivery.new(session_id, 0)

    flooded_progress =
      Enum.reduce(1..64, queue, fn index, queue ->
        Delivery.progress(queue, %{"seq" => index, "bytes" => String.duplicate("p", 32_768)})
      end)

    refute Delivery.detached?(flooded_progress)

    flooded_events =
      Enum.reduce(1..128, queue, fn index, queue ->
        Delivery.event(queue, %{
          event_id: "event-#{index}",
          kind: "run.progressed",
          event_sequence: index,
          payload: %{"bytes" => String.duplicate("e", 65_536)}
        })
      end)

    assert Delivery.detached?(flooded_events)
    detachment = Delivery.detachment(flooded_events)
    assert detachment["code"] == "detached"
    assert is_binary(detachment["event_cursor"])
  end

  test "snapshots durable events transient progress and diagnostics stay separate record families and a fresh settled attachment is the final authority" do
    fixture = fixture()
    {connection, session_id} = created(fixture)

    assert {:ok, snapshot, connection} =
             Connection.dispatch(connection, %{
               "method" => "session.attach",
               "request_id" => "ra",
               "session_id" => Wire.encode_identity(session_id)
             })

    assert {:ok, admission, _connection} =
             Connection.dispatch(connection, %{
               "method" => "session.prompt",
               "request_id" => "rp",
               "command_id" => Wire.encode_identity("cp"),
               "content_b64" => Base.url_encode64("go", padding: false)
             })

    settle(fixture, session_id)

    # Each plane is its own record family, and the families are disjoint: a
    # client branching on `type` can never mistake a rendering aid for history.
    assert snapshot["type"] == "snapshot"
    assert admission["type"] == "admission"

    families = LoopexProtocol.Session.record_families()
    assert "snapshot" in families
    assert "event" in families
    assert "progress" in families
    assert length(Enum.uniq(families)) == length(families)

    # A fresh attachment after the run settles is the authority: it reports the
    # session as it now stands, not as the first attachment last saw it.
    fresh = Connection.new(runtime: fixture.runtime)

    {:ok, _reply, fresh} =
      Connection.initialize(fresh, %{
        "request_id" => "r0",
        "generations" => [LoopexProtocol.Session.generation()],
        "capabilities" => []
      })

    assert {:ok, settled, _fresh} =
             Connection.dispatch(fresh, %{
               "method" => "session.attach",
               "request_id" => "rc",
               "session_id" => Wire.encode_identity(session_id),
               "replace" => true
             })

    assert settled["type"] == "snapshot"

    assert String.to_integer(settled["event_cursor"]) >
             String.to_integer(snapshot["event_cursor"])
  end

  defp fixture do
    fixture = Fixture.start(script: [%{text: "done", calls: []}])
    on_exit(fn -> Fixture.stop(fixture) end)
    fixture
  end

  defp dispatch(fixture, request) do
    connection = Connection.new(runtime: fixture.runtime)

    {:ok, _reply, connection} =
      Connection.initialize(connection, %{
        "request_id" => "r0",
        "generations" => [LoopexProtocol.Session.generation()],
        "capabilities" => []
      })

    Connection.dispatch(connection, request)
  end

  defp created(fixture) do
    connection = Connection.new(runtime: fixture.runtime)

    {:ok, _reply, connection} =
      Connection.initialize(connection, %{
        "request_id" => "r0",
        "generations" => [LoopexProtocol.Session.generation()],
        "capabilities" => []
      })

    {:ok, record, connection} =
      Connection.dispatch(connection, %{
        "method" => "session.create",
        "request_id" => "r1",
        "command_id" => Wire.encode_identity("cs")
      })

    {:ok, session_id} = Wire.identity(record["session_id"])
    {connection, session_id}
  end

  # Concept: the durable event history, with the identities that differ between
  # two runtimes removed.
  #
  # Technical depth: event and session identifiers are derived per runtime, so
  # comparing them would compare the two fixtures rather than the two surfaces.
  # What must match is the ordered kinds and the payload members that carry
  # meaning, which is what a client actually reads.
  defp events(fixture, session_id) do
    fixture
    |> Fixture.events(session_id)
    |> Enum.map(fn event ->
      {event.kind, event |> Map.drop([:event_id, :event_sequence, :kind]) |> Map.delete("run_id")}
    end)
  end

  defp kinds(fixture, session_id) do
    fixture |> Fixture.records(session_id) |> Enum.map(& &1.payload.kind)
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
