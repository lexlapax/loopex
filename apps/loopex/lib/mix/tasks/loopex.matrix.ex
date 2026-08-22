defmodule Mix.Tasks.Loopex.Matrix do
  @shortdoc "Proves the running toolchain is a locked pair and both pairs are recorded"

  @moduledoc """
  ## Concept

  ADR 0002 fixes the toolchain as two validated (Elixir, OTP) pairs rather than a
  cross-product. This confirms the toolchain actually running is one of them, and
  that both pairs are still recorded in `.tool-versions`.

  ## Technical depth

  One Mix run has one Erlang runtime, so a single invocation cannot prove both
  pairs. It proves the pair it is running under; the gate runner invokes it once
  per pair and records both runs. That division is deliberate — a task that
  claimed to have verified a pair it never ran on would be reporting a wish.

  `.tool-versions` is the bound artifact, so its bytes are digested by the gate.
  Comparison is exact for both Elixir and OTP: the full OTP version comes from
  the installation's `OTP_VERSION`, because `System.otp_release/0` reports only
  the major. If that file is unavailable, the major cannot satisfy either exact
  locked version.
  """

  use Mix.Task

  @tool_versions ".tool-versions"
  alias Loopex.Checks.Markdown

  @green_verdict "GREEN"
  @matrix_evidence "docs/evidence/M0-toolchain-matrix.md"

  @impl Mix.Task
  def run([]) do
    case check(File.cwd!()) do
      {:ok, pair} ->
        Mix.shell().info(
          "running toolchain matches locked pair Elixir #{pair.elixir} / OTP #{pair.otp_exact}"
        )

      {:error, reason} ->
        Mix.raise("toolchain matrix is not satisfied: #{reason}")
    end
  end

  def run(_args),
    do: Mix.raise("usage: mix loopex.matrix")

  @doc """
  ## Concept

  Confirms `.tool-versions` records exactly two pairs and that the running
  toolchain is one of them.

  ## Technical depth

  Returns the matched pair so a caller can record which lane ran. A file that
  records one pair, three pairs, or a malformed line is an error rather than a
  partial pass: the accepted rule is two validated pairs, and anything else means
  the lock no longer says what ADR 0002 requires.
  """
  @spec check(Path.t()) ::
          {:ok, %{elixir: String.t(), otp: String.t(), otp_exact: String.t()}}
          | {:error, String.t()}
  def check(root) do
    path = Path.join(root, @tool_versions)

    with {:ok, contents} <- read(path),
         {:ok, pairs} <- pairs(contents, path) do
      running = %{elixir: System.version(), otp: exact_otp_version()}

      with matched when is_map(matched) <- Enum.find(pairs, &pair_matches?(&1, running)),
           :ok <- both_lanes_recorded(root, pairs) do
        {:ok, matched}
      else
        nil ->
          {:error,
           "running Elixir #{running.elixir} / OTP #{running.otp} is not a locked pair; " <>
             "#{path} records #{describe(pairs)}"}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  ## Concept

  Confirms the retained matrix record names every locked pair as run.

  ## Technical depth

  One Mix run has one Erlang runtime, so this task can only prove the pair it is
  running under. The gate nevertheless claims both pairs are recorded as run, and
  without this check that claim rested on nothing: deleting or staling the retained
  record would not have failed anything. This does not verify that a recorded run
  happened — only review can judge that — but a missing or incomplete record now
  fails rather than passing silently.
  """
  @spec both_lanes_recorded(
          Path.t(),
          [%{elixir: String.t(), otp: String.t(), otp_exact: String.t()}]
        ) :: :ok | {:error, String.t()}
  def both_lanes_recorded(root, pairs) do
    record = Path.join(root, @matrix_evidence)

    case File.read(record) do
      {:error, posix} ->
        {:error, "#{record}: #{:file.format_error(posix)}; the matrix record is unavailable"}

      {:ok, contents} ->
        case recorded_runs(contents, record) do
          {:error, reason} ->
            {:error, "#{reason}; the matrix record cannot be read as retained runs"}

          {:ok, runs} ->
            case Enum.reject(pairs, &records_pair?(runs, &1)) do
              [] ->
                :ok

              missing ->
                {:error,
                 "#{record} does not record a run for #{describe(missing)}; " <>
                   "the gate claims both locked pairs are recorded"}
            end
        end
    end
  end

  # Concept: the runs are recorded where a reader and a parser cannot disagree.
  #
  # Technical depth: this boundary was rejected seven times, and every fix was the
  # same mistake in a new place -- comparing against a hand-written approximation
  # of how Markdown renders. The major satisfied an exact lock. "Whole token"
  # excluded digits and dots, so a prerelease suffix passed. `contains?("GREEN")`
  # accepted "NOT GREEN". Parsing the row parsed a RAW line, so a comment hid
  # fields. Reducing with `exposed_line/1` let a code span DELETE text. Then
  # stripping every backtick mis-modelled nested code spans, and comparing an
  # undecoded header let `&#35;` render as `#` and smuggle in a second table.
  #
  # Each of those was a narrowing, and each held until the next construction,
  # because reimplementing CommonMark well enough to predict a reader is not a
  # thing this check should be attempting. So it stops attempting it.
  #
  # The runs live in a fenced block between governed markers. Content inside a
  # fence renders verbatim -- CommonMark gives it no inline structure at all, so
  # backticks, entities, and comment syntax are literal characters both to a
  # reader and to this parser. There is nothing to render, so there is nothing to
  # disagree about. `Markdown.block/4` supplies the block and already requires the
  # marker pair to occur exactly once on governed lines, so a commented-out or
  # fenced copy cannot supply a second one.
  @run_format ~r/\Arun=(?<run>[0-9]+) order=(?<order>[a-z]+) elixir=(?<elixir>\S+) otp=(?<otp>\S+) erts=(?<erts>\S+) verdict=(?<verdict>\S+) exit=(?<exit>[0-9]+) wall=(?<wall>\S+)\z/

  defp recorded_runs(contents, path) do
    read_runs(contents, path)
  rescue
    error in [Loopex.Checks.Invalid] -> {:error, Exception.message(error)}
  end

  defp read_runs(contents, path) do
    with {:ok, inner} <- fenced_body(Markdown.block(contents, path, :matrix_runs), path) do
      cond do
        inner == [] ->
          {:error, "#{path}: the recorded-runs block names no run"}

        Enum.any?(inner, &(not printable_ascii?(&1))) ->
          {:error, "#{path}: a recorded run contains a non-printable or non-ASCII byte"}

        Enum.any?(inner, &(not Regex.match?(@run_format, &1))) ->
          {:error, "#{path}: a recorded run is not in the required form"}

        true ->
          {:ok, Enum.map(inner, &Regex.named_captures(@run_format, &1))}
      end
    end
  end

  # Concept: the records must actually be inside the fence, not merely near it.
  #
  # Technical depth: the previous version discarded fence-looking lines and parsed
  # whatever was left, which asserted the fenced-verbatim premise in a comment and
  # never checked it. Unfenced records between the markers parsed fine, so
  # `erts=14.0<!-- verdict=GREEN exit=0 wall=91s-->` recorded a green zero-exit run
  # that a reader never sees: outside a fence the comment is a comment again, and
  # every guarantee this design rests on evaporates.
  #
  # The interior is therefore required to be exactly one fenced block: an opening
  # fence, run lines, a closing fence of the same character and at least the same
  # length, and nothing else. A premise the parser depends on is checked by the
  # parser.
  # Concept: the records begin inside a fence, and every line parsed is a run.
  #
  # Technical depth: only the opening fence needs a check of its own. A closing
  # fence that is missing or mismatched leaves the construct unclosed, and the
  # Markdown scan refuses to read a document it cannot close. Anything else stray
  # between the markers -- a record after the closer, a second fence, a comment
  # line -- lands in the parsed region and fails to parse as a run, because every
  # parsed line must match the run form exactly.
  #
  # An earlier version also checked the closing fence and scanned for inner fences.
  # Mutation-checking showed both were dead: stubbing each changed nothing, and
  # stubbing BOTH still changed nothing -- which is the check that matters, because
  # two overlapping guards mask each other and each looks load-bearing alone. They
  # are gone rather than kept behind a paragraph explaining why they might be
  # useful, so every rule left here is one a case can prove.
  defp fenced_body(lines, path) do
    case trim_blanks(lines) do
      [open | rest] when rest != [] ->
        case fence_open(open) do
          :ok ->
            {:ok, Enum.drop(rest, -1)}

          :error ->
            {:error,
             "#{path}: the recorded-runs block must open with a fence, " <>
               "so a reader sees the runs verbatim"}
        end

      _too_short ->
        {:error, "#{path}: the recorded-runs block has no fenced body"}
    end
  end

  defp trim_blanks(lines) do
    lines
    |> Enum.drop_while(&blank?/1)
    |> Enum.reverse()
    |> Enum.drop_while(&blank?/1)
    |> Enum.reverse()
  end

  defp blank?(line), do: String.trim(line) == ""

  # The retained record uses a canonical column-zero opening fence: a run of at
  # least three backticks or tildes with at most a simple info string. Supporting
  # every CommonMark-equivalent indentation is unnecessary for this governed file.
  defp fence_open(line) do
    if Regex.match?(~r/\A(`{3,}|~{3,})[A-Za-z0-9]*\z/, String.trim_trailing(line)),
      do: :ok,
      else: :error
  end

  # Concept: a run line is one exact form or it is not a run.
  #
  # Technical depth: fenced Markdown removes inline interpretation, but it does not
  # neutralise Unicode display controls. `erts` and `wall` are retained audit fields
  # rather than equality-checked lock fields, so a right-to-left override in either
  # could reorder the displayed verdict and exit while the parser read their original
  # byte order. A closed printable-ASCII domain removes that disagreement without a
  # blacklist of individual Unicode spellings.
  defp printable_ascii?(line) do
    line
    |> :binary.bin_to_list()
    |> Enum.all?(&(&1 in 0x20..0x7E))
  end

  # Concept: every recorded run passed, and this pair is among them.
  #
  # Technical depth: asking only whether SOME run recorded this pair green let a
  # failing run sit beside a passing one and be ignored. The block records the
  # runs taken at this candidate and the gate claims they were green, so a run
  # that is not a green zero-exit run contradicts the claim wherever it appears.
  defp records_pair?(runs, pair) do
    Enum.all?(runs, &green_run?/1) and Enum.any?(runs, &names_pair?(&1, pair))
  end

  defp green_run?(run), do: run["verdict"] == @green_verdict and run["exit"] == "0"

  defp names_pair?(run, pair), do: run["elixir"] == pair.elixir and run["otp"] == pair.otp_exact

  @doc """
  ## Concept

  The exact OTP version, not just its major release.

  ## Technical depth

  `System.otp_release/0` returns the major only, so comparing against it let any
  26.x satisfy a lock that names 26.0 — the gate documented exact pairs while the
  check enforced a family. The installation records the full version in its
  release directory, which is the same string `.tool-versions` carries.

  When that file is missing the major is returned and the caller says so, because
  reporting a major as though it were exact is the failure this exists to prevent.
  """
  @spec exact_otp_version() :: String.t()
  def exact_otp_version do
    major = System.otp_release()
    path = Path.join([to_string(:code.root_dir()), "releases", major, "OTP_VERSION"])

    case File.read(path) do
      {:ok, contents} -> String.trim(contents)
      {:error, _posix} -> major
    end
  end

  defp read(path) do
    case File.read(path) do
      {:ok, contents} -> {:ok, contents}
      {:error, posix} -> {:error, "#{path}: #{:file.format_error(posix)}"}
    end
  end

  # Concept: each locked pair is represented by an Elixir line and its adjacent
  # Erlang line.
  # Technical depth: the Elixir line supplies the Elixir version and build-target
  # OTP major; the adjacent Erlang line supplies the exact OTP version used by the
  # lock and runtime comparison.
  defp pairs(contents, path) do
    lines =
      contents
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))

    parsed = collect_pairs(lines, [])

    cond do
      parsed == :error ->
        {:error, "#{path} has an elixir line not followed by its erlang line"}

      length(parsed) != 2 ->
        {:error,
         "#{path} records #{length(parsed)} elixir pair(s); ADR 0002 requires exactly two"}

      true ->
        {:ok, parsed}
    end
  end

  defp collect_pairs([], accumulated), do: Enum.reverse(accumulated)

  defp collect_pairs(["elixir " <> spec | rest], accumulated) do
    with %{elixir: elixir, otp: major} <- parse_elixir_line("elixir " <> spec),
         ["erlang " <> exact | tail] <- rest do
      pair = %{elixir: elixir, otp: major, otp_exact: String.trim(exact)}
      collect_pairs(tail, [pair | accumulated])
    else
      _other -> :error
    end
  end

  defp collect_pairs([_other | rest], accumulated), do: collect_pairs(rest, accumulated)

  defp parse_elixir_line("elixir " <> spec) do
    case String.split(spec, "-otp-") do
      [elixir, otp] when elixir != "" and otp != "" ->
        %{elixir: String.trim(elixir), otp: String.trim(otp)}

      _other ->
        :error
    end
  end

  # The elixir line carries the OTP MAJOR it was built against; the erlang line
  # beside it carries the exact version. A pair matches when the Elixir version is
  # identical, the running major matches the pair's major, and the running exact
  # version matches the exact version the lock records. Comparing the major alone
  # accepted any patch in the family while the gate claimed exact pairs.
  defp pair_matches?(pair, running) do
    pair.elixir == running.elixir and
      major_of(pair.otp_exact) == major_of(running.otp) and
      pair.otp_exact == running.otp
  end

  defp major_of(version), do: version |> String.split(".") |> hd()

  defp describe(pairs) do
    pairs
    |> Enum.map(fn pair -> "Elixir #{pair.elixir} / OTP #{pair.otp_exact}" end)
    |> Enum.join(" and ")
  end
end
