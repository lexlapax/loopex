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
  Comparison is on the Elixir version and the OTP major release, because
  `System.otp_release/0` reports the major only; the recorded Erlang patch is for
  the version manager, not for this assertion, and the check says so rather than
  pretending to verify it.
  """

  use Mix.Task

  @tool_versions ".tool-versions"
  alias Loopex.Checks.Markdown

  @green_verdict "GREEN"
  @matrix_evidence "docs/evidence/M0-toolchain-matrix.md"

  @impl Mix.Task
  def run(_args) do
    case check(File.cwd!()) do
      {:ok, pair} ->
        Mix.shell().info(
          "running toolchain matches locked pair Elixir #{pair.elixir} / OTP #{pair.otp_exact}"
        )

      {:error, reason} ->
        Mix.raise("toolchain matrix is not satisfied: #{reason}")
    end
  end

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
      parsed = Enum.map(inner, &Regex.named_captures(@run_format, &1))

      cond do
        inner == [] ->
          {:error, "#{path}: the recorded-runs block names no run"}

        Enum.any?(parsed, &is_nil/1) ->
          {:error, "#{path}: a recorded run is not in the required form"}

        true ->
          {:ok, parsed}
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
  defp fenced_body(lines, path) do
    case Enum.drop_while(lines, &blank?/1) |> Enum.reverse() |> Enum.drop_while(&blank?/1) do
      [] ->
        {:error, "#{path}: the recorded-runs block is empty"}

      [last | reversed_rest] ->
        [open | inner] = Enum.reverse([last | reversed_rest])
        close_fenced(open, inner, last, path)
    end
  end

  # Concept: the closing fence and the absence of inner fences are checked here
  # too, deliberately, even though the Markdown scan already rejects them.
  #
  # Technical depth: mutation-checking shows both are currently redundant --
  # `visible_line_numbers/2` raises on an unclosed construct, and a mismatched
  # delimiter or an info-stringed closer leaves the fence open, so the block never
  # reaches this function. A redundant guard was removed elsewhere in this module
  # for good reason, and the difference is worth stating: that one duplicated an
  # equality check three lines below it, while these depend on an incidental
  # property of ANOTHER module. If that scan ever stops raising, the premise this
  # design rests on would fail silently rather than loudly. This boundary has been
  # evaded eight times; the cheap local check stays.
  defp close_fenced(open, inner, last, path) do
    with {:ok, char, len} <- fence_open(open),
         true <- inner != [],
         true <- fence_close?(last, char, len),
         body = Enum.drop(inner, -1),
         false <- Enum.any?(body, &fence_line?/1) do
      {:ok, body}
    else
      _other ->
        {:error,
         "#{path}: the recorded-runs block must be exactly one fenced block, " <>
           "so a reader sees the runs verbatim"}
    end
  end

  defp blank?(line), do: String.trim(line) == ""

  defp fence_line?(line), do: String.match?(line, ~r/\A\s{0,3}(`{3,}|~{3,})/)

  # An opening fence is a run of at least three backticks or tildes with at most a
  # simple info string. Anything else is not a fence a reader will see as one.
  defp fence_open(line) do
    case Regex.run(~r/\A(`{3,}|~{3,})([A-Za-z0-9]*)\z/, String.trim_trailing(line)) do
      [_all, delim, _info] -> {:ok, String.first(delim), String.length(delim)}
      _other -> :error
    end
  end

  # A closing fence matches the opener's character and is at least as long, and
  # carries no info string.
  defp fence_close?(line, char, len) do
    case Regex.run(~r/\A(`{3,}|~{3,})\z/, String.trim_trailing(line)) do
      [_all, delim] -> String.first(delim) == char and String.length(delim) >= len
      _other -> false
    end
  end

  # Concept: a run line is one exact form or it is not a run.
  #
  # Technical depth: no separate printable-character guard. Earlier versions needed
  # one because a non-breaking or zero-width character could occupy a cell while
  # rendering as nothing. Here every field is compared by equality against an exact
  # expected value rather than searched, so a field carrying an invisible character
  # simply is not equal to the value it imitates. Mutation-checking found the guard
  # broke no case, and a redundant rule in a check like this is one a reader has to
  # verify is not the load-bearing one.

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

  # Concept: an elixir line carries both the Elixir version and the OTP major it
  # is built against, which is exactly the pair ADR 0002 validates.
  # Each pair is an elixir line followed by the erlang line beside it. The elixir
  # line names the OTP MAJOR it was built against; the erlang line names the exact
  # version, and that exact version is what the lock actually promises.
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
