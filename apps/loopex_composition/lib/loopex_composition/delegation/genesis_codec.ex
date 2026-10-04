defmodule LoopexComposition.Delegation.GenesisCodec do
  @moduledoc """
  ## Concept

  Retain exact resolved session genesis for parent bindings and child
  reservations without rendering opaque core bytes as host text.

  ## Technical depth

  ADR 0046 fixes the three-member private object: encoding, padded RFC 4648
  base64 bytes and the lowercase SHA-256 of the decoded bytes. Writers serialize
  the normalized plain map with deterministic, uncompressed ETF. Readers cap
  bytes before parsing, use existing-atom-only decoding, consume the complete
  payload and call the shared core genesis validator. They do not require an
  OTP release to reproduce another release's ETF bytes. The current contract
  is v3; this codec admits no superseded genesis or protocol Canonical tree.
  Neither operation creates a session, reads host defaults or writes a ledger.
  """

  alias Loopex.Runtime.SessionGenesis

  @encoding "loopex.ledger.plain_etf.v1.base64"
  @max_payload_bytes 65_536
  @max_base64_bytes 4 * div(@max_payload_bytes + 2, 3)

  @doc """
  ## Concept

  Encode resolved current genesis as the exact private retained object.

  ## Technical depth

  Core owns normalization and the complete 65,536-byte genesis limit. The
  object uses binary keys and ASCII values, including base64 expansion; its
  containing creation object must also measure its complete encoded JSON.
  """
  @spec encode(term()) :: {:ok, map()} | {:error, :invalid_retained_genesis}
  def encode(genesis) do
    with {:ok, %{kind: "session_genesis_v3"} = normalized} <-
           SessionGenesis.normalize(genesis) do
      bytes = :erlang.term_to_binary(normalized, [:deterministic])

      {:ok,
       %{
         "encoding" => @encoding,
         "bytes" => Base.encode64(bytes),
         "sha256" => digest(bytes)
       }}
    else
      _invalid -> {:error, :invalid_retained_genesis}
    end
  end

  @doc """
  ## Concept

  Recover validated genesis from retained bytes without substituting settings.

  ## Technical depth

  Exactly three binary-key members are required. Base64 is canonical and
  padded; compressed ETF, unsafe terms, trailing bytes, digest mismatches and
  invalid core schemas refuse. Integrity covers the original retained bytes,
  rather than a new encoding produced by the reader's OTP release.
  """
  @spec decode(term()) :: {:ok, SessionGenesis.genesis()} | {:error, :invalid_retained_genesis}
  def decode(%{"encoding" => @encoding, "bytes" => encoded, "sha256" => hash} = object)
      when map_size(object) == 3 and is_binary(encoded) and is_binary(hash) and
             byte_size(encoded) <= @max_base64_bytes and byte_size(hash) == 64 do
    with {:ok, bytes} <- Base.decode64(encoded),
         true <- byte_size(bytes) <= @max_payload_bytes,
         true <- Base.encode64(bytes) == encoded,
         true <- digest(bytes) == hash,
         {:ok, genesis} <- decode_plain(bytes),
         {:ok, %{kind: "session_genesis_v3"} = normalized} <-
           SessionGenesis.normalize(genesis) do
      {:ok, normalized}
    else
      _invalid -> {:error, :invalid_retained_genesis}
    end
  end

  def decode(_object), do: {:error, :invalid_retained_genesis}

  # Concept: retained bytes cannot expand through compression or intern atoms.
  # Technical depth: ETF compression is an outer tag. Reject it before decoding;
  # :used rejects otherwise valid terms with an unconsumed suffix. Core validates
  # the decoded plain map, including process terms that :safe alone can admit.
  defp decode_plain(<<131, tag, _rest::binary>> = bytes) when tag != 80 do
    case :erlang.binary_to_term(bytes, [:safe, :used]) do
      {genesis, used} when used == byte_size(bytes) -> {:ok, genesis}
      _trailing -> :error
    end
  rescue
    ArgumentError -> :error
  end

  defp decode_plain(_bytes), do: :error

  defp digest(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
