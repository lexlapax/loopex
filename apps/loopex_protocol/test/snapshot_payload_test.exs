defmodule LoopexProtocol.SnapshotPayloadTest do
  use ExUnit.Case, async: true

  alias LoopexProtocol.Session.{Checkpoint, Configuration}

  test "literal configuration and change vectors close every public member" do
    fixture = read("vectors/configuration-projection.v1.json")
    assert fixture["contract"] == "configuration_projection"
    assert length(fixture["cases"]) == 123

    for vector <- fixture["cases"] do
      {decode, encode} =
        if vector["scope"] == "configured_event",
          do: {&Configuration.decode_change/1, &Configuration.encode_change/1},
          else: {&Configuration.decode_wire/1, &Configuration.encode_wire/1}

      verify_vector(vector, decode, encode)
    end
  end

  test "literal checkpoints pin both owners, every original source and exact quantities" do
    fixture = read("vectors/checkpoint-projection.v1.json")
    assert fixture["contract"] == "checkpoint_projection"
    assert length(fixture["cases"]) == 259

    for vector <- fixture["cases"],
        do: verify_vector(vector, &Checkpoint.decode_wire/1, &Checkpoint.encode_wire/1)
  end

  test "both complete payload definitions and literal vector bytes have pinned identities" do
    for {relative, digest} <- [
          {"schema/configuration-projection.v1.json",
           "6171aaff827e009e73c04c2f30a421fae1d3d3b10ee00645948a05ebf7b4bd2f"},
          {"vectors/configuration-projection.v1.json",
           "1e06688db8f3ccf86c8607565808f083f3fe05ab82954dc6e21e635ece686565"},
          {"schema/checkpoint-projection.v1.json",
           "3f76c7926be7ec814fe2a7537482a75a4033104d543b456d8232cab0070af241"},
          {"vectors/checkpoint-projection.v1.json",
           "d8287cb98e5f917bab0a347525772e67a980dfc68bda5b5cfa53f1998f4bb17b"}
        ] do
      assert :crypto.hash(:sha256, File.read!(path(relative))) |> Base.encode16(case: :lower) ==
               digest
    end

    config = read("schema/configuration-projection.v1.json")
    assert config["configuration_version"]["domain"] == "arbitrary_positive_integer"
    assert config["configured_event"]["configuration"] == Map.delete(config, "configured_event")
    assert config["instructions"]["version"]["maximum_bytes"] == 64
    assert config["max_tokens"]["maximum"] == "18446744073709551615"
    checkpoint = read("schema/checkpoint-projection.v1.json")
    assert checkpoint["owner"] == read("schema/checkpoint-owner.v1.json")

    assert checkpoint["covered_range"]["first"]["variants"] |> Map.keys() |> Enum.sort() ==
             ~w(session_assistant session_command session_tool_result)

    assert checkpoint["strategy_revision"] == 3
    refute "summary" in checkpoint["required"]
  end

  test "every opaque position preserves the full identity boundary" do
    reference = :binary.copy(<<255>>, 65_536)
    native = checkpoint()

    for keys <- [
          ["checkpoint_id"],
          ["episode_id"],
          ["prior_checkpoint_id"],
          ["owner", "id"],
          ["covered_range", "first", "run_id"],
          ["covered_range", "first", "command_id"],
          ["covered_range", "last", "run_id"],
          ["covered_range", "first_kept", "run_id"],
          ["covered_range", "first_kept", "call_id"]
        ] do
      value = put_in(native, keys, reference)
      assert {:ok, wire} = Checkpoint.encode_wire(value)
      assert Checkpoint.decode_wire(wire) == {:ok, value}
      assert Checkpoint.encode_wire(put_in(value, keys, reference <> "x")) == :error

      assert Checkpoint.decode_wire(
               put_in(wire, keys, Base.url_encode64(reference <> "x", padding: false))
             ) == :error
    end

    change = %{"command_id" => reference, "configuration" => configuration()}
    assert {:ok, wire} = Configuration.encode_change(change)
    assert Configuration.decode_change(wire) == {:ok, change}
    assert Configuration.encode_change(%{change | "command_id" => reference <> "x"}) == :error
  end

  test "model and instruction provenance bounds use exact UTF-8 and ASCII bytes" do
    model = String.duplicate("é", 65_536)

    for {value, encode} <- [
          {configuration(), &Configuration.encode_wire/1},
          {checkpoint(), &Checkpoint.encode_wire/1}
        ] do
      assert {:ok, _} = encode.(%{value | "model" => model})
      assert encode.(%{value | "model" => model <> "x"}) == :error
      assert encode.(%{value | "model" => <<255>>}) == :error
      assert encode.(%URI{}) == :error
      assert encode.(Map.put(value, "provider_mapping", %{route: self()})) == :error
    end

    config = configuration()

    assert {:ok, _} =
             Configuration.encode_wire(
               put_in(config, ["instructions", "version"], String.duplicate("v", 64))
             )

    assert Configuration.encode_wire(
             put_in(config, ["instructions", "version"], String.duplicate("v", 65))
           ) == :error
  end

  @tag :node_client
  test "an independent Node consumer checks every literal and complete byte boundary" do
    node =
      System.find_executable("node") || flunk("Node is required for snapshot payload conformance")

    root = Path.expand("../../..", __DIR__)
    runner = Path.join(root, "clients/node/snapshot-payload-vectors.mjs")

    {output, status} =
      System.cmd(
        node,
        [
          runner,
          path("vectors/configuration-projection.v1.json"),
          path("vectors/checkpoint-projection.v1.json")
        ],
        stderr_to_stdout: true
      )

    assert status == 0, output

    assert JSON.decode!(String.trim_trailing(output, "\n")) ==
             %{
               "configuration_vectors" => 123,
               "checkpoint_vectors" => 259,
               "boundary_checks" => 34
             }
  end

  defp verify_vector(vector, decode, encode) do
    if vector["error"] do
      assert decode.(vector["input"]) == :error, vector["name"]
    else
      assert {:ok, native} = decode.(vector["input"]), vector["name"]
      assert retained(native) == vector["decoded"], vector["name"]
      assert encode.(native) == {:ok, vector["input"]}, vector["name"]
    end
  end

  defp retained(value) when is_map(value) do
    Map.new(value, fn
      {key, bytes}
      when key in ~w(checkpoint_id episode_id prior_checkpoint_id run_id command_id call_id id) and
             not is_nil(bytes) ->
        {key, %{"opaque_hex" => Base.encode16(bytes, case: :lower)}}

      {"strategy_revision", revision} ->
        {"strategy_revision", revision}

      {key, member} ->
        {key, retained(member)}
    end)
  end

  defp retained(value) when is_integer(value), do: Integer.to_string(value)
  defp retained(value), do: value

  defp checkpoint do
    value =
      Enum.find(
        read("vectors/checkpoint-projection.v1.json")["cases"],
        &(&1["name"] == "run-covered-prefix")
      )["input"]

    {:ok, native} = Checkpoint.decode_wire(value)
    native
  end

  defp configuration do
    value =
      Enum.find(
        read("vectors/configuration-projection.v1.json")["cases"],
        &(&1["name"] == "initial")
      )["input"]

    {:ok, native} = Configuration.decode_wire(value)
    native
  end

  defp read(relative), do: JSON.decode!(File.read!(path(relative)))
  defp path(relative), do: Path.join(:code.priv_dir(:loopex_protocol), relative)
end
