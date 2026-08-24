defmodule Loopex.StreamDomain do
  @moduledoc """
  ## Concept

  The identity of one stream of progress. Every delta and every closing item
  names the single attempt that produced it, so a consumer can tell a gap from a
  quiet provider and can tell a retry from a fault.

  There are two kinds, and both belong to an *attempt* rather than to a turn:
  one per model attempt and one per executor operation attempt. A retry opens a
  new domain, so several domains under one turn are the ordinary shape of a
  retried turn rather than a defect.

  Each domain the coordinator opens is owed exactly one content-free closing
  item, an abandoned domain included. Closure is an emission obligation and not
  a delivery guarantee: it rides the transient plane like any other progress
  item and may be coalesced away, dropped under backpressure, or lost with the
  plane when its owner changes. A consumer that receives no closure has an
  incomplete transient view and falls back to the durable record exactly as it
  does for a sequence gap. It must never read an absence as abandonment, because
  that inference needs a timeout, and a timeout is a guess.

  Fixed by
  [ADR 0011](../../../../docs/adr/0011-session-input-algebra-and-streaming.md#concept).

  ## Technical depth

  The identifier is the lowercase hexadecimal of the first sixteen bytes of the
  SHA-256 of the canonically encoded domain tuple:

      {"loopex.stream_domain.v1", domain_kind, session_id, operation_id, attempt}

  `attempt` is the integer itself, never a rendering of it. The canonical
  encoding is length-aware and therefore injective over arbitrary binary
  identifiers; a delimiter-joined string is not, and two sessions could collide
  by choosing identifiers that straddle the delimiter.

  The coordinator derives every domain from committed identity it already holds.
  An adapter never supplies one, and one is never read off an executor's event:
  the executor-side domain is derived from the `(operation_id, attempt)` the
  coordinator dispatched and journaled, *after* validation has already proved
  the event belongs to that attempt.

  Continuity, count agreement, and closure are evaluated strictly within one
  domain. No comparison is defined between two domains, including two of the
  same kind under one turn — a model reply's `delta_count` is known before that
  turn's first tool is even dispatched, so a cross-domain total could not be
  computed even if one were wanted.
  """

  alias LoopexProtocol.Canonical

  @domain_version "loopex.stream_domain.v1"
  @kinds [:model, :executor]
  @dispositions [:complete, :abandoned]

  @typedoc """
  ## Concept

  An opaque fixed-width label naming one attempt's stream.

  ## Technical depth

  Exactly 32 lowercase hexadecimal characters. Opaque by contract: a consumer
  compares it and never takes it apart, because its derivation is free to change
  behind the identifier's stability.
  """
  @type id :: binary()

  @typedoc """
  ## Concept

  Which kind of attempt owns a domain.

  ## Technical depth

  `:model` for a provider call, `:executor` for one tool operation attempt.
  """
  @type kind :: :model | :executor

  @typedoc """
  ## Concept

  Whether a domain produced its durable artifact or was given up on.

  ## Technical depth

  `:complete` when the attempt produced its reply or receipt, and the count is
  the producer's own statement. `:abandoned` when it produced neither — an
  error, a cancellation mid-stream, or supersession by a retry — and the count
  is what the coordinator itself observed before closing, which is exact because
  it stops accepting items for a domain once closed.
  """
  @type disposition :: :complete | :abandoned

  @doc """
  ## Concept

  Derives the domain identifier for one attempt.

  ## Technical depth

  Total over the identities the coordinator holds. Raises on an unknown kind
  rather than deriving something plausible, because a mislabelled domain is
  indistinguishable from a correct one once it is on the plane.
  """
  @spec derive(kind(), binary(), binary(), non_neg_integer()) :: id()
  def derive(kind, session_id, operation_id, attempt)
      when kind in @kinds and is_binary(session_id) and is_binary(operation_id) and
             is_integer(attempt) and attempt >= 0 do
    {@domain_version, kind, session_id, operation_id, attempt}
    |> Canonical.encode()
    |> then(&:crypto.hash(:sha256, &1))
    |> binary_part(0, 16)
    |> Base.encode16(case: :lower)
  end

  @doc """
  ## Concept

  The closing item owed to a model attempt's domain.

  ## Technical depth

  Content-free by construction: it carries counts and a disposition and no
  fragment of what was streamed. A consumer reconstructing text from deltas gets
  nothing extra from the closure, which is deliberate — the durable assistant
  message is built from the adapter's return value, never assembled from deltas.
  """
  @spec model_closed(binary(), id(), non_neg_integer(), disposition(), non_neg_integer()) :: map()
  def model_closed(turn_id, domain_id, base_event_sequence, disposition, delta_count)
      when disposition in @dispositions do
    %{
      kind: :model_stream_closed,
      turn_id: turn_id,
      stream_domain_id: domain_id,
      base_event_sequence: base_event_sequence,
      disposition: disposition,
      delta_count: delta_count
    }
  end

  @doc """
  ## Concept

  The closing item owed to one executor operation attempt's domain.

  ## Technical depth

  Carries the `tool_call_id` as well, because a turn may have several tool
  domains open and a consumer attributes progress per call rather than per turn.
  """
  @spec tool_closed(
          binary(),
          id(),
          binary(),
          non_neg_integer(),
          disposition(),
          non_neg_integer()
        ) :: map()
  def tool_closed(turn_id, domain_id, tool_call_id, base_event_sequence, disposition, count)
      when disposition in @dispositions do
    %{
      kind: :tool_stream_closed,
      turn_id: turn_id,
      stream_domain_id: domain_id,
      tool_call_id: tool_call_id,
      base_event_sequence: base_event_sequence,
      disposition: disposition,
      progress_count: count
    }
  end

  @doc """
  ## Concept

  The permitted dispositions.

  ## Technical depth

  Exposed so conformance enumerates them from here rather than restating them.
  """
  @spec dispositions() :: [disposition()]
  def dispositions, do: @dispositions
end
