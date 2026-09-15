defmodule Loopex.AppServer.InitializationTest do
  @moduledoc """
  ## Concept

  A connection agrees on a generation before it may ask for anything else, and
  it agrees exactly once. Everything that fails those two rules is refused
  without reaching a runtime, so no refused client leaves durable work behind.

  ## Technical depth

  Accepted ADR 0023 fixes both rules and the error codes that report them.
  These cases drive the connection state directly rather than through a
  transport, because the rules belong to the protocol and not to stdio: a later
  transport inherits them by using this state, and a transport that
  reimplemented them could drift. What is asserted is the exact code a client
  branches on, the correlation it gets back, and the state the connection is
  left in, since a refusal that silently reset the state would hand back the
  retry the decision forbids.
  """

  use ExUnit.Case, async: true

  alias Loopex.AppServer.Connection
  alias LoopexProtocol.Session

  test "a fresh connection has negotiated nothing" do
    connection = Connection.new()

    refute Connection.initialized?(connection)
    assert Connection.generation(connection) == nil
  end

  test "initializing on a shared generation settles the connection and returns the contract" do
    assert {:ok, reply, connection} = initialize(["loopex.session.v1-experimental"])

    assert reply["type"] == "initialized"
    assert reply["request_id"] == "r1"
    assert reply["selected_generation"] == Session.generation()
    assert reply["exact_schema_sha256"] == Session.schema_digest()
    assert reply["limits"] == Session.limits()

    assert Connection.initialized?(connection)
    assert Connection.generation(connection) == Session.generation()
  end

  test "a mutation before initialization is refused and reaches no runtime" do
    connection = Connection.new()

    assert {:error, refusal, unchanged} =
             Connection.dispatch(connection, %{
               "method" => "session.prompt",
               "request_id" => "r1",
               "command_id" => "p1"
             })

    assert refusal["code"] == "not_initialized"
    assert refusal["request_id"] == "r1"
    refute Connection.initialized?(unchanged)

    # Nothing about the refusal tells the client which methods exist, and the
    # connection may still initialize: this is order, not a spent attempt.
    refute refusal["message"] =~ "session.prompt"
    assert {:ok, _reply, _initialized} = Connection.initialize(unchanged, request())
  end

  test "a second initialization is refused after a successful one, and changes nothing" do
    assert {:ok, _reply, connection} = initialize([Session.generation()])

    assert {:error, refusal, unchanged} = Connection.initialize(connection, request("r2"))

    assert refusal["code"] == "already_initialized"
    assert refusal["request_id"] == "r2"
    assert Connection.initialized?(unchanged)
    assert Connection.generation(unchanged) == Session.generation()
  end

  test "no common generation refuses and spends the connection's one attempt" do
    assert {:error, refusal, connection} = initialize(["loopex.session.v9-imaginary"])

    assert refusal["code"] == "unsupported_generation"
    assert refusal["request_id"] == "r1"
    refute Connection.initialized?(connection)

    # The refused connection does not get a second negotiation: a client that
    # could retry would walk the server's list until something matched.
    assert {:error, second, still_refused} = Connection.initialize(connection, request("r2"))
    assert second["code"] == "already_initialized"
    refute Connection.initialized?(still_refused)
  end

  test "a method this generation does not name is refused once the connection may ask" do
    assert {:ok, _reply, connection} = initialize([Session.generation()])

    assert {:error, refusal, _connection} =
             Connection.dispatch(connection, %{
               "method" => "session.teleport",
               "request_id" => "r2"
             })

    assert refusal["code"] == "unsupported_method"
    assert refusal["request_id"] == "r2"
  end

  test "every method the generation names is one this build answers" do
    for method <- Session.methods() do
      assert Loopex.AppServer.Mapping.implemented?(method),
             "#{method} is named by the generation but not answered"
    end
  end

  test "a request refused before a facade is an error, never a fabricated admission" do
    assert {:ok, _reply, connection} = initialize([Session.generation()])

    assert {:error, refusal, _connection} =
             Connection.dispatch(connection, %{
               "method" => "artifact.open_transfer",
               "request_id" => "r2",
               "use_ref" => "not base64url!"
             })

    assert refusal["type"] == "error"
    refute refusal["type"] == "admission"
    refute Map.has_key?(refusal, "status")
  end

  test "a connection with no runtime says so rather than pretending to answer" do
    assert {:ok, _reply, connection} = initialize([Session.generation()])

    assert {:error, refusal, _connection} =
             Connection.dispatch(connection, %{
               "method" => "session.create",
               "request_id" => "r2",
               "command_id" => "Y18x"
             })

    assert refusal["code"] == "facade_unavailable"
    assert refusal["request_id"] == "r2"
  end

  test "a malformed request correlates nothing rather than echoing bytes a client chose" do
    connection = Connection.new()

    for bad <- [
          %{"generations" => [Session.generation()], "capabilities" => []},
          %{"request_id" => "", "generations" => [Session.generation()], "capabilities" => []},
          %{
            "request_id" => String.duplicate("r", 65),
            "generations" => [Session.generation()],
            "capabilities" => []
          },
          %{
            "request_id" => "has space",
            "generations" => [Session.generation()],
            "capabilities" => []
          },
          %{"request_id" => "r1", "generations" => [], "capabilities" => []},
          %{"request_id" => "r1", "generations" => "not-an-array", "capabilities" => []},
          %{"request_id" => "r1", "generations" => [1], "capabilities" => []},
          %{"request_id" => "r1", "generations" => [Session.generation()]},
          %{
            "request_id" => "r1",
            "generations" => [Session.generation()],
            "capabilities" => [1]
          }
        ] do
      assert {:error, refusal, unchanged} = Connection.initialize(connection, bad)
      assert refusal["code"] == "invalid_request", "admitted #{inspect(bad)}"

      # A malformed request has not spent the attempt, because there was no
      # negotiation to spend.
      refute Connection.initialized?(unchanged)
    end
  end

  test "an unparsable request identity is never copied back into the refusal" do
    connection = Connection.new()

    assert {:error, refusal, _unchanged} =
             Connection.initialize(connection, %{
               "request_id" => "not a valid id",
               "generations" => [Session.generation()],
               "capabilities" => []
             })

    refute Map.has_key?(refusal, "request_id")
    refute inspect(refusal) =~ "not a valid id"
  end

  test "every refusal names a code from the closed set and carries no private text" do
    connection = Connection.new()

    refusals = [
      elem(Connection.dispatch(connection, %{"method" => "session.prompt"}), 1),
      elem(Connection.initialize(connection, %{"request_id" => "r1"}), 1),
      elem(initialize(["loopex.session.v9-imaginary"]), 1)
    ]

    for refusal <- refusals do
      assert refusal["type"] == "error"
      assert refusal["code"] in Session.error_codes()
      assert is_binary(refusal["message"])
      assert byte_size(refusal["message"]) <= 200
      refute refusal["message"] =~ "Elixir."
      refute refusal["message"] =~ "/"
    end
  end

  defp initialize(generations) do
    Connection.initialize(Connection.new(), %{
      "request_id" => "r1",
      "generations" => generations,
      "capabilities" => []
    })
  end

  defp request(request_id \\ "r1") do
    %{
      "request_id" => request_id,
      "generations" => [Session.generation()],
      "capabilities" => []
    }
  end
end
