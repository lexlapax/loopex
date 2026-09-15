defmodule Loopex.Instrumentation do
  @moduledoc """
  ## Concept

  Where core says what it is doing, in identities and timing only. Every port
  callback and transaction cut in the accepted inventory emits one span here,
  and nothing else does.

  ## Technical depth

  Accepted ADR 0030 fixes the inventory exactly: a callback or cut absent from
  it is not instrumented, and adding one is an amendment to that decision rather
  than a call to this module. Spans carry a start, a stop with a duration, or an
  exception, which is what `:telemetry.span/3` provides; measurements are
  durations, counts and byte totals, and metadata is identities and outcomes.
  Content, arguments, results, credentials and pids never appear.

  Telemetry dispatch runs handlers synchronously in the emitting process, so
  core attaches no handler of its own: whatever a host attaches is the host's
  responsibility, and the edge application Loopex ships attaches one that only
  hands the event to a runtime's bounded diagnostics admission. With no handler
  attached, a span is a pair of `:telemetry.execute/3` calls over an empty
  handler list.
  """

  @doc """
  ## Concept

  Emits one span around the work a port callback or transaction cut performs.

  ## Technical depth

  The result of `work` is returned unchanged, so instrumentation cannot alter a
  decision. The stop event carries the outcome the work reported, derived from
  the result rather than supplied alongside it, so a failure and a success are
  distinguishable without the value itself crossing the boundary. An exception
  propagates after the exception event, exactly as it would without the span.

  A boundary whose results are not `:ok`/`{:error, _}` shaped passes its own
  classifier, because this module must not learn another boundary's vocabulary
  to name what happened there. A classifier returns one bounded atom and reads
  nothing out of the value.
  """
  @spec span([atom()], map(), (-> result), (result -> atom())) :: result when result: term()
  def span(event, metadata, work, classify \\ &__MODULE__.outcome/1)
      when is_list(event) and is_map(metadata) do
    :telemetry.span([:loopex | event], metadata, fn ->
      result = work.()
      {result, Map.put(metadata, :outcome, classify.(result))}
    end)
  end

  @doc """
  ## Concept

  Opens a span whose lifetime is not one function call, and returns what closes
  it.

  ## Technical depth

  A transfer opens, is read many times and closes across three separate calls,
  so there is no single call `span/3` could wrap. The start and stop events are
  the same two `:telemetry` events `span/3` emits, in the same order, with the
  same measurement names -- what changes is only that the caller holds the
  start time between them. The returned token is plain data and carries no more
  than that time.
  """
  @spec open_span([atom()], map()) :: map()
  def open_span(event, metadata) when is_list(event) and is_map(metadata) do
    start = System.monotonic_time()

    :telemetry.execute(
      [:loopex | event] ++ [:start],
      %{monotonic_time: start, system_time: System.system_time()},
      metadata
    )

    %{event: event, started: start}
  end

  @doc """
  ## Concept

  Closes a span opened by `open_span/2`, with the totals it accumulated.

  ## Technical depth

  The duration is measured the way `:telemetry.span/3` measures it, from the
  same monotonic clock, so a reader cannot tell which of the two shapes produced
  the pair. Supplied measurements are counts and byte totals; a supplied
  duration is ignored, because the elapsed time is not the caller's to state.
  """
  @spec close_span(map(), map(), map()) :: :ok
  def close_span(%{event: event, started: started}, measurements, metadata)
      when is_map(measurements) and is_map(metadata) do
    :telemetry.execute(
      [:loopex | event] ++ [:stop],
      Map.put(measurements, :duration, System.monotonic_time() - started),
      metadata
    )
  end

  @doc """
  ## Concept

  The outcome word a span reports for a result.

  ## Technical depth

  A closed set: `ok`, `error`, and `other` for a result shape this boundary does
  not classify. The reason of an error is carried only when it is an atom, which
  is the bounded category form every port here already uses; anything richer
  stays out, because a reason can carry a provider's own words.
  """
  @spec outcome(term()) :: atom()
  def outcome(:ok), do: :ok
  def outcome({:ok, _value}), do: :ok
  def outcome({:ok, _first, _second}), do: :ok
  def outcome({:error, reason}) when is_atom(reason), do: reason
  def outcome({:error, _reason}), do: :error
  def outcome(_result), do: :other
end
