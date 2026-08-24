_ = System.fetch_env!("LOOPEX_HOME")

defmodule Loopex.AgentLoopTestModel do
  @moduledoc false

  # Concept: a model whose every turn is scripted, so the loop's behaviour is
  # the only variable.
  #
  # Technical depth: the script is a list of turn results consumed in order and
  # held in an agent, not in the adapter, because the adapter is called from a
  # fresh task per turn. Each call records the exact request it was handed so a
  # test can assert on the bytes that were dispatched rather than on the bytes a
  # test rebuilt for itself.

  @behaviour Loopex.Model

  def start(script) when is_list(script) do
    {:ok, pid} = Agent.start_link(fn -> %{script: script, seen: []} end)
    pid
  end

  def dispatched(pid), do: Agent.get(pid, & &1.seen) |> Enum.reverse()

  @impl Loopex.Model
  def complete(request, options, progress \\ nil) do
    pid = Keyword.fetch!(options, :script)
    progress = progress || Loopex.Model.discard_progress()

    turn =
      Agent.get_and_update(pid, fn state ->
        {next, rest} =
          case state.script do
            [] -> {%{text: "done", calls: []}, []}
            [next | rest] -> {next, rest}
          end

        {next, %{state | script: rest, seen: [request | state.seen]}}
      end)

    Enum.each(Map.get(turn, :deltas, []), fn text ->
      progress.(%{kind: :text_delta, content_index: 0, text: text})
    end)

    # Concept: a turn that can be held open, so a test can steer a live run.
    #
    # Technical depth: the adapter blocks inside the supervised task exactly as a
    # slow provider would, which is the only way to observe input admitted while
    # a run is genuinely active rather than between runs.
    case Map.get(turn, :hold) do
      nil ->
        :ok

      waiter when is_pid(waiter) ->
        send(waiter, {:holding, self()})

        receive do
          :release -> :ok
        after
          5_000 -> :ok
        end
    end

    case Map.get(turn, :error) do
      nil ->
        {:ok,
         %{
           text: Map.get(turn, :text, ""),
           identity: %{provider: "scripted", model: request.model, endpoint: "in-process"},
           usage: Map.get(turn, :usage, %{}),
           tool_calls: Map.get(turn, :calls, []),
           delta_count: length(Map.get(turn, :deltas, [])),
           streamed: Map.get(turn, :deltas, []) != [],
           canonical_request_bytes: request.canonical_request_bytes,
           staged_request_digest: request.staged_request_digest
         }}

      reason ->
        {:error, reason}
    end
  end
end

