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

  ## Technical depth

  Unpadded base64url, so an identity needs no escaping in a URL or a path and
  one value has exactly one encoding. The bytes stay opaque: nothing downstream
  is entitled to interpret them.
  """
  @spec encode_identity(binary()) :: binary()
  def encode_identity(bytes) when is_binary(bytes),
    do: Base.url_encode64(bytes, padding: false)

  @doc """
  ## Concept

  The tighter bound a session or runtime placement identity carries.

  ## Technical depth

  The same decoding as any other identity against a smaller ceiling, because a
  session or placement identity is quoted far more often than it is created. It
  answers `:error` rather than raising, since the value arrives from the wire.
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

  ## Technical depth

  Produces the one form its decoder admits -- no sign, no leading zero except
  for zero itself, no whitespace -- so a value encoded here round-trips. The
  guard refuses a negative or out-of-range integer at this boundary rather than
  emitting something the other side would reject.
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

  ## Technical depth

  Unpadded base64url again, so exact bytes survive a JSON string unchanged,
  including bytes that are not valid UTF-8. Encoding is total: there is no
  binary it cannot carry, so there is nothing to refuse.
  """
  @spec encode_bytes(binary()) :: binary()
  def encode_bytes(value) when is_binary(value), do: Base.url_encode64(value, padding: false)

  @reference_bytes 8_192

  @doc """
  ## Concept

  Encodes the compact artifact reference a client holds as one opaque value.

  ## Technical depth

  A client receives a reference in an event and hands it back to open a
  transfer. Accepted ADR 0023 makes that one opaque identity rather than four
  fields, so the client cannot assemble a reference it was never given by
  mixing parts of two. The bytes inside are this protocol's own bounded JSON,
  which is what makes the value safe to decode again: nothing here ever calls
  the term decoder on something a client sent.
  """
  @spec encode_reference(map()) :: binary()
  def encode_reference(%{} = reference) do
    {:ok, encoded} =
      reference
      |> normalize_reference()
      |> LoopexProtocol.Frame.encode()

    encoded
    |> IO.iodata_to_binary()
    |> String.trim_trailing("\n")
    |> encode_bytes()
  end

  # Concept: the four members a reference carries, in their wire forms.
  #
  # Technical depth: a compact reference holds its size as an integer, and this
  # protocol carries every size as a decimal string. Converting here rather than
  # asking each caller to means the value inside an opaque identity obeys the
  # same rules as a value beside it, which is what lets the decoder validate it
  # with the same functions.
  defp normalize_reference(reference) do
    for key <- ["digest", "size", "locator", "use_locator"],
        value = reference_member(reference, key),
        into: %{} do
      case key do
        "size" when is_integer(value) -> {key, encode_u64(value)}
        _other -> {key, value}
      end
    end
  end

  defp reference_member(reference, key) do
    case Map.fetch(reference, key) do
      {:ok, value} -> value
      :error -> Map.get(reference, String.to_existing_atom(key))
    end
  end

  @doc """
  ## Concept

  Decodes an opaque artifact reference back to its members.

  ## Technical depth

  Bounded twice: once by the base64url decode and again by the frame decoder's
  own limits, with a ceiling far below a frame's because a reference is a handful
  of short members. A value that decodes but does not carry the exact members is
  refused, so a client cannot open a transfer with half a reference.
  """
  @spec reference(term()) :: {:ok, map()} | :error
  def reference(value) do
    with {:ok, payload} <- bytes(value, @reference_bytes),
         {:ok, decoded} <- LoopexProtocol.Frame.decode(payload, @reference_bytes),
         {:ok, digest} <- digest(Map.get(decoded, "digest")),
         {:ok, size} <- u64(Map.get(decoded, "size")),
         locator when is_binary(locator) <- Map.get(decoded, "locator"),
         "use:" <> _rest = use_locator <- Map.get(decoded, "use_locator") do
      {:ok, %{digest: digest, size: size, locator: locator, use_locator: use_locator}}
    else
      _other -> :error
    end
  end

  defp canonical_decimal?(""), do: false
  defp canonical_decimal?("0"), do: true
  defp canonical_decimal?(<<?0, _rest::binary>>), do: false

  defp canonical_decimal?(value),
    do: value |> :binary.bin_to_list() |> Enum.all?(&(&1 in ?0..?9))

  defp lower_hex?(byte), do: byte in ?0..?9 or byte in ?a..?f
end
