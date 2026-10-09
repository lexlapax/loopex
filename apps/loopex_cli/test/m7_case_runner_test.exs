Code.require_file("../../loopex/test/support/m1_runtime_helper.exs", __DIR__)
Code.require_file("../../loopex/test/support/agent_loop_helper.exs", __DIR__)

defmodule LoopexCli.M7CaseRunnerTest do
  use ExUnit.Case, async: false
  @moduletag capture_log: true

  # Concept: the dispatching entrypoint is proved credential-free. A scripted
  # model stands in only for the provider; admission, the attempts index, the
  # fixture policy, the real executor, oracle reruns and change inspection are
  # the production paths.

  alias LoopexCli.ChatConfiguration
  alias Mix.Tasks.Loopex.M7Evidence.{AttemptEvents, AttemptWriter, CaseRunner, FixtureManifest}

  @fixtures Path.expand("../../../test/fixtures/m7", __DIR__)
  @candidate String.duplicate("1", 40)
  @fixed "defmodule Ledger do\n  def total(entries), do: Enum.sum(entries)\nend\n"

  setup do
    root = Path.join(System.tmp_dir!(), "m7-case-runner-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "runs"))
    File.mkdir_p!(Path.join(root, "markers"))
    on_exit(fn -> File.rm_rf!(root) end)
    isolated_signal_manager()

    identity = %{
      "writer_id" => "writer-1",
      "host_id" => "host-1",
      "marker_dir" => Path.join(root, "markers")
    }

    {:ok, catalog} = FixtureManifest.load(@fixtures)
    index = Path.join(root, "attempts.jsonl")
    campaign = catalog.catalog["execution_manifest"]["campaign_id"]
    {:ok, writer} = AttemptWriter.create(index, campaign, identity)
    [_, designation] = records(index)
    config = Path.join(root, "template.json")
    File.write!(config, :json.encode(profile(root)))

    context = %{
      manifest: lane(catalog.catalog, ["m7.repair"]),
      manifest_digest: catalog.digest,
      catalog_root: @fixtures,
      run_root: Path.join(root, "runs"),
      candidate: @candidate,
      concept: head_line(designation),
      config_argv: ["chat", "--config", config],
      cwd: root,
      operator: "Maintainer"
    }

    %{root: root, writer: writer, index: index, context: context, config: config}
  end

  test "a repair attempt is recorded before dispatch, reopens its session and passes independently",
       f do
    parent = self()

    scripts = fn capture, call ->
      if call == 1,
        do: repair_script(capture.argv, @fixed),
        else: [%{text: "the empty-ledger boundary", calls: []}]
    end

    context = Map.put(f.context, :chat_options, chat_options(f, scripts, parent))
    result = passed!(CaseRunner.run_lane(f.writer, "m7-operator", context))
    assert result.mechanical_result == "pass"

    # Both conversations saw the started record already in the index.
    assert_received {:index_at_dispatch, 1, before_first}
    assert_received {:index_at_dispatch, 2, _}
    assert List.last(before_first)["body"]["state"] == "started"
    refute_received {:index_at_dispatch, 3, _}

    [_, _, started, completed] = records(f.index)
    assert started["body"]["attempt_id"] == completed["body"]["attempt_id"]
    assert completed["body"]["mechanical_result"] == "pass"
    assert completed["body"]["case_key"] == "m7.repair"
    assert completed["body"]["lane_id"] == "m7-operator"

    references = Enum.map(completed["body"]["evidence"], & &1["reference"])
    names = Enum.map(references, &Path.basename/1)

    for name <- ~w(execution.json oracle.txt changes.json transcript-1.txt transcript-2.txt),
        do: assert(name in names)

    for reference <- completed["body"]["evidence"] do
      bytes = File.read!(reference["reference"])
      assert LoopexProtocol.Canonical.digest_bytes(bytes) == reference["sha256"]
    end

    oracle = File.read!(Enum.find(references, &String.ends_with?(&1, "oracle.txt")))
    assert oracle =~ "status=0"
    assert File.read!(Path.join(result.root, "workspace/lib/ledger.ex")) == @fixed

    assert {:blocked, %{reason: :lane_already_ended}} =
             AttemptWriter.admit(
               f.writer,
               f.context.concept,
               lane_selection(f),
               :continue
             )
  end

  test "a failing oracle completes as assertion_failed and stops the lane", f do
    context =
      f.context
      |> Map.put(:manifest, lane(f.context.manifest, ["m7.repair", "m7.external"]))
      |> Map.put(
        :chat_options,
        chat_options(f, fn capture, _ -> repair_script(capture.argv, "broken\n") end, self())
      )

    assert {:stopped, [{:ok, result}]} = CaseRunner.run_lane(f.writer, "m7-operator", context)
    assert result.mechanical_result == "assertion_failed"
    [_, _, _, completed] = records(f.index)
    assert completed["body"]["mechanical_result"] == "assertion_failed"
    assert Enum.count(records(f.index), &(&1["body"]["case_key"] == "m7.external")) == 0

    assert {:blocked, %{reason: :consumed_lane_failure}} =
             AttemptWriter.admit(f.writer, f.context.concept, lane_selection(f), :continue)
  end

  test "a preparation refusal records a not-dispatched stop and no conversation runs", f do
    File.write!(f.config, :json.encode(Map.delete(profile(f.root), "paths")))
    parent = self()
    context = Map.put(f.context, :chat_options, chat_options(f, fn _, _ -> [] end, parent))

    assert {:stopped, [{:ok, result}]} = CaseRunner.run_lane(f.writer, "m7-operator", context)
    assert result.mechanical_result == "evidence_incomplete_pre_dispatch"
    refute_received {:index_at_dispatch, _, _}
    [_, _, pending] = records(f.index)
    assert pending["body"]["state"] == "not_dispatched"
    assert pending["body"]["attempt_id"] == nil
    [preflight] = pending["body"]["evidence"]
    assert File.read!(preflight["reference"]) =~ "invalid_m7_config"
  end

  test "the external task runs in a disposable checkout and inspects only allowed changes", f do
    {catalog_root, repository} = external_catalog(f.root)
    {:ok, catalog} = FixtureManifest.load(catalog_root)

    fixed =
      String.replace(
        base_threads(),
        "    return re.sub",
        "    name = unicodedata.normalize(\"NFKD\", name).encode(\"ascii\", \"ignore\").decode()\n    return re.sub"
      )

    fixed = String.replace(fixed, "import re\n", "import re\nimport unicodedata\n")

    script = fn capture, _ ->
      [
        %{
          text: "fix",
          calls: [
            %{
              id: "fix",
              name: "write",
              arguments: %{"path" => "tools/threads.py", "content" => fixed}
            }
          ]
        },
        %{
          text: "test",
          calls: [%{id: "oracle", name: "bash", arguments: %{"argv" => capture.argv}}]
        },
        %{text: "done", calls: []}
      ]
    end

    context =
      f.context
      |> Map.merge(%{
        manifest: lane(catalog.catalog, ["m7.external"]),
        manifest_digest: catalog.digest,
        catalog_root: catalog_root,
        external_repository: repository,
        chat_options: chat_options(f, script, self())
      })

    result = passed!(CaseRunner.run_lane(f.writer, "m7-operator", context))
    assert result.mechanical_result == "pass"
    changes = File.read!(Path.join(result.root, "records/changes.json"))
    assert JSON.decode!(changes)["changed"] == ["tools/threads.py"]
    assert File.read!(Path.join(result.root, "records/oracle.txt")) =~ "status=0"
    # The source repository itself is untouched and has no remote push path.
    assert {"", 0} = System.cmd("git", ["-C", repository, "status", "--porcelain"])
    assert {"", 0} = System.cmd("git", ["-C", Path.join(result.root, "workspace"), "remote"])
  end

  test "an unchanged external checkout fails its oracle and a stray write is denied",
       f do
    {catalog_root, repository} = external_catalog(f.root)
    {:ok, catalog} = FixtureManifest.load(catalog_root)

    script = fn capture, _ ->
      [
        %{
          text: "stray",
          calls: [
            %{id: "stray", name: "write", arguments: %{"path" => "README.md", "content" => "x\n"}}
          ]
        },
        %{
          text: "test",
          calls: [%{id: "oracle", name: "bash", arguments: %{"argv" => capture.argv}}]
        },
        %{text: "done", calls: []}
      ]
    end

    context =
      Map.merge(f.context, %{
        manifest: lane(catalog.catalog, ["m7.external"]),
        manifest_digest: catalog.digest,
        catalog_root: catalog_root,
        external_repository: repository,
        chat_options: chat_options(f, script, self())
      })

    assert {:stopped, [{:ok, result}]} = CaseRunner.run_lane(f.writer, "m7-operator", context)
    assert result.mechanical_result == "assertion_failed"
    oracle = File.read!(Path.join(result.root, "records/oracle.txt"))
    assert oracle =~ "status=2" and oracle =~ "cafe-society"
    assert File.read!(Path.join(result.root, "workspace/README.md")) == "fixture\n"
  end

  test "the wrapper command checks admission without staging and refuses bad arguments", f do
    :ok = AttemptWriter.close(f.writer)
    root = Path.expand("../../..", __DIR__)

    args = [
      "--lane",
      "m7-operator",
      "--attempts-index",
      f.index,
      "--writer",
      "writer-1",
      "--host",
      "host-1",
      "--markers",
      Path.join(f.root, "markers"),
      "--run-root",
      Path.join(f.root, "runs"),
      "--operator",
      "Maintainer",
      "--check",
      "chat",
      "--config",
      f.config
    ]

    output =
      ExUnit.CaptureIO.capture_io(fn ->
        assert CaseRunner.main(args, %{root: root, candidate: @candidate}) == 2
      end)

    assert output =~ "m7_cases_pending"
    assert File.ls!(Path.join(f.root, "runs")) == []

    output =
      ExUnit.CaptureIO.capture_io(fn ->
        assert CaseRunner.main(
                 List.delete(args, "--check") -- ["chat", "--config", f.config],
                 %{root: root, candidate: @candidate}
               ) == 2
      end)

    assert output =~ "evidence unavailable"

    script = Path.join(root, "scripts/m7-fixture-chat.exs")
    assert File.read!(script) =~ "CaseRunner.main"
  end

  # A failed pass expectation reports the retained transcripts and oracle.
  defp passed!({:ok, [{:ok, %{mechanical_result: "pass"} = result}]}), do: result

  defp passed!({_, [{:ok, %{root: root}} | _]} = other) do
    records = Path.join(root, "records")

    retained =
      for name <- File.ls!(records), into: %{}, do: {name, File.read!(Path.join(records, name))}

    flunk(inspect(%{lane: elem(other, 0), records: retained}, pretty: true, limit: :infinity))
  end

  defp passed!(other), do: flunk(inspect(other))

  defp repair_script(argv, content) do
    [
      %{text: "the empty ledger reaches a missing base case", calls: []},
      %{
        text: "fix",
        calls: [
          %{
            id: "fix",
            name: "write",
            arguments: %{"path" => "lib/ledger.ex", "content" => content}
          }
        ]
      },
      %{text: "fixed", calls: []},
      %{text: "test", calls: [%{id: "oracle", name: "bash", arguments: %{"argv" => argv}}]},
      %{text: "tested", calls: []}
    ]
  end

  defp chat_options(_f, scripts, parent) do
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    [
      provider_launch: fn -> [] end,
      acquire_placement: fn _, _ -> {:ok, :test_lock} end,
      release_placement: fn _, _ -> :ok end,
      placement_id: fn _ -> {:ok, "case-runner-runtime"} end,
      with_runtime: fn options, callback ->
        call = Agent.get_and_update(calls, &{&1 + 1, &1 + 1})
        capture = options[:policy].context

        index =
          Path.join([
            Path.dirname(Path.dirname(Path.dirname(capture.workspace))),
            "attempts.jsonl"
          ])

        send(parent, {:index_at_dispatch, call, records(index)})
        with_stack(options, scripts.(capture, call), callback)
      end
    ]
  end

  defp with_stack(options, script, callback) do
    state = options[:state_root]
    File.mkdir_p!(state)
    {:ok, adapter} = Loopex.Store.Local.start_link(path: Path.join(state, "store.log"))
    {:ok, store} = Loopex.Store.new(Loopex.Store.Local, adapter)
    capture = options[:policy].context

    {:ok, lease} =
      Loopex.Executor.Local.WorkspaceLease.start_link(
        id: "workspace",
        path: options[:workspace],
        fencing_token: 1
      )

    {:ok, executor} =
      Loopex.Executor.Local.start_link(
        identity: "fixture-executor",
        epoch: 1,
        fencing_token: 1,
        workspace_leases: %{"workspace" => lease},
        ledger_root: Path.join(state, "receipts")
      )

    model = Loopex.AgentLoopTestModel.start(script)

    {:ok, runtime} =
      Loopex.start_link(
        runtime_id: "case-runner-runtime",
        context_token_budget: 8192,
        store: store,
        policy: options[:policy],
        policy_identity: options[:policy_identity],
        model: %{
          module: Loopex.AgentLoopTestModel,
          model: options[:model],
          options: [script: model]
        },
        executor: %{
          module: Loopex.Executor.Local,
          reference: executor,
          identity: "fixture-executor",
          epoch: 1,
          fencing_token: 1,
          workspace_ref: capture.workspace_ref,
          workspace_lease: "workspace"
        },
        tools: ChatConfiguration.selected_definitions(ChatConfiguration.active_tools("coding")),
        cleanup_grace_ms: options[:cleanup_grace_ms]
      )

    {:ok, startup_deadline} = LoopexComposition.StartupGate.await(runtime)
    :ok = LoopexComposition.StartupGate.publication({:ok, startup_deadline})

    try do
      callback.(runtime)
    after
      ref = Process.monitor(runtime.supervisor)
      :ok = Loopex.stop(runtime)
      assert_receive {:DOWN, ^ref, :process, _, _}, 5000

      for pid <- [executor, lease, adapter, model], is_pid(pid) do
        Process.unlink(pid)
        if Process.alive?(pid), do: GenServer.stop(pid, :normal, 1000)
      end
    end
  end

  defp profile(root) do
    %{
      "schema_version" => 1,
      "providers" => %{
        "anthropic" => %{"credential" => %{"env" => "M7_UNUSED_FIXTURE_REFERENCE"}}
      },
      "policy" => "shell-allowlist",
      "paths" => %{"workspace" => root, "state_root" => Path.join(root, "unused")},
      "session" => %{
        "model" => "anthropic:claude-haiku-4-5",
        "tools" => "coding",
        "system_class_tokens" => 8000,
        "bounds" => %{"max_turns" => 8, "deadline_ms" => 15_000, "token_budget" => 100_000}
      }
    }
  end

  defp external_catalog(root) do
    repository = Path.join(root, "lapaxworks")
    File.mkdir_p!(Path.join(repository, "tools"))
    File.write!(Path.join(repository, "tools/threads.py"), base_threads())
    File.write!(Path.join(repository, "README.md"), "fixture\n")
    git = &System.cmd("git", ["-C", repository | &1], stderr_to_stdout: true)
    {_, 0} = git.(["init", "-q"])
    {_, 0} = git.(["add", "."])

    {_, 0} =
      git.([
        "-c",
        "user.name=Fixture",
        "-c",
        "user.email=fixture@invalid",
        "-c",
        "commit.gpgsign=false",
        "commit",
        "-qm",
        "fixture"
      ])

    {sha, 0} = git.(["rev-parse", "HEAD"])
    catalog_root = Path.join(root, "catalog")
    File.cp_r!(@fixtures, catalog_root)
    manifest = Path.join(catalog_root, "manifest.json")
    catalog = JSON.decode!(File.read!(manifest))
    catalog = put_in(catalog, ["external", "base_sha"], String.trim(sha))
    File.write!(manifest, JSON.encode!(catalog))
    {catalog_root, repository}
  end

  defp base_threads do
    """
    import re
    import sys


    def slugify(name):
        return re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")


    if __name__ == "__main__":
        if "--check" in sys.argv:
            print("threads: up to date")
    """
  end

  defp lane(catalog, cases) do
    lanes = catalog["execution_manifest"]["lanes"]

    catalog
    |> put_in(["execution_manifest", "lanes"], %{lanes | "m7-operator" => cases})
    |> update_in(["execution_manifest", "cases"], fn all ->
      Map.new(all, fn {id, entry} ->
        {id, if(id in cases, do: %{entry | "status" => "ready"}, else: entry)}
      end)
    end)
  end

  defp lane_selection(f) do
    {:ok, selection} =
      Mix.Tasks.Loopex.M7Evidence.ExecutionManifest.selection(
        f.context.manifest["execution_manifest"],
        f.context.manifest_digest,
        "m7-operator",
        @candidate,
        nil
      )

    selection
  end

  defp records(index) do
    index
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(fn line ->
      {:ok, record} = AttemptEvents.decode(line)
      record
    end)
  end

  defp head_line(record),
    do: "index-head: #{record["campaign_id"]} #{record["sequence"]} #{record["digest"]}"

  defp isolated_signal_manager do
    original = Process.whereis(:erl_signal_server)
    {:ok, manager} = :gen_event.start()
    :ok = :gen_event.add_handler(manager, :erl_signal_handler, [])
    Process.unregister(:erl_signal_server)
    true = Process.register(manager, :erl_signal_server)

    on_exit(fn ->
      if Process.whereis(:erl_signal_server) == manager,
        do: Process.unregister(:erl_signal_server)

      if Process.alive?(manager), do: :gen_event.stop(manager)

      if is_pid(original) and Process.alive?(original),
        do: Process.register(original, :erl_signal_server)
    end)
  end
end
