defmodule Loopex.Runtime.ArtifactReadCapabilitiesTest do
  use ExUnit.Case, async: true

  alias Loopex.Runtime.ArtifactReadCapabilities, as: Capabilities
  alias LoopexProtocol.ToolDefinition

  @range_digest "858956b73d7059ffaf18943d28bb0654ee3ca935f86cec3a136ba8e93b6e3c9e"
  setup do
    path = Path.expand("../priv/vectors/artifact_read.v1.json", __DIR__)
    manifest = path |> File.read!() |> JSON.decode!()
    [range] = manifest["vectors"]
    %{manifest: manifest, range: range}
  end

  test "fixed preimages and literal table agree for every supported generation", fixture do
    assert fixture.manifest["revision"] == "loopex.artifact_read.v1"
    assert fixture.range["definition_digest"] == @range_digest

    expected =
      Map.new(fixture.manifest["vectors"], fn row ->
        definition = row["definition"]
        assert ToolDefinition.valid?(definition)
        assert ToolDefinition.definition_digest(definition) == row["definition_digest"]

        assert ToolDefinition.canonical_bytes(definition) ==
                 Base.decode64!(row["canonical_bytes_base64"])

        generation = ToolDefinition.generation(definition)

        binding =
          if row["artifact_capable"] do
            %{
              "revision" => "loopex.artifact_read.v1",
              "tool_id" => row["tool_id"],
              "tool_version" => row["tool_version"],
              "definition_digest" => row["definition_digest"]
            }
          end

        assert Capabilities.resolve([definition]) == {:ok, binding}
        assert Capabilities.validate_binding([definition], binding) == :ok
        {generation, binding}
      end)

    assert Capabilities.table() == expected
  end

  test "an absent read or a tool merely named read gains no retrieval", fixture do
    other = Map.put(fixture.range["definition"], "tool_id", "example.read")
    assert ToolDefinition.valid?(other)
    assert Capabilities.resolve([]) == {:ok, nil}
    assert Capabilities.resolve([other]) == {:ok, nil}
  end

  test "every changed reference generation refuses instead of guessing support", fixture do
    for original <- [fixture.range["definition"]],
        changed <- [
          Map.put(original, "tool_version", "1.0.0"),
          Map.put(original, "tool_version", "9.9.9"),
          Map.update!(original, "description", &(&1 <> ".")),
          Map.put(original, "name", "other_read"),
          put_in(original, ["budgets", "output_bytes"], 1)
        ] do
      assert ToolDefinition.valid?(changed)
      assert Capabilities.resolve([changed]) == {:error, :invalid_tool_selection}
    end
  end

  test "the complete frozen identity binds all retained capability members", fixture do
    definition = fixture.range["definition"]
    assert {:ok, binding} = Capabilities.resolve([definition])

    for supplied <- [
          nil,
          Map.delete(binding, "definition_digest"),
          Map.put(binding, "extra", true),
          Map.put(binding, "revision", "loopex.artifact_read.v2"),
          Map.put(binding, "tool_version", "1.0.0"),
          Map.put(binding, "definition_digest", String.duplicate("0", 64))
        ] do
      assert Capabilities.validate_binding([definition], supplied) ==
               {:error, :invalid_tool_selection}
    end
  end

  test "ambiguous and non-plain selections refuse within the existing item bounds", fixture do
    range = fixture.range["definition"]

    for definitions <- [
          nil,
          %{},
          [range, range],
          [Map.put(range, "process", self())],
          List.duplicate(range, 4_097),
          [Map.delete(range, "parameter_schema")]
        ] do
      assert Capabilities.resolve(definitions) == {:error, :invalid_tool_selection}
    end
  end
end
