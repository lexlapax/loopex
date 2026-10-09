defmodule Mix.Tasks.Loopex.M7Evidence.RestoreCase do
  @moduledoc """
  ## Concept

  The attended M7 restore (V13.1 and V13.4 to V13.6) over the exact retained
  execution of the `m7-rollback` lane. It verifies the retained backup and its
  manifest, restores a fresh copy into a separate empty root through the
  public current-format restore, and proves the old root can no longer open.
  It then proves complete manifest equality and inspects the restored session
  history. The named operator confirms what was shown. No provider is called.

  ## Technical depth

  `run/3` reads `retained.json`, `baseline.manifest`, the backup and the
  physically identified workspace that the rollback lane's restore test left
  in its retained directory. The retained backup is only read. A
  mode-preserving copy becomes the attempt's available source, and the
  ADR 0051 plan names that source, the retained backup, an empty destination
  and the retained workspace. The result's `checks` map holds one boolean per
  step; `records` lists retained evidence. Any refusal leaves the checks false.
  """

  alias Loopex.Executor.Local.{RestoreCodec, RestoreGuard}
  alias LoopexComposition.Restore
  alias LoopexComposition.Restore.IO, as: RestoreIO
  alias LoopexProtocol.Canonical

  @total 16_777_216
  @limits %{"work_ms" => 10_000, "cleanup_grace_ms" => 1_000}

  @doc false
  def run(retained_dir, root, confirm) do
    with {:ok, bytes} <- File.read(Path.join(retained_dir, "retained.json")),
         {:ok, retained} <- JSON.decode(bytes),
         {:ok, baseline} <- File.read(Path.join(retained_dir, "baseline.manifest")) do
      verify(retained, baseline, root, confirm)
    else
      _ ->
        %{checks: %{"retained_execution" => false}, records: [], summary: "no retained execution"}
    end
  end

  defp verify(retained, baseline, root, confirm) do
    backup = retained["backup"]
    original = retained["plan"]
    source = original["source_state_root"]
    retired = source <> ".retired"
    destination = Path.join(root, "destination")

    recorded =
      manifest(backup) == {:ok, baseline} and
        Canonical.digest_bytes(baseline) == retained["baseline_manifest_sha256"] and
        original["manifest_sha256"] == retained["baseline_manifest_sha256"]

    # The upgraded root is gone: move the rollback lane's retired source aside
    # once, keeping it as evidence, so its original path is absent.
    # Ordinary opens refuse the retired root at its own path before it moves.
    prevented =
      if File.exists?(source),
        do: RestoreGuard.state(source) == {:error, :source_retired},
        else: match?({:error, _}, RestoreGuard.state(retired))

    if File.exists?(source) and not File.exists?(retired), do: :ok = File.rename(source, retired)
    :ok = File.mkdir(destination)

    plan = %{
      original
      | "tx_id" => Canonical.digest_bytes("m7-restore:" <> root),
        "destination_state_root" => destination,
        "source_status" => "lost"
    }

    restored =
      Restore.restore(
        plan,
        Map.merge(@limits, %{
          "max_total_file_bytes" => @total,
          "prior_admin_authority" => "none",
          "prior_admin_evidence_sha256" => nil
        })
      )

    lookup = Restore.lookup(destination, plan["tx_id"], @limits)
    complete = complete?(baseline, manifest(destination), backup, destination)
    history = history(destination, retained["session_id"])
    workspace = manifest(retained["workspace"])

    checks = %{
      "retained_execution" => true,
      "backup_manifest_recorded" => recorded,
      "restore_committed" => match?({:committed, _}, restored),
      "lookup_committed" => match?({:committed, %{"view" => "current"}}, lookup),
      "old_root_prevented" => prevented and not File.exists?(source),
      "manifest_complete" => complete,
      "workspace_baseline" =>
        match?({:ok, _}, workspace) and
          Canonical.digest_bytes(elem(workspace, 1)) == retained["workspace_manifest_sha256"],
      "restored_history" => history > 0
    }

    summary =
      "restore #{plan["tx_id"]}: " <>
        Enum.map_join(Enum.sort(checks), ", ", fn {name, ok} -> "#{name}=#{ok}" end) <>
        "; restored records=#{history}"

    %{
      checks: Map.put(checks, "operator_confirmed", confirm.(summary)),
      summary: summary,
      records: [
        {"restore-plan.json", JSON.encode!(plan)},
        {"restore-result.txt", inspect({restored, lookup}, pretty: true, limit: :infinity)},
        {"restore-summary.txt", summary <> "\n"}
      ]
    }
  rescue
    error ->
      %{
        checks: %{"retained_execution" => true, "restore_committed" => false},
        records: [{"restore-failure.txt", Exception.message(error)}],
        summary: Exception.message(error)
      }
  end

  # Concept: every baseline entry is restored exactly; the restore adds only
  # its own lineage records and re-binds each ledger generation to the new
  # root. Technical depth: a generation keeps every member but its executor
  # epoch, generation ID and root binding, as ADR 0051's restore requires.
  @generations ["receipts/generation", "resource-packs/receipts/generation"]
  @rebound ["executor_epoch", "generation_id", "root_binding"]

  defp complete?(baseline, {:ok, restored}, backup, destination) do
    with {:ok, expected} <- RestoreCodec.manifest(baseline, @total),
         {:ok, actual} <- RestoreCodec.manifest(restored, @total) do
      index = Map.new(actual, &{&1["path"], &1})
      added = Map.keys(index) -- Enum.map(expected, & &1["path"])

      Enum.all?(expected, fn entry ->
        found = index[entry["path"]]

        if entry["path"] in @generations,
          do:
            found && Map.drop(found, ~w(size sha256)) == Map.drop(entry, ~w(size sha256)) &&
              generation(backup, entry["path"]) == generation(destination, entry["path"]),
          else: found == entry
      end) and Enum.all?(added, &restore_admin?/1)
    else
      _ -> false
    end
  end

  defp complete?(_baseline, _restored, _backup, _destination), do: false

  defp generation(root, path) do
    with {:ok, bytes} <- File.read(Path.join(root, path)),
         {:ok, generation} <- RestoreCodec.decode(:generation, bytes),
         do: Map.drop(generation, @rebound)
  end

  defp restore_admin?(path),
    do:
      String.starts_with?(path, ".loopex-restore") or
        Enum.any?(
          ~w(receipts resource-packs/receipts),
          &String.starts_with?(path, &1 <> "/restore-lineage")
        )

  defp history(destination, session) when is_binary(session) do
    case Mix.Tasks.Loopex.M7Evidence.CaseRunner.committed(destination, session) do
      {:ok, rows} -> length(rows)
      _ -> 0
    end
  end

  defp history(_destination, _session), do: 0

  defp manifest(root) do
    case RestoreIO.run({:manifest, root, @total}, @limits) do
      {:joined, {:ok, bytes}, _evidence} -> {:ok, bytes}
      _ -> :error
    end
  end
end
