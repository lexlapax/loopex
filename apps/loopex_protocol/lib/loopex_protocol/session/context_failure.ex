defmodule LoopexProtocol.Session.ContextFailure do
  @moduledoc """
  ## Concept

  Preserve ADR 0043's current context-failure union wherever a run or compact
  result reports it. A configured failure must survive a chat terminal barrier.

  ## Technical depth

  This internal codec shares the existing v2 numeric and preparation alternatives
  between Outcome and CompactResult. It preserves closed fields, scopes, causes,
  unsigned 64-bit quantities and measurement relations. The enclosing codecs
  still own their result shapes, reasons, cleanup and presentation limits.
  """

  @u64 18_446_744_073_709_551_615
  @dimensions ~w(system_class_tokens context_tokens context_record_bytes context_record_depth context_record_cardinality)
  @causes ~w(maintenance_model_unconfigured maintenance_instructions_unconfigured
    maintenance_reasoning_unsupported compaction_excerpt_budget_too_small compaction_no_progress
    compaction_preparation_deadline maintenance_deadline_unrepresentable maintenance_summary_incomplete
    maintenance_summary_invalid maintenance_reply_reserve_unavailable canonical_history_rendering_unsupported artifact_read_unavailable
    artifact_metadata_unrepresentable artifact_preparation_count_exhausted artifact_preparation_bytes_exhausted
    artifact_preparation_deadline artifact_preparation_failed context_projection_invalid)

  @doc false
  @spec project(term(), :encode | :decode) :: {:ok, map()} | :error
  def project(%{"version" => 2, "category" => category} = value, mode)
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

  def project(%{"version" => 2, "category" => "context_preparation_failed"} = value, _) do
    if closed?(value, ~w(version category retryable measurement_scope cause)) and
         value["retryable"] == false and value["measurement_scope"] in [nil, "ordinary"] and
         value["cause"] in @causes do
      {:ok, value}
    else
      :error
    end
  end

  def project(_, _), do: :error

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

  defp closed?(value, keys),
    do: is_map(value) and not is_struct(value) and Enum.sort(Map.keys(value)) == Enum.sort(keys)
end
