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

  # Concept: how long the terminal waits in silence before reporting its own view.
  #
  # Technical depth: this is patience, not a timeout on the run. The runtime's own
  # default wall-clock deadline is ten minutes, and it commits a terminal event
  # when that deadline expires, so a terminal that gave up sooner would report
  # "it may still be running" about a run that was still, correctly, running --
  # which is exactly what happened under load, where a single provider turn
  # outlasted a six-second window. Waiting past the deadline the runtime itself
  # enforces means the fallback is reached only when the durable stream really has
  # gone quiet.
  @idle_limit_ms 660_000
  @poll_ms 10

  alias LoopexCli.ProgressConsumer

  alias Loopex.ProgressPayload

  @doc """
  ## Concept

  Follows a run to its end and prints what happened.

  ## Technical depth

  Blocks on the durable event stream and drains whatever transient progress has
  arrived alongside it. The durable stream decides when the run is over; progress
  never does, because progress can stop for reasons that have nothing to do with
  the run.
  """
  @spec stream(Loopex.Attachment.t(), keyword()) :: :ok | {:error, binary()}
  def stream(attachment, options \\ []) do
    follow(
      attachment,
      0,
      Keyword.get(options, :on_run_started, fn _run_id -> :ok end),
      Keyword.get(options, :idle_limit_ms, @idle_limit_ms),
      Keyword.get(options, :next_event, &Loopex.next_event/1),
      ProgressConsumer.new(),
      nil
    )
  end

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
      IO.puts(terminal_text(entry[:session_id] || entry["session_id"]))
    end

    :ok
  end

  defp follow(attachment, waited, on_run_started, limit, next_event, progress, pending) do
    progress = drain_progress(progress)

    case next_event.(attachment) do
      {:ok, event} ->
        # The durable result is committed before its transient closure is sent.
        # An assistant event is therefore held until the next durable event. By
        # then the relay close that precedes later durable work has returned, so
        # a healthy closure has reached this mailbox without this consumer
        # inventing a timeout to decide the stream's disposition.
        progress = drain_progress(progress)
        progress = render_pending(pending, progress)

        {progress, pending} =
          if event.kind == "assistant.message_appended" do
            {progress, event}
          else
            {render_event(event, progress), nil}
          end

        announce(event, on_run_started)

        if terminal?(event) do
          _progress = render_pending(pending, drain_progress(progress))
          :ok
        else
          follow(attachment, 0, on_run_started, limit, next_event, progress, pending)
        end

      _absent when waited < limit ->
        Process.sleep(@poll_ms)

        follow(
          attachment,
          waited + @poll_ms,
          on_run_started,
          limit,
          next_event,
          progress,
          pending
        )

      # Concept: silence is not an ending.
      #
      # Technical depth: reaching this arm means the durable stream produced no
      # terminal event within the window, which is a report about this terminal's
      # view and never a claim that the run was abandoned. The session and its
      # journal are unaffected and `loopex resume` continues reading from where
      # this stopped.
      _absent ->
        _progress = render_pending(pending, drain_progress(progress))
        IO.puts(:stderr, "loopex: stopped following this run; it may still be running")
        IO.puts(:stderr, "loopex: `loopex resume` continues reading from the durable record")
        :ok
    end
  end

  # Concept: the run identifier is public information, read where it is published.
  #
  # Technical depth: an attachment's snapshot is anchored to the event sequence it
  # attached at and never advances, so a caller that needed the active run could
  # not get it from there. `run.started` carries it on the durable plane, which is
  # where a steer's target belongs: the terminal names the run the session
  # actually started rather than one it remembers starting.
  defp announce(%{kind: "run.started"} = event, on_run_started) do
    _ = on_run_started.(event["run_id"])
    :ok
  end

  defp announce(_event, _on_run_started), do: :ok

  # Concept: drain whatever arrived, never wait for it.
  #
  # Technical depth: progress rides the transient plane and may be coalesced,
  # dropped under backpressure, or lost with the plane when its owner changes.
  # Waiting on it would make the terminal's liveness depend on something with no
  # delivery guarantee.
  defp drain_progress(progress) do
    receive do
      {:loopex_progress, item} ->
        {next, actions} = ProgressConsumer.consume(progress, item)
        Enum.each(actions, &render_progress/1)
        drain_progress(next)
    after
      0 -> progress
    end
  end

  defp render_progress({:stdout, text}) do
    IO.write(text)
  end

  defp render_progress({:stderr, chunk}) do
    IO.write(:stderr, chunk)
  end

  # Concept: a complete transient answer is already in the terminal.
  #
  # Technical depth: only the per-domain consumer may suppress this durable
  # projection. It requires a gapless, count-matched complete closure and exact
  # byte reconstruction anchored immediately before this durable event. Every
  # other state renders the record as fallback.
  defp render_event(%{kind: "assistant.message_appended"} = event, progress) do
    case ProgressConsumer.durable_assistant(
           progress,
           Map.get(event, :event_sequence),
           event["content"]
         ) do
      {next, :suppress} ->
        next

      {next, :render} ->
        render(event)
        next
    end
  end

  defp render_event(event, progress) do
    render(event)
    progress
  end

  defp render_pending(nil, progress), do: progress
  defp render_pending(event, progress), do: render_event(event, progress)

  defp render(%{kind: "user.message_appended"} = event) do
    IO.puts("> #{terminal_text(event["content"])}")
  end

  defp render(%{kind: "assistant.message_appended"} = event) do
    IO.puts("\n#{terminal_text(event["content"])}")
  end

  defp render(%{kind: "tool.started"} = event) do
    IO.puts(
      :stderr,
      "  · #{terminal_text(event["tool_id"])} (#{terminal_text(event["tool_call_id"])})"
    )
  end

  # Concept: a tool that spilled says where the rest of its output went.
  #
  # Technical depth: the reference is on the public plane precisely so an
  # operator can retrieve what the model was not shown, and `loopex artifact`
  # takes exactly that locator. A terminal that printed only the outcome left the
  # operator holding a retrieval command with nothing to give it, which makes the
  # spill a loss from where they are standing even though nothing was lost.
  defp render(%{kind: "tool.finished"} = event) do
    IO.puts(
      :stderr,
      "  · #{terminal_text(event["tool_id"] || event["tool_call_id"])}: " <>
        terminal_text(event["outcome"])
    )

    for artifact <- event["artifacts"] || [] do
      locator = terminal_text(artifact["locator"])

      IO.puts(
        :stderr,
        "    output beyond the tool's bound was retained: #{terminal_text(artifact["size"])} bytes, " <>
          "read it with `loopex artifact -- #{shell_quote(locator)}`"
      )
    end
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
          "\nloopex: stopped at the #{terminal_text(event["bound"])} bound " <>
            "(#{terminal_text(event["observed"])} against " <>
            "#{terminal_text(event["declared_limit"])})"
        )

      "outcome_unknown" ->
        IO.puts(:stderr, "\nloopex: stopped, but the effect's outcome is unknown")
        IO.puts(:stderr, "loopex: reconcile with #{terminal_text(event["reconciliation_ref"])}")

      "failed" ->
        IO.puts(:stderr, "\nloopex: failed#{failure_text(event)}")

      other ->
        IO.puts(:stderr, "\nloopex: #{terminal_text(other)}")
    end
  end

  defp render(%{kind: "steer.resolved"} = event) do
    IO.puts(
      :stderr,
      "  · steer #{terminal_text(event["command_id"])}: #{terminal_text(event["disposition"])}"
    )
  end

  defp render(_other), do: :ok

  defp terminal?(%{kind: "run.finished"}), do: true
  defp terminal?(_event), do: false

  # Concept: durable data is displayed as data, never interpreted by the
  # operator's terminal.
  #
  # Technical depth: shipped producers already refuse terminal-control bytes on
  # the transient plane, but durable journals can be supplied by another
  # conforming store or predate that validation. Unsafe or non-binary values are
  # rendered through Elixir's escaped representation. The result contains only
  # printable source notation, so ESC, OSC, BEL, cursor movement, and malformed
  # UTF-8 cannot become terminal instructions during replay.
  defp terminal_text(value) when is_binary(value) do
    if ProgressPayload.terminal_safe?(value),
      do: value,
      else: inspect(value, binaries: :as_strings, printable_limit: :infinity, limit: :infinity)
  end

  defp terminal_text(value), do: inspect(value, printable_limit: :infinity, limit: :infinity)

  # Concept: a context-admission failure says which dimension was exceeded, by
  # how much, and against what -- and says nothing else.
  #
  # Technical depth: ADR 0017 gives this terminal an exact five-member bounded
  # projection. Only those five members are read here. Descriptor bodies, source
  # references, and any other member a producer attached are never rendered,
  # because the whole point of the compact projection is that an operator can
  # act on the refusal without receiving the private context that caused it.
  # Concept: a failed run says what failed, whatever failed.
  #
  # Technical depth: one category was projected and every other dropped, so a
  # provider failure reached the operator as the bare word "failed" -- the one
  # ending where the reason is the only thing that tells them what to do next.
  # The projection stays a fixed whitelist rather than the failure map: category
  # and retryable always, and the measured dimension only where the failure
  # declares one. Failures carry private descriptors and provider text that must
  # never reach a terminal, so naming the admitted fields is what keeps a field
  # added to a later category from becoming rendered output by default.
  defp failure_text(%{"failure" => %{"category" => category} = failure})
       when is_binary(category) do
    " " <>
      terminal_text(category) <>
      " (retryable " <> terminal_text(failure["retryable"]) <> measured_text(failure) <> ")"
  end

  defp failure_text(%{"reason" => reason}) when is_binary(reason),
    do: " " <> terminal_text(reason)

  defp failure_text(_event), do: ""

  defp measured_text(%{"dimension" => dimension} = failure) when is_binary(dimension) do
    "; " <>
      terminal_text(dimension) <>
      " " <>
      terminal_text(failure["observed"]) <> " against " <> terminal_text(failure["limit"])
  end

  defp measured_text(_failure), do: ""

  # Concept: the retrieval instruction remains one literal argument when copied
  # into a POSIX shell.
  #
  # Technical depth: single quotes carry every byte except a single quote; the
  # standard close-quote, quoted-apostrophe, reopen-quote sequence handles that
  # one byte without invoking expansion. The explicit `--` also prevents a
  # leading-hyphen locator from being parsed as a command flag.
  defp shell_quote(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end
end
