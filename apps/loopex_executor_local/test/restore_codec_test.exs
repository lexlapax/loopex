defmodule Loopex.Executor.Local.RestoreCodecTest do
  use ExUnit.Case, async: true

  alias Loopex.Executor.Local.{Ledger, RestoreCodec}

  @hex String.duplicate("a", 64)

  test "closed plans use exact deterministic ETF rather than canonical projection tuples" do
    plan = plan()
    assert {:ok, bytes} = RestoreCodec.encode(:plan, plan)
    assert bytes == :erlang.term_to_binary(plan, [:deterministic])
    assert {:ok, ^plan} = RestoreCodec.decode(:plan, bytes)
    assert {:ok, digest} = RestoreCodec.plan_digest(plan)
    assert digest == hash(<<"loopex:current-restore-plan:v1", 0, bytes::binary>>)
    assert {:ok, ^digest} = RestoreCodec.plan_digest(Map.new(Enum.reverse(Map.to_list(plan))))
  end

  test "compressed trailing noncanonical and unsafe terms refuse without creating atoms" do
    plan = plan()
    {:ok, bytes} = RestoreCodec.encode(:plan, plan)
    assert :error = RestoreCodec.decode(:plan, bytes <> <<0>>)
    assert :error = RestoreCodec.decode(:plan, :erlang.term_to_binary(plan, [:compressed]))
    assert :error = RestoreCodec.encode(:plan, Map.put(plan, "private", self()))
    assert :error = RestoreCodec.encode(:plan, Map.put(plan, "private", fn -> :ok end))
    name = "loopex_restore_unknown_#{System.unique_integer([:positive])}"
    assert :error = RestoreCodec.decode(:plan, <<131, 119, byte_size(name), name::binary>>)
    assert_raise ArgumentError, fn -> :erlang.binary_to_existing_atom(name, :utf8) end
    assert :error = RestoreCodec.encode(:plan, Map.put(plan, "runtime_ids", ["a" | :improper]))
  end

  test "every accepted output record is closed and current-only" do
    for {type, record} <- records() do
      assert {:ok, bytes} = RestoreCodec.encode(type, record), inspect(type)
      assert {:ok, ^record} = RestoreCodec.decode(type, bytes)
      assert :error = RestoreCodec.encode(type, Map.put(record, "extra", true))
      assert :error = RestoreCodec.encode(type, Map.delete(record, "kind"))
      assert :error = RestoreCodec.encode(type, Map.put(record, "kind", record["kind"] <> "_old"))
      assert :error = RestoreCodec.decode(type, bytes <> <<0>>)
    end
  end

  test "placement domains remain distinct and claim binding includes the expanded path length" do
    placement = placement("/state/source", 17)
    path = placement["expanded_root"]
    suffix = <<byte_size(path)::unsigned-64-big, path::binary, 3::unsigned-64-big, 17::unsigned-64-big>>
    assert {:ok, state} = RestoreCodec.state_binding(placement)
    assert state == hash(<<"loopex:current-state-root-binding:v1", 0, suffix::binary>>)
    assert {:ok, ledger} = RestoreCodec.ledger_binding(placement)
    assert ledger == hash(<<"loopex:local-root-binding:v1", 0, suffix::binary>>)
    refute state == ledger
    assert {:ok, claim} = RestoreCodec.claim_digest(path)
    assert claim == hash(<<"loopex:current-restore-claim:v1", 0, byte_size(path)::unsigned-64-big, path::binary>>)
  end

  test "path syntax and root independence refuse normalization and nested placements" do
    for path <- ["relative", "/state/./source", "/state/source/", "/state/../source", "/state/" <> <<0>>, "/state/" <> <<255>>] do
      assert :error = RestoreCodec.encode(:placement, placement(path, 1))
    end
    for path <- [".", "../ledger", "ledger/../other", "ledger//nested", "/ledger", "ledger/", "ledger/" <> <<0>>] do
      assert :error = RestoreCodec.encode(:store_descriptor, %{"relative_path" => path, "sha256" => @hex})
    end
    assert :error = RestoreCodec.encode(:plan, Map.put(plan(), "backup_state_root", "/state/source/backup"))
    assert :error = RestoreCodec.encode(:plan, Map.put(plan(), "backup_state_root", "/state/source"))
  end

  test "the current host WorkspaceIdentity spelling is retained without physical authority" do
    workspace = plan()["workspace"]
    assert {:ok, _} = RestoreCodec.encode(:workspace, workspace)
    for reference <- ["opaque-core-reference", "workspace:" <> String.upcase(@hex), "workspace:" <> @hex <> "0"] do
      assert :error = RestoreCodec.encode(:workspace, %{workspace | "workspace_ref" => reference})
    end
  end

  test "lineage zero and transition 64 to 65 are checked without pruning" do
    assert {:ok, empty} = RestoreCodec.lineage_digest([])
    assert empty == hash(<<"loopex:current-restore-lineage:v1", 0, :erlang.term_to_binary([], [:deterministic])::binary>>)
    assert :ok = RestoreCodec.eligible_plan(plan())
    assert :error = RestoreCodec.encode(:plan, Map.put(plan(), "prior_lineage_sha256", @hex))
    full = Map.merge(plan(), %{"prior_restore_count" => 64, "prior_lineage_sha256" => @hex})
    assert {:ok, _} = RestoreCodec.encode(:plan, full)
    assert :error = RestoreCodec.eligible_plan(full)
    assert :error = RestoreCodec.encode(:plan, Map.put(full, "prior_restore_count", 65))
  end

  test "lists are bytewise sorted unique and bounded and whole plan and claim caps are independent" do
    ids = Enum.map(1..256, &String.pad_leading(Integer.to_string(&1), 3, "0"))
    assert {:ok, _} = RestoreCodec.encode(:plan, Map.put(plan(), "runtime_ids", ids))
    for values <- [Enum.reverse(ids), ids ++ ["257"], ["a", "a"]] do
      assert :error = RestoreCodec.encode(:plan, Map.put(plan(), "runtime_ids", values))
    end
    long_ids = Enum.map(ids, &(&1 <> String.duplicate("x", 253)))
    assert :error = RestoreCodec.encode(:plan, Map.put(plan(), "runtime_ids", long_ids))
    claim = records()[:claim]
    assert :error = RestoreCodec.encode(:claim, Map.put(claim, "state_root", "/" <> String.duplicate("p", 2_048)))
  end

  test "manifest includes root hidden entries empty directories modes and complete regular bytes" do
    entries = [entry(".", "directory", 0, nil, 0o750), entry(".hidden", "regular", 0, hash(""), 0o600), entry("empty", "directory", 0, nil, 0o711), entry("file", "regular", 5, hash("value"), 0o640)]
    assert {:ok, bytes} = RestoreCodec.encode(:manifest, ["loopex:current-state-manifest:v1", entries])
    assert {:ok, ^entries} = RestoreCodec.manifest(bytes, 5)
    assert :error = RestoreCodec.manifest(bytes, 4)
    for invalid <- [tl(entries), Enum.reverse(entries), entries ++ [List.last(entries)], [entry(".", "regular", 0, hash(""), 0o600)], [hd(entries), entry("missing/child", "regular", 0, hash(""), 0o600)]] do
      assert :error = RestoreCodec.encode(:manifest, ["loopex:current-state-manifest:v1", invalid])
    end
    assert :error = RestoreCodec.encode(:manifest, ["loopex:current-state-manifest:v1", [hd(entries), %{Enum.at(entries, 2) | "size" => 1}]])
  end

  test "actual ordinary Local generation bytes and binding pass without rewriting" do
    root = Path.join(System.tmp_dir!(), "loopex-restore-codec-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)
    assert {:ok, prepared} = Ledger.prepare(root, "codec-test", 5_000)
    bytes = File.read!(Path.join(root, "generation"))
    assert {:ok, generation} = RestoreCodec.decode(:generation, bytes)
    assert generation["executor_epoch"] == prepared.executor_epoch
    assert {:ok, ^bytes} = RestoreCodec.encode(:generation, generation)
    stat = File.stat!(root)
    assert {:ok, binding} = RestoreCodec.ledger_binding(%{"expanded_root" => root, "major_device" => stat.major_device, "inode" => stat.inode})
    assert binding == prepared.root_binding
    assert :error = RestoreCodec.encode(:generation, %{generation | "executor_epoch" => 0})
    assert File.read!(Path.join(root, "generation")) == bytes
  end

  test "intent retains exact candidates and binds source placement bytes identity and ordinal" do
    intent = intent(1, "executor")
    assert {:ok, bytes} = RestoreCodec.encode(:intent, intent)
    assert {:ok, ^intent} = RestoreCodec.decode(:intent, bytes)
    for {key, value} <- [{"ordinal", 2}, {"tx_id", String.duplicate("b", 64)}, {"plan_digest", @hex}, {"source_state_binding", @hex}, {"destination_state_binding", @hex}, {"generations", []}] do
      assert :error = RestoreCodec.encode(:intent, Map.put(intent, key, value))
    end
    [candidate] = intent["generations"]
    assert :error = RestoreCodec.encode(:candidate, Map.put(candidate, "destination_generation_bytes", candidate["source_generation_bytes"]))
    assert :error = RestoreCodec.encode(:candidate, Map.put(candidate, "source_generation_bytes", candidate["source_generation_bytes"] <> <<0>>))
    assert :error = RestoreCodec.encode(:candidate, Map.put(candidate, "source_ledger_binding", @hex))
    assert :error = RestoreCodec.encode(:intent, Map.put(intent, "generations", [Map.put(candidate, "relative_root", "other")]))
  end

  test "candidate epochs are distinct and combined intent has its own whole byte ceiling" do
    two = intent(2, "executor")
    assert {:ok, _} = RestoreCodec.encode(:intent, two)
    [first, second] = two["generations"]
    {:ok, generation} = RestoreCodec.decode(:generation, first["destination_generation_bytes"])
    {:ok, second_generation} = RestoreCodec.decode(:generation, second["destination_generation_bytes"])
    {:ok, reused} = RestoreCodec.encode(:generation, Map.merge(second_generation, Map.take(generation, ["executor_epoch", "generation_id"])))
    assert :error = RestoreCodec.encode(:intent, %{two | "generations" => [first, %{second | "destination_generation_bytes" => reused}]})
    large = intent(32, String.duplicate("e", 1_000))
    assert {:ok, plan_bytes} = RestoreCodec.encode(:plan, large["plan"])
    assert byte_size(plan_bytes) < 65_536
    assert byte_size(:erlang.term_to_binary(large, [:deterministic])) > 65_536
    assert :error = RestoreCodec.encode(:intent, large)
  end

  test "complete manifest whole cap is independent of entry and path limits" do
    entries = [entry(".", "directory", 0, nil, 0o700) | Enum.map(1..520, fn id -> entry(String.pad_leading(Integer.to_string(id), 3, "0") <> String.duplicate("p", 8_000), "regular", 0, hash(""), 0o600) end)]
    manifest = ["loopex:current-state-manifest:v1", entries]
    assert byte_size(:erlang.term_to_binary(manifest, [:deterministic])) > 4_194_304
    assert :error = RestoreCodec.encode(:manifest, manifest)
  end

  test "limits require checked cleanup arithmetic and representable monotonic durations" do
    assert {:ok, %{cleanup_window_ms: 10_000}} = RestoreCodec.limits(%{"work_ms" => 500, "cleanup_grace_ms" => 5})
    assert {:ok, %{cleanup_window_ms: 12_001}} = RestoreCodec.limits(%{"work_ms" => 500, "cleanup_grace_ms" => 10_001})
    for value <- [0, -1, 1.0, Integer.pow(2, 64) - 1, Integer.pow(2, 64)] do
      assert :error = RestoreCodec.limits(%{"work_ms" => value, "cleanup_grace_ms" => 5})
    end
    invocation = %{"work_ms" => 500, "cleanup_grace_ms" => 5, "max_total_file_bytes" => 0, "prior_admin_authority" => "none", "prior_admin_evidence_sha256" => nil}
    assert {:ok, _} = RestoreCodec.encode(:invocation, invocation)
    assert :error = RestoreCodec.encode(:invocation, %{invocation | "prior_admin_evidence_sha256" => @hex})
    assert :error = RestoreCodec.encode(:invocation, %{invocation | "prior_admin_authority" => "joined"})
  end

  defp plan do
    {:ok, empty} = RestoreCodec.lineage_digest([])
    %{"version" => 1, "tx_id" => @hex, "source_state_root" => "/state/source", "source_state_placement" => placement("/state/source", 1), "source_status" => "available", "backup_state_root" => "/state/backup", "destination_state_root" => "/state/destination", "manifest_sha256" => @hex, "cut_id" => @hex, "prior_restore_count" => 0, "prior_lineage_sha256" => empty, "runtime_ids" => [], "stores" => [], "ledgers" => [], "workspace" => %{"root" => "/workspace", "workspace_ref" => "workspace:" <> @hex}, "host_attestation" => %{"latest_cut" => true, "no_post_cut_activity" => true, "all_other_copies_excluded" => true, "old_authority_termination" => "joined", "host_ledgers_validated" => true, "evidence_sha256" => @hex}}
  end
  defp placement(root, inode), do: %{"expanded_root" => root, "major_device" => 3, "inode" => inode}
  defp intent(count, identity) do
    base = plan()
    pairs = Enum.map(1..count, fn id ->
      relative = "ledger-" <> String.pad_leading(Integer.to_string(id), 3, "0")
      source = placement(Path.join(base["source_state_root"], relative), id + 10)
      destination = placement(Path.join(base["destination_state_root"], relative), id + 100)
      {:ok, source_binding} = RestoreCodec.ledger_binding(source)
      {:ok, destination_binding} = RestoreCodec.ledger_binding(destination)
      {:ok, source_bytes} = RestoreCodec.encode(:generation, generation(identity, id, source_binding))
      {:ok, destination_bytes} = RestoreCodec.encode(:generation, generation(identity, id + 100, destination_binding))
      {%{"relative_root" => relative, "executor_identity" => identity, "source_generation_sha256" => hash(source_bytes), "source_placement" => source},
       %{"relative_root" => relative, "executor_identity" => identity, "source_generation_bytes" => source_bytes, "destination_generation_bytes" => destination_bytes, "source_ledger_binding" => source_binding, "destination_ledger_placement" => destination, "destination_ledger_binding" => destination_binding}}
    end)
    plan = %{base | "ledgers" => Enum.map(pairs, &elem(&1, 0))}
    {:ok, digest} = RestoreCodec.plan_digest(plan)
    destination = placement(base["destination_state_root"], 2)
    {:ok, source_binding} = RestoreCodec.state_binding(base["source_state_placement"])
    {:ok, destination_binding} = RestoreCodec.state_binding(destination)
    %{"kind" => "loopex_current_restore_intent_v1", "ordinal" => 1, "tx_id" => @hex, "plan_digest" => digest, "plan" => plan, "prior_lineage_sha256" => base["prior_lineage_sha256"], "source_state_binding" => source_binding, "destination_state_placement" => destination, "destination_state_binding" => destination_binding, "generations" => Enum.map(pairs, &elem(&1, 1))}
  end
  defp generation(identity, epoch, binding), do: %{:ledger_kind => "local_executor_generation_v1", "executor_epoch" => epoch, "executor_identity" => identity, "generation_id" => Base.encode16(<<epoch::unsigned-256>>, case: :lower), "root_binding" => binding}
  defp entry(path, kind, size, sha, mode), do: %{"path" => path, "kind" => kind, "mode" => mode, "size" => size, "sha256" => sha}
  defp hash(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
  defp records do
    common = %{"ordinal" => 1, "tx_id" => @hex, "intent_sha256" => @hex}
    make = fn type, fields -> {type, Map.merge(common, Map.put(fields, "kind", "loopex_current_restore_#{type}_v1"))} end
    [make.(:ledger_intent, %{"relative_root" => "ledger", "source_state_binding" => @hex, "destination_state_binding" => @hex, "source_generation_sha256" => @hex, "destination_generation_sha256" => @hex, "source_ledger_binding" => @hex, "destination_ledger_binding" => @hex}),
     make.(:ledger_retired, %{"ledger_intent_sha256" => @hex, "relative_root" => "ledger", "source_state_binding" => @hex, "source_ledger_binding" => @hex, "source_generation_sha256" => @hex, "destination_state_binding" => @hex, "destination_generation_sha256" => @hex}),
     make.(:source_retirement, %{"disposition" => "source_retired", "source_state_binding" => @hex, "destination_state_binding" => @hex, "host_evidence_sha256" => @hex, "ledger_retirements" => [%{"relative_root" => "ledger", "record_sha256" => @hex}]}),
     make.(:ledger_committed, %{"relative_root" => "ledger", "ledger_intent_sha256" => @hex, "source_retirement_sha256" => @hex, "destination_state_binding" => @hex, "destination_ledger_binding" => @hex, "destination_generation_sha256" => @hex}),
     make.(:committed, %{"plan_digest" => @hex, "prior_lineage_sha256" => @hex, "baseline_manifest_sha256" => @hex, "activation_manifest_sha256" => @hex, "source_retirement_sha256" => @hex, "destination_state_binding" => @hex, "ledger_proofs" => [%{"relative_root" => "ledger", "record_sha256" => @hex}]}),
     {:claim, %{"kind" => "loopex_current_restore_claim_v1", "tx_id" => @hex, "plan_digest" => @hex, "claim_nonce" => @hex, "state_root" => "/state/source", "role" => "source"}},
     {:receipt, %{"kind" => "loopex_current_restore_receipt_v1", "tx_id" => @hex, "ordinal" => 1, "plan_digest" => @hex, "intent_sha256" => @hex, "committed_sha256" => @hex, "source_retirement_sha256" => @hex, "baseline_manifest_sha256" => @hex, "activation_manifest_sha256" => @hex, "prior_lineage_sha256" => @hex, "destination_state_binding" => @hex, "ledger_count" => 1}},
     {:observation, %{"kind" => "loopex_current_restore_observation_v1", "tx_id" => @hex, "ordinal" => nil, "phase" => "claim", "intent" => "absent", "cleanup" => "joined", "claim" => "none", "reason" => "none"}},
     {:refusal, %{"kind" => "loopex_current_restore_refusal_v1", "tx_id" => nil, "code" => "invalid_plan", "phase" => "claim", "cleanup" => "joined", "claim" => "none"}},
     {:lookup_refusal, %{"kind" => "loopex_current_restore_lookup_refusal_v1", "tx_id" => nil, "code" => "invalid_query", "cleanup" => "joined"}}]
  end
end
