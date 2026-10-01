defmodule Loopex.LLM.ReqLLM.NativeContentTest do
  use ExUnit.Case, async: true
  alias Loopex.LLM.ReqLLM.NativeContent
  alias Loopex.Model.ContentReferences

  test "buffered and streamed native replies preserve the same ordered content and usage" do
    alias Loopex.LLM.ReqLLM.NativeStream
    id = String.replace_prefix(model(), "anthropic:", "")

    content = [
      %{"type" => "thinking", "thinking" => "private 猫", "signature" => "sig+/="},
      %{"type" => "text", "text" => "é"},
      %{"type" => "redacted_thinking", "data" => "opaque+/="},
      %{"type" => "text", "text" => "tail"}
    ]

    native = %{
      "id" => "message",
      "type" => "message",
      "role" => "assistant",
      "model" => id,
      "content" => content,
      "stop_reason" => "end_turn",
      "stop_sequence" => nil,
      "usage" => %{"input_tokens" => 7, "output_tokens" => 11}
    }

    assert {:ok, buffered} = NativeContent.response(model(), true, id, Jason.encode!(native))
    start = %{native | "content" => [], "stop_reason" => nil, "usage" => %{"input_tokens" => 7}}

    events =
      [%{"type" => "message_start", "message" => start}] ++
        Enum.flat_map(Enum.with_index(content), fn {block, index} ->
          [
            %{"type" => "content_block_start", "index" => index, "content_block" => block},
            %{"type" => "content_block_stop", "index" => index}
          ]
        end) ++
        [
          %{
            "type" => "message_delta",
            "delta" => %{"stop_reason" => "end_turn", "stop_sequence" => nil},
            "usage" => %{"output_tokens" => 11}
          },
          %{"type" => "message_stop"}
        ]

    state =
      Enum.reduce(events, NativeStream.new(id), fn event, state ->
        assert {:ok, next} = NativeStream.feed(state, event)
        next
      end)

    assert {:ok, streamed} = NativeStream.finish(state)

    assert {:ok, captured} =
             NativeContent.capture(model(), streamed.stop_reason, streamed.content)

    assert Map.put(captured, :usage, streamed.usage) == buffered
    assert {:ok, ^content} = ContentReferences.expand(buffered.continuation, buffered.text, [])

    for invalid <- [
          Map.delete(native, "stop_reason"),
          Map.put(native, "model", "wrong"),
          Map.put(native, "role", "user"),
          Map.put(native, "extra", true)
        ] do
      assert {:error, :invalid_native_content} =
               NativeContent.response(model(), true, id, Jason.encode!(invalid))
    end

    assert {:error, :invalid_native_content} =
             NativeContent.response(model(), true, id, "{truncated")

    assert {:error, :invalid_native_content} =
             NativeContent.response(model(), true, id, String.duplicate(" ", 8_388_609))

    for usage <- [
          %{},
          %{"input_tokens" => -1, "output_tokens" => "7"},
          %{"input_tokens" => 18_446_744_073_709_551_616}
        ] do
      assert {:ok, reply} =
               NativeContent.response(
                 model(),
                 true,
                 id,
                 Jason.encode!(%{native | "usage" => usage})
               )

      assert Map.get(reply.usage, :input_tokens) == nil
      assert Map.get(reply.usage, :output_tokens) == nil
    end

    echoed = %{native | "usage" => %{"input_tokens" => "selected-key", "output_tokens" => 11}}

    assert {:error, :invalid_native_content} =
             NativeContent.response(model(), true, id, Jason.encode!(echoed), "selected-key")
  end

  test "complete native arrays round trip with exact strings, order, IDs and parsed arguments" do
    content = [
      %{"type" => "thinking", "thinking" => "summary\n猫", "signature" => "signature+/="},
      %{"type" => "text", "text" => "é"},
      %{
        "type" => "tool_use",
        "id" => "native:α",
        "name" => "read",
        "input" => %{"path" => "猫.txt", "ratio" => 1.5}
      },
      %{"type" => "text", "text" => ""},
      %{"type" => "redacted_thinking", "data" => "opaque+/="},
      %{"type" => "text", "text" => "😀"},
      %{
        "type" => "tool_use",
        "id" => "native:β",
        "name" => "unknown-tool",
        "input" => %{"literal" => %{"kind" => "text_ref"}}
      }
    ]

    assert {:ok, reply} = NativeContent.capture(model(), "tool_use", content)
    assert reply.text == "é😀"
    assert reply.completion == "natural"
    assert reply.continuation["status"] == "open"

    assert reply.tool_calls == [
             %{id: "native:α", name: "read", arguments: %{"path" => "猫.txt", "ratio" => 1.5}},
             %{
               id: "native:β",
               name: "unknown-tool",
               arguments: %{"literal" => %{"kind" => "text_ref"}}
             }
           ]

    assert {:ok, ^content} =
             ContentReferences.expand(
               reply.continuation,
               reply.text,
               Enum.map(reply.tool_calls, & &1.arguments)
             )

    refute :erlang.term_to_binary(reply.continuation) =~ "猫.txt"
    refute :erlang.term_to_binary(reply.continuation) =~ "é😀"

    assert Enum.filter(reply.continuation["content"], &(&1["kind"] == "text_ref"))
           |> Enum.map(& &1["byte_length"]) == [2, 0, 4]
  end

  test "a reference-only completion still captures a closed capsule without invented thinking" do
    assert {:ok, reply} =
             NativeContent.capture(model(), "end_turn", [%{"type" => "text", "text" => "done"}])

    assert reply.text == "done"
    assert reply.tool_calls == []
    assert reply.continuation["status"] == "closed"
    assert Enum.all?(reply.continuation["content"], &(&1["kind"] == "text_ref"))
    assert {:ok, empty} = NativeContent.capture(model(), "end_turn", [])
    assert empty.text == ""
    assert empty.continuation["content"] == []
  end

  test "generic replies preserve stop evidence but cannot discard private thinking" do
    content = [%{"type" => "text", "text" => "answer"}]

    for {stop, completion} <- [
          {"end_turn", "natural"},
          {"tool_use", "natural"},
          {"stop_sequence", "natural"},
          {"max_tokens", "limit"},
          {"model_context_window_exceeded", "unknown"},
          {"refusal", "unknown"},
          {"pause_turn", "unknown"},
          {nil, "unknown"},
          {"future_reason", "unknown"}
        ] do
      assert {:ok, reply} = NativeContent.project(model(), false, stop, content)
      assert reply.completion == completion
      assert reply.continuation == nil
      assert reply.text == "answer"
    end

    for block <- [
          %{"type" => "thinking", "thinking" => "private", "signature" => "sig"},
          %{"type" => "redacted_thinking", "data" => "opaque"}
        ] do
      assert {:error, :invalid_native_content} =
               NativeContent.project(model(), false, "end_turn", content ++ [block])
    end

    assert {:error, :invalid_native_content} =
             NativeContent.project(model(), true, "max_tokens", content)
  end

  test "only complete matching stop and call relations admit a continuation reply" do
    tool = %{"type" => "tool_use", "id" => "n", "name" => "read", "input" => %{}}

    for {stop, content} <- [
          {"tool_use", []},
          {"end_turn", [tool]},
          {"max_tokens", [tool]},
          {"max_tokens", []},
          {"stop_sequence", []},
          {"refusal", []},
          {"pause_turn", []},
          {nil, []},
          {"future", []}
        ] do
      assert NativeContent.capture(model(), stop, content) == {:error, :invalid_native_content}
    end
  end

  test "unsupported fields and incomplete signatures are never silently discarded" do
    for block <- [
          %{"type" => "thinking", "thinking" => "secret"},
          %{"type" => "thinking", "thinking" => "secret", "signature" => ""},
          %{"type" => "thinking", "thinking" => "secret", "signature" => "sig", "extra" => true},
          %{"type" => "redacted_thinking", "data" => "opaque", "extra" => true},
          %{"type" => "redacted_thinking", "data" => ""},
          %{"type" => "text", "text" => "answer", "citations" => []},
          %{"type" => "text", "text" => <<255>>},
          %{"type" => "future", "text" => "answer"},
          %{"type" => "tool_use", "id" => "n", "name" => "read", "input" => %{}, "extra" => true},
          %{"type" => "tool_use", "id" => "n", "name" => "read", "input" => "{}"},
          %{"type" => "tool_use", "id" => "", "name" => "read", "input" => %{}},
          %{"type" => "tool_use", "id" => "n", "name" => "", "input" => %{}},
          %{"type" => "tool_use", "id" => "n", "name" => "read", "input" => %{"pid" => self()}}
        ] do
      assert NativeContent.capture(model(), "end_turn", [block]) ==
               {:error, :invalid_native_content}

      assert NativeContent.capture(model(), "tool_use", [block]) ==
               {:error, :invalid_native_content}
    end
  end

  test "duplicate native identities fail the complete ordered call list" do
    tool = %{"type" => "tool_use", "id" => "n", "name" => "read", "input" => %{}}

    assert NativeContent.capture(model(), "tool_use", [tool, %{tool | "name" => "write"}]) ==
             {:error, :invalid_native_content}
  end

  test "private JSON measurement agrees with the adapter encoder for numeric arguments" do
    for value <- [
          0.0,
          -0.0,
          1.0,
          0.5,
          -3.125,
          1.0e20,
          1.0e-20,
          9_007_199_254_740_993,
          -18_446_744_073_709_551_615
        ] do
      arguments = %{"value" => value, "unicode" => "猫😀", "control" => <<0, 10, 34, 92>>}
      assert ContentReferences.json_size(arguments) == {:ok, byte_size(Jason.encode!(arguments))}
    end
  end

  test "complete wrapper and compact reference overhead count before admission" do
    content = [%{"type" => "text", "text" => String.duplicate("x", 16_250)}]
    assert {:ok, _} = ContentReferences.json_size(content)

    assert NativeContent.capture(model(), "end_turn", content) ==
             {:error, :invalid_native_content}

    huge = [%{"type" => "text", "text" => String.duplicate("x", 1_000_000)}]
    assert NativeContent.capture(model(), "end_turn", huge) == {:error, :invalid_native_content}
    blocks = List.duplicate(%{"type" => "text", "text" => ""}, 128)
    assert {:ok, reply} = NativeContent.capture(model(), "end_turn", blocks)
    assert length(reply.continuation["content"]) == 128

    assert NativeContent.capture(model(), "end_turn", blocks ++ [hd(blocks)]) ==
             {:error, :invalid_native_content}

    assert NativeContent.capture("openai:other", "end_turn", []) ==
             {:error, :invalid_native_content}

    assert NativeContent.capture("anthropic:" <> <<255>>, "end_turn", []) ==
             {:error, :invalid_native_content}

    assert NativeContent.capture(model(), "end_turn", [hd(blocks) | :improper]) ==
             {:error, :invalid_native_content}
  end

  defp model, do: "anthropic:claude-haiku-4-5-20251001"
end
