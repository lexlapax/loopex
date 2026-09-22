defmodule LoopexDaemon.SocketConnection do
  @moduledoc """
  ## Concept

  One accepted daemon client becomes live only after the registry has recorded
  socket ownership. Until then the process is inert and exists only so the
  listener can transfer one exact socket without an ownership gap.

  ## Technical depth

  `init/1` performs no IO or external call. It installs monitors on the exact
  registry and listener and waits. After the listener has transferred the
  socket and the registry has recorded that result, activation asks the
  registry to promote the provisional slot. Only a successful acknowledgement
  drops the listener monitor and reports `promotion_complete`. Registry loss,
  pre-promotion listener loss, abort, or deadline refusal closes the socket.
  The socket and monitor handles are redacted from formatted process status.
  """

  use GenServer
  require Logger

  alias LoopexDaemon.ConnectionRegistry

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options), do: GenServer.start_link(__MODULE__, options)

  @doc false
  @spec activate(pid(), :socket.socket()) :: :ok
  def activate(connection, socket), do: GenServer.cast(connection, {:activate, socket})

  @doc false
  @spec initialized(pid()) :: :ok
  def initialized(connection), do: GenServer.cast(connection, :initialized)

  @impl true
  def init(options) do
    state = %{
      registry: Keyword.fetch!(options, :registry),
      registry_monitor: nil,
      listener: Keyword.fetch!(options, :listener),
      listener_monitor: nil,
      rollback_token: Keyword.fetch!(options, :rollback_token),
      incarnation: Keyword.fetch!(options, :connection_incarnation),
      initialize_deadline: Keyword.fetch!(options, :initialize_deadline),
      phase: :waiting,
      socket: nil
    }

    Logger.debug("loopex daemon socket connection waiting")

    {:ok,
     %{
       state
       | registry_monitor: Process.monitor(state.registry),
         listener_monitor: Process.monitor(state.listener)
     }}
  end

  @impl true
  def handle_cast({:activate, socket}, %{phase: :waiting} = state) do
    if socket_owner?(socket, self()) do
      case ConnectionRegistry.promote(
             state.registry,
             state.rollback_token,
             state.incarnation
           ) do
        :ok ->
          Process.demonitor(state.listener_monitor, [:flush])

          send(
            state.listener,
            {:promotion_complete, state.rollback_token, state.incarnation, self()}
          )

          Logger.debug("loopex daemon socket connection promoted")

          {:noreply, %{state | phase: :live, socket: socket, listener_monitor: nil}}

        {:error, _reason} ->
          {:stop, :normal, %{state | socket: socket}}
      end
    else
      {:stop, :socket_owner_unverified, state}
    end
  end

  def handle_cast({:activate, socket}, state) do
    if socket_owner?(socket, self()), do: :socket.close(socket)
    {:noreply, state}
  end

  def handle_cast(:initialized, %{phase: :live} = state) do
    case ConnectionRegistry.initialize_complete(
           state.registry,
           state.rollback_token,
           state.incarnation
         ) do
      :ok ->
        Logger.debug("loopex daemon socket connection initialized")
        {:noreply, %{state | phase: :initialized}}

      {:error, _reason} ->
        {:stop, :normal, state}
    end
  end

  def handle_cast(:initialized, state), do: {:noreply, state}

  @impl true
  def handle_info({:connection_abort, token, _reason}, %{rollback_token: token} = state),
    do: {:stop, :normal, state}

  def handle_info(
        {:DOWN, monitor, :process, registry, _reason},
        %{registry: registry, registry_monitor: monitor} = state
      ),
      do: {:stop, :registry_lost, state}

  def handle_info(
        {:DOWN, monitor, :process, listener, _reason},
        %{phase: :waiting, listener: listener, listener_monitor: monitor} = state
      ),
      do: {:stop, :normal, state}

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.socket, do: :socket.close(state.socket)
    Logger.debug("loopex daemon socket connection closed")
    :ok
  end

  @impl GenServer
  def format_status(status) do
    status
    |> Map.put(:state, :redacted_socket_connection_state)
    |> Map.put(:message, :redacted_socket_connection_message)
    |> Map.put(:reason, :redacted_socket_connection_reason)
    |> Map.put(:log, [])
  end

  defp socket_owner?(socket, expected) do
    try do
      case :socket.info(socket) do
        %{owner: ^expected} -> true
        _other -> false
      end
    catch
      :error, _reason -> false
    end
  end
end
