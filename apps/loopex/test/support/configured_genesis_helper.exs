defmodule Loopex.ConfiguredGenesisFixture do
  @moduledoc false

  alias Loopex.Runtime.Instructions
  alias Loopex.Runtime.SessionGenesis
  alias LoopexProtocol.ToolDefinition

  def configuration(base \\ "Follow the host's captured instructions.") do
    {:ok, instructions} =
      Instructions.capture(%{
        "version" => "host.v1",
        "base" => base,
        "environment" => "captured environment",
        "appendix" => ""
      })

    %{
      "model" => "scripted:v1",
      "reasoning" => "default",
      "configuration_version" => 1,
      "instructions" => instructions,
      "max_tokens" => 1_024,
      "context_token_budget" => 8_192,
      "system_class_tokens" => 5_000,
      "budget_origins" => %{
        "context_token_budget" => "unknown_window",
        "system_class_tokens" => "explicit"
      },
      "model_capabilities" => %{
        "model" => "scripted:v1",
        "context_window" => nil,
        "output_limit" => nil,
        "reasoning_levels" => [],
        "source_revision" => "fixture.v1",
        "source_digest" => String.duplicate("0", 64)
      },
      "provider_mapping" => %{
        "mapping_revision" => "loopex.unregistered.default.v1",
        "renderer_revision" => "loopex.reqllm.canonical.v1",
        "continuation_required" => false,
        "canonical_terminal_tool_history" => false,
        "thinking_disabled" => false,
        "thinking" => %{"mode" => "omitted"}
      }
    }
  end

  def genesis(definitions, configuration \\ configuration()) do
    names =
      Map.new(definitions, fn definition ->
        {id, version, digest} = ToolDefinition.generation(definition)

        {definition["name"],
         %{"tool_id" => id, "tool_version" => version, "definition_digest" => digest}}
      end)

    {:ok, genesis} =
      SessionGenesis.resolve(%{}, %{
        genesis_version: "session_genesis_v3",
        runtime_configuration: %{"cleanup_grace_ms" => 5_000},
        initial_configuration: configuration,
        tool_selection: %{"definitions" => definitions, "names" => names},
        policy_defer_mode: "admit"
      })

    genesis
  end
end
