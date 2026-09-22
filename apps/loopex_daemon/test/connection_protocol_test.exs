defmodule LoopexDaemon.ConnectionProtocolTest do
  use ExUnit.Case, async: true

  alias LoopexDaemon.ConnectionProtocol
  alias LoopexProtocol.Session.V2

  test "generation two initializes exactly once" do
    assert {:ok, reply, initialized, :initialized} =
             ConnectionProtocol.handle(ConnectionProtocol.new(), initialize())

    assert reply["type"] == "initialized"
    assert reply["request_id"] == "r1"
    assert reply["selected_generation"] == V2.generation()
    assert reply["exact_schema_sha256"] == V2.schema_digest()
    assert reply["limits"] == V2.limits()
    assert ConnectionProtocol.initialized?(initialized)

    assert {:error, second, ^initialized, :none} =
             ConnectionProtocol.handle(initialized, initialize("r2"))

    assert second["code"] == "already_initialized"
    assert second["request_id"] == "r2"
  end

  test "generation one is refused and spends the negotiation attempt" do
    request = initialize("r1", ["loopex.experimental/1"])

    assert {:error, refusal, refused, :none} =
             ConnectionProtocol.handle(ConnectionProtocol.new(), request)

    assert refusal["code"] == "unsupported_generation"

    assert {:error, second, ^refused, :none} =
             ConnectionProtocol.handle(refused, initialize("r2"))

    assert second["code"] == "already_initialized"
  end

  test "malformed negotiation does not spend the attempt or echo unsafe identity" do
    protocol = ConnectionProtocol.new()

    for bad <- [
          %{"method" => "initialize", "generations" => [V2.generation()], "capabilities" => []},
          initialize(""),
          initialize(String.duplicate("r", 65)),
          initialize("has space"),
          initialize("r1", []),
          Map.put(initialize(), "generations", "not-an-array"),
          Map.put(initialize(), "generations", [1]),
          Map.delete(initialize(), "capabilities"),
          Map.put(initialize(), "capabilities", [1]),
          Map.put(initialize(), "extra", true)
        ] do
      assert {:error, refusal, ^protocol, :none} = ConnectionProtocol.handle(protocol, bad)
      assert refusal["code"] == "invalid_request"

      if bad["request_id"] == "r1",
        do: assert(refusal["request_id"] == "r1"),
        else: refute(Map.has_key?(refusal, "request_id"))
    end

    assert {:ok, _reply, _initialized, :initialized} =
             ConnectionProtocol.handle(protocol, initialize())
  end

  test "method order is hidden before initialization and named methods remain inert" do
    protocol = ConnectionProtocol.new()

    assert {:error, before, ^protocol, :none} =
             ConnectionProtocol.handle(protocol, %{
               "method" => "session.list",
               "request_id" => "r1"
             })

    assert before["code"] == "not_initialized"

    assert {:ok, _reply, initialized, :initialized} =
             ConnectionProtocol.handle(protocol, initialize())

    assert {:error, named, ^initialized, :none} =
             ConnectionProtocol.handle(initialized, %{
               "method" => "session.list",
               "request_id" => "r2"
             })

    assert named["code"] == "unsupported_method"

    assert {:error, unknown, ^initialized, :none} =
             ConnectionProtocol.handle(initialized, %{
               "method" => "session.teleport",
               "request_id" => "r3"
             })

    assert unknown["code"] == "unsupported_method"
  end

  defp initialize(request_id \\ "r1", generations \\ [V2.generation()]) do
    %{
      "method" => "initialize",
      "request_id" => request_id,
      "generations" => generations,
      "capabilities" => []
    }
  end
end
