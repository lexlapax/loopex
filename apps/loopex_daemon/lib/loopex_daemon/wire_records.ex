defmodule LoopexDaemon.WireRecords do
  @moduledoc """
  ## Concept

  The daemon renders generation-two attachment succession with the same stable
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

  The cursor and the snapshot's event sequence are one number reported twice;
  the open interaction is projected at that same cursor by core.
  """
  @spec snapshot(binary(), map(), map() | nil) :: map()
  def snapshot(request_id, snapshot, open_interaction)
      when is_binary(request_id) and is_map(snapshot) do
    cursor = Map.get(snapshot, :event_sequence, 0)
    session_id = Map.fetch!(snapshot, :session_id)

    %{
      "type" => "snapshot",
      "request_id" => request_id,
      "session_id" => Wire.encode_identity(session_id),
      "event_cursor" => Wire.encode_u64(cursor),
      "snapshot" => %{
        "snapshot_revision" => Map.fetch!(snapshot, :snapshot_revision),
        "session_id" => Wire.encode_identity(session_id),
        "event_sequence" => Wire.encode_u64(cursor),
        "active_run_id" => optional_identity(Map.get(snapshot, :active_run_id)),
        "active_run_phase" => optional_word(Map.get(snapshot, :active_run_phase))
      },
      "open_interaction" => open_interaction
    }
  end

  @doc """
  ## Concept

  One transient progress item for an attached client, in the record ADR 0023
  fixes; it may be dropped and is never history.

  ## Technical depth

  The item's stream domain and base sequence are encoded as a wire identity
  and quantity; every other member is carried as the core projected it.
  """
  @spec progress(binary(), map()) :: map()
  def progress(session_id, item) when is_binary(session_id) and is_map(item) do
    %{
      "type" => "progress",
      "session_id" => Wire.encode_identity(session_id),
      "progress" =>
        item
        |> Map.drop([:stream_domain_id, :base_event_sequence])
        |> Map.merge(%{
          "stream_domain_id" => optional_identity(Map.get(item, :stream_domain_id)),
          "base_event_sequence" => optional_sequence(Map.get(item, :base_event_sequence))
        })
    }
  end

  @doc """
  ## Concept

  One durable event, with only the members its kind carries.

  ## Technical depth

  The event's identity and sequence move into the envelope and everything else
  stays in `data` exactly as core published it.
  """
  @spec event(binary(), map()) :: map()
  def event(session_id, event) when is_binary(session_id) and is_map(event) do
    %{
      "type" => "event",
      "session_id" => Wire.encode_identity(session_id),
      "event" => %{
        "kind" => Map.fetch!(event, :kind),
        "event_id" => Wire.encode_identity(Map.fetch!(event, :event_id)),
        "event_sequence" => Wire.encode_u64(Map.fetch!(event, :event_sequence)),
        "data" => Map.drop(event, [:kind, :event_id, :event_sequence])
      }
    }
  end

  defp optional_identity(nil), do: nil
  defp optional_identity(value) when is_binary(value), do: Wire.encode_identity(value)

  defp optional_sequence(nil), do: nil
  defp optional_sequence(value) when is_integer(value), do: Wire.encode_u64(value)

  defp optional_word(nil), do: nil
  defp optional_word(value) when is_atom(value), do: Atom.to_string(value)
  defp optional_word(value) when is_binary(value), do: value

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

  ADR 0023 names the exact members; owner epoch, journal version, handles and
  attachment state never cross.
  """
  @spec session_status(map()) :: map()
  def session_status(status) when is_map(status) do
    %{
      "status" => to_string(Map.get(status, :status)),
      "event_sequence" => Wire.encode_u64(Map.get(status, :event_sequence, 0)),
      "active_run_id" => optional_identity(Map.get(status, :active_run_id)),
      "cleanup_grace_ms" => Wire.encode_u64(Map.get(status, :cleanup_grace_ms, 0)),
      "active_context_token_budget" =>
        optional_u64(Map.get(status, :active_context_token_budget)),
      "pending_work_ids" =>
        status |> Map.get(:pending_work_ids, []) |> Enum.map(&Wire.encode_identity/1),
      "open_interaction" => Map.get(status, :open_interaction)
    }
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

  defp optional_u64(nil), do: nil
  defp optional_u64(value) when is_integer(value), do: Wire.encode_u64(value)

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
