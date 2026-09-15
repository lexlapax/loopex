Code.require_file("../../loopex/test/support/m1_runtime_helper.exs", __DIR__)
Code.require_file("../../loopex/test/support/agent_loop_helper.exs", __DIR__)

defmodule Loopex.AppServer.FoundationMappingTest do
  @moduledoc """
  ## Concept

  Attaching over the wire gives a client the same authoritative snapshot the
  facade gives, at the same cursor, and an interaction answered over the wire is
  the same durable answer the facade would have committed. Neither carries
  anything a client is not owed.

  ## Technical depth

  Accepted ADR 0023 fixes the snapshot's exact members and the answer's exact
  shape, and accepted ADR 0024 owns what an interaction is. These cases assert
  the wire projection member by member rather than comparing it to itself, and
  they assert the refusals that keep an answer from becoming an authority: an
  answer naming anything besides one choice is refused before a facade sees it,
  because a client that could attach a second member to an answer would be
  writing policy input.
  """

  use ExUnit.Case, async: false

  alias Loopex.AgentLoopFixture, as: Fixture
  alias Loopex.AppServer.Connection
  alias LoopexProtocol.Session
  alias LoopexProtocol.Wire

  test "attaching returns the snapshot and the cursor, in their wire representations" do
    fixture = fixture()
    {connection, session_id} = created(fixture)

    {:ok, record, _connection} =
      Connection.dispatch(connection, %{
        "method" => "session.attach",
        "request_id" => "r2",
        "session_id" => Wire.encode_identity(session_id),
        "after_event_sequence" => "0"
      })

    assert record["type"] == "snapshot"
    assert record["request_id"] == "r2"
    assert {:ok, ^session_id} = Wire.identity(record["session_id"])

    # The cursor is a decimal string, and the snapshot reports the same number.
    assert {:ok, cursor} = Wire.u64(record["event_cursor"])
    assert record["snapshot"]["event_sequence"] == record["event_cursor"]
    assert is_integer(cursor)

    snapshot = record["snapshot"]
    assert snapshot["snapshot_revision"] == 2

    assert Enum.sort(Map.keys(snapshot)) == [
             "active_run_id",
             "active_run_phase",
             "event_sequence",
             "session_id",
             "snapshot_revision"
           ]

    # The two active members are both absent or both present; a phase is never
    # inferred from an identity.
    assert is_nil(snapshot["active_run_id"]) == is_nil(snapshot["active_run_phase"])
  end

  test "the wire snapshot carries the same state the facade's own attachment does" do
    fixture = fixture()
    {connection, session_id} = created(fixture)

    {:ok, record, _connection} =
      Connection.dispatch(connection, %{
        "method" => "session.attach",
        "request_id" => "r2",
        "session_id" => Wire.encode_identity(session_id)
      })

    {:ok, attachment} = Loopex.attach(fixture.runtime, session_id, after_event_sequence: 0)
    facade = Loopex.snapshot(attachment)

    assert record["snapshot"]["snapshot_revision"] == facade.snapshot_revision
    assert {:ok, ^session_id} = Wire.identity(record["snapshot"]["session_id"])

    assert {:ok, facade.event_sequence} == Wire.u64(record["snapshot"]["event_sequence"])
  end

  test "a cursor in any spelling but canonical decimal is refused" do
    fixture = fixture()
    {connection, session_id} = created(fixture)

    for bad <- [0, "00", "-1", "1.0", " 0"] do
      assert {:error, refusal, _connection} =
               Connection.dispatch(connection, %{
                 "method" => "session.attach",
                 "request_id" => "r2",
                 "session_id" => Wire.encode_identity(session_id),
                 "after_event_sequence" => bad
               })

      assert refusal["code"] == "invalid_request", "admitted #{inspect(bad)}"
    end
  end

  test "replace must be a boolean, and defaults to leaving another attachment alone" do
    fixture = fixture()
    {connection, session_id} = created(fixture)

    assert {:error, refusal, _connection} =
             Connection.dispatch(connection, %{
               "method" => "session.attach",
               "request_id" => "r2",
               "session_id" => Wire.encode_identity(session_id),
               "replace" => "true"
             })

    assert refusal["code"] == "invalid_request"

    assert {:ok, record, _connection} =
             Connection.dispatch(connection, %{
               "method" => "session.attach",
               "request_id" => "r3",
               "session_id" => Wire.encode_identity(session_id)
             })

    assert record["type"] == "snapshot"
  end

  test "an answer must name exactly one offered choice and nothing else" do
    fixture = fixture()
    {connection, session_id} = created(fixture)
    {:ok, attachment} = Loopex.attach(fixture.runtime, session_id, after_event_sequence: 0)
    connection = Connection.attach(connection, attachment)

    for bad <- [
          %{},
          %{"choice_id" => Wire.encode_identity("yes"), "note" => "extra"},
          %{"choice" => Wire.encode_identity("yes")},
          %{"choice_id" => "not base64url!"},
          "yes"
        ] do
      assert {:error, refusal, _connection} =
               Connection.dispatch(connection, %{
                 "method" => "session.respond_interaction",
                 "request_id" => "r2",
                 "command_id" => Wire.encode_identity("a1"),
                 "interaction_id" => Wire.encode_identity("i1"),
                 "answer" => bad
               })

      assert refusal["code"] == "invalid_request", "admitted #{inspect(bad)}"
    end
  end

  test "an answer to no open question is refused by the runtime, not accepted here" do
    fixture = fixture()
    {connection, session_id} = created(fixture)
    {:ok, attachment} = Loopex.attach(fixture.runtime, session_id, after_event_sequence: 0)
    connection = Connection.attach(connection, attachment)

    assert {:ok, record, _connection} =
             Connection.dispatch(connection, %{
               "method" => "session.respond_interaction",
               "request_id" => "r2",
               "command_id" => Wire.encode_identity("a1"),
               "interaction_id" => Wire.encode_identity("i1"),
               "answer" => %{"choice_id" => Wire.encode_identity("yes")}
             })

    # It reaches the facade and comes back refused with a stable reason, rather
    # than being accepted by a layer with no authority to accept it.
    assert record["type"] == "admission"
    assert record["status"] == "refused"
    assert is_binary(record["reason"])
  end

  test "an answer carries no authority: the wire cannot mark a decision allowed" do
    fixture = fixture()
    {connection, session_id} = created(fixture)
    {:ok, attachment} = Loopex.attach(fixture.runtime, session_id, after_event_sequence: 0)
    connection = Connection.attach(connection, attachment)

    assert {:ok, record, _connection} =
             Connection.dispatch(connection, %{
               "method" => "session.respond_interaction",
               "request_id" => "r2",
               "command_id" => Wire.encode_identity("a1"),
               "interaction_id" => Wire.encode_identity("i1"),
               "answer" => %{"choice_id" => Wire.encode_identity("yes")}
             })

    rendered = inspect(record, limit: :infinity)

    refute rendered =~ "allow"
    refute rendered =~ "grant"
    refute rendered =~ "policy"
  end

  test "a resource read names at least one selector" do
    fixture = fixture()
    {connection, session_id} = created(fixture)

    assert {:error, refusal, _connection} =
             Connection.dispatch(connection, %{
               "method" => "resources.read",
               "request_id" => "r2",
               "session_id" => Wire.encode_identity(session_id)
             })

    assert refusal["code"] == "invalid_request"
  end

  test "every method this build answers is one the generation names" do
    for method <- ["session.attach", "session.respond_interaction", "resources.catalog"] do
      assert method in Session.methods()
    end
  end

  defp fixture do
    fixture = Fixture.start(script: [%{text: "done", calls: []}])
    on_exit(fn -> Fixture.stop(fixture) end)
    fixture
  end

  defp created(fixture) do
    connection = Connection.new(runtime: fixture.runtime)

    {:ok, _reply, connection} =
      Connection.initialize(connection, %{
        "request_id" => "r0",
        "generations" => [Session.generation()],
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
end
