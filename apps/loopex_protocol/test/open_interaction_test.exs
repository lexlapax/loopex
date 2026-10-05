defmodule LoopexProtocol.OpenInteractionTest do
  use ExUnit.Case, async: true
  alias LoopexProtocol.Session.OpenInteraction

  test "complete literal open and answer-admitted vectors preserve both producers" do
    for {file, count, decode, encode} <- [
          {"open-interaction.v1.json", 114, &OpenInteraction.decode_wire/1,
           &OpenInteraction.encode_wire/1},
          {"policy-answer-admitted.v1.json", 60, &OpenInteraction.decode_answer_admitted/1,
           &OpenInteraction.encode_answer_admitted/1}
        ] do
      fixture = read("vectors/" <> file)
      assert length(fixture["cases"]) == count
      for value <- fixture["cases"], do: verify(value, decode, encode)
    end
  end

  test "answered identities preserve full command and offered-choice byte limits" do
    assert {:ok, native} =
             OpenInteraction.decode_wire(vector("open-interaction.v1.json", "policy-answered"))

    command = :binary.copy(<<255>>, 65_536)
    choice = :binary.copy(<<255>>, 64)

    native = %{
      native
      | "answer_command_id" => command,
        "answer_choice_id" => choice,
        "choices" => [%{"id" => choice, "label" => "Proceed"}]
    }

    assert {:ok, wire} = OpenInteraction.encode_wire(native)
    assert OpenInteraction.decode_wire(wire) == {:ok, native}

    assert OpenInteraction.encode_wire(%{native | "answer_command_id" => command <> "x"}) ==
             :error

    assert OpenInteraction.encode_wire(%{native | "answer_choice_id" => choice <> "x"}) == :error
    assert OpenInteraction.encode_wire(%{native | "answer_choice_id" => "unoffered"}) == :error
    assert OpenInteraction.encode_wire(%{native | "answer_choice_id" => nil}) == :error
    assert OpenInteraction.encode_wire(%{native | "answer_command_id" => nil}) == :error
    assert OpenInteraction.encode_wire(Map.put(native, "policy_binding", self())) == :error
  end

  test "answer-admitted native data validates every identity without a public grant" do
    assert {:ok, native} =
             OpenInteraction.decode_answer_admitted(
               vector("policy-answer-admitted.v1.json", "admitted-policy-answer")
             )

    for key <- ~w(interaction_id run_id tool_call_id answer_command_id) do
      full = :binary.copy(<<255>>, 65_536)
      value = Map.put(native, key, full)
      assert {:ok, wire} = OpenInteraction.encode_answer_admitted(value)
      assert OpenInteraction.decode_answer_admitted(wire) == {:ok, value}
      assert OpenInteraction.encode_answer_admitted(Map.put(value, key, full <> "x")) == :error
    end

    full = :binary.copy(<<255>>, 64)

    assert {:ok, wire} =
             OpenInteraction.encode_answer_admitted(%{native | "answer_choice_id" => full})

    assert {:ok, _} = OpenInteraction.decode_answer_admitted(wire)

    assert OpenInteraction.encode_answer_admitted(%{native | "answer_choice_id" => full <> "x"}) ==
             :error

    for value <- [0, -1, 1.0, nil, true, "1", self(), %{}] do
      assert OpenInteraction.encode_answer_admitted(%{native | "turn" => value}) == :error
    end

    for value <- [nil, [], %URI{}, Map.put(native, "grant", %{})] do
      assert OpenInteraction.encode_answer_admitted(value) == :error
      assert OpenInteraction.decode_answer_admitted(value) == :error
    end
  end

  test "literal schema bytes pin the closed pending answered and event shapes" do
    schema = read("schema/open-interaction.v1.json")
    assert length(schema["required_by_status"]["pending"]) == 10
    assert length(schema["required_by_status"]["answered"]) == 12
    event = read("schema/policy-answer-admitted.v1.json")
    assert event["event_kind"] == "interaction.answer_admitted"
    assert length(event["required"]) == 9
    assert event["authority_granted"] == false

    for {file, digest} <- [
          {"schema/open-interaction.v1.json",
           "3b764fe133c8cabf59418d02d890edcb82a5eac764c28e13a41638742e910721"},
          {"schema/policy-answer-admitted.v1.json",
           "34f0d1b76b7823c7747afae43f915b381d699a9b99ddb9386f6a8f3957755a6c"},
          {"vectors/open-interaction.v1.json",
           "2fc849930dc7ccac592c9f076c1a2008bfb86a983531f499490b28d5c5c4288d"},
          {"vectors/policy-answer-admitted.v1.json",
           "3b2dea43ce6525c5bb9fecfc55947da54d2bfeb36faaea459264bc0001fd77b2"}
        ] do
      assert :crypto.hash(:sha256, File.read!(path(file))) |> Base.encode16(case: :lower) ==
               digest
    end
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
