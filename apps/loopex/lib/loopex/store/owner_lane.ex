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
  preserves it. Workstream B is responsible for retaining this value in the
  coordinator and putting downstream eligibility decisions behind it.
  """

  alias Loopex.Store

  @typedoc """
  ## Concept

  Explicit runtime-local mutation admission state for one Store owner.

  ## Technical depth

  The map can contain a Store handle and therefore is never durable or public
  data. Coordinators retain it in their own serial process state.
  """
  @opaque t :: %__MODULE__{store: Store.t(), fences: map()}
  defstruct [:store, fences: %{}]

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
    with {:ok, scope} <- scope(transaction),
         {:ok, binding} <- Store.immutable_binding(transaction) do
      case Map.fetch(owner.fences, scope) do
        :error ->
          call(owner, scope, binding, transaction)

        {:ok, ^binding} ->
          call(owner, scope, binding, transaction)

        {:ok, _other_binding} ->
          {{:fenced, :commit_unknown}, owner}
      end
    else
      _invalid -> {{:not_committed, :invalid_transaction}, owner}
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

  defp call(owner, scope, binding, transaction) do
    outcome = Store.transact(owner.store, transaction)

    next =
      case outcome do
        {:commit_unknown, _tx_id} ->
          %{owner | fences: Map.put(owner.fences, scope, binding)}

        {:committed, _tx_id, _receipt} ->
          %{owner | fences: Map.delete(owner.fences, scope)}

        {:not_committed, _reason} ->
          %{owner | fences: Map.delete(owner.fences, scope)}
      end

    {outcome, next}
  end

  defp scope(%{type: :create_session, runtime_id: runtime_id}) when is_binary(runtime_id),
    do: {:ok, {:runtime_control, runtime_id}}

  defp scope(%{session_id: session_id, mutation_domain: mutation_domain})
       when is_binary(session_id) and is_binary(mutation_domain),
       do: {:ok, {session_id, mutation_domain}}

  defp scope(_transaction), do: {:error, :invalid_scope}
end
