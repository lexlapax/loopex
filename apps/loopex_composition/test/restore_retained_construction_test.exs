defmodule LoopexComposition.RestoreRetainedConstructionTest do
  use ExUnit.Case, async: true

  alias Loopex.Executor.Local.{RestoreCodec, RestoreGuard}
  alias LoopexComposition.Restore.Workflow

  @total 16_777_216

  test "available and lost retained candidates reconstruct exact canonical records without a receipt" do
    for status <- ~w(available lost) do
      fixture = fixture(status)
      assert {:ok, compiled} = construct(fixture)
      assert compiled.intent == fixture.intent_bytes
      refute Map.has_key?(compiled, :receipt)
      [ledger] = compiled.ledgers
      [candidate] = fixture.intent["generations"]
      assert ledger.original == candidate["source_generation_bytes"]
      assert ledger.candidate == candidate["destination_generation_bytes"]
      assert ledger.mode == 0o640
      assert {:ok, retirement} = RestoreCodec.decode(:source_retirement, compiled.retirement)

      assert retirement["disposition"] ==
               if(status == "available", do: "source_retired", else: "lost_source_host_excluded")

      if status == "available" do
        assert {:ok, _} = RestoreCodec.decode(:ledger_retired, ledger.retired)
      else
        assert ledger.retired == nil
        assert retirement["ledger_retirements"] == [
                 %{"relative_root" => "receipts", "record_sha256" => nil}
               ]
      end

      assert {:ok, proof} = RestoreCodec.decode(:ledger_committed, ledger.committed)
      assert proof["destination_generation_sha256"] == hash(ledger.candidate)
      assert proof["source_retirement_sha256"] == hash(compiled.retirement)
      assert {:ok, committed} = RestoreCodec.decode(:committed, compiled.committed)
      assert committed["intent_sha256"] == hash(fixture.intent_bytes)
      assert committed["activation_manifest_sha256"] == hash(compiled.activation)
      assert {:ok, _} = RestoreCodec.manifest(compiled.final, @total)
    end
  end

  test "repeated pure construction preserves every original candidate and record byte" do
    fixture = fixture("available")
    assert {:ok, first} = construct(fixture)
    assert {:ok, ^first} = construct(fixture)
    assert {:ok, ^first} = construct(fixture)
    assert first.intent == fixture.intent_bytes
    assert hd(first.ledgers).candidate == hd(fixture.intent["generations"])["destination_generation_bytes"]
  end

  test "changed canonical plan cannot consume the retained original intent" do
    fixture = fixture("available")
    changed = %{fixture.plan | "cut_id" => hash("different-cut")}
    assert {:ok, _} = RestoreCodec.encode(:plan, changed)
    assert {:error, "restore_conflict"} = construct(%{fixture | plan: changed})
  end

  test "missing malformed noncanonical or incomplete intent refuses rather than allocating" do
    fixture = fixture("available")

    for bytes <- [
          <<>>,
          fixture.intent_bytes <> <<0>>,
          :erlang.term_to_binary(fixture.intent, [:compressed]),
          :erlang.term_to_binary(Map.delete(fixture.intent, "generations"), [:deterministic]),
          :erlang.term_to_binary(%{fixture.intent | "generations" => []}, [:deterministic])
        ] do
      assert {:error, "invalid_current_history"} = construct(%{fixture | intent_bytes: bytes})
    end
  end

  test "forged generation and physical binding relations refuse before reconstruction" do
    fixture = fixture("available")
    [candidate] = fixture.intent["generations"]

    for changed <- [
          %{candidate | "destination_generation_bytes" => candidate["source_generation_bytes"]},
          %{candidate | "destination_ledger_binding" => hash("different-binding")},
          %{candidate | "source_ledger_binding" => hash("different-source")},
          %{candidate | "relative_root" => "other"}
        ] do
      intent = %{fixture.intent | "generations" => [changed]}
      bytes = :erlang.term_to_binary(intent, [:deterministic])
      assert {:error, "invalid_current_history"} = construct(%{fixture | intent_bytes: bytes})
    end
  end

  test "baseline digest and exact original generation size hash and kind are mandatory" do
    fixture = fixture("available")
    assert {:error, "inventory_mismatch"} = construct(%{fixture | baseline: empty_baseline()})
    {:ok, entries} = RestoreCodec.manifest(fixture.baseline, @total)

    for change <- [
          %{"size" => 1},
          %{"sha256" => hash("third-preimage")},
          %{"kind" => "directory", "size" => 0, "sha256" => nil}
        ] do
      changed =
        Enum.map(entries, fn entry ->
          if entry["path"] == "receipts/generation", do: Map.merge(entry, change), else: entry
        end)

      baseline = encode!(:manifest, ["loopex:current-state-manifest:v1", changed])
      rebound = rebind_baseline(fixture, baseline)
      assert {:error, "inventory_mismatch"} = construct(rebound)
    end
  end

  test "complete prior lineage is checked and original historical epochs cannot be reused" do
    first = fixture("available")
    assert {:ok, compiled} = construct(first)
    next = next_fixture(first, compiled, 1)
    assert {:ok, _} = RestoreCodec.decode(:intent, next.intent_bytes)
    assert {:error, "invalid_current_history"} = construct(next)
  end

  test "later retained construction preserves the full prior administrative image" do
    first = fixture("available")
    assert {:ok, compiled} = construct(first)
    next = next_fixture(first, compiled, 3)
    assert {:ok, later} = construct(next)
    assert later.intent == next.intent_bytes
    assert {:ok, old_entries} = RestoreCodec.manifest(next.baseline, @total)
    assert {:ok, final_entries} = RestoreCodec.manifest(later.final, @total)

    for entry <- old_entries, reserved?(entry["path"]) do
      assert Enum.find(final_entries, &(&1["path"] == entry["path"])) == entry
    end

    assert {:ok, checked} =
             RestoreGuard.validate_captured_lineage(next.plan, old_entries, next.prior_files)

    assert checked.previous == 1
    assert checked.epochs["receipts"] == MapSet.new([1, 2])
  end

  test "missing prior proof refuses even when baseline and intent remain canonical" do
    first = fixture("available")
    assert {:ok, compiled} = construct(first)
    next = next_fixture(first, compiled, 3)
    files = Map.delete(next.prior_files, ".loopex-restore/lineage/00000001/committed")
    assert {:error, "invalid_current_history"} = construct(%{next | prior_files: files})
  end

  test "caller total allowance also bounds reconstructed activation and final bytes" do
    fixture = fixture("available")
    assert {:ok, entries} = RestoreCodec.manifest(fixture.baseline, @total)
    total = Enum.reduce(entries, 0, &(&1["size"] + &2))
    assert {:ok, _} = RestoreCodec.manifest(fixture.baseline, total)
    assert {:error, "inventory_limit_exceeded"} = construct(fixture, total)
  end

  # Concept: these are pure current-codec vectors, not physical restore evidence.
  # Technical depth: fixed retained generation bytes and captures permit semantic
  # reconstruction without filesystem/actors, allocation or an acknowledged receipt.
  defp fixture(status) do
    source = placement("/retained/source", 1)
    destination = placement("/retained/destination", 2)
    source_ledger = placement("/retained/source/receipts", 3)
    destination_ledger = placement("/retained/destination/receipts", 4)
    original = generation(1, source_ledger)
    baseline = baseline(original)
    plan = plan(status, source, source_ledger, baseline, 0)
    candidate = candidate(original, 2, source_ledger, destination_ledger)
    intent = intent(plan, destination, candidate)

    %{
      plan: plan,
      baseline: baseline,
      intent: intent,
      intent_bytes: encode!(:intent, intent),
      prior_files: %{}
    }
  end

  defp next_fixture(first, compiled, epoch) do
    [old] = first.intent["generations"]
    source = first.intent["destination_state_placement"]
    source_ledger = old["destination_ledger_placement"]
    destination = placement("/retained/next-destination", 5)
    destination_ledger = placement("/retained/next-destination/receipts", 6)
    plan = plan("available", source, source_ledger, compiled.final, 1)
    candidate = candidate(old["destination_generation_bytes"], epoch, source_ledger, destination_ledger)
    intent = intent(plan, destination, candidate)
    [ledger] = compiled.ledgers

    files = %{
      ".loopex-restore/lineage/00000001/baseline" => first.baseline,
      ".loopex-restore/lineage/00000001/intent" => compiled.intent,
      ".loopex-restore/lineage/00000001/source-retirement" => compiled.retirement,
      ".loopex-restore/lineage/00000001/committed" => compiled.committed,
      "receipts/restore-lineage/00000001/intent" => ledger.intent,
      "receipts/restore-lineage/00000001/source-retired" => ledger.retired,
      "receipts/restore-lineage/00000001/committed" => ledger.committed,
      "receipts/generation" => ledger.candidate
    }

    %{plan: plan, baseline: compiled.final, intent: intent, intent_bytes: encode!(:intent, intent), prior_files: files}
  end

  defp rebind_baseline(fixture, baseline) do
    plan = %{fixture.plan | "manifest_sha256" => hash(baseline)}
    {:ok, digest} = RestoreCodec.plan_digest(plan)
    intent = %{fixture.intent | "plan" => plan, "plan_digest" => digest}
    %{fixture | plan: plan, baseline: baseline, intent: intent, intent_bytes: encode!(:intent, intent)}
  end

  defp plan(status, source, source_ledger, baseline, prior) do
    {:ok, entries} = RestoreCodec.manifest(baseline, @total)
    {:ok, lineage} = RestoreCodec.lineage_digest(Enum.filter(entries, &reserved?(&1["path"])))
    original = Enum.find(entries, &(&1["path"] == "receipts/generation"))["sha256"]

    %{
      "version" => 1,
      "tx_id" => hash("pure-retained-#{prior}"),
      "source_state_root" => source["expanded_root"],
      "source_state_placement" => source,
      "source_status" => status,
      "backup_state_root" => "/retained/backup-#{prior}",
      "destination_state_root" => if(prior == 0, do: "/retained/destination", else: "/retained/next-destination"),
      "manifest_sha256" => hash(baseline),
      "cut_id" => hash("pure-cut-#{prior}"),
      "prior_restore_count" => prior,
      "prior_lineage_sha256" => lineage,
      "runtime_ids" => [],
      "stores" => [],
      "ledgers" => [
        %{
          "relative_root" => "receipts",
          "executor_identity" => "retained-executor",
          "source_generation_sha256" => original,
          "source_placement" => source_ledger
        }
      ],
      "workspace" => %{"root" => "/retained/workspace", "workspace_ref" => "workspace:" <> hash("workspace")},
      "host_attestation" => %{
        "latest_cut" => true,
        "no_post_cut_activity" => true,
        "all_other_copies_excluded" => true,
        "old_authority_termination" => "joined",
        "host_ledgers_validated" => true,
        "evidence_sha256" => hash("pure-vector-not-a-join-proof")
      }
    }
  end

  defp intent(plan, destination, candidate) do
    {:ok, digest} = RestoreCodec.plan_digest(plan)
    {:ok, source_binding} = RestoreCodec.state_binding(plan["source_state_placement"])
    {:ok, destination_binding} = RestoreCodec.state_binding(destination)

    %{
      "kind" => "loopex_current_restore_intent_v1",
      "ordinal" => plan["prior_restore_count"] + 1,
      "tx_id" => plan["tx_id"],
      "plan_digest" => digest,
      "plan" => plan,
      "prior_lineage_sha256" => plan["prior_lineage_sha256"],
      "source_state_binding" => source_binding,
      "destination_state_placement" => destination,
      "destination_state_binding" => destination_binding,
      "generations" => [candidate]
    }
  end

  defp candidate(original, epoch, source_ledger, destination_ledger) do
    {:ok, source_binding} = RestoreCodec.ledger_binding(source_ledger)
    {:ok, destination_binding} = RestoreCodec.ledger_binding(destination_ledger)

    %{
      "relative_root" => "receipts",
      "executor_identity" => "retained-executor",
      "source_generation_bytes" => original,
      "destination_generation_bytes" => generation(epoch, destination_ledger),
      "source_ledger_binding" => source_binding,
      "destination_ledger_placement" => destination_ledger,
      "destination_ledger_binding" => destination_binding
    }
  end

  defp generation(epoch, placement) do
    {:ok, binding} = RestoreCodec.ledger_binding(placement)

    encode!(:generation, %{
      :ledger_kind => "local_executor_generation_v1",
      "executor_identity" => "retained-executor",
      "executor_epoch" => epoch,
      "generation_id" => Base.encode16(<<epoch::unsigned-256>>, case: :lower),
      "root_binding" => binding
    })
  end

  defp baseline(original) do
    encode!(:manifest, [
      "loopex:current-state-manifest:v1",
      [directory("."), directory("receipts"), file("receipts/generation", original, 0o640)]
    ])
  end

  defp empty_baseline, do: encode!(:manifest, ["loopex:current-state-manifest:v1", [directory(".")]])

  defp directory(path),
    do: %{"path" => path, "kind" => "directory", "mode" => 0o700, "size" => 0, "sha256" => nil}

  defp file(path, bytes, mode),
    do: %{"path" => path, "kind" => "regular", "mode" => mode, "size" => byte_size(bytes), "sha256" => hash(bytes)}

  defp placement(root, inode), do: %{"expanded_root" => root, "major_device" => 1, "inode" => inode}
  defp reserved?(path), do: Enum.any?(Path.split(path), &(&1 in [".loopex-restore", "restore-lineage"]))

  defp construct(fixture, total \\ @total),
    do: Workflow.retained_construction(fixture.plan, fixture.baseline, fixture.intent_bytes, fixture.prior_files, total)

  defp encode!(type, value) do
    assert {:ok, bytes} = RestoreCodec.encode(type, value)
    bytes
  end

  defp hash(bytes), do: RestoreCodec.digest_bytes(bytes)
end
