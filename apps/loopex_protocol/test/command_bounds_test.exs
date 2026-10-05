defmodule LoopexProtocol.CommandBoundsTest do
  use ExUnit.Case, async: true
  alias LoopexProtocol.Frame
  alias LoopexProtocol.Session.CommandBounds

  @kinds %{"prompt" => :prompt, "follow_up" => :follow_up, "compact" => :compact}

  test "literal vectors pin both bounds directions and every refused scalar domain" do
    fixture = read_contract("vectors/command-bounds.v1.json")
    assert fixture["format"] == "loopex.experimental.payload-vectors/1"
    assert fixture["contract"] == "command_bounds"
    assert length(fixture["cases"]) == 171

    for vector <- fixture["cases"] do
      kind = Map.get(@kinds, vector["kind"], :unknown)

      if vector["error"] do
        assert CommandBounds.decode_wire(vector["input"], kind) == :error, vector["name"]
      else
        assert {:ok, native} = CommandBounds.decode_wire(vector["input"], kind), vector["name"]
        assert retained(native) == vector["decoded"], vector["name"]
        assert CommandBounds.encode_wire(native, kind) == {:ok, vector["input"]}, vector["name"]
      end
    end
  end

  test "enclosing requests preserve omitted, empty and partial authored bounds" do
    fixture = read_contract("vectors/command-bounds.v1.json")

    for vector <- fixture["enclosing_request_cases"] do
      request = vector["request"]
      kind = Map.fetch!(@kinds, vector["kind"])

      converted =
        case Map.fetch(request, "bounds") do
          :error ->
            request

          {:ok, bounds} ->
            assert {:ok, native} = CommandBounds.decode_wire(bounds, kind)
            assert {:ok, wire} = CommandBounds.encode_wire(native, kind)
            Map.put(request, "bounds", wire)
        end

      assert converted == vector["expected"]
      assert Map.has_key?(converted, "bounds") == Map.has_key?(request, "bounds")
    end
  end

  test "encoding refuses invalid native types, numeric boundaries and private keys" do
    for value <- [0, -1, "1", 1.0, nil, true, [], %{}, self(), fn -> :ok end] do
      assert CommandBounds.encode_wire(%{"max_turns" => value}, :prompt) == :error
    end

    for value <- [0, -1, 9_007_199_254_740_992, 1.0, "1", nil, true] do
      assert CommandBounds.encode_wire(%{"deadline_at_ms" => value}, :prompt) == :error
    end

    for {kind, key, maximum} <- [
          {:prompt, "deadline_ms", 18_446_744_073_709_551_615},
          {:compact, "max_attempts", 4},
          {:compact, "deadline_ms", 60_000},
          {:compact, "token_budget", 32_768}
        ] do
      bounds =
        if kind == :compact,
          do: %{"max_attempts" => 1, "deadline_ms" => 1, "token_budget" => 1},
          else: %{}

      assert CommandBounds.encode_wire(Map.put(bounds, key, maximum + 1), kind) == :error
    end

    for kind <- [:prompt, :follow_up, :compact] do
      for bounds <- [nil, [], %URI{}, %{deadline_at_ms: 1}, %{"private" => "canary"}] do
        assert CommandBounds.encode_wire(bounds, kind) == :error
        assert CommandBounds.decode_wire(bounds, kind) == :error
      end
    end

    assert CommandBounds.encode_wire(%{}, "prompt") == :error
    assert CommandBounds.decode_wire(%{}, :followup) == :error
    assert CommandBounds.decode_wire(%{"max_turns" => <<255>>}, :prompt) == :error
  end

  test "wire framing refuses noninteger and unsafe absolute deadline spellings" do
    for literal <- ["1.0", "1e0", "9007199254740992", "9007199254740993"] do
      assert {:error, _reason} = Frame.decode("{\"deadline_at_ms\":" <> literal <> "}", 128)
    end

    assert {:ok, bounds} = Frame.decode("{\"deadline_at_ms\":9007199254740991}", 128)

    assert CommandBounds.decode_wire(bounds, :prompt) ==
             {:ok, %{"deadline_at_ms" => 9_007_199_254_740_991}}
  end

  test "complete schema and literal vector byte identities remain pinned" do
    schema = read_contract("schema/command-bounds.v1.json")
    assert schema["command_kinds"] == ~w(prompt follow_up compact)
    assert schema["additional_members"] == "refuse"
    assert schema["null"] == "refuse"
    assert schema["defaults"] == "none"
    assert schema["clock"] == "none"
    assert schema["prompt"]["required"] == []
    assert schema["follow_up"]["required"] == []
    assert schema["compact"]["required"] == ~w(max_attempts deadline_ms token_budget)

    for {relative, digest} <- [
          {"schema/command-bounds.v1.json",
           "14e7c08995ceb0bc93ccfbffba8ad3808e41b04fbe0f08b80bb19698fbf795dd"},
          {"vectors/command-bounds.v1.json",
           "90bba24974cf9b7755f2cfd0dd0e42dafbf5a80a6bf26750d404df03a89522da"}
        ] do
      path = Path.join([:code.priv_dir(:loopex_protocol), relative])
      assert :crypto.hash(:sha256, File.read!(path)) |> Base.encode16(case: :lower) == digest
    end
  end

  @tag :node_client
  test "independent Node executes the same literal grammar and omission vectors" do
    node = System.find_executable("node") || flunk("Node is required for bounds conformance")
    root = Path.expand("../../..", __DIR__)
    runner = Path.join(root, "clients/node/command-bounds-vectors.mjs")
    vectors = Path.join(root, "apps/loopex_protocol/priv/vectors/command-bounds.v1.json")
    schema = Path.join(root, "apps/loopex_protocol/priv/schema/command-bounds.v1.json")
    {output, status} = System.cmd(node, [runner, vectors, schema], stderr_to_stdout: true)
    assert status == 0, output

    assert {:ok,
            %{
              "contract" => "command_bounds",
              "checked" => 171,
              "enclosing_checks" => 6,
              "boundary_checks" => 39
            }} = Frame.decode(String.trim_trailing(output, "\n"), 65_536)
  end

  defp retained(bounds) do
    Map.new(bounds, fn {key, value} ->
      {key, if(key == "deadline_at_ms", do: value, else: Integer.to_string(value))}
    end)
  end

  defp read_contract(relative) do
    path = Path.join([:code.priv_dir(:loopex_protocol), relative])
    JSON.decode!(File.read!(path))
  end
end
