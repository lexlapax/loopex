defmodule LoopexComposition.Restore.Workflow do
  @moduledoc """
  ## Concept

  The private transition restores one complete shipped current baseline
  into an empty root. Available sources retire before activation; lost sources
  require positive absence and the retained host exclusion attestation.

  ## Technical depth

  This development path sequences existing physical audits, streaming copy and
  canonical ADR 0051 publication inside one Restore.IO worker. It has no public
  restore entry point. It classifies exact committed duplicates before fresh
  work and validates and appends complete prior lineage. Original-tx
  continuation remains implementation work. The IO callback never
  starts another guardian or refreshes this invocation's work or cleanup allowance.
  """

  alias Loopex.Executor.Local.{Ledger, RestoreCodec}
  alias LoopexComposition.Restore.Audit
  alias LoopexComposition.WorkspaceIdentity

  @doc false
  def execute(plan, invocation, io) do
    Process.put(:restore_workflow_claims, [])
    Process.put(:restore_workflow_changed, false)
    Process.put(:restore_workflow_intent, false)
    root_admin = root_admin(plan)
    phase(io, "claim")
    # Concept: transition 65 refuses before acquiring or changing physical state.
    # Technical depth: the existing metadata-only phase remains observable before
    # this admission gate; every claim and physical IO operation follows the gate.
    ensure!(plan["prior_restore_count"] < 64, "inventory_limit_exceeded")
    classify!(plan["destination_state_root"], plan, io)
    if plan["source_status"] == "available",
      do: classify!(plan["source_state_root"], plan, io)
    claims = claims!(plan, io)
    Process.put(:restore_workflow_claims, claims)
    phase(io, "inventory")
    source = plan["source_state_root"]
    backup = plan["backup_state_root"]
    destination = plan["destination_state_root"]
    max_total = invocation["max_total_file_bytes"]
    available = plan["source_status"] == "available"
    source_placement = plan["source_state_placement"]

    source_observation =
      if available do
        ensure!(value!(io.({:placement, source})) == source_placement, "invalid_placement")
        nil
      else
        value!(io.({:lost_source_absent, source}))
      end

    destination_placement = value!(io.({:placement, destination}))
    value!(io.({:placement, backup}))
    workspace = value!(io.({:placement, plan["workspace"]["root"]}))
    workspace!(plan, workspace)
    ensure!(value!(io.({:directory_names, destination})) == [], "destination_not_empty")
    baseline = value!(io.({:manifest, backup, max_total}))
    ensure!(hash(baseline) == plan["manifest_sha256"], "inventory_mismatch")

    if available,
      do: ensure!(value!(io.({:manifest, source, max_total})) == baseline, "inventory_mismatch")

    {:ok, entries} = RestoreCodec.manifest(baseline, max_total)
    {:ok, lineage_digest} = RestoreCodec.lineage_digest(Enum.filter(entries, &admin_entry?/1))
    ensure!(plan["prior_lineage_sha256"] == lineage_digest, "inventory_mismatch")

    lineage =
      case io.({:audit_restore_lineage, backup, plan, baseline}) do
        {:ok, lineage} -> lineage
        {:error, :restore_conflict} -> throw({:restore_refusal, "restore_conflict"})
        _ -> throw({:restore_refusal, "invalid_current_history"})
      end

    facts = Audit.complete(plan, baseline, max_total, io)

    phase(io, "baseline_copy")
    Process.put(:restore_workflow_changed, true)

    Enum.each(entries, fn entry ->
      relative = entry["path"]
      path = if relative == ".", do: destination, else: Path.join(destination, relative)

      if entry["kind"] == "directory" do
        if relative != ".", do: value!(io.({:make_directory, path, 0o700}))
      else
        value!(io.({:copy_file, Path.join(backup, relative), path, entry}))
      end
    end)

    entries
    |> Enum.filter(&(&1["kind"] == "directory"))
    |> Enum.sort_by(&byte_size(&1["path"]), :desc)
    |> Enum.each(fn entry ->
      path = if entry["path"] == ".", do: destination, else: Path.join(destination, entry["path"])
      value!(io.({:set_directory_mode, path, entry["mode"]}))
    end)

    ensure!(value!(io.({:manifest, destination, max_total})) == baseline, "inventory_mismatch")

    if available do
      Enum.each(plan["ledgers"], fn declaration ->
        ensure!(
          value!(io.({:placement, Path.join(source, declaration["relative_root"])})) ==
            declaration["source_placement"],
          "source_changed"
        )
      end)
    else
      lost_source!(source, source_observation, io)
    end

    compiled =
      compile!(
        plan,
        baseline,
        entries,
        facts,
        lineage,
        source_placement,
        destination_placement,
        max_total,
        io
      )

    # All independent whole-record ceilings and exact activation bytes have
    # already been checked; no intent temp exists before this point.
    phase(io, "destination_intent")
    admin_directories!(destination, root_admin, entries, io)
    publish!(destination, Path.join(root_admin, "baseline"), baseline, io)
    Process.put(:restore_workflow_intent, true)
    value!(io.({:intent_may_persist, "destination_intent"}))
    publish!(destination, Path.join(root_admin, "intent"), compiled.intent, io)

    phase(io, "source_retirement")

    if available do
      ensure!(value!(io.({:manifest, source, max_total})) == baseline, "source_changed")
      ensure!(value!(io.({:placement, source})) == source_placement, "source_changed")
      admin_directories!(source, root_admin, entries, io)
      publish!(source, Path.join(root_admin, "intent"), compiled.intent, io)

      Enum.each(compiled.ledgers, fn ledger ->
        admin_directories!(source, ledger.directory, entries, io)
        publish!(source, Path.join(ledger.directory, "intent"), ledger.intent, io)
        publish!(source, Path.join(ledger.directory, "source-retired"), ledger.retired, io)
      end)

      publish!(source, Path.join(root_admin, "source-retirement"), compiled.retirement, io)
    else
      lost_source!(source, source_observation, io)
    end

    publish!(destination, Path.join(root_admin, "source-retirement"), compiled.retirement, io)

    phase(io, "destination_generations")

    Enum.each(compiled.ledgers, fn ledger ->
      admin_directories!(destination, ledger.directory, entries, io)
      publish!(destination, Path.join(ledger.directory, "intent"), ledger.intent, io)

      if available,
        do:
          publish!(destination, Path.join(ledger.directory, "source-retired"), ledger.retired, io)

      path = Path.join([destination, ledger.relative, "generation"])

      value!(
        io.(
          {:publish, path, path <> ".restore-" <> ordinal(plan) <> ".tmp", ledger.candidate,
           ledger.mode, ledger.original}
        )
      )
    end)

    if not available, do: lost_source!(source, source_observation, io)
    workspace!(plan, value!(io.({:placement, plan["workspace"]["root"]})))
    ensure!(value!(io.({:placement, destination})) == destination_placement, "source_changed")
    activation = value!(io.({:manifest, destination, max_total}))
    ensure!(activation == compiled.activation, "inventory_mismatch")

    phase(io, "destination_proofs")

    Enum.each(compiled.ledgers, fn ledger ->
      publish!(destination, Path.join(ledger.directory, "committed"), ledger.committed, io)
    end)

    if not available, do: lost_source!(source, source_observation, io)
    publish!(destination, Path.join(root_admin, "committed"), compiled.committed, io)
    final = value!(io.({:manifest, destination, max_total}))
    ensure!(final == compiled.final, "inventory_mismatch")
    phase(io, "claim_release")
    {:ok, %{restore_result: {:committed, compiled.receipt}, release_claims: claims}}
  catch
    {:restore_duplicate, receipt} ->
      {:ok, %{restore_result: {:committed, receipt}, release_claims: []}}
    {:restore_refusal, code} -> refusal(code)
    {:io_error, _reason} -> refusal("inventory_unavailable")
    {:stopped, _reason} -> refusal("inventory_unavailable")
  end

  # Concept: classify retained completion before fresh claims or allocation.
  # Technical depth: administrative capture and reduction remain in this one
  # worker. Duplicates never inspect the old source/backup or allocate epochs;
  # pending continuation remains a separate unfinished implementation unit.
  defp classify!(root, plan, io) do
    case value!(io.({:restore_classification, root, plan})) do
      :fresh -> :ok
      {:committed, receipt} -> throw({:restore_duplicate, receipt})
      {:error, %{"code" => "restore_history_invalid"}} ->
        throw({:restore_refusal, "invalid_current_history"})
      {:error, %{"code" => code}} -> throw({:restore_refusal, code})
      _ -> throw({:restore_refusal, "invalid_current_history"})
    end
  end

  # Concept: a pre-intent IO refusal still releases positively acquired claims.
  # Technical depth: only the original worker's completed acquisition records
  # enter this list. The guardian retains partial acquisitions separately and
  # runs release through its existing terminal owner and captured cutoffs. Its
  # original stop reason still owns deadline/caller-loss outcomes; possible
  # intent persistence still produces commit_unknown and retains every claim.
  defp refusal(code) do
    claims = Process.get(:restore_workflow_claims, [])
    release = if Process.get(:restore_workflow_changed), do: [], else: claims

    result =
      if Process.get(:restore_workflow_intent),
        do: {:commit_unknown, code},
        else: {:not_committed, code}

    {:ok, %{restore_result: result, release_claims: release}}
  end

  # Concept: host exclusion and the original captured placement survive source loss.
  # Technical depth: copied native generation bindings are audited against the
  # plan, while repeated native absence checks must retain the same ancestor
  # identities. Neither a backup inode nor a fabricated tombstone replaces the
  # lost source's captured identity.
  defp lost_source!(source, observation, io),
    do: ensure!(value!(io.({:lost_source_absent, source})) == observation, "source_changed")

  defp claims!(plan, io) do
    {:ok, digest} = RestoreCodec.plan_digest(plan)
    nonce = random_hex()

    roots =
      if plan["source_status"] == "available" do
        [
          {plan["source_state_root"], "source"},
          {plan["destination_state_root"], "destination"}
        ]
      else
        [{plan["destination_state_root"], "destination"}]
      end

    roots
    |> Enum.sort()
    |> Enum.map(fn {root, role} ->
      {:ok, claim_digest} = RestoreCodec.claim_digest(root)
      directory = Path.join(Path.dirname(root), ".loopex-restore-claim-" <> claim_digest)

      owner =
        encode!(:claim, %{
          "kind" => "loopex_current_restore_claim_v1",
          "tx_id" => plan["tx_id"],
          "plan_digest" => digest,
          "claim_nonce" => nonce,
          "state_root" => root,
          "role" => role
        })

      claim = %{directory: directory, owner: owner}
      claim = value!(io.({:acquire_restore_claim, claim}))
      Process.put(:restore_workflow_claims, [claim | Process.get(:restore_workflow_claims, [])])
      claim
    end)
  end

  defp compile!(plan, baseline, entries, facts, lineage, source, destination, max_total, io) do
    root_admin = root_admin(plan)
    {:ok, plan_digest} = RestoreCodec.plan_digest(plan)
    {:ok, source_binding} = RestoreCodec.state_binding(source)
    {:ok, destination_binding} = RestoreCodec.state_binding(destination)

    {candidates, _epochs} =
      Enum.map_reduce(plan["ledgers"], MapSet.new(), fn declaration, epochs ->
        relative = declaration["relative_root"]
        old = facts.ledgers[relative].generation
        original = :erlang.term_to_binary(old, [:deterministic])
        ensure!(hash(original) == declaration["source_generation_sha256"], "inventory_mismatch")
        placement = value!(io.({:placement, Path.join(plan["destination_state_root"], relative)}))
        {:ok, binding} = RestoreCodec.ledger_binding(placement)

        excluded =
          epochs
          |> MapSet.union(Map.get(lineage.epochs, relative, MapSet.new()))
          |> MapSet.put(old["executor_epoch"])

        epoch = fresh_epoch(excluded)

        generation = %{
          old
          | "executor_epoch" => epoch,
            "generation_id" => Base.encode16(<<epoch::unsigned-256>>, case: :lower),
            "root_binding" => binding
        }

        bytes = :erlang.term_to_binary(generation, [:deterministic])
        {:ok, ^generation} = Ledger.decode_bytes(bytes, "local_executor_generation_v1")

        {:ok, source_ledger_binding} =
          RestoreCodec.ledger_binding(declaration["source_placement"])

        candidate = %{
          "relative_root" => relative,
          "executor_identity" => declaration["executor_identity"],
          "source_generation_bytes" => original,
          "destination_generation_bytes" => bytes,
          "source_ledger_binding" => source_ledger_binding,
          "destination_ledger_placement" => placement,
          "destination_ledger_binding" => binding
        }

        {candidate, MapSet.put(epochs, epoch)}
      end)

    intent =
      encode!(
        :intent,
        common(plan, "loopex_current_restore_intent_v1")
        |> Map.merge(%{
          "plan_digest" => plan_digest,
          "plan" => plan,
          "prior_lineage_sha256" => plan["prior_lineage_sha256"],
          "source_state_binding" => source_binding,
          "destination_state_placement" => destination,
          "destination_state_binding" => destination_binding,
          "generations" => candidates
        })
      )

    intent_hash = hash(intent)

    ledgers =
      Enum.map(candidates, fn candidate ->
        relative = candidate["relative_root"]

        binding_fields =
          Map.take(candidate, [
            "relative_root",
            "source_ledger_binding",
            "destination_ledger_binding"
          ])

        shared = %{
          "source_state_binding" => source_binding,
          "destination_state_binding" => destination_binding,
          "source_generation_sha256" => hash(candidate["source_generation_bytes"]),
          "destination_generation_sha256" => hash(candidate["destination_generation_bytes"])
        }

        ledger_intent =
          encode!(
            :ledger_intent,
            proof(plan, "loopex_current_restore_ledger_intent_v1", intent_hash)
            |> Map.merge(binding_fields)
            |> Map.merge(shared)
          )

        retired =
          if plan["source_status"] == "available" do
            encode!(
              :ledger_retired,
              proof(plan, "loopex_current_restore_ledger_retired_v1", intent_hash)
              |> Map.merge(Map.delete(binding_fields, "destination_ledger_binding"))
              |> Map.merge(shared)
              |> Map.put("ledger_intent_sha256", hash(ledger_intent))
            )
          end

        entry = Enum.find(entries, &(&1["path"] == Path.join(relative, "generation")))

        %{
          relative: relative,
          directory: Path.join([relative, "restore-lineage", ordinal(plan)]),
          intent: ledger_intent,
          retired: retired,
          candidate: candidate["destination_generation_bytes"],
          original: candidate["source_generation_bytes"],
          mode: entry["mode"],
          binding: candidate["destination_ledger_binding"]
        }
      end)

    retirement =
      encode!(
        :source_retirement,
        proof(plan, "loopex_current_restore_source_retirement_v1", intent_hash)
        |> Map.merge(%{
          "disposition" =>
            if(plan["source_status"] == "available",
              do: "source_retired",
              else: "lost_source_host_excluded"
            ),
          "source_state_binding" => source_binding,
          "destination_state_binding" => destination_binding,
          "host_evidence_sha256" => plan["host_attestation"]["evidence_sha256"],
          "ledger_retirements" =>
            Enum.map(
              ledgers,
              &%{
                "relative_root" => &1.relative,
                "record_sha256" => if(&1.retired, do: hash(&1.retired), else: nil)
              }
            )
        })
      )

    ledgers =
      Enum.map(ledgers, fn ledger ->
        record =
          encode!(
            :ledger_committed,
            proof(plan, "loopex_current_restore_ledger_committed_v1", intent_hash)
            |> Map.merge(%{
              "relative_root" => ledger.relative,
              "ledger_intent_sha256" => hash(ledger.intent),
              "source_retirement_sha256" => hash(retirement),
              "destination_state_binding" => destination_binding,
              "destination_ledger_binding" => ledger.binding,
              "destination_generation_sha256" => hash(ledger.candidate)
            })
          )

        Map.put(ledger, :committed, record)
      end)

    activation_entries =
      entries
      |> Map.new(&{&1["path"], &1})
      |> replace_generations(ledgers)
      |> add_records([
        {root_admin,
         [{"baseline", baseline}, {"intent", intent}, {"source-retirement", retirement}]}
        | Enum.map(
            ledgers,
            fn ledger ->
              records = [{"intent", ledger.intent}]

              records =
                if ledger.retired,
                  do: records ++ [{"source-retired", ledger.retired}],
                  else: records

              {ledger.directory, records}
            end
          )
      ])

    activation = manifest!(activation_entries)

    committed =
      encode!(
        :committed,
        proof(plan, "loopex_current_restore_committed_v1", intent_hash)
        |> Map.merge(%{
          "plan_digest" => plan_digest,
          "prior_lineage_sha256" => plan["prior_lineage_sha256"],
          "baseline_manifest_sha256" => hash(baseline),
          "activation_manifest_sha256" => hash(activation),
          "source_retirement_sha256" => hash(retirement),
          "destination_state_binding" => destination_binding,
          "ledger_proofs" =>
            Enum.map(
              ledgers,
              &%{"relative_root" => &1.relative, "record_sha256" => hash(&1.committed)}
            )
        })
      )

    final =
      activation_entries
      |> add_records([
        {root_admin, [{"committed", committed}]}
        | Enum.map(ledgers, &{&1.directory, [{"committed", &1.committed}]})
      ])
      |> manifest!()

    receipt =
      common(plan, "loopex_current_restore_receipt_v1")
      |> Map.merge(%{
        "plan_digest" => plan_digest,
        "intent_sha256" => intent_hash,
        "committed_sha256" => hash(committed),
        "source_retirement_sha256" => hash(retirement),
        "baseline_manifest_sha256" => hash(baseline),
        "activation_manifest_sha256" => hash(activation),
        "prior_lineage_sha256" => plan["prior_lineage_sha256"],
        "destination_state_binding" => destination_binding,
        "ledger_count" => length(ledgers)
      })

    encode!(:receipt, receipt)

    ensure!(
      match?({:ok, _}, RestoreCodec.manifest(activation, max_total)),
      "inventory_limit_exceeded"
    )

    ensure!(match?({:ok, _}, RestoreCodec.manifest(final, max_total)), "inventory_limit_exceeded")

    %{
      intent: intent,
      retirement: retirement,
      ledgers: ledgers,
      activation: activation,
      final: final,
      committed: committed,
      receipt: receipt
    }
  end

  defp replace_generations(entries, ledgers),
    do:
      Enum.reduce(ledgers, entries, fn ledger, acc ->
        path = Path.join(ledger.relative, "generation")

        Map.update!(
          acc,
          path,
          &%{&1 | "size" => byte_size(ledger.candidate), "sha256" => hash(ledger.candidate)}
        )
      end)

  defp add_records(entries, records),
    do:
      Enum.reduce(records, entries, fn {directory, files}, acc ->
        acc =
          Enum.reduce(prefixes(directory), acc, fn path, map ->
            Map.put_new(map, path, %{
              "path" => path,
              "kind" => "directory",
              "mode" => 0o700,
              "size" => 0,
              "sha256" => nil
            })
          end)

        Enum.reduce(files, acc, fn {name, bytes}, map ->
          path = Path.join(directory, name)

          Map.put(map, path, %{
            "path" => path,
            "kind" => "regular",
            "mode" => 0o600,
            "size" => byte_size(bytes),
            "sha256" => hash(bytes)
          })
        end)
      end)

  defp manifest!(entries),
    do:
      encode!(:manifest, [
        "loopex:current-state-manifest:v1",
        entries |> Map.values() |> Enum.sort_by(& &1["path"])
      ])

  defp admin_directories!(root, relative, entries, io) do
    baseline = Map.new(entries, &{&1["path"], &1})

    Enum.each(prefixes(relative), fn path ->
      case baseline[path] do
        %{"kind" => "directory", "mode" => mode} ->
          value!(io.({:require_directory, Path.join(root, path), mode}))

        nil ->
          value!(io.({:ensure_admin_directory, Path.join(root, path)}))

        _ ->
          throw({:restore_refusal, "invalid_current_history"})
      end
    end)
  end

  defp prefixes(relative),
    do:
      relative
      |> Path.split()
      |> Enum.scan(fn component, parent -> Path.join(parent, component) end)

  defp publish!(root, relative, bytes, io) do
    path = Path.join(root, relative)
    value!(io.({:publish, path, path <> ".tmp", bytes, 0o600, :absent}))
  end

  defp workspace!(plan, placement) do
    reference =
      WorkspaceIdentity.from_verified_root(
        placement["expanded_root"],
        {placement["major_device"], placement["inode"]}
      )

    ensure!(reference == plan["workspace"]["workspace_ref"], "invalid_placement")
  end

  defp admin_entry?(entry),
    do: Enum.any?(Path.split(entry["path"]), &(&1 in [".loopex-restore", "restore-lineage"]))

  defp ordinal(plan),
    do: (plan["prior_restore_count"] + 1) |> Integer.to_string() |> String.pad_leading(8, "0")

  defp root_admin(plan), do: Path.join([".loopex-restore", "lineage", ordinal(plan)])

  defp common(plan, kind),
    do: %{"kind" => kind, "ordinal" => plan["prior_restore_count"] + 1, "tx_id" => plan["tx_id"]}

  defp proof(plan, kind, intent), do: Map.put(common(plan, kind), "intent_sha256", intent)
  defp phase(io, phase), do: value!(io.({:restore_phase, phase}))

  defp encode!(type, value) do
    case RestoreCodec.encode(type, value) do
      {:ok, bytes} -> bytes
      _ -> throw({:restore_refusal, "inventory_limit_exceeded"})
    end
  end

  defp hash(bytes), do: RestoreCodec.digest_bytes(bytes)
  defp random_hex, do: :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)

  defp fresh_epoch(excluded) do
    <<epoch::unsigned-256>> = :crypto.strong_rand_bytes(32)
    if epoch == 0 or MapSet.member?(excluded, epoch), do: fresh_epoch(excluded), else: epoch
  end

  defp ensure!(true, _code), do: :ok
  defp ensure!(_, code), do: throw({:restore_refusal, code})
  defp value!({:ok, value}), do: value
  defp value!(_), do: throw({:restore_refusal, "inventory_unavailable"})
end
