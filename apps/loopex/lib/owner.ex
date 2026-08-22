defmodule Loopex.Owner do
  @moduledoc """
  ## Concept

  The current-owner consequence fence. A Store result describes durable truth,
  but only the exact coordinator generation presently routed by runtime control
  may turn that result into current cache, publication eligibility, pending work,
  or any later authority-sensitive action.

  ## Technical depth

  Runtime control calls `current_owner_post_commit_fence/2` while serializing
  both owner replacement and post-commit installation. The comparison includes
  the runtime-local generation plus the Store-bound owner epoch and incarnation.
  It performs no Store read: the Store already enforced the commit-time compare,
  and this function answers the different question of whether the reply's
  originator is still the runtime's current routed owner.

  This small artifact is deliberately the independently mutable mechanism for
  M1's `current_owner_post_commit_fence` negative demonstration.
  """

  @typedoc """
  ## Concept

  The minimum runtime-control view needed to admit a consequence.

  ## Technical depth

  Only `:active` with an exact owner map passes. Pids, Store handles, reducer
  state, and consequence payloads are outside this pure comparison.
  """
  @type current :: %{required(:status) => atom(), optional(:owner) => map()}

  @doc """
  ## Concept

  Admits consequences only for the exact current owner.

  ## Technical depth

  Changed generation, epoch, incarnation, missing state, acquisition, and
  unavailability all fail closed as `:superseded_owner`.
  """
  @spec current_owner_post_commit_fence(current() | term(), map()) ::
          :ok | {:error, :superseded_owner}
  def current_owner_post_commit_fence(%{status: :active, owner: owner}, owner), do: :ok

  def current_owner_post_commit_fence(_current, _candidate),
    do: {:error, :superseded_owner}
end
