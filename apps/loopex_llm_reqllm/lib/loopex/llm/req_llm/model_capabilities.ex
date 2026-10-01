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
  Its reasoning subset is empty until deterministic adapter conformance registers
  mapping rows; neither a catalog reasoning label nor an alias enables a level.
  """

  alias Loopex.LLM.ReqLLM.InProcess.Guards
  alias LoopexProtocol.Canonical

  @snapshot_id "b78cd916413017210f042b413c715d73180999b194545d1aa7e95a293e837c53"
  @alias %{"anthropic:claude-haiku-4-5" => "anthropic:claude-haiku-4-5-20251001"}
  @uint64 18_446_744_073_709_551_615

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
        "reasoning_levels" => []
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
