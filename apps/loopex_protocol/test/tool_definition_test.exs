defmodule LoopexProtocol.ToolDefinitionTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias LoopexProtocol.Canonical
  alias LoopexProtocol.ToolDefinition

  defp definition(overrides \\ %{}) do
    Map.merge(
      %{
        "tool_id" => "example.read",
        "tool_version" => "1.0.0",
        "name" => "read",
        "description" => "Read a file beneath the workspace root.",
        "parameter_schema" => %{
          "type" => "object",
          "properties" => %{
            "path" => %{"type" => "string", "description" => "Relative path."},
            "lines" => %{"type" => "array", "items" => %{"type" => "integer"}},
            "mode" => %{"type" => "string", "enum" => ["text", "binary"]}
          },
          "required" => ["path"]
        },
        "result_shape" => %{"content_type" => "text", "description" => "File contents."},
        "effect_class" => "read_only",
        "idempotency_class" => "safe_retry",
        "budgets" => %{
          "wall_time_ms" => 30_000,
          "output_bytes" => 65_536,
          "artifact_bytes" => 1_048_576
        }
      },
      overrides
    )
  end

  test "a complete definition in the declared subset is valid" do
    assert ToolDefinition.validate(definition()) == []
    assert ToolDefinition.valid?(definition())
    assert length(ToolDefinition.fields()) == 9
  end

  test "validation reports every reason rather than the first" do
    reasons =
      ToolDefinition.validate(%{
        "tool_id" => "Example.Read",
        "tool_version" => "1.0",
        "name" => "Read It",
        "description" => "",
        "parameter_schema" => %{"type" => "object", "properties" => %{}},
        "result_shape" => %{"content_type" => "xml"},
        "effect_class" => "omnipotent",
        "idempotency_class" => "whenever",
        "budgets" => %{"wall_time_ms" => 0, "output_bytes" => 1}
      })

    # Seven independent defects, each named once, in one pass.
    assert Enum.any?(reasons, &String.starts_with?(&1, "tool_id:"))
    assert Enum.any?(reasons, &String.starts_with?(&1, "tool_version:"))
    assert Enum.any?(reasons, &String.starts_with?(&1, "name:"))
    assert Enum.any?(reasons, &String.starts_with?(&1, "description:"))
    assert Enum.any?(reasons, &String.starts_with?(&1, "result_shape:"))
    assert Enum.any?(reasons, &String.starts_with?(&1, "effect_class:"))
    assert Enum.any?(reasons, &String.starts_with?(&1, "idempotency_class:"))
    assert "budgets: artifact_bytes is missing" in reasons
    assert "budgets: wall_time_ms must be a positive integer" in reasons
  end

  test "a missing or unknown field is named rather than ignored" do
    assert ToolDefinition.validate(Map.delete(definition(), "budgets")) ==
             ["budgets: required field is missing"]

    assert ToolDefinition.validate(Map.put(definition(), "retries", 3)) ==
             ["retries: is not a tool definition field"]

    assert ToolDefinition.validate(Map.put(definition(), :name, "read")) ==
             ["a tool definition must use only binary keys"]

    assert ToolDefinition.validate("read") ==
             ["a tool definition must be a map with binary keys"]
  end

  test "constructs outside the declared schema subset are refused at registration" do
    refute_schema = fn schema ->
      reasons = ToolDefinition.validate(definition(%{"parameter_schema" => schema}))
      assert reasons != [], "expected #{inspect(schema)} to be refused"
      reasons
    end

    # A nested object: the walk cannot evaluate it, so it is refused by name
    # rather than skipped. A skipped keyword reads as "validated" while
    # validating nothing.
    refute_schema.(%{
      "type" => "object",
      "properties" => %{"where" => %{"type" => "object"}},
      "required" => []
    })

    # A union, a reference, and a conditional keyword.
    refute_schema.(%{
      "type" => "object",
      "properties" => %{"path" => %{"oneOf" => [%{"type" => "string"}]}},
      "required" => []
    })

    refute_schema.(%{
      "type" => "object",
      "properties" => %{"path" => %{"$ref" => "#/definitions/path"}},
      "required" => []
    })

    refute_schema.(%{
      "type" => "object",
      "properties" => %{"path" => %{"type" => "string"}},
      "required" => [],
      "if" => %{}
    })

    # A non-object root, an array without scalar items, and a required name that
    # is not a declared property.
    refute_schema.(%{"type" => "array", "properties" => %{}, "required" => []})

    refute_schema.(%{
      "type" => "object",
      "properties" => %{"lines" => %{"type" => "array"}},
      "required" => []
    })

    refute_schema.(%{
      "type" => "object",
      "properties" => %{"path" => %{"type" => "string"}},
      "required" => ["absent"]
    })
  end

  test "arguments are checked against every declared schema constraint" do
    assert :ok =
             ToolDefinition.validate_arguments(definition(), %{
               "path" => "README.md",
               "lines" => [1, 3],
               "mode" => "text",
               "provider_extension" => %{"threshold" => 0.5}
             })

    for invalid <- [
          %{},
          %{"path" => 1},
          %{"path" => "README.md", "lines" => [1, 0.5]},
          %{"path" => "README.md", "mode" => "raw"},
          %{"path" => "README.md", "provider_extension" => self()}
        ] do
      assert {:error, :invalid_arguments} =
               ToolDefinition.validate_arguments(definition(), invalid)
    end

    number_definition =
      definition(%{
        "parameter_schema" => %{
          "type" => "object",
          "properties" => %{"threshold" => %{"type" => "number"}},
          "required" => ["threshold"]
        }
      })

    assert :ok = ToolDefinition.validate_arguments(number_definition, %{"threshold" => 0.5})
    assert :ok = ToolDefinition.validate_arguments(number_definition, %{"threshold" => 1})
  end

  test "the generation triple changes with any field and is stable across key order" do
    base = definition()
    {tool_id, tool_version, digest} = ToolDefinition.generation(base)

    assert tool_id == "example.read"
    assert tool_version == "1.0.0"
    assert String.match?(digest, ~r/^[0-9a-f]{64}$/)

    # Rebuilding the same record with different insertion order must produce
    # byte-identical canonical bytes: the digest names content, not layout.
    reordered =
      base |> Map.to_list() |> Enum.reverse() |> Map.new()

    assert ToolDefinition.canonical_bytes(reordered) == ToolDefinition.canonical_bytes(base)
    assert ToolDefinition.generation(reordered) == ToolDefinition.generation(base)

    # A change to the model-visible name is a new generation, which is why a
    # rename must be a new version rather than an edit.
    renamed = definition(%{"name" => "read_file"})
    {_id, _version, renamed_digest} = ToolDefinition.generation(renamed)
    assert renamed_digest != digest

    # So is a change to any other field.
    for field <- ["description", "effect_class", "idempotency_class"] do
      changed =
        definition(%{
          field =>
            case field do
              "description" -> "Different text."
              "effect_class" -> "workspace_write"
              "idempotency_class" -> "never_blind_retry"
            end
        })

      {_id, _version, changed_digest} = ToolDefinition.generation(changed)
      assert changed_digest != digest, "#{field} did not change the generation"
    end
  end

  test "canonical bytes cover both version tags and refuse an invalid definition" do
    bytes = ToolDefinition.canonical_bytes(definition())
    assert is_binary(bytes)
    assert ToolDefinition.definition_digest(definition()) == Canonical.digest_bytes(bytes)

    # The encoding version is inside the covered bytes, so a retained digest
    # always states which encoding produced it.
    assert bytes =~ Canonical.version()

    assert_raise ArgumentError, fn ->
      ToolDefinition.canonical_bytes(definition(%{"effect_class" => "omnipotent"}))
    end
  end

  test "the reserved namespace and the model facing projection are exact" do
    assert ToolDefinition.reserved?("loopex.demo.write")
    refute ToolDefinition.reserved?("example.read")
    refute ToolDefinition.reserved?("loopexish.read")

    assert ToolDefinition.model_facing(definition()) |> Map.keys() |> Enum.sort() ==
             ["description", "name", "parameter_schema"]
  end

  test "a narrowed schema keyword is reported rather than dropped in silence" do
    declaration = %{
      "tool_id" => "example.read",
      "tool_version" => "1.0.0",
      "name" => "read",
      "description" => "Read a file.",
      "effect_class" => "read_only",
      "input_schema" => %{
        "type" => "object",
        "properties" => %{
          "path" => %{"type" => "string", "const" => "fixed.txt"},
          "mode" => %{"type" => "string"}
        },
        "required" => ["path"],
        "additionalProperties" => false
      }
    }

    # Completion fills the fields a host had no opinion about.
    normalized = ToolDefinition.normalize(declaration)
    assert ToolDefinition.validate(normalized) == []
    assert Map.has_key?(normalized, "result_shape")
    assert Map.has_key?(normalized, "idempotency_class")
    assert Map.has_key?(normalized, "budgets")
    refute Map.has_key?(normalized, "input_schema")

    # And every keyword the kernel cannot evaluate is named, so a host that
    # believed `additionalProperties: false` was enforced finds out at
    # registration rather than at dispatch.
    assert ToolDefinition.narrowing(declaration) == [
             "parameter_schema.additionalProperties",
             "parameter_schema.properties.path.const"
           ]

    # A declaration already written in the subset reports nothing.
    assert ToolDefinition.narrowing(definition()) == []
  end

  test "canonical encoding is injective over map and list shapes" do
    # A map and a list of its pairs must not collide, or two different staged
    # requests could share one digest.
    assert Canonical.encode(%{"a" => 1}) != Canonical.encode([{"a", 1}])
    assert Canonical.encode(%{"a" => "b"}) == Canonical.encode(%{"a" => "b"})

    assert_raise ArgumentError, fn -> Canonical.encode(%{"pid" => self()}) end
  end
end
