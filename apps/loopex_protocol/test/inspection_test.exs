defmodule LoopexProtocol.InspectionTest do
  use ExUnit.Case, async: true
  alias LoopexProtocol.Session.{Inspection, ActiveBounds}

  test "literal eleven-field observations preserve current views and captured bounds" do
    fixture = read("vectors/inspection.v1.json")
    assert length(fixture["cases"]) == 63

    for value <- fixture["cases"],
        do: verify(value, &Inspection.decode_wire/1, &Inspection.encode_wire/1)
  end

  test "native active bounds retain the exact atom-key coordinator capture" do
    assert {:ok, native} =
             Inspection.decode_wire(
               vector("inspection.v1.json", "active-policy-answer-exact-bounds")
             )

    assert native.status == :active

    assert Enum.sort(Map.keys(native.active_bounds)) ==
             ~w(deadline deadline_ms max_turns token_budget)a

    assert native.active_bounds.max_turns == 184_467_440_737_095_516_160_000_000_001
    assert native.active_bounds.deadline == 18_446_744_073_709_551_615
    assert {:ok, wire} = Inspection.encode_wire(native)
    assert {:ok, _} = ActiveBounds.decode_wire(wire["active_bounds"])

    for key <- Map.keys(native),
        do: assert(Inspection.encode_wire(Map.delete(native, key)) == :error)

    for key <- Map.keys(native.active_bounds) do
      assert Inspection.encode_wire(%{
               native
               | active_bounds: Map.delete(native.active_bounds, key)
             }) == :error
    end

    wrong_keys =
      Map.new(native.active_bounds, fn {key, value} -> {Atom.to_string(key), value} end)

    assert Inspection.encode_wire(%{native | active_bounds: wrong_keys}) == :error
    assert Inspection.encode_wire(Map.put(native, :owner_epoch, 1)) == :error
    assert Inspection.encode_wire(Map.put(native, :journal_version, 9)) == :error
    assert Inspection.encode_wire(%{native | status: "active"}) == :error
    assert Inspection.encode_wire(%{native | active_run_id: nil}) == :error
    assert Inspection.encode_wire(%{native | active_bounds: nil}) == :error
    assert Inspection.encode_wire(%{native | configuration: nil}) == :error
    assert Inspection.encode_wire(%URI{}) == :error
  end

  test "pending work preserves full identity and existing array cardinality" do
    assert {:ok, native} =
             Inspection.decode_wire(vector("inspection.v1.json", "idle-current-configuration"))

    full = :binary.copy(<<255>>, 65_536)
    single = %{native | pending_work_ids: [full]}
    assert {:ok, full_wire} = Inspection.encode_wire(single)
    assert Inspection.decode_wire(full_wire) == {:ok, single}
    value = %{native | pending_work_ids: List.duplicate("a", 1_024)}
    assert {:ok, wire} = Inspection.encode_wire(value)
    assert Inspection.decode_wire(wire) == {:ok, value}

    assert Inspection.encode_wire(%{value | pending_work_ids: [full | value.pending_work_ids]}) ==
             :error

    assert Inspection.encode_wire(%{native | pending_work_ids: [full <> "x"]}) == :error
  end

  test "complete nested definitions and vector bytes remain literal pinned data" do
    schema = read("schema/inspection.v1.json")
    assert length(schema["required"]) == 11
    assert schema["active_bounds"]["definition"] == read("schema/active-bounds.v1.json")
    assert schema["open_interaction"]["definition"] == read("schema/open-interaction.v1.json")

    assert schema["configuration"]["definition"] ==
             Map.delete(read("schema/configuration-projection.v1.json"), "configured_event")

    assert schema["checkpoint"]["definition"] == read("schema/checkpoint-projection.v1.json")
    maintenance = read("schema/maintenance-view.v1.json")["active_maintenance"]

    assert schema["active_maintenance"] ==
             Map.put(maintenance, "owner", read("schema/checkpoint-owner.v1.json"))

    for {file, digest} <- [
          {"schema/inspection.v1.json",
           "26251f514e6240eedfbcfe0e7458a453dc750453357734af33b3fb5f839ef528"},
          {"vectors/inspection.v1.json",
           "3a3ce808d958a8d982a96680528af603321cd859edd481e72f1922578551c564"}
        ] do
      assert :crypto.hash(:sha256, File.read!(path(file))) |> Base.encode16(case: :lower) ==
               digest
    end
  end

  @tag :node_client
  test "independent Node consumes every literal union inspection and answer-admitted vector" do
    node = System.find_executable("node") || flunk("Node is required for inspection conformance")
    root = Path.expand("../../..", __DIR__)

    argv = [
      Path.join(root, "clients/node/inspection-vectors.mjs"),
      path("vectors/open-interaction.v1.json"),
      path("vectors/policy-answer-admitted.v1.json"),
      path("vectors/inspection.v1.json")
    ]

    {output, status} = System.cmd(node, argv, stderr_to_stdout: true)
    assert status == 0, output

    assert JSON.decode!(String.trim(output)) == %{
             "open_vectors" => 114,
             "answer_admitted_vectors" => 60,
             "inspection_vectors" => 63,
             "boundary_checks" => 38
           }
  end

  @identities ~w(session_id active_run_id interaction_id run_id tool_call_id checkpoint_id episode_id prior_checkpoint_id command_id id call_id answer_choice_id answer_command_id pending_work_ids)
  defp retained(value, key \\ nil)

  defp retained(value, _key) when is_map(value),
    do: Map.new(value, fn {key, member} -> {to_string(key), retained(member, to_string(key))} end)

  defp retained(value, key) when is_list(value), do: Enum.map(value, &retained(&1, key))

  defp retained(value, key) when is_binary(value) and key in @identities,
    do: %{"opaque_hex" => Base.encode16(value, case: :lower)}

  defp retained(value, _key) when is_integer(value), do: Integer.to_string(value)
  defp retained(:active, _key), do: "active"
  defp retained(value, _key), do: value
  defp read(relative), do: JSON.decode!(File.read!(path(relative)))
  defp path(relative), do: Path.join(:code.priv_dir(:loopex_protocol), relative)

  defp vector(file, name),
    do: Enum.find(read("vectors/" <> file)["cases"], &(&1["name"] == name))["input"]

  defp verify(vector, decode, encode) do
    if vector["error"] do
      assert decode.(vector["input"]) == :error, vector["name"]
    else
      assert {:ok, native} = decode.(vector["input"]), vector["name"]
      assert retained(native) == vector["decoded"], vector["name"]
      assert encode.(native) == {:ok, vector["input"]}, vector["name"]
    end
  end
end
