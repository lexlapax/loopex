defmodule Loopex.ModelContinuationTest do
  use ExUnit.Case, async: true

  alias Loopex.Model
  alias Loopex.Model.{ContentReferences, Continuation}
  alias LoopexProtocol.Canonical

  test "expansion retains every binding and charges the full expanded envelope" do
    {envelope, messages} = exchange(2)
    assert {:ok, expanded} = Continuation.expand(envelope, "m", messages)

    for {entry, index} <- Enum.with_index(expanded["entries"]) do
      original = Enum.at(envelope["entries"], index)
      assert Map.drop(entry, ["capsule"]) == Map.drop(original, ["capsule"])

      assert entry["capsule"]["content"] == [
               %{
                 "type" => "tool_use",
                 "id" => "n#{index}",
                 "name" => "read",
                 "input" => %{"path" => "file"}
               }
             ]
    end

    bytes = Canonical.encode(expanded)

    assert Continuation.cost(envelope, "m", messages) ==
             {:ok,
              %{
                "content_digest" => Canonical.digest_bytes(bytes),
                "byte_cost" => byte_size(bytes),
                "token_cost" => div(byte_size(bytes) + 2, 3)
              }}

    assert {:ok, nil} = Continuation.cost(nil, "m", messages)
  end

  test "the request digest binds compact continuation and its canonical targets" do
    {envelope, messages} = exchange(1)
    options = [sampling: %{"max_tokens" => 64}, deadline: 123, continuation: envelope]
    assert {:ok, request} = Model.request("m", messages, options)
    assert :ok = Model.validate_request(request)

    assert {:error, :canonical_model_request_mismatch} =
             Model.validate_request(%{request | continuation: nil})

    changed = put_in(envelope, ["base_request_digest"], String.duplicate("b", 64))

    assert {:ok, other} =
             Model.request("m", messages, Keyword.put(options, :continuation, changed))

    refute request.staged_request_digest == other.staged_request_digest

    assert {:error, :canonical_model_request_mismatch} =
             Model.validate_request(%{
               request
               | canonicalization_version: "loopex.model_request.v1"
             })
  end

  test "closed source, entry, capsule and call bindings reject substituted or ambiguous targets" do
    {envelope, messages} = exchange(2)
    first = hd(envelope["entries"])

    for bad <- [
          Map.put(envelope, "extra", nil),
          Map.delete(envelope, "base_request_digest"),
          Map.put(envelope, "model", "elsewhere"),
          Map.put(envelope, "configuration_version", 1.0),
          Map.put(envelope, "base_request_digest", "BAD"),
          Map.put(envelope, "exchange_id", "other"),
          Map.put(envelope, "entries", []),
          Map.put(envelope, "entries", [first, first]),
          update_in(envelope, ["entries"], &Enum.reverse/1),
          change_first(envelope, ["source", "attempt"], 3),
          change_first(envelope, ["source", "settlement_digest"], "bad"),
          change_first(envelope, ["assistant_message_index"], -1),
          change_first(envelope, ["assistant_message_index"], 2.0),
          change_first(envelope, ["assistant_message_index"], 1024),
          change_first(envelope, ["capsule", "status"], "closed"),
          change_first(envelope, ["capsule", "model"], "other"),
          change_first(envelope, ["calls"], []),
          change_first(envelope, ["calls"], [
            %{"canonical_call_id" => "other", "native_id" => "n0", "result_message_index" => 3}
          ]),
          change_first(envelope, ["calls"], [
            %{"canonical_call_id" => "c0", "native_id" => "other", "result_message_index" => 3}
          ]),
          change_first(envelope, ["calls"], [
            %{"canonical_call_id" => "c0", "native_id" => "n0", "result_message_index" => 5}
          ])
        ] do
      assert {:error, :invalid_continuation} = Continuation.expand(bad, "m", messages)
    end

    for bad <- [
          List.replace_at(messages, 2, %{"role" => "user", "content" => ""}),
          List.update_at(messages, 2, &Map.put(&1, "tool_calls", [nil])),
          List.update_at(messages, 2, &Map.put(&1, "content", "unconsumed")),
          List.update_at(messages, 3, &Map.put(&1, "tool_call_id", "other"))
        ] do
      assert {:error, :invalid_continuation} = Continuation.expand(envelope, "m", bad)
    end
  end

  test "native identities remain disjoint from unmapped canonical history" do
    {envelope, messages} = exchange(2)

    prefix = [
      %{
        "role" => "assistant",
        "content" => "",
        "tool_calls" => [
          %{"tool_call_id" => "prior", "name" => "read", "arguments" => %{}}
        ]
      },
      %{
        "role" => "tool",
        "tool_call_id" => "prior",
        "content" => "done",
        "outcome" => "completed"
      }
    ]

    messages = Enum.take(messages, 2) ++ prefix ++ Enum.drop(messages, 2)

    envelope =
      update_in(envelope, ["entries"], fn entries ->
        Enum.map(entries, fn entry ->
          entry
          |> Map.update!("assistant_message_index", &(&1 + 2))
          |> Map.update!("calls", fn calls ->
            Enum.map(calls, &Map.update!(&1, "result_message_index", fn i -> i + 2 end))
          end)
        end)
      end)

    assert {:ok, _} = Continuation.expand(envelope, "m", messages)
    request = %{continuation: envelope, messages: messages}

    for id <- ["prior", "n0", "n1"] do
      assert {:error, :invalid_continuation} =
               Continuation.validate_reply_ids(
                 request,
                 %{"continuation" => %{}, "tool_calls" => [%{"id" => id}]}
               )
    end

    assert :ok =
             Continuation.validate_reply_ids(
               request,
               %{"continuation" => %{}, "tool_calls" => [%{"id" => "fresh"}]}
             )

    colliding =
      List.update_at(messages, 2, fn message ->
        put_in(message, ["tool_calls"], [
          %{"tool_call_id" => "n0", "name" => "read", "arguments" => %{}}
        ])
      end)

    assert {:error, :invalid_continuation} = Continuation.expand(envelope, "m", colliding)

    for malformed <- [
          nil,
          %{"role" => "assistant", "tool_calls" => nil},
          %{"role" => "assistant", "tool_calls" => [nil]}
        ] do
      assert {:error, :invalid_continuation} =
               Continuation.expand(envelope, "m", List.replace_at(messages, 2, malformed))
    end
  end

  test "aggregate entry and block ceilings are inclusive and cover all capsules" do
    {at, messages} = exchange(32)
    at = minimal_templates(at)
    assert {:ok, _} = ContentReferences.json_size(at)
    assert {:ok, _} = Continuation.expand(at, "m", messages)
    {over, messages} = exchange(33)
    over = minimal_templates(over)
    assert {:error, :invalid_continuation} = Continuation.expand(over, "m", messages)

    {envelope, messages} = exchange(2)

    at =
      update_in(envelope, ["entries"], fn entries ->
        Enum.map(entries, fn entry ->
          update_in(
            entry,
            ["capsule", "content"],
            &(&1 ++ List.duplicate(%{"kind" => "literal", "value" => %{}}, 63))
          )
        end)
      end)

    assert {:ok, _} = Continuation.expand(at, "m", messages)

    over =
      update_in(at, ["entries"], fn [first | rest] ->
        [
          update_in(
            first,
            ["capsule", "content"],
            &(&1 ++ [%{"kind" => "literal", "value" => %{}}])
          )
          | rest
        ]
      end)

    assert {:error, :invalid_continuation} = Continuation.expand(over, "m", messages)
  end

  test "both complete-envelope JSON ceilings include wrappers and source mappings" do
    {envelope, messages} = exchange(1)

    envelope =
      change_first(envelope, ["capsule", "content"], [
        %{"kind" => "literal", "value" => %{"private" => ""}},
        hd(hd(envelope["entries"])["capsule"]["content"])
      ])

    assert {:ok, fixed} = ContentReferences.json_size(envelope)
    at = padding(envelope, String.duplicate("x", 16_384 - fixed))
    assert {:ok, _} = Continuation.expand(at, "m", messages)

    assert {:error, :invalid_continuation} =
             Continuation.expand(
               padding(envelope, String.duplicate("x", 16_385 - fixed)),
               "m",
               messages
             )

    {envelope, messages} = exchange(1)
    messages = put_argument(messages, "")
    assert {:ok, expanded} = Continuation.expand(envelope, "m", messages)
    assert {:ok, fixed} = ContentReferences.json_size(expanded)
    at = put_argument(messages, String.duplicate("x", 16_384 - fixed))
    assert {:ok, expanded} = Continuation.expand(envelope, "m", at)
    assert {:ok, 16_384} = ContentReferences.json_size(expanded)

    assert {:error, :invalid_continuation} =
             Continuation.expand(
               envelope,
               "m",
               put_argument(messages, String.duplicate("x", 16_385 - fixed))
             )
  end

  defp minimal_templates(envelope) do
    update_in(envelope, ["entries"], fn entries ->
      Enum.map(entries, fn entry ->
        update_in(entry, ["capsule", "content"], fn [node] ->
          [%{node | "template" => %{}, "field" => "i"}]
        end)
      end)
    end)
  end

  defp padding(envelope, value) do
    update_in(envelope, ["entries"], fn [entry] ->
      [
        update_in(entry, ["capsule", "content"], fn [literal | rest] ->
          [put_in(literal, ["value", "private"], value) | rest]
        end)
      ]
    end)
  end

  defp put_argument(messages, value),
    do:
      List.update_at(messages, 2, fn message ->
        update_in(message, ["tool_calls"], fn [call] ->
          [put_in(call, ["arguments", "path"], value)]
        end)
      end)

  defp change_first(envelope, path, value),
    do:
      update_in(envelope, ["entries"], fn [first | rest] ->
        [put_in(first, path, value) | rest]
      end)

  defp exchange(count) do
    entries =
      for i <- 0..(count - 1) do
        %{
          "source" => %{
            "run_id" => "r",
            "turn_id" => "t#{i}",
            "operation_id" => "o#{i}",
            "attempt" => 1,
            "settlement_digest" => String.duplicate("d", 64)
          },
          "assistant_message_index" => 2 + 2 * i,
          "calls" => [
            %{
              "canonical_call_id" => "c#{i}",
              "native_id" => "n#{i}",
              "result_message_index" => 3 + 2 * i
            }
          ],
          "capsule" => %{
            "format" => "loopex.anthropic.content_refs.v1",
            "provider" => "anthropic",
            "model" => "m",
            "status" => "open",
            "content" => [
              %{
                "kind" => "tool_use_ref",
                "call_index" => 0,
                "native_id" => "n#{i}",
                "template" => %{"type" => "tool_use", "id" => "n#{i}", "name" => "read"},
                "field" => "input"
              }
            ]
          }
        }
      end

    envelope = %{
      "format" => "loopex.anthropic.content_refs.v1",
      "provider" => "anthropic",
      "model" => "m",
      "configuration_version" => 1,
      "exchange_id" => "o0",
      "base_request_digest" => String.duplicate("a", 64),
      "entries" => entries
    }

    messages =
      [%{"role" => "system", "content" => "system"}, %{"role" => "user", "content" => "go"}] ++
        Enum.flat_map(0..(count - 1), fn i ->
          [
            %{
              "role" => "assistant",
              "content" => "",
              "tool_calls" => [
                %{"tool_call_id" => "c#{i}", "name" => "read", "arguments" => %{"path" => "file"}}
              ]
            },
            %{
              "role" => "tool",
              "tool_call_id" => "c#{i}",
              "content" => "result",
              "outcome" => "completed"
            }
          ]
        end)

    {envelope, messages}
  end
end
