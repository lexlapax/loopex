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

  @green_verdict "M0 gate GREEN"
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
        case recorded_rows(contents, record) do
          {:error, reason} ->
            {:error, "#{reason}; the matrix record cannot be read as retained runs"}

          {:ok, rows} ->
            case Enum.reject(pairs, &records_pair?(rows, &1)) do
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

  # Concept: the runs this check counts are the rows a reader sees in the table.
  #
  # Technical depth: this was narrowed four times and evaded four times -- the
  # major satisfied an exact lock; "whole token" excluded digits and dots, so a
  # prerelease suffix walked through; `contains?("GREEN")` accepted "NOT GREEN";
  # and parsing the row still parsed a RAW line, so fields hidden inside an inline
  # HTML comment were read as if visible while a reader saw an empty cell.
  #
  # Every one of those was a filter added to reject the last example. The rule is
  # not a filter: read the table the reader reads. Lines the Markdown reader calls
  # hidden are dropped, each surviving line is reduced to what it actually exposes,
  # and the result must be an exact table under the declared header -- byte-for-byte
  # header and separator, exact column count, no empty cells. A row whose fields
  # live inside a comment exposes an empty cell and is refused as malformed rather
  # than parsed.
  #
  # The verdict is required as plain text rather than a code span, because
  # exposing a line removes code-span content too. That is stricter, not looser: a
  # verdict written inside a code span now exposes an empty cell and is refused,
  # so there is no markup in which a verdict can sit and still count.
  #
  # There is no next construction to enumerate, because nothing is being searched
  # for and nothing hidden survives to be parsed.
  @table_header ["#", "Order", "Toolchain", "Verdict", "Exit", "Wall clock"]

  # The Markdown reader raises on a document it cannot read -- an unclosed comment
  # or fence, for instance -- and that is a reason the record cannot be trusted,
  # not a crash to let out of a check. Rescued here so the gate reports why.
  defp recorded_rows(contents, path) do
    read_rows(contents, path)
  rescue
    error in [Loopex.Checks.Invalid] -> {:error, Exception.message(error)}
  end

  defp read_rows(contents, path) do
    lines = Markdown.lines(contents, path)
    visible = Markdown.visible_line_numbers(contents, path)

    exposed =
      lines
      |> Enum.with_index()
      |> Enum.filter(fn {_line, number} -> MapSet.member?(visible, number) end)
      |> Enum.map(fn {line, _number} -> Markdown.exposed_line(line) end)

    header = "| " <> Enum.join(@table_header, " | ") <> " |"

    case Enum.find_index(exposed, &(&1 == header)) do
      nil ->
        {:error, "#{path}: no visible #{Enum.join(@table_header, " | ")} table"}

      at ->
        exposed
        |> Enum.drop(at)
        |> Enum.take_while(&String.starts_with?(&1, "|"))
        |> parse_table(path)
    end
  end

  # `Markdown.table/3` raises on a malformed row rather than skipping it, which is
  # the behaviour wanted here: a row that cannot be read is not a row that passed.
  defp parse_table(lines, path), do: {:ok, Markdown.table(lines, @table_header, path)}

  defp records_pair?(rows, pair) do
    Enum.any?(rows, fn
      [number, order, toolchain, verdict, exit_code | _rest] ->
        numbered?(number) and order != "" and
          toolchain_matches?(toolchain, pair) and
          verdict == @green_verdict and
          exit_code == "0"

      _other ->
        false
    end)
  end

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

  # A recorded run is numbered. The cells are already exposed and trimmed by the
  # table reader, so these compare exact values rather than search text.
  defp numbered?(cell), do: Regex.match?(~r/\A[0-9]+\z/, cell)

  # The toolchain cell names both exact versions and nothing else that could be
  # mistaken for them. `erts-` is allowed to follow because the rows carry it.
  defp toolchain_matches?(cell, pair) do
    case Regex.run(~r/\AElixir (\S+) \/ OTP (\S+?)(?: erts-\S+)?\z/, cell) do
      [_all, elixir, otp] -> elixir == pair.elixir and otp == pair.otp_exact
      _other -> false
    end
  end

  defp describe(pairs) do
    pairs
    |> Enum.map(fn pair -> "Elixir #{pair.elixir} / OTP #{pair.otp_exact}" end)
    |> Enum.join(" and ")
  end
end
