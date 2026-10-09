defmodule Mix.Tasks.Loopex.M7Evidence do
  @shortdoc "Validates M7 committed attempts heads, fixtures and release lane prerequisites"

  @moduledoc """
  ## Concept

  The M7 evidence validator both check commands run. The fast check proves the
  committed `index-head:` lines in the M7 Concept plan are well formed and do
  not conflict, and that the pinned coding-fixture catalog and its oracles are
  intact. The release check adds the indexed lanes' prerequisites: an absolute
  retained attempts index outside the checkout and a pinned execution manifest.
  Any missing prerequisite is unavailable evidence, never a pass.

  ## Technical depth

  `mix loopex.m7_evidence [--root DIR]` checks every line beginning
  `index-head:` against the exact `index-head: <campaign_id> <sequence>
  <sha256>` form, then selects each campaign's greatest head through
  `AttemptHeads`, refusing conflicting digests at one sequence. It loads
  `test/fixtures/m7/manifest.json` through `FixtureManifest`, which verifies
  every workspace inventory and oracle digest.

  `--release [--attempts-index FILE] [--resume-matrix ID] [--lane LANE ...]`
  also requires FILE, except for an unindexed `m7-rollback` selection, to be
  absolute and outside the root, and the execution manifest to pin the M7
  campaign and its lane cases. While the catalog records that manifest as
  pending, indexed lanes refuse before staging with exit status 2. Nothing here
  opens, creates or writes an index; `AttemptWriter` is the only writer.
  """

  use Mix.Task

  alias Mix.Tasks.Loopex.M7Evidence.AttemptHeads
  alias Mix.Tasks.Loopex.M7Evidence.FixtureManifest

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
        Mix.shell().error("m7-evidence: evidence unavailable: #{reason}")
        exit({:shutdown, 2})
    end
  end

  @doc false
  def validate(root, opts) do
    with {:ok, heads} <- heads(Path.join(root, "docs/plans/M7.md")),
         {:ok, fixtures} <- fixtures(root),
         {:ok, release} <- release(root, opts) do
      {:ok, [heads, fixtures | release]}
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
    case FixtureManifest.load(Path.join(root, "test/fixtures/m7")) do
      {:ok, manifest} ->
        {:ok, "fixture catalog #{manifest.digest}; execution manifest pending"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp release(root, opts) do
    if Keyword.get(opts, :release, false) do
      index = Keyword.get(opts, :attempts_index)
      lanes = Keyword.get_values(opts, :lane)

      cond do
        lanes -- ["m7-provider", "m7-rollback"] != [] ->
          {:error, :unknown_m7_lane}

        is_nil(index) and (lanes != ["m7-rollback"] or opts[:resume_matrix]) ->
          {:error, :attempts_index_required}

        not is_nil(index) and Path.type(index) != :absolute ->
          {:error, :attempts_index_must_be_absolute}

        not is_nil(index) and String.starts_with?(Path.expand(index) <> "/", root <> "/") ->
          {:error, :attempts_index_inside_checkout}

        true ->
          {:error, :m7_execution_manifest_pending}
      end
    else
      {:ok, []}
    end
  end

  defp read(path, reason) do
    case File.read(path) do
      {:ok, text} -> {:ok, text}
      _ -> {:error, reason}
    end
  end
end
