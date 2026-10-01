defmodule Loopex.LLM.ReqLLM.ModelCapabilitiesTest do
  use ExUnit.Case, async: true
  alias Loopex.LLM.ReqLLM.ModelCapabilities
  alias LoopexProtocol.Canonical
  @snapshot_id "b78cd916413017210f042b413c715d73180999b194545d1aa7e95a293e837c53"

  test "pinned known limits are captured as closed plain metadata" do
    for {model, context, output, levels} <- [
          {"anthropic:claude-haiku-4-5-20251001", 200_000, 64_000,
           ~w(default none low medium high)},
          {"anthropic:claude-fable-5-1", 1_000_000, 128_000, ~w(default low medium high)},
          {"openai:gpt-4o-mini", 128_000, 16_384, []}
        ] do
      assert {:ok, captured} = ModelCapabilities.capture(model)
      assert captured["model"] == model
      assert captured["context_window"] == context
      assert captured["output_limit"] == output
      assert captured["source_revision"] == "llmdb." <> @snapshot_id
      assert captured["reasoning_levels"] == levels

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

  test "all nine ordinary mappings fit the configuration envelope and preserve exact controls" do
    alias Loopex.Runtime.{Instructions, SessionConfiguration}
    haiku = "anthropic:claude-haiku-4-5-20251001"
    fable = "anthropic:claude-fable-5-1"

    for {model, level, thinking, required} <- [
          {haiku, "default", %{"mode" => "omitted"}, false},
          {haiku, "none", %{"mode" => "disabled"}, false},
          {haiku, "low", %{"mode" => "manual", "budget_tokens" => 1024}, true},
          {haiku, "medium", %{"mode" => "manual", "budget_tokens" => 2048}, true},
          {haiku, "high", %{"mode" => "manual", "budget_tokens" => 4096}, true},
          {fable, "default", %{"mode" => "omitted"}, true},
          {fable, "low", %{"mode" => "adaptive", "effort" => "low", "display" => "summarized"},
           true},
          {fable, "medium",
           %{"mode" => "adaptive", "effort" => "medium", "display" => "summarized"}, true},
          {fable, "high", %{"mode" => "adaptive", "effort" => "high", "display" => "summarized"},
           true}
        ] do
      assert {:ok, capabilities} = ModelCapabilities.capture(model)
      assert {:ok, mapping} = ModelCapabilities.mapping(model, level, 8192)

      assert mapping == %{
               "mapping_revision" =>
                 if(model == haiku,
                   do: "loopex.anthropic.haiku45.v1",
                   else: "loopex.anthropic.fable51.v1"
                 ),
               "renderer_revision" => "loopex.anthropic.native.v1",
               "continuation_required" => required,
               "canonical_terminal_tool_history" => true,
               "thinking_disabled" => level == "none",
               "thinking" => thinking
             }

      declaration = %{
        "model" => model,
        "reasoning" => level,
        "configuration_version" => 1,
        "max_tokens" => 8192,
        "instructions" => Instructions.legacy()
      }

      assert {:ok, configuration} =
               SessionConfiguration.resolve(declaration, capabilities, mapping, [])

      assert configuration["model"] == model and configuration["max_tokens"] == 8192
      assert configuration["context_token_budget"] == capabilities["context_window"] - 8192
      sampling = SessionConfiguration.sampling(configuration)
      assert sampling["provider_mapping"] == mapping
      assert Map.get(sampling, "reasoning", "default") == level
      if level == "default", do: refute(Map.has_key?(sampling, "reasoning"))
    end
  end

  test "mapping selection refuses unsupported levels and never increases a manual allowance" do
    haiku = "anthropic:claude-haiku-4-5-20251001"

    for {level, budget} <- [{"low", 1024}, {"medium", 2048}, {"high", 4096}] do
      assert {:error, :invalid_model_mapping} = ModelCapabilities.mapping(haiku, level, budget)
      assert {:ok, _} = ModelCapabilities.mapping(haiku, level, budget + 1)
    end

    for {model, level, limit} <- [
          {"anthropic:claude-fable-5-1", "none", 8192},
          {haiku, "unsupported", 8192},
          {"openai:gpt-4o-mini", "none", 8192},
          {"anthropic:claude-haiku-latest", "high", 8192},
          {haiku, "default", 0},
          {haiku, "default", 18_446_744_073_709_551_616},
          {nil, "default", 8192}
        ] do
      assert {:error, :invalid_model_mapping} = ModelCapabilities.mapping(model, level, limit)
    end

    assert {:ok, generic} = ModelCapabilities.mapping("openai:m7-unknown-model", "default", 4096)

    assert generic == %{
             "mapping_revision" => "loopex.unregistered.default.v1",
             "renderer_revision" => "loopex.reqllm.canonical.v1",
             "continuation_required" => false,
             "canonical_terminal_tool_history" => false,
             "thinking_disabled" => false,
             "thinking" => %{"mode" => "omitted"}
           }

    assert {:ok, captured} = ModelCapabilities.capture("anthropic:claude-haiku-4-5")

    assert {:ok, %{"thinking_disabled" => true}} =
             ModelCapabilities.mapping(captured["model"], "none", 1024)
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
