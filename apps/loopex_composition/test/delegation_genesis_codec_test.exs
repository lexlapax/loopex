Code.require_file("support/delegation_genesis_fixture.exs", __DIR__)

defmodule LoopexComposition.DelegationGenesisCodecTest do
  use ExUnit.Case, async: true

  alias Loopex.Runtime.SessionGenesis
  alias Loopex.Store
  alias LoopexComposition.Delegation.{GenesisCodec, LedgerCodec}
  alias LoopexComposition.DelegationGenesisFixture, as: Fixture
  alias LoopexProtocol.Canonical
  alias LoopexProtocol.Frame

  @fixtures Path.join(__DIR__, "fixtures/delegation")

  test "the retained object is plain-map ETF with exact bytes, digest and padded base64" do
    genesis = Fixture.genesis()
    assert {:ok, object} = GenesisCodec.encode(genesis)
    assert Enum.sort(Map.keys(object)) == ~w(bytes encoding sha256)
    assert object["encoding"] == "loopex.ledger.plain_etf.v1.base64"

    bytes = Base.decode64!(object["bytes"])
    assert bytes == :erlang.term_to_binary(genesis, [:deterministic])
    refute bytes == Canonical.encode(genesis)
    assert object["sha256"] == Canonical.digest_bytes(bytes)
    assert {:ok, ^genesis} = GenesisCodec.decode(object)

    assert {:ok, json} = GenesisCodec.encode_json(genesis)
    assert String.valid?(json)
    assert {:ok, ^object} = LedgerCodec.decode_json(json, :object)
    assert {:ok, ^genesis} = GenesisCodec.decode_json(json)

    assert genesis["options"]["opaque_id"] == <<255, 0, 128, 254>>
    assert genesis["options"]["opaque_digest"] == <<0, 255>>
  end

  test "both supported toolchains read each other's retained objects and exact create identity" do
    genesis = Fixture.genesis()
    assert {:ok, expected_transaction} = Store.create_session("runtime", "create", genesis)

    for pair <- ~w(current floor) do
      json = File.read!(Path.join(@fixtures, "genesis-#{pair}-v1.json"))
      assert {:ok, object} = Frame.decode(String.trim_trailing(json, "\n"), 1_048_576)
      assert {:ok, ^genesis} = GenesisCodec.decode(object)
      assert {:ok, ^genesis} = GenesisCodec.decode_json(String.trim_trailing(json, "\n"))
      assert {:ok, ^expected_transaction} = Store.create_session("runtime", "create", genesis)
      assert object["sha256"] == Canonical.digest_bytes(Base.decode64!(object["bytes"]))
    end
  end

  test "reader integrity does not require reencoding the retained ETF with its own writer recipe" do
    genesis = Fixture.genesis()
    retained = :erlang.term_to_binary(genesis, [{:minor_version, 0}])
    assert {:ok, current} = GenesisCodec.encode(genesis)
    refute retained == Base.decode64!(current["bytes"])
    assert {:ok, ^genesis} = GenesisCodec.decode(object(retained))
    assert {:ok, json} = LedgerCodec.encode_json(object(retained), :object)
    assert {:ok, ^genesis} = GenesisCodec.decode_json(json)
  end

  test "closed object members and their declared encodings refuse mixed representations" do
    {:ok, valid} = GenesisCodec.encode(Fixture.genesis())

    invalid = [
      nil,
      [],
      Map.delete(valid, "bytes"),
      Map.delete(valid, "sha256"),
      Map.delete(valid, "encoding"),
      Map.put(valid, "extra", true),
      %{encoding: valid["encoding"], bytes: valid["bytes"], sha256: valid["sha256"]},
      Map.put(valid, "encoding", "loopex.canonical.v1"),
      Map.put(valid, "bytes", Base.decode64!(valid["bytes"])),
      Map.put(valid, "sha256", Base.decode16!(valid["sha256"], case: :lower)),
      Map.put(valid, "sha256", String.upcase(valid["sha256"])),
      Map.put(valid, "sha256", String.duplicate("0", 64)),
      Map.put(valid, "bytes", valid["bytes"] <> "\n"),
      Map.put(valid, "bytes", <<255>>),
      Map.put(valid, "bytes", ""),
      Map.put(valid, "bytes", "%%invalid%%")
    ]

    for value <- invalid,
        do: assert(GenesisCodec.decode(value) == {:error, :invalid_retained_genesis})
  end

  test "noncanonical padding and pad bits refuse even when they decode to the original bytes" do
    genesis = Fixture.genesis()
    genesis = put_in(genesis, ["options", "padding"], padding_for_base64(genesis))
    {:ok, valid} = GenesisCodec.encode(genesis)
    encoded = valid["bytes"]
    assert String.ends_with?(encoded, "==")

    assert GenesisCodec.decode(%{valid | "bytes" => String.trim_trailing(encoded, "=")}) ==
             {:error, :invalid_retained_genesis}

    alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    prefix = binary_part(encoded, 0, byte_size(encoded) - 3)
    last = :binary.at(encoded, byte_size(encoded) - 3)
    {offset, 1} = :binary.match(alphabet, <<last>>)
    noncanonical = prefix <> binary_part(alphabet, offset + 1, 1) <> "=="
    assert Base.decode64!(noncanonical) == Base.decode64!(encoded)

    assert GenesisCodec.decode(%{valid | "bytes" => noncanonical}) ==
             {:error, :invalid_retained_genesis}
  end

  test "compressed ETF and any unconsumed suffix refuse before schema admission" do
    genesis = Fixture.genesis()
    bytes = :erlang.term_to_binary(genesis, [:deterministic])
    compressed = :erlang.term_to_binary(genesis, [:compressed])
    assert <<131, 80, _::binary>> = compressed

    for invalid <- [
          compressed,
          bytes <> <<0>>,
          bytes <> bytes,
          <<131, 116, 255, 255, 255, 255>>,
          <<131>>,
          <<0>>,
          ""
        ] do
      assert GenesisCodec.decode(object(invalid)) == {:error, :invalid_retained_genesis}
    end
  end

  test "safe ETF decoding does not admit process terms or tagged canonical trees" do
    genesis = Fixture.genesis()
    unsafe = [self(), make_ref(), fn -> :ok end, MapSet.new(), {:opaque, "value"}]

    for value <- unsafe do
      changed = put_in(genesis, ["options", "unsafe"], value)
      assert GenesisCodec.encode(changed) == {:error, :invalid_retained_genesis}

      assert GenesisCodec.decode(object(:erlang.term_to_binary(changed))) ==
               {:error, :invalid_retained_genesis}
    end

    assert GenesisCodec.decode(object(Canonical.encode(genesis))) ==
             {:error, :invalid_retained_genesis}
  end

  test "untrusted retained ETF cannot create an atom even with a valid retained hash" do
    name = "m7_ledger_atom_" <> Integer.to_string(System.unique_integer([:positive]))
    assert_raise ArgumentError, fn -> String.to_existing_atom(name) end
    genesis = put_in(Fixture.genesis(), ["options", "untrusted_atom"], name)
    bytes = :erlang.term_to_binary(genesis)
    encoded_binary = <<109, byte_size(name)::32, name::binary>>
    encoded_atom = <<119, byte_size(name), name::binary>>
    forged = :binary.replace(bytes, encoded_binary, encoded_atom)
    refute bytes == forged
    assert GenesisCodec.decode(object(forged)) == {:error, :invalid_retained_genesis}
    assert_raise ArgumentError, fn -> String.to_existing_atom(name) end
  end

  test "the owning core decoder refuses malformed settings and superseded genesis" do
    genesis = Fixture.genesis()

    previous = %{
      :kind => "session_genesis_v2",
      "options" => %{},
      "runtime_configuration" => %{"cleanup_grace_ms" => 5_000}
    }

    invalid = [
      Map.put(genesis, "extra", true),
      Map.delete(genesis, "initial_configuration"),
      put_in(genesis, ["initial_configuration", "max_tokens"], 0),
      put_in(genesis, ["initial_configuration", "instructions", "base"], "changed bytes"),
      put_in(genesis, ["tool_selection", "names"], %{"invented" => %{}}),
      Map.put(genesis, "policy_defer_mode", "invented"),
      previous
    ]

    for value <- invalid do
      assert GenesisCodec.encode(value) == {:error, :invalid_retained_genesis}

      assert GenesisCodec.decode(object(:erlang.term_to_binary(value))) ==
               {:error, :invalid_retained_genesis}
    end
  end

  test "payload ceiling counts normalized ETF and complete JSON includes base64 expansion" do
    empty = put_in(Fixture.genesis(), ["options", "padding"], "")
    overhead = :erlang.external_size(empty, [:deterministic])

    for size <- [65_535, 65_536, 65_537] do
      genesis = put_in(empty, ["options", "padding"], String.duplicate("g", size - overhead))
      assert byte_size(:erlang.term_to_binary(genesis, [:deterministic])) == size

      if size <= 65_536 do
        assert {:ok, encoded} = GenesisCodec.encode(genesis)
        assert {:ok, ^genesis} = GenesisCodec.decode(encoded)
        assert {:ok, json} = GenesisCodec.encode_json(genesis)
        assert byte_size(json) > 65_536
        assert byte_size(json) < 1_048_576
        assert {:ok, ^genesis} = GenesisCodec.decode_json(json)
      else
        assert GenesisCodec.encode(genesis) == {:error, :invalid_retained_genesis}

        assert GenesisCodec.decode(object(:erlang.term_to_binary(genesis))) ==
                 {:error, :invalid_retained_genesis}
      end
    end

    normalized = put_in(empty, ["options", "padding"], String.duplicate("g", 65_537 - overhead))

    atom_options =
      normalized["options"]
      |> Map.delete("padding")
      |> Map.put(:padding, normalized["options"]["padding"])

    caller = %{normalized | "options" => atom_options}
    assert byte_size(:erlang.term_to_binary(caller)) < 65_537
    assert SessionGenesis.normalize(caller) == {:error, :session_configuration_too_large}
    assert GenesisCodec.encode(caller) == {:error, :invalid_retained_genesis}
  end

  test "canonical JSON refuses alternate bytes and closed-envelope violations" do
    genesis = Fixture.genesis()
    assert {:ok, bytes} = GenesisCodec.encode_json(genesis)
    assert {:ok, object} = LedgerCodec.decode_json(bytes, :object)

    for altered <- [bytes <> "\n", " " <> bytes, bytes <> " ", <<239, 187, 191>> <> bytes] do
      assert GenesisCodec.decode_json(altered) == {:error, :invalid_retained_genesis}
    end

    for changed <- [Map.put(object, "extra", true), Map.delete(object, "bytes")] do
      assert {:ok, altered} = LedgerCodec.encode_json(changed, :object)
      assert GenesisCodec.decode_json(altered) == {:error, :invalid_retained_genesis}
    end

    assert GenesisCodec.decode_json(nil) == {:error, :invalid_retained_genesis}
    assert GenesisCodec.encode_json(nil) == {:error, :invalid_retained_genesis}
  end

  defp object(bytes) do
    %{
      "encoding" => "loopex.ledger.plain_etf.v1.base64",
      "bytes" => Base.encode64(bytes),
      "sha256" => Canonical.digest_bytes(bytes)
    }
  end

  defp padding_for_base64(genesis) do
    Enum.find(["", "x", "xx"], fn padding ->
      bytes = :erlang.term_to_binary(put_in(genesis, ["options", "padding"], padding))
      rem(byte_size(bytes), 3) == 1
    end)
  end
end
