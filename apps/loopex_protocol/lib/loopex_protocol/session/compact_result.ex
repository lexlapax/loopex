defmodule LoopexProtocol.Session.CompactResult do
  @moduledoc """
  ## Concept

  Encode the completed standalone compaction result for chat and public session
  projections. A maintenance command has its own result, without a run outcome.

  ## Technical depth

  ADR 0043 fixes the five-member result, closed failure alternatives and exact
  usage accounting. Native input uses binary keys and integer quantities; wire
  output uses canonical decimal strings and opaque base64url checkpoint IDs.
  Validation checks structure and numeric relations, not committed completion.
  The enclosing transport owns the presentation ceiling. No input creates atoms.
  """

  alias LoopexProtocol.Wire
  @u64 18_446_744_073_709_551_615
  @dimensions ~w(system_class_tokens context_tokens context_record_bytes context_record_depth context_record_cardinality)
  @causes ~w(maintenance_model_unconfigured maintenance_instructions_unconfigured
    maintenance_reasoning_unsupported compaction_excerpt_budget_too_small compaction_no_progress
    compaction_preparation_deadline maintenance_deadline_unrepresentable maintenance_summary_incomplete
    maintenance_summary_invalid canonical_history_rendering_unsupported artifact_read_unavailable
    artifact_metadata_unrepresentable artifact_preparation_count_exhausted artifact_preparation_bytes_exhausted
    artifact_preparation_deadline artifact_preparation_failed context_projection_invalid)

  @doc """
  ## Concept

  Project a closed native result without losing integer or identity bytes.

  ## Technical depth

  Success requires confirmed cleanup and null failure. Failed results require a
  failure and may retain a partial checkpoint. Usage total must equal reported
  plus estimated tokens. Missing, extra, malformed and non-plain members refuse.
  """
  @spec encode_wire(term()) :: {:ok, map()} | :error
  def encode_wire(value), do: project(value, :encode)

  @doc """
  ## Concept

  Recover exact native quantities and identities from the wire result.

  ## Technical depth

  Decimal JSON numbers, noncanonical spellings, padded identities and unknown
  failure variants refuse. Decoding spends no authority and admits no command.
  """
  @spec decode_wire(term()) :: {:ok, map()} | :error
  def decode_wire(value), do: project(value, :decode)

  defp project(value, mode) do
    with true <- closed?(value, ~w(disposition checkpoint_id failure usage cleanup)),
         true <- value["disposition"] in ~w(checkpointed unchanged failed),
         true <- value["cleanup"] in ~w(confirmed unknown),
         {:ok, checkpoint} <- identity(value["checkpoint_id"], mode),
         true <- disposition?(value, checkpoint),
         {:ok, failure} <- failure(value["failure"], mode),
         {:ok, usage} <- usage(value["usage"], mode) do
      {:ok,
       Map.merge(value, %{"checkpoint_id" => checkpoint, "failure" => failure, "usage" => usage})}
    else
      _ -> :error
    end
  end

  defp disposition?(%{"disposition" => "failed", "failure" => failure}, _), do: failure != nil

  defp disposition?(
         %{"disposition" => disposition, "failure" => nil, "cleanup" => "confirmed"},
         checkpoint
       ),
       do: if(disposition == "checkpointed", do: checkpoint != nil, else: checkpoint == nil)

  defp disposition?(_, _), do: false

  defp usage(value, mode) do
    keys = ~w(attempts reported_tokens estimated_tokens total_tokens)

    with true <- closed?(value, keys),
         {:ok, converted, native} <- quantities(value, keys, mode, []),
         true <- native["total_tokens"] == native["reported_tokens"] + native["estimated_tokens"] do
      {:ok, converted}
    end
  end

  defp failure(nil, _), do: {:ok, nil}

  defp failure(%{"category" => category} = value, _mode)
       when category in ~w(model_call_failed cancelled) do
    if closed?(value, ~w(category retryable)) and value["retryable"] == false,
      do: {:ok, value},
      else: :error
  end

  defp failure(%{"category" => "bound_reached"} = value, mode) do
    with true <-
           closed?(value, ~w(category retryable bound observed declared_limit accounting_source)),
         false <- value["retryable"],
         true <- value["bound"] in ~w(max_attempts deadline_ms token_budget),
         true <- value["accounting_source"] in [nil, "reported", "estimated"],
         true <- value["bound"] != "max_attempts" or value["accounting_source"] == nil,
         ceiling <- if(value["bound"] == "deadline_ms", do: @u64),
         {:ok, converted, native} <-
           quantities(value, ~w(observed declared_limit), mode, ceiling: ceiling),
         true <- native["declared_limit"] > 0 do
      {:ok, converted}
    end
  end

  defp failure(%{"version" => 2, "category" => category} = value, mode)
       when category in ~w(context_budget_exceeded thinking_exchange_headroom) do
    with true <-
           closed?(
             value,
             ~w(version category retryable measurement_scope dimension observed limit hard_limit)
           ),
         false <- value["retryable"],
         true <- value["measurement_scope"] in ~w(ordinary maintenance),
         true <- value["dimension"] in @dimensions,
         {:ok, converted, native} <-
           quantities(value, ~w(observed limit hard_limit), mode, ceiling: @u64),
         true <- native["limit"] > 0 and native["hard_limit"] > 0,
         true <- native["dimension"] != "context_record_bytes" or native["hard_limit"] == 65_536,
         true <- numeric_failure?(native) do
      {:ok, converted}
    end
  end

  defp failure(%{"version" => 2, "category" => "context_preparation_failed"} = value, _) do
    if closed?(value, ~w(version category retryable measurement_scope cause)) and
         value["retryable"] == false and value["measurement_scope"] in [nil, "ordinary"] and
         value["cause"] in @causes, do: {:ok, value}, else: :error
  end

  defp failure(_, _), do: :error

  defp numeric_failure?(%{"category" => "thinking_exchange_headroom"} = value),
    do:
      value["dimension"] in ~w(context_tokens context_record_bytes) and
        value["limit"] <= value["hard_limit"] and value["observed"] > value["limit"]

  defp numeric_failure?(value),
    do:
      value["limit"] == value["hard_limit"] and
        if(value["dimension"] == "system_class_tokens",
          do: value["observed"] >= value["limit"],
          else: value["observed"] > value["limit"]
        )

  defp quantities(value, keys, mode, options) do
    Enum.reduce_while(keys, {:ok, value, value}, fn key, {:ok, converted, native} ->
      case quantity(value[key], mode, Keyword.get(options, :ceiling)) do
        {:ok, wire_value, integer} ->
          {:cont, {:ok, Map.put(converted, key, wire_value), Map.put(native, key, integer)}}

        _ ->
          {:halt, :error}
      end
    end)
  end

  defp quantity(value, :encode, ceiling) when is_integer(value) and value >= 0 do
    if ceiling == nil or value <= ceiling,
      do: {:ok, Integer.to_string(value), value},
      else: :error
  end

  defp quantity(value, :decode, ceiling) when is_binary(value) do
    if Regex.match?(~r/\A(?:0|[1-9][0-9]*)\z/, value) do
      integer = String.to_integer(value)
      if ceiling == nil or integer <= ceiling, do: {:ok, integer, integer}, else: :error
    else
      :error
    end
  end

  defp quantity(_, _, _), do: :error

  defp identity(nil, _), do: {:ok, nil}

  defp identity(value, :encode) when is_binary(value) and byte_size(value) in 1..65_536,
    do: {:ok, Wire.encode_identity(value)}

  defp identity(value, :decode) when is_binary(value) do
    with {:ok, decoded} <- Wire.identity(value),
         true <- Wire.encode_identity(decoded) == value,
         do: {:ok, decoded},
         else: (_ -> :error)
  end

  defp identity(_, _), do: :error

  defp closed?(value, keys),
    do: is_map(value) and not is_struct(value) and Enum.sort(Map.keys(value)) == Enum.sort(keys)
end
