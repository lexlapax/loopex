defmodule Loopex.Executor.Local.SearchProjectionGenerationTest do
  use ExUnit.Case, async: true

  alias Loopex.Executor.Local.CodingTools
  alias LoopexProtocol.ToolDefinition

  test "old and M7 search definitions keep their literal canonical bytes and digests" do
    vectors =
      Path.expand("../../loopex/priv/vectors/search_projection.v1.json", __DIR__)
      |> File.read!()
      |> JSON.decode!()
      |> Map.fetch!("vectors")

    assert length(vectors) == 6
    actual = CodingTools.generations() |> Enum.map(&ToolDefinition.normalize/1)

    for vector <- vectors do
      definition = vector["definition"]
      assert definition in actual
      assert ToolDefinition.valid?(definition)

      assert ToolDefinition.canonical_bytes(definition) ==
               Base.decode64!(vector["canonical_bytes_base64"])

      assert ToolDefinition.definition_digest(definition) == vector["definition_digest"]
      assert definition["budgets"]["output_bytes"] == 16_384

      assert definition["budgets"]["artifact_bytes"] ==
               if(definition["tool_version"] == "1.0.0", do: 1, else: 16_384)
    end

    legacy =
      CodingTools.definitions()
      |> Enum.filter(&(&1["tool_id"] in ~w(loopex.grep loopex.find loopex.ls)))

    assert length(legacy) == 3
    assert Enum.all?(legacy, &(&1["tool_version"] == "1.0.0"))
  end
end
