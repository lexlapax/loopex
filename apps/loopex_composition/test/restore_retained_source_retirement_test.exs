defmodule LoopexComposition.RestoreRetainedSourceRetirementTest do
  use ExUnit.Case, async: false

  alias Loopex.Executor.Local.{Ledger, RestoreCodec, RestoreGuard}
  alias LoopexComposition.{Restore, WorkspaceIdentity}
  alias LoopexComposition.Restore.IO, as: RestoreIO

  @limits %{"work_ms" => 10_000, "cleanup_grace_ms" => 1_000}
  @total 16_777_216

  setup do
    {:ok, temp} = WorkspaceIdentity.resolve_path(System.tmp_dir!())

    root =
      Path.join(
        temp,
        "restore-retirement-" <> Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)
      )

    File.mkdir!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  for status <- ~w(available lost), authority <- ~w(joined host_rebooted) do
    test "actual #{status} original transaction retires with #{authority} while keeping all claims",
         %{root: root} do
      cut = prepare(root, unquote(status))
      prior = strand(cut, "source_retirement")
      original = File.read!(intent_path(cut))
      before = original_payload(cut)
      {result, events, _prior} = retirement(cut, invocation(unquote(authority), prior))

      assert {:joined, {:ok, %{claims: claims, intent: ^original, source_retirement: proof}},
              evidence} = result

      assert evidence.opens == evidence.closes
      assert evidence.claim_count == if(unquote(status) == "available", do: 2, else: 1)
      assert evidence.restore_observation["claim"] == "retained"
      assert evidence.restore_observation["intent"] == "validated"
      assert evidence.restore_observation["phase"] == "source_retirement"
      assert original_payload(cut) == before
      assert Enum.all?(claims, &(File.read!(Path.join(&1.directory, "owner")) == &1.owner))
      assert_retirement(cut, original, proof)
      assert_no_activation_or_release(cut, events)
      assert {:pending, _} = Restore.lookup(cut.destination, cut.plan["tx_id"], @limits)
      assert {:error, :restore_incomplete} = RestoreGuard.state(cut.destination)

      assert {:error, {:ledger_unavailable, :restore_incomplete}} =
               RestoreGuard.ledger(Path.join(cut.destination, "receipts"))

      if unquote(status) == "available" do
        assert {:error, :restore_incomplete} = RestoreGuard.state(cut.source)
        assert source_proof_before_destination_copy(events)
      else
        assert File.lstat(cut.source) == {:error, :enoent}
        refute File.exists?(claim_path(cut.source))
      end
    end
  end

  test "an equal fully retired cut re-syncs the same native records without replacing their inodes",
       %{root: root} do
    cut = prepare(root, "available")
    prior = strand(cut, "source_retirement")

    {{:joined, {:ok, %{intent: original, source_retirement: proof}}, _}, _, next_prior} =
      retirement(cut, invocation("joined", prior))

    before = state_image(cut)

    {{:joined, {:ok, %{intent: ^original, source_retirement: ^proof}}, evidence}, events, _} =
      retirement(cut, invocation("joined", next_prior))

    assert evidence.opens == evidence.closes and evidence.claim_count == 2
    assert state_image(cut) == before
    # Handoff replaces only two owner files. Every state record is re-synced,
    # not renamed or rewritten; native sync acknowledgements exceed owner syncs.
    assert Enum.count(events, &match?({:acknowledged, _, :rename, :completed}, &1)) == 2
    assert Enum.count(events, &match?({:acknowledged, _, :file_sync, :completed}, &1)) > 4
    assert_retirement(cut, original, proof)
    assert_no_activation_or_release(cut, events)
  end

  for {side, name, occurrence} <- [
        {"source", "intent", 2},
        {"source", "source-retired", 1},
        {"source", "source-retirement", 1},
        {"destination", "source-retired", 1}
      ] do
    test "native caller cut before #{side} #{name} occurrence #{occurrence} resumes original retirement bytes",
         %{root: root} do
      cut = prepare(root, "available")
      prior = strand(cut, "source_retirement")
      original = File.read!(intent_path(cut))
      payload = original_payload(cut)

      owned =
        launch(
          {:restore_retained_source_retirement, cut.plan, invocation("joined", prior)},
          :restore_retirement_step
        )

      try do
        {_id, _events} = hold_step(owned, unquote(side), unquote(name), unquote(occurrence))
        Process.exit(owned.caller, :kill)
        assert {:joined, {:error, :caller_lost}, evidence} = receive_terminal(owned)
        assert evidence.opens == evidence.closes and evidence.claim_count == 2
        join(owned, [:killed, :normal, :normal])
        next_prior = prior_evidence(cut, owned, evidence)

        {{:joined, {:ok, %{intent: ^original, source_retirement: proof}}, final}, events, _} =
          retirement(cut, invocation("joined", next_prior))

        assert final.opens == final.closes and final.claim_count == 2
        assert original_payload(cut) == payload
        assert_retirement(cut, original, proof)
        assert_no_activation_or_release(cut, events)
      after
        cleanup(owned)
      end
    end
  end

  for side <- ~w(source destination) do
    test "changed ordinary #{side} baseline refuses before retained nonce or retirement mutation",
         %{root: root} do
      cut = prepare(root, "available")
      prior = strand(cut, "source_retirement")
      target = if unquote(side) == "source", do: cut.source, else: cut.destination
      path = Path.join(target, "ordinary")
      File.write!(path, String.duplicate("x", byte_size(File.read!(path))))
      before = image(root)

      assert {{:joined, {:error, "inventory_mismatch"}, evidence}, events, _} =
               retirement(cut, invocation("joined", prior))

      assert evidence.opens == evidence.closes
      assert image(root) == before
      refute Enum.any?(events, &match?({:issued, _, {:restore_claim_handoff, _}}, &1))
      assert_no_activation_or_release(cut, events)
    end
  end

  test "foreign owner substitution after handoff remains fenced before the next state publication",
       %{root: root} do
    cut = prepare(root, "available")
    prior = strand(cut, "source_retirement")
    before = state_image(cut)

    owned =
      launch(
        {:restore_retained_source_retirement, cut.plan, invocation("joined", prior)},
        :restore_retirement_step
      )

    try do
      {id, events} = hold_step(owned, "destination", "baseline", 1)

      change_owner(
        Path.join(claim_path(cut.source), "owner"),
        "plan_digest",
        hash("foreign-plan")
      )

      send(owned.guardian, {:proceed, owned.reference, id})

      assert {{:joined, {:error, "inventory_unavailable"}, evidence}, events} =
               collect(owned, events)

      join(owned, [:normal, :normal, :normal])
      assert evidence.opens == evidence.closes and evidence.claim_count == 2
      assert state_image(cut) == before
      assert_no_activation_or_release(cut, events)
    after
      cleanup(owned)
    end
  end

  test "same-byte source ledger replacement after handoff refuses before retirement binds a new inode",
       %{root: root} do
    cut = prepare(root, "available")
    prior = strand(cut, "source_retirement")

    owned =
      launch(
        {:restore_retained_source_retirement, cut.plan, invocation("joined", prior)},
        :restore_retirement_step
      )

    try do
      {id, events} = hold_step(owned, "source", "intent", 1)
      ledger = Path.join(cut.source, "receipts")
      original = File.lstat!(ledger)
      aside = Path.join(root, "original-ledger")
      File.rename!(ledger, aside)
      File.cp_r!(aside, ledger)
      assert File.lstat!(ledger).inode != original.inode

      projection = fn path ->
        Enum.map(image(path), fn {relative, type, mode, size, links, _inode, bytes} ->
          {relative, type, mode, if(type == :regular, do: size, else: nil), links, bytes}
        end)
      end

      assert projection.(ledger) == projection.(aside)
      before = state_image(cut)
      send(owned.guardian, {:proceed, owned.reference, id})
      assert {{:joined, {:error, "source_changed"}, evidence}, events} = collect(owned, events)
      join(owned, [:normal, :normal, :normal])
      assert evidence.opens == evidence.closes and evidence.claim_count == 2
      assert state_image(cut) == before
      refute File.exists?(Path.join(ledger, "restore-lineage/00000001/source-retired"))
      assert File.lstat!(aside).inode == original.inode
      assert_no_activation_or_release(cut, events)
    after
      cleanup(owned)
    end
  end

  test "lost source endpoint replacement after handoff refuses without a fabricated tombstone", %{
    root: root
  } do
    cut = prepare(root, "lost")
    prior = strand(cut, "source_retirement")
    before = image(cut.destination)

    owned =
      launch(
        {:restore_retained_source_retirement, cut.plan, invocation("joined", prior)},
        :restore_retirement_step
      )

    try do
      {id, events} = hold_step(owned, "destination", "baseline", 1)
      File.mkdir!(cut.source)
      send(owned.guardian, {:proceed, owned.reference, id})

      assert {{:joined, {:error, "inventory_unavailable"}, evidence}, events} =
               collect(owned, events)

      join(owned, [:normal, :normal, :normal])
      assert evidence.opens == evidence.closes and evidence.claim_count == 1
      assert image(cut.destination) == before
      assert File.ls!(cut.source) == []
      assert_no_activation_or_release(cut, events)
    after
      cleanup(owned)
    end
  end

  for native <- [:file_sync, :rename, :directory_sync] do
    test "caller loss before real source-retirement #{native} retains claims and no destination retirement proof",
         %{root: root} do
      cut = prepare(root, "available")
      prior = strand(cut, "source_retirement")

      owned =
        launch(
          {:restore_retained_source_retirement, cut.plan, invocation("joined", prior)},
          unquote(native)
        )

      try do
        {_id, _events} =
          hold_native_after_step(owned, "source", "source-retirement", unquote(native))

        Process.exit(owned.caller, :kill)
        assert {:joined, {:error, :caller_lost}, evidence} = receive_terminal(owned)
        join(owned, [:killed, :normal, :normal])
        assert evidence.opens == evidence.closes and evidence.claim_count == 2
        assert evidence.restore_observation["claim"] == "retained"

        refute File.exists?(
                 Path.join(cut.destination, ".loopex-restore/lineage/00000001/source-retirement")
               )

        assert File.exists?(claim_path(cut.source)) and File.exists?(claim_path(cut.destination))

        refute File.exists?(
                 Path.join(cut.destination, ".loopex-restore/lineage/00000001/committed")
               )
      after
        cleanup(owned)
      end
    end
  end

  test "guardian loss with a native source-retirement temp descriptor remains unconfirmed", %{
    root: root
  } do
    cut = prepare(root, "available")
    prior = strand(cut, "source_retirement")

    owned =
      launch(
        {:restore_retained_source_retirement, cut.plan, invocation("joined", prior)},
        :file_sync
      )

    try do
      {_id, _events} = hold_native_after_step(owned, "source", "source-retirement", :file_sync)
      temp = Path.join(cut.source, ".loopex-restore/lineage/00000001/source-retirement.tmp")
      assert File.lstat!(temp).type == :regular
      Process.exit(owned.guardian, :kill)

      assert {{:unconfirmed, :guardian_lost, %{restore_observation: observation}}, _} =
               collect(owned, [])

      join(owned, [:normal, :killed, :killed])
      assert observation["cleanup"] == "unconfirmed" and observation["claim"] == "retained"
      assert File.lstat!(temp).type == :regular
      assert File.exists?(claim_path(cut.source)) and File.exists?(claim_path(cut.destination))

      refute File.exists?(
               Path.join(cut.destination, ".loopex-restore/lineage/00000001/committed")
             )
    after
      cleanup(owned)
    end
  end

  test "already installed candidates are explicitly unfinished before any new nonce or retirement mutation",
       %{root: root} do
    cut = prepare(root, "available")
    prior = strand(cut, "destination_proofs")
    before = image(root)

    attempt = retirement(cut, invocation("joined", prior))
    assert {result, events, _} = attempt
    assert {:joined, outcome, evidence} = result
    assert {:development_incomplete, {:retained_retirement_cut, phase}} = outcome
    assert phase == "destination_proofs"

    assert evidence.opens == evidence.closes
    assert image(root) == before
    refute Enum.any?(events, &match?({:issued, _, {:restore_claim_handoff, _}}, &1))
  end

  test "changed actual source intent conflicts without inventing replacement candidate bytes", %{
    root: root
  } do
    cut = prepare(root, "available")
    prior = strand(cut, "destination_generations")
    path = Path.join(cut.source, ".loopex-restore/lineage/00000001/intent")
    assert {:ok, intent} = RestoreCodec.decode(:intent, File.read!(path))
    hostile_plan = Map.put(intent["plan"], "tx_id", hash("different-tx"))
    assert {:ok, hostile_digest} = RestoreCodec.plan_digest(hostile_plan)

    hostile_intent = %{
      intent
      | "plan" => hostile_plan,
        "tx_id" => hostile_plan["tx_id"],
        "plan_digest" => hostile_digest
    }

    assert {:ok, hostile} = RestoreCodec.encode(:intent, hostile_intent)
    File.write!(path, hostile)
    before = image(root)

    assert {{:joined, {:error, _}, evidence}, events, _} =
             retirement(cut, invocation("joined", prior))

    assert evidence.opens == evidence.closes and image(root) == before
    refute Enum.any?(events, &match?({:issued, _, {:restore_claim_handoff, _}}, &1))
  end

  defp retirement(cut, invoke) do
    owned =
      launch({:restore_retained_source_retirement, cut.plan, invoke}, :restore_retirement_step)

    try do
      {result, events} = collect(owned, [])
      join(owned, [:normal, :normal, :normal])

      evidence =
        case result do
          {:joined, _, evidence} -> evidence
          _ -> nil
        end

      prior = if evidence, do: prior_evidence(cut, owned, evidence), else: nil
      {result, events, prior}
    after
      cleanup(owned)
    end
  end

  defp assert_retirement(cut, original, proof) do
    {:ok, intent} = RestoreCodec.decode(:intent, original)
    {:ok, retirement} = RestoreCodec.decode(:source_retirement, proof)
    assert retirement["tx_id"] == cut.plan["tx_id"]
    assert retirement["intent_sha256"] == hash(original)
    assert retirement["source_state_binding"] == intent["source_state_binding"]
    assert retirement["destination_state_binding"] == intent["destination_state_binding"]
    assert retirement["host_evidence_sha256"] == cut.plan["host_attestation"]["evidence_sha256"]
    assert File.read!(intent_path(cut)) == original

    assert File.read!(
             Path.join(cut.destination, ".loopex-restore/lineage/00000001/source-retirement")
           ) == proof

    assert File.read!(Path.join(cut.destination, ".loopex-restore/lineage/00000001/baseline")) ==
             cut.baseline

    Enum.each(intent["generations"], fn candidate ->
      relative = candidate["relative_root"]

      assert File.read!(Path.join([cut.destination, relative, "generation"])) ==
               candidate["source_generation_bytes"]

      destination_intent =
        File.read!(Path.join([cut.destination, relative, "restore-lineage/00000001/intent"]))

      {:ok, ledger_intent} = RestoreCodec.decode(:ledger_intent, destination_intent)
      assert ledger_intent["intent_sha256"] == hash(original)

      assert ledger_intent["source_generation_sha256"] ==
               hash(candidate["source_generation_bytes"])

      assert ledger_intent["destination_generation_sha256"] ==
               hash(candidate["destination_generation_bytes"])

      member = Enum.find(retirement["ledger_retirements"], &(&1["relative_root"] == relative))

      if cut.plan["source_status"] == "available" do
        assert retirement["disposition"] == "source_retired"

        assert File.read!(Path.join(cut.source, ".loopex-restore/lineage/00000001/intent")) ==
                 original

        assert File.read!(
                 Path.join(cut.source, ".loopex-restore/lineage/00000001/source-retirement")
               ) == proof

        assert File.read!(Path.join([cut.source, relative, "generation"])) ==
                 candidate["source_generation_bytes"]

        source_intent =
          File.read!(Path.join([cut.source, relative, "restore-lineage/00000001/intent"]))

        assert source_intent == destination_intent

        source_retired =
          File.read!(Path.join([cut.source, relative, "restore-lineage/00000001/source-retired"]))

        assert File.read!(
                 Path.join([cut.destination, relative, "restore-lineage/00000001/source-retired"])
               ) == source_retired

        {:ok, retired} = RestoreCodec.decode(:ledger_retired, source_retired)
        assert retired["ledger_intent_sha256"] == hash(source_intent)
        assert retired["source_ledger_binding"] == candidate["source_ledger_binding"]
        assert member["record_sha256"] == hash(source_retired)
      else
        assert retirement["disposition"] == "lost_source_host_excluded"
        assert member["record_sha256"] == nil

        refute File.exists?(
                 Path.join([cut.destination, relative, "restore-lineage/00000001/source-retired"])
               )
      end

      assert mode(Path.join([cut.destination, relative, "restore-lineage/00000001/intent"])) ==
               0o600
    end)
  end

  test "payload projection accounts only for newly installed administrative directories", %{
    root: root
  } do
    cut = prepare(root, "available")
    copy_baseline_payload(cut)
    before = original_payload(cut)

    for base <- [cut.source, cut.destination] do
      for relative <- [".loopex-restore", "receipts/restore-lineage"] do
        path = Path.join(base, relative)
        File.mkdir!(path)
        File.chmod!(path, 0o700)
      end
    end

    assert original_payload(cut) == before
    File.mkdir!(Path.join(cut.source, "unexpected-directory"))
    refute original_payload(cut) == before
  end

  test "payload projection preserves regular-file hard-link detection", %{root: root} do
    cut = prepare(root, "available")
    copy_baseline_payload(cut)
    before = original_payload(cut)
    File.ln!(Path.join(cut.source, "ordinary"), Path.join(root, "ordinary-alias"))
    refute original_payload(cut) == before
  end

  defp copy_baseline_payload(cut) do
    backup = cut.plan["backup_state_root"]

    for relative <- File.ls!(backup) do
      File.cp_r!(Path.join(backup, relative), Path.join(cut.destination, relative))
    end
  end

  defp original_payload(cut) do
    {:ok, entries} = RestoreCodec.manifest(cut.baseline, @total)

    roots =
      if cut.plan["source_status"] == "available",
        do: [cut.source, cut.destination],
        else: [cut.destination]

    Enum.map(roots, fn root ->
      {root,
       Enum.map(entries, fn entry ->
         path = if entry["path"] == ".", do: root, else: Path.join(root, entry["path"])
         info = File.lstat!(path)

         {entry["path"], info.type, mode(path), payload_links(cut, entries, root, entry, info),
          info.inode, if(info.type == :regular, do: File.read!(path), else: nil)}
       end)}
    end)
  end

  # Concept: Restoring adds administrative directories while preserving the imported payload.
  # Technical depth: Subtract only canonical direct child directories absent from the baseline;
  # original directory identity/mode and all regular-file bytes/inodes/link counts stay exact.
  defp payload_links(cut, entries, root, entry, %{type: :directory} = info) do
    administrative =
      [
        ".loopex-restore"
        | Enum.map(cut.plan["ledgers"], &Path.join(&1["relative_root"], "restore-lineage"))
      ]

    additions =
      Enum.count(administrative, fn relative ->
        parent = Path.dirname(relative)

        if parent == entry["path"] and not Enum.any?(entries, &(&1["path"] == relative)) do
          case File.lstat(Path.join(root, relative)) do
            {:ok, child} ->
              assert child.type == :directory
              assert Bitwise.band(child.mode, 0o7777) == 0o700
              true

            {:error, :enoent} ->
              false

            other ->
              flunk("administrative directory observation failed: #{inspect(other)}")
          end
        else
          false
        end
      end)

    info.links - additions
  end

  defp payload_links(_cut, _entries, _root, _entry, info), do: info.links

  defp assert_no_activation_or_release(cut, events) do
    refute Enum.any?(events, fn
             {:terminal_release_installed, _} ->
               true

             {:issued, _, kind} when is_tuple(kind) ->
               elem(kind, 0) in [:restore_claim_create, :restore_claim_released]

             {:issued, _, kind} ->
               kind in [:claim_delete, :claim_directory_delete]

             _ ->
               false
           end)

    refute File.exists?(Path.join(cut.destination, ".loopex-restore/lineage/00000001/committed"))
    refute File.exists?(Path.join(cut.destination, "receipts/restore-lineage/00000001/committed"))
  end

  defp source_proof_before_destination_copy(events) do
    positions =
      for {:issued, id, {:restore_retirement_step, side, name}} <- events, do: {id, side, name}

    source =
      Enum.find_value(positions, fn {id, side, name} ->
        if side == "source" and name == "source-retirement", do: id
      end)

    copied =
      Enum.find_value(positions, fn {id, side, name} ->
        if side == "destination" and name == "source-retired", do: id
      end)

    assert is_integer(source) and is_integer(copied) and source < copied

    assert Enum.any?(events, fn
             {:acknowledged, id, :directory_sync, :completed} -> id > source and id < copied
             _ -> false
           end)

    assert Enum.any?(events, fn
             {:acknowledged, id, {:close, _}, :closed} -> id > source and id < copied
             _ -> false
           end)
  end

  defp hold_step(owned, side, name, occurrence, events \\ []) do
    receive do
      {:restore_io, guardian, worker, reference,
       {:issued, id, {:restore_retirement_step, got_side, got_name}} = event}
      when guardian == owned.guardian and worker == owned.worker and reference == owned.reference ->
        if got_side == side and got_name == name and occurrence == 1 do
          {id, [event | events]}
        else
          send(guardian, {:proceed, reference, id})
          next = if got_side == side and got_name == name, do: occurrence - 1, else: occurrence
          hold_step(owned, side, name, next, [event | events])
        end

      {:restore_io, guardian, worker, reference, event}
      when guardian == owned.guardian and worker == owned.worker and reference == owned.reference ->
        hold_step(owned, side, name, occurrence, [event | events])
    after
      left(owned.cutoff) -> flunk("exact retained retirement step unavailable")
    end
  end

  defp hold_native_after_step(owned, side, name, native, seen \\ false, events \\ []) do
    receive do
      {:restore_io, guardian, worker, reference, {:issued, id, kind} = event}
      when guardian == owned.guardian and worker == owned.worker and reference == owned.reference ->
        actual = if is_tuple(kind), do: elem(kind, 0), else: kind
        next = seen or kind == {:restore_retirement_step, side, name}

        if actual == native and next do
          {id, [event | events]}
        else
          if actual == owned.pause, do: send(guardian, {:proceed, reference, id})
          hold_native_after_step(owned, side, name, native, next, [event | events])
        end

      {:restore_io, guardian, worker, reference, event}
      when guardian == owned.guardian and worker == owned.worker and reference == owned.reference ->
        hold_native_after_step(owned, side, name, native, seen, [event | events])
    after
      left(owned.cutoff) -> flunk("original native retirement boundary unavailable")
    end
  end

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

    hash(
      :erlang.term_to_binary(
        {owners, evidence.opens, evidence.closes,
         Enum.map(actors(owned), fn {_actor, monitor} ->
           reason = Process.get({:retirement_down, monitor})
           assert not is_nil(reason)
           reason
         end)},
        [:deterministic]
      )
    )
  end

  defp claims_before(cut) do
    roots =
      if cut.plan["source_status"] == "available",
        do: [cut.source, cut.destination],
        else: [cut.destination]

    Enum.map(Enum.sort(roots), fn root ->
      directory = claim_path(root)
      path = Path.join(directory, "owner")
      bytes = File.read!(path)
      assert {:ok, owner} = RestoreCodec.decode(:claim, bytes)

      %{
        directory: directory,
        inode: File.lstat!(directory).inode,
        owner_inode: File.lstat!(path).inode,
        owner: owner,
        bytes: bytes
      }
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

    own =
      {relative, info.type, Bitwise.band(info.mode, 0o7777), info.size, info.links, info.inode,
       if(info.type == :regular, do: File.read!(path), else: nil)}

    if info.type == :directory,
      do: [
        own
        | Enum.flat_map(
            Enum.sort(File.ls!(path)),
            &image(root, if(relative == ".", do: &1, else: Path.join(relative, &1)))
          )
      ],
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
      10_000 -> flunk("original retirement actors unavailable")
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
      left(owned.cutoff) -> flunk("original retirement result unavailable")
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
          Process.put({:retirement_down, monitor}, actual)
          assert actual == reason
      after
        left(owned.cutoff) -> flunk("exact original actor join unavailable")
      end
    end)
  end

  defp cleanup(owned) do
    Enum.each(actors(owned), fn {actor, monitor} ->
      if is_nil(Process.get({:retirement_down, monitor})) do
        Process.exit(actor, :kill)

        receive do
          {:DOWN, ^monitor, :process, ^actor, reason} ->
            Process.put({:retirement_down, monitor}, reason)
        after
          left(owned.cutoff) -> flunk("failure cleanup did not join original actor")
        end
      end
    end)
  end
end
