defmodule Loopex.Store.OwnerLane do
  @moduledoc """
  ## Concept

  A session owner uses an Owner Lane for every Store mutation in one runtime
  incarnation. If a call returns `commit_unknown`, the lane refuses a distinct
  transaction in that mutation domain until exact re-presentation reaches a
  durable terminal outcome. Coordinators must also keep publication, dispatch,
  acknowledgement, and other eligibility decisions behind their retained lane;
  this module itself admits Store mutations and does not perform those later
  actions.

  The lane is runtime-local owner state, not durable truth or a Store adapter.
  A successor does not inherit it as authority: recovery observes transaction
  status, reads the non-authorizing ownership head, and commits a fresh owner
  succession before admitting commands.

  ## Technical depth

  Fences are keyed by `{session_id, mutation_domain}`; runtime-control creation
  uses `{runtime_control, runtime_id}`. The retained value is the complete
  immutable Store binding, not only a transaction ID or digest. While fenced,
  only an exact binding reaches the Store. Another binding returns `:fenced`
  without an adapter call, so the Store mutation path cannot treat ambiguity as
  absence. A matching terminal Store outcome clears the fence; another unknown
  preserves it. The serial owner retains this value and keeps downstream eligibility
  decisions behind it. Creation close additionally retains its exact unresolved
  predecessor until the close commits; refusal cannot erase that ambiguity.
  """

  alias Loopex.Store

  @typedoc """
  ## Concept

  Explicit runtime-local mutation admission state for one Store owner.

  ## Technical depth

  The map can contain a Store handle and therefore is never durable or public
  data. Coordinators retain it in their own serial process state.
  """
  @opaque t :: %__MODULE__{store: Store.t(), fences: map(), creation_prior: map()}
  defstruct [:store, fences: %{}, creation_prior: %{}]

  @typedoc """
  ## Concept

  The result of one owner-lane mutation admission attempt.

  ## Technical depth

  Store outcomes pass through unchanged. A distinct transaction in a fenced
  domain is refused locally as `{:fenced, :commit_unknown}`.
  """
  @type result :: Store.outcome() | {:fenced, :commit_unknown}

  @doc """
  ## Concept

  Creates an unfenced mutation lane for an explicit Store.

  ## Technical depth

  No process, name, or global state is created. The caller owns the returned
  value and must preserve the updated lane returned by `transact/2`.
  """
  @spec new(Store.t()) :: t()
  def new(%Store{} = store), do: %__MODULE__{store: store}

  @doc """
  ## Concept

  Presents one Store transaction if its mutation domain is not fenced, or if
  it exactly resolves the transaction that established the fence.

  ## Technical depth

  The returned lane is authoritative for the next owner action. Discarding it
  would discard the caller-side ambiguity fence and is therefore invalid owner
  behavior.
  """
  @spec transact(t(), Store.transaction()) :: {result(), t()}
  def transact(%__MODULE__{} = owner, transaction) do
    case admit(owner, transaction) do
      {:ok, _binding, admitted} ->
        outcome = Store.transact(admitted.store, transaction)
        {outcome, observe(admitted, transaction, outcome)}

      {:error, refusal, retained} ->
        {refusal, retained}
    end
  end

  @doc """
  ## Concept

  Reports whether a transaction's mutation domain currently has unresolved
  commit ambiguity.

  ## Technical depth

  This runtime-local observation grants no mutation authority and exposes none
  of the retained binding.
  """
  @spec fenced?(t(), Store.transaction()) :: boolean()
  def fenced?(%__MODULE__{} = owner, transaction) do
    case scope(transaction) do
      {:ok, scope} -> Map.has_key?(owner.fences, scope)
      {:error, _reason} -> true
    end
  end

  @doc false
  @spec admit(t(), Store.transaction()) :: {:ok, map(), t()} | {:error, result(), t()}
  def admit(%__MODULE__{} = owner, transaction) do
    with {:ok, scope} <- scope(transaction),
         {:ok, binding} <- Store.immutable_binding(transaction) do
      case Map.fetch(owner.fences, scope) do
        :error -> {:ok, binding, %{owner | fences: Map.put(owner.fences, scope, binding)}}
        {:ok, ^binding} -> {:ok, binding, owner}
        {:ok, _other} -> {:error, {:fenced, :commit_unknown}, owner}
      end
    else
      _ -> {:error, {:not_committed, :invalid_transaction}, owner}
    end
  end

  @doc false
  @spec observe(t(), Store.transaction(), Store.outcome()) :: t()
  def observe(%__MODULE__{} = owner, transaction, outcome) do
    with {:ok, scope} <- scope(transaction),
         {:ok, binding} <- Store.immutable_binding(transaction),
         {:ok, ^binding} <- Map.fetch(owner.fences, scope),
         {:ok, id} <- Store.transaction_id(transaction) do
      case outcome do
        {:committed, ^id, _receipt} ->
          %{
            owner
            | fences: Map.delete(owner.fences, scope),
              creation_prior: Map.delete(owner.creation_prior, scope)
          }

        {:not_committed, _reason} ->
          case Map.pop(owner.creation_prior, scope) do
            {nil, prior} ->
              %{owner | fences: Map.delete(owner.fences, scope), creation_prior: prior}

            {original, prior} ->
              %{owner | fences: Map.put(owner.fences, scope, original), creation_prior: prior}
          end

        _ ->
          owner
      end
    else
      _ -> owner
    end
  end

  # Concept: only exact retained creation custody may terminate a final ambiguity.
  # Technical depth: Control first joins the old carrier and reads the matching
  # atomic capsule. This pure split replaces only its complete reserve/F fence;
  # close carries both original final bytes and digest, never a changed F.
  @doc false
  def admit_creation_close(owner, %{type: :close_creation_reservation} = close, final) do
    with {:ok, {:runtime_control, runtime} = scope} <- scope(close),
         {:ok, final_binding} <- Store.immutable_binding(final),
         {:ok, close_binding} <- Store.immutable_binding(close),
         true <- final.type == :create_session and final.runtime_id == runtime,
         true <- close.command_id == final.command_id,
         true <- close.final_canonical_record_bytes == final.canonical_record_bytes,
         true <- close.final_canonical_mutation_digest == final.canonical_mutation_digest do
      case Map.fetch(owner.fences, scope) do
        :error ->
          admit(owner, close)

        {:ok, ^close_binding} ->
          admit(owner, close)

        {:ok, ^final_binding} ->
          creation_close_fence(owner, scope, close_binding, final_binding)

        {:ok, %{type: :reserve_creation} = reserve} ->
          if reserve.runtime_id == runtime and reserve.command_id == final.command_id and
               reserve.tx_id == close.reservation_tx_id and reserve.genesis == final.genesis and
               reserve.expected_domain_version + 1 == close.reservation_domain_version,
             do: creation_close_fence(owner, scope, close_binding, reserve),
             else: {:error, {:fenced, :commit_unknown}, owner}

        _ ->
          {:error, {:fenced, :commit_unknown}, owner}
      end
    else
      _ -> {:error, {:not_committed, :invalid_transaction}, owner}
    end
  end

  def admit_creation_close(owner, _close, _final),
    do: {:error, {:not_committed, :invalid_transaction}, owner}

  # Concept: a refused close cannot resolve the original reserve/F ambiguity.
  # Technical depth: this one creation dependency retains the original full fence
  # until close commits. A terminal close refusal restores it; an unknown retains
  # both exact proposals. It creates no separate mutation domain or persistent data.
  defp creation_close_fence(owner, scope, close, original) do
    {:ok, close,
     %{
       owner
       | fences: Map.put(owner.fences, scope, close),
         creation_prior: Map.put(owner.creation_prior, scope, original)
     }}
  end

  defp scope(%{type: type, runtime_id: runtime_id})
       when type in [
              :create_session,
              :claim_creation_domain,
              :reserve_creation,
              :close_creation_reservation
            ] and is_binary(runtime_id),
       do: {:ok, {:runtime_control, runtime_id}}

  defp scope(%{session_id: session_id, mutation_domain: mutation_domain})
       when is_binary(session_id) and is_binary(mutation_domain),
       do: {:ok, {session_id, mutation_domain}}

  defp scope(_transaction), do: {:error, :invalid_scope}
end
