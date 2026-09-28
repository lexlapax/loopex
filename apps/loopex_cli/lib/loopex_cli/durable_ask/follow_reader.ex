defmodule LoopexCli.DurableAsk.FollowReader do
  @moduledoc """
  ## Concept

  Follows only the run admitted by one durable `ask` prompt. Its disposable
  attachment never advances the command's durable recovery cursor.

  ## Technical depth

  One linked, monitored reader owns the replay attachment. The callback accepts
  one event at a time through a PID/reference handshake and acknowledges the
  accepted cursor before the reader asks again. Every return path reaps that
  exact process within a private bound or discards the projection.
  """

  @uint64_max 18_446_744_073_709_551_615
  @observed_max 55_340_232_221_128_654_844
  @text_max 65_536
  @tool_max 256
  @reap_ms 1_000
  @poll_ms 1_000
  @empty_ms 10
  @tool_outcomes ~w(completed failed denied cancelled cancelled_workspace_lease_lost outcome_unknown)
  @run_outcomes %{
    "completed" => :completed,
    "failed" => :failed,
    "bound_reached" => :bound_reached,
    "outcome_unknown" => :outcome_unknown,
    "cancelled" => :cancelled
  }

  @doc """
  ## Concept

  Returns one bounded selected-run observation or one fixed reader diagnostic.

  ## Technical depth

  `started_at` is recorded by the caller directly after the exact prompt
  acceptance. The clock and facade arguments are private test seams. The
  function never calls a session mutation or writes output.
  """
  @spec follow(term(), binary(), binary(), integer(), pos_integer(), [binary()], keyword()) ::
          {:observation, term()} | {:diagnostic, atom()}
  def follow(runtime, session_id, prompt_id, started_at, duration_ms, shadows, seams) do
    facade = Keyword.fetch!(seams, :facade)
    clock = Keyword.fetch!(seams, :monotonic_ms)
    previous_trap = Process.flag(:trap_exit, true)

    try do
      callback = self()
      reference = make_ref()

      spawn_reader =
        Keyword.get(seams, :spawn_reader, fn function ->
          :erlang.spawn_opt(function, [:link, :monitor])
        end)

      {reader, monitor} =
        spawn_reader.(fn -> read(callback, reference, runtime, session_id, facade, clock) end)

      state = %{
        reader: reader,
        monitor: monitor,
        reference: reference,
        clock: clock,
        deadline: min(@uint64_max, started_at + duration_ms + 30_000),
        started_at: started_at,
        prompt_id: prompt_id,
        cursor: 0,
        joined: nil,
        observation: %{
          profile: :durable,
          session_id: session_id,
          run_id: nil,
          text: "",
          text_truncated: false,
          tools: [],
          tools_truncated: false,
          shadowed_skills: shadows
        }
      }

      outcome =
        try do
          {:returned, await(state)}
        rescue
          error -> {:raised, :error, error, __STACKTRACE__}
        catch
          kind, reason -> {:raised, kind, reason, __STACKTRACE__}
        end

      case outcome do
        {:returned, {result, mode, final_state}} ->
          case reap(final_state, mode) do
            :ok -> result
            :abnormal -> unavailable(final_state)
            :unconfirmed -> {:diagnostic, :follow_reader_cleanup_unconfirmed}
          end

        {:raised, kind, reason, stacktrace} ->
          case reap(state, :kill) do
            :unconfirmed -> {:diagnostic, :follow_reader_cleanup_unconfirmed}
            _ -> :erlang.raise(kind, reason, stacktrace)
          end
      end
    after
      Process.flag(:trap_exit, previous_trap)
    end
  end

  defp read(callback, reference, runtime, session_id, facade, clock) do
    result = facade.(Loopex, :attach, [runtime, session_id, [after_event_sequence: 0]])

    case result do
      {:ok, %Loopex.Attachment{} = attachment} ->
        read_next(callback, reference, attachment, facade, clock)

      _ ->
        return_and_wait(callback, reference, {:error, :attachment}, clock.(), 0, nil)
    end
  end

  defp read_next(callback, reference, attachment, facade, clock) do
    result = facade.(Loopex, :next_event, [attachment])

    cursor =
      if match?({:ok, %{event_sequence: _}}, result),
        do: elem(result, 1).event_sequence,
        else: nil

    return_and_wait(callback, reference, result, clock.(), cursor, {attachment, facade, clock})
  end

  defp return_and_wait(callback, reference, result, finished_at, cursor, continuation) do
    send(callback, {self(), reference, result, finished_at})

    receive do
      {^callback, ^reference, :finish} ->
        :ok

      {^callback, ^reference, :accept, accepted_cursor}
      when is_integer(accepted_cursor) and accepted_cursor >= 0 ->
        case continuation do
          {attachment, facade, clock} ->
            if result == {:error, :empty}, do: Process.sleep(@empty_ms)

            if is_nil(cursor) or cursor == accepted_cursor,
              do: read_next(callback, reference, attachment, facade, clock),
              else: :ok

          nil ->
            :ok
        end
    end
  end

  defp await(state) do
    remaining = state.deadline - state.clock.()
    timeout = if remaining <= 0, do: 0, else: min(remaining, @poll_ms)
    reader = state.reader
    reference = state.reference
    monitor = state.monitor

    receive do
      {^reader, ^reference, result, finished_at} ->
        if is_integer(finished_at) and finished_at <= state.deadline do
          accept_return(state, result)
        else
          {timeout(state), :finish, state}
        end

      {:DOWN, ^monitor, :process, ^reader, _reason} ->
        {unavailable(state), :already_down, state}

      {:EXIT, ^reader, _reason} ->
        await(state)
    after
      timeout ->
        if timeout == 0,
          do: {timeout(state), :kill, state},
          else: await(state)
    end
  end

  defp accept_return(state, {:ok, event}) do
    with {:ok, sequence} <- event_sequence(event, state.cursor),
         {:ok, next, terminal} <- project(state, event, sequence) do
      case terminal do
        nil ->
          send(state.reader, {self(), state.reference, :accept, sequence})

          if next.clock.() >= next.deadline,
            do: {timeout(next), :kill, next},
            else: await(next)

        ending ->
          {ending, :finish, next}
      end
    else
      _ -> {unavailable(state), :finish, state}
    end
  end

  defp accept_return(state, {:error, :empty}) do
    send(state.reader, {self(), state.reference, :accept, state.cursor})

    if state.clock.() >= state.deadline,
      do: {timeout(state), :kill, state},
      else: await(state)
  end

  defp accept_return(state, _), do: {unavailable(state), :finish, state}

  defp event_sequence(%{event_sequence: sequence, kind: kind}, cursor)
       when is_integer(sequence) and sequence > cursor and sequence <= @uint64_max and
              is_binary(kind),
       do: {:ok, sequence}

  defp event_sequence(_, _), do: :error

  defp project(state, %{kind: "user.message_appended"} = event, sequence) do
    case {Map.get(event, "command_id"), state.joined} do
      {prompt_id, nil} when prompt_id == state.prompt_id ->
        run_id = Map.get(event, "run_id")

        if bounded_id?(run_id) do
          observation = %{state.observation | run_id: run_id}
          {:ok, %{state | cursor: sequence, joined: run_id, observation: observation}, nil}
        else
          :error
        end

      {prompt_id, _run_id} when prompt_id == state.prompt_id ->
        :error

      _ ->
        {:ok, %{state | cursor: sequence}, nil}
    end
  end

  defp project(state, event, sequence) do
    state = %{state | cursor: sequence}

    if not is_nil(state.joined) and Map.get(event, "run_id") == state.joined do
      selected(state, event)
    else
      {:ok, state, nil}
    end
  end

  defp selected(state, %{kind: "assistant.message_appended"} = event) do
    case Map.get(event, "content") do
      content when is_binary(content) ->
        if String.valid?(content) do
          {text, cut?} = bounded_text(content)

          {:ok, %{state | observation: %{state.observation | text: text, text_truncated: cut?}},
           nil}
        else
          :error
        end

      _ ->
        :error
    end
  end

  defp selected(state, %{kind: "tool.finished"} = event) do
    id = Map.get(event, "tool_id")
    outcome = Map.get(event, "outcome")

    if (is_nil(id) or bounded_tool_id?(id)) and outcome in @tool_outcomes do
      tools = state.observation.tools ++ [%{tool_id: id, outcome: outcome}]
      cut? = length(tools) > @tool_max
      tools = if cut?, do: tl(tools), else: tools

      observation = %{
        state.observation
        | tools: tools,
          tools_truncated: state.observation.tools_truncated or cut?
      }

      {:ok, %{state | observation: observation}, nil}
    else
      :error
    end
  end

  defp selected(state, %{kind: "run.finished"} = event) do
    case Map.fetch(@run_outcomes, Map.get(event, "outcome")) do
      {:ok, outcome} ->
        details =
          if outcome == :failed,
            do: normalize_failure(event),
            else: event

        if terminal_details?(outcome, details) do
          observation = Map.merge(state.observation, %{outcome: outcome, details: details})

          ending =
            if outcome == :completed,
              do: {:ok, observation},
              else: {:error, {:run, outcome, observation}}

          {:ok, state, {:observation, ending}}
        else
          :error
        end

      :error ->
        :error
    end
  end

  defp selected(state, _event), do: {:ok, state, nil}

  defp normalize_failure(event) do
    event = event |> Map.put_new("reason", nil) |> Map.put_new("failure", nil)

    case Map.get(event, "failure") do
      %{"category" => "deadline_preflight_failed"} = failure ->
        Map.put(
          event,
          "failure",
          failure
          |> Map.put_new("dimension", nil)
          |> Map.put_new("observed", nil)
          |> Map.put_new("limit", nil)
        )

      _ ->
        event
    end
  end

  defp terminal_details?(outcome, event) do
    grace = Map.get(event, "cleanup_grace_ms")

    positive_uint64?(grace) and
      case outcome do
        outcome when outcome in [:completed, :cancelled] ->
          true

        :failed ->
          reason = Map.get(event, "reason")
          failure = Map.get(event, "failure")

          (reason in ["model_call_failed", "unreadable_model_answer"] and is_nil(failure)) or
            (is_nil(reason) and valid_failure?(failure))

        :bound_reached ->
          Map.get(event, "bound") in ~w(max_turns token_budget deadline) and
            nonnegative_integer?(Map.get(event, "observed"), @observed_max) and
            nonnegative_integer?(Map.get(event, "declared_limit"), @uint64_max) and
            Map.get(event, "accounting_source") in ["reported", "estimated", nil]

        :outcome_unknown ->
          bounded_reference?(Map.get(event, "reconciliation_ref"))
      end
  end

  defp valid_failure?(%{"category" => "deadline_preflight_failed"} = failure) do
    Map.get(failure, "retryable") == false and
      is_nil(Map.get(failure, "dimension")) and
      is_nil(Map.get(failure, "observed")) and
      is_nil(Map.get(failure, "limit"))
  end

  defp valid_failure?(%{"category" => "context_budget_exceeded"} = failure) do
    Map.get(failure, "retryable") == false and
      Map.get(failure, "dimension") in ~w(system_class_tokens context_tokens context_record_bytes context_record_depth context_record_cardinality) and
      nonnegative_integer?(Map.get(failure, "observed"), @observed_max) and
      positive_uint64?(Map.get(failure, "limit"))
  end

  defp valid_failure?(_), do: false

  defp positive_uint64?(value),
    do: is_integer(value) and value > 0 and value <= @uint64_max

  defp nonnegative_integer?(value, limit),
    do: is_integer(value) and value >= 0 and value <= limit

  defp bounded_reference?(value),
    do: is_binary(value) and byte_size(value) in 1..1_024 and String.valid?(value)

  defp bounded_text(content) when byte_size(content) <= @text_max, do: {content, false}

  defp bounded_text(content) do
    content
    |> binary_part(0, @text_max)
    |> valid_prefix()
    |> then(&{&1, true})
  end

  defp valid_prefix(prefix) do
    if String.valid?(prefix),
      do: prefix,
      else: prefix |> binary_part(0, byte_size(prefix) - 1) |> valid_prefix()
  end

  defp bounded_id?(id),
    do: is_binary(id) and byte_size(id) in 1..256 and String.valid?(id)

  defp bounded_tool_id?(id),
    do: is_binary(id) and byte_size(id) in 1..128 and String.valid?(id)

  defp timeout(state),
    do: {:observation, {:error, {:timeout, snapshot(state)}}}

  defp unavailable(state),
    do: {:observation, {:error, {:session_unavailable, snapshot(state)}}}

  defp snapshot(state) do
    Map.put(state.observation, :waited_ms, saturate(max(0, state.clock.() - state.started_at)))
  end

  defp saturate(value), do: min(@uint64_max, max(0, value))

  defp reap(state, :already_down) do
    retire_monitor(state)
    :ok
  end

  defp reap(state, mode) do
    if mode == :finish,
      do: send(state.reader, {self(), state.reference, :finish}),
      else: Process.exit(state.reader, :kill)

    result = await_down(state, mode, @reap_ms)

    if result == :unconfirmed do
      Process.exit(state.reader, :kill)
      result = await_down(state, :kill, 0)
      retire_monitor(state)
      result
    else
      retire_monitor(state)
      result
    end
  end

  defp await_down(state, mode, timeout) do
    reader = state.reader
    monitor = state.monitor

    receive do
      {:DOWN, ^monitor, :process, ^reader, reason} ->
        if mode == :finish and reason != :normal, do: :abnormal, else: :ok
    after
      timeout -> :unconfirmed
    end
  end

  defp retire_monitor(state) do
    Process.unlink(state.reader)
    Process.demonitor(state.monitor, [:flush])

    receive do
      {:EXIT, reader, _reason} when reader == state.reader -> :ok
    after
      0 -> :ok
    end
  end
end
