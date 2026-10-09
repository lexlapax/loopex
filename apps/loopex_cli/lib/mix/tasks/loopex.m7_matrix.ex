defmodule Mix.Tasks.Loopex.M7Matrix do
  @shortdoc "Records the full release matrix's own lanes in the M7 attempts index"

  @moduledoc """
  ## Concept

  The release check's recorder for one logical closure matrix. It holds the
  attempts writer for the whole invocation, admits the release lanes as one
  indexed lane, and answers the runner line by line: which lanes a resumed
  matrix already completed and must skip, and a durable `started` record before
  each lane runs. A completed lane is never run again; a started lane that did
  not pass ends the matrix.

  ## Technical depth

  `mix loopex.m7_matrix --attempts-index FILE --writer ID --host ID --markers
  DIR --matrix ID --candidate SHA --concept FILE --manifest-digest SHA256
  --run-root DIR --case KEY=SHA256 ... [--create] [--resume]` admits lane
  `release-matrix` with those ordered case pins: `:new` for a fresh matrix,
  `:continue` with `--resume`. It first writes an exclusive invocation record
  joining this invocation to the matrix, then prints `plan skip KEY` for each
  reused pass and `plan run KEY` for each remaining case, or `plan ended` or
  `refused REASON`.

  Standard input then carries `start KEY`, `finish KEY pass|fail LOG` and
  `stop KEY LOG` lines, answered by `started KEY ATTEMPT`, `finished KEY` or
  `stopped KEY`, or `refused REASON`. A start is acknowledged only after the
  synced append; each record's evidence names the invocation record and, at
  completion, the lane's retained log with its digest. End of input closes
  the writer.
  """

  use Mix.Task

  alias LoopexProtocol.Canonical
  alias Mix.Tasks.Loopex.M7Evidence.AttemptWriter

  @requirements ["compile"]
  @switches [
    attempts_index: :string,
    writer: :string,
    host: :string,
    markers: :string,
    matrix: :string,
    candidate: :string,
    concept: :string,
    manifest_digest: :string,
    run_root: :string,
    case: :keep,
    create: :boolean,
    resume: :boolean
  ]

  @impl Mix.Task
  def run(argv), do: exit({:shutdown, serve(argv, :stdio, :stdio)})

  @doc false
  def serve(argv, input, output) do
    {opts, [], []} = OptionParser.parse(argv, strict: @switches)

    with {:ok, pins} <- pins(Keyword.get_values(opts, :case)),
         {:ok, concept} <- File.read(opts[:concept] || ""),
         {:ok, writer} <- writer(opts) do
      try do
        session(writer, opts, pins, concept, input, output)
      after
        if Process.alive?(writer), do: AttemptWriter.close(writer)
      end
    else
      {:error, reason} -> reply(output, "refused #{inspect(reason)}", 2)
    end
  rescue
    _ -> reply(output, "refused invalid_matrix_arguments", 2)
  end

  defp session(writer, opts, pins, concept, input, output) do
    selection = %{
      "candidate_sha" => opts[:candidate],
      "lane_id" => "release-matrix",
      "logical_matrix_id" => opts[:matrix],
      "manifest_digest" => opts[:manifest_digest],
      "cases" => pins
    }

    mode = if opts[:resume], do: :continue, else: :new

    with {:ok, invocation} <- invocation(opts),
         {:ok, plan} <- AttemptWriter.admit(writer, concept, selection, mode) do
      # A reused lane names the digest of its retained result, which a
      # rebuilt prerequisite such as the fresh-source manifest must reproduce.
      for %{pin: pin, history: history} <- plan.reused do
        completed = Enum.find(history.records, &(&1["body"]["state"] == "completed"))

        IO.puts(
          output,
          "plan skip #{pin["case_key"]} #{List.last(completed["body"]["evidence"])["sha256"]}"
        )
      end

      for %{pin: pin} <- plan.remaining, do: IO.puts(output, "plan run #{pin["case_key"]}")
      IO.puts(output, "plan ready")
      loop(writer, selection, invocation, opts[:run_root], input, output)
    else
      {:blocked, %{reason: :lane_already_ended}} -> reply(output, "plan ended", 0)
      {_tag, %{reason: reason}} -> reply(output, "refused #{reason}", 2)
      {:error, reason} -> reply(output, "refused #{inspect(reason)}", 2)
      other -> reply(output, "refused #{inspect(other)}", 2)
    end
  end

  defp loop(writer, selection, invocation, root, input, output) do
    case IO.read(input, :line) do
      line when is_binary(line) ->
        answer =
          command(String.split(String.trim(line), " "), writer, selection, invocation, root)

        IO.puts(output, answer)

        if String.starts_with?(answer, "refused"),
          do: 2,
          else: loop(writer, selection, invocation, root, input, output)

      _ ->
        0
    end
  end

  defp command(["start", key], writer, selection, invocation, root) do
    attempt =
      "release-" <> key <> "-" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)

    with {:ok, execution} <-
           retain(root, attempt <> ".json", %{
             "attempt_id" => attempt,
             "case_key" => key,
             "matrix" => selection["logical_matrix_id"],
             "invocation" => invocation
           }),
         {:ok, _} <-
           append(writer, selection, key, "started", attempt, nil, [invocation, execution]) do
      "started #{key} #{attempt}"
    else
      error -> "refused #{inspect(error)}"
    end
  end

  defp command(["finish", key, result, log], writer, selection, invocation, _root)
       when result in ["pass", "fail"] do
    mechanical = if result == "pass", do: "pass", else: "assertion_failed"
    attempt = attempt_of(writer, key)

    with {:ok, log} <- reference(log),
         {:ok, _} <-
           append(writer, selection, key, "completed", attempt, mechanical, [invocation, log]) do
      "finished #{key}"
    else
      error -> "refused #{inspect(error)}"
    end
  end

  defp command(["stop", key, log], writer, selection, _invocation, _root) do
    # A pre-dispatch stop suspends this lane and every later one, in order.
    keys =
      selection["cases"]
      |> Enum.map(& &1["case_key"])
      |> Enum.drop_while(&(&1 != key))

    suspend = fn log ->
      Enum.reduce_while(keys, :ok, fn each, :ok ->
        state = "not_dispatched"

        case append(writer, selection, each, state, nil, "evidence_incomplete_pre_dispatch", [log]) do
          {:ok, _} -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)
    end

    with {:ok, log} <- reference(log),
         [_ | _] <- keys,
         :ok <- suspend.(log) do
      "stopped #{key}"
    else
      error -> "refused #{inspect(error)}"
    end
  end

  defp command(other, _writer, _selection, _invocation, _root),
    do: "refused #{inspect(Enum.join(other, " "))}"

  defp append(writer, selection, key, state, attempt, mechanical, evidence) do
    pin = Enum.find(selection["cases"], &(&1["case_key"] == key))

    body =
      Map.merge(
        Map.take(selection, ~w(manifest_digest candidate_sha lane_id logical_matrix_id)),
        %{
          "kind" => "case",
          "version" => 1,
          "case_key" => key,
          "subcase_key" => nil,
          "specification_digest" => pin && pin["specification_digest"],
          "attempt_id" => attempt,
          "state" => state,
          "mechanical_result" => mechanical,
          "verdict" => nil,
          "evidence" => evidence,
          "diagnosis" => nil,
          "disposition" => nil,
          "reviewer_id" => nil,
          "authorized_candidate_sha" => nil,
          "authorization_evidence" => nil
        }
      )

    AttemptWriter.append(writer, body)
  end

  defp attempt_of(writer, key) do
    {:ok, bytes} = AttemptWriter.read(writer)

    bytes
    |> String.split("\n", trim: true)
    |> Enum.map(&JSON.decode!/1)
    |> Enum.filter(&(&1["body"]["case_key"] == key and &1["body"]["state"] == "started"))
    |> List.last()
    |> case do
      nil -> nil
      record -> record["body"]["attempt_id"]
    end
  end

  # Concept: every invocation of one matrix leaves its own joined record.
  # Technical depth: the record names the matrix, candidate and argv-free
  # identity of this invocation; it is created exclusively under the run root.
  defp invocation(opts) do
    name = "invocation-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower) <> ".json"

    retain(opts[:run_root], name, %{
      "matrix" => opts[:matrix],
      "candidate" => opts[:candidate],
      "resume" => opts[:resume] == true,
      "started_at_ms" => System.system_time(:millisecond)
    })
  end

  defp pins(values) do
    pins =
      Enum.map(values, fn value ->
        [key, digest] = String.split(value, "=", parts: 2)
        %{"case_key" => key, "subcase_key" => nil, "specification_digest" => digest}
      end)

    if pins != [], do: {:ok, pins}, else: {:error, :no_matrix_cases}
  end

  defp writer(opts) do
    identity = %{
      "writer_id" => opts[:writer],
      "host_id" => opts[:host],
      "marker_dir" => opts[:markers]
    }

    if opts[:create],
      do: AttemptWriter.create(opts[:attempts_index], campaign(), identity),
      else: AttemptWriter.open(opts[:attempts_index], identity)
  end

  defp campaign do
    {:ok, catalog} =
      Mix.Tasks.Loopex.M7Evidence.FixtureManifest.load(Path.join(File.cwd!(), "test/fixtures/m7"))

    catalog.catalog["execution_manifest"]["campaign_id"]
  end

  defp reference(path) do
    with true <- is_binary(path) and Path.type(path) == :absolute,
         {:ok, bytes} <- File.read(path) do
      {:ok, %{"reference" => path, "sha256" => Canonical.digest_bytes(bytes)}}
    else
      _ -> {:error, :lane_log_unavailable}
    end
  end

  defp retain(root, name, value) do
    path = Path.join(root, name)
    {:ok, encoded} = LoopexProtocol.Frame.encode(value)
    bytes = IO.iodata_to_binary(encoded)

    with :ok <- File.mkdir_p(root), :ok <- File.write(path, bytes, [:exclusive]) do
      {:ok, %{"reference" => path, "sha256" => Canonical.digest_bytes(bytes)}}
    end
  end

  defp reply(output, line, status) do
    IO.puts(output, line)
    status
  end
end
