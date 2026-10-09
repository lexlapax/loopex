Code.require_file("support/foreground_output_fixture.txt", __DIR__)

defmodule Loopex.AppServer.StdioProbeTest do
  @moduledoc """
  ## Concept

  A separate operating-system process, driven by raw bytes on its standard
  input, negotiates a generation before it answers anything else and writes only
  protocol records to its standard output.

  ## Technical depth

  These cases run the real server process rather than calling its loop in this
  VM, because what accepted ADR 0023 fixes is a wire contract and a wire
  contract is only proved over the wire. The bytes are written literally,
  including the ones that are deliberately malformed, so what is exercised is
  the decoder a client will actually meet rather than a map this test built.

  Output is parsed the way a client must parse it: split on the newline, one
  record per line. A case that read the whole of standard output as one blob
  would pass even if the server had emitted two records on one line.
  """

  use ExUnit.Case, async: false

  alias LoopexProtocol.Session

  @generation "loopex.experimental/3"

  test "the process negotiates, then refuses a second attempt, over raw bytes" do
    [initialized, refused] =
      run([
        initialize("r1"),
        initialize("r2")
      ])

    assert initialized["type"] == "initialized"
    assert initialized["request_id"] == "r1"
    assert initialized["selected_generation"] == @generation
    assert initialized["exact_schema_sha256"] == Session.schema_digest()
    assert initialized["supported_methods"] == Session.methods()
    assert initialized["limits"]["frame_bytes"] == 1_048_576

    assert refused["type"] == "error"
    assert refused["code"] == "already_initialized"
    assert refused["request_id"] == "r2"
  end

  test "a mutation before initialization is refused, and the process still initializes after" do
    [refused, initialized] =
      run([
        ~s({"method":"session.prompt","request_id":"r1","command_id":"p1"}),
        initialize("r2")
      ])

    assert refused["type"] == "error"
    assert refused["code"] == "not_initialized"
    assert refused["request_id"] == "r1"

    assert initialized["type"] == "initialized"
    assert initialized["request_id"] == "r2"
  end

  test "no common generation refuses and spends the one attempt" do
    [refused, second] =
      run([
        ~s({"method":"initialize","request_id":"r1","generations":["loopex.session.v9-imaginary"],"capabilities":[]}),
        initialize("r2")
      ])

    assert refused["code"] == "unsupported_generation"
    assert refused["request_id"] == "r1"

    assert second["code"] == "already_initialized"
  end

  # Concept: real old and wrong-server generations are refused over stdio.
  # Technical depth: the retired name, generations one and two and the daemon's
  # /4 each spend the one attempt; later create, attach, resume and prompt
  # frames are then refused as not_initialized before any session work.
  test "real old and daemon generations are refused and fence later session frames" do
    for offer <- [
          "loopex.session.v1-experimental",
          "loopex.experimental/1",
          "loopex.experimental/2",
          "loopex.experimental/4"
        ] do
      [refused | later] =
        run([
          ~s({"method":"initialize","request_id":"old","generations":["#{offer}"],"capabilities":[]}),
          ~s({"method":"session.create","request_id":"create","command_id":"Yw","session_options":{"version":1}}),
          ~s({"method":"session.attach","request_id":"attach","session_id":"c190ZXN0XzE"}),
          ~s({"method":"session.resume","request_id":"resume","session_id":"c190ZXN0XzE","command_id":"cg"}),
          ~s({"method":"session.prompt","request_id":"prompt","command_id":"cA","content_b64":"Z28"})
        ])

      assert refused["code"] == "unsupported_generation", offer
      assert refused["request_id"] == "old"

      assert Enum.map(later, &{&1["request_id"], &1["code"]}) == [
               {"create", "not_initialized"},
               {"attach", "not_initialized"},
               {"resume", "not_initialized"},
               {"prompt", "not_initialized"}
             ]
    end
  end

  test "a malformed frame is refused uncorrelated, and the process keeps reading" do
    [invalid, duplicate, trailing, initialized] =
      run([
        ~s({"method":"initialize","request_id":),
        ~s({"request_id":"r1","request_id":"r2"}),
        ~s({"a":1} ),
        initialize("r3")
      ])

    for refusal <- [invalid, duplicate, trailing] do
      assert refusal["type"] == "error"
      assert refusal["code"] == "invalid_frame"

      # Parsing failed, so there is no identity the server may trust.
      refute Map.has_key?(refusal, "request_id")
    end

    assert initialized["type"] == "initialized"
    assert initialized["request_id"] == "r3"
  end

  test "a frame beyond the pre-initialization ceiling is refused without being read" do
    oversized =
      ~s({"method":"initialize","request_id":"r1","generations":["#{String.duplicate("g", 70_000)}"],"capabilities":[]})

    [refused, initialized] = run([oversized, initialize("r2")])

    assert refused["code"] == "invalid_frame"
    assert refused["message"] =~ "ceiling"

    # The oversized frame was not a negotiation, so the attempt is unspent.
    assert initialized["type"] == "initialized"
  end

  test "a carriage return before the newline is not a frame" do
    [refused] = run_raw(~s({"method":"initialize","request_id":"r1"}) <> "\r\n")

    assert refused["code"] == "invalid_frame"
  end

  test "input ending inside a frame starts no output and physically cleans the connection" do
    # Accepted ADR0058 stops new frames at EOF; retain truncated classification
    # independently and drive the actual partial-input cleanup over inherited fd0.
    partial = ~s({"method":"initialize")
    assert {:error, :truncated} = LoopexProtocol.Frame.decode(partial, 65_536)
    assert run_raw(partial) == []
  end

  test "every line of standard output is exactly one protocol record" do
    lines = run_lines([initialize("r1"), ~s(nonsense), initialize("r2")])

    assert length(lines) == 3

    for line <- lines do
      assert {:ok, record} = LoopexProtocol.Frame.decode(line, 2_097_152)
      assert record["type"] in Session.record_families()
      refute String.contains?(line, "\n")
    end
  end

  defp initialize(request_id) do
    ~s({"method":"initialize","request_id":"#{request_id}","generations":["#{@generation}"],"capabilities":[]})
  end

  defp run(frames), do: frames |> Enum.join("\n") |> Kernel.<>("\n") |> run_raw()

  defp run_raw(input) do
    input
    |> capture()
    |> Enum.map(fn line ->
      assert {:ok, record} = LoopexProtocol.Frame.decode(line, 2_097_152)
      record
    end)
  end

  defp run_lines(frames), do: frames |> Enum.join("\n") |> Kernel.<>("\n") |> capture()

  # Concept: consume complete records before closing the real input FIFO.
  # Technical depth: regular-file stdin would deliver EOF before an asynchronous
  # writer could join. This harness preserves exact bytes and actual EOF while
  # keeping that producer open until every requested LF reply was observed.
  defp capture(input) do
    Loopex.AppServer.ForegroundOutputHarness.with_fixture(:file, :bare, fn fixture ->
      :ok = :file.write(fixture.input, input)
      count = length(:binary.matches(input, "\n"))
      lines = Loopex.AppServer.ForegroundOutputHarness.await_lines(fixture, count)
      :ok = :file.close(fixture.input)
      summary = Loopex.AppServer.ForegroundOutputHarness.finished(fixture)
      assert summary.result == :ok
      assert summary.owner_joined
      assert summary.writer_joined
      assert File.read!(fixture.stderr) == ""
      lines
    end)
  end
end
