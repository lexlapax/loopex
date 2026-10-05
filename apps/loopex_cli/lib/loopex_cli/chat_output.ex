defmodule LoopexCli.ChatOutput do
  @moduledoc """
  ## Concept

  Drain one chat transcript independently of input and runtime cleanup. Bound
  retained output, discard progress before required output, and tell the host
  when delivery fails without claiming that the runtime has stopped.

  ## Technical depth

  Only the creating host may enqueue already rendered bytes. Queued and active
  writes together retain at most 256 KiB. Control frames are at most 65,536
  bytes and have one 5,000-ms deadline measured from enqueue. An owned worker
  performs each blocking IO write; the manager remains responsive. Every worker
  is linked and monitored, and its termination precedes the next write or a
  successful finish. Failure notifies the host once and seals further writes.
  Closed control-record validation belongs to the chat command renderer.
  """

  use GenServer

  @queue_bytes 262_144
  @control_bytes 65_536
  @drain_ms 5_000

  @doc """
  ## Concept

  Start the transcript writer owned by this calling host.

  ## Technical depth

  The device is an existing byte-oriented IO device. Owner loss terminates the
  writer and its linked IO worker. This process opens no file or runtime.
  """
  @spec start_link(IO.device()) :: GenServer.on_start()
  def start_link(device), do: GenServer.start_link(__MODULE__, {self(), device})

  @doc """
  ## Concept

  Enqueue a complete rendered record without waiting for its delivery.

  ## Technical depth

  Kinds are control, text and progress. A successful reply means queue admission
  only. Dropped progress returns `:dropped`; required output is never dropped.
  A sealed writer returns its original failure. The host must stop accepting
  input and perform runtime cleanup on any failure.
  """
  @spec write(pid(), :control | :text | :progress, binary()) ::
          :ok | :dropped | {:error, atom()}
  def write(writer, kind, bytes), do: GenServer.call(writer, {:write, kind, bytes})

  # Concept: provisional answer and summary text share transcript pressure.
  # Technical depth: the owner supplies the existing stdout/stderr device for
  # each entry. One queue, byte charge and IO worker govern both destinations.
  # A private domain tag records actual joined writes, never queue admission.
  @doc false
  def progress(writer, bytes, device, domain \\ nil),
    do: GenServer.call(writer, {:progress, bytes, device, domain})

  # Concept: a durable answer replaces any undelivered provisional fragments.
  # Technical depth: return the exact delivery counts before retiring this
  # domain. Active IO stays charged and delivery-unconfirmed until worker DOWN;
  # queued fragments are discarded before the required answer is admitted.
  @doc false
  def settle_progress(writer, domain), do: GenServer.call(writer, {:settle_progress, domain})

  # Concept: capture a stable drop count before diagnostic shutdown.
  # Technical depth: seal only progress and discard queued provisional entries.
  # Required output and the active IO worker retain their existing lifecycle.
  @doc false
  def seal_progress(writer), do: GenServer.call(writer, :seal_progress)

  @doc """
  ## Concept

  Observe delivery pressure and the progress-drop count without blocking on IO.

  ## Technical depth

  Byte accounting includes the active write. Failure is a fixed code or nil;
  this view exposes neither buffered text nor IO error terms.
  """
  @spec status(pid()) :: map() | {:error, :not_output_owner}
  def status(writer), do: GenServer.call(writer, :status)

  @doc """
  ## Concept

  Seal input to the writer, drain admitted records and join its IO worker.

  ## Technical depth

  Finish has a 5,000-ms ceiling and preserves any earlier control deadline.
  An optional absolute monotonic-millisecond deadline shortens this ceiling
  when host shutdown already has a bound; it cannot extend delivery time.
  Its result describes output delivery only. Runtime and trace cleanup remain
  separate obligations; a failed output channel cannot prove either one.
  """
  @spec finish(pid(), integer()) :: :ok | {:error, atom()}
  def finish(writer, deadline \\ now() + @drain_ms),
    do: GenServer.call(writer, {:finish, deadline}, :infinity)

  @impl true
  def init({owner, device}) do
    Process.flag(:trap_exit, true)

    {:ok,
     %{
       owner: owner,
       owner_monitor: Process.monitor(owner),
       device: device,
       queue: :queue.new(),
       bytes: 0,
       current: nil,
       dropped: 0,
       progress_sealed: false,
       progress_delivery: %{},
       failure: nil,
       finishing: nil,
       finish_deadline: nil,
       timer: nil,
       delivery_deadline: nil
     }}
  end

  @impl true
  def handle_call(_request, {caller, _}, %{owner: owner} = state) when caller != owner,
    do: {:reply, {:error, :not_output_owner}, state}

  def handle_call(:status, _from, state),
    do: {:reply, Map.take(state, [:bytes, :dropped, :failure]), state}

  def handle_call({:settle_progress, domain}, _from, state) when is_binary(domain) do
    state = discard_progress(state, &(&1.domain == domain))
    counts = Map.get(state.progress_delivery, domain, %{admitted: 0, delivered: 0, dropped: 0})
    {:reply, counts, %{state | progress_delivery: Map.delete(state.progress_delivery, domain)}}
  end

  def handle_call(:seal_progress, _from, state) do
    state = discard_progress(state, fn _ -> true end)
    {:reply, state.dropped, %{state | progress_sealed: true, progress_delivery: %{}}}
  end

  def handle_call({:progress, bytes, device, domain}, from, state)
      when is_binary(bytes) and (is_binary(domain) or is_nil(domain)),
      do: enqueue(:progress, bytes, device || state.device, domain, from, state)

  def handle_call({:write, _, _}, _from, %{failure: failure} = state) when failure != nil,
    do: {:reply, {:error, failure}, state}

  def handle_call({:write, _, _}, _from, %{finishing: from} = state) when from != nil,
    do: {:reply, {:error, :output_closed}, state}

  def handle_call({:write, kind, bytes}, _from, state)
      when kind in [:control, :text, :progress] and is_binary(bytes) do
    enqueue(kind, bytes, state.device, nil, nil, state)
  end

  def handle_call({:write, _, _}, _from, state),
    do: {:reply, {:error, :invalid_output}, fail(state, :invalid_output)}

  def handle_call({:finish, deadline}, from, state) when is_integer(deadline) do
    state = %{state | finishing: from, finish_deadline: min(deadline, now() + @drain_ms)}
    continue(arm(state))
  end

  def handle_call({:finish, _}, _from, state),
    do: {:reply, {:error, :invalid_output_deadline}, state}

  defp enqueue(_kind, _bytes, _device, _domain, _from, %{failure: failure} = state)
       when failure != nil,
       do: {:reply, {:error, failure}, state}

  defp enqueue(_kind, _bytes, _device, _domain, _from, %{finishing: from} = state)
       when from != nil,
       do: {:reply, {:error, :output_closed}, state}

  defp enqueue(:progress, _bytes, _device, _domain, _from, %{progress_sealed: true} = state),
    do: {:reply, :dropped, state}

  defp enqueue(kind, bytes, device, domain, _from, state) do
    cond do
      kind == :control and byte_size(bytes) > @control_bytes ->
        {:reply, {:error, :control_record_too_large}, fail(state, :control_record_too_large)}

      bytes == "" ->
        {:reply, :ok, state}

      kind == :progress and state.bytes + byte_size(bytes) > @queue_bytes ->
        state = account_progress(state, domain, :dropped)
        {:reply, :dropped, %{state | dropped: state.dropped + 1}}

      true ->
        state = make_room(state, byte_size(bytes))

        if state.bytes + byte_size(bytes) <= @queue_bytes do
          deadline = if kind == :control, do: now() + @drain_ms
          item = %{kind: kind, bytes: bytes, deadline: deadline, device: device, domain: domain}

          state =
            if kind == :progress, do: account_progress(state, domain, :admitted), else: state

          state = %{
            state
            | queue: :queue.in(item, state.queue),
              bytes: state.bytes + byte_size(bytes)
          }

          {:reply, :ok, state |> dispatch() |> arm()}
        else
          {:reply, {:error, :output_overflow}, fail(state, :output_overflow)}
        end
    end
  end

  @impl true
  def format_status(status) do
    Map.new(status, fn
      {:state, state} -> {:state, Map.take(state, [:bytes, :dropped, :failure])}
      {:message, _} -> {:message, :redacted}
      {:log, _} -> {:log, []}
      other -> other
    end)
  end

  @impl true
  def handle_info({:written, pid, result}, %{current: %{pid: pid} = current} = state),
    do: {:noreply, %{state | current: Map.put(current, :result, result)}}

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner_monitor: ref} = state),
    do: {:stop, :normal, state}

  def handle_info(
        {:DOWN, ref, :process, pid, reason},
        %{current: %{ref: ref, pid: pid} = current} = state
      ) do
    state = %{state | current: nil, bytes: state.bytes - byte_size(current.item.bytes)}

    state =
      if reason == :normal and current.result == :ok,
        do: delivered_progress(state, current.item),
        else: fail(state, :output_failed)

    continue(state |> dispatch() |> arm())
  end

  def handle_info({:output_deadline, token}, %{timer: {_timer, token}} = state),
    do: continue(fail(state, :output_drain_timeout))

  def handle_info({:EXIT, owner, _reason}, %{owner: owner} = state),
    do: {:stop, :normal, state}

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    cancel_timer(state.timer)

    if state.current do
      %{pid: pid, ref: ref} = state.current
      Process.exit(pid, :kill)
      receive do: ({:DOWN, ^ref, :process, ^pid, _} -> :ok)
    end

    :ok
  end

  defp make_room(state, incoming) when state.bytes + incoming <= @queue_bytes, do: state

  defp make_room(state, _incoming) do
    discard_progress(state, fn _ -> true end)
  end

  defp discard_progress(state, selected) do
    {progress, retained} =
      Enum.split_with(:queue.to_list(state.queue), &(&1.kind == :progress and selected.(&1)))

    removed = Enum.reduce(progress, 0, &(byte_size(&1.bytes) + &2))
    state = Enum.reduce(progress, state, &account_progress(&2, &1.domain, :dropped))

    %{
      state
      | queue: :queue.from_list(retained),
        bytes: state.bytes - removed,
        dropped: state.dropped + length(progress)
    }
  end

  defp dispatch(%{current: nil, failure: nil} = state) do
    case :queue.out(state.queue) do
      {:empty, _} ->
        state

      {{:value, item}, rest} ->
        manager = self()
        device = item.device

        {pid, ref} =
          :erlang.spawn_opt(
            fn -> send(manager, {:written, self(), write_device(device, item.bytes)}) end,
            [:link, :monitor]
          )

        %{state | queue: rest, current: %{pid: pid, ref: ref, item: item, result: nil}}
    end
  end

  defp dispatch(state), do: state

  defp write_device(device, bytes) do
    case IO.binwrite(device, bytes) do
      :ok -> :ok
      _ -> :error
    end
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end

  defp fail(%{failure: nil} = state, reason) do
    send(state.owner, {:loopex_chat_output_failed, self(), reason})
    cancel_timer(state.timer)
    if state.current, do: Process.exit(state.current.pid, :kill)
    state = discard_progress(state, fn _ -> true end)
    retained = if state.current, do: byte_size(state.current.item.bytes), else: 0
    %{state | failure: reason, queue: :queue.new(), bytes: retained, timer: nil}
  end

  defp fail(state, _reason), do: state

  defp delivered_progress(state, %{kind: :progress, domain: domain}) when is_binary(domain) do
    if Map.has_key?(state.progress_delivery, domain),
      do: account_progress(state, domain, :delivered),
      else: state
  end

  defp delivered_progress(state, _item), do: state

  defp account_progress(state, nil, _field), do: state

  defp account_progress(state, domain, field) do
    counts = Map.get(state.progress_delivery, domain, %{admitted: 0, delivered: 0, dropped: 0})
    counts = Map.update!(counts, field, &(&1 + 1))
    %{state | progress_delivery: Map.put(state.progress_delivery, domain, counts)}
  end

  defp continue(%{finishing: from, current: nil} = state) when from != nil do
    if :queue.is_empty(state.queue) do
      GenServer.reply(from, if(state.failure, do: {:error, state.failure}, else: :ok))
      {:stop, :normal, state}
    else
      {:noreply, state}
    end
  end

  defp continue(state), do: {:noreply, state}

  defp arm(%{failure: failure} = state) when failure != nil, do: state

  # Concept: the host can shorten shutdown without waiting on blocked IO.
  # Technical depth: notify only this writer's owner when the earliest pending
  # delivery cutoff changes. Clearing delivered controls cannot renew a cutoff
  # the host already captured. A sealed writer keeps its last cutoff.
  defp arm(state) do
    cancel_timer(state.timer)
    current_deadline = if state.current, do: state.current.item.deadline

    deadlines = [
      state.finish_deadline,
      current_deadline | Enum.map(:queue.to_list(state.queue), & &1.deadline)
    ]

    deadline =
      case Enum.reject(deadlines, &is_nil/1) do
        [] -> nil
        pending -> Enum.min(pending)
      end

    if deadline != state.delivery_deadline,
      do: send(state.owner, {:loopex_chat_output_deadline, self(), deadline})

    timer =
      if deadline != nil do
        token = make_ref()
        timer = Process.send_after(self(), {:output_deadline, token}, max(deadline - now(), 0))
        {timer, token}
      end

    %{state | timer: timer, delivery_deadline: deadline}
  end

  defp cancel_timer(nil), do: :ok
  defp cancel_timer({timer, _}), do: Process.cancel_timer(timer)
  defp now, do: System.monotonic_time(:millisecond)
end
