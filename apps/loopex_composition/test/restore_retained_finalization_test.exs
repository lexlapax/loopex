Code.require_file("support/restore_fixture_copy.ex", __DIR__)

defmodule LoopexComposition.RestoreRetainedFinalizationTest do
  use ExUnit.Case, async: false

  alias Loopex.Executor.Local.{Ledger, RestoreCodec, RestoreGuard}
  alias LoopexComposition.{Restore, WorkspaceIdentity}
  alias LoopexComposition.RestoreFixtureCopy
  alias LoopexComposition.Restore.IO, as: RestoreIO

  @limits %{"work_ms" => 10_000, "cleanup_grace_ms" => 1_000}
  @total 16_777_216

  setup do
    {:ok, temp} = WorkspaceIdentity.resolve_path(System.tmp_dir!())
    root = Path.join(temp, "restore-final-" <> Base.encode16(:crypto.strong_rand_bytes(12)))
    File.mkdir!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  for status <- ~w(available lost), authority <- ~w(joined host_rebooted) do
    test "actual two-ledger #{status} finalization with #{authority} releases captured claims before receipt",
         %{root: root} do
      cut = prepare(root, unquote(status))
      prior = strand_first(cut)
      original = File.read!(intent_path(cut))
      payload = payload_identity(cut)
      backup = manifest(cut.plan["backup_state_root"])
      {result, events} = finish(cut, invocation(unquote(authority), prior))

      assert {:joined, {:ok, %{restore_result: {:committed, receipt}, release_claims: []}},
              evidence} = result

      assert evidence.opens == evidence.closes and evidence.claim_count == 0
      assert evidence.restore_observation["claim"] == "none"
      assert evidence.restore_observation["phase"] == "claim_release"
      assert payload_identity(cut) == payload
      assert manifest(cut.plan["backup_state_root"]) == backup
      assert File.read!(intent_path(cut)) == original
      assert_complete(cut, receipt, original)
      assert_root_last_and_release(events)
    end
  end

  for status <- ~w(available lost),
      member <- [2, 3],
      native <- [:file_sync, :rename, :directory_sync, :read] do
    test "actual #{status} proof #{member} #{native} interruption resumes original proofs and candidates",
         %{root: root} do
      cut = prepare(root, unquote(status))
      prior = strand_first(cut)
      original = File.read!(intent_path(cut))
      payload = payload_identity(cut)
      owned = launch(finalization(cut, prior), unquote(native))

      try do
        {_id, events} =
          hold_proof(
            owned,
            unquote(member),
            unquote(native),
            0,
            [],
            proof_path(cut, unquote(member))
          )

        path = proof_path(cut, unquote(member))

        if unquote(native) in [:directory_sync, :read] do
          assert File.lstat!(path).type == :regular
          refute File.exists?(path <> ".tmp")
        else
          assert File.lstat!(path <> ".tmp").type == :regular
          refute File.exists?(path)
        end

        if unquote(member) == 2, do: refute(File.exists?(proof_path(cut, 3)))
        Process.exit(owned.caller, :kill)
        {stopped, events} = collect(owned, events, :terminal)

        assert {:joined,
                {:ok,
                 %{restore_result: {:commit_unknown, "inventory_unavailable"}, release_claims: []}},
                evidence} = stopped

        join(owned, [:killed, :normal, :normal])
        assert evidence.opens == evidence.closes
        assert evidence.restore_observation["claim"] == "retained"

        refute Enum.any?(events, fn {_worker, event} ->
                 match?({:terminal_release_installed, _}, event)
               end)

        next_prior = prior_evidence(cut, owned, evidence)
        before_claims = claim_owners(cut)
        {result, resumed} = finish(cut, invocation("joined", next_prior))

        assert {:joined, {:ok, %{restore_result: {:committed, receipt}, release_claims: []}},
                final} = result

        assert final.opens == final.closes and final.claim_count == 0
        assert payload_identity(cut) == payload
        assert File.read!(intent_path(cut)) == original
        assert length(before_claims) == if(unquote(status) == "available", do: 2, else: 1)
        assert_complete(cut, receipt, original)
        assert_root_last_and_release(resumed)
        refute File.exists?(path <> ".tmp")
      after
        cleanup(owned)
      end
    end
  end

  for fault <- [
        :torn_proof,
        :foreign_proof,
        :wrong_ordinal,
        :ordinary,
        :backup,
        :owner,
        :root_missing_ledger
      ] do
    test "actual #{fault} proof prefix refuses before nonce handoff", %{root: root} do
      cut = prepare(root, "available")
      prior = strand_first(cut)
      {next_prior, _} = strand_proof(cut, prior, 3, :file_sync)
      expected = install_fault(cut, unquote(fault))
      before = image(root)
      owners = claim_owners(cut)
      {result, events} = finish(cut, invocation("joined", next_prior))

      assert {:joined, {:ok, %{restore_result: {:commit_unknown, ^expected}, release_claims: []}},
              evidence} = result

      assert evidence.opens == evidence.closes
      assert image(root) == before and claim_owners(cut) == owners

      refute Enum.any?(events, fn {_worker, event} ->
               match?({:issued, _, {:restore_claim_handoff, _}}, event)
             end)

      refute Enum.any?(events, fn {_worker, event} ->
               match?({:terminal_release_installed, _}, event)
             end)
    end
  end

  test "lost source reappearance refuses an installed proof-free cut without handing off claims",
       %{root: root} do
    cut = prepare(root, "lost")
    prior = strand_first(cut)
    File.mkdir!(cut.source)
    before = image(root)
    owners = claim_owners(cut)
    {result, events} = finish(cut, invocation("joined", prior))

    assert {:joined,
            {:ok,
             %{restore_result: {:commit_unknown, "inventory_unavailable"}, release_claims: []}},
            evidence} = result

    assert evidence.opens == evidence.closes
    assert image(root) == before and claim_owners(cut) == owners

    refute Enum.any?(events, fn {_worker, event} ->
             match?({:issued, _, {:restore_claim_handoff, _}}, event)
           end)
  end

  test "guardian loss at held terminal claim IO cannot return a committed receipt", %{root: root} do
    cut = prepare(root, "available")
    prior = strand_first(cut)
    original = File.read!(intent_path(cut))
    owned = launch(finalization(cut, prior), :open)

    try do
      {_id, events} = hold_release_open(owned, [])
      assert File.lstat!(proof_path(cut, 3)).type == :regular

      assert Enum.any?(events, fn {_worker, event} ->
               match?({:terminal_release_installed, _}, event)
             end)

      assert length(claim_owners(cut)) == 2
      Process.exit(owned.guardian, :kill)
      {result, _events} = collect(owned, events)
      assert {:unconfirmed, :guardian_lost, %{restore_observation: observation}} = result
      assert observation["intent"] == "validated" and observation["claim"] == "retained"
      join(owned, [:normal, :killed, :normal])
      join_release(owned, :killed)
      assert File.read!(intent_path(cut)) == original

      assert {:pending, %{"phase" => "claim_release"}} =
               Restore.lookup(cut.destination, cut.plan["tx_id"], @limits)

      assert {:error, :restore_incomplete} = RestoreGuard.state(cut.destination)
    after
      cleanup(owned)
    end
  end

  test "a complete root retained before release re-syncs and returns the same canonical receipt",
       %{root: root} do
    cut = prepare(root, "available")
    prior = strand_first(cut)
    {next_prior, evidence} = strand_proof(cut, prior, 3, :directory_sync)
    assert evidence.opens == evidence.closes
    original = File.read!(intent_path(cut))
    committed = File.read!(proof_path(cut, 3))
    generations = generation_bytes(cut)
    {result, events} = finish(cut, invocation("joined", next_prior))

    assert {:joined, {:ok, %{restore_result: {:committed, receipt}, release_claims: []}}, final} =
             result

    assert final.opens == final.closes and final.claim_count == 0
    assert File.read!(proof_path(cut, 3)) == committed
    assert generation_bytes(cut) == generations
    assert_complete(cut, receipt, original)
    assert_root_last_and_release(events)
  end

  test "a completed duplicate needs no source backup allocation handoff or release", %{root: root} do
    cut = prepare(root, "available")
    prior = strand_first(cut)
    {first, _events} = finish(cut, invocation("joined", prior))
    assert {:joined, {:ok, %{restore_result: {:committed, receipt}}}, _} = first
    File.rm_rf!(cut.source)
    File.rm_rf!(cut.plan["backup_state_root"])
    File.write!(Path.join(cut.destination, "evolved"), "ordinary later state")
    before = image(cut.destination)

    {result, events} =
      finish(cut, invocation("host_rebooted", hash("joined original finalization")))

    assert {:joined, {:ok, %{restore_result: {:committed, ^receipt}, release_claims: []}},
            evidence} = result

    assert evidence.opens == evidence.closes and evidence.claim_count == 0
    assert image(cut.destination) == before

    refute Enum.any?(events, fn {_worker, event} ->
             match?({:issued, _, {:restore_claim_handoff, _}}, event) or
               match?({:terminal_release_installed, _}, event) or
               match?({:issued, _, :file_sync}, event) or match?({:issued, _, :rename}, event)
           end)
  end

  test "unproved prior authority refuses before actors or source mutation", %{root: root} do
    cut = prepare(root, "available")
    _prior = strand_first(cut)
    before = image(root)

    assert {:error, :invalid_io_request} =
             RestoreIO.run(
               {:restore_retained_destination_finalization, cut.plan, invocation()},
               @limits,
               probe: self()
             )

    assert image(root) == before
    refute_receive {:restore_io, _, _, _, {:installed, _, _}}, 0
  end

  defp install_fault(cut, :torn_proof) do
    path = proof_path(cut, 3) <> ".tmp"
    bytes = File.read!(path)
    File.write!(path, binary_part(bytes, 0, byte_size(bytes) - 1))
    "invalid_current_history"
  end

  defp install_fault(cut, :foreign_proof) do
    path = proof_path(cut, 3) <> ".tmp"
    {:ok, proof} = RestoreCodec.decode(:committed, File.read!(path))
    {:ok, bytes} = RestoreCodec.encode(:committed, Map.put(proof, "tx_id", hash("foreign-proof")))
    File.write!(path, bytes)
    "invalid_current_history"
  end

  defp install_fault(cut, :wrong_ordinal) do
    File.rename!(proof_path(cut, 3) <> ".tmp", proof_path(cut, 3) <> ".other")
    "invalid_current_history"
  end

  defp install_fault(cut, :ordinary) do
    path = Path.join(cut.destination, "ordinary")
    File.write!(path, :binary.copy(<<3>>, byte_size(File.read!(path))))
    "inventory_mismatch"
  end

  defp install_fault(cut, :backup) do
    File.write!(Path.join(cut.plan["backup_state_root"], "ordinary"), "changed backup")
    "inventory_mismatch"
  end

  defp install_fault(cut, :owner) do
    path = Path.join(claim_path(cut.destination), "owner")
    {:ok, claim} = RestoreCodec.decode(:claim, File.read!(path))

    {:ok, bytes} =
      RestoreCodec.encode(:claim, Map.put(claim, "plan_digest", hash("foreign-plan")))

    File.write!(path, bytes)
    "restore_conflict"
  end

  defp install_fault(cut, :root_missing_ledger) do
    File.rm!(proof_path(cut, 1))
    "invalid_current_history"
  end

  defp assert_complete(cut, receipt, original) do
    assert {:ok, _} = RestoreCodec.encode(:receipt, receipt)
    assert receipt["tx_id"] == cut.plan["tx_id"] and receipt["ordinal"] == 1
    assert receipt["ledger_count"] == 2
    assert receipt["intent_sha256"] == hash(original)
    assert receipt["committed_sha256"] == hash(File.read!(proof_path(cut, 3)))
    assert receipt["baseline_manifest_sha256"] == hash(cut.baseline)
    {:ok, root_proof} = RestoreCodec.decode(:committed, File.read!(proof_path(cut, 3)))
    assert receipt["activation_manifest_sha256"] == root_proof["activation_manifest_sha256"]
    {:ok, intent} = RestoreCodec.decode(:intent, original)

    Enum.zip(intent["generations"], [1, 2])
    |> Enum.each(fn {candidate, member} ->
      assert File.read!(Path.join([cut.destination, candidate["relative_root"], "generation"])) ==
               candidate["destination_generation_bytes"]

      bytes = File.read!(proof_path(cut, member))
      assert {:ok, proof} = RestoreCodec.decode(:ledger_committed, bytes)
      assert proof["tx_id"] == cut.plan["tx_id"] and proof["intent_sha256"] == hash(original)

      assert proof["destination_generation_sha256"] ==
               hash(candidate["destination_generation_bytes"])

      assert proof["relative_root"] == candidate["relative_root"]

      assert Enum.find(
               root_proof["ledger_proofs"],
               &(&1["relative_root"] == candidate["relative_root"])
             )["record_sha256"] == hash(bytes)

      assert Bitwise.band(File.lstat!(proof_path(cut, member)).mode, 0o7777) == 0o600
      refute File.exists?(proof_path(cut, member) <> ".tmp")
    end)

    refute File.exists?(proof_path(cut, 3) <> ".tmp")
    for root <- participating(cut), do: refute(File.exists?(claim_path(root)))

    assert {:committed, %{"receipt" => ^receipt, "view" => "current"}} =
             Restore.lookup(cut.destination, cut.plan["tx_id"], @limits)

    assert {:ok, _} = RestoreGuard.state(cut.destination)

    if cut.plan["source_status"] == "available",
      do: assert({:error, :source_retired} == RestoreGuard.state(cut.source))
  end

  defp assert_root_last_and_release(events) do
    steps =
      for {worker, {:issued, id, {:restore_retirement_step, "destination", "committed"}}} <-
            events,
          do: {worker, id}

    assert length(steps) == 3
    [{worker, first}, {second_worker, second}, {root_worker, root}] = steps
    assert worker == second_worker and worker == root_worker
    assert first < second and second < root
    root_at = Enum.find_index(events, &match?({^worker, {:issued, ^root, _}}, &1))

    release_at =
      Enum.find_index(events, fn {_worker, event} ->
        match?({:terminal_release_installed, _}, event)
      end)

    assert is_integer(release_at) and root_at < release_at

    assert Enum.any?(Enum.slice(events, root_at, release_at - root_at), fn
             {^worker, {:acknowledged, _, :directory_sync, :completed}} -> true
             _ -> false
           end)

    refute Enum.any?(Enum.drop(events, release_at), fn
             {_worker, {:issued, _, kind}} -> kind in [:rename, :write, :file_sync]
             _ -> false
           end)
  end

  defp finish(cut, invoke) do
    owned = launch({:restore_retained_destination_finalization, cut.plan, invoke}, :open)

    try do
      {result, events} = collect(owned, [])
      join(owned, [:normal, :normal, :normal])
      if release(owned), do: join_release(owned, :normal)
      {result, events}
    after
      cleanup(owned)
    end
  end

  defp strand_proof(cut, prior, member, native) do
    owned = launch(finalization(cut, prior), native)

    try do
      {_id, events} = hold_proof(owned, member, native, 0, [], proof_path(cut, member))
      Process.exit(owned.caller, :kill)
      {result, _events} = collect(owned, events, :terminal)

      assert {:joined,
              {:ok,
               %{restore_result: {:commit_unknown, "inventory_unavailable"}, release_claims: []}},
              evidence} = result

      join(owned, [:killed, :normal, :normal])
      assert evidence.opens == evidence.closes
      {prior_evidence(cut, owned, evidence), evidence}
    after
      cleanup(owned)
    end
  end

  defp strand_first(cut) do
    owned = launch({:restore_first, cut.plan, invocation()}, :restore_phase)

    try do
      {_id, events} = hold_phase(owned, "destination_proofs", [])
      Process.exit(owned.caller, :kill)
      {result, _events} = collect(owned, events, :terminal)
      assert {:joined, _, evidence} = result
      join(owned, [:killed, :normal, :normal])
      assert evidence.opens == evidence.closes
      assert evidence.restore_observation["claim"] == "retained"
      refute File.exists?(proof_path(cut, 1))
      refute File.exists?(proof_path(cut, 2))
      refute File.exists?(proof_path(cut, 3))
      prior_evidence(cut, owned, evidence)
    after
      cleanup(owned)
    end
  end

  defp hold_phase(owned, selected, events) do
    receive do
      {:restore_io, guardian, worker, reference, {:issued, id, {:restore_phase, phase}} = event}
      when guardian == owned.guardian and worker == owned.worker and reference == owned.reference ->
        if phase == selected do
          {id, [{worker, event} | events]}
        else
          send(guardian, {:proceed, reference, id})
          hold_phase(owned, selected, [{worker, event} | events])
        end

      {:restore_io, guardian, worker, reference, event}
      when guardian == owned.guardian and worker == owned.worker and reference == owned.reference ->
        hold_phase(owned, selected, [{worker, event} | events])
    after
      left(owned.cutoff) -> flunk("original installed destination phase unavailable")
    end
  end

  defp hold_proof(owned, selected, native, count, events, path) do
    receive do
      {:restore_io, guardian, worker, reference,
       {:issued, _id, {:restore_retirement_step, "destination", "committed"}} = event}
      when guardian == owned.guardian and worker == owned.worker and reference == owned.reference ->
        hold_proof(owned, selected, native, count + 1, [{worker, event} | events], path)

      {:restore_io, guardian, worker, reference, {:issued, id, kind} = event}
      when guardian == owned.guardian and worker == owned.worker and reference == owned.reference ->
        name = if is_tuple(kind), do: elem(kind, 0), else: kind
        # Concept: a readback cut belongs to an actually published proof.
        # Technical depth: earlier claim/source reads are permitted under the
        # same cutoff. Only the native read following this exact proof's rename
        # and directory-sync may hold the readback control; no signal is forged.
        ready = native != :read or (File.exists?(path) and not File.exists?(path <> ".tmp"))

        if count == selected and name == native and ready do
          {id, [{worker, event} | events]}
        else
          if name == owned.pause, do: send(guardian, {:proceed, reference, id})
          hold_proof(owned, selected, native, count, [{worker, event} | events], path)
        end

      {:restore_io, guardian, worker, reference, event}
      when guardian == owned.guardian and worker == owned.worker and reference == owned.reference ->
        hold_proof(owned, selected, native, count, [{worker, event} | events], path)
    after
      left(owned.cutoff) -> flunk("exact native canonical proof cut unavailable")
    end
  end

  defp hold_release_open(owned, events) do
    receive do
      {:restore_io, guardian, worker, reference, {:terminal_release_installed, _} = event}
      when guardian == owned.guardian and reference == owned.reference ->
        retain_release(owned, worker)
        hold_release_open(owned, [{worker, event} | events])

      {:restore_io, guardian, worker, reference, {:issued, id, kind} = event}
      when guardian == owned.guardian and reference == owned.reference ->
        assert_known_worker(owned, worker)
        name = if is_tuple(kind), do: elem(kind, 0), else: kind

        if release(owned) && worker == elem(release(owned), 0) && name == :open do
          {id, [{worker, event} | events]}
        else
          if name == owned.pause, do: send(guardian, {:proceed, reference, id})
          hold_release_open(owned, [{worker, event} | events])
        end

      {:restore_io, guardian, worker, reference, event}
      when guardian == owned.guardian and reference == owned.reference ->
        assert_known_worker(owned, worker)
        hold_release_open(owned, [{worker, event} | events])

      {:DOWN, monitor, :process, actor, reason} ->
        retain_down(owned, actor, monitor, reason)
        hold_release_open(owned, events)
    after
      left(owned.cutoff) -> flunk("original terminal release IO cut unavailable")
    end
  end

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
          guardian_monitor: Process.monitor(guardian),
          worker: worker,
          worker_monitor: Process.monitor(worker),
          reference: reference,
          cutoff: cutoff + 10_000,
          pause: pause
        }
    after
      10_000 -> flunk("original finalization actors unavailable")
    end
  end

  defp collect(owned, events, wanted \\ :result) do
    receive do
      {:restore_io, guardian, worker, reference, {:terminal_release_installed, _} = event}
      when guardian == owned.guardian and reference == owned.reference ->
        retain_release(owned, worker)
        collect(owned, [{worker, event} | events], wanted)

      {:restore_io, guardian, worker, reference, {:issued, id, kind} = event}
      when guardian == owned.guardian and reference == owned.reference ->
        assert_known_worker(owned, worker)
        name = if is_tuple(kind), do: elem(kind, 0), else: kind
        if name == owned.pause, do: send(guardian, {:proceed, reference, id})
        collect(owned, [{worker, event} | events], wanted)

      {:restore_io, guardian, worker, reference, {:terminal, result} = event}
      when guardian == owned.guardian and reference == owned.reference ->
        assert_known_worker(owned, worker)

        if wanted == :terminal,
          do: {result, Enum.reverse([{worker, event} | events])},
          else: collect(owned, [{worker, event} | events], wanted)

      {:restore_io, guardian, worker, reference, event}
      when guardian == owned.guardian and reference == owned.reference ->
        assert_known_worker(owned, worker)
        collect(owned, [{worker, event} | events], wanted)

      {:result, caller, result} when caller == owned.caller ->
        assert wanted == :result
        {result, Enum.reverse(events)}

      {:DOWN, monitor, :process, actor, reason} ->
        retain_down(owned, actor, monitor, reason)
        collect(owned, events, wanted)
    after
      left(owned.cutoff) -> flunk("original finalization result unavailable")
    end
  end

  # Concept: release-worker evidence belongs to the same original guardian and cutoff.
  # Technical depth: the guardian's installed notification names the actual
  # worker while the selected open barrier keeps it alive. Monitor that exact
  # actor before permitting its first descriptor open; no replacement actor or
  # late noproc monitor can satisfy this terminal-release proof.
  defp retain_release(owned, worker) do
    assert is_nil(release(owned)) and worker != owned.worker and Process.alive?(worker)
    join_actor(owned, owned.worker, owned.worker_monitor, :normal)
    Process.put({__MODULE__, owned.reference, :release}, {worker, Process.monitor(worker)})
  end

  defp release(owned), do: Process.get({__MODULE__, owned.reference, :release})

  defp assert_known_worker(owned, worker) do
    assert worker == owned.worker or (release(owned) && worker == elem(release(owned), 0))
  end

  defp actors(owned),
    do: [
      {owned.caller, owned.caller_monitor},
      {owned.guardian, owned.guardian_monitor},
      {owned.worker, owned.worker_monitor}
    ]

  defp retain_down(owned, actor, monitor, reason) do
    assert {actor, monitor} in (actors(owned) ++
                                  if(release(owned), do: [release(owned)], else: []))

    assert is_nil(Process.get({__MODULE__, monitor, :down}))
    Process.put({__MODULE__, monitor, :down}, reason)
  end

  defp join(owned, reasons) do
    Enum.zip(actors(owned), reasons)
    |> Enum.each(fn {{actor, monitor}, reason} ->
      join_actor(owned, actor, monitor, reason)
    end)
  end

  defp join_release(owned, reason) do
    {actor, monitor} = release(owned)
    join_actor(owned, actor, monitor, reason)
  end

  defp join_actor(owned, actor, monitor, expected) do
    actual =
      Process.get({__MODULE__, monitor, :down}) ||
        receive do
          {:DOWN, ^monitor, :process, ^actor, reason} ->
            Process.put({__MODULE__, monitor, :down}, reason)
            reason
        after
          left(owned.cutoff) -> flunk("original finalization monitor join unavailable")
        end

    assert actual == expected
  end

  defp cleanup(owned) do
    selected = actors(owned) ++ if(release(owned), do: [release(owned)], else: [])

    Enum.each(selected, fn {actor, monitor} ->
      if is_nil(Process.get({__MODULE__, monitor, :down})) do
        Process.exit(actor, :kill)

        receive do
          {:DOWN, ^monitor, :process, ^actor, reason} ->
            Process.put({__MODULE__, monitor, :down}, reason)
        after
          left(owned.cutoff) -> flunk("failure cleanup did not join original finalization actor")
        end
      end
    end)
  end

  defp prior_evidence(cut, owned, evidence) do
    reasons =
      Enum.map(actors(owned), fn {_actor, monitor} ->
        reason = Process.get({__MODULE__, monitor, :down})
        assert not is_nil(reason)
        reason
      end)

    hash(
      :erlang.term_to_binary({claim_owners(cut), evidence.opens, evidence.closes, reasons}, [
        :deterministic
      ])
    )
  end

  defp claim_owners(cut) do
    Enum.map(participating(cut) |> Enum.sort(), fn root ->
      directory = claim_path(root)
      bytes = File.read!(Path.join(directory, "owner"))
      assert {:ok, owner} = RestoreCodec.decode(:claim, bytes)

      {directory, owner, bytes, File.lstat!(directory).inode,
       File.lstat!(Path.join(directory, "owner")).inode}
    end)
  end

  defp participating(cut) do
    if cut.plan["source_status"] == "available",
      do: [cut.source, cut.destination],
      else: [cut.destination]
  end

  # Concept: preserve every original payload's physical identity across proof additions.
  # Technical depth: full native manifests check all added paths, modes and hashes;
  # baseline file byte/inode/link checks remain exact. Directory link counts are
  # outside ADR 0051's directory mode/identity proof because native entry-link
  # contributions vary; no original file or generation comparison is relaxed.
  defp payload_identity(cut) do
    {:ok, entries} = RestoreCodec.manifest(cut.baseline, @total)

    Enum.map(participating(cut), fn root ->
      {root,
       Enum.map(entries, fn entry ->
         path = if entry["path"] == ".", do: root, else: Path.join(root, entry["path"])
         info = File.lstat!(path)
         bytes = if info.type == :regular, do: File.read!(path), else: nil

         {entry["path"], info.type, Bitwise.band(info.mode, 0o7777), info.inode,
          if(info.type == :regular, do: info.links, else: nil), bytes}
       end)}
    end)
  end

  defp generation_bytes(cut) do
    Enum.map(cut.plan["ledgers"], fn ledger ->
      {ledger["relative_root"],
       File.read!(Path.join([cut.destination, ledger["relative_root"], "generation"]))}
    end)
  end

  defp prepare(root, status) do
    source = Path.join(root, "source")
    backup = Path.join(root, "backup")
    destination = Path.join(root, "destination")
    workspace = Path.join(root, "workspace")
    for path <- [source, destination, workspace], do: File.mkdir!(path)

    ledgers =
      for {relative, identity} <- [{"ledger-a", "final-a"}, {"ledger-b", "final-b"}] do
        path = Path.join(source, relative)
        assert {:ok, prepared} = Ledger.prepare(path, identity, 1_000)

        job = %{
          job_id: <<0, 255, relative::binary>>,
          operation_id: "operation-" <> relative,
          attempt: 1,
          canonical_request_digest: hash(relative),
          cleanup_grace_ms: 1_000,
          origin_executor_epoch: 7
        }

        refused = %{job | job_id: "refused-" <> relative, operation_id: "refusal-" <> relative}
        assert {:ok, refusal} = Ledger.refusal(refused, :workspace_lease_lost)

        assert :ok =
                 Ledger.with_claim(prepared, fn claimed ->
                   assert :ok =
                            Ledger.admit(
                              claimed,
                              Ledger.marker(job),
                              Ledger.open_entry(job, identity)
                            )

                   Ledger.refuse(claimed, refusal)
                 end)

        bytes = File.read!(Path.join(path, "generation"))

        %{
          "relative_root" => relative,
          "executor_identity" => identity,
          "source_generation_sha256" => hash(bytes),
          "source_placement" => placement(path)
        }
      end

    File.write!(Path.join(source, "ordinary"), <<0, 255, 1, 254, 2, 0, 128>>)
    assert {:ok, _} = RestoreFixtureCopy.copy(source, backup)
    baseline = manifest(backup)
    {:ok, lineage} = RestoreCodec.lineage_digest([])
    assert {:ok, workspace_ref} = WorkspaceIdentity.reference(workspace)

    plan = %{
      "version" => 1,
      "tx_id" => hash("finalization-original-tx"),
      "source_state_root" => source,
      "source_state_placement" => placement(source),
      "source_status" => status,
      "backup_state_root" => backup,
      "destination_state_root" => destination,
      "manifest_sha256" => hash(baseline),
      "cut_id" => hash("finalization-cut"),
      "prior_restore_count" => 0,
      "prior_lineage_sha256" => lineage,
      "runtime_ids" => [],
      "stores" => [],
      "ledgers" => ledgers,
      "workspace" => %{"root" => workspace, "workspace_ref" => workspace_ref},
      "host_attestation" => %{
        "latest_cut" => true,
        "no_post_cut_activity" => true,
        "all_other_copies_excluded" => true,
        "old_authority_termination" => "joined",
        "host_ledgers_validated" => true,
        "evidence_sha256" => hash("native-finalization-writers")
      }
    }

    if status == "lost", do: File.rm_rf!(source)
    %{plan: plan, source: source, destination: destination, baseline: baseline}
  end

  defp finalization(cut, prior),
    do: {:restore_retained_destination_finalization, cut.plan, invocation("joined", prior)}

  defp invocation(authority \\ "none", evidence \\ nil),
    do:
      Map.merge(@limits, %{
        "max_total_file_bytes" => @total,
        "prior_admin_authority" => authority,
        "prior_admin_evidence_sha256" => evidence
      })

  defp placement(root) do
    stat = File.lstat!(root)
    %{"expanded_root" => root, "major_device" => stat.major_device, "inode" => stat.inode}
  end

  defp manifest(root) do
    assert {:joined, {:ok, bytes}, _} = RestoreIO.run({:manifest, root, @total}, @limits)
    bytes
  end

  defp proof_path(cut, 1),
    do: Path.join(cut.destination, "ledger-a/restore-lineage/00000001/committed")

  defp proof_path(cut, 2),
    do: Path.join(cut.destination, "ledger-b/restore-lineage/00000001/committed")

  defp proof_path(cut, 3),
    do: Path.join(cut.destination, ".loopex-restore/lineage/00000001/committed")

  defp intent_path(cut), do: Path.join(cut.destination, ".loopex-restore/lineage/00000001/intent")

  defp claim_path(root) do
    {:ok, digest} = RestoreCodec.claim_digest(root)
    Path.join(Path.dirname(root), ".loopex-restore-claim-" <> digest)
  end

  defp image(root) do
    {:joined, {:ok, bytes}, _} = RestoreIO.run({:manifest, root, @total}, @limits)
    bytes
  end

  defp left(cutoff), do: max(0, cutoff - System.monotonic_time(:millisecond))
  defp hash(bytes), do: RestoreCodec.digest_bytes(bytes)
end
