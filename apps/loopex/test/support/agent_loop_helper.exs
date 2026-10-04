_ = System.fetch_env!("LOOPEX_HOME")

Code.require_file("agent_loop_adapters.exs", __DIR__)
Code.require_file("configured_genesis_helper.exs", __DIR__)

defmodule Loopex.AgentLoopFixture do
  @moduledoc false

  alias Loopex.M1RuntimeTestStore

  def tool_definition(overrides \\ %{}) do
    Map.merge(
      %{
        "tool_id" => "example.write",
        "tool_version" => "1.0.0",
        "name" => "write",
        "description" => "Write a file beneath the workspace root.",
        "parameter_schema" => %{
          "type" => "object",
          "properties" => %{"path" => %{"type" => "string"}},
          "required" => ["path"]
        },
        "result_shape" => %{"content_type" => "text", "description" => "What was written."},
        "effect_class" => "workspace_write",
        "idempotency_class" => "reconcile_then_retry",
        "budgets" => %{
          "wall_time_ms" => 30_000,
          "output_bytes" => 65_536,
          "artifact_bytes" => 1_048_576
        }
      },
      overrides
    )
  end

  def bounds(overrides \\ %{}) do
    Map.merge(
      %{max_turns: 8, token_budget: 1_000_000, deadline_ms: 600_000},
      overrides
    )
  end

  # Concept: the scripted host declares the settings its adapter consumes.
  # Technical depth: this adapter reads canonical typed history directly. Its
  # captured renderer supports terminal tool history without provider-native
  # continuation, and each session retains the declared reply and cleanup bounds.
  def creation_defaults(definitions, options \\ []) do
    model_id = Keyword.get(options, :model, "scripted:v1")

    configuration =
      Loopex.ConfiguredGenesisFixture.configuration()
      |> Map.put("model", model_id)
      |> Map.put("max_tokens", Keyword.get(options, :max_tokens, 256))
      |> Map.put("context_token_budget", Keyword.get(options, :context_token_budget, 8_192))
      |> Map.put("system_class_tokens", Keyword.get(options, :system_class_tokens, 5_000))
      |> put_in(
        ["budget_origins", "context_token_budget"],
        if(Keyword.has_key?(options, :context_token_budget),
          do: "explicit",
          else: "unknown_window"
        )
      )
      |> put_in(["model_capabilities", "model"], model_id)
      |> put_in(["model_capabilities", "reasoning_levels"], ["default"])
      |> put_in(["provider_mapping", "mapping_revision"], "loopex.test.scripted.mapping.v1")
      |> put_in(["provider_mapping", "renderer_revision"], "loopex.test.scripted.renderer.v1")
      |> put_in(["provider_mapping", "canonical_terminal_tool_history"], true)

    Loopex.ConfiguredGenesisFixture.genesis(definitions, configuration)
    |> Map.drop([:kind, "options"])
    |> put_in(
      ["runtime_configuration", "cleanup_grace_ms"],
      Keyword.get(options, :cleanup_grace_ms) || 5_000
    )
  end

  def start(options) do
    script = Keyword.fetch!(options, :script)
    definitions = Keyword.get(options, :tools, [tool_definition()])
    outcomes = Keyword.get(options, :outcomes, %{})

    model_pid = Loopex.AgentLoopTestModel.start(script)

    executor_pid =
      Loopex.AgentLoopTestExecutor.start(
        outcomes,
        Keyword.get(options, :tool_delay_ms, 0),
        Keyword.get(options, :cleanup, :cleaned),
        Keyword.get(options, :tool_progress_gate),
        Keyword.get(options, :artifacts, %{})
      )

    # A case about recovery starts a second fixture over the first one's Store,
    # which is what makes the successor a successor rather than a new session.
    #
    # A case about recovery across operating-system processes needs a Store that
    # outlives one, so it names the module as well as the handle. The in-memory
    # default stays the default, because most cases want a Store that disappears
    # with them.
    {store_pid, store} =
      case {Keyword.get(options, :store), Keyword.get(options, :store_module)} do
        {nil, _module} ->
          M1RuntimeTestStore.start_store(label: "agent-loop")

        {existing, nil} ->
          {:ok, store} = Loopex.Store.new(M1RuntimeTestStore, existing)
          {existing, store}

        {existing, module} ->
          {:ok, store} = Loopex.Store.new(module, existing)
          {existing, store}
      end

    {:ok, runtime} =
      Loopex.start_link(
        context_token_budget: Keyword.get(options, :context_token_budget, 8_192),
        session_creation_defaults: creation_defaults(definitions, options),
        runtime_id: Keyword.get(options, :runtime_id, "agent-loop-runtime"),
        store: store,
        cleanup_grace_ms: Keyword.get(options, :cleanup_grace_ms),
        progress_to: Keyword.get(options, :progress_to),
        diagnostics_to: Keyword.get(options, :diagnostics_to),
        model: %{
          module: Loopex.AgentLoopTestModel,
          model: Keyword.get(options, :model, "scripted:v1"),
          options: [script: model_pid, max_tokens: Keyword.get(options, :max_tokens, 256)]
        },
        maintenance_model: Keyword.get(options, :maintenance_model),
        maintenance_instructions: Keyword.get(options, :maintenance_instructions),
        executor: %{
          module: Loopex.AgentLoopTestExecutor,
          reference: executor_pid,
          identity: "agent-loop-executor",
          epoch: 1,
          fencing_token: 1,
          workspace_ref: Keyword.get(options, :workspace_ref, "workspace-ref"),
          workspace_lease: "workspace-lease"
        },
        tool: nil,
        bounds: %{
          max_turns: Keyword.get(options, :bounds_max_turns, 8),
          token_budget: Keyword.get(options, :bounds_token_budget, 1_000_000),
          deadline_ms: Keyword.get(options, :bounds_deadline_ms, 600_000)
        },
        project_manifest: Keyword.get(options, :project_manifest),
        project_decision: Keyword.get(options, :project_decision),
        resource_manifest: Keyword.get(options, :resource_manifest),
        # A case about ADR 0028 transfers needs the runtime composed with a
        # store that implements them; every other case leaves it absent, which
        # is what makes the unsupported refusal reachable.
        artifact_store: Keyword.get(options, :artifact_store),
        tools: definitions,
        active_tools: Enum.map(definitions, &Map.fetch!(&1, "tool_id")),
        policy: Keyword.get(options, :policy, Loopex.AgentLoopTestPolicy),
        # A case about the policy binding surviving a restart needs to name the
        # identity itself; every other case takes the launch default.
        policy_identity:
          Keyword.get(options, :policy_identity, %{
            "id" => "loopex.test.agent_loop_policy",
            "revision" => "1"
          }),
        grant_decision: {:host_policy, :allow}
      )

    %{
      runtime: runtime,
      model: model_pid,
      executor: executor_pid,
      store: store_pid,
      definitions: definitions
    }
  end

  def stop(fixture) do
    try do
      Loopex.stop(fixture.runtime)
    catch
      :exit, _reason -> :ok
    end

    try do
      GenServer.stop(fixture.store, :normal, 1_000)
    catch
      :exit, _reason -> :ok
    end
  end

  def run(fixture, content, bound_overrides \\ %{}) do
    {:ok, session_id} =
      Loopex.create_session(fixture.runtime, %{"tenant" => "t"}, command_id: "create-1")

    {:ok, attachment} = Loopex.attach(fixture.runtime, session_id, after_event_sequence: 0)

    # Concept: a prompt names bounds only when the case is about overriding them.
    #
    # Technical depth: supplying them unconditionally would mask the runtime's
    # own declared configuration, so a case that set a runtime bound would still
    # see the command's default and quietly test nothing.
    command =
      %{type: :prompt, command_id: "prompt-1", content: content}
      |> then(fn command ->
        if map_size(bound_overrides) == 0,
          do: command,
          else: Map.put(command, :bounds, bounds(bound_overrides))
      end)

    reply = Loopex.command(attachment, command)

    {session_id, attachment, reply}
  end

  def await_events(attachment, wanted, acc \\ []) do
    if Enum.any?(acc, &(&1.kind == wanted)) do
      Enum.reverse(acc)
    else
      case Loopex.next_event(attachment) do
        {:ok, event} -> await_events(attachment, wanted, [event | acc])
        _other -> Enum.reverse(acc)
      end
    end
  end

  def run_ids(fixture) do
    fixture.store
    |> M1RuntimeTestStore.inspect_state()
    |> Map.fetch!(:sessions)
    |> Map.keys()
    |> List.to_tuple()
  end

  # The public history beside the private records, for a case that has to rebuild
  # a session the way a recovering owner does: `recover/3` validates the two
  # against each other, so a record list without its events is refused.
  def events(fixture, session_id) do
    M1RuntimeTestStore.inspect_state(fixture.store).sessions
    |> Map.get(session_id, %{events: []})
    |> Map.get(:events, [])
  end

  def records(fixture, session_id) do
    M1RuntimeTestStore.inspect_state(fixture.store).sessions
    |> Map.get(session_id, %{records: []})
    |> Map.fetch!(:records)
  end
end
