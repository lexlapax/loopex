defmodule LoopexProtocol.ModelQuestionEventTest do
  use ExUnit.Case, async: true

  alias LoopexProtocol.Session.ModelQuestionEvent

  test "complete literal requested-model vectors retain every null and exact byte" do
    fixture = read("vectors/model-question-requested.v1.json")
    assert fixture["contract"] == "model_question_requested"
    assert length(fixture["cases"]) == 141

    for vector <- fixture["cases"] do
      if vector["error"] do
        assert ModelQuestionEvent.decode_requested(vector["input"]) == :error, vector["name"]
      else
        assert {:ok, native} = ModelQuestionEvent.decode_requested(vector["input"])
        assert retained(native) == vector["decoded"], vector["name"]
        assert ModelQuestionEvent.encode_requested(native) == {:ok, vector["input"]}
      end
    end
  end

  test "native requested data preserves full identities and rejects pending evidence" do
    assert {:ok, native} = ModelQuestionEvent.decode_requested(vector("requested-model-choice"))
    full = :binary.copy(<<255>>, 65_536)

    for key <- ~w(interaction_id run_id tool_call_id) do
      value = Map.put(native, key, full)
      assert {:ok, wire} = ModelQuestionEvent.encode_requested(value)
      assert ModelQuestionEvent.decode_requested(wire) == {:ok, value}
      assert ModelQuestionEvent.encode_requested(Map.put(value, key, full <> "x")) == :error
      assert ModelQuestionEvent.encode_requested(Map.put(value, key, "")) == :error
    end

    for key <- ~w(answer command_digest command_id disposition settlement_sequence),
        value <- [false, 0, "", [], %{}, self()] do
      assert ModelQuestionEvent.encode_requested(Map.put(native, key, value)) == :error
    end

    for value <- [0, -1, 1.0, nil, true, "1", self(), %{}] do
      assert ModelQuestionEvent.encode_requested(%{native | "turn" => value}) == :error
    end

    for value <- [-1, 18_446_744_073_709_551_616, 1.0, nil, true, "1", self(), %{}] do
      assert ModelQuestionEvent.encode_requested(%{native | "expires_at" => value}) == :error
    end

    assert ModelQuestionEvent.encode_requested(%{native | "prompt" => <<255>>}) == :error

    for key <- Map.keys(native) do
      assert ModelQuestionEvent.encode_requested(Map.delete(native, key)) == :error
    end

    for value <- [nil, [], %URI{}, Map.put(native, "grant", self())] do
      assert ModelQuestionEvent.encode_requested(value) == :error
      assert ModelQuestionEvent.decode_requested(value) == :error
    end

    atom_keys = native |> Map.delete("producer") |> Map.put(:producer, "model_tool")
    assert ModelQuestionEvent.encode_requested(atom_keys) == :error
  end

  test "standalone literal schema retains model-only variants and shared byte domains" do
    schema = read("schema/model-question-requested.v1.json")
    shared = read("schema/open-interaction.v1.json")
    assert schema["event_kind"] == "interaction.requested"
    assert schema["closed"] == true
    assert length(schema["required"]) == 15
    assert schema["producer"] == "model_tool"
    assert schema["status"] == "pending"

    assert schema["required_null_fields"] ==
             ~w(answer command_digest command_id disposition settlement_sequence)

    assert Enum.sort(Map.keys(schema["variants"])) ==
             ~w(model_tool_choice model_tool_text)

    for key <- ~w(interaction_id run_id turn tool_call_id prompt choices expires_at),
        do: assert(schema["fields"][key] == shared[key])

    for {file, digest} <- [
          {"schema/model-question-requested.v1.json",
           "e91c864a7ae2db429243f2ec874667ab3adcb521a94b9d404fb81f1ab1a67fc6"},
          {"vectors/model-question-requested.v1.json",
           "04ea6b8ebe77217fef3fcc30875973cb447761c9e89af7b7ec6b34aa18e861cf"}
        ] do
      assert :crypto.hash(:sha256, File.read!(path(file))) |> Base.encode16(case: :lower) ==
               digest
    end
  end

  @tag :node_client
  test "independent Node consumes the complete literal requested payload" do
    node = System.find_executable("node") || flunk("Node is required for model-question vectors")
    root = Path.expand("../../..", __DIR__)

    argv = [
      Path.join(root, "clients/node/model-question-event-vectors.mjs"),
      path("vectors/model-question-requested.v1.json"),
      path("schema/model-question-requested.v1.json")
    ]

    {output, status} = System.cmd(node, argv, stderr_to_stdout: true)
    assert status == 0, output
    assert output =~ "\"vectors\":141"
  end

  @identities ~w(interaction_id run_id tool_call_id id)
  defp retained(value, key \\ nil)

  defp retained(value, _key) when is_map(value),
    do: Map.new(value, fn {key, member} -> {key, retained(member, key)} end)

  defp retained(value, key) when is_list(value), do: Enum.map(value, &retained(&1, key))

  defp retained(value, key) when is_binary(value) and key in @identities,
    do: %{"opaque_hex" => Base.encode16(value, case: :lower)}

  defp retained(value, _key) when is_integer(value), do: Integer.to_string(value)
  defp retained(value, _key), do: value
  defp read(relative), do: JSON.decode!(File.read!(path(relative)))
  defp path(relative), do: Path.join(:code.priv_dir(:loopex_protocol), relative)

  defp vector(name),
    do:
      Enum.find(read("vectors/model-question-requested.v1.json")["cases"], &(&1["name"] == name))[
        "input"
      ]
end
