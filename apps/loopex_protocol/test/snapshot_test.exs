defmodule LoopexProtocol.SnapshotTest do
  use ExUnit.Case, async: true

  alias LoopexProtocol.Session.{OpenInteraction, Snapshot}

  test "literal open questions preserve both producers and exact model kinds" do
    fixture = read("vectors/open-interaction.v1.json")
    assert length(fixture["cases"]) == 114

    for vector <- fixture["cases"],
        do: verify(vector, &OpenInteraction.decode_wire/1, &OpenInteraction.encode_wire/1)
  end

  test "literal snapshots close every cursor view and reject inconsistent owners" do
    fixture = read("vectors/session-snapshot.v3.json")
    assert length(fixture["cases"]) == 50

    for vector <- fixture["cases"],
        do: verify(vector, &Snapshot.decode_wire/1, &Snapshot.encode_wire/1)
  end

  test "pending identities and policy choice identities keep their full byte ceilings" do
    native = pending()
    full = :binary.copy(<<255>>, 65_536)

    for key <- ~w(interaction_id run_id tool_call_id) do
      value = Map.put(native, key, full)
      assert {:ok, wire} = OpenInteraction.encode_wire(value)
      assert OpenInteraction.decode_wire(wire) == {:ok, value}
      assert OpenInteraction.encode_wire(Map.put(value, key, full <> "x")) == :error
    end

    short = :binary.copy(<<255>>, 64)
    value = %{native | "choices" => [%{"id" => short, "label" => "Proceed"}]}
    assert {:ok, wire} = OpenInteraction.encode_wire(value)
    assert OpenInteraction.decode_wire(wire) == {:ok, value}

    assert OpenInteraction.encode_wire(
             put_in(value, ["choices", Access.at(0), "id"], short <> "x")
           ) == :error
  end

  test "pending prompt and labels use exact UTF-8 byte limits" do
    native = pending()
    prompt = String.duplicate("é", 1_024)
    assert {:ok, _} = OpenInteraction.encode_wire(%{native | "prompt" => prompt})
    assert OpenInteraction.encode_wire(%{native | "prompt" => prompt <> "x"}) == :error
    assert OpenInteraction.encode_wire(%{native | "prompt" => <<255>>}) == :error
    label = String.duplicate("é", 128)
    value = %{native | "choices" => [%{"id" => "choice", "label" => label}]}
    assert {:ok, _} = OpenInteraction.encode_wire(value)

    assert OpenInteraction.encode_wire(
             put_in(value, ["choices", Access.at(0), "label"], label <> "x")
           ) == :error

    assert OpenInteraction.encode_wire(%URI{}) == :error
  end

  test "snapshot identity ceilings, atom keys and current configuration are exact" do
    native = snapshot()
    session = :binary.copy(<<255>>, 256)
    assert {:ok, wire} = Snapshot.encode_wire(%{native | session_id: session})
    assert Snapshot.decode_wire(wire) == {:ok, %{native | session_id: session}}
    assert Snapshot.encode_wire(%{native | session_id: session <> "x"}) == :error
    run = :binary.copy(<<255>>, 65_536)
    running = %{native | event_sequence: 1, active_run_id: run, active_run_phase: "started"}
    assert {:ok, wire} = Snapshot.encode_wire(running)
    assert Snapshot.decode_wire(wire) == {:ok, running}
    assert Snapshot.encode_wire(%{running | active_run_id: run <> "x"}) == :error
    assert Snapshot.encode_wire(Map.put(native, :private_recovery, self())) == :error
    assert Snapshot.encode_wire(%{native | configuration: nil}) == :error
    assert Snapshot.encode_wire(%URI{}) == :error

    assert Snapshot.encode_wire(
             Map.new(native, fn {key, value} -> {Atom.to_string(key), value} end)
           ) == :error
  end

  test "complete nested schemas and literal vectors have pinned byte identities" do
    for {relative, digest} <- [
          {"schema/open-interaction.v1.json",
           "3b764fe133c8cabf59418d02d890edcb82a5eac764c28e13a41638742e910721"},
          {"schema/session-snapshot.v3.json",
           "bce5ad3ea0e2b8027f7c29d2d480c864fe7b2032959290cc2ed8b234ed20aeeb"},
          {"vectors/open-interaction.v1.json",
           "2fc849930dc7ccac592c9f076c1a2008bfb86a983531f499490b28d5c5c4288d"},
          {"vectors/session-snapshot.v3.json",
           "6147367feaf72a5c14a15755b88ba91726d8cd3d48a17b244eb9082e33717268"}
        ] do
      assert :crypto.hash(:sha256, File.read!(path(relative))) |> Base.encode16(case: :lower) ==
               digest
    end

    schema = read("schema/session-snapshot.v3.json")
    assert schema["snapshot_revision"] == 3
    assert schema["configuration"]["nullable"] == false

    assert schema["configuration"]["definition"] ==
             Map.delete(read("schema/configuration-projection.v1.json"), "configured_event")

    assert schema["checkpoint"]["definition"] == read("schema/checkpoint-projection.v1.json")

    assert schema["last_compact"]["definition"] ==
             read("schema/standalone-compact-completion.v1.json")

    assert schema["open_interaction"]["definition"] == read("schema/open-interaction.v1.json")
    assert schema["active_maintenance"]["owner"] == read("schema/checkpoint-owner.v1.json")

    assert Map.keys(schema["active_maintenance"]["bounds"]["variants"]) |> Enum.sort() ==
             ~w(compact run)
  end

  @tag :node_client
  test "independent Node validates all literals and complete identity/text boundaries" do
    node = System.find_executable("node") || flunk("Node is required for snapshot conformance")
    root = Path.expand("../../..", __DIR__)

    arguments = [
      Path.join(root, "clients/node/snapshot-vectors.mjs"),
      path("vectors/open-interaction.v1.json"),
      path("vectors/session-snapshot.v3.json")
    ]

    {output, status} = System.cmd(node, arguments, stderr_to_stdout: true)
    assert status == 0, output

    assert JSON.decode!(String.trim(output)) == %{
             "open_vectors" => 114,
             "snapshot_vectors" => 50,
             "boundary_checks" => 21
           }
  end

  defp verify(vector, decode, encode) do
    if vector["error"] do
      assert decode.(vector["input"]) == :error, vector["name"]
    else
      assert {:ok, native} = decode.(vector["input"]), vector["name"]
      assert retained(native) == vector["decoded"], vector["name"]
      assert encode.(native) == {:ok, vector["input"]}, vector["name"]
    end
  end

  @identities ~w(session_id active_run_id interaction_id run_id tool_call_id checkpoint_id episode_id prior_checkpoint_id command_id id call_id answer_choice_id answer_command_id)
  defp retained(value, key \\ nil)

  defp retained(value, _key) when is_map(value),
    do: Map.new(value, fn {key, member} -> {to_string(key), retained(member, to_string(key))} end)

  defp retained(value, _key) when is_list(value), do: Enum.map(value, &retained/1)

  defp retained(value, key) when is_binary(value) and key in @identities,
    do: %{"opaque_hex" => Base.encode16(value, case: :lower)}

  defp retained(value, key)
       when is_integer(value) and key not in ~w(snapshot_revision strategy_revision),
       do: Integer.to_string(value)

  defp retained(value, _key), do: value

  defp pending do
    {:ok, value} =
      OpenInteraction.decode_wire(vector("open-interaction.v1.json", "policy-choice"))

    value
  end

  defp snapshot do
    {:ok, value} = Snapshot.decode_wire(vector("session-snapshot.v3.json", "creation"))
    value
  end

  defp vector(file, name),
    do: Enum.find(read("vectors/" <> file)["cases"], &(&1["name"] == name))["input"]

  defp read(relative), do: JSON.decode!(File.read!(path(relative)))
  defp path(relative), do: Path.join(:code.priv_dir(:loopex_protocol), relative)
end
