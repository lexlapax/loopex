defmodule LoopexComposition.DelegationLedgerCodecTest do
  use ExUnit.Case, async: true

  alias LoopexComposition.Delegation.LedgerCodec

  @fixture_path Path.join(__DIR__, "fixtures/delegation/ledger-bytes-v1.json")
  @external_resource @fixture_path
  @fixture JSON.decode!(File.read!(@fixture_path))

  for vector <- @fixture["json_vectors"] do
    @vector vector
    test "independent canonical JSON vector #{@vector["name"]}" do
      expected = Base.decode64!(@vector["json_base64"])
      value = @vector["value"]
      assert {:ok, ^expected} = LedgerCodec.encode_json(value, :object)
      assert {:ok, ^value} = LedgerCodec.decode_json(expected, :object)
      assert digest(expected) == @vector["sha256"]
    end
  end

  for vector <- @fixture["header_vectors"] do
    @vector vector
    test "independent complete header frame #{@vector["name"]}" do
      kind = kind(@vector["ledger_kind"])
      ids = Enum.map(@vector["identifiers_base64"], &Base.decode64!/1)
      expected = Base.decode64!(@vector["frame_base64"])
      payload = Base.decode64!(@vector["payload_base64"])
      key = @vector["identity_sha256"]
      identity = Base.decode64!(@vector["identity_json_base64"])
      label = "loopex:helper-" <> @vector["ledger_kind"] <> ":v1"
      assert digest(label <> <<0>> <> identity) == key
      assert {:ok, ^key} = LedgerCodec.header_key(kind, ids)
      assert {:ok, ^expected} = LedgerCodec.encode_header(kind, ids)
      assert byte_size(expected) == byte_size(payload) + 78
      assert {:ok, ^payload, ""} = LedgerCodec.decode_frame(expected)
      assert {:ok, header} = LedgerCodec.decode_header(expected, kind, ids, key)
      assert header["identity"] == @vector["identifiers_base64"]
      assert header["identity_sha256"] == key
    end
  end

  test "noncanonical spelling and malformed JSON refuse without rounding" do
    invalid = [
      "",
      "{}\n",
      " {}",
      "{} ",
      <<239, 187, 191>> <> "{}",
      "[]",
      "null",
      ~s({"b":0,"a":0}),
      ~s({"a" :0}),
      ~s({"a": 0}),
      ~s({"a":1,"a":2}),
      ~S({"a":1,"\u0061":2}),
      ~S({"a":"\/"}),
      ~S({"a":"\u0061"}),
      ~S({"a":"\u000A"}),
      ~S({"a":"\u000a"}),
      ~S({"a":"\u001A"}),
      ~S({"a":"\ud800"}),
      ~S({"a":"\udfff"}),
      ~s({"a":-1}),
      ~s({"a":-0}),
      ~s({"a":1.0}),
      ~s({"a":1e1}),
      ~s({"a":1E999999}),
      ~s({"a":01}),
      ~s({"a":0}garbage),
      <<123, 34, 97, 34, 58, 34, 255, 34, 125>>
    ]

    for bytes <- invalid do
      assert LedgerCodec.decode_json(bytes, :object) == {:error, :invalid_ledger_bytes}
    end
  end

  test "native terms and invalid owning classes cannot widen private JSON" do
    invalid = [
      nil,
      [],
      1,
      true,
      %URI{},
      MapSet.new([1]),
      MapSet.new(),
      MapSet.new([{"a", 1}]),
      %{"a" => %URI{}},
      %{"a" => [%URI{}]},
      %{"a" => MapSet.new([1])},
      %{"a" => [MapSet.new([1])]},
      %{"a" => MapSet.new()},
      %{"a" => [MapSet.new()]},
      %{"a" => MapSet.new([{"b", 1}])},
      %{"a" => [MapSet.new([{"b", 1}])]},
      %{a: 1},
      %{"a" => :invented},
      %{"a" => 1.0},
      %{"a" => -1},
      %{"a" => <<255>>},
      %{<<255>> => 1},
      %{"a" => self()},
      %{"a" => make_ref()},
      %{"a" => fn -> :ok end},
      %{"a" => [1 | 2]},
      %{"a" => {1, 2}}
    ]

    for value <- invalid,
        class <- [:object, :frame],
        do: assert(LedgerCodec.encode_json(value, class) == {:error, :invalid_ledger_bytes})

    assert LedgerCodec.encode_json(%{}, :unbounded) == {:error, :invalid_ledger_bytes}
    assert LedgerCodec.decode_json("{}", :unbounded) == {:error, :invalid_ledger_bytes}
    assert LedgerCodec.decode_json(nil, :object) == {:error, :invalid_ledger_bytes}
  end

  test "duplicate names remain visible after escape decoding and create no atoms" do
    name = "m7_helper_json_" <> Integer.to_string(System.unique_integer([:positive]))
    assert_raise ArgumentError, fn -> String.to_existing_atom(name) end
    bytes = "{\"" <> name <> "\":0}"
    assert {:ok, %{^name => 0}} = LedgerCodec.decode_json(bytes, :object)
    assert_raise ArgumentError, fn -> String.to_existing_atom(name) end

    assert LedgerCodec.decode_json(~S({"a":0,"\u0061":1}), :object) ==
             {:error, :invalid_ledger_bytes}
  end

  test "sixteen containers admit and the seventeenth refuses during byte admission" do
    admitted = nest(16)
    assert {:ok, bytes} = LedgerCodec.encode_json(admitted, :object)
    assert {:ok, ^admitted} = LedgerCodec.decode_json(bytes, :object)
    assert LedgerCodec.encode_json(nest(17), :object) == {:error, :invalid_ledger_bytes}
    assert LedgerCodec.decode_json(nested_bytes(17), :object) == {:error, :invalid_ledger_bytes}
  end

  test "object member and stored array cardinalities have exact closed bounds" do
    admitted = numbered_map(32)
    assert {:ok, bytes} = LedgerCodec.encode_json(admitted, :object)
    assert {:ok, ^admitted} = LedgerCodec.decode_json(bytes, :object)
    assert LedgerCodec.encode_json(numbered_map(33), :object) == {:error, :invalid_ledger_bytes}

    members = Enum.map(1..33, fn i -> "\"k#{i}\":0" end) |> Enum.join(",")

    assert LedgerCodec.decode_json("{" <> members <> "}", :object) ==
             {:error, :invalid_ledger_bytes}

    array = %{"a" => Enum.to_list(1..16)}
    assert {:ok, bytes} = LedgerCodec.encode_json(array, :object)
    assert {:ok, ^array} = LedgerCodec.decode_json(bytes, :object)

    assert LedgerCodec.encode_json(%{"a" => Enum.to_list(1..17)}, :object) ==
             {:error, :invalid_ledger_bytes}

    assert LedgerCodec.decode_json(~s({"a":[) <> Enum.join(1..17, ",") <> "]}", :object) ==
             {:error, :invalid_ledger_bytes}
  end

  test "complete object and frame payload JSON ceilings include punctuation" do
    for {class, limit} <- [object: 1_048_576, frame: 65_536],
        size <- [limit - 1, limit, limit + 1] do
      value = %{"p" => String.duplicate("x", size - 8)}
      bytes = ~s({"p":") <> value["p"] <> ~s("})
      assert byte_size(bytes) == size

      if size <= limit do
        assert {:ok, ^bytes} = LedgerCodec.encode_json(value, class)
        assert {:ok, ^value} = LedgerCodec.decode_json(bytes, class)
      else
        assert LedgerCodec.encode_json(value, class) == {:error, :invalid_ledger_bytes}
        assert LedgerCodec.decode_json(bytes, class) == {:error, :invalid_ledger_bytes}
      end
    end
  end

  test "escaped string expansion spends complete encoded bytes before encoding" do
    value = %{"p" => String.duplicate(<<1>>, 174_762)}
    assert byte_size(value["p"]) < 1_048_576
    assert LedgerCodec.encode_json(value, :object) == {:error, :invalid_ledger_bytes}

    assert LedgerCodec.encode_json(%{"p" => String.duplicate("x", 1_048_577)}, :object) ==
             {:error, :invalid_ledger_bytes}
  end

  test "raw framing exact payload cap is independent of JSON semantic admission" do
    for size <- [65_535, 65_536, 65_537] do
      bytes = String.duplicate("x", size)

      if size <= 65_536 do
        assert {:ok, frame} = LedgerCodec.encode_frame(bytes)
        assert byte_size(frame) == size + 78
        assert {:ok, ^bytes, ""} = LedgerCodec.decode_frame(frame)
        assert LedgerCodec.decode_json(bytes, :frame) == {:error, :invalid_ledger_bytes}
      else
        assert LedgerCodec.encode_frame(bytes) == {:error, :invalid_frame}
      end
    end

    for bytes <- ["", nil, 1],
        do: assert(LedgerCodec.encode_frame(bytes) == {:error, :invalid_frame})

    assert LedgerCodec.decode_frame(nil) == {:error, :invalid_frame}
  end

  test "each complete header byte corruption refuses even without a payload" do
    frame = binding_frame()
    complete_header = binary_part(frame, 0, 46)

    for offset <- 0..45 do
      corrupt = flip(complete_header, offset)
      assert LedgerCodec.decode_frame(corrupt) == {:error, :invalid_frame}

      assert LedgerCodec.decode_frame(corrupt <> binary_part(frame, 46, byte_size(frame) - 46)) ==
               {:error, :invalid_frame}
    end
  end

  test "complete recomputed invalid magic version and lengths refuse at EOF" do
    invalid = [
      <<"LXPHELP0", 1::unsigned-16-big, 1::unsigned-32-big>>,
      <<"LXPHELP1", 0::unsigned-16-big, 1::unsigned-32-big>>,
      <<"LXPHELP1", 2::unsigned-16-big, 1::unsigned-32-big>>,
      <<"LXPHELP1", 1::unsigned-16-big, 0::unsigned-32-big>>,
      <<"LXPHELP1", 1::unsigned-16-big, 65_537::unsigned-32-big>>,
      <<"LXPHELP1", 1::unsigned-16-big, 4_294_967_295::unsigned-32-big>>
    ]

    for prefix <- invalid,
        do:
          assert(LedgerCodec.decode_frame(prefix <> raw_hash(prefix)) == {:error, :invalid_frame})
  end

  test "all genuinely incomplete header payload and trailer cuts remain nonusable" do
    frame = binding_frame()
    {:ok, key} = LedgerCodec.header_key(:binding, ["runtime", "create"])

    for size <- 0..(byte_size(frame) - 1) do
      bytes = binary_part(frame, 0, size)
      assert LedgerCodec.decode_frame(bytes) == {:error, :incomplete_frame}

      assert LedgerCodec.decode_header(bytes, :binding, ["runtime", "create"], key) ==
               {:error, :incomplete_frame}
    end
  end

  test "each complete payload and trailer corruption refuses" do
    frame = binding_frame()

    for offset <- 46..(byte_size(frame) - 1),
        do: assert(LedgerCodec.decode_frame(flip(frame, offset)) == {:error, :invalid_frame})
  end

  test "header scope preimage and exact basename are required alongside checksums" do
    frame = binding_frame()
    {:ok, key} = LedgerCodec.header_key(:binding, ["runtime", "create"])

    for {kind, ids, expected} <- [
          {:binding, ["different", "create"], key},
          {:binding, ["runtime", "different"], key},
          {:run, ["runtime", "create", "run"], key},
          {:binding, ["runtime", "create"], String.duplicate("0", 64)},
          {:binding, ["runtime", "create"], String.upcase(key)},
          {:binding, ["runtime", "create"], key <> ".log"},
          {:binding, ["runtime", "create"], nil}
        ] do
      assert LedgerCodec.decode_header(frame, kind, ids, expected) ==
               {:error, :invalid_ledger_header}
    end
  end

  test "closed header schema refuses recomputed envelopes with altered payloads" do
    frame = binding_frame()
    {:ok, payload, ""} = LedgerCodec.decode_frame(frame)
    {:ok, header} = LedgerCodec.decode_json(payload, :frame)
    key = header["identity_sha256"]

    changed = [
      Map.put(header, "extra", true),
      Map.delete(header, "version"),
      Map.put(header, "version", 2),
      Map.put(header, "version", "1"),
      Map.put(header, "kind", "transaction"),
      Map.put(header, "ledger_kind", "run"),
      Map.put(header, "identity_sha256", String.duplicate("0", 64)),
      Map.put(header, "identity", ["cnVudGltZQ", "Y3JlYXRl"]),
      Map.put(header, "identity", ["cnVudGltZR==", "Y3JlYXRl"]),
      Map.put(header, "identity", ["", "Y3JlYXRl"]),
      Map.put(header, "identity", ["cnVudGltZQ=="]),
      Map.put(header, "identity", ["cnVudGltZQ==", "Y3JlYXRl", "cnVu"])
    ]

    for value <- changed do
      assert {:ok, json} = LedgerCodec.encode_json(value, :frame)
      assert {:ok, altered} = LedgerCodec.encode_frame(json)

      assert LedgerCodec.decode_header(altered, :binding, ["runtime", "create"], key) ==
               {:error, :invalid_ledger_header}
    end

    assert {:ok, altered} = LedgerCodec.encode_frame(payload <> " ")

    assert LedgerCodec.decode_header(altered, :binding, ["runtime", "create"], key) ==
             {:error, :invalid_ledger_header}
  end

  test "raw frame remainder cannot be mistaken for a complete validated header log" do
    frame = binding_frame()
    {:ok, key} = LedgerCodec.header_key(:binding, ["runtime", "create"])
    assert {:ok, payload, "extra"} = LedgerCodec.decode_frame(frame <> "extra")
    assert is_binary(payload)

    assert LedgerCodec.decode_header(frame <> "extra", :binding, ["runtime", "create"], key) ==
             {:error, :invalid_ledger_header}

    assert LedgerCodec.decode_header(frame <> frame, :binding, ["runtime", "create"], key) ==
             {:error, :invalid_ledger_header}
  end

  test "original Core identifier limits are exact and no larger executor cap is borrowed" do
    for ids <- [["r", "c"], [String.duplicate("r", 256), String.duplicate("c", 256)]] do
      assert {:ok, key} = LedgerCodec.header_key(:binding, ids)
      assert {:ok, frame} = LedgerCodec.encode_header(:binding, ids)
      assert {:ok, _header} = LedgerCodec.decode_header(frame, :binding, ids, key)
    end

    for ids <- [
          [],
          ["r"],
          ["r", "c", "extra"],
          ["", "c"],
          ["r", ""],
          [String.duplicate("r", 257), "c"],
          ["r", String.duplicate("c", 257)],
          [String.duplicate("r", 8_192), "c"],
          [nil, "c"],
          [1, "c"],
          ["r", "c" | "improper"]
        ] do
      assert LedgerCodec.header_key(:binding, ids) == {:error, :invalid_ledger_header}
      assert LedgerCodec.encode_header(:binding, ids) == {:error, :invalid_ledger_header}
    end

    assert LedgerCodec.header_key(:unknown, ["r", "c"]) == {:error, :invalid_ledger_header}
    assert LedgerCodec.encode_header(:run, ["r", "s"]) == {:error, :invalid_ledger_header}
  end

  test "identity arrays preserve member boundaries and separate binding from run domains" do
    assert {:ok, first} = LedgerCodec.header_key(:binding, ["ab", "c"])
    assert {:ok, second} = LedgerCodec.header_key(:binding, ["a", "bc"])
    refute first == second
    assert {:ok, run} = LedgerCodec.header_key(:run, ["ab", "c", "r"])
    refute first == run
    assert {:ok, reversed} = LedgerCodec.header_key(:binding, ["c", "ab"])
    refute first == reversed
  end

  defp binding_frame do
    {:ok, frame} = LedgerCodec.encode_header(:binding, ["runtime", "create"])
    frame
  end

  defp kind("binding"), do: :binding
  defp kind("run"), do: :run
  defp numbered_map(count), do: Map.new(1..count, fn n -> {"k#{n}", 0} end)
  defp nest(count), do: Enum.reduce(1..count, 0, fn _, value -> %{"v" => value} end)

  defp nested_bytes(count),
    do: String.duplicate(~s({"v":), count) <> "0" <> String.duplicate("}", count)

  defp raw_hash(bytes), do: :crypto.hash(:sha256, bytes)
  defp digest(bytes), do: raw_hash(bytes) |> Base.encode16(case: :lower)

  defp flip(bytes, offset) do
    <<before::binary-size(^offset), byte, rest::binary>> = bytes
    before <> <<Bitwise.bxor(byte, 1)>> <> rest
  end
end
