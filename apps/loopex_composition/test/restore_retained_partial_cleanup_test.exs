Code.require_file("support/restore_fixture_copy.ex", __DIR__)

defmodule LoopexComposition.RestoreRetainedPartialCleanupTest do
  use ExUnit.Case, async: false

  alias Loopex.Executor.Local.{Ledger, RestoreCodec, RestoreGuard}
  alias LoopexComposition.{Restore, WorkspaceIdentity}
  alias LoopexComposition.RestoreFixtureCopy
  alias LoopexComposition.Restore.IO, as: RestoreIO

  @limits %{"work_ms" => 10_000, "cleanup_grace_ms" => 1_000}
  @total 16_777_216

  setup do
    {:ok, temp} = WorkspaceIdentity.resolve_path(System.tmp_dir!())
    root = Path.join(temp, "restore-partial-" <> Base.encode16(:crypto.strong_rand_bytes(12)))
    File.mkdir!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  for {status, removed} <- [{"available", 1}, {"available", 2}, {"lost", 1}],
      authority <- ~w(joined host_rebooted) do
    test "actual #{status} #{removed}-directory prior deletion with #{authority} syncs every claim obligation",
         %{root: root} do
      cut = prepare(root, unquote(status))
      prior = strand_release(cut, unquote(removed))
      assert length(absent_claims(cut)) == unquote(removed)
      payload = payload_identity(cut)
      original = File.read!(intent_path(cut))
      committed = File.read!(proof_path(cut, 3))
      backup = manifest(cut.plan["backup_state_root"])
      owners = present_owners(cut)
      {result, events} = finish(cut, invocation(unquote(authority), prior))

      assert {:joined, {:ok, %{restore_result: {:committed, receipt}, release_claims: []}},
              evidence} = result

      assert evidence.opens == evidence.closes and evidence.claim_count == 0
      assert evidence.stop == :complete and evidence.restore_observation["claim"] == "none"
      assert evidence.restore_observation["phase"] == "claim_release"
      assert payload_identity(cut) == payload
      assert File.read!(intent_path(cut)) == original
      assert File.read!(proof_path(cut, 3)) == committed
      assert manifest(cut.plan["backup_state_root"]) == backup
      assert_complete(cut, receipt, original)
      terminal = terminal_events(events)

      [installed_cutoff] =
        for {_worker, {:terminal_release_installed, cutoff}} <- events, do: cutoff

      [original_cutoff] = for {_worker, {:stopping, :complete, _at, cutoff}} <- events, do: cutoff
      assert installed_cutoff == original_cutoff

      released =
        for {_, {:acknowledged, _, {:restore_claim_released, path}, :completed}} <- terminal,
            do: path

      expected =
        participating(cut)
        |> Enum.map(&claim_path/1)
        |> Enum.sort_by(&(&1 == claim_path(cut.destination)))

      assert released == expected

      assert Enum.count(terminal, fn {_worker, event} ->
               match?({:acknowledged, _, :directory_sync, :completed}, event)
             end) == length(participating(cut)) + map_size(owners)

      refute Enum.any?(events, fn {_worker, event} ->
               match?({:issued, _, {:restore_claim_create, _}}, event) or
                 match?({:issued, _, {:restore_claim_handoff, _}}, event)
             end)

      refute Enum.any?(terminal, fn
               {_worker, {:issued, _, kind}} -> kind in [:rename, :write, :file_sync]
               _ -> false
             end)
    end
  end

  for when_reappears <- [:before_sync, :after_sync] do
    test "a wholly absent claim reappearing #{when_reappears} cannot clear original uncertainty",
         %{root: root} do
      cut = prepare(root, "available")
      prior = strand_release(cut, 2)
      original = payload_identity(cut)
      owned = launch(cleanup_operation(cut, prior), :retained_publication_recheck)

      try do
        {id, events} =
          hold_terminal(
            owned,
            :retained_publication_recheck,
            fn events ->
              unquote(when_reappears) == :before_sync or
                Enum.any?(events, fn {_worker, event} ->
                  match?({:acknowledged, _, :directory_sync, :completed}, event)
                end)
            end,
            []
          )

        path = claim_path(cut.source)
        File.mkdir!(path)
        File.chmod!(path, 0o700)
        send(owned.guardian, {:proceed, owned.reference, id})
        {result, _events} = collect(owned, events)
        assert {:joined, {:error, :restore_commit_unknown}, evidence} = result
        assert evidence.opens == evidence.closes
        join(owned, [:normal, :normal, :normal])
        join_release(owned, :normal)
        assert File.lstat!(path).type == :directory and File.ls!(path) == []
        assert payload_identity(cut) == original
      after
        cleanup(owned)
      end
    end
  end

  test "replacement of the captured parent at its original native sync boundary refuses receipt",
       %{root: root} do
    cut = prepare(root, "available")
    prior = strand_release(cut, 2)
    payload = payload_identity(cut)
    owned = launch(cleanup_operation(cut, prior), :directory_sync)
    retained = root <> ".retained"

    try do
      {id, events} = hold_terminal(owned, :directory_sync, fn _ -> true end, [])
      File.rename!(root, retained)
      File.mkdir!(root)
      send(owned.guardian, {:proceed, owned.reference, id})
      {result, _events} = collect(owned, events)
      assert {:joined, {:error, :restore_commit_unknown}, evidence} = result
      assert evidence.opens == evidence.closes
      join(owned, [:normal, :normal, :normal])
      join_release(owned, :normal)
    after
      cleanup(owned)

      if File.exists?(retained) do
        File.rm_rf!(root)
        File.rename!(retained, root)
      end
    end

    assert payload_identity(cut) == payload
  end

  for {native, actor} <- [
        {:claim_delete, :guardian},
        {:claim_directory_delete, :guardian},
        {:directory_sync, :guardian},
        {:open, :release},
        {:open, :caller}
      ] do
    test "actual terminal #{native} #{actor} loss keeps cleanup uncertain within original cutoffs",
         %{root: root} do
      cut = prepare(root, "available")
      prior = strand_release(cut, 1)
      original = File.read!(intent_path(cut))
      owned = launch(cleanup_operation(cut, prior), unquote(native))

      try do
        {_id, events} = hold_terminal(owned, unquote(native), fn _ -> true end, [])

        target =
          case unquote(actor) do
            :guardian -> owned.guardian
            :release -> elem(release(owned), 0)
            :caller -> owned.caller
          end

        Process.exit(target, :kill)

        {result, result_events} =
          collect(owned, events, if(unquote(actor) == :caller, do: :terminal, else: :result))

        assert {:unconfirmed, _reason, %{restore_observation: observation}} = result
        assert observation["intent"] == "validated" and observation["cleanup"] == "unconfirmed"

        join(
          owned,
          if(unquote(actor) == :caller,
            do: [:killed, :normal, :normal],
            else:
              if(unquote(actor) == :guardian,
                do: [:normal, :killed, :normal],
                else: [:normal, :normal, :normal]
              )
          )
        )

        join_release(owned, :killed)
        assert File.read!(intent_path(cut)) == original

        if unquote(native) == :claim_directory_delete do
          exact_joins =
            Enum.map(actors(owned) ++ [release(owned)], fn {actor, monitor} ->
              {actor, Process.get({__MODULE__, monitor, :down})}
            end)

          assert Enum.all?(exact_joins, fn {_actor, reason} -> not is_nil(reason) end)

          evidence =
            hash(
              :erlang.term_to_binary({cut.plan["tx_id"], result_events, exact_joins}, [
                :deterministic
              ])
            )

          {next, after_events} = finish(cut, invocation("host_rebooted", evidence))

          assert {:joined, {:ok, %{restore_result: {:commit_unknown, "restore_conflict"}}}, _} =
                   next

          refute Enum.any?(after_events, fn {_worker, event} ->
                   match?({:terminal_release_installed, _}, event)
                 end)
        end
      after
        cleanup(owned)
      end
    end
  end

  for fault <- [
        :empty_claim,
        :ownerless_claim,
        :wrong_owner,
        :missing_ledger_proof,
        :root_proof,
        :backup,
        :ordinary,
        :workspace,
        :plan,
        :lost_source
      ] do
    test "post-commit #{fault} refuses without altering retained payload or releasing claims", %{
      root: root
    } do
      status = if unquote(fault) == :lost_source, do: "lost", else: "available"
      cut = prepare(root, status)
      prior = strand_release(cut, 1)
      supplied = install_fault(cut, unquote(fault))
      before = image(root)
      {result, events} = finish(%{cut | plan: supplied}, invocation("joined", prior))

      assert {:joined, {:ok, %{restore_result: {:commit_unknown, _}, release_claims: []}},
              evidence} = result

      assert evidence.opens == evidence.closes and image(root) == before

      refute Enum.any?(events, fn {_worker, event} ->
               match?({:terminal_release_installed, _}, event) or
                 match?({:issued, _, {:restore_claim_create, _}}, event)
             end)
    end
  end

  test "all-absent cleanup still requires independently retained prior administrator termination",
       %{root: root} do
    cut = prepare(root, "available")
    _prior = strand_release(cut, 2)
    before = image(root)

    assert {:error, :invalid_io_request} =
             RestoreIO.run({:restore_retained_claim_cleanup, cut.plan, invocation()}, @limits,
               probe: self()
             )

    assert image(root) == before
    refute_receive {:restore_io, _, _, _, {:installed, _, _}}, 0
  end

  defp cleanup_operation(cut, prior),
    do: {:restore_retained_claim_cleanup, cut.plan, invocation("joined", prior)}

  defp finish(cut, invoke) do
    owned = launch({:restore_retained_claim_cleanup, cut.plan, invoke}, :open)

    try do
      {result, events} = collect(owned, [])
      join(owned, [:normal, :normal, :normal])
      if release(owned), do: join_release(owned, :normal)
      {result, events}
    after
      cleanup(owned)
    end
  end

  # Concept: prior absence comes from the actual original terminal deletion path.
  # Technical depth: pause before its next parent descriptor opens, prove every
  # earlier descriptor closed, then join the exact actors. Retained host evidence
  # names this cut and independently covers prior administrative exclusion.
  defp strand_release(cut, removed) do
    owned = launch({:restore_first, cut.plan, invocation()}, :open)

    try do
      {_id, events} =
        hold_terminal(owned, :open, fn _ -> length(absent_claims(cut)) == removed end, [])

      assert File.lstat!(proof_path(cut, 3)).type == :regular
      opened = for {_worker, {:acknowledged, _, {:open, token}, :opened}} <- events, do: token
      closed = for {_worker, {:acknowledged, _, {:close, token}, :closed}} <- events, do: token
      assert Enum.sort(opened) == Enum.sort(closed)

      assert Enum.count(events, fn {_worker, event} ->
               match?({:acknowledged, _, :claim_directory_delete, :completed}, event)
             end) == removed

      Process.exit(owned.guardian, :kill)
      {result, _events} = collect(owned, events)
      assert {:unconfirmed, :guardian_lost, %{restore_observation: observation}} = result
      assert observation["intent"] == "validated"
      join(owned, [:normal, :killed, :normal])
      join_release(owned, :killed)

      hash(
        :erlang.term_to_binary(
          {cut.plan["tx_id"], removed, opened, closed, [:normal, :killed, :normal, :killed]},
          [:deterministic]
        )
      )
    after
      cleanup(owned)
    end
  end

  defp hold_terminal(owned, native, ready, events) do
    receive do
      {:restore_io, guardian, worker, reference, {:terminal_release_installed, _} = event}
      when guardian == owned.guardian and reference == owned.reference ->
        retain_release(owned, worker)
        hold_terminal(owned, native, ready, [{worker, event} | events])

      {:restore_io, guardian, worker, reference, {:issued, id, kind} = event}
      when guardian == owned.guardian and reference == owned.reference ->
        assert_known_worker(owned, worker)
        name = if is_tuple(kind), do: elem(kind, 0), else: kind

        if release(owned) && worker == elem(release(owned), 0) && name == native && ready.(events) do
          {id, [{worker, event} | events]}
        else
          if name == owned.pause, do: send(guardian, {:proceed, reference, id})
          hold_terminal(owned, native, ready, [{worker, event} | events])
        end

      {:restore_io, guardian, worker, reference, event}
      when guardian == owned.guardian and reference == owned.reference ->
        assert_known_worker(owned, worker)
        hold_terminal(owned, native, ready, [{worker, event} | events])

      {:DOWN, monitor, :process, actor, reason} ->
        retain_down(owned, actor, monitor, reason)
        hold_terminal(owned, native, ready, events)
    after
      left(owned.cutoff) -> flunk("original terminal claim boundary unavailable")
    end
  end

  defp terminal_events(events) do
    at =
      Enum.find_index(events, fn {_worker, event} ->
        match?({:terminal_release_installed, _}, event)
      end)

    assert is_integer(at)
    Enum.drop(events, at)
  end

  defp absent_claims(cut),
    do: Enum.filter(participating(cut), &(File.lstat(claim_path(&1)) == {:error, :enoent}))

  defp present_owners(cut) do
    Map.new(participating(cut) -- absent_claims(cut), fn root ->
      owner = Path.join(claim_path(root), "owner")
      {root, {File.read!(owner), File.lstat!(owner)}}
    end)
  end

  # Concept: fault placement follows the original joined release, not path ordering.
  # Technical depth: exactly one native absence and one canonical intact owner
  # identify the targets after strand_release has joined every original actor.
  defp joined_partial_claims(cut) do
    [absent] = absent_claims(cut)
    [{intact, {bytes, info}}] = Map.to_list(present_owners(cut))
    assert {:error, :enoent} = File.lstat(claim_path(absent))
    assert File.lstat!(claim_path(intact)).type == :directory
    assert info.type == :regular and info.links == 1
    assert Bitwise.band(info.mode, 0o7777) == 0o600
    {:ok, owner} = RestoreCodec.decode(:claim, bytes)
    assert {:ok, ^bytes} = RestoreCodec.encode(:claim, owner)
    {:ok, digest} = RestoreCodec.plan_digest(cut.plan)
    assert owner["tx_id"] == cut.plan["tx_id"] and owner["plan_digest"] == digest
    assert owner["state_root"] == intact
    assert owner["role"] == if(intact == cut.source, do: "source", else: "destination")
    {absent, intact, owner}
  end

  defp install_fault(cut, fault) do
    case fault do
      :empty_claim ->
        {absent, _intact, _owner} = joined_partial_claims(cut)
        File.mkdir!(claim_path(absent))
        File.chmod!(claim_path(absent), 0o700)

      :ownerless_claim ->
        {_absent, intact, _owner} = joined_partial_claims(cut)
        File.rm!(Path.join(claim_path(intact), "owner"))

      :wrong_owner ->
        {_absent, intact, owner} = joined_partial_claims(cut)
        opposite = if owner["role"] == "source", do: "destination", else: "source"
        {:ok, bytes} = RestoreCodec.encode(:claim, %{owner | "role" => opposite})
        File.write!(Path.join(claim_path(intact), "owner"), bytes)

      :missing_ledger_proof ->
        File.rm!(proof_path(cut, 1))

      :root_proof ->
        File.write!(proof_path(cut, 3), "torn current root proof")

      :backup ->
        File.write!(Path.join(cut.plan["backup_state_root"], "ordinary"), "changed backup")

      :ordinary ->
        File.write!(Path.join(cut.destination, "ordinary"), "changed current payload")

      :workspace ->
        path = cut.plan["workspace"]["root"]
        File.rename!(path, path <> ".retained")
        File.mkdir!(path)

      :plan ->
        :ok

      :lost_source ->
        File.mkdir!(cut.source)
    end

    if fault == :plan,
      do: Map.put(cut.plan, "cut_id", hash("different retained plan")),
      else: cut.plan
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
      10_000 -> flunk("original partial cleanup actors unavailable")
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
      left(owned.cutoff) -> flunk("original partial cleanup result unavailable")
    end
  end

  # Concept: release-worker evidence belongs to the same original guardian and cutoff.
  # Technical depth: the guardian's installed notification names the actual
  # worker while the selected native barrier keeps it alive. Monitor that exact
  # actor before permitting the selected native operation; no replacement actor or
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
          left(owned.cutoff) -> flunk("original partial cleanup monitor join unavailable")
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
          left(owned.cutoff) ->
            flunk("failure cleanup did not join original partial cleanup actor")
        end
      end
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
      "tx_id" => hash("partial-cleanup-original-tx"),
      "source_state_root" => source,
      "source_state_placement" => placement(source),
      "source_status" => status,
      "backup_state_root" => backup,
      "destination_state_root" => destination,
      "manifest_sha256" => hash(baseline),
      "cut_id" => hash("partial-cleanup-cut"),
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
        "evidence_sha256" => hash("native-partial-cleanup-writers")
      }
    }

    if status == "lost", do: File.rm_rf!(source)
    %{plan: plan, source: source, destination: destination, baseline: baseline}
  end

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
