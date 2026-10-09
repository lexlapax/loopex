Code.require_file(
  "../../loopex_llm_reqllm/test/support/provider_isolation_fixture.exs",
  __DIR__
)

defmodule LoopexCli.FoundationWorkflowTest do
  use ExUnit.Case, async: false

  alias Loopex.Executor.Local.CodingTools
  alias Loopex.LLM.ReqLLM
  alias Loopex.LLM.ReqLLM.ProviderIsolationFixture, as: ProviderFixture
  alias Loopex.ResourcePack
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
        policy_identity: %{"id" => "loopex.test.policy", "revision" => "1"},
        provider_launch:
          Keyword.drop(embedded.provider.options, [
            :credential_token,
            :credential_registry,
            :tracing_capability
          ]),
        resource_manifest: embedded.manifest
      )

    on_exit(fn -> stop_runtime(embedded_runtime) end)
    # The embedded composition consumed the variable; the source-built CLI is a
    # separate host process that inherits the operator's credential afresh.
    System.put_env(variable, credential)
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

    assert workflow.instruction in provider_texts(first)
    assert workflow.support in provider_texts(first)
    assert_artifact_excerpt(second, workflow)
    assert workflow.instruction in provider_texts(recovered)
    assert workflow.support in provider_texts(recovered)
    refute changed.instruction in provider_texts(recovered)
    refute changed.support in provider_texts(recovered)
    assert_artifact_excerpt(recovered, workflow)

    assert {workflow.full, 0} ==
             run_cli_process(
               workflow.cli_binary,
               ["artifact", locator, "--state-root", workflow.state_root],
               nil
             )
  end

  test "the source built CLI refuses a changed worker identity before provider dispatch" do
    workflow = configured_recovery_workflow("launch-mismatch")
    {_session_id, positive_output} = complete_cli_workflow(workflow)
    assert positive_output =~ "artifact retained"
    positive_events = ProviderFixture.events(workflow.provider)
    assert length(positive_events) == 2

    {:ok, configuration} =
      Loopex.LLM.ReqLLM.ProviderConfiguration.validate(workflow.provider.options)

    assert :ok = Loopex.LLM.ReqLLM.ProviderConfiguration.verify_artifact(configuration)

    File.write!(configuration.worker_path, "\n% Changed after the CLI bound its identity.\n", [
      :append
    ])

    assert {:error, :provider_artifact_unavailable} =
             Loopex.LLM.ReqLLM.ProviderConfiguration.verify_artifact(configuration)

    {refused, 0} =
      run_cli_process(
        workflow.cli_binary,
        [
          "run",
          "--policy",
          "allow-all",
          "--state-root",
          Path.join(workflow.root, "mismatched-launch-state"),
          "--workspace",
          workflow.workspace,
          "Complete another ordinary task."
        ],
        nil
      )

    assert refused =~ "loopex: failed"
    refute refused =~ "loopex: done"
    assert ProviderFixture.events(workflow.provider) == positive_events
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

    recovered_contents = provider_texts(recovered)

    first
    |> provider_texts()
    |> Enum.take(3)
    |> Enum.each(fn content -> refute content in recovered_contents end)

    refute changed.instruction in provider_texts(recovered)
    refute changed.support in provider_texts(recovered)
    assert_artifact_excerpt(recovered, workflow)
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
    {:ok, workspace_ref} = LoopexComposition.ProjectResources.workspace_reference(workspace)

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
        Enum.any?(frame.records, &(&1.payload.kind == "executor_receipt_committed_v2"))
      end)

    assert is_integer(tool_frame), "the completed workflow did not retain its tool result"
    {kept, removed} = Enum.split(frames, tool_frame + 1)
    assert get_in(List.last(kept), [:transaction, :session_id]) == session_id

    assert Enum.any?(removed, fn frame ->
             Enum.any?(frame.records, fn record ->
               record.payload.kind in [
                 "model_request_committed_v2",
                 "model_request_committed_resources_v2"
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
    assert_artifact_excerpt(second, workflow)
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
    staged = provider_texts(first)
    assert workflow.instruction in staged
    assert workflow.support in staged
    assert_artifact_excerpt(second, workflow)
  end

  defp provider_texts(request) do
    for message <- request["messages"],
        %{"type" => "text", "text" => text} <- message["content"],
        do: text
  end

  # Concept: the model sees a bounded artifact excerpt and the retained object
  # remains retrievable in full through the public artifact surface.
  # Technical depth: inspect the native tool-result block's closed JSON object;
  # verify its actual source prefix, byte counts, object identity and omission.
  defp assert_artifact_excerpt(request, workflow) do
    [result] =
      for message <- request["messages"],
          %{"type" => "tool_result"} = block <- message["content"],
          do: block

    projection = JSON.decode!(result["content"])

    assert Enum.sort(Map.keys(projection)) ==
             ~w(excerpt excerpt_byte_count excerpt_offset excerpt_source object_digest object_size omitted source_byte_count use_locator)

    digest = Base.encode16(:crypto.hash(:sha256, workflow.full), case: :lower)
    assert projection["object_digest"] == digest
    assert projection["object_size"] == byte_size(workflow.full)
    assert projection["source_byte_count"] == CodingTools.limits().read_bytes
    assert projection["excerpt_source"] == "receipt_content"
    assert projection["excerpt_offset"] == 0
    assert projection["omitted"] == true
    assert projection["use_locator"] =~ ~r/^use:[0-9a-f]{64}$/
    assert projection["excerpt_byte_count"] > 0
    assert projection["excerpt_byte_count"] < projection["source_byte_count"]
    assert projection["excerpt_byte_count"] == byte_size(projection["excerpt"])

    assert projection["excerpt"] ==
             binary_part(workflow.full, 0, projection["excerpt_byte_count"])

    assert byte_size(result["content"]) <= 2_048
    digest
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

      input_paths = [
        List.to_string(:code.which(LoopexCli.ProviderLaunch)),
        Path.join(Mix.Project.compile_path(), "Elixir.LoopexCli.IsolatedProviderMain.beam"),
        Path.expand(Mix.Project.config()[:escript][:path] || "loopex")
      ]

      original_inputs = Map.new(input_paths, &{&1, File.read(&1)})
      executable = build_cli_in_project(workflow)
      assert Map.new(input_paths, &{&1, File.read(&1)}) == original_inputs
      executable
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
    original_escript = Mix.Project.config()[:escript]

    with_resource_decision_main(workflow.decision, fn main_module, main_beam ->
      with_provider_launch(launch_path, fn launch_beam ->
        Mix.ProjectStack.merge_config(
          escript:
            original_escript
            |> Keyword.put(:main_module, main_module)
            |> Keyword.put(:path, executable)
        )

        try do
          Mix.Tasks.Escript.Build.run(["--no-compile", "--no-deps-check"])

          # Concept: a killed workflow build cannot poison the production beams.
          # Technical depth: test overrides exist only in this owned archive;
          # the build directory and any ordinary CLI artifact are read-only inputs.
          replace_archive_beams(executable, [
            {main_module, main_beam},
            {LoopexCli.ProviderLaunch, launch_beam}
          ])
        after
          Mix.ProjectStack.merge_config(escript: original_escript)
        end
      end)
    end)

    assert File.exists?(executable)
    executable
  end

  defp replace_archive_beams(executable, overrides) do
    {:ok, sections} = :escript.extract(String.to_charlist(executable), [])
    {:ok, entries} = :zip.extract(Keyword.fetch!(sections, :archive), [:memory])

    cli_directory =
      entries
      |> Enum.find(fn {path, _bytes} ->
        Path.basename(List.to_string(path)) == "Elixir.LoopexCli.beam"
      end)
      |> elem(0)
      |> List.to_string()
      |> Path.dirname()

    # Mix 1.17 stores beams at the archive root; a ./ prefix names a different
    # ZIP entry and prevents OTP 26 from loading the injected module.
    cli_directory = if cli_directory == ".", do: "", else: cli_directory

    replacements =
      Map.new(overrides, fn {module, bytes} ->
        {String.to_charlist(Path.join(cli_directory, Atom.to_string(module) <> ".beam")), bytes}
      end)

    entries = Enum.reject(entries, fn {path, _bytes} -> Map.has_key?(replacements, path) end)

    {:ok, {_name, archive}} =
      :zip.create(~c"loopex.zip", entries ++ Map.to_list(replacements), [:memory])

    :ok =
      :escript.create(String.to_charlist(executable), Keyword.put(sections, :archive, archive))
  end

  defp with_resource_decision_main(decision, build) do
    module = LoopexCli.IsolatedProviderMain

    quoted =
      quote do
        defmodule unquote(module) do
          def main(arguments) do
            # The product entry point starts the application graph, including
            # composition's helper registry, before any command runs.
            {:ok, _applications} = Application.ensure_all_started(:loopex_cli)

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
      build.(module, beam)
    after
      :code.purge(module)
      :code.delete(module)
    end
  end

  defp with_provider_launch(launch_path, build) do
    module = LoopexCli.ProviderLaunch
    {^module, original, original_path} = :code.get_object_code(module)
    previous_environment = System.get_env("LOOPEX_BUILD_PROVIDER_CONFIG")
    previous_compiler = Code.compiler_options(ignore_module_conflict: true)
    System.put_env("LOOPEX_BUILD_PROVIDER_CONFIG", launch_path)

    try do
      [{^module, configured}] =
        Code.compile_file(Path.expand("../lib/provider_launch.ex", __DIR__))

      build.(configured)
    after
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
        "model" => "claude-haiku-4-5-20251001",
        "content" => [],
        "stop_reason" => nil,
        "stop_sequence" => nil,
        "usage" => %{"input_tokens" => 4, "output_tokens" => 0}
      }
    }

  defp sse(events) do
    Enum.map_join(events, fn event ->
      "event: #{event["type"]}\ndata: #{Jason.encode!(event)}\n\n"
    end)
  end
end
