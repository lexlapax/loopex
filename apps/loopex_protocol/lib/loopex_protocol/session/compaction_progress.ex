defmodule LoopexProtocol.Session.CompactionProgress do
  @moduledoc """
  ## Concept

  Carry one permitted compaction attempt's activity without exposing its input
  or treating transient delivery as an outcome.

  ## Technical depth

  Accepted ADR 0054 fixes six required members. Native episode and owner IDs
  remain opaque bytes; the attempt domain is 32 lowercase hexadecimal bytes.
  Wire quantities are canonical decimal strings, and identities are canonical
  unpadded base64url. This codec grants no authority and admits no private data.
  """

  alias LoopexProtocol.Session.CheckpointOwner
  alias LoopexProtocol.Wire

  @kind "context.compaction_progress"
  @u64_max 18_446_744_073_709_551_615

  @doc """
  ## Concept

  Encode only the approved activity observation.

  ## Technical depth

  Require a plain atom-keyed six-member map and the closed CheckpointOwner.
  Sequence is exactly zero; base admits the whole unsigned 64-bit range.
  """
  @spec encode_wire(term()) :: {:ok, map()} | :error
  def encode_wire(
        %{
          kind: @kind,
          episode_id: episode_id,
          owner: owner,
          stream_domain_id: domain,
          progress_sequence: 0,
          base_event_sequence: base
        } = value
      )
      when not is_struct(value) and map_size(value) == 6 and is_binary(episode_id) and
             byte_size(episode_id) in 1..65_536 and is_integer(base) and base >= 0 and
             base <= @u64_max do
    with true <- domain?(domain),
         {:ok, encoded_owner} <- CheckpointOwner.encode_wire(owner) do
      {:ok,
       %{
         "kind" => @kind,
         "episode_id" => Wire.encode_identity(episode_id),
         "owner" => encoded_owner,
         "stream_domain_id" => Wire.encode_identity(domain),
         "progress_sequence" => "0",
         "base_event_sequence" => Wire.encode_u64(base)
       }}
    else
      _ -> :error
    end
  end

  def encode_wire(_), do: :error

  @doc """
  ## Concept

  Recover the exact observation from its closed wire shape.

  ## Technical depth

  Refuse extra or alternate keys, nulls, numbers, alternate identity encodings
  and noncanonical quantities. Decoding does not establish who emitted it.
  """
  @spec decode_wire(term()) :: {:ok, map()} | :error
  def decode_wire(
        %{
          "kind" => @kind,
          "episode_id" => episode_id,
          "owner" => owner,
          "stream_domain_id" => domain,
          "progress_sequence" => "0",
          "base_event_sequence" => base
        } = value
      )
      when not is_struct(value) and map_size(value) == 6 do
    with {:ok, native_episode} <- identity(episode_id),
         {:ok, native_owner} <- CheckpointOwner.decode_wire(owner),
         {:ok, native_domain} <- identity(domain),
         true <- domain?(native_domain),
         {:ok, native_base} <- Wire.u64(base) do
      {:ok,
       %{
         kind: @kind,
         episode_id: native_episode,
         owner: native_owner,
         stream_domain_id: native_domain,
         progress_sequence: 0,
         base_event_sequence: native_base
       }}
    else
      _ -> :error
    end
  end

  def decode_wire(_), do: :error

  defp identity(value) do
    with {:ok, native} <- Wire.identity(value),
         true <- Wire.encode_identity(native) == value do
      {:ok, native}
    else
      _ -> :error
    end
  end

  defp domain?(value) when is_binary(value) and byte_size(value) == 32,
    do: value |> :binary.bin_to_list() |> Enum.all?(&(&1 in ?0..?9 or &1 in ?a..?f))

  defp domain?(_), do: false
end
