defmodule LoopexComposition.DelegationToolTest do
  use ExUnit.Case, async: true
  alias LoopexComposition.Delegation.Tool
  alias LoopexProtocol.ToolDefinition

  test "the opt-in helper is one effect generation with explicit fixed ceilings" do
    definition = Tool.definition()
    assert ToolDefinition.validate(definition) == []
    assert ToolDefinition.class(definition) == "effect"
    assert definition["tool_id"] == "loopex.task"
    assert definition["tool_version"] == "1.0.0"
    assert definition["effect_class"] == "external_effect"
    assert definition["idempotency_class"] == "reconcile_then_retry"

    assert definition["budgets"] == %{
             "wall_time_ms" => 600_000,
             "output_bytes" => 32_768,
             "artifact_bytes" => 8_388_608
           }

    assert definition["parameter_schema"]["required"] == ~w(role description prompt)
    refute Map.has_key?(definition["parameter_schema"]["properties"]["role"], "enum")

    refute Enum.any?(
             LoopexComposition.DurableOptions.definitions([]),
             &(&1["tool_id"] == "loopex.task")
           )
  end

  test "closed helper arguments preserve exact UTF-8 byte limits without granting catalog membership" do
    maximal = %{
      "role" => "r" <> String.duplicate("x", 63),
      "description" => String.duplicate("é", 128),
      "prompt" => String.duplicate("猫", 5461) <> "x"
    }

    assert byte_size(maximal["prompt"]) == 16_384
    assert Tool.validate_arguments(maximal) == :ok
    assert ToolDefinition.validate_arguments(Tool.definition(), maximal) == :ok

    assert Tool.validate_arguments(%{
             "role" => "unlisted_role",
             "description" => "task",
             "prompt" => "inspect"
           }) == :ok

    for {key, value} <- [
          {"role", "R"},
          {"role", "a/role"},
          {"role", "r" <> String.duplicate("x", 64)},
          {"description", ""},
          {"description", maximal["description"] <> "x"},
          {"description", <<255>>},
          {"prompt", ""},
          {"prompt", maximal["prompt"] <> "x"},
          {"prompt", <<255>>},
          {"model", "injected"}
        ] do
      assert Tool.validate_arguments(Map.put(maximal, key, value)) ==
               {:error, :invalid_tool_arguments}
    end

    for key <- Map.keys(maximal),
        do:
          assert(
            Tool.validate_arguments(Map.delete(maximal, key)) == {:error, :invalid_tool_arguments}
          )

    for value <- [nil, [], %URI{}, %{role: "r", description: "task", prompt: "p"}],
        do: assert(Tool.validate_arguments(value) == {:error, :invalid_tool_arguments})
  end
end
