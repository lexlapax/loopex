defmodule Loopex.Executor.Local.ArtifactRangeTest do
  use ExUnit.Case, async: true

  alias Loopex.Executor.Local.ArtifactRange
  alias LoopexProtocol.Frame

  @call "lx_0123456789abcdef0123456789abcdef0123456789abcdef"

  test "exact ranges keep the original reference and advance to the actual next offset" do
    reference = reference(20)
    assert {:ok, encoded} = ArtifactRange.encode(reference, 2, 4, "abcd")
    assert {:ok, result} = Frame.decode(encoded, 8_192)

    assert result == %{
             "artifact" => reference,
             "offset" => 2,
             "byte_count" => 4,
             "next_offset" => 6,
             "eof" => false,
             "content" => "abcd"
           }

    assert {:ok, encoded} = ArtifactRange.encode(reference, 18, 4, "xy")

    assert {:ok, %{"content" => "xy", "eof" => true, "next_offset" => 20}} =
             Frame.decode(encoded, 8_192)

    assert {:ok, encoded} = ArtifactRange.encode(reference, 20, 4, "")

    assert {:ok, %{"content" => "", "eof" => true, "byte_count" => 0}} =
             Frame.decode(encoded, 8_192)
  end

  test "a partial final codepoint shortens before EOF but cannot hide malformed bytes" do
    assert {:ok, encoded} = ArtifactRange.encode(reference(6), 0, 3, <<?a, 0xF0, 0x9F>>)

    assert {:ok, %{"content" => "a", "next_offset" => 1, "eof" => false}} =
             Frame.decode(encoded, 8_192)

    for {size, offset, bytes} <- [
          {6, 1, <<0x9F, 0x98, 0x80>>},
          {3, 0, <<?a, 0xF0, 0x9F>>},
          {6, 0, <<?a, 0xFF, ?b>>},
          {6, 0, <<0xED, 0xA0, 0x80>>},
          {6, 0, <<0xC0, 0xAF, ?b>>}
        ] do
      assert {:error, :artifact_range_unsupported_content} =
               ArtifactRange.encode(reference(size), offset, 3, bytes)
    end

    assert {:error, :artifact_range_unrepresentable} =
             ArtifactRange.encode(reference(4), 0, 1, <<0xF0>>)
  end

  test "JSON escaping and all metadata count, and the selected prefix is maximal" do
    bytes = :binary.copy(<<0>>, 4_096)
    reference = reference(4_096)
    assert {:ok, encoded} = ArtifactRange.encode(reference, 0, 4_096, bytes)
    assert message_size(encoded) <= 8_192
    assert {:ok, result} = Frame.decode(encoded, 8_192)
    assert result["byte_count"] in 1..4_095
    assert result["content"] == binary_part(bytes, 0, result["byte_count"])
    assert result["next_offset"] == result["byte_count"]
    refute result["eof"]
    assert encoded_size(extend(result, <<0>>)) > 8_192
  end

  test "UTF-8 and escaped ranges stay maximal across independently selected limits" do
    bytes = :binary.copy("😀\"\\\n\tα", 100)
    reference = reference(byte_size(bytes))

    for limit <- [750, 900, 1_024, 1_500, 2_048, 4_096, 8_192] do
      assert {:ok, encoded} =
               ArtifactRange.encode(reference, 0, byte_size(bytes), bytes, limit)

      assert message_size(encoded) <= limit
      assert {:ok, result} = Frame.decode(encoded, limit)
      count = result["byte_count"]
      assert count > 0
      assert String.valid?(result["content"])
      assert result["content"] == binary_part(bytes, 0, count)

      if count < byte_size(bytes) do
        {next, _rest} = String.next_codepoint(binary_part(bytes, count, byte_size(bytes) - count))
        assert encoded_size(extend(result, next)) > limit
      else
        assert result["eof"]
      end
    end
  end

  test "metadata that leaves no room for a character refuses rather than returning no progress" do
    assert {:ok, encoded} = ArtifactRange.encode(reference(1), 0, 1, "a")

    assert {:error, :artifact_range_unrepresentable} =
             ArtifactRange.encode(reference(1), 0, 1, "a", message_size(encoded) - 1)

    assert {:error, :artifact_range_unrepresentable} =
             ArtifactRange.encode(reference(0), 0, 1, "", 1)
  end

  test "the real conversation projector preserves the range within the complete-message ceiling" do
    bytes = :binary.copy(<<0>>, 4_096)
    assert {:ok, content} = ArtifactRange.encode(reference(4_096), 0, 4_096, bytes)
    original_id = String.duplicate("provider-id-", 200)

    elements = [
      %{
        kind: :assistant_message,
        run_id: "range-run",
        turn_number: 1,
        content: "",
        tool_calls: [%{tool_call_id: original_id, name: "read", arguments: %{}, generation: nil}]
      },
      %{
        kind: :tool_result,
        run_id: "range-run",
        turn_number: 1,
        tool_call_id: original_id,
        outcome: :completed,
        content: content
      }
    ]

    assert {:ok, entries} = Loopex.Conversation.lineage_entries(elements)

    {_source, message} =
      Enum.find(entries, fn {_source, message} -> message["role"] == "tool" end)

    assert message["content"] == content
    assert byte_size(message["tool_call_id"]) == 51
    assert message["tool_call_id"] != @call
    assert {:ok, frame} = Frame.encode(message)
    assert IO.iodata_length(frame) - 1 == message_size(content)
    assert IO.iodata_length(frame) - 1 <= 8_192
  end

  test "short, overlong and out-of-range windows cannot claim exact progress" do
    for {offset, length, bytes} <- [
          {0, 4, "abc"},
          {0, 4, "abcde"},
          {9, 1, "x"},
          {0, 0, ""},
          {0, 4_097, ""},
          {-1, 1, "x"}
        ] do
      assert {:error, :invalid_artifact_range} =
               ArtifactRange.encode(reference(8), offset, length, bytes)
    end
  end

  defp extend(result, next) do
    count = result["byte_count"] + byte_size(next)

    Map.merge(result, %{
      "content" => result["content"] <> next,
      "byte_count" => count,
      "next_offset" => result["offset"] + count,
      "eof" => result["offset"] + count == result["artifact"]["size"]
    })
  end

  defp encoded_size(result) do
    {:ok, frame} = Frame.encode(result)
    binary = IO.iodata_to_binary(frame)
    message_size(binary_part(binary, 0, byte_size(binary) - 1))
  end

  defp message_size(content) do
    {:ok, frame} =
      Frame.encode(%{
        "role" => "tool",
        "tool_call_id" => @call,
        "outcome" => "completed",
        "content" => content
      })

    IO.iodata_length(frame) - 1
  end

  defp reference(size) do
    digest = String.duplicate("a", 64)

    %{
      "digest" => digest,
      "size" => size,
      "locator" => digest,
      "media_type" => "text/plain",
      "role" => "tool_output",
      "use_canonicalization_version" => "loopex.canonical.v1",
      "use_digest" => digest,
      "use_locator" => "use:" <> digest
    }
  end
end
