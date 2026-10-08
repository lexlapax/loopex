defmodule LoopexProtocol.Session.CreationCancellation do
  @moduledoc """
  ## Concept

  Carry a terminal creation cancellation without inventing a session identity
  or interpreting a refused response as authority.

  ## Technical depth

  Accepted ADR 0061 fixes the complete six-member admission record. Request
  identity is 1–64 ASCII bytes; command identity is 1–256 original opaque bytes,
  represented as canonical unpadded base64url. This dormant codec validates
  shape and correlation values only. It performs no request matching, Store
  read, cancellation, activation or transport-generation selection.
  """

  alias LoopexProtocol.Wire

  @doc """
  ## Concept

  Encode the exact cancelled-creation admission.

  ## Technical depth

  Require a plain atom-keyed six-member map with the four fixed string values.
  Command bytes remain opaque. Session and disposition members are forbidden,
  including their null forms. Invalid input returns error without repair.
  """
  @spec encode_wire(term()) :: {:ok, map()} | :error
  def encode_wire(
        %{
          type: "admission",
          request_id: request,
          method: "session.create",
          command_id: command,
          status: "refused",
          reason: "creation_cancelled"
        } = value
      )
      when not is_struct(value) and map_size(value) == 6 and is_binary(command) and
             byte_size(command) in 1..256 do
    if request?(request) do
      {:ok,
       %{
         "type" => "admission",
         "request_id" => request,
         "method" => "session.create",
         "command_id" => Wire.encode_identity(command),
         "status" => "refused",
         "reason" => "creation_cancelled"
       }}
    else
      :error
    end
  end

  def encode_wire(_), do: :error

  @doc """
  ## Concept

  Decode a closed cancellation record into its exact correlation values.

  ## Technical depth

  Identity spelling is bounded before decoding and must reencode identically.
  The enclosing duplicate-aware Frame owns JSON parsing and framing limits.
  Decoding does not establish durable non-commit or grant activation authority.
  """
  @spec decode_wire(term()) :: {:ok, map()} | :error
  def decode_wire(
        %{
          "type" => "admission",
          "request_id" => request,
          "method" => "session.create",
          "command_id" => command,
          "status" => "refused",
          "reason" => "creation_cancelled"
        } = value
      )
      when not is_struct(value) and map_size(value) == 6 and is_binary(command) and
             byte_size(command) in 1..342 do
    with true <- request?(request),
         {:ok, bytes} <- Wire.identity(command, 256),
         true <- Wire.encode_identity(bytes) == command do
      {:ok,
       %{
         type: "admission",
         request_id: request,
         method: "session.create",
         command_id: bytes,
         status: "refused",
         reason: "creation_cancelled"
       }}
    else
      _ -> :error
    end
  end

  def decode_wire(_), do: :error

  defp request?(value) when is_binary(value) and byte_size(value) in 1..64,
    do:
      Enum.all?(
        :binary.bin_to_list(value),
        &(&1 in ?A..?Z or &1 in ?a..?z or
            &1 in ?0..?9 or &1 in ~c"._~-")
      )

  defp request?(_), do: false
end
