defmodule Loopex.Runtime.ContextAdmission do
  @moduledoc """
  ## Concept

  Decides whether the exact request a session is about to stage may be admitted
  at all.

  Two separate questions have to be answered before a provider is called. The
  first is whether the provider-visible content fits the ceiling this run
  committed. The second is whether the durable record describing that request
  can be retained. Passing one says nothing about the other: token cost omits
  the envelope, provenance, and full tool definitions that occupy durable
  space, so a request can fit every token ceiling and still be too large to
  write down.

  A candidate that fails either question is refused here, before any provider
  call, effect, or queue work, and the refusal names the one dimension that
  failed, what was observed, and what the limit was. It carries no descriptor
  bodies and no private source identity.

  ## Technical depth

  This module owns the ADR 0017 admission boundary. Evaluation is ordered and
  the first failure wins, so a refusal is reproducible from the same inputs:

  1. the `system` provenance class against its strict 1,000-token ceiling,
     where one below fits while exactly at and above refuse;
  2. the whole provider-visible request against the run's committed
     `context_token_budget`;
  3. the exact durable record's structure, reported as `context_record_depth`
     or `context_record_cardinality`; and
  4. that record's exact encoded byte cost against the Store item ceiling.

  Structure precedes bytes because a structurally inadmissible record has no
  meaningful size, and both are measured through `Loopex.Store` so a caller and
  the Store compare the same count against the same ceiling rather than two
  independently drifting estimates.

  The candidate is measured exactly as supplied. Resolving the record's
  self-reported `record_byte_cost` to its fixed point belongs to the caller
  that constructs the successful receipt; this boundary reports what the
  candidate in front of it actually costs.
  """

  alias Loopex.Store

  @system_class_token_ceiling 1_000

  @typedoc """
  ## Concept

  What was already measured about a candidate request, plus the limits it must
  be judged against.

  ## Technical depth

  Token observations are supplied rather than recomputed here, because only the
  live constructor holds the exact provider-visible preimage. The three limit
  members are passed explicitly so the caller and this boundary cannot disagree
  about which ceiling was applied.
  """
  @type observations() :: %{
          required(:system_class_tokens) => non_neg_integer(),
          required(:provider_estimated_tokens) => non_neg_integer(),
          required(:context_token_budget) => pos_integer(),
          required(:context_record_byte_ceiling) => pos_integer(),
          required(:context_record_depth_limit) => pos_integer(),
          required(:context_record_cardinality_limit) => pos_integer()
        }

  @typedoc """
  ## Concept

  The compact, safe description of why a candidate was refused.

  ## Technical depth

  Exactly the selected dimension, the observed value, the limit, and the record
  byte cost. `record_byte_cost` is `nil` for a token or structural refusal,
  because those precede record construction; for a byte refusal it equals
  `observed` and never claims a candidate was admitted.
  """
  @type refusal() :: %{
          optional(binary()) => binary() | non_neg_integer() | nil
        }

  @doc """
  ## Concept

  Judges one exact required-context candidate record and either admits it or
  names the first dimension it exceeded.

  ## Technical depth

  Returns `:ok` when every dimension fits, or `{:refused, refusal}` naming the
  first failure under the fixed order in this module's documentation. The
  candidate is neither retained nor mutated, and nothing is dispatched, so a
  refusal costs no provider call, journal write, or queue work.

  A candidate that is not plain bounded data at all is not a budget verdict.
  It returns `{:error, reason}` from `Loopex.Store`, so a malformed candidate is
  reported as invalid data rather than fabricated into an operator-facing
  context failure.
  """
  @spec preflight_required_candidate(map(), observations()) ::
          :ok | {:refused, refusal()} | {:error, term()}
  def preflight_required_candidate(candidate, observations)
      when is_map(candidate) and is_map(observations) do
    with :ok <- system_class(observations),
         :ok <- context_tokens(observations) do
      record_admission(candidate, observations)
    end
  end

  # Concept: the system class is checked before the total it contributes to.
  #
  # Technical depth: ADR 0010's rule is strict rather than inclusive -- exactly
  # at the ceiling refuses -- so a host-owned system prompt that has grown to
  # consume the whole reserved class is caught by its own name instead of being
  # reported as a total-budget failure the operator cannot locate.
  defp system_class(%{system_class_tokens: observed})
       when observed >= @system_class_token_ceiling,
       do: refused("system_class_tokens", observed, @system_class_token_ceiling, nil)

  defp system_class(_observations), do: :ok

  defp context_tokens(%{provider_estimated_tokens: observed, context_token_budget: limit})
       when observed > limit,
       do: refused("context_tokens", observed, limit, nil)

  defp context_tokens(_observations), do: :ok

  # Concept: the record has to be writable, not merely affordable.
  #
  # Technical depth: structure is resolved before size because a record that
  # breaches depth or collection cardinality has no admissible encoded form to
  # compare with a byte ceiling. Both come from the Store's shared normalizer,
  # so the number compared here is the number the Store itself would validate.
  defp record_admission(candidate, observations) do
    case Store.normalize_and_measure_item(:record, candidate) do
      {:ok, _normalized, bytes} ->
        record_bytes(bytes, observations)

      {:error, {:item_structure_exceeded, dimension, observed, _limit}} ->
        structural(dimension, observed, observations)

      {:error, _reason} = error ->
        error
    end
  end

  defp record_bytes(bytes, %{context_record_byte_ceiling: limit}) when bytes > limit,
    do: refused("context_record_bytes", bytes, limit, bytes)

  defp record_bytes(_bytes, _observations), do: :ok

  defp structural(:depth, observed, %{context_record_depth_limit: limit}),
    do: refused("context_record_depth", observed, limit, nil)

  defp structural(:cardinality, observed, %{context_record_cardinality_limit: limit}),
    do: refused("context_record_cardinality", observed, limit, nil)

  defp refused(dimension, observed, limit, record_byte_cost) do
    {:refused,
     %{
       "dimension" => dimension,
       "observed" => observed,
       "limit" => limit,
       "record_byte_cost" => record_byte_cost
     }}
  end
end
