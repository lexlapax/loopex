defmodule Loopex.Runtime.CompactionSummaryTest do
  @moduledoc false
  use ExUnit.Case, async: true
  alias Loopex.Runtime.CompactionSummary
  alias LoopexProtocol.Frame

  defp output(summary \\ "Goal, constraints, progress and next steps.") do
    %{
      "summary" => summary,
      "carry_forward" => %{"files_read" => ["lib/a.ex"], "files_changed" => []}
    }
  end

  defp json(value) do
    {:ok, bytes} = Frame.encode(%{"v" => value})
    bytes = IO.iodata_to_binary(bytes)
    binary_part(bytes, 5, byte_size(bytes) - 7)
  end

  defp request do
    {:ok, request} =
      Loopex.Model.request("scripted:summary", [%{"role" => "user", "content" => "source"}],
        sampling: %{"max_tokens" => 1_024},
        deadline: 1_000_000
      )

    request
  end

  defp reply(request, text \\ nil) do
    %{
      text: text || json(output()),
      identity: %{provider: "scripted", model: request.model, endpoint: "in-process"},
      usage: %{input_tokens: 37, output_tokens: 19},
      tool_calls: [],
      delta_count: 0,
      streamed: false,
      provider_response_id: nil,
      canonical_request_bytes: request.canonical_request_bytes,
      staged_request_digest: request.staged_request_digest,
      completion: "natural",
      continuation: nil
    }
  end

  test "natural complete output retains its canonical reply and usage" do
    request = request()
    assert {:ok, canonical, {:ok, summary}} = CompactionSummary.admit(reply(request), request)
    assert summary == output()
    assert canonical["completion"] == "natural"
    assert canonical["continuation"] == nil

    assert canonical["usage"] == %{
             "status" => "reported",
             "input_tokens" => 37,
             "output_tokens" => 19
           }

    refute Map.has_key?(canonical, "canonical_request_bytes")

    assert {:ok, _, {:ok, summary}} =
             CompactionSummary.admit(
               reply(request, " \t\n" <> json(output()) <> "\r\n "),
               request
             )

    assert summary == output()
  end

  test "length and unknown completion precede invalid JSON and tool calls without discarding usage" do
    request = request()

    for completion <- ["limit", "unknown"], text <- [json(output()), "not JSON"] do
      raw = %{
        reply(request, text)
        | completion: completion,
          tool_calls: [%{id: "unexpected", name: "bash", arguments: %{}}]
      }

      assert {:ok, canonical, {:error, :maintenance_summary_incomplete}} =
               CompactionSummary.admit(raw, request)

      assert canonical["usage"]["output_tokens"] == 19
      assert length(canonical["tool_calls"]) == 1
    end
  end

  test "nine-key v2 is incomplete and eight-key callbacks are unreadable" do
    request = request()
    v2 = Map.drop(reply(request), [:completion, :continuation])
    assert map_size(v2) == 9

    assert {:ok, canonical, {:error, :maintenance_summary_incomplete}} =
             CompactionSummary.admit(v2, request)

    assert canonical["usage"]["status"] == "reported"

    assert CompactionSummary.admit(Map.delete(v2, :provider_response_id), request) ==
             {:error, :unreadable_model_answer}
  end

  test "natural replies with tool calls or private continuation cannot create summaries" do
    request = request()
    raw = %{reply(request) | tool_calls: [%{id: "bash", name: "bash", arguments: %{}}]}

    assert {:ok, canonical, {:error, :maintenance_summary_invalid}} =
             CompactionSummary.admit(raw, request)

    assert canonical["usage"]["input_tokens"] == 37

    assert CompactionSummary.admit(%{reply(request) | continuation: %{}}, request) ==
             {:error, :unreadable_model_answer}
  end

  test "output is closed JSON and no repair removes duplicates, fences or unknown fields" do
    request = request()

    for invalid <- [
          "not JSON",
          "```json\n" <> json(output()) <> "\n```",
          "[]",
          "{}",
          json(Map.put(output(), "source_excerpted", false)),
          json(%{output() | "carry_forward" => %{"files_read" => []}}),
          "{\"summary\":\"first\",\"summary\":\"second\",\"carry_forward\":{\"files_read\":[],\"files_changed\":[]}}",
          "\u00a0" <> json(output()),
          json(output()) <> " extra"
        ] do
      assert {:ok, canonical, {:error, :maintenance_summary_invalid}} =
               CompactionSummary.admit(reply(request, invalid), request)

      assert canonical["usage"]["status"] == "reported"
      assert canonical["text"] == invalid
    end
  end

  test "summary limit includes quotes and escaping with exact cap edges" do
    assert :ok = CompactionSummary.validate(output(String.duplicate("x", 4_094)))

    assert CompactionSummary.validate(output(String.duplicate("x", 4_095))) ==
             {:error, :maintenance_summary_invalid}

    assert :ok = CompactionSummary.validate(output(String.duplicate("\0", 682)))

    assert CompactionSummary.validate(output(String.duplicate("\0", 683))) ==
             {:error, :maintenance_summary_invalid}

    assert :ok = CompactionSummary.validate(output(""))
    assert CompactionSummary.validate(output(<<255>>)) == {:error, :maintenance_summary_invalid}
  end

  test "carry-forward paths, lists and combined encoded size have independent bounds" do
    for field <- ~w(files_read files_changed) do
      assert :ok =
               CompactionSummary.validate(
                 put_in(output(), ["carry_forward", field], List.duplicate("a", 32))
               )

      for paths <- [List.duplicate("a", 33), [String.duplicate("a", 1_025)], [<<255>>], [1]] do
        assert CompactionSummary.validate(put_in(output(), ["carry_forward", field], paths)) ==
                 {:error, :maintenance_summary_invalid}
      end
    end

    carry = %{"files_read" => [String.duplicate("a", 1_024), ""], "files_changed" => []}

    second_size =
      Enum.find(0..1_024, fn count ->
        byte_size(
          json(%{
            carry
            | "files_read" => [String.duplicate("a", 1_024), String.duplicate("b", count)]
          })
        ) == 2_048
      end)

    carry = %{
      carry
      | "files_read" => [String.duplicate("a", 1_024), String.duplicate("b", second_size)]
    }

    assert :ok = CompactionSummary.validate(%{output() | "carry_forward" => carry})

    assert CompactionSummary.validate(%{
             output(String.duplicate("x", 4_094))
             | "carry_forward" => carry
           }) ==
             {:error, :maintenance_summary_invalid}

    oversized = %{
      carry
      | "files_read" => [String.duplicate("a", 1_024), String.duplicate("b", second_size + 1)]
    }

    assert CompactionSummary.validate(%{output() | "carry_forward" => oversized}) ==
             {:error, :maintenance_summary_invalid}

    assert CompactionSummary.validate(put_in(output(), ["carry_forward", "extra"], [])) ==
             {:error, :maintenance_summary_invalid}
  end

  test "raw callback admission rejects changed request bytes and oversized usage before summary processing" do
    request = request()

    for raw <- [
          %{reply(request) | canonical_request_bytes: "different"},
          %{
            reply(request)
            | usage: %{input_tokens: 37, output_tokens: 19, extra: String.duplicate("x", 65_536)}
          },
          Map.delete(reply(request), :continuation)
        ] do
      assert CompactionSummary.admit(raw, request) == {:error, :unreadable_model_answer}
    end
  end
end
