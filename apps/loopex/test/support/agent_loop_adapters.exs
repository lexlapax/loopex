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
    {:ok, pid} = Agent.start_link(fn -> %{script: script, seen: [], previous_worker: nil} end)
    pid
  end

  def retained_progress(pid), do: Agent.get(pid, &Map.get(&1, :progress))

  def dispatched(pid), do: Agent.get(pid, & &1.seen) |> Enum.reverse()

  @impl Loopex.Model
  def complete(request, options, progress \\ nil) do
    pid = Keyword.fetch!(options, :script)
    progress = progress || Loopex.Model.discard_progress()
    worker = self()

    {turn, previous_worker} =
      Agent.get_and_update(pid, fn state ->
        {next, rest} =
          case state.script do
            [] -> {%{text: "done", calls: []}, []}
            [next | rest] -> {next, rest}
          end

        {{next, state.previous_worker},
         %{state | script: rest, seen: [request | state.seen], previous_worker: worker}}
      end)

    if Map.get(turn, :require_previous_worker_down, false) and
         is_pid(previous_worker) and Process.alive?(previous_worker) do
      raise "the replacement model call began before its predecessor terminated"
    end

    # Concept: an adapter that names its own stream domain and sequence.
    #
    # Technical depth: `Loopex.Model.valid_delta?/1` admits any plain bounded map
    # carrying a known `:kind`, so extra keys pass it. Whether the coordinator's
    # own labels survive an adapter that supplies its own is a question only an
    # adapter that supplies them can ask, and no fixture did.
    forged = Map.get(turn, :forged_labels, %{})

    # The adapter keeps the callback it was handed, as a real one does for as
    # long as it holds the attempt. A case can then ask the only question that
    # matters about closure: what happens when it is called once more afterwards.
    :ok = Agent.update(pid, fn state -> Map.put(state, :progress, progress) end)

    Enum.each(Map.get(turn, :deltas, []), fn text ->
      progress.(Map.merge(%{kind: :text_delta, content_index: 0, text: text}, forged))
    end)

    # Concept: a turn that can be held open, so a test can steer a live run.
    #
    # Technical depth: the adapter blocks inside the supervised task exactly as a
    # slow provider would, which is the only way to observe input admitted while
    # a run is genuinely active rather than between runs. A test's wait for
    # `{:holding, _}` is liveness only: it measures how soon a loaded host
    # schedules the run to its first request, which no case claims, so those
    # waits allow 5 s rather than a bound a busy suite can cross.
    case Map.get(turn, :hold) do
      nil ->
        :ok

      waiter when is_pid(waiter) ->
        send(waiter, {:holding, self()})
        hold_timeout_ms = Map.get(turn, :hold_timeout_ms, 5_000)

        receive do
          :release -> :ok
        after
          hold_timeout_ms -> :ok
        end
    end

    case Map.fetch(turn, :raw_result) do
      {:ok, result} ->
        result

      :error ->
        case Map.get(turn, :error) do
          nil ->
            text =
              case Map.get(turn, :text, "") do
                builder when is_function(builder, 1) -> builder.(request)
                text -> text
              end

            reply = %{
              completion: "unknown",
              continuation: nil,
              text: text,
              identity: %{provider: "scripted", model: request.model, endpoint: "in-process"},
              # ADR 0018: a dispatched attempt whose usage is not a complete reported
              # pair is charged the whole remaining allowance. A scripted provider that
              # completes a turn reports usage like a real one; a case that wants the
              # conservative charge passes an incomplete `usage:` explicitly.
              usage: Map.get(turn, :usage, %{input_tokens: 1, output_tokens: 1}),
              tool_calls: Map.get(turn, :calls, []),
              delta_count: Map.get(turn, :delta_count, length(Map.get(turn, :deltas, []))),
              streamed: Map.get(turn, :deltas, []) != [],
              provider_response_id: nil,
              canonical_request_bytes: request.canonical_request_bytes,
              staged_request_digest: request.staged_request_digest
            }

            {:ok, Map.merge(reply, Map.get(turn, :reply_overrides, %{}))}

          reason ->
            {:error, reason}
        end
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

  def start(
        outcomes \\ %{},
        delay_ms \\ 0,
        cleanup \\ :cleaned,
        progress_gate \\ nil,
        artifacts \\ %{}
      ) do
    {:ok, pid} =
      Agent.start_link(fn ->
        %{
          outcomes: outcomes,
          jobs: [],
          delay_ms: delay_ms,
          cleanup: cleanup,
          progress_gate: progress_gate,
          artifacts: artifacts
        }
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

    {outcome, artifacts} =
      Agent.get(pid, fn state ->
        {
          Map.get(state.outcomes, job.tool_call_id, "completed"),
          Map.get(state.artifacts, job.tool_call_id, [])
        }
      end)

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
      protocol_version: job.protocol_version,
      job_id: job.job_id,
      tool_call_id: job.tool_call_id,
      operation_id: job.operation_id,
      attempt: job.attempt,
      session_id: job.session_id,
      run_id: job.run_id,
      turn_id: job.turn_id,
      canonical_request_digest: job.canonical_request_digest,
      session_epoch_at_dispatch: job.origin_session_epoch,
      executor_epoch: job.origin_executor_epoch,
      executor_identity: job.executor_identity,
      fencing_token: job.fencing_token,
      progress_sequence: 0,
      stream: "stdout",
      byte_offset: 0,
      chunk: "working"
    })

    # Concept: a case can keep the tool unfinished after progress was emitted.
    #
    # Technical depth: progress and durable events reach a test from different
    # processes, so comparing their mailbox arrival order is a scheduler race.
    # This optional gate makes the operator claim causal instead: the executor
    # cannot return, and therefore `tool.finished` cannot be committed, until
    # the case has observed the transient item and releases this worker.
    case Agent.get(pid, & &1.progress_gate) do
      waiter when is_pid(waiter) ->
        send(waiter, {:tool_progress_emitted, job.tool_call_id, self()})

        receive do
          :release -> :ok
        after
          5_000 -> raise "tool progress gate was never released"
        end

      _none ->
        :ok
    end

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
       provider_credential_present: false,
       artifacts: artifacts
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

defmodule Loopex.AgentLoopUnexpectedPolicy do
  @moduledoc false

  @behaviour Loopex.Policy

  @impl Loopex.Policy
  def decide(_request), do: raise("schema-invalid arguments reached host policy")
end
