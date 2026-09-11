Code.require_file(
  "../../loopex_llm_reqllm/test/support/provider_isolation_fixture.exs",
  __DIR__
)

defmodule LoopexCli.FoundationNoEffectModel do
  @moduledoc false
  @behaviour Loopex.Model

  @impl Loopex.Model
  def complete(_request, options, _progress) do
    Agent.update(
      Keyword.fetch!(options, :counter),
      &Map.update!(&1, :model, fn count -> count + 1 end)
    )

    {:error, :unexpected_model_dispatch}
  end
end

defmodule LoopexCli.FoundationNoEffectExecutor do
  @moduledoc false
  @behaviour Loopex.Executor

  @impl Loopex.Executor
  def execute(counter, _job, _grant, _lease, _progress) do
    Agent.update(counter, &Map.update!(&1, :executor, fn count -> count + 1 end))
    {:error, :unexpected_executor_dispatch}
  end

  @impl Loopex.Executor
  def cancel(_counter, _job_id), do: {:ok, :cleaned}
end

defmodule LoopexCli.FoundationWorkflowTest do
  use ExUnit.Case, async: false

  alias Loopex.Executor.Local.CodingTools
  alias Loopex.LLM.ReqLLM
  alias Loopex.LLM.ReqLLM.ProviderIsolationFixture, as: ProviderFixture
  alias Loopex.ResourcePack
  alias Loopex.Store
  alias Loopex.Store.Local.Log
  alias LoopexCli.Policy.AllowAll

  setup do
    :persistent_term.erase({AllowAll, :announced})
    on_exit(&LoopexCli.release_placement/0)
    :ok
  end

  test "isolated provider responses preserve request order for the pending tool workflow" do
    credential = "m3-foundation-local-provider"

    fixture =
      ProviderFixture.new(:reply,
        credential: credential,
        response_bodies: [
          text_response("first", "msg_first"),
          text_response("second", "msg_second")
        ]
      )

    variable = ReqLLM.credential_variable()
    previous = System.get_env(variable)
    System.put_env(variable, credential)

    try do
      assert {:ok, first} = ProviderFixture.complete(fixture)
      assert {:ok, second} = ProviderFixture.complete(fixture)
      assert first.text == "first"
      assert second.text == "second"
      assert ProviderFixture.methods(fixture) == ["POST", "POST"]
    after
      if previous,
        do: System.put_env(variable, previous),
        else: System.delete_env(variable)
    end
  end

  # Concept: both public entry points perform the complete workflow against the
  # isolated provider. The separately required attended case binds the clean
  # source-built CLI and production companion artifact.
  #
  # Technical depth: the reviewed M3 workflow-evidence disposition preserves
  # both obligations while keeping credentials out of this deterministic lane.
  # This lane's test main supplies a host_supplied decision through dispatch/2;
  # only the attended selector binds exact production LoopexCli.main/1 and companion bytes.
  test "embedding and the source built CLI complete the same skill tool and full artifact workflow" do
    credential = "m3-foundation-workflow"
    variable = ReqLLM.credential_variable()
    previous = System.get_env(variable)
    System.put_env(variable, credential)

    on_exit(fn ->
      if previous,
        do: System.put_env(variable, previous),
        else: System.delete_env(variable)
    end)

    embedded = workflow_fixture("embedded", credential)

    {:ok, embedded_runtime} =
      LoopexComposition.start(
        state_root: embedded.state_root,
        workspace: embedded.workspace,
        runtime_id: "foundation-embedded",
        policy: AllowAll,
        provider_launch: embedded.provider.options,
        resource_manifest: embedded.manifest
      )

    on_exit(fn -> stop_runtime(embedded_runtime) end)
    run_embedded(embedded_runtime, embedded)
    embedded_locator = assert_provider_workflow(embedded)
    {:ok, embedded_artifacts} = LoopexComposition.artifacts(embedded.state_root)

    assert {:ok, embedded_bytes} =
             Loopex.ArtifactStore.retrieve(embedded_artifacts, embedded_locator)

    assert embedded_bytes == embedded.full

    cli = workflow_fixture("cli", credential)
    cli_binary = build_isolated_provider_cli(cli)

    {cli_output, 0} =
      run_cli_process(
        cli_binary,
        [
          "run",
          "--policy",
          "allow-all",
          "--skill",
          "review",
          "--skill-resource",
          "review:references/checklist.md",
          "--state-root",
          cli.state_root,
          "--workspace",
          cli.workspace,
          "Use the review skill and inspect large.txt."
        ],
        nil
      )

    assert cli_output =~ "artifact retained"
    assert cli_output =~ "loopex.read: completed"
    cli_locator = assert_provider_workflow(cli)

    assert {cli.full, 0} ==
             run_cli_process(
               cli_binary,
               ["artifact", cli_locator, "--state-root", cli.state_root],
               nil
             )
  end

  # Concept: a fresh CLI process recovers the exact skill content admitted by
  # the prior process while preserving its configured provider launch.
  #
  # Technical depth: one source-built CLI completes the real skill/tool/artifact
  # workflow. Its genuine journal is retained at the settled tool-result frame,
  # before the next provider request. A second operating-system process uses the
  # production preparation bracket, loads the admitted snapshot, and stages the
  # pending turn with the prior provider and executor history.
  test "trusted launch and fresh process recovery preserve resource and provider configuration" do
    workflow = configured_recovery_workflow("recovery")
    {session_id, first_output} = complete_cli_workflow(workflow)
    locator = completed_artifact_locator(workflow)
    rewind_after_tool_result(workflow, session_id)
    changed = replace_workspace_resources(workflow)
    {recovery_output, 0} = resume_cli_workflow(workflow, session_id)

    assert first_output =~ "artifact retained"
    assert recovery_output =~ "artifact retained after recovery"

    assert [{first, true}, {second, true}, {recovered, true}] =
             ProviderFixture.events(workflow.provider)

    assert workflow.instruction in Enum.map(first["messages"], & &1["content"])
    assert workflow.support in Enum.map(first["messages"], & &1["content"])
    assert Jason.encode!(second) =~ "output truncated"
    assert workflow.instruction in Enum.map(recovered["messages"], & &1["content"])
    assert workflow.support in Enum.map(recovered["messages"], & &1["content"])
    refute changed.instruction in Enum.map(recovered["messages"], & &1["content"])
    refute changed.support in Enum.map(recovered["messages"], & &1["content"])
    assert Jason.encode!(recovered) =~ "output truncated"

    assert {workflow.full, 0} ==
             run_cli_process(
               workflow.cli_binary,
               ["artifact", locator, "--state-root", workflow.state_root],
               nil
             )
  end

  test "fresh recovery withholds resources when the admitted snapshot is missing" do
    workflow = configured_recovery_workflow("missing-recovery")
    {session_id, first_output} = complete_cli_workflow(workflow)
    rewind_after_tool_result(workflow, session_id)
    changed = replace_workspace_resources(workflow)

    retained =
      Path.join([
        workflow.state_root,
        "resource-packs",
        "manifests",
        workflow.digest <> ".etf"
      ])

    File.rm!(retained)
    {recovery_output, 0} = resume_cli_workflow(workflow, session_id)

    assert first_output =~ "artifact retained"
    assert recovery_output =~ "admitted skill snapshot is unavailable"
    assert recovery_output =~ "artifact retained"

    assert [{first, true}, {_second, true}, {recovered, true}] =
             ProviderFixture.events(workflow.provider)

    recovered_contents = Enum.map(recovered["messages"], & &1["content"])

    first
    |> Map.fetch!("messages")
    |> Enum.take(3)
    |> Enum.each(fn message -> refute message["content"] in recovered_contents end)

    refute changed.instruction in Enum.map(recovered["messages"], & &1["content"])
    refute changed.support in Enum.map(recovered["messages"], & &1["content"])
    assert Jason.encode!(recovered) =~ "output truncated"
  end

  test "new readers preserve genuine M2 history and old readers refuse new records before effects" do
    root = owned_root("compatibility")

    old = build_m2_reader(root)
    written = Path.join(root, "m2-written")
    File.mkdir_p!(written)

    assert run_compatibility_probe(old.paths, old.probe, "write-v2", written, root) =~
             "writer=model_attempt_settled_v2 ready=true model_calls=1"

    old_control = Path.join(root, "m2-old-reader-control")
    new_control = Path.join(root, "m2-new-reader-control")
    File.cp_r!(written, old_control)
    File.cp_r!(written, new_control)

    old_journal = File.read!(Path.join(old_control, "store.log"))
    old_ready = run_compatibility_probe(old.paths, old.probe, "read-v1", old_control, root)
    assert old_ready =~ "reader=ready model_calls=0 semantic_records=0 public_events=0"
    assert old_ready =~ "session_state_beam=#{Path.join(old.build, "lib/loopex/ebin")}/"
    assert File.read!(Path.join(old_control, "before-reader.log")) == old_journal
    assert File.read!(Path.join(old_control, "store.log")) |> String.starts_with?(old_journal)

    current_paths = current_reader_paths()
    current_journal = File.read!(Path.join(new_control, "store.log"))

    current_ready =
      run_compatibility_probe(current_paths, old.probe, "read-v1", new_control, root)

    assert current_ready =~ "reader=ready model_calls=0 semantic_records=0 public_events=0"
    assert current_ready =~ "session_state_beam=#{Enum.at(current_paths, 1)}/"
    assert File.read!(Path.join(new_control, "before-reader.log")) == current_journal
    assert File.read!(Path.join(new_control, "store.log")) |> String.starts_with?(current_journal)

    for variant <- [:accepted_command, :refused_command, :resource_request] do
      resource_root = Path.join(root, "m3-resource-#{variant}")
      history = write_resource_history(resource_root, variant)
      resource_journal = File.read!(Path.join(resource_root, "store.log"))

      if variant == :resource_request,
        do: assert_old_reader_reaches_resource_request(old.paths, history, resource_root, root)

      refused =
        run_compatibility_probe(old.paths, old.probe, "read-v2-refused", resource_root, root)

      assert refused =~ "reader=refused model_calls=0 semantic_records=0 public_events=0"
      assert refused =~ "session_state_beam=#{Path.join(old.build, "lib/loopex/ebin")}/"
      assert File.read!(Path.join(resource_root, "before-reader.log")) == resource_journal

      assert File.read!(Path.join(resource_root, "store.log"))
             |> String.starts_with?(resource_journal)
    end
  end

  defp build_m2_reader(root) do
    source = Path.join(root, "m2-source")
    build = Path.join(root, "m2-build")
    repository = Path.expand("../../..", __DIR__)
    closure = "b637873ddc39542ec27add71015b46a4f7c7f80e"

    git_environment = [
      {"HOME", root},
      {"GIT_CONFIG_GLOBAL", "/dev/null"},
      {"GIT_CONFIG_NOSYSTEM", "1"}
    ]

    command!(
      "git",
      ["clone", "--shared", "--no-checkout", repository, source],
      root,
      git_environment
    )

    command!("git", ["checkout", "--detach", closure], source, git_environment)
    assert String.trim(command!("git", ["rev-parse", "HEAD"], source, git_environment)) == closure

    assert command!(
             "git",
             ["status", "--porcelain=v1", "--untracked-files=all"],
             source,
             git_environment
           ) == ""

    environment = isolated_mix_environment(root, build)

    for application <- ["loopex_protocol", "loopex", "loopex_store_local"] do
      command!(
        System.find_executable("mix") || flunk("Mix executable unavailable"),
        ["compile", "--no-deps-check", "--warnings-as-errors"],
        Path.join([source, "apps", application]),
        environment
      )
    end

    paths =
      for application <- ["loopex_protocol", "loopex", "loopex_store_local"] do
        Path.join([build, "lib", application, "ebin"])
      end

    assert Enum.all?(paths, &File.dir?/1)

    %{
      build: build,
      paths: paths,
      probe: Path.join([source, "scripts", "provider-accounting-rollback.exs"])
    }
  end

  defp isolated_mix_environment(root, build) do
    [
      {"HOME", root},
      {"TMPDIR", root},
      {"MIX_ENV", "test"},
      {"MIX_BUILD_PATH", build},
      {"MIX_HOME", Path.join(root, "mix-home")},
      {"HEX_HOME", Path.join(root, "hex-home")},
      # Every compiler owns a unique task-root build, so no cross-process lock
      # protects shared bytes and Mix's TCP fallback is deliberately unnecessary.
      {"MIX_OS_CONCURRENCY_LOCK", "0"},
      {"LOOPEX_HOME", root},
      {"LOOPEX_PROVIDER_API_KEY", nil},
      {"ANTHROPIC_API_KEY", nil},
      {"OPENAI_API_KEY", nil},
      {"ERL_CRASH_DUMP", "/dev/null"},
      {"ERL_CRASH_DUMP_SECONDS", "0"}
    ]
  end

  defp current_reader_paths do
    for application <- [:loopex_protocol, :loopex, :loopex_store_local] do
      path = Application.app_dir(application, "ebin")
      assert File.dir?(path)
      path
    end
  end

  defp run_compatibility_probe(paths, probe, mode, root, environment_root) do
    elixir = System.find_executable("elixir") || flunk("Elixir executable unavailable")
    path_arguments = Enum.flat_map(paths, &["-pa", &1])

    command!(
      elixir,
      path_arguments ++ [probe, mode, root],
      environment_root,
      isolated_mix_environment(environment_root, Path.join(environment_root, "unused-build"))
    )
  end

  # Concept: the complete resource history proves rollback refusal, while this
  # isolated record-format vector proves which later record the M2 reducer rejects.
  #
  # Technical depth: a genuine resource request necessarily follows an admitted
  # resource command, which an M2 reducer rejects first. Keep the exact captured
  # request payload and owner stamps, change only its journal position so it is
  # the next row after the genuine genesis/owner prefix, and prove that prefix
  # succeeds immediately before the added kind returns invalid private history.
  defp assert_old_reader_reaches_resource_request(paths, history, root, environment_root) do
    prefix = Enum.take(history.records, 2)

    captured =
      Enum.find(history.records, &(&1.payload.kind == "model_request_committed_resources_v1"))

    candidate = %{captured | journal_version: List.last(prefix).journal_version + 1}
    assert candidate.payload === captured.payload
    assert Map.drop(candidate, [:journal_version]) === Map.drop(captured, [:journal_version])

    vector = Path.join(root, "resource-request-record-format.term")

    File.write!(vector, :erlang.term_to_binary({history.session_id, prefix, candidate}), [
      :exclusive
    ])

    probe = """
    [vector] = System.argv()
    {session_id, prefix, candidate} = vector |> File.read!() |> :erlang.binary_to_term([:safe])
    {:ok, _state} = Loopex.Runtime.SessionState.recover(session_id, prefix, [])
    {:error, :invalid_private_history} =
      Loopex.Runtime.SessionState.recover(session_id, prefix ++ [candidate], [])
    IO.puts("reader=refused_at_kind kind=\#{candidate.payload.kind} prefix=ready")
    """

    elixir = System.find_executable("elixir") || flunk("Elixir executable unavailable")
    path_arguments = Enum.flat_map(paths, &["-pa", &1])

    output =
      command!(
        elixir,
        path_arguments ++ ["-e", probe, "--", vector],
        environment_root,
        isolated_mix_environment(environment_root, Path.join(environment_root, "unused-build"))
      )

    assert output =~
             "reader=refused_at_kind kind=model_request_committed_resources_v1 prefix=ready"
  end

  defp command!(executable, arguments, directory, environment) do
    {output, status} =
      System.cmd(executable, arguments,
        cd: directory,
        env: environment,
        stderr_to_stdout: true
      )

    assert status == 0,
           "command failed (#{Path.basename(executable)} #{Enum.join(arguments, " ")}):\n#{output}"

    output
  end

  defp write_resource_history(root, variant) do
    File.mkdir_p!(root)
    File.write!(Path.join(root, "probe-owned"), "LOOPEX_ACCOUNTING_ROLLBACK_PROBE_V1\n")
    {:ok, store_pid} = Store.Local.start_link(path: Path.join(root, "store.log"))
    {:ok, store} = Store.new(Store.Local, store_pid)
    {:ok, counter} = Agent.start_link(fn -> %{model: 0, executor: 0} end)
    {manifest, digest, decision} = compatibility_manifest()

    {:ok, runtime} =
      Loopex.start_link(
        runtime_id: "m3-resource-rollback-probe",
        store: store,
        context_token_budget: 8_192,
        cleanup_grace_ms: 250,
        model: %{
          module: LoopexCli.FoundationNoEffectModel,
          model: "scripted:no-effects",
          options: [counter: counter, max_tokens: 256]
        },
        executor: %{
          module: LoopexCli.FoundationNoEffectExecutor,
          reference: counter,
          identity: "resource-rollback-no-effects",
          epoch: 1,
          fencing_token: 1,
          workspace_ref: "m3-resource-workspace",
          workspace_lease: "m3-resource-workspace"
        },
        policy: AllowAll,
        tools: [],
        active_tools: [],
        bounds: %{max_turns: 2, token_budget: 10_000, deadline_ms: 30_000},
        resource_manifest: manifest
      )

    try do
      {:ok, session_id} =
        Loopex.create_session(runtime, %{"purpose" => "resource rollback refusal"},
          command_id: "create"
        )

      {:ok, attachment} = Loopex.attach(runtime, session_id, after_event_sequence: 0)

      admit = %{
        type: :admit_resources,
        command_id: "admit",
        manifest_digest: digest,
        decision: decision
      }

      activate = %{
        type: :activate_skill,
        command_id: "activate",
        manifest_digest: digest,
        source_id: "project",
        name: "compatibility",
        pack_digest: ResourcePack.pack_digest(hd(manifest["packs"])),
        supporting_labels: []
      }

      {expected_disposition, expected_model_calls} =
        case variant do
          :accepted_command ->
            assert {:accepted, "admit"} = Loopex.command(attachment, admit)
            {"accepted", 0}

          :refused_command ->
            assert {:error, :resource_not_admitted} = Loopex.command(attachment, activate)
            {"resource_not_admitted", 0}

          :resource_request ->
            assert {:accepted, "admit"} = Loopex.command(attachment, admit)

            assert {:accepted, "prompt"} =
                     Loopex.command(attachment, %{
                       type: :prompt,
                       command_id: "prompt",
                       content: "Exercise the resource-bearing request format."
                     })

            assert %{"outcome" => "failed"} = await_finished(attachment)
            {"accepted", 1}
        end

      assert {:ok, records} = Store.load_records(store, session_id, 0, 128)

      resource_records = Enum.filter(records, &(&1.payload.kind == "resource_command_v1"))

      assert [%{"disposition" => ^expected_disposition}] =
               Enum.map(resource_records, & &1.payload)

      assert Agent.get(counter, & &1) == %{model: expected_model_calls, executor: 0}

      if variant == :resource_request,
        do:
          assert(Enum.any?(records, &(&1.payload.kind == "model_request_committed_resources_v1")))

      File.write!(Path.join(root, "session-id"), session_id <> "\n")
      %{session_id: session_id, records: records}
    after
      :ok = Loopex.stop(runtime)
      :ok = GenServer.stop(store_pid, :normal, 5_000)
      :ok = Agent.stop(counter)
    end
  end

  defp compatibility_manifest do
    content = "Compatibility skill instructions."

    manifest = %{
      version: "loopex.resource_pack/1",
      workspace_ref: "m3-resource-workspace",
      revision: nil,
      packs: [
        %{
          source_id: "project",
          origin: nil,
          commit: nil,
          tree_digest: nil,
          name: "compatibility",
          description: "Compatibility boundary",
          manual_only: true,
          files: [
            %{
              label: "SKILL.md",
              content: content,
              size: byte_size(content),
              digest: LoopexProtocol.Canonical.digest_bytes(content),
              contained: true
            }
          ]
        }
      ]
    }

    {:ok, digest, normalized} = ResourcePack.digest(manifest)

    decision = %{
      manifest_digest: digest,
      workspace_ref: "m3-resource-workspace",
      trust_scope: "project_skills",
      decision_source: "host_supplied",
      issued_at: "2026-09-10T00:00:00Z",
      expires_at: nil,
      revocation_state: "active"
    }

    {normalized, digest, decision}
  end

  defp owned_root(label) do
    nonce = Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)
    root = Path.join(System.tmp_dir!(), "loopex-m3-#{label}-#{nonce}")

    case File.mkdir(root) do
      :ok ->
        on_exit(fn -> File.rm_rf(root) end)
        root

      {:error, :eexist} ->
        owned_root(label)

      {:error, reason} ->
        flunk("cannot allocate workflow root: #{inspect(reason)}")
    end
  end

  defp workflow_fixture(label, credential) do
    root = owned_root("foundation-#{label}")
    workspace = Path.join(root, "workspace")
    state_root = Path.join(root, "state")
    skill = Path.join([workspace, ".agents", "skills", "review"])
    File.mkdir_p!(Path.join(skill, "references"))

    instruction =
      "---\nname: review\ndescription: Inspect a large result.\n---\n" <>
        "M3_INSTRUCTION_MARKER: read the named file and inspect the retained artifact.\n"

    support = "M3_SUPPORT_MARKER: verify every retained byte.\n"
    File.write!(Path.join(skill, "SKILL.md"), instruction)
    File.write!(Path.join([skill, "references", "checklist.md"]), support)

    full = String.duplicate("artifact-byte-sequence\n", CodingTools.limits().read_bytes)
    File.write!(Path.join(workspace, "large.txt"), full)
    File.mkdir_p!(state_root)
    {:ok, workspace_ref} = LoopexCli.ProjectResources.workspace_reference(workspace)

    {:ok, manifest} =
      LoopexComposition.ResourcePacks.discover(workspace,
        workspace_ref: workspace_ref,
        state_root: state_root
      )

    {:ok, digest, normalized} = ResourcePack.digest(manifest)

    decision = %{
      "manifest_digest" => digest,
      "workspace_ref" => workspace_ref,
      "trust_scope" => "project_skills",
      "decision_source" => "host_supplied",
      "issued_at" => "2026-09-10T00:00:00Z",
      "expires_at" => nil,
      "revocation_state" => "active"
    }

    provider =
      ProviderFixture.new(:reply,
        credential: credential,
        response_bodies: [
          tool_response("large.txt", "msg_#{label}_tool"),
          text_response("artifact retained", "msg_#{label}_done"),
          text_response("artifact retained after recovery", "msg_#{label}_recovered")
        ]
      )

    %{
      root: root,
      state_root: state_root,
      workspace: workspace,
      manifest: normalized,
      digest: digest,
      decision: decision,
      pack: hd(normalized["packs"]),
      provider: provider,
      full: full,
      instruction: instruction,
      support: support
    }
  end

  defp configured_recovery_workflow(label) do
    credential = "m3-foundation-#{label}"
    variable = ReqLLM.credential_variable()
    previous = System.get_env(variable)
    System.put_env(variable, credential)

    on_exit(fn ->
      if previous,
        do: System.put_env(variable, previous),
        else: System.delete_env(variable)
    end)

    workflow = workflow_fixture(label, credential)
    Map.put(workflow, :cli_binary, build_isolated_provider_cli(workflow))
  end

  defp complete_cli_workflow(workflow) do
    {output, 0} =
      run_cli_process(
        workflow.cli_binary,
        [
          "run",
          "--policy",
          "allow-all",
          "--skill",
          "review",
          "--skill-resource",
          "review:references/checklist.md",
          "--state-root",
          workflow.state_root,
          "--workspace",
          workflow.workspace,
          "Use the review skill and inspect large.txt."
        ],
        nil
      )

    assert {:ok, [%{session_id: session_id}]} = Loopex.list_sessions(workflow.state_root)
    {session_id, output}
  end

  # Concept: recovery starts from a real durable continuation point after the
  # tool result, so it must stage new provider input rather than replay a
  # completed session.
  #
  # Technical depth: the source-built CLI first writes the complete genuine
  # history. This keeps its exact Store bytes only through the existing frame
  # whose session transaction committed the tool result. The next request and
  # terminal are complete later frames, so removing that suffix is equivalent
  # to the previous process stopping at this already-linearized boundary; no
  # resource receipt or runtime record is synthesized.
  defp rewind_after_tool_result(workflow, session_id) do
    path = Path.join(workflow.state_root, "store.log")
    original = File.read!(path)
    assert {:ok, frames, :complete} = Log.read(path)

    tool_frame =
      Enum.find_index(frames, fn frame ->
        Enum.any?(frame.records, &(&1.payload.kind == "executor_receipt_committed"))
      end)

    assert is_integer(tool_frame), "the completed workflow did not retain its tool result"
    {kept, removed} = Enum.split(frames, tool_frame + 1)
    assert get_in(List.last(kept), [:transaction, :session_id]) == session_id

    assert Enum.any?(removed, fn frame ->
             Enum.any?(frame.records, fn record ->
               record.payload.kind in [
                 "model_request_committed",
                 "model_request_committed_resources_v1"
               ]
             end)
           end),
           "the fixture had no later provider request to remove"

    prefix =
      Enum.map_join(kept, fn frame ->
        assert {:ok, encoded} = Log.encode(frame)
        encoded
      end)

    assert String.starts_with?(original, prefix)
    File.write!(path, binary_part(original, 0, byte_size(prefix)), [:binary])
    assert {:ok, ^kept, :complete} = Log.read(path)
  end

  defp replace_workspace_resources(workflow) do
    instruction =
      "---\nname: review\ndescription: A valid replacement after admission.\n---\n" <>
        "M3_CHANGED_WORKSPACE_INSTRUCTION: must never be rediscovered.\n"

    support = "M3_CHANGED_WORKSPACE_SUPPORT: must never be rediscovered.\n"
    skill = Path.join([workflow.workspace, ".agents", "skills", "review"])
    File.write!(Path.join(skill, "SKILL.md"), instruction)
    File.write!(Path.join([skill, "references", "checklist.md"]), support)

    assert {:ok, replacement} =
             LoopexComposition.ResourcePacks.discover(workflow.workspace,
               workspace_ref: workflow.manifest["workspace_ref"],
               state_root: workflow.state_root
             )

    assert {:ok, replacement_digest, _normalized} = ResourcePack.digest(replacement)
    refute replacement_digest == workflow.digest
    %{instruction: instruction, support: support}
  end

  defp completed_artifact_locator(workflow) do
    assert [{_first, true}, {second, true}] = ProviderFixture.events(workflow.provider)

    assert [_, locator] =
             Regex.run(~r/output truncated[^\]]* ([0-9a-f]{64})\]/, Jason.encode!(second))

    locator
  end

  defp resume_cli_workflow(workflow, session_id) do
    run_cli_process(
      workflow.cli_binary,
      [
        "resume",
        session_id,
        "--policy",
        "allow-all",
        "--state-root",
        workflow.state_root,
        "--workspace",
        workflow.workspace
      ],
      nil
    )
  end

  defp run_embedded(runtime, workflow) do
    {:ok, session_id} =
      Loopex.create_session(runtime, %{"surface" => "embedded"}, command_id: "create")

    {:ok, attachment} = Loopex.attach(runtime, session_id, after_event_sequence: 0)

    assert {:accepted, "admit"} =
             Loopex.command(attachment, %{
               type: :admit_resources,
               command_id: "admit",
               manifest_digest: workflow.digest,
               decision: workflow.decision
             })

    assert {:accepted, "activate"} =
             Loopex.command(attachment, %{
               type: :activate_skill,
               command_id: "activate",
               manifest_digest: workflow.digest,
               source_id: workflow.pack["source_id"],
               name: workflow.pack["name"],
               pack_digest: ResourcePack.pack_digest(workflow.pack),
               supporting_labels: ["references/checklist.md"]
             })

    assert {:accepted, "prompt"} =
             Loopex.command(attachment, %{
               type: :prompt,
               command_id: "prompt",
               content: "Use the review skill and inspect large.txt."
             })

    assert %{"outcome" => "completed", kind: "run.finished"} = await_finished(attachment)
  end

  defp await_finished(attachment, remaining \\ 800)

  defp await_finished(_attachment, 0), do: flunk("the resource workflow did not finish")

  defp await_finished(attachment, remaining) do
    case Loopex.next_event(attachment) do
      {:ok, %{kind: "run.finished"} = event} -> event
      _other -> Process.sleep(10) && await_finished(attachment, remaining - 1)
    end
  end

  defp assert_provider_workflow(workflow) do
    assert [{first, true}, {second, true}] = ProviderFixture.events(workflow.provider)
    second_bytes = Jason.encode!(second)
    staged = Enum.map(first["messages"], & &1["content"])
    assert workflow.instruction in staged
    assert workflow.support in staged
    assert second_bytes =~ "output truncated"

    assert [_, locator] = Regex.run(~r/output truncated[^\]]* ([0-9a-f]{64})\]/, second_bytes)
    locator
  end

  defp build_isolated_provider_cli(workflow) do
    # Concept: the source-built workflow also runs as a standalone gate selector.
    # Technical depth: only its build helper needs Mix project state. Establish
    # that state explicitly and keep using the application bytes loaded by the
    # selector, instead of depending on mix test's ambient project stack.
    {:ok, _} = Application.ensure_all_started(:mix)

    build = fn ->
      assert Path.expand(Mix.Project.compile_path()) ==
               Path.expand(Application.app_dir(:loopex_cli, "ebin"))

      build_cli_in_project(workflow)
    end

    if Mix.Project.get() == LoopexCli.MixProject do
      build.()
    else
      Mix.Project.in_project(:loopex_cli, Path.expand("..", __DIR__), fn _project -> build.() end)
    end
  end

  defp build_cli_in_project(workflow) do
    launch_path = Path.join(workflow.root, "isolated-test-provider.launch")

    launch =
      Keyword.take(workflow.provider.options, [
        :worker_path,
        :interpreter_path,
        :worker_sha256,
        :build_manifest_sha256
      ])

    File.write!(launch_path, :io_lib.format(~c"~tp.~n", [launch]))

    executable = Path.join(workflow.root, "loopex")
    build_output = Path.expand(Mix.Project.config()[:escript][:path] || "loopex")
    previous_output = File.read(build_output)
    previous_mode = file_mode(build_output)

    try do
      with_resource_decision_main(workflow.decision, fn main_module ->
        with_provider_launch(launch_path, fn ->
          original_escript = Mix.Project.config()[:escript]

          Mix.ProjectStack.merge_config(
            escript: Keyword.put(original_escript, :main_module, main_module)
          )

          try do
            Mix.Tasks.Escript.Build.run(["--no-compile", "--no-deps-check"])
            File.cp!(build_output, executable)
            File.chmod!(executable, file_mode(build_output))
          after
            Mix.ProjectStack.merge_config(escript: original_escript)
          end
        end)
      end)
    after
      restore_build_output(build_output, previous_output, previous_mode)
    end

    assert File.exists?(executable)
    executable
  end

  defp file_mode(path) do
    case File.stat(path) do
      {:ok, stat} -> stat.mode
      {:error, :enoent} -> nil
    end
  end

  defp restore_build_output(path, {:ok, bytes}, mode) do
    File.write!(path, bytes)
    File.chmod!(path, mode)
  end

  defp restore_build_output(path, {:error, :enoent}, nil), do: File.rm(path)

  defp with_resource_decision_main(decision, build) do
    module = LoopexCli.IsolatedProviderMain

    beam_path =
      Path.join(Mix.Project.compile_path(), "Elixir.LoopexCli.IsolatedProviderMain.beam")

    previous_beam = File.read(beam_path)
    previous_mode = file_mode(beam_path)

    quoted =
      quote do
        defmodule unquote(module) do
          def main(arguments) do
            result =
              LoopexCli.dispatch(arguments,
                resource_decision: unquote(Macro.escape(decision)),
                operator_present: false
              )

            LoopexCli.release_placement()

            case result do
              :ok -> System.halt(0)
              {:error, message} -> IO.puts(:stderr, "loopex: #{message}") && System.halt(1)
            end
          end
        end
      end

    try do
      [{^module, beam}] = Code.compile_quoted(quoted)
      File.write!(beam_path, beam)
      build.(module)
    after
      restore_build_output(beam_path, previous_beam, previous_mode)
      :code.purge(module)
      :code.delete(module)
    end
  end

  defp with_provider_launch(launch_path, build) do
    module = LoopexCli.ProviderLaunch
    {^module, original, original_path} = :code.get_object_code(module)
    beam_path = List.to_string(original_path)
    previous_environment = System.get_env("LOOPEX_BUILD_PROVIDER_CONFIG")
    previous_compiler = Code.compiler_options(ignore_module_conflict: true)
    System.put_env("LOOPEX_BUILD_PROVIDER_CONFIG", launch_path)

    try do
      [{^module, configured}] =
        Code.compile_file(Path.expand("../lib/provider_launch.ex", __DIR__))

      File.write!(beam_path, configured)
      build.()
    after
      File.write!(beam_path, original)
      Code.compiler_options(previous_compiler)

      if previous_environment,
        do: System.put_env("LOOPEX_BUILD_PROVIDER_CONFIG", previous_environment),
        else: System.delete_env("LOOPEX_BUILD_PROVIDER_CONFIG")

      :code.purge(module)
      {:module, ^module} = :code.load_binary(module, original_path, original)
    end
  end

  defp run_cli_process(executable, arguments, input) do
    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        # The escript does not inherit Elixir launcher options such as +fnu.
        # Give this byte-preserving child its own UTF-8 locale under inherited gates.
        env: [{~c"LANG", ~c"C.UTF-8"}, {~c"LC_ALL", ~c"C.UTF-8"}],
        args: arguments
      ])

    if is_binary(input), do: Port.command(port, input)
    collect_port(port, "")
  end

  defp collect_port(port, output) do
    receive do
      {^port, {:data, bytes}} -> collect_port(port, output <> bytes)
      {^port, {:exit_status, status}} -> {output, status}
    after
      60_000 -> flunk("the source-built CLI did not exit")
    end
  end

  defp stop_runtime(runtime) do
    try do
      Loopex.stop(runtime)
    catch
      :exit, _reason -> :ok
    end
  end

  defp tool_response(path, response_id) do
    [
      message_start(response_id),
      %{
        "type" => "content_block_start",
        "index" => 0,
        "content_block" => %{
          "type" => "tool_use",
          "id" => "call_read",
          "name" => "read",
          "input" => %{}
        }
      },
      %{
        "type" => "content_block_delta",
        "index" => 0,
        "delta" => %{
          "type" => "input_json_delta",
          "partial_json" => Jason.encode!(%{"path" => path})
        }
      },
      %{"type" => "content_block_stop", "index" => 0},
      %{
        "type" => "message_delta",
        "delta" => %{"stop_reason" => "tool_use", "stop_sequence" => nil},
        "usage" => %{"output_tokens" => 12}
      },
      %{"type" => "message_stop"}
    ]
    |> sse()
  end

  defp text_response(text, response_id) do
    [
      message_start(response_id),
      %{
        "type" => "content_block_start",
        "index" => 0,
        "content_block" => %{"type" => "text", "text" => ""}
      },
      %{
        "type" => "content_block_delta",
        "index" => 0,
        "delta" => %{"type" => "text_delta", "text" => text}
      },
      %{"type" => "content_block_stop", "index" => 0},
      %{
        "type" => "message_delta",
        "delta" => %{"stop_reason" => "end_turn", "stop_sequence" => nil},
        "usage" => %{"output_tokens" => 2}
      },
      %{"type" => "message_stop"}
    ]
    |> sse()
  end

  defp message_start(response_id),
    do: %{
      "type" => "message_start",
      "message" => %{
        "id" => response_id,
        "type" => "message",
        "role" => "assistant",
        "model" => "claude-haiku-4-5",
        "content" => [],
        "usage" => %{"input_tokens" => 4, "output_tokens" => 0}
      }
    }

  defp sse(events) do
    Enum.map_join(events, fn event ->
      "event: #{event["type"]}\ndata: #{Jason.encode!(event)}\n\n"
    end)
  end
end
