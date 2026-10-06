defmodule LoopexComposition.RestoreRetainedClaimHandoffTest do
  use ExUnit.Case, async: false

  alias Loopex.Executor.Local.{Ledger, RestoreCodec}
  alias LoopexComposition.{Restore, WorkspaceIdentity}
  alias LoopexComposition.Restore.IO, as: RestoreIO
  alias LoopexComposition.Restore.Workflow

  @limits %{"work_ms" => 10_000, "cleanup_grace_ms" => 1_000}
  @total 16_777_216

  setup do
    {:ok, temp} = WorkspaceIdentity.resolve_path(System.tmp_dir!())
    root = Path.join(temp, "restore-handoff-" <> Base.encode16(:crypto.strong_rand_bytes(12), case: :lower))
    File.mkdir!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  for status <- ~w(available lost), authority <- ~w(joined host_rebooted) do
    test "actual #{status} retained claim handoff admits #{authority} without publishing state", %{root: root} do
      cut = prepare(root, unquote(status))
      prior = strand(cut, "source_retirement")
      before = state_image(cut)
      original = File.read!(intent_path(cut))
      claims = claims_before(cut)
      {result, events} = handoff(cut, invocation(unquote(authority), prior))
      assert {:joined, {:ok, %{claims: acquired, intent: ^original}}, evidence} = result
      assert evidence.opens == evidence.closes and evidence.claim_count == length(claims)
      assert evidence.restore_observation["claim"] == "retained"
      assert evidence.restore_observation["intent"] == "validated"
      assert state_image(cut) == before
      assert_nonce_only(acquired, claims)
      assert_no_release_or_publication(events)
      assert acquisition_after_native_proof(events, length(claims))
      capture_ids = for {:acknowledged, id, :restore_pending_decode, :completed} <- events, do: id
      first_handoff = Enum.find_value(events, fn
        {:issued, id, {:restore_claim_handoff, _}} -> id
        _ -> nil
      end)
      assert length(capture_ids) == 2 * length(claims)
      assert Enum.all?(capture_ids, &(&1 < first_handoff))
      assert {:pending, _} = Restore.lookup(cut.destination, cut.plan["tx_id"], @limits)
      if unquote(status) == "lost", do: assert(File.lstat(cut.source) == {:error, :enoent})
    end
  end

  test "installed original candidates retain their exact bytes while only the claim nonce changes", %{root: root} do
    cut = prepare(root, "available")
    prior = strand(cut, "destination_proofs")
    original = File.read!(intent_path(cut))
    assert {:ok, intent} = RestoreCodec.decode(:intent, original)
    assert File.read!(Path.join(cut.destination, "receipts/generation")) ==
             hd(intent["generations"])["destination_generation_bytes"]
    before = state_image(cut)
    claims = claims_before(cut)
    assert {{:joined, {:ok, %{claims: acquired, intent: ^original}}, _}, events} =
             handoff(cut, invocation("joined", prior))
    assert_nonce_only(acquired, claims)
    assert state_image(cut) == before
    assert_no_release_or_publication(events)
  end

  test "all participating claims are validated before the first nonce publication", %{root: root} do
    cut = prepare(root, "available")
    prior = strand(cut, "source_retirement")
    path = Path.join(claim_path(cut.source), "owner")
    change_owner(path, "plan_digest", hash("foreign-source-plan"))
    before = image(root)
    assert {{:joined, {:error, "restore_conflict"}, _}, events} = handoff(cut, invocation("joined", prior))
    assert image(root) == before
    refute Enum.any?(events, &match?({:issued, _, {:restore_claim_handoff, _}}, &1))
    assert_no_mutation(events)
  end

  test "a real partial two-root handoff preserves mixed old nonces for a later joined invocation", %{root: root} do
    cut = prepare(root, "available")
    prior = strand(cut, "source_retirement")
    original = File.read!(intent_path(cut))
    before = state_image(cut)
    owned = launch({:restore_retained_claim_handoff, cut.plan, invocation("joined", prior)}, :restore_claim_handoff)

    try do
      {_id, _events} = hold_kind(owned, :restore_claim_handoff, 2)
      Process.exit(owned.caller, :kill)
      terminal = receive_terminal(owned)
      assert {:joined, {:error, :caller_lost}, evidence} = terminal
      assert evidence.opens == evidence.closes and evidence.claim_count == 2
      assert evidence.restore_observation["claim"] == "retained"
      join(owned, [:killed, :normal, :normal])
      next_prior = prior_evidence(cut, owned, evidence)
      mixed = claims_before(cut)
      assert mixed |> Enum.map(& &1.owner["claim_nonce"]) |> Enum.uniq() |> length() == 2
      assert {{:joined, {:ok, %{claims: acquired, intent: ^original}}, _}, events} =
               handoff(cut, invocation("joined", next_prior))
      assert_nonce_only(acquired, mixed)
      assert state_image(cut) == before
      assert_no_release_or_publication(events)
    after
      cleanup(owned)
    end
  end

  test "a real second-claim conflict retains the already acknowledged first nonce", %{root: root} do
    cut = prepare(root, "available")
    prior = strand(cut, "source_retirement")
    before = claims_before(cut)
    original = File.read!(intent_path(cut))
    owned = launch({:restore_retained_claim_handoff, cut.plan, invocation("joined", prior)}, :restore_claim_handoff)

    try do
      {id, events} = hold_kind(owned, :restore_claim_handoff, 2)
      path = Path.join(claim_path(cut.source), "owner")
      change_owner(path, "plan_digest", hash("changed-after-first-handoff"))
      send(owned.guardian, {:proceed, owned.reference, id})
      assert {{:joined, {:error, "inventory_unavailable"}, evidence}, complete} = collect(owned, events)
      assert evidence.opens == evidence.closes and evidence.claim_count == 2
      assert evidence.restore_observation["claim"] == "retained"
      assert File.read!(intent_path(cut)) == original
      destination = hd(before)
      assert destination.directory == claim_path(cut.destination)
      assert File.read!(Path.join(destination.directory, "owner")) != destination.bytes
      assert File.lstat!(destination.directory).inode == destination.inode
      assert mode(destination.directory) == 0o700
      assert_no_release_or_publication(complete)
      join(owned, [:normal, :normal, :normal])
    after
      cleanup(owned)
    end
  end

  test "none or missing prior evidence refuses before installing a new owner", %{root: root} do
    cut = prepare(root, "available")
    _prior = strand(cut, "source_retirement")
    before = image(root)

    for invoke <- [invocation(), invocation("joined", nil)] do
      assert RestoreIO.run({:restore_retained_claim_handoff, cut.plan, invoke}, @limits, probe: self()) ==
               {:error, :invalid_io_request}
      refute_receive {:restore_io, _, _, _, {:installed, _, _}}, 100
      assert image(root) == before
    end
  end

  test "malformed Workflow invocation refuses before its actual IO callback is entered", %{root: root} do
    cut = prepare(root, "available")
    prior = strand(cut, "source_retirement")
    before = image(root)
    invoke = invocation("joined", prior)
    caller = self()

    io = fn operation ->
      send(caller, {:handoff_callback_entered, operation})
      RestoreIO.run(operation, @limits, probe: caller)
    end

    for {plan, invocation} <- [
          {Map.put(cut.plan, "destination_state_root", "relative-root"), invoke},
          {cut.plan, Map.put(invoke, "work_ms", 0)}
        ] do
      assert Workflow.retained_claim_handoff(plan, invocation, io) == {:error, "invalid_plan"}
      refute_receive {:handoff_callback_entered, _}, 100
      refute_receive {:restore_io, _, _, _, {:installed, _, _}}, 100
      assert image(root) == before
    end
  end

  test "complete pre-intent staging cannot invent candidates while reclaiming an owner", %{root: root} do
    cut = prepare(root, "available")
    prior = strand(cut, "destination_intent")
    before = image(root)
    assert {{:joined, {:error, "invalid_current_history"}, _}, events} =
             handoff(cut, invocation("joined", prior))
    assert image(root) == before
    assert_no_mutation(events)
  end

  for field <- ~w(tx_id plan_digest state_root role) do
    test "retained owner with foreign #{field} remains fenced without nonce replacement", %{root: root} do
      cut = prepare(root, "available")
      prior = strand(cut, "source_retirement")
      path = Path.join(claim_path(cut.destination), "owner")
      value = case unquote(field) do
        "state_root" -> cut.source
        "role" -> "source"
        _ -> hash("foreign-original-owner")
      end
      change_owner(path, unquote(field), value)
      before = image(root)
      assert {{:joined, {:error, "restore_conflict"}, _}, events} = handoff(cut, invocation("joined", prior))
      assert image(root) == before
      assert_no_mutation(events)
    end
  end

  test "a matching owner under a foreign claim directory digest is not acquired", %{root: root} do
    cut = prepare(root, "available")
    prior = strand(cut, "source_retirement")
    path = claim_path(cut.destination)
    File.rename!(path, path <> "-foreign")
    before = image(root)
    assert {{:joined, {:error, "restore_conflict"}, _}, events} = handoff(cut, invocation("joined", prior))
    assert image(root) == before
    assert_no_mutation(events)
  end

  for fault <- [:ownerless, :symlink, :hardlink, :fifo, :mode, :oversized, :noncanonical, :owner_tmp, :directory_mode] do
    test "actual #{fault} claim namespace remains stranded and is never repaired", %{root: root} do
      cut = prepare(root, "available")
      prior = strand(cut, "source_retirement")
      directory = claim_path(cut.destination)
      path = Path.join(directory, "owner")
      original = File.read!(path)

      case unquote(fault) do
        :ownerless -> File.rm!(path)
        :symlink ->
          File.rename!(path, Path.join(root, "outside-owner"))
          File.ln_s!(Path.join(root, "outside-owner"), path)
        :hardlink -> File.ln!(path, Path.join(root, "outside-owner"))
        :fifo ->
          File.rm!(path)
          assert {_, 0} = System.cmd("mkfifo", [path])
        :mode -> File.chmod!(path, 0o640)
        :oversized -> File.write!(path, :binary.copy("x", 2049))
        :noncanonical -> File.write!(path, original <> <<0>>)
        :owner_tmp ->
          File.write!(path <> ".tmp", original)
          File.chmod!(path <> ".tmp", 0o600)
        :directory_mode -> File.chmod!(directory, 0o750)
      end

      before = image(root)
      expected =
        if unquote(fault) in [:symlink, :hardlink, :fifo, :mode],
          do: "invalid_current_history",
          else: if(unquote(fault) == :oversized, do: "inventory_limit_exceeded", else: "restore_conflict")

      assert {{:joined, {:error, ^expected}, evidence}, events} = handoff(cut, invocation("joined", prior))
      assert evidence.opens == evidence.closes
      assert image(root) == before
      assert_no_mutation(events)

      if unquote(fault) in [:ownerless, :symlink, :hardlink, :fifo, :mode, :oversized, :owner_tmp, :directory_mode] do
        boundary = if unquote(fault) == :directory_mode, do: :lookup_claim_stat, else: :lookup_claim_names
        tail = events |> Enum.reverse() |> Enum.take_while(&(not match?({:issued, _, ^boundary}, &1)))
        refute Enum.any?(tail, &match?({:issued, _, {:open, _}}, &1))
      end

    end
  end

  for fault <- [:owner, :directory, :ancestor] do
    test "real #{fault} replacement after capture refuses the checked handoff", %{root: root} do
      cut = prepare(root, "available")
      prior = strand(cut, "source_retirement")
      directory = claim_path(cut.destination)
      original = File.read!(Path.join(directory, "owner"))
      owned = launch({:restore_retained_claim_handoff, cut.plan, invocation("joined", prior)}, :restore_claim_handoff)

      try do
        {id, events} = hold_kind(owned, :restore_claim_handoff)

        case unquote(fault) do
          :owner ->
            path = Path.join(directory, "owner")
            File.rename!(path, Path.join(root, "saved-owner"))
            File.write!(path, original)
            File.chmod!(path, 0o600)
          :directory ->
            File.rename!(directory, directory <> "-saved")
            File.mkdir!(directory)
            File.chmod!(directory, 0o700)
            File.write!(Path.join(directory, "owner"), original)
            File.chmod!(Path.join(directory, "owner"), 0o600)
          :ancestor ->
            File.rename!(root, root <> "-saved")
            File.mkdir!(root)
            on_exit(fn -> File.rm_rf!(root <> "-saved") end)
        end

        before = image(root)
        send(owned.guardian, {:proceed, owned.reference, id})
        assert {{:joined, {:error, "inventory_unavailable"}, evidence}, complete} = collect(owned, events)
        assert evidence.opens == evidence.closes
        assert image(root) == before
        assert_no_mutation(complete)
        join(owned, [:normal, :normal, :normal])
      after
        cleanup(owned)
      end
    end
  end

  test "same-byte owner replacement at the publication stat cannot replace captured custody", %{root: root} do
    cut = prepare(root, "available")
    prior = strand(cut, "source_retirement")
    directory = claim_path(cut.destination)
    path = Path.join(directory, "owner")
    original = File.read!(path)
    owned = launch({:restore_retained_claim_handoff, cut.plan, invocation("joined", prior)}, :retained_publication_stat)

    try do
      {id, events} = hold_kind(owned, :retained_publication_stat, 2)
      File.rename!(path, Path.join(root, "saved-owner"))
      File.write!(path, original)
      File.chmod!(path, 0o600)
      before = image(root)
      send(owned.guardian, {:proceed, owned.reference, id})
      assert {{:joined, {:error, "inventory_unavailable"}, evidence}, complete} = collect(owned, events)
      assert evidence.opens == evidence.closes
      assert image(root) == before
      assert_no_mutation(complete)
      join(owned, [:normal, :normal, :normal])
    after
      cleanup(owned)
    end
  end

  for cut_at <- [:file_sync, :rename, :directory_sync, :restore_claim_acquired] do
    test "caller loss at actual #{cut_at} retains the original claim directory and no receipt", %{root: root} do
      cut = prepare(root, "available")
      prior = strand(cut, "source_retirement")
      before = state_image(cut)
      directory = claim_path(cut.destination)
      inode = File.lstat!(directory).inode
      owned = launch({:restore_retained_claim_handoff, cut.plan, invocation("joined", prior)}, unquote(cut_at))

      try do
        {_id, events} = hold_kind(owned, unquote(cut_at))
        Process.exit(owned.caller, :kill)
        terminal = receive_terminal(owned)
        assert {:joined, {:error, :caller_lost}, evidence} = terminal
        assert evidence.opens == evidence.closes and evidence.claim_count == 1
        assert evidence.restore_observation["claim"] == "retained"
        assert File.lstat!(directory).inode == inode and mode(directory) == 0o700
        assert mode(Path.join(directory, "owner")) == 0o600
        assert state_image(cut) == before
        refute Enum.any?(events, &match?({:acknowledged, _, {:restore_claim_acquired, _}, :completed}, &1))
        join(owned, [:killed, :normal, :normal])
        if File.exists?(Path.join(directory, "owner.tmp")) do
          assert {:error, %{"code" => "restore_conflict"}} = Restore.lookup(cut.destination, cut.plan["tx_id"], @limits)
        else
          assert {:pending, _} = Restore.lookup(cut.destination, cut.plan["tx_id"], @limits)
        end
      after
        cleanup(owned)
      end
    end
  end

  test "guardian loss with an actual owner-temp descriptor retains uncertainty and the fence", %{root: root} do
    cut = prepare(root, "available")
    prior = strand(cut, "source_retirement")
    directory = claim_path(cut.destination)
    original = File.read!(Path.join(directory, "owner"))
    inode = File.lstat!(directory).inode
    owned = launch({:restore_retained_claim_handoff, cut.plan, invocation("joined", prior)}, :file_sync)

    try do
      {_id, _events} = hold_kind(owned, :file_sync)
      assert File.lstat!(Path.join(directory, "owner.tmp")).type == :regular
      Process.exit(owned.guardian, :kill)
      assert {{:unconfirmed, :guardian_lost, %{restore_observation: observation}}, _} = collect(owned, [])
      assert observation["cleanup"] == "unconfirmed" and observation["claim"] == "retained"
      join(owned, [:normal, :killed, :killed])
      assert File.lstat!(directory).inode == inode and mode(directory) == 0o700
      assert File.read!(Path.join(directory, "owner")) == original
      assert File.lstat!(Path.join(directory, "owner.tmp")).type == :regular
    after
      cleanup(owned)
    end
  end

  # Concept: prior authority is evidenced by real original actor and descriptor joins.
  # Technical depth: native first-restore creates the retained claims/candidates;
  # only its exact terminal and three original DOWNs enter the host evidence hash.
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
      prior_evidence(cut, owned, evidence)
    after
      cleanup(owned)
    end
  end

  defp prior_evidence(cut, owned, evidence) do
    owners = Enum.map(claims_before(cut), & &1.bytes)
    hash(:erlang.term_to_binary({owners, evidence.opens, evidence.closes,
      Enum.map(actors(owned), fn {_actor, monitor} ->
        reason = Process.get({:handoff_down, monitor})
        assert not is_nil(reason)
        reason
      end)}, [:deterministic]))
  end

  defp handoff(cut, invoke) do
    owned = launch({:restore_retained_claim_handoff, cut.plan, invoke}, :restore_claim_handoff)

    try do
      {result, events} = collect(owned, [])
      join(owned, [:normal, :normal, :normal])
      {result, events}
    after
      cleanup(owned)
    end
  end

  defp claims_before(cut) do
    roots = if cut.plan["source_status"] == "available", do: [cut.source, cut.destination], else: [cut.destination]

    Enum.map(Enum.sort(roots), fn root ->
      directory = claim_path(root)
      path = Path.join(directory, "owner")
      bytes = File.read!(path)
      assert {:ok, owner} = RestoreCodec.decode(:claim, bytes)
      %{directory: directory, inode: File.lstat!(directory).inode, owner_inode: File.lstat!(path).inode, owner: owner, bytes: bytes}
    end)
  end

  defp assert_nonce_only(acquired, before) do
    assert Enum.map(acquired, & &1.directory) == Enum.map(before, & &1.directory)
    nonces = Enum.map(acquired, fn claim ->
      previous = Enum.find(before, &(&1.directory == claim.directory))
      path = Path.join(claim.directory, "owner")
      assert {:ok, owner} = RestoreCodec.decode(:claim, File.read!(path))
      assert Map.delete(owner, "claim_nonce") == Map.delete(previous.owner, "claim_nonce")
      assert owner["claim_nonce"] != previous.owner["claim_nonce"]
      assert File.read!(path) == claim.owner
      assert File.lstat!(claim.directory).inode == previous.inode and mode(claim.directory) == 0o700
      assert mode(path) == 0o600 and File.lstat!(path).links == 1
      assert File.lstat!(path).inode != previous.owner_inode
      assert File.ls!(claim.directory) == ["owner"]
      owner["claim_nonce"]
    end)
    assert length(Enum.uniq(nonces)) == 1
  end

  defp assert_no_mutation(events) do
    refute Enum.any?(events, fn
      {:issued, _, kind} -> (if is_tuple(kind), do: elem(kind, 0), else: kind) in [:write, :rename, :mode, :delete, :claim_delete, :claim_directory_delete, :restore_claim_create]
      _ -> false
    end)
  end

  defp assert_no_release_or_publication(events) do
    refute Enum.any?(events, fn
      {:issued, _, kind} -> (if is_tuple(kind), do: elem(kind, 0), else: kind) in [:claim_delete, :claim_directory_delete, :restore_claim_create, :restore_claim_released, :intent_may_persist]
      {:terminal_release_installed, _} -> true
      _ -> false
    end)
  end

  defp acquisition_after_native_proof(events, count) do
    acquired = for {:issued, id, {:restore_claim_acquired, _}} <- events, do: id
    renamed = for {:acknowledged, id, :rename, :completed} <- events, do: id
    synced = for {:acknowledged, id, :directory_sync, :completed} <- events, do: id
    assert length(acquired) == count and length(renamed) == count and length(synced) == count
    Enum.zip([acquired, renamed, synced]) |> Enum.each(fn {ack, rename, sync} ->
      assert rename < sync and sync < ack
      assert Enum.any?(events, fn
        {:acknowledged, id, {:close, _}, :closed} -> id > sync and id < ack
        _ -> false
      end)
    end)
  end

  defp change_owner(path, field, value) do
    assert {:ok, owner} = RestoreCodec.decode(:claim, File.read!(path))
    assert {:ok, bytes} = RestoreCodec.encode(:claim, Map.put(owner, field, value))
    File.write!(path, bytes)
  end

  defp state_image(cut) do
    [cut.source, cut.destination, cut.plan["backup_state_root"]]
    |> Enum.map(fn path -> {path, if(File.exists?(path), do: image(path), else: :absent)} end)
  end

  defp image(root), do: image(root, ".")
  defp image(root, relative) do
    path = if relative == ".", do: root, else: Path.join(root, relative)
    info = File.lstat!(path)
    own = {relative, info.type, Bitwise.band(info.mode, 0o7777), info.size, info.links, info.inode,
      if(info.type == :regular, do: File.read!(path), else: nil)}
    if info.type == :directory,
      do: [own | Enum.flat_map(Enum.sort(File.ls!(path)), &image(root, if(relative == ".", do: &1, else: Path.join(relative, &1))))],
      else: [own]
  end

  defp mode(path), do: Bitwise.band(File.lstat!(path).mode, 0o7777)

  defp prepare(root, status) do
    source = Path.join(root, "source")
    backup = Path.join(root, "backup")
    destination = Path.join(root, "destination")
    workspace = Path.join(root, "workspace")
    for path <- [source, destination, workspace], do: File.mkdir!(path)
    assert {:ok, _} = Ledger.prepare(Path.join(source, "receipts"), "handoff-local", 1_000)
    File.write!(Path.join(source, "ordinary"), "unchanged current bytes")
    assert {:ok, _} = File.cp_r(source, backup)
    baseline = manifest(backup)
    generation = File.read!(Path.join(source, "receipts/generation"))
    assert {:ok, workspace_ref} = WorkspaceIdentity.reference(workspace)
    {:ok, entries} = RestoreCodec.manifest(baseline, @total)

    {:ok, lineage} =
      RestoreCodec.lineage_digest(
        Enum.filter(entries, fn entry ->
          Enum.any?(Path.split(entry["path"]), &(&1 in [".loopex-restore", "restore-lineage"]))
        end)
      )

    plan = %{
      "version" => 1,
      "tx_id" => hash("handoff-original-tx"),
      "source_state_root" => source,
      "source_state_placement" => placement(source),
      "source_status" => status,
      "backup_state_root" => backup,
      "destination_state_root" => destination,
      "manifest_sha256" => hash(baseline),
      "cut_id" => hash("handoff-cut"),
      "prior_restore_count" => 0,
      "prior_lineage_sha256" => lineage,
      "runtime_ids" => [],
      "stores" => [],
      "ledgers" => [
        %{
          "relative_root" => "receipts",
          "executor_identity" => "handoff-local",
          "source_generation_sha256" => hash(generation),
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
        "evidence_sha256" => hash("quiescent-native-writer")
      }
    }

    if status == "lost", do: File.rm_rf!(source)
    %{plan: plan, source: source, destination: destination, baseline: baseline}
  end

  defp invocation(authority \\ "none", evidence \\ nil),
    do:
      Map.merge(
        @limits,
        %{
          "max_total_file_bytes" => @total,
          "prior_admin_authority" => authority,
          "prior_admin_evidence_sha256" => evidence
        }
      )

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

    {caller, monitor} =
      spawn_monitor(fn ->
        send(
          parent,
          {:result, self(), RestoreIO.run(operation, @limits, probe: parent, pause_at: pause)}
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
          cutoff: cutoff + 10_000,
          pause: pause
        }
    after
      10_000 -> flunk("original handoff actors unavailable")
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
      {:restore_io, guardian, worker, reference, {:issued, id, kind} = event}
      when guardian == owned.guardian and worker == owned.worker and reference == owned.reference ->
        name = if is_tuple(kind), do: elem(kind, 0), else: kind
        if name == owned.pause, do: send(guardian, {:proceed, reference, id})
        collect(owned, [event | events])

      {:restore_io, guardian, worker, reference, event}
      when guardian == owned.guardian and worker == owned.worker and reference == owned.reference ->
        collect(owned, [event | events])

      {:result, caller, result} when caller == owned.caller ->
        {result, Enum.reverse(events)}
    after
      left(owned.cutoff) -> flunk("original handoff result unavailable")
    end
  end

  defp hold_kind(owned, wanted, ordinal \\ 1, events \\ []) do
    receive do
      {:restore_io, guardian, worker, reference, {:issued, id, kind} = event}
      when guardian == owned.guardian and worker == owned.worker and reference == owned.reference ->
        name = if is_tuple(kind), do: elem(kind, 0), else: kind

        cond do
          name == wanted and ordinal == 1 -> {id, [event | events]}
          name == wanted ->
            send(guardian, {:proceed, reference, id})
            hold_kind(owned, wanted, ordinal - 1, [event | events])
          true -> hold_kind(owned, wanted, ordinal, [event | events])
        end

      {:restore_io, guardian, worker, reference, event}
      when guardian == owned.guardian and worker == owned.worker and reference == owned.reference ->
        hold_kind(owned, wanted, ordinal, [event | events])
    after
      left(owned.cutoff) -> flunk("original native handoff cut unavailable")
    end
  end

  defp receive_terminal(owned) do
    receive do
      {:restore_io, guardian, worker, reference, {:terminal, result}}
      when guardian == owned.guardian and worker == owned.worker and reference == owned.reference ->
        result

      {:restore_io, guardian, worker, reference, _event}
      when guardian == owned.guardian and worker == owned.worker and reference == owned.reference ->
        receive_terminal(owned)
    after
      left(owned.cutoff) -> flunk("original stopped-owner terminal unavailable")
    end
  end

  defp actors(owned),
    do: [
      {owned.caller, owned.caller_monitor},
      {owned.guardian, owned.guardian_monitor},
      {owned.worker, owned.worker_monitor}
    ]

  defp join(owned, reasons) do
    Enum.zip(actors(owned), reasons)
    |> Enum.each(fn {{actor, monitor}, reason} ->
      receive do
        {:DOWN, ^monitor, :process, ^actor, actual} ->
          Process.put({:handoff_down, monitor}, actual)
          assert actual == reason
      after
        left(owned.cutoff) -> flunk("exact original actor join unavailable")
      end
    end)
  end

  defp cleanup(owned) do
    Enum.each(actors(owned), fn {actor, monitor} ->
      if is_nil(Process.get({:handoff_down, monitor})) do
        Process.exit(actor, :kill)

        receive do
          {:DOWN, ^monitor, :process, ^actor, reason} ->
            Process.put({:handoff_down, monitor}, reason)
        after
          left(owned.cutoff) -> flunk("failure cleanup did not join original actor")
        end
      end
    end)
  end
end
