Code.require_file("../../loopex/test/support/configured_genesis_helper.exs", __DIR__)

defmodule LoopexComposition.RestoreWorkflowTest do
  use ExUnit.Case, async: false

  alias Loopex.Executor.Local, as: Local
  alias Loopex.Executor.Local.{CodingTools, Ledger, RestoreCodec, RestoreGuard, WorkspaceLease}
  alias Loopex.Store.Local, as: Store
  alias Loopex.Store.Local.{Artifacts, Log, State, Transfers}
  alias LoopexComposition.{Placement, ResourcePacks, Restore, WorkspaceIdentity}
  alias LoopexComposition.Restore.IO, as: RestoreIO
  alias LoopexComposition.Delegation.{GenesisCodec, RetainedObjects}
  alias LoopexProtocol.{Canonical, Frame}

  @runtime "restore-current"
  @policy %{"id" => "restore-policy", "revision" => "1"}
  @total 16_777_216
  @work 10_000
  @grace 1_000

  defmodule Policy do
    @moduledoc false
    @behaviour Loopex.Policy
    @impl true
    def decide(_), do: {:allow, nil}
  end

  defmodule Model do
    @moduledoc false
    @behaviour Loopex.Model
    @impl true
    def complete(request, options, _progress) do
      index = Agent.get_and_update(options[:observer], &{length(&1), &1 ++ [request]})
      calls = if rem(index, 2) == 0 do
        message = Enum.find(Enum.reverse(request.messages), &(&1["role"] == "user"))
        {:ok, selected} = Frame.decode(message["content"], 8_192)
        [%{id: "call-#{index}", name: selected["tool"], arguments: selected["arguments"]}]
      else
        []
      end
      {:ok, %{completion: "unknown", continuation: nil, text: "done",
        identity: %{provider: "scripted", model: request.model, endpoint: "in-process"},
        usage: %{input_tokens: 1, output_tokens: 1}, tool_calls: calls,
        delta_count: 0, streamed: false, provider_response_id: nil,
        canonical_request_bytes: request.canonical_request_bytes,
        staged_request_digest: request.staged_request_digest}}
    end
  end

  setup do
    {:ok, temp} = WorkspaceIdentity.resolve_path(System.tmp_dir!())
    root = Path.join(temp, "loopex-restore-workflow-" <> Base.encode16(:crypto.strong_rand_bytes(12), case: :lower))
    File.mkdir!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "one owned first transition preserves real histories and reopens both guarded compositions", context do
    fixture = actual_cut(context.root)
    owned = launch(fixture.plan)
    {result, events} = finish(owned)
    assert {:joined, {:ok, %{restore_result: {:committed, receipt}, release_claims: []}}, evidence} = result
    assert receipt["ordinal"] == 1 and receipt["ledger_count"] == 2
    assert evidence.claim_count == 0
    assert evidence.opens == evidence.closes
    assert evidence.restore == %{phase: "claim_release", intent: true}
    assert evidence.work_cutoff == owned.work_cutoff
    [{:stopping, :complete, stop, cutoff}] = for {:stopping, :complete, _, _} = event <- events, do: event
    assert cutoff == stop + max(10_000, @grace + 2_000)
    assert evidence.cleanup_cutoff == cutoff
    releases = for {:terminal_release_installed, _} = event <- events, do: event
    assert [{:terminal_release_installed, ^cutoff}] = releases
    phases = for {:issued, _, {:restore_phase, phase}} <- events, do: phase
    assert phases == ~w(claim inventory baseline_copy destination_intent source_retirement destination_generations destination_proofs claim_release)
    exact_joins(owned)

    assert_complete_copy(fixture)
    assert File.read!(Path.join(fixture.backup, "store.log")) == fixture.store_bytes
    assert File.read!(Path.join(fixture.destination, "store.log")) == fixture.store_bytes
    assert File.read!(Path.join(fixture.workspace, "unknown-ready")) == "ready"
    assert {:error, :source_retired} = RestoreGuard.state(fixture.source)
    for declaration <- fixture.plan["ledgers"] do
      root = Path.join(fixture.source, declaration["relative_root"])
      assert {:error, {:ledger_unavailable, :source_retired}} = Ledger.prepare(root, declaration["executor_identity"], @grace)
    end
    assert {:ok, _} = RestoreGuard.state(fixture.destination)
    assert Enum.all?(claims(fixture.plan), &(File.lstat(&1) == {:error, :enoent}))

    # Concept: a new ordinary open keeps settled/unknown truth and never starts
    # a replacement effect. Technical depth: no prompt is submitted, the public
    # history is identical, and the physical unknown marker remains unchanged.
    assert {:ok, runtime} = LoopexComposition.TestHost.start(
      runtime_id: @runtime, state_root: fixture.destination, workspace: fixture.workspace,
      model: "openai:test", policy: Policy, policy_identity: @policy,
      artifact_transfers: true, active_tools: ~w(loopex.read loopex.bash))
    runtime_monitor = Process.monitor(runtime.supervisor)
    assert {:ok, _attachment} = Loopex.attach(runtime, fixture.session, after_event_sequence: 0)
    assert {:ok, status} = Loopex.session_status(runtime, fixture.session)
    assert is_map(status)
    retained = effect_rows(runtime, fixture.session, nil, [])
    assert Enum.count(retained, &(&1.kind == "intent")) == 2
    assert Enum.count(retained, &(&1.kind == "terminal" and &1.disposition == "receipt_committed")) == 2
    reopened_bytes = File.read!(Path.join(fixture.destination, "store.log"))
    assert binary_part(reopened_bytes, 0, byte_size(fixture.store_bytes)) == fixture.store_bytes
    assert File.read!(Path.join(fixture.workspace, "unknown-ready")) == "ready"
    assert :ok = Loopex.stop(runtime)
    assert_receive {:DOWN, ^runtime_monitor, :process, _supervisor, :normal}, 1_000

    before = generation(Path.join(fixture.destination, "resource-packs/receipts/generation"))
    assert before["executor_identity"] == fixture.import_identity
    assert {:ok, imported} = ResourcePacks.add(fixture.workspace, fixture.git_source,
      workspace_ref: fixture.workspace_ref, state_root: fixture.destination,
      path: "second", rev: fixture.commit, git_executable: System.find_executable("git"),
      executor_authorization: {:host_policy, :allow})
    assert imported["name"] == "second"
    assert generation(Path.join(fixture.destination, "resource-packs/receipts/generation")) == before
    assert File.read!(Path.join(fixture.workspace, "unknown-ready")) == "ready"
  end

  for dependency <- [:receipt, :artifact, :resource] do
    test "missing historical #{dependency} refuses before intent with actual writer histories", context do
      fixture = actual_cut(context.root)
      dependency = unquote(dependency)
      path = case dependency do
        :receipt -> fixture.receipt_path
        :artifact -> fixture.object_path
        :resource -> fixture.manifest_path
      end
      File.rm!(Path.join(fixture.source, path))
      File.rm!(Path.join(fixture.backup, path))
      baseline = manifest(fixture.backup)
      plan = refresh_plan(fixture.plan, baseline, fixture.backup)
      owned = launch(plan)
      {result, _events} = finish(owned)
      assert {:joined, {:ok, %{restore_result: {:not_committed, "invalid_current_history"}, release_claims: []}}, evidence} = result
      assert evidence.restore.intent == false and evidence.claim_count == 0
      assert File.ls!(fixture.destination) == []
      assert File.lstat(Path.join(fixture.source, ".loopex-restore")) == {:error, :enoent}
      assert File.lstat(Path.join(fixture.destination, ".loopex-restore")) == {:error, :enoent}
      exact_joins(owned)
    end
  end

  test "ordinary guards refuse malformed higher head and missing imported generation", context do
    fixture = actual_cut(context.root)
    owned = launch(fixture.plan)
    assert {{:joined, {:ok, %{restore_result: {:committed, _}}}, _}, _} = finish(owned)
    exact_joins(owned)
    root = fixture.destination
    generation_path = Path.join(root, "receipts/generation")
    bytes = File.read!(generation_path)
    File.rm!(generation_path)
    assert {:error, :history_invalid} = RestoreGuard.state(root)
    assert {:error, {:ledger_unavailable, :history_invalid}} = Ledger.prepare(Path.join(root, "receipts"), "executor-local", @grace)
    assert File.lstat(generation_path) == {:error, :enoent}
    File.write!(generation_path, bytes)
    File.chmod!(generation_path, 0o600)
    higher = Path.join([root, ".loopex-restore", "lineage", "00000002"])
    File.mkdir!(higher)
    File.chmod!(higher, 0o700)
    File.write!(Path.join(higher, "intent"), "malformed")
    File.chmod!(Path.join(higher, "intent"), 0o600)
    assert {:error, :history_invalid} = RestoreGuard.state(root)
    assert {:error, {:ledger_unavailable, :history_invalid}} = Ledger.prepare(Path.join(root, "receipts"), "executor-local", @grace)
    assert File.lstat(Path.join(root, "receipts/claim")) == {:error, :enoent}
  end

  test "a prepared source cannot reacquire a claim after per-ledger retirement", context do
    fixture = actual_cut(context.root)
    assert {:ok, prepared} = Ledger.prepare(Path.join(fixture.source, "receipts"), "executor-local", @grace)
    owned = launch(fixture.plan)
    assert {{:joined, {:ok, %{restore_result: {:committed, _}}}, _}, _} = finish(owned)
    exact_joins(owned)
    original_deadline = System.monotonic_time(:millisecond) + 1_000
    parent = self()
    assert {:error, {:ledger_unavailable, :source_retired}} = Ledger.with_claim_until(prepared, fn -> send(parent, :authority_entered) end, original_deadline)
    refute_received :authority_entered
    assert File.lstat(Path.join(fixture.source, "receipts/claim")) == {:error, :enoent}
    assert original_deadline > System.monotonic_time(:millisecond)
  end

  defp actual_cut(root) do
    source = Path.join(root, "source")
    backup = Path.join(root, "backup")
    destination = Path.join(root, "destination")
    workspace = Path.join(root, "workspace")
    for path <- [source, destination, workspace], do: File.mkdir!(path)
    {:ok, workspace_ref} = WorkspaceIdentity.reference(workspace)
    bytes = :binary.copy("captured 猫\n", 4_096)
    File.write!(Path.join(workspace, "source.txt"), bytes)
    File.write!(Path.join(source, "orphan"), "unclaimed bytes")
    File.chmod!(Path.join(source, "orphan"), 0o640)
    File.mkdir!(Path.join(source, ".staging"))
    File.write!(Path.join(source, ".staging/preserved"), <<0, 255, 1>>)

    git_source = Path.join(root, "git-source")
    for name <- ["first", "second"] do
      path = Path.join([git_source, name, "SKILL.md"])
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "---\nname: #{name}\ndescription: Inspect retained files.\n---\nUse read.\n")
    end
    git!(git_source, ["init", "--quiet"])
    git!(git_source, ["add", "."])
    git!(git_source, ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "--quiet", "-m", "fixture"])
    commit = git!(git_source, ["rev-parse", "HEAD"]) |> String.trim()
    assert {:ok, imported} = ResourcePacks.add(workspace, git_source,
      workspace_ref: workspace_ref, state_root: source, path: "first", rev: commit,
      git_executable: System.find_executable("git"), executor_authorization: {:host_policy, :allow})
    resource_manifest = %{"version" => "loopex.resource_pack/1", "workspace_ref" => workspace_ref, "revision" => nil, "packs" => [imported]}
    assert {:ok, manifest_digest} = ResourcePacks.retain(resource_manifest, source)
    import_generation = generation(Path.join(source, "resource-packs/receipts/generation"))


    {:ok, store} = Store.start_link(path: Path.join(source, "store.log"))
    {:ok, port} = Loopex.Store.new(Store, store)
    {:ok, transfers} = Transfers.start_link(root: Path.join(source, "artifacts"))
    {:ok, artifacts_handle} = Artifacts.open(Path.join(source, "artifacts"))
    artifacts = %{module: Artifacts, handle: Map.put(artifacts_handle, :transfers, transfers)}
    {:ok, lease} = WorkspaceLease.start_link(id: "workspace", path: workspace, fencing_token: 1)
    {:ok, executor} = Local.start_link(identity: "executor-local", epoch: 1, fencing_token: 1,
      workspace_leases: %{"workspace" => lease}, ledger_root: Path.join(source, "receipts"),
      artifacts: artifacts, cleanup_grace_ms: @grace)
    {:ok, observer} = Agent.start_link(fn -> [] end)
    definitions = Enum.filter(CodingTools.definitions(), &({&1["tool_id"], &1["tool_version"]} in [{"loopex.read", "1.1.0"}, {"loopex.bash", "1.0.0"}]))
    genesis = Loopex.ConfiguredGenesisFixture.genesis(definitions)
    genesis = %{genesis | "runtime_configuration" => %{"cleanup_grace_ms" => @grace}}
    assert {:ok, runtime} = Loopex.start_link(runtime_id: @runtime, store: port,
      resource_manifest: resource_manifest, artifact_store: artifacts, model: %{module: Model, model: "scripted:v1", options: [observer: observer]},
      executor: %{module: Local, reference: executor, identity: "executor-local", epoch: 1,
        fencing_token: 1, workspace_ref: workspace_ref, workspace_lease: "workspace"},
      tools: definitions, active_tools: Enum.map(definitions, & &1["tool_id"]),
      policy: Policy, policy_identity: @policy, grant_decision: {:host_policy, :allow},
      context_token_budget: 8_192)
    actors = [runtime.supervisor, store, transfers, executor, observer]
    monitors = Enum.map(actors, &{&1, Process.monitor(&1)})
    lease_monitor = Process.monitor(lease)
    on_exit(fn ->
      for actor <- [lease | actors] do
        if Process.alive?(actor) do
          monitor = Process.monitor(actor)
          Process.exit(actor, :kill)
          assert_receive {:DOWN, ^monitor, :process, ^actor, _}, 1_000
        end
      end
    end)
    assert {:ok, session} = Loopex.create_session(runtime, %{}, command_id: "create", genesis: genesis)
    assert {:ok, attachment} = Loopex.attach(runtime, session, after_event_sequence: 0)
    prompt(attachment, "read", %{"tool" => "read", "arguments" => %{"path" => "source.txt"}})
    completed = await_settled(attachment, System.monotonic_time(:millisecond) + 5_000, [])
    assert Enum.find(completed, &(&1.kind == "run.finished"))["outcome"] == "completed"
    [reference] = Enum.find(completed, &(&1.kind == "tool.finished"))["artifacts"]
    assert reference["size"] == byte_size(bytes)

    prompt(attachment, "unknown", %{"tool" => "bash", "arguments" => %{"command" => "printf ready > unknown-ready; while :; do sleep 1; done"}})
    cutoff = System.monotonic_time(:millisecond) + 5_000
    await_file(Path.join(workspace, "unknown-ready"), cutoff)
    assert :ok = GenServer.stop(lease, :normal, 1_000)
    assert_receive {:DOWN, ^lease_monitor, :process, ^lease, :normal}, 1_000
    unknown = await_settled(attachment, cutoff, [])
    assert Enum.find(unknown, &(&1.kind == "run.finished"))["outcome"] == "outcome_unknown"
    assert :ok = Loopex.stop(runtime)
    for actor <- [store, transfers, executor, observer], do: assert(:ok == GenServer.stop(actor, :normal, 1_000))
    for {actor, monitor} <- monitors, do: assert_receive({:DOWN, ^monitor, :process, ^actor, :normal}, 1_000)
    store_bytes = File.read!(Path.join(source, "store.log"))
    {:ok, frames, :complete} = Log.decode_bytes(store_bytes)
    {:ok, replayed} = State.replay(frames)
    records = replayed.sessions[session].records
    assert Enum.any?(records, &(&1.payload.kind == "model_request_committed_resources_v2"))
    [receipt_row, unknown_row] = Enum.filter(records, &(&1.payload.kind == "executor_receipt_committed_v2"))
    assert unknown_row.payload["receipt"]["outcome"] == "outcome_unknown"
    assert unknown_row.payload["receipt"]["cleanup_confirmation"] == "confirmed"
    receipt_path = Path.join("receipts", hash(receipt_row.payload["receipt"]["job_id"]) <> ".receipt")

    assert {:ok, placement} = Placement.acquire(source)
    assert {:ok, object_owner} = RetainedObjects.open(source, @runtime, placement)
    object_monitor = Process.monitor(object_owner)
    {:ok, object} = GenesisCodec.encode(genesis)
    {:ok, encoded} = Frame.encode(object)
    object_bytes = encoded |> IO.iodata_to_binary() |> String.trim_trailing("\n")
    assert {:ok, _digest} = RetainedObjects.install(object_owner, object_bytes)
    assert :ok = GenServer.stop(object_owner, :normal, 1_000)
    assert_receive {:DOWN, ^object_monitor, :process, ^object_owner, :normal}, 1_000
    assert :ok = Placement.release(placement)

    assert {:ok, _} = File.cp_r(source, backup)
    assert manifest(source) == manifest(backup)
    baseline = manifest(backup)
    {:ok, lineage} = RestoreCodec.lineage_digest([])
    plan = %{"version" => 1, "tx_id" => hash("first-restore"), "source_state_root" => source,
      "source_state_placement" => placement(source), "source_status" => "available",
      "backup_state_root" => backup, "destination_state_root" => destination,
      "manifest_sha256" => hash(baseline), "cut_id" => hash("joined-current-cut"),
      "prior_restore_count" => 0, "prior_lineage_sha256" => lineage,
      "runtime_ids" => [@runtime], "stores" => [], "ledgers" => [],
      "workspace" => %{"root" => workspace, "workspace_ref" => workspace_ref},
      "host_attestation" => %{"latest_cut" => true, "no_post_cut_activity" => true,
        "all_other_copies_excluded" => true, "old_authority_termination" => "joined",
        "host_ledgers_validated" => true, "evidence_sha256" => hash("exact-fixture-joins")}}
    plan = refresh_plan(plan, baseline, backup)
    assert {:ok, _} = RestoreCodec.encode(:plan, plan)
    %{source: source, backup: backup, destination: destination, workspace: workspace,
      workspace_ref: workspace_ref, session: session, baseline: baseline, plan: plan,
      store_bytes: store_bytes, receipt_path: receipt_path,
      object_path: Path.join(["artifacts", "objects", binary_part(reference["locator"], 0, 2), reference["locator"]]),
      manifest_path: Path.join(["resource-packs", "manifests", manifest_digest <> ".etf"]),
      git_source: git_source, commit: commit, import_identity: import_generation["executor_identity"]}
  end

  defp refresh_plan(plan, baseline, backup) do
    store = %{"relative_path" => "store.log", "sha256" => hash(File.read!(Path.join(backup, "store.log")))}
    ledgers = for relative <- ["receipts", "resource-packs/receipts"] do
      bytes = File.read!(Path.join([backup, relative, "generation"]))
      {:ok, generation} = RestoreCodec.decode(:generation, bytes)
      %{"relative_root" => relative, "executor_identity" => generation["executor_identity"],
        "source_generation_sha256" => hash(bytes), "source_placement" => placement(Path.join(plan["source_state_root"], relative))}
    end
    %{plan | "manifest_sha256" => hash(baseline), "stores" => [store], "ledgers" => ledgers}
  end

  defp assert_complete_copy(fixture) do
    {:ok, baseline} = RestoreCodec.manifest(fixture.baseline, @total)
    {:ok, restored} = RestoreCodec.manifest(manifest(fixture.destination), @total)
    index = Map.new(restored, &{&1["path"], &1})
    for entry <- baseline do
      path = entry["path"]
      if path in ["receipts/generation", "resource-packs/receipts/generation"] do
        assert Map.drop(index[path], ["size", "sha256"]) == Map.drop(entry, ["size", "sha256"])
        original = generation(Path.join(fixture.backup, path))
        current = generation(Path.join(fixture.destination, path))
        assert Map.drop(current, ["executor_epoch", "generation_id", "root_binding"]) == Map.drop(original, ["executor_epoch", "generation_id", "root_binding"])
        refute current["executor_epoch"] == original["executor_epoch"]
      else
        assert index[path] == entry
      end
    end
    admin = [".loopex-restore", ".loopex-restore/lineage", ".loopex-restore/lineage/00000001"] ++
      for(relative <- ["receipts", "resource-packs/receipts"], suffix <- ["restore-lineage", "restore-lineage/00000001"], do: Path.join(relative, suffix)) ++
      for(name <- ["baseline", "intent", "source-retirement", "committed"], do: Path.join(".loopex-restore/lineage/00000001", name)) ++
      for(relative <- ["receipts", "resource-packs/receipts"], name <- ["intent", "source-retired", "committed"], do: Path.join([relative, "restore-lineage", "00000001", name]))
    added = Map.keys(index) -- Enum.map(baseline, & &1["path"])
    assert Enum.sort(added) == Enum.sort(admin)
  end

  defp launch(plan) do
    parent = self()
    tag = make_ref()
    invocation = %{"work_ms" => @work, "cleanup_grace_ms" => @grace,
      "max_total_file_bytes" => @total, "prior_admin_authority" => "none", "prior_admin_evidence_sha256" => nil}
    {caller, caller_monitor} = spawn_monitor(fn -> send(parent, {tag, Restore.available_first(plan, invocation, probe: parent, pause_at: :open)}) end)
    assert_receive {:restore_io, guardian, worker, reference, {:installed, admitted, work_cutoff}}, 1_000
    owned = %{caller: caller, caller_monitor: caller_monitor, guardian: guardian,
      guardian_monitor: Process.monitor(guardian), worker: worker, worker_monitor: Process.monitor(worker),
      reference: reference, tag: tag, work_cutoff: work_cutoff}
    assert work_cutoff == admitted + @work
    on_exit(fn ->
      for actor <- [caller, guardian, worker] do
        if Process.alive?(actor) do
          monitor = Process.monitor(actor)
          Process.exit(actor, :kill)
          assert_receive {:DOWN, ^monitor, :process, ^actor, _}, 1_000
        end
      end
    end)
    Process.put({:restore_release_monitors, reference}, [])
    owned
  end

  defp finish(owned, events \\ []) do
    guardian = owned.guardian
    reference = owned.reference
    tag = owned.tag
    receive do
      {:restore_io, ^guardian, worker, ^reference, {:terminal_release_installed, _} = event} ->
        monitors = Process.get({:restore_release_monitors, reference})
        Process.put({:restore_release_monitors, reference}, [{worker, Process.monitor(worker)} | monitors])
        finish(owned, [event | events])
      {:restore_io, ^guardian, _worker, ^reference, {:issued, id, {:open, _}} = event} ->
        send(guardian, {:proceed, reference, id})
        finish(owned, [event | events])
      {:restore_io, ^guardian, _worker, ^reference, event} -> finish(owned, [event | events])
      {^tag, result} -> {result, Enum.reverse(events)}
    after
      max(0, owned.work_cutoff + max(10_000, @grace + 2_000) - System.monotonic_time(:millisecond)) -> flunk("original restore work/cleanup cutoff reached")
    end
  end

  defp exact_joins(owned) do
    actors = [{owned.worker, owned.worker_monitor}, {owned.guardian, owned.guardian_monitor}, {owned.caller, owned.caller_monitor}] ++ Process.delete({:restore_release_monitors, owned.reference})
    for {actor, monitor} <- actors, do: assert_receive({:DOWN, ^monitor, :process, ^actor, :normal}, 1_000)
  end

  defp effect_rows(runtime, session, cursor, rows) do
    assert {:ok, page} = Loopex.Runtime.effect_intents(runtime, session, cursor, 16)
    rows = rows ++ page.rows
    if page.next_cursor, do: effect_rows(runtime, session, page.next_cursor, rows), else: rows
  end

  defp manifest(root) do
    assert {:joined, {:ok, bytes}, _} = RestoreIO.run({:manifest, root, @total}, %{"work_ms" => @work, "cleanup_grace_ms" => @grace})
    bytes
  end
  defp prompt(attachment, id, selected) do
    {:ok, bytes} = Frame.encode(selected)
    assert {:accepted, ^id} = Loopex.command(attachment, %{type: :prompt, command_id: id, content: bytes |> IO.iodata_to_binary() |> String.trim_trailing("\n")})
  end
  defp await_settled(attachment, cutoff, events) do
    assert System.monotonic_time(:millisecond) < cutoff
    case Loopex.next_event(attachment) do
      {:ok, %{kind: "session.settled"} = event} -> Enum.reverse([event | events])
      {:ok, event} -> await_settled(attachment, cutoff, [event | events])
      {:error, :empty} ->
        receive do
        after
          1 -> await_settled(attachment, cutoff, events)
        end
    end
  end
  defp await_file(path, cutoff) do
    assert System.monotonic_time(:millisecond) < cutoff
    case File.read(path) do
      {:ok, "ready"} -> :ok
      _ ->
        receive do
        after
          1 -> await_file(path, cutoff)
        end
    end
  end
  defp generation(path) do
    assert {:ok, generation} = RestoreCodec.decode(:generation, File.read!(path))
    generation
  end
  defp placement(path) do
    stat = File.lstat!(path)
    %{"expanded_root" => path, "major_device" => stat.major_device, "inode" => stat.inode}
  end
  defp claims(plan), do: Enum.map([plan["source_state_root"], plan["destination_state_root"]], fn root ->
    {:ok, digest} = RestoreCodec.claim_digest(root)
    Path.join(Path.dirname(root), ".loopex-restore-claim-" <> digest)
  end)
  defp git!(root, args) do
    assert {output, 0} = System.cmd("git", args, cd: root)
    output
  end
  defp hash(bytes), do: Canonical.digest_bytes(bytes)
end
