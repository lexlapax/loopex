defmodule Loopex.Runtime.CompactionSourceTest do
  @moduledoc false
  use ExUnit.Case, async: true
  alias Loopex.Runtime.CompactionSource
  alias LoopexProtocol.{Canonical, Frame}

  defp check, do: :ok

  defp source(messages, prior \\ nil, form \\ :complete),
    do: CompactionSource.encode(messages, prior, form, &check/0)

  defp json(value) do
    {:ok, bytes} = Frame.encode(%{"v" => value})
    bytes = IO.iodata_to_binary(bytes)
    binary_part(bytes, 5, byte_size(bytes) - 7)
  end

  defp user(text), do: %{"role" => "user", "content" => text}

  defp prior do
    %{
      "covered_range_digest" => String.duplicate("a", 64),
      "summary" => "Earlier facts",
      "carry_forward" => %{"files_read" => ["lib/a.ex"], "files_changed" => []},
      "source_excerpted" => true
    }
  end

  test "complete source matches the independent compact JSON recipe with exact calls and outcomes" do
    messages = [
      user("\"\\\b\f\n\r\t\0\x01é🐈"),
      %{
        "role" => "assistant",
        "content" => "do it",
        "tool_calls" => [
          %{
            "tool_call_id" => "lx_call",
            "tool_id" => "loopex.read",
            "tool_version" => "1.1.0",
            "definition_digest" => "digest",
            "arguments" => %{"path" => "lib/a.ex"}
          }
        ]
      },
      %{
        "role" => "tool",
        "tool_call_id" => "lx_call",
        "outcome" => "failed",
        "content" => "failed"
      }
    ]

    assert {:ok, [candidate]} = source(messages, prior())

    expected =
      json(%{
        "version" => "loopex.compaction.source.v2",
        "prior_checkpoint" => prior(),
        "messages" => %{"kind" => "complete", "value" => messages}
      })

    assert candidate.bytes == expected
    assert candidate.digest == Canonical.digest_bytes(expected)
    refute candidate.source_excerpted
    assert candidate.quota == nil
    assert {:ok, decoded} = Frame.decode(candidate.bytes, 16_384)
    assert decoded["prior_checkpoint"] == prior()
    assert decoded["messages"]["value"] == messages
  end

  test "source cap includes envelope framing and prior checkpoint once" do
    for prior <- [nil, prior()] do
      count =
        Enum.find(16_000..16_384, fn count ->
          byte_size(
            json(%{
              "version" => "loopex.compaction.source.v2",
              "prior_checkpoint" => prior,
              "messages" => %{
                "kind" => "complete",
                "value" => [user(String.duplicate("x", count))]
              }
            })
          ) == 16_384
        end)

      assert is_integer(count)
      assert {:ok, [candidate]} = source([user(String.duplicate("x", count))], prior)
      assert byte_size(candidate.bytes) == 16_384
      assert {:ok, []} = source([user(String.duplicate("x", count + 1))], prior)
    end
  end

  test "large lazy source retains exact whole-list count and digest with disjoint UTF-8 ends" do
    message = user(String.duplicate("🐈é\"\\\n", 500))
    messages = Stream.repeatedly(fn -> message end) |> Stream.take(200)
    serialized = json(List.duplicate(message, 200))
    assert {:ok, candidates} = source(messages, prior(), :excerpt)
    assert Enum.map(candidates, & &1.quota) == [4_096, 2_048, 1_024, 512]

    for candidate <- candidates do
      assert byte_size(candidate.bytes) <= 16_384
      assert candidate.digest == Canonical.digest_bytes(candidate.bytes)
      assert candidate.source_excerpted
      assert {:ok, decoded} = Frame.decode(candidate.bytes, 16_384)
      excerpt = decoded["messages"]
      assert excerpt["encoding"] == "loopex.compaction.messages_json.v1"
      assert excerpt["byte_length"] == byte_size(serialized)
      assert excerpt["sha256"] == Canonical.digest_bytes(serialized)
      [prefix, suffix] = excerpt["fragments"]
      assert prefix["offset"] == 0
      assert suffix["offset"] > byte_size(prefix["text"])
      assert suffix["offset"] + byte_size(suffix["text"]) == byte_size(serialized)

      for fragment <- [prefix, suffix] do
        text = fragment["text"]
        assert String.valid?(text)
        assert byte_size(text) in candidate.quota..(candidate.quota + 3)
        assert binary_part(serialized, fragment["offset"], byte_size(text)) == text

        if byte_size(text) > candidate.quota do
          smaller =
            if fragment == prefix,
              do: binary_part(text, 0, byte_size(text) - 1),
              else: binary_part(text, 1, byte_size(text) - 1)

          refute String.valid?(smaller)
        end
      end
    end
  end

  test "JSON double escaping can discard larger quotas without changing quota order" do
    message = user(String.duplicate("\"\\", 4_000))
    assert {:ok, candidates} = source([message], prior(), :excerpt)
    assert Enum.map(candidates, & &1.quota) == [2_048, 1_024, 512]
    assert Enum.all?(candidates, &(byte_size(&1.bytes) <= 16_384))
  end

  test "excerpt requires nonempty disjoint fragments and an omitted middle" do
    assert source([user("short")], nil, :excerpt) ==
             {:error, :compaction_excerpt_budget_too_small}

    for count <- [980, 982] do
      assert source([user(String.duplicate("x", count))], nil, :excerpt) ==
               {:error, :compaction_excerpt_budget_too_small}
    end

    assert {:ok, [candidate]} = source([user(String.duplicate("x", 1_100))], nil, :excerpt)
    assert candidate.quota == 512
  end

  test "unresolved calls retain their exact names and nested plain arguments" do
    calls = [
      %{
        "tool_call_id" => "missing",
        "name" => "unknown",
        "arguments" => %{"nested" => [%{"flag" => true, "none" => nil, "count" => -7}, false]}
      }
    ]

    message = %{"role" => "assistant", "content" => "", "tool_calls" => calls}
    assert {:ok, [candidate]} = source([message])
    assert {:ok, decoded} = Frame.decode(candidate.bytes, 16_384)
    assert decoded["messages"]["value"] == [message]

    for invalid <- [
          Map.put(hd(calls), "private", "hidden"),
          %{hd(calls) | "arguments" => %{}}
          |> Map.put("name", nil)
        ] do
      assert source([%{message | "tool_calls" => [invalid]}]) ==
               {:error, :context_projection_invalid}
    end
  end

  test "numeric arguments preserve admitted floats and arbitrarily large integers" do
    integer = Integer.pow(10, 3_000)

    message = %{
      "role" => "assistant",
      "content" => "",
      "tool_calls" => [
        %{
          "tool_call_id" => "numbers",
          "name" => "unknown",
          "arguments" => %{"ratio" => 0.125, "negative_zero" => -0.0, "large" => integer}
        }
      ]
    }

    assert {:ok, [candidate]} = source([message])

    expected =
      "{\"messages\":{\"kind\":\"complete\",\"value\":[{\"content\":\"\",\"role\":\"assistant\",\"tool_calls\":[{\"arguments\":{\"large\":" <>
        Integer.to_string(integer) <>
        ",\"negative_zero\":-0.0,\"ratio\":0.125},\"name\":\"unknown\",\"tool_call_id\":\"numbers\"}]}]},\"prior_checkpoint\":null,\"version\":\"loopex.compaction.source.v2\"}"

    assert candidate.bytes == expected
    assert candidate.digest == Canonical.digest_bytes(expected)
  end

  test "deadline and cancellation checks stop before later lazy messages are read" do
    messages =
      Stream.map(1..100, fn index ->
        send(self(), {:read_message, index})
        user(String.duplicate("x", 10_000))
      end)

    for refusal <- [:cancelled, :deadline] do
      Process.put(:source_checks, 0)

      check = fn ->
        count = Process.get(:source_checks) + 1
        Process.put(:source_checks, count)
        if count == 8, do: {:error, refusal}, else: :ok
      end

      assert CompactionSource.encode(messages, nil, :excerpt, check) == {:error, refusal}
      assert_receive {:read_message, 1}
      refute_receive {:read_message, 2}, 0
      assert Process.get(:source_checks) == 8
    end
  end

  test "invalid text, hidden fields, system messages and malformed prior data are refused" do
    for messages <- [
          [],
          nil,
          [user(<<255>>)],
          [%{"role" => "system", "content" => "host"}],
          [Map.put(user("go"), "continuation", %{})],
          [%{"role" => "assistant", "content" => "go", "tool_calls" => [%{private: "data"}]}]
        ] do
      assert source(messages) == {:error, :context_projection_invalid}
    end

    for invalid <- [
          Map.put(prior(), "extra", true),
          %{prior() | "summary" => <<255>>},
          %{prior() | "summary" => String.duplicate("\0", 700)},
          %{
            prior()
            | "carry_forward" => %{"files_read" => List.duplicate("a", 33), "files_changed" => []}
          },
          %{
            prior()
            | "carry_forward" => %{
                "files_read" => [String.duplicate("x", 1_025)],
                "files_changed" => []
              }
          },
          %{prior() | "covered_range_digest" => String.duplicate("A", 64)}
        ] do
      assert source([user("go")], invalid) == {:error, :context_projection_invalid}
    end
  end
end
