defmodule LoopexComposition.RestorePendingIntakeTest do
  use ExUnit.Case, async: false

  alias Loopex.Executor.Local.{Ledger, RestoreCodec}
  alias LoopexComposition.{Restore, WorkspaceIdentity}
  alias LoopexComposition.Restore.IO, as: RestoreIO

  @limits %{"work_ms" => 10_000, "cleanup_grace_ms" => 1_000}
  @total 16_777_216

  setup do
    {:ok, temp} = WorkspaceIdentity.resolve_path(System.tmp_dir!())
    root = Path.join(temp, "restore-intake-" <> Base.encode16(:crypto.strong_rand_bytes(12), case: :lower))
    File.mkdir!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  for status <- ~w(available lost), authority <- ~w(joined host_rebooted) do
    test "actual #{status} pending candidates admit #{authority} intake without mutation", %{root: root} do
      cut = prepare(root, unquote(status))
      {terminal, prior} = strand(cut, "source_retirement")
      assert {:joined, _, old_evidence} = terminal
      assert old_evidence.restore_observation["ordinal"] == 1
      assert old_evidence.restore_observation["intent"] == "validated"
      assert old_evidence.restore_observation["reason"] == "caller_lost"
      before = manifest(root)
      original = File.read!(intent_path(cut))
      invoke = invocation(unquote(authority), prior)
      {result, events} = intake(cut, invoke)
      assert {:joined, {:ok, retained}, evidence} = result
      assert retained.intent == original and retained.observation["phase"] == "source_retirement"
      assert {:ok, intent} = RestoreCodec.decode(:intent, retained.intent)
      assert intent["plan"] == cut.plan
      assert File.read!(Path.join(cut.destination, "receipts/generation")) ==
               hd(intent["generations"])["source_generation_bytes"]
      assert evidence.restore_observation["ordinal"] == 1
      assert evidence.restore_observation["intent"] == "validated"
      assert manifest(root) == before
      assert_read_only(events, evidence)
      assert {:ok, _} = RestoreCodec.encode(:observation, evidence.restore_observation)
    end
  end

  for status <- ~w(available lost) do
    test "complete #{status} pre-intent staging preserves its exact baseline", %{root: root} do
      cut = prepare(root, unquote(status))
      {terminal, prior} = strand(cut, "destination_intent")
      assert {:joined, _, evidence} = terminal
      assert evidence.restore_observation["intent"] == "absent"
      assert evidence.restore_observation["cleanup"] == "joined"
      before = manifest(root)
      {result, events} = intake(cut, invocation("joined", prior))
      assert {:joined, {:ok, retained}, current} = result
      assert retained.intent == nil and retained.baseline == cut.baseline
      assert retained.observation["intent"] == "may_exist"
      assert current.restore_observation["claim"] == "retained"
      assert manifest(root) == before
      assert_read_only(events, current)
    end
  end

  test "none does not admit or reclaim an actual retained claim", %{root: root} do
    cut = prepare(root, "available")
    {_terminal, _prior} = strand(cut, "source_retirement")
    before = manifest(root)
    {result, events} = intake(cut, invocation())
    assert {:joined, {:error, "authority_unconfirmed"}, evidence} = result
    assert manifest(root) == before
    assert evidence.restore_observation["intent"] != "absent"
    assert evidence.restore_observation["claim"] == "retained"
    assert_read_only(events, evidence)
    assert {:pending, _} = Restore.lookup(cut.destination, cut.plan["tx_id"], @limits)
  end

  test "a live original owner does not become joined authority from its filesystem claim", %{root: root} do
    cut = prepare(root, "available")
    owned = launch({:restore_first, cut.plan, invocation()}, :restore_phase)
    try do
      {_id, _events} = hold(owned, "source_retirement", [])
      assert Process.alive?(owned.guardian) and Process.alive?(owned.worker)
      before = manifest(root)
      {result, events} = intake(cut, invocation())
      assert {:joined, {:error, "authority_unconfirmed"}, evidence} = result
      assert manifest(root) == before
      assert Process.alive?(owned.guardian) and Process.alive?(owned.worker)
      assert_read_only(events, evidence)
      Process.exit(owned.caller, :kill)
      assert {:joined, _, stopped} = receive_terminal(owned)
      assert stopped.opens == stopped.closes
      join(owned, [:killed, :normal, :normal])
    after
      cleanup(owned)
    end
  end

  test "changed original plan cannot consume actual pending candidates", %{root: root} do
    cut = prepare(root, "available")
    {_terminal, prior} = strand(cut, "source_retirement")
    changed = %{cut | plan: %{cut.plan | "cut_id" => hash("changed-original-cut")}}
    before = manifest(root)
    {result, events} = intake(changed, invocation("joined", prior))
    assert {:joined, {:error, "restore_conflict"}, evidence} = result
    assert manifest(root) == before
    assert_read_only(events, evidence)
  end

  for field <- ~w(plan_digest role tx_id) do
    test "actual retained claim with changed #{field} remains fenced", %{root: root} do
      cut = prepare(root, "available")
      {_terminal, prior} = strand(cut, "source_retirement")
      path = claim_path(cut.destination) |> Path.join("owner")
      assert {:ok, owner} = RestoreCodec.decode(:claim, File.read!(path))
      value = if unquote(field) == "role", do: "source", else: hash("foreign-owner")
      assert {:ok, bytes} = RestoreCodec.encode(:claim, Map.put(owner, unquote(field), value))
      File.write!(path, bytes)
      before = manifest(root)
      {result, events} = intake(cut, invocation("joined", prior))
      assert {:joined, {:error, "restore_conflict"}, evidence} = result
      assert File.read!(path) == bytes and manifest(root) == before
      assert_read_only(events, evidence)
    end
  end

  for fault <- [:generation, :mode] do
    test "pending intake refuses actual generation #{fault} outside retained phase", %{root: root} do
      cut = prepare(root, "available")
      {_terminal, prior} = strand(cut, "source_retirement")
      path = Path.join(cut.destination, "receipts/generation")
      if unquote(fault) == :generation do
        other = Path.join(root, "other-ledger")
        assert {:ok, _} = Ledger.prepare(other, "intake-local", 1_000)
        File.write!(path, File.read!(Path.join(other, "generation")))
      else
        File.chmod!(path, 0o640)
      end
      before = manifest(root)
      {result, events} = intake(cut, invocation("joined", prior))
      assert {:joined, {:error, "invalid_current_history"}, evidence} = result
      assert manifest(root) == before
      assert_read_only(events, evidence)
    end
  end

  test "incomplete pre-intent staging is not a complete baseline", %{root: root} do
    cut = prepare(root, "available")
    {_terminal, prior} = strand(cut, "destination_intent")
    File.rm!(Path.join(cut.destination, "ordinary"))
    before = manifest(root)
    {result, events} = intake(cut, invocation("joined", prior))
    assert {:joined, {:error, "inventory_mismatch"}, evidence} = result
    assert manifest(root) == before
    assert_read_only(events, evidence)
  end

  test "guardian loss retains last actual intent ordinal phase and uncertain cleanup", %{root: root} do
    cut = prepare(root, "available")
    owned = launch({:restore_first, cut.plan, invocation()}, :restore_phase)
    try do
      {_id, _events} = hold(owned, "source_retirement", [])
      Process.exit(owned.guardian, :kill)
      {result, _events} = collect(owned, [])
      assert {:unconfirmed, :guardian_lost, %{restore_observation: observation}} = result
      assert observation["tx_id"] == cut.plan["tx_id"] and observation["ordinal"] == 1
      assert observation["intent"] == "validated" and observation["phase"] == "source_retirement"
      assert observation["cleanup"] == "unconfirmed" and observation["claim"] == "retained"
      assert observation["reason"] == "worker_unjoined"
      assert {:ok, _} = RestoreCodec.encode(:observation, observation)
      join(owned, [:normal, :killed, :killed])
      assert File.regular?(intent_path(cut))
      assert File.regular?(Path.join(claim_path(cut.destination), "owner"))
    after
      cleanup(owned)
    end
  end

  test "pre-claim guardian loss cannot report absent intent joined cleanup or a retained claim", %{root: root} do
    cut = prepare(root, "available")
    owned = launch({:restore_first, cut.plan, invocation()}, :restore_phase)
    try do
      {_id, _events} = hold(owned, "claim", [])
      Process.exit(owned.guardian, :kill)
      {result, _events} = collect(owned, [])
      assert {:unconfirmed, :guardian_lost, %{restore_observation: observation}} = result
      assert observation["ordinal"] == nil and observation["intent"] == "may_exist"
      assert observation["cleanup"] == "unconfirmed" and observation["claim"] == "none"
      assert {:ok, _} = RestoreCodec.encode(:observation, observation)
      join(owned, [:normal, :killed, :killed])
      assert File.lstat(intent_path(cut)) == {:error, :enoent}
    after
      cleanup(owned)
    end
  end

  # Concept: prior authority evidence follows the actual original owner's joins.
  # Technical depth: hold a real named publication phase, kill only its caller,
  # then observe original closed-descriptor terminal evidence and exact three
  # monitors. A new intake is read-only and cannot reacquire any claim.
  defp strand(cut, phase) do
    owned = launch({:restore_first, cut.plan, invocation()}, :restore_phase)
    try do
      {_id, _events} = hold(owned, phase, [])
      Process.exit(owned.caller, :kill)
      terminal = receive_terminal(owned)
      assert {:joined, _, evidence} = terminal
      assert evidence.opens == evidence.closes
      assert evidence.restore_observation["claim"] == "retained"
      join(owned, [:killed, :normal, :normal])
      owner = File.read!(Path.join(claim_path(cut.destination), "owner"))
      evidence_digest = hash(:erlang.term_to_binary({owner, evidence.opens, evidence.closes,
        Enum.map(actors(owned), fn {_actor, monitor} -> Process.get({:intake_down, monitor}) end)}, [:deterministic]))
      {terminal, evidence_digest}
    after
      cleanup(owned)
    end
  end

  defp intake(cut, invoke) do
    owned = launch({:restore_pending_intake, cut.plan, invoke}, :restore_pending_decode)
    try do
      {result, events} = collect(owned, [])
      join(owned, [:normal, :normal, :normal])
      {result, events}
    after
      cleanup(owned)
    end
  end

  defp assert_read_only(events, evidence) do
    assert evidence.opens == evidence.closes and evidence.claim_count == 0
    Enum.each(events, fn
      {:issued, _, {:open, _}} -> :ok
      {:issued, _, {:close, _}} -> :ok
      {:issued, _, {:restore_phase, "claim"}} -> :ok
      {:issued, _, {:restore_observation_facts, _}} -> :ok
      {:issued, _, kind} -> assert kind in [:manifest_stat, :lookup_stat, :lookup_list,
        :lookup_intent_decode, :lookup_ledger_placement_stat, :lookup_descriptor_stat,
        :lookup_claim_stat, :lookup_claim_names, :lookup_claim_decode,
        :lookup_recheck_names, :lookup_recheck_absent, :read, :restore_pending_decode,
        :descriptor_stat, :list, :hash_read, :source_absence]
      _ -> :ok
    end)
  end

  defp prepare(root, status) do
    source = Path.join(root, "source")
    backup = Path.join(root, "backup")
    destination = Path.join(root, "destination")
    workspace = Path.join(root, "workspace")
    for path <- [source, destination, workspace], do: File.mkdir!(path)
    assert {:ok, _} = Ledger.prepare(Path.join(source, "receipts"), "intake-local", 1_000)
    File.write!(Path.join(source, "ordinary"), "unchanged current bytes")
    assert {:ok, _} = File.cp_r(source, backup)
    baseline = manifest(backup)
    generation = File.read!(Path.join(source, "receipts/generation"))
    assert {:ok, workspace_ref} = WorkspaceIdentity.reference(workspace)
    {:ok, entries} = RestoreCodec.manifest(baseline, @total)
    {:ok, lineage} = RestoreCodec.lineage_digest(Enum.filter(entries, fn entry ->
      Enum.any?(Path.split(entry["path"]), &(&1 in [".loopex-restore", "restore-lineage"]))
    end))
    plan = %{"version" => 1, "tx_id" => hash("pending-original-tx"), "source_state_root" => source,
      "source_state_placement" => placement(source), "source_status" => status,
      "backup_state_root" => backup, "destination_state_root" => destination,
      "manifest_sha256" => hash(baseline), "cut_id" => hash("pending-cut"),
      "prior_restore_count" => 0, "prior_lineage_sha256" => lineage,
      "runtime_ids" => [], "stores" => [], "ledgers" => [%{"relative_root" => "receipts",
        "executor_identity" => "intake-local", "source_generation_sha256" => hash(generation),
        "source_placement" => placement(Path.join(source, "receipts"))}],
      "workspace" => %{"root" => workspace, "workspace_ref" => workspace_ref},
      "host_attestation" => %{"latest_cut" => true, "no_post_cut_activity" => true,
        "all_other_copies_excluded" => true, "old_authority_termination" => "joined",
        "host_ledgers_validated" => true, "evidence_sha256" => hash("quiescent-native-writer")}}
    if status == "lost", do: File.rm_rf!(source)
    %{plan: plan, source: source, destination: destination, baseline: baseline}
  end

  defp invocation(authority \\ "none", evidence \\ nil), do: Map.merge(@limits,
    %{"max_total_file_bytes" => @total, "prior_admin_authority" => authority,
      "prior_admin_evidence_sha256" => evidence})
  defp placement(root) do
    stat = File.lstat!(root)
    %{"expanded_root" => root, "major_device" => stat.major_device, "inode" => stat.inode}
  end
  defp manifest(root) do
    assert {:joined, {:ok, bytes}, _} = RestoreIO.run({:manifest, root, @total}, @limits)
    bytes
  end
  defp hash(bytes), do: RestoreCodec.digest_bytes(bytes)
  defp claim_path(root) do
    {:ok, digest} = RestoreCodec.claim_digest(root)
    Path.join(Path.dirname(root), ".loopex-restore-claim-" <> digest)
  end
  defp intent_path(cut), do: Path.join(cut.destination, ".loopex-restore/lineage/00000001/intent")
  defp left(cutoff), do: max(0, cutoff - System.monotonic_time(:millisecond))

  defp launch(operation, pause) do
    parent = self()
    {caller, monitor} = spawn_monitor(fn ->
      send(parent, {:result, self(), RestoreIO.run(operation, @limits, probe: parent, pause_at: pause)})
    end)
    receive do
      {:restore_io, guardian, worker, reference, {:installed, _, cutoff}} ->
        %{caller: caller, caller_monitor: monitor, guardian: guardian, worker: worker,
          reference: reference, guardian_monitor: Process.monitor(guardian),
          worker_monitor: Process.monitor(worker), cutoff: cutoff + 10_000}
    after
      10_000 -> flunk("original intake actors unavailable")
    end
  end

  defp hold(owned, wanted, events) do
    receive do
      {:restore_io, guardian, worker, reference, {:issued, id, {:restore_phase, phase}} = event}
      when guardian == owned.guardian and worker == owned.worker and reference == owned.reference ->
        if phase == wanted do
          {id, [event | events]}
        else
          send(guardian, {:proceed, reference, id})
          hold(owned, wanted, [event | events])
        end
      {:restore_io, guardian, worker, reference, event}
      when guardian == owned.guardian and worker == owned.worker and reference == owned.reference ->
        hold(owned, wanted, [event | events])
    after
      left(owned.cutoff) -> flunk("named original phase unavailable at original cutoff")
    end
  end

  defp collect(owned, events) do
    receive do
      {:restore_io, guardian, worker, reference, {:issued, id, :restore_pending_decode} = event}
      when guardian == owned.guardian and worker == owned.worker and reference == owned.reference ->
        send(guardian, {:proceed, reference, id})
        collect(owned, [event | events])
      {:restore_io, guardian, worker, reference, event}
      when guardian == owned.guardian and worker == owned.worker and reference == owned.reference ->
        collect(owned, [event | events])
      {:result, caller, result} when caller == owned.caller -> {result, events}
    after
      left(owned.cutoff) -> flunk("original intake result unavailable")
    end
  end

  defp receive_terminal(owned) do
    receive do
      {:restore_io, guardian, worker, reference, {:terminal, result}}
      when guardian == owned.guardian and worker == owned.worker and reference == owned.reference -> result
      {:restore_io, guardian, worker, reference, _event}
      when guardian == owned.guardian and worker == owned.worker and reference == owned.reference -> receive_terminal(owned)
    after
      left(owned.cutoff) -> flunk("original stopped-owner terminal unavailable")
    end
  end

  defp actors(owned), do: [{owned.caller, owned.caller_monitor},
    {owned.guardian, owned.guardian_monitor}, {owned.worker, owned.worker_monitor}]
  defp join(owned, reasons) do
    Enum.zip(actors(owned), reasons) |> Enum.each(fn {{actor, monitor}, reason} ->
      receive do
        {:DOWN, ^monitor, :process, ^actor, actual} ->
          Process.put({:intake_down, monitor}, actual)
          assert actual == reason
      after
        left(owned.cutoff) -> flunk("exact original actor join unavailable")
      end
    end)
  end
  defp cleanup(owned) do
    Enum.each(actors(owned), fn {actor, monitor} ->
      if is_nil(Process.get({:intake_down, monitor})) do
        Process.exit(actor, :kill)
        receive do
          {:DOWN, ^monitor, :process, ^actor, reason} -> Process.put({:intake_down, monitor}, reason)
        after
          left(owned.cutoff) -> flunk("failure cleanup did not join original actor")
        end
      end
    end)
  end
end
