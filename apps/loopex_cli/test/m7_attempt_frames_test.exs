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

  defp rendered(record) do
    {:ok, io} = Frame.encode(record)
    io |> IO.iodata_to_binary() |> String.trim_trailing("\n")
  end
end
