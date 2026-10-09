Code.require_file(
  "../../loopex_llm_reqllm/test/support/provider_isolation_fixture.exs",
  __DIR__
)

defmodule LoopexComposition.DelegationDemonstrationTest do
  use ExUnit.Case, async: false

  alias Loopex.Executor.Local.CodingTools
  alias Loopex.LLM.ReqLLM
  alias Loopex.LLM.ReqLLM.ProviderIsolationFixture, as: ProviderFixture
  alias Loopex.Runtime.SessionGenesis
  alias LoopexComposition.{Delegation, DurableOptions, Placement}
  alias LoopexComposition.Delegation.{Helper, LedgerCodec, Tool}
  alias LoopexProtocol.ToolDefinition

  defmodule AllowAll do
    @moduledoc false
    @behaviour Loopex.Policy
    @impl Loopex.Policy
    def decide(_request), do: {:allow, nil}
  end

  @read_only ~w(loopex.read loopex.grep loopex.find loopex.ls)

  # Concept: both accepted role demonstrations run through the reference
  # composition, the real local executor and a local fake provider.
  # Technical depth: an isolated provider process answers the parent and each
  # child in order. The helper reads the workspace with real read tools; every
  # workspace byte is unchanged afterwards. Each demonstration reports the
  # child's usage, the parent's own usage and their combination separately.
  # The paid real-provider run of the same two roles is the release lane's
  # `helper_role_demonstrations` case and is not run here.
  test "repository investigation and code review helpers return known findings read-only" do
    credential = "m7-helper-demonstration"
    variable = ReqLLM.credential_variable()
    previous = System.get_env(variable)
    System.put_env(variable, credential)

    on_exit(fn ->
      if previous,
        do: System.put_env(variable, previous),
        else: System.delete_env(variable)
    end)

    root =
      Path.join(
        if(File.dir?("/private/tmp"), do: "/private/tmp", else: "/tmp"),
        "loopex-helper-demo-#{Base.encode16(:crypto.strong_rand_bytes(8))}"
      )

    workspace = Path.join(root, "workspace")
    state_root = Path.join(root, "state")
    roles_dir = Path.join(root, "roles")
    File.mkdir_p!(Path.join(workspace, "lib"))
    File.mkdir_p!(state_root)
    File.mkdir_p!(roles_dir)
    on_exit(fn -> File.rm_rf!(root) end)

    File.write!(
      Path.join(workspace, "README.md"),
      "# Helper demo\nThe service entry is lib/app.ex.\n"
    )

    File.write!(Path.join([workspace, "lib", "app.ex"]), "def add(a, b), do: a - b\n")
    File.write!(Path.join(roles_dir, "investigate.md"), "Investigate the repository read-only.\n")
    File.write!(Path.join(roles_dir, "review.md"), "Review the named code read-only.\n")
    before = workspace_bytes(workspace)

    provider =
      ProviderFixture.new(:reply,
        credential: credential,
        response_bodies: [
          tool_use("call_task_1", "task", %{
            "role" => "investigate",
            "description" => "find the entry",
            "prompt" => "Which file is the service entry?"
          }),
          tool_use("call_read_1", "read", %{"path" => "README.md"}),
          text("Finding: the service entry is lib/app.ex.", "child_1"),
          text("Investigation complete.", "parent_1"),
          tool_use("call_task_2", "task", %{
            "role" => "review",
            "description" => "review add",
            "prompt" => "Review lib/app.ex for defects."
          }),
          tool_use("call_read_2", "read", %{"path" => "lib/app.ex"}),
          text("Review: add/2 subtracts instead of adding.", "child_2"),
          text("Review complete.", "parent_2")
        ]
      )

    {:ok, placement} = Placement.acquire(state_root)
    on_exit(fn -> Placement.release(placement) end)
    {:ok, handle} = Delegation.open(state_root, "helper-demo", placement, enabled: true)
    Process.unlink(handle.helper)
    Process.unlink(handle.objects)

    options = [
      state_root: state_root,
      workspace: workspace,
      runtime_id: "helper-demo",
      policy: AllowAll,
      policy_identity: %{"id" => "loopex.test.helper_demo", "revision" => "1"},
      active_tools: @read_only,
      provider_launch:
        Keyword.drop(provider.options, [
          :credential_token,
          :credential_registry,
          :tracing_capability
        ]),
      delegation: handle
    ]

    {:ok, runtime} = LoopexComposition.start(options)

    on_exit(fn ->
      if Loopex.Runtime.alive?(runtime), do: Loopex.stop(runtime)

      for pid <- [handle.helper, handle.objects],
          Process.alive?(pid),
          do: GenServer.stop(pid, :normal, 5_000)
    end)

    assert Helper.status(handle.helper).classified == :complete
    model = ReqLLM.default_model()
    providers = %{"anthropic" => %{"credential" => %{"env" => variable}}}
    definitions = CodingTools.definitions()

    roles =
      for name <- ~w(investigate review), into: %{} do
        assert {:ok, genesis} =
                 Delegation.role(
                   workspace,
                   %{
                     "instructions_file" => Path.join(roles_dir, name <> ".md"),
                     "model" => model,
                     "reasoning" => "default",
                     "max_tokens" => 1_024,
                     "system_class_tokens" => 1_000
                   },
                   providers,
                   definitions,
                   Loopex.Executor.default_cleanup_grace_ms()
                 )

        {name, genesis}
      end

    session_options = %{"surface" => "helper-demo"}
    parent_genesis = parent_genesis(workspace, model, session_options)

    assert {:ok, parent} =
             Delegation.create_parent(
               handle,
               "demo-parent",
               providers,
               roles,
               %{
                 "roles" => ["investigate", "review"],
                 "max_children" => 4,
                 "token_budget" => 100_000,
                 "child_bounds" => %{
                   "max_turns" => 4,
                   "deadline_ms" => 600_000,
                   "token_budget" => 20_000
                 },
                 "max_tokens" => 1_024
               },
               session_options,
               parent_genesis
             )

    {:ok, attachment} = Loopex.attach(runtime, parent, after_event_sequence: 0)

    results =
      for {command, content} <- [
            {"investigate", "Investigate the repository."},
            {"review", "Review the code."}
          ] do
        assert {:accepted, ^command} =
                 Loopex.command(attachment, %{
                   type: :prompt,
                   command_id: command,
                   content: content
                 })

        {:ok, {:committed, :admitted, _code, run}} =
          Loopex.command_disposition(attachment, command)

        evidence = await_terminal(runtime, parent, run)
        assert evidence.terminal.state == "completed"
        {run, evidence}
      end

    status = Helper.status(handle.helper)
    assert map_size(status.children) == 2 and map_size(status.receipts) == 2

    outputs =
      for {_job, receipt} <- status.receipts, into: %{} do
        assert receipt.outcome == :completed
        {:ok, output} = LedgerCodec.decode_json(receipt.output, :object)
        {output["role"], output}
      end

    assert outputs["investigate"]["text"] == "Finding: the service entry is lib/app.ex."
    assert outputs["review"]["text"] == "Review: add/2 subtracts instead of adding."

    for {{run, evidence}, role} <- Enum.zip(results, ~w(investigate review)) do
      output = outputs[role]
      child = output["usage"]["child"]
      child_total = child["reported_input_tokens"] + child["reported_output_tokens"]
      assert child_total > 0
      assert output["usage"]["delegation"]["charged_tokens"] == child_total
      ledger = status.runs[{parent, run}]
      assert ledger.charged_tokens == child_total and ledger.count == 1
      parent_tokens = evidence.usage.reported_input + evidence.usage.reported_output
      assert parent_tokens > output["usage"]["parent"]["tokens"]

      assert output["usage"]["combined_tokens"] ==
               output["usage"]["parent"]["tokens"] + child_total

      refute LoopexComposition.Delegation.RunLedger.occupied?(ledger)
    end

    assert workspace_bytes(workspace) == before
    assert ProviderFixture.count(provider) == 8
  end

  defp parent_genesis(workspace, model, session_options) do
    {:ok, base} =
      DurableOptions.capture_genesis(
        [model: model, workspace: workspace, active_tools: @read_only],
        session_options
      )

    definitions = base["tool_selection"]["definitions"] ++ [Tool.definition()]

    {:ok, genesis} =
      SessionGenesis.resolve(session_options, %{
        genesis_version: "session_genesis_v3",
        runtime_configuration: base["runtime_configuration"],
        initial_configuration: base["initial_configuration"],
        tool_selection: %{
          "definitions" => definitions,
          "names" =>
            Map.new(definitions, fn definition ->
              {id, version, digest} = ToolDefinition.generation(definition)

              {definition["name"],
               %{"tool_id" => id, "tool_version" => version, "definition_digest" => digest}}
            end)
        },
        policy_defer_mode: "admit"
      })

    genesis
  end

  defp await_terminal(runtime, session, run, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 30_000

    case Loopex.Runtime.run_evidence(runtime, session, run) do
      {:ok, %{terminal: %{}} = evidence} ->
        evidence

      _ ->
        assert System.monotonic_time(:millisecond) < deadline, "run did not end"
        Process.sleep(20)
        await_terminal(runtime, session, run, deadline)
    end
  end

  defp workspace_bytes(workspace) do
    workspace
    |> Path.join("**")
    |> Path.wildcard(match_dot: true)
    |> Enum.sort()
    |> Enum.map(fn path ->
      {Path.relative_to(path, workspace),
       if(File.regular?(path), do: File.read!(path), else: :dir)}
    end)
  end

  defp tool_use(id, name, input) do
    [
      message_start("msg_" <> id),
      %{
        "type" => "content_block_start",
        "index" => 0,
        "content_block" => %{"type" => "tool_use", "id" => id, "name" => name, "input" => %{}}
      },
      %{
        "type" => "content_block_delta",
        "index" => 0,
        "delta" => %{"type" => "input_json_delta", "partial_json" => Jason.encode!(input)}
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

  defp text(text, id) do
    [
      message_start("msg_" <> id),
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
        "usage" => %{"output_tokens" => 7}
      },
      %{"type" => "message_stop"}
    ]
    |> sse()
  end

  defp message_start(id),
    do: %{
      "type" => "message_start",
      "message" => %{
        "id" => id,
        "type" => "message",
        "role" => "assistant",
        "model" => "claude-haiku-4-5-20251001",
        "content" => [],
        "stop_reason" => nil,
        "stop_sequence" => nil,
        "usage" => %{"input_tokens" => 40, "output_tokens" => 0}
      }
    }

  defp sse(events) do
    Enum.map_join(events, fn event ->
      "event: #{event["type"]}\ndata: #{Jason.encode!(event)}\n\n"
    end)
  end
end
