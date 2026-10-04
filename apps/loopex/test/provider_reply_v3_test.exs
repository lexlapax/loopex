defmodule Loopex.Runtime.ProviderReplyV3Test do
  use ExUnit.Case, async: true
  alias Loopex.Model
  alias Loopex.Runtime.ProviderAttempt

  test "only eleven-field current callbacks produce the ten-field canonical reply" do
    request = request()
    raw = reply(request)
    assert map_size(raw) == 11
    assert {:ok, projected} = ProviderAttempt.canonical_reply(raw, request, false)
    assert map_size(projected) == 10
    assert projected["continuation"] == nil
    assert projected["completion"] == "unknown"
    assert projected["provider_response_id"] == nil

    assert projected["usage"] == %{
             "status" => "reported",
             "input_tokens" => 3,
             "output_tokens" => 2
           }

    refute Map.has_key?(projected, "canonical_request_bytes")
    assert projected["staged_request_digest"] == request.staged_request_digest

    assert {:error, :unreadable_model_answer} =
             ProviderAttempt.canonical_reply(raw, request, true)

    retired = Map.drop(raw, ~w(completion continuation))
    assert map_size(retired) == 9

    for required <- [false, true] do
      assert ProviderAttempt.canonical_reply(retired, request, required) ==
               {:error, :unreadable_model_answer}
    end
  end

  test "retired, incomplete and extra callback members reject before accounting" do
    request = request()
    raw = reply(request)

    for invalid <- [
          Map.delete(raw, "provider_response_id"),
          Map.delete(raw, "completion"),
          Map.delete(raw, "continuation"),
          Map.drop(raw, ~w(completion continuation provider_response_id)),
          Map.put(raw, "extra", "unused"),
          Map.merge(raw, %{"completion" => "natural", "continuation" => nil, "extra" => nil})
        ] do
      assert {:error, :unreadable_model_answer} =
               ProviderAttempt.canonical_reply(invalid, request, false)
    end

    assert {:ok, current} = ProviderAttempt.canonical_reply(raw, request, false)
    assert map_size(current) == 10
    assert current["continuation"] == nil
    assert current["completion"] == "unknown"
    refute function_exported?(ProviderAttempt, :canonical_reply, 2)
  end

  test "nil-capsule v3 preserves the closed completion class" do
    request = request()

    for completion <- ~w(natural limit unknown) do
      raw = Map.merge(reply(request), %{"completion" => completion, "continuation" => nil})
      assert {:ok, projected} = ProviderAttempt.canonical_reply(raw, request, false)
      assert projected["completion"] == completion
      assert projected["continuation"] == nil

      assert {:error, :unreadable_model_answer} =
               ProviderAttempt.canonical_reply(raw, request, true)
    end

    for completion <- [nil, "future", :natural, 1] do
      raw = Map.merge(reply(request), %{"completion" => completion, "continuation" => nil})

      assert {:error, :unreadable_model_answer} =
               ProviderAttempt.canonical_reply(raw, request, false)
    end
  end

  test "a required closed capsule binds its exact model and consumes all canonical text" do
    request = request()

    raw =
      Map.merge(reply(request), %{"completion" => "natural", "continuation" => capsule(request)})

    assert {:ok, projected} = ProviderAttempt.canonical_reply(raw, request, true)
    assert projected["continuation"] == raw["continuation"]
    assert projected["text"] == "é"

    assert {:error, :unreadable_model_answer} =
             ProviderAttempt.canonical_reply(raw, request, false)

    for change <- [
          %{"model" => "anthropic:other"},
          %{"status" => "open"},
          %{"extra" => nil},
          %{"content" => [text(1)]},
          %{"content" => [text(0)]},
          %{"provider" => "other"}
        ] do
      bad = %{raw | "continuation" => Map.merge(raw["continuation"], change)}

      assert {:error, :unreadable_model_answer} =
               ProviderAttempt.canonical_reply(bad, request, true)
    end

    for completion <- ~w(limit unknown) do
      assert {:error, :unreadable_model_answer} =
               ProviderAttempt.canonical_reply(%{raw | "completion" => completion}, request, true)
    end
  end

  test "open capsule arguments and native identities bind the original canonical calls" do
    request = request()
    call = %{"id" => "native", "name" => "read", "arguments" => %{"path" => "猫.txt"}}
    content = [text(2), tool(0, "native")]
    capsule = %{capsule(request) | "status" => "open", "content" => content}

    raw =
      Map.merge(reply(request), %{
        "completion" => "natural",
        "continuation" => capsule,
        "tool_calls" => [call]
      })

    assert {:ok, projected} = ProviderAttempt.canonical_reply(raw, request, true)
    assert projected["tool_calls"] == [call]
    assert projected["continuation"] == capsule

    for bad <- [
          %{raw | "tool_calls" => []},
          %{raw | "tool_calls" => [%{call | "id" => "other"}]},
          %{raw | "continuation" => %{capsule | "content" => [text(2), tool(1, "native")]}},
          %{
            raw
            | "tool_calls" => [call, call],
              "continuation" => %{
                capsule
                | "content" => [text(2), tool(0, "native"), tool(1, "native")]
              }
          }
        ] do
      assert {:error, :unreadable_model_answer} =
               ProviderAttempt.canonical_reply(bad, request, true)
    end
  end

  test "malformed and oversized capsules cannot retain a plausible reported usage pair" do
    request = request()

    raw =
      Map.merge(reply(request), %{"completion" => "natural", "continuation" => capsule(request)})

    for content <- [
          [%{"kind" => "literal", "value" => %{"opaque" => self()}}, text(2)],
          [
            %{"kind" => "literal", "value" => %{"opaque" => String.duplicate("x", 16_384)}},
            text(2)
          ],
          List.duplicate(text(0), 129),
          [
            %{
              "kind" => "text_ref",
              "byte_length" => 2,
              "template" => %{"text" => "overwrite"},
              "field" => "text"
            }
          ]
        ] do
      bad = %{raw | "continuation" => %{raw["continuation"] | "content" => content}}

      assert {:error, :unreadable_model_answer} =
               ProviderAttempt.canonical_reply(bad, request, true)
    end
  end

  test "atom callback keys normalize once and duplicate spellings refuse" do
    request = request()
    raw = reply(request)

    atom_raw = %{
      text: raw["text"],
      identity: raw["identity"],
      usage: raw["usage"],
      tool_calls: [],
      delta_count: 0,
      streamed: false,
      provider_response_id: nil,
      staged_request_digest: raw["staged_request_digest"],
      canonical_request_bytes: raw["canonical_request_bytes"],
      completion: "natural",
      continuation: nil
    }

    assert {:ok, _} = ProviderAttempt.canonical_reply(atom_raw, request, false)

    assert {:error, :unreadable_model_answer} =
             ProviderAttempt.canonical_reply(
               Map.put(atom_raw, "completion", "natural"),
               request,
               false
             )
  end

  test "v3 retains ordinary echo, digest, stream and closed usage checks" do
    request = request()
    raw = Map.merge(reply(request), %{"completion" => "natural", "continuation" => nil})

    for changes <- [
          %{"canonical_request_bytes" => "other"},
          %{"staged_request_digest" => String.duplicate("0", 64)},
          %{"streamed" => true},
          %{"usage" => %{"input_tokens" => 1, "output_tokens" => 2, "extra" => 3}},
          %{"provider_response_id" => String.duplicate("x", 257)}
        ] do
      assert {:error, :unreadable_model_answer} =
               ProviderAttempt.canonical_reply(Map.merge(raw, changes), request, false)
    end

    assert {:ok, projected} =
             ProviderAttempt.canonical_reply(
               %{raw | "usage" => %{"output_tokens" => -1}},
               request,
               false
             )

    assert projected["usage"] == %{"status" => "unreported", "category" => "malformed"}
  end

  test "v3 settlement decoders retain ten-field replies and reject generation relabeling" do
    request = request()

    raw =
      Map.merge(reply(request), %{"completion" => "natural", "continuation" => capsule(request)})

    {:ok, projected} = ProviderAttempt.canonical_reply(raw, request, true)
    record = settlement(request, projected)
    assert :ok = ProviderAttempt.validate_settled(record)
    assert :ok = ProviderAttempt.validate_settled(record, request, true)

    assert {:error, :unreadable_model_answer} =
             ProviderAttempt.validate_settled(record, request, false)

    assert {:error, _} =
             ProviderAttempt.validate_settled(%{record | kind: "model_attempt_settled_v2"})

    assert {:error, _} =
             ProviderAttempt.validate_settled(%{record | kind: "model_attempt_settled_v1"})

    old_reply = Map.drop(projected, ~w(completion continuation))

    assert {:error, _} =
             ProviderAttempt.validate_settled(%{
               record
               | "result" => %{"kind" => "reply", "reply" => old_reply}
             })

    changed_request = %{request | model: "anthropic:other"}

    assert {:error, :unreadable_model_answer} =
             ProviderAttempt.validate_settled(record, changed_request, true)

    for change <- [
          %{"completion" => "limit"},
          %{"completion" => "future"},
          %{"extra" => nil},
          %{"continuation" => Map.put(projected["continuation"], "extra", nil)}
        ] do
      bad = %{record | "result" => %{"kind" => "reply", "reply" => Map.merge(projected, change)}}
      assert {:error, _} = ProviderAttempt.validate_settled(bad)
    end
  end

  defp request do
    {:ok, request} =
      Model.request(
        "anthropic:claude-haiku-4-5-20251001",
        [%{"role" => "user", "content" => "go"}],
        sampling: %{"max_tokens" => 512},
        deadline: 123_456
      )

    request
  end

  defp settlement(request, reply),
    do: %{
      :kind => "model_attempt_settled_v3",
      "run_id" => "r",
      "turn_id" => "t",
      "operation_id" => "o",
      "attempt" => 1,
      "staged_request_digest" => request.staged_request_digest,
      "transport" => "dispatched_or_unknown",
      "termination" => nil,
      "conversation" => "canonical",
      "next" => "terminal",
      "result" => %{"kind" => "reply", "reply" => reply},
      "accounting" => %{"source" => "reported", "input_tokens" => 3, "output_tokens" => 2}
    }

  defp reply(request),
    do: %{
      "completion" => "unknown",
      "continuation" => nil,
      "text" => "é",
      "identity" => %{
        "provider" => "anthropic",
        "model" => "claude-haiku-4-5-20251001",
        "endpoint" => "https://fixture.invalid"
      },
      "usage" => %{"input_tokens" => 3, "output_tokens" => 2},
      "tool_calls" => [],
      "delta_count" => 0,
      "streamed" => false,
      "provider_response_id" => nil,
      "canonical_request_bytes" => request.canonical_request_bytes,
      "staged_request_digest" => request.staged_request_digest
    }

  defp capsule(request),
    do: %{
      "format" => "loopex.anthropic.content_refs.v1",
      "provider" => "anthropic",
      "model" => request.model,
      "status" => "closed",
      "content" => [text(2)]
    }

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
