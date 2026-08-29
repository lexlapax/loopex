defmodule Loopex.Runtime.StreamRelay do
  @moduledoc """
  ## Concept

  The one process that puts a stream domain's items on the progress plane,
  including the closing item that ends it.

  ## Technical depth

  ADR 0011 gives every stream domain one gapless zero-based sequence closed by
  exactly one total, and says the closure is the last item of its domain in
  every case. Two parties would otherwise be emitting into one domain: a
  producer running an adapter's or an executor's callback, and the coordinator
  closing the domain. Nothing either of them does alone makes "last" true,
  because they are different processes and neither orders the other.

  So neither of them emits. A relay does, and it is the only emitter of its
  domain: producers hand it items, the closer asks it to close, and it assigns
  every sequence, emits every item, and emits the closure itself, in the order
  its own mailbox delivers them. There is no reservation separate from an
  emission to be stranded, no seal to be read after the fact, and no wait to be
  bounded.

  Closing ends the relay. A producer that hands an item to a closed domain is
  sending to a process that no longer exists, which is exactly ADR 0011's rule
  that a delta offered by a stale progress function after closure is ignored --
  dropped, uncounted, and unable to appear after the total that closed the
  domain.

  Closing is synchronous, because the caller needs the count, and the wait is
  bounded by construction rather than by a clock. A relay's whole work is a
  message send per item, and the items it processes before a close are exactly
  the ones that had already arrived when the close did -- anything a producer
  hands it afterwards queues behind that close and is never processed. So the
  caller waits for a backlog this runtime already produced, never for an
  adapter's, an executor's, or a consumer's patience, and never on a deadline
  held open over somebody else's code. A relay that died before it could close
  reports that rather than a number, because a count nobody produced is not a
  count.

  A relay also ends with the process that opened it, and it ends by link rather
  than by message. The task supervisor it runs under belongs to the runtime
  rather than to one session, so a coordinator that stops mid-run would otherwise
  leave a relay blocked in `receive` for the life of the runtime. Ending the
  transient plane does not fabricate a disposition: the durable result may have
  committed immediately before the owner died. ADR 0011 therefore tells a
  consumer to read a missing closure as an incomplete transient view, never as
  abandonment.

  A relay never takes its owner down with it. Its own body is wrapped so that
  anything it raises ends it normally rather than propagating into the session.
  """

  @typedoc """
  ## Concept

  A running relay.

  ## Technical depth

  The process identifier is the whole handle: a relay holds its own sequence and
  is addressed by nothing else.
  """
  @type t :: pid()

  @typedoc """
  ## Concept

  How a domain ended, and what its closure states.

  ## Technical depth

  `{:complete, count}` carries the producer's own figure, which ADR 0011 assigns
  to a domain whose attempt produced the durable artifact of its kind.
  `:abandoned` carries the count this relay actually emitted, which is exact
  because it emitted all of it.
  """
  @type disposition :: {:complete, non_neg_integer()} | :abandoned

  @typedoc """
  ## Concept

  How one item and its sequence become what crosses the plane.

  ## Technical depth

  Supplied by the caller, because the label and shape of an item belong to the
  domain kind rather than to the relay.
  """
  @type build :: (term(), non_neg_integer() -> map())

  @typedoc """
  ## Concept

  How a disposition and a total become the closing item.

  ## Technical depth

  Supplied by the caller for the same reason, and called by the relay rather than
  by the caller, which is what makes the closure the last item of its domain.
  """
  @type closing :: (atom(), non_neg_integer() -> map())

  @doc """
  ## Concept

  Opens a domain and returns the relay that owns it.

  ## Technical depth

  Started under the runtime's task supervisor and linked to the caller, so a
  relay outlives neither the transient plane nor the process that opened it.
  `build` renders one item and its sequence into what crosses the plane; `close`
  renders the closing item.
  """
  @spec open(Supervisor.supervisor(), pid() | nil, build(), closing()) ::
          {:ok, t()} | {:error, term()}
  def open(supervisor, sink, build, close)
      when is_function(build, 2) and is_function(close, 2) do
    owner = self()

    Task.Supervisor.start_child(supervisor, fn ->
      Process.link(owner)

      try do
        relay(%{sink: sink, build: build, close: close, count: 0})
      catch
        _kind, _reason -> :ok
      end
    end)
  end

  @doc """
  ## Concept

  Hands one item to its domain.

  ## Technical depth

  Never blocks and never fails: an item offered to a closed domain reaches a
  process that has already exited, and is dropped exactly as ADR 0011 requires.
  A producer therefore needs no answer and has none to misread.
  """
  @spec emit(t(), term()) :: :ok
  def emit(relay, item) when is_pid(relay) do
    send(relay, {:emit, item})
    :ok
  end

  @doc """
  ## Concept

  Closes the domain and returns the total its closure stated.

  ## Technical depth

  The relay emits the closing item itself, as the last thing it does, and then
  ends. Every item it had already been handed crosses first, because it is the
  same mailbox; every item handed to it afterwards reaches nothing.

  Waiting carries no timeout and needs none: the wait is exactly the backlog this
  relay had already been handed when the close arrived -- anything handed to it
  afterwards queues behind the close and is never processed -- and its whole work
  per item is a message send. So the caller waits on a queue this runtime
  produced rather than on the patience of a process it does not own. A relay that
  died is reported as `:unavailable`, because a domain whose relay is gone was
  closed by nothing and has no total to state.
  """
  @spec close(t(), disposition()) :: non_neg_integer() | :unavailable
  def close(relay, disposition) when is_pid(relay) do
    reference = Process.monitor(relay)
    send(relay, {:close, self(), reference, disposition})

    receive do
      {^reference, count} ->
        Process.demonitor(reference, [:flush])
        count

      {:DOWN, ^reference, :process, ^relay, _reason} ->
        :unavailable
    end
  end

  # Concept: one mailbox, in order, and the closure is the last thing out of it.
  defp relay(state) do
    receive do
      {:emit, item} ->
        deliver(state.sink, state.build.(item, state.count))
        relay(%{state | count: state.count + 1})

      {:close, from, reference, disposition} ->
        count = stated_count(disposition, state.count)
        deliver(state.sink, state.close.(name(disposition), count))
        send(from, {reference, count})
        :ok
    end
  end

  # Concept: a complete domain states what its producer produced; an abandoned
  # one states what this relay put on the plane.
  #
  # Technical depth: ADR 0011 fixes both. The producer's figure is its own
  # evidence about the attempt, and the difference between it and what arrived is
  # the signal a consumer reads -- erasing that difference by substituting this
  # relay's count would hide a refusal from every live consumer.
  defp stated_count({:complete, reported}, _emitted), do: reported
  defp stated_count(:abandoned, emitted), do: emitted

  defp name({:complete, _reported}), do: :complete
  defp name(:abandoned), do: :abandoned

  defp deliver(nil, _item), do: :ok

  defp deliver(sink, item) when is_pid(sink) do
    send(sink, {:loopex_progress, item})
    :ok
  end
end
