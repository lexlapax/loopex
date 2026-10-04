defmodule LoopexProtocol.CheckpointOwnerTest do
  use ExUnit.Case, async: true

  alias LoopexProtocol.Frame
  alias LoopexProtocol.Session.CheckpointOwner

  test "literal owners retain opaque bytes and reject superseded or malformed shapes" do
    fixture = contract("vectors/checkpoint-owner.v1.json")
    assert fixture["format"] == "loopex.experimental.payload-vectors/1"
    assert fixture["contract"] == "checkpoint_owner"
    assert length(fixture["cases"]) == 36

    for vector <- fixture["cases"] do
      if vector["error"] do
        assert CheckpointOwner.decode_wire(vector["input"]) == :error, vector["name"]
      else
        assert {:ok, native} = CheckpointOwner.decode_wire(vector["input"]), vector["name"]

        assert %{
                 "kind" => native["kind"],
                 "id" => %{"opaque_hex" => Base.encode16(native["id"], case: :lower)}
               } ==
                 vector["decoded"],
               vector["name"]

        assert CheckpointOwner.encode_wire(native) == {:ok, vector["input"]}, vector["name"]
      end
    end
  end

  test "native and wire identities share the complete existing identity boundary" do
    for kind <- ["run", "compact"] do
      native = %{"kind" => kind, "id" => :binary.copy(<<255>>, 65_536)}
      assert {:ok, wire} = CheckpointOwner.encode_wire(native)
      assert {:ok, ^native} = CheckpointOwner.decode_wire(wire)
      assert CheckpointOwner.encode_wire(%{native | "id" => native["id"] <> "x"}) == :error

      assert CheckpointOwner.decode_wire(%{
               wire
               | "id" => Base.url_encode64(native["id"] <> "x", padding: false)
             }) == :error

      for id <- [nil, "", 1, [], %{}, self()] do
        assert CheckpointOwner.encode_wire(%{native | "id" => id}) == :error
      end

      assert CheckpointOwner.encode_wire(Map.put(native, "run_id", "alias")) == :error
      assert CheckpointOwner.encode_wire(Map.put(native, :__struct__, __MODULE__)) == :error
      assert CheckpointOwner.decode_wire(Map.put(wire, :__struct__, __MODULE__)) == :error
    end
  end

  test "the schema and exact literal bytes pin the approved owner contract" do
    schema = contract("schema/checkpoint-owner.v1.json")
    assert schema["required"] == ~w(kind id)
    assert schema["kind"] == ~w(run compact)
    assert schema["additional_members"] == "refuse"
    assert schema["id"]["original_max_bytes"] == 65_536
    assert schema["superseded_owning_run_id"] == "refuse"

    for {relative, digest} <- [
          {"schema/checkpoint-owner.v1.json",
           "f68f93ced7af2778223780430dd4f08c10e3a18f082773d324e22f54c2950f76"},
          {"vectors/checkpoint-owner.v1.json",
           "4c556212a88c43aade603c0e9c6c4570c736f056f468e11d605643651669cc44"}
        ] do
      assert :crypto.hash(:sha256, File.read!(path(relative))) |> Base.encode16(case: :lower) ==
               digest
    end
  end

  @tag :node_client
  test "independent Node decoding executes every literal owner and identity boundary" do
    node = System.find_executable("node") || flunk("Node is required for owner conformance")
    root = Path.expand("../../..", __DIR__)
    runner = Path.join(root, "clients/node/checkpoint-owner-vectors.mjs")

    {output, status} =
      System.cmd(node, [runner, path("vectors/checkpoint-owner.v1.json")], stderr_to_stdout: true)

    assert status == 0, output

    assert {:ok, %{"contract" => "checkpoint_owner", "checked" => 36, "boundary_checks" => 4}} =
             Frame.decode(String.trim_trailing(output, "\n"), 65_536)
  end

  defp path(relative), do: Path.join([:code.priv_dir(:loopex_protocol), relative])
  defp contract(relative), do: relative |> path() |> File.read!() |> JSON.decode!()
end
