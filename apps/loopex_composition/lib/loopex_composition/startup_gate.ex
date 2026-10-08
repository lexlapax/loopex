defmodule LoopexComposition.StartupGate do
  @moduledoc false

  @interrupt :"$loopex_composition_startup_interrupt"
  @owned :"$loopex_composition_owned"

  @doc false
  def interrupt_key, do: @interrupt

  # Concept: both hosts require the same original startup proof before publication.
  # Technical depth: the linked, monitored observer performs only bounded native
  # reads. Its result carries the exact earlier native cutoff for the owning
  # process to check again before publication. No creation or recovery is issued.
  @doc false
  def start(runtime, deadline \\ nil, read \\ &Loopex.creation_startup_status/2) do
    owner = self()
    tag = make_ref()

    {pid, monitor} =
      :erlang.spawn_opt(
        fn ->
          Process.flag(:sensitive, true)
          send(owner, {tag, observe(runtime, deadline, nil, read)})
        end,
        [:link, :monitor]
      )

    %{pid: pid, monitor: monitor, tag: tag}
  end

  @doc false
  def await(runtime, read \\ &Loopex.creation_startup_status/2) do
    initial = System.monotonic_time() + System.convert_time_unit(1_000, :millisecond, :native)
    with {:ok, observer} <- start_owned(runtime, initial, read), do: await_owned(observer, initial)
  end

  # Concept: tracked host cleanup owns every observer through its returned runtime.
  # Technical depth: the existing runtime worker supervisor owns this temporary
  # read-only task. Resolution, admission and the first public read share one
  # initial failure cap. Async requests leave owner loss and host stop responsive.
  # A late admitted task stays inert beneath Workers and retires without a grant.
  defp start_owned(runtime, initial, read) do
    owner = self()
    tag = make_ref()

    listener = test_listener()
    task = fn -> owned_observer(owner, tag, runtime, initial, listener, read) end
    callers = [owner | Process.get(:"$callers", [])]
    args = [{node(), owner, owner}, callers, {:erlang, :apply, [task, []]}]

    # Concept: admission uses the same temporary task owned by Runtime.Workers.
    # Technical depth: Elixir 1.18.5/OTP27 and 1.20.3/OTP29 Task.Supervisor use
    # this exact private request/Task.Supervised argument shape. The public
    # start_child helper waits infinitely; this source-pinned adapter uses OTP's
    # asynchronous GenServer request API and requires proof on both pairs.
    with {:ok, children} <- request(runtime.supervisor, :which_children, initial),
         {Loopex.Runtime.Workers, workers, _type, _modules} when is_pid(workers) <-
           List.keyfind(children, Loopex.Runtime.Workers, 0),
         {:ok, {:ok, pid}} when is_pid(pid) <-
           request(workers, {:start_task, args, :temporary, :brutal_kill}, initial) do
      monitor = Process.monitor(pid)
      send(pid, {owner, tag, :observe})
      {:ok, %{pid: pid, monitor: monitor, tag: tag}}
    else
      {:error, _reason} = error -> error
      _failure -> {:error, :runtime_unavailable}
    end
  catch
    :exit, _reason -> {:error, :runtime_unavailable}
  end

  defp request(server, message, initial) do
    request = :gen_server.send_request(server, message)
    operation = if message == :which_children, do: :resolve, else: :admit
    notify(test_listener(), {:startup_request, self(), server, operation})

    try do
      await_request(request, initial)
    after
      # Abandon the response alias, not the queued supervisor operation.
      :gen_server.receive_response(request, 0)
    end
  end

  defp await_request(request, initial) do
    with :ok <- interrupted(), remaining when remaining > 0 <- remaining_ms(initial) do
      case :gen_server.wait_response(request, min(10, remaining)) do
        {:reply, response} ->
          with :ok <- interrupted(), true <- fresh?(initial), do: {:ok, response}
        :timeout -> await_request(request, initial)
        {:error, _reason} -> {:error, :runtime_unavailable}
      end
    else
      {:error, _reason} = error -> error
      _expired -> {:error, :runtime_unavailable}
    end
  end

  defp owned_observer(owner, tag, runtime, initial, listener, read) do
    Process.flag(:sensitive, true)
    owner_monitor = Process.monitor(owner)
    notify(listener, {:startup_task, self(), owner, initial})

    if Process.alive?(owner) and fresh?(initial) do
      receive do
        {^owner, ^tag, :observe} ->
          if Process.alive?(owner) and remaining_ms(initial) > 0 do
            notify(listener, {:startup_first_read, self(), runtime})
            first = status_read(read, runtime, timeout(initial))
            if valid_snapshot?(first), do: send(owner, {tag, :snapshot, first})
            result = accept(first, runtime, nil, nil, read)
            send(owner, {tag, result})
          end

        {:DOWN, ^owner_monitor, :process, ^owner, _reason} -> :ok
      after
        remaining_ms(initial) -> :ok
      end
    end
  end

  # Concept: fault schedules identify the actual request and original child.
  # Technical depth: this test-only listener reports admission/read phases and
  # never changes constructors, snapshots, deadlines or cleanup operations.
  if Mix.env() == :test do
    defp test_listener, do: Process.get({__MODULE__, :test_listener})
    defp notify(listener, message) when is_pid(listener), do: send(listener, message)
    defp notify(_listener, _message), do: :ok
  else
    defp test_listener, do: nil
    defp notify(_listener, _message), do: :ok
  end

  defp await_owned(observer, initial) do
    result =
      try do
        await_result(observer, initial, false)
      after
        case cancel(observer) do
          :ok -> :ok
          {:pending, identity} ->
            Process.put({__MODULE__, :pending}, [identity | Process.get({__MODULE__, :pending}, [])])
        end
      end

    if Process.get({__MODULE__, :pending}, []) == [] do
      case result do
        {:ok, deadline} -> Process.put({__MODULE__, :publication_deadline}, deadline)
        _ -> :ok
      end

      result
    else
      {:error, :runtime_unavailable}
    end
  end

  @doc false
  def confirm do
    with :ok <- interrupted(),
         deadline when is_integer(deadline) <- Process.get({__MODULE__, :publication_deadline}) do
      publication({:ok, deadline})
    else
      {:error, _reason} = error -> error
      _missing -> {:error, :runtime_unavailable}
    end
  end

  @doc false
  def pending, do: Process.delete({__MODULE__, :pending}) || []

  @doc false
  def publication({:ok, deadline}) do
    if fresh?(deadline), do: :ok, else: {:error, :startup_deadline_expired}
  end

  def publication({:error, _reason} = error), do: error

  @doc false
  def cancel(observer) do
    Process.unlink(observer.pid)
    if Process.alive?(observer.pid), do: Process.exit(observer.pid, :kill)

    receive do
      {:DOWN, monitor, :process, pid, _reason}
      when monitor == observer.monitor and pid == observer.pid -> :ok
    after
      1_000 -> {:pending, {observer.pid, observer.monitor}}
    end
  end

  @doc false
  def cancel_async(observer) do
    Process.unlink(observer.pid)
    if Process.alive?(observer.pid), do: Process.exit(observer.pid, :kill)
    :ok
  end

  defp await_result(observer, deadline, pinned?) do
    with :ok <- interrupted(), remaining when remaining > 0 <- remaining_ms(deadline) do
      # Concept: an observer's exit cannot discard its already-queued result.
      # Technical depth: a dead observer gets one zero-wait selective receive;
      # its exact DOWN remains for cancellation/retention, and the cutoff still
      # precedes acceptance. A timeout returns here before classifying death.
      wait = if Process.alive?(observer.pid), do: min(10, remaining), else: 0
      receive do
        {tag, :snapshot, {:ok, %{state: :unavailable}}}
        when tag == observer.tag and not pinned? ->
          {:error, :runtime_unavailable}

        {tag, :snapshot, {:ok, %{startup_deadline_ms: cutoff}} = snapshot}
        when tag == observer.tag and not pinned? ->
          if valid_snapshot?(snapshot) and fresh?(deadline) do
            notify(test_listener(), {:startup_snapshot_pinned, self(), observer.pid, snapshot})
            await_result(observer, System.convert_time_unit(cutoff, :millisecond, :native), true)
          else
            {:error, :runtime_unavailable}
          end

        {tag, result} when tag == observer.tag ->
          with :ok <- interrupted(), :ok <- publication(result), do: result
      after
        wait ->
          if wait == 0,
            do: {:error, :runtime_unavailable},
            else: await_result(observer, deadline, pinned?)
      end
    else
      {:error, _reason} = error -> error
      _expired -> {:error, if(pinned?, do: :startup_deadline_expired, else: :runtime_unavailable)}
    end
  end

  defp valid_snapshot?({:ok, %{state: state, startup_id: id, startup_deadline_ms: cutoff} = snapshot})
       when state in [:starting, :ready, :unavailable] and is_binary(id) and
              byte_size(id) == 32 and is_integer(cutoff) and map_size(snapshot) == 3,
       do: true

  defp valid_snapshot?(_snapshot), do: false

  defp interrupted do
    alive? =
      Enum.all?(Process.get(@owned, []), fn
        {Loopex, %{supervisor: pid}} -> Process.alive?(pid)
        {_module, pid} when is_pid(pid) -> Process.alive?(pid)
      end)

    if alive? do
      Process.get(@interrupt, fn -> :ok end).()
    else
      {:error, :runtime_unavailable}
    end
  end

  defp observe(runtime, deadline, pinned, read) do
    case timeout(deadline) do
      0 -> {:error, :startup_deadline_expired}
      timeout -> accept(status_read(read, runtime, timeout), runtime, deadline, pinned, read)
    end
  end

  defp accept(
         {:ok, %{state: state, startup_id: id, startup_deadline_ms: cutoff} = snapshot},
         runtime,
         deadline,
         pinned,
         read
       )
       when state in [:starting, :ready, :unavailable] and is_binary(id) and
              byte_size(id) == 32 and is_integer(cutoff) and map_size(snapshot) == 3 do
    identity = {id, cutoff}

    if pinned != nil and pinned != identity do
      {:error, :runtime_unavailable}
    else
      core_deadline = System.convert_time_unit(cutoff, :millisecond, :native)
      retained = if deadline == nil, do: core_deadline, else: min(deadline, core_deadline)

      cond do
        state == :unavailable -> {:error, :runtime_unavailable}
        not fresh?(retained) -> {:error, :startup_deadline_expired}
        state == :ready -> {:ok, retained}
        true -> pause(runtime, retained, identity, read)
      end
    end
  end

  defp accept(_result, _runtime, _deadline, _pinned, _read),
    do: {:error, :runtime_unavailable}

  defp pause(runtime, deadline, pinned, read) do
    case remaining_ms(deadline) do
      0 -> {:error, :startup_deadline_expired}
      remaining ->
        receive do
        after
          min(10, remaining) -> observe(runtime, deadline, pinned, read)
        end
    end
  end

  defp timeout(nil), do: 1_000
  defp timeout(deadline), do: min(1_000, remaining_ms(deadline))
  defp fresh?(deadline), do: System.monotonic_time() < deadline

  # Concept: a caller's shorter cutoff is never rounded to a later instant.
  # Technical depth: sub-millisecond time cannot fund the API's minimum one-ms
  # read, so it expires conservatively instead of extending the captured bound.
  defp remaining_ms(deadline),
    do: System.convert_time_unit(max(deadline - System.monotonic_time(), 0), :native, :millisecond)

  defp status_read(read, runtime, timeout) do
    read.(runtime, timeout)
  catch
    _kind, _reason -> {:error, :runtime_unavailable}
  end
end
