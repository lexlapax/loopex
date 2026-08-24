defmodule LoopexProtocol.Canonical do
  @moduledoc """
  ## Concept

  The one way this repository turns a bounded plain-data record into bytes that
  can be digested, compared, and retained. Two records that mean the same thing
  produce the same bytes, two that differ never collide, and the bytes a digest
  covers are always available beside it rather than reconstructed later from
  something that has since changed.

  Four separate contracts depend on that single answer: a tool definition's
  generation digest, a turn's `staged_request_digest`, an executor job's
  attempt-bound `canonical_request_digest`, and a progress stream's
  `stream_domain_id`. They live in different applications and are decided by
  different ADRs, so the encoding they share is defined here, in the one
  application every other application may depend on.

  ## Technical depth

  Encoding is `:erlang.term_to_binary/2` with `:deterministic`, applied to a
  recursively ordered projection of the record. Map keys are sorted by their
  binary value before encoding, so an equal map encodes identically regardless
  of insertion order. The encoding is length-aware and therefore injective over
  arbitrary binary content: no choice of identifiers can make two distinct
  tuples encode to the same bytes, which a delimiter-joined string cannot
  promise and which
  [ADR 0011](../../../../docs/adr/0011-session-input-algebra-and-streaming.md#concept)
  requires of `stream_domain_id` specifically.

  `version/0` tags the encoding itself. It is carried inside the structures that
  digest their own contents, so a future change to this function is a visible
  change of covered bytes rather than a silent reinterpretation of a retained
  digest.

  Both `:erlang` and `:crypto` are OTP applications available at the
  [ADR 0002](../../../../docs/adr/0002-bootstrap-runtime-floor.md#concept)
  floor of OTP 26, so nothing here depends on `:json`, `JSON`, or any package.
  """

  @encoding_version "loopex.canonical.v1"

  @typedoc """
  ## Concept

  Bounded plain data: a term built only from binaries, integers, booleans,
  atoms, `nil`, lists, tuples, and maps of the same.

  ## Technical depth

  Deliberately not a structural type. Elixir cannot express "no pid anywhere
  inside", so the constraint is enforced by `encode/1` raising on anything
  outside the set rather than by a specification a caller could satisfy on
  paper while passing a pid at runtime.
  """
  @type plain :: term()

  @doc """
  ## Concept

  The tag naming this encoding.

  ## Technical depth

  Structures that digest themselves carry this value among the bytes they
  cover, so a digest always states which encoding produced it.
  """
  @spec version() :: binary()
  def version, do: @encoding_version

  @doc """
  ## Concept

  The canonical bytes of a bounded plain-data term.

  ## Technical depth

  Orders the term recursively, then encodes deterministically. Raises
  `ArgumentError` when the term carries anything outside the plain-data set —
  a pid, port, reference, function, or improper list — because such a term
  cannot cross a durable or executor boundary and silently encoding one would
  put an unrepresentable value inside a retained digest.
  """
  @spec encode(plain()) :: binary()
  def encode(term), do: :erlang.term_to_binary(order(term), [:deterministic])

  @doc """
  ## Concept

  The lowercase hexadecimal SHA-256 digest of a term's canonical bytes.

  ## Technical depth

  Callers that retain a digest retain the bytes beside it. Equal digests never
  admit different bytes anywhere in this repository, because every comparison
  that matters compares the bytes and treats the digest as an index rather than
  as the identity itself.
  """
  @spec digest(plain()) :: binary()
  def digest(term), do: digest_bytes(encode(term))

  @doc """
  ## Concept

  The lowercase hexadecimal SHA-256 digest of bytes already canonicalized.

  ## Technical depth

  Used where the bytes were committed earlier and must not be recomputed from a
  structure that may since have changed — a staged request replayed from the
  journal being the case that matters.
  """
  @spec digest_bytes(binary()) :: binary()
  def digest_bytes(bytes) when is_binary(bytes) do
    :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
  end

  # Concept: ordering is what makes two equal maps encode identically.
  #
  # Technical depth: `:deterministic` fixes how a given term is laid out, not
  # how a map's contents are arranged, so maps are converted to key-sorted
  # lists before encoding rather than trusted to encode stably as maps. The
  # walk is total over plain data and raises on anything else, which is why the
  # guard clauses below are exhaustive rather than falling through to a
  # permissive default.
  defp order(term) when is_map(term) and not is_struct(term) do
    term
    |> Enum.map(fn {key, value} -> {order(key), order(value)} end)
    |> Enum.sort_by(fn {key, _value} -> :erlang.term_to_binary(key, [:deterministic]) end)
    |> then(&{:loopex_map, &1})
  end

  defp order(term) when is_list(term), do: Enum.map(term, &order/1)

  defp order(term) when is_tuple(term) do
    term |> Tuple.to_list() |> Enum.map(&order/1) |> List.to_tuple()
  end

  defp order(term)
       when is_binary(term) or is_integer(term) or is_boolean(term) or is_nil(term) or
              is_atom(term),
       do: term

  defp order(term) do
    raise ArgumentError,
          "canonical encoding refuses a term outside bounded plain data: #{inspect(term)}"
  end
end
