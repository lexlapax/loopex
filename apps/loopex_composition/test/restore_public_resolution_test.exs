Code.require_file("support/restore_fixture_copy.ex", __DIR__)

defmodule LoopexComposition.RestorePublicResolutionTest do
  use ExUnit.Case, async: false

  alias Loopex.Executor.Local.{Ledger, RestoreCodec, RestoreGuard}
  alias LoopexComposition.{Restore, WorkspaceIdentity}
  alias LoopexComposition.RestoreFixtureCopy
  alias LoopexComposition.Restore.IO, as: RestoreIO

  @limits %{"work_ms" => 10_000, "cleanup_grace_ms" => 1_000}
  @total 16_777_216

  setup do
    {:ok, temp} = WorkspaceIdentity.resolve_path(System.tmp_dir!())
    root = Path.join(temp, "restore-public-" <> Base.encode16(:crypto.strong_rand_bytes(12)))
    File.mkdir!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  for status <- ~w(available lost) do
    test "public #{status} restore retains unknown effects and permits an ordinary guarded reopen",
         %{root: root} do
      cut = prepare(root, unquote(status))
      {:committed, receipt} = Restore.restore(cut.plan, invocation())
      assert_complete(cut, receipt)

      for declaration <- cut.plan["ledgers"] do
        path = Path.join(cut.destination, declaration["relative_root"])
        assert {:ok, _prepared} = Ledger.prepare(path, declaration["executor_identity"], 1_000)
        assert length(File.ls!(Path.join(path, "open"))) == 1
        assert length(File.ls!(Path.join(path, "markers"))) == 2

        for plane <- ["markers", "open"], name <- File.ls!(Path.join(path, plane)) do
          original =
            Path.join([cut.plan["backup_state_root"], declaration["relative_root"], plane, name])

          assert File.read!(Path.join([path, plane, name])) == File.read!(original)
        end
      end

      assert manifest(cut.plan["backup_state_root"]) == cut.baseline
    end
  end

  for status <- ~w(available lost),
      authority <- ~w(joined host_rebooted),
      phase <-
        ~w(destination_intent source_retirement destination_generations destination_proofs claim_release) do
    test "public #{status} #{authority} resolution continues the original #{phase} cut", %{
      root: root
    } do
      cut = prepare(root, unquote(status))

      prior =
        strand(cut, :restore_phase, fn kind, _events ->
          kind == {:restore_phase, unquote(phase)}
        end)

      original = File.read(intent_path(cut))
      {:committed, receipt} = Restore.restore(cut.plan, invocation(unquote(authority), prior))
      assert_complete(cut, receipt)
      if match?({:ok, _}, original), do: assert(File.read(intent_path(cut)) == original)
      assert manifest(cut.plan["backup_state_root"]) == cut.baseline
    end
  end

  for status <- ~w(available lost),
      authority <- ~w(joined host_rebooted),
      member <- [:intent, :generation, :ledger_proof, :root_proof] do
    test "public #{status} #{authority} resolution reuses the actual #{member} native temporary",
         %{root: root} do
      cut = prepare(root, unquote(status))
      path = temporary_path(cut, unquote(member))

      prior =
        strand(cut, :file_sync, fn kind, _events ->
          kind == :file_sync and File.exists?(path)
        end)

      assert File.lstat!(path).type == :regular

      original =
        if unquote(member) == :intent, do: File.read!(path), else: File.read!(intent_path(cut))

      {:committed, receipt} = Restore.restore(cut.plan, invocation(unquote(authority), prior))
      assert File.read!(intent_path(cut)) == original
      refute File.exists?(path)
      assert_complete(cut, receipt)
    end
  end

  for status <- ~w(available lost) do
    test "public #{status} partial pre-intent staging is refused without candidate allocation", %{
      root: root
    } do
      cut = prepare(root, unquote(status))

      prior =
        strand(cut, :restore_phase, fn kind, _events ->
          kind == {:restore_phase, "destination_intent"}
        end)

      File.rm!(Path.join(cut.destination, "ordinary"))
      before = manifest(cut.destination)
      assert {:not_committed, refusal} = Restore.restore(cut.plan, invocation("joined", prior))
      assert refusal["code"] == "inventory_mismatch" and refusal["claim"] == "retained"
      assert {:ok, _} = RestoreCodec.encode(:refusal, refusal)
      assert manifest(cut.destination) == before
      refute File.exists?(intent_path(cut))
      assert File.exists?(claim_path(cut.destination))
    end
  end

  for {status, removed} <- [{"available", 1}, {"available", 2}, {"lost", 1}],
      authority <- ~w(joined host_rebooted) do
    test "public #{status} #{authority} resolution syncs #{removed} actually absent claims", %{
      root: root
    } do
      cut = prepare(root, unquote(status))
      prior = strand_release(cut, unquote(removed))
      original = File.read!(intent_path(cut))
      assert length(absent_claims(cut)) == unquote(removed)
      {:committed, receipt} = Restore.restore(cut.plan, invocation(unquote(authority), prior))
      assert File.read!(intent_path(cut)) == original
      assert_complete(cut, receipt)
    end
  end

  for status <- ~w(available lost) do
    test "public #{status} acknowledged duplicate needs neither old source nor backup", %{
      root: root
    } do
      cut = prepare(root, unquote(status))
      {:committed, receipt} = Restore.restore(cut.plan, invocation())
      File.rm_rf!(cut.source)
      File.rm_rf!(cut.plan["backup_state_root"])
      before = manifest(cut.destination)
      assert {:committed, ^receipt} = Restore.restore(cut.plan, invocation())
      assert manifest(cut.destination) == before
    end
  end

  test "public historical duplicate validates lineage without opening old source or backup", %{
    root: root
  } do
    cut = prepare(root, "available")
    {:committed, original} = Restore.restore(cut.plan, invocation())
    next = next_cut(cut)
    {:committed, _} = Restore.restore(next.plan, invocation())
    File.rm_rf!(cut.source)
    File.rm_rf!(cut.plan["backup_state_root"])
    File.rm_rf!(next.plan["backup_state_root"])

    assert {:committed, ^original} =
             Restore.restore(cut.plan, invocation("joined", hash("joined-old-admin")))

    assert {:committed, %{"receipt" => ^original, "view" => "historical"}} =
             Restore.lookup(next.destination, cut.plan["tx_id"], @limits)
  end

  for fault <- [
        :changed_plan,
        :foreign_owner,
        :ownerless_claim,
        :torn_intent,
        :missing_intent,
        :missing_candidate,
        :bad_namespace,
        :changed_workspace,
        :changed_source
      ] do
    test "public original-tx #{fault} retains uncertainty and cannot publish replacement candidates",
         %{root: root} do
      cut = prepare(root, "available")

      prior =
        strand(cut, :restore_phase, fn kind, _events ->
          kind == {:restore_phase, "destination_proofs"}
        end)

      supplied = install_fault(cut, unquote(fault))
      before = manifest(root)

      assert {:commit_unknown, observation} =
               Restore.restore(supplied, invocation("joined", prior))

      assert observation["cleanup"] == "joined" and observation["claim"] == "retained"
      assert {:ok, _} = RestoreCodec.encode(:observation, observation)
      assert manifest(root) == before
      refute File.exists?(proof_path(cut, 3))
    end
  end

  test "public validation refuses invalid grammar and checked duration overflow before IO", %{
    root: root
  } do
    cut = prepare(root, "available")

    for {plan, invoke} <- [
          {Map.put(cut.plan, "extra", true), invocation()},
          {%{cut.plan | "tx_id" => "invalid"}, invocation()},
          {cut.plan, Map.put(invocation(), "work_ms", 18_446_744_073_709_551_615)},
          {cut.plan, Map.put(invocation(), "prior_admin_authority", "joined")}
        ] do
      assert {:not_committed, refusal} = Restore.restore(plan, invoke)
      assert refusal["code"] == "invalid_plan" and refusal["claim"] == "none"
      assert {:ok, _} = RestoreCodec.encode(:refusal, refusal)
    end

    assert File.ls!(cut.destination) == []
    for path <- participating(cut), do: refute(File.exists?(claim_path(path)))
  end

  test "public transition 65 refuses before any claim or physical staging", %{root: root} do
    cut = prepare(root, "available")
    plan = %{cut.plan | "prior_restore_count" => 64}
    before = manifest(root)
    assert {:not_committed, refusal} = Restore.restore(plan, invocation())
    assert refusal["code"] == "inventory_limit_exceeded" and refusal["claim"] == "none"
    assert manifest(root) == before
  end

  for member <- ["objects.lock", "objects.writer", "opaque"] do
    test "public helper #{member} namespace remains fenced until semantic audit exists", %{
      root: root
    } do
      cut = prepare(root, "available")

      for state_root <- [cut.source, cut.plan["backup_state_root"]] do
        File.mkdir!(Path.join(state_root, "delegation"))
        File.write!(Path.join([state_root, "delegation", unquote(member)]), "opaque")
      end

      baseline = manifest(cut.plan["backup_state_root"])
      plan = %{cut.plan | "manifest_sha256" => hash(baseline)}
      assert {:not_committed, refusal} = Restore.restore(plan, invocation())
      assert refusal["code"] == "invalid_current_history"
      assert File.ls!(cut.destination) == []
      for path <- participating(cut), do: refute(File.exists?(claim_path(path)))
    end
  end

  test "the original driver installs one payload owner and one cutoff through all resumed stages",
       %{root: root} do
    cut = prepare(root, "available")

    prior =
      strand(cut, :restore_phase, fn kind, _events ->
        kind == {:restore_phase, "source_retirement"}
      end)

    owned = launch({:restore_driver, cut.plan, invocation("joined", prior)}, :open)

    try do
      {result, events} = collect(owned, [])

      assert {:joined, {:ok, %{restore_result: {:committed, receipt}, release_claims: []}},
              evidence} = result

      assert evidence.work_cutoff == owned.work_cutoff
      assert evidence.opens == evidence.closes and evidence.claim_count == 0
      assert Enum.count(events, &match?({_worker, {:terminal_release_installed, _}}, &1)) == 1

      assert Enum.count(events, &match?({_worker, {:issued, _, {:restore_claim_handoff, _}}}, &1)) ==
               2

      refute Enum.any?(events, &match?({_worker, {:issued, _, {:restore_claim_create, _}}}, &1))

      assert Enum.all?(events, fn {worker, _} ->
               worker == owned.worker or (release(owned) && worker == elem(release(owned), 0))
             end)

      join(owned, [:normal, :normal, :normal])
      join_release(owned, :normal)
      assert_complete(cut, receipt)
      assert {:committed, ^receipt} = Restore.restore(cut.plan, invocation())
    after
      cleanup(owned)
    end
  end

  # Concept: loss outcomes share the public facade's validation and projection.
  # Technical depth: the trusted test entry adds only existing native IO pause
  # options. Original actors are monitored before gates are permitted; actual
  # acknowledgements, descriptor custody and both intent names establish the cut.
  for boundary <- [
        :fresh_intake,
        :retained_intake,
        :proved_guardian,
        :marker_guardian,
        :proved_payload
      ] do
    test "shared facade native #{boundary} loss preserves the original absence boundary", %{
      root: root
    } do
      cut = prepare(root, "available")

      if unquote(boundary) == :retained_intake do
        strand(cut, :restore_phase, fn kind, _events ->
          kind == {:restore_phase, "destination_proofs"}
        end)

        assert File.exists?(intent_path(cut))
      end

      facade_loss(cut, unquote(boundary))
    end
  end

  defp facade_loss(cut, boundary) do
    pause = if boundary == :marker_guardian, do: :intent_may_persist, else: :restore_phase
    owned = launch_facade(cut, pause)

    try do
      ready = fn kind, events ->
        cond do
          boundary in [:fresh_intake, :retained_intake] ->
            kind == {:restore_phase, "claim"}

          boundary == :marker_guardian ->
            kind == {:intent_may_persist, "destination_intent"}

          true ->
            kind == {:restore_phase, "claim"} and absence_acknowledged?(events)
        end
      end

      {id, events} = hold_kind(owned, ready, [])
      assert_facade_native_cut(owned, cut, boundary, id, events)

      if boundary == :proved_payload,
        do: Process.exit(owned.worker, :kill),
        else: Process.exit(owned.guardian, :kill)

      {result, final_events} = collect(owned, events)

      expected =
        if boundary in [:proved_guardian, :proved_payload],
          do: :cleanup_unconfirmed,
          else: :commit_unknown

      assert {^expected, observation} = result
      assert {:ok, _bytes} = RestoreCodec.encode(:observation, observation)
      assert observation["tx_id"] == cut.plan["tx_id"]
      assert observation["cleanup"] == "unconfirmed"

      assert observation["intent"] ==
               if(expected == :cleanup_unconfirmed, do: "absent", else: "may_exist")

      assert observation["reason"] != "none"
      refute Enum.any?(final_events, &match?({_worker, {:terminal_release_installed, _}}, &1))

      reasons =
        if boundary == :proved_payload,
          do: [:normal, :normal, :killed],
          else: [:normal, :killed, :killed]

      join(owned, reasons)

      if boundary == :retained_intake do
        assert File.exists?(intent_path(cut))
      else
        assert {:error, :enoent} = File.lstat(intent_path(cut))
        assert {:error, :enoent} = File.lstat(intent_path(cut) <> ".tmp")
      end

      refute File.exists?(proof_path(cut, 3))
    after
      cleanup(owned)
    end
  end

  defp launch_facade(cut, pause) do
    parent = self()
    admitted = System.monotonic_time(:millisecond)
    fixture_cutoff = admitted + @limits["work_ms"] + 10_000 + 1_000

    {caller, monitor} =
      spawn_monitor(fn ->
        send(
          parent,
          {:result, self(),
           Restore.test_restore(cut.plan, invocation(), probe: parent, pause_at: pause)}
        )
      end)

    receive do
      {:restore_io, guardian, worker, reference, {:installed, _, cutoff}} ->
        assert Process.alive?(guardian) and Process.alive?(worker)

        %{
          caller: caller,
          caller_monitor: monitor,
          guardian: guardian,
          guardian_monitor: Process.monitor(guardian),
          worker: worker,
          worker_monitor: Process.monitor(worker),
          reference: reference,
          work_cutoff: cutoff,
          cutoff: min(fixture_cutoff, cutoff + 10_000 + 1_000),
          pause: pause
        }
    after
      left(admitted + @limits["work_ms"]) ->
        Process.exit(caller, :kill)

        receive do
          {:DOWN, ^monitor, :process, ^caller, :killed} -> :ok
        after
          left(fixture_cutoff) -> flunk("original facade installation cleanup unavailable")
        end

        flunk("original shared-facade actors unavailable")
    end
  end

  defp absence_acknowledged?(events),
    do:
      Enum.any?(
        events,
        &match?(
          {_worker, {:acknowledged, _, {:restore_absence_proved, false}, :completed}},
          &1
        )
      )

  defp assert_facade_native_cut(owned, cut, boundary, id, events) do
    assert is_reference(owned.guardian_monitor) and is_reference(owned.worker_monitor)
    assert Process.alive?(owned.guardian) and Process.alive?(owned.worker)
    assert {:dictionary, dictionary} = Process.info(owned.worker, :dictionary)
    guardian = owned.guardian
    reference = owned.reference

    assert {^guardian, ^reference, worker_guardian_monitor} =
             Keyword.fetch!(dictionary, :restore_io_owner)

    assert is_reference(worker_guardian_monitor)
    assert Keyword.fetch!(dictionary, :restore_io_descriptors) == %{}
    assert Keyword.fetch!(dictionary, :restore_io_sequence) == id
    assert {_worker, {:issued, ^id, kind}} = hd(events)
    refute Enum.any?(events, &match?({_worker, {:acknowledged, ^id, _, _}}, &1))

    if boundary in [:fresh_intake, :retained_intake] do
      assert kind == {:restore_phase, "claim"} and id == 1
      refute absence_acknowledged?(events)
      assert Keyword.fetch!(dictionary, :restore_workflow_intent)
    else
      assert absence_acknowledged?(events)

      if boundary == :marker_guardian do
        assert kind == {:intent_may_persist, "destination_intent"}
        assert Keyword.fetch!(dictionary, :restore_workflow_intent)
      else
        assert kind == {:restore_phase, "claim"}
        refute Keyword.fetch!(dictionary, :restore_workflow_intent)

        refute Enum.any?(
                 events,
                 &match?(
                   {_worker, {:issued, _, {:intent_may_persist, _}}},
                   &1
                 )
               )
      end
    end

    if boundary == :retained_intake do
      assert File.exists?(intent_path(cut))
    else
      assert {:error, :enoent} = File.lstat(intent_path(cut))
      assert {:error, :enoent} = File.lstat(intent_path(cut) <> ".tmp")
    end
  end

  defp strand(cut, pause, ready) do
    owned = launch({:restore_driver, cut.plan, invocation()}, pause)

    try do
      {_id, events} = hold_kind(owned, ready, [])
      Process.exit(owned.caller, :kill)
      {result, _} = collect(owned, events, :terminal)
      assert {:joined, _payload, evidence} = result
      assert evidence.opens == evidence.closes
      join(owned, [:killed, :normal, :normal])

      hash(
        :erlang.term_to_binary(
          {cut.plan["tx_id"], evidence.opens, evidence.closes,
           Enum.map(actors(owned), fn {_actor, monitor} ->
             Process.get({__MODULE__, monitor, :down})
           end)},
          [:deterministic]
        )
      )
    after
      cleanup(owned)
    end
  end

  defp hold_kind(owned, ready, events) do
    receive do
      {:restore_io, guardian, worker, reference, {:issued, id, kind} = event}
      when guardian == owned.guardian and worker == owned.worker and reference == owned.reference ->
        if ready.(kind, events) do
          {id, [{worker, event} | events]}
        else
          name = if is_tuple(kind), do: elem(kind, 0), else: kind
          if name == owned.pause, do: send(guardian, {:proceed, reference, id})
          hold_kind(owned, ready, [{worker, event} | events])
        end

      {:restore_io, guardian, worker, reference, event}
      when guardian == owned.guardian and reference == owned.reference ->
        hold_kind(owned, ready, [{worker, event} | events])

      {:DOWN, monitor, :process, actor, reason} ->
        retain_down(owned, actor, monitor, reason)
        hold_kind(owned, ready, events)
    after
      left(owned.cutoff) -> flunk("original native restore cut unavailable")
    end
  end

  defp temporary_path(cut, :intent), do: intent_path(cut) <> ".tmp"

  defp temporary_path(cut, :generation),
    do: Path.join(cut.destination, "ledger-a/generation.restore-00000001.tmp")

  defp temporary_path(cut, :ledger_proof), do: proof_path(cut, 1) <> ".tmp"
  defp temporary_path(cut, :root_proof), do: proof_path(cut, 3) <> ".tmp"

  defp install_fault(cut, fault) do
    case fault do
      :changed_plan ->
        :ok

      :foreign_owner ->
        path = Path.join(claim_path(cut.destination), "owner")
        {:ok, owner} = RestoreCodec.decode(:claim, File.read!(path))
        {:ok, bytes} = RestoreCodec.encode(:claim, %{owner | "tx_id" => hash("foreign-owner")})
        File.write!(path, bytes)

      :ownerless_claim ->
        File.rm!(Path.join(claim_path(cut.destination), "owner"))

      :torn_intent ->
        File.write!(intent_path(cut), "torn")

      :missing_intent ->
        File.rm!(intent_path(cut))

      :missing_candidate ->
        File.rm!(Path.join(cut.destination, "ledger-a/generation"))

      :bad_namespace ->
        path = Path.join(cut.destination, ".loopex-restore/lineage/00000001/foreign")
        File.write!(path, "foreign")
        File.chmod!(path, 0o600)

      :changed_workspace ->
        path = cut.plan["workspace"]["root"]
        File.rename!(path, path <> ".retained")
        File.mkdir!(path)

      :changed_source ->
        File.rename!(cut.source, cut.source <> ".retained")
        File.mkdir!(cut.source)
    end

    if fault == :changed_plan, do: %{cut.plan | "cut_id" => hash("changed-cut")}, else: cut.plan
  end

  defp next_cut(cut) do
    source = cut.destination
    backup = cut.plan["backup_state_root"] <> "-next"
    destination = source <> "-next"
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

    ledgers =
      Enum.map(cut.plan["ledgers"], fn ledger ->
        path = Path.join(source, ledger["relative_root"])

        %{
          ledger
          | "source_placement" => placement(path),
            "source_generation_sha256" => hash(File.read!(Path.join(path, "generation")))
        }
      end)

    plan = %{
      cut.plan
      | "tx_id" => hash("public-second-restore"),
        "source_state_root" => source,
        "source_state_placement" => placement(source),
        "source_status" => "available",
        "backup_state_root" => backup,
        "destination_state_root" => destination,
        "manifest_sha256" => hash(baseline),
        "cut_id" => hash("public-second-cut"),
        "prior_restore_count" => 1,
        "prior_lineage_sha256" => lineage,
        "ledgers" => ledgers
    }

    %{plan: plan, source: source, destination: destination, baseline: baseline}
  end

  defp strand_release(cut, removed) do
    owned = launch({:restore_driver, cut.plan, invocation()}, :open)

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

  defp absent_claims(cut),
    do: Enum.filter(participating(cut), &(File.lstat(claim_path(&1)) == {:error, :enoent}))

  defp assert_complete(cut, receipt) do
    original = File.read!(intent_path(cut))
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
          work_cutoff: cutoff,
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

  defp participating(cut) do
    if cut.plan["source_status"] == "available",
      do: [cut.source, cut.destination],
      else: [cut.destination]
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

  defp left(cutoff), do: max(0, cutoff - System.monotonic_time(:millisecond))
  defp hash(bytes), do: RestoreCodec.digest_bytes(bytes)
end
