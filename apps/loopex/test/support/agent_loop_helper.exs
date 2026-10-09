Code.require_file("progress_test_consumer.exs", __DIR__)
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
  # Concept: a host maintenance selection and one valid scripted summary, so a
  # transport fixture can run a real explicit compaction.
  # Technical depth: the selection disables thinking under the captured scripted
  # configuration; the summary's text never reaches a public projection.
  @doc false
  def maintenance_options do
    configuration = Loopex.ConfiguredGenesisFixture.configuration()

    [
      maintenance_model: %{
        "model" => configuration["model"],
        "reasoning" => "none",
        "model_capabilities" => %{
          configuration["model_capabilities"]
          | "reasoning_levels" => ["none", "default"]
        },
        "provider_mapping" => %{configuration["provider_mapping"] | "thinking_disabled" => true}
      },
      maintenance_instructions: %{"version" => "summary.v1", "body" => "Keep facts"}
    ]
  end

  @doc false
  def summary_reply do
    %{
      text:
        ~s({"summary":"retain this fact","carry_forward":{"files_read":[],"files_changed":[]}}),
      reply_overrides: %{completion: "natural", continuation: nil},
      usage: %{input_tokens: 37, output_tokens: 19}
    }
  end

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

    key = {__MODULE__, make_ref()}
    Process.put(key, %{actors: [], runtime: nil})

    try do
      model_pid = Loopex.AgentLoopTestModel.start(script)
      own_constructor_actor(key, :model, model_pid)

      executor_pid =
        Loopex.AgentLoopTestExecutor.start(
          outcomes,
          Keyword.get(options, :tool_delay_ms, 0),
          Keyword.get(options, :cleanup, :cleaned),
          Keyword.get(options, :tool_progress_gate),
          Keyword.get(options, :artifacts, %{})
        )

      own_constructor_actor(key, :executor, executor_pid)

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

      if is_nil(Keyword.get(options, :store)),
        do: own_constructor_actor(key, :store, store_pid)

      {:ok, runtime} =
        Loopex.start_link(
          context_token_budget: Keyword.get(options, :context_token_budget, 8_192),
          session_creation_defaults: creation_defaults(definitions, options),
          runtime_id: Keyword.get(options, :runtime_id, "agent-loop-runtime"),
          store: store,
          cleanup_grace_ms: Keyword.get(options, :cleanup_grace_ms),
          progress_sink: Keyword.get(options, :progress_sink),
          diagnostics_to: Keyword.get(options, :diagnostics_to),
          model: %{
            module: Keyword.get(options, :model_module, Loopex.AgentLoopTestModel),
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

      own_constructor_actor(key, :runtime, runtime.supervisor)
      Process.put(key, %{Process.get(key) | runtime: runtime})

      fixture = %{
        runtime: runtime,
        model: model_pid,
        executor: executor_pid,
        store: store_pid,
        definitions: definitions,
        progress_sink: Keyword.get(options, :progress_sink)
      }

      await_creation_ready(runtime, System.monotonic_time(:millisecond) + 1_000)
      fixture
    catch
      kind, reason ->
        stack = __STACKTRACE__
        owned = Process.get(key)
        receipt = cleanup_constructor(owned, System.monotonic_time(:millisecond) + 1_000)

        Process.put(
          {__MODULE__, :constructor_cleanup},
          Map.put(receipt, :original_failure, {kind, reason, stack})
        )

        :erlang.raise(kind, reason, stack)
    after
      owned = Process.delete(key)
      for {_kind, _pid, monitor} <- owned.actors, do: Process.demonitor(monitor, [:flush])
    end
  end

  # Concept: failed construction retires only resources acquired by this call.
  # Technical depth: every original actor is monitored before the next
  # acquisition. Borrowed Stores remain host-owned. Parallel stop calls spend
  # one captured fixture grace; no slow actor can skip the other stop attempts.
  # The receipt records physical original DOWN and stop-worker DOWN separately.
  # Unproved retirement remains explicit in the surviving caller while the
  # original constructor exception and stack are reraised unchanged.
  defp own_constructor_actor(key, kind, pid) do
    monitor = Process.monitor(pid)
    owned = Process.get(key)
    Process.put(key, %{owned | actors: [{kind, pid, monitor} | owned.actors]})
  end

  defp cleanup_constructor(owned, cutoff) do
    owner = self()
    token = make_ref()

    workers =
      Enum.map(owned.actors, fn {kind, pid, monitor} ->
        {worker, worker_monitor} =
          spawn_monitor(fn ->
            result =
              try do
                if kind == :runtime do
                  Loopex.stop(owned.runtime)
                else
                  GenServer.stop(
                    pid,
                    :normal,
                    max(cutoff - System.monotonic_time(:millisecond), 0)
                  )
                end
              catch
                stop_kind, stop_reason -> {:stop_failed, stop_kind, stop_reason}
              end

            send(owner, {token, kind, result})
          end)

        %{kind: kind, pid: pid, monitor: monitor, worker: worker, worker_monitor: worker_monitor}
      end)

    actors =
      Enum.map(workers, fn actor ->
        down = constructor_down(actor.pid, actor.monitor, cutoff)
        worker_down = constructor_down(actor.worker, actor.worker_monitor, cutoff)
        if worker_down == :unproved, do: Process.exit(actor.worker, :kill)

        result =
          receive do
            {^token, kind, result} when kind == actor.kind -> result
          after
            0 -> :unproved
          end

        worker_down =
          if worker_down == :unproved,
            do: constructor_down(actor.worker, actor.worker_monitor, cutoff),
            else: worker_down

        if worker_down != :unproved, do: Process.demonitor(actor.worker_monitor, [:flush])
        Map.merge(actor, %{original_down: down, worker_down: worker_down, stop_result: result})
      end)

    observed_at = System.monotonic_time(:millisecond)

    status =
      if observed_at < cutoff and
           Enum.all?(actors, fn actor ->
             actor.original_down != :unproved and actor.worker_down != :unproved and
               actor.stop_result == :ok
           end) do
        :joined
      else
        :cleanup_unproved
      end

    %{status: status, cutoff: cutoff, observed_at: observed_at, actors: actors}
  end

  defp constructor_down(pid, monitor, cutoff) do
    receive do
      {:DOWN, ^monitor, :process, ^pid, reason} -> {:down, reason}
    after
      max(cutoff - System.monotonic_time(:millisecond), 0) -> :unproved
    end
  end

  defp await_creation_ready(runtime, cutoff) do
    remaining = cutoff - System.monotonic_time(:millisecond)

    if remaining <= 0,
      do: raise("fixture creation startup did not settle within its observation bound")

    with {:ok, %{control: control}} <- Loopex.Runtime.children(runtime),
         true <- is_pid(control),
         %{creation_status: status} <- :sys.get_state(control, remaining) do
      case status do
        :ready ->
          :ok

        :starting ->
          remaining = max(cutoff - System.monotonic_time(:millisecond), 0)

          receive do
            :no_fixture_message -> :ok
          after
            min(remaining, 10) -> :ok
          end

          await_creation_ready(runtime, cutoff)

        other ->
          raise "fixture creation startup unavailable: #{inspect(other)}"
      end
    else
      _ -> raise "fixture creation startup capability unavailable"
    end
  catch
    :exit, _reason -> raise "fixture creation startup capability unavailable"
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

defmodule Loopex.AgentLoopPreparingModel do
  @moduledoc """
  ## Concept

  The scripted fixture model, plus host-style preparation of authored
  configuration changes, so transport tests can configure a live session.

  ## Technical depth

  `complete/3` delegates to the scripted model. `prepare_configuration/5`
  resolves any authored model name to the fixture's canonical `scripted:v1`
  through the shared configuration updater; it holds no other state.
  """
  @behaviour Loopex.Model

  @canonical "scripted:v1"

  @impl true
  def complete(request, options, progress),
    do: Loopex.AgentLoopTestModel.complete(request, options, progress)

  @impl true
  def prepare_configuration(current, authored, definitions, _context, _options) do
    effective =
      if Map.has_key?(authored, "model"),
        do: Map.put(authored, "model", @canonical),
        else: authored

    Loopex.Runtime.SessionConfiguration.update(
      current,
      effective,
      Map.put(current["model_capabilities"], "model", @canonical),
      current["provider_mapping"],
      definitions
    )
  end
end
