Code.require_file("support/configured_genesis_helper.exs", __DIR__)

defmodule Loopex.Runtime.SessionConfigurationUpdateTest do
  use ExUnit.Case, async: true

  alias Loopex.ConfiguredGenesisFixture
  alias Loopex.Runtime.Instructions
  alias Loopex.Runtime.SessionConfiguration
  alias LoopexProtocol.ToolDefinition

  test "reply reserve changes recompute derived input with the captured window" do
    current = known_configuration()
    assert {:ok, next} = update(current, %{"max_tokens" => 2_048})
    assert next["configuration_version"] == 2
    assert next["max_tokens"] == 2_048
    assert next["context_token_budget"] == 14_336
    assert next["budget_origins"]["context_token_budget"] == "model_window"
    assert next["instructions"] == current["instructions"]
    assert current["configuration_version"] == 1
    assert current["context_token_budget"] == 15_360
  end

  test "explicit ceilings retain exact values and origins across model and reserve changes" do
    current =
      known_configuration()
      |> Map.put("context_token_budget", 8_192)
      |> put_in(["budget_origins", "context_token_budget"], "explicit")

    capabilities = %{
      current["model_capabilities"]
      | "model" => "other:v2",
        "context_window" => 32_768
    }

    assert {:ok, next} =
             SessionConfiguration.update(
               current,
               %{"model" => "other:v2", "max_tokens" => 2_048},
               capabilities,
               current["provider_mapping"],
               []
             )

    assert next["context_token_budget"] == 8_192
    assert next["system_class_tokens"] == 5_000

    assert next["budget_origins"] == %{
             "context_token_budget" => "explicit",
             "system_class_tokens" => "explicit"
           }

    assert next["model_capabilities"] == capabilities
    assert next["model"] == "other:v2"
  end

  test "known to unknown and unknown to known selection recomputes derived budgets" do
    known = known_configuration()

    unknown_capabilities = %{
      known["model_capabilities"]
      | "model" => "unknown:v1",
        "context_window" => nil,
        "output_limit" => nil
    }

    assert {:ok, unknown} =
             SessionConfiguration.update(
               known,
               %{"model" => "unknown:v1", "max_tokens" => 9_000},
               unknown_capabilities,
               known["provider_mapping"],
               []
             )

    assert unknown["context_token_budget"] == 8_192
    assert unknown["budget_origins"]["context_token_budget"] == "unknown_window"

    assert {:ok, restored} =
             SessionConfiguration.update(
               unknown,
               %{"model" => known["model"], "max_tokens" => 1_024},
               known["model_capabilities"],
               known["provider_mapping"],
               []
             )

    assert restored["context_token_budget"] == 15_360
    assert restored["budget_origins"]["context_token_budget"] == "model_window"
    assert restored["configuration_version"] == 3
  end

  test "explicit default-valued replacements remain explicit on later updates" do
    current = ConfiguredGenesisFixture.configuration()

    assert {:ok, next} =
             update(current, %{"context_token_budget" => 8_192, "system_class_tokens" => 1_000})

    assert next["budget_origins"] == %{
             "context_token_budget" => "explicit",
             "system_class_tokens" => "explicit"
           }

    assert {:ok, later} = update(next, %{"max_tokens" => 2_048})
    assert later["context_token_budget"] == 8_192
    assert later["system_class_tokens"] == 1_000
    assert later["budget_origins"] == next["budget_origins"]
  end

  test "a legacy system default remains derived when another setting changes" do
    current = ConfiguredGenesisFixture.configuration()

    current = %{
      current
      | "system_class_tokens" => 1_000,
        "budget_origins" => %{
          current["budget_origins"]
          | "system_class_tokens" => "legacy_default"
        }
    }

    assert {:ok, next} = update(current, %{"max_tokens" => 2_048})
    assert next["system_class_tokens"] == 1_000
    assert next["budget_origins"]["system_class_tokens"] == "legacy_default"
  end

  test "captured instruction replacement is exact and validates the entire selected system class" do
    current = ConfiguredGenesisFixture.configuration()

    {:ok, instructions} =
      Instructions.capture(%{
        "version" => "host.v2",
        "base" => "Changed instructions",
        "environment" => "exact host frame",
        "appendix" => "é"
      })

    definition = ToolDefinition.question_definition()
    assert {:ok, next} = update(current, %{"instructions" => instructions}, [definition])
    assert next["instructions"] == instructions
    assert next["configuration_version"] == 2

    assert update(current, %{"instructions" => instructions, "system_class_tokens" => 1}, [
             definition
           ]) == {:error, :invalid_session_configuration}

    assert current["instructions"] != instructions
  end

  test "every supplied mutable value is validated and internal facts cannot be authored" do
    current = ConfiguredGenesisFixture.configuration()

    for changes <- [
          %{},
          nil,
          [],
          %{max_tokens: 512},
          %{"model" => ""},
          %{"reasoning" => "automatic"},
          %{"instructions" => %{}},
          %{"max_tokens" => 0},
          %{"context_token_budget" => -1},
          %{"system_class_tokens" => "1000"},
          %{"max_tokens" => 512, "reasoning" => "bad"},
          %{"configuration_version" => 2},
          %{"model_capabilities" => current["model_capabilities"]},
          %{"provider_mapping" => current["provider_mapping"]},
          %{"tools" => []},
          %{"maintenance_model" => "other:v2"},
          %{"model" => String.duplicate("x", 65_536)},
          %{"model" => <<255>>},
          %{"max_tokens" => 18_446_744_073_709_551_616}
        ] do
      assert update(current, changes) == {:error, :invalid_configuration_update}
    end
  end

  test "whole-candidate refusal retains prior settings for limit, mapping and version failures" do
    current = known_configuration()

    for changes <- [
          %{"max_tokens" => 4_097},
          %{"context_token_budget" => 15_361},
          %{"system_class_tokens" => 15_361},
          %{"reasoning" => "high"}
        ] do
      assert update(current, changes) == {:error, :invalid_session_configuration}
    end

    assert SessionConfiguration.update(
             current,
             %{"model" => "other:v2"},
             current["model_capabilities"],
             current["provider_mapping"],
             []
           ) == {:error, :invalid_session_configuration}

    exhausted = %{current | "configuration_version" => 18_446_744_073_709_551_615}
    assert update(exhausted, %{"max_tokens" => 512}) == {:error, :invalid_session_configuration}
    assert current == known_configuration()
  end

  defp known_configuration do
    current = ConfiguredGenesisFixture.configuration()

    %{
      current
      | "context_token_budget" => 15_360,
        "budget_origins" => %{
          current["budget_origins"]
          | "context_token_budget" => "model_window"
        },
        "model_capabilities" => %{
          current["model_capabilities"]
          | "context_window" => 16_384,
            "output_limit" => 4_096
        }
    }
  end

  defp update(current, changes, definitions \\ []),
    do:
      SessionConfiguration.update(
        current,
        changes,
        current["model_capabilities"],
        current["provider_mapping"],
        definitions
      )
end
