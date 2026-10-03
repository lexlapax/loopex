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

  defp select(units, preflight \\ fn _, _ -> :ok end),
    do: CompactionSource.select(units, nil, preflight, &check/0)

  defp decode(candidate) do
    {:ok, decoded} = Frame.decode(candidate.bytes, 16_384)
    decoded["messages"]
  end

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

  test "selection retains the largest full-request-admissible whole prefix" do
    units = Enum.map(1..3, &[user(String.duplicate(Integer.to_string(&1), 4_000))])

    preflight = fn candidate, _count ->
      if byte_size(candidate.bytes) < 10_000, do: :ok, else: {:refused, :record_bytes}
    end

    assert {:ok, selected} = select(units, preflight)
    assert selected.unit_count == 2
    refute selected.source.source_excerpted
    assert decode(selected.source)["value"] == Enum.concat(Enum.take(units, 2))

    assert {:ok, all} = select(units)
    assert all.unit_count == 3
    assert decode(all.source)["value"] == Enum.concat(units)
  end

  test "whole-request preflight receives the actual covered-unit count" do
    units = [[user(String.duplicate("x", 7_000))], [user("later")]]

    preflight = fn candidate, count ->
      send(self(), {:candidate, count, candidate.source_excerpted})
      if count == 1, do: :ok, else: {:refused, :range_metadata_budget}
    end

    assert {:ok, %{unit_count: 1}} = select(units, preflight)
    assert_receive {:candidate, 1, false}
    assert_receive {:candidate, 2, false}

    small = [[user("small")], [user("next")]]
    assert {:error, :compaction_excerpt_budget_too_small} == select(small, preflight)
    assert_receive {:candidate, 1, false}
    assert_receive {:candidate, 2, false}
    refute_receive {:candidate, 1, true}, 0
  end

  test "a small prefix consumes the next oversized whole unit and never reads later units" do
    messages = [user("earlier"), user(String.duplicate("x", 30_000))]
    later = Stream.map([:later], fn _ -> flunk("read beyond selected oversized unit") end)
    units = Enum.map(messages, &[&1]) ++ [later]
    assert {:ok, selected} = select(units)
    assert selected.unit_count == 2
    assert selected.source.source_excerpted
    assert selected.source.quota == 4_096
    excerpt = decode(selected.source)
    assert excerpt["byte_length"] == byte_size(json(messages))
    assert excerpt["sha256"] == Canonical.digest_bytes(json(messages))
  end

  test "small-prefix threshold uses serialized message bytes including framing" do
    framing = byte_size(json([user("")]))

    for bytes <- [6_144, 6_145] do
      first = user(String.duplicate("x", bytes - framing))
      units = [[first], [user(String.duplicate("y", 30_000))]]
      assert {:ok, selected} = select(units)

      if bytes == 6_144 do
        assert selected.unit_count == 2
        assert selected.source.source_excerpted
      else
        assert selected.unit_count == 1
        assert selected.source.message_byte_length == 6_145
        refute selected.source.source_excerpted
      end
    end
  end

  test "an oversized assistant and all its results remain one covered unit" do
    messages = [
      user("read both"),
      %{
        "role" => "assistant",
        "content" => "reading",
        "tool_calls" => [
          %{"tool_call_id" => "first", "name" => "read", "arguments" => %{"path" => "a"}},
          %{"tool_call_id" => "second", "name" => "read", "arguments" => %{"path" => "b"}}
        ]
      },
      %{
        "role" => "tool",
        "tool_call_id" => "first",
        "outcome" => "completed",
        "content" => String.duplicate("a", 10_000)
      },
      %{
        "role" => "tool",
        "tool_call_id" => "second",
        "outcome" => "denied",
        "content" => String.duplicate("b", 10_000)
      }
    ]

    assert {:ok, selected} = select([Stream.map(messages, & &1)])
    assert selected.unit_count == 1
    assert selected.source.source_excerpted
    excerpt = decode(selected.source)
    assert excerpt["byte_length"] == byte_size(json(messages))
    assert excerpt["sha256"] == Canonical.digest_bytes(json(messages))
  end

  test "a small prefix at the end of the eligible range remains complete" do
    assert {:ok, selected} = select([[user("only eligible history")]])
    assert selected.unit_count == 1
    refute selected.source.source_excerpted
    assert select([]) == {:ok, nil}
  end

  test "maintenance preflight selects quota order and can refuse a source-cap fit" do
    units = [[user(String.duplicate("x", 30_000))]]

    preflight = fn candidate, _count ->
      send(self(), {:preflight_quota, candidate.quota})
      if candidate.quota <= 1_024, do: :ok, else: {:refused, :maintenance_input_tokens}
    end

    assert {:ok, selected} = select(units, preflight)
    assert selected.unit_count == 1
    assert selected.source.quota == 1_024
    assert_receive {:preflight_quota, 4_096}
    assert_receive {:preflight_quota, 2_048}
    assert_receive {:preflight_quota, 1_024}
    refute_receive {:preflight_quota, 512}, 0
  end

  test "failed combined excerpts cannot fall back to their small complete prefix" do
    units = [[user("small")], [user(String.duplicate("x", 30_000))]]

    preflight = fn candidate, _count ->
      if candidate.source_excerpted, do: {:refused, :record_bytes}, else: :ok
    end

    assert select(units, preflight) == {:error, :compaction_excerpt_budget_too_small}
  end

  test "complete source fit alone does not admit a prefix and prior data spends its cap" do
    units = [[user(String.duplicate("x", 4_000))], [user(String.duplicate("y", 4_000))]]

    preflight = fn candidate, _count ->
      if candidate.source_excerpted, do: :ok, else: {:refused, :maintenance_record_bytes}
    end

    assert {:ok, selected} = select(units, preflight)
    assert selected.unit_count == 1
    assert selected.source.source_excerpted

    assert {:ok, selected} = CompactionSource.select(units, prior(), fn _, _ -> :ok end, &check/0)
    assert {:ok, decoded} = Frame.decode(selected.source.bytes, 16_384)
    assert decoded["prior_checkpoint"] == prior()
    assert selected.unit_count == 2
  end

  test "selection propagates cancellation and preflight errors without reading later units" do
    later = Stream.map([:later], fn _ -> flunk("read after refusal") end)
    units = [[user("first")], later]

    assert select(units, fn _, _ -> {:error, :maintenance_reasoning_unsupported} end) ==
             {:error, :maintenance_reasoning_unsupported}

    for cause <- [:cancelled, :deadline] do
      assert CompactionSource.select(units, nil, fn _, _ -> :ok end, fn -> {:error, cause} end) ==
               {:error, cause}
    end

    Process.put(:selection_cancelled, false)

    preflight = fn _, _ ->
      Process.put(:selection_cancelled, true)
      :ok
    end

    check = fn ->
      if Process.get(:selection_cancelled), do: {:error, :cancelled}, else: :ok
    end

    assert CompactionSource.select(units, nil, preflight, check) == {:error, :cancelled}

    for units <- [[[]], [[user("first")], []], [nil], [[user(<<255>>)]], :invalid] do
      assert select(units) == {:error, :context_projection_invalid}
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
