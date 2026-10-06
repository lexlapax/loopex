Code.require_file("support/restore_fixture_copy.ex", __DIR__)

defmodule LoopexComposition.RestoreResolutionTest do
  use ExUnit.Case, async: false

  alias Loopex.Executor.Local.{Ledger, RestoreCodec}
  alias LoopexComposition.{Restore, WorkspaceIdentity}
  alias LoopexComposition.RestoreFixtureCopy
  alias LoopexComposition.Restore.IO, as: RestoreIO

  @limits %{"work_ms" => 10_000, "cleanup_grace_ms" => 1_000}
  @total 16_777_216

  setup do
    {:ok, temp} = WorkspaceIdentity.resolve_path(System.tmp_dir!())

    root =
      Path.join(
        temp,
        "restore-resolution-" <> Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)
      )

    File.mkdir!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "exact committed duplicate joins without allocation or opening old source and backup", %{
    root: root
  } do
    fixture = first(root)
    File.rm_rf!(fixture.source)
    File.rm_rf!(fixture.plan["backup_state_root"])
    File.write!(Path.join(fixture.destination, "later-ordinary-file"), "evolved ordinary state")
    before = manifest(root)
    assert_resolution(fixture, {:committed, fixture.receipt})
    assert manifest(root) == before
    assert File.lstat(fixture.source) == {:error, :enoent}
    assert File.lstat(fixture.plan["backup_state_root"]) == {:error, :enoent}
  end

  test "original plan at retained B returns its historical receipt after actual A to B to C", %{
    root: root
  } do
    first = first(root)
    next = restore_cut(root, first.destination, first.workspace, 1)
    File.rm_rf!(first.source)
    File.rm_rf!(first.plan["backup_state_root"])
    File.rm_rf!(next.destination)
    before = manifest(root)
    assert_resolution(first, {:committed, first.receipt})
    assert manifest(root) == before
    assert File.lstat(next.destination) == {:error, :enoent}
    assert {:error, :source_retired} = Loopex.Executor.Local.RestoreGuard.state(first.destination)
  end

  test "same tx with changed canonical plan refuses without claims or writes", %{root: root} do
    fixture = first(root)
    changed = %{fixture | plan: %{fixture.plan | "cut_id" => hash("changed-cut")}}
    assert {:ok, _} = RestoreCodec.encode(:plan, changed.plan)
    before = manifest(root)
    assert_resolution(changed, {:not_committed, "restore_conflict"})
    assert manifest(root) == before
  end

  test "invocation total allowance does not change exact committed receipt identity", %{
    root: root
  } do
    fixture = first(root)
    before = manifest(root)
    invoke = %{invocation() | "max_total_file_bytes" => @total + 1}
    assert_resolution(fixture, {:committed, fixture.receipt}, invoke)
    assert manifest(root) == before
  end

  test "retained matching claim stays fenced without implicit reclaim", %{root: root} do
    fixture = first(root)
    claim = install_claim(fixture)
    bytes = File.read!(Path.join(claim, "owner"))
    before = manifest(root)
    assert_resolution(fixture, {:not_committed, "restore_conflict"})
    assert manifest(root) == before
    assert File.read!(Path.join(claim, "owner")) == bytes
  end

  for status <- ~w(available lost) do
    test "preinstalled foreign destination claim excludes fresh #{status} restore before native acquisition",
         %{root: root} do
      {source, workspace} = source(root)
      cut = root |> prepare_cut(source, workspace, 0) |> with_source_status(unquote(status))
      foreign = %{cut | plan: %{cut.plan | "tx_id" => hash("foreign-preflight")}}
      claim = install_claim(foreign)
      original = File.read!(Path.join(claim, "owner"))
      before = manifest(root)
      assert_resolution(cut, {:not_committed, "restore_conflict"})
      assert manifest(root) == before
      assert File.read!(Path.join(claim, "owner")) == original
      assert File.lstat(claim_path(cut.source)) == {:error, :enoent}
    end
  end

  test "fresh tx cannot replace a real unfinished original transition", %{root: root} do
    {source, workspace} = source(root)
    cut = prepare_cut(root, source, workspace, 0)
    owned = launch_restore(cut)

    try do
      {id, _} = hold_phase(owned, "source_retirement", [])

      try do
        replacement = %{cut | plan: %{cut.plan | "tx_id" => hash("fresh-tx")}}
        before = manifest(root)
        assert_resolution(replacement, {:not_committed, "restore_conflict"})
        assert manifest(root) == before
      after
        send(owned.guardian, {:proceed, owned.reference, id})
        finish_restore(owned)
      end
    after
      cleanup_owned(owned)
    end
  end

  test "missing completion dependency cannot return the retained receipt", %{root: root} do
    fixture = first(root)
    File.rm!(Path.join(fixture.destination, "receipts/restore-lineage/00000001/committed"))
    before = manifest(root)
    assert_resolution(fixture, {:not_committed, "invalid_current_history"})
    assert manifest(root) == before
  end

  # Concept: classification is read-only even when it returns a committed receipt.
  # Technical depth: pause the exact pure reduction after original monitors install;
  # observe one guardian/worker, forbid every mutation primitive and join exact
  # original actors under the captured cutoff. A late monitor is not a join proof.
  defp assert_resolution(fixture, expected, invoke \\ invocation()) do
    parent = self()

    {caller, monitor} =
      spawn_monitor(fn ->
        send(
          parent,
          {:restore_result, self(),
           Restore.first(fixture.plan, invoke,
             probe: parent,
             pause_at: :restore_classification_decode
           )}
        )
      end)

    owned =
      receive do
        {:restore_io, guardian, worker, reference, {:installed, _, cutoff}} ->
          %{
            caller: caller,
            caller_monitor: monitor,
            guardian: guardian,
            worker: worker,
            reference: reference,
            guardian_monitor: Process.monitor(guardian),
            worker_monitor: Process.monitor(worker),
            cutoff: cutoff + 10_000
          }
      after
        10_000 -> flunk("resolution did not install original actors")
      end

    try do
      {result, events} = collect_resolution(owned, [])
      assert {:joined, {:ok, %{restore_result: ^expected, release_claims: []}}, evidence} = result
      assert evidence.opens == evidence.closes and evidence.claim_count == 0
      assert Enum.count(events, &match?({:issued, _, :restore_classification_decode}, &1)) == 1

      assert Enum.all?(events, fn
               {:issued, _, {:open, _}} ->
                 true

               {:issued, _, {:close, _}} ->
                 true

               {:issued, _, {:restore_phase, "claim"}} ->
                 true

               {:issued, _, kind} ->
                 kind in [
                   :manifest_stat,
                   :lookup_stat,
                   :lookup_list,
                   :lookup_intent_decode,
                   :lookup_ledger_placement_stat,
                   :lookup_descriptor_stat,
                   :lookup_claim_stat,
                   :lookup_claim_names,
                   :lookup_claim_decode,
                   :lookup_recheck_names,
                   :lookup_recheck_absent,
                   :read,
                   :restore_classification_decode
                 ]

               _ ->
                 true
             end)

      join(owned)
    after
      cleanup_owned(owned)
    end
  end

  defp collect_resolution(owned, events) do
    receive do
      {:restore_io, guardian, worker, reference,
       {:issued, id, :restore_classification_decode} = event}
      when guardian == owned.guardian and worker == owned.worker and reference == owned.reference ->
        send(guardian, {:proceed, reference, id})
        collect_resolution(owned, [event | events])

      {:restore_io, guardian, worker, reference, event}
      when guardian == owned.guardian and worker == owned.worker and reference == owned.reference ->
        collect_resolution(owned, [event | events])

      {:restore_result, caller, result} when caller == owned.caller ->
        {result, events}
    after
      left(owned.cutoff) -> flunk("resolution unavailable at original cutoff")
    end
  end

  defp with_source_status(cut, "available"), do: cut

  defp with_source_status(cut, "lost") do
    File.rm_rf!(cut.source)
    %{cut | plan: %{cut.plan | "source_status" => "lost"}}
  end

  defp source(root) do
    source = Path.join(root, "source")
    workspace = Path.join(root, "workspace")
    File.mkdir!(source)
    File.mkdir!(workspace)
    assert {:ok, _} = Ledger.prepare(Path.join(source, "receipts"), "lookup-local", 1_000)
    File.write!(Path.join(source, "orphan"), "preserved ordinary bytes")
    {source, workspace}
  end

  defp first(root) do
    {source, workspace} = source(root)
    restore_cut(root, source, workspace, 0)
  end

  defp restore_cut(root, source, workspace, prior),
    do: root |> prepare_cut(source, workspace, prior) |> execute_cut()

  defp prepare_cut(root, source, workspace, prior) do
    backup = Path.join(root, "backup-#{prior}")
    destination = Path.join(root, "destination-#{prior}")
    File.mkdir!(destination)
    assert {:ok, _} = RestoreFixtureCopy.copy(source, backup)
    baseline = manifest(backup)
    {:ok, entries} = RestoreCodec.manifest(baseline, @total)

    {:ok, lineage} =
      RestoreCodec.lineage_digest(
        Enum.filter(entries, fn entry ->
          Enum.any?(Path.split(entry["path"]), &(&1 in [".loopex-restore", "restore-lineage"]))
        end)
      )

    generation_bytes = File.read!(Path.join(source, "receipts/generation"))
    {:ok, generation} = Ledger.decode_bytes(generation_bytes, "local_executor_generation_v1")
    {:ok, workspace_ref} = WorkspaceIdentity.reference(workspace)

    plan = %{
      "version" => 1,
      "tx_id" => hash("lookup-restore-#{prior}"),
      "source_state_root" => source,
      "source_state_placement" => placement(source),
      "source_status" => "available",
      "backup_state_root" => backup,
      "destination_state_root" => destination,
      "manifest_sha256" => hash(baseline),
      "cut_id" => hash("cut-#{prior}"),
      "prior_restore_count" => prior,
      "prior_lineage_sha256" => lineage,
      "runtime_ids" => [],
      "stores" => [],
      "ledgers" => [
        %{
          "relative_root" => "receipts",
          "executor_identity" => generation["executor_identity"],
          "source_generation_sha256" => hash(generation_bytes),
          "source_placement" => placement(Path.join(source, "receipts"))
        }
      ],
      "workspace" => %{"root" => workspace, "workspace_ref" => workspace_ref},
      "host_attestation" => %{
        "latest_cut" => true,
        "no_post_cut_activity" => true,
        "all_other_copies_excluded" => true,
        "old_authority_termination" => "joined",
        "host_ledgers_validated" => true,
        "evidence_sha256" => hash("fixture-local-joined")
      }
    }

    %{plan: plan, destination: destination, source: source, workspace: workspace}
  end

  defp execute_cut(cut) do
    assert {:joined, {:ok, %{restore_result: {:committed, receipt}, release_claims: []}},
            evidence} =
             Restore.first(cut.plan, invocation())

    assert evidence.opens == evidence.closes and evidence.claim_count == 0
    Map.put(cut, :receipt, receipt)
  end

  defp invocation,
    do:
      Map.merge(@limits, %{
        "max_total_file_bytes" => @total,
        "prior_admin_authority" => "none",
        "prior_admin_evidence_sha256" => nil
      })

  defp manifest(root) do
    assert {:joined, {:ok, bytes}, _} = RestoreIO.run({:manifest, root, @total}, @limits)
    bytes
  end

  defp placement(root) do
    stat = File.lstat!(root)
    %{"expanded_root" => root, "major_device" => stat.major_device, "inode" => stat.inode}
  end

  defp hash(bytes), do: RestoreCodec.digest_bytes(bytes)

  defp claim_path(root) do
    {:ok, digest} = RestoreCodec.claim_digest(root)
    Path.join(Path.dirname(root), ".loopex-restore-claim-" <> digest)
  end

  defp claim_bytes(fixture) do
    {:ok, digest} = RestoreCodec.plan_digest(fixture.plan)

    {:ok, bytes} =
      RestoreCodec.encode(:claim, %{
        "kind" => "loopex_current_restore_claim_v1",
        "tx_id" => fixture.plan["tx_id"],
        "plan_digest" => digest,
        "claim_nonce" => hash("retained-fixture-claim"),
        "state_root" => fixture.destination,
        "role" => "destination"
      })

    bytes
  end

  defp install_claim(fixture) do
    path = claim_path(fixture.destination)
    File.mkdir!(path)
    File.chmod!(path, 0o700)
    File.write!(Path.join(path, "owner"), claim_bytes(fixture), [:exclusive])
    File.chmod!(Path.join(path, "owner"), 0o600)
    path
  end

  defp left(cutoff), do: max(0, cutoff - System.monotonic_time(:millisecond))

  defp launch_restore(cut) do
    parent = self()

    {caller, monitor} =
      spawn_monitor(fn ->
        send(
          parent,
          {:restore_result, self(),
           Restore.first(cut.plan, invocation(), probe: parent, pause_at: :restore_phase)}
        )
      end)

    receive do
      {:restore_io, guardian, worker, reference, {:installed, _, cutoff}} ->
        %{
          caller: caller,
          caller_monitor: monitor,
          guardian: guardian,
          worker: worker,
          reference: reference,
          guardian_monitor: Process.monitor(guardian),
          worker_monitor: Process.monitor(worker),
          cutoff: cutoff + 10_000
        }
    after
      10_000 -> flunk("restore did not install")
    end
  end

  defp hold_phase(owned, wanted, events) do
    receive do
      {:restore_io, guardian, worker, reference, {:issued, id, {:restore_phase, phase}} = event}
      when guardian == owned.guardian and worker == owned.worker and reference == owned.reference ->
        if phase == wanted do
          {id, [event | events]}
        else
          send(guardian, {:proceed, reference, id})
          hold_phase(owned, wanted, [event | events])
        end

      {:restore_io, _, _, _, event} ->
        hold_phase(owned, wanted, [event | events])
    after
      left(owned.cutoff) -> flunk("original restore cutoff reached before phase")
    end
  end

  defp finish_restore(owned) do
    receive do
      {:restore_io, guardian, _, reference, {:issued, id, {:restore_phase, _}}} ->
        send(guardian, {:proceed, reference, id})
        finish_restore(owned)

      {:restore_io, _, _, _, _} ->
        finish_restore(owned)

      {:restore_result, caller, result} when caller == owned.caller ->
        assert {:joined, {:ok, %{restore_result: {:committed, _}}}, _} = result
        join(owned)
    after
      left(owned.cutoff) -> flunk("restore result unavailable at original bound")
    end
  end

  defp join(owned) do
    exact_down(owned, owned.caller, owned.caller_monitor, :normal)
    exact_down(owned, owned.guardian, owned.guardian_monitor, :normal)
    exact_down(owned, owned.worker, owned.worker_monitor, :normal)
  end

  defp exact_down(owned, actor, monitor, reason) do
    receive do
      {:DOWN, ^monitor, :process, ^actor, actual} ->
        Process.put({:lookup_original_down, monitor}, actual)
        assert actual == reason
    after
      left(owned.cutoff) -> flunk("exact original actor join unavailable")
    end
  end

  defp cleanup_owned(owned) do
    Enum.each(
      [
        {owned.caller, owned.caller_monitor},
        {owned.guardian, owned.guardian_monitor},
        {owned.worker, owned.worker_monitor}
      ],
      fn {actor, monitor} ->
        if is_nil(Process.get({:lookup_original_down, monitor})) do
          Process.exit(actor, :kill)

          receive do
            {:DOWN, ^monitor, :process, ^actor, reason} ->
              Process.put({:lookup_original_down, monitor}, reason)
          after
            left(owned.cutoff) ->
              flunk("failure cleanup did not join original actor within original bound")
          end
        end
      end
    )
  end
end
