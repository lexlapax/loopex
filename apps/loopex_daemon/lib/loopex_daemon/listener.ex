defmodule LoopexDaemon.Listener do
  @moduledoc """
  ## Concept

  The daemon listener owns the bound Unix socket but accepts no client until
  the successful-readiness arbiter releases its exact startup gate. Each
  accepted socket is charged to the connection registry before peer
  verification or child creation.

  ## Technical depth

  The starting owner transfers the parked socket to this process before it
  receives the parked acknowledgement. A nonblocking OTP socket select keeps
  owner and shutdown signals observable while accept is pending. For each
  accepted socket the listener records the monotonic accept instant, reserves
  a registry slot, verifies the peer uid, asks the registry to create the inert
  child, records the transfer disposition on both sides, and keeps a temporary
  child monitor through `promotion_complete`. Every refusal closes through the
  registry's authenticated rollback acknowledgement. Socket handles, tokens,
  monitors and paths are redacted from process status.
  """

  use GenServer
  require Logger

  alias LoopexDaemon.{ConnectionRegistry, ListenerSocket, PeerCredential, SocketConnection}

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options) do
    owner = Keyword.fetch!(options, :owner)
    socket = Keyword.fetch!(options, :socket)

    if owner == self() do
      case GenServer.start_link(__MODULE__, options) do
        {:ok, listener} ->
          start_result =
            with :ok <- transfer_listener_socket(socket, listener),
                 :ok <- adopt_socket(listener, socket) do
              :ok
            end

          case start_result do
            :ok ->
              {:ok, listener}

            {:error, _reason} = error ->
              stop_started_listener(listener)
              Logger.debug("loopex daemon parked listener start refused")
              error
          end

        {:error, _reason} = error ->
          error
      end
    else
      {:error, :owner_mismatch}
    end
  end

  @doc false
  @spec begin_accept(pid(), reference()) :: :ok
  def begin_accept(listener, startup_ref) do
    send(listener, {:begin_accept, startup_ref})
    :ok
  end

  @doc false
  @spec phase(pid()) :: :awaiting_socket | :parked | :accepting
  def phase(listener), do: GenServer.call(listener, :phase)

  @impl true
  def init(options) do
    Process.flag(:trap_exit, true)
    owner = Keyword.fetch!(options, :owner)
    Process.link(owner)

    state = %{
      owner: owner,
      owner_monitor: Process.monitor(owner),
      registry: Keyword.fetch!(options, :registry),
      daemon_uid: Keyword.fetch!(options, :daemon_uid),
      startup_ref: Keyword.fetch!(options, :startup_ref),
      peer_module: Keyword.get(options, :peer_module, PeerCredential),
      connection_module: Keyword.get(options, :connection_module, SocketConnection),
      socket: nil,
      phase: :awaiting_socket,
      accept_select: nil,
      handoffs: %{}
    }

    Logger.debug("loopex daemon parked listener process start")
    {:ok, state}
  end

  @impl true
  def handle_call({:adopt_socket, socket}, {owner, _tag}, %{owner: owner} = state) do
    if socket_owner?(socket, self()) and state.phase == :awaiting_socket do
      send(owner, {:listener_parked, state.startup_ref, self()})
      Logger.debug("loopex daemon parked listener ready")
      {:reply, :ok, %{state | socket: socket, phase: :parked}}
    else
      {:stop, :socket_owner_unverified, {:error, :socket_owner_unverified}, state}
    end
  end

  def handle_call({:adopt_socket, _socket}, _from, state),
    do: {:reply, {:error, :owner_mismatch}, state}

  def handle_call(:phase, _from, state), do: {:reply, state.phase, state}

  @impl true
  def handle_info(
        {:begin_accept, startup_ref},
        %{phase: :parked, startup_ref: startup_ref} = state
      ) do
    Logger.debug("loopex daemon listener accept gate released")
    send(self(), :accept_next)
    {:noreply, %{state | phase: :accepting}}
  end

  def handle_info({:begin_accept, _startup_ref}, state), do: {:noreply, state}

  def handle_info(:accept_next, %{phase: :accepting, accept_select: nil} = state),
    do: arm_accept(state)

  def handle_info(
        {:"$socket", socket, :select, handle},
        %{
          phase: :accepting,
          socket: socket,
          accept_select: {:select_info, :accept, handle}
        } = state
      ) do
    state = %{state | accept_select: nil}

    case :socket.accept(socket, handle) do
      {:ok, accepted} -> accepted(accepted, state)
      {:select, select_info} -> {:noreply, %{state | accept_select: select_info}}
      {:error, reason} -> accept_failed(reason, state)
    end
  end

  def handle_info(
        {:"$socket", socket, :abort, {handle, reason}},
        %{socket: socket, accept_select: {:select_info, :accept, handle}} = state
      ),
      do: accept_failed(reason, %{state | accept_select: nil})

  def handle_info({:close_accepted, token}, state) do
    case Map.fetch(state.handoffs, token) do
      {:ok, %{disposition: :listener_owned} = handoff} ->
        _ = close_if_owned(handoff.socket)
        :ok = ConnectionRegistry.listener_closed(state.registry, token)
        handoff = %{handoff | listener_closed: true}
        {:noreply, maybe_release_handoff(state, token, handoff)}

      _other ->
        {:noreply, state}
    end
  end

  def handle_info(
        {:promotion_complete, token, incarnation, connection},
        state
      ) do
    case Map.fetch(state.handoffs, token) do
      {:ok,
       %{
         disposition: :connection_owned,
         connection: ^connection,
         connection_incarnation: ^incarnation,
         connection_monitor: monitor
       }} ->
        Process.demonitor(monitor, [:flush])
        {:noreply, %{state | handoffs: Map.delete(state.handoffs, token)}}

      _other ->
        {:noreply, state}
    end
  end

  def handle_info(
        {:DOWN, monitor, :process, owner, reason},
        %{owner: owner, owner_monitor: monitor} = state
      ),
      do: {:stop, reason, state}

  def handle_info({:DOWN, monitor, :process, connection, _reason}, state) do
    case handoff_for_monitor(state.handoffs, monitor, connection) do
      {token, handoff} ->
        handoff = %{handoff | connection_down: true}
        {:noreply, maybe_release_handoff(state, token, handoff)}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info({:EXIT, owner, reason}, %{owner: owner} = state),
    do: {:stop, reason, state}

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.handoffs, fn {_token, handoff} ->
      _ = close_if_owned(handoff.socket)
    end)

    if state.socket, do: ListenerSocket.close(state.socket)
    Logger.debug("loopex daemon parked listener process stop")
    :ok
  end

  @impl GenServer
  def format_status(status) do
    status
    |> Map.put(:state, :redacted_listener_state)
    |> Map.put(:message, :redacted_listener_message)
    |> Map.put(:reason, :redacted_listener_reason)
    |> Map.put(:log, [])
  end

  defp arm_accept(state) do
    case :socket.accept(state.socket, :nowait) do
      {:ok, accepted_socket} -> accepted(accepted_socket, state)
      {:select, select_info} -> {:noreply, %{state | accept_select: select_info}}
      {:error, reason} -> accept_failed(reason, state)
    end
  end

  defp accepted(socket, state) do
    accepted_at = System.monotonic_time(:millisecond)
    listener_incarnation = state.startup_ref

    case ConnectionRegistry.reserve(
           state.registry,
           self(),
           listener_incarnation,
           accepted_at
         ) do
      {:ok, %{rollback_token: token}} ->
        handoff = %{
          socket: socket,
          disposition: :listener_owned,
          connection: nil,
          connection_incarnation: nil,
          connection_monitor: nil,
          listener_closed: false,
          connection_down: false
        }

        state = put_in(state, [:handoffs, token], handoff)
        state = continue_handoff(state, token)
        send(self(), :accept_next)
        {:noreply, state}

      {:error, _reason} ->
        _ = :socket.close(socket)
        Logger.debug("loopex daemon accepted socket refused before reservation")
        send(self(), :accept_next)
        {:noreply, state}
    end
  end

  defp continue_handoff(state, token) do
    handoff = Map.fetch!(state.handoffs, token)

    with :ok <- authorize_peer(state.peer_module, handoff.socket, state.daemon_uid),
         {:ok, connection, incarnation} <-
           ConnectionRegistry.start_connection(state.registry, token),
         monitor = Process.monitor(connection),
         state <-
           update_handoff(state, token, fn row ->
             %{
               row
               | connection: connection,
                 connection_incarnation: incarnation,
                 connection_monitor: monitor
             }
           end),
         :ok <- ConnectionRegistry.begin_transfer(state.registry, token, incarnation) do
      transfer_handoff(state, token, connection, incarnation)
    else
      {:error, :peer_credential_unverified} ->
        :ok =
          ConnectionRegistry.abort_provisional(
            state.registry,
            token,
            :peer_credential_unverified
          )

        state

      {:error, _reason} ->
        _ = ConnectionRegistry.abort_provisional(state.registry, token, :handoff_failed)
        state
    end
  end

  defp transfer_handoff(state, token, connection, incarnation) do
    socket = get_in(state, [:handoffs, token, :socket])
    transfer_result = transfer_socket(socket, connection)

    state =
      if transfer_result == :ok,
        do: update_handoff(state, token, &%{&1 | disposition: :connection_owned}),
        else: state

    case ConnectionRegistry.transfer_result(
           state.registry,
           token,
           incarnation,
           transfer_result
         ) do
      :ok ->
        state.connection_module.activate(connection, socket)
        state

      {:error, _reason} ->
        state
    end
  end

  defp maybe_release_handoff(state, token, handoff) do
    complete =
      case handoff.disposition do
        :listener_owned ->
          handoff.listener_closed and
            (is_nil(handoff.connection) or handoff.connection_down)

        :connection_owned ->
          handoff.connection_down
      end

    if complete do
      if handoff.connection_monitor,
        do: Process.demonitor(handoff.connection_monitor, [:flush])

      %{state | handoffs: Map.delete(state.handoffs, token)}
    else
      put_in(state, [:handoffs, token], handoff)
    end
  end

  defp handoff_for_monitor(handoffs, monitor, connection) do
    Enum.find_value(handoffs, fn {token, handoff} ->
      if handoff.connection_monitor == monitor and handoff.connection == connection,
        do: {token, handoff}
    end)
  end

  defp update_handoff(state, token, function),
    do: update_in(state, [:handoffs, token], function)

  defp authorize_peer(module, socket, daemon_uid) do
    try do
      case module.authorize(socket, daemon_uid) do
        :ok -> :ok
        _other -> {:error, :peer_credential_unverified}
      end
    catch
      _kind, _reason -> {:error, :peer_credential_unverified}
    end
  end

  defp transfer_listener_socket(socket, listener) do
    case :socket.setopt(socket, {:otp, :controlling_process}, listener) do
      :ok -> :ok
      {:error, _reason} -> {:error, :listener_socket_transfer_failed}
    end
  end

  defp adopt_socket(listener, socket) do
    try do
      case GenServer.call(listener, {:adopt_socket, socket}) do
        :ok -> :ok
        {:error, _reason} -> {:error, :listener_socket_adoption_failed}
      end
    catch
      :exit, _reason -> {:error, :listener_socket_adoption_failed}
    end
  end

  defp transfer_socket(socket, connection) do
    case :socket.setopt(socket, {:otp, :controlling_process}, connection) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp close_if_owned(socket) do
    if socket_owner?(socket, self()), do: :socket.close(socket), else: :ok
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

  defp accept_failed(reason, state) do
    Logger.debug("loopex daemon listener accept failed")
    {:stop, {:listener_accept_failed, reason}, state}
  end

  defp stop_started_listener(listener) do
    try do
      GenServer.stop(listener, :normal, 5_000)
    catch
      :exit, _reason -> :ok
    end
  end
end
