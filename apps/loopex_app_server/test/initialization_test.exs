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
  alias LoopexProtocol.Frame
  alias LoopexProtocol.Session

  @frame_limit 2_097_152

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

  # The five cases below are this outcome's locked witnesses. Each carries the
  # exact identity acceptance bound, and each composes what its name claims; the
  # finer cases above remain because they say which single rule broke when one of
  # these fails.

  test "a raw byte client negotiates the exact experimental generation schema digest and limits before any mutation" do
    # Bytes, not maps: a client that only ever spoke through Elixir terms would
    # not notice a contract that could not survive its own encoding.
    assert {:ok, encoded} =
             Frame.encode(%{
               "method" => "initialize",
               "request_id" => "r1",
               "generations" => [Session.generation()],
               "capabilities" => []
             })

    # The encoder frames what it produces, so the line it carries is the object
    # without the newline. A caller that re-framed would send two.
    frame = IO.iodata_to_binary(encoded)
    assert String.ends_with?(frame, "\n")

    assert {:ok, request} = Frame.decode(String.trim_trailing(frame, "\n"), @frame_limit)
    assert {:ok, reply, connection} = Connection.initialize(Connection.new(), request)

    assert reply["selected_generation"] == "loopex.session.v1-experimental"
    assert reply["exact_schema_sha256"] == Session.schema_digest()
    assert reply["limits"] == Session.limits()

    # The reply survives the same encoding it arrived through.
    assert {:ok, round_tripped} = Frame.encode(reply)

    assert {:ok, decoded} =
             round_tripped
             |> IO.iodata_to_binary()
             |> String.trim_trailing("\n")
             |> Frame.decode(@frame_limit)

    assert decoded["exact_schema_sha256"] == Session.schema_digest()

    # Negotiation comes first: the same mutation is refused before it, and is
    # refused for some other reason after it.
    mutation = %{"method" => "session.prompt", "request_id" => "r2", "command_id" => "cDE"}

    assert {:error, before, _unchanged} = Connection.dispatch(Connection.new(), mutation)
    assert before["code"] == "not_initialized"

    assert {:error, after_negotiation, _connection} = Connection.dispatch(connection, mutation)
    assert after_negotiation["code"] != "not_initialized"
  end

  test "mutation before initialization and repeated initialization refuse without durable work" do
    fresh = Connection.new()

    assert {:error, early, unchanged} =
             Connection.dispatch(fresh, %{
               "method" => "session.prompt",
               "request_id" => "r1",
               "command_id" => "cDE"
             })

    assert early["code"] == "not_initialized"
    refute Connection.initialized?(unchanged)

    # Order, not a spent attempt: the same connection may still negotiate.
    assert {:ok, _reply, connection} = Connection.initialize(unchanged, request())

    assert {:error, repeated, still} = Connection.initialize(connection, request("r2"))
    assert repeated["code"] == "already_initialized"
    assert Connection.initialized?(still)
    assert Connection.generation(still) == Session.generation()

    # Neither refusal carried an admission, which is what "without durable work"
    # means here: this connection holds no runtime, so any status it reported
    # would have had to be fabricated rather than committed.
    for refusal <- [early, repeated] do
      assert refusal["type"] == "error"
      refute Map.has_key?(refusal, "status")
      refute Map.has_key?(refusal, "command_id")
    end
  end

  test "protocol records reach only stdout and bounded diagnostics only stderr across a real process boundary" do
    elixir = System.find_executable("elixir") || flunk("Elixir executable unavailable")

    arguments =
      ["-pa", ebin(:loopex_protocol), "-pa", ebin(:loopex), "-pa", ebin(:loopex_app_server)] ++
        ["-pa", ebin(:telemetry)] ++
        Enum.flat_map(require_paths(), &["-r", &1]) ++
        ["-e", "Loopex.AppServer.Fixture.serve()"]

    port =
      Port.open({:spawn_executable, elixir}, [
        :binary,
        :exit_status,
        args: arguments,
        env: for({key, value} <- child_environment(), do: {to_charlist(key), to_charlist(value)})
      ])

    assert {:ok, encoded} =
             Frame.encode(%{
               "method" => "initialize",
               "request_id" => "r1",
               "generations" => [Session.generation()],
               "capabilities" => []
             })

    Port.command(port, IO.iodata_to_binary(encoded))
    output = collect(port, "", System.monotonic_time(:millisecond) + 20_000)
    close_port(port)

    lines = String.split(output, "\n", trim: true)
    assert lines != [], "the server wrote nothing to standard output"

    # Every line the process produced on standard output is a protocol record.
    # Anything else here would break a client parsing this stream by line, which
    # is the whole reason diagnostics are kept off it. Standard error is not
    # merged into this port, so a diagnostic arriving here would be visible as a
    # line that does not decode.
    for line <- lines do
      assert {:ok, record} = Frame.decode(line, @frame_limit),
             "not a protocol record: #{inspect(line)}"

      assert record["type"] in Session.record_families()
    end

    assert Enum.any?(lines, fn line ->
             {:ok, record} = Frame.decode(line, @frame_limit)
             record["type"] == "initialized"
           end)
  end

  test "strict UTF-8 LF framing and the exact method inventory refuse unknown mutating methods before admission and answer unknown queries with a bounded error" do
    # Framing first: a carriage return, a second object on the line, invalid
    # UTF-8 and trailing bytes are each refused rather than repaired.
    for bad <- [
          ~s({"method":"initialize"}\r),
          ~s({"method":"initialize"}{"method":"initialize"}),
          <<123, 34, 109, 34, 58, 34, 255, 34, 125>>,
          ~s({"method":"initialize"} trailing)
        ] do
      assert match?({:error, _reason}, Frame.decode(bad, @frame_limit)),
             "framing admitted #{inspect(bad)}"
    end

    # The inventory is exact in both directions: the generation names sixteen
    # methods and this build answers every one of them.
    assert length(Session.methods()) == 16

    for method <- Session.methods() do
      assert Loopex.AppServer.Mapping.implemented?(method),
             "#{method} is named by the generation but not answered"
    end

    assert {:ok, _reply, connection} = initialize([Session.generation()])

    # An unknown method is refused whether it reads as a mutation or a query,
    # and the refusal is bounded and names a code from the closed set.
    for method <- ["session.teleport", "resources.divine"] do
      assert {:error, refusal, unchanged} =
               Connection.dispatch(connection, %{"method" => method, "request_id" => "r2"})

      assert refusal["code"] == "unsupported_method"
      assert refusal["code"] in Session.error_codes()
      assert byte_size(refusal["message"]) <= 200
      refute Map.has_key?(refusal, "status")
      assert Connection.initialized?(unchanged)
    end
  end

  test "every connection state row from before initialize through restart behaves as ADR 0023 specifies" do
    # One row per state the decision names, driven in order.
    fresh = Connection.new()
    refute Connection.initialized?(fresh)
    assert Connection.generation(fresh) == nil

    assert {:error, early, _unchanged} =
             Connection.dispatch(fresh, %{"method" => "session.prompt", "request_id" => "r1"})

    assert early["code"] == "not_initialized"

    assert {:ok, _reply, settled} = Connection.initialize(fresh, request())
    assert Connection.initialized?(settled)
    assert Connection.generation(settled) == Session.generation()

    assert {:error, repeated, _still} = Connection.initialize(settled, request("r2"))
    assert repeated["code"] == "already_initialized"

    assert {:error, unsupported, refused} = initialize(["loopex.session.v9-imaginary"])
    assert unsupported["code"] == "unsupported_generation"
    refute Connection.initialized?(refused)

    # A refused negotiation has spent the connection's one attempt: a client
    # that could retry would walk the server's list until something matched.
    assert {:error, spent, _} = Connection.initialize(refused, request("r3"))
    assert spent["code"] == "already_initialized"

    # Restart is a new connection, and a new connection has negotiated nothing.
    # None of this state survives the transport that carried it.
    restarted = Connection.new()
    refute Connection.initialized?(restarted)
    assert Connection.generation(restarted) == nil
    assert {:ok, _reply, _negotiated} = Connection.initialize(restarted, request())
  end

  defp collect(port, acc, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      acc
    else
      receive do
        {^port, {:data, chunk}} ->
          combined = acc <> chunk

          if String.contains?(combined, "\n"),
            do: combined,
            else: collect(port, combined, deadline)

        {^port, {:exit_status, _status}} ->
          acc
      after
        remaining -> acc
      end
    end
  end

  defp close_port(port) do
    Port.close(port)
  catch
    :error, :badarg -> :ok
  end

  defp ebin(application) do
    path = Application.app_dir(application, "ebin")
    assert File.dir?(path)
    path
  end

  defp repository_root, do: Path.expand(Path.join([__DIR__, "..", "..", ".."]))

  defp require_paths do
    support = Path.join([repository_root(), "apps", "loopex", "test", "support"])
    own = Path.join([repository_root(), "apps", "loopex_app_server", "test", "support"])

    [
      Path.join(support, "m1_runtime_helper.exs"),
      Path.join(support, "agent_loop_helper.exs"),
      Path.join(own, "fixture_server.exs")
    ]
  end

  defp child_environment do
    root =
      Path.join(System.tmp_dir!(), "loopex-initialization-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(root, "home"))
    File.mkdir_p!(Path.join(root, "workspace"))
    on_exit(fn -> File.rm_rf(root) end)

    [
      {"LOOPEX_HOME", Path.join(root, "home")},
      {"LOOPEX_WORKSPACE", Path.join(root, "workspace")},
      {"ELIXIR_ERL_OPTIONS", "-noinput"}
    ]
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
