defmodule LoopexProtocol.PolicyEventTest do
  use ExUnit.Case, async: true

  alias LoopexProtocol.{Frame, Session.PolicyEvent}

  test "literal requested vectors preserve every actual policy correlation byte" do
    fixture = read("vectors/policy-requested.v1.json")
    assert fixture["contract"] == "policy_requested"
    assert length(fixture["cases"]) == 187

    for vector <- fixture["cases"] do
      if vector["error"] do
        assert PolicyEvent.decode_requested(vector["input"]) == :error, vector["name"]
      else
        assert {:ok, native} = PolicyEvent.decode_requested(vector["input"])
        assert retained(native) == vector["decoded"], vector["name"]
        assert PolicyEvent.encode_requested(native) == {:ok, vector["input"]}
      end
    end
  end

  test "literal terminal vectors retain denied answered expiry and cancelled histories" do
    fixture = read("vectors/policy-terminal.v1.json")
    assert fixture["contract"] == "policy_terminal"
    assert length(fixture["cases"]) == 237

    for vector <- fixture["cases"] do
      kind = vector["event_kind"]

      if vector["error"] do
        assert PolicyEvent.decode_terminal(kind, vector["input"]) == :error, vector["name"]
      else
        assert {:ok, native} = PolicyEvent.decode_terminal(kind, vector["input"])
        assert retained(native) == vector["decoded"], vector["name"]
        assert PolicyEvent.encode_terminal(kind, native) == {:ok, vector["input"]}
      end
    end
  end

  test "native requests reject private captures and preserve full scalar byte domains" do
    assert {:ok, native} =
             PolicyEvent.decode_requested(vector("policy-requested", "requested-policy-choice"))

    full = :binary.copy(<<255>>, 65_536)

    for field <- ~w(interaction_id run_id tool_call_id) do
      value = Map.put(native, field, full)
      assert {:ok, wire} = PolicyEvent.encode_requested(value)
      assert PolicyEvent.decode_requested(wire) == {:ok, value}

      for invalid <- ["", full <> "x", nil, 1, self(), %{}, []] do
        assert PolicyEvent.encode_requested(Map.put(native, field, invalid)) == :error
      end
    end

    for field <-
          ~w(producer interaction_kind status answer_command_id choice_id reason policy_ref grant turn_id) do
      assert PolicyEvent.encode_requested(Map.put(native, field, "private-canary")) == :error
    end

    for invalid <- [0, -1, "1", 1.0, nil, true, self()] do
      assert PolicyEvent.encode_requested(%{native | "turn" => invalid}) == :error
    end

    for invalid <- [-1, 18_446_744_073_709_551_616, "1", 1.0, nil, self()] do
      assert PolicyEvent.encode_requested(%{native | "expires_at" => invalid}) == :error
    end

    for invalid <- ["", <<255>>, String.duplicate("猫", 683)] do
      assert PolicyEvent.encode_requested(%{native | "prompt" => invalid}) == :error
    end

    for invalid <- [
          [],
          [%{"id" => "x", "label" => <<255>>}],
          [%{"id" => :binary.copy("x", 65), "label" => "Allow"}],
          [hd(native["choices"]) | :private]
        ] do
      assert PolicyEvent.encode_requested(%{native | "choices" => invalid}) == :error

      assert PolicyEvent.decode_requested(
               Map.put(vector("policy-requested", "requested-policy-choice"), "choices", invalid)
             ) == :error
    end

    for value <- [nil, [], %URI{}, Map.put(native, :interaction_id, "private")] do
      assert PolicyEvent.encode_requested(value) == :error
      assert PolicyEvent.decode_requested(value) == :error
    end

    for field <- Map.keys(native),
        do: assert(PolicyEvent.encode_requested(Map.delete(native, field)) == :error)
  end

  test "native terminal reason bytes are bounded and deliberately absent after decoding" do
    wire = vector("policy-terminal", "terminal-denied-answered")
    assert {:ok, native} = PolicyEvent.decode_terminal("interaction.resolved", wire)

    for reason <- ["", <<255, 0>>, :binary.copy(<<255>>, 65_536)] do
      value = Map.put(native, "reason", reason)
      assert PolicyEvent.encode_terminal("interaction.resolved", value) == {:ok, wire}
      assert PolicyEvent.decode_terminal("interaction.resolved", wire) == {:ok, native}
      refute Map.has_key?(native, "reason")
    end

    for reason <- [nil, 1, self(), [], %{}, :binary.copy("x", 65_537)] do
      assert PolicyEvent.encode_terminal(
               "interaction.resolved",
               Map.put(native, "reason", reason)
             ) == :error
    end

    for field <- ~w(interaction_id run_id tool_call_id answer_command_id choice_id) do
      maximum = if field == "choice_id", do: 64, else: 65_536
      full = :binary.copy(<<255>>, maximum)
      value = Map.put(native, field, full)
      assert {:ok, encoded} = PolicyEvent.encode_terminal("interaction.resolved", value)
      assert PolicyEvent.decode_terminal("interaction.resolved", encoded) == {:ok, value}

      for invalid <- ["", full <> "x", nil, 1, self(), %{}, []] do
        assert PolicyEvent.encode_terminal(
                 "interaction.resolved",
                 Map.put(native, field, invalid)
               ) == :error
      end
    end

    for invalid <- [0, -1, "1", 1.0, nil, true, self()] do
      assert PolicyEvent.encode_terminal("interaction.resolved", %{native | "turn" => invalid}) ==
               :error
    end

    for field <- Map.keys(native),
        do:
          assert(
            PolicyEvent.encode_terminal("interaction.resolved", Map.delete(native, field)) ==
              :error
          )

    for value <- [
          nil,
          [],
          %URI{},
          Map.put(native, :resolution, "denied"),
          Map.put(native, "grant", self())
        ] do
      assert PolicyEvent.encode_terminal("interaction.resolved", value) == :error
      assert PolicyEvent.decode_terminal("interaction.resolved", value) == :error
    end
  end

  test "event kinds and actual nullable answer captures admit exactly the six terminal rows" do
    assert {:ok, answered} =
             PolicyEvent.decode_terminal(
               "interaction.resolved",
               vector("policy-terminal", "terminal-answered-answered")
             )

    for {kind, resolution} <- [
          {"interaction.resolved", "allowed"},
          {"interaction.resolved", "denied"},
          {"interaction.expired", "expired"},
          {"interaction.cancelled", "cancelled"}
        ] do
      value = %{answered | "resolution" => resolution}
      assert {:ok, encoded} = PolicyEvent.encode_terminal(kind, value)
      assert PolicyEvent.decode_terminal(kind, encoded) == {:ok, value}
      pending = value |> Map.delete("choice_id") |> Map.put("answer_command_id", nil)

      if resolution in ~w(expired cancelled) do
        assert {:ok, wire} = PolicyEvent.encode_terminal(kind, pending)
        assert wire["answer_choice_id"] == nil and wire["answer_command_id"] == nil
        assert PolicyEvent.decode_terminal(kind, wire) == {:ok, pending}
        assert PolicyEvent.encode_terminal(kind, Map.put(pending, "choice_id", nil)) == :error
      else
        assert PolicyEvent.encode_terminal(kind, pending) == :error
      end

      assert PolicyEvent.encode_terminal(kind, Map.delete(value, "choice_id")) == :error
      assert PolicyEvent.encode_terminal(kind, %{value | "answer_command_id" => nil}) == :error

      for other <- ~w(interaction.requested interaction.answer_admitted unknown),
          do: assert(PolicyEvent.encode_terminal(other, value) == :error)
    end

    for kind <- [nil, 0, self(), %{}] do
      assert PolicyEvent.encode_terminal(kind, answered) == :error

      assert PolicyEvent.decode_terminal(
               kind,
               vector("policy-terminal", "terminal-answered-answered")
             ) == :error
    end
  end

  test "literal schemas pin closed native and wire domains without generation activation" do
    requested = read("schema/policy-requested.v1.json")
    terminal = read("schema/policy-terminal.v1.json")
    assert requested["closed"] and terminal["closed"]
    assert length(requested["required"]) == 10 and length(requested["native_required"]) == 7
    assert length(terminal["required"]) == 9 and length(terminal["native_required"]) == 6
    assert terminal["variants"]["denied"]["answer_pair"] == "both_nonnull"
    assert terminal["native_conditional"]["reason"]["maximum_bytes"] == 65_536
    assert requested["output_record_bytes_including_newline"] == Frame.output_record_bytes()
    assert terminal["output_record_bytes_including_newline"] == Frame.output_record_bytes()

    for {file, digest} <- pins() do
      assert :crypto.hash(:sha256, File.read!(path(file))) |> Base.encode16(case: :lower) ==
               digest
    end
  end

  test "the exact complete output overrun refuses before arbitrary turn decoding" do
    for {contract, codec} <- [
          {"policy-requested", &PolicyEvent.decode_requested/1},
          {"policy-terminal", &PolicyEvent.decode_terminal("interaction.resolved", &1)}
        ] do
      name = if contract == "policy-requested", do: "request", else: "terminal"
      wire = vector(contract, name <> "-exact-output-record-overrun")
      assert {:error, :output_record_too_large} = Frame.encode(wire)
      assert IO.iodata_length([JSON.encode!(wire), "\n"]) == Frame.output_record_bytes() + 1
      assert codec.(wire) == :error
    end
  end

  @tag :node_client
  test "independent Node validates every requested policy payload and native boundary" do
    run_node("policy-requested", 187)
  end

  @tag :node_client
  test "independent Node validates every terminal policy row and native reason boundary" do
    run_node("policy-terminal", 237)
  end

  defp run_node(contract, count) do
    node = System.find_executable("node") || flunk("Node is required for policy vectors")
    root = Path.expand("../../..", __DIR__)

    argv = [
      Path.join(root, "clients/node/policy-interaction-event-vectors.mjs"),
      contract,
      path("vectors/" <> contract <> ".v1.json"),
      path("schema/" <> contract <> ".v1.json")
    ]

    {output, status} = System.cmd(node, argv, stderr_to_stdout: true)
    assert status == 0, output
    assert output =~ "\"vectors\":" <> Integer.to_string(count)
  end

  defp pins,
    do: [
      {"schema/policy-requested.v1.json",
       "684f2bd45fb6720291eeeac31e09a99e1f81f0b0662fbf122cfc1ccf4791e9c7"},
      {"schema/policy-terminal.v1.json",
       "bab1d537933764c1c51bc1b2c9430ba1d3e1dbeee7f4978cc244cd7680b94e76"},
      {"vectors/policy-requested.v1.json",
       "9dcae66c03cb1cabf0db28f46deedb52f9952bb722a16b73a7128766c0d64bbe"},
      {"vectors/policy-terminal.v1.json",
       "b63a8de4efca09b1098ac557cdc9175ff146bdfdf41e23b673d2144b730e73e3"}
    ]

  @identities ~w(interaction_id run_id tool_call_id choice_id answer_command_id id)
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

  defp vector(contract, name),
    do:
      Enum.find(read("vectors/" <> contract <> ".v1.json")["cases"], &(&1["name"] == name))[
        "input"
      ]
end
