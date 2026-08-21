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
  Comparison is exact for both Elixir and OTP: the OTP patch comes from the
  installation's `OTP_VERSION`, because `System.otp_release/0` reports only the
  major. If that file is unavailable the major cannot satisfy an exact lock.
  """

  use Mix.Task

  @tool_versions ".tool-versions"
  alias Loopex.Checks.Git
  alias Loopex.Checks.Markdown

  @green_verdict "GREEN"
  @matrix_evidence "docs/evidence/M0-toolchain-matrix.md"
  @m1_matrix_evidence "docs/evidence/M1-toolchain-matrix.md"
  @m1_gate "docs/plans/M1-gate.md"
  @m1_command "bash:scripts/check-m1-gate.sh"
  @m1_orders ~w(first second third fourth fifth)

  @impl Mix.Task
  def run(args) do
    {evidence, profile} = invocation!(args)

    case check(File.cwd!(), evidence: evidence, profile: profile) do
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
    check(root, evidence: @matrix_evidence, profile: :m0)
  end

  @doc """
  ## Concept

  Confirms one explicitly selected milestone matrix record as well as the
  running pair.

  ## Technical depth

  The no-argument form remains the closed M0 contract. M1 names both its evidence
  path and its profile at the command boundary so a later milestone cannot pass
  by silently reading M0's retained rows. The profile selects additional
  structure; it never weakens the exact-pair comparison.
  """
  @spec check(Path.t(), keyword()) ::
          {:ok, %{elixir: String.t(), otp: String.t(), otp_exact: String.t()}}
          | {:error, String.t()}
  def check(root, options) do
    evidence = Keyword.fetch!(options, :evidence)
    profile = Keyword.fetch!(options, :profile)
    path = Path.join(root, @tool_versions)

    with {:ok, contents} <- read(path),
         {:ok, pairs} <- pairs(contents, path) do
      running = %{elixir: System.version(), otp: exact_otp_version()}

      with matched when is_map(matched) <- Enum.find(pairs, &pair_matches?(&1, running)),
           :ok <- both_lanes_recorded(root, pairs, evidence, profile) do
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
    both_lanes_recorded(root, pairs, @matrix_evidence, :m0)
  end

  @doc """
  ## Concept

  Confirms a named retained matrix record satisfies its milestone profile.

  ## Technical depth

  M0 retains its original presence rule. M1 additionally binds one reachable
  candidate whose committed gate, the current gate, and the recorded gate digest
  are identical, then requires the minimal five-run walk whose four adjacent
  edges are floor-to-floor, floor-to-current, current-to-floor, and
  current-to-current. Exact run numbering, order labels, numeric seeds, and
  positive executed counts bind the claim to physical lines.
  """
  @spec both_lanes_recorded(
          Path.t(),
          [%{elixir: String.t(), otp: String.t(), otp_exact: String.t()}],
          String.t(),
          :m0 | :m1
        ) :: :ok | {:error, String.t()}
  def both_lanes_recorded(root, pairs, evidence, profile) do
    record = Path.join(root, evidence)

    case File.read(record) do
      {:error, posix} ->
        {:error, "#{record}: #{:file.format_error(posix)}; the matrix record is unavailable"}

      {:ok, contents} ->
        case recorded_runs(contents, record, profile, root) do
          {:error, reason} ->
            {:error, "#{reason}; the matrix record cannot be read as retained runs"}

          {:ok, runs} ->
            validate_runs(runs, pairs, profile, record)
        end
    end
  end

  defp invocation!([]), do: {@matrix_evidence, :m0}

  defp invocation!(["--evidence", @m1_matrix_evidence, "--profile", "m1"]),
    do: {@m1_matrix_evidence, :m1}

  defp invocation!(_args) do
    Mix.raise("usage: mix loopex.matrix [--evidence #{@m1_matrix_evidence} --profile m1]")
  end

  defp validate_runs(runs, pairs, :m0, record) do
    case Enum.reject(pairs, &records_pair?(runs, &1)) do
      [] ->
        :ok

      missing ->
        {:error,
         "#{record} does not record a run for #{describe(missing)}; " <>
           "the gate claims both locked pairs are recorded"}
    end
  end

  defp validate_runs(runs, pairs, :m1, record) do
    expected_edges =
      MapSet.new([{:floor, :floor}, {:floor, :current}, {:current, :floor}, {:current, :current}])

    with :ok <- all_green(runs, record),
         :ok <- exact_m1_sequence(runs, record),
         {:ok, lanes} <- identify_lanes(runs, pairs, record),
         :ok <- exact_adjacencies(lanes, expected_edges, record) do
      :ok
    end
  end

  defp validate_runs(_runs, _pairs, profile, record),
    do: {:error, "#{record}: unknown matrix evidence profile #{inspect(profile)}"}

  defp all_green(runs, record) do
    case Enum.find_index(runs, &(not green_run?(&1))) do
      nil -> :ok
      index -> {:error, "#{record}: run #{index + 1} is not GREEN with exit 0"}
    end
  end

  defp exact_m1_sequence(runs, record) do
    expected_numbers = Enum.map(1..5, &Integer.to_string/1)

    cond do
      length(runs) != 5 ->
        {:error, "#{record}: M1 requires exactly five retained runs"}

      Enum.map(runs, & &1["run"]) != expected_numbers ->
        {:error, "#{record}: M1 run numbers must be 1 through 5 in physical order"}

      Enum.map(runs, & &1["order"]) != @m1_orders ->
        {:error, "#{record}: M1 order fields must be first through fifth in physical order"}

      true ->
        :ok
    end
  end

  defp identify_lanes(runs, [floor, current], record) do
    Enum.reduce_while(runs, {:ok, []}, fn run, {:ok, lanes} ->
      lane =
        cond do
          names_pair?(run, floor) -> :floor
          names_pair?(run, current) -> :current
          true -> nil
        end

      case lane do
        nil ->
          {:halt, {:error, "#{record}: run #{run["run"]} does not name either exact locked pair"}}

        value ->
          {:cont, {:ok, [value | lanes]}}
      end
    end)
    |> case do
      {:ok, lanes} -> {:ok, Enum.reverse(lanes)}
      error -> error
    end
  end

  defp identify_lanes(_runs, _pairs, record),
    do: {:error, "#{record}: M1 adjacency evidence requires exactly two locked pairs"}

  defp exact_adjacencies(lanes, expected, record) do
    actual = lanes |> Enum.zip(Enum.drop(lanes, 1)) |> MapSet.new()

    case actual == expected do
      true -> :ok
      false -> {:error, "#{record}: M1 runs do not cover all four locked-pair adjacencies"}
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
  @m1_run_format ~r/\Arun=(?<run>[0-9]+) order=(?<order>[a-z]+) elixir=(?<elixir>\S+) otp=(?<otp>\S+) erts=(?<erts>\S+) seed=(?<seed>[0-9]+) executed=(?<executed>[1-9][0-9]*) verdict=(?<verdict>\S+) exit=(?<exit>[0-9]+) wall=(?<wall>\S+)\z/
  @m1_metadata_format ~r/\Amatrix candidate=(?<candidate>[0-9a-f]{40}) gate_sha256=(?<gate_sha256>[0-9a-f]{64}) command=(?<command>bash:scripts\/check-m1-gate\.sh) platform=(?<platform>\S+) limits=(?<limits>\S+)\z/

  defp recorded_runs(contents, path, profile, root) do
    read_runs(contents, path, profile, root)
  rescue
    error in [Loopex.Checks.Invalid] -> {:error, Exception.message(error)}
  end

  defp read_runs(contents, path, :m0, _root) do
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

  defp read_runs(contents, path, :m1, root) do
    with {:ok, inner} <- fenced_body(Markdown.block(contents, path, :matrix_runs), path) do
      case inner do
        [metadata | runs] when length(runs) == 5 ->
          cond do
            Enum.any?(inner, &(not printable_ascii?(&1))) ->
              {:error, "#{path}: M1 metadata and runs must use printable ASCII only"}

            not Regex.match?(@m1_metadata_format, metadata) ->
              {:error, "#{path}: M1 matrix metadata is not in the required form"}

            Enum.any?(runs, &(not Regex.match?(@m1_run_format, &1))) ->
              {:error, "#{path}: an M1 run is not in the required form"}

            true ->
              identity = Regex.named_captures(@m1_metadata_format, metadata)

              with :ok <- validate_m1_identity(identity, root, path) do
                {:ok, Enum.map(runs, &Regex.named_captures(@m1_run_format, &1))}
              end
          end

        _other ->
          {:error,
           "#{path}: M1 requires exactly one metadata record and exactly five retained runs"}
      end
    end
  end

  defp read_runs(_contents, path, profile, _root),
    do: {:error, "#{path}: unknown matrix evidence profile #{inspect(profile)}"}

  defp validate_m1_identity(identity, root, path) do
    candidate = identity["candidate"]
    gate_path = Path.join(root, @m1_gate)
    gate_digest = identity["gate_sha256"]

    with {:ok, gate} <- read(gate_path),
         :ok <- current_gate_matches(gate, gate_digest, path),
         :ok <- candidate_gate_matches(root, candidate, gate_digest, path),
         true <- identity["command"] == @m1_command do
      :ok
    else
      {:error, reason} ->
        {:error, reason}

      false ->
        {:error, "#{path}: M1 matrix command does not match the locked runner"}
    end
  end

  defp current_gate_matches(gate, digest, path) do
    if Markdown.digest(gate) == digest,
      do: :ok,
      else: {:error, "#{path}: M1 matrix digest does not match the current gate"}
  end

  defp candidate_gate_matches(root, candidate, digest, path) do
    with {resolved, 0} <-
           Git.run(root, ["rev-parse", "--verify", "--quiet", "#{candidate}^{commit}"]),
         true <- String.trim(resolved) == candidate,
         true <- Git.ancestor?(root, candidate, "HEAD"),
         {entry, 0} <- Git.run(root, ["ls-tree", "-z", candidate, "--", @m1_gate]),
         :ok <- regular_gate_entry(entry),
         gate when is_binary(gate) <- Git.resolver(root).(candidate, @m1_gate) do
      if Markdown.digest(gate) == digest,
        do: :ok,
        else: {:error, "#{path}: M1 matrix candidate gate does not match the recorded digest"}
    else
      _other ->
        {:error, "#{path}: M1 matrix candidate does not carry a reachable gate blob"}
    end
  end

  defp regular_gate_entry(entry) do
    case String.split(entry, [" ", "\t", <<0>>], trim: true) do
      ["100644", "blob", _object, @m1_gate] -> :ok
      _other -> :error
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
