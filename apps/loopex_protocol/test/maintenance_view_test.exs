defmodule LoopexProtocol.MaintenanceViewTest do
  use ExUnit.Case, async: true

  alias LoopexProtocol.Frame
  alias LoopexProtocol.Session.MaintenanceView

  test "literal views preserve both owners and exact admission domains, refusing private fields" do
    fixture = contract("vectors/maintenance-view.v1.json")
    assert fixture["format"] == "loopex.experimental.payload-vectors/1"
    assert fixture["contract"] == "maintenance_view"
    assert length(fixture["cases"]) == 201

    for vector <- fixture["cases"] do
      if vector["error"] do
        assert MaintenanceView.decode_wire(vector["input"]) == :error, vector["name"]
      else
        assert {:ok, native} = MaintenanceView.decode_wire(vector["input"]), vector["name"]
        assert retained(native) == vector["decoded"], vector["name"]
        assert MaintenanceView.encode_wire(native) == {:ok, vector["input"]}, vector["name"]
      end
    end
  end

  test "native quantities reject wire spellings and retain unbounded configuration and run allowances" do
    wire = run_wire()
    assert {:ok, native} = MaintenanceView.decode_wire(wire)
    assert MaintenanceView.encode_wire(wire) == :error
    assert MaintenanceView.decode_wire(native) == :error

    for path <- [
          ["active_maintenance", "configuration_version"],
          ["active_maintenance", "bounds", "max_turns"],
          ["active_maintenance", "bounds", "token_budget"]
        ] do
      arbitrary = Integer.pow(10, 100) + 1
      assert {:ok, encoded} = MaintenanceView.encode_wire(put_in(native, path, arbitrary))
      assert get_in(encoded, path) == Integer.to_string(arbitrary)

      for invalid <- [0, -1, 1.0, true, nil, "1", self(), %{}] do
        assert MaintenanceView.encode_wire(put_in(native, path, invalid)) == :error
      end
    end

    for invalid <- [-1, 18_446_744_073_709_551_616, true, "0"] do
      assert MaintenanceView.encode_wire(
               put_in(native, ["active_maintenance", "bounds", "run_deadline"], invalid)
             ) == :error
    end
  end

  test "identity and UTF-8 ceilings are byte exact for both directions" do
    assert {:ok, native} = MaintenanceView.decode_wire(run_wire())
    reference = :binary.copy(<<255>>, 65_536)

    for path <- [["active_maintenance", "episode_id"], ["active_maintenance", "owner", "id"]] do
      value = put_in(native, path, reference)
      assert {:ok, encoded} = MaintenanceView.encode_wire(value)
      assert {:ok, ^value} = MaintenanceView.decode_wire(encoded)
      assert MaintenanceView.encode_wire(put_in(value, path, reference <> "x")) == :error

      assert MaintenanceView.decode_wire(
               put_in(encoded, path, Base.url_encode64(reference <> "x", padding: false))
             ) == :error
    end

    model = String.duplicate("🙂", 32_768)
    value = put_in(native, ["active_maintenance", "model"], model)
    assert {:ok, encoded} = MaintenanceView.encode_wire(value)
    assert {:ok, ^value} = MaintenanceView.decode_wire(encoded)

    for invalid <- [model <> "x", <<255>>, ""] do
      assert MaintenanceView.encode_wire(put_in(value, ["active_maintenance", "model"], invalid)) ==
               :error

      assert MaintenanceView.decode_wire(
               put_in(encoded, ["active_maintenance", "model"], invalid)
             ) ==
               :error
    end
  end

  test "every object refuses structs and native private additions" do
    assert {:ok, native} = MaintenanceView.decode_wire(run_wire())

    for path <- [
          [],
          ["active_maintenance"],
          ["active_maintenance", "owner"],
          ["active_maintenance", "bounds"]
        ] do
      member = if path == [], do: native, else: get_in(native, path)

      for key <- [:__struct__, "instructions", "provider_mapping", "stage", "remaining_tokens"] do
        extra = Map.put(member, key, __MODULE__)
        value = if path == [], do: extra, else: put_in(native, path, extra)
        assert MaintenanceView.encode_wire(value) == :error
      end
    end
  end

  test "literal schema and vectors pin the approved closed view" do
    schema = contract("schema/maintenance-view.v1.json")
    assert schema["event_kind"] == "context.maintenance_changed"
    assert schema["required"] == ["active_maintenance"]
    assert schema["active_maintenance"]["owner"] == "checkpoint_owner/1"

    for {relative, digest} <- [
          {"schema/maintenance-view.v1.json",
           "2687353577ed1c8380f876ac3ff7ce36cfd5832818a7a9d4c0e52b8c4a0af2f9"},
          {"vectors/maintenance-view.v1.json",
           "65e19feaa24b735299dfdd09a2048ec933a8e13e9288c061ecf70e97aadb9bd8"}
        ] do
      assert :crypto.hash(:sha256, File.read!(path(relative))) |> Base.encode16(case: :lower) ==
               digest
    end
  end

  @tag :node_client
  test "independent Node consumer checks all literals and complete byte boundaries" do
    node = System.find_executable("node") || flunk("Node is required for maintenance conformance")
    runner = Path.expand("../../../clients/node/maintenance-view-vectors.mjs", __DIR__)

    {output, status} =
      System.cmd(node, [runner, path("vectors/maintenance-view.v1.json")], stderr_to_stdout: true)

    assert status == 0, output

    assert {:ok, %{"contract" => "maintenance_view", "checked" => 201, "boundary_checks" => 15}} =
             Frame.decode(String.trim_trailing(output, "\n"), 65_536)
  end

  defp retained(value) when is_integer(value), do: Integer.to_string(value)

  defp retained(value) when is_map(value) do
    Map.new(value, fn
      {key, member} when key in ["episode_id", "id"] ->
        {key, %{"opaque_hex" => Base.encode16(member, case: :lower)}}

      {key, member} ->
        {key, retained(member)}
    end)
  end

  defp retained(value), do: value

  defp run_wire do
    fixture = contract("vectors/maintenance-view.v1.json")
    Enum.find(fixture["cases"], &(&1["name"] == "run-captured-null-deadline"))["input"]
  end

  defp path(relative), do: Path.join([:code.priv_dir(:loopex_protocol), relative])
  defp contract(relative), do: relative |> path() |> File.read!() |> JSON.decode!()
end
