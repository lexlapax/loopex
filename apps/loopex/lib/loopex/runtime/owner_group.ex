defmodule Loopex.Runtime.OwnerGroup do
  @moduledoc false

  use GenServer

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options) when is_list(options), do: GenServer.start_link(__MODULE__, options)

  @doc false
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(options) do
    %{
      id: {__MODULE__, Keyword.fetch!(options, :generation)},
      start: {__MODULE__, :start_link, [options]},
      restart: :temporary,
      shutdown: :infinity,
      type: :worker
    }
  end

  @doc false
  @spec workers(pid()) :: {:ok, pid()} | {:error, :owner_group_unavailable}
  def workers(group) when is_pid(group) do
    try do
      GenServer.call(group, :workers, :infinity)
    catch
      :exit, _reason -> {:error, :owner_group_unavailable}
    end
  end

  @doc false
  @spec attach(pid(), pid()) :: :ok | {:error, :owner_group_unavailable}
  def attach(group, coordinator) when is_pid(group) and is_pid(coordinator) do
    try do
      GenServer.call(group, {:attach, coordinator}, :infinity)
    catch
      :exit, _reason -> {:error, :owner_group_unavailable}
    end
  end

  @impl GenServer
  def init(_options) do
    # Concept: model and policy work share the lifetime of the session owner
    # incarnation that started them.
    #
    # Technical depth: the private Task.Supervisor is linked to this group, not
    # to Runtime.Workers. Executor and cleanup tasks stay on Runtime.Workers, so
    # ending this group cannot terminate evidence-producing effectful work.
    Process.flag(:trap_exit, true)
    {:ok, workers} = Task.Supervisor.start_link()
    {:ok, %{workers: workers, coordinator: nil, monitor: nil}}
  end

  @impl GenServer
  def handle_call(:workers, _from, state), do: {:reply, {:ok, state.workers}, state}

  def handle_call({:attach, coordinator}, _from, %{coordinator: nil} = state) do
    monitor = Process.monitor(coordinator)
    {:reply, :ok, %{state | coordinator: coordinator, monitor: monitor}}
  end

  def handle_call({:attach, _coordinator}, _from, state),
    do: {:reply, {:error, :owner_group_unavailable}, state}

  @impl GenServer
  def handle_info(
        {:DOWN, monitor, :process, coordinator, _reason},
        %{monitor: monitor, coordinator: coordinator} = state
      ) do
    # Concept: the group is the barrier between a dead owner and its successor.
    #
    # Technical depth: terminate/2 synchronously stops the private supervisor
    # before this process emits DOWN. Control monitors this process rather than
    # the coordinator, so it cannot dispatch the successor while an old model
    # or policy task remains alive.
    {:stop, :normal, state}
  end

  def handle_info({:EXIT, workers, reason}, %{workers: workers} = state),
    do: {:stop, {:owner_workers_stopped, reason}, state}

  def handle_info(_message, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, %{workers: workers, coordinator: coordinator}) do
    if Process.alive?(workers), do: Supervisor.stop(workers, :shutdown, :infinity)

    if is_pid(coordinator) and Process.alive?(coordinator),
      do: Process.exit(coordinator, :shutdown)

    :ok
  end

  @impl GenServer
  def format_status(status) do
    status
    |> Map.put(:state, :redacted_owner_group_state)
    |> Map.put(:message, :redacted_owner_group_message)
    |> Map.put(:reason, :redacted_owner_group_reason)
    |> Map.put(:log, [])
  end
end
