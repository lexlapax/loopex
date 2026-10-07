Code.require_file("support/restore_fixture_copy.ex", __DIR__)

defmodule LoopexComposition.RestoreLookupTest do
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
        "restore-lookup-" <> Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)
      )

    File.mkdir!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "actual restore writers yield the exact current receipt without changing state", %{
    root: root
  } do
    fixture = first(root)
    before = manifest(fixture.destination)

    assert Restore.lookup(fixture.destination, fixture.plan["tx_id"], @limits) ==
             {:committed, %{"receipt" => fixture.receipt, "view" => "current"}}

    assert manifest(fixture.destination) == before
    assert {:ok, _} = RestoreCodec.encode(:receipt, fixture.receipt)
    assert File.lstat(claim_path(fixture.destination)) == {:error, :enoent}
  end

  test "lookup does not compare evolved ordinary files to the retained cut", %{root: root} do
    fixture = first(root)
    File.write!(Path.join(fixture.destination, "evolved-store-bytes"), "later ordinary state")
    before = manifest(fixture.destination)

    assert {:committed, %{"receipt" => receipt, "view" => "current"}} =
             Restore.lookup(fixture.destination, fixture.plan["tx_id"], @limits)

    assert receipt == fixture.receipt
    assert manifest(fixture.destination) == before
  end

  test "successive real restore writers retain historical receipts without reopening old roots",
       %{root: root} do
    old = first(root)
    next = restore_cut(root, old.destination, old.workspace, 1)
    File.rm_rf!(old.source)
    File.rm_rf!(old.destination)
    before = manifest(next.destination)

    assert {:committed, %{"receipt" => receipt, "view" => "historical"}} =
             Restore.lookup(next.destination, old.plan["tx_id"], @limits)

    assert receipt == old.receipt

    assert {:committed, %{"receipt" => current, "view" => "current"}} =
             Restore.lookup(next.destination, next.plan["tx_id"], @limits)

    assert current == next.receipt
    assert manifest(next.destination) == before
  end

  test "lost-source actual writer completion remains observable after source absence", %{
    root: root
  } do
    {source, workspace} = source(root)
    cut = prepare_cut(root, source, workspace, 0)
    File.rm_rf!(source)
    cut = %{cut | plan: %{cut.plan | "source_status" => "lost"}}
    fixture = execute_cut(cut)

    assert {:committed, %{"receipt" => receipt, "view" => "current"}} =
             Restore.lookup(fixture.destination, fixture.plan["tx_id"], @limits)

    assert receipt == fixture.receipt
    assert File.lstat(source) == {:error, :enoent}
  end

  test "root committed with a retained matching claim is pending claim release", %{root: root} do
    fixture = first(root)
    claim = install_claim(fixture)
    before = manifest(fixture.destination)

    assert {:pending, observation} =
             Restore.lookup(fixture.destination, fixture.plan["tx_id"], @limits)

    assert observation["phase"] == "claim_release"
    assert observation["intent"] == "validated" and observation["claim"] == "retained"
    assert observation["cleanup"] == "joined"
    assert {:ok, _} = RestoreCodec.encode(:observation, observation)
    assert File.read!(Path.join(claim, "owner")) == claim_bytes(fixture)
    assert manifest(fixture.destination) == before
  end

  for phase <- ~w(source_retirement destination_generations destination_proofs claim_release) do
    test "a real held restore #{phase} is pending and lookup cannot continue it", %{root: root} do
      {source, workspace} = source(root)
      cut = prepare_cut(root, source, workspace, 0)
      owned = launch_restore(cut)
      {id, _events} = hold_phase(owned, unquote(phase), [])
      before = manifest(cut.destination)

      try do
        assert {:pending, observation} =
                 Restore.lookup(cut.destination, cut.plan["tx_id"], @limits)

        assert observation["phase"] == unquote(phase)
        assert observation["intent"] == "validated" and observation["claim"] == "retained"
        assert manifest(cut.destination) == before
        assert_root_commit_boundary(cut, unquote(phase))
      after
        send(owned.guardian, {:proceed, owned.reference, id})

        try do
          finish_restore(owned)
        after
          cleanup_owned(owned)
        end
      end
    end
  end

  test "newer outgoing intent makes the earlier completed receipt historical", %{root: root} do
    fixture = first(root)
    cut = prepare_cut(root, fixture.destination, fixture.workspace, 1)
    owned = launch_restore(cut)
    {id, _} = hold_phase(owned, "destination_generations", [])

    try do
      assert {:committed, %{"receipt" => receipt, "view" => "historical"}} =
               Restore.lookup(fixture.destination, fixture.plan["tx_id"], @limits)

      assert receipt == fixture.receipt
    after
      send(owned.guardian, {:proceed, owned.reference, id})

      try do
        finish_restore(owned)
      after
        cleanup_owned(owned)
      end
    end
  end

  test "joined absence is a present observation and preserves unrelated state", %{root: root} do
    {source, _workspace} = source(root)
    tx = hash("not-present")
    before = manifest(source)

    assert Restore.lookup(source, tx, @limits) ==
             {:absent, %{"tx_id" => tx, "observation" => "not_present"}}

    assert manifest(source) == before
  end

  test "missing proof is an error rather than historical completion", %{root: root} do
    fixture = first(root)
    path = Path.join(fixture.destination, "receipts/restore-lineage/00000001/committed")
    File.rm!(path)
    before = manifest(fixture.destination)

    assert {:error, %{"code" => "restore_history_invalid", "cleanup" => "joined"}} =
             Restore.lookup(fixture.destination, fixture.plan["tx_id"], @limits)

    assert manifest(fixture.destination) == before
  end

  test "malformed retained proof refuses without altering its bytes", %{root: root} do
    fixture = first(root)
    path = Path.join(fixture.destination, "receipts/restore-lineage/00000001/committed")
    File.write!(path, <<131, 106>>)
    before = manifest(fixture.destination)

    assert {:error, %{"code" => "restore_history_invalid", "cleanup" => "joined"}} =
             Restore.lookup(fixture.destination, fixture.plan["tx_id"], @limits)

    assert File.read!(path) == <<131, 106>>
    assert manifest(fixture.destination) == before
  end

  test "physical destination replacement cannot preserve current authority", %{root: root} do
    fixture = first(root)
    File.rename!(fixture.destination, fixture.destination <> "-old")
    assert {:ok, _} = RestoreFixtureCopy.copy(fixture.destination <> "-old", fixture.destination)
    before = manifest(fixture.destination)

    assert {:error, %{"code" => "physical_destination_changed"}} =
             Restore.lookup(fixture.destination, fixture.plan["tx_id"], @limits)

    assert manifest(fixture.destination) == before
  end

  test "stranded and foreign claims refuse without reclaim or writes", %{root: root} do
    fixture = first(root)
    claim = claim_path(fixture.destination)
    File.mkdir!(claim)
    File.chmod!(claim, 0o700)

    assert {:error, %{"code" => "restore_conflict"}} =
             Restore.lookup(fixture.destination, fixture.plan["tx_id"], @limits)

    File.rmdir!(claim)
    foreign = %{fixture | plan: %{fixture.plan | "tx_id" => hash("foreign")}}
    install_claim(foreign)
    original = File.read!(Path.join(claim, "owner"))

    assert {:error, %{"code" => "restore_conflict"}} =
             Restore.lookup(fixture.destination, fixture.plan["tx_id"], @limits)

    assert File.read!(Path.join(claim, "owner")) == original
  end

  test "administrative raw ceilings refuse before the oversized record opens", %{root: root} do
    fixture = first(root)
    path = Path.join(fixture.destination, ".loopex-restore/lineage/00000001/intent")
    File.write!(path, :binary.copy("x", 65_537))
    before = manifest(fixture.destination)

    assert {:joined, {:ok, {:error, %{"code" => "inventory_limit_exceeded"}}}, evidence} =
             RestoreIO.run({:restore_lookup, fixture.destination, fixture.plan["tx_id"]}, @limits,
               probe: self()
             )

    events = probe_events([])
    assert evidence.opens == evidence.closes
    # The root's baseline and committed records sort before intent. The
    # oversized intent must refuse before its own open or any ledger read.
    assert evidence.opens == 2

    assert Enum.count(events, fn
             {:issued, _id, {:open, _token}} -> true
             _ -> false
           end) == 2

    assert manifest(fixture.destination) == before
  end

  test "caller loss after actual raw open joins original actors and preserves bytes", %{
    root: root
  } do
    fixture = first(root)
    before = manifest(fixture.destination)
    parent = self()

    {caller, caller_monitor} =
      spawn_monitor(fn ->
        send(
          parent,
          {:lookup_result, self(),
           RestoreIO.run({:restore_lookup, fixture.destination, fixture.plan["tx_id"]}, @limits,
             probe: parent,
             pause_at: :lookup_descriptor_stat
           )}
        )
      end)

    owned =
      receive do
        {:restore_io, guardian, worker, reference, {:installed, admitted, cutoff}} ->
          %{
            caller: caller,
            caller_monitor: caller_monitor,
            guardian: guardian,
            worker: worker,
            reference: reference,
            guardian_monitor: Process.monitor(guardian),
            worker_monitor: Process.monitor(worker),
            cutoff: cutoff + 10_000,
            admitted: admitted
          }
      after
        10_000 -> flunk("lookup did not install its original actors")
      end

    try do
      await_pause(owned, :lookup_descriptor_stat)
      Process.exit(caller, :kill)
      exact_down(owned, caller, caller_monitor, :killed)
      exact_down(owned, owned.worker, owned.worker_monitor, :normal)
      exact_down(owned, owned.guardian, owned.guardian_monitor, :normal)
      guardian = owned.guardian
      worker = owned.worker
      reference = owned.reference

      assert_receive {:restore_io, ^guardian, ^worker, ^reference,
                      {:terminal, {:joined, {:error, :caller_lost}, evidence}}},
                     left(owned.cutoff)

      assert evidence.opens == 1 and evidence.closes == 1
      refute_received {:lookup_result, ^caller, _}
      assert manifest(fixture.destination) == before
    after
      cleanup_owned(owned)
    end
  end

  test "a held real raw descriptor spends one original deadline and closes before joined refusal",
       %{root: root} do
    fixture = first(root)
    before = manifest(fixture.destination)
    limits = %{"work_ms" => 1_000, "cleanup_grace_ms" => 1_000}
    parent = self()

    {caller, monitor} =
      spawn_monitor(fn ->
        send(
          parent,
          {:lookup_result, self(),
           RestoreIO.run({:restore_lookup, fixture.destination, fixture.plan["tx_id"]}, limits,
             probe: parent,
             pause_at: :lookup_descriptor_stat
           )}
        )
      end)

    owned =
      receive do
        {:restore_io, guardian, worker, reference, {:installed, admitted, cutoff}} ->
          assert cutoff == admitted + 1_000

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
        1_000 -> flunk("deadline fixture did not install original actors")
      end

    try do
      await_pause(owned, :lookup_descriptor_stat)
      guardian = owned.guardian
      worker = owned.worker
      reference = owned.reference

      assert_receive {:restore_io, ^guardian, ^worker, ^reference,
                      {:stopping, :deadline, stop, cleanup}},
                     left(owned.cutoff)

      assert stop == owned.cutoff - 10_000 and cleanup == owned.cutoff

      assert_receive {:lookup_result, ^caller, {:joined, {:error, :deadline}, evidence}},
                     left(owned.cutoff)

      assert evidence.opens == 1 and evidence.closes == 1 and evidence.stop == :deadline
      join(owned)
      assert manifest(fixture.destination) == before
    after
      cleanup_owned(owned)
    end
  end

  test "closed invalid lookup queries refuse before IO", %{root: root} do
    assert {:error, %{"tx_id" => nil, "code" => "invalid_query", "cleanup" => "joined"}} =
             Restore.lookup(root, "bad", @limits)

    assert {:error, %{"code" => "invalid_query"}} =
             Restore.lookup(root <> "/..", hash("tx"), @limits)

    assert {:error, %{"code" => "invalid_query"}} =
             Restore.lookup(root, hash("tx"), Map.put(@limits, "extra", true))
  end

  for prefix <- ["admin", "lineage"] do
    test "actual empty #{prefix} prefix is conservative pending before ordinal creation", %{
      root: root
    } do
      {source, workspace} = source(root)
      cut = prepare_cut(root, source, workspace, 0)
      owned = launch_paused(cut, :directory_sync)

      try do
        path =
          if unquote(prefix) == "admin",
            do: Path.join(cut.destination, ".loopex-restore"),
            else: Path.join(cut.destination, ".loopex-restore/lineage")

        id = hold_when(owned, :directory_sync, fn -> File.ls(path) == {:ok, []} end)
        before = manifest(cut.destination)

        try do
          assert {:pending, observation} =
                   Restore.lookup(cut.destination, cut.plan["tx_id"], @limits)

          assert observation["phase"] == "destination_intent"
          assert observation["intent"] == "may_exist" and observation["claim"] == "retained"
          assert observation["ordinal"] == nil and observation["cleanup"] == "joined"
          assert manifest(cut.destination) == before
        after
          send(owned.guardian, {:proceed, owned.reference, id})

          try do
            finish_paused(owned, :directory_sync)
          after
            cleanup_owned(owned)
          end
        end
      after
        cleanup_owned(owned)
      end
    end
  end

  for {record, phase, intent_status} <- [
        {"baseline", "destination_intent", "may_exist"},
        {"source-retirement", "source_retirement", "validated"},
        {"committed", "destination_proofs", "validated"}
      ] do
    test "actual root #{record} temporary retains its earliest writer phase", %{root: root} do
      {source, workspace} = source(root)
      cut = prepare_cut(root, source, workspace, 0)
      owned = launch_paused(cut, :rename)

      try do
        path = Path.join(cut.destination, ".loopex-restore/lineage/00000001/" <> unquote(record))

        id =
          hold_when(owned, :rename, fn ->
            File.regular?(path <> ".tmp") and File.lstat(path) == {:error, :enoent}
          end)

        before = manifest(cut.destination)

        try do
          assert {:pending, observation} =
                   Restore.lookup(cut.destination, cut.plan["tx_id"], @limits)

          assert observation["phase"] == unquote(phase)

          assert observation["intent"] == unquote(intent_status) and
                   observation["claim"] == "retained"

          assert manifest(cut.destination) == before
          assert File.regular?(path <> ".tmp") and File.lstat(path) == {:error, :enoent}
        after
          send(owned.guardian, {:proceed, owned.reference, id})

          try do
            finish_paused(owned, :rename)
          after
            cleanup_owned(owned)
          end
        end
      after
        cleanup_owned(owned)
      end
    end
  end

  test "a retained destination intent never invents a missing final baseline", %{root: root} do
    {source, workspace} = source(root)
    cut = prepare_cut(root, source, workspace, 0)
    owned = launch_restore(cut)

    try do
      {id, _} = hold_phase(owned, "source_retirement", [])
      path = Path.join(cut.destination, ".loopex-restore/lineage/00000001/baseline")
      bytes = File.read!(path)
      File.rm!(path)

      try do
        assert {:error, %{"code" => "restore_history_invalid", "cleanup" => "joined"}} =
                 Restore.lookup(cut.destination, cut.plan["tx_id"], @limits)

        assert File.lstat(path) == {:error, :enoent}
      after
        File.write!(path, bytes, [:exclusive])
        File.chmod!(path, 0o600)
        send(owned.guardian, {:proceed, owned.reference, id})

        try do
          finish_restore(owned)
        after
          cleanup_owned(owned)
        end
      end
    after
      cleanup_owned(owned)
    end
  end

  test "lookup refuses replacement between original ledger placement and capture", %{root: root} do
    fixture = first(root)
    parent = self()

    {caller, caller_monitor} =
      spawn_monitor(fn ->
        send(
          parent,
          {:lookup_result, self(),
           RestoreIO.run({:restore_lookup, fixture.destination, fixture.plan["tx_id"]}, @limits,
             probe: parent,
             pause_at: :lookup_ledger_placement_stat
           )}
        )
      end)

    owned = installed_lookup(caller, caller_monitor)

    try do
      path = Path.join(fixture.destination, "receipts")

      try do
        id = hold_when(owned, :lookup_ledger_placement_stat, fn -> true end)
        File.rename!(path, path <> "-old")
        assert {:ok, _} = RestoreFixtureCopy.copy(path <> "-old", path)
        before = manifest(fixture.destination)
        send(owned.guardian, {:proceed, owned.reference, id})

        assert_receive {:lookup_result, ^caller,
                        {:joined, {:ok, {:error, %{"code" => "physical_destination_changed"}}},
                         evidence}},
                       left(owned.cutoff)

        assert evidence.opens == evidence.closes
        join(owned)
        assert manifest(fixture.destination) == before
      after
        cleanup_owned(owned)
      end
    after
      cleanup_owned(owned)
    end
  end

  for {field, value} <- [{"tx_id", "foreign"}, {"plan_digest", "foreign"}, {"role", "source"}] do
    test "actual pending intent refuses foreign claim #{field} identity without reclaim", %{
      root: root
    } do
      {source, workspace} = source(root)
      cut = prepare_cut(root, source, workspace, 0)
      owned = launch_restore(cut)

      try do
        {id, _} = hold_phase(owned, "destination_generations", [])
        owner = Path.join(claim_path(cut.destination), "owner")
        bytes = File.read!(owner)
        {:ok, claim} = RestoreCodec.decode(:claim, bytes)

        replacement =
          if unquote(value) == "foreign",
            do: hash("foreign-" <> unquote(field)),
            else: unquote(value)

        {:ok, hostile} = RestoreCodec.encode(:claim, Map.put(claim, unquote(field), replacement))
        retained = claim_path(cut.destination) <> ".retained"
        identity = claim_owner_identity(owner)
        File.rename!(claim_path(cut.destination), retained)
        File.mkdir!(claim_path(cut.destination))
        File.chmod!(claim_path(cut.destination), 0o700)
        File.write!(owner, hostile)
        File.chmod!(owner, 0o600)
        before = manifest(cut.destination)

        try do
          assert {:error, %{"code" => "restore_conflict", "cleanup" => "joined"}} =
                   Restore.lookup(cut.destination, cut.plan["tx_id"], @limits)

          assert File.read!(owner) == hostile and manifest(cut.destination) == before
        after
          File.rm_rf!(claim_path(cut.destination))
          File.rename!(retained, claim_path(cut.destination))
          assert File.read!(owner) == bytes
          assert claim_owner_identity(owner) == identity
          send(owned.guardian, {:proceed, owned.reference, id})

          try do
            finish_restore(owned)
          after
            cleanup_owned(owned)
          end
        end
      after
        cleanup_owned(owned)
      end
    end
  end

  test "an older historical query validates the actual newer claim identity", %{root: root} do
    fixture = first(root)
    cut = prepare_cut(root, fixture.destination, fixture.workspace, 1)
    owned = launch_restore(cut)

    try do
      {id, _} = hold_phase(owned, "destination_generations", [])
      owner = Path.join(claim_path(fixture.destination), "owner")
      bytes = File.read!(owner)
      {:ok, claim} = RestoreCodec.decode(:claim, bytes)
      {:ok, hostile} = RestoreCodec.encode(:claim, %{claim | "role" => "destination"})
      # Concept: hostile lookup data preserves the paused writer's original claim custody.
      # Technical depth: rewriting its owner changes captured mtime/ctime even when bytes return.
      retained = claim_path(fixture.destination) <> ".retained"
      identity = claim_owner_identity(owner)
      File.rename!(claim_path(fixture.destination), retained)
      File.mkdir!(claim_path(fixture.destination))
      File.chmod!(claim_path(fixture.destination), 0o700)
      File.write!(owner, hostile)
      File.chmod!(owner, 0o600)

      try do
        assert {:error, %{"code" => "restore_conflict", "cleanup" => "joined"}} =
                 Restore.lookup(fixture.destination, fixture.plan["tx_id"], @limits)

        assert File.read!(owner) == hostile
        File.rm_rf!(claim_path(fixture.destination))
        File.rename!(retained, claim_path(fixture.destination))
        assert File.read!(owner) == bytes
        assert claim_owner_identity(owner) == identity

        assert {:committed, %{"receipt" => receipt, "view" => "historical"}} =
                 Restore.lookup(fixture.destination, fixture.plan["tx_id"], @limits)

        assert receipt == fixture.receipt
      after
        if File.exists?(retained) do
          File.rm_rf!(claim_path(fixture.destination))
          File.rename!(retained, claim_path(fixture.destination))
        end

        assert File.read!(owner) == bytes
        assert claim_owner_identity(owner) == identity
        send(owned.guardian, {:proceed, owned.reference, id})

        try do
          finish_restore(owned)
        after
          cleanup_owned(owned)
        end
      end
    after
      cleanup_owned(owned)
    end
  end

  for fault <- [:generation, :placement] do
    test "a real higher empty outgoing ordinal cannot hide earlier #{fault}", %{root: root} do
      fixture = first(root)
      cut = prepare_cut(root, fixture.destination, fixture.workspace, 1)
      owned = launch_paused(cut, :directory_sync)

      try do
        path = Path.join(fixture.destination, ".loopex-restore/lineage/00000002")
        # The actual writer has created/chmodded source ordinal2 and is held
        # at its parent-directory sync before issuing the source intent.
        id = hold_when(owned, :directory_sync, fn -> File.ls(path) == {:ok, []} end)
        ledger = Path.join(fixture.destination, "receipts")
        bytes = File.read!(Path.join(ledger, "generation"))

        if unquote(fault) == :generation do
          File.write!(Path.join(ledger, "generation"), "changed-current-generation")
        else
          File.rename!(ledger, ledger <> "-old")
          assert {:ok, _} = RestoreFixtureCopy.copy(ledger <> "-old", ledger)
        end

        try do
          assert {:error, %{"code" => code, "cleanup" => "joined"}} =
                   Restore.lookup(fixture.destination, fixture.plan["tx_id"], @limits)

          assert code ==
                   if(unquote(fault) == :generation,
                     do: "restore_history_invalid",
                     else: "physical_destination_changed"
                   )
        after
          if unquote(fault) == :generation do
            File.write!(Path.join(ledger, "generation"), bytes)
          else
            File.rm_rf!(ledger)
            File.rename!(ledger <> "-old", ledger)
          end

          send(owned.guardian, {:proceed, owned.reference, id})

          try do
            finish_paused(owned, :directory_sync)
          after
            cleanup_owned(owned)
          end
        end
      after
        cleanup_owned(owned)
      end
    end
  end

  for fault <- [:generation, :placement] do
    test "a hostile sparse outgoing intent cannot hide an unmentioned current #{fault}", %{
      root: root
    } do
      {source, workspace} = source(root)
      assert {:ok, _} = Ledger.prepare(Path.join(source, "sparse"), "lookup-sparse", 1_000)
      fixture = execute_cut(prepare_pair_cut(root, source, workspace, 0))
      cut = prepare_pair_cut(root, fixture.destination, fixture.workspace, 1)
      owned = launch_paused(cut, :rename)

      try do
        temp = Path.join(fixture.destination, ".loopex-restore/lineage/00000002/intent.tmp")
        id = hold_when(owned, :rename, fn -> File.regular?(temp) end)
        intent_bytes = File.read!(temp)
        {:ok, intent} = RestoreCodec.decode(:intent, intent_bytes)

        plan = %{
          intent["plan"]
          | "ledgers" =>
              Enum.reject(intent["plan"]["ledgers"], &(&1["relative_root"] == "sparse"))
        }

        {:ok, digest} = RestoreCodec.plan_digest(plan)

        {:ok, hostile_intent} =
          RestoreCodec.encode(:intent, %{
            intent
            | "plan" => plan,
              "plan_digest" => digest,
              "generations" =>
                Enum.reject(intent["generations"], &(&1["relative_root"] == "sparse"))
          })

        assert {:ok, _} = RestoreCodec.decode(:intent, hostile_intent)
        owner = Path.join(claim_path(fixture.destination), "owner")
        claim_bytes = File.read!(owner)
        {:ok, claim} = RestoreCodec.decode(:claim, claim_bytes)
        {:ok, hostile_claim} = RestoreCodec.encode(:claim, %{claim | "plan_digest" => digest})
        retained = claim_path(fixture.destination) <> ".retained"
        identity = claim_owner_identity(owner)
        File.rename!(claim_path(fixture.destination), retained)
        File.mkdir!(claim_path(fixture.destination))
        File.chmod!(claim_path(fixture.destination), 0o700)
        File.write!(temp, hostile_intent)
        File.write!(owner, hostile_claim)
        File.chmod!(owner, 0o600)
        ledger = Path.join(fixture.destination, "sparse")
        generation = File.read!(Path.join(ledger, "generation"))

        if unquote(fault) == :generation do
          File.write!(Path.join(ledger, "generation"), "changed-unmentioned-generation")
        else
          File.rename!(ledger, ledger <> "-old")
          assert {:ok, _} = RestoreFixtureCopy.copy(ledger <> "-old", ledger)
        end

        before = manifest(fixture.destination)

        try do
          assert {:error, %{"code" => code, "cleanup" => "joined"}} =
                   Restore.lookup(fixture.destination, fixture.plan["tx_id"], @limits)

          assert code ==
                   if(unquote(fault) == :generation,
                     do: "restore_history_invalid",
                     else: "physical_destination_changed"
                   )

          assert manifest(fixture.destination) == before
          assert File.read!(temp) == hostile_intent and File.read!(owner) == hostile_claim
        after
          if unquote(fault) == :generation do
            File.write!(Path.join(ledger, "generation"), generation)
          else
            File.rm_rf!(ledger)
            File.rename!(ledger <> "-old", ledger)
          end

          File.write!(temp, intent_bytes)
          File.rm_rf!(claim_path(fixture.destination))
          File.rename!(retained, claim_path(fixture.destination))
          assert File.read!(owner) == claim_bytes
          assert claim_owner_identity(owner) == identity
          send(owned.guardian, {:proceed, owned.reference, id})

          try do
            finish_paused(owned, :rename)
          after
            cleanup_owned(owned)
          end
        end
      after
        cleanup_owned(owned)
      end
    end
  end

  for phase <- ~w(source_retirement destination_generations destination_proofs claim_release) do
    test "a second incoming destination at #{phase} preserves prior receipt and candidate membership",
         %{root: root} do
      first = first(root)
      source_generation = File.read!(Path.join(first.destination, "receipts/generation"))

      {:ok, source_record} =
        Ledger.decode_bytes(source_generation, "local_executor_generation_v1")

      first_intent_path = ".loopex-restore/lineage/00000001/intent"
      first_intent_bytes = File.read!(Path.join(first.destination, first_intent_path))
      {:ok, first_intent} = RestoreCodec.decode(:intent, first_intent_bytes)
      assert [prior_candidate] = first_intent["generations"]
      assert prior_candidate["destination_generation_bytes"] == source_generation
      assert prior_candidate["relative_root"] == "receipts"
      cut = prepare_cut(root, first.destination, first.workspace, 1)
      owned = launch_restore(cut)

      try do
        {id, _events} = hold_phase(owned, unquote(phase), [])

        try do
          intent_path = Path.join(cut.destination, ".loopex-restore/lineage/00000002/intent")
          intent_bytes = File.read!(intent_path)
          {:ok, intent} = RestoreCodec.decode(:intent, intent_bytes)
          assert intent["ordinal"] == 2 and intent["tx_id"] == cut.plan["tx_id"]
          assert intent["plan"] == cut.plan
          assert [candidate] = intent["generations"]
          assert candidate["relative_root"] == "receipts"
          assert candidate["source_generation_bytes"] == source_generation

          {:ok, destination_record} =
            Ledger.decode_bytes(
              candidate["destination_generation_bytes"],
              "local_executor_generation_v1"
            )

          assert destination_record["executor_identity"] == source_record["executor_identity"]
          refute destination_record["executor_epoch"] == source_record["executor_epoch"]
          assert File.read!(Path.join(cut.source, "receipts/generation")) == source_generation
          assert File.read!(Path.join(cut.destination, first_intent_path)) == first_intent_bytes

          assert File.read!(Path.join(cut.destination, "receipts/generation")) ==
                   incoming_generation(candidate, unquote(phase))

          assert_incoming_root_commit(cut, unquote(phase))

          {:ok, plan_digest} = RestoreCodec.plan_digest(cut.plan)

          owners =
            Enum.map([{cut.source, "source"}, {cut.destination, "destination"}], fn {state_root,
                                                                                     role} ->
              owner = Path.join(claim_path(state_root), "owner")
              bytes = File.read!(owner)
              {:ok, claim} = RestoreCodec.decode(:claim, bytes)
              assert claim["tx_id"] == cut.plan["tx_id"] and claim["plan_digest"] == plan_digest
              assert claim["state_root"] == state_root and claim["role"] == role
              {owner, bytes}
            end)

          # Concept: lookup validates an incoming ordinal with genuine prior candidates.
          # Technical depth: capture every temporary tree and both actual claims;
          # source/candidate membership is checked before the read-only queries.
          before = manifest(root)

          assert Restore.lookup(cut.destination, cut.plan["tx_id"], @limits) ==
                   {:pending,
                    %{
                      "kind" => "loopex_current_restore_observation_v1",
                      "tx_id" => cut.plan["tx_id"],
                      "ordinal" => 2,
                      "phase" => unquote(phase),
                      "intent" => "validated",
                      "cleanup" => "joined",
                      "claim" => "retained",
                      "reason" => "none"
                    }}

          assert Restore.lookup(cut.destination, first.plan["tx_id"], @limits) ==
                   {:committed, %{"receipt" => first.receipt, "view" => "historical"}}

          assert manifest(root) == before
          for {owner, bytes} <- owners, do: assert(File.read!(owner) == bytes)
        after
          send(owned.guardian, {:proceed, owned.reference, id})
          finish_restore(owned)
        end

        assert File.lstat(claim_path(cut.source)) == {:error, :enoent}
        assert File.lstat(claim_path(cut.destination)) == {:error, :enoent}

        assert {:committed, %{"receipt" => current, "view" => "current"}} =
                 Restore.lookup(cut.destination, cut.plan["tx_id"], @limits)

        assert current["ordinal"] == 2 and current["tx_id"] == cut.plan["tx_id"]

        assert Restore.lookup(cut.destination, first.plan["tx_id"], @limits) ==
                 {:committed, %{"receipt" => first.receipt, "view" => "historical"}}
      after
        cleanup_owned(owned)
      end
    end
  end

  defp incoming_generation(candidate, phase)
       when phase in ~w(source_retirement destination_generations),
       do: candidate["source_generation_bytes"]

  defp incoming_generation(candidate, phase) when phase in ~w(destination_proofs claim_release),
    do: candidate["destination_generation_bytes"]

  defp assert_incoming_root_commit(cut, "claim_release"),
    do:
      assert(
        {:ok, %File.Stat{type: :regular}} =
          File.lstat(Path.join(cut.destination, ".loopex-restore/lineage/00000002/committed"))
      )

  defp assert_incoming_root_commit(cut, phase)
       when phase in ~w(source_retirement destination_generations destination_proofs),
       do:
         assert(
           File.lstat(Path.join(cut.destination, ".loopex-restore/lineage/00000002/committed")) ==
             {:error, :enoent}
         )

  defp assert_root_commit_boundary(cut, "claim_release") do
    assert {:ok, %File.Stat{type: :regular}} =
             File.lstat(Path.join(cut.destination, ".loopex-restore/lineage/00000001/committed"))
  end

  defp assert_root_commit_boundary(cut, _phase),
    do:
      assert(
        File.lstat(Path.join(cut.destination, ".loopex-restore/lineage/00000001/committed")) ==
          {:error, :enoent}
      )

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

  defp probe_events(events) do
    receive do
      {:restore_io, _, _, _, event} -> probe_events([event | events])
    after
      0 -> events
    end
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

  defp await_pause(owned, kind) do
    receive do
      {:restore_io, guardian, worker, reference, {:issued, _, ^kind}}
      when guardian == owned.guardian and worker == owned.worker and reference == owned.reference ->
        :ok

      {:restore_io, _, _, _, _} ->
        await_pause(owned, kind)
    after
      left(owned.cutoff) -> flunk("lookup read barrier unavailable")
    end
  end

  defp prepare_pair_cut(root, source, workspace, prior) do
    cut = prepare_cut(root, source, workspace, prior)
    bytes = File.read!(Path.join(source, "sparse/generation"))
    {:ok, generation} = Ledger.decode_bytes(bytes, "local_executor_generation_v1")

    descriptor = %{
      "relative_root" => "sparse",
      "executor_identity" => generation["executor_identity"],
      "source_generation_sha256" => hash(bytes),
      "source_placement" => placement(Path.join(source, "sparse"))
    }

    %{
      cut
      | plan: %{
          cut.plan
          | "ledgers" => Enum.sort_by([descriptor | cut.plan["ledgers"]], & &1["relative_root"])
        }
    }
  end

  defp launch_paused(cut, pause) do
    parent = self()

    {caller, monitor} =
      spawn_monitor(fn ->
        send(
          parent,
          {:restore_result, self(),
           Restore.first(cut.plan, invocation(), probe: parent, pause_at: pause)}
        )
      end)

    installed_lookup(caller, monitor)
  end

  defp installed_lookup(caller, monitor) do
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
      10_000 -> flunk("original lookup/writer actors did not install")
    end
  end

  defp hold_when(owned, pause, predicate) do
    receive do
      {:restore_io, guardian, worker, reference, {:issued, id, ^pause}}
      when guardian == owned.guardian and worker == owned.worker and reference == owned.reference ->
        if predicate.() do
          id
        else
          send(guardian, {:proceed, reference, id})
          hold_when(owned, pause, predicate)
        end

      {:restore_io, _, _, _, _} ->
        hold_when(owned, pause, predicate)
    after
      left(owned.cutoff) -> flunk("actual writer primitive cut unavailable within original bound")
    end
  end

  defp finish_paused(owned, pause) do
    receive do
      {:restore_io, guardian, worker, reference, {:terminal_release_installed, _}}
      when guardian == owned.guardian and reference == owned.reference and
             pause == :directory_sync ->
        # The release worker pauses at directory_sync before it can finish.
        # A rename-only fixture has no such release barrier and adds no late monitor.
        assert worker != owned.worker
        assert Process.get({:lookup_release_worker, reference}) == nil
        Process.put({:lookup_release_worker, reference}, {worker, Process.monitor(worker)})
        finish_paused(owned, pause)

      {:restore_io, guardian, worker, reference, {:issued, id, ^pause}}
      when guardian == owned.guardian and worker == owned.worker and reference == owned.reference ->
        send(guardian, {:proceed, reference, id})
        finish_paused(owned, pause)

      {:restore_io, guardian, worker, reference, {:issued, id, ^pause}}
      when guardian == owned.guardian and reference == owned.reference ->
        assert {^worker, _monitor} = Process.get({:lookup_release_worker, reference})
        send(guardian, {:proceed, reference, id})
        finish_paused(owned, pause)

      {:restore_io, _, _, _, _} ->
        finish_paused(owned, pause)

      {:restore_result, caller, result} when caller == owned.caller ->
        assert {:joined, {:ok, %{restore_result: {:committed, _}, release_claims: []}}, evidence} =
                 result

        assert evidence.opens == evidence.closes and evidence.claim_count == 0
        join(owned)
    after
      left(owned.cutoff) -> flunk("actual writer result unavailable within original bound")
    end
  end

  defp join(owned) do
    exact_down(owned, owned.caller, owned.caller_monitor, :normal)
    exact_down(owned, owned.guardian, owned.guardian_monitor, :normal)
    exact_down(owned, owned.worker, owned.worker_monitor, :normal)

    if release = Process.get({:lookup_release_worker, owned.reference}) do
      {worker, monitor} = release
      exact_down(owned, worker, monitor, :normal)
    end
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
    releases =
      case Process.get({:lookup_release_worker, owned.reference}) do
        nil -> []
        release -> [release]
      end

    Enum.each(
      [
        {owned.caller, owned.caller_monitor},
        {owned.guardian, owned.guardian_monitor},
        {owned.worker, owned.worker_monitor}
      ] ++ releases,
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

  defp claim_owner_identity(owner),
    do:
      owner
      |> File.lstat!(time: :posix)
      |> Map.take([
        :type,
        :major_device,
        :minor_device,
        :inode,
        :mode,
        :size,
        :links,
        :mtime,
        :ctime
      ])
end
