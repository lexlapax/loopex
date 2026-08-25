defmodule LoopexCli.Render do
  @moduledoc """
  ## Concept

  What the operator sees. The answer arrives as it is produced, tool calls and
  their results are shown as they happen, and the run's ending says what actually
  happened rather than that something stopped.

  ## Technical depth

  Two planes reach this module and they are not interchangeable. Durable events
  are the record: the terminal's account of what happened is built from them, and
  they are what a reconnecting reader replays. Progress deltas are transient
  decoration that make the answer appear as it is produced.

  A missing stream closure is therefore not an event. A consumer that never
  receives one is looking at an incomplete transient view and falls back to the
  durable record exactly as it does for a sequence gap. It must never infer
  abandonment from an absence, because that inference needs a timeout, and a
  timeout is a guess about a stream that may simply have been coalesced away.
  """

  @doc """
  ## Concept

  Follows a run to its end and prints what happened.

  ## Technical depth

  Blocks on the durable event stream and drains whatever transient progress has
  arrived alongside it. The durable stream decides when the run is over; progress
  never does, because progress can stop for reasons that have nothing to do with
  the run.
  """
  @spec stream(Loopex.Attachment.t()) :: :ok | {:error, binary()}
  def stream(attachment), do: follow(attachment, 0)

  @doc """
  ## Concept

  Lists an operator's sessions.

  ## Technical depth

  Prints the identifier an operator passes to `resume` and `cancel`, so what they
  read is what they can type back.
  """
  @spec sessions([map()]) :: :ok
  def sessions([]) do
    IO.puts("no sessions in this state root")
    :ok
  end

  def sessions(entries) do
    for entry <- entries do
      IO.puts("#{entry[:session_id] || entry["session_id"]}")
    end

    :ok
  end

  defp follow(attachment, idle) do
    drain_progress()

    case Loopex.next_event(attachment) do
      {:ok, event} ->
        render(event)
        if terminal?(event), do: :ok, else: follow(attachment, 0)

      _absent when idle < 600 ->
        Process.sleep(10)
        follow(attachment, idle + 1)

      # Concept: silence is not an ending.
      #
      # Technical depth: reaching this arm means the durable stream produced no
      # terminal event within the window, which is a report about this terminal's
      # view and never a claim that the run was abandoned. The session and its
      # journal are unaffected and `loopex resume` continues reading from where
      # this stopped.
      _absent ->
        IO.puts(:stderr, "loopex: stopped following this run; it may still be running")
        IO.puts(:stderr, "loopex: `loopex resume` continues reading from the durable record")
        :ok
    end
  end

  # Concept: drain whatever arrived, never wait for it.
  #
  # Technical depth: progress rides the transient plane and may be coalesced,
  # dropped under backpressure, or lost with the plane when its owner changes.
  # Waiting on it would make the terminal's liveness depend on something with no
  # delivery guarantee.
  defp drain_progress do
    receive do
      {:loopex_progress, item} ->
        render_progress(item)
        drain_progress()
    after
      0 -> :ok
    end
  end

  defp render_progress(%{kind: :text_delta, text: text}) when is_binary(text) do
    IO.write(text)
  end

  defp render_progress(%{kind: :tool_progress, chunk: chunk}) when is_binary(chunk) do
    IO.write(:stderr, chunk)
  end

  defp render_progress(_other), do: :ok

  defp render(%{kind: "user.message_appended"} = event) do
    IO.puts("> #{event["content"]}")
  end

  defp render(%{kind: "assistant.message_appended"} = event) do
    IO.puts("\n#{event["content"]}")
  end

  defp render(%{kind: "tool.started"} = event) do
    IO.puts(:stderr, "  · #{event["tool_id"]} (#{event["tool_call_id"]})")
  end

  defp render(%{kind: "tool.finished"} = event) do
    IO.puts(:stderr, "  · #{event["tool_call_id"]}: #{event["outcome"]}")
  end

  # Concept: the ending says what happened, including when nobody knows.
  #
  # Technical depth: `outcome_unknown` carries its reconciliation reference and
  # says plainly that the effect's truth was not established. Printing it as a
  # cancellation would tell an operator something false about work that may still
  # have taken effect.
  defp render(%{kind: "run.finished"} = event) do
    case event["outcome"] do
      "completed" ->
        IO.puts(:stderr, "\nloopex: done")

      "bound_reached" ->
        IO.puts(
          :stderr,
          "\nloopex: stopped at the #{event["bound"]} bound " <>
            "(#{event["observed"]} against #{event["declared_limit"]})"
        )

      "outcome_unknown" ->
        IO.puts(:stderr, "\nloopex: stopped, but the effect's outcome is unknown")
        IO.puts(:stderr, "loopex: reconcile with #{event["reconciliation_ref"]}")

      other ->
        IO.puts(:stderr, "\nloopex: #{other}")
    end
  end

  defp render(%{kind: "steer.resolved"} = event) do
    IO.puts(:stderr, "  · steer #{event["command_id"]}: #{event["disposition"]}")
  end

  defp render(_other), do: :ok

  defp terminal?(%{kind: "run.finished"}), do: true
  defp terminal?(_event), do: false
end
