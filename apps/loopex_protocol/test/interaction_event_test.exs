defmodule LoopexProtocol.InteractionEventTest do
  use ExUnit.Case, async: true

  alias LoopexProtocol.Session.InteractionEvent

  @endings %{
    "answered" => "interaction.answered",
    "declined" => "interaction.declined",
    "expired" => "interaction.expired",
    "cancelled" => "interaction.cancelled"
  }

  test "all literal model requests retain their explicit producer and null captures" do
    assert_vectors("model-question-requested", 141, fn _ -> "interaction.requested" end)
  end

  test "all literal model endings retain their kind-correlated disposition" do
    assert_vectors("model-question-terminal", 377, &model_kind/1)
  end

  test "all literal policy requests select only their complete closed native shape" do
    assert_vectors("policy-requested", 187, fn _ -> "interaction.requested" end)
  end

  test "all literal policy endings preserve actual nullable answer pairs" do
    assert_vectors("policy-terminal", 237, & &1["event_kind"])
  end

  test "all literal policy admissions stay distinct from model settlement" do
    assert_vectors("policy-answer-admitted", 60, fn _ -> "interaction.answer_admitted" end)
  end

  test "model endings refuse every mismatched interaction kind in native and wire form" do
    for vector <- positive("model-question-terminal"),
        kind <-
          ["interaction.requested", "interaction.answer_admitted", "interaction.resolved"] ++
            Map.values(@endings) do
      native = restore(vector["decoded"])
      expected_kind = model_kind(vector)

      if kind == expected_kind do
        assert InteractionEvent.encode(kind, native) == {:ok, vector["input"]}
        assert InteractionEvent.decode(kind, vector["input"]) == {:ok, native}
      else
        assert InteractionEvent.encode(kind, native) == :error, inspect({vector["name"], kind})

        assert InteractionEvent.decode(kind, vector["input"]) == :error,
               inspect({vector["name"], kind})
      end
    end
  end

  test "missing producer never admits a malformed policy or a stripped model request" do
    model = vector("model-question-requested", "requested-model-choice")
    policy = vector("policy-requested", "requested-policy-choice")
    native_model = restore(model["decoded"])
    native_policy = restore(policy["decoded"])

    assert InteractionEvent.encode("interaction.requested", native_policy) ==
             {:ok, policy["input"]}

    for native <- [
          Map.delete(native_model, "producer"),
          Map.delete(native_policy, "prompt"),
          Map.put(native_policy, "producer", nil),
          Map.put(native_policy, "producer", "policy_defer"),
          Map.put(native_model, "answer", "private"),
          Map.put(native_policy, "grant", self())
        ] do
      assert InteractionEvent.encode("interaction.requested", native) == :error
    end

    for wire <- [
          Map.delete(model["input"], "producer"),
          Map.delete(policy["input"], "producer"),
          Map.put(model["input"], "producer", "policy_defer"),
          Map.put(policy["input"], "producer", "model_tool"),
          Map.put(policy["input"], "producer", nil)
        ] do
      assert InteractionEvent.decode("interaction.requested", wire) == :error
    end
  end

  test "shared expiry and cancellation require the exact producer branch" do
    for kind <- ~w(interaction.expired interaction.cancelled) do
      model = Enum.find(positive("model-question-terminal"), &(model_kind(&1) == kind))
      policy = Enum.find(positive("policy-terminal"), &(&1["event_kind"] == kind))

      for vector <- [model, policy] do
        native = restore(vector["decoded"])
        assert InteractionEvent.encode(kind, native) == {:ok, vector["input"]}
        assert InteractionEvent.decode(kind, vector["input"]) == {:ok, native}

        other =
          if vector["input"]["producer"] == "model_tool", do: "policy_defer", else: "model_tool"

        assert InteractionEvent.decode(kind, Map.put(vector["input"], "producer", other)) ==
                 :error

        assert InteractionEvent.decode(kind, Map.delete(vector["input"], "producer")) == :error
        assert InteractionEvent.encode(kind, Map.put(native, "producer", other)) == :error
      end
    end
  end

  test "identical answered wire members have separate admission and resolution meanings" do
    admitted = vector("policy-answer-admitted", "admitted-policy-answer")
    wire = admitted["input"]
    admission = restore(admitted["decoded"])

    resolution =
      admission
      |> Map.drop(~w(producer interaction_kind status answer_choice_id))
      |> Map.put("choice_id", admission["answer_choice_id"])
      |> Map.put("resolution", "allowed")

    assert InteractionEvent.decode("interaction.answer_admitted", wire) == {:ok, admission}
    assert InteractionEvent.decode("interaction.resolved", wire) == {:ok, resolution}
    assert InteractionEvent.encode("interaction.answer_admitted", admission) == {:ok, wire}
    assert InteractionEvent.encode("interaction.resolved", resolution) == {:ok, wire}
    assert InteractionEvent.encode("interaction.resolved", admission) == :error
    assert InteractionEvent.encode("interaction.answer_admitted", resolution) == :error

    assert InteractionEvent.decode(
             "interaction.answer_admitted",
             Map.put(wire, "status", "denied")
           ) == :error

    collision = vector("policy-terminal", "terminal-kind-interaction.answer_admitted-answered")
    terminal = vector("policy-terminal", "terminal-answered-answered")
    collision_native = collision_admission()
    terminal_native = restore(terminal["decoded"])
    assert collision["input"] == terminal["input"]

    assert InteractionEvent.decode("interaction.answer_admitted", collision["input"]) ==
             {:ok, collision_native}

    assert InteractionEvent.decode("interaction.resolved", collision["input"]) ==
             {:ok, terminal_native}

    assert InteractionEvent.encode("interaction.answer_admitted", collision_native) ==
             {:ok, terminal["input"]}

    assert InteractionEvent.encode("interaction.resolved", terminal_native) ==
             {:ok, collision["input"]}

    assert InteractionEvent.encode("interaction.resolved", collision_native) == :error
    assert InteractionEvent.encode("interaction.answer_admitted", terminal_native) == :error

    model = vector("model-question-terminal", "terminal-answered-text")
    assert InteractionEvent.decode("interaction.answer_admitted", model["input"]) == :error

    assert InteractionEvent.encode("interaction.answer_admitted", restore(model["decoded"])) ==
             :error
  end

  test "policy reason validates before omission and private or extra members refuse" do
    vector = vector("policy-terminal", "terminal-denied-answered")
    native = restore(vector["decoded"])

    for reason <- ["", <<0, 255>>, :binary.copy(<<255>>, 65_536)] do
      assert InteractionEvent.encode("interaction.resolved", Map.put(native, "reason", reason)) ==
               {:ok, vector["input"]}

      assert InteractionEvent.decode("interaction.resolved", vector["input"]) == {:ok, native}
    end

    for reason <- [nil, self(), [], %{}, :binary.copy(<<255>>, 65_537)] do
      assert InteractionEvent.encode("interaction.resolved", Map.put(native, "reason", reason)) ==
               :error
    end

    for field <- ~w(policy_ref credential grant private_capture producer) do
      assert InteractionEvent.encode(
               "interaction.resolved",
               Map.put(native, field, "PRIVATE_CANARY")
             ) == :error

      assert InteractionEvent.decode(
               "interaction.resolved",
               Map.put(vector["input"], field, "PRIVATE_CANARY")
             ) == :error
    end
  end

  test "selectors preserve opaque identity ceilings and reject implementation terms and kinds" do
    vector = vector("model-question-terminal", "terminal-answered-text")
    native = restore(vector["decoded"])
    full = :binary.copy(<<255>>, 65_536)
    maximum = %{native | "interaction_id" => full, "command_id" => full}
    assert {:ok, wire} = InteractionEvent.encode("interaction.answered", maximum)
    assert InteractionEvent.decode("interaction.answered", wire) == {:ok, maximum}

    assert InteractionEvent.encode(
             "interaction.answered",
             Map.put(maximum, "command_id", full <> "x")
           ) == :error

    for kind <- [nil, 1, :interaction_answered, "__proto__", "interaction.unknown"],
        value <- [native, vector["input"]] do
      assert InteractionEvent.encode(kind, value) == :error
      assert InteractionEvent.decode(kind, value) == :error
    end

    for value <- [nil, [], self(), %URI{}, Map.put(native, :producer, "model_tool")] do
      assert InteractionEvent.encode("interaction.answered", value) == :error
      assert InteractionEvent.decode("interaction.answered", value) == :error
    end
  end

  @tag :node_client
  test "independent Node selects all existing literals and checks kind and inert-data boundaries" do
    node =
      System.find_executable("node") || flunk("Node is required for interaction selector vectors")

    root = Path.expand("../../..", __DIR__)
    runner = Path.join(root, "clients/node/interaction-event-vectors.mjs")

    {output, status} =
      System.cmd(node, [runner, Path.join(:code.priv_dir(:loopex_protocol), "vectors")],
        stderr_to_stdout: true
      )

    assert status == 0, output

    assert %{"vectors" => 1_002, "kind_checks" => kinds, "boundary_checks" => boundaries} =
             JSON.decode!(output)

    assert kinds > 0
    assert boundaries > 0
  end

  defp assert_vectors(file, count, kind) do
    vectors = read(file)["cases"]
    assert length(vectors) == count

    for vector <- vectors do
      event_kind = kind.(vector)

      cond do
        file == "policy-terminal" and
            vector["name"] == "terminal-kind-interaction.answer_admitted-answered" ->
          assert vector["error"] == true
          assert event_kind == "interaction.answer_admitted"

          assert vector["input"] ==
                   vector("policy-terminal", "terminal-answered-answered")["input"]

          native = collision_admission()
          assert InteractionEvent.decode(event_kind, vector["input"]) == {:ok, native}
          assert InteractionEvent.encode(event_kind, native) == {:ok, vector["input"]}

        vector["error"] ->
          assert InteractionEvent.decode(event_kind, vector["input"]) == :error, vector["name"]

        true ->
          native = restore(vector["decoded"])

          assert InteractionEvent.decode(event_kind, vector["input"]) == {:ok, native},
                 vector["name"]

          assert InteractionEvent.encode(event_kind, native) == {:ok, vector["input"]},
                 vector["name"]
      end
    end
  end

  # Concept: One terminal-only negative literal is a valid admission for the shared selector.
  # Technical depth: These native fields are independent literals; the terminal fixture's
  # retained input must exactly match its positive answered resolution before admitting it.
  defp collision_admission do
    %{
      "interaction_id" => <<0, 255, 10>>,
      "run_id" => <<114, 117, 110, 128>>,
      "turn" => 1,
      "tool_call_id" => <<99, 97, 108, 108, 0>>,
      "producer" => "policy_defer",
      "interaction_kind" => "choice",
      "status" => "answered",
      "answer_choice_id" => <<255>>,
      "answer_command_id" => <<97, 110, 115, 119, 101, 114, 0, 254>>
    }
  end

  defp model_kind(vector) do
    input = vector["input"]
    disposition = if is_map(input), do: input["disposition"], else: nil
    Map.get(@endings, disposition, "interaction.answered")
  end

  defp restore(value, key \\ nil)

  defp restore(%{"opaque_hex" => hex} = value, _key) when map_size(value) == 1,
    do: Base.decode16!(hex, case: :lower)

  defp restore(value, _key) when is_map(value),
    do: Map.new(value, fn {key, member} -> {key, restore(member, key)} end)

  defp restore(value, key) when is_list(value), do: Enum.map(value, &restore(&1, key))

  defp restore(value, key)
       when key in ~w(turn expires_at settlement_sequence) and is_binary(value),
       do: String.to_integer(value)

  defp restore(value, _key), do: value

  defp positive(file), do: Enum.reject(read(file)["cases"], & &1["error"])
  defp vector(file, name), do: Enum.find(read(file)["cases"], &(&1["name"] == name))

  defp read(file),
    do:
      JSON.decode!(
        File.read!(Path.join(:code.priv_dir(:loopex_protocol), "vectors/#{file}.v1.json"))
      )
end
