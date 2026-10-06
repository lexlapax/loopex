defmodule Loopex.Executor.Local.RestoreGuard do
  @moduledoc """
  ## Concept

  Ordinary composition and Local opens refuse retired or incomplete restore
  placements. Checked current destination lineage selects preserved identities.

  ## Technical depth

  This private reader shares Local's existing synchronous startup IO posture.
  Exact file, path, mode, byte and lineage-count ceilings bound admission. It
  adds no elapsed-time, cancellation or joined administrative-cleanup guarantee;
  restore and lookup retain their separate explicit owned-IO limits. The same
  closed chain reducer accepts manifest-bound bytes from restore's original
  worker; that private seam performs no IO and grants no executor authority. Claim
  deadlines remain the original caller's deadlines and are rechecked afterward.
  """

  alias Loopex.Executor.Local.RestoreCodec
  @root_admin ".loopex-restore"
  @record_cap 65_536

  @doc false
  def state(root) do
    root = Path.expand(root)

    try do
      claim_absent!(root)

      case File.lstat(Path.join(root, @root_admin)) do
        {:error, :enoent} -> {:ok, :ordinary}
        {:ok, _} -> {:ok, checked_state!(root)}
        _ -> throw(:restore_incomplete)
      end
    rescue
      _ -> {:error, :history_invalid}
    catch
      reason when reason in [:source_retired, :restore_incomplete, :history_invalid] ->
        {:error, reason}
    end
  end

  @doc false
  def ledger(root) do
    root = Path.expand(root)

    try do
      case File.lstat(Path.join(root, "restore-lineage")) do
        {:error, :enoent} ->
          :ok

        {:ok, _} ->
          ordinals = ordinals!(Path.join(root, "restore-lineage"))

          intent =
            record!(
              :ledger_intent,
              Path.join([root, "restore-lineage", List.last(ordinals), "intent"])
            )

          relative = intent["relative_root"]
          state_root = enclosing_root!(root, relative)

          case state(state_root) do
            {:ok, %{candidates: candidates}} ->
              candidate = Map.fetch!(candidates, relative)
              ensure!(candidate["destination_ledger_placement"]["expanded_root"] == root)
              ensure!(ordinals == candidate[:covered_ordinals])

              ensure!(
                read!(Path.join(root, "generation"), 2048, :baseline) ==
                  candidate["destination_generation_bytes"]
              )

              :ok

            {:error, reason} ->
              throw(reason)

            _ ->
              throw(:restore_incomplete)
          end

        _ ->
          throw(:restore_incomplete)
      end
    rescue
      _ -> {:error, {:ledger_unavailable, :history_invalid}}
    catch
      reason when reason in [:source_retired, :restore_incomplete, :history_invalid] ->
        {:error, {:ledger_unavailable, reason}}
    end
  end

  @doc false
  def identity(state_root, relative, ordinary) do
    case state(state_root) do
      {:ok, :ordinary} ->
        {:ok, ordinary}

      {:ok, %{candidates: candidates}} ->
        case Map.fetch(candidates, relative) do
          {:ok, candidate} -> {:ok, candidate["executor_identity"]}
          :error -> {:ok, ordinary}
        end

      error ->
        error
    end
  end

  # Concept: prior lineage uses the same semantic reducer as ordinary opens.
  # Technical depth: restore supplies manifest-bound bytes captured and closed by
  # its original IO worker. Placements are the retained source captures, so older
  # unavailable roots are never opened and copied backup inodes grant no authority.
  @doc false
  def validate_captured_lineage(plan, entries, files) do
    try do
      root = plan["source_state_root"]
      index = Map.new(entries, &{&1["path"], &1})

      placements =
        Map.new(plan["ledgers"], fn ledger ->
          {Path.join(root, ledger["relative_root"]), ledger["source_placement"]}
        end)
        |> Map.put(root, plan["source_state_placement"])

      context = %{root: root, index: index, files: files, placements: placements}
      reserved = Enum.filter(entries, &reserved_entry?/1)
      {:ok, digest} = RestoreCodec.lineage_digest(reserved)
      ensure!(digest == plan["prior_lineage_sha256"])

      if plan["prior_restore_count"] == 0 do
        ensure!(reserved == [])
        {:ok, %{candidates: %{}, epochs: %{}, previous: 0}}
      else
        state = checked_state!({root, context})
        ensure!(state.previous == plan["prior_restore_count"])
        ensure!(reserved == state.lineage)
        if MapSet.member?(state.tx_ids, plan["tx_id"]), do: throw(:restore_conflict)
        declarations = Map.new(plan["ledgers"], &{&1["relative_root"], &1})

        Enum.each(state.candidates, fn {relative, candidate} ->
          declaration = Map.fetch!(declarations, relative)
          ensure!(candidate["executor_identity"] == declaration["executor_identity"])

          ensure!(
            hash(candidate["destination_generation_bytes"]) ==
              declaration["source_generation_sha256"]
          )
        end)

        Enum.each(reserved, fn entry ->
          path = entry["path"]

          ensure!(
            path == @root_admin or String.starts_with?(path, @root_admin <> "/") or
              Enum.any?(state.candidates, fn {relative, _} ->
                prefix = Path.join(relative, "restore-lineage")
                path == prefix or String.starts_with?(path, prefix <> "/")
              end)
          )
        end)

        {:ok, state}
      end
    rescue
      _ -> {:error, :history_invalid}
    catch
      :restore_conflict ->
        {:error, :restore_conflict}

      reason when reason in [:source_retired, :restore_incomplete, :history_invalid] ->
        {:error, :history_invalid}
    end
  end

  # Concept: lookup observes retained completion and uncertainty without admission.
  # Technical depth: this pure entry shares the committed lineage reducer, but
  # accepts a checked partial final ordinal. Every byte/placement is supplied by
  # the one owned lookup worker; captured reads have no live-IO fallback.
  @doc false
  def lookup_captured(root, tx_id, index, files, placements, claim) do
    context = %{root: root, index: index, files: files, placements: placements}
    captured = {root, context}

    try do
      admin = history_path(captured, @root_admin)
      if Map.has_key?(index, @root_admin) do
        admin_names = names!(admin)
        ensure!(admin_names in [[], ["lineage"]])
        names = if admin_names == [], do: [], else: names!(history_path(captured, [@root_admin, "lineage"]))
        ensure!(length(names) <= 64)
        ensure!(names == if(names == [], do: [], else: Enum.map(1..length(names), &ordinal/1)))
        if names == [], do: lookup_ensure!(not is_nil(claim), "restore_history_invalid")
        initial = %{candidates: %{}, epochs: %{}, previous: 0, tx_ids: MapSet.new(), lineage: []}
        {state, receipts, pending} = Enum.reduce(names, {initial, %{}, nil}, fn name, {state, receipts, pending} ->
          ensure!(is_nil(pending))
          directory = history_path(captured, [@root_admin, "lineage", name])
          actual = names!(directory)
          allowed = ~w(baseline baseline.tmp intent intent.tmp source-retirement source-retirement.tmp committed committed.tmp)
          ensure!(Enum.all?(actual, &(&1 in allowed)))
          intent_name = cond do
            "intent" in actual -> "intent"
            "intent.tmp" in actual -> "intent.tmp"
            true -> nil
          end
          if is_nil(intent_name) do
            lookup_ensure!(not is_nil(claim), "restore_history_invalid")
            ensure!(Enum.all?(actual, &(&1 in ["baseline", "baseline.tmp"])))
            {state, receipts, lookup_observation(claim["tx_id"], nil, "destination_intent", "may_exist", claim)}
          else
            intent = record!(:intent, history_path(directory, intent_name))
            ensure!(intent["ordinal"] == state.previous + 1 and ordinal(intent["ordinal"]) == name)
            ensure!(intent["plan"]["prior_restore_count"] == state.previous)
            lookup_ensure!(not MapSet.member?(state.tx_ids, intent["tx_id"]), "restore_conflict")
            if name == List.last(names) do
              lookup_claim_intent!(claim, root, intent)
              lookup_ensure!(root in [intent["plan"]["source_state_root"], intent["plan"]["destination_state_root"]], "physical_destination_changed")
              expected_placement = if root == intent["plan"]["destination_state_root"],
                do: intent["destination_state_placement"], else: intent["plan"]["source_state_placement"]
              lookup_ensure!(placements[root] == expected_placement, "physical_destination_changed")
            end
            phase = if root == intent["plan"]["source_state_root"],
              do: lookup_outgoing!(captured, directory, intent, actual, state),
              else: lookup_partial!(captured, directory, intent, actual, state)
            complete = is_nil(phase) and root == intent["plan"]["destination_state_root"]
            if complete do
              next = complete_transition!(captured, directory, intent, state)
              receipt = lookup_receipt!(directory, intent)
              {next, Map.put(receipts, intent["tx_id"], receipt), nil}
            else
              phase = phase || "destination_generations"
              lookup_pending_previous!(captured, state, intent)
              {state, receipts, lookup_observation(intent["tx_id"], intent["ordinal"], phase,
                if(intent_name == "intent", do: "validated", else: "may_exist"), claim)}
            end
          end
        end)
        if state.previous > 0 and (is_nil(pending) or pending["intent"] == "may_exist" and is_nil(pending["ordinal"]) and pending["tx_id"] != tx_id),
          do: lookup_current!(captured, state)
        if names == [], do: lookup_ensure!(claim["tx_id"] == tx_id, "restore_conflict")
        if pending && pending["tx_id"] == tx_id do
          {:pending, pending}
        else
          case Map.fetch(receipts, tx_id) do
            {:ok, receipt} ->
              current = is_nil(pending) and receipt["ordinal"] == state.previous
              if current do
                if claim do
                  lookup_ensure!(claim["tx_id"] == tx_id, "restore_conflict")
                  {:pending, lookup_observation(tx_id, receipt["ordinal"], "claim_release", "validated", claim)}
                else
                  {:committed, %{"receipt" => receipt, "view" => "current"}}
                end
              else
                {:committed, %{"receipt" => receipt, "view" => "historical"}}
              end
            :error ->
              if names == [],
                do: {:pending, lookup_observation(tx_id, nil, "destination_intent", "may_exist", claim)},
                else: lookup_absent_or_claim(tx_id, claim)
          end
        end
      else
        lookup_absent_or_claim(tx_id, claim)
      end
    rescue
      _error in [MatchError, KeyError, ArgumentError] -> lookup_failure(tx_id, "restore_history_invalid")
    catch
      {:lookup_refusal, code} -> lookup_failure(tx_id, code)
      :history_invalid -> lookup_failure(tx_id, "restore_history_invalid")
      :restore_incomplete -> lookup_failure(tx_id, "restore_history_invalid")
    end
  end

  defp lookup_absent_or_claim(tx_id, nil),
    do: {:absent, %{"tx_id" => tx_id, "observation" => "not_present"}}

  defp lookup_absent_or_claim(tx_id, claim) do
    lookup_ensure!(claim["tx_id"] == tx_id, "restore_conflict")
    {:pending, lookup_observation(tx_id, nil, "claim", "may_exist", claim)}
  end

  defp lookup_observation(tx_id, ordinal, phase, intent, claim) do
    observation = %{"kind" => "loopex_current_restore_observation_v1", "tx_id" => tx_id,
      "ordinal" => ordinal, "phase" => phase, "intent" => intent, "cleanup" => "joined",
      "claim" => if(is_nil(claim), do: "none", else: "retained"), "reason" => "none"}
    {:ok, _} = RestoreCodec.encode(:observation, observation)
    observation
  end

  defp lookup_failure(tx_id, code),
    do: {:error, %{"kind" => "loopex_current_restore_lookup_refusal_v1", "tx_id" => tx_id,
      "code" => code, "cleanup" => "joined"}}

  defp lookup_ensure!(true, _code), do: :ok
  defp lookup_ensure!(_, code), do: throw({:lookup_refusal, code})

  # Concept: an administrative claim names the actual current transition, not the queried historical receipt.
  # Technical depth: its canonical digest, root role and transaction must all agree with the retained final intent.
  defp lookup_claim_intent!(nil, _root, _intent), do: :ok
  defp lookup_claim_intent!(claim, root, intent) do
    role = cond do
      root == intent["plan"]["destination_state_root"] -> "destination"
      root == intent["plan"]["source_state_root"] -> "source"
      true -> nil
    end
    lookup_ensure!(not is_nil(role) and claim["state_root"] == root and claim["role"] == role and
      claim["tx_id"] == intent["tx_id"] and claim["plan_digest"] == intent["plan_digest"], "restore_conflict")
  end

  # Concept: a pending higher transition cannot hide an earlier ledger's present binding.
  # Technical depth: named replacements admit only their captured source/destination generation;
  # sparse unmentioned candidates retain their previous placement, generation, mode and ordinal coverage.
  defp lookup_pending_previous!(root, previous, intent) do
    outgoing = history_root(root) == intent["plan"]["source_state_root"]
    named = Map.new(intent["generations"], &{&1["relative_root"], &1})
    if previous.previous > 0 and outgoing,
      do: lookup_ensure!(placement!(root) == previous.latest["destination_state_placement"], "physical_destination_changed")
    Enum.each(previous.candidates, fn {relative, prior} ->
      ledger = history_path(root, relative)
      replacement = named[relative]
      expected = cond do
        is_nil(replacement) -> prior["destination_ledger_placement"]
        outgoing -> intent["plan"]["ledgers"] |> Enum.find(&(&1["relative_root"] == relative)) |> Map.fetch!("source_placement")
        true -> replacement["destination_ledger_placement"]
      end
      lookup_ensure!(placement!(ledger) == expected, "physical_destination_changed")
      generation = read!(history_path(ledger, "generation"), 2048, :baseline)
      allowed = cond do
        is_nil(replacement) -> [prior["destination_generation_bytes"]]
        outgoing -> [replacement["source_generation_bytes"]]
        true -> [replacement["source_generation_bytes"], replacement["destination_generation_bytes"]]
      end
      ensure!(generation in allowed)
      ensure!(generation_mode!(history_path(ledger, "generation")) == prior[:generation_mode])
      names = ordinals!(history_path(ledger, "restore-lineage"))
      tail = ordinal(intent["ordinal"])
      allowed_names = if replacement, do: [prior[:covered_ordinals], prior[:covered_ordinals] ++ [tail]],
        else: [prior[:covered_ordinals]]
      ensure!(names in allowed_names)
    end)
  end

  defp lookup_outgoing!(root, directory, intent, actual, previous) do
    ensure!(intent["plan"]["source_status"] == "available")
    ensure!(Enum.all?(actual, &(&1 in ~w(intent intent.tmp source-retirement source-retirement.tmp))))
    {:ok, lineage_hash} = RestoreCodec.lineage_digest(previous.lineage)
    ensure!(lineage_hash == intent["prior_lineage_sha256"])
    intent_bytes = read!(history_path(directory, if("intent" in actual, do: "intent", else: "intent.tmp")), @record_cap)
    intent_hash = hash(intent_bytes)
    if "intent" in actual and "intent.tmp" in actual,
      do: ensure!(read!(history_path(directory, "intent.tmp"), @record_cap) == intent_bytes)
    retired = lookup_optional_record(root, directory, "source-retirement", :source_retirement, actual)
    if retired do
      common!(retired, intent, intent_hash)
      ensure!(retired["disposition"] == "source_retired")
      Enum.each(["source_state_binding", "destination_state_binding"], &ensure!(retired[&1] == intent[&1]))
      ensure!(retired["host_evidence_sha256"] == intent["plan"]["host_attestation"]["evidence_sha256"])
      ensure!(Enum.map(retired["ledger_retirements"], & &1["relative_root"]) == Enum.map(intent["generations"], & &1["relative_root"]))
    end
    Enum.each(intent["generations"], fn candidate ->
      relative = candidate["relative_root"]
      if prior = previous.candidates[relative],
        do: ensure!(prior["destination_generation_bytes"] == candidate["source_generation_bytes"])
      ledger = history_path(root, relative)
      {:ok, binding} = RestoreCodec.ledger_binding(placement!(ledger))
      lookup_ensure!(binding == candidate["source_ledger_binding"], "physical_destination_changed")
      ensure!(read!(history_path(ledger, "generation"), 2048, :baseline) == candidate["source_generation_bytes"])
      tail = history_path(ledger, ["restore-lineage", ordinal(intent["ordinal"])])
      {path, context} = tail
      if Map.has_key?(context.index, Path.relative_to(path, context.root)) do
        names = names!(tail)
        ensure!(Enum.all?(names, &(&1 in ~w(intent intent.tmp source-retired source-retired.tmp))))
        ledger_intent = lookup_optional_record(root, tail, "intent", :ledger_intent, names)
        ledger_retired = lookup_optional_record(root, tail, "source-retired", :ledger_retired, names)
        if ledger_intent do
          common!(ledger_intent, intent, intent_hash)
          candidate_bindings!(ledger_intent, intent, candidate)
        end
        if ledger_retired do
          ensure!(not is_nil(ledger_intent))
          common!(ledger_retired, intent, intent_hash)
          candidate_bindings!(ledger_retired, intent, candidate)
          ensure!(ledger_retired["ledger_intent_sha256"] == hash(read!(history_path(tail, "intent"), @record_cap)))
        end
        if retired do
          ensure!(not is_nil(ledger_retired))
          ensure!(Enum.find(retired["ledger_retirements"], &(&1["relative_root"] == relative))["record_sha256"] == hash(read!(history_path(tail, "source-retired"), @record_cap)))
        end
      else
        ensure!(is_nil(retired))
      end
    end)
    if is_nil(retired) or Enum.any?(actual, &String.ends_with?(&1, ".tmp")),
      do: "source_retirement", else: "destination_generations"
  end

  defp lookup_partial!(root, directory, intent, actual, previous) do
    hash = hash(read!(history_path(directory, if("intent" in actual, do: "intent", else: "intent.tmp")), @record_cap))
    baseline = read!(history_path(directory, "baseline"), 4_194_304)
    ensure!(hash(baseline) == intent["plan"]["manifest_sha256"])
    {:ok, entries} = RestoreCodec.manifest(baseline, 18_446_744_073_709_551_615)
    lineage = Enum.filter(entries, &reserved_entry?/1)
    ensure!(lineage == previous.lineage)
    {:ok, lineage_digest} = RestoreCodec.lineage_digest(lineage)
    ensure!(lineage_digest == intent["prior_lineage_sha256"])
    Enum.each(lineage, &verify_historical_entry!(root, &1))
    if "intent.tmp" in actual and "intent" in actual,
      do: ensure!(read!(history_path(directory, "intent.tmp"), @record_cap) == read!(history_path(directory, "intent"), @record_cap))
    if "baseline.tmp" in actual, do: ensure!(read!(history_path(directory, "baseline.tmp"), 4_194_304) == baseline)
    Enum.each(intent["generations"], fn candidate ->
      relative = candidate["relative_root"]
      generation_entry = Enum.find(entries, &(&1["path"] == Path.join(relative, "generation")))
      ensure!(not is_nil(generation_entry) and generation_entry["kind"] == "regular")
      ensure!(generation_entry["sha256"] == hash(candidate["source_generation_bytes"]))
      ensure!(generation_entry["size"] == byte_size(candidate["source_generation_bytes"]))
      if old = previous.candidates[relative], do: ensure!(old["destination_generation_bytes"] == candidate["source_generation_bytes"])
      {:ok, source_generation} = RestoreCodec.decode(:generation, candidate["source_generation_bytes"])
      {:ok, destination_generation} = RestoreCodec.decode(:generation, candidate["destination_generation_bytes"])
      epochs = Map.get(previous.epochs, relative, MapSet.new()) |> MapSet.put(source_generation["executor_epoch"])
      ensure!(not MapSet.member?(epochs, destination_generation["executor_epoch"]))
    end)
    retired = lookup_optional_record(root, directory, "source-retirement", :source_retirement, actual)
    committed = lookup_optional_record(root, directory, "committed", :committed, actual)
    if retired do
      common!(retired, intent, hash)
      Enum.each(["source_state_binding", "destination_state_binding"], &ensure!(retired[&1] == intent[&1]))
      ensure!(retired["host_evidence_sha256"] == intent["plan"]["host_attestation"]["evidence_sha256"])
      ensure!(retired["disposition"] == if(intent["plan"]["source_status"] == "available", do: "source_retired", else: "lost_source_host_excluded"))
      ensure!(Enum.map(retired["ledger_retirements"], & &1["relative_root"]) == Enum.map(intent["generations"], & &1["relative_root"]))
    end
    if committed do
      ensure!(not is_nil(retired))
      common!(committed, intent, hash)
      ensure!(committed["plan_digest"] == intent["plan_digest"])
      ensure!(committed["prior_lineage_sha256"] == intent["prior_lineage_sha256"])
      ensure!(committed["baseline_manifest_sha256"] == hash(baseline))
      ensure!(committed["source_retirement_sha256"] == hash(read!(history_path(directory, "source-retirement"), @record_cap)))
      ensure!(committed["destination_state_binding"] == intent["destination_state_binding"])
    end
    ledger_phases = Enum.map(intent["generations"], fn candidate ->
      lookup_ledger!(root, intent, candidate, retired, committed, hash)
    end)
    cond do
      "baseline.tmp" in actual or "intent.tmp" in actual -> "destination_intent"
      is_nil(retired) or "source-retirement.tmp" in actual -> "source_retirement"
      "destination_generations" in ledger_phases -> "destination_generations"
      is_nil(committed) or "committed.tmp" in actual or "destination_proofs" in ledger_phases -> "destination_proofs"
      true -> nil
    end
  end

  defp lookup_optional_record(_root, directory, name, type, actual) do
    file = cond do
      name in actual -> name
      (name <> ".tmp") in actual -> name <> ".tmp"
      true -> nil
    end
    if file do
      record = record!(type, history_path(directory, file))
      if name in actual and (name <> ".tmp") in actual,
        do: ensure!(read!(history_path(directory, name), @record_cap) == read!(history_path(directory, name <> ".tmp"), @record_cap))
      record
    end
  end

  defp lookup_ledger!({path, context} = root, intent, candidate, retired, committed, intent_hash) do
    relative = candidate["relative_root"]
    if is_nil(committed), do: lookup_ensure!(placement!(history_path(root, relative)) == candidate["destination_ledger_placement"], "physical_destination_changed")
    directory = history_path(root, [relative, "restore-lineage", ordinal(intent["ordinal"])])
    if not Map.has_key?(context.index, Path.relative_to(history_root(directory), path)) do
      ensure!(is_nil(committed))
      "destination_generations"
    else
      actual = names!(directory)
      ensure!(Enum.all?(actual, &(&1 in ~w(intent intent.tmp source-retired source-retired.tmp committed committed.tmp))))
      ledger_intent = lookup_optional_record(root, directory, "intent", :ledger_intent, actual)
      ledger_retired = lookup_optional_record(root, directory, "source-retired", :ledger_retired, actual)
      proof = lookup_optional_record(root, directory, "committed", :ledger_committed, actual)
      if ledger_intent do
        common!(ledger_intent, intent, intent_hash)
        candidate_bindings!(ledger_intent, intent, candidate)
      end
      if ledger_retired do
        ensure!(not is_nil(ledger_intent) and intent["plan"]["source_status"] == "available")
        common!(ledger_retired, intent, intent_hash)
        candidate_bindings!(ledger_retired, intent, candidate)
        ensure!(ledger_retired["ledger_intent_sha256"] == hash(read!(history_path(directory, "intent"), @record_cap)))
        if retired, do: ensure!(Enum.find(retired["ledger_retirements"], &(&1["relative_root"] == relative))["record_sha256"] == hash(read!(history_path(directory, "source-retired"), @record_cap)))
      end
      if proof do
        ensure!(not is_nil(ledger_intent) and not is_nil(retired))
        common!(proof, intent, intent_hash)
        ensure!(proof["relative_root"] == relative)
        ensure!(proof["ledger_intent_sha256"] == hash(read!(history_path(directory, "intent"), @record_cap)))
        ensure!(proof["source_retirement_sha256"] == hash(read!(history_path(history_path(root, [@root_admin, "lineage", ordinal(intent["ordinal"])]), "source-retirement"), @record_cap)))
        ensure!(proof["destination_state_binding"] == intent["destination_state_binding"])
        ensure!(proof["destination_ledger_binding"] == candidate["destination_ledger_binding"])
        ensure!(proof["destination_generation_sha256"] == hash(candidate["destination_generation_bytes"]))
        if committed, do: ensure!(Enum.find(committed["ledger_proofs"], &(&1["relative_root"] == relative))["record_sha256"] == hash(read!(history_path(directory, "committed"), @record_cap)))
      end
      generation = read!(history_path(root, [relative, "generation"]), 2048, :baseline)
      if is_nil(committed), do: ensure!(generation in [candidate["source_generation_bytes"], candidate["destination_generation_bytes"]])
      cond do
        is_nil(committed) and generation != candidate["destination_generation_bytes"] -> "destination_generations"
        is_nil(proof) or Enum.any?(actual, &String.ends_with?(&1, ".tmp")) -> "destination_proofs"
        true -> nil
      end
    end
  end

  defp lookup_current!(root, state) do
    lookup_ensure!(placement!(root) == state.latest["destination_state_placement"], "physical_destination_changed")
    Enum.each(state.candidates, fn {relative, candidate} ->
      ledger = history_path(root, relative)
      lookup_ensure!(placement!(ledger) == candidate["destination_ledger_placement"], "physical_destination_changed")
      ensure!(ordinals!(history_path(ledger, "restore-lineage")) == candidate[:covered_ordinals])
      ensure!(generation_mode!(history_path(ledger, "generation")) == candidate[:generation_mode])
      ensure!(read!(history_path(ledger, "generation"), 2048, :baseline) == candidate["destination_generation_bytes"])
    end)
  end

  defp lookup_receipt!(directory, intent) do
    committed_bytes = read!(history_path(directory, "committed"), @record_cap)
    {:ok, committed} = RestoreCodec.decode(:committed, committed_bytes)
    receipt = %{"kind" => "loopex_current_restore_receipt_v1", "tx_id" => intent["tx_id"],
      "ordinal" => intent["ordinal"], "plan_digest" => intent["plan_digest"],
      "intent_sha256" => hash(read!(history_path(directory, "intent"), @record_cap)),
      "committed_sha256" => hash(committed_bytes),
      "source_retirement_sha256" => committed["source_retirement_sha256"],
      "baseline_manifest_sha256" => committed["baseline_manifest_sha256"],
      "activation_manifest_sha256" => committed["activation_manifest_sha256"],
      "prior_lineage_sha256" => committed["prior_lineage_sha256"],
      "destination_state_binding" => committed["destination_state_binding"],
      "ledger_count" => length(intent["generations"])}
    {:ok, _} = RestoreCodec.encode(:receipt, receipt)
    receipt
  end

  defp reserved_entry?(entry),
    do: Enum.any?(Path.split(entry["path"]), &(&1 in [@root_admin, "restore-lineage"]))

  defp history_root({path, _context}), do: path
  defp history_root(path), do: path

  defp history_path({path, context}, parts),
    do: {Path.join([path | List.wrap(parts)]), context}

  defp history_path(path, parts), do: Path.join([path | List.wrap(parts)])

  defp generation_mode!({path, context}) do
    entry = captured_entry!(path, context)
    ensure!(entry["kind"] == "regular")
    entry["mode"]
  end

  defp generation_mode!(path) do
    {:ok, stat} = File.lstat(path)
    Bitwise.band(stat.mode, 0o7777)
  end

  defp captured_entry!(path, context),
    do: Map.fetch!(context.index, Path.relative_to(path, context.root))

  defp checked_state!(root) do
    names!(history_path(root, @root_admin), ["lineage"])
    ordinals = ordinals!(history_path(root, [@root_admin, "lineage"]))
    ensure!(ordinals == Enum.map(1..length(ordinals), &ordinal/1))
    placement = placement!(root)
    {:ok, binding} = RestoreCodec.state_binding(placement)

    result =
      Enum.reduce(
        ordinals,
        %{candidates: %{}, epochs: %{}, previous: 0, tx_ids: MapSet.new(), lineage: []},
        fn name, state ->
          directory = history_path(root, [@root_admin, "lineage", name])
          intent = record!(:intent, history_path(directory, "intent"))
          ensure!(intent["ordinal"] == state.previous + 1 and ordinal(intent["ordinal"]) == name)
          ensure!(intent["plan"]["prior_restore_count"] == state.previous)
          ensure!(not MapSet.member?(state.tx_ids, intent["tx_id"]))
          actual_names = names!(directory)

          ensure!(
            Enum.all?(
              actual_names,
              &(&1 in ["baseline", "intent", "source-retirement", "committed"])
            )
          )

          if intent["source_state_binding"] == binding and
               intent["plan"]["source_state_root"] == history_root(root),
             do: throw(:source_retired)

          if actual_names != Enum.sort(["baseline", "intent", "source-retirement", "committed"]),
            do: throw(:restore_incomplete)

          complete_transition!(root, directory, intent, state)
        end
      )

    Enum.each(result.candidates, fn {relative, candidate} ->
      ledger = history_path(root, relative)
      observed = placement!(ledger)
      ensure!(observed == candidate["destination_ledger_placement"])
      ensure!(ordinals!(history_path(ledger, "restore-lineage")) == candidate[:covered_ordinals])
      ensure!(generation_mode!(history_path(ledger, "generation")) == candidate[:generation_mode])

      ensure!(
        read!(history_path(ledger, "generation"), 2048, :baseline) ==
          candidate["destination_generation_bytes"]
      )
    end)

    # Highest transition governs this physical root; older destination placements
    # are captured history and never compared to today's directory identity.
    ensure!(result.latest["destination_state_placement"] == placement)
    if is_tuple(root), do: result, else: %{candidates: result.candidates, latest: result.latest}
  end

  defp complete_transition!(root, directory, intent, previous) do
    intent_bytes = read!(history_path(directory, "intent"), @record_cap)
    intent_hash = hash(intent_bytes)
    baseline = read!(history_path(directory, "baseline"), 4_194_304)
    {:ok, entries} = RestoreCodec.manifest(baseline, 18_446_744_073_709_551_615)
    ensure!(hash(baseline) == intent["plan"]["manifest_sha256"])

    lineage =
      Enum.filter(
        entries,
        &Enum.any?(Path.split(&1["path"]), fn part -> part in [@root_admin, "restore-lineage"] end)
      )

    {:ok, lineage_hash} = RestoreCodec.lineage_digest(lineage)
    ensure!(lineage_hash == intent["prior_lineage_sha256"])
    # Concept: every earlier administrative fact remains in the complete cut.
    # Technical depth: compare the full prior reconstructed projection, not only
    # whatever subset the next baseline happens to list. Ordinary runtime files
    # may evolve and are excluded only from this lineage comparison.
    ensure!(lineage == previous.lineage)
    Enum.each(lineage, fn entry -> verify_historical_entry!(root, entry) end)
    retired_bytes = read!(history_path(directory, "source-retirement"), @record_cap)
    {:ok, retired} = RestoreCodec.decode(:source_retirement, retired_bytes)
    common!(retired, intent, intent_hash)
    ensure!(retired["source_state_binding"] == intent["source_state_binding"])
    ensure!(retired["destination_state_binding"] == intent["destination_state_binding"])

    ensure!(
      retired["host_evidence_sha256"] == intent["plan"]["host_attestation"]["evidence_sha256"]
    )

    available = intent["plan"]["source_status"] == "available"

    ensure!(
      retired["disposition"] ==
        if(available, do: "source_retired", else: "lost_source_host_excluded")
    )

    committed_bytes = read!(history_path(directory, "committed"), @record_cap)
    {:ok, committed} = RestoreCodec.decode(:committed, committed_bytes)
    common!(committed, intent, intent_hash)
    ensure!(committed["plan_digest"] == intent["plan_digest"])
    ensure!(committed["prior_lineage_sha256"] == intent["prior_lineage_sha256"])
    ensure!(committed["baseline_manifest_sha256"] == hash(baseline))
    ensure!(committed["source_retirement_sha256"] == hash(retired_bytes))
    ensure!(committed["destination_state_binding"] == intent["destination_state_binding"])

    ensure!(
      Enum.map(committed["ledger_proofs"], & &1["relative_root"]) ==
        Enum.map(intent["generations"], & &1["relative_root"])
    )

    ensure!(
      Enum.map(retired["ledger_retirements"], & &1["relative_root"]) ==
        Enum.map(intent["generations"], & &1["relative_root"])
    )

    ordinal_name = ordinal(intent["ordinal"])

    {candidates, epochs, replacements, records, committed_records} =
      Enum.reduce(
        intent["generations"],
        {previous.candidates, previous.epochs, [], [], []},
        fn candidate, {candidates, epochs, replacements, records, committed_records} ->
          relative = candidate["relative_root"]
          ledger_directory = history_path(root, [relative, "restore-lineage", ordinal_name])

          expected_names =
            ["intent", "committed"] ++ if(available, do: ["source-retired"], else: [])

          names!(ledger_directory, expected_names)
          ledger_intent_bytes = read!(history_path(ledger_directory, "intent"), @record_cap)
          {:ok, ledger_intent} = RestoreCodec.decode(:ledger_intent, ledger_intent_bytes)
          common!(ledger_intent, intent, intent_hash)
          candidate_bindings!(ledger_intent, intent, candidate)
          proof_bytes = read!(history_path(ledger_directory, "committed"), @record_cap)
          {:ok, proof} = RestoreCodec.decode(:ledger_committed, proof_bytes)
          common!(proof, intent, intent_hash)
          ensure!(proof["relative_root"] == relative)
          ensure!(proof["ledger_intent_sha256"] == hash(ledger_intent_bytes))
          ensure!(proof["source_retirement_sha256"] == hash(retired_bytes))
          ensure!(proof["destination_state_binding"] == intent["destination_state_binding"])
          ensure!(proof["destination_ledger_binding"] == candidate["destination_ledger_binding"])

          ensure!(
            proof["destination_generation_sha256"] ==
              hash(candidate["destination_generation_bytes"])
          )

          ensure!(
            Enum.find(committed["ledger_proofs"], &(&1["relative_root"] == relative))[
              "record_sha256"
            ] == hash(proof_bytes)
          )

          files = [{"intent", ledger_intent_bytes}]

          files =
            if available do
              bytes = read!(history_path(ledger_directory, "source-retired"), @record_cap)
              {:ok, record} = RestoreCodec.decode(:ledger_retired, bytes)
              common!(record, intent, intent_hash)
              ensure!(record["ledger_intent_sha256"] == hash(ledger_intent_bytes))
              candidate_bindings!(record, intent, candidate)

              ensure!(
                Enum.find(retired["ledger_retirements"], &(&1["relative_root"] == relative))[
                  "record_sha256"
                ] == hash(bytes)
              )

              [{"source-retired", bytes} | files]
            else
              files
            end

          generation_entry =
            Enum.find(entries, &(&1["path"] == Path.join(relative, "generation")))

          ensure!(generation_entry["kind"] == "regular")
          ensure!(generation_entry["sha256"] == hash(candidate["source_generation_bytes"]))
          ensure!(generation_entry["size"] == byte_size(candidate["source_generation_bytes"]))

          {:ok, source_generation} =
            RestoreCodec.decode(:generation, candidate["source_generation_bytes"])

          {:ok, destination_generation} =
            RestoreCodec.decode(:generation, candidate["destination_generation_bytes"])

          if old = candidates[relative],
            do:
              ensure!(old["destination_generation_bytes"] == candidate["source_generation_bytes"])

          prior_epochs =
            Map.get(epochs, relative, MapSet.new())
            |> MapSet.put(source_generation["executor_epoch"])

          ensure!(not MapSet.member?(prior_epochs, destination_generation["executor_epoch"]))

          covered =
            case candidates[relative] do
              nil -> [ordinal_name]
              old -> old[:covered_ordinals] ++ [ordinal_name]
            end

          current =
            Map.merge(candidate, %{
              covered_ordinals: covered,
              generation_mode: generation_entry["mode"]
            })

          {Map.put(candidates, relative, current),
           Map.put(
             epochs,
             relative,
             MapSet.put(prior_epochs, destination_generation["executor_epoch"])
           ), [candidate | replacements],
           [{Path.join([relative, "restore-lineage", ordinal_name]), files} | records],
           [
             {Path.join([relative, "restore-lineage", ordinal_name]),
              [{"committed", proof_bytes}]}
             | committed_records
           ]}
        end
      )

    activation =
      reconstruct(entries, replacements, [
        {Path.join([@root_admin, "lineage", ordinal_name]),
         [{"baseline", baseline}, {"intent", intent_bytes}, {"source-retirement", retired_bytes}]}
        | records
      ])

    ensure!(hash(activation) == committed["activation_manifest_sha256"])
    {:ok, activation_entries} = RestoreCodec.manifest(activation, 18_446_744_073_709_551_615)

    final =
      reconstruct(activation_entries, [], [
        {Path.join([@root_admin, "lineage", ordinal_name]), [{"committed", committed_bytes}]}
        | committed_records
      ])

    {:ok, final_entries} = RestoreCodec.manifest(final, 18_446_744_073_709_551_615)

    %{
      candidates: candidates,
      epochs: epochs,
      previous: intent["ordinal"],
      latest: intent,
      tx_ids: MapSet.put(previous.tx_ids, intent["tx_id"]),
      lineage: Enum.filter(final_entries, &reserved_entry?/1)
    }
  end

  defp candidate_bindings!(record, intent, candidate) do
    Enum.each(["relative_root", "source_ledger_binding"], &ensure!(record[&1] == candidate[&1]))

    if Map.has_key?(record, "destination_ledger_binding"),
      do: ensure!(record["destination_ledger_binding"] == candidate["destination_ledger_binding"])

    Enum.each(
      ["source_state_binding", "destination_state_binding"],
      &ensure!(record[&1] == intent[&1])
    )

    ensure!(record["source_generation_sha256"] == hash(candidate["source_generation_bytes"]))

    ensure!(
      record["destination_generation_sha256"] == hash(candidate["destination_generation_bytes"])
    )
  end

  defp common!(record, intent, hash) do
    ensure!(
      record["ordinal"] == intent["ordinal"] and record["tx_id"] == intent["tx_id"] and
        record["intent_sha256"] == hash
    )
  end

  defp reconstruct(entries, candidates, additions) do
    index = Map.new(entries, &{&1["path"], &1})

    index =
      Enum.reduce(candidates, index, fn candidate, acc ->
        path = Path.join(candidate["relative_root"], "generation")

        Map.update!(
          acc,
          path,
          &%{
            &1
            | "size" => byte_size(candidate["destination_generation_bytes"]),
              "sha256" => hash(candidate["destination_generation_bytes"])
          }
        )
      end)

    index =
      Enum.reduce(additions, index, fn {directory, files}, acc ->
        acc =
          directory
          |> Path.split()
          |> Enum.scan(fn part, parent -> Path.join(parent, part) end)
          |> Enum.reduce(acc, fn path, map ->
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

    {:ok, bytes} =
      RestoreCodec.encode(:manifest, [
        "loopex:current-state-manifest:v1",
        index |> Map.values() |> Enum.sort_by(& &1["path"])
      ])

    bytes
  end

  defp verify_historical_entry!(root, entry) do
    path = history_path(root, entry["path"])

    if entry["kind"] == "regular" do
      bytes =
        read!(
          path,
          if(Path.basename(history_root(path)) == "baseline", do: 4_194_304, else: @record_cap)
        )

      ensure!(byte_size(bytes) == entry["size"] and hash(bytes) == entry["sha256"])
    else
      directory!(path)
    end
  end

  defp claim_absent!(root) do
    {:ok, digest} = RestoreCodec.claim_digest(root)
    path = Path.join(Path.dirname(root), ".loopex-restore-claim-" <> digest)

    case File.lstat(path) do
      {:error, :enoent} -> :ok
      _ -> throw(:restore_incomplete)
    end
  end

  defp enclosing_root!(ledger, relative) do
    parts = Path.split(relative)
    root = Enum.reduce(parts, ledger, fn _part, path -> Path.dirname(path) end)
    ensure!(Path.join(root, relative) == ledger)
    root
  end

  defp placement!({path, context}) do
    ensure!(captured_entry!(path, context)["kind"] == "directory")
    Map.fetch!(context.placements, path)
  end

  defp placement!(root) do
    Enum.each(ancestors(root), fn path ->
      {:ok, %File.Stat{type: :directory}} = File.lstat(path)
    end)

    {:ok, %File.Stat{type: :directory} = stat} = File.lstat(root)
    %{"expanded_root" => root, "major_device" => stat.major_device, "inode" => stat.inode}
  end

  defp ancestors("/"), do: ["/"]
  defp ancestors(root), do: [root | ancestors(Path.dirname(root))]

  defp directory!({path, context}) do
    entry = captured_entry!(path, context)
    ensure!(entry["kind"] == "directory" and entry["mode"] == 0o700)
    :ok
  end

  defp directory!(path) do
    {:ok, %File.Stat{type: :directory} = stat} = File.lstat(path)
    ensure!(Bitwise.band(stat.mode, 0o7777) == 0o700)
    :ok
  end

  defp names!({path, context} = captured) do
    directory!(captured)
    relative = Path.relative_to(path, context.root)

    names =
      context.index
      |> Map.keys()
      |> Enum.filter(&(Path.dirname(&1) == relative and &1 != relative))
      |> Enum.map(&Path.basename/1)

    ensure!(length(names) <= 64 and Enum.all?(names, &String.valid?/1))
    Enum.sort(names)
  end

  defp names!(path) do
    directory!(path)
    {:ok, names} = File.ls(path)
    ensure!(length(names) <= 64 and Enum.all?(names, &String.valid?/1))
    Enum.sort(names)
  end

  defp names!(path, expected), do: ensure!(names!(path) == Enum.sort(expected))

  defp ordinals!(path) do
    names = names!(path)

    ensure!(
      names != [] and
        Enum.all?(names, &Regex.match?(~r/\A000000(?:0[1-9]|[1-5][0-9]|6[0-4])\z/, &1))
    )

    names
  end

  defp record!(type, path) do
    {:ok, record} = RestoreCodec.decode(type, read!(path, @record_cap))
    record
  end

  defp read!(path, cap, role \\ :administrative)

  defp read!({path, context}, cap, role) do
    entry = captured_entry!(path, context)
    bytes = Map.fetch!(context.files, Path.relative_to(path, context.root))
    ensure!(entry["kind"] == "regular" and entry["size"] <= cap)
    ensure!(role == :baseline or entry["mode"] == 0o600)
    ensure!(byte_size(bytes) == entry["size"] and hash(bytes) == entry["sha256"])
    bytes
  end

  defp read!(path, cap, role) do
    {:ok, %File.Stat{type: :regular, links: 1, size: size} = before} = File.lstat(path)
    ensure!(size <= cap and (role == :baseline or Bitwise.band(before.mode, 0o7777) == 0o600))
    {:ok, descriptor} = :file.open(String.to_charlist(path), [:raw, :binary, :read])

    try do
      # Concept: descriptor and path identities use the same timestamp representation.
      # Technical depth: File.lstat defaults to universal time; raw reads default to local.
      {:ok, record} = :file.read_file_info(descriptor, time: :universal)
      ensure!(file_identity(File.Stat.from_record(record)) == file_identity(before))

      bytes =
        case :file.read(descriptor, cap + 1) do
          {:ok, bytes} -> bytes
          :eof -> <<>>
          _ -> throw(:history_invalid)
        end

      {:ok, current} = File.lstat(path)
      ensure!(file_identity(current) == file_identity(before) and byte_size(bytes) == size)
      bytes
    after
      :ok = :file.close(descriptor)
    end
  end

  defp file_identity(stat),
    do:
      {stat.type, stat.links, stat.size, stat.mode, stat.major_device, stat.inode, stat.mtime,
       stat.ctime}

  defp ordinal(number), do: number |> Integer.to_string() |> String.pad_leading(8, "0")
  defp hash(bytes), do: RestoreCodec.digest_bytes(bytes)
  defp ensure!(true), do: :ok
  defp ensure!(_), do: throw(:history_invalid)
end
