defmodule LoopexCli.DaemonClient do
  @moduledoc """
  ## Concept

  The reference CLI's connection to a running daemon: one socket, one
  generation-two session, requests answered by their own identity and
  everything else — events, notices and the daemon's own stop record — kept in
  arrival order for whoever is following the session.

  ## Technical depth

  `connect/2` opens the Unix-domain socket, starts one linked reader that
  decodes each complete JSONL frame under the generation-two output ceiling and
  sends it to the caller as `{:loopex_daemon_record, reader, record}`, and
  performs the initialize exchange within `:timeout` milliseconds, 30 000 by
  default; any failure closes the socket. `request/4` sends one frame with a fresh
  request identity and selectively receives only the record correlated to it,
  leaving every other record in the mailbox. Transport loss arrives as
  `{:loopex_daemon_closed, reader}`. A `{:loopex_live_signal, signal}` message
  ends any wait with `:signalled`, so an operator's detach is never held
  behind a reply. No request content is logged.
  """

  require Logger

  alias LoopexProtocol.{Frame, Session.V2, Wire}

  @enforce_keys [:socket, :reader]
  defstruct [:socket, :reader, sequence: 0]

  @type t :: %__MODULE__{socket: :socket.socket(), reader: pid(), sequence: non_neg_integer()}

  @initialize_timeout_ms 30_000

  @doc false
  @spec connect(Path.t(), keyword()) :: {:ok, t()} | {:error, :daemon_unreachable | :signalled}
  def connect(path, options \\ []) when is_binary(path) do
    case :socket.open(:local, :stream, :default) do
      {:ok, socket} ->
        case :socket.connect(socket, %{family: :local, path: path}) do
          :ok ->
            initialize(socket, Keyword.get(options, :timeout, @initialize_timeout_ms))

          {:error, _reason} ->
            _ = :socket.close(socket)
            Logger.debug("loopex live client could not connect")
            {:error, :daemon_unreachable}
        end

      {:error, _reason} ->
        Logger.debug("loopex live client could not open a socket")
        {:error, :daemon_unreachable}
    end
  end

  defp initialize(socket, timeout) do
    owner = self()
    reader = spawn_link(fn -> read(socket, owner, "") end)
    :ok = :socket.setopt(socket, {:otp, :controlling_process}, reader)
    client = %__MODULE__{socket: socket, reader: reader}

    case request(
           client,
           "initialize",
           %{"generations" => [V2.generation()], "capabilities" => []},
           timeout
         ) do
      {:ok, %{"type" => "initialized"}, client} ->
        Logger.debug("loopex live client initialized")
        {:ok, client}

      {:error, :signalled, client} ->
        close(client)
        {:error, :signalled}

      _refused ->
        Logger.debug("loopex live client initialize refused")
        close(client)
        {:error, :daemon_unreachable}
    end
  end

  @doc false
  @spec request(t(), binary(), map(), timeout()) ::
          {:ok, map(), t()} | {:error, :closed | :timeout | :signalled, t()}
  def request(client, method, fields, timeout \\ 30_000) do
    {request_id, client} = next_request_id(client)
    frame = Map.merge(fields, %{"method" => method, "request_id" => request_id})

    with :ok <- send_frame(client, frame) do
      await(client, request_id, timeout)
    else
      _error -> {:error, :closed, client}
    end
  end

  @doc false
  @spec send_request(t(), binary(), map()) :: {:ok, binary(), t()} | {:error, :closed, t()}
  def send_request(client, method, fields) do
    {request_id, client} = next_request_id(client)
    frame = Map.merge(fields, %{"method" => method, "request_id" => request_id})

    case send_frame(client, frame) do
      :ok -> {:ok, request_id, client}
      _error -> {:error, :closed, client}
    end
  end

  @doc false
  @spec await(t(), binary(), timeout()) ::
          {:ok, map(), t()} | {:error, :closed | :timeout | :signalled, t()}
  def await(%__MODULE__{reader: reader} = client, request_id, timeout) do
    receive do
      {:loopex_daemon_record, ^reader, %{"request_id" => ^request_id} = record} ->
        {:ok, record, client}

      {:loopex_daemon_closed, ^reader} ->
        {:error, :closed, client}

      {:loopex_live_signal, _signal} ->
        {:error, :signalled, client}
    after
      timeout -> {:error, :timeout, client}
    end
  end

  @doc false
  @spec close(t()) :: :ok
  def close(%__MODULE__{socket: socket, reader: reader}) do
    Logger.debug("loopex live client closed")
    Process.unlink(reader)
    Process.exit(reader, :kill)
    _ = :socket.close(socket)
    :ok
  end

  @doc """
  ## Concept

  Rebuilds the runtime-shaped event a durable wire event record carries, so a
  daemon session renders exactly as an embedded one does.

  ## Technical depth

  The envelope's identity and sequence return to their atom keys and the event
  data's members are restored beside them unchanged.
  """
  @spec event(map()) :: {:ok, map()} | :error
  def event(%{"type" => "event", "event" => %{"kind" => kind, "data" => data} = event}) do
    with {:ok, event_id} <- Wire.identity(Map.get(event, "event_id")),
         {:ok, sequence} <- Wire.u64(Map.get(event, "event_sequence")) do
      {:ok, Map.merge(data, %{kind: kind, event_id: event_id, event_sequence: sequence})}
    else
      _invalid -> :error
    end
  end

  def event(_record), do: :error

  defp send_frame(%__MODULE__{socket: socket}, frame) do
    with {:ok, encoded} <- Frame.encode(frame) do
      :socket.send(socket, IO.iodata_to_binary(encoded))
    end
  end

  defp next_request_id(%__MODULE__{sequence: sequence} = client),
    do: {"c#{sequence + 1}", %{client | sequence: sequence + 1}}

  defp read(socket, owner, buffered) do
    case :socket.recv(socket, 0) do
      {:ok, bytes} ->
        buffered = deliver(owner, buffered <> bytes)
        read(socket, owner, buffered)

      {:error, _reason} ->
        send(owner, {:loopex_daemon_closed, self()})
    end
  end

  defp deliver(owner, data) do
    case :binary.split(data, "\n") do
      [payload, rest] ->
        case Frame.decode(payload, Frame.output_record_bytes()) do
          {:ok, record} -> send(owner, {:loopex_daemon_record, self(), record})
          {:error, _reason} -> :ok
        end

        deliver(owner, rest)

      [partial] ->
        partial
    end
  end
end
