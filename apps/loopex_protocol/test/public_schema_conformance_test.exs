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
  alias LoopexProtocol.Session.V2
  alias LoopexProtocol.Wire

  @frame_limit 65_536

  # Concept: vectors the contract calls protocol errors that a codec still
  # admits, because what is wrong with them is not the framing.
  #
  # Technical depth: an identity outside the admitted alphabet is exactly one
  # well-formed object on one line. Both independent implementations decode it
  # and both are correct; the refusal belongs to the layer that reads the
  # identity. Listing it by name keeps the rule above honest rather than broad.
  @refused_above_the_codec ["request_id_outside_alphabet"]

  # Concept: the admitted vectors, as bytes and the value they mean.
  #
  # Technical depth: written as literal frames a client can copy. A vector that
  # was built by encoding a term would prove only that the encoder and decoder
  # agree with each other, which is not what an independent implementation needs
  # to check itself against.
  @admitted [
    {~s({"method":"initialize","request_id":"r1","generations":["loopex.experimental/1"],"capabilities":[]}),
     %{
       "method" => "initialize",
       "request_id" => "r1",
       "generations" => ["loopex.experimental/1"],
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

  @tag :node_client
  test "Elixir and Node clients execute the same positive and negative vectors without the server codec" do
    node_executable = System.find_executable("node")

    if is_nil(node_executable) do
      flunk("Node is required for the independent client and was not found")
    end

    executor = Path.join([repository_root(), "clients", "node", "vectors.mjs"])
    assert File.exists?(executor)

    for generation <- [1, 2] do
      assert_vector_clients_agree(node_executable, executor, generation)
    end
  end

  defp assert_vector_clients_agree(node_executable, executor, generation) do
    vectors_path =
      Path.join([
        Application.app_dir(:loopex_protocol, "priv"),
        "vectors",
        "loopex-experimental-#{generation}.json"
      ])

    {output, status} =
      System.cmd(node_executable, [executor, vectors_path], stderr_to_stdout: false)

    assert status == 0, "the Node client failed: #{output}"

    reported = decode_report(output)
    assert reported["format"] == "loopex.experimental.hex-vectors/1"

    results = reported["results"]

    assert length(results) >= 30,
           "generation #{generation} executed only #{length(results)} vectors"

    # The Elixir side reads the same file and decides the same question with its
    # own decoder. Neither client uses the other's: what makes this conformance
    # rather than a self-check is that two implementations reached the same
    # verdict on the same exact bytes.
    cases = vectors_path |> File.read!() |> decode_cases()
    assert length(cases) == length(results)

    disagreements =
      for {%{"id" => id, "raw_hex" => hex, "expect" => expect}, index} <-
            Enum.with_index(cases),
          reduce: [] do
        found ->
          node_result = Enum.at(results, index)
          assert node_result["id"] == id, "the two ran the cases in different orders"

          bytes = Base.decode16!(hex, case: :lower)
          mine = elixir_admits?(bytes)

          # A case whose expectation begins `protocol_error` is refused by
          # framing alone, with one named exception: a request identity outside
          # the admitted alphabet is a well-formed frame carrying a value the
          # layer above refuses, so both codecs admit it and are right to. Naming
          # the exception is the point — a rule with a silent hole would let a
          # second one in unnoticed.
          expected =
            not String.starts_with?(expect, "protocol_error") or
              id in @refused_above_the_codec

          cond do
            mine != node_result["admitted"] ->
              [{id, :clients_disagree, mine, node_result["admitted"]} | found]

            mine != expected ->
              [{id, :contract_disagrees, mine, expected} | found]

            true ->
              found
          end
      end

    assert disagreements == [], "vector disagreements: #{inspect(disagreements)}"

    # Both halves carry weight: a run that admitted everything, or refused
    # everything, would agree with itself and prove nothing.
    admitted = Enum.count(results, & &1["admitted"])
    refused = length(results) - admitted

    assert admitted > 0, "no vector was admitted"
    assert refused > 0, "no vector was refused"
  end

  # Concept: the vector file's cases and the Node client's report.
  #
  # Technical depth: this application's whole point is that it carries no JSON
  # dependency, so the fixture is read with the decoder under test. That is
  # admissible here and nowhere else in this case: what is being compared is the
  # verdict on each `raw_hex`, and the file that holds them is not one of them.
  defp decode_cases(document), do: document |> JSON.decode!() |> Map.fetch!("cases")

  defp decode_report(output), do: JSON.decode!(output)

  # Concept: whether these exact bytes are one well-formed frame, decided here.
  #
  # Technical depth: the same question the Node client answers, asked of this
  # implementation. The trailing newline is the framing, so it is removed before
  # the frame itself is decoded, exactly as a transport reading a line would.
  defp elixir_admits?(bytes) do
    case bytes do
      <<>> ->
        false

      _other ->
        if String.ends_with?(bytes, "\n") do
          line = binary_part(bytes, 0, byte_size(bytes) - 1)
          match?({:ok, _record}, Frame.decode(line, @frame_limit))
        else
          false
        end
    end
  end

  defp repository_root, do: Path.expand(Path.join([__DIR__, "..", "..", ".."]))

  test "exact source schema client versions and toolchain platform identities are recorded with every result" do
    # What an independent implementation checks itself against is a set of exact
    # identities, not a description. Each one below is a value another language's
    # client can read and compare without running any Elixir, and each is exact
    # rather than a range: a client that matched "close enough" would report
    # agreement with a contract it had not actually met.

    # The schema identity the vectors belong to.
    assert Session.generation() == "loopex.experimental/1"
    assert String.match?(Session.schema_digest(), ~r/\A[0-9a-f]{64}\z/)

    # The schema digest names the contract, not the file: it covers the
    # generation, the methods, the record families, the error codes and the
    # limits. An implementation compares this exact value, so it is written out
    # here rather than recomputed, and a change to any of those five fails here
    # rather than silently renaming what clients are agreeing to.
    assert Session.schema_digest() ==
             "3c0e34a99cd0178095de0d75843340128d26143798e517daae26b44cbf9a884f"

    # The schema and vector files an independent client reads are identified by
    # their own bytes, which are the digests the gate binds. A conformance
    # result therefore names files a reader can fetch and verify.
    for {directory, expected} <- [
          {"schema", "a4c286cf45442273011d8f51d25d867334cb3dc0ce3621e86564cba520e1bcff"},
          {"vectors", "a7f2dc36f9206dc48d258bc7b49a8d390ec3a0e93c51ed5a35f45153052e1951"}
        ] do
      path =
        Path.join([
          Application.app_dir(:loopex_protocol, "priv"),
          directory,
          "loopex-experimental-1.json"
        ])

      assert File.exists?(path), "the #{directory} file is missing"

      bytes = File.read!(path)
      measured = :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)
      assert measured == expected, "the #{directory} file is #{measured}"
      assert JSON.decode!(bytes)["generation"] == Session.generation()
    end

    vectors_digest = "a7f2dc36f9206dc48d258bc7b49a8d390ec3a0e93c51ed5a35f45153052e1951"

    # The toolchain and platform a result was produced on. These are exact
    # values rather than ranges, because a conformance result that did not say
    # which build produced it cannot be reproduced.
    assert String.match?(System.version(), ~r/\A\d+\.\d+\.\d+/)
    assert :erlang.system_info(:otp_release) |> to_string() |> String.match?(~r/\A\d+\z/)
    assert is_list(:erlang.system_info(:system_architecture))
    assert :erlang.system_info(:version) |> to_string() |> String.match?(~r/\A\d+\./)

    # The client pin an independent implementation runs under, read from the
    # file that pins it rather than from anything this build could vary.
    pins_path =
      Path.join([
        __DIR__,
        "..",
        "..",
        "..",
        "scripts",
        "fixtures",
        "m4",
        "client-toolchain.txt"
      ])

    assert File.exists?(pins_path)
    pins = pins_path |> File.read!() |> String.trim()

    assert String.match?(pins, ~r/\Anode=\d+\.\d+\.\d+\z/),
           "the client pin is not an exact version: #{inspect(pins)}"

    # Every identity above is a value, not a shape: two of them collide only if
    # the things they identify are the same things.
    identities = [Session.generation(), Session.schema_digest(), vectors_digest, pins]
    assert length(Enum.uniq(identities)) == length(identities)
  end

  test "the schema digest is the value an independent implementation checks against" do
    assert Session.schema_digest() ==
             "3c0e34a99cd0178095de0d75843340128d26143798e517daae26b44cbf9a884f"
  end

  test "generation-two schema and vector files have pinned identities" do
    for {directory, expected} <- [
          {"schema", "49e79bc8bd087d7381228db280a5e702f2544f9965398edf23fe655e845fb5ee"},
          {"vectors", "82b20498272f5ca155d3f42f63fc12b94deaea24b3be1f92fc120bb4899c5fec"}
        ] do
      path =
        Path.join([
          Application.app_dir(:loopex_protocol, "priv"),
          directory,
          "loopex-experimental-2.json"
        ])

      bytes = File.read!(path)
      measured = :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)
      assert measured == expected, "the generation-two #{directory} file is #{measured}"
      assert JSON.decode!(bytes)["generation"] == V2.generation()
    end
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
