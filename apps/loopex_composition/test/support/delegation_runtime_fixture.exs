Code.require_file("../../../loopex/test/support/m1_runtime_helper.exs", __DIR__)
Code.require_file("../../../loopex/test/support/agent_loop_helper.exs", __DIR__)

defmodule LoopexComposition.DelegationRuntimeFixture do
  @moduledoc false
  import ExUnit.Assertions
  import ExUnit.Callbacks

  alias Loopex.{AgentLoopFixture, AgentLoopTestModel}
  alias LoopexComposition.Delegation.{Catalog, Helper, RetainedObjects, Router, Tool}
  alias LoopexComposition.Placement

  @model "anthropic:helper-fixture"
  @providers %{"anthropic" => %{"credential" => %{"env" => "HELPER_FIXTURE_KEY"}}}

  # Concept: a durable runtime whose executor is the helper router over a
  # scripted local executor, with the shipped Local Store and a physical ledger.
  def start(script, options \\ []) do
    root =
      Path.join(
        if(File.dir?("/private/tmp"), do: "/private/tmp", else: "/tmp"),
        "loopex-helper-#{Base.encode16(:crypto.strong_rand_bytes(8))}"
      )

    File.mkdir!(root)
    {:ok, lease} = Placement.acquire(root)
    {:ok, objects} = RetainedObjects.open(root, "helper-runtime", lease)
    Process.unlink(objects)
    {:ok, store_pid} = Loopex.Store.Local.start_link(path: Path.join(root, "core.log"))
    Process.unlink(store_pid)
    {:ok, store} = Loopex.Store.new(Loopex.Store.Local, store_pid)
    {:ok, helper} = Helper.start_link(objects: objects, runtime_id: "helper-runtime")
    Process.unlink(helper)
    model = AgentLoopTestModel.start(script)
    executor = Loopex.AgentLoopTestExecutor.start(Keyword.get(options, :outcomes, %{}))
    definitions = read_definitions() ++ [Tool.definition()]

    {:ok, runtime} =
      Loopex.start_link(
        runtime_id: "helper-runtime",
        store: store,
        context_token_budget: 8_192,
        session_creation_defaults:
          AgentLoopFixture.creation_defaults(read_definitions(), model: @model),
        model: %{
          module: AgentLoopTestModel,
          model: @model,
          options: [script: model, max_tokens: 256]
        },
        executor:
          Router.wrap(
            %{
              module: Loopex.AgentLoopTestExecutor,
              reference: executor,
              identity: "helper-executor",
              epoch: 1,
              fencing_token: 1,
              workspace_ref: "workspace-ref",
              workspace_lease: "workspace-lease"
            },
            helper
          ),
        tool: nil,
        tools: definitions,
        active_tools: Enum.map(definitions, & &1["tool_id"]),
        policy: Keyword.get(options, :policy, Loopex.AgentLoopTestPolicy),
        policy_identity: %{"id" => "loopex.test.helper_policy", "revision" => "1"},
        grant_decision: {:host_policy, :allow},
        bounds: %{max_turns: 8, token_budget: 1_000_000, deadline_ms: 600_000}
      )

    Loopex.ConfiguredGenesisFixture.await_creation_ready(runtime)
    assert :ok = Helper.bind(helper, runtime)
    assert :ok = Helper.classification(helper, :complete)

    on_exit(fn ->
      if Loopex.Runtime.alive?(runtime), do: Loopex.stop(runtime)

      for pid <- [helper, objects, store_pid], Process.alive?(pid) do
        GenServer.stop(pid, :normal, 5_000)
      end

      Placement.release(lease)
      File.rm_rf!(root)
    end)

    %{
      root: root,
      runtime: runtime,
      helper: helper,
      objects: objects,
      model: model,
      executor: executor,
      store: store
    }
  end

  def read_definitions do
    Loopex.Executor.Local.CodingTools.definitions()
    |> Enum.filter(&(&1["tool_id"] in ~w(loopex.read loopex.grep loopex.find loopex.ls)))
  end

  def configuration do
    AgentLoopFixture.creation_defaults(read_definitions(), model: @model)["initial_configuration"]
  end

  # Concept: one enabled role over the scripted model with finite limits.
  def parent(fixture, command, limits \\ %{}) do
    assert {:ok, role} = Catalog.role_genesis(configuration(), read_definitions(), 5_000)

    limits =
      Map.merge(
        %{
          "roles" => ["inspect"],
          "max_children" => 4,
          "token_budget" => 4_000,
          "child_bounds" => %{"max_turns" => 4, "deadline_ms" => 600_000, "token_budget" => 1_000},
          "max_tokens" => 256
        },
        limits
      )

    options = %{"tenant" => "helper"}

    {:ok, genesis} =
      Loopex.Runtime.SessionGenesis.resolve(options, %{
        genesis_version: "session_genesis_v3",
        runtime_configuration: %{"cleanup_grace_ms" => 5_000},
        initial_configuration: configuration(),
        tool_selection: selection(read_definitions() ++ [Tool.definition()]),
        policy_defer_mode: "admit"
      })

    assert {:ok, capture} =
             Catalog.capture(
               "helper-runtime",
               command,
               @providers,
               %{"inspect" => role},
               limits,
               options,
               genesis
             )

    assert {:ok, session} = Helper.create_parent(fixture.helper, capture)
    session
  end

  defp selection(definitions) do
    %{
      "definitions" => definitions,
      "names" =>
        Map.new(definitions, fn definition ->
          {id, version, digest} = LoopexProtocol.ToolDefinition.generation(definition)

          {definition["name"],
           %{"tool_id" => id, "tool_version" => version, "definition_digest" => digest}}
        end)
    }
  end

  def task_call(id, role \\ "inspect", prompt \\ "Inspect the workspace."),
    do: %{
      id: id,
      name: "task",
      arguments: %{"role" => role, "description" => "investigate", "prompt" => prompt}
    }

  def await_terminal(fixture, session, run, cutoff \\ nil) do
    cutoff = cutoff || System.monotonic_time(:millisecond) + 10_000

    case Loopex.Runtime.run_evidence(fixture.runtime, session, run) do
      {:ok, %{terminal: %{}} = evidence} ->
        evidence

      _ ->
        assert System.monotonic_time(:millisecond) < cutoff, "run did not end"
        Process.sleep(10)
        await_terminal(fixture, session, run, cutoff)
    end
  end

  def prompt(fixture, session, command_id, content) do
    {:ok, attachment} = Loopex.attach(fixture.runtime, session, after_event_sequence: 0)

    assert {:accepted, ^command_id} =
             Loopex.command(attachment, %{type: :prompt, command_id: command_id, content: content})

    {:ok, {:committed, :admitted, _code, run}} =
      Loopex.command_disposition(attachment, command_id)

    {attachment, run}
  end
end
