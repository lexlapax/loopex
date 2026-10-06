defmodule LoopexComposition.Restore.Audit do
  @moduledoc """
  ## Concept

  Join the shipped current Store, Local, artifact and Resource history before
  the private first-restore workflow publishes intent. Evidence never becomes
  an effect grant or a reason to redispatch unknown work.

  ## Technical depth

  This private reduction runs inside Restore.IO's existing serial worker. Its
  IO callback executes owned captures under that invocation's original cutoffs.
  It folds every original journal record, including records summarized by later
  checkpoints. Host attestation covers host-owned ledgers; the separate helper
  accounting grammar remains unfinished and this unit makes no helper proof.
  """

  alias Loopex.ArtifactStore
  alias Loopex.Executor.Local
  alias Loopex.Executor.Local.RestoreCodec
  alias Loopex.Runtime.SessionState
  alias LoopexProtocol.Canonical

  @reference_fields [
    :digest,
    :size,
    :locator,
    :media_type,
    :role,
    :use_canonicalization_version,
    :use_digest,
    :use_locator
  ]
  @effect_kinds ~w(effect_intent_committed_v2 executor_receipt_committed_v2 tool_result_committed_v2 outcome_unknown_committed_v2)

  @doc false
  def complete(plan, manifest, max_total, io) do
    {:ok, entries} = RestoreCodec.manifest(manifest, max_total)
    index = Map.new(entries, &{&1["path"], &1})
    root = plan["backup_state_root"]
    covered_placement!(plan, index)

    stores =
      Map.new(plan["stores"], fn declaration ->
        {declaration["relative_path"], require!(io.({:audit_store, root, declaration, manifest}))}
      end)

    runtimes =
      stores
      |> Map.values()
      |> Enum.flat_map(fn facts ->
        Map.keys(facts.store.runtime_commands) ++
          Enum.map(facts.store.sessions, fn {_id, s} -> s.runtime_id end)
      end)
      |> Enum.uniq()
      |> Enum.sort()

    ensure!(runtimes == plan["runtime_ids"])

    ledgers =
      Map.new(plan["ledgers"], fn declaration ->
        relative = declaration["relative_root"]
        facts = require!(io.({:audit_ledger_index, root, declaration, manifest}))
        receipts = receipts!(root, declaration, index, manifest, io)
        ledger_receipt_pairs!(facts, receipts, declaration)
        {relative, Map.put(facts, :receipts, receipts)}
      end)

    resources = resource_inventory!(root, index, manifest, io)

    history =
      Enum.flat_map(stores, fn {_path, facts} ->
        Enum.flat_map(facts.store.sessions, fn {session, retained} ->
          session_history!(session, retained, plan, ledgers, resources)
        end)
      end)

    artifact_references =
      Enum.flat_map(Map.values(ledgers), fn facts ->
        Enum.flat_map(Map.values(facts.receipts), & &1.artifacts)
      end) ++ history

    artifact_references
    |> Enum.uniq()
    |> Enum.each(fn reference ->
      ensure!(ArtifactStore.valid_reference?(reference))
      ensure!(hex?(reference.locator))

      use =
        Path.join([
          "artifacts",
          "uses",
          binary_part(reference.use_digest, 0, 2),
          reference.use_digest
        ])

      object = Path.join(["artifacts", binary_part(reference.locator, 0, 2), reference.locator])
      ensure!(match?(%{"kind" => "regular"}, index[use]))
      ensure!(match?(%{"kind" => "regular"}, index[object]))
      require!(io.({:audit_artifact_use, root, reference, manifest}))
      require!(io.({:audit_artifact_object, root, reference, manifest, max_total}))
    end)

    retained_objects!(plan, root, index, io)
    %{stores: stores, ledgers: ledgers, resources: resources}
  end

  defp covered_placement!(plan, index) do
    stores = Enum.map(plan["stores"], & &1["relative_path"])
    ensure!(not Map.has_key?(index, "store.log") or "store.log" in stores)
    declared = Enum.map(plan["ledgers"], & &1["relative_root"])

    # Concept: current Local namespaces cannot disappear from plan coverage.
    # Technical depth: markers/open directories identify the shipped placement;
    # unrelated orphan files remain in the full unexcluded manifest.
    discovered =
      index
      |> Map.keys()
      |> Enum.filter(fn path ->
        String.ends_with?(path, "/markers") and index[path]["kind"] == "directory" and
          match?(%{"kind" => "directory"}, index[Path.join(Path.dirname(path), "open")])
      end)
      |> Enum.map(&Path.dirname/1)
      |> Enum.sort()

    ensure!(discovered == declared)

    ensure!(
      Enum.all?(plan["stores"], &match?(%{"kind" => "regular"}, index[&1["relative_path"]]))
    )
  end

  defp receipts!(root, declaration, index, manifest, io) do
    relative = declaration["relative_root"]

    index
    |> Map.keys()
    |> Enum.filter(fn path ->
      Path.dirname(path) == relative and String.ends_with?(path, ".receipt")
    end)
    |> Enum.sort()
    |> Map.new(fn path ->
      name = Path.basename(path, ".receipt")
      ensure!(hex?(name))
      receipt = require!(io.({:audit_receipt, root, path, manifest}))
      ensure!(RestoreCodec.digest_bytes(receipt.job_id) == name)
      ensure!(receipt.executor_identity == declaration["executor_identity"])
      {receipt.job_id, receipt}
    end)
  end

  defp ledger_receipt_pairs!(facts, receipts, declaration) do
    markers = Map.new(facts.markers)

    Enum.each(receipts, fn {job, receipt} ->
      marker = markers[RestoreCodec.digest_bytes(job)]
      ensure!(is_map(marker))
      ensure!(marker["canonical_request_digest"] == receipt.canonical_request_digest)

      ensure!(
        marker["operation_id"] == receipt.operation_id and marker["attempt"] == receipt.attempt
      )

      ensure!(receipt.executor_identity == declaration["executor_identity"])

      if marker.ledger_kind == "local_effect_admission_v1",
        do: ensure!(marker["cleanup_grace_ms"] == receipt.cleanup_grace_ms)
    end)
  end

  defp session_history!(session_id, session, plan, ledgers, resources) do
    workspace = plan["workspace"]["workspace_ref"]

    Enum.reduce(session.records, %{jobs: %{}, references: []}, fn row, history ->
      record = row.payload
      kind = record[:kind]

      if kind in @effect_kinds,
        do: require!(SessionState.effect_history_projection(session_id, record))

      case kind do
        "effect_intent_committed_v2" ->
          %{job: job} = require!(SessionState.effect_history_projection(session_id, record))
          ensure!(job.workspace_ref == workspace)
          ledger = ledger_for!(plan, ledgers, job.executor_identity)
          validate_job_plane!(job, ledger)
          key = {job.run_id, job.tool_call_id}
          %{history | jobs: Map.put(history.jobs, key, job)}

        "executor_receipt_committed_v2" ->
          retained = record["receipt"]
          key = {record["run_id"], retained["tool_call_id"]}
          job = fetch!(history.jobs, key)
          ledger = ledger_for!(plan, ledgers, job.executor_identity)
          receipt = fetch!(ledger.receipts, job.job_id)
          ensure!(Local.retained_receipt_matches_job?(receipt, job))
          ensure!(plain(receipt) == retained)
          %{history | references: receipt.artifacts ++ history.references}

        "tool_result_reference_prepared" ->
          %{history | references: [reference!(record["reference"]) | history.references]}

        "resource_command_v1" ->
          if record["disposition"] == "accepted" and is_map(record["resolved"]),
            do: resource_reference!(record["command"]["manifest_digest"], workspace, resources)

          history

        "model_request_committed_resources_v2" ->
          header = record["context_receipt"]["resource_packs"]

          if is_map(header) and is_binary(header["manifest_digest"]),
            do: resource_reference!(header["manifest_digest"], workspace, resources)

          history

        "session_genesis_v3" ->
          retained_workspace = record["options"]["workspace_ref"]
          ensure!(is_nil(retained_workspace) or retained_workspace == workspace)
          history

        _ ->
          history
      end
    end).references
  end

  defp ledger_for!(plan, ledgers, identity) do
    declarations = Enum.filter(plan["ledgers"], &(&1["executor_identity"] == identity))
    ensure!(length(declarations) == 1)
    ledgers[hd(declarations)["relative_root"]]
  end

  defp validate_job_plane!(job, ledger) do
    name = RestoreCodec.digest_bytes(job.job_id)
    marker = Map.new(ledger.markers)[name]

    if marker do
      ensure!(marker["operation_id"] == job.operation_id and marker["attempt"] == job.attempt)
      ensure!(marker["canonical_request_digest"] == job.canonical_request_digest)

      if marker.ledger_kind == "local_effect_admission_v1",
        do: ensure!(marker["cleanup_grace_ms"] == job.cleanup_grace_ms)
    end

    Enum.each(ledger.open, fn entry ->
      if entry["job_id"] == job.job_id do
        ensure!(entry["canonical_request_digest"] == job.canonical_request_digest)
        ensure!(entry["executor_identity"] == job.executor_identity)
        ensure!(entry["origin_executor_epoch"] == job.origin_executor_epoch)
        ensure!(entry["cleanup_grace_ms"] == job.cleanup_grace_ms)
      end
    end)

    if receipt = ledger.receipts[job.job_id],
      do: ensure!(Local.retained_receipt_matches_job?(receipt, job))
  end

  defp resource_inventory!(root, index, manifest, io) do
    maps =
      Map.new([{:manifest, "manifests"}, {:provenance, "provenance"}], fn {role, directory} ->
        prefix = Path.join(["resource-packs", directory])

        records =
          index
          |> Map.keys()
          |> Enum.filter(&(Path.dirname(&1) == prefix))
          |> Enum.sort()
          |> Map.new(fn path ->
            ensure!(String.ends_with?(path, ".etf"))
            identity = Path.basename(path, ".etf")
            ensure!(hex?(identity))
            {identity, require!(io.({:audit_resource, root, role, identity, manifest}))}
          end)

        {role, records}
      end)

    Enum.each(maps.manifest, fn {_digest, manifest} ->
      Enum.each(manifest["packs"], fn pack ->
        if is_binary(pack["commit"]), do: ensure!(maps.provenance[content_identity(pack)] == pack)
      end)
    end)

    maps
  end

  defp resource_reference!(digest, workspace, resources) do
    manifest = fetch!(resources.manifest, digest)
    ensure!(manifest["workspace_ref"] == workspace)
  end

  defp retained_objects!(plan, root, index, io) do
    namespaces = Map.new(plan["runtime_ids"], &{RestoreCodec.digest_bytes(&1), &1})

    Enum.each(index, fn {path, entry} ->
      case Path.split(path) do
        ["delegation", runtime_hash, object_hash] when byte_size(object_hash) == 64 ->
          ensure!(Map.has_key?(namespaces, runtime_hash) and hex?(object_hash))
          ensure!(entry["kind"] == "regular" and entry["size"] in 1..1_048_576)
          bytes = require!(io.({:read, Path.join(root, path), 1_048_576}))
          ensure!(String.valid?(bytes) and RestoreCodec.digest_bytes(bytes) == object_hash)

        _ ->
          :ok
      end
    end)
  end

  defp reference!(reference) do
    decoded = Map.new(@reference_fields, fn key -> {key, reference[Atom.to_string(key)]} end)

    ensure!(
      map_size(reference) == length(@reference_fields) and ArtifactStore.valid_reference?(decoded)
    )

    decoded
  end

  defp content_identity(pack) do
    pairs = pack["files"] |> Enum.map(&[&1["label"], &1["digest"]]) |> Enum.sort_by(&hd/1)

    Canonical.digest(%{
      "encoding" => Canonical.version(),
      "kind" => "loopex.retained_resource_content/1",
      "value" => pairs
    })
  end

  defp plain(value) when is_atom(value) and value not in [nil, true, false],
    do: Atom.to_string(value)

  defp plain(value) when is_list(value), do: Enum.map(value, &plain/1)

  defp plain(value) when is_map(value),
    do: Map.new(value, fn {key, nested} -> {plain(key), plain(nested)} end)

  defp plain(value), do: value
  defp hex?(value), do: is_binary(value) and Regex.match?(~r/\A[0-9a-f]{64}\z/, value)

  defp fetch!(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> throw({:restore_refusal, "invalid_current_history"})
    end
  end

  defp ensure!(true), do: :ok
  defp ensure!(_), do: throw({:restore_refusal, "invalid_current_history"})
  defp require!({:ok, value}), do: value
  defp require!(_), do: throw({:restore_refusal, "invalid_current_history"})
end
