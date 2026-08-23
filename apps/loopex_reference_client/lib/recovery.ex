defmodule Loopex.ReferenceClient.Recovery do
  @moduledoc """
  ## Concept

  Constructs one response to a recovery query already solicited by the current
  runtime. It can present a retained executor receipt or state that the caller
  has insufficient evidence; it never dispatches an effect.

  ## Technical depth

  The complete current-query and retained-origin bindings are copied from the
  runtime query. The receipt remains nested evidence. `outcome_unknown/1` is the
  explicit `no_blind_retry_without_receipt` transition: absence produces a
  terminal recovery response and provides no executor callback or job payload
  from which a retry could be started.
  """

  @fields [
    :reconciliation_query_id,
    :current_session_epoch,
    :expected_executor_identity,
    :current_recovery_contract,
    :journaled_operation_id,
    :original_attempt,
    :journaled_canonical_request_digest,
    :original_session_epoch,
    :original_executor_epoch,
    :origin_executor_identity,
    :origin_fencing_token
  ]

  @doc """
  ## Concept

  Answers the current query with one retained terminal executor receipt.

  ## Technical depth

  The runtime independently validates every copied binding and the nested
  receipt; constructing this plain response grants no admission authority.
  """
  @spec receipt(map(), map()) :: map()
  def receipt(query, retained_receipt) when is_map(query) and is_map(retained_receipt) do
    query
    |> Map.take(@fields)
    |> Map.merge(%{evidence: "receipt", retained_receipt: retained_receipt})
  end

  @doc """
  ## Concept

  Answers that an effect may have occurred but no provable receipt exists.

  ## Technical depth

  This is the named `no_blind_retry_without_receipt` mechanism. It constructs
  only `outcome_unknown` evidence and carries no dispatchable request.
  """
  @spec outcome_unknown(map()) :: map()
  def outcome_unknown(query) when is_map(query) do
    query
    |> Map.take(@fields)
    |> Map.put(:evidence, "outcome_unknown")
  end
end
