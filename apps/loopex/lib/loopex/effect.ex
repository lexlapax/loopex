defmodule Loopex.Effect do
  @moduledoc """
  ## Concept

  What identifies one effect, and what a coordinator will accept as its outcome.

  An effect's transaction id is preallocated before dispatch and derived from
  the request itself, so it is bound to the mutation being asked for rather than
  handed out by a counter. Two things follow. The same operation attempt always
  names the same transaction, so a restart can find it again from the operation
  identity alone. And a request whose payload, domain, or domain version differs
  in any way is a different transaction, so a changed mutation can never inherit
  a previous one's fence or receipt.

  An outcome is admitted only when it matches the intent that was durable before
  dispatch. A live result must match the operation, the attempt, the journaled
  request digest, the executor identity and epoch, the fencing token, and the
  session's current epoch. A receipt for an effect whose outcome went unknown is
  admitted only as a solicited answer to the current reconciliation query, and
  must additionally carry the epoch the effect was dispatched under. Anything
  else is stale and is refused.

  ## Technical depth

  Pure and process-free, so the admission rules are testable without a session,
  a journal, or a restart, and so the rules themselves cannot depend on ambient
  state. No behaviour is declared: one implementation exists and the minimalism
  budget admits a behaviour only where a fake must substitute for a real edge.

  The digest is SHA-256 over the `:deterministic` external term format of an
  exact five-field projection of the request. The projection is exact rather
  than "the request minus some keys", because a digest that silently absorbs
  unknown fields would let a caller change what is dispatched while the digest
  that is supposed to bind it stays the same.

  Every comparison returns the first field that failed. A boolean would say a
  result was rejected without saying which invariant caught it, and the
  difference between a wrong attempt and a stale epoch is exactly what a
  recovery diagnosis needs.
  """

  alias Loopex.Journal

  @typedoc """
  ## Concept

  A request to perform one effect: which operation, which attempt of it, which
  mutation domain and version it belongs to, and the mutation itself.

  ## Technical depth

  All five fields are plain boundary data, and all five are covered by the
  digest. `attempt` is part of the identity rather than a retry counter kept
  elsewhere, so attempt 2 of an operation is a distinct transaction from attempt
  1 and cannot be mistaken for it.
  """
  @type request :: %{
          required(:operation_id) => binary(),
          required(:attempt) => pos_integer(),
          required(:domain) => atom(),
          required(:domain_version) => non_neg_integer(),
          required(:payload) => term()
        }

  @typedoc """
  ## Concept

  The executor an effect is dispatched to, as the coordinator expects to find
  it: who it is, which generation of it is current, and the token that authorises
  this coordinator to fence it.

  ## Technical depth

  Plain data held by the coordinator and copied into each intent, so an outcome
  arriving after the executor was replaced fails the comparison against the
  journaled values rather than against whatever the coordinator happens to
  believe now.
  """
  @type executor :: %{
          required(:identity) => binary(),
          required(:epoch) => non_neg_integer(),
          required(:fencing_token) => non_neg_integer()
        }

  # Technical depth: the exact projection the digest covers. Listed as data so
  # the digest's definition is one readable line, and so adding a request field
  # is a visible decision about whether the digest binds it.
  @digest_fields [:operation_id, :attempt, :domain, :domain_version, :payload]

  # Technical depth: a live result must match the intent on every one of these.
  # The session epoch is compared separately because it is checked against the
  # coordinator's current epoch, not against the journaled one -- that asymmetry
  # is what makes a result from a previous incarnation recognisably stale.
  @live_fields [
    :tx_id,
    :operation_id,
    :attempt,
    :canonical_request_digest,
    :executor_identity,
    :executor_epoch,
    :fencing_token
  ]

  @doc """
  ## Concept

  The canonical digest of what a request asks to mutate.

  ## Technical depth

  Equal requests produce equal digests and unequal requests produce unequal ones,
  which is what lets the digest stand in for the request when an outcome is
  admitted. Raises when a required field is absent: a digest computed over a
  partial request would be a valid-looking binding to the wrong mutation, which
  is worse than a crash at the call site that built it.
  """
  @spec canonical_request_digest(request()) :: binary()
  def canonical_request_digest(request) when is_map(request) do
    canonical = Enum.map(@digest_fields, fn field -> {field, Map.fetch!(request, field)} end)

    :crypto.hash(:sha256, :erlang.term_to_binary(canonical, [:deterministic]))
    |> Base.encode16(case: :lower)
  end

  @doc """
  ## Concept

  The transaction id this request preallocates.

  ## Technical depth

  Derived from the operation identity, the mutation domain and its version, and
  the request digest, so it is bound to the domain version and the canonical
  mutation the durability invariant requires, and recoverable from the operation
  identity without consulting anything but the request.
  """
  @spec tx_id(request(), binary()) :: binary()
  def tx_id(request, digest) when is_map(request) and is_binary(digest) do
    bound = [
      Map.fetch!(request, :operation_id),
      Map.fetch!(request, :attempt),
      Map.fetch!(request, :domain),
      Map.fetch!(request, :domain_version),
      digest
    ]

    :crypto.hash(:sha256, :erlang.term_to_binary(bound, [:deterministic]))
    |> Base.encode16(case: :lower)
  end

  @doc """
  ## Concept

  The durable record that must exist before this effect is dispatched.

  ## Technical depth

  Carries the request payload as well as its digest, so a recovered intent can
  be checked against its own digest rather than trusted. Carrying the payload
  does not authorise redispatching it: an intent with no outcome is fenced by
  `Loopex.Session`, and nothing in this milestone rebuilds a dispatch from a
  journal.

  The `:seq` field is deliberately absent. Sequence is assigned by the single
  serial writer at commit time; an intent that arrived with one would be claiming
  a position in a history it does not own.
  """
  @spec intent(request(), non_neg_integer(), executor()) :: Journal.entry()
  def intent(request, session_epoch, executor) when is_map(request) and is_map(executor) do
    digest = canonical_request_digest(request)

    %{
      kind: :effect_intent,
      tx_id: tx_id(request, digest),
      operation_id: Map.fetch!(request, :operation_id),
      attempt: Map.fetch!(request, :attempt),
      canonical_request_digest: digest,
      domain: Map.fetch!(request, :domain),
      domain_version: Map.fetch!(request, :domain_version),
      payload: Map.fetch!(request, :payload),
      epoch: session_epoch,
      executor_identity: Map.fetch!(executor, :identity),
      executor_epoch: Map.fetch!(executor, :epoch),
      fencing_token: Map.fetch!(executor, :fencing_token)
    }
  end

  @doc """
  ## Concept

  The request an intent was built from.

  ## Technical depth

  Exists so a recovered intent's digest can be recomputed and compared with the
  journaled one. That is the difference between a journal that records a digest
  and a journal whose digest is checkable.
  """
  @spec request_of(Journal.entry()) :: request()
  def request_of(intent) when is_map(intent) do
    Map.new(@digest_fields, fn field -> {field, Map.fetch!(intent, field)} end)
  end

  @doc """
  ## Concept

  What crosses the boundary to the executor.

  ## Technical depth

  Plain data only: the intent without the fields that describe its place in the
  journal. The executor receives the identity, digest, epochs, and fencing token
  it must validate before it performs anything, which is the same set an outcome
  is later admitted on.
  """
  @spec dispatch(Journal.entry()) :: map()
  def dispatch(intent) when is_map(intent) do
    Map.drop(intent, [:kind, :seq])
  end

  @doc """
  ## Concept

  Whether a result that arrived while the effect was still awaited may be
  believed.

  ## Technical depth

  Matches the journaled intent on operation, attempt, request digest, executor
  identity and epoch, and fencing token, and requires the result to carry the
  session's current epoch. The current epoch is the check that rejects a result
  produced under a previous incarnation of the coordinator: the epoch increments
  on every start, so a result in flight across a restart cannot match.
  """
  @spec admit_live_result(Journal.entry(), map(), non_neg_integer()) ::
          :ok | {:error, {:mismatch, atom()}}
  def admit_live_result(intent, result, session_epoch)
      when is_map(intent) and is_map(result) do
    with :ok <- match_fields(intent, result, @live_fields) do
      expect(result, :session_epoch, session_epoch)
    end
  end

  @doc """
  ## Concept

  Whether a receipt for an effect whose outcome went unknown may resolve it.

  Admission is narrower than for a live result. The receipt must be a solicited
  answer to the reconciliation query the coordinator is currently asking, from
  the executor it currently expects, under its current epoch — and the tuple it
  retained must match the effect as it was dispatched, including the session
  epoch that dispatched it.

  ## Technical depth

  `expected` carries the current `reconciliation_query_id`, the current session
  epoch, and the expected executor identity. Requiring the query id is what
  makes the response solicited: an unsolicited receipt matches no live query and
  is refused, so an executor cannot resolve a fence by volunteering an answer.

  The session epoch appears twice with different meanings, and both are checked.
  `:session_epoch` must be the coordinator's current epoch, proving the receipt
  answers this incarnation. `:session_epoch_at_dispatch` must equal the epoch
  journaled in the intent, proving the receipt describes the dispatch that
  actually happened rather than a later one.
  """
  @spec admit_receipt(Journal.entry(), map(), map()) :: :ok | {:error, {:mismatch, atom()}}
  def admit_receipt(intent, receipt, expected)
      when is_map(intent) and is_map(receipt) and is_map(expected) do
    with :ok <-
           expect(
             receipt,
             :reconciliation_query_id,
             Map.fetch!(expected, :reconciliation_query_id)
           ),
         :ok <- expect(receipt, :session_epoch, Map.fetch!(expected, :session_epoch)),
         :ok <- expect(receipt, :executor_identity, Map.fetch!(expected, :executor_identity)),
         :ok <- match_fields(intent, receipt, @live_fields) do
      expect(receipt, :session_epoch_at_dispatch, Map.fetch!(intent, :epoch))
    end
  end

  # Concept: every named field of the answer must equal the journaled intent.
  # Technical depth: a field absent from the answer is a mismatch, not a pass.
  # Comparing with Map.get on both sides would have made a missing field match a
  # missing field, which is how an empty map would have been admitted.
  defp match_fields(intent, answer, fields) do
    Enum.reduce_while(fields, :ok, fn field, :ok ->
      case is_map_key(answer, field) and Map.get(answer, field) == Map.fetch!(intent, field) do
        true -> {:cont, :ok}
        false -> {:halt, {:error, {:mismatch, field}}}
      end
    end)
  end

  defp expect(answer, field, value) do
    case is_map_key(answer, field) and Map.fetch!(answer, field) == value do
      true -> :ok
      false -> {:error, {:mismatch, field}}
    end
  end
end
