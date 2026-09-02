@doc false
@spec propose_context_refusal(t(), binary(), map()) :: {:ok, proposal()} | {:error, term()}
def propose_context_refusal(%__MODULE__{} = state, run_id, refusal)
    when is_binary(run_id) and is_map(refusal) do
  terminal =
    state
    |> run_terminal_record(run_id, "failed", %{})
    |> Map.put("failure", context_failure(refusal))

  internal_proposal(
    state,
    stable_id("context-refusal", run_id, Map.fetch!(refusal, "turn_id")),
    [refusal, terminal]
  )
end

# Concept: the four fields an operator can act on, plus the one fact that
# makes the ending final.
#
# Technical depth: ADR 0017 fixes this projection at exactly five members and
# makes it exclusive to a failed context terminal. It copies the refusal's own
# committed observations rather than deriving new ones, so the private
# terminal, the public event, and the retained receipt cannot disagree.
defp context_failure(refusal) do
  %{
    "category" => Map.fetch!(refusal, "category"),
    "retryable" => false,
    "dimension" => Map.fetch!(refusal, "dimension"),
    "observed" => Map.fetch!(refusal, "observed"),
    "limit" => Map.fetch!(refusal, "limit")
  }
end

# Concept: applying the refusal row alone changes nothing durable.
#
# Technical depth: ADR 0017 makes the refusal and its terminal one semantic
# unit spread over two consecutive journal rows. The first row installs only a
# transient marker: no run state moves, no event is emitted, no queue
# resolves, and nothing is dispatched. A pagination boundary between the two
# rows is legitimate and carries the marker into the next fetch. Reaching the
# durable head with the marker still pending, or observing any intervening,
# duplicated, or mismatched row, is invalid incomplete history.
defp apply_internal_record(state, %{kind: "context_admission_refused_v1"} = refusal) do
  with :ok <- validate_context_refusal(state, refusal) do
    {:ok, %{state | context_refusal: refusal}, []}
  end
end

defp validate_context_refusal(state, refusal) do
  run_id = Map.get(refusal, "run_id")
  work = Map.get(state.pending_work, run_id)

  with true <- Enum.sort(Map.keys(refusal)) == @context_refusal_keys,
       true <- run_id == state.active_run_id,
       %{stage: stage} <- work,
       true <- stage in ["model_pending", "turn_settled"],
       true <- Map.get(refusal, "turn_id") == stable_id("turn", run_id, next_turn_number(work)),
       true <- Map.get(refusal, "category") == "context_budget_exceeded",
       true <- Map.get(refusal, "token_estimator") == Bounds.estimator(),
       true <-
         Map.get(refusal, "descriptor_canonicalization_version") ==
           @descriptor_canonicalization_version,
       true <- Map.get(refusal, "context_record_byte_ceiling") == Store.max_item_bytes(),
       true <- Map.get(refusal, "context_token_budget") == Map.get(state.context_budgets, run_id),
       true <- Map.get(refusal, "project_disposition") in @context_project_dispositions,
       true <- valid_descriptor_counts?(refusal),
       true <- valid_context_dimension?(refusal) do
    :ok
  else
    _invalid -> {:error, :invalid_context_refusal}
  end
end

defp valid_descriptor_counts?(refusal) do
  Enum.all?(
    ~w(system_message_count session_message_count steer_message_count tool_definition_count
         provider_estimated_tokens),
    &(is_integer(Map.get(refusal, &1)) and Map.get(refusal, &1) >= 0)
  ) and is_binary(Map.get(refusal, "ordered_descriptor_digest"))
end

# Concept: each dimension admits only the relations its own preimage makes
# derivable.
#
# Technical depth: recovery has no descriptor bodies and no rejected candidate
# from which to recompute a refusal, so it validates the relations that hold
# by construction and treats the rest as committed observations the Store
# transaction digest already protects. `record_byte_cost` is non-nil for the
# byte dimension alone, because the token and structural dimensions are
# decided before any record is constructed.
defp valid_context_dimension?(%{
       "dimension" => "context_tokens",
       "observed" => observed,
       "limit" => limit,
       "provider_estimated_tokens" => estimated,
       "context_token_budget" => budget,
       "record_byte_cost" => nil
     }),
     do: observed == estimated and limit == budget and observed > limit

defp valid_context_dimension?(%{
       "dimension" => "context_record_bytes",
       "observed" => observed,
       "limit" => limit,
       "record_byte_cost" => cost
     }),
     do: observed == cost and limit == 65_536 and observed > limit

defp valid_context_dimension?(%{
       "dimension" => "context_record_depth",
       "observed" => observed,
       "limit" => limit,
       "record_byte_cost" => nil
     }),
     do: observed == 13 and limit == 12

defp valid_context_dimension?(%{
       "dimension" => "context_record_cardinality",
       "observed" => observed,
       "limit" => limit,
       "record_byte_cost" => nil
     }),
     do: observed == 1_025 and limit == 1_024

defp valid_context_dimension?(%{
       "dimension" => "system_class_tokens",
       "observed" => observed,
       "limit" => limit,
       "provider_estimated_tokens" => estimated,
       "record_byte_cost" => nil
     }),
     do: limit == 1_000 and observed >= limit and observed <= estimated

defp valid_context_dimension?(_refusal), do: false
