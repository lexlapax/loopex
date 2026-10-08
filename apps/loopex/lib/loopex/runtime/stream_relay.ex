defmodule Loopex.Runtime.StreamRelay do
  @moduledoc """
  ## Concept

  One serial relay projects the credited prefix of one transient domain.
  Pressure seals its raw tail without changing durable work or producer totals.
  Compaction activity has independently droppable observations and no closure.

  ## Technical depth

  The private handle captures one sink, gate, session and exact Control owner.
  Payloads live only in charged arena slots. Control routes metadata after its
  current-owner fence; a coalesced reference-only wake makes the relay scan at
  most 32 slots. Executor validation remains here and observes that prefix only.
  Projection retains the same charge through every local representation. A
  helper frame containing raw/projected copies returns before host-ready custody
  is published. Owner linkage ends the plane without fabricating an outcome.
  """

  alias Loopex.ProgressSink
  alias Loopex.Runtime.Control
  alias Loopex.Runtime.ProgressIngress

  @typedoc false
  @opaque t :: {pid(), ProgressSink.t() | nil, reference(), atom(), pid(), binary(), map(), map()}
  @typedoc false
  @type disposition :: {:complete, non_neg_integer()} | :abandoned
  @typedoc false
  @type build :: (term(), non_neg_integer() -> map())
  @typedoc false
  @type stateful_build :: (term(), non_neg_integer(), term() ->
                             {:emit, map(), term()} | {:drop, term()})
  @typedoc false
  @type closing :: (atom(), non_neg_integer() -> map())

  @doc false
  def open(supervisor, route, build, close)
      when is_function(build, 2) and is_function(close, 2) do
    start(
      supervisor,
      route,
      :model,
      nil,
      fn item, sequence, state ->
        if Loopex.Model.valid_delta?(item),
          do: {:emit, build.(item, sequence), state},
          else: {:drop, state}
      end,
      close
    )
  end

  @doc false
  def open_stateful(supervisor, route, initial, build, close)
      when is_function(build, 3) and is_function(close, 2),
      do: start(supervisor, route, :executor, initial, build, close)

  @doc false
  def open_activity(supervisor, route) do
    start(
      supervisor,
      route,
      :activity,
      nil,
      fn item, _sequence, state ->
        case Loopex.CompactionProgress.project(item) do
          {:ok, projected} -> {:emit, projected, state}
          :error -> {:drop, state}
        end
      end,
      nil
    )
  end

  defp start(supervisor, {sink, session, control, owner, header}, kind, initial, build, close) do
    opener = self()
    gate = ProgressIngress.gate()
    ready = make_ref()

    case Task.Supervisor.start_child(supervisor, fn ->
           try do
             Process.link(opener)
             monitor = Process.monitor(opener)
             handle = {self(), sink, gate, kind, control, session, owner, header}
             send(opener, {ready, handle})

             relay(%{
               handle: handle,
               opener: opener,
               monitor: monitor,
               build: build,
               build_state: initial,
               close: close,
               count: 0
             })
           catch
             _kind, _reason -> :ok
           end
         end) do
      {:ok, pid} ->
        monitor = Process.monitor(pid)

        receive do
          {^ready, handle} ->
            Process.demonitor(monitor, [:flush])
            {:ok, handle}

          {:DOWN, ^monitor, :process, ^pid, reason} ->
            {:error, {:relay_start_failed, reason}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp start(_supervisor, _route, _kind, _initial, _build, _close),
    do: {:error, :invalid_progress_route}

  @doc false
  def pid({pid, _sink, _gate, _kind, _control, _session, _owner, _header}), do: pid
  @doc false
  def sink({_pid, sink, _gate, _kind, _control, _session, _owner, _header}), do: sink
  @doc false
  def seal({_pid, _sink, gate, _kind, _control, _session, _owner, _header}),
    do: ProgressIngress.seal(gate)

  @doc false
  def emit({_, _, _, _, control, session, owner, _header} = relay, item) do
    Control.project_progress(control, session, owner, relay, item)
  end

  @doc false
  def close({pid, _sink, _gate, _kind, control, _session, _owner, _header} = relay, disposition) do
    seal(relay)
    # Concept: closure drains only references that passed the serial owner fence.
    # Technical depth: the flush is metadata-only and cannot await a consumer.
    # Control calls close_fenced directly to avoid a reentrant call to itself.
    if control != self() do
      try do
        GenServer.call(control, {:flush_progress, relay}, :infinity)
      catch
        :exit, _reason -> :ok
      end
    end

    close_fenced(relay, pid, disposition)
  end

  @doc false
  def close_fenced(relay, disposition), do: close_fenced(relay, pid(relay), disposition)

  defp close_fenced(relay, pid, disposition) do
    seal(relay)
    monitor = Process.monitor(pid)
    send(pid, {:close, self(), monitor, disposition})

    receive do
      {^monitor, count} ->
        Process.demonitor(monitor, [:flush])
        count

      {:DOWN, ^monitor, :process, ^pid, _reason} ->
        :unavailable
    end
  end

  @doc false
  def discard(relay) do
    seal(relay)
    pid = pid(relay)
    monitor = Process.monitor(pid)
    Process.unlink(pid)
    Process.exit(pid, :shutdown)

    receive do
      {:DOWN, ^monitor, :process, ^pid, :shutdown} -> :ok
      {:DOWN, ^monitor, :process, ^pid, _reason} -> :unavailable
    end
  end

  defp relay(
         %{handle: {_, sink, gate, _kind, _control, _session, _owner, _header}, monitor: monitor} =
           state
       ) do
    receive do
      {:loopex_progress_stage, ^sink, ^gate} ->
        :atomics.put(gate, 2, 0)
        relay(drain(state))

      {:close, from, reference, disposition} ->
        state = drain(state)
        count = stated_count(disposition, state.count)

        if state.close != nil and Process.alive?(state.opener) do
          # Closure is an independent already-projected finite offer. It may be
          # lost even when the charged prefix projected successfully.
          item = state.close.(name(disposition), count)
          _offered = ProgressSink.try_offer(sink, elem(state.handle, 5), item)
        end

        send(from, {reference, count})
        :ok

      {:DOWN, ^monitor, :process, _opener, _reason} ->
        :ok
    end
  end

  defp drain(state) do
    sink = sink(state.handle)
    references = ProgressSink.references(sink, self(), :relay_ready)

    Enum.reduce_while(references, state, fn reference, current ->
      if Process.alive?(current.opener) do
        # project_one returns no payload. The raw/projected stack frame has
        # returned before ready_stage can transfer to a concurrently taking host.
        {decision, next} = project_one(current, reference)

        case decision do
          :ready ->
            if ProgressSink.ready_stage(sink, reference) do
              {:cont, next}
            else
              :atomics.put(elem(current.handle, 2), 1, 2)
              ProgressSink.retire_stage(sink, reference, :relay_owned)
              {:cont, %{next | count: current.count}}
            end

          :retire ->
            ProgressSink.retire_stage(sink, reference, :relay_owned)
            {:cont, next}

          :stale ->
            {:cont, next}

          # Concept: a still-live earlier reservation is an ordering barrier.
          # Technical depth: finite claim exhaustion leaves custody charged in
          # relay_ready. A later coalesced scan or close may settle that prefix;
          # this turn cannot project a successor and later emit the old item.
          :blocked ->
            {:halt, current}
        end
      else
        {:halt, current}
      end
    end)
  end

  defp project_one(state, reference) do
    sink = sink(state.handle)

    with {:ok, _route} <- ProgressSink.claim_stage(sink, reference, :relay_ready, :relay_owned),
         {:ok, _session, raw} <- ProgressSink.stage_payload(sink, reference) do
      case state.build.(raw, state.count, state.build_state) do
        {:emit, projected, validation} ->
          if ProgressSink.replace_payload(sink, reference, projected) do
            {:ready, %{state | count: state.count + 1, build_state: validation}}
          else
            {:retire, %{state | build_state: validation}}
          end

        {:drop, validation} ->
          {:retire, %{state | build_state: validation}}
      end
    else
      :blocked -> {:blocked, state}
      _ -> {:stale, state}
    end
  end

  defp stated_count({:complete, reported}, _projected), do: reported
  defp stated_count(:abandoned, projected), do: projected
  defp name({:complete, _reported}), do: :complete
  defp name(:abandoned), do: :abandoned
end
