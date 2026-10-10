# Concept: the shared session fixtures load under an explicit temporary home,
# as the delegation fixture does; the host environment is restored at once.
fixture_home =
  Path.join(System.tmp_dir!(), "restore-helper-load-#{System.unique_integer([:positive])}")

File.mkdir_p!(fixture_home)
prior_home = System.get_env("LOOPEX_HOME")
System.put_env("LOOPEX_HOME", fixture_home)

try do
  Code.require_file("../../loopex/test/support/m1_runtime_helper.exs", __DIR__)
  Code.require_file("../../loopex/test/support/agent_loop_helper.exs", __DIR__)
after
  if prior_home,
    do: System.put_env("LOOPEX_HOME", prior_home),
    else: System.delete_env("LOOPEX_HOME")

  File.rm_rf!(fixture_home)
end

Code.require_file("support/restore_fixture_copy.ex", __DIR__)

defmodule LoopexComposition.RestoreHelperRootTest do
  @moduledoc """
  ## Concept

  A state root that has run a real helper parent and child, beside an
  ordinary session whose effect is unresolved, restores publicly into an empty
  root. The restored helper namespace, Store and executor ledger reopen without
  dispatching any effect or rerunning any helper.

  ## Technical depth

  The source runs the shipped Local Store and executor, the helper owner and
  its router over one physical workspace. After an orderly stop the
  disposable `job-index-v1` cache is removed before the backup is taken; the
  quiescent namespace then holds only digest-named objects and complete
  binding/run logs.
  """
  use ExUnit.Case, async: false

  alias Loopex.AgentLoopTestModel
  alias Loopex.Executor.Local, as: Local
  alias Loopex.Executor.Local.{CodingTools, Ledger, RestoreCodec, WorkspaceLease}
  alias Loopex.Store.Local, as: Store
  alias Loopex.Store.Local.{Artifacts, Transfers}
  alias LoopexComposition.{Placement, RestoreFixtureCopy, WorkspaceIdentity}
  alias LoopexComposition.Delegation.{Catalog, Helper, RetainedObjects, Router, Tool}
  alias LoopexComposition.Restore.IO, as: RestoreIO
  alias LoopexProtocol.Canonical

  @runtime "restore-helper"
  @model "anthropic:helper-fixture"
  @providers %{"anthropic" => %{"credential" => %{"env" => "HELPER_FIXTURE_KEY"}}}
  @policy %{"id" => "restore-helper-policy", "revision" => "1"}
  @total 16_777_216
  @work 10_000
  @grace 1_000

  setup do
    {:ok, temp} = WorkspaceIdentity.resolve_path(System.tmp_dir!())

    root =
      Path.join(temp, "loopex-restore-helper-" <> Base.encode16(:crypto.strong_rand_bytes(8)))

    File.mkdir!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "a quiescent helper root restores into an empty root and reopens without dispatch",
       context do
    fixture = helper_cut(context.root)
    workspace_before = manifest(fixture.workspace)

    assert {:committed, receipt} = LoopexComposition.Restore.restore(fixture.plan, invocation())
    assert receipt["baseline_manifest_sha256"] == hash(fixture.baseline)

    # Concept: the complete state is the backup plus only restore administration.
    {:ok, baseline} = RestoreCodec.manifest(fixture.baseline, @total)
    {:ok, restored} = RestoreCodec.manifest(manifest(fixture.destination), @total)
    index = Map.new(restored, &{&1["path"], &1})

    for entry <- baseline do
      if entry["path"] == "receipts/generation" do
        assert Map.drop(index[entry["path"]], ["size", "sha256"]) ==
                 Map.drop(entry, ["size", "sha256"])
      else
        assert index[entry["path"]] == entry
      end
    end

    added = Map.keys(index) -- Enum.map(baseline, & &1["path"])

    assert Enum.all?(added, fn path ->
             String.starts_with?(path, ".loopex-restore") or
               String.starts_with?(path, "receipts/restore-lineage")
           end)

    assert Enum.any?(baseline, &String.starts_with?(&1["path"], "delegation/"))
    assert manifest(fixture.workspace) == workspace_before

    # Concept: reopening rebuilds the helper index from history and dispatches nothing.
    reopened = boot(fixture.destination, fixture.workspace, fixture.workspace_ref, [])
    assert :ok = Helper.classify(reopened.helper)

    for session <- [fixture.parent, fixture.ordinary] do
      assert Loopex.resume_session(reopened.runtime, session, command_id: "reopen-" <> session) ==
               {:ok, session}
    end

    status = Helper.status(reopened.helper)
    assert Map.keys(status.children) == [fixture.child]
    assert Local.stats(reopened.executor).dispatches == %{}
    assert AgentLoopTestModel.dispatched(reopened.model) == []
    assert File.read!(Path.join(fixture.workspace, "unknown-ready")) == "ready"
    stop(reopened)
  end

  # Concept: each damage is applied identically to the source and the backup
  # in place, so their manifests and physical identities still agree and the
  # refusal comes from the helper audit alone. The undamaged control commits.
  for damage <- [:none, :writer_marker, :corrupt_run_log, :unknown_member, :job_index] do
    test "a helper namespace with #{damage} damage restores only when undamaged", context do
      fixture = helper_cut(context.root)

      for root <- [fixture.source, fixture.backup],
          do: damage!(unquote(damage), Path.join([root, "delegation", hash(@runtime)]))

      plan = %{fixture.plan | "manifest_sha256" => hash(manifest(fixture.backup))}

      assert_restore(
        unquote(damage),
        LoopexComposition.Restore.restore(plan, invocation()),
        fixture
      )
    end
  end

  defp assert_restore(:none, result, _fixture), do: assert({:committed, _receipt} = result)

  defp assert_restore(_damage, result, fixture) do
    assert {:not_committed, %{"code" => "invalid_current_history"}} = result
    assert File.ls!(fixture.destination) == []
  end

  defp damage!(:none, _namespace), do: :ok

  # A writer marker left by a live or crashed owner means the root is not quiescent.
  defp damage!(:writer_marker, namespace),
    do: File.write!(Path.join(namespace, "objects.writer"), "stale writer")

  defp damage!(:corrupt_run_log, namespace) do
    [log] = Path.wildcard(Path.join([namespace, "runs", "*.log"]))
    bytes = File.read!(log)
    middle = div(byte_size(bytes), 2)

    File.write!(log, [
      binary_part(bytes, 0, middle),
      Bitwise.bxor(:binary.at(bytes, middle), 1),
      binary_part(bytes, middle + 1, byte_size(bytes) - middle - 1)
    ])
  end

  defp damage!(:unknown_member, namespace),
    do: File.write!(Path.join(namespace, String.duplicate("a", 64)), "not its digest")

  defp damage!(:job_index, namespace) do
    File.mkdir_p!(Path.join(namespace, "job-index-v1"))
    File.write!(Path.join([namespace, "job-index-v1", "entry"]), "{}")
  end

  # Concept: one real helper parent delegates to one child, then an ordinary
  # session leaves an unresolved effect; every owner stops in order.
  defp helper_cut(root) do
    source = Path.join(root, "source")
    backup = Path.join(root, "backup")
    destination = Path.join(root, "destination")
    workspace = Path.join(root, "workspace")
    for path <- [source, destination, workspace], do: File.mkdir!(path)
    File.write!(Path.join(workspace, "README.md"), "helper restore fixture\n")
    {:ok, workspace_ref} = WorkspaceIdentity.reference(workspace)

    script = [
      %{text: "delegating", calls: [task_call()]},
      %{
        text: "reading",
        calls: [%{id: "child-read", name: "read", arguments: %{"path" => "README.md"}}]
      },
      %{text: "Finding: README is present.", calls: []},
      %{text: "Parent done.", calls: []},
      %{
        text: "",
        calls: [
          %{
            id: "unknown",
            name: "bash",
            arguments: %{"command" => "printf ready > unknown-ready; while :; do sleep 1; done"}
          }
        ]
      }
    ]

    host = boot(source, workspace, workspace_ref, script)
    assert {:ok, parent} = Helper.create_parent(host.helper, capture())
    run = prompt(host.runtime, parent, "parent-prompt")
    assert terminal(host.runtime, parent, run).terminal.state == "completed"
    [{child, _job}] = Map.to_list(Helper.status(host.helper).children)

    {:ok, ordinary} =
      Loopex.create_session(host.runtime, %{},
        command_id: "ordinary",
        genesis: Loopex.ConfiguredGenesisFixture.genesis(bash_definitions(), configuration())
      )

    unknown = prompt(host.runtime, ordinary, "unknown-prompt")
    await_file(Path.join(workspace, "unknown-ready"), System.monotonic_time(:millisecond) + 5_000)
    assert :ok = GenServer.stop(host.lease, :normal, 1_000)
    assert terminal(host.runtime, ordinary, unknown).terminal.state == "outcome_unknown"
    stop(host)

    namespace = Path.join([source, "delegation", hash(@runtime)])
    refute File.exists?(Path.join(namespace, "objects.writer"))
    assert Path.wildcard(Path.join([namespace, "runs", "*.log"])) != []
    assert Path.wildcard(Path.join([namespace, "bindings", "*.log"])) != []
    # The operator excludes the disposable job index from the quiescent root.
    File.rm_rf!(Path.join(namespace, "job-index-v1"))

    assert {:ok, _} = RestoreFixtureCopy.copy(source, backup)
    baseline = manifest(backup)
    assert manifest(source) == baseline
    {:ok, lineage} = RestoreCodec.lineage_digest([])

    plan = %{
      "version" => 1,
      "tx_id" => hash("helper-restore"),
      "source_state_root" => source,
      "source_state_placement" => placement(source),
      "source_status" => "available",
      "backup_state_root" => backup,
      "destination_state_root" => destination,
      "manifest_sha256" => hash(baseline),
      "cut_id" => hash("helper-cut"),
      "prior_restore_count" => 0,
      "prior_lineage_sha256" => lineage,
      "runtime_ids" => [@runtime],
      "stores" => stores(backup),
      "ledgers" => [],
      "workspace" => %{"root" => workspace, "workspace_ref" => workspace_ref},
      "host_attestation" => %{
        "latest_cut" => true,
        "no_post_cut_activity" => true,
        "all_other_copies_excluded" => true,
        "old_authority_termination" => "joined",
        "host_ledgers_validated" => true,
        "evidence_sha256" => hash("helper-joins")
      }
    }

    plan = %{plan | "ledgers" => ledgers(plan, backup)}
    assert {:ok, _} = RestoreCodec.encode(:plan, plan)

    %{
      source: source,
      backup: backup,
      destination: destination,
      workspace: workspace,
      workspace_ref: workspace_ref,
      baseline: baseline,
      plan: plan,
      parent: parent,
      child: child,
      ordinary: ordinary
    }
  end

  defp boot(root, workspace, workspace_ref, script) do
    {:ok, placement} = Placement.acquire(root)
    {:ok, objects} = RetainedObjects.open(root, @runtime, placement)

    if not File.exists?(Path.join(root, "receipts")),
      do: :ok,
      else: {:ok, _} = Ledger.prepare(Path.join(root, "receipts"), "executor-local", @grace)

    {:ok, store_pid} = Store.start_link(path: Path.join(root, "store.log"))
    {:ok, store} = Loopex.Store.new(Store, store_pid)
    {:ok, transfers} = Transfers.start_link(root: Path.join(root, "artifacts"))
    {:ok, artifacts_handle} = Artifacts.open(Path.join(root, "artifacts"))
    artifacts = %{module: Artifacts, handle: Map.put(artifacts_handle, :transfers, transfers)}
    {:ok, lease} = WorkspaceLease.start_link(id: "workspace", path: workspace, fencing_token: 1)

    {:ok, executor} =
      Local.start_link(
        identity: "executor-local",
        epoch: 1,
        fencing_token: 1,
        workspace_leases: %{"workspace" => lease},
        ledger_root: Path.join(root, "receipts"),
        artifacts: artifacts,
        cleanup_grace_ms: @grace
      )

    {:ok, helper} = Helper.start_link(objects: objects, runtime_id: @runtime)
    model = AgentLoopTestModel.start(script)
    definitions = bash_definitions() ++ [Tool.definition()]

    {:ok, runtime} =
      Loopex.start_link(
        runtime_id: @runtime,
        store: store,
        artifact_store: artifacts,
        context_token_budget: 8_192,
        session_creation_defaults:
          Loopex.AgentLoopFixture.creation_defaults(read_definitions(), model: @model),
        model: %{
          module: AgentLoopTestModel,
          model: @model,
          options: [script: model, max_tokens: 256]
        },
        executor:
          Router.wrap(
            %{
              module: Local,
              reference: executor,
              identity: "executor-local",
              epoch: 1,
              fencing_token: 1,
              workspace_ref: workspace_ref,
              workspace_lease: "workspace"
            },
            helper
          ),
        tools: definitions,
        active_tools: Enum.map(definitions, & &1["tool_id"]),
        policy: Loopex.AgentLoopTestPolicy,
        policy_identity: @policy,
        grant_decision: {:host_policy, :allow},
        bounds: %{max_turns: 8, token_budget: 1_000_000, deadline_ms: 600_000}
      )

    :ok = Loopex.ConfiguredGenesisFixture.await_creation_ready(runtime)
    assert :ok = Helper.bind(helper, runtime, store)
    if script != [], do: :ok = Helper.classification(helper, :complete)

    host = %{
      runtime: runtime,
      helper: helper,
      objects: objects,
      placement: placement,
      store: store_pid,
      transfers: transfers,
      lease: lease,
      executor: executor,
      model: model
    }

    on_exit(fn -> kill(host) end)
    host
  end

  # Concept: an orderly stop releases every writer, so the root is quiescent.
  defp stop(host) do
    assert :ok = Loopex.stop(host.runtime)

    for pid <- [host.helper, host.objects, host.store, host.transfers, host.executor, host.lease],
        Process.alive?(pid),
        do: assert(:ok == GenServer.stop(pid, :normal, 5_000))

    assert :ok = Placement.release(host.placement)
  end

  defp kill(host) do
    for pid <- [
          host.runtime.supervisor,
          host.helper,
          host.objects,
          host.store,
          host.transfers,
          host.executor,
          host.lease
        ],
        Process.alive?(pid) do
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 5_000
    end
  end

  defp capture do
    limits = %{
      "roles" => ["inspect"],
      "max_children" => 4,
      "token_budget" => 4_000,
      "child_bounds" => %{"max_turns" => 4, "deadline_ms" => 600_000, "token_budget" => 1_000},
      "max_tokens" => 256
    }

    options = %{"tenant" => "helper"}

    {:ok, genesis} =
      Loopex.Runtime.SessionGenesis.resolve(options, %{
        genesis_version: "session_genesis_v3",
        runtime_configuration: %{"cleanup_grace_ms" => 5_000},
        initial_configuration: configuration(),
        tool_selection: selection(read_definitions() ++ [Tool.definition()]),
        policy_defer_mode: "admit"
      })

    {:ok, role} = Catalog.role_genesis(configuration(), read_definitions(), 5_000)

    {:ok, capture} =
      Catalog.capture(
        @runtime,
        "parent-create",
        @providers,
        %{"inspect" => role},
        limits,
        options,
        genesis
      )

    capture
  end

  defp task_call,
    do: %{
      id: "call-task",
      name: "task",
      arguments: %{"role" => "inspect", "description" => "investigate", "prompt" => "Inspect."}
    }

  defp read_definitions,
    do:
      Enum.filter(
        CodingTools.definitions(),
        &(&1["tool_id"] in ~w(loopex.read loopex.grep loopex.find loopex.ls))
      )

  defp bash_definitions,
    do:
      read_definitions() ++
        Enum.filter(CodingTools.definitions(), &(&1["tool_id"] == "loopex.bash"))

  defp configuration,
    do:
      Loopex.AgentLoopFixture.creation_defaults(read_definitions(), model: @model)[
        "initial_configuration"
      ]

  defp selection(definitions),
    do: %{
      "definitions" => definitions,
      "names" =>
        Map.new(definitions, fn definition ->
          {id, version, digest} = LoopexProtocol.ToolDefinition.generation(definition)

          {definition["name"],
           %{"tool_id" => id, "tool_version" => version, "definition_digest" => digest}}
        end)
    }

  defp prompt(runtime, session, command_id) do
    {:ok, attachment} = Loopex.attach(runtime, session, after_event_sequence: 0)

    assert {:accepted, ^command_id} =
             Loopex.command(attachment, %{type: :prompt, command_id: command_id, content: "go"})

    {:ok, {:committed, :admitted, _code, run}} =
      Loopex.command_disposition(attachment, command_id)

    run
  end

  defp terminal(runtime, session, run, cutoff \\ nil) do
    cutoff = cutoff || System.monotonic_time(:millisecond) + 10_000

    case Loopex.Runtime.run_evidence(runtime, session, run) do
      {:ok, %{terminal: %{}} = evidence} ->
        evidence

      _ ->
        assert System.monotonic_time(:millisecond) < cutoff, "run did not end"
        Process.sleep(10)
        terminal(runtime, session, run, cutoff)
    end
  end

  defp await_file(path, cutoff) do
    case File.read(path) do
      {:ok, "ready"} ->
        :ok

      _ ->
        assert System.monotonic_time(:millisecond) < cutoff
        Process.sleep(5)
        await_file(path, cutoff)
    end
  end

  defp stores(backup),
    do: [
      %{
        "relative_path" => "store.log",
        "sha256" => hash(File.read!(Path.join(backup, "store.log")))
      }
    ]

  defp ledgers(plan, backup) do
    bytes = File.read!(Path.join([backup, "receipts", "generation"]))
    {:ok, generation} = RestoreCodec.decode(:generation, bytes)

    [
      %{
        "relative_root" => "receipts",
        "executor_identity" => generation["executor_identity"],
        "source_generation_sha256" => hash(bytes),
        "source_placement" => placement(Path.join(plan["source_state_root"], "receipts"))
      }
    ]
  end

  defp invocation,
    do: %{
      "work_ms" => @work,
      "cleanup_grace_ms" => @grace,
      "max_total_file_bytes" => @total,
      "prior_admin_authority" => "none",
      "prior_admin_evidence_sha256" => nil
    }

  defp manifest(root) do
    assert {:joined, {:ok, bytes}, _} =
             RestoreIO.run({:manifest, root, @total}, %{
               "work_ms" => @work,
               "cleanup_grace_ms" => @grace
             })

    bytes
  end

  defp placement(path) do
    stat = File.lstat!(path)
    %{"expanded_root" => path, "major_device" => stat.major_device, "inode" => stat.inode}
  end

  defp hash(bytes), do: Canonical.digest_bytes(bytes)
end
