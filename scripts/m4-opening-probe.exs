# Concept: observe how a real local session resolves a host-policy `defer`.
# Technical depth: the deterministic model asks for exactly one tool call; the
# fixture executor records every invocation. Allow and deny are positive
# controls proving the call reaches policy and the journal; defer is the witness.
defmodule Loopex.M4Opening.Model do
  def complete(request, options, _progress) do
    observer = Keyword.fetch!(options, :observer)
    send(observer, :model_called)
    turn = Agent.get_and_update(Keyword.fetch!(options, :turns), &{&1 + 1, &1 + 1})

    calls =
      if turn == 1,
        do: [%{id: "m4-probe-call", name: "write", arguments: %{"path" => "m4-probe.txt"}}],
        else: []

    {:ok,
     %{
       text: if(turn == 1, do: "writing", else: "done"),
       identity: %{provider: "fixture", model: request.model, endpoint: "in-process"},
       usage: %{input_tokens: 1, output_tokens: 1},
       tool_calls: calls,
       delta_count: 0,
       streamed: false,
       canonical_request_bytes: request.canonical_request_bytes,
       staged_request_digest: request.staged_request_digest
     }}
  end
end

defmodule Loopex.M4Opening.AllowPolicy do
  def decide(_request), do: {:allow, nil}
end

defmodule Loopex.M4Opening.DenyPolicy do
  def decide(_request), do: {:deny, :policy_denied}
end

defmodule Loopex.M4Opening.DeferPolicy do
  def decide(_request) do
    {:defer,
     %{
       kind: "choice",
       prompt: "Allow the bounded M4 probe write?",
       choices: [%{id: "continue", label: "Continue"}, %{id: "deny", label: "Deny"}],
       expires_in_ms: 10_000
     }}
  end
end

defmodule Loopex.M4Opening.Executor do
  def execute(observer, job, _grant, _options, _progress) do
    send(observer, {:executor_called, job.tool_call_id})

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
       outcome: "completed",
       output: "probe output",
       progress_count: 0,
       observed_at_ms: System.system_time(:millisecond),
       child_environment_names: [],
       provider_credential_present: false,
       artifacts: []
     }}
  end

  def cancel(_, _), do: {:ok, :cleaned}
end

