defmodule Loopex.Model.ContentReferencesTest do
  use ExUnit.Case, async: true
  alias Loopex.Model.ContentReferences
  alias LoopexProtocol.Frame

  test "literal blocks and ordered text/tool references reconstruct exact values" do
    opaque = %{"kind" => "text_ref", "byte_length" => 999, "template" => %{}, "field" => "x"}
    arguments = [%{"nested" => opaque, "ratio" => 0.5}, %{"path" => "é.txt"}]

    content = [
      literal(%{"type" => "thinking", "thinking" => "opaque", "signature" => "signature"}),
      text(2),
      tool(0, "native-0"),
      text(0),
      literal(%{"type" => "redacted_thinking", "data" => "opaque-data"}),
      text(3),
      tool(1, "native-1")
    ]

    assert {:ok, blocks} = ContentReferences.expand(capsule(content, "open"), "é猫", arguments)

    assert blocks == [
             %{"type" => "thinking", "thinking" => "opaque", "signature" => "signature"},
             %{"type" => "text", "text" => "é"},
             %{
               "type" => "tool_use",
               "id" => "native-0",
               "name" => "read",
               "input" => hd(arguments)
             },
             %{"type" => "text", "text" => ""},
             %{"type" => "redacted_thinking", "data" => "opaque-data"},
             %{"type" => "text", "text" => "猫"},
             %{
               "type" => "tool_use",
               "id" => "native-1",
               "name" => "read",
               "input" => List.last(arguments)
             }
           ]
  end

  test "zero length text nodes preserve empty native blocks and complete consumption" do
    assert {:ok, [%{"type" => "text", "text" => ""}]} =
             ContentReferences.expand(capsule([text(0)]), "", [])

    assert {:ok, []} = ContentReferences.expand(capsule([]), "", [])

    for {content, value} <- [
          {[text(1)], "é"},
          {[text(3)], "é"},
          {[text(0)], "a"},
          {[], "a"},
          {[text(-1)], ""},
          {[text(1)], <<255>>}
        ] do
      assert {:error, :invalid_continuation} =
               ContentReferences.expand(capsule(content), value, [])
    end
  end

  test "tool indices consume every canonical argument once in original order" do
    for content <- [
          [tool(0.0, "a"), tool(1, "b")],
          [tool(1, "n")],
          [tool(0, "a"), tool(0, "b")],
          [tool(0, "a"), tool(2, "b")],
          [tool(0, "a")],
          [],
          [tool(0, ""), tool(1, "b")],
          [tool(0, <<255>>), tool(1, "b")]
        ] do
      assert {:error, :invalid_continuation} =
               ContentReferences.expand(capsule(content, "open"), "", [%{}, %{}])
    end

    assert {:error, :invalid_continuation} =
             ContentReferences.expand(capsule([tool(0, "n")], "open"), "", [])

    assert {:error, :invalid_continuation} =
             ContentReferences.expand(capsule([tool(0, "n")]), "", [%{}])
  end

  test "only an absent top-level ASCII field may be inserted" do
    for field <- ["", "é", String.duplicate("x", 129), 1],
        template <- [%{}, %{"type" => "text"}] do
      node = %{text(1) | "field" => field, "template" => template}
      assert {:error, :invalid_continuation} = ContentReferences.expand(capsule([node]), "x", [])
    end

    overwritten = %{text(1) | "template" => %{"text" => "old"}}

    assert {:error, :invalid_continuation} =
             ContentReferences.expand(capsule([overwritten]), "x", [])

    # Concept: a field names one key, even when it resembles a path.
    # Technical depth: neither field syntax nor opaque nested data causes recursion.
    node = %{text(1) | "field" => "a/b", "template" => %{"a" => %{"b" => "old"}}}

    assert {:ok, [%{"a" => %{"b" => "old"}, "a/b" => "x"}]} =
             ContentReferences.expand(capsule([node]), "x", [])
  end

  test "closed capsule and node shapes reject extra members and runtime terms" do
    valid = capsule([text(1)])

    for bad <- [
          Map.put(valid, "extra", nil),
          Map.delete(valid, "model"),
          %{valid | "model" => <<255>>},
          %{valid | "provider" => "other"},
          %{valid | "format" => "future"},
          %{valid | "status" => "unknown"},
          %{valid | "content" => [Map.put(text(1), "extra", nil)]},
          %{valid | "content" => [literal(self())]},
          %{valid | "content" => [literal(%{atom: "value"})]},
          %{valid | "content" => [literal(%{"runtime" => fn -> :ok end})]},
          %{valid | "content" => [%{"kind" => "future"}]},
          %{valid | "content" => [text(1) | :improper]}
        ] do
      assert {:error, :invalid_continuation} = ContentReferences.expand(bad, "x", [])
    end
  end

  test "compact and expanded capsule limits include the complete enclosing object" do
    compact = capsule([literal(%{"value" => ""})])
    {:ok, overhead} = ContentReferences.json_size(compact)

    at_limit =
      put_in(compact, ["content"], [
        literal(%{"value" => String.duplicate("x", 16_384 - overhead)})
      ])

    assert {:ok, 16_384} = ContentReferences.json_size(at_limit)
    assert {:ok, [_]} = ContentReferences.expand(at_limit, "", [])

    too_large =
      put_in(at_limit, ["content"], [
        literal(%{"value" => String.duplicate("x", 16_385 - overhead)})
      ])

    assert {:error, :invalid_continuation} = ContentReferences.expand(too_large, "", [])

    references = capsule([text(16_000), tool(0, "n")], "open")
    assert {:ok, _} = ContentReferences.json_size(references)

    assert {:error, :invalid_continuation} =
             ContentReferences.expand(references, String.duplicate("x", 16_000), [
               %{"value" => String.duplicate("y", 1_000)}
             ])

    escaped = capsule([text(3_000)])

    assert {:error, :invalid_continuation} =
             ContentReferences.expand(escaped, String.duplicate(<<0>>, 3_000), [])
  end

  test "block and argument limits count empty content and refuse improper tails" do
    assert {:ok, blocks} = ContentReferences.expand(capsule(List.duplicate(text(0), 128)), "", [])
    assert length(blocks) == 128

    assert {:error, :invalid_continuation} =
             ContentReferences.expand(capsule(List.duplicate(text(0), 129)), "", [])

    assert {:error, :invalid_continuation} =
             ContentReferences.expand(capsule([], "open"), "", [%{} | :improper])

    assert {:error, :invalid_continuation} =
             ContentReferences.expand(capsule([], "open"), "", List.duplicate(%{}, 129))
  end

  test "expanded multi-block ceiling counts separators and metadata exactly" do
    empty_blocks = [%{"type" => "text", "text" => ""}, %{"type" => "text", "text" => ""}]
    {:ok, encoded} = Frame.encode(capsule(empty_blocks))
    length = 16_384 - (IO.iodata_length(encoded) - 1)
    content = capsule([text(0), text(length)])
    assert {:ok, [_, last]} = ContentReferences.expand(content, String.duplicate("x", length), [])
    assert byte_size(last["text"]) == length

    assert {:error, :invalid_continuation} =
             ContentReferences.expand(
               capsule([text(0), text(length + 1)]),
               String.duplicate("x", length + 1),
               []
             )
  end

  test "bounded nested JSON costs agree across escaped and Unicode variations" do
    for count <- 0..64, char <- ["x", "é", "😀", "\n", <<0>>, "\"", "\\"] do
      value = %{
        "b" => [String.duplicate(char, count), %{"x" => count, "y" => -count}],
        "a" => [true, false, nil, []]
      }

      {:ok, bytes} = Frame.encode(value)
      assert ContentReferences.json_size(value) == {:ok, IO.iodata_length(bytes) - 1}
    end
  end

  test "JSON measurement matches the existing compact encoder and exact ceiling" do
    for value <- [
          %{},
          %{"one" => 1},
          %{"two" => [1, 2], "a" => true},
          %{"escapes" => <<0, 8, 9, 10, 12, 13, 31, 34, 92>>},
          %{"unicode" => "é猫😀", "negative" => -123, "nil" => nil},
          %{"nested" => [%{"x" => []}, %{"y" => false}]}
        ] do
      {:ok, encoded} = Frame.encode(value)
      assert ContentReferences.json_size(value) == {:ok, IO.iodata_length(encoded) - 1}
    end

    assert ContentReferences.json_size(%{"float" => 0.5}) == {:ok, 13}
    assert ContentReferences.json_size(String.duplicate("x", 16_382)) == {:ok, 16_384}

    assert ContentReferences.json_size(String.duplicate("x", 16_383)) ==
             {:error, :invalid_continuation}

    assert ContentReferences.json_size(Integer.pow(10, 16_384)) == {:error, :invalid_continuation}

    assert ContentReferences.json_size(%{"x" => String.duplicate("x", 1_000_000)}) ==
             {:error, :invalid_continuation}
  end

  test "JSON structural checks reject excessive depth, cardinality and nonplain values" do
    depth = Enum.reduce(1..14, "x", fn _, value -> [value] end)

    for value <- [
          depth,
          List.duplicate(nil, 1_025),
          %URI{},
          %{atom: "value"},
          %{"x" => :atom},
          [nil | :improper],
          %{"x" => self()},
          <<255>>
        ] do
      assert ContentReferences.json_size(value) == {:error, :invalid_continuation}
    end
  end

  defp capsule(content, status \\ "closed"),
    do: %{
      "format" => "loopex.anthropic.content_refs.v1",
      "provider" => "anthropic",
      "model" => "anthropic:claude-haiku-4-5-20251001",
      "status" => status,
      "content" => content
    }

  defp literal(value), do: %{"kind" => "literal", "value" => value}

  defp text(length),
    do: %{
      "kind" => "text_ref",
      "byte_length" => length,
      "template" => %{"type" => "text"},
      "field" => "text"
    }

  defp tool(index, id),
    do: %{
      "kind" => "tool_use_ref",
      "call_index" => index,
      "native_id" => id,
      "template" => %{"type" => "tool_use", "id" => id, "name" => "read"},
      "field" => "input"
    }
end
