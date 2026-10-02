defmodule Loopex.ToolResultExcerptTest do
  use ExUnit.Case, async: true

  alias Loopex.Runtime.ToolResultExcerpt
  alias LoopexProtocol.Frame

  @call "lx_" <> String.duplicate("a", 48)

  test "excerpt offsets and digests describe receipt text rather than artifact bytes" do
    source = "receipt notice: retained bytes differ"
    original = message(source, "failed")
    reference = reference()
    assert {:ok, result} = ToolResultExcerpt.encode(original, reference, 7)
    assert result.message["tool_call_id"] == @call
    assert result.message["outcome"] == "failed"
    assert {:ok, notice} = Frame.decode(result.message["content"], 2_048)

    assert notice == %{
             "use_locator" => reference.use_locator,
             "object_digest" => reference.digest,
             "object_size" => reference.size,
             "excerpt_source" => "receipt_content",
             "source_byte_count" => byte_size(source),
             "excerpt_offset" => 0,
             "excerpt_byte_count" => 7,
             "excerpt" => "receipt",
             "omitted" => true
           }

    assert result.source_range == %{
             "source_digest" => sha(source),
             "source_byte_count" => byte_size(source),
             "offset" => 0,
             "byte_count" => 7
           }

    assert source == original["content"]
  end

  test "zero allowance keeps a result and empty sources are complete" do
    for source <- ["", "retained"] do
      assert {:ok, result} = ToolResultExcerpt.encode(message(source), reference(), 0)
      assert {:ok, notice} = Frame.decode(result.message["content"], 2_048)
      assert notice["excerpt"] == ""
      assert notice["excerpt_byte_count"] == 0
      assert notice["omitted"] == (source != "")
      assert notice["use_locator"] == reference().use_locator
    end
  end

  test "raw allowance and complete-message escaping independently bound a maximal UTF-8 prefix" do
    for source <- [
          String.duplicate("a", 4_096),
          String.duplicate("猫😀", 600),
          :binary.copy(<<0, ?\", ?\\, ?\n>>, 1_024)
        ],
        allowance <- [0, 1, 2, 3, 7, 127, 255, 512, 1_024, 2_048] do
      assert {:ok, result} = ToolResultExcerpt.encode(message(source), reference(), allowance)
      assert json_size(result.message) <= 2_048
      assert {:ok, notice} = Frame.decode(result.message["content"], 2_048)
      count = notice["excerpt_byte_count"]
      assert count <= allowance
      assert notice["excerpt"] == binary_part(source, 0, count)
      assert String.valid?(notice["excerpt"])

      if count < byte_size(source) do
        {point, _} = String.next_codepoint(binary_part(source, count, byte_size(source) - count))
        next_count = count + byte_size(point)

        larger = %{
          notice
          | "excerpt" => notice["excerpt"] <> point,
            "excerpt_byte_count" => next_count,
            "omitted" => next_count < byte_size(source)
        }

        projected = %{result.message | "content" => json(larger)}
        assert next_count > allowance or json_size(projected) > 2_048
      end
    end
  end

  test "one shared raw allowance saturates short sources and preserves every terminal outcome" do
    for outcome <- ~w(completed failed denied cancelled outcome_unknown),
        source <- ["a", "猫", "line\nquote\""] do
      assert {:ok, result} =
               ToolResultExcerpt.encode(message(source, outcome), reference(), 2_048)

      assert result.message["outcome"] == outcome
      assert {:ok, notice} = Frame.decode(result.message["content"], 2_048)
      assert notice["excerpt"] == source
      assert notice["omitted"] == false
    end
  end

  test "binary sources have one fixed description and retain their exact source digest" do
    source = <<255, 0, 195>>
    assert {:ok, zero} = ToolResultExcerpt.encode(message(source), reference(), 0)
    assert {:ok, full} = ToolResultExcerpt.encode(message(source), reference(), 2_048)
    assert zero == full
    assert zero.source_range["source_digest"] == sha(source)
    assert {:ok, notice} = Frame.decode(zero.message["content"], 2_048)
    assert notice["description"] == "Binary receipt content."
    assert notice["excerpt"] == ""
    assert notice["excerpt_byte_count"] == 0
    assert notice["source_byte_count"] == 3
    assert notice["omitted"]
  end

  test "unrepresentable metadata refuses instead of dropping the result" do
    oversized = %{message("a") | "tool_call_id" => String.duplicate("i", 2_048)}

    assert {:error, :artifact_metadata_unrepresentable} =
             ToolResultExcerpt.encode(oversized, reference(), 0)
  end

  test "malformed inputs do not manufacture a projection" do
    for invalid <- [
          Map.put(message("a"), "extra", true),
          %{message("a") | "role" => "assistant"},
          %{message("a") | "tool_call_id" => <<255>>},
          %{message("a") | "outcome" => "invented"}
        ] do
      assert {:error, :context_projection_invalid} =
               ToolResultExcerpt.encode(invalid, reference())
    end

    for allowance <- [-1, 2_049, 1.0, nil] do
      assert {:error, :context_projection_invalid} =
               ToolResultExcerpt.encode(message("a"), reference(), allowance)
    end

    assert {:error, :context_projection_invalid} = ToolResultExcerpt.encode(message("a"), %{})
  end

  defp message(source, outcome \\ "completed"),
    do: %{"role" => "tool", "tool_call_id" => @call, "outcome" => outcome, "content" => source}

  defp reference do
    digest = String.duplicate("b", 64)

    %{
      digest: digest,
      size: 32_768,
      locator: digest,
      media_type: "text/plain",
      role: "tool_output",
      use_canonicalization_version: "loopex.canonical.v1",
      use_digest: digest,
      use_locator: "use:" <> digest
    }
  end

  defp sha(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
  defp json_size(value), do: byte_size(json(value))

  defp json(value) do
    {:ok, frame} = Frame.encode(value)
    bytes = IO.iodata_to_binary(frame)
    binary_part(bytes, 0, byte_size(bytes) - 1)
  end
end