defmodule Loopex.M4Opening do
  alias Loopex.Store

  @tool %{
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
  }

  def run(root) do
    allow = observe(root, "allow", Loopex.M4Opening.AllowPolicy)
    deny = observe(root, "deny", Loopex.M4Opening.DenyPolicy)
    defer = observe(root, "defer", Loopex.M4Opening.DeferPolicy)

    require_witness(allow.executor_calls == ["m4-probe-call"], "allow_control_effect_missing")
    require_witness(allow.model_calls == 2, "allow_control_model_turns_unexpected")

    require_witness(
      allow.intent and is_nil(allow.terminal) and
        to_string(receipt_field(allow.receipt, :outcome)) == "completed",
      "allow_control_receipt_missing"
    )

    require_witness(
      allow.settled and allow.interaction_records == [],
      "allow_control_not_settled"
    )

    require_witness(
      deny.executor_calls == [] and is_nil(deny.receipt) and not deny.intent,
      "deny_control_unexpected_effect"
    )

    require_witness(
      match?(%{"outcome" => "denied", "reason" => "policy_denied"}, deny.terminal),
      "deny_control_terminal_missing"
    )

    require_witness(deny.settled and deny.interaction_records == [], "deny_control_not_settled")

    require_witness(
      defer.executor_calls == [] and is_nil(defer.receipt) and not defer.intent,
      "defer_unexpected_effect_before_answer"
    )

    IO.puts(
      "LOOPEX_M4_OBSERVATION controls=2/2 allow_outcome=#{receipt_field(allow.receipt, :outcome)} " <>
        "deny_reason=#{deny.terminal["reason"]} " <>
        "defer_outcome=#{inspect(defer.terminal && defer.terminal["outcome"])} " <>
        "defer_reason=#{inspect(defer.terminal && defer.terminal["reason"])} " <>
        "defer_settled=#{defer.settled} " <>
        "defer_interaction_records=#{length(defer.interaction_records)} defer_executor_calls=0"
    )

    cond do
      match?(%{"outcome" => "denied", "reason" => "interaction_unsupported"}, defer.terminal) ->
        IO.puts(
          "M4 gate RED: policy defer denies the tool call as interaction_unsupported instead of committing a durable pending interaction"
        )

        System.halt(1)

      is_nil(defer.terminal) and defer.interaction_records != [] and not defer.settled ->
        IO.puts(
          "M4 opening GREEN: policy defer commits a pending interaction and suspends the run"
        )

      true ->
        throw({:witness_error, "defer_neither_denied_nor_durably_pending"})
    end
  end

  defp receipt_field(nil, _key), do: nil

  defp receipt_field(%{"receipt" => receipt}, key) when is_map(receipt),
    do: Map.get(receipt, key, Map.get(receipt, to_string(key)))

  defp require_witness(true, _reason), do: :ok
  defp require_witness(false, reason), do: throw({:witness_error, reason})

  defp observe(root, label, policy) do
    {:ok, pid} = Loopex.Store.Local.start_link(path: Path.join(root, "probe-#{label}.log"))
    {:ok, store} = Store.new(Loopex.Store.Local, pid)
    {:ok, turns} = Agent.start_link(fn -> 0 end)

    {:ok, runtime} =
      Loopex.start_link(
        runtime_id: "m4-probe-#{label}",
        store: store,
        model: %{
          module: Loopex.M4Opening.Model,
          model: "fixture:v1",
          options: [observer: self(), turns: turns]
        },
        executor: %{
          module: Loopex.M4Opening.Executor,
          reference: self(),
          identity: "probe-executor",
          epoch: 1,
          fencing_token: 1,
          workspace_ref: "workspace-ref",
          workspace_lease: "workspace-lease"
        },
        policy: policy,
        bounds: %{max_turns: 4, token_budget: 100_000, deadline_ms: 60_000},
        context_token_budget: 100_000,
        tools: [@tool],
        active_tools: ["example.write"]
      )

    try do
      {:ok, session} = Loopex.create_session(runtime, %{}, command_id: "#{label}-create")
      {:ok, attachment} = Loopex.attach(runtime, session, after_event_sequence: 0)

      {:accepted, _} =
        Loopex.command(attachment, %{
          type: :prompt,
          command_id: "#{label}-prompt",
          content: "write the probe file"
        })

      settled = settle(runtime, session, System.monotonic_time(:millisecond) + 6_000)
      {:ok, records} = Store.load_records(store, session, 0, 200)
      kinds = Enum.map(records, &to_string(&1.payload[:kind]))

      terminal =
        Enum.find(
          records,
          &(to_string(&1.payload[:kind]) == "tool_result_committed" and
              &1.payload["tool_call_id"] == "m4-probe-call")
        )

      receipt =
        Enum.find(
          records,
          &(to_string(&1.payload[:kind]) == "executor_receipt_committed" and
              receipt_field(&1.payload, :tool_call_id) == "m4-probe-call")
        )

      %{
        terminal: terminal && terminal.payload,
        receipt: receipt && receipt.payload,
        intent: "effect_intent_committed" in kinds,
        interaction_records: Enum.filter(kinds, &String.contains?(&1, "interaction")),
        settled: settled,
        model_calls: drain(:model_called, 0),
        executor_calls: drain_executor([])
      }
    after
      Loopex.stop(runtime)
      Agent.stop(turns)
      GenServer.stop(pid)
    end
  end

  # Concept: settlement is observed, never assumed; a suspended run is a result.
  # Technical depth: an unsettled session within the bound is reported as false
  # so the defer observation can distinguish suspension from denial.
  defp settle(runtime, session, deadline) do
    case Loopex.session_status(runtime, session) do
      {:ok, %{active_run_id: nil, pending_work_ids: []}} ->
        true

      _ ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(10)
          settle(runtime, session, deadline)
        else
          false
        end
    end
  end

  defp drain(message, count) do
    receive do
      ^message -> drain(message, count + 1)
    after
      0 -> count
    end
  end

  defp drain_executor(calls) do
    receive do
      {:executor_called, id} -> drain_executor(calls ++ [id])
    after
      0 -> calls
    end
  end
end

Process.flag(:trap_exit, true)

try do
  [root] = System.argv()
  Loopex.M4Opening.run(root)
rescue
  error ->
    IO.puts(
      :stderr,
      "M4 opening UNAVAILABLE: #{inspect(error.__struct__)}: " <>
        String.slice(Exception.message(error), 0, 500)
    )

    System.halt(2)
catch
  :throw, {:witness_error, reason} ->
    IO.puts(:stderr, "M4 opening WITNESS ERROR: #{reason}")
    System.halt(2)

  kind, _reason ->
    IO.puts(:stderr, "M4 opening UNAVAILABLE: #{kind}")
    System.halt(2)
end
