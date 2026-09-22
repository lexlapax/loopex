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
  Once promoted, nonblocking socket receives feed the shared strict JSONL frame
  decoder. The generation-two negotiation becomes visible only after the
  registry consumes the final initialize compare-and-set before its unchanged
  accept-time deadline. Partial input is bounded, and fixed protocol refusals
  contain no received bytes. The socket, buffered bytes and monitor handles are
  redacted from formatted process status.
  """

  use GenServer
  require Logger

  alias LoopexDaemon.{ConnectionProtocol, ConnectionRegistry}
  alias LoopexProtocol.{Frame, Session.V2}

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options), do: GenServer.start_link(__MODULE__, options)

  @doc false
  @spec activate(pid(), :socket.socket()) :: :ok
  def activate(connection, socket), do: GenServer.cast(connection, {:activate, socket})

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
      socket: nil,
      protocol: ConnectionProtocol.new(),
      input_buffer: "",
      discarding_oversize: false,
      receive_select: nil
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

          send(self(), :receive_next)

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

  @impl true
  def handle_info({:connection_abort, token, _reason}, %{rollback_token: token} = state),
    do: {:stop, :normal, state}

  def handle_info(:receive_next, %{phase: phase, receive_select: nil} = state)
      when phase in [:live, :initialized],
      do: arm_receive(state)

  def handle_info(
        {:"$socket", socket, :select, handle},
        %{
          phase: phase,
          socket: socket,
          receive_select: {:select_info, :recv, handle}
        } = state
      )
      when phase in [:live, :initialized] do
    state
    |> Map.put(:receive_select, nil)
    |> arm_receive()
  end

  def handle_info(
        {:"$socket", socket, :abort, {handle, _reason}},
        %{socket: socket, receive_select: {:select_info, :recv, handle}} = state
      ),
      do: {:stop, :normal, %{state | receive_select: nil}}

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

  defp arm_receive(state) do
    case :socket.recv(state.socket, 0, :nowait) do
      {:ok, bytes} when is_binary(bytes) and byte_size(bytes) > 0 ->
        case consume_bytes(state, bytes) do
          {:ok, state} ->
            send(self(), :receive_next)
            {:noreply, state}

          {:stop, state} ->
            {:stop, :normal, state}
        end

      {:ok, _empty} ->
        {:stop, :normal, state}

      {:select, select_info} ->
        {:noreply, %{state | receive_select: select_info}}

      {:error, :closed} ->
        {:stop, :normal, state}

      {:error, _reason} ->
        Logger.debug("loopex daemon socket receive failed")
        {:stop, :normal, state}
    end
  end

  defp consume_bytes(%{discarding_oversize: true} = state, bytes) do
    case :binary.match(bytes, "\n") do
      :nomatch ->
        {:ok, state}

      {offset, 1} ->
        rest_offset = offset + 1
        rest = binary_part(bytes, rest_offset, byte_size(bytes) - rest_offset)
        consume_data(%{state | discarding_oversize: false}, rest)
    end
  end

  defp consume_bytes(state, bytes), do: consume_data(state, state.input_buffer <> bytes)

  defp consume_data(state, data) do
    parts = :binary.split(data, "\n", [:global])
    {payloads, [partial]} = Enum.split(parts, -1)
    state = %{state | input_buffer: ""}

    case Enum.reduce_while(payloads, {:ok, state}, fn payload, {:ok, acc} ->
           case handle_payload(acc, payload) do
             {:ok, next} -> {:cont, {:ok, next}}
             {:stop, next} -> {:halt, {:stop, next}}
           end
         end) do
      {:stop, state} ->
        {:stop, state}

      {:ok, state} ->
        retain_partial(state, partial)
    end
  end

  defp retain_partial(state, partial) do
    if byte_size(partial) > frame_ceiling(state.protocol) do
      case send_record(state, invalid_frame(:frame_too_large)) do
        :ok ->
          Logger.debug("loopex daemon protocol frame refused")
          {:ok, %{state | input_buffer: "", discarding_oversize: true}}

        {:error, _reason} ->
          {:stop, state}
      end
    else
      {:ok, %{state | input_buffer: partial}}
    end
  end

  defp handle_payload(state, payload) do
    case Frame.decode(payload, frame_ceiling(state.protocol)) do
      {:ok, request} ->
        handle_request(state, request)

      {:error, reason} ->
        case send_record(state, invalid_frame(reason)) do
          :ok ->
            Logger.debug("loopex daemon protocol frame refused")
            {:ok, state}

          {:error, _send_reason} ->
            {:stop, state}
        end
    end
  end

  defp handle_request(state, request) do
    case ConnectionProtocol.handle(state.protocol, request) do
      {_kind, record, protocol, :none} ->
        case send_record(state, record) do
          :ok -> {:ok, %{state | protocol: protocol}}
          {:error, _reason} -> {:stop, state}
        end

      {:ok, record, protocol, :initialized} ->
        case ConnectionRegistry.initialize_complete(
               state.registry,
               state.rollback_token,
               state.incarnation
             ) do
          :ok ->
            case send_record(state, record) do
              :ok ->
                Logger.debug("loopex daemon socket connection initialized")
                {:ok, %{state | protocol: protocol, phase: :initialized}}

              {:error, _reason} ->
                {:stop, state}
            end

          {:error, _reason} ->
            {:stop, state}
        end
    end
  end

  defp send_record(state, record) do
    with {:ok, encoded} <- Frame.encode(record),
         :ok <- :socket.send(state.socket, encoded, V2.limits()["reply_wait_ms"]) do
      :ok
    else
      _other ->
        Logger.debug("loopex daemon socket send failed")
        {:error, :send_failed}
    end
  end

  defp frame_ceiling(protocol) do
    limits = V2.limits()

    if ConnectionProtocol.initialized?(protocol),
      do: limits["frame_bytes"],
      else: limits["frame_bytes_before_initialization"]
  end

  defp invalid_frame(reason) do
    %{
      "type" => "error",
      "code" => "invalid_frame",
      "message" => frame_reason(reason)
    }
  end

  defp frame_reason(:frame_too_large), do: "the frame exceeds the ceiling in force"
  defp frame_reason(:invalid_utf8), do: "the frame is not valid UTF-8"
  defp frame_reason(:not_an_object), do: "a frame must be one JSON object"
  defp frame_reason(:trailing_bytes), do: "a frame carries bytes after its object"
  defp frame_reason(:truncated), do: "the frame ended early"
  defp frame_reason(:duplicate_member), do: "the frame repeats a member name"
  defp frame_reason(:depth_exceeded), do: "the frame nests beyond the admitted depth"
  defp frame_reason(:too_many_members), do: "a collection in the frame is too large"
  defp frame_reason(:string_too_large), do: "a string in the frame is too large"
  defp frame_reason(:integer_out_of_range), do: "an integer is outside the admitted range"
  defp frame_reason(:number_not_an_integer), do: "a number is not an integer"
  defp frame_reason(_reason), do: "the frame is malformed"
end
