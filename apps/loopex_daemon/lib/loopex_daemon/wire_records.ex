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
                      "activation_ceiling_reached" => "activation ceiling reached."
                    })

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
end
