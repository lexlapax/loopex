defmodule LoopexProtocol.Wire do
  @moduledoc """
  ## Concept

  The value types the public session protocol carries: opaque identities,
  quantities that can reach the whole unsigned 64-bit range, digests, and raw
  bytes. Each one has exactly one wire representation, and each is decoded
  before anything reaches a facade.

  ## Technical depth

  Accepted ADR 0023 fixes these representations, and the reasons are the same
  in every case: an identity is bytes rather than text, so it travels base64url
  and its alphabet is never narrowed on the way through; a count that can reach
  2^64 does not fit a JSON number both sides can round-trip, so it travels as a
  canonical decimal string; a digest is the lowercase hexadecimal the rest of
  the repository already writes.

  Decoding refuses rather than repairs. A representation that is nearly right is
  a client that has misunderstood the contract, and answering it as though it
  were right would let two clients disagree about what the same bytes mean.
  """

  @max_identity_bytes 65_536
  @max_session_identity_bytes 256
  @u64_max 18_446_744_073_709_551_615

  @doc """
  ## Concept

  Decodes an opaque identity from its wire form.

  ## Technical depth

  Unpadded base64url, decoded to the exact bytes the runtime uses. Padding is
  refused rather than accepted alongside the unpadded form: two spellings of one
  identity would give a client two ways to name the same thing and a server two
  strings to compare.
  """
  @spec identity(term(), pos_integer()) :: {:ok, binary()} | :error
  def identity(value, max_bytes \\ @max_identity_bytes)

  def identity(value, max_bytes) when is_binary(value) do
    with false <- String.contains?(value, "="),
         {:ok, decoded} <- Base.url_decode64(value, padding: false),
         true <- byte_size(decoded) in 1..max_bytes do
      {:ok, decoded}
    else
      _other -> :error
    end
  end

  def identity(_value, _max_bytes), do: :error

  @doc """
  ## Concept

  Encodes bytes as an opaque wire identity.
  """
  @spec encode_identity(binary()) :: binary()
  def encode_identity(bytes) when is_binary(bytes),
    do: Base.url_encode64(bytes, padding: false)

  @doc """
  ## Concept

  The tighter bound a session or runtime placement identity carries.
  """
  @spec session_identity(term()) :: {:ok, binary()} | :error
  def session_identity(value), do: identity(value, @max_session_identity_bytes)

  @doc """
  ## Concept

  Decodes a quantity that may use the whole unsigned 64-bit range.

  ## Technical depth

  Canonical decimal, which means no sign, no leading zero except for zero
  itself, and no whitespace. A JSON number is refused here even when it would
  fit, because the contract admits exactly one representation and a client that
  sent a number has not read it.
  """
  @spec u64(term()) :: {:ok, non_neg_integer()} | :error
  def u64(value) when is_binary(value) do
    with true <- canonical_decimal?(value),
         {parsed, ""} <- Integer.parse(value),
         true <- parsed <= @u64_max do
      {:ok, parsed}
    else
      _other -> :error
    end
  end

  def u64(_value), do: :error

  @doc """
  ## Concept

  Encodes a quantity in the canonical decimal form the wire carries.
  """
  @spec encode_u64(non_neg_integer()) :: binary()
  def encode_u64(value) when is_integer(value) and value >= 0 and value <= @u64_max,
    do: Integer.to_string(value)

  @doc """
  ## Concept

  Decodes a digest in its wire form.

  ## Technical depth

  Sixty-four lowercase hexadecimal characters. Uppercase is refused rather than
  folded: the repository writes digests in one case, and accepting the other
  would make two spellings compare unequal as strings while naming the same
  bytes.
  """
  @spec digest(term()) :: {:ok, binary()} | :error
  def digest(value) when is_binary(value) do
    if byte_size(value) == 64 and
         value |> :binary.bin_to_list() |> Enum.all?(&lower_hex?/1),
       do: {:ok, value},
       else: :error
  end

  def digest(_value), do: :error

  @doc """
  ## Concept

  Decodes raw bytes from their wire form.

  ## Technical depth

  The same unpadded base64url an identity uses, because both carry exact bytes
  rather than text. Content is decoded here and never rendered as a string on
  the way, so bytes that are not valid UTF-8 survive the crossing intact.
  """
  @spec bytes(term(), pos_integer()) :: {:ok, binary()} | :error
  def bytes(value, max_bytes) when is_binary(value) and is_integer(max_bytes) do
    with false <- String.contains?(value, "="),
         {:ok, decoded} <- Base.url_decode64(value, padding: false),
         true <- byte_size(decoded) <= max_bytes do
      {:ok, decoded}
    else
      _other -> :error
    end
  end

  def bytes(_value, _max_bytes), do: :error

  @doc """
  ## Concept

  Encodes exact bytes for the wire.
  """
  @spec encode_bytes(binary()) :: binary()
  def encode_bytes(value) when is_binary(value), do: Base.url_encode64(value, padding: false)

  defp canonical_decimal?(""), do: false
  defp canonical_decimal?("0"), do: true
  defp canonical_decimal?(<<?0, _rest::binary>>), do: false

  defp canonical_decimal?(value),
    do: value |> :binary.bin_to_list() |> Enum.all?(&(&1 in ?0..?9))

  defp lower_hex?(byte), do: byte in ?0..?9 or byte in ?a..?f
end