defmodule Loopex.AgentLoopTestExecutor do
  @moduledoc false

  # Concept: an executor that answers instantly with a controllable outcome.
  #
  # Technical depth: it validates nothing about authority, because the trusted
  # local executor already owns that and re-proving it here would make this
  # helper a second executor rather than a test double.

  @behaviour Loopex.Executor

  def start(outcomes \\ %{}, delay_ms \\ 0, cleanup \\ :cleaned) do
    {:ok, pid} =
      Agent.start_link(fn ->
        %{outcomes: outcomes, jobs: [], delay_ms: delay_ms, cleanup: cleanup}
      end)

    pid
  end

  def jobs(pid), do: Agent.get(pid, & &1.jobs) |> Enum.reverse()

  # Concept: an executor that can be told to stop, and can be told it could not
  # confirm that it did.
  #
  # Technical depth: the unconfirmed answer is what drives a run to
  # `outcome_unknown` rather than `cancelled`, so a case about that precedence
  # needs an executor that can actually give it.
  @impl Loopex.Executor
  def cancel(pid, _job_id) do
    case Agent.get(pid, &Map.get(&1, :cleanup, :cleaned)) do
      :unconfirmed -> {:ok, :unconfirmed}
      _cleaned -> {:ok, :cleaned}
    end
  end

  @impl Loopex.Executor
  def execute(pid, job, _grant, _options, progress \\ nil) do
    progress = progress || Loopex.Executor.discard_progress()
    :ok = Agent.update(pid, fn state -> %{state | jobs: [job | state.jobs]} end)
    outcome = Agent.get(pid, &Map.get(&1.outcomes, job.tool_call_id, "completed"))

    # Concept: a tool that takes real time, so a deadline can be reached while it
    # runs rather than before it starts.
    #
    # Technical depth: without this the only way to reach a deadline mid-run is a
    # deadline so short the call is cancelled before dispatch, which is a
    # different case entirely and would make a precedence test pass or fail on
    # scheduling.
    case Agent.get(pid, & &1.delay_ms) do
      delay when is_integer(delay) and delay > 0 -> Process.sleep(delay)
      _none -> :ok
    end

    progress.(%{
      tool_call_id: job.tool_call_id,
      stream: "stdout",
      byte_offset: 0,
      chunk: "working"
    })

    {:ok,
     %{
       protocol_version: 1,
       job_id: job.job_id,
       operation_id: job.operation_id,
       attempt: job.attempt,
       session_id: job.session_id,
       run_id: job.run_id,
       turn_id: job.turn_id,
       tool_call_id: job.tool_call_id,
       session_epoch_at_dispatch: job.origin_session_epoch,
       executor_epoch: job.origin_executor_epoch,
       executor_identity: job.executor_identity,
       canonical_request_digest: job.canonical_request_digest,
       fencing_token: job.fencing_token,
       tool_id: job.tool_id,
       tool_version: job.tool_version,
       outcome: outcome,
       output: "tool output for #{job.tool_call_id}",
       progress_count: 1,
       observed_at_ms: System.system_time(:millisecond),
       child_environment_names: [],
       provider_credential_present: false
     }}
  end
end

defmodule Loopex.AgentLoopTestPolicy do
  @moduledoc false

  # Concept: a host policy that allows, so loop cases exercise the loop.
  #
  # Technical depth: a permissive policy is named explicitly here for the same
  # reason a real host must name one — the kernel refuses to run tools for a
  # runtime that declared no authority at all. Cases about refusal name a
  # refusing policy instead.

  @behaviour Loopex.Policy

  @impl Loopex.Policy
  def decide(_request), do: {:allow, nil}
end

defmodule Loopex.AgentLoopFixture do
  @moduledoc false

  alias Loopex.M1RuntimeTestStore

  @far_future 4_102_444_800_000

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

  def start(options) do
    script = Keyword.fetch!(options, :script)
    definitions = Keyword.get(options, :tools, [tool_definition()])
    outcomes = Keyword.get(options, :outcomes, %{})

    model_pid = Loopex.AgentLoopTestModel.start(script)

    executor_pid =
      Loopex.AgentLoopTestExecutor.start(
        outcomes,
        Keyword.get(options, :tool_delay_ms, 0),
        Keyword.get(options, :cleanup, :cleaned)
      )

    {store_pid, store} = M1RuntimeTestStore.start_store(label: "agent-loop")

    {:ok, runtime} =
      Loopex.start_link(
        runtime_id: Keyword.get(options, :runtime_id, "agent-loop-runtime"),
        store: store,
        progress_to: Keyword.get(options, :progress_to),
        diagnostics_to: Keyword.get(options, :diagnostics_to),
        model: %{
          module: Loopex.AgentLoopTestModel,
          model: "scripted:v1",
          options: [script: model_pid, max_tokens: Keyword.get(options, :max_tokens, 256)]
        },
        executor: %{
          module: Loopex.AgentLoopTestExecutor,
          reference: executor_pid,
          identity: "agent-loop-executor",
          epoch: 1,
          fencing_token: 1,
          workspace_ref: "workspace-ref",
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
        tools: definitions,
        active_tools: Enum.map(definitions, &Map.fetch!(&1, "tool_id")),
        policy: Keyword.get(options, :policy, Loopex.AgentLoopTestPolicy),
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

  def records(fixture, session_id) do
    M1RuntimeTestStore.inspect_state(fixture.store).sessions
    |> Map.get(session_id, %{records: []})
    |> Map.fetch!(:records)
  end
end
