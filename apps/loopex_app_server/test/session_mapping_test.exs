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
