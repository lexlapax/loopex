defmodule LoopexCli.M7MatrixTest do
  use ExUnit.Case, async: true

  # Concept: the release check's matrix recorder skips completed lanes on
  # resume, never reruns a completed or failed lane, and joins every
  # invocation to the one matrix. Technical depth: real index files and the
  # real writer lock; standard input and output are in-memory devices.

  alias Mix.Tasks.Loopex.M7Evidence.{AttemptEvents, AttemptWriter}
  alias Mix.Tasks.Loopex.M7Matrix

  @candidate String.duplicate("1", 40)
  @digest String.duplicate("0", 64)

  setup do
    root = Path.join(System.tmp_dir!(), "m7-matrix-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "markers"))
    on_exit(fn -> File.rm_rf!(root) end)
    index = Path.join(root, "attempts.jsonl")
    identity = %{"writer_id" => "w", "host_id" => "h", "marker_dir" => Path.join(root, "markers")}
    {:ok, writer} = AttemptWriter.create(index, "m7-closure-1", identity)
    :ok = AttemptWriter.close(writer)
    [_, designation] = records(index)
    concept = Path.join(root, "M7.md")
    File.write!(concept, "index-head: m7-closure-1 2 #{designation["digest"]}\n")
    log = Path.join(root, "lane.log")
    File.write!(log, "lane output\n")
    %{root: root, index: index, concept: concept, log: log}
  end

  test "a stopped matrix resumes by skipping completed lanes and never reruns them", f do
    assert {0, out} =
             serve(f, "matrix-1", [], "start a\nfinish a pass #{f.log}\nstop b #{f.log}\n")

    assert Enum.take(out, 4) == ["plan run a", "plan run b", "plan run c", "plan ready"]
    assert Enum.at(out, 4) =~ ~r/\Astarted a release-a-[0-9a-f]{8}\z/
    assert "finished a" in out and "stopped b" in out

    assert states(f.index) == [
             {"a", "started"},
             {"a", "completed"},
             {"b", "not_dispatched"},
             {"c", "not_dispatched"}
           ]

    input = "start a\n"
    assert {2, resumed} = serve(f, "matrix-1", ["--resume"], input)
    assert Enum.take(resumed, 4) == ["plan skip a", "plan run b", "plan run c", "plan ready"]
    assert List.last(resumed) =~ "refused"

    input = "start b\nfinish b pass #{f.log}\nstart c\nfinish c pass #{f.log}\n"
    assert {0, finished} = serve(f, "matrix-1", ["--resume"], input)
    assert "finished c" in finished
    assert {0, ["plan ended"]} = serve(f, "matrix-1", ["--resume"], "")

    started = for {key, "started"} <- states(f.index), do: key
    assert started == ["a", "b", "c"]
    invocations = Path.wildcard(Path.join([f.root, "runs", "invocation-*.json"]))
    assert length(invocations) == 4
  end

  test "a failed lane ends the matrix and a fresh matrix on the candidate refuses", f do
    assert {0, _} = serve(f, "matrix-1", [], "start a\nfinish a fail #{f.log}\n")
    assert {2, resumed} = serve(f, "matrix-1", ["--resume"], "")
    assert List.last(resumed) =~ "refused consumed_lane_failure"
    assert {2, fresh} = serve(f, "matrix-2", [], "")
    assert List.last(fresh) =~ "refused fresh_matrix_already_consumed"
  end

  test "unknown lanes, missing logs and absent arguments refuse", f do
    assert {2, out} = serve(f, "matrix-1", [], "start zzz\n")
    assert List.last(out) =~ "refused"
    assert {2, out} = serve(f, "matrix-1", [], "start a\nfinish a pass relative.log\n")
    assert List.last(out) =~ "refused"
    {:ok, output} = StringIO.open("")
    {:ok, input} = StringIO.open("")
    assert M7Matrix.serve(["--matrix", "m"], input, output) == 2
  end

  defp serve(f, matrix, extra, input) do
    {:ok, input} = StringIO.open(input)
    {:ok, output} = StringIO.open("")

    argv =
      [
        "--attempts-index",
        f.index,
        "--writer",
        "w",
        "--host",
        "h",
        "--markers",
        Path.join(f.root, "markers"),
        "--matrix",
        matrix,
        "--candidate",
        @candidate,
        "--concept",
        f.concept,
        "--manifest-digest",
        @digest,
        "--run-root",
        Path.join(f.root, "runs")
      ] ++ Enum.flat_map(~w(a b c), &["--case", "#{&1}=#{@digest}"]) ++ extra

    status = M7Matrix.serve(argv, input, output)
    {_, text} = StringIO.contents(output)
    {status, String.split(text, "\n", trim: true)}
  end

  defp states(index),
    do:
      for(
        r <- records(index),
        r["body"]["kind"] == "case",
        do: {r["body"]["case_key"], r["body"]["state"]}
      )

  defp records(index) do
    index
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(fn line ->
      {:ok, record} = AttemptEvents.decode(line)
      record
    end)
  end
end
