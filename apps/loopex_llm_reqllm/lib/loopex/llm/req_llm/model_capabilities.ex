defmodule Loopex.LLM.ReqLLM.ModelCapabilities do
  @moduledoc """
  ## Concept

  Capture bounded model limits from the pinned packaged catalog without a
  provider call, credential lookup or mutable catalog refresh. Catalog labels
  do not establish reasoning conformance.

  ## Technical depth

  ADR 0044 names the packaged LLMDB snapshot. This boundary verifies that exact
  snapshot and reads its model limits directly, avoiding runtime catalog filters,
  custom overlays and cold-load effects during inspection. The build embeds the
  dependency snapshot already; no second catalog is retained here. Missing model
  rows or limits remain unknown. Only ADR 0044's literal Haiku alias is rewritten.
  The six-member plain record retains the source revision and canonical digest.
  Its reasoning subset contains only ADR 0044's nine literal cells proved by
  deterministic native transport conformance. Catalog labels do not add cells.
  The same literal mappings serve host resolution and final transport validation;
  mapping validation alone never refreshes the catalog or changes captured data.
  """

  alias Loopex.LLM.ReqLLM.InProcess.Guards
  alias LoopexProtocol.Canonical

  @snapshot_id "b78cd916413017210f042b413c715d73180999b194545d1aa7e95a293e837c53"
  @alias %{"anthropic:claude-haiku-4-5" => "anthropic:claude-haiku-4-5-20251001"}
  @uint64 18_446_744_073_709_551_615
  @haiku "anthropic:claude-haiku-4-5-20251001"
  @fable "anthropic:claude-fable-5-1"
  @levels %{@haiku => ~w(default none low medium high), @fable => ~w(default low medium high)}
  @generic %{
    "mapping_revision" => "loopex.unregistered.default.v1",
    "renderer_revision" => "loopex.reqllm.canonical.v1",
    "continuation_required" => false,
    "canonical_terminal_tool_history" => false,
    "thinking_disabled" => false,
    "thinking" => %{"mode" => "omitted"}
  }

  @doc """
  ## Concept

  Capture declared limits and their source for one explicitly selected model.

  ## Technical depth

  The supported provider grammar precedes catalog access and creates no atoms.
  Packaged snapshot verification is strict independently of the dependency's
  host integrity setting. Invalid catalog data refuses rather than silently
  becoming an unknown limit. Source digest binds snapshot identity, exact model,
  both limits and the verified reasoning subset. This function returns no SDK
  struct, runtime handle, provider module, environment reference or timestamp.
  """
  @spec capture(term()) :: {:ok, map()} | {:error, atom()}
  def capture(model) do
    with {:ok, _} <- Guards.model(model),
         exact <- Map.get(@alias, model, model),
         {:ok, snapshot} <- packaged(),
         {:ok, limits} <- limits(snapshot, exact) do
      metadata = %{
        "model" => exact,
        "context_window" => limits["context_window"],
        "output_limit" => limits["output_limit"],
        "reasoning_levels" => Map.get(@levels, exact, [])
      }

      {:ok,
       metadata
       |> Map.put("source_revision", "llmdb." <> @snapshot_id)
       |> Map.put(
         "source_digest",
         Canonical.digest(%{
           "catalog_snapshot_id" => @snapshot_id,
           "capabilities" => metadata
         })
       )}
    else
      {:error, :unknown_provider} -> {:error, :invalid_model_spec}
      {:error, _} = error -> error
    end
  end

  @doc """
  ## Concept

  Resolve one verified literal model and reasoning level within the selected
  reply allowance. Never enlarge that allowance or substitute another level.

  ## Technical depth

  Host preparation calls capture/1 first to resolve the sole admitted alias and
  retain catalog limits. Transport preflight uses this pure table to verify its
  already captured mapping without reading the catalog. Registered models admit
  only their listed cells; unregistered models admit only the generic default.
  Manual thinking budgets must be strictly smaller than max_tokens. Catalog
  output and context limits remain whole-configuration admission obligations.
  """
  @spec mapping(term(), term(), term()) :: {:ok, map()} | {:error, :invalid_model_mapping}
  def mapping(model, level, max_tokens)
      when is_integer(max_tokens) and max_tokens in 1..@uint64 do
    with {:ok, _} <- Guards.model(model) do
      case Map.fetch(@levels, model) do
        :error when level == "default" ->
          {:ok, @generic}

        {:ok, levels} ->
          if level in levels do
            {thinking, required} = thinking(model, level)

            if max_tokens > Map.get(thinking, "budget_tokens", 0) do
              {:ok,
               %{
                 "mapping_revision" =>
                   if(model == @haiku,
                     do: "loopex.anthropic.haiku45.v1",
                     else: "loopex.anthropic.fable51.v1"
                   ),
                 "renderer_revision" => "loopex.anthropic.native.v1",
                 "continuation_required" => required,
                 "canonical_terminal_tool_history" => true,
                 "thinking_disabled" => thinking == %{"mode" => "disabled"},
                 "thinking" => thinking
               }}
            else
              {:error, :invalid_model_mapping}
            end
          else
            {:error, :invalid_model_mapping}
          end

        _ ->
          {:error, :invalid_model_mapping}
      end
    else
      _ -> {:error, :invalid_model_mapping}
    end
  end

  def mapping(_, _, _), do: {:error, :invalid_model_mapping}

  defp thinking(@haiku, "default"), do: {%{"mode" => "omitted"}, false}
  defp thinking(@haiku, "none"), do: {%{"mode" => "disabled"}, false}

  defp thinking(@haiku, level),
    do:
      {%{
         "mode" => "manual",
         "budget_tokens" => %{"low" => 1_024, "medium" => 2_048, "high" => 4_096}[level]
       }, true}

  defp thinking(@fable, "default"), do: {%{"mode" => "omitted"}, true}

  defp thinking(@fable, level),
    do: {%{"mode" => "adaptive", "effort" => level, "display" => "summarized"}, true}

  defp packaged do
    case LLMDB.Packaged.snapshot() do
      %{"snapshot_id" => @snapshot_id} = snapshot ->
        case LLMDB.Snapshot.verify(snapshot) do
          :ok -> {:ok, snapshot}
          _ -> {:error, :model_catalog_unavailable}
        end

      _ ->
        {:error, :model_catalog_unavailable}
    end
  rescue
    _ -> {:error, :model_catalog_unavailable}
  catch
    _, _ -> {:error, :model_catalog_unavailable}
  end

  defp limits(snapshot, model) do
    [provider, id] = String.split(model, ":", parts: 2)
    row = get_in(snapshot, ["providers", provider, "models", id])
    limits = if is_nil(row), do: %{}, else: Map.get(row, "limits") || %{}

    if is_map(limits) and valid_limit?(limits["context"]) and valid_limit?(limits["output"]) do
      {:ok, %{"context_window" => limits["context"], "output_limit" => limits["output"]}}
    else
      {:error, :invalid_model_capabilities}
    end
  end

  defp valid_limit?(nil), do: true
  defp valid_limit?(value), do: is_integer(value) and value > 0 and value <= @uint64
end
