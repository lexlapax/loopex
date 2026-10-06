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

      calls =
        if rem(index, 2) == 0 do
          message = Enum.find(Enum.reverse(request.messages), &(&1["role"] == "user"))
          {:ok, selected} = Frame.decode(message["content"], 8_192)
          [%{id: "call-#{index}", name: selected["tool"], arguments: selected["arguments"]}]
        else
          []
        end

      {:ok,
       %{
         completion: "unknown",
         continuation: nil,
         text: "done",
         identity: %{provider: "scripted", model: request.model, endpoint: "in-process"},
         usage: %{input_tokens: 1, output_tokens: 1},
         tool_calls: calls,
         delta_count: 0,
         streamed: false,
         provider_response_id: nil,
         canonical_request_bytes: request.canonical_request_bytes,
         staged_request_digest: request.staged_request_digest
       }}
    end
  end

  setup do
    {:ok, temp} = WorkspaceIdentity.resolve_path(System.tmp_dir!())

    root =
      Path.join(
        temp,
        "loopex-restore-workflow-" <> Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)
      )

    File.mkdir!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "one owned first transition preserves real histories and reopens both guarded compositions",
       context do
    fixture = actual_cut(context.root)
    owned = launch(fixture.plan)
    {result, events} = finish(owned)

    assert {:joined, {:ok, %{restore_result: {:committed, receipt}, release_claims: []}},
            evidence} = result

    assert receipt["ordinal"] == 1 and receipt["ledger_count"] == 2
    assert evidence.claim_count == 0
    assert evidence.opens == evidence.closes
    assert evidence.restore == %{phase: "claim_release", intent: true}
    assert evidence.work_cutoff == owned.work_cutoff

    [{:stopping, :complete, stop, cutoff}] =
      for {:stopping, :complete, _, _} = event <- events, do: event

    assert cutoff == stop + max(10_000, @grace + 2_000)
    assert evidence.cleanup_cutoff == cutoff
    releases = for {:terminal_release_installed, _} = event <- events, do: event
    assert [{:terminal_release_installed, ^cutoff}] = releases
    phases = for {:issued, _, {:restore_phase, phase}} <- events, do: phase

    assert phases ==
             ~w(claim inventory baseline_copy destination_intent source_retirement destination_generations destination_proofs claim_release)

    exact_joins(owned)

    assert_complete_copy(fixture)
    assert File.read!(Path.join(fixture.backup, "store.log")) == fixture.store_bytes
    assert File.read!(Path.join(fixture.destination, "store.log")) == fixture.store_bytes
    assert File.read!(Path.join(fixture.workspace, "unknown-ready")) == "ready"
    assert {:error, :source_retired} = RestoreGuard.state(fixture.source)

    for declaration <- fixture.plan["ledgers"] do
      root = Path.join(fixture.source, declaration["relative_root"])

      assert {:error, {:ledger_unavailable, :source_retired}} =
               Ledger.prepare(root, declaration["executor_identity"], @grace)
    end

    assert {:ok, _} = RestoreGuard.state(fixture.destination)
    assert Enum.all?(claims(fixture.plan), &(File.lstat(&1) == {:error, :enoent}))

    # Concept: a new ordinary open keeps settled/unknown truth and never starts
    # a replacement effect. Technical depth: no prompt is submitted, the public
    # history is identical, and the physical unknown marker remains unchanged.
    assert {:ok, runtime} =
             LoopexComposition.TestHost.start(
               runtime_id: @runtime,
               state_root: fixture.destination,
               workspace: fixture.workspace,
               model: "openai:test",
               policy: Policy,
               policy_identity: @policy,
               artifact_transfers: true,
               active_tools: ~w(loopex.read loopex.bash)
             )

    runtime_monitor = Process.monitor(runtime.supervisor)
    assert {:ok, _attachment} = Loopex.attach(runtime, fixture.session, after_event_sequence: 0)
    assert {:ok, status} = Loopex.session_status(runtime, fixture.session)
    assert is_map(status)
    retained = effect_rows(runtime, fixture.session, nil, [])
    assert Enum.count(retained, &(&1.kind == "intent")) == 2

    assert Enum.count(
             retained,
             &(&1.kind == "terminal" and &1.disposition == "receipt_committed")
           ) == 2

    reopened_bytes = File.read!(Path.join(fixture.destination, "store.log"))
    assert binary_part(reopened_bytes, 0, byte_size(fixture.store_bytes)) == fixture.store_bytes
    assert File.read!(Path.join(fixture.workspace, "unknown-ready")) == "ready"
    assert :ok = Loopex.stop(runtime)
    assert_receive {:DOWN, ^runtime_monitor, :process, _supervisor, :normal}, 1_000

    before = generation(Path.join(fixture.destination, "resource-packs/receipts/generation"))
    assert before["executor_identity"] == fixture.import_identity

    assert {:ok, imported} =
             ResourcePacks.add(fixture.workspace, fixture.git_source,
               workspace_ref: fixture.workspace_ref,
               state_root: fixture.destination,
               path: "second",
               rev: fixture.commit,
               git_executable: System.find_executable("git"),
               executor_authorization: {:host_policy, :allow}
             )

    assert imported["name"] == "second"

    assert generation(Path.join(fixture.destination, "resource-packs/receipts/generation")) ==
             before

    assert File.read!(Path.join(fixture.workspace, "unknown-ready")) == "ready"
  end

  for dependency <- [:receipt, :artifact, :resource] do
    test "missing historical #{dependency} refuses before intent with actual writer histories",
         context do
      fixture = actual_cut(context.root)
      path = historical_dependency_path(fixture, unquote(dependency))

      source_path = Path.join(fixture.source, path)
      backup_path = Path.join(fixture.backup, path)
      assert {:ok, %File.Stat{type: :regular, links: 1}} = File.lstat(source_path)
      assert {:ok, %File.Stat{type: :regular, links: 1}} = File.lstat(backup_path)
      assert File.read!(source_path) == File.read!(backup_path)
      File.rm!(source_path)
      File.rm!(backup_path)
      assert File.lstat(source_path) == {:error, :enoent}
      assert File.lstat(backup_path) == {:error, :enoent}
      baseline = manifest(fixture.backup)
      plan = refresh_plan(fixture.plan, baseline, fixture.backup)
      owned = launch(plan)
      {result, _events} = finish(owned)

      assert {:joined,
              {:ok,
               %{restore_result: {:not_committed, "invalid_current_history"}, release_claims: []}},
              evidence} = result

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

    assert {:error, {:ledger_unavailable, :history_invalid}} =
             Ledger.prepare(Path.join(root, "receipts"), "executor-local", @grace)

    assert File.lstat(generation_path) == {:error, :enoent}
    File.write!(generation_path, bytes)
    File.chmod!(generation_path, 0o600)
    higher = Path.join([root, ".loopex-restore", "lineage", "00000002"])
    File.mkdir!(higher)
    File.chmod!(higher, 0o700)
    File.write!(Path.join(higher, "intent"), "malformed")
    File.chmod!(Path.join(higher, "intent"), 0o600)
    assert {:error, :history_invalid} = RestoreGuard.state(root)

    assert {:error, {:ledger_unavailable, :history_invalid}} =
             Ledger.prepare(Path.join(root, "receipts"), "executor-local", @grace)

    assert File.lstat(Path.join(root, "receipts/claim")) == {:error, :enoent}
  end

  test "a prepared source cannot reacquire a claim after per-ledger retirement", context do
    fixture = actual_cut(context.root)

    assert {:ok, prepared} =
             Ledger.prepare(Path.join(fixture.source, "receipts"), "executor-local", @grace)

    owned = launch(fixture.plan)
    assert {{:joined, {:ok, %{restore_result: {:committed, _}}}, _}, _} = finish(owned)
    exact_joins(owned)
    original_deadline = System.monotonic_time(:millisecond) + 1_000
    parent = self()

    assert {:error, {:ledger_unavailable, :source_retired}} =
             Ledger.with_claim_until(
               prepared,
               fn -> send(parent, :authority_entered) end,
               original_deadline
             )

    refute_received :authority_entered
    assert File.lstat(Path.join(fixture.source, "receipts/claim")) == {:error, :enoent}
    assert original_deadline > System.monotonic_time(:millisecond)
  end

  test "second foreign claim failure releases the fully acquired first claim only", context do
    fixture = actual_cut(context.root)
    [first, second] = ordered_claims(fixture.plan)
    source_before = manifest(fixture.source)
    destination_before = manifest(fixture.destination)
    File.mkdir!(second)
    foreign_owner = Path.join(second, "owner")
    File.write!(foreign_owner, "foreign claim", [:exclusive])
    foreign_before = File.lstat!(foreign_owner)
    owned = launch(fixture.plan)
    {result, events} = finish(owned)

    assert {:joined,
            {:ok,
             %{restore_result: {:not_committed, "inventory_unavailable"}, release_claims: []}},
            evidence} = result

    assert evidence.claim_count == 0 and evidence.restore.intent == false
    assert evidence.opens == evidence.closes
    assert File.lstat(first) == {:error, :enoent}
    assert File.lstat!(foreign_owner) == foreign_before
    assert File.read!(foreign_owner) == "foreign claim"
    assert File.ls!(second) == ["owner"]
    assert manifest(fixture.source) == source_before
    assert manifest(fixture.destination) == destination_before

    assert Enum.any?(events, fn
             {:acknowledged, _, {:restore_claim_acquired, %{directory: ^first}}, :completed} ->
               true

             _ ->
               false
           end)

    assert Enum.any?(events, fn
             {:acknowledged, _, {:restore_claim_create, %{directory: ^second}}, :foreign} -> true
             _ -> false
           end)

    assert Enum.any?(
             events,
             &match?({:acknowledged, _, {:restore_claim_released, ^first}, :completed}, &1)
           )

    assert Enum.count(events, &match?({:terminal_release_installed, _}, &1)) == 1
    exact_joins(owned)
  end

  test "partial second owner publication remains fenced after joined first claim release",
       context do
    fixture = actual_cut(context.root)
    [first, second] = ordered_claims(fixture.plan)
    source_before = manifest(fixture.source)
    destination_before = manifest(fixture.destination)
    owned = launch(fixture.plan)
    {id, events} = pause_after_claim_create(owned, second, false, [])
    assert File.dir?(second)
    assert File.lstat(Path.join(second, "owner")) == {:error, :enoent}
    collision = Path.join(second, "owner.tmp")
    File.write!(collision, "partial publication fence", [:exclusive])
    partial_before = File.lstat!(collision)
    send(owned.guardian, {:proceed, owned.reference, id})
    {result, events} = finish(owned, events)

    assert {:joined,
            {:ok,
             %{restore_result: {:not_committed, "inventory_unavailable"}, release_claims: []}},
            evidence} = result

    assert evidence.claim_count == 1 and evidence.restore.intent == false
    assert evidence.opens == evidence.closes
    assert File.lstat(first) == {:error, :enoent}
    assert File.lstat(Path.join(second, "owner")) == {:error, :enoent}
    assert File.lstat!(collision) == partial_before
    assert File.read!(collision) == "partial publication fence"
    assert File.ls!(second) == ["owner.tmp"]
    assert manifest(fixture.source) == source_before
    assert manifest(fixture.destination) == destination_before

    assert Enum.any?(events, fn
             {:acknowledged, _, {:restore_claim_acquired, %{directory: ^first}}, :completed} ->
               true

             _ ->
               false
           end)

    assert Enum.any?(events, &match?({:acknowledged, _, {:open, _}, :error}, &1))

    refute Enum.any?(events, fn
             {:acknowledged, _, {:restore_claim_acquired, %{directory: ^second}}, :completed} ->
               true

             {:issued, _, {:restore_claim_released, ^second}} ->
               true

             _ ->
               false
           end)

    assert Enum.any?(
             events,
             &match?({:acknowledged, _, {:restore_claim_released, ^first}, :completed}, &1)
           )

    assert Enum.count(events, &match?({:terminal_release_installed, _}, &1)) == 1
    exact_joins(owned)
  end

  test "caller loss releases the first acquired claim without deleting the partial second claim",
       context do
    fixture = actual_cut(context.root)
    [first, second] = ordered_claims(fixture.plan)
    source_before = manifest(fixture.source)
    destination_before = manifest(fixture.destination)
    owned = launch(fixture.plan)
    {_id, events} = pause_after_claim_create(owned, second, false, [])
    Process.exit(owned.caller, :kill)
    {result, events} = finish_cancelled(owned, events)
    assert {:joined, {:error, :caller_lost}, evidence} = result
    assert evidence.stop == :caller_lost
    assert evidence.restore.intent == false and evidence.claim_count == 1
    assert evidence.opens == evidence.closes
    assert evidence.work_cutoff == owned.work_cutoff

    [{:stopping, :caller_lost, stop, cutoff}] =
      for {:stopping, :caller_lost, _, _} = event <- events, do: event

    assert cutoff == stop + max(10_000, @grace + 2_000)
    assert evidence.cleanup_cutoff == cutoff

    assert [{:terminal_release_installed, ^cutoff}] =
             for({:terminal_release_installed, _} = event <- events, do: event)

    assert File.lstat(first) == {:error, :enoent}
    assert File.ls!(second) == []
    assert manifest(fixture.source) == source_before
    assert manifest(fixture.destination) == destination_before

    assert Enum.any?(
             events,
             &match?({:acknowledged, _, {:restore_claim_released, ^first}, :completed}, &1)
           )

    refute Enum.any?(events, &match?({:issued, _, {:restore_claim_released, ^second}}, &1))
    caller = owned.caller
    caller_monitor = owned.caller_monitor
    assert_receive {:DOWN, ^caller_monitor, :process, ^caller, :killed}, 1_000

    actors =
      [{owned.worker, owned.worker_monitor}, {owned.guardian, owned.guardian_monitor}] ++
        Process.delete({:restore_release_monitors, owned.reference})

    for {actor, monitor} <- actors,
        do: assert_receive({:DOWN, ^monitor, :process, ^actor, :normal}, 1_000)
  end

  test "lost first transition preserves the captured binding and joins guarded real reopen",
       context do
    fixture = context.root |> actual_cut() |> lose_source()
    [source_claim, destination_claim] = claims(fixture.plan)
    File.mkdir!(source_claim)
    foreign_owner = Path.join(source_claim, "owner")
    File.write!(foreign_owner, "excluded lost source claim", [:exclusive])
    foreign_before = File.lstat!(foreign_owner)
    owned = launch(fixture.plan)
    {result, events} = finish(owned)

    assert {:joined, {:ok, %{restore_result: {:committed, receipt}, release_claims: []}},
            evidence} = result

    assert receipt["ordinal"] == 1 and receipt["ledger_count"] == 2
    assert evidence.claim_count == 0 and evidence.opens == evidence.closes
    assert evidence.restore == %{phase: "claim_release", intent: true}
    assert evidence.work_cutoff == owned.work_cutoff

    [{:stopping, :complete, stop, cutoff}] =
      for {:stopping, :complete, _, _} = event <- events, do: event

    assert cutoff == stop + max(10_000, @grace + 2_000)
    assert evidence.cleanup_cutoff == cutoff

    assert [{:terminal_release_installed, ^cutoff}] =
             for({:terminal_release_installed, _} = event <- events, do: event)

    assert for({:issued, _, {:restore_phase, phase}} <- events, do: phase) ==
             ~w(claim inventory baseline_copy destination_intent source_retirement destination_generations destination_proofs claim_release)

    acquired =
      for {:acknowledged, _, {:restore_claim_acquired, %{directory: path}}, :completed} <- events,
          do: path

    assert acquired == [destination_claim]

    refute Enum.any?(events, fn
             {:issued, _, {:restore_claim_create, %{directory: ^source_claim}}} -> true
             _ -> false
           end)

    exact_joins(owned)
    assert File.lstat(fixture.source) == {:error, :enoent}
    assert File.lstat(destination_claim) == {:error, :enoent}
    assert File.lstat!(foreign_owner) == foreign_before
    assert File.read!(foreign_owner) == "excluded lost source claim"
    assert File.ls!(source_claim) == ["owner"]
    assert manifest(fixture.backup) == fixture.baseline
    assert_complete_copy(fixture)
    assert File.read!(Path.join(fixture.destination, "store.log")) == fixture.store_bytes
    assert {:ok, backup_frames, :complete} = Log.decode_bytes(fixture.store_bytes)

    assert {:ok, copied_frames, :complete} =
             Log.decode_bytes(File.read!(Path.join(fixture.destination, "store.log")))

    assert {:ok, backup_state} = State.replay(backup_frames)
    assert {:ok, ^backup_state} = State.replay(copied_frames)

    admin = Path.join(fixture.destination, ".loopex-restore/lineage/00000001")
    assert {:ok, intent} = RestoreCodec.decode(:intent, File.read!(Path.join(admin, "intent")))
    assert intent["plan"] == fixture.plan
    assert {:ok, binding} = RestoreCodec.state_binding(fixture.plan["source_state_placement"])
    assert intent["source_state_binding"] == binding

    assert {:ok, retirement} =
             RestoreCodec.decode(
               :source_retirement,
               File.read!(Path.join(admin, "source-retirement"))
             )

    assert retirement["disposition"] == "lost_source_host_excluded"
    assert retirement["source_state_binding"] == binding

    assert retirement["host_evidence_sha256"] ==
             fixture.plan["host_attestation"]["evidence_sha256"]

    assert retirement["ledger_retirements"] ==
             Enum.map(
               fixture.plan["ledgers"],
               &%{"relative_root" => &1["relative_root"], "record_sha256" => nil}
             )

    for declaration <- fixture.plan["ledgers"] do
      directory =
        Path.join([
          fixture.destination,
          declaration["relative_root"],
          "restore-lineage",
          "00000001"
        ])

      assert Enum.sort(File.ls!(directory)) == ["committed", "intent"]
      assert File.lstat(Path.join(directory, "source-retired")) == {:error, :enoent}
    end

    assert {:ok, _} = RestoreGuard.state(fixture.destination)

    assert {:ok, runtime} =
             LoopexComposition.TestHost.start(
               runtime_id: @runtime,
               state_root: fixture.destination,
               workspace: fixture.workspace,
               model: "openai:test",
               policy: Policy,
               policy_identity: @policy,
               artifact_transfers: true,
               active_tools: ~w(loopex.read loopex.bash)
             )

    monitor = Process.monitor(runtime.supervisor)

    on_exit(fn ->
      if Process.alive?(runtime.supervisor) do
        cleanup_monitor = Process.monitor(runtime.supervisor)
        Process.exit(runtime.supervisor, :kill)
        assert_receive {:DOWN, ^cleanup_monitor, :process, _supervisor, :killed}, 1_000
      end
    end)

    assert {:ok, _} = Loopex.attach(runtime, fixture.session, after_event_sequence: 0)
    assert {:ok, status} = Loopex.session_status(runtime, fixture.session)
    assert is_map(status)
    rows = effect_rows(runtime, fixture.session, nil, [])
    assert Enum.count(rows, &(&1.kind == "intent")) == 2

    assert Enum.count(rows, &(&1.kind == "terminal" and &1.disposition == "receipt_committed")) ==
             2

    assert {:ok, original_frames, :complete} = Log.decode_bytes(fixture.store_bytes)
    assert {:ok, original_state} = State.replay(original_frames)

    receipts =
      for %{payload: %{kind: "executor_receipt_committed_v2"} = payload} <-
            original_state.sessions[fixture.session].records,
          do: payload["receipt"]

    assert Enum.count(receipts, &(&1["outcome"] == "outcome_unknown")) == 1
    assert File.read!(Path.join(fixture.workspace, "unknown-ready")) == "ready"
    reopened = File.read!(Path.join(fixture.destination, "store.log"))
    assert binary_part(reopened, 0, byte_size(fixture.store_bytes)) == fixture.store_bytes
    assert :ok = Loopex.stop(runtime)
    assert_receive {:DOWN, ^monitor, :process, _supervisor, :normal}, 1_000

    before = generation(Path.join(fixture.destination, "resource-packs/receipts/generation"))
    assert before["executor_identity"] == fixture.import_identity

    assert {:ok, imported} =
             ResourcePacks.add(fixture.workspace, fixture.git_source,
               workspace_ref: fixture.workspace_ref,
               state_root: fixture.destination,
               path: "second",
               rev: fixture.commit,
               git_executable: System.find_executable("git"),
               executor_authorization: {:host_policy, :allow}
             )

    assert imported["name"] == "second"

    assert generation(Path.join(fixture.destination, "resource-packs/receipts/generation")) ==
             before

    assert File.read!(Path.join(fixture.workspace, "unknown-ready")) == "ready"
    assert File.lstat(fixture.source) == {:error, :enoent}
  end

  for endpoint <- [:directory, :regular, :symlink] do
    test "lost source refuses a present #{endpoint} endpoint before any baseline mutation",
         context do
      fixture = context.root |> actual_cut() |> lose_source()
      install_source_endpoint(fixture, unquote(endpoint))
      before = File.lstat!(fixture.source)
      owned = launch(fixture.plan)
      assert_preintent_refusal(owned, fixture, "inventory_unavailable")
      assert File.lstat!(fixture.source) == before
    end
  end

  for ancestor <- [:missing, :nondirectory, :symlink] do
    test "lost endpoint ENOENT cannot hide a #{ancestor} ancestor", context do
      parent = Path.join(context.root, "source-parent")
      File.mkdir!(parent)
      fixture = context.root |> actual_cut(parent) |> lose_source()
      replace_source_ancestor(parent, unquote(ancestor))
      expected = if unquote(ancestor) == :nondirectory, do: :enotdir, else: :enoent
      assert File.lstat(fixture.source) == {:error, expected}
      owned = launch(fixture.plan)
      assert_preintent_refusal(owned, fixture, "inventory_unavailable", [], expected)
    end
  end

  test "lost endpoint replacement between two actual absence checks refuses before intent",
       context do
    fixture = context.root |> actual_cut() |> lose_source()
    owned = launch(fixture.plan, :source_absence)
    {id, events} = hold_absence(owned, 1, 0, [])
    assert Enum.any?(events, &match?({:acknowledged, _, :source_absence, :error}, &1))
    File.mkdir!(fixture.source)
    before = File.lstat!(fixture.source)
    send(owned.guardian, {:proceed, owned.reference, id})
    assert_preintent_refusal(owned, fixture, "inventory_unavailable", events)
    assert File.lstat!(fixture.source) == before
  end

  test "lost endpoint reappearance after intent stays unknown and destination claimed", context do
    fixture = context.root |> actual_cut() |> lose_source()
    owned = launch(fixture.plan, :source_absence)
    {id, events} = hold_absence(owned, 4, 0, [])

    assert File.regular?(
             Path.join(fixture.destination, ".loopex-restore/lineage/00000001/intent")
           )

    File.mkdir!(fixture.source)
    send(owned.guardian, {:proceed, owned.reference, id})
    {result, events} = finish(owned, events)

    assert {:joined,
            {:ok,
             %{restore_result: {:commit_unknown, "inventory_unavailable"}, release_claims: []}},
            evidence} = result

    assert evidence.restore.intent == true and evidence.claim_count == 1
    assert evidence.opens == evidence.closes and evidence.work_cutoff == owned.work_cutoff
    [source_claim, destination_claim] = claims(fixture.plan)
    assert File.lstat(source_claim) == {:error, :enoent}
    assert File.dir?(destination_claim)

    assert File.lstat(
             Path.join(fixture.destination, ".loopex-restore/lineage/00000001/committed")
           ) == {:error, :enoent}

    for declaration <- fixture.plan["ledgers"] do
      original = Path.join([fixture.backup, declaration["relative_root"], "generation"])
      copied = Path.join([fixture.destination, declaration["relative_root"], "generation"])
      assert File.read!(copied) == File.read!(original)
    end

    refute Enum.any?(events, &match?({:terminal_release_installed, _}, &1))
    exact_joins(owned)
  end

  test "lost final second absence cannot admit root completion below a missing captured parent",
       context do
    parent = Path.join(context.root, "source-parent")
    File.mkdir!(parent)
    fixture = context.root |> actual_cut(parent) |> lose_source()
    captured = placement(parent)
    owned = launch(fixture.plan, :source_absence)
    {id, events} = hold_absence(owned, 9, 0, [])
    assert Enum.count(events, &match?({:acknowledged, _, :source_absence, :error}, &1)) == 9
    assert Enum.count(events, &match?({:issued, _, :source_absence}, &1)) == 10
    assert {:issued, ^id, :source_absence} = hd(events)

    assert Enum.count(events, &match?({:issued, _, {:restore_phase, "destination_proofs"}}, &1)) ==
             1

    refute Enum.any?(events, &match?({:issued, _, {:restore_phase, "claim_release"}}, &1))
    root_admin = Path.join(fixture.destination, ".loopex-restore/lineage/00000001")
    committed = Path.join(root_admin, "committed")
    assert File.lstat(committed) == {:error, :enoent}

    retained =
      for path <-
            [Path.join(root_admin, "intent"), Path.join(root_admin, "source-retirement")] ++
              for(
                declaration <- fixture.plan["ledgers"],
                suffix <- ["generation", "restore-lineage/00000001/committed"],
                do: Path.join([fixture.destination, declaration["relative_root"], suffix])
              ),
          into: %{} do
        assert File.regular?(path)
        {path, File.read!(path)}
      end

    moved = parent <> "-captured"
    File.rename!(parent, moved)
    assert File.lstat(parent) == {:error, :enoent}
    assert File.lstat(fixture.source) == {:error, :enoent}
    assert Map.drop(placement(moved), ["expanded_root"]) == Map.drop(captured, ["expanded_root"])
    send(owned.guardian, {:proceed, owned.reference, id})
    {result, events} = finish(owned, events)

    assert {:joined,
            {:ok,
             %{restore_result: {:commit_unknown, "inventory_unavailable"}, release_claims: []}},
            evidence} = result

    assert evidence.restore == %{phase: "destination_proofs", intent: true}
    assert evidence.claim_count == 1 and evidence.opens == evidence.closes
    assert evidence.work_cutoff == owned.work_cutoff

    [{:stopping, :complete, stop, cutoff}] =
      for {:stopping, :complete, _, _} = event <- events, do: event

    assert cutoff == stop + max(10_000, @grace + 2_000)
    assert evidence.cleanup_cutoff == cutoff
    assert Enum.count(events, &match?({:acknowledged, _, :source_absence, :error}, &1)) == 10
    refute Enum.any?(events, &match?({:terminal_release_installed, _}, &1))
    exact_joins(owned)
    assert File.lstat(committed) == {:error, :enoent}
    for {path, bytes} <- retained, do: assert(File.read!(path) == bytes)
    [source_claim, destination_claim] = claims(fixture.plan)
    assert File.lstat(source_claim) == {:error, :enoent}
    assert File.dir?(destination_claim)
    assert File.lstat(parent) == {:error, :enoent}
    assert File.lstat(fixture.source) == {:error, :enoent}
    assert manifest(fixture.backup) == fixture.baseline
    assert {:error, :restore_incomplete} = RestoreGuard.state(fixture.destination)

    for declaration <- fixture.plan["ledgers"] do
      assert {:error, {:ledger_unavailable, :restore_incomplete}} =
               Ledger.prepare(
                 Path.join(fixture.destination, declaration["relative_root"]),
                 declaration["executor_identity"],
                 @grace
               )
    end
  end

  for dependency <- [:receipt, :artifact, :resource] do
    test "lost backup missing historical #{dependency} refuses before intent", context do
      fixture = actual_cut(context.root)
      relative = historical_dependency_path(fixture, unquote(dependency))

      for root <- [fixture.source, fixture.backup] do
        path = Path.join(root, relative)
        assert {:ok, %File.Stat{type: :regular, links: 1}} = File.lstat(path)
        File.rm!(path)
      end

      baseline = manifest(fixture.backup)
      plan = refresh_plan(fixture.plan, baseline, fixture.backup)
      fixture = lose_source(%{fixture | plan: plan, baseline: baseline})
      owned = launch(fixture.plan)
      assert_preintent_refusal(owned, fixture, "invalid_current_history")
    end
  end

  test "lost backup must still match the exact captured latest manifest", context do
    fixture = context.root |> actual_cut() |> lose_source()
    path = Path.join(fixture.backup, "orphan")
    File.write!(path, "changed after capture")
    changed = manifest(fixture.backup)
    refute changed == fixture.baseline
    owned = launch(fixture.plan)
    assert_preintent_refusal(owned, %{fixture | baseline: changed}, "inventory_mismatch")
  end

  test "lost native generation cannot use a different captured source ledger placement",
       context do
    fixture = context.root |> actual_cut() |> lose_source()
    [first | rest] = fixture.plan["ledgers"]
    altered = put_in(first, ["source_placement", "inode"], first["source_placement"]["inode"] + 1)
    plan = %{fixture.plan | "ledgers" => [altered | rest]}
    assert {:ok, _} = RestoreCodec.encode(:plan, plan)
    owned = launch(plan)
    assert_preintent_refusal(owned, fixture, "invalid_current_history")
  end

  test "lost source destination foreign claim refuses without touching either foreign owner",
       context do
    fixture = context.root |> actual_cut() |> lose_source()
    [source_claim, destination_claim] = claims(fixture.plan)

    for claim <- [source_claim, destination_claim] do
      File.mkdir!(claim)
      File.write!(Path.join(claim, "owner"), "foreign", [:exclusive])
    end

    before = Enum.map([source_claim, destination_claim], &File.lstat!(Path.join(&1, "owner")))
    owned = launch(fixture.plan)
    {result, events} = finish(owned)

    assert {:joined,
            {:ok,
             %{restore_result: {:not_committed, "inventory_unavailable"}, release_claims: []}},
            evidence} = result

    assert evidence.claim_count == 0 and evidence.restore.intent == false
    assert evidence.opens == evidence.closes

    assert Enum.map([source_claim, destination_claim], &File.lstat!(Path.join(&1, "owner"))) ==
             before

    assert Enum.all?(
             [source_claim, destination_claim],
             &(File.read!(Path.join(&1, "owner")) == "foreign")
           )

    assert File.ls!(fixture.destination) == []

    refute Enum.any?(events, fn
             {:issued, _, {:restore_claim_create, %{directory: ^source_claim}}} -> true
             _ -> false
           end)

    assert Enum.any?(
             events,
             &match?(
               {:acknowledged, _, {:restore_claim_create, %{directory: ^destination_claim}},
                :foreign},
               &1
             )
           )

    exact_joins(owned)
  end

  test "lost source cannot replace the retained physical workspace", context do
    fixture = context.root |> actual_cut() |> lose_source()
    File.rename!(fixture.workspace, fixture.workspace <> "-captured")
    File.mkdir!(fixture.workspace)
    owned = launch(fixture.plan)
    assert_preintent_refusal(owned, fixture, "invalid_placement")
  end

  test "lost source requires every explicit host latestness and exclusion attestation", context do
    fixture = context.root |> actual_cut() |> lose_source()

    invocation = %{
      "work_ms" => @work,
      "cleanup_grace_ms" => @grace,
      "max_total_file_bytes" => @total,
      "prior_admin_authority" => "none",
      "prior_admin_evidence_sha256" => nil
    }

    for field <-
          ~w(latest_cut no_post_cut_activity all_other_copies_excluded host_ledgers_validated) do
      plan = put_in(fixture.plan, ["host_attestation", field], false)
      assert {:error, :invalid_restore_input} = Restore.first(plan, invocation)
    end

    for {field, value} <- [{"old_authority_termination", "unconfirmed"}, {"evidence_sha256", nil}] do
      plan = put_in(fixture.plan, ["host_attestation", field], value)
      assert {:error, :invalid_restore_input} = Restore.first(plan, invocation)
    end

    assert File.ls!(fixture.destination) == []
    assert Enum.all?(claims(fixture.plan), &(File.lstat(&1) == {:error, :enoent}))
    assert File.lstat(fixture.source) == {:error, :enoent}
    assert manifest(fixture.backup) == fixture.baseline
  end

  for {first_status, second_status} <-
        [{:available, :available}, {:available, :lost}, {:lost, :available}, {:lost, :lost}] do
    test "successive #{first_status}/#{second_status} restores retain real A to B to C lineage",
         context do
      first = context.root |> actual_cut() |> with_source_status(unquote(first_status))
      first_receipt = restore_joined(first)
      assert first_receipt["ordinal"] == 1
      assert_complete_copy(first)
      assert {:ok, _} = RestoreGuard.state(first.destination)

      second = next_cut(first, context.root)
      # Older captured placements are history. Removing A must not prevent the
      # complete B cut from moving to C, with either current source disposition.
      File.rm_rf!(first.source)
      assert File.lstat(first.source) == {:error, :enoent}
      second = with_source_status(second, unquote(second_status))
      second_receipt = restore_joined(second)
      assert second_receipt["ordinal"] == 2
      assert second_receipt["prior_lineage_sha256"] == second.plan["prior_lineage_sha256"]
      assert_successive_copy(second)
      assert manifest(first.backup) == first.baseline
      assert File.read!(Path.join(second.destination, "store.log")) == first.store_bytes
      assert File.read!(Path.join(first.workspace, "unknown-ready")) == "ready"
      assert File.lstat(first.source) == {:error, :enoent}

      assert {:ok, %{latest: latest, candidates: candidates}} =
               RestoreGuard.state(second.destination)

      assert latest["ordinal"] == 2 and latest["plan"] == second.plan

      for declaration <- second.plan["ledgers"] do
        relative = declaration["relative_root"]
        assert candidates[relative][:covered_ordinals] == ["00000001", "00000002"]
        assert :ok = RestoreGuard.ledger(Path.join(second.destination, relative))
        original = generation(Path.join([first.backup, relative, "generation"]))
        middle = generation(Path.join([second.backup, relative, "generation"]))
        current = generation(Path.join([second.destination, relative, "generation"]))

        assert MapSet.size(
                 MapSet.new([
                   original["executor_epoch"],
                   middle["executor_epoch"],
                   current["executor_epoch"]
                 ])
               ) == 3
      end

      assert File.read!(
               Path.join(second.destination, ".loopex-restore/lineage/00000001/committed")
             ) ==
               File.read!(Path.join(second.backup, ".loopex-restore/lineage/00000001/committed"))

      assert second_receipt["tx_id"] != first_receipt["tx_id"]
      assert_second_source_disposition(second, unquote(second_status))
    end
  end

  test "a real ledger introduced at B retains sparse provenance starting at ordinal two",
       context do
    first = actual_cut(context.root)
    restore_joined(first)
    extra = "additional-receipts"

    assert {:ok, _prepared} =
             Ledger.prepare(Path.join(first.destination, extra), "additional-executor", @grace)

    second = next_cut(first, context.root, [extra, "receipts", "resource-packs/receipts"])
    restore_joined(second)
    assert_successive_copy(second)
    assert {:ok, %{candidates: candidates}} = RestoreGuard.state(second.destination)
    assert candidates[extra][:covered_ordinals] == ["00000002"]
    assert candidates["receipts"][:covered_ordinals] == ["00000001", "00000002"]
    assert candidates["resource-packs/receipts"][:covered_ordinals] == ["00000001", "00000002"]

    assert File.lstat(Path.join([second.destination, extra, "restore-lineage", "00000001"])) ==
             {:error, :enoent}

    assert :ok = RestoreGuard.ledger(Path.join(second.destination, extra))
    assert File.read!(Path.join(first.workspace, "unknown-ready")) == "ready"
  end

  for fault <- [:corrupt_proof, :incomplete_higher_head, :extra_ledger_record] do
    test "successive restore rejects actual #{fault} lineage before destination mutation",
         context do
      first = actual_cut(context.root)
      restore_joined(first)
      second = next_cut(first, context.root)
      for root <- [second.source, second.backup], do: damage_lineage(root, unquote(fault))
      baseline = manifest(second.backup)
      assert manifest(second.source) == baseline
      second = %{second | baseline: baseline, plan: refresh_lineage_plan(second.plan, baseline)}
      owned = launch(second.plan)
      assert_preintent_refusal(owned, second, "invalid_current_history")
    end
  end

  test "a later transition cannot reuse any earlier transaction with a changed canonical plan",
       context do
    first = actual_cut(context.root)
    restore_joined(first)
    second = next_cut(first, context.root)
    restore_joined(second)
    third_parent = Path.join(context.root, "third-transition")
    File.mkdir!(third_parent)
    third = next_cut(second, third_parent)
    assert third.plan["prior_restore_count"] == 2
    third = %{third | plan: %{third.plan | "tx_id" => first.plan["tx_id"]}}
    owned = launch(third.plan)
    assert_preintent_refusal(owned, third, "restore_conflict")
  end

  test "a declared 64-transition cut refuses transition 65 before claim or baseline IO",
       context do
    first = actual_cut(context.root)
    restore_joined(first)
    second = next_cut(first, context.root)
    plan = %{second.plan | "prior_restore_count" => 64}
    assert {:ok, _} = RestoreCodec.encode(:plan, plan)
    owned = launch(plan, {:restore_phase, "claim"})
    guardian = owned.guardian
    worker = owned.worker
    reference = owned.reference

    assert_receive {:restore_io, ^guardian, ^worker, ^reference,
                    {:issued, id, {:restore_phase, "claim"}} = phase},
                   1_000

    send(guardian, {:proceed, reference, id})
    {result, events} = finish(owned, [phase])

    assert {:joined,
            {:ok,
             %{restore_result: {:not_committed, "inventory_limit_exceeded"}, release_claims: []}},
            evidence} = result

    assert evidence.restore.intent == false and evidence.claim_count == 0
    assert evidence.opens == 0 and evidence.closes == 0
    assert for({:issued, _, kind} <- events, do: kind) == [{:restore_phase, "claim"}]
    exact_joins(owned)
    assert File.ls!(second.destination) == []
    assert Enum.all?(claims(plan), &(File.lstat(&1) == {:error, :enoent}))
    assert manifest(second.source) == second.baseline
    assert manifest(second.backup) == second.baseline
  end

  defp with_source_status(fixture, :available), do: fixture
  defp with_source_status(fixture, :lost), do: lose_source(fixture)

  defp assert_second_source_disposition(fixture, :available),
    do: assert({:error, :source_retired} == RestoreGuard.state(fixture.source))

  defp assert_second_source_disposition(fixture, :lost),
    do: assert(File.lstat(fixture.source) == {:error, :enoent})

  defp restore_joined(fixture) do
    owned = launch(fixture.plan)
    {result, events} = finish(owned)

    assert {:joined, {:ok, %{restore_result: {:committed, receipt}, release_claims: []}},
            evidence} = result

    assert evidence.claim_count == 0 and evidence.opens == evidence.closes
    assert evidence.work_cutoff == owned.work_cutoff
    assert evidence.restore == %{phase: "claim_release", intent: true}

    [{:stopping, :complete, stop, cutoff}] =
      for {:stopping, :complete, _, _} = event <- events, do: event

    assert cutoff == stop + max(10_000, @grace + 2_000)
    assert evidence.cleanup_cutoff == cutoff

    assert [{:terminal_release_installed, ^cutoff}] =
             for({:terminal_release_installed, _} = event <- events, do: event)

    exact_joins(owned)
    assert Enum.all?(claims(fixture.plan), &(File.lstat(&1) == {:error, :enoent}))
    receipt
  end

  defp next_cut(first, root, relatives \\ ["receipts", "resource-packs/receipts"]) do
    source = first.destination
    prior = first.plan["prior_restore_count"] + 1
    backup = Path.join(root, "backup-#{prior + 1}")
    destination = Path.join(root, "destination-#{prior + 1}")
    File.mkdir!(destination)
    assert {:ok, _} = File.cp_r(source, backup)
    baseline = manifest(backup)
    assert manifest(source) == baseline

    ledgers =
      for relative <- Enum.sort(relatives) do
        bytes = File.read!(Path.join([backup, relative, "generation"]))
        {:ok, generation} = RestoreCodec.decode(:generation, bytes)

        %{
          "relative_root" => relative,
          "executor_identity" => generation["executor_identity"],
          "source_generation_sha256" => hash(bytes),
          "source_placement" => placement(Path.join(source, relative))
        }
      end

    plan =
      %{
        first.plan
        | "tx_id" => hash("restore-#{prior + 1}"),
          "cut_id" => hash("joined-cut-#{prior + 1}"),
          "source_state_root" => source,
          "source_state_placement" => placement(source),
          "source_status" => "available",
          "backup_state_root" => backup,
          "destination_state_root" => destination,
          "prior_restore_count" => prior,
          "ledgers" => ledgers
      }
      |> refresh_lineage_plan(baseline)

    assert {:ok, _} = RestoreCodec.encode(:plan, plan)

    %{
      first
      | source: source,
        backup: backup,
        destination: destination,
        baseline: baseline,
        plan: plan
    }
  end

  defp refresh_lineage_plan(plan, baseline) do
    {:ok, entries} = RestoreCodec.manifest(baseline, @total)

    reserved =
      Enum.filter(entries, fn entry ->
        Enum.any?(Path.split(entry["path"]), &(&1 in [".loopex-restore", "restore-lineage"]))
      end)

    {:ok, digest} = RestoreCodec.lineage_digest(reserved)
    %{plan | "manifest_sha256" => hash(baseline), "prior_lineage_sha256" => digest}
  end

  defp damage_lineage(root, :corrupt_proof),
    do:
      File.write!(Path.join(root, ".loopex-restore/lineage/00000001/committed"), "corrupt proof")

  defp damage_lineage(root, :incomplete_higher_head) do
    path = Path.join(root, ".loopex-restore/lineage/00000002")
    File.mkdir!(path)
    File.chmod!(path, 0o700)
  end

  defp damage_lineage(root, :extra_ledger_record),
    do: File.write!(Path.join(root, "receipts/restore-lineage/00000001/extra"), "extra record")

  defp assert_successive_copy(fixture) do
    {:ok, baseline} = RestoreCodec.manifest(fixture.baseline, @total)
    {:ok, restored} = RestoreCodec.manifest(manifest(fixture.destination), @total)
    index = Map.new(restored, &{&1["path"], &1})

    generation_paths =
      Enum.map(fixture.plan["ledgers"], &Path.join(&1["relative_root"], "generation"))

    for entry <- baseline do
      if entry["path"] in generation_paths do
        assert Map.drop(index[entry["path"]], ["size", "sha256"]) ==
                 Map.drop(entry, ["size", "sha256"])

        original = generation(Path.join(fixture.backup, entry["path"]))
        current = generation(Path.join(fixture.destination, entry["path"]))

        assert Map.drop(current, ["executor_epoch", "generation_id", "root_binding"]) ==
                 Map.drop(original, ["executor_epoch", "generation_id", "root_binding"])
      else
        assert index[entry["path"]] == entry
      end
    end

    ordinal =
      (fixture.plan["prior_restore_count"] + 1)
      |> Integer.to_string()
      |> String.pad_leading(8, "0")

    root_admin = Path.join([".loopex-restore", "lineage", ordinal])

    records =
      [
        {root_admin, ~w(baseline intent source-retirement committed)}
        | Enum.map(fixture.plan["ledgers"], fn declaration ->
            {Path.join([declaration["relative_root"], "restore-lineage", ordinal]),
             ledger_record_names(fixture.plan)}
          end)
      ]

    expected =
      Enum.flat_map(records, fn {directory, names} ->
        dirs =
          directory |> Path.split() |> Enum.scan(fn part, parent -> Path.join(parent, part) end)

        dirs ++ Enum.map(names, &Path.join(directory, &1))
      end)
      |> Enum.uniq()

    added = Map.keys(index) -- Enum.map(baseline, & &1["path"])
    assert Enum.sort(added) == Enum.sort(expected -- Enum.map(baseline, & &1["path"]))

    for path <- added do
      entry = index[path]
      assert entry["mode"] == if(entry["kind"] == "directory", do: 0o700, else: 0o600)
    end

    assert manifest(fixture.backup) == fixture.baseline
  end

  test "64 actual one-ledger restores retain every ordinal and refuse 65 without physical IO",
       context do
    first = empty_ledger_cut(context.root)
    original = generation(Path.join(first.source, "l/generation"))

    {last, epochs, backups} =
      Enum.reduce(1..64, {first, MapSet.new([original["executor_epoch"]]), []}, fn ordinal,
                                                                                   {fixture,
                                                                                    epochs,
                                                                                    backups} ->
        receipt = restore_joined(fixture)
        assert receipt["ordinal"] == ordinal
        assert receipt["ledger_count"] == 1
        assert_successive_copy(fixture)
        assert_current_record_caps(fixture)
        assert :ok = RestoreGuard.ledger(Path.join(fixture.destination, "l"))
        current = generation(Path.join(fixture.destination, "l/generation"))
        refute MapSet.member?(epochs, current["executor_epoch"])
        assert current["executor_identity"] == original["executor_identity"]
        epochs = MapSet.put(epochs, current["executor_epoch"])
        backups = [{fixture.backup, fixture.baseline} | backups]
        next = if ordinal == 64, do: fixture, else: next_cut(fixture, context.root, ["l"])
        {next, epochs, backups}
      end)

    assert MapSet.size(epochs) == 65

    assert {:ok, %{latest: latest, candidates: %{"l" => candidate}}} =
             RestoreGuard.state(last.destination)

    assert latest["ordinal"] == 64
    ordinals = Enum.map(1..64, &lineage_ordinal/1)
    assert Enum.sort(File.ls!(Path.join(last.destination, ".loopex-restore/lineage"))) == ordinals
    assert Enum.sort(File.ls!(Path.join(last.destination, "l/restore-lineage"))) == ordinals
    assert candidate[:covered_ordinals] == ordinals
    {:ok, entries} = RestoreCodec.manifest(manifest(last.destination), @total)
    assert length(entries) == 5 + 3 + 64 * 9

    for {root, baseline} <- backups, do: assert(manifest(root) == baseline)
    next = next_cut(last, context.root, ["l"])
    assert next.plan["prior_restore_count"] == 64
    owned = launch(next.plan, {:restore_phase, "claim"})
    guardian = owned.guardian
    worker = owned.worker
    reference = owned.reference

    assert_receive {:restore_io, ^guardian, ^worker, ^reference,
                    {:issued, id, {:restore_phase, "claim"}} = phase},
                   1_000

    send(guardian, {:proceed, reference, id})
    {result, events} = finish(owned, [phase])

    assert {:joined,
            {:ok,
             %{restore_result: {:not_committed, "inventory_limit_exceeded"}, release_claims: []}},
            evidence} = result

    assert evidence.restore.intent == false and evidence.claim_count == 0
    assert evidence.work_cutoff == owned.work_cutoff
    assert evidence.opens == 0 and evidence.closes == 0
    assert for({:issued, _, kind} <- events, do: kind) == [{:restore_phase, "claim"}]
    exact_joins(owned)
    assert File.ls!(next.destination) == []
    assert Enum.all?(claims(next.plan), &(File.lstat(&1) == {:error, :enoent}))
    assert manifest(next.source) == next.baseline
    assert manifest(next.backup) == next.baseline
  end

  test "a fully rebound historical omission cannot make an incomplete baseline authoritative",
       context do
    first = actual_cut(context.root)
    restore_joined(first)
    second = next_cut(first, context.root)
    restore_joined(second)
    assert {:ok, _} = RestoreGuard.state(second.destination)
    before = manifest(second.destination)
    omitted = "receipts/restore-lineage/00000001/source-retired"
    omitted_bytes = File.read!(Path.join(second.destination, omitted))
    assert {:ok, _} = RestoreCodec.decode(:ledger_retired, omitted_bytes)
    rebound = rebind_historical_omission(second, omitted)
    after_bytes = manifest(second.destination)
    assert_rebound_record_closure(second.destination, rebound, after_bytes)
    assert File.read!(Path.join(second.destination, omitted)) == omitted_bytes
    {:ok, before_entries} = RestoreCodec.manifest(before, @total)
    {:ok, after_entries} = RestoreCodec.manifest(after_bytes, @total)
    before_index = Map.new(before_entries, &{&1["path"], &1})
    after_index = Map.new(after_entries, &{&1["path"], &1})
    assert Enum.sort(Map.keys(before_index)) == Enum.sort(Map.keys(after_index))

    for {path, entry} <- before_index do
      if Map.has_key?(rebound.records, path) do
        assert Map.drop(after_index[path], ["size", "sha256"]) ==
                 Map.drop(entry, ["size", "sha256"])
      else
        assert after_index[path] == entry
      end
    end

    assert after_index[omitted] == before_index[omitted]
    assert manifest(second.backup) == second.baseline
    assert {:error, :history_invalid} = RestoreGuard.state(second.destination)
    third = next_cut(second, context.root)
    assert third.plan["prior_restore_count"] == 2
    owned = launch(third.plan)
    assert_preintent_refusal(owned, third, "invalid_current_history")
    assert manifest(third.source) == after_bytes
  end

  # Concept: the maximum-lineage proof starts from a real minimal Local placement.
  # Technical depth: the synchronous native writer has returned before the cut;
  # no Runtime, Store, effect, lease or imported-generation prepare is substituted.
  # Every later restore uses its original work/grace/total and exact actor joins.
  defp empty_ledger_cut(root) do
    source = Path.join(root, "source")
    backup = Path.join(root, "backup")
    destination = Path.join(root, "destination")
    workspace = Path.join(root, "workspace")
    for path <- [source, destination, workspace], do: File.mkdir!(path)
    assert {:ok, _prepared} = Ledger.prepare(Path.join(source, "l"), "lineage-ledger", @grace)
    assert File.ls!(Path.join(source, "l/markers")) == []
    assert File.ls!(Path.join(source, "l/open")) == []
    bytes = File.read!(Path.join(source, "l/generation"))
    assert {:ok, generation} = RestoreCodec.decode(:generation, bytes)
    assert {:ok, _} = File.cp_r(source, backup)
    baseline = manifest(backup)
    assert manifest(source) == baseline
    {:ok, lineage} = RestoreCodec.lineage_digest([])
    observed_workspace = placement(workspace)

    workspace_ref =
      WorkspaceIdentity.from_verified_root(
        workspace,
        {observed_workspace["major_device"], observed_workspace["inode"]}
      )

    plan = %{
      "version" => 1,
      "tx_id" => hash("empty-ledger-first"),
      "cut_id" => hash("empty-ledger-cut"),
      "source_state_root" => source,
      "source_state_placement" => placement(source),
      "source_status" => "available",
      "backup_state_root" => backup,
      "destination_state_root" => destination,
      "manifest_sha256" => hash(baseline),
      "prior_restore_count" => 0,
      "prior_lineage_sha256" => lineage,
      "runtime_ids" => [],
      "stores" => [],
      "ledgers" => [
        %{
          "relative_root" => "l",
          "executor_identity" => generation["executor_identity"],
          "source_generation_sha256" => hash(bytes),
          "source_placement" => placement(Path.join(source, "l"))
        }
      ],
      "workspace" => %{"root" => workspace, "workspace_ref" => workspace_ref},
      "host_attestation" => %{
        "latest_cut" => true,
        "no_post_cut_activity" => true,
        "all_other_copies_excluded" => true,
        "old_authority_termination" => "joined",
        "host_ledgers_validated" => true,
        "evidence_sha256" => hash("native-writer-completed")
      }
    }

    assert {:ok, _} = RestoreCodec.encode(:plan, plan)

    %{
      source: source,
      backup: backup,
      destination: destination,
      workspace: workspace,
      workspace_ref: workspace_ref,
      baseline: baseline,
      plan: plan
    }
  end

  defp lineage_ordinal(value), do: value |> Integer.to_string() |> String.pad_leading(8, "0")

  defp assert_current_record_caps(fixture) do
    ordinal = lineage_ordinal(fixture.plan["prior_restore_count"] + 1)
    root = Path.join([".loopex-restore", "lineage", ordinal])
    baseline = File.read!(Path.join([fixture.destination, root, "baseline"]))
    assert byte_size(baseline) <= 4_194_304
    assert {:ok, _} = RestoreCodec.manifest(baseline, @total)

    for {name, type} <- [
          {"intent", :intent},
          {"source-retirement", :source_retirement},
          {"committed", :committed}
        ],
        do: read_fixture_record(fixture.destination, Path.join(root, name), type)

    for ledger <- fixture.plan["ledgers"],
        {name, type} <- [
          {"intent", :ledger_intent},
          {"source-retired", :ledger_retired},
          {"committed", :ledger_committed}
        ],
        do:
          read_fixture_record(
            fixture.destination,
            Path.join([ledger["relative_root"], "restore-lineage", ordinal, name]),
            type
          )

    assert {:ok, _} = RestoreCodec.manifest(manifest(fixture.destination), @total)
  end

  # Concept: the hostile cut changes one historical manifest entry, not a digest.
  # Technical depth: actual A/B/C writers and all earlier physical records remain;
  # every ordinal-two dependent record/hash is rebound in noncircular publication
  # order. No product decoder, callback, clock or cleanup result is replaced.
  defp rebind_historical_omission(fixture, omitted) do
    root = fixture.destination
    directory = ".loopex-restore/lineage/00000002"
    original_baseline = File.read!(Path.join(root, Path.join(directory, "baseline")))
    assert original_baseline == fixture.baseline
    {:ok, entries} = RestoreCodec.manifest(original_baseline, @total)
    assert Enum.count(entries, &(&1["path"] == omitted)) == 1
    altered = Enum.reject(entries, &(&1["path"] == omitted))
    baseline = fixture_record_bytes(:manifest, ["loopex:current-state-manifest:v1", altered])
    assert {:ok, ^altered} = RestoreCodec.manifest(baseline, @total)
    old_intent = read_fixture_record(root, Path.join(directory, "intent"), :intent)
    plan = refresh_lineage_plan(old_intent["plan"], baseline)
    {:ok, plan_digest} = RestoreCodec.plan_digest(plan)

    intent = %{
      old_intent
      | "plan" => plan,
        "plan_digest" => plan_digest,
        "prior_lineage_sha256" => plan["prior_lineage_sha256"]
    }

    intent_bytes = fixture_record_bytes(:intent, intent)
    intent_digest = hash(intent_bytes)
    refute intent_digest == hash(File.read!(Path.join(root, Path.join(directory, "intent"))))

    ledger_rows =
      Enum.map(intent["generations"], fn candidate ->
        path = Path.join([candidate["relative_root"], "restore-lineage", "00000002"])
        original_intent = read_fixture_record(root, Path.join(path, "intent"), :ledger_intent)
        ledger_intent = %{original_intent | "intent_sha256" => intent_digest}
        ledger_intent_bytes = fixture_record_bytes(:ledger_intent, ledger_intent)

        original_retired =
          read_fixture_record(root, Path.join(path, "source-retired"), :ledger_retired)

        retired = %{
          original_retired
          | "intent_sha256" => intent_digest,
            "ledger_intent_sha256" => hash(ledger_intent_bytes)
        }

        retired_bytes = fixture_record_bytes(:ledger_retired, retired)
        %{path: path, candidate: candidate, intent: ledger_intent_bytes, retired: retired_bytes}
      end)

    original_retirement =
      read_fixture_record(root, Path.join(directory, "source-retirement"), :source_retirement)

    retirement = %{
      original_retirement
      | "intent_sha256" => intent_digest,
        "ledger_retirements" =>
          Enum.map(ledger_rows, fn row ->
            %{
              "relative_root" => row.candidate["relative_root"],
              "record_sha256" => hash(row.retired)
            }
          end)
    }

    retirement_bytes = fixture_record_bytes(:source_retirement, retirement)

    ledger_rows =
      Enum.map(ledger_rows, fn row ->
        original = read_fixture_record(root, Path.join(row.path, "committed"), :ledger_committed)

        committed = %{
          original
          | "intent_sha256" => intent_digest,
            "ledger_intent_sha256" => hash(row.intent),
            "source_retirement_sha256" => hash(retirement_bytes)
        }

        Map.put(row, :committed, fixture_record_bytes(:ledger_committed, committed))
      end)

    activation_records =
      [
        {directory,
         [
           {"baseline", baseline},
           {"intent", intent_bytes},
           {"source-retirement", retirement_bytes}
         ]}
        | Enum.map(
            ledger_rows,
            &{&1.path, [{"intent", &1.intent}, {"source-retired", &1.retired}]}
          )
      ]

    activation = rebound_activation(altered, intent["generations"], activation_records)
    assert {:ok, _} = RestoreCodec.manifest(activation, @total)
    original_committed = read_fixture_record(root, Path.join(directory, "committed"), :committed)

    committed = %{
      original_committed
      | "intent_sha256" => intent_digest,
        "plan_digest" => plan_digest,
        "prior_lineage_sha256" => plan["prior_lineage_sha256"],
        "baseline_manifest_sha256" => hash(baseline),
        "activation_manifest_sha256" => hash(activation),
        "source_retirement_sha256" => hash(retirement_bytes),
        "ledger_proofs" =>
          Enum.map(ledger_rows, fn row ->
            %{
              "relative_root" => row.candidate["relative_root"],
              "record_sha256" => hash(row.committed)
            }
          end)
    }

    committed_bytes = fixture_record_bytes(:committed, committed)

    records =
      Map.new([
        {Path.join(directory, "baseline"), {:manifest, baseline}},
        {Path.join(directory, "intent"), {:intent, intent_bytes}},
        {Path.join(directory, "source-retirement"), {:source_retirement, retirement_bytes}},
        {Path.join(directory, "committed"), {:committed, committed_bytes}}
        | Enum.flat_map(ledger_rows, fn row ->
            [
              {Path.join(row.path, "intent"), {:ledger_intent, row.intent}},
              {Path.join(row.path, "source-retired"), {:ledger_retired, row.retired}},
              {Path.join(row.path, "committed"), {:ledger_committed, row.committed}}
            ]
          end)
      ])

    for {path, {_type, bytes}} <- records do
      target = Path.join(root, path)
      assert Bitwise.band(File.lstat!(target).mode, 0o7777) == 0o600
      File.write!(target, bytes)
    end

    %{
      records: records,
      omitted: omitted,
      original_entries: entries,
      altered_entries: altered,
      baseline: baseline,
      intent: intent,
      intent_bytes: intent_bytes,
      retirement: retirement,
      retirement_bytes: retirement_bytes,
      ledgers: ledger_rows,
      activation: activation,
      committed: committed,
      committed_bytes: committed_bytes
    }
  end

  defp fixture_record_bytes(type, value) do
    assert {:ok, bytes} = RestoreCodec.encode(type, value)
    assert {:ok, ^value} = RestoreCodec.decode(type, bytes)
    bytes
  end

  defp read_fixture_record(root, relative, type) do
    bytes = File.read!(Path.join(root, relative))
    assert byte_size(bytes) <= 65_536
    assert {:ok, value} = RestoreCodec.decode(type, bytes)
    assert {:ok, ^bytes} = RestoreCodec.encode(type, value)
    value
  end

  defp rebound_activation(entries, candidates, additions) do
    index = Map.new(entries, &{&1["path"], &1})

    index =
      Enum.reduce(candidates, index, fn candidate, index ->
        Map.update!(index, Path.join(candidate["relative_root"], "generation"), fn entry ->
          %{
            entry
            | "size" => byte_size(candidate["destination_generation_bytes"]),
              "sha256" => hash(candidate["destination_generation_bytes"])
          }
        end)
      end)

    index =
      Enum.reduce(additions, index, fn {directory, records}, index ->
        index =
          directory
          |> Path.split()
          |> Enum.scan(fn part, parent -> Path.join(parent, part) end)
          |> Enum.reduce(index, fn path, index ->
            Map.put_new(index, path, %{
              "path" => path,
              "kind" => "directory",
              "mode" => 0o700,
              "size" => 0,
              "sha256" => nil
            })
          end)

        Enum.reduce(records, index, fn {name, bytes}, index ->
          path = Path.join(directory, name)

          Map.put(index, path, %{
            "path" => path,
            "kind" => "regular",
            "mode" => 0o600,
            "size" => byte_size(bytes),
            "sha256" => hash(bytes)
          })
        end)
      end)

    fixture_record_bytes(:manifest, [
      "loopex:current-state-manifest:v1",
      Enum.sort_by(Map.values(index), & &1["path"])
    ])
  end

  defp assert_rebound_record_closure(root, rebound, physical) do
    for {path, {type, bytes}} <- rebound.records do
      assert File.read!(Path.join(root, path)) == bytes
      assert {:ok, value} = RestoreCodec.decode(type, bytes)
      assert {:ok, ^bytes} = RestoreCodec.encode(type, value)
    end

    intent_hash = hash(rebound.intent_bytes)
    {:ok, plan_digest} = RestoreCodec.plan_digest(rebound.intent["plan"])
    assert rebound.intent["plan_digest"] == plan_digest
    assert rebound.intent["plan"]["manifest_sha256"] == hash(rebound.baseline)

    reserved =
      Enum.filter(rebound.altered_entries, fn entry ->
        Enum.any?(Path.split(entry["path"]), &(&1 in [".loopex-restore", "restore-lineage"]))
      end)

    {:ok, lineage_digest} = RestoreCodec.lineage_digest(reserved)
    assert rebound.intent["prior_lineage_sha256"] == lineage_digest
    assert rebound.intent["plan"]["prior_lineage_sha256"] == lineage_digest

    assert rebound.altered_entries ==
             Enum.reject(rebound.original_entries, &(&1["path"] == rebound.omitted))

    {:ok, original_digest} =
      RestoreCodec.lineage_digest(
        Enum.filter(rebound.original_entries, fn entry ->
          Enum.any?(Path.split(entry["path"]), &(&1 in [".loopex-restore", "restore-lineage"]))
        end)
      )

    refute lineage_digest == original_digest
    assert rebound.retirement["intent_sha256"] == intent_hash
    assert rebound.retirement["ordinal"] == rebound.intent["ordinal"]
    assert rebound.retirement["tx_id"] == rebound.intent["tx_id"]
    assert rebound.retirement["disposition"] == "source_retired"
    assert rebound.retirement["source_state_binding"] == rebound.intent["source_state_binding"]

    assert rebound.retirement["destination_state_binding"] ==
             rebound.intent["destination_state_binding"]

    assert rebound.retirement["host_evidence_sha256"] ==
             rebound.intent["plan"]["host_attestation"]["evidence_sha256"]

    assert rebound.committed["intent_sha256"] == intent_hash
    assert rebound.committed["ordinal"] == rebound.intent["ordinal"]
    assert rebound.committed["tx_id"] == rebound.intent["tx_id"]

    assert rebound.committed["destination_state_binding"] ==
             rebound.intent["destination_state_binding"]

    {:ok, destination_binding} = RestoreCodec.state_binding(placement(root))
    assert rebound.intent["destination_state_binding"] == destination_binding
    assert rebound.committed["plan_digest"] == plan_digest
    assert rebound.committed["prior_lineage_sha256"] == lineage_digest
    assert rebound.committed["baseline_manifest_sha256"] == hash(rebound.baseline)
    assert rebound.committed["source_retirement_sha256"] == hash(rebound.retirement_bytes)

    for row <- rebound.ledgers do
      {:ok, ledger_intent} = RestoreCodec.decode(:ledger_intent, row.intent)
      {:ok, retired} = RestoreCodec.decode(:ledger_retired, row.retired)
      {:ok, committed} = RestoreCodec.decode(:ledger_committed, row.committed)

      for record <- [ledger_intent, retired, committed] do
        assert record["intent_sha256"] == intent_hash
        assert record["ordinal"] == rebound.intent["ordinal"]
        assert record["tx_id"] == rebound.intent["tx_id"]
        assert record["relative_root"] == row.candidate["relative_root"]
        assert record["destination_state_binding"] == rebound.intent["destination_state_binding"]
      end

      for record <- [ledger_intent, retired] do
        assert record["source_state_binding"] == rebound.intent["source_state_binding"]
        assert record["source_ledger_binding"] == row.candidate["source_ledger_binding"]

        assert record["source_generation_sha256"] ==
                 hash(row.candidate["source_generation_bytes"])

        assert record["destination_generation_sha256"] ==
                 hash(row.candidate["destination_generation_bytes"])
      end

      assert ledger_intent["destination_ledger_binding"] ==
               row.candidate["destination_ledger_binding"]

      assert committed["destination_ledger_binding"] ==
               row.candidate["destination_ledger_binding"]

      {:ok, ledger_binding} =
        RestoreCodec.ledger_binding(placement(Path.join(root, row.candidate["relative_root"])))

      assert row.candidate["destination_ledger_binding"] == ledger_binding

      assert row.candidate["destination_ledger_placement"] ==
               placement(Path.join(root, row.candidate["relative_root"]))

      source_entry =
        Enum.find(
          rebound.altered_entries,
          &(&1["path"] == Path.join(row.candidate["relative_root"], "generation"))
        )

      assert source_entry["size"] == byte_size(row.candidate["source_generation_bytes"])
      assert source_entry["sha256"] == hash(row.candidate["source_generation_bytes"])

      assert committed["destination_generation_sha256"] ==
               hash(row.candidate["destination_generation_bytes"])

      assert retired["intent_sha256"] == intent_hash
      assert retired["ledger_intent_sha256"] == hash(row.intent)
      assert committed["intent_sha256"] == intent_hash
      assert committed["ledger_intent_sha256"] == hash(row.intent)
      assert committed["source_retirement_sha256"] == hash(rebound.retirement_bytes)

      retirement =
        Enum.find(
          rebound.retirement["ledger_retirements"],
          &(&1["relative_root"] == row.candidate["relative_root"])
        )

      assert retirement["record_sha256"] == hash(row.retired)

      proof =
        Enum.find(
          rebound.committed["ledger_proofs"],
          &(&1["relative_root"] == row.candidate["relative_root"])
        )

      assert proof["record_sha256"] == hash(row.committed)

      actual_generation =
        File.read!(Path.join(root, Path.join(row.candidate["relative_root"], "generation")))

      assert actual_generation == row.candidate["destination_generation_bytes"]
    end

    {:ok, physical_entries} = RestoreCodec.manifest(physical, @total)

    commit_paths = [
      ".loopex-restore/lineage/00000002/committed"
      | Enum.map(rebound.ledgers, &Path.join(&1.path, "committed"))
    ]

    actual_activation_entries = Enum.reject(physical_entries, &(&1["path"] in commit_paths))

    actual_activation =
      fixture_record_bytes(:manifest, [
        "loopex:current-state-manifest:v1",
        actual_activation_entries
      ])

    forged_activation =
      fixture_record_bytes(:manifest, [
        "loopex:current-state-manifest:v1",
        Enum.reject(actual_activation_entries, &(&1["path"] == rebound.omitted))
      ])

    assert forged_activation == rebound.activation
    assert rebound.committed["activation_manifest_sha256"] == hash(forged_activation)
    refute rebound.committed["activation_manifest_sha256"] == hash(actual_activation)
  end

  # Concept: source loss happens only after the actual original writers joined.
  # Technical depth: preserve their captured source placements and exact latest
  # backup/workspace/host attestation. Removing the temporary source models loss;
  # no fabricated replacement generation, identity or source tombstone is used.
  defp lose_source(fixture) do
    File.rm_rf!(fixture.source)
    assert File.lstat(fixture.source) == {:error, :enoent}
    plan = %{fixture.plan | "source_status" => "lost"}
    assert {:ok, _} = RestoreCodec.encode(:plan, plan)
    %{fixture | plan: plan}
  end

  # Concept: pre-intent refusal leaves no acquired claim behind.
  # Technical depth: a lost source never acquires its source claim. Its absent
  # pathname reports ENOTDIR beneath the deliberately nondirectory ancestor;
  # the destination claim must still report ENOENT.
  defp assert_preintent_refusal(
         owned,
         fixture,
         code,
         events \\ [],
         source_claim_error \\ :enoent
       ) do
    {result, _events} = finish(owned, events)

    assert {:joined, {:ok, %{restore_result: {:not_committed, ^code}, release_claims: []}},
            evidence} = result

    assert evidence.restore.intent == false and evidence.claim_count == 0
    assert evidence.opens == evidence.closes and evidence.work_cutoff == owned.work_cutoff
    assert File.ls!(fixture.destination) == []
    assert File.lstat(Path.join(fixture.destination, ".loopex-restore")) == {:error, :enoent}
    assert manifest(fixture.backup) == fixture.baseline
    [source_claim, destination_claim] = claims(fixture.plan)
    assert File.lstat(source_claim) == {:error, source_claim_error}
    assert File.lstat(destination_claim) == {:error, :enoent}
    exact_joins(owned)
  end

  # Concept: replacement is injected at one exact real native absence check.
  # Technical depth: count completed ENOENT lstat acknowledgements, then hold the
  # next primitive on the original worker/reference/id. Every wait spends the
  # already captured work/cleanup cutoff; no fake IO result or fresh allowance.
  defp hold_absence(owned, wanted, completed, events) do
    guardian = owned.guardian
    reference = owned.reference
    worker = owned.worker
    tag = owned.tag

    receive do
      {:restore_io, ^guardian, ^worker, ^reference, {:issued, id, :source_absence} = event} ->
        if completed == wanted do
          {id, [event | events]}
        else
          send(guardian, {:proceed, reference, id})
          hold_absence(owned, wanted, completed, [event | events])
        end

      {:restore_io, ^guardian, ^worker, ^reference,
       {:acknowledged, _, :source_absence, :error} = event} ->
        hold_absence(owned, wanted, completed + 1, [event | events])

      {:restore_io, ^guardian, _worker, ^reference, event} ->
        hold_absence(owned, wanted, completed, [event | events])

      {^tag, result} ->
        flunk("restore ended before actual absence control: #{inspect(result)}")
    after
      max(
        0,
        owned.work_cutoff + max(10_000, @grace + 2_000) - System.monotonic_time(:millisecond)
      ) ->
        flunk("original restore work/cleanup cutoff reached")
    end
  end

  defp finish_cancelled(owned, events) do
    guardian = owned.guardian
    reference = owned.reference

    receive do
      {:restore_io, ^guardian, worker, ^reference, {:terminal_release_installed, _} = event} ->
        monitors = Process.get({:restore_release_monitors, reference})

        Process.put({:restore_release_monitors, reference}, [
          {worker, Process.monitor(worker)} | monitors
        ])

        finish_cancelled(owned, [event | events])

      {:restore_io, ^guardian, _worker, ^reference, {:issued, id, {:open, _}} = event} ->
        send(guardian, {:proceed, reference, id})
        finish_cancelled(owned, [event | events])

      {:restore_io, ^guardian, _worker, ^reference, {:terminal, result} = event} ->
        {result, Enum.reverse([event | events])}

      {:restore_io, ^guardian, _worker, ^reference, event} ->
        finish_cancelled(owned, [event | events])
    after
      max(
        0,
        owned.work_cutoff + max(10_000, @grace + 2_000) - System.monotonic_time(:millisecond)
      ) ->
        flunk("original restore work/cleanup cutoff reached")
    end
  end

  # Concept: the partial-publication control changes only the newly owned claim.
  # Technical depth: the exact guardian acknowledges second mkdir, then its next
  # real open is held before creating the exclusive owner.tmp collision. Every
  # receive spends the same original work/cleanup cutoff; no actor is replaced.
  defp pause_after_claim_create(owned, directory, created, events) do
    guardian = owned.guardian
    reference = owned.reference
    tag = owned.tag

    receive do
      {:restore_io, ^guardian, _worker, ^reference,
       {:acknowledged, _, {:restore_claim_create, %{directory: ^directory}}, :created} = event} ->
        pause_after_claim_create(owned, directory, true, [event | events])

      {:restore_io, ^guardian, _worker, ^reference, {:issued, id, {:open, _}} = event} ->
        if created do
          {id, [event | events]}
        else
          send(guardian, {:proceed, reference, id})
          pause_after_claim_create(owned, directory, false, [event | events])
        end

      {:restore_io, ^guardian, _worker, ^reference, event} ->
        pause_after_claim_create(owned, directory, created, [event | events])

      {^tag, result} ->
        flunk("restore ended before second claim publication control: #{inspect(result)}")
    after
      max(
        0,
        owned.work_cutoff + max(10_000, @grace + 2_000) - System.monotonic_time(:millisecond)
      ) ->
        flunk("original restore work/cleanup cutoff reached")
    end
  end

  defp ordered_claims(plan) do
    Enum.sort([plan["source_state_root"], plan["destination_state_root"]])
    |> Enum.map(fn root ->
      {:ok, digest} = RestoreCodec.claim_digest(root)
      Path.join(Path.dirname(root), ".loopex-restore-claim-" <> digest)
    end)
  end

  defp historical_dependency_path(fixture, :receipt), do: fixture.receipt_path
  defp historical_dependency_path(fixture, :artifact), do: fixture.object_path
  defp historical_dependency_path(fixture, :resource), do: fixture.manifest_path

  defp install_source_endpoint(fixture, :directory), do: File.mkdir!(fixture.source)

  defp install_source_endpoint(fixture, :regular),
    do: File.write!(fixture.source, "present endpoint", [:exclusive])

  defp install_source_endpoint(fixture, :symlink),
    do: File.ln_s!(fixture.backup, fixture.source)

  defp replace_source_ancestor(parent, :missing), do: File.rmdir!(parent)

  defp replace_source_ancestor(parent, :nondirectory) do
    File.rmdir!(parent)
    File.write!(parent, "not a directory", [:exclusive])
  end

  defp replace_source_ancestor(parent, :symlink) do
    File.rename!(parent, parent <> "-captured")
    File.ln_s!(parent <> "-captured", parent)
  end

  defp actual_cut(root, source_parent \\ nil) do
    source = Path.join(source_parent || root, "source")
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

      File.write!(
        path,
        "---\nname: #{name}\ndescription: Inspect retained files.\n---\nUse read.\n"
      )
    end

    git!(git_source, ["init", "--quiet"])
    git!(git_source, ["add", "."])

    git!(git_source, [
      "-c",
      "user.name=Fixture",
      "-c",
      "user.email=fixture@example.invalid",
      "commit",
      "--quiet",
      "-m",
      "fixture"
    ])

    commit = git!(git_source, ["rev-parse", "HEAD"]) |> String.trim()

    assert {:ok, imported} =
             ResourcePacks.add(workspace, git_source,
               workspace_ref: workspace_ref,
               state_root: source,
               path: "first",
               rev: commit,
               git_executable: System.find_executable("git"),
               executor_authorization: {:host_policy, :allow}
             )

    resource_manifest = %{
      "version" => "loopex.resource_pack/1",
      "workspace_ref" => workspace_ref,
      "revision" => nil,
      "packs" => [imported]
    }

    assert {:ok, manifest_digest} = ResourcePacks.retain(resource_manifest, source)
    import_generation = generation(Path.join(source, "resource-packs/receipts/generation"))

    {:ok, store} = Store.start_link(path: Path.join(source, "store.log"))
    {:ok, port} = Loopex.Store.new(Store, store)
    {:ok, transfers} = Transfers.start_link(root: Path.join(source, "artifacts"))
    {:ok, artifacts_handle} = Artifacts.open(Path.join(source, "artifacts"))
    artifacts = %{module: Artifacts, handle: Map.put(artifacts_handle, :transfers, transfers)}
    {:ok, lease} = WorkspaceLease.start_link(id: "workspace", path: workspace, fencing_token: 1)

    {:ok, executor} =
      Local.start_link(
        identity: "executor-local",
        epoch: 1,
        fencing_token: 1,
        workspace_leases: %{"workspace" => lease},
        ledger_root: Path.join(source, "receipts"),
        artifacts: artifacts,
        cleanup_grace_ms: @grace
      )

    {:ok, observer} = Agent.start_link(fn -> [] end)

    definitions =
      Enum.filter(
        CodingTools.definitions(),
        &({&1["tool_id"], &1["tool_version"]} in [
            {"loopex.read", "1.1.0"},
            {"loopex.bash", "1.0.0"}
          ])
      )

    genesis = Loopex.ConfiguredGenesisFixture.genesis(definitions)
    genesis = %{genesis | "runtime_configuration" => %{"cleanup_grace_ms" => @grace}}

    assert {:ok, runtime} =
             Loopex.start_link(
               runtime_id: @runtime,
               store: port,
               resource_manifest: resource_manifest,
               artifact_store: artifacts,
               model: %{module: Model, model: "scripted:v1", options: [observer: observer]},
               executor: %{
                 module: Local,
                 reference: executor,
                 identity: "executor-local",
                 epoch: 1,
                 fencing_token: 1,
                 workspace_ref: workspace_ref,
                 workspace_lease: "workspace"
               },
               tools: definitions,
               active_tools: Enum.map(definitions, & &1["tool_id"]),
               policy: Policy,
               policy_identity: @policy,
               grant_decision: {:host_policy, :allow},
               context_token_budget: 8_192
             )

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

    assert {:ok, session} =
             Loopex.create_session(runtime, %{}, command_id: "create", genesis: genesis)

    assert {:ok, attachment} = Loopex.attach(runtime, session, after_event_sequence: 0)

    assert {:accepted, "admit"} =
             Loopex.command(attachment, %{
               type: :admit_resources,
               command_id: "admit",
               manifest_digest: manifest_digest,
               decision: %{
                 manifest_digest: manifest_digest,
                 workspace_ref: workspace_ref,
                 trust_scope: "project_skills",
                 decision_source: "host_supplied",
                 issued_at: "2026-10-06T00:00:00Z",
                 expires_at: nil,
                 revocation_state: "active"
               }
             })

    assert {:ok, %{"admitted_manifest_digest" => ^manifest_digest, "entries" => [_entry]}} =
             Loopex.resource_catalog(runtime, session)

    prompt(attachment, "read", %{"tool" => "read", "arguments" => %{"path" => "source.txt"}})
    completed = await_settled(attachment, System.monotonic_time(:millisecond) + 5_000, [])
    assert Enum.find(completed, &(&1.kind == "run.finished"))["outcome"] == "completed"
    [reference] = Enum.find(completed, &(&1.kind == "tool.finished"))["artifacts"]
    assert reference["size"] == byte_size(bytes)

    prompt(attachment, "unknown", %{
      "tool" => "bash",
      "arguments" => %{"command" => "printf ready > unknown-ready; while :; do sleep 1; done"}
    })

    cutoff = System.monotonic_time(:millisecond) + 5_000
    await_file(Path.join(workspace, "unknown-ready"), cutoff)
    assert :ok = GenServer.stop(lease, :normal, 1_000)
    assert_receive {:DOWN, ^lease_monitor, :process, ^lease, :normal}, 1_000
    unknown = await_settled(attachment, cutoff, [])
    assert Enum.find(unknown, &(&1.kind == "run.finished"))["outcome"] == "outcome_unknown"
    assert :ok = Loopex.stop(runtime)

    for actor <- [store, transfers, executor, observer],
        do: assert(:ok == GenServer.stop(actor, :normal, 1_000))

    for {actor, monitor} <- monitors,
        do: assert_receive({:DOWN, ^monitor, :process, ^actor, :normal}, 1_000)

    store_bytes = File.read!(Path.join(source, "store.log"))
    {:ok, frames, :complete} = Log.decode_bytes(store_bytes)
    {:ok, replayed} = State.replay(frames)
    records = replayed.sessions[session].records
    assert Enum.any?(records, &(&1.payload.kind == "model_request_committed_resources_v2"))

    for record <- records,
        record.payload.kind == "model_request_committed_resources_v2" do
      assert record.payload["context_receipt"]["resource_packs"]["manifest_digest"] ==
               manifest_digest
    end

    [receipt_row, unknown_row] =
      Enum.filter(records, &(&1.payload.kind == "executor_receipt_committed_v2"))

    assert unknown_row.payload["receipt"]["outcome"] == "outcome_unknown"
    assert unknown_row.payload["receipt"]["cleanup_confirmation"] == "confirmed"

    receipt_path =
      Path.join("receipts", hash(receipt_row.payload["receipt"]["job_id"]) <> ".receipt")

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

    plan = %{
      "version" => 1,
      "tx_id" => hash("first-restore"),
      "source_state_root" => source,
      "source_state_placement" => placement(source),
      "source_status" => "available",
      "backup_state_root" => backup,
      "destination_state_root" => destination,
      "manifest_sha256" => hash(baseline),
      "cut_id" => hash("joined-current-cut"),
      "prior_restore_count" => 0,
      "prior_lineage_sha256" => lineage,
      "runtime_ids" => [@runtime],
      "stores" => [],
      "ledgers" => [],
      "workspace" => %{"root" => workspace, "workspace_ref" => workspace_ref},
      "host_attestation" => %{
        "latest_cut" => true,
        "no_post_cut_activity" => true,
        "all_other_copies_excluded" => true,
        "old_authority_termination" => "joined",
        "host_ledgers_validated" => true,
        "evidence_sha256" => hash("exact-fixture-joins")
      }
    }

    plan = refresh_plan(plan, baseline, backup)
    assert {:ok, _} = RestoreCodec.encode(:plan, plan)

    %{
      source: source,
      backup: backup,
      destination: destination,
      workspace: workspace,
      workspace_ref: workspace_ref,
      session: session,
      baseline: baseline,
      plan: plan,
      store_bytes: store_bytes,
      receipt_path: receipt_path,
      object_path:
        Path.join(["artifacts", binary_part(reference["locator"], 0, 2), reference["locator"]]),
      manifest_path: Path.join(["resource-packs", "manifests", manifest_digest <> ".etf"]),
      git_source: git_source,
      commit: commit,
      import_identity: import_generation["executor_identity"]
    }
  end

  defp refresh_plan(plan, baseline, backup) do
    store = %{
      "relative_path" => "store.log",
      "sha256" => hash(File.read!(Path.join(backup, "store.log")))
    }

    ledgers =
      for relative <- ["receipts", "resource-packs/receipts"] do
        bytes = File.read!(Path.join([backup, relative, "generation"]))
        {:ok, generation} = RestoreCodec.decode(:generation, bytes)

        %{
          "relative_root" => relative,
          "executor_identity" => generation["executor_identity"],
          "source_generation_sha256" => hash(bytes),
          "source_placement" => placement(Path.join(plan["source_state_root"], relative))
        }
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

        assert Map.drop(current, ["executor_epoch", "generation_id", "root_binding"]) ==
                 Map.drop(original, ["executor_epoch", "generation_id", "root_binding"])

        refute current["executor_epoch"] == original["executor_epoch"]
      else
        assert index[path] == entry
      end
    end

    admin =
      [".loopex-restore", ".loopex-restore/lineage", ".loopex-restore/lineage/00000001"] ++
        for(
          relative <- ["receipts", "resource-packs/receipts"],
          suffix <- ["restore-lineage", "restore-lineage/00000001"],
          do: Path.join(relative, suffix)
        ) ++
        for(
          name <- ["baseline", "intent", "source-retirement", "committed"],
          do: Path.join(".loopex-restore/lineage/00000001", name)
        ) ++
        for(
          relative <- ["receipts", "resource-packs/receipts"],
          name <- ledger_record_names(fixture.plan),
          do: Path.join([relative, "restore-lineage", "00000001", name])
        )

    added = Map.keys(index) -- Enum.map(baseline, & &1["path"])
    assert Enum.sort(added) == Enum.sort(admin)
  end

  defp ledger_record_names(%{"source_status" => "lost"}), do: ["intent", "committed"]
  defp ledger_record_names(_), do: ["intent", "source-retired", "committed"]

  defp launch(plan, pause \\ :open) do
    parent = self()
    tag = make_ref()

    invocation = %{
      "work_ms" => @work,
      "cleanup_grace_ms" => @grace,
      "max_total_file_bytes" => @total,
      "prior_admin_authority" => "none",
      "prior_admin_evidence_sha256" => nil
    }

    {caller, caller_monitor} =
      spawn_monitor(fn ->
        send(
          parent,
          {tag, Restore.first(plan, invocation, probe: parent, pause_at: pause)}
        )
      end)

    assert_receive {:restore_io, guardian, worker, reference,
                    {:installed, admitted, work_cutoff}},
                   1_000

    owned = %{
      caller: caller,
      caller_monitor: caller_monitor,
      guardian: guardian,
      guardian_monitor: Process.monitor(guardian),
      worker: worker,
      worker_monitor: Process.monitor(worker),
      reference: reference,
      tag: tag,
      work_cutoff: work_cutoff,
      pause: pause
    }

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

        Process.put({:restore_release_monitors, reference}, [
          {worker, Process.monitor(worker)} | monitors
        ])

        finish(owned, [event | events])

      {:restore_io, ^guardian, _worker, ^reference, {:issued, id, {:open, _}} = event} ->
        if owned.pause == :open, do: send(guardian, {:proceed, reference, id})
        finish(owned, [event | events])

      {:restore_io, ^guardian, _worker, ^reference, {:issued, id, :source_absence} = event} ->
        if owned.pause == :source_absence, do: send(guardian, {:proceed, reference, id})
        finish(owned, [event | events])

      {:restore_io, ^guardian, _worker, ^reference, event} ->
        finish(owned, [event | events])

      {^tag, result} ->
        {result, Enum.reverse(events)}
    after
      max(
        0,
        owned.work_cutoff + max(10_000, @grace + 2_000) - System.monotonic_time(:millisecond)
      ) ->
        flunk("original restore work/cleanup cutoff reached")
    end
  end

  defp exact_joins(owned) do
    actors =
      [
        {owned.worker, owned.worker_monitor},
        {owned.guardian, owned.guardian_monitor},
        {owned.caller, owned.caller_monitor}
      ] ++ Process.delete({:restore_release_monitors, owned.reference})

    for {actor, monitor} <- actors,
        do: assert_receive({:DOWN, ^monitor, :process, ^actor, :normal}, 1_000)
  end

  defp effect_rows(runtime, session, cursor, rows) do
    assert {:ok, page} = Loopex.Runtime.effect_intents(runtime, session, cursor, 16)
    rows = rows ++ page.rows
    if page.next_cursor, do: effect_rows(runtime, session, page.next_cursor, rows), else: rows
  end

  defp manifest(root) do
    assert {:joined, {:ok, bytes}, _} =
             RestoreIO.run({:manifest, root, @total}, %{
               "work_ms" => @work,
               "cleanup_grace_ms" => @grace
             })

    bytes
  end

  defp prompt(attachment, id, selected) do
    {:ok, bytes} = Frame.encode(selected)

    assert {:accepted, ^id} =
             Loopex.command(attachment, %{
               type: :prompt,
               command_id: id,
               content: bytes |> IO.iodata_to_binary() |> String.trim_trailing("\n")
             })
  end

  defp await_settled(attachment, cutoff, events) do
    assert System.monotonic_time(:millisecond) < cutoff

    case Loopex.next_event(attachment) do
      {:ok, %{kind: "session.settled"} = event} ->
        Enum.reverse([event | events])

      {:ok, event} ->
        await_settled(attachment, cutoff, [event | events])

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
      {:ok, "ready"} ->
        :ok

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

  defp claims(plan),
    do:
      Enum.map([plan["source_state_root"], plan["destination_state_root"]], fn root ->
        {:ok, digest} = RestoreCodec.claim_digest(root)
        Path.join(Path.dirname(root), ".loopex-restore-claim-" <> digest)
      end)

  defp git!(root, args) do
    assert {output, 0} = System.cmd("git", args, cd: root)
    output
  end

  defp hash(bytes), do: Canonical.digest_bytes(bytes)
end
