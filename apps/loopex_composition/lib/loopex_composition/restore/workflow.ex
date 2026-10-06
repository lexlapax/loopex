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
  continuation through source retirement reuses retained claim custody and exact
  native records. A private continuation installs exact retained generation prefixes
  and validates the complete activation manifest. Committed receipts, claim release and
  later proof-prefix continuation remain implementation work. The IO callback never
  starts another guardian or refreshes this invocation's work or cleanup allowance.
  """

  alias Loopex.Executor.Local.{Ledger, RestoreCodec, RestoreGuard}
  alias LoopexComposition.Restore.Audit
  alias LoopexComposition.WorkspaceIdentity

  # Concept: intake preserves an unfinished original transaction without acting on it.
  # Technical depth: both claims and their canonical candidates are captured by
  # this callback's original IO owner. Joined/rebooted host evidence is mandatory;
  # no reclaim, sync, copy, publication or candidate allocation follows intake.
  @doc false
  def pending_intake(plan, invocation, io) do
    phase(io, "claim")
    ensure!(plan["prior_restore_count"] < 64, "inventory_limit_exceeded")
    destination = plan["destination_state_root"]
    retained = pending!(destination, plan, invocation, io)
    value!(io.({:restore_observation_facts, retained.observation}))
    workspace!(plan, value!(io.({:placement, plan["workspace"]["root"]})))

    source =
      if plan["source_status"] == "available" do
        pending!(plan["source_state_root"], plan, invocation, io)
      else
        value!(io.({:lost_source_absent, plan["source_state_root"]}))
        nil
      end

    if source && source.intent,
      do: ensure!(source.intent == retained.intent, "restore_conflict")

    if is_nil(retained.intent) do
      # A partial staging copy is not an admitted baseline. This unit accepts
      # only the complete unchanged pre-intent cut; later prefix handling owns
      # staged administrative temporaries and publication continuation.
      max_total = invocation["max_total_file_bytes"]
      baseline = value!(io.({:manifest, plan["backup_state_root"], max_total}))
      ensure!(hash(baseline) == plan["manifest_sha256"], "inventory_mismatch")
      ensure!(value!(io.({:manifest, destination, max_total})) == baseline, "inventory_mismatch")

      if source,
        do:
          ensure!(
            value!(io.({:manifest, plan["source_state_root"], max_total})) == baseline,
            "inventory_mismatch"
          )

      retained = %{retained | baseline: baseline}
      {:ok, retained}
    else
      if source && is_nil(source.intent),
        do:
          ensure!(
            value!(
              io.({:manifest, plan["source_state_root"], invocation["max_total_file_bytes"]})
            ) == retained.baseline,
            "inventory_mismatch"
          )

      {:ok, retained}
    end
  catch
    {:restore_refusal, code} -> {:error, code}
    {:io_error, _} -> {:error, "inventory_unavailable"}
    {:stopped, _} -> {:error, "inventory_unavailable"}
  end

  defp pending!(root, plan, invocation, io) do
    case io.({:restore_pending_capture, root, plan, invocation}) do
      {:ok, {:pending, retained}} ->
        retained

      {:ok, {:error, :authority_unconfirmed}} ->
        throw({:restore_refusal, "authority_unconfirmed"})

      {:ok, {:error, %{"code" => "restore_history_invalid"}}} ->
        throw({:restore_refusal, "invalid_current_history"})

      {:ok, {:error, %{"code" => code}}} ->
        throw({:restore_refusal, code})

      _ ->
        throw({:restore_refusal, "inventory_unavailable"})
    end
  end

  # Concept: reconstruct private records without allocation or IO, never a receipt.
  # Technical depth: exact captured baseline/intent and the existing prior-lineage
  # reducer bind current grammar, placements and epochs. This validates retained
  # facts, not live identity, complete ordinary history or claim custody. All
  # compiled caps apply and canonical intent must equal the original bytes.
  @doc false
  def retained_construction(plan, baseline, intent_bytes, prior_files, max_total) do
    try do
      {:ok, _} = RestoreCodec.encode(:plan, plan)
      ensure!(plan["prior_restore_count"] < 64, "inventory_limit_exceeded")
      {:ok, entries} = RestoreCodec.manifest(baseline, max_total)
      ensure!(hash(baseline) == plan["manifest_sha256"], "inventory_mismatch")
      {:ok, intent} = RestoreCodec.decode(:intent, intent_bytes)
      ensure!(intent["plan"] == plan, "restore_conflict")
      {:ok, lineage} = RestoreGuard.validate_captured_lineage(plan, entries, prior_files)
      retained_candidates!(intent["generations"], entries, lineage)

      compiled =
        compile_records!(
          plan,
          baseline,
          entries,
          intent["generations"],
          construction_bindings!(
            plan,
            plan["source_state_placement"],
            intent["destination_state_placement"]
          ),
          max_total
        )

      ensure!(compiled.intent == intent_bytes, "invalid_current_history")
      {:ok, Map.delete(compiled, :receipt)}
    rescue
      _error in [MatchError, KeyError, ArgumentError] -> {:error, "invalid_current_history"}
    catch
      {:restore_refusal, code} -> {:error, code}
    end
  end

  # Concept: retained candidates preserve the baseline and all earlier epochs.
  # Technical depth: the intent codec already checks coverage and candidate
  # bindings. These additional baseline/lineage relations use the same prior
  # reducer as fresh construction, with no replacement generation serialization.
  defp retained_candidates!(candidates, entries, lineage) do
    Enum.each(candidates, fn candidate ->
      relative = candidate["relative_root"]
      original = candidate["source_generation_bytes"]
      {:ok, source} = Ledger.decode_bytes(original, "local_executor_generation_v1")

      {:ok, destination} =
        Ledger.decode_bytes(
          candidate["destination_generation_bytes"],
          "local_executor_generation_v1"
        )

      entry = Enum.find(entries, &(&1["path"] == Path.join(relative, "generation")))

      ensure!(
        not is_nil(entry) and entry["kind"] == "regular" and
          entry["size"] == byte_size(original) and entry["sha256"] == hash(original),
        "inventory_mismatch"
      )

      excluded =
        Map.get(lineage.epochs, relative, MapSet.new())
        |> MapSet.put(source["executor_epoch"])

      ensure!(
        not MapSet.member?(excluded, destination["executor_epoch"]),
        "invalid_current_history"
      )
    end)
  end

  # Concept: hand off only the live owner nonce of an exact retained transaction.
  # Technical depth: intake, every participating capture and canonical candidate
  # reconstruction precede mutation. The existing owner remains the fence through
  # partial failure; this private result authorizes no publication or release.
  @doc false
  def retained_claim_handoff(plan, invocation, io) do
    {:ok, Map.take(retained_handoff!(plan, invocation, io, false), [:claims, :intent])}
  catch
    {:restore_refusal, code} -> {:error, code}
    {:io_error, _} -> {:error, "inventory_unavailable"}
    {:lookup_error, _} -> {:error, "inventory_unavailable"}
    {:stopped, _} -> {:error, "inventory_unavailable"}
  end

  # Concept: continue the original transaction only through checked source retirement.
  # Technical depth: handoff, equal-stage sync and retirement stay in the same IO
  # worker and original permits/cutoffs. No candidate, receipt or release follows.
  # Installed-candidate/committed cuts remain explicitly unfinished development.
  @doc false
  def retained_source_retirement(plan, invocation, io) do
    retained = retained_retire!(plan, invocation, io)

    {:ok,
     %{
       claims: retained.claims,
       intent: retained.intent,
       source_retirement: retained.compiled.retirement
     }}
  catch
    {:retained_retirement_unfinished, phase} ->
      {:development_incomplete, {:retained_retirement_cut, phase}}

    {:restore_refusal, code} ->
      {:error, code}

    {:io_error, _} ->
      {:error, "inventory_unavailable"}

    {:lookup_error, _} ->
      {:error, "inventory_unavailable"}

    {:stopped, _} ->
      {:error, "inventory_unavailable"}
  end

  # Concept: install only the original retained destination generations after retirement.
  # Technical depth: this private development path shares retirement's one worker,
  # custody and cutoffs. It returns an audited activation image, never a receipt or
  # committed proof. Exact original/candidate prefixes resume after full native
  # baseline/history/retirement admission; torn bytes and later proofs refuse.
  @doc false
  def retained_generation_install(plan, invocation, io) do
    retained = retained_retire!(plan, invocation, io, :generations)
    destination = plan["destination_state_root"]
    phase(io, "destination_generations")

    Enum.each(retained.compiled.ledgers, fn ledger ->
      value!(io.({:restore_generation_step, ledger.relative}))
      retained_generation_fences!(plan, invocation, retained, io)
      path = Path.join([destination, ledger.relative, "generation"])

      value!(
        io.(
          {:restore_generation_install, path, ledger.candidate, ledger.mode, ledger.original,
           plan["prior_restore_count"] + 1}
        )
      )

      retained_generation_fences!(plan, invocation, retained, io)
    end)

    retained_generation_fences!(plan, invocation, retained, io)
    activation = value!(io.({:manifest, destination, invocation["max_total_file_bytes"]}))
    ensure!(activation == retained.compiled.activation, "inventory_mismatch")
    retained_generation_fences!(plan, invocation, retained, io)

    {:ok,
     %{
       claims: retained.claims,
       intent: retained.intent,
       source_retirement: retained.compiled.retirement,
       activation_manifest: activation
     }}
  catch
    {:retained_retirement_unfinished, phase} ->
      {:development_incomplete, {:retained_retirement_cut, phase}}

    {:restore_refusal, code} ->
      {:error, code}

    {:io_error, _} ->
      {:error, "inventory_unavailable"}

    {:lookup_error, _} ->
      {:error, "inventory_unavailable"}

    {:stopped, _} ->
      {:error, "inventory_unavailable"}
  end

  defp retained_generation_fences!(plan, invocation, retained, io) do
    retained_retirement_custody!(retained, plan, io)

    if retained.source_observation do
      lost_source!(plan["source_state_root"], retained.source_observation, io)
    else
      retained_retirement_complete!(plan, invocation, retained, plan["source_state_root"], io)
    end

    retained_retirement_placements!(plan, retained, plan["destination_state_root"], io)
    workspace!(plan, value!(io.({:placement, plan["workspace"]["root"]})))
  end

  defp retained_retire!(plan, invocation, io, admission \\ true) do
    retained = retained_handoff!(plan, invocation, io, admission)
    compiled = retained.compiled
    {:ok, entries} = RestoreCodec.manifest(retained.baseline, invocation["max_total_file_bytes"])
    root_admin = root_admin(plan)
    destination = plan["destination_state_root"]
    source = plan["source_state_root"]

    phase(io, "destination_intent")

    retained_retirement_publish!(
      retained,
      plan,
      destination,
      root_admin,
      "baseline",
      :baseline,
      retained.baseline,
      entries,
      io
    )

    retained_retirement_publish!(
      retained,
      plan,
      destination,
      root_admin,
      "intent",
      :record,
      compiled.intent,
      entries,
      io
    )

    value!(io.({:restore_intent_facts, plan["prior_restore_count"] + 1, "validated"}))
    phase(io, "source_retirement")

    if plan["source_status"] == "available" do
      retained_retirement_publish!(
        retained,
        plan,
        source,
        root_admin,
        "intent",
        :record,
        compiled.intent,
        entries,
        io
      )

      Enum.each(compiled.ledgers, fn ledger ->
        retained_retirement_publish!(
          retained,
          plan,
          source,
          ledger.directory,
          "intent",
          :record,
          ledger.intent,
          entries,
          io
        )

        retained_retirement_publish!(
          retained,
          plan,
          source,
          ledger.directory,
          "source-retired",
          :record,
          ledger.retired,
          entries,
          io
        )
      end)

      retained_retirement_publish!(
        retained,
        plan,
        source,
        root_admin,
        "source-retirement",
        :record,
        compiled.retirement,
        entries,
        io
      )

      retained_retirement_complete!(plan, invocation, retained, source, io)
    else
      lost_source!(source, retained.source_observation, io)
    end

    # Actual source proof is fully synced/read back before its destination copies.
    Enum.each(compiled.ledgers, fn ledger ->
      retained_retirement_publish!(
        retained,
        plan,
        destination,
        ledger.directory,
        "intent",
        :record,
        ledger.intent,
        entries,
        io
      )

      if ledger.retired do
        retained_retirement_publish!(
          retained,
          plan,
          destination,
          ledger.directory,
          "source-retired",
          :record,
          ledger.retired,
          entries,
          io
        )
      end
    end)

    retained_retirement_publish!(
      retained,
      plan,
      destination,
      root_admin,
      "source-retirement",
      :record,
      compiled.retirement,
      entries,
      io
    )

    retained_retirement_complete!(plan, invocation, retained, destination, io)
    retained_retirement_custody!(retained, plan, io)
    if retained.source_observation, do: lost_source!(source, retained.source_observation, io)
    workspace!(plan, value!(io.({:placement, plan["workspace"]["root"]})))
    retained
  end

  defp retained_handoff!(plan, invocation, io, retirement) do
    ensure!(match?({:ok, _}, RestoreCodec.encode(:plan, plan)), "invalid_plan")
    ensure!(match?({:ok, _}, RestoreCodec.encode(:invocation, invocation)), "invalid_plan")

    ensure!(
      invocation["prior_admin_authority"] in ["joined", "host_rebooted"],
      "authority_unconfirmed"
    )

    retained =
      case pending_intake(plan, invocation, io) do
        {:ok, retained} -> retained
        {:error, code} -> throw({:restore_refusal, code})
      end

    ensure!(is_binary(retained.intent), "invalid_current_history")

    roots =
      if plan["source_status"] == "available",
        do: [plan["source_state_root"], plan["destination_state_root"]],
        else: [plan["destination_state_root"]]

    source_observation =
      if plan["source_status"] == "lost",
        do: value!(io.({:lost_source_absent, plan["source_state_root"]})),
        else: nil

    captures = Enum.map(Enum.sort(roots), &claim_capture!(&1, plan, invocation, io))
    destination = Enum.find(captures, &(&1.root == plan["destination_state_root"]))
    ensure!(destination.retained.intent == retained.intent, "restore_conflict")
    ensure!(destination.retained.baseline == retained.baseline, "restore_conflict")

    Enum.each(captures, fn capture ->
      if capture.retained.intent,
        do: ensure!(capture.retained.intent == retained.intent, "restore_conflict")
    end)

    # The pure prior reducer consumes the exact baseline generation projection,
    # not a partially installed current candidate. Physical phase admission above
    # remains separate; all earlier captured administrative bytes are unchanged.
    {:ok, intent} = RestoreCodec.decode(:intent, retained.intent)

    prior_files =
      Enum.reduce(intent["generations"], destination.state.files, fn candidate, files ->
        Map.put(
          files,
          Path.join(candidate["relative_root"], "generation"),
          candidate["source_generation_bytes"]
        )
      end)

    compiled =
      case retained_construction(
             plan,
             retained.baseline,
             retained.intent,
             prior_files,
             invocation["max_total_file_bytes"]
           ) do
        {:ok, compiled} -> compiled
        {:error, code} -> throw({:restore_refusal, code})
      end

    generation_prefix =
      case retirement do
        :generations ->
          retained_generation_admit!(plan, invocation, retained, compiled, captures, io)

        true ->
          retained_retirement_admit!(plan, invocation, retained, compiled, captures, io)
          false

        false ->
          false
      end

    nonce = handoff_nonce(captures)

    claims =
      Enum.map(captures, fn capture ->
        if source_observation,
          do: lost_source!(plan["source_state_root"], source_observation, io)

        value!(io.({:restore_claim_handoff, capture, plan, invocation, nonce}))
      end)

    if source_observation,
      do: lost_source!(plan["source_state_root"], source_observation, io)

    %{
      claims: claims,
      intent: retained.intent,
      baseline: retained.baseline,
      compiled: compiled,
      source_observation: source_observation,
      generation_prefix: generation_prefix
    }
  end

  # Concept: continuation audits real baseline bytes and the current exact transformation.
  # Technical depth: a candidate never impersonates its source generation for
  # Ledger/receipt/open validation. Audit the held native backup, then bind all
  # current bytes/modes and original physical roles before changing a claim nonce.
  defp retained_generation_admit!(plan, invocation, retained, compiled, captures, io) do
    destination = Enum.find(captures, &(&1.root == plan["destination_state_root"]))
    observed_phase = destination.retained.observation["phase"]

    ensure!(
      observed_phase in [
        "destination_intent",
        "source_retirement",
        "destination_generations",
        "destination_proofs"
      ],
      "invalid_current_history"
    )

    max_total = invocation["max_total_file_bytes"]
    backup = value!(io.({:manifest, plan["backup_state_root"], max_total}))
    ensure!(backup == retained.baseline, "inventory_mismatch")
    Audit.complete(plan, backup, max_total, io)

    ensure!(
      value!(io.({:manifest, plan["backup_state_root"], max_total})) == backup,
      "inventory_mismatch"
    )

    projected = Map.put(retained, :compiled, compiled)
    prefix = retained_generation_manifest!(plan, invocation, projected, false, io)
    prefix = prefix or observed_phase == "destination_proofs"

    Enum.each(captures, fn capture ->
      retained_retirement_placements!(plan, projected, capture.root, io)
    end)

    workspace!(plan, value!(io.({:placement, plan["workspace"]["root"]})))

    if prefix do
      # Candidate/staging or proof-free all-installed prefixes require complete
      # retirement already retained, including the empty candidate vector;
      # admission cannot invent missing retirement after such a publication cut.
      retained_generation_manifest!(plan, invocation, projected, true, io)

      if plan["source_status"] == "available" do
        retained_retirement_complete!(plan, invocation, projected, plan["source_state_root"], io)
      else
        value!(io.({:lost_source_absent, plan["source_state_root"]}))
      end
    else
      # Original, unstaged cuts preserve retirement's admission and complete its
      # native proof before this operation publishes the first candidate.
      retained_retirement_admit!(plan, invocation, retained, compiled, captures, io)
    end

    prefix
  end

  # Concept: every current payload remains the baseline plus exact original stages.
  # Technical depth: only listed O/C generations, baseline modes and original
  # ordinal C temporaries may vary. Whole native captures share the same worker
  # and caps; foreign, torn, missing and committed-proof entries refuse.
  defp retained_generation_manifest!(plan, invocation, retained, complete, io) do
    root = plan["destination_state_root"]
    max_total = invocation["max_total_file_bytes"]
    {:ok, entries} = RestoreCodec.manifest(retained.baseline, max_total)
    original = Map.new(entries, &{&1["path"], &1})
    records = retained_retirement_records(plan, retained.baseline, retained.compiled, root)

    final =
      add_records(
        original,
        Enum.map(records, fn {path, bytes} ->
          {Path.dirname(path), [{Path.basename(path), bytes}]}
        end)
      )

    allowed =
      add_records(
        original,
        Enum.map(records, fn {path, bytes} ->
          {Path.dirname(path),
           [{Path.basename(path), bytes}, {Path.basename(path) <> ".tmp", bytes}]}
        end)
      )

    actual = value!(io.({:manifest, root, max_total}))
    {:ok, observed} = RestoreCodec.manifest(actual, max_total)
    index = Map.new(observed, &{&1["path"], &1})

    {projected, temps, prefix} =
      Enum.reduce(retained.compiled.ledgers, {original, %{}, false}, fn ledger,
                                                                        {current, staging,
                                                                         progressed} ->
        relative = Path.join(ledger.relative, "generation")
        path = Path.join(root, relative)

        selected =
          value!(
            io.(
              {:restore_generation_capture, path, ledger.original, ledger.candidate, ledger.mode,
               plan["prior_restore_count"] + 1}
            )
          )

        generation = %{
          original[relative]
          | "size" => byte_size(selected.current),
            "sha256" => hash(selected.current)
        }

        ensure!(index[relative] == generation, "inventory_mismatch")
        temporary = relative <> ".restore-" <> ordinal(plan) <> ".tmp"

        staging =
          if selected.temporary do
            entry = %{
              "path" => temporary,
              "kind" => "regular",
              "mode" => ledger.mode,
              "size" => byte_size(ledger.candidate),
              "sha256" => hash(ledger.candidate)
            }

            ensure!(index[temporary] == entry, "inventory_mismatch")
            Map.put(staging, temporary, entry)
          else
            ensure!(not Map.has_key?(index, temporary), "inventory_mismatch")
            staging
          end

        {Map.put(current, relative, generation), staging,
         progressed or selected.current == ledger.candidate or selected.temporary}
      end)

    Enum.each(projected, fn {path, entry} ->
      ensure!(index[path] == entry, "inventory_mismatch")
    end)

    allowed = Map.merge(allowed, projected) |> Map.merge(temps)

    Enum.each(index, fn {path, entry} -> ensure!(allowed[path] == entry, "inventory_mismatch") end)

    if complete do
      expected = Map.merge(final, projected) |> Map.merge(temps)
      ensure!(index == expected, "inventory_mismatch")
    end

    ensure!(value!(io.({:manifest, root, max_total})) == actual, "inventory_mismatch")
    prefix
  end

  defp retained_retirement_admit!(plan, invocation, retained, compiled, captures, io) do
    destination = Enum.find(captures, &(&1.root == plan["destination_state_root"]))
    phase = destination.retained.observation["phase"]

    if phase not in ["destination_intent", "source_retirement", "destination_generations"],
      do: throw({:retained_retirement_unfinished, phase})

    {:ok, intent} = RestoreCodec.decode(:intent, retained.intent)

    Enum.each(intent["generations"], fn candidate ->
      generation = destination.state.files[Path.join(candidate["relative_root"], "generation")]

      if generation == candidate["destination_generation_bytes"],
        do: throw({:retained_retirement_unfinished, "destination_generations"})

      ensure!(generation == candidate["source_generation_bytes"], "inventory_mismatch")
    end)

    workspace!(plan, value!(io.({:placement, plan["workspace"]["root"]})))

    Enum.each(captures, fn capture ->
      expected =
        if capture.root == plan["source_state_root"],
          do: plan["source_state_placement"],
          else: intent["destination_state_placement"]

      ensure!(value!(io.({:placement, capture.root})) == expected, "source_changed")

      actual =
        retained_retirement_manifest!(
          plan,
          invocation,
          retained.baseline,
          compiled,
          capture.root,
          false,
          io
        )

      # This changes only the audit reader's physical placement, never authored
      # plan/intent bytes. Reuse every shipped Store/Local/artifact/Resource fold.
      Audit.complete(
        Map.put(plan, "backup_state_root", capture.root),
        actual,
        invocation["max_total_file_bytes"],
        io
      )

      Enum.each(intent["generations"], fn candidate ->
        placement =
          if capture.root == plan["source_state_root"],
            do:
              Enum.find(plan["ledgers"], &(&1["relative_root"] == candidate["relative_root"]))[
                "source_placement"
              ],
            else: candidate["destination_ledger_placement"]

        ensure!(
          value!(io.({:placement, Path.join(capture.root, candidate["relative_root"])})) ==
            placement,
          "source_changed"
        )
      end)

      ensure!(value!(io.({:placement, capture.root})) == expected, "source_changed")
    end)
  end

  defp retained_retirement_records(plan, baseline, compiled, root) do
    root_admin = root_admin(plan)
    destination = root == plan["destination_state_root"]
    root_records = [{"intent", compiled.intent}, {"source-retirement", compiled.retirement}]
    root_records = if destination, do: [{"baseline", baseline} | root_records], else: root_records

    Map.new(
      [
        {root_admin, root_records}
        | Enum.map(compiled.ledgers, fn ledger ->
            records = [{"intent", ledger.intent}]

            records =
              if ledger.retired,
                do: records ++ [{"source-retired", ledger.retired}],
                else: records

            {ledger.directory, records}
          end)
      ]
      |> Enum.flat_map(fn {directory, records} ->
        Enum.map(records, fn {name, bytes} -> {Path.join(directory, name), bytes} end)
      end)
    )
  end

  # Concept: a retained baseline remains complete, including every unexcluded byte.
  # Technical depth: only exact named canonical retirement records and their
  # temporaries/directories may extend it. Generation replacement is unsupported.
  defp retained_retirement_manifest!(plan, invocation, baseline, compiled, root, complete, io) do
    max_total = invocation["max_total_file_bytes"]
    {:ok, entries} = RestoreCodec.manifest(baseline, max_total)
    original = Map.new(entries, &{&1["path"], &1})
    records = retained_retirement_records(plan, baseline, compiled, root)

    allowed =
      add_records(
        original,
        Enum.map(records, fn {path, bytes} ->
          {Path.dirname(path),
           [{Path.basename(path), bytes}, {Path.basename(path) <> ".tmp", bytes}]}
        end)
      )

    candidate_temps =
      if root == plan["destination_state_root"] do
        Map.new(compiled.ledgers, fn ledger ->
          path = Path.join(ledger.relative, "generation.restore-" <> ordinal(plan) <> ".tmp")

          {path,
           %{
             "path" => path,
             "kind" => "regular",
             "mode" => ledger.mode,
             "size" => byte_size(ledger.candidate),
             "sha256" => hash(ledger.candidate)
           }}
        end)
      else
        %{}
      end

    allowed = Map.merge(allowed, candidate_temps)
    actual = value!(io.({:manifest, root, max_total}))
    {:ok, observed} = RestoreCodec.manifest(actual, max_total)
    index = Map.new(observed, &{&1["path"], &1})

    Enum.each(original, fn {path, entry} ->
      ensure!(index[path] == entry, "inventory_mismatch")
    end)

    Enum.each(index, fn {path, entry} -> ensure!(allowed[path] == entry, "inventory_mismatch") end)

    if Enum.any?(candidate_temps, fn {path, _} -> Map.has_key?(index, path) end),
      do: throw({:retained_retirement_unfinished, "destination_generations"})

    if complete do
      expected =
        add_records(
          original,
          Enum.map(records, fn {path, bytes} ->
            {Path.dirname(path), [{Path.basename(path), bytes}]}
          end)
        )

      ensure!(index == expected, "inventory_mismatch")
    end

    actual
  end

  defp retained_retirement_complete!(plan, invocation, retained, root, io) do
    if root == plan["destination_state_root"] and Map.get(retained, :generation_prefix, false) do
      retained_generation_manifest!(plan, invocation, retained, true, io)
    else
      retained_retirement_manifest!(
        plan,
        invocation,
        retained.baseline,
        retained.compiled,
        root,
        true,
        io
      )
    end

    retained_retirement_placements!(plan, retained, root, io)
  end

  # Concept: retirement evidence names the actual preserved root and ledger placements.
  # Technical depth: admission alone cannot cover a later physical replacement.
  # Recheck the original root/ledger bindings before and after each publication,
  # within the existing individual permits and host access exclusion.
  defp retained_retirement_placements!(plan, retained, root, io) do
    {:ok, intent} = RestoreCodec.decode(:intent, retained.intent)

    expected =
      if root == plan["source_state_root"],
        do: plan["source_state_placement"],
        else: intent["destination_state_placement"]

    ensure!(value!(io.({:placement, root})) == expected, "source_changed")

    Enum.each(intent["generations"], fn candidate ->
      expected_ledger =
        if root == plan["source_state_root"],
          do:
            Enum.find(plan["ledgers"], &(&1["relative_root"] == candidate["relative_root"]))[
              "source_placement"
            ],
          else: candidate["destination_ledger_placement"]

      ensure!(
        value!(io.({:placement, Path.join(root, candidate["relative_root"])})) == expected_ledger,
        "source_changed"
      )
    end)
  end

  defp retained_retirement_custody!(retained, plan, io),
    do: value!(io.({:restore_retirement_claim_check, retained.claims, plan}))

  defp retained_retirement_publish!(
         retained,
         plan,
         root,
         directory,
         name,
         role,
         bytes,
         entries,
         io
       ) do
    side = if root == plan["source_state_root"], do: "source", else: "destination"
    value!(io.({:restore_retirement_step, side, name}))
    retained_retirement_custody!(retained, plan, io)

    if retained.source_observation,
      do: lost_source!(plan["source_state_root"], retained.source_observation, io)

    retained_retirement_placements!(plan, retained, root, io)
    admin_directories!(root, directory, entries, io)
    path = Path.join([root, directory, name])
    value!(io.({:restore_publish, role, path, bytes, 0o600, :absent}))
    retained_retirement_placements!(plan, retained, root, io)
    retained_retirement_custody!(retained, plan, io)

    if retained.source_observation,
      do: lost_source!(plan["source_state_root"], retained.source_observation, io)
  end

  defp handoff_nonce(captures) do
    nonce = random_hex()

    if Enum.any?(captures, &(&1.retained.claim["claim_nonce"] == nonce)),
      do: handoff_nonce(captures),
      else: nonce
  end

  defp claim_capture!(root, plan, invocation, io) do
    case io.({:restore_claim_capture, root, plan, invocation}) do
      {:ok, {:pending, capture}} ->
        capture

      {:ok, {:error, :authority_unconfirmed}} ->
        throw({:restore_refusal, "authority_unconfirmed"})

      {:ok, {:error, %{"code" => "restore_history_invalid"}}} ->
        throw({:restore_refusal, "invalid_current_history"})

      {:ok, {:error, %{"code" => code}}} ->
        throw({:restore_refusal, code})

      _ ->
        throw({:restore_refusal, "inventory_unavailable"})
    end
  end

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
    value!(io.({:restore_intent_facts, plan["prior_restore_count"] + 1, "may_exist"}))
    publish!(destination, Path.join(root_admin, "intent"), compiled.intent, io)
    value!(io.({:restore_intent_facts, plan["prior_restore_count"] + 1, "validated"}))

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

    {:restore_refusal, code} ->
      refusal(code)

    {:io_error, _reason} ->
      refusal("inventory_unavailable")

    {:stopped, _reason} ->
      refusal("inventory_unavailable")
  end

  # Concept: classify retained completion before fresh claims or allocation.
  # Technical depth: administrative capture and reduction remain in this one
  # worker. Duplicates never inspect the old source/backup or allocate epochs;
  # pending continuation remains a separate unfinished implementation unit.
  defp classify!(root, plan, io) do
    case value!(io.({:restore_classification, root, plan})) do
      :fresh ->
        :ok

      {:committed, receipt} ->
        throw({:restore_duplicate, receipt})

      {:error, %{"code" => "restore_history_invalid"}} ->
        throw({:restore_refusal, "invalid_current_history"})

      {:error, %{"code" => code}} ->
        throw({:restore_refusal, code})

      _ ->
        throw({:restore_refusal, "invalid_current_history"})
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
    bindings = construction_bindings!(plan, source, destination)
    candidates = allocate_candidates!(plan, facts, lineage, io)
    compile_records!(plan, baseline, entries, candidates, bindings, max_total)
  end

  defp allocate_candidates!(plan, facts, lineage, io) do
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

    candidates
  end

  defp construction_bindings!(plan, source, destination) do
    root_admin = root_admin(plan)
    {:ok, plan_digest} = RestoreCodec.plan_digest(plan)
    {:ok, source_binding} = RestoreCodec.state_binding(source)
    {:ok, destination_binding} = RestoreCodec.state_binding(destination)
    {root_admin, plan_digest, source_binding, destination_binding, destination}
  end

  defp compile_records!(plan, baseline, entries, candidates, bindings, max_total) do
    {root_admin, plan_digest, source_binding, destination_binding, destination} = bindings

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
