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

  defp workflow_fixture(label, credential) do
    unique = "#{System.pid()}-#{System.unique_integer([:positive])}"
    root = Path.join(System.tmp_dir!(), "loopex-m3-foundation-#{label}-#{unique}")
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
    on_exit(fn -> File.rm_rf(root) end)

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
          text_response("artifact retained", "msg_#{label}_done")
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
