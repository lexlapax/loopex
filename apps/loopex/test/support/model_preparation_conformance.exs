defmodule Loopex.ModelPreparationConformance do
  @moduledoc false
  import ExUnit.Assertions
  alias Loopex.Runtime.SessionConfiguration

  def assert_context(context, grace) do
    assert Enum.sort(Map.keys(context)) == [:cleanup_grace_ms, :deadline_monotonic_ms]
    assert context.cleanup_grace_ms == grace
    assert is_integer(context.deadline_monotonic_ms)
    remaining = context.deadline_monotonic_ms - System.monotonic_time(:millisecond)
    assert remaining > 0 and remaining <= 60_000
  end

  def candidate(current, authored, definitions, canonical) do
    effective =
      if Map.has_key?(authored, "model"),
        do: Map.put(authored, "model", canonical),
        else: authored

    capabilities = Map.put(current["model_capabilities"], "model", canonical)

    SessionConfiguration.update(
      current,
      effective,
      capabilities,
      current["provider_mapping"],
      definitions
    )
  end
end
