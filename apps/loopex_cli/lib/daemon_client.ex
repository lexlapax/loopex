defmodule LoopexCli.DaemonClient do
  @moduledoc """
  ## Concept

  The reference CLI's connection to a running daemon: one socket, one
  current negotiated session, requests answered by their own identity and
  everything else — events, notices and the daemon's own stop record — kept in
  arrival order for whoever is following the session.

  ## Technical depth

  `connect/2` opens the Unix-domain socket, starts one linked reader that
  decodes each complete JSONL frame under the current output ceiling and
  sends it to the caller as `{:loopex_daemon_record, reader, record}`, and
  performs the initialize exchange within `:timeout` milliseconds, 30 000 by
  default. The reply must select the independently pinned current daemon
  generation and canonical schema digest; a mismatch closes the socket without
  downgrade or replay. `request/4` sends one frame with a fresh
  request identity and selectively receives only the record correlated to it,
  leaving every other record in the mailbox. Transport loss arrives as
  `{:loopex_daemon_closed, reader}`. A `{:loopex_live_signal, signal}` message
  ends any wait with `:signalled`, so an operator's detach is never held
  behind a reply. No request content is logged.
  """

  require Logger

  alias LoopexProtocol.{Frame, Wire}

  @enforce_keys [:socket, :reader]
  defstruct [:socket, :reader, sequence: 0]

  @type t :: %__MODULE__{socket: :socket.socket(), reader: pid(), sequence: non_neg_integer()}

  # Concept: the bundled client verifies the independently pinned daemon contract.
  # Technical depth: ADR 0044 requires exact generation and canonical schema
  # identity before session work; a mismatch uses the original close path.
  @generation "loopex.experimental/4"
  @schema_digest "9306e4aeb2ffb9aab3cf4dac94db5a1e4699f09d3f58cc57e2fa79a7e63ef7b9"
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
           %{"generations" => [@generation], "capabilities" => []},
           timeout
         ) do
      {:ok,
       %{
         "type" => "initialized",
         "selected_generation" => @generation,
         "exact_schema_sha256" => @schema_digest
       }, client} ->
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

  Rebuilds the native event from the daemon's complete current wire record.

  ## Technical depth

  Shared payload codecs restore opaque bytes and exact quantities. Ordinary
  fields restore their native representation before the existing daemon builder
  checks the complete envelope and payload by exact re-encoding. The CLI already
  depends on that builder's application; no alternate schema or fallback is
  introduced. Missing, extra, noncanonical or private members refuse whole.
  """
  @spec event(map()) :: {:ok, map()} | :error
  def event(%{
        "type" => "event",
        "session_id" => session,
        "event" => %{"kind" => kind, "data" => data} = event
      } = record)
      when is_binary(kind) and is_map(data) and not is_struct(data) do
    with {:ok, session} <- Wire.session_identity(session),
         {:ok, event_id} <- Wire.identity(event["event_id"]),
         {:ok, sequence} <- Wire.u64(event["event_sequence"]),
         {:ok, data} <- event_data(kind, data),
         native = Map.merge(data, %{kind: kind, event_id: event_id, event_sequence: sequence}),
         true <- LoopexDaemon.WireRecords.event(session, native) === record do
      {:ok, native}
    else
      _invalid -> :error
    end
  end

  def event(_record), do: :error

  defp event_data("session.configured", data),
    do: LoopexProtocol.Session.Configuration.decode_change(data)

  defp event_data("context.compacted", data),
    do: LoopexProtocol.Session.Checkpoint.decode_wire(data)

  defp event_data("context.maintenance_changed", data),
    do: LoopexProtocol.Session.MaintenanceView.decode_wire(data)

  defp event_data("context.compaction_finished", data),
    do: LoopexProtocol.Session.CompactResult.decode_completion(data)

  defp event_data(kind, data)
       when kind in ~w(interaction.requested interaction.answer_admitted interaction.resolved interaction.expired interaction.cancelled interaction.answered interaction.declined),
       do: LoopexProtocol.Session.InteractionEvent.decode(kind, data)

  defp event_data("run.finished", data) do
    extra =
      case data["outcome"] do
        "bound_reached" -> ~w(bound observed declared_limit accounting_source)
        "failed" -> if Map.has_key?(data, "failure"), do: ["failure"], else: ["reason"]
        _other -> []
      end

    details = Map.take(data, ["cleanup_grace_ms" | extra])

    details =
      case data["outcome"] do
        "failed" -> Map.merge(%{"reason" => nil, "failure" => nil}, details)
        "outcome_unknown" -> Map.put(details, "reconciliation_ref", data["reconciliation_ref"])
        _other -> details
      end

    with {:ok, fields} <- event_fields(data),
         {:ok, outcome} <-
           LoopexProtocol.Session.Outcome.decode_wire(%{
             "outcome" => data["outcome"],
             "details" => details
           }) do
      {:ok, Map.merge(fields, Map.take(outcome.details, Map.keys(data)))}
    else
      _invalid -> :error
    end
  end

  defp event_data(kind, data)
       when kind in ~w(user.message_appended assistant.message_appended run.started session.settled tool.started tool.finished steer.resolved follow_up.resolved),
       do: event_fields(data)

  defp event_data(_kind, _data), do: :error

  defp event_fields(data) do
    Enum.reduce_while(data, {:ok, %{}}, fn {key, value}, {:ok, fields} ->
      case event_field(key, value) do
        {:ok, native_key, native} -> {:cont, {:ok, Map.put(fields, native_key, native)}}
        :error -> {:halt, :error}
      end
    end)
  end

  defp event_field(key, nil) when key in ~w(command_id reconciliation_ref),
    do: {:ok, key, nil}

  defp event_field(key, value)
       when key in ~w(command_id run_id turn_id tool_call_id operation_id reconciliation_ref) do
    case Wire.identity(value) do
      {:ok, native} -> {:ok, key, native}
      :error -> :error
    end
  end

  defp event_field("content_b64", value) do
    case Wire.bytes(value, 98_304) do
      {:ok, native} -> {:ok, "content", native}
      :error -> :error
    end
  end

  defp event_field("artifacts", values) when is_list(values) do
    Enum.reduce_while(values, {:ok, []}, fn
      %{"size" => size} = artifact, {:ok, artifacts} ->
        case Wire.u64(size) do
          {:ok, native} -> {:cont, {:ok, [Map.put(artifact, "size", native) | artifacts]}}
          :error -> {:halt, :error}
        end

      _invalid, _acc ->
        {:halt, :error}
    end)
    |> case do
      {:ok, artifacts} -> {:ok, "artifacts", Enum.reverse(artifacts)}
      :error -> :error
    end
  end

  defp event_field(key, value), do: {:ok, key, value}

  @progress_kinds %{
    "text_delta" => :text_delta,
    "reasoning_delta" => :reasoning_delta,
    "tool_call_delta" => :tool_call_delta,
    "tool_progress" => :tool_progress,
    "model_stream_closed" => :model_stream_closed,
    "tool_stream_closed" => :tool_stream_closed
  }
  @progress_keys %{
    "turn_id" => :turn_id,
    "stream_domain_id" => :stream_domain_id,
    "base_event_sequence" => :base_event_sequence,
    "model_sequence" => :model_sequence,
    "progress_sequence" => :progress_sequence,
    "tool_call_id" => :tool_call_id,
    "content_index" => :content_index,
    "text" => :text,
    "call_index" => :call_index,
    "name" => :name,
    "arguments_fragment" => :arguments_fragment,
    "stream" => :stream,
    "byte_offset" => :byte_offset,
    "chunk_b64" => :chunk,
    "delta_count" => :delta_count,
    "progress_count" => :progress_count,
    "disposition" => :disposition
  }
  @dispositions %{"complete" => :complete, "abandoned" => :abandoned}

  @doc """
  ## Concept

  Restores current transient progress to the renderer's native item.

  ## Technical depth

  Closed tables name ordinary kinds, keys and dispositions without creating
  atoms. Identities, quantities and raw chunks decode before the existing daemon
  builder checks the complete record. Compaction activity uses its shared codec.
  A refused transient item is not shown and cannot authorize durable suppression.
  """
  @spec progress(map()) :: {:ok, map()} | :error
  def progress(%{"type" => "progress", "session_id" => session, "progress" => item} = record)
      when is_map(item) and not is_struct(item) do
    with {:ok, session} <- Wire.session_identity(session),
         {:ok, native} <- progress_item(item),
         true <- LoopexDaemon.WireRecords.progress(session, native) === record do
      {:ok, native}
    else
      _invalid -> :error
    end
  end

  def progress(_record), do: :error

  defp progress_item(%{"kind" => "context.compaction_progress"} = item),
    do: LoopexProtocol.Session.CompactionProgress.decode_wire(item)

  defp progress_item(%{"kind" => kind} = item) do
    with {:ok, native_kind} <- Map.fetch(@progress_kinds, kind) do
      item
      |> Map.delete("kind")
      |> Enum.reduce_while({:ok, %{kind: native_kind}}, fn {key, value}, {:ok, fields} ->
        with {:ok, atom} <- Map.fetch(@progress_keys, key),
             {:ok, native} <- progress_field(atom, value) do
          {:cont, {:ok, Map.put(fields, atom, native)}}
        else
          _invalid -> {:halt, :error}
        end
      end)
    end
  end

  defp progress_item(_item), do: :error

  defp progress_field(:tool_call_id, nil), do: {:ok, nil}

  defp progress_field(key, value) when key in [:turn_id, :tool_call_id, :stream_domain_id],
    do: Wire.identity(value)

  defp progress_field(key, value)
       when key in [
              :base_event_sequence,
              :model_sequence,
              :progress_sequence,
              :byte_offset,
              :delta_count,
              :progress_count
            ],
       do: Wire.u64(value)

  defp progress_field(:chunk, value), do: Wire.bytes(value, 65_536)
  defp progress_field(:disposition, value), do: Map.fetch(@dispositions, value)
  defp progress_field(_key, value), do: {:ok, value}

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
