defmodule LoopexProtocol.Session.ConfigureRequest do
  @moduledoc """
  ## Concept

  Decode the current authored configure request shared by both transports.
  Preserve omissions, model aliases and explicit instruction sections; input
  supplies no prepared configuration, capability or authority.

  ## Technical depth

  Accepted ADR 0053 closes each envelope and its nonempty six-member update.
  Quantities become exact native integers through Wire, identities stay opaque
  bytes, and raw instructions retain four bounded UTF-8 sections. This inward
  pure decoder performs no capture, resolution, runtime call or IO. The existing
  duplicate-aware Frame must admit JSON before map conversion; enclosing frame
  limits and subsequent native whole-update/candidate validation still apply.
  """

  alias LoopexProtocol.Wire

  @changes ~w(model reasoning instructions max_tokens context_token_budget system_class_tokens)
  @quantities ~w(max_tokens context_token_budget system_class_tokens)
  @instructions ~w(version base environment appendix)

  @doc """
  ## Concept

  Decode one foreground or daemon configure envelope.

  ## Technical depth

  Both require exactly request_id, method, command_id and changes; daemon also
  requires its opaque writer_epoch. The attachment selects the session later.
  Unknown transport selectors and extra, missing or null fields refuse.
  """
  @spec decode_wire(term(), :foreground | :daemon) :: {:ok, map()} | :error
  def decode_wire(request, transport) when transport in [:foreground, :daemon] do
    required = ~w(request_id method command_id changes)
    keys = if transport == :daemon, do: required ++ ["writer_epoch"], else: required

    with true <- closed?(request, keys),
         "session.configure" <- request["method"],
         true <- request_id?(request["request_id"]),
         {:ok, command_id} <- identity(request["command_id"], 65_536),
         {:ok, changes} <- decode_changes(request["changes"]),
         {:ok, writer} <- writer_identity(request, transport) do
      decoded = %{request_id: request["request_id"], command_id: command_id, changes: changes}
      {:ok, if(transport == :daemon, do: Map.put(decoded, :writer_epoch, writer), else: decoded)}
    else
      _ -> :error
    end
  end

  def decode_wire(_request, _transport), do: :error

  @doc """
  ## Concept

  Preserve one nonempty authored update without applying defaults.

  ## Technical depth

  Only the six mutable binary keys are admitted. The three positive uint64
  quantities require canonical decimal strings. Instructions remain raw and
  digest-free; the adapter captures them before native normalization. Model
  text retains authored UTF-8 bytes without trimming or resolving an alias.
  """
  @spec decode_changes(term()) :: {:ok, map()} | :error
  def decode_changes(changes) when is_map(changes) and not is_struct(changes) do
    if map_size(changes) > 0 and Enum.all?(Map.keys(changes), &(&1 in @changes)) do
      Enum.reduce_while(changes, {:ok, %{}}, fn {key, value}, {:ok, decoded} ->
        case change(key, value) do
          {:ok, native} -> {:cont, {:ok, Map.put(decoded, key, native)}}
          :error -> {:halt, :error}
        end
      end)
    else
      :error
    end
  end

  def decode_changes(_changes), do: :error

  defp change("model", value) do
    if is_binary(value) and byte_size(value) > 0 and String.valid?(value),
      do: {:ok, value},
      else: :error
  end

  defp change("reasoning", value) when value in ~w(default none low medium high),
    do: {:ok, value}

  defp change("instructions", value) do
    if closed?(value, @instructions) and text?(value["version"], 1, 64) and
         Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9._-]{0,63}\z/, value["version"]) and
         text?(value["base"], 1, 32_768) and text?(value["environment"], 0, 4_096) and
         text?(value["appendix"], 0, 16_384),
       do: {:ok, value},
       else: :error
  end

  defp change(key, value) when key in @quantities do
    with {:ok, integer} <- Wire.u64(value),
         true <- integer > 0 do
      {:ok, integer}
    else
      _ -> :error
    end
  end

  defp change(_key, _value), do: :error

  defp writer_identity(request, :daemon), do: identity(request["writer_epoch"], 64)
  defp writer_identity(_request, :foreground), do: {:ok, nil}

  defp identity(value, maximum) do
    with {:ok, bytes} <- Wire.identity(value, maximum),
         true <- Wire.encode_identity(bytes) == value do
      {:ok, bytes}
    else
      _ -> :error
    end
  end

  defp request_id?(value),
    do: text?(value, 1, 64) and Regex.match?(~r/\A[A-Za-z0-9._~-]+\z/, value)

  defp text?(value, minimum, maximum),
    do:
      is_binary(value) and byte_size(value) >= minimum and byte_size(value) <= maximum and
        String.valid?(value)

  defp closed?(value, keys),
    do: is_map(value) and not is_struct(value) and Enum.sort(Map.keys(value)) == Enum.sort(keys)
end
