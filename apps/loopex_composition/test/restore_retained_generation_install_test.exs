Code.require_file("support/restore_fixture_copy.ex", __DIR__)

defmodule LoopexComposition.RestoreRetainedGenerationInstallTest do
  use ExUnit.Case, async: false

  alias Loopex.Executor.Local.{Ledger, RestoreCodec, RestoreGuard}
  alias LoopexComposition.{Restore, RestoreFixtureCopy, WorkspaceIdentity}
  alias LoopexComposition.Restore.IO, as: RestoreIO

  @limits %{"work_ms" => 10_000, "cleanup_grace_ms" => 1_000}
  @total 16_777_216

  setup do
    {:ok, temp} = WorkspaceIdentity.resolve_path(System.tmp_dir!())
    Process.put({__MODULE__, :payload_link_profile}, payload_link_profile(temp))

    root =
      Path.join(
        temp,
        "restore-generation-" <> Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)
      )

    File.mkdir!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  for status <- ~w(available lost), authority <- ~w(joined host_rebooted) do
    test "actual #{status} original candidates install with #{authority} and remain fenced", %{
      root: root
    } do
      cut = prepare(root, unquote(status))
      prior = strand(cut, "source_retirement")
      original = File.read!(intent_path(cut))
      before = original_payload(cut)
      {result, events, _prior} = finish(cut, invocation(unquote(authority), prior))

      assert {:joined,
              {:ok,
               %{
                 claims: claims,
                 intent: ^original,
                 source_retirement: proof,
                 activation_manifest: activation
               }}, evidence} = result

      assert evidence.opens == evidence.closes
      assert evidence.claim_count == if(unquote(status) == "available", do: 2, else: 1)
      assert evidence.restore_observation["phase"] == "destination_generations"
      assert evidence.restore_observation["claim"] == "retained"
      assert original_payload(cut) == before
      assert activation == manifest(cut.destination)
      assert_generation(cut, original, proof)
      assert Enum.all?(claims, &(File.read!(Path.join(&1.directory, "owner")) == &1.owner))
      {:ok, intent} = RestoreCodec.decode(:intent, original)
      [candidate] = intent["generations"]

      {:ok, old_generation} =
        RestoreCodec.decode(:generation, candidate["source_generation_bytes"])

      {:ok, new_generation} =
        RestoreCodec.decode(:generation, candidate["destination_generation_bytes"])

      assert old_generation["executor_epoch"] != new_generation["executor_epoch"]
      assert File.read!(Path.join(cut.destination, "ordinary")) == <<0, 255, 1, 254, 2, 0, 128>>
      refute File.exists?(Path.join(cut.destination, "receipts/generation.restore-00000001.tmp"))
      assert_no_commit_or_release(cut, events)
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

  test "a positively joined fully retired cut installs the literal retained candidate without another epoch",
       %{root: root} do
    cut = prepare(root, "available")
    prior = strand(cut, "source_retirement")

    {{:joined, {:ok, %{intent: original, source_retirement: proof}}, _}, _, next_prior} =
      finish(
        cut,
        invocation("joined", prior),
        :restore_retained_source_retirement,
        :restore_retirement_step
      )

    source_before = image(cut.source)

    {{:joined, {:ok, %{intent: ^original, source_retirement: ^proof}}, evidence}, events, _} =
      finish(cut, invocation("joined", next_prior))

    assert image(cut.source) == source_before
    assert evidence.opens == evidence.closes and evidence.claim_count == 2
    assert_generation(cut, original, proof)
    assert_no_commit_or_release(cut, events)
  end

  for native <- [:file_sync, :rename, :directory_sync] do
    test "caller loss before native candidate #{native} joins original descriptors and retains custody",
         %{root: root} do
      cut = prepare(root, "available")
      prior = strand(cut, "source_retirement")
      original_generation = File.read!(Path.join(cut.source, "receipts/generation"))

      owned =
        launch(
          {:restore_retained_generation_install, cut.plan, invocation("joined", prior)},
          unquote(native)
        )

      try do
        {_id, _events} = hold_candidate(owned, unquote(native))
        Process.exit(owned.caller, :kill)
        assert {:joined, {:error, :caller_lost}, evidence} = receive_terminal(owned)
        join(owned, [:killed, :normal, :normal])
        assert evidence.opens == evidence.closes and evidence.claim_count == 2
        assert evidence.restore_observation["phase"] == "destination_generations"
        assert evidence.restore_observation["claim"] == "retained"
        assert File.read!(Path.join(cut.source, "receipts/generation")) == original_generation
        assert_no_commit_or_release(cut, [])
      after
        cleanup(owned)
      end
    end
  end

  test "guardian loss at real ordinal-bound candidate temp sync remains unconfirmed", %{
    root: root
  } do
    cut = prepare(root, "available")
    prior = strand(cut, "source_retirement")

    owned =
      launch(
        {:restore_retained_generation_install, cut.plan, invocation("joined", prior)},
        :file_sync
      )

    try do
      {_id, _events} = hold_candidate(owned, :file_sync)
      temp = Path.join(cut.destination, "receipts/generation.restore-00000001.tmp")
      assert File.lstat!(temp).type == :regular
      Process.exit(owned.guardian, :kill)

      assert {{:unconfirmed, :guardian_lost, %{restore_observation: observation}}, _} =
               collect(owned, [])

      join(owned, [:normal, :killed, :killed])
      assert observation["cleanup"] == "unconfirmed" and observation["claim"] == "retained"
      assert File.lstat!(temp).type == :regular
      assert_no_commit_or_release(cut, [])
    after
      cleanup(owned)
    end
  end

  for fault <- [:source_proof, :lost_source, :workspace, :destination_ledger, :generation, :owner] do
    test "actual #{fault} substitution at candidate barrier refuses without committed authority",
         %{root: root} do
      status = if unquote(fault) == :lost_source, do: "lost", else: "available"
      cut = prepare(root, status)
      prior = strand(cut, "source_retirement")

      owned =
        launch(
          {:restore_retained_generation_install, cut.plan, invocation("joined", prior)},
          :restore_generation_step
        )

      try do
        {id, events} = hold_candidate(owned, :restore_generation_step)
        original_generation = File.read!(Path.join(cut.destination, "receipts/generation"))
        expected = install_fault(cut, root, unquote(fault))
        before = state_image(cut)
        send(owned.guardian, {:proceed, owned.reference, id})
        assert {{:joined, {:error, ^expected}, evidence}, events} = collect(owned, events)
        join(owned, [:normal, :normal, :normal])

        assert evidence.opens == evidence.closes and
                 evidence.claim_count == if(status == "available", do: 2, else: 1)

        assert state_image(cut) == before

        if unquote(fault) != :generation,
          do:
            assert(
              File.read!(Path.join(cut.destination, "receipts/generation")) == original_generation
            )

        assert_no_commit_or_release(cut, events)
      after
        cleanup(owned)
      end
    end
  end

  test "same-size ordinary destination overwrite prevents complete activation-manifest success",
       %{root: root} do
    cut = prepare(root, "available")
    prior = strand(cut, "source_retirement")

    owned =
      launch(
        {:restore_retained_generation_install, cut.plan, invocation("joined", prior)},
        :directory_sync
      )

    try do
      {id, events} = hold_candidate(owned, :directory_sync)
      path = Path.join(cut.destination, "ordinary")
      File.write!(path, :binary.copy(<<3>>, byte_size(File.read!(path))))
      send(owned.guardian, {:proceed, owned.reference, id})

      assert {{:joined, {:error, "inventory_mismatch"}, evidence}, events} =
               collect(owned, events)

      join(owned, [:normal, :normal, :normal])
      assert evidence.opens == evidence.closes and evidence.claim_count == 2
      assert_no_commit_or_release(cut, events)
    after
      cleanup(owned)
    end
  end

  test "same-size candidate temp overwrite cannot produce successful readback", %{root: root} do
    cut = prepare(root, "available")
    prior = strand(cut, "source_retirement")

    owned =
      launch(
        {:restore_retained_generation_install, cut.plan, invocation("joined", prior)},
        :file_sync
      )

    try do
      {id, events} = hold_candidate(owned, :file_sync)
      temp = Path.join(cut.destination, "receipts/generation.restore-00000001.tmp")
      File.write!(temp, :binary.copy(<<0>>, byte_size(File.read!(temp))))
      send(owned.guardian, {:proceed, owned.reference, id})

      assert {{:joined, {:error, "inventory_unavailable"}, evidence}, events} =
               collect(owned, events)

      join(owned, [:normal, :normal, :normal])
      assert evidence.opens == evidence.closes and evidence.claim_count == 2
      assert_no_commit_or_release(cut, events)
    after
      cleanup(owned)
    end
  end

  test "a genuine complete candidate staging cut resumes the original bytes after proved cleanup",
       %{root: root} do
    cut = prepare(root, "available")
    prior = strand(cut, "source_retirement")

    owned =
      launch(
        {:restore_retained_generation_install, cut.plan, invocation("joined", prior)},
        :file_sync
      )

    try do
      {_id, _events} = hold_candidate(owned, :file_sync)
      Process.exit(owned.caller, :kill)
      assert {:joined, {:error, :caller_lost}, evidence} = receive_terminal(owned)
      join(owned, [:killed, :normal, :normal])
      assert evidence.opens == evidence.closes
      original = File.read!(intent_path(cut))
      {:ok, intent} = RestoreCodec.decode(:intent, original)
      [candidate] = intent["generations"]
      temporary = Path.join(cut.destination, "receipts/generation.restore-00000001.tmp")
      assert File.read!(temporary) == candidate["destination_generation_bytes"]
      next_prior = prior_evidence(cut, owned, evidence)
      before = claims_before(cut)
      payload = original_payload(cut)

      assert {{:joined, {:ok, result}, final}, events, _} =
               finish(cut, invocation("joined", next_prior))

      assert final.opens == final.closes
      assert original_payload(cut) == payload
      assert result.intent == original
      assert result.activation_manifest == manifest(cut.destination)
      assert_generation(cut, original, result.source_retirement)
      refute File.exists?(temporary)

      Enum.zip(before, claims_before(cut))
      |> Enum.each(fn {old, current} ->
        assert Map.delete(old.owner, "claim_nonce") == Map.delete(current.owner, "claim_nonce")
        refute old.owner["claim_nonce"] == current.owner["claim_nonce"]
      end)

      assert_no_commit_or_release(cut, events)
    after
      cleanup(owned)
    end
  end

  test "already installed original candidates re-sync without another epoch or committed authority",
       %{root: root} do
    cut = prepare(root, "available")
    prior = strand(cut, "source_retirement")
    {{:joined, {:ok, first}, _}, _, next_prior} = finish(cut, invocation("joined", prior))
    before = state_image(cut)
    owners = claims_before(cut)

    assert {{:joined, {:ok, result}, evidence}, events, _} =
             finish(cut, invocation("joined", next_prior))

    assert evidence.opens == evidence.closes and state_image(cut) == before
    assert result.intent == first.intent
    assert result.source_retirement == first.source_retirement
    assert result.activation_manifest == first.activation_manifest

    Enum.zip(owners, claims_before(cut))
    |> Enum.each(fn {old, current} ->
      assert Map.delete(old.owner, "claim_nonce") == Map.delete(current.owner, "claim_nonce")
      refute old.owner["claim_nonce"] == current.owner["claim_nonce"]
    end)

    assert_no_commit_or_release(cut, events)
  end

  defp install_fault(cut, _root, :source_proof) do
    File.rm!(Path.join(cut.source, "receipts/restore-lineage/00000001/source-retired"))
    "inventory_mismatch"
  end

  defp install_fault(cut, _root, :lost_source) do
    File.mkdir!(cut.source)
    "inventory_unavailable"
  end

  defp install_fault(cut, root, :workspace) do
    workspace = cut.plan["workspace"]["root"]
    File.rename!(workspace, Path.join(root, "original-workspace"))
    File.mkdir!(workspace)
    "invalid_placement"
  end

  defp install_fault(cut, root, :destination_ledger) do
    ledger = Path.join(cut.destination, "receipts")
    before = File.lstat!(ledger)
    aside = Path.join(root, "original-destination-ledger")
    File.rename!(ledger, aside)
    assert {:ok, _} = RestoreFixtureCopy.copy(aside, ledger)
    assert File.lstat!(ledger).inode != before.inode

    assert File.read!(Path.join(ledger, "generation")) ==
             File.read!(Path.join(aside, "generation"))

    "source_changed"
  end

  defp install_fault(cut, _root, :generation) do
    path = Path.join(cut.destination, "receipts/generation")
    File.write!(path, :binary.copy(<<0>>, byte_size(File.read!(path))))
    "inventory_unavailable"
  end

  defp install_fault(cut, _root, :owner) do
    change_owner(Path.join(claim_path(cut.source), "owner"), "plan_digest", hash("foreign-plan"))
    "inventory_unavailable"
  end

  defp finish(
         cut,
         invoke,
         operation \\ :restore_retained_generation_install,
         pause \\ :restore_generation_step
       ) do
    owned = launch({operation, cut.plan, invoke}, pause)

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

  defp hold_candidate(owned, native, seen \\ false, events \\ []) do
    receive do
      {:restore_io, guardian, worker, reference, {:issued, id, kind} = event}
      when guardian == owned.guardian and worker == owned.worker and reference == owned.reference ->
        actual = if is_tuple(kind), do: elem(kind, 0), else: kind
        next = seen or kind == {:restore_generation_step, "receipts"}

        if actual == native and next do
          {id, [event | events]}
        else
          if actual == owned.pause, do: send(guardian, {:proceed, reference, id})
          hold_candidate(owned, native, next, [event | events])
        end

      {:restore_io, guardian, worker, reference, event}
      when guardian == owned.guardian and worker == owned.worker and reference == owned.reference ->
        hold_candidate(owned, native, seen, [event | events])
    after
      left(owned.cutoff) -> flunk("original native generation boundary unavailable")
    end
  end

  defp assert_generation(cut, original, proof) do
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
               candidate["destination_generation_bytes"]

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

  test "payload projection accounts only for the genuine original ordinal staging file", %{
    root: root
  } do
    cut = prepare(root, "available")
    prior = strand(cut, "source_retirement")

    owned =
      launch(
        {:restore_retained_generation_install, cut.plan, invocation("joined", prior)},
        :file_sync
      )

    try do
      {_id, _events} = hold_candidate(owned, :file_sync)
      Process.exit(owned.caller, :kill)
      assert {:joined, {:error, :caller_lost}, evidence} = receive_terminal(owned)
      join(owned, [:killed, :normal, :normal])
      assert evidence.opens == evidence.closes
      before = original_payload(cut)
      temporary = Path.join(cut.destination, "receipts/generation.restore-00000001.tmp")
      assert File.lstat!(temporary).type == :regular
      File.rm!(temporary)
      assert original_payload(cut) == before
    after
      cleanup(owned)
    end
  end

  test "payload projection retains unexpected regular directory entries", %{root: root} do
    cut = prepare(root, "available")
    copy_baseline_payload(cut)
    before = original_payload(cut)
    File.write!(Path.join(cut.destination, "receipts/unrelated.tmp"), "unrelated")
    refute original_payload(cut) == before
  end

  defp copy_baseline_payload(cut) do
    backup = cut.plan["backup_state_root"]

    for relative <- File.ls!(backup) do
      assert {:ok, _} =
               RestoreFixtureCopy.copy(
                 Path.join(backup, relative),
                 Path.join(cut.destination, relative)
               )
    end
  end

  defp original_payload(cut) do
    {:ok, entries} = RestoreCodec.manifest(cut.baseline, @total)

    roots =
      if cut.plan["source_status"] == "available",
        do: [cut.source, cut.destination],
        else: [cut.destination]

    Enum.map(roots, fn root ->
      selected =
        Enum.reject(entries, fn entry ->
          root == cut.destination and entry["path"] == "receipts/generation"
        end)

      {root,
       Enum.map(selected, fn entry ->
         path = if entry["path"] == ".", do: root, else: Path.join(root, entry["path"])
         info = File.lstat!(path)

         {entry["path"], info.type, mode(path), payload_links(cut, entries, root, entry, info),
          info.inode, if(info.type == :regular, do: File.read!(path), else: nil)}
       end)}
    end)
  end

  # Concept: Preserve the original payload across only the admitted administrative additions.
  # Technical depth: Native directory links may count regular entries as well as subdirectories.
  # The once-selected same-device fixture profile supplies their measured contributions; subtract
  # only canonical absent-baseline children and retain all remaining direct-child names. Original
  # directory identity/mode and every regular-file byte/inode/link count remain exact.
  defp payload_links(cut, entries, root, entry, %{type: :directory} = info) do
    profile = Process.get({__MODULE__, :payload_link_profile})
    assert profile.device == {info.major_device, info.minor_device}

    administrative =
      [
        ".loopex-restore"
        | Enum.map(cut.plan["ledgers"], &Path.join(&1["relative_root"], "restore-lineage"))
      ]

    directories =
      Enum.filter(administrative, fn relative ->
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

    temporaries = payload_temporaries(cut, entries, root, entry)
    normalized = Enum.map(directories ++ temporaries, &Path.basename/1)
    path = if entry["path"] == ".", do: root, else: Path.join(root, entry["path"])
    residual = File.ls!(path) |> Enum.reject(&(&1 in normalized)) |> Enum.sort()

    {info.links - length(directories) * profile.directory -
       length(temporaries) * profile.regular, residual}
  end

  defp payload_links(_cut, _entries, _root, _entry, info), do: info.links

  # Concept: The staging exception belongs to the original retained transaction alone.
  # Technical depth: Only the destination ledger's exact ordinal name, absent from the baseline,
  # with the retained intent's complete bounded candidate bytes, baseline generation mode and
  # single-link identity is normalized.
  # Unrecognized or invalid files remain visible through the residual direct-child projection.
  defp payload_temporaries(cut, entries, root, entry) do
    if root == cut.destination do
      ordinal = cut.plan["prior_restore_count"] + 1
      ordinal = ordinal |> Integer.to_string() |> String.pad_leading(8, "0")

      intent =
        with {:ok, info} <- File.lstat(intent_path(cut)),
             true <- info.type == :regular and info.links == 1 and info.size <= 65_536,
             true <- Bitwise.band(info.mode, 0o7777) == 0o600,
             {:ok, bytes} <- File.read(intent_path(cut)),
             {:ok, retained} <- RestoreCodec.decode(:intent, bytes),
             true <- retained["plan"] == cut.plan,
             true <- retained["destination_state_placement"] == placement(root) do
          retained
        else
          _ -> nil
        end

      if intent do
        Enum.flat_map(intent["generations"], fn candidate ->
          relative =
            Path.join(candidate["relative_root"], "generation.restore-" <> ordinal <> ".tmp")

          generation =
            Enum.find(
              entries,
              &(&1["path"] == Path.join(candidate["relative_root"], "generation"))
            )

          if is_map(generation) and generation["kind"] == "regular" and
               Path.dirname(relative) == entry["path"] and
               not Enum.any?(entries, &(&1["path"] == relative)) and
               Enum.any?(
                 cut.plan["ledgers"],
                 &(&1["relative_root"] == candidate["relative_root"])
               ) and
               candidate["destination_ledger_placement"] ==
                 placement(Path.join(root, candidate["relative_root"])) and
               payload_temporary?(
                 Path.join(root, relative),
                 candidate["destination_generation_bytes"],
                 generation["mode"]
               ) do
            [relative]
          else
            []
          end
        end)
      else
        []
      end
    else
      []
    end
  end

  defp payload_temporary?(path, expected, expected_mode) do
    with {:ok, before} <- File.lstat(path),
         true <- before.type == :regular and Bitwise.band(before.mode, 0o7777) == expected_mode,
         true <- before.links == 1 and before.size <= 2_048,
         true <- before.size == byte_size(expected),
         {:ok, ^expected} <- File.read(path),
         {:ok, after_read} <- File.lstat(path) do
      Enum.all?([:type, :mode, :size, :inode, :major_device, :minor_device, :links], fn field ->
        Map.fetch!(before, field) == Map.fetch!(after_read, field)
      end)
    else
      _ -> false
    end
  end

  # Concept: Select a supported native link profile outside all restore authorities.
  # Technical depth: One same-device sibling scratch measures both add/remove transitions without
  # recapturing state/workspace/backup facts. Zero/one regular-entry contribution and one directory
  # contribution are supported; unsupported profiles fail, and scratch cleanup runs on every exit.
  defp payload_link_profile(temp) do
    scratch = Path.join(temp, "restore-links-" <> Base.encode16(:crypto.strong_rand_bytes(12)))

    try do
      File.mkdir!(scratch)
      initial = File.lstat!(scratch)
      assert initial.type == :directory and initial.links >= 2
      regular = Path.join(scratch, "regular")
      directory = Path.join(scratch, "directory")
      File.write!(regular, "probe")
      with_regular = File.lstat!(scratch)
      regular_increment = with_regular.links - initial.links
      assert regular_increment in [0, 1]
      assert File.lstat!(regular).links == 1
      File.mkdir!(directory)
      with_both = File.lstat!(scratch)
      assert with_both.links == with_regular.links + 1
      File.rm!(regular)
      with_directory = File.lstat!(scratch)
      assert with_directory.links == initial.links + 1
      File.rmdir!(directory)
      final = File.lstat!(scratch)
      assert final.links == initial.links

      Enum.each([with_regular, with_both, with_directory, final], fn observed ->
        assert {observed.type, observed.mode, observed.inode, observed.major_device,
                observed.minor_device} ==
                 {initial.type, initial.mode, initial.inode, initial.major_device,
                  initial.minor_device}
      end)

      assert File.ls!(scratch) == []

      %{
        regular: regular_increment,
        directory: 1,
        device: {initial.major_device, initial.minor_device}
      }
    after
      File.rm_rf!(scratch)
    end
  end

  defp assert_no_commit_or_release(cut, events) do
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
           reason = Process.get({:generation_down, monitor})
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
    File.write!(Path.join(source, "ordinary"), <<0, 255, 1, 254, 2, 0, 128>>)
    assert {:ok, _} = RestoreFixtureCopy.copy(source, backup)
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
          Process.put({:generation_down, monitor}, actual)
          assert actual == reason
      after
        left(owned.cutoff) -> flunk("exact original actor join unavailable")
      end
    end)
  end

  defp cleanup(owned) do
    Enum.each(actors(owned), fn {actor, monitor} ->
      if is_nil(Process.get({:generation_down, monitor})) do
        Process.exit(actor, :kill)

        receive do
          {:DOWN, ^monitor, :process, ^actor, reason} ->
            Process.put({:generation_down, monitor}, reason)
        after
          left(owned.cutoff) -> flunk("failure cleanup did not join original actor")
        end
      end
    end)
  end
end
