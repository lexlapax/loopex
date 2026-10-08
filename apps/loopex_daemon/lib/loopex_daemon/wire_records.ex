defmodule LoopexDaemon.WireRecords do
  @moduledoc """
  ## Concept

  The daemon renders attachment succession with the same stable
  records it will use while serving a client. Keeping those records in one pure
  boundary prevents the capacity reservation from measuring a shape different
  from the one a connection later emits.

  ## Technical depth

  These constructors accept only already-validated internal values. Identity
  bytes are encoded here exactly once, unsigned cursors use the protocol's
  canonical decimal representation, and the four succession error messages are
  fixed server-authored text. No process, credential, path, exception or
  arbitrary reason reaches a record through this module.
  """

  alias LoopexProtocol.Wire
  alias LoopexProtocol.Session.{Inspection, Snapshot}

  @inspection_fields ~w(status event_sequence active_run_id cleanup_grace_ms active_context_token_budget pending_work_ids open_interaction configuration active_bounds checkpoint active_maintenance)a

  @ordinary_progress_fields %{
    text_delta: [
      :kind,
      :turn_id,
      :stream_domain_id,
      :model_sequence,
      :base_event_sequence,
      :content_index,
      :text
    ],
    reasoning_delta: [
      :kind,
      :turn_id,
      :stream_domain_id,
      :model_sequence,
      :base_event_sequence,
      :content_index,
      :text
    ],
    tool_call_delta: [
      :kind,
      :turn_id,
      :stream_domain_id,
      :model_sequence,
      :base_event_sequence,
      :call_index,
      :tool_call_id,
      :name,
      :arguments_fragment
    ],
    tool_progress: [
      :kind,
      :turn_id,
      :stream_domain_id,
      :tool_call_id,
      :progress_sequence,
      :base_event_sequence,
      :stream,
      :byte_offset,
      :chunk
    ],
    model_stream_closed: [
      :kind,
      :turn_id,
      :stream_domain_id,
      :base_event_sequence,
      :disposition,
      :delta_count
    ],
    tool_stream_closed: [
      :kind,
      :turn_id,
      :stream_domain_id,
      :tool_call_id,
      :base_event_sequence,
      :disposition,
      :progress_count
    ]
  }

  @succession_messages %{
    "admission_unknown" => "Admission outcome unknown; retry with the same command ID.",
    "attachment_conflict" => "another attachment holds this session",
    "control_not_held" => "control is not held by this connection",
    "session_unavailable" => "session unavailable."
  }

  @control_messages %{
    "control_held" => "control held.",
    "control_not_held" => "control is not held by this connection",
    "control_pending" => "control pending."
  }

  @request_messages Map.merge(@control_messages, %{
                      "activation_ceiling_reached" => "activation ceiling reached.",
                      "attachment_conflict" => "another attachment holds this session",
                      "capacity_exceeded" => "too many requests are in flight on this connection",
                      "composition_mismatch" =>
                        "session cannot be activated by this daemon composition",
                      "control_capacity_reached" => "control capacity reached.",
                      "control_owner_lost" => "the session's control owner was lost",
                      "daemon_stopping" => "the daemon is stopping",
                      "internal_failure" => "the daemon could not complete this request",
                      "recovery_required" => "this session cannot be resumed without recovery",
                      "session_dormant" => "session is dormant in this daemon lifetime",
                      "session_unavailable" => "session unavailable.",
                      "session_unknown" => "session unknown.",
                      "store_unavailable" => "store unavailable.",
                      "unsupported_method" => "this build does not yet answer that method"
                    })

  @refusals %{
    "duplicate_request" => "this request identity is already in flight on this connection",
    "session_conflict" => "this connection serves another session"
  }

  @doc false
  @spec detached(binary(), non_neg_integer()) :: map()
  def detached(session_id, event_cursor)
      when is_binary(session_id) and is_integer(event_cursor) and event_cursor >= 0 do
    %{
      "type" => "error",
      "code" => "detached",
      "message" => "session attachment invalidated; reattach to continue",
      "session_id" => Wire.encode_identity(session_id),
      "event_cursor" => Wire.encode_u64(event_cursor)
    }
  end

  @doc false
  @spec admission(
          binary(),
          binary(),
          binary(),
          :accepted | {:refused, binary()},
          binary() | nil
        ) :: map()
  def admission(request_id, method, command_id, disposition, session_id \\ nil)
      when is_binary(request_id) and is_binary(method) and is_binary(command_id) and
             (is_binary(session_id) or is_nil(session_id)) do
    {status, reason} =
      case disposition do
        :accepted -> {"accepted", nil}
        {:refused, reason} when is_binary(reason) and reason != "" -> {"refused", reason}
      end

    record = %{
      "type" => "admission",
      "request_id" => request_id,
      "method" => method,
      "command_id" => Wire.encode_identity(command_id),
      "status" => status,
      "reason" => reason
    }

    if session_id,
      do: Map.put(record, "session_id", Wire.encode_identity(session_id)),
      else: record
  end

  @doc false
  @spec succession_error(binary(), binary()) :: map()
  def succession_error(request_id, code)
      when is_binary(request_id) and is_map_key(@succession_messages, code) do
    %{
      "type" => "error",
      "request_id" => request_id,
      "code" => code,
      "message" => Map.fetch!(@succession_messages, code)
    }
  end

  @doc false
  @spec control_acquired(binary(), binary(), non_neg_integer(), boolean()) :: map()
  def control_acquired(request_id, writer_epoch, expires_in_ms, renewed)
      when is_binary(request_id) and is_binary(writer_epoch) and byte_size(writer_epoch) >= 1 and
             byte_size(writer_epoch) <= 64 and is_integer(expires_in_ms) and expires_in_ms >= 0 and
             is_boolean(renewed) do
    result = %{
      "writer_epoch" => Wire.encode_identity(writer_epoch),
      "expires_in_ms" => Wire.encode_u64(expires_in_ms)
    }

    result = if renewed, do: Map.put(result, "renewed", true), else: result

    %{
      "type" => "result",
      "request_id" => request_id,
      "method" => "session.acquire_control",
      "result" => result
    }
  end

  @doc false
  @spec control_released(binary()) :: map()
  def control_released(request_id) when is_binary(request_id) do
    %{
      "type" => "result",
      "request_id" => request_id,
      "method" => "session.release_control",
      "result" => %{"released" => true}
    }
  end

  @doc false
  @spec control_error(binary(), binary()) :: map()
  def control_error(request_id, code)
      when is_binary(request_id) and is_map_key(@control_messages, code) do
    request_error(request_id, code)
  end

  @doc false
  @spec request_error(binary(), binary()) :: map()
  def request_error(request_id, code)
      when is_binary(request_id) and is_map_key(@request_messages, code) do
    %{
      "type" => "error",
      "request_id" => request_id,
      "code" => code,
      "message" => Map.fetch!(@request_messages, code)
    }
  end

  @doc false
  @spec invalid_request(binary(), binary()) :: map()
  def invalid_request(request_id, refusal)
      when is_binary(request_id) and is_map_key(@refusals, refusal) do
    %{
      "type" => "error",
      "request_id" => request_id,
      "code" => "invalid_request",
      "message" => Map.fetch!(@refusals, refusal)
    }
  end

  @doc """
  ## Concept

  The one uncorrelated record a granted holder receives when its session's
  control owner is lost, immediately before the daemon closes it.

  ## Technical depth

  It carries `session_id` instead of `request_id`, so a client can never
  confuse it with a correlated refusal. `event_cursor` is present exactly
  when the connection held an attachment whose emitted cursor it can name.
  """
  @spec owner_lost_close(binary(), non_neg_integer() | nil) :: map()
  def owner_lost_close(session_id, event_cursor)
      when is_binary(session_id) and
             (is_nil(event_cursor) or (is_integer(event_cursor) and event_cursor >= 0)) do
    record = %{
      "type" => "error",
      "code" => "control_owner_lost",
      "message" => Map.fetch!(@request_messages, "control_owner_lost"),
      "session_id" => Wire.encode_identity(session_id)
    }

    if is_nil(event_cursor),
      do: record,
      else: Map.put(record, "event_cursor", Wire.encode_u64(event_cursor))
  end

  @doc """
  ## Concept

  An attachment's authoritative snapshot at its own cursor, in the same shape
  the foreground server emits for the same session.

  ## Technical depth

  The complete revision-3 snapshot passes through the closed Snapshot codec.
  The cursor and the snapshot's event sequence are one number reported twice;
  the envelope repeats that snapshot's own encoded interaction. Malformed or
  incomplete captures fail before record construction, without defaults.
  """
  @spec snapshot(binary(), map()) :: map()
  def snapshot(request_id, captured_snapshot)
      when is_binary(request_id) and is_map(captured_snapshot) do
    {:ok, snapshot} = Snapshot.encode_wire(captured_snapshot)

    %{
      "type" => "snapshot",
      "request_id" => request_id,
      "session_id" => snapshot["session_id"],
      "event_cursor" => snapshot["event_sequence"],
      "snapshot" => snapshot,
      "open_interaction" => snapshot["open_interaction"]
    }
  end

  @doc """
  ## Concept

  One transient progress item for an attached client, in the record ADR 0023
  fixes; it may be dropped and is never history.

  ## Technical depth

  Compaction activity uses its closed codec and refuses malformed items with
  `:error`, allowing the connection's existing transient drop path. Other
  progress uses ADR 0011's closed shapes and ADR 0023's identity and quantity
  encodings, with whole-item refusal for malformed values. Frame and queue
  ceilings remain enforced by the connection.
  """
  @spec progress(binary(), map()) :: map() | :error
  def progress(session_id, %{kind: "context.compaction_progress"} = item)
      when is_binary(session_id),
      do: compaction_progress(session_id, item)

  def progress(session_id, %{"kind" => "context.compaction_progress"} = item)
      when is_binary(session_id),
      do: compaction_progress(session_id, item)

  def progress(session_id, item), do: ordinary_progress_record(session_id, item)

  @doc """
  ## Concept

  One durable event, with only the members its kind carries.

  ## Technical depth

  The event's identity and sequence move into the envelope. Maintenance views,
  compact completions and checkpoint owners use their closed codecs; other data
  keeps its native members.
  """
  @spec event(binary(), map()) :: map()
  def event(session_id, event) when is_binary(session_id) and is_map(event) do
    data = Map.drop(event, [:kind, :event_id, :event_sequence])

    data =
      case event.kind do
        "context.compacted" ->
          {:ok, owner} =
            LoopexProtocol.Session.CheckpointOwner.encode_wire(Map.fetch!(data, "owner"))

          Map.put(data, "owner", owner)

        "context.maintenance_changed" ->
          {:ok, view} = LoopexProtocol.Session.MaintenanceView.encode_wire(data)
          view

        "context.compaction_finished" ->
          {:ok, completion} = LoopexProtocol.Session.CompactResult.encode_completion(data)
          completion

        _ ->
          data
      end

    %{
      "type" => "event",
      "session_id" => Wire.encode_identity(session_id),
      "event" => %{
        "kind" => Map.fetch!(event, :kind),
        "event_id" => Wire.encode_identity(Map.fetch!(event, :event_id)),
        "event_sequence" => Wire.encode_u64(Map.fetch!(event, :event_sequence)),
        "data" => data
      }
    }
  end

  defp compaction_progress(session_id, item) do
    case LoopexProtocol.Session.CompactionProgress.encode_wire(item) do
      {:ok, progress} ->
        %{
          "type" => "progress",
          "session_id" => Wire.encode_identity(session_id),
          "progress" => progress
        }

      :error ->
        :error
    end
  end

  # Concept: ordinary progress carries exactly its kind's public fields.
  # Technical depth: ADR 0011 supplies native shapes and payload ceilings;
  # ADR 0023 encodes opaque identities, full-range quantities and raw chunks.
  # Refuse the whole item before a private or malformed value reaches a writer.
  defp ordinary_progress_record(session_id, item) do
    with true <- is_binary(session_id) and byte_size(session_id) in 1..256,
         {:ok, progress} <- ordinary_progress(item) do
      %{
        "type" => "progress",
        "session_id" => Wire.encode_identity(session_id),
        "progress" => progress
      }
    else
      _invalid -> :error
    end
  end

  defp ordinary_progress(item) when is_map(item) and not is_struct(item) do
    kind = Map.get(item, :kind)
    fields = Map.get(@ordinary_progress_fields, kind)

    if is_list(fields) and Enum.sort(Map.keys(item)) == Enum.sort(fields) do
      encoded =
        Enum.reduce_while(item, {:ok, %{}}, fn {field, value}, {:ok, progress} ->
          case progress_member(kind, field, value) do
            {:ok, encoded} ->
              key = if field == :chunk, do: "chunk_b64", else: Atom.to_string(field)
              {:cont, {:ok, Map.put(progress, key, encoded)}}

            :error ->
              {:halt, :error}
          end
        end)

      if match?({:ok, _progress}, encoded) and model_payload_bounded?(item),
        do: encoded,
        else: :error
    else
      :error
    end
  end

  defp ordinary_progress(_item), do: :error

  defp progress_member(kind, :kind, kind), do: {:ok, Atom.to_string(kind)}

  defp progress_member(:tool_call_delta, :tool_call_id, nil), do: {:ok, nil}

  defp progress_member(_kind, field, value)
       when field in [:turn_id, :tool_call_id] and is_binary(value) and
              byte_size(value) in 1..65_536,
       do: {:ok, Wire.encode_identity(value)}

  defp progress_member(_kind, :stream_domain_id, value)
       when is_binary(value) and byte_size(value) == 32 do
    if Enum.all?(:binary.bin_to_list(value), &(&1 in ?0..?9 or &1 in ?a..?f)),
      do: {:ok, Wire.encode_identity(value)},
      else: :error
  end

  defp progress_member(_kind, field, value)
       when field in [
              :model_sequence,
              :progress_sequence,
              :base_event_sequence,
              :byte_offset,
              :delta_count,
              :progress_count
            ] and
              is_integer(value) and value >= 0 and value <= 18_446_744_073_709_551_615,
       do: {:ok, Wire.encode_u64(value)}

  defp progress_member(_kind, field, value)
       when field in [:content_index, :call_index] and is_integer(value) and
              value >= 0 and value <= 9_007_199_254_740_991,
       do: {:ok, value}

  defp progress_member(:tool_call_delta, field, nil)
       when field in [:name, :arguments_fragment],
       do: {:ok, nil}

  defp progress_member(_kind, field, value)
       when field in [:text, :name, :arguments_fragment] and is_binary(value) and
              byte_size(value) <= 65_536 do
    if Loopex.ProgressPayload.terminal_safe?(value), do: {:ok, value}, else: :error
  end

  defp progress_member(:tool_progress, :stream, value)
       when value in ["stdout", "stderr", "progress"],
       do: {:ok, value}

  defp progress_member(:tool_progress, :chunk, value)
       when is_binary(value) and byte_size(value) <= 65_536 do
    if Loopex.ProgressPayload.terminal_safe?(value),
      do: {:ok, Wire.encode_bytes(value)},
      else: :error
  end

  defp progress_member(kind, :disposition, value)
       when kind in [:model_stream_closed, :tool_stream_closed] and
              value in [:complete, :abandoned],
       do: {:ok, Atom.to_string(value)}

  defp progress_member(_kind, _field, _value), do: :error

  defp model_payload_bounded?(%{kind: kind} = item)
       when kind in [:text_delta, :reasoning_delta, :tool_call_delta] do
    item
    |> Map.take([:content_index, :call_index, :text, :tool_call_id, :name, :arguments_fragment])
    |> Enum.reduce(0, fn {_field, value}, total ->
      total +
        if is_binary(value), do: byte_size(value), else: byte_size(:erlang.term_to_binary(value))
    end)
    |> Kernel.<=(65_536)
  end

  defp model_payload_bounded?(_item), do: true

  @doc false
  @spec result(binary(), binary(), map()) :: map()
  def result(request_id, method, body)
      when is_binary(request_id) and is_binary(method) and is_map(body) do
    %{"type" => "result", "method" => method, "request_id" => request_id, "result" => body}
  end

  @doc """
  ## Concept

  The public session status projection, and only it.

  ## Technical depth

  Select the eleven approved M7 fields from one captured owner observation,
  then validate their exact native shapes through Inspection. Owner epoch,
  journal version, compact_pending, handles and attachment state never cross.
  Missing or malformed public data refuses without defaults.
  """
  @spec session_status(map()) :: map()
  def session_status(status) when is_map(status) do
    {:ok, inspection} = status |> Map.take(@inspection_fields) |> Inspection.encode_wire()
    inspection
  end

  @doc false
  @spec facade_unavailable(binary(), term()) :: map()
  def facade_unavailable(request_id, reason) when is_binary(request_id) do
    message =
      if is_atom(reason) and not is_nil(reason),
        do: Atom.to_string(reason),
        else: "the request could not be answered"

    %{
      "type" => "error",
      "request_id" => request_id,
      "code" => "facade_unavailable",
      "message" => message
    }
  end

  @doc false
  @spec not_attached(binary()) :: map()
  def not_attached(request_id) when is_binary(request_id) do
    %{
      "type" => "error",
      "request_id" => request_id,
      "code" => "not_attached",
      "message" => "this connection holds no attachment"
    }
  end

  @doc """
  ## Concept

  A refused artifact transfer, named by the closed cause core reported.

  ## Technical depth

  A reason outside core's closed atom set collapses to `internal_failure`
  rather than serializing an arbitrary term.
  """
  @spec transfer_refused(binary(), term()) :: map()
  def transfer_refused(request_id, reason) when is_binary(request_id) and is_atom(reason) do
    %{
      "type" => "error",
      "request_id" => request_id,
      "code" => "transfer_refused",
      "reason" => Atom.to_string(reason),
      "message" => "the transfer was refused"
    }
  end

  def transfer_refused(request_id, _reason), do: request_error(request_id, "internal_failure")

  @doc false
  @spec transfer_opened(map()) :: map()
  def transfer_opened(transfer) when is_map(transfer) do
    %{
      "transfer_ref" => Wire.encode_identity(Map.fetch!(transfer, :transfer_ref)),
      "total_size" => Wire.encode_u64(Map.fetch!(transfer, :total_size)),
      "window_start" => Wire.encode_u64(Map.fetch!(transfer, :window_start)),
      "window_end_exclusive" =>
        Wire.encode_u64(
          Map.fetch!(transfer, :window_start) + Map.fetch!(transfer, :window_length)
        ),
      "object_digest" => Map.fetch!(transfer, :object_digest)
    }
  end

  @doc false
  @spec transfer_chunk(:complete | map()) :: map()
  def transfer_chunk(:complete), do: %{"eof" => true}

  def transfer_chunk(chunk) when is_map(chunk) do
    %{
      "offset" => Wire.encode_u64(Map.fetch!(chunk, :offset)),
      "bytes_b64" => Wire.encode_bytes(Map.fetch!(chunk, :bytes)),
      "chunk_digest" => Map.fetch!(chunk, :chunk_digest),
      "eof" => false
    }
  end

  @doc false
  @spec resource_read(map()) :: map()
  def resource_read(%{digest: digest, size: size, content: content}) do
    %{
      "digest" => digest,
      "size" => Wire.encode_u64(size),
      "content_b64" => Wire.encode_bytes(content)
    }
  end

  def resource_read(resource) when is_map(resource), do: resource

  @doc """
  ## Concept

  One `session.list` page: what the daemon index records and what this daemon
  knows about each row.

  ## Technical depth

  `residency` is the one-way activation fact of this daemon lifetime and
  `controlled` is whether a granted lease routes the session; lineage,
  lifecycle state and committed sequence never appear. The continuation and
  `index_full` are present exactly when true.
  """
  @spec session_page(map(), map()) :: map()
  def session_page(page, facts) when is_map(page) and is_map(facts) do
    entries =
      Enum.map(page.entries, fn row ->
        fact = Map.get(facts, row.session_id, %{active: false, controlled: false})

        %{
          "session_id" => Wire.encode_identity(row.session_id),
          "placement_identity" => Wire.encode_identity(row.placement_identity),
          "residency" => if(fact.active, do: "active", else: "dormant"),
          "controlled" => fact.controlled
        }
      end)

    body = %{"entries" => entries}

    body =
      case Map.get(page, :next_after_session_id) do
        nil -> body
        next -> Map.put(body, "next_after_session_id", Wire.encode_identity(next))
      end

    if page.index_full, do: Map.put(body, "index_full", true), else: body
  end

  @doc """
  ## Concept

  The exact `daemon.status` projection: identities, bounded counts and their
  limits, with every reservation in flight counted.

  ## Technical depth

  Counts come from the registry and index owners at one instant each; no
  path beyond the socket the client already reached, no credential and no
  process identity crosses.
  """
  @spec daemon_status(map(), map(), map()) :: map()
  def daemon_status(context, registry, index) do
    started_at = Map.get(context, :started_at) || System.monotonic_time(:millisecond)

    %{
      "placement_identity" => Wire.encode_identity(Map.get(context, :placement_identity) || ""),
      "daemon_incarnation" => Wire.encode_identity(Map.fetch!(context, :daemon_incarnation)),
      "socket_path" => Map.get(context, :socket_path) || "",
      "connections" => registry.occupied,
      "connection_limit" => registry.limit,
      "attachments" => registry.attachments,
      "attachment_limit" => registry.limit,
      "active_sessions" => registry.active_sessions,
      "activation_limit" => registry.activation_limit,
      "activations_used" => registry.activations_used,
      "index_entries" => index.entries,
      "index_limit" => index.limit,
      "index_full" => index.full,
      "uptime_ms" => Wire.encode_u64(max(System.monotonic_time(:millisecond) - started_at, 0))
    }
  end

  @doc """
  ## Concept

  Tells the one client whose command reached a session that the daemon could
  not record it in the listing index; the session remains usable by ID.

  ## Technical depth

  An uncorrelated `daemon.notice` record with the closed code
  `index_write_failed`, the session identity and a fixed message.
  """
  @spec index_write_failed(binary()) :: map()
  def index_write_failed(session_id) when is_binary(session_id) do
    %{
      "type" => "daemon.notice",
      "code" => "index_write_failed",
      "session_id" => Wire.encode_identity(session_id),
      "message" => "the session could not be recorded in the daemon index"
    }
  end

  @doc """
  ## Concept

  The one uncorrelated record every initialized client is sent when the
  daemon ends, naming why.

  ## Technical depth

  `reason` is `operator_stop`, `store_lost`, `store_capacity_exceeded` or
  `fatal:<class>` for a live-registry fatal class; the message is fixed text
  and never carries a path, credential or exception.
  """
  @spec daemon_stopping(binary()) :: map()
  def daemon_stopping(reason) when is_binary(reason) do
    %{
      "type" => "daemon.stopping",
      "reason" => reason,
      "message" => "the daemon is stopping; reconnect after it restarts"
    }
  end
end
