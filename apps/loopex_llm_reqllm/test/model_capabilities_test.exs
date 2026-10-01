defmodule Loopex.LLM.ReqLLM.ModelCapabilitiesTest do
  use ExUnit.Case, async: true
  alias Loopex.LLM.ReqLLM.ModelCapabilities
  alias LoopexProtocol.Canonical
  @snapshot_id "b78cd916413017210f042b413c715d73180999b194545d1aa7e95a293e837c53"

  test "pinned known limits are captured as closed plain metadata" do
    for {model, context, output} <- [
          {"anthropic:claude-haiku-4-5-20251001", 200_000, 64_000},
          {"anthropic:claude-fable-5-1", 1_000_000, 128_000},
          {"openai:gpt-4o-mini", 128_000, 16_384}
        ] do
      assert {:ok, captured} = ModelCapabilities.capture(model)
      assert captured["model"] == model
      assert captured["context_window"] == context
      assert captured["output_limit"] == output
      assert captured["source_revision"] == "llmdb." <> @snapshot_id
      assert captured["reasoning_levels"] == []

      assert Enum.sort(Map.keys(captured)) ==
               ~w(context_window model output_limit reasoning_levels source_digest source_revision)

      assert {:ok, size} = Loopex.Store.admit_bounded(captured)
      assert is_integer(size) and size > 0 and size < 2_048
      assert byte_size(Canonical.encode(captured)) < 2_048
      metadata = Map.drop(captured, ~w(source_revision source_digest))

      assert captured["source_digest"] ==
               Canonical.digest(%{
                 "catalog_snapshot_id" => @snapshot_id,
                 "capabilities" => metadata
               })
    end
  end

  test "only the retained literal Haiku alias changes the requested identity" do
    assert {:ok, dated} = ModelCapabilities.capture("anthropic:claude-haiku-4-5-20251001")
    assert ModelCapabilities.capture("anthropic:claude-haiku-4-5") == {:ok, dated}
    assert {:ok, other} = ModelCapabilities.capture("anthropic:claude-haiku-latest")
    assert other["model"] == "anthropic:claude-haiku-latest"
    assert other["context_window"] == nil
    assert other["output_limit"] == nil
  end

  test "unknown limits remain unknown without an invented output guarantee" do
    assert {:ok, captured} = ModelCapabilities.capture("openai:m7-unknown-model")
    assert captured["model"] == "openai:m7-unknown-model"
    assert captured["context_window"] == nil
    assert captured["output_limit"] == nil
    assert captured["reasoning_levels"] == []
    assert {:ok, other} = ModelCapabilities.capture("openai:m7-other-unknown-model")
    refute captured["source_digest"] == other["source_digest"]
  end

  test "malformed or unsupported model specifications refuse before catalog preparation" do
    for model <- [
          nil,
          :model,
          "",
          "openai:",
          ":id",
          "unknown:id",
          <<255>>,
          String.duplicate("x", 513)
        ] do
      assert ModelCapabilities.capture(model) == {:error, :invalid_model_spec}
    end
  end
end
