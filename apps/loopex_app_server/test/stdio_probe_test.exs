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

  @generation "loopex.session.v1-experimental"

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

  test "input ending inside a frame is reported before the process stops" do
    [refused] = run_raw(~s({"method":"initialize"))

    assert refused["code"] == "invalid_frame"
    assert refused["message"] =~ "ended inside a frame"
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

  # Concept: the server as the operator launches it, fed exact bytes.
  #
  # Technical depth: the input is written to a file and piped in, so the bytes
  # arrive exactly as written with no shell quoting between the case and the
  # decoder. Standard error is kept separate: a case that merged the two streams
  # could not tell a protocol record from a diagnostic, which is the very
  # separation being proved.
  defp capture(input) do
    directory =
      Path.join(System.tmp_dir!(), "loopex-stdio-#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf(directory) end)

    input_path = Path.join(directory, "input")
    output_path = Path.join(directory, "output")
    File.write!(input_path, input)

    script = Path.join(directory, "run.sh")

    File.write!(script, """
    #!/bin/sh
    exec "$1" -pa "$2" -pa "$3" -e 'Loopex.AppServer.Stdio.main([])' < "$4" > "$5"
    """)

    File.chmod!(script, 0o755)

    {_output, 0} =
      System.cmd(
        "/bin/sh",
        [
          script,
          System.find_executable("elixir") || flunk("Elixir executable unavailable"),
          ebin(:loopex_protocol),
          ebin(:loopex_app_server),
          input_path,
          output_path
        ],
        # The server owns standard input, so the machine must not.
        env: [{"ELIXIR_ERL_OPTIONS", "-noinput"}],
        stderr_to_stdout: false
      )

    output_path |> File.read!() |> String.split("\n", trim: true)
  end

  defp ebin(application) do
    path = Application.app_dir(application, "ebin")
    assert File.dir?(path)
    path
  end
end
