defmodule Mix.Tasks.Loopex.M7Evidence do
  @shortdoc "Validates M7 committed attempts heads, fixtures and release lane prerequisites"

  @moduledoc """
  ## Concept

  The M7 evidence validator both check commands run. The fast check proves the
  committed `index-head:` lines in the M7 Concept plan are well formed and do
  not conflict, that the pinned coding-fixture catalog, external task and
  execution manifest are intact and complete, and that the two release case
  families agree: the eleven legacy cases and the M7 cases. It reports every
  case and step owner still pending. The release check adds the selected
  lanes' prerequisites: an absolute retained attempts index outside the
  checkout and no pending case in a selected lane, or anywhere for the full
  matrix. Any missing prerequisite is unavailable evidence, never a pass.

  ## Technical depth

  `mix loopex.m7_evidence [--root DIR]` checks every line beginning
  `index-head:` against the exact `index-head: <campaign_id> <sequence>
  <sha256>` form, then selects each campaign's greatest head through
  `AttemptHeads`, refusing conflicting digests at one sequence. It loads
  `test/fixtures/m7/manifest.json` through `FixtureManifest` and
  `ExecutionManifest`, proves every test owner is a literal test, and reads the
  legacy family from the release script's own manifest rows.

  `--release [--attempts-index FILE] [--resume-matrix ID] --lane LANE ...`
  names the selected M7 lanes; the full matrix names all three. FILE is
  required except for an unindexed `m7-rollback` selection. Pending cases in a
  selected lane, or pending step owners in the full matrix, exit with status 2.
  Nothing here opens, creates or writes an index; `AttemptWriter` is the only
  writer.
  """

  use Mix.Task

  alias Mix.Tasks.Loopex.M7Evidence.AttemptHeads
  alias Mix.Tasks.Loopex.M7Evidence.{ExecutionManifest, FixtureManifest}

  @requirements ["compile"]
  @line ~r/\Aindex-head: (\S+) [1-9][0-9]* [0-9a-f]{64}\z/u

  @impl Mix.Task
  def run(argv) do
    {opts, rest} =
      OptionParser.parse!(argv,
        strict: [
          root: :string,
          release: :boolean,
          attempts_index: :string,
          resume_matrix: :string,
          lane: :keep
        ]
      )

    root = Path.expand(Keyword.get(opts, :root, File.cwd!()))

    result =
      if rest == [] do
        validate(root, opts)
      else
        {:error, :invalid_arguments}
      end

    case result do
      {:ok, lines} ->
        Enum.each(lines, &Mix.shell().info("m7-evidence: " <> &1))

      {:error, reason} ->
        Mix.shell().error("m7-evidence: evidence unavailable: #{format(reason)}")
        exit({:shutdown, 2})
    end
  end

  @doc false
  def validate(root, opts) do
    with {:ok, heads} <- heads(Path.join(root, "docs/plans/M7.md")),
         {:ok, [catalog, families, pending_line, execution, pending]} <- fixtures(root),
         {:ok, release} <- release(root, opts, execution, pending) do
      {:ok, [heads, catalog, families, pending_line | release]}
    end
  end

  defp heads(path) do
    with {:ok, text} <- read(path, :m7_concept_unavailable) do
      lines =
        text
        |> String.split("\n")
        |> Enum.filter(&String.starts_with?(String.trim_leading(&1), "index-head:"))

      with :ok <- exact_lines(lines) do
        campaigns = lines |> Enum.map(&(Regex.run(@line, &1) |> Enum.at(1))) |> Enum.uniq()

        Enum.reduce_while(campaigns, {:ok, []}, fn campaign, {:ok, selected} ->
          case AttemptHeads.select(text, campaign) do
            {:ok, head} -> {:cont, {:ok, selected ++ [head]}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)
        |> case do
          {:ok, []} ->
            {:ok, "committed heads: none"}

          {:ok, selected} ->
            {:ok,
             "committed heads: " <>
               Enum.map_join(selected, ", ", &"#{&1["campaign_id"]} #{&1["sequence"]}")}

          error ->
            error
        end
      end
    end
  end

  defp exact_lines(lines) do
    if Enum.all?(lines, &Regex.match?(@line, &1)),
      do: :ok,
      else: {:error, :invalid_committed_attempt_head_line}
  end

  defp fixtures(root) do
    with {:ok, manifest} <- FixtureManifest.load(Path.join(root, "test/fixtures/m7")),
         execution = manifest.catalog["execution_manifest"],
         :ok <- ExecutionManifest.verify_owners(execution, root),
         {:ok, legacy} <- legacy_family(root),
         :ok <- release_credentials(root, execution),
         :ok <- runbook(root, execution),
         :ok <- closure_rows(root, execution) do
      pending = ExecutionManifest.pending(execution)

      {:ok,
       [
         "fixture catalog #{manifest.digest}; campaign #{execution["campaign_id"]} " <>
           "genesis #{execution["genesis_digest"]}",
         "families: #{legacy} legacy release cases, #{map_size(execution["cases"])} M7 cases, " <>
           "#{map_size(execution["operator_step_evidence"])} operator step keys",
         "pending: #{length(pending.cases)} cases, #{length(pending.owners)} step owners",
         execution,
         pending
       ]}
    end
  end

  # Concept: the operator runbook shows exactly the committed ownership.
  # Technical depth: every step key and case row appears literally.
  defp runbook(root, execution) do
    with {:ok, text} <- read(Path.join(root, "docs/operator/m7-validation.md"), :m7_runbook_stale) do
      lines = MapSet.new(String.split(text, "\n"))

      steps =
        for {key, entry} <- execution["operator_step_evidence"],
            do: "| `#{key}` | #{entry["classification"]} | `#{entry["owner"]}` |"

      cases =
        for {lane, ids} <- execution["lanes"], id <- ids do
          entry = execution["cases"][id]
          "| `#{id}` | `#{lane}` | #{entry["driver"]} | `#{entry["status"]}` |"
        end

      if Enum.all?(steps ++ cases, &MapSet.member?(lines, &1)),
        do: :ok,
        else: {:error, :m7_runbook_stale}
    end
  end

  # Concept: the closure scaffold reserves one row per committed key.
  # Technical depth: rows start with the backquoted step or case key.
  defp closure_rows(root, execution) do
    with {:ok, text} <-
           read(Path.join(root, "docs/evidence/M7-closure-runs.md"), :m7_closure_rows_missing) do
      starts = text |> String.split("\n") |> Enum.map(&hd(String.split(&1, " |", parts: 2)))
      starts = MapSet.new(starts)

      keys =
        Map.keys(execution["operator_step_evidence"]) ++ Map.keys(execution["cases"])

      if Enum.all?(keys, &MapSet.member?(starts, "| `#{&1}`")),
        do: :ok,
        else: {:error, :m7_closure_rows_missing}
    end
  end

  # Concept: the release check carries exactly the manifest's selected
  # credential names into the M7 lanes, and no others.
  # Technical depth: the script's `m7_credential_names=(...)` list is read as
  # text and compared, as a set, with providers A and B.
  defp release_credentials(root, execution) do
    with {:ok, script} <-
           read(Path.join(root, "scripts/check-release.sh"), :m7_credential_names_mismatch),
         [_, names] <- Regex.run(~r/^m7_credential_names=\(([A-Z_ ]+)\)$/m, script),
         true <-
           Enum.sort(String.split(names)) == ExecutionManifest.credential_names(execution) do
      :ok
    else
      _ -> {:error, :m7_credential_names_mismatch}
    end
  end

  # Concept: the eleven legacy release cases stay one exact family beside M7's.
  # Technical depth: the runner's manifest rows are read from the release
  # script itself; each names a literal test in its file.
  defp legacy_family(root) do
    with {:ok, script} <-
           read(Path.join(root, "scripts/check-release.sh"), :legacy_release_family_invalid),
         [_, rows] <- Regex.run(~r/cat >"\$manifest" <<'EOF'\n(.*?)\nEOF\n/s, script),
         rows = String.split(rows, "\n"),
         11 <- length(Enum.uniq(rows)),
         true <- Enum.all?(rows, &legacy_row?(root, &1)) do
      {:ok, 11}
    else
      _ -> {:error, :legacy_release_family_invalid}
    end
  end

  defp legacy_row?(root, row) do
    with [app, file, name] <- String.split(row, "|"),
         {:ok, source} <- File.read(Path.join([root, "apps", app, file])) do
      String.contains?(source, inspect(name))
    else
      _ -> false
    end
  end

  defp release(root, opts, execution, pending) do
    if Keyword.get(opts, :release, false) do
      index = Keyword.get(opts, :attempts_index)
      lanes = Keyword.get_values(opts, :lane)
      full = Enum.sort(lanes) == ~w(m7-operator m7-provider m7-rollback)

      blocked =
        lanes
        |> Enum.flat_map(&Map.get(execution["lanes"], &1, []))
        |> Enum.filter(&(&1 in pending.cases))

      cond do
        lanes == [] or lanes -- ~w(m7-provider m7-rollback m7-operator) != [] or
            ("m7-operator" in lanes and not full) ->
          {:error, :unknown_m7_lane}

        is_nil(index) and (lanes != ["m7-rollback"] or opts[:resume_matrix]) ->
          {:error, :attempts_index_required}

        not is_nil(index) and Path.type(index) != :absolute ->
          {:error, :attempts_index_must_be_absolute}

        not is_nil(index) and String.starts_with?(Path.expand(index) <> "/", root <> "/") ->
          {:error, :attempts_index_inside_checkout}

        blocked != [] ->
          {:error, {:m7_cases_pending, blocked}}

        full and pending.owners != [] ->
          {:error, {:m7_step_owners_pending, pending.owners}}

        true ->
          {:ok, ["release lanes admitted: " <> Enum.join(lanes, " ")]}
      end
    else
      {:ok, []}
    end
  end

  defp format(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format({reason, items}) when is_list(items), do: "#{reason} #{Enum.join(items, " ")}"
  defp format(reason), do: inspect(reason)

  defp read(path, reason) do
    case File.read(path) do
      {:ok, text} -> {:ok, text}
      _ -> {:error, reason}
    end
  end
end
