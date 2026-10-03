defmodule Loopex.Executor.Local.SearchProjectionGenerationTest do
  use ExUnit.Case, async: true

  alias Loopex.Executor.Local.CodingTools
  alias LoopexProtocol.ToolDefinition

  test "current search definitions keep their literal canonical bytes and digests" do
    vectors =
      Path.expand("../../loopex/priv/vectors/search_projection.v1.json", __DIR__)
      |> File.read!()
      |> JSON.decode!()
      |> Map.fetch!("vectors")

    assert length(vectors) == 3
    actual = CodingTools.definitions() |> Enum.map(&ToolDefinition.normalize/1)

    for vector <- vectors do
      definition = vector["definition"]
      assert definition in actual
      assert ToolDefinition.valid?(definition)

      assert ToolDefinition.canonical_bytes(definition) ==
               Base.decode64!(vector["canonical_bytes_base64"])

      assert ToolDefinition.definition_digest(definition) == vector["definition_digest"]
      assert definition["budgets"]["output_bytes"] == 16_384

      assert definition["budgets"]["artifact_bytes"] == 16_384
      assert definition["tool_version"] == "1.1.0"
    end

    current =
      CodingTools.definitions()
      |> Enum.filter(&(&1["tool_id"] in ~w(loopex.grep loopex.find loopex.ls)))

    assert length(current) == 3
    assert Enum.all?(current, &(&1["tool_version"] == "1.1.0"))
  end
end
