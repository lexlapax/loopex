defmodule LoopexProtocol.ActiveBoundsTest do
  use ExUnit.Case, async: true
  alias LoopexProtocol.Frame
  alias LoopexProtocol.Session.ActiveBounds

  @keys ~w(max_turns token_budget deadline_ms deadline)
  @u64 18_446_744_073_709_551_615

  test "literal vectors preserve exact integer domains and refuse malformed objects" do
    fixture = read_contract("vectors/active-bounds.v1.json")
    assert fixture["contract"] == "active_bounds"
    assert fixture["format"] == "loopex.experimental.payload-vectors/1"
    assert length(fixture["cases"]) == 121

    for vector <- fixture["cases"] do
      if vector["error"] do
        assert ActiveBounds.decode_wire(vector["input"]) == :error, vector["name"]
      else
        assert {:ok, native} = ActiveBounds.decode_wire(vector["input"]), vector["name"]
        assert Enum.sort(Map.keys(native)) == Enum.sort(@keys)

        retained =
          Map.new(native, fn {key, value} ->
            assert value == nil or is_integer(value), vector["name"]
            {key, if(value == nil, do: nil, else: Integer.to_string(value))}
          end)

        assert retained == vector["decoded"], vector["name"]
        assert ActiveBounds.encode_wire(native) == {:ok, vector["input"]}, vector["name"]
      end
    end
  end

  test "native encoding refuses private values and exact numeric boundaries" do
    base = %{
      "max_turns" => 8,
      "token_budget" => 10_000,
      "deadline_ms" => 60_000,
      "deadline" => nil
    }

    assert {:ok, wire} = ActiveBounds.encode_wire(base)

    for key <- @keys,
        value <- [-1, "1", 1.0, true, [], %{}, self(), fn -> :ok end] do
      assert ActiveBounds.encode_wire(Map.put(base, key, value)) == :error
    end

    for key <- ~w(max_turns token_budget deadline_ms), value <- [0, nil] do
      assert ActiveBounds.encode_wire(Map.put(base, key, value)) == :error
    end

    for key <- ~w(deadline deadline_ms) do
      assert ActiveBounds.encode_wire(Map.put(base, key, @u64 + 1)) == :error
      assert ActiveBounds.decode_wire(Map.put(wire, key, Integer.to_string(@u64 + 1))) == :error
    end

    for key <- @keys do
      assert ActiveBounds.encode_wire(Map.delete(base, key)) == :error
      assert ActiveBounds.decode_wire(Map.delete(wire, key)) == :error
      assert ActiveBounds.decode_wire(Map.put(wire, key, <<255>>)) == :error
    end

    for object <- [nil, [], %URI{}, %{max_turns: 1}, Map.put(base, "private", "canary")] do
      assert ActiveBounds.encode_wire(object) == :error
      assert ActiveBounds.decode_wire(object) == :error
    end
  end

  test "committed deadline remains exact and does not borrow a clock or duration" do
    for deadline <- [nil, 0, 9_007_199_254_740_993, @u64] do
      native = %{
        "max_turns" => @u64 + 1,
        "token_budget" => @u64 + 2,
        "deadline_ms" => @u64,
        "deadline" => deadline
      }

      assert {:ok, wire} = ActiveBounds.encode_wire(native)
      assert wire["deadline"] == if(deadline == nil, do: nil, else: Integer.to_string(deadline))
      assert ActiveBounds.decode_wire(wire) == {:ok, native}
      assert wire["max_turns"] == "18446744073709551616"
      assert wire["token_budget"] == "18446744073709551617"
    end
  end

  test "schema and complete literal vectors have pinned byte identities" do
    schema = read_contract("schema/active-bounds.v1.json")
    assert schema["required"] == @keys
    assert schema["additional_members"] == "refuse"
    assert schema["null"] == "refuse"
    assert schema["max_turns"]["domain"] == "arbitrary_positive_integer"
    assert schema["token_budget"]["domain"] == "arbitrary_positive_integer"
    assert schema["deadline_ms"]["minimum"] == "1"
    assert schema["deadline"]["minimum"] == "0"
    assert schema["defaults"] == "none"
    assert schema["clock"] == "none"

    for {relative, digest} <- [
          {"schema/active-bounds.v1.json",
           "f18c1c86184f3a34a0d627398318fdc9273aec9a7645a400b184e0d30130b4d5"},
          {"vectors/active-bounds.v1.json",
           "27c8733a76233b4e9ca41ba22ca7484043b8c9ed815341b27855c8d49a522a83"}
        ] do
      path = Path.join([:code.priv_dir(:loopex_protocol), relative])
      assert :crypto.hash(:sha256, File.read!(path)) |> Base.encode16(case: :lower) == digest
    end
  end

  @tag :node_client
  test "independent pinned Node validates the complete object and inert data properties" do
    node =
      System.find_executable("node") || flunk("Node is required for ActiveBounds conformance")

    root = Path.expand("../../..", __DIR__)
    runner = Path.join(root, "clients/node/active-bounds-vectors.mjs")
    vectors = Path.join(root, "apps/loopex_protocol/priv/vectors/active-bounds.v1.json")
    schema = Path.join(root, "apps/loopex_protocol/priv/schema/active-bounds.v1.json")
    {output, status} = System.cmd(node, [runner, vectors, schema], stderr_to_stdout: true)
    assert status == 0, output

    assert {:ok, %{"contract" => "active_bounds", "checked" => 121, "boundary_checks" => 89}} =
             Frame.decode(String.trim_trailing(output, "\n"), 65_536)
  end

  defp read_contract(relative) do
    path = Path.join([:code.priv_dir(:loopex_protocol), relative])
    JSON.decode!(File.read!(path))
  end
end
