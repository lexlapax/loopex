defmodule Loopex.Store.Transitions do
  @moduledoc """
  ## Concept

  The closed catalogue of durable Store mutations and the stable phases at
  which their fault behavior is exercised. It makes mutation coverage a set
  derived from production declarations rather than a list maintained by a
  separate test.

  ## Technical depth

  Every Store transaction is one of three accepted shapes: runtime-controlled
  session creation, session-owner succession, or an ordinary session commit.
  Each shape exposes the same three phase identities around its one
  linearization point. Adapters validate both identities before invoking a
  fault probe; an unknown transition or phase is refused rather than becoming
  an unobserved mutation path.
  """

  @typedoc """
  ## Concept

  The stable identity of one catalogued Store mutation.

  ## Technical depth

  The closed values correspond one-to-one with the accepted transaction shapes
  and are derived from those shapes before fault dispatch.
  """
  @type transition_id ::
          :runtime_control_create_session
          | :session_journal_advance_owner
          | :session_journal_commit

  @typedoc """
  ## Concept

  A stable observation point around a Store mutation's linearization.

  ## Technical depth

  Every transition declares the same minimum phases: before linearization,
  after linearization before result, and exact recovery re-presentation.
  """
  @type fault_point_id ::
          :before_linearization
          | :after_linearization_before_result
          | :recovery_representation

  @phases [
    :before_linearization,
    :after_linearization_before_result,
    :recovery_representation
  ]

  @catalogue %{
    runtime_control_create_session: @phases,
    session_journal_advance_owner: @phases,
    session_journal_commit: @phases
  }

  @doc """
  ## Concept

  Returns the production transition identity carried by a closed Store
  transaction shape.

  ## Technical depth

  The identity is derived from `:type`; callers cannot supply a second ID that
  disagrees with the transaction they ask the adapter to execute.
  """
  @spec id(map()) :: {:ok, transition_id()} | {:error, :unknown_transaction_type}
  def id(%{type: :create_session}), do: {:ok, :runtime_control_create_session}
  def id(%{type: :advance_owner}), do: {:ok, :session_journal_advance_owner}
  def id(%{type: :session_commit}), do: {:ok, :session_journal_commit}
  def id(_transaction), do: {:error, :unknown_transaction_type}

  @doc """
  ## Concept

  Returns every declared transition and its ordered fault phases.

  ## Technical depth

  The returned map is the production authority used by adapters and by the
  conformance suite's derived injected/observed set equality assertion.
  """
  @spec catalogue() :: %{transition_id() => [fault_point_id()]}
  def catalogue, do: @catalogue

  @doc """
  ## Concept

  Returns the complete set of stable transition/fault-point identities.

  ## Technical depth

  Sorted tuples make equality deterministic across VMs and toolchain pairs;
  no test-owned enumeration participates in the result.
  """
  @spec declared_pairs() :: [{transition_id(), fault_point_id()}]
  def declared_pairs do
    @catalogue
    |> Enum.flat_map(fn {transition, phases} ->
      Enum.map(phases, &{transition, &1})
    end)
    |> Enum.sort()
  end

  @doc """
  ## Concept

  Confirms that a fault checkpoint belongs to the production catalogue.

  ## Technical depth

  Both dimensions are checked together, so a valid phase borrowed from another
  future transition cannot silently certify an undeclared pair.
  """
  @spec validate_pair(term(), term()) :: :ok | {:error, :unknown_fault_point}
  def validate_pair(transition, phase) do
    case Map.fetch(@catalogue, transition) do
      {:ok, phases} ->
        if phase in phases, do: :ok, else: {:error, :unknown_fault_point}

      :error ->
        {:error, :unknown_fault_point}
    end
  end
end
