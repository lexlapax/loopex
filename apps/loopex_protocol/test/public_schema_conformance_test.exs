defmodule LoopexProtocol.PublicSchemaConformanceTest do
  @moduledoc """
  ## Concept

  The vectors an independent implementation is checked against. Each one is a
  literal byte string with a literal verdict, so a client written in another
  language can run the same list and agree or disagree without reading any
  Elixir.

  ## Technical depth

  Accepted ADR 0023 requires language-neutral conformance, and that means the
  vectors cannot be generated from the implementation they check. Every frame
  below is written out by hand, and every expectation names the outcome rather
  than deriving it, so a decoder that changed behaviour fails here instead of
  quietly agreeing with itself.

  The negatives are the useful half. Any decoder accepts a well-formed object;
  what distinguishes a conforming one is that it refuses a duplicate member, a
  number it cannot round-trip, a trailing byte and a carriage return, and that
  it refuses each for its own reason rather than collapsing them into one.
  """

  use ExUnit.Case, async: true

  alias LoopexProtocol.Frame
  alias LoopexProtocol.Session
  alias LoopexProtocol.Wire

  @frame_limit 65_536

  # Concept: the admitted vectors, as bytes and the value they mean.
  #
  # Technical depth: written as literal frames a client can copy. A vector that
  # was built by encoding a term would prove only that the encoder and decoder
  # agree with each other, which is not what an independent implementation needs
  # to check itself against.
  @admitted [
    {~s({"method":"initialize","request_id":"r1","generations":["loopex.session.v1-experimental"],"capabilities":[]}),
     %{
       "method" => "initialize",
       "request_id" => "r1",
       "generations" => ["loopex.session.v1-experimental"],
       "capabilities" => []
     }},
    {~s({"a":0}), %{"a" => 0}},
    {~s({"a":-1}), %{"a" => -1}},
    {~s({"a":9007199254740991}), %{"a" => 9_007_199_254_740_991}},
    {~s({"a":-9007199254740991}), %{"a" => -9_007_199_254_740_991}},
    {~s({"a":true,"b":false,"c":null}), %{"a" => true, "b" => false, "c" => nil}},
    {~s({"a":[]}), %{"a" => []}},
    {~s({"a":{}}), %{"a" => %{}}},
    {~s({ "a" : [ 1 , 2 ] }), %{"a" => [1, 2]}},
    {~s({"a":"\\u00e9"}), %{"a" => "é"}},
    {~s({"a":"\\ud83d\\ude00"}), %{"a" => "😀"}},
    {~s({"a":"tab\\there"}), %{"a" => "tab\there"}},
    {~s({"a":"quote\\"here"}), %{"a" => "quote\"here"}},
    {~s({"a":"slash\\/here"}), %{"a" => "slash/here"}}
  ]

  # Concept: the refused vectors, as bytes and the reason they are refused.
  #
  # Technical depth: each reason is distinct on purpose. An implementation that
  # refused all of these as one undifferentiated error would pass a weaker test
  # and leave its own users unable to tell a frame that was too large from one
  # that repeated a member.
  @refused [
    {~s([1,2,3]), :not_an_object},
    {~s("a string"), :not_an_object},
    {~s(7), :not_an_object},
    {~s(true), :not_an_object},
    {~s({"a":1} ), :trailing_bytes},
    {~s({"a":1}\r), :trailing_bytes},
    {~s({"a":1}{"b":2}), :trailing_bytes},
    {~s( {"a":1}), :not_an_object},
    {~s({"a":1,"a":2}), :duplicate_member},
    {~s({"a":{"b":1,"b":2}}), :duplicate_member},
    {~s({"a":9007199254740992}), :integer_out_of_range},
    {~s({"a":-9007199254740992}), :integer_out_of_range},
    {~s({"a":1.5}), :number_not_an_integer},
    {~s({"a":1e3}), :number_not_an_integer},
    {~s({"a":), :truncated},
    {~s({"a":"unterminated), :truncated},
    {~s({), :truncated},
    {"", :truncated},
    {~s({"a":'single'}), :malformed},
    {~s({a:1}), :malformed},
    {~s({"a":"\\ud83d"}), :malformed}
  ]

  test "every admitted vector decodes to exactly its stated value" do
    for {frame, expected} <- @admitted do
      assert {:ok, ^expected} = Frame.decode(frame, @frame_limit),
             "did not admit #{inspect(frame)}"
    end
  end

  test "every refused vector is refused for its own stated reason" do
    for {frame, reason} <- @refused do
      assert {:error, ^reason} = Frame.decode(frame, @frame_limit),
             "did not refuse #{inspect(frame)} as #{reason}"
    end
  end

  test "the refusal reasons are distinct, so a client can tell them apart" do
    reasons = @refused |> Enum.map(&elem(&1, 1)) |> Enum.uniq()

    assert length(reasons) >= 6
  end

  test "a control character inside a string is refused, since a frame is one line" do
    assert {:error, :malformed} = Frame.decode(~s({"a":"x) <> "\n" <> ~s(y"}), @frame_limit)
    assert {:error, :malformed} = Frame.decode(~s({"a":"x) <> "\r" <> ~s(y"}), @frame_limit)
    assert {:error, :malformed} = Frame.decode(~s({"a":"x) <> <<0>> <> ~s(y"}), @frame_limit)
  end

  test "identity vectors decode to exactly these bytes" do
    for {wire, bytes} <- [
          {"cw", "s"},
          {"c18x", "s_1"},
          {"YWJj", "abc"},
          {"AAEC_w", <<0, 1, 2, 255>>}
        ] do
      assert {:ok, ^bytes} = Wire.identity(wire), "did not admit #{wire}"
      assert Wire.encode_identity(bytes) == wire
    end
  end

  test "identity vectors that must be refused are refused" do
    for wire <- ["", "YWJj=", "YWJjZA==", "a+b", "a/b", "not base64url!"] do
      assert :error = Wire.identity(wire), "admitted #{inspect(wire)}"
    end
  end

  test "quantity vectors decode to exactly these numbers" do
    for {wire, value} <- [
          {"0", 0},
          {"1", 1},
          {"42", 42},
          {"18446744073709551615", 18_446_744_073_709_551_615}
        ] do
      assert {:ok, ^value} = Wire.u64(wire)
      assert Wire.encode_u64(value) == wire
    end
  end

  test "quantity vectors that must be refused are refused" do
    for wire <- ["", "00", "01", "+1", "-1", "1.0", " 1", "1 ", "18446744073709551616"] do
      assert :error = Wire.u64(wire), "admitted #{inspect(wire)}"
    end
  end

  test "the schema digest is the value an independent implementation checks against" do
    assert Session.schema_digest() ==
             "3a1723e370bf392e2a6e9d2709c22735577d8cfbf946d63ac22e12a8fa1708f4"
  end

  test "an encoded record is the exact bytes an independent implementation expects" do
    assert {:ok, encoded} =
             Frame.encode(%{"type" => "error", "code" => "invalid_frame", "request_id" => "r1"})

    assert IO.iodata_to_binary(encoded) ==
             ~s({"code":"invalid_frame","request_id":"r1","type":"error"}\n)
  end

  test "an encoded record sorts its members, so two builds emit the same bytes" do
    assert {:ok, first} = Frame.encode(%{"b" => 1, "a" => 2})
    assert {:ok, second} = Frame.encode(%{"a" => 2, "b" => 1})

    assert IO.iodata_to_binary(first) == IO.iodata_to_binary(second)
    assert IO.iodata_to_binary(first) == ~s({"a":2,"b":1}\n)
  end
end
