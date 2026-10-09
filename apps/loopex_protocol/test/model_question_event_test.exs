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
           "fbaa077e006bed444e3b2bb8fe53f1eafe060aec9d4357b3e79da6883aabcab2"},
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

  test "complete terminal vectors preserve exact evidence and refuse contradictory branches" do
    fixture = read("vectors/model-question-terminal.v1.json")
    assert fixture["contract"] == "model_question_terminal"
    assert length(fixture["cases"]) == 377

    for vector <- fixture["cases"] do
      if vector["error"] do
        assert ModelQuestionEvent.decode_terminal(vector["input"]) == :error, vector["name"]
      else
        assert {:ok, native} = ModelQuestionEvent.decode_terminal(vector["input"])
        assert retained(native) == vector["decoded"], vector["name"]
        assert ModelQuestionEvent.encode_terminal(native) == {:ok, vector["input"]}
      end
    end
  end

  test "native terminal identities quantities answers and closed shapes retain their boundaries" do
    text = terminal_vector("terminal-answered-text")
    assert {:ok, native} = ModelQuestionEvent.decode_terminal(text)
    full = :binary.copy(<<255>>, 65_536)

    for key <- ~w(interaction_id run_id tool_call_id command_id) do
      value = Map.put(native, key, full)
      assert {:ok, wire} = ModelQuestionEvent.encode_terminal(value)
      assert ModelQuestionEvent.decode_terminal(wire) == {:ok, value}
      assert ModelQuestionEvent.encode_terminal(Map.put(value, key, full <> "x")) == :error
      assert ModelQuestionEvent.encode_terminal(Map.put(value, key, "")) == :error
    end

    for kind <- ~w(text choice) do
      assert {:ok, cancelled} =
               ModelQuestionEvent.decode_terminal(
                 terminal_vector("terminal-cancelled-" <> kind <> "-abort-command")
               )

      value = Map.put(cancelled, "command_id", full)
      assert {:ok, wire} = ModelQuestionEvent.encode_terminal(value)
      assert ModelQuestionEvent.decode_terminal(wire) == {:ok, value}

      for command <- ["", full <> "x", nil, 1, true, self(), %{}] do
        assert ModelQuestionEvent.encode_terminal(Map.put(cancelled, "command_id", command)) ==
                 :error
      end

      for digest <- [
            nil,
            "",
            String.duplicate("A", 64),
            String.duplicate("a", 63),
            String.duplicate("a", 65),
            true,
            %{}
          ] do
        assert ModelQuestionEvent.encode_terminal(Map.put(cancelled, "command_digest", digest)) ==
                 :error
      end

      closing = %{cancelled | "command_id" => nil, "command_digest" => nil}
      assert {:ok, closing_wire} = ModelQuestionEvent.encode_terminal(closing)
      assert ModelQuestionEvent.decode_terminal(closing_wire) == {:ok, closing}

      assert ModelQuestionEvent.encode_terminal(%{
               cancelled
               | "status" => "expired",
                 "disposition" => "expired"
             }) == :error
    end

    for value <- [0, -1, 18_446_744_073_709_551_616, 1.0, "1", nil, true, self(), %{}] do
      assert ModelQuestionEvent.encode_terminal(%{native | "settlement_sequence" => value}) ==
               :error
    end

    assert ModelQuestionEvent.decode_terminal(%{
             text
             | "settlement_sequence" => String.duplicate("1", 21)
           }) == :error

    for answer <- [
          %{"text" => ""},
          %{"text" => <<255>>},
          %{"text" => String.duplicate("x", 8_193)},
          %{text: "answer"},
          %{"text" => "answer", "extra" => nil},
          %URI{}
        ] do
      assert ModelQuestionEvent.encode_terminal(%{native | "answer" => answer}) == :error
    end

    for key <- Map.keys(native) do
      assert ModelQuestionEvent.encode_terminal(Map.delete(native, key)) == :error

      assert ModelQuestionEvent.encode_terminal(
               native
               |> Map.delete(key)
               |> Map.put("extra", nil)
             ) == :error
    end

    for value <- [
          nil,
          [],
          %URI{},
          Map.put(native, "credential_ref", self()),
          native |> Map.delete("producer") |> Map.put(:producer, "model_tool")
        ] do
      assert ModelQuestionEvent.encode_terminal(value) == :error
      assert ModelQuestionEvent.decode_terminal(value) == :error
    end

    assert {:ok, choice} =
             ModelQuestionEvent.decode_terminal(terminal_vector("terminal-answered-choice"))

    assert ModelQuestionEvent.encode_terminal(put_in(choice, ["answer", "choice_id"], "choice-1")) ==
             :error

    assert ModelQuestionEvent.encode_terminal(put_in(choice, ["answer", "label"], "empty")) ==
             :error

    assert ModelQuestionEvent.encode_terminal(put_in(choice, ["answer", "label"], <<255>>)) ==
             :error

    assert ModelQuestionEvent.encode_terminal(put_in(choice, ["answer", "__struct__"], URI)) ==
             :error
  end

  test "standalone terminal schema pins the existing event branches and exact literal bytes" do
    schema = read("schema/model-question-terminal.v1.json")
    assert schema["closed"] == true
    assert length(schema["required"]) == 15
    assert schema["choice_only_additional_field"] == "choice_id"
    assert schema["status_equals_disposition"] == true
    assert schema["producer"] == "model_tool"
    assert schema["variants"]["expired"]["null_fields"] == ~w(answer command_id command_digest)
    assert schema["variants"]["cancelled"]["null_fields"] == ["answer"]
    assert schema["variants"]["cancelled"]["command_captures"] == "both_null_or_both_valid"

    for key <- ~w(command_id command_digest) do
      assert schema["fields"][key]["null_on"] == ["expired"]
      assert schema["fields"][key]["nullable_on"] == ["cancelled"]
    end

    assert schema["kind_by_disposition"] ==
             read("schema/model-question-events.v1.json")["terminal"]["kind_by_disposition"]

    assert Enum.sort(Map.keys(schema["variants"])) ==
             ~w(answered_choice answered_text cancelled declined expired)

    for {file, digest} <- [
          {"schema/model-question-terminal.v1.json",
           "6bb84c9594bef5532a463f664ee43463a92e881f94267cf4356143af5ebb4563"},
          {"vectors/model-question-terminal.v1.json",
           "747a893c1417f57dfe95da6a5d02ae69165683edb477a5e748c5e26a96e89b44"}
        ] do
      assert :crypto.hash(:sha256, File.read!(path(file))) |> Base.encode16(case: :lower) ==
               digest
    end
  end

  @tag :node_client
  test "independent Node consumes every terminal payload branch and rejects descriptor traps" do
    node = System.find_executable("node") || flunk("Node is required for model-question vectors")
    root = Path.expand("../../..", __DIR__)

    argv = [
      Path.join(root, "clients/node/model-question-event-vectors.mjs"),
      path("vectors/model-question-terminal.v1.json"),
      path("schema/model-question-terminal.v1.json")
    ]

    {output, status} = System.cmd(node, argv, stderr_to_stdout: true)
    assert status == 0, output
    assert output =~ "\"vectors\":377"
  end

  defp terminal_vector(name),
    do:
      Enum.find(read("vectors/model-question-terminal.v1.json")["cases"], &(&1["name"] == name))[
        "input"
      ]

  @identities ~w(interaction_id run_id tool_call_id command_id choice_id id)
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
