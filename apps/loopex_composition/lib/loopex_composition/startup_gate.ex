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
  def await(runtime) do
    with {:ok, observer} <- start_owned(runtime), do: await_owned(observer)
  end

  # Concept: tracked host cleanup owns every observer through its returned runtime.
  # Technical depth: the existing runtime worker supervisor owns this temporary
  # read-only task. A delayed cancellation DOWN cannot leave an unreturned child
  # outside the runtime subtree. Monitoring precedes the exact observation grant.
  defp start_owned(runtime) do
    owner = self()
    tag = make_ref()

    with {:ok, %{workers: workers}} <- Loopex.Runtime.children(runtime),
         {:ok, pid} <-
           Task.Supervisor.start_child(
             workers,
             fn ->
               Process.flag(:sensitive, true)

               receive do
                 {^owner, ^tag, :observe} ->
                   send(
                     owner,
                     {tag, observe(runtime, nil, nil, &Loopex.creation_startup_status/2)}
                   )
               end
             end,
             shutdown: :brutal_kill
           ) do
      monitor = Process.monitor(pid)
      send(pid, {owner, tag, :observe})
      {:ok, %{pid: pid, monitor: monitor, tag: tag}}
    else
      _failure -> {:error, :runtime_unavailable}
    end
  catch
    :exit, _reason -> {:error, :runtime_unavailable}
  end

  defp await_owned(observer) do
    result =
      try do
        await_result(observer)
      after
        case cancel(observer) do
          :ok ->
            :ok

          {:pending, identity} ->
            Process.put({__MODULE__, :pending}, [
              identity | Process.get({__MODULE__, :pending}, [])
            ])
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
      when monitor == observer.monitor and pid == observer.pid ->
        :ok
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

  defp await_result(observer) do
    with :ok <- interrupted() do
      receive do
        {tag, result} when tag == observer.tag ->
          with :ok <- interrupted(), :ok <- publication(result), do: result
      after
        10 ->
          if Process.alive?(observer.pid),
            do: await_result(observer),
            else: {:error, :runtime_unavailable}
      end
    end
  end

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
      0 ->
        {:error, :startup_deadline_expired}

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
    do:
      System.convert_time_unit(max(deadline - System.monotonic_time(), 0), :native, :millisecond)

  defp status_read(read, runtime, timeout) do
    read.(runtime, timeout)
  catch
    _kind, _reason -> {:error, :runtime_unavailable}
  end
end
