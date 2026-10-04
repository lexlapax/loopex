defmodule LoopexCli.M7AttemptFramesTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Loopex.M7Evidence.AttemptFrames, as: Frames
  alias LoopexProtocol.Frame

  @vector ~s({"body":{"a":[true,null,17],"z":"猫"},"campaign_id":"m7-frame-vector","digest":"7273e8aa511a1ddf4e8b9bf17ae9730ec04f562b25c42c8bfe84e85edbc67608","previous_digest":null,"sequence":1,"version":1})

  test "literal independent JSON/SHA vector fixes sorted nested keys and exact hash coverage" do
    assert {:ok, line, record} =
             Frames.encode("m7-frame-vector", 1, nil, %{"z" => "猫", "a" => [true, nil, 17]})

    assert line == @vector <> "\n"
    assert {:ok, ^record} = Frames.decode(@vector)
    assert {:ok, %{"sequence" => 1, "digest" => digest}} = Frames.verify(line)
    assert digest == "7273e8aa511a1ddf4e8b9bf17ae9730ec04f562b25c42c8bfe84e85edbc67608"
  end

  test "only exact canonical bytes with a closed authenticated envelope are admitted" do
    {:ok, line, record} = Frames.encode("campaign", 1, nil, %{"text" => "one"})
    bytes = String.trim_trailing(line, "\n")

    for changed <- [
          " " <> bytes,
          bytes <> " ",
          bytes <> "\n",
          String.replace(bytes, ":1", ":1.0"),
          String.replace(bytes, "one", "two"),
          String.replace(bytes, "\"version\":1", "\"version\":1,\"version\":1"),
          String.replace(bytes, "\"text\":\"one\"", "\"text\":\"one\",\"te\\u0078t\":\"one\""),
          rendered(Map.put(record, "extra", nil)),
          rendered(Map.delete(record, "body")),
          rendered(Map.put(record, "digest", String.upcase(record["digest"]))),
          rendered(Map.put(record, "version", 2)),
          rendered(Map.put(record, "sequence", 2))
        ] do
      assert Frames.decode(changed) == {:error, :invalid_attempt_frame}
    end
  end

  test "the line ceiling is exact for UTF-8 bytes and includes the full envelope" do
    {:ok, empty, _} = Frames.encode("campaign", 1, nil, %{"text" => ""})
    room = 65_536 - (byte_size(empty) - 1)
    value = String.duplicate("猫", div(room, 3)) <> String.duplicate("x", rem(room, 3))
    assert {:ok, line, record} = Frames.encode("campaign", 1, nil, %{"text" => value})
    assert byte_size(line) == 65_537
    assert {:ok, ^record} = Frames.decode(binary_part(line, 0, 65_536))
    assert {:ok, _} = Frames.verify(line)

    assert Frames.encode("campaign", 1, nil, %{"text" => value <> "x"}) ==
             {:error, :invalid_attempt_frame}

    assert Frames.decode(String.duplicate("x", 65_537)) == {:error, :invalid_attempt_frame}
    assert Frames.verify(String.duplicate("x", 65_537)) == {:error, :invalid_attempt_chain}
  end

  test "encoding refuses implementation terms, floats, invalid Unicode and excess nesting" do
    nested = Enum.reduce(1..17, %{}, fn _, inner -> %{"nested" => inner} end)

    for body <- [
          %{atom_key: "value"},
          %{"value" => :implementation_atom},
          %{"value" => self()},
          %{"value" => make_ref()},
          %{"value" => fn -> :ok end},
          %{"value" => 1.5},
          %{"value" => {"tuple"}},
          %{"value" => [1 | 2]},
          %{"value" => <<255>>},
          nested,
          [],
          nil
        ] do
      assert Frames.encode("campaign", 1, nil, body) == {:error, :invalid_attempt_frame}
    end

    for {campaign, sequence, previous} <- [
          {"", 1, nil},
          {<<255>>, 1, nil},
          {:atom, 1, nil},
          {"campaign", 0, nil},
          {"campaign", 1.0, nil},
          {"campaign", 1, String.duplicate("a", 64)},
          {"campaign", 2, nil}
        ] do
      assert Frames.encode(campaign, sequence, previous, %{}) == {:error, :invalid_attempt_frame}
    end
  end

  test "reordered, repeated, gapped, foreign and forked records refuse continuity" do
    {:ok, first, one} = Frames.encode("campaign", 1, nil, %{"label" => "first"})
    {:ok, second, two} = Frames.encode("campaign", 2, one["digest"], %{"label" => "second"})
    {:ok, third, three} = Frames.encode("campaign", 3, two["digest"], %{})
    {:ok, foreign, _} = Frames.encode("other", 2, one["digest"], %{})
    {:ok, fork, _} = Frames.encode("campaign", 3, one["digest"], %{})

    assert {:ok, Map.take(three, ~w(campaign_id sequence digest))} ==
             Frames.verify(first <> second <> third)

    for bytes <- [
          second,
          second <> first,
          first <> first,
          first <> third,
          first <> foreign,
          first <> second <> fork,
          first <> "\n"
        ] do
      assert Frames.verify(bytes) == {:error, :invalid_attempt_chain}
    end

    assert Frames.verify("") == {:error, :empty_attempt_chain}
    assert Frames.verify(nil) == {:error, :invalid_attempt_chain}
  end

  test "every missing terminator remains an unresolved append, including a complete JSON tail" do
    {:ok, first, one} = Frames.encode("campaign", 1, nil, %{})
    {:ok, second, _} = Frames.encode("campaign", 2, one["digest"], %{"note" => "next"})
    head = Map.take(one, ~w(campaign_id sequence digest))

    for length <- 1..(byte_size(second) - 1) do
      tail = binary_part(second, 0, length)
      assert Frames.verify(first <> tail) == {:error, {:incomplete_attempt_append, head, tail}}
    end

    assert Frames.verify("{") == {:error, {:incomplete_attempt_append, nil, "{"}}
  end

  test "large integers are retained without floating-point rounding" do
    value = 18_446_744_073_709_551_616
    assert {:ok, line, record} = Frames.encode("campaign", 1, nil, %{"quantity" => value})
    assert line =~ Integer.to_string(value)
    assert {:ok, ^record} = Frames.decode(String.trim_trailing(line, "\n"))
  end

  test "every committed position must occur exactly in the complete extended chain" do
    {:ok, first, one} = Frames.encode("campaign", 1, nil, %{"label" => "first"})
    {:ok, second, two} = Frames.encode("campaign", 2, one["digest"], %{"label" => "second"})
    {:ok, third, three} = Frames.encode("campaign", 3, two["digest"], %{"label" => "third"})
    bytes = first <> second <> third

    for record <- [one, two, three] do
      assert Frames.verify(bytes, head(record)) == {:ok, head(three)}
    end

    assert Frames.verify(first <> second, head(two)) == {:ok, head(two)}
    assert Frames.verify(first, head(two)) == {:error, :committed_attempt_head_mismatch}

    assert Frames.verify(first <> second, head(three)) ==
             {:error, :committed_attempt_head_mismatch}
  end

  test "a fully authenticated fork or foreign campaign cannot replace the committed head" do
    {:ok, first, one} = Frames.encode("campaign", 1, nil, %{})
    {:ok, second, two} = Frames.encode("campaign", 2, one["digest"], %{"answer" => "original"})

    {:ok, fork, fork_record} =
      Frames.encode("campaign", 2, one["digest"], %{"answer" => "changed"})

    {:ok, fork_tail, _} = Frames.encode("campaign", 3, fork_record["digest"], %{})
    {:ok, foreign, foreign_record} = Frames.encode("other", 1, nil, %{})

    assert {:ok, _} = Frames.verify(first <> fork <> fork_tail)
    assert {:ok, _} = Frames.verify(foreign)

    assert Frames.verify(first <> fork <> fork_tail, head(two)) ==
             {:error, :committed_attempt_head_mismatch}

    assert Frames.verify(foreign, head(one)) == {:error, :committed_attempt_head_mismatch}

    assert Frames.verify(first <> second, head(foreign_record)) ==
             {:error, :committed_attempt_head_mismatch}
  end

  test "reaching the anchor never turns an incomplete append into a complete index" do
    {:ok, first, one} = Frames.encode("campaign", 1, nil, %{})
    {:ok, second, two} = Frames.encode("campaign", 2, one["digest"], %{})
    {:ok, third, _} = Frames.encode("campaign", 3, two["digest"], %{"note" => "next"})

    for length <- 1..(byte_size(third) - 1) do
      tail = binary_part(third, 0, length)

      assert Frames.verify(first <> second <> tail, head(one)) ==
               {:error, {:incomplete_attempt_append, head(two), tail}}
    end

    tail = String.trim_trailing(second, "\n")

    assert Frames.verify(first <> tail, head(two)) ==
             {:error, {:incomplete_attempt_append, head(one), tail}}
  end

  test "a committed head grants no exception to canonical framing and chain continuity" do
    {:ok, first, one} = Frames.encode("campaign", 1, nil, %{})
    {:ok, second, two} = Frames.encode("campaign", 2, one["digest"], %{})
    {:ok, third, _} = Frames.encode("campaign", 3, two["digest"], %{})

    for bytes <- [first <> first, first <> third, second, first <> "\n", " " <> first] do
      assert Frames.verify(bytes, head(one)) == {:error, :invalid_attempt_chain}
    end

    assert Frames.verify("", head(one)) == {:error, :empty_attempt_chain}
  end

  test "anchors contain exactly a valid campaign, positive integer sequence and lower-case digest" do
    {:ok, first, one} = Frames.encode("campaign", 1, nil, %{})
    original = head(one)

    for invalid <- [
          nil,
          [],
          %{},
          one,
          Map.put(original, "extra", nil),
          Map.delete(original, "sequence"),
          Map.put(original, "sequence", 0),
          Map.put(original, "sequence", 1.0),
          Map.put(original, "campaign_id", ""),
          Map.put(original, "campaign_id", <<255>>),
          Map.put(original, "campaign_id", :atom),
          Map.put(original, "digest", String.upcase(original["digest"])),
          Map.put(original, "digest", <<255>>),
          Map.put(original, "digest", self())
        ] do
      assert Frames.verify(first, invalid) == {:error, :invalid_committed_attempt_head}
    end

    assert Frames.verify(nil, original) == {:error, :invalid_committed_attempt_head}
  end

  defp head(record), do: Map.take(record, ~w(campaign_id sequence digest))

  defp rendered(record) do
    {:ok, io} = Frame.encode(record)
    io |> IO.iodata_to_binary() |> String.trim_trailing("\n")
  end
end
