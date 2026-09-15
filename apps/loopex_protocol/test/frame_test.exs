defmodule LoopexProtocol.FrameTest do
  @moduledoc """
  ## Concept

  A frame is admitted only if it is exactly one bounded JSON object, and it is
  refused for a named reason otherwise. Nothing a sender writes can make the
  decoder hold more than the contract allows, resolve an ambiguity on the
  sender's behalf, or intern a name.

  ## Technical depth

  Accepted ADR 0023 fixes these bounds, so the cases state them literally. The
  negatives matter more than the positives here: a decoder that quietly took the
  last of two duplicate keys, rounded an integer it could not represent, or
  accepted a trailing byte would satisfy every positive test while giving a
  sender a way to mean two things at once.
  """

  use ExUnit.Case, async: true

  alias LoopexProtocol.Frame

  @limit 65_536

  test "one bounded object decodes to string keys and plain values" do
    assert {:ok, decoded} =
             Frame.decode(
               ~s({"method":"session.prompt","request_id":"r1","count":7,"ok":true,"none":null}),
               @limit
             )

    assert decoded == %{
             "method" => "session.prompt",
             "request_id" => "r1",
             "count" => 7,
             "ok" => true,
             "none" => nil
           }

    # Keys are binaries. Nothing a sender writes becomes an atom in this VM.
    assert Enum.all?(Map.keys(decoded), &is_binary/1)
  end

  test "nested arrays and objects decode, up to the admitted depth" do
    assert {:ok, decoded} =
             Frame.decode(~s({"a":[1,2,{"b":["c",{"d":[]}]}]}), @limit)

    assert decoded == %{"a" => [1, 2, %{"b" => ["c", %{"d" => []}]}]}
  end

  test "whitespace between tokens is ordinary, and leading or trailing bytes are not" do
    assert {:ok, %{"a" => 1}} = Frame.decode(~s({ "a" : 1 }), @limit)

    assert {:error, :not_an_object} = Frame.decode(~s( {"a":1}), @limit)
    assert {:error, :trailing_bytes} = Frame.decode(~s({"a":1} ), @limit)
    assert {:error, :trailing_bytes} = Frame.decode(~s({"a":1}{"b":2}), @limit)
    assert {:error, :trailing_bytes} = Frame.decode(~s({"a":1}\n), @limit)
  end

  test "a frame that is not a top-level object is refused" do
    assert {:error, :not_an_object} = Frame.decode(~s([1,2,3]), @limit)
    assert {:error, :not_an_object} = Frame.decode(~s("a string"), @limit)
    assert {:error, :not_an_object} = Frame.decode(~s(7), @limit)
    assert {:error, :truncated} = Frame.decode("", @limit)
  end

  test "a duplicate member is refused rather than resolved for the sender" do
    assert {:error, :duplicate_member} =
             Frame.decode(~s({"request_id":"r1","request_id":"r2"}), @limit)

    # Including deeper in the frame, where a careless decoder would have already
    # collapsed it into a map.
    assert {:error, :duplicate_member} =
             Frame.decode(~s({"a":{"k":1,"k":2}}), @limit)
  end

  test "an oversized frame costs a length comparison and nothing else" do
    payload = ~s({"a":"#{String.duplicate("x", 200)}"})

    assert {:error, :frame_too_large} = Frame.decode(payload, 64)
    assert {:ok, _decoded} = Frame.decode(payload, @limit)
  end

  test "invalid UTF-8 is refused before anything is parsed" do
    assert {:error, :invalid_utf8} = Frame.decode(<<?{, 0xFF, ?}>>, @limit)
  end

  test "nesting beyond sixteen levels is refused while parsing, not after" do
    admitted = nest(15)
    refused = nest(16)

    assert {:ok, _decoded} = Frame.decode(admitted, @limit)
    assert {:error, :depth_exceeded} = Frame.decode(refused, @limit)
  end

  test "more than a thousand and twenty-four members is refused" do
    admitted = ~s({"a":[#{Enum.map_join(1..1_024, ",", &Integer.to_string/1)}]})
    refused = ~s({"a":[#{Enum.map_join(1..1_025, ",", &Integer.to_string/1)}]})

    assert {:ok, _decoded} = Frame.decode(admitted, 1_048_576)
    assert {:error, :too_many_members} = Frame.decode(refused, 1_048_576)
  end

  test "an integer outside the range both sides round-trip is refused, never truncated" do
    assert {:ok, %{"n" => 9_007_199_254_740_991}} =
             Frame.decode(~s({"n":9007199254740991}), @limit)

    assert {:ok, %{"n" => -9_007_199_254_740_991}} =
             Frame.decode(~s({"n":-9007199254740991}), @limit)

    assert {:error, :integer_out_of_range} = Frame.decode(~s({"n":9007199254740992}), @limit)
    assert {:error, :integer_out_of_range} = Frame.decode(~s({"n":-9007199254740992}), @limit)
  end

  test "a number with a fraction or an exponent names nothing this protocol has" do
    assert {:error, :number_not_an_integer} = Frame.decode(~s({"n":1.5}), @limit)
    assert {:error, :number_not_an_integer} = Frame.decode(~s({"n":1e3}), @limit)
  end

  test "escapes decode, and a raw control character inside a string does not" do
    assert {:ok, %{"s" => "a\"b\\c\nd\te"}} =
             Frame.decode(~s({"s":"a\\"b\\\\c\\nd\\te"}), @limit)

    assert {:ok, %{"s" => "é"}} = Frame.decode(~s({"s":"\\u00e9"}), @limit)
    assert {:ok, %{"s" => "😀"}} = Frame.decode(~s({"s":"\\ud83d\\ude00"}), @limit)

    # A newline inside a string would put a second line inside a line-delimited
    # frame.
    assert {:error, :malformed} = Frame.decode(~s({"s":"a) <> "\n" <> ~s(b"}), @limit)
    assert {:error, :malformed} = Frame.decode(~s({"s":"\\ud83d"}), @limit)
  end

  test "a truncated frame is refused as truncated, not guessed at" do
    assert {:error, :truncated} = Frame.decode(~s({"a":), @limit)
    assert {:error, :truncated} = Frame.decode(~s({"a":"unterminated), @limit)
    assert {:error, :truncated} = Frame.decode(~s({"a":1), @limit)
  end

  test "an encoded record is one line and refuses rather than truncating" do
    assert {:ok, encoded} = Frame.encode(%{"type" => "error", "code" => "invalid_frame"})
    rendered = IO.iodata_to_binary(encoded)

    assert String.ends_with?(rendered, "\n")
    assert String.split(rendered, "\n", trim: true) |> length() == 1
    assert rendered == ~s({"code":"invalid_frame","type":"error"}\n)

    assert {:error, :output_record_too_large} =
             Frame.encode(%{"m" => String.duplicate("x", Frame.output_record_bytes())})
  end

  test "an encoded record round-trips through the decoder unchanged" do
    record = %{
      "type" => "initialized",
      "request_id" => "r1",
      "limits" => %{"frame_bytes" => 1_048_576},
      "supported_methods" => ["session.create", "session.prompt"],
      "note" => "quotes \" and newlines \n survive"
    }

    assert {:ok, encoded} = Frame.encode(record)

    payload =
      encoded
      |> IO.iodata_to_binary()
      |> String.trim_trailing("\n")

    assert {:ok, ^record} = Frame.decode(payload, 1_048_576)
  end

  defp nest(levels) do
    inner = Enum.reduce(1..levels, "1", fn _level, acc -> "[" <> acc <> "]" end)
    ~s({"a":) <> inner <> "}"
  end
end
