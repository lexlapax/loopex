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
  checkpoints. Host attestation covers host-owned ledgers. A helper namespace
  restores only from a quiescent root: every member is a digest-named object or
  a complete binding/run log the existing `RetainedObjects` decoders accept for
  a planned runtime, and each committed `loopex.task` receipt must equal the
  receipt object its run log bound. Writer markers, locks, the disposable
  `job-index-v1` cache and any other member refuse.
  """

  alias Loopex.ArtifactStore
  alias Loopex.Executor.Local
  alias Loopex.Executor.Local.RestoreCodec
  alias Loopex.Runtime.SessionState
  alias LoopexComposition.Delegation.{LedgerCodec, RetainedObjects, RunLedger, Tool}
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
          Enum.map(facts.store.sessions, fn {_id, s} -> s.runtime_id end) ++
          Map.keys(facts.store.creation_heads) ++
          Enum.map(Map.keys(facts.store.creation_capsules), fn {runtime, _command} -> runtime end) ++
          Enum.map(Map.keys(facts.store.creation_resolutions), fn {runtime, _type, _tx} ->
            runtime
          end)
      end)
      |> Enum.uniq()
      |> Enum.sort()

    ensure!(runtimes == plan["runtime_ids"])

    # Concept: pending and cancelled candidates retain the same physical workspace.
    # Technical depth: current strict Store replay supplies complete capsules;
    # their genesis is not a session and cannot acquire authority from this join.
    Enum.each(stores, fn {_path, facts} ->
      Enum.each(facts.store.creation_capsules, fn {_key, capsule} ->
        genesis_workspace!(capsule.genesis, plan["workspace"]["workspace_ref"])
      end)
    end)

    ledgers =
      Map.new(plan["ledgers"], fn declaration ->
        relative = declaration["relative_root"]
        facts = require!(io.({:audit_ledger_index, root, declaration, manifest}))
        receipts = receipts!(root, declaration, index, manifest, io)
        ledger_receipt_pairs!(facts, receipts, declaration)
        {relative, Map.put(facts, :receipts, receipts)}
      end)

    resources = resource_inventory!(root, index, manifest, io)
    helpers = helper_namespace!(plan, root, index, io)

    history =
      Enum.flat_map(stores, fn {_path, facts} ->
        Enum.flat_map(facts.store.sessions, fn {session, retained} ->
          session_history!(session, retained, plan, ledgers, resources, helpers)
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

  defp session_history!(session_id, session, plan, ledgers, resources, helpers) do
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

          if job.tool_id == Tool.definition()["tool_id"] do
            task_receipt!(job, retained, session.runtime_id, helpers)
            history
          else
            local_receipt(history, job, retained, plan, ledgers)
          end

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
          genesis_workspace!(record, workspace)
          history

        _ ->
          history
      end
    end).references
  end

  defp genesis_workspace!(genesis, workspace) do
    retained = genesis["options"]["workspace_ref"]
    ensure!(is_nil(retained) or retained == workspace)
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

  defp local_receipt(history, job, retained, plan, ledgers) do
    ledger = ledger_for!(plan, ledgers, job.executor_identity)
    receipt = fetch!(ledger.receipts, job.job_id)
    ensure!(Local.retained_receipt_matches_job?(receipt, job))
    ensure!(plain(receipt) == retained)
    %{history | references: receipt.artifacts ++ history.references}
  end

  # Concept: a helper task receipt is the one its run log bound, never a guess.
  # Technical depth: exactly one complete bind_receipt names the job; its
  # digest-named object passes the run ledger's own receipt validator against
  # the original job and must equal Core's committed receipt.
  defp task_receipt!(job, retained, runtime, helpers) do
    binds =
      for {identifiers, transactions} <- Map.get(helpers.runs, runtime, []),
          %{"mutation" => %{"kind" => "bind_receipt"} = mutation} <- transactions,
          mutation["job"]["job_id"] == Base.encode64(job.job_id),
          do: {identifiers, mutation}

    ensure!(length(binds) == 1)
    [{identifiers, mutation}] = binds
    bytes = fetch!(helpers.objects, {runtime, mutation["receipt_sha256"]})
    receipt = require!(RunLedger.receipt_object(bytes, identifiers, mutation, job))
    ensure!(plain(receipt) == retained)
  end

  # Concept: helper state restores only from a quiescent, fully decodable root.
  # Technical depth: each member must be a planned runtime's directory, a
  # digest-named object, or a complete binding/run log named by its header key
  # and accepted by the existing offline decoders. Anything else, including a
  # writer marker, lock, temporary or the disposable job index, refuses.
  defp helper_namespace!(plan, root, index, io) do
    namespaces = Map.new(plan["runtime_ids"], &{RestoreCodec.digest_bytes(&1), &1})

    Enum.reduce(index, %{objects: %{}, runs: %{}}, fn {path, entry}, helpers ->
      case Path.split(path) do
        ["delegation"] ->
          ensure!(entry["kind"] == "directory")
          helpers

        ["delegation", runtime_hash] ->
          ensure!(Map.has_key?(namespaces, runtime_hash) and entry["kind"] == "directory")
          helpers

        ["delegation", runtime_hash, ledger] when ledger in ["bindings", "runs"] ->
          ensure!(Map.has_key?(namespaces, runtime_hash) and entry["kind"] == "directory")
          helpers

        ["delegation", runtime_hash, object_hash] when byte_size(object_hash) == 64 ->
          ensure!(Map.has_key?(namespaces, runtime_hash) and hex?(object_hash))
          ensure!(entry["kind"] == "regular" and entry["size"] in 1..1_048_576)
          bytes = require!(io.({:read, Path.join(root, path), 1_048_576}))
          ensure!(String.valid?(bytes) and RestoreCodec.digest_bytes(bytes) == object_hash)
          key = {namespaces[runtime_hash], object_hash}
          %{helpers | objects: Map.put(helpers.objects, key, bytes)}

        ["delegation", runtime_hash, ledger, name] when ledger in ["bindings", "runs"] ->
          runtime = fetch!(namespaces, runtime_hash)
          cap = if ledger == "bindings", do: 1_048_576, else: 16_777_216
          ensure!(entry["kind"] == "regular" and entry["size"] in 1..cap)
          bytes = require!(io.({:read, Path.join(root, path), cap}))
          {identifiers, log} = helper_log!(ledger, runtime, bytes)
          ensure!(log.tail == :complete and name == log.key <> ".log")

          if ledger == "runs",
            do: %{
              helpers
              | runs:
                  Map.update(
                    helpers.runs,
                    runtime,
                    [{identifiers, log.transactions}],
                    &[{identifiers, log.transactions} | &1]
                  )
            },
            else: helpers

        ["delegation" | _] ->
          throw({:restore_refusal, "invalid_current_history"})

        _ ->
          helpers
      end
    end)
  end

  defp helper_log!(ledger, runtime, bytes) do
    with {:ok, payload, _rest} <- LedgerCodec.decode_frame(bytes),
         {:ok, %{"identity" => identity}} <- LedgerCodec.decode_json(payload, :frame),
         true <- is_list(identity),
         identifiers = Enum.map(identity, &Base.decode64!/1),
         [^runtime | _] <- identifiers,
         {:ok, log} <- decode_helper_log(ledger, bytes, identifiers) do
      {identifiers, log}
    else
      _ -> throw({:restore_refusal, "invalid_current_history"})
    end
  rescue
    ArgumentError -> throw({:restore_refusal, "invalid_current_history"})
  end

  defp decode_helper_log("bindings", bytes, [runtime, command]),
    do: RetainedObjects.decode_binding(bytes, runtime, command)

  defp decode_helper_log("runs", bytes, identifiers),
    do: RetainedObjects.decode_run(bytes, identifiers)

  defp decode_helper_log(_ledger, _bytes, _identifiers), do: {:error, :invalid_helper_log}

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
