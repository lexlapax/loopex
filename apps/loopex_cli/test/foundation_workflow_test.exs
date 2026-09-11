Code.require_file(
  "../../loopex_llm_reqllm/test/support/provider_isolation_fixture.exs",
  __DIR__
)

defmodule LoopexCli.FoundationWorkflowTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

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
    assert_workflow(embedded, :embedded)

    cli = workflow_fixture("cli", credential)
    parent = self()

    starter = fn options ->
      result =
        options
        |> Keyword.replace!(:provider_launch, cli.provider.options)
        |> LoopexComposition.start()

      case result do
        {:ok, runtime} -> send(parent, {:cli_runtime, runtime})
        _error -> :ok
      end

      result
    end

    stderr =
      capture_io(:stderr, fn ->
        send(
          parent,
          {:cli_result,
           capture_io(fn ->
             assert :ok =
                      LoopexCli.dispatch(
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
                        runtime_starter: starter,
                        resource_decision: cli.decision,
                        operator_present: false
                      )
           end)}
        )
      end)

    assert_receive {:cli_result, answer}
    assert_receive {:cli_runtime, cli_runtime}
    on_exit(fn -> stop_runtime(cli_runtime) end)
    assert answer =~ "artifact retained"
    assert stderr =~ "loopex.read: completed"
    assert_workflow(cli, :cli)
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

  defp assert_workflow(workflow, entry) do
    assert [{first, true}, {second, true}] = ProviderFixture.events(workflow.provider)
    second_bytes = Jason.encode!(second)
    staged = Enum.map(first["messages"], & &1["content"])
    assert workflow.instruction in staged
    assert workflow.support in staged
    assert second_bytes =~ "output truncated"

    assert [_, locator] = Regex.run(~r/output truncated[^\]]* ([0-9a-f]{64})\]/, second_bytes)

    retrieved =
      capture_io(fn ->
        assert :ok =
                 LoopexCli.dispatch([
                   "artifact",
                   locator,
                   "--state-root",
                   workflow.state_root
                 ])
      end)

    assert retrieved == workflow.full, "#{entry} did not retrieve the complete retained artifact"
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
