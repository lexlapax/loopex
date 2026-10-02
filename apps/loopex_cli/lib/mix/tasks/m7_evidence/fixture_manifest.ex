defmodule Mix.Tasks.Loopex.M7Evidence.FixtureManifest do
  @moduledoc """
  ## Concept

  Pins the four accepted M7 coding fixtures and protects their independent
  oracles from workspace changes. A fixture source catalog is preparation;
  provider executions and V1–V13 evidence require their separate complete manifest.

  ## Technical depth

  The closed catalog fixes source bytes/modes, literal prompts, run bounds,
  permitted changes, expected results and required model actions. Source and
  workspace verification visit complete file/directory inventories and refuse
  symlinks or additional paths. Oracle bytes and modes are checked separately
  before and after execution. No file is written and no oracle or model runs.
  The external target and complete execution manifest remain explicitly pending.
  """

  alias LoopexCli.ConfigJson
  @names ~w(repair feature review long)
  @entry_keys ~w(workspace initial_files initial_directories allowed_changed_paths allowed_created_paths oracle invocation run_bounds prompts objective_results required_model_actions)

  @doc false
  def load(root) do
    with {:ok, bytes} <- read(Path.join(root, "manifest.json")),
         {:ok, catalog} <- ConfigJson.decode(bytes),
         true <- valid_catalog?(catalog),
         :ok <- verify_sources(catalog, root) do
      {:ok, catalog}
    else
      _ -> {:error, :fixture_manifest_unavailable}
    end
  end

  @doc false
  def verify_sources(catalog, root) do
    Enum.reduce_while(@names, :ok, fn name, :ok ->
      entry = catalog["fixtures"][name]

      with {:ok, tree} <- inventory(Path.join(root, entry["workspace"])),
           true <- tree == expected_tree(entry),
           :ok <- verify_oracle(entry, root) do
        {:cont, :ok}
      else
        _ -> {:halt, {:error, :fixture_sources_changed}}
      end
    end)
  rescue
    _ -> {:error, :fixture_sources_changed}
  end

  @doc false
  def verify_oracle(entry, root) do
    oracle = entry["oracle"]

    case file_entry(Path.join(root, oracle["path"])) do
      {:ok, %{"kind" => "file", "mode" => mode, "sha256" => digest}} ->
        if mode == oracle["mode"] and digest == oracle["sha256"],
          do: :ok,
          else: {:error, :fixture_oracle_changed}

      _ ->
        {:error, :fixture_oracle_changed}
    end
  end

  @doc false
  def verify_workspace(entry, workspace) do
    with {:ok, actual} <- inventory(workspace),
         expected = expected_tree(entry),
         true <- Map.keys(expected) -- Map.keys(actual) == [],
         true <- Map.keys(actual) -- (Map.keys(expected) ++ entry["allowed_created_paths"]) == [],
         true <-
           Enum.all?(actual, fn {path, value} ->
             case Map.fetch(expected, path) do
               {:ok, original} ->
                 if path in entry["allowed_changed_paths"],
                   do: Map.take(value, ~w(kind mode)) == Map.take(original, ~w(kind mode)),
                   else: value == original

               :error ->
                 value["kind"] == "file" and value["mode"] == 420
             end
           end) do
      :ok
    else
      _ -> {:error, :fixture_workspace_changed}
    end
  end

  defp valid_catalog?(catalog) do
    closed?(catalog, ~w(version fixtures external execution_manifest)) and catalog["version"] == 1 and
      closed?(catalog["fixtures"], @names) and
      catalog["external"] == %{"status" => "pending_maintainer_selection"} and
      catalog["execution_manifest"] == %{"status" => "pending", "coverage" => "V1-V13"} and
      Enum.all?(@names, &valid_entry?(&1, catalog["fixtures"][&1]))
  end

  defp valid_entry?(name, entry) do
    closed?(entry, @entry_keys) and entry["workspace"] == name <> "/workspace" and
      files?(entry["initial_files"]) and directories?(entry["initial_directories"]) and
      entry["allowed_changed_paths"] == changed_paths(name) and
      entry["allowed_created_paths"] == created_paths(name) and
      entry["allowed_changed_paths"] -- Map.keys(entry["initial_files"]) == [] and
      Enum.all?(entry["allowed_created_paths"], &(not Map.has_key?(entry["initial_files"], &1))) and
      closed?(entry["oracle"], ~w(path sha256 mode)) and
      entry["oracle"]["path"] == name <> "/oracle.exs" and
      entry["oracle"]["mode"] == 420 and digest?(entry["oracle"]["sha256"]) and
      entry["run_bounds"] == %{
        "max_turns" => 16,
        "deadline_ms" => 600_000,
        "token_budget" => 1_000_000
      } and
      closed?(entry["invocation"], ~w(argv environment additional_environment)) and
      entry["invocation"]["argv"] == ["elixir", "{oracle}"] and
      entry["invocation"]["environment"] == %{"M7_WORKSPACE" => "{workspace}"} and
      entry["invocation"]["additional_environment"] == additional_environment(name) and
      is_list(entry["prompts"]) and length(entry["prompts"]) in 1..16 and
      Enum.all?(
        entry["prompts"],
        &(is_binary(&1) and byte_size(&1) in 1..32_768 and String.valid?(&1))
      ) and
      entry["objective_results"] == objective_results(name) and
      entry["required_model_actions"] == required_actions(name)
  end

  defp objective_results("feature"),
    do: %{
      "choice-1" => "empty",
      "choice-2" => "literal_null",
      "explicit_modes" => ["empty", "literal_null"],
      "ordinary_row" => "left,3,right"
    }

  defp objective_results("long"),
    do: %{
      "batch_size" => 3,
      "batches.txt" => "amber-001\namber-002\namber-003\n",
      "release.txt" => "amber\n",
      "release_prefix" => "amber",
      "required_runtime_joins" => [
        "automatic_checkpoint",
        "explicit_checkpoint",
        "restart",
        "retained_raw_facts"
      ]
    }

  defp objective_results("repair"),
    do: %{
      "empty" => 0,
      "negative" => %{"entries" => [-12, -7], "total" => -19},
      "positive" => %{"entries" => [12, 7, 4], "total" => 23},
      "refunds" => %{"entries" => [12, -7, 4, -9], "total" => 0}
    }

  defp objective_results("review"),
    do: %{
      "finding" =>
        "file\tfunction\tdefect_code\tcall_chain\nlib/fees.ex\ttotal/2\tduplicate_fee\tCheckout.quote/2>Invoice.total/2>Fees.total/2\n",
      "quote" => %{"amount" => 1200, "fee" => 75, "observed" => 1350}
    }

  defp required_actions("feature"),
    do: [
      %{
        "arguments" => %{
          "choices" => ["empty", "literal_null"],
          "question" => "Which default should nil_mode use?"
        },
        "require_committed_answer" => true,
        "tool_id" => "loopex.ask"
      }
    ]

  defp required_actions("long"), do: []

  defp required_actions("repair"), do: []

  defp required_actions("review"),
    do: [
      %{"role" => "investigate", "tool_id" => "loopex.task"},
      %{"role" => "review", "tool_id" => "loopex.task"}
    ]

  defp additional_environment("feature"), do: ["M7_NIL_DEFAULT"]
  defp additional_environment("review"), do: ["M7_FINDING"]
  defp additional_environment(_), do: []

  defp files?(files) do
    is_map(files) and map_size(files) in 1..64 and
      Enum.all?(files, fn {path, file} ->
        path?(path) and closed?(file, ~w(sha256 mode)) and file["mode"] == 420 and
          digest?(file["sha256"])
      end)
  end

  defp directories?(dirs),
    do:
      is_map(dirs) and map_size(dirs) <= 16 and
        Enum.all?(dirs, fn {path, mode} -> path?(path) and mode == 493 end)

  defp changed_paths("repair"), do: ["lib/ledger.ex"]
  defp changed_paths("feature"), do: ["lib/row_encoder.ex"]
  defp changed_paths(_), do: []
  defp created_paths("long"), do: ["release.txt", "batches.txt"]
  defp created_paths(_), do: []

  defp path?(path),
    do:
      is_binary(path) and byte_size(path) in 1..256 and
        Regex.match?(~r/\A[A-Za-z0-9_.-]+(?:\/[A-Za-z0-9_.-]+)*\z/, path) and
        Enum.all?(String.split(path, "/"), &(&1 not in [".", ".."]))

  defp closed?(map, keys), do: is_map(map) and Enum.sort(Map.keys(map)) == Enum.sort(keys)
  defp digest?(value), do: is_binary(value) and Regex.match?(~r/\A[0-9a-f]{64}\z/, value)

  defp expected_tree(entry) do
    files =
      Map.new(entry["initial_files"], fn {path, value} ->
        {path, Map.put(value, "kind", "file")}
      end)

    dirs =
      Map.new(entry["initial_directories"], fn {path, mode} ->
        {path, %{"kind" => "directory", "mode" => mode}}
      end)

    Map.merge(files, dirs)
  end

  defp inventory(root) do
    case File.lstat(root) do
      {:ok, %{type: :directory}} -> {:ok, walk(root, "", %{})}
      _ -> {:error, :invalid_tree}
    end
  rescue
    _ -> {:error, :invalid_tree}
  end

  defp walk(root, relative, acc) do
    Enum.reduce(File.ls!(Path.join(root, relative)), acc, fn name, acc ->
      path = if relative == "", do: name, else: relative <> "/" <> name
      {:ok, entry} = file_entry(Path.join(root, path))
      acc = Map.put(acc, path, entry)
      if entry["kind"] == "directory", do: walk(root, path, acc), else: acc
    end)
  end

  defp file_entry(path) do
    with {:ok, info} <- File.lstat(path) do
      mode = Bitwise.band(info.mode, 0o7777)

      case info.type do
        :directory ->
          {:ok, %{"kind" => "directory", "mode" => mode}}

        :regular ->
          {:ok,
           %{
             "kind" => "file",
             "mode" => mode,
             "sha256" => file_digest(path)
           }}

        _ ->
          {:error, :invalid_tree}
      end
    end
  end

  defp file_digest(path) do
    path
    |> File.stream!(65_536, [])
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  defp read(path) do
    with {:ok, io} <- File.open(path, [:read, :binary]) do
      try do
        case IO.binread(io, 65_537) do
          bytes when is_binary(bytes) and byte_size(bytes) <= 65_536 -> {:ok, bytes}
          _ -> {:error, :invalid_bytes}
        end
      after
        File.close(io)
      end
    end
  end
end
