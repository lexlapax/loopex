defmodule Loopex.LLM.ReqLLM.NativeStreamTest do
  use ExUnit.Case, async: true

  alias Loopex.LLM.ReqLLM.{NativeContent, NativeStream}
  alias Loopex.Model.ContentReferences
  alias ServerSentEvents.Parser

  @model "claude-fable-5-1"

  test "native assembly preserves block order, signature fragments, parsed arguments and final usage" do
    events = exchange()

    state =
      Enum.reduce(events, NativeStream.new(@model), fn event, state ->
        assert {:ok, next} = NativeStream.feed(state, event)
        next
      end)

    assert {:ok, native} = NativeStream.finish(state)
    assert native.usage == %{input_tokens: 13, output_tokens: 7}

    assert native.content == [
             %{"type" => "thinking", "thinking" => "summary猫", "signature" => "sig+/="},
             %{"type" => "text", "text" => ""},
             %{"type" => "redacted_thinking", "data" => "opaque+/="},
             %{
               "type" => "tool_use",
               "id" => "native",
               "name" => "read",
               "input" => %{"path" => "猫.txt"}
             },
             %{"type" => "text", "text" => "done😀"}
           ]

    assert {:ok, reply} =
             NativeContent.capture("anthropic:" <> @model, native.stop_reason, native.content)

    assert reply.text == "done😀"

    assert {:ok, reconstructed} =
             ContentReferences.expand(
               reply.continuation,
               reply.text,
               Enum.map(reply.tool_calls, & &1.arguments)
             )

    assert reconstructed == native.content
    refute Map.has_key?(state, :events)
    assert state.open == nil
  end

  test "every byte boundary uses the pinned parser and exact native stop establishes completion" do
    wire = encode(exchange())

    {state, parser, seen} =
      wire
      |> :binary.bin_to_list()
      |> Enum.reduce(
        {NativeStream.new(@model), nil, []},
        fn byte, {state, parser, seen} ->
          assert {:ok, next, events, %Parser{} = next_parser} =
                   NativeStream.parse(state, <<byte>>, parser)

          {next, next_parser, Enum.reverse(events) ++ seen}
        end
      )

    assert Enum.reverse(seen) == exchange()
    assert state.raw_bytes == byte_size(wire)
    assert {:ok, ^state} = NativeStream.flush(state, parser)
    assert {:ok, _} = NativeStream.finish(state)

    [start | rest] = exchange()
    assert {:ok, state} = NativeStream.feed(NativeStream.new(@model), start)

    for event <- Enum.drop(rest, -1), reduce: state do
      state ->
        assert {:ok, next} = NativeStream.feed(state, event)
        assert {:error, :incomplete_native_stream} = NativeStream.finish(next)
        next
    end
  end

  test "identity and grammar failures clear private content and remain failed" do
    [start | _] = exchange()
    text = block_start(0, %{"type" => "text", "text" => "private text"})

    thinking =
      block_start(0, %{"type" => "thinking", "thinking" => "private thought", "signature" => ""})

    bad_sequences = [
      [put_in(start, ["message", "model"], "other")],
      [put_in(start, ["message", "role"], "user")],
      [start, start],
      [text],
      [start, block_start(1, %{"type" => "text", "text" => ""})],
      [start, text, text],
      [start, block_stop(0)],
      [start, text, block_stop(1)],
      [start, text, delta(0, "thinking_delta", "thinking", "wrong type")],
      [start, thinking, block_stop(0)],
      [
        start,
        thinking,
        delta(0, "signature_delta", "signature", "sig"),
        delta(0, "thinking_delta", "thinking", "late")
      ],
      [
        start,
        block_start(0, %{"type" => "redacted_thinking", "data" => "opaque"}),
        delta(0, "text_delta", "text", "leak")
      ],
      [start, block_start(0, %{"type" => "server_tool_use", "id" => "id"})],
      [start, %{"type" => "error", "error" => %{"message" => "secret diagnostic"}}],
      [start, text, ending("end_turn", %{})],
      [start, ending("end_turn", %{}), text],
      [start, ending("end_turn", %{}), ending("tool_use", %{})],
      [start, %{"type" => "message_stop"}],
      exchange() ++ [%{"type" => "message_stop"}]
    ]

    for events <- bad_sequences do
      assert {:error, failed} =
               Enum.reduce_while(events, {:ok, NativeStream.new(@model)}, fn event,
                                                                             {:ok, state} ->
                 case NativeStream.feed(state, event) do
                   {:ok, next} -> {:cont, {:ok, next}}
                   {:error, failed} -> {:halt, {:error, failed}}
                 end
               end)

      assert failed.phase == :failed
      assert failed.open == nil and failed.blocks == []
      assert {:error, ^failed} = NativeStream.feed(failed, start)
      assert {:error, :incomplete_native_stream} = NativeStream.finish(failed)
      refute inspect(failed) =~ "private"
      refute inspect(failed) =~ "secret"
    end
  end

  test "malformed tool JSON never becomes repaired or default arguments" do
    start = hd(exchange())
    tool = block_start(0, %{"type" => "tool_use", "id" => "n", "name" => "read", "input" => %{}})

    for json <- ["{", "[]", "null", "true", "{\"a\":undefined}", "{\"a\":1,}"] do
      state = feed!([start, tool, delta(0, "input_json_delta", "partial_json", json)])
      assert {:error, failed} = NativeStream.feed(state, block_stop(0))
      assert failed.open == nil
    end

    state =
      feed!([start, tool, block_stop(0), ending("tool_use", %{}), %{"type" => "message_stop"}])

    assert {:ok, %{content: [%{"input" => %{}}]}} = NativeStream.finish(state)
  end

  test "usage preserves missing and invalid evidence without summing cumulative updates" do
    start = put_in(hd(exchange()), ["message", "usage"], %{"output_tokens" => "bad"})

    state =
      feed!([
        start,
        ending("end_turn", %{"output_tokens" => 3}),
        ending("end_turn", %{"output_tokens" => 7}),
        %{"type" => "message_stop"}
      ])

    assert {:ok, %{usage: %{input_tokens: nil, output_tokens: 7}}} = NativeStream.finish(state)

    for invalid <- [-1, 1.0, "7", nil, 18_446_744_073_709_551_616] do
      state =
        feed!([
          hd(exchange()),
          ending("end_turn", %{"output_tokens" => invalid}),
          %{"type" => "message_stop"}
        ])

      assert {:ok, %{usage: %{input_tokens: 13, output_tokens: nil}}} = NativeStream.finish(state)
    end
  end

  test "raw ceiling includes framing, ignored comments and pings before append or decode" do
    prefix = encode([hd(exchange()), %{"type" => "ping"}])
    tail = encode([ending("end_turn", %{}), %{"type" => "message_stop"}])
    comment_size = 8_388_608 - byte_size(prefix) - byte_size(tail)
    comment = ":" <> String.duplicate("x", comment_size - 2) <> "\n"
    assert {:ok, state, _, parser} = NativeStream.parse(NativeStream.new(@model), prefix, nil)
    assert {:ok, state, [], parser} = NativeStream.parse(state, comment, parser)
    assert {:ok, state, _, parser} = NativeStream.parse(state, tail, parser)
    assert state.raw_bytes == 8_388_608
    assert {:ok, ^state} = NativeStream.flush(state, parser)
    assert {:error, failed} = NativeStream.parse(state, "x", parser)
    assert failed.phase == :failed
    assert {:error, _} = NativeStream.flush(failed, parser)

    assert {:error, _} =
             NativeStream.parse(NativeStream.new(@model), String.duplicate("x", 8_388_609), nil)
  end

  test "malformed JSON, foreign parser states and synthetic EOF completion fail permanently" do
    for invalid <- [
          "event: ping\ndata: secret\n\n",
          "event: ping\ndata: []\n\n",
          "event: ping\ndata: {\"type\":\"message_stop\"}\n\n",
          "data: {\"type\":\"ping\"}\n\n"
        ] do
      assert {:error, failed} = NativeStream.parse(NativeStream.new(@model), invalid, nil)
      assert failed.phase == :failed
      assert {:error, ^failed} = NativeStream.parse(failed, encode(exchange()), nil)
    end

    for parser <- [%{}, "", :unknown, %Parser{phase: :unknown}] do
      assert {:error, _} = NativeStream.parse(NativeStream.new(@model), "", parser)
    end

    wire = encode(exchange())

    for cut <- [1, 2, 3] do
      incomplete = binary_part(wire, 0, byte_size(wire) - cut)

      assert {:ok, state, _, parser} =
               NativeStream.parse(NativeStream.new(@model), incomplete, nil)

      assert {:error, failed} = NativeStream.flush(state, parser)
      assert {:error, _} = NativeStream.parse(failed, "\n\n", parser)
    end

    assert {:ok, state, _, _} = NativeStream.parse(NativeStream.new(@model), wire, nil)
    assert {:error, _} = NativeStream.flush(state, %{})
  end

  test "native JSON and block ceilings are inclusive and checked during assembly" do
    start = hd(exchange())
    block = %{"type" => "text", "text" => ""}
    {:ok, overhead} = ContentReferences.json_size([block])
    state = feed!([start, block_start(0, block)])

    assert {:ok, at} =
             NativeStream.feed(
               state,
               delta(0, "text_delta", "text", String.duplicate("x", 16_384 - overhead))
             )

    assert at.json_bytes == 16_384
    assert {:error, _} = NativeStream.feed(at, delta(0, "text_delta", "text", "x"))
    assert {:ok, at} = NativeStream.feed(at, block_stop(0))
    assert at.json_bytes == 16_384
    events = [start] ++ Enum.flat_map(0..127, &[block_start(&1, block), block_stop(&1)])
    state = feed!(events)
    assert state.index == 128
    assert {:error, _} = NativeStream.feed(state, block_start(128, block))
  end

  defp feed!(events),
    do:
      Enum.reduce(events, NativeStream.new(@model), fn event, state ->
        assert {:ok, next} = NativeStream.feed(state, event)
        next
      end)

  defp encode(events),
    do:
      Enum.map_join(events, fn event ->
        "event: #{event["type"]}\ndata: #{Jason.encode!(event)}\n\n"
      end)

  defp block_start(index, block),
    do: %{"type" => "content_block_start", "index" => index, "content_block" => block}

  defp block_stop(index), do: %{"type" => "content_block_stop", "index" => index}

  defp delta(index, type, field, value),
    do: %{
      "type" => "content_block_delta",
      "index" => index,
      "delta" => %{"type" => type, field => value}
    }

  defp ending(reason, usage),
    do: %{
      "type" => "message_delta",
      "delta" => %{"stop_reason" => reason, "stop_sequence" => nil},
      "usage" => usage
    }

  defp exchange do
    [
      %{
        "type" => "message_start",
        "message" => %{
          "id" => "msg_test",
          "type" => "message",
          "role" => "assistant",
          "model" => @model,
          "content" => [],
          "stop_reason" => nil,
          "stop_sequence" => nil,
          "usage" => %{"input_tokens" => 13, "output_tokens" => 0}
        }
      },
      block_start(0, %{"type" => "thinking", "thinking" => "", "signature" => ""}),
      delta(0, "thinking_delta", "thinking", "summary"),
      delta(0, "thinking_delta", "thinking", "猫"),
      delta(0, "signature_delta", "signature", "sig+"),
      delta(0, "signature_delta", "signature", "/="),
      block_stop(0),
      block_start(1, %{"type" => "text", "text" => ""}),
      block_stop(1),
      block_start(2, %{"type" => "redacted_thinking", "data" => "opaque+/="}),
      block_stop(2),
      block_start(3, %{"type" => "tool_use", "id" => "native", "name" => "read", "input" => %{}}),
      delta(3, "input_json_delta", "partial_json", "{\"path\":"),
      delta(3, "input_json_delta", "partial_json", "\"猫.txt\"}"),
      block_stop(3),
      block_start(4, %{"type" => "text", "text" => "done"}),
      delta(4, "text_delta", "text", "😀"),
      block_stop(4),
      ending("tool_use", %{"output_tokens" => 3}),
      ending("tool_use", %{"output_tokens" => 7}),
      %{"type" => "message_stop"}
    ]
  end
end
