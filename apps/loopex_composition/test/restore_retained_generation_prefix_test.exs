Code.require_file("support/restore_fixture_copy.ex", __DIR__)

defmodule LoopexComposition.RestoreRetainedGenerationPrefixTest do
  use ExUnit.Case, async: false

  alias Loopex.Executor.Local.{Ledger, RestoreCodec, RestoreGuard}
  alias LoopexComposition.{Restore, RestoreFixtureCopy, WorkspaceIdentity}
  alias LoopexComposition.Restore.{IO, Workflow}

  @limits %{"work_ms" => 10_000, "cleanup_grace_ms" => 1_000}
  @total 16_777_216

  setup do
    {:ok, temp} = WorkspaceIdentity.resolve_path(System.tmp_dir!())
    Process.put({__MODULE__, :payload_link_profile}, payload_link_profile(temp))

    root =
      Path.join(
        temp,
        "restore-prefix-" <> Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)
      )

    File.mkdir!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  for status <- ~w(available lost), native <- [:file_sync, :rename, :directory_sync] do
    test "actual #{status} second-ledger #{native} interruption reuses both original candidates",
         %{root: root} do
      cut = prepare(root, unquote(status))
      prior = strand_first(cut)
      original = File.read!(intent_path(cut))
      {next_prior, stopped} = strand_candidate(cut, prior, unquote(native))
      {:ok, intent} = RestoreCodec.decode(:intent, original)
      [first, second] = intent["generations"]
      assert File.read!(generation_path(cut, first)) == first["destination_generation_bytes"]

      if unquote(native) == :directory_sync do
        assert File.read!(generation_path(cut, second)) == second["destination_generation_bytes"]
        refute File.exists?(temporary_path(cut, second))
      else
        assert File.read!(generation_path(cut, second)) == second["source_generation_bytes"]
        assert File.read!(temporary_path(cut, second)) == second["destination_generation_bytes"]
      end

      assert stopped.opens == stopped.closes
      owners = claim_owners(cut)
      preserved = payload(cut)
      {result, events, _next_prior} = finish(cut, next_prior)
      assert {:joined, {:ok, value}, evidence} = result
      assert evidence.opens == evidence.closes
      assert value.intent == original
      assert value.activation_manifest == manifest(cut.destination)
      actual = payload(cut)

      assert actual == preserved,
             if(actual == preserved, do: "", else: payload_differences(actual, preserved))

      assert_exact_candidates(cut, original)
      assert_nonce_only(owners, claim_owners(cut))
      assert_no_commit_release(cut, events)
      assert {:pending, _} = Restore.lookup(cut.destination, cut.plan["tx_id"], @limits)
      assert {:error, :restore_incomplete} = RestoreGuard.state(cut.destination)

      for candidate <- intent["generations"] do
        assert {:error, {:ledger_unavailable, :restore_incomplete}} =
                 RestoreGuard.ledger(Path.dirname(generation_path(cut, candidate)))

        refute File.exists?(temporary_path(cut, candidate))
      end

      if unquote(status) == "available" do
        assert {:error, :restore_incomplete} = RestoreGuard.state(cut.source)
      else
        assert File.lstat(cut.source) == {:error, :enoent}
        refute File.exists?(claim_path(cut.source))
      end
    end
  end

  for fault <- [
        :torn_stage,
        :conflicting_stage,
        :wrong_ordinal,
        :missing_generation,
        :missing_retirement,
        :ledger_proof,
        :root_proof,
        :owner,
        :backup,
        :workspace,
        :destination_ledger,
        :source_retirement
      ] do
    test "actual #{fault} prefix refuses before nonce handoff and preserves fault evidence", %{
      root: root
    } do
      cut = prepare(root, "available")
      prior = strand_first(cut)
      {next_prior, _} = strand_candidate(cut, prior, :file_sync)
      install_fault(cut, root, unquote(fault))
      before = image(root)
      owners = claim_owners(cut)
      {result, events, _next_prior} = finish(cut, next_prior)
      assert {:joined, {:error, code}, evidence} = result
      assert code in expected_refusals(unquote(fault))
      assert evidence.opens == evidence.closes
      assert image(root) == before and claim_owners(cut) == owners
      refute Enum.any?(events, &match?({:issued, _, {:restore_claim_handoff, _}}, &1))
      assert_no_commit_release(cut, events, unquote(fault))
    end
  end

  test "lost source reappearance on a genuine staged prefix refuses before nonce", %{root: root} do
    cut = prepare(root, "lost")
    prior = strand_first(cut)
    {next_prior, _} = strand_candidate(cut, prior, :file_sync)
    File.mkdir!(cut.source)
    before = image(root)
    {result, events, _next_prior} = finish(cut, next_prior)
    assert {:joined, {:error, "inventory_unavailable"}, evidence} = result
    assert evidence.opens == evidence.closes and image(root) == before
    refute Enum.any?(events, &match?({:issued, _, {:restore_claim_handoff, _}}, &1))
    assert_no_commit_release(cut, events)
  end

  test "unproved prior owner evidence refuses a new invocation before actor installation", %{
    root: root
  } do
    cut = prepare(root, "available")
    prior = strand_first(cut)
    {_next_prior, _} = strand_candidate(cut, prior, :file_sync)
    before = image(root)

    assert {:error, :invalid_io_request} =
             IO.run({:restore_retained_generation_install, cut.plan, invocation()}, @limits,
               probe: self()
             )

    assert image(root) == before
    assert_no_commit_release(cut, [])
  end

  test "a proof-free zero-ledger completed generation stage re-syncs the original records", %{
    root: root
  } do
    cut = prepare(root, "available", [])
    prior = strand_first(cut)
    {first, _events, next_prior} = finish(cut, prior)
    assert {:joined, {:ok, initial}, initial_evidence} = first
    assert initial_evidence.opens == initial_evidence.closes
    before = image(cut.source) ++ image(cut.destination) ++ image(cut.plan["backup_state_root"])
    {second, events, _} = finish(cut, next_prior)
    assert {:joined, {:ok, repeated}, evidence} = second
    assert evidence.opens == evidence.closes
    assert repeated.intent == initial.intent
    assert repeated.source_retirement == initial.source_retirement
    assert repeated.activation_manifest == initial.activation_manifest

    assert image(cut.source) ++ image(cut.destination) ++ image(cut.plan["backup_state_root"]) ==
             before

    assert_no_commit_release(cut, events)
  end

  test "two-ledger projection normalizes only exact destination original-ordinal candidates", %{
    root: root
  } do
    cut = prepare(root, "available")
    prior = strand_first(cut)
    {_next_prior, stopped} = strand_candidate(cut, prior, :file_sync)
    assert stopped.opens == stopped.closes
    {:ok, intent} = RestoreCodec.decode(:intent, File.read!(intent_path(cut)))
    [_first, second] = intent["generations"]
    assert File.read!(temporary_path(cut, second)) == second["destination_generation_bytes"]
    preserved = payload(cut)
    File.rm!(temporary_path(cut, second))
    assert payload(cut) == preserved

    # Concept: These are physical projection controls using actual retained writer candidates.
    # Technical depth: The real second-ledger cut above supplies the positive staging witness.
    # The following native files exercise both declared placements and source-role rejection;
    # they do not claim that the runtime published each controlled file.
    {:ok, entries} = RestoreCodec.manifest(cut.baseline, @total)

    Enum.each(intent["generations"], fn candidate ->
      generation =
        Enum.find(entries, &(&1["path"] == Path.join(candidate["relative_root"], "generation")))

      assert generation["kind"] == "regular"
      temporary = temporary_path(cut, candidate)
      File.write!(temporary, candidate["destination_generation_bytes"])
      File.chmod!(temporary, generation["mode"])
      assert payload(cut) == preserved
      File.rm!(temporary)
      assert payload(cut) == preserved

      File.write!(temporary, candidate["destination_generation_bytes"])
      File.chmod!(temporary, Bitwise.bxor(generation["mode"], 0o100))
      refute payload(cut) == preserved
      File.rm!(temporary)
      assert payload(cut) == preserved

      File.write!(temporary, "foreign candidate")
      File.chmod!(temporary, generation["mode"])
      refute payload(cut) == preserved
      File.rm!(temporary)

      foreign = generation_path(cut, candidate) <> ".restore-00000002.tmp"
      File.write!(foreign, candidate["destination_generation_bytes"])
      File.chmod!(foreign, generation["mode"])
      refute payload(cut) == preserved
      File.rm!(foreign)

      source = Path.join(cut.source, Path.relative_to(temporary, cut.destination))
      File.write!(source, candidate["destination_generation_bytes"])
      File.chmod!(source, generation["mode"])
      refute payload(cut) == preserved
      File.rm!(source)
      assert payload(cut) == preserved
    end)
  end

  test "two-ledger projection retains unexpected regular entries in every captured role", %{
    root: root
  } do
    cut = prepare(root, "available")
    copy_baseline_payload(cut)
    preserved = payload(cut)

    for selected <- [cut.source, cut.destination],
        relative <- ["." | Enum.map(cut.plan["ledgers"], & &1["relative_root"])] do
      path = Path.join([selected, relative, "unrelated.tmp"])
      File.write!(path, "unrelated")
      refute payload(cut) == preserved
      File.rm!(path)
      assert payload(cut) == preserved
    end
  end

  test "two-ledger projection accounts only for canonical administrative direct directories", %{
    root: root
  } do
    cut = prepare(root, "available")
    copy_baseline_payload(cut)
    preserved = payload(cut)

    for selected <- [cut.source, cut.destination] do
      administrative =
        [
          ".loopex-restore"
          | Enum.map(cut.plan["ledgers"], &Path.join(&1["relative_root"], "restore-lineage"))
        ]

      Enum.each(administrative, fn relative ->
        path = Path.join(selected, relative)
        File.mkdir!(path)
        File.chmod!(path, 0o700)
        assert payload(cut) == preserved
      end)

      for relative <- ["." | Enum.map(cut.plan["ledgers"], & &1["relative_root"])] do
        path = Path.join([selected, relative, "unrelated-directory"])
        File.mkdir!(path)
        refute payload(cut) == preserved
        File.rmdir!(path)
        assert payload(cut) == preserved
      end
    end
  end

  test "two-ledger projection preserves each original regular-file hard-link check", %{
    root: root
  } do
    cut = prepare(root, "available")
    copy_baseline_payload(cut)
    {:ok, entries} = RestoreCodec.manifest(cut.baseline, @total)
    preserved = payload(cut)

    for selected <- [cut.source, cut.destination], ledger <- cut.plan["ledgers"] do
      entry =
        Enum.find(entries, fn entry ->
          entry["kind"] == "regular" and
            String.starts_with?(entry["path"], ledger["relative_root"] <> "/") and
            entry["path"] != Path.join(ledger["relative_root"], "generation")
        end)

      assert not is_nil(entry)
      link = Path.join(root, "payload-hardlink")
      File.ln!(Path.join(selected, entry["path"]), link)
      refute payload(cut) == preserved
      File.rm!(link)
      assert payload(cut) == preserved
    end
  end

  # Concept: fault controls mutate real retained paths, not outcome maps.
  # Technical depth: proof bytes come from the canonical original construction;
  # adding later stages is still outside this prefix unit and must refuse.
  defp install_fault(cut, root, fault) do
    original = File.read!(intent_path(cut))
    {:ok, intent} = RestoreCodec.decode(:intent, original)
    [_first, second] = intent["generations"]
    temporary = temporary_path(cut, second)

    case fault do
      :torn_stage ->
        bytes = File.read!(temporary)
        File.write!(temporary, binary_part(bytes, 0, byte_size(bytes) - 1))

      :conflicting_stage ->
        File.write!(temporary, :binary.copy(<<0>>, byte_size(File.read!(temporary))))

      :wrong_ordinal ->
        File.rename!(temporary, generation_path(cut, second) <> ".restore-00000002.tmp")

      :missing_generation ->
        File.rm!(generation_path(cut, second))

      :missing_retirement ->
        File.rm!(Path.join(cut.destination, ".loopex-restore/lineage/00000001/source-retirement"))

      proof when proof in [:ledger_proof, :root_proof] ->
        files =
          Map.new(intent["generations"], fn candidate ->
            {Path.join(candidate["relative_root"], "generation"),
             candidate["source_generation_bytes"]}
          end)

        assert {:ok, compiled} =
                 Workflow.retained_construction(cut.plan, cut.baseline, original, files, @total)

        if proof == :ledger_proof do
          ledger = Enum.find(compiled.ledgers, &(&1.relative == second["relative_root"]))
          path = Path.join([cut.destination, ledger.directory, "committed"])
          File.write!(path, ledger.committed)
          File.chmod!(path, 0o600)
        else
          path = Path.join(cut.destination, ".loopex-restore/lineage/00000001/committed")
          File.write!(path, compiled.committed)
          File.chmod!(path, 0o600)
        end

      :owner ->
        path = Path.join(claim_path(cut.destination), "owner")
        assert {:ok, owner} = RestoreCodec.decode(:claim, File.read!(path))

        assert {:ok, bytes} =
                 RestoreCodec.encode(:claim, Map.put(owner, "plan_digest", hash("foreign")))

        File.write!(path, bytes)

      :backup ->
        File.write!(Path.join(cut.plan["backup_state_root"], "ordinary"), "changed")

      :workspace ->
        workspace = cut.plan["workspace"]["root"]
        File.rename!(workspace, Path.join(root, "old-workspace"))
        File.mkdir!(workspace)

      :destination_ledger ->
        ledger = Path.dirname(generation_path(cut, second))
        old = Path.join(root, "old-ledger")
        File.rename!(ledger, old)
        assert {:ok, _} = RestoreFixtureCopy.copy(old, ledger)

      :source_retirement ->
        File.rm!(
          Path.join([
            cut.source,
            second["relative_root"],
            "restore-lineage/00000001/source-retired"
          ])
        )
    end
  end

  defp expected_refusals(fault) do
    case fault do
      bad when bad in [:torn_stage, :conflicting_stage] ->
        ["inventory_unavailable"]

      bad when bad in [:wrong_ordinal, :ledger_proof, :backup] ->
        ["inventory_mismatch"]

      :missing_generation ->
        ["administrative_path_unavailable"]

      bad when bad in [:missing_retirement, :root_proof] ->
        ["invalid_current_history"]

      :owner ->
        ["restore_conflict"]

      :workspace ->
        ["invalid_placement"]

      :destination_ledger ->
        ["physical_destination_changed"]

      :source_retirement ->
        ["inventory_mismatch", "invalid_current_history"]
    end
  end

  defp prepare(root, status, members \\ [{"ledger-a", "prefix-a"}, {"ledger-b", "prefix-b"}]) do
    source = Path.join(root, "source")
    backup = Path.join(root, "backup")
    destination = Path.join(root, "destination")
    workspace = Path.join(root, "workspace")
    for path <- [source, destination, workspace], do: File.mkdir!(path)

    ledgers =
      for {relative, identity} <- members do
        path = Path.join(source, relative)
        assert {:ok, prepared} = Ledger.prepare(path, identity, 1_000)
        # Real admission/open and refusal writers provide unsettled metadata;
        # this fixture has no dispatched effect or invented terminal receipt.
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
    {:ok, entries} = RestoreCodec.manifest(baseline, @total)
    {:ok, lineage} = RestoreCodec.lineage_digest([])
    assert not Enum.any?(entries, &String.contains?(&1["path"], "restore-lineage"))
    assert {:ok, workspace_ref} = WorkspaceIdentity.reference(workspace)

    plan = %{
      "version" => 1,
      "tx_id" => hash("prefix-original-tx"),
      "source_state_root" => source,
      "source_state_placement" => placement(source),
      "source_status" => status,
      "backup_state_root" => backup,
      "destination_state_root" => destination,
      "manifest_sha256" => hash(baseline),
      "cut_id" => hash("prefix-cut"),
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
        "evidence_sha256" => hash("native-prefix-writers")
      }
    }

    if status == "lost", do: File.rm_rf!(source)
    %{plan: plan, source: source, destination: destination, baseline: baseline}
  end

  defp strand_first(cut) do
    owned = launch({:restore_first, cut.plan, invocation()}, :restore_phase)

    try do
      {_id, _events} = hold_phase(owned, "source_retirement", [])
      Process.exit(owned.caller, :kill)
      assert {:joined, _, evidence} = terminal(owned)
      join(owned, [:killed, :normal, :normal])
      assert evidence.opens == evidence.closes
      prior(cut, owned, evidence)
    after
      cleanup(owned)
    end
  end

  defp strand_candidate(cut, evidence, native) do
    owned =
      launch(
        {:restore_retained_generation_install, cut.plan, invocation("joined", evidence)},
        native
      )

    try do
      {_id, _events} = hold_second(owned, native, 0, [])
      Process.exit(owned.caller, :kill)
      assert {:joined, {:error, :caller_lost}, stopped} = terminal(owned)
      join(owned, [:killed, :normal, :normal])
      assert stopped.opens == stopped.closes
      {prior(cut, owned, stopped), stopped}
    after
      cleanup(owned)
    end
  end

  defp finish(cut, evidence) do
    owned =
      launch(
        {:restore_retained_generation_install, cut.plan, invocation("joined", evidence)},
        :restore_generation_step
      )

    try do
      {result, events} = collect(owned, [])
      join(owned, [:normal, :normal, :normal])
      assert {:joined, _, cleanup_evidence} = result
      {result, events, prior(cut, owned, cleanup_evidence)}
    after
      cleanup(owned)
    end
  end

  defp hold_phase(owned, selected, events) do
    receive do
      {:restore_io, guardian, worker, reference, {:issued, id, {:restore_phase, phase}} = event}
      when guardian == owned.guardian and worker == owned.worker and reference == owned.reference ->
        if phase == selected do
          {id, [event | events]}
        else
          send(guardian, {:proceed, reference, id})
          hold_phase(owned, selected, [event | events])
        end

      {:restore_io, guardian, worker, reference, event}
      when guardian == owned.guardian and worker == owned.worker and reference == owned.reference ->
        hold_phase(owned, selected, [event | events])
    after
      left(owned.cutoff) -> flunk("exact original retirement cut unavailable")
    end
  end

  defp hold_second(owned, selected, count, events) do
    receive do
      {:restore_io, guardian, worker, reference,
       {:issued, _id, {:restore_generation_step, _}} = event}
      when guardian == owned.guardian and worker == owned.worker and reference == owned.reference ->
        hold_second(owned, selected, count + 1, [event | events])

      {:restore_io, guardian, worker, reference, {:issued, id, kind} = event}
      when guardian == owned.guardian and worker == owned.worker and reference == owned.reference ->
        name = if is_tuple(kind), do: elem(kind, 0), else: kind

        if name == selected and count == 2 do
          {id, [event | events]}
        else
          if name == owned.pause, do: send(guardian, {:proceed, reference, id})
          hold_second(owned, selected, count, [event | events])
        end

      {:restore_io, guardian, worker, reference, event}
      when guardian == owned.guardian and worker == owned.worker and reference == owned.reference ->
        hold_second(owned, selected, count, [event | events])
    after
      left(owned.cutoff) -> flunk("actual second native candidate cut unavailable")
    end
  end

  defp launch(operation, pause) do
    parent = self()

    {caller, monitor} =
      spawn_monitor(fn ->
        send(
          parent,
          {:result, self(), IO.run(operation, @limits, probe: parent, pause_at: pause)}
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
      10_000 -> flunk("original prefix actors unavailable")
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
      left(owned.cutoff) -> flunk("original prefix result unavailable")
    end
  end

  defp terminal(owned) do
    receive do
      {:restore_io, guardian, worker, reference, {:terminal, result}}
      when guardian == owned.guardian and worker == owned.worker and reference == owned.reference ->
        result

      {:restore_io, guardian, worker, reference, _}
      when guardian == owned.guardian and worker == owned.worker and reference == owned.reference ->
        terminal(owned)
    after
      left(owned.cutoff) -> flunk("original stopped prefix terminal unavailable")
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
    |> Enum.each(fn {{actor, monitor}, expected} ->
      receive do
        {:DOWN, ^monitor, :process, ^actor, reason} ->
          Process.put({:prefix_down, monitor}, reason)
          assert reason == expected
      after
        left(owned.cutoff) -> flunk("original prefix actor join unavailable")
      end
    end)
  end

  defp cleanup(owned) do
    Enum.each(actors(owned), fn {actor, monitor} ->
      if is_nil(Process.get({:prefix_down, monitor})) do
        Process.exit(actor, :kill)

        receive do
          {:DOWN, ^monitor, :process, ^actor, reason} ->
            Process.put({:prefix_down, monitor}, reason)
        after
          left(owned.cutoff) -> flunk("original prefix failure cleanup join unavailable")
        end
      end
    end)
  end

  defp prior(cut, owned, evidence) do
    reasons =
      Enum.map(actors(owned), fn {_actor, monitor} ->
        reason = Process.get({:prefix_down, monitor})
        assert not is_nil(reason)
        reason
      end)

    hash(
      :erlang.term_to_binary({claim_owners(cut), evidence.opens, evidence.closes, reasons}, [
        :deterministic
      ])
    )
  end

  defp assert_exact_candidates(cut, original) do
    assert File.read!(intent_path(cut)) == original
    {:ok, intent} = RestoreCodec.decode(:intent, original)

    Enum.each(intent["generations"], fn candidate ->
      assert File.read!(generation_path(cut, candidate)) ==
               candidate["destination_generation_bytes"]

      {:ok, old} = RestoreCodec.decode(:generation, candidate["source_generation_bytes"])
      {:ok, current} = RestoreCodec.decode(:generation, candidate["destination_generation_bytes"])
      refute old["executor_epoch"] == current["executor_epoch"]

      if cut.plan["source_status"] == "available" do
        assert File.read!(Path.join([cut.source, candidate["relative_root"], "generation"])) ==
                 candidate["source_generation_bytes"]
      end
    end)
  end

  defp assert_no_commit_release(cut, events, fault \\ nil) do
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

    if fault != :root_proof,
      do:
        refute(
          File.exists?(Path.join(cut.destination, ".loopex-restore/lineage/00000001/committed"))
        )

    if fault != :ledger_proof do
      for declaration <- cut.plan["ledgers"] do
        refute File.exists?(
                 Path.join([
                   cut.destination,
                   declaration["relative_root"],
                   "restore-lineage/00000001/committed"
                 ])
               )
      end
    end
  end

  defp claim_owners(cut) do
    roots =
      if cut.plan["source_status"] == "available",
        do: [cut.source, cut.destination],
        else: [cut.destination]

    Enum.sort(roots)
    |> Enum.map(fn root ->
      bytes = File.read!(Path.join(claim_path(root), "owner"))
      assert {:ok, owner} = RestoreCodec.decode(:claim, bytes)
      {root, bytes, owner}
    end)
  end

  defp assert_nonce_only(before, current) do
    Enum.zip(before, current)
    |> Enum.each(fn {{root, _, old}, {same_root, bytes, owner}} ->
      assert root == same_root
      assert Map.delete(old, "claim_nonce") == Map.delete(owner, "claim_nonce")
      refute old["claim_nonce"] == owner["claim_nonce"]
      assert File.read!(Path.join(claim_path(root), "owner")) == bytes
    end)
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

  defp payload(cut) do
    {:ok, entries} = RestoreCodec.manifest(cut.baseline, @total)

    roots =
      if cut.plan["source_status"] == "available",
        do: [cut.source, cut.destination],
        else: [cut.destination]

    generations = MapSet.new(cut.plan["ledgers"], &Path.join(&1["relative_root"], "generation"))

    Enum.map(roots, fn root ->
      selected =
        Enum.reject(
          entries,
          &(root == cut.destination and MapSet.member?(generations, &1["path"]))
        )

      {root,
       Enum.map(selected, fn entry ->
         path = if entry["path"] == ".", do: root, else: Path.join(root, entry["path"])
         info = File.lstat!(path)

         {entry["path"], info.type, Bitwise.band(info.mode, 0o7777),
          payload_links(cut, entries, root, entry, info), info.inode,
          if(info.type == :regular, do: File.read!(path), else: nil)}
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
            Enum.find(entries, &(&1["path"] == Path.join(candidate["relative_root"], "generation")))

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

  # Concept: Failure diagnostics identify the original payload entry and changed fields.
  # Technical depth: This runs only after complete equality fails. Original byte comparisons
  # remain exact; diagnostics retain byte sizes/digests and at most sixteen entry differences,
  # with bounded inspect output. Unprinted entries/tails remain unavailable, not accepted.
  defp payload_differences(actual, expected) do
    indexed = fn payload ->
      Map.new(
        Enum.flat_map(payload, fn {root, entries} ->
          Enum.map(entries, &{{root, elem(&1, 0)}, &1})
        end)
      )
    end

    actual = indexed.(actual)
    expected = indexed.(expected)
    keys = Map.keys(actual) ++ Map.keys(expected)

    differences =
      keys
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.reject(&(actual[&1] == expected[&1]))

    rows =
      differences
      |> Enum.take(16)
      |> Enum.map(fn key ->
        describe = fn
          nil ->
            nil

          row ->
            row
            |> Tuple.to_list()
            |> Enum.zip([:path, :type, :mode, :links, :inode, :bytes])
            |> Map.new(fn
              {bytes, :bytes} when is_binary(bytes) ->
                {:bytes, %{size: byte_size(bytes), sha256: hash(bytes)}}

              {value, field} ->
                {field, value}
            end)
        end

        {key, %{expected: describe.(expected[key]), actual: describe.(actual[key])}}
      end)

    "payload differences: #{length(differences)} entries; first sixteen only; " <>
      inspect(rows, limit: 128, printable_limit: 1_024, width: 120) <>
      "; omitted tails unavailable"
  end

  defp image(root), do: image(root, ".")

  defp image(root, relative) do
    path = if relative == ".", do: root, else: Path.join(root, relative)
    info = File.lstat!(path)

    row =
      {relative, info.type, Bitwise.band(info.mode, 0o7777), info.size, info.links, info.inode,
       if(info.type == :regular, do: File.read!(path), else: nil)}

    if info.type == :directory do
      [
        row
        | Enum.flat_map(Enum.sort(File.ls!(path)), fn name ->
            image(root, if(relative == ".", do: name, else: Path.join(relative, name)))
          end)
      ]
    else
      [row]
    end
  end

  defp generation_path(cut, candidate),
    do: Path.join([cut.destination, candidate["relative_root"], "generation"])

  defp temporary_path(cut, candidate),
    do: generation_path(cut, candidate) <> ".restore-00000001.tmp"

  defp intent_path(cut), do: Path.join(cut.destination, ".loopex-restore/lineage/00000001/intent")

  defp claim_path(root) do
    {:ok, digest} = RestoreCodec.claim_digest(root)
    Path.join(Path.dirname(root), ".loopex-restore-claim-" <> digest)
  end

  defp invocation(authority \\ "none", evidence \\ nil),
    do:
      Map.merge(@limits, %{
        "max_total_file_bytes" => @total,
        "prior_admin_authority" => authority,
        "prior_admin_evidence_sha256" => evidence
      })

  defp placement(root) do
    info = File.lstat!(root)
    %{"expanded_root" => root, "major_device" => info.major_device, "inode" => info.inode}
  end

  defp manifest(root) do
    assert {:joined, {:ok, bytes}, _} = IO.run({:manifest, root, @total}, @limits)
    bytes
  end

  defp left(cutoff), do: max(0, cutoff - System.monotonic_time(:millisecond))
  defp hash(bytes), do: RestoreCodec.digest_bytes(bytes)
end
