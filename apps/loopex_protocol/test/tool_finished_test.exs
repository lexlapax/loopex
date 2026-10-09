defmodule LoopexProtocol.Session.ToolFinishedTest do
  @moduledoc """
  ## Concept

  A tool terminal crosses as the closed variant the session committed: with an
  executor operation identity and no reason, or without one and with an
  optional public reason.

  ## Technical depth

  Accepted ADR 0067 literal vectors are consumed here and by the independent
  Node decoder; neither derives expectations from the other. Native-side
  refusals, full byte boundaries and whole-frame fit are pinned separately.
  """

  use ExUnit.Case, async: true

  alias LoopexProtocol.{Canonical, Frame, Session, Wire}
  alias LoopexProtocol.Session.{ToolFinished, V2}

  @max 18_446_744_073_709_551_615
  @digest String.duplicate("0123456789abcdef", 4)
  @use_digest String.duplicate("fedcba9876543210", 4)

  test "the receipt-backed variant keeps its eight members and exact opaque bytes" do
    native = receipt([artifact(0), artifact(@max)])
    assert {:ok, wire} = ToolFinished.encode_wire(native)

    assert wire == %{
             "run_id" => "AP8K",
             "turn_id" => "dHVyboA",
             "tool_call_id" => "YXNrLTE",
             "operation_id" => "_gBvcA",
             "tool_id" => "loopex.read",
             "outcome" => "completed",
             "reason" => nil,
             "artifacts" => [
               Map.put(artifact(0), "size", "0"),
               Map.put(artifact(@max), "size", "18446744073709551615")
             ]
           }

    assert ToolFinished.decode_wire(wire) == {:ok, native}
  end

  test "the operation-less variant carries null or exact reasons and a null unresolved tool" do
    for reason <- [nil, "", "question_declined", "café ☃", "the run deadline passed"],
        tool_id <- [nil, "loopex.ask"],
        outcome <-
          ~w(completed failed denied cancelled outcome_unknown cancelled_workspace_lease_lost) do
      native = %{
        operation_less()
        | "reason" => reason,
          "tool_id" => tool_id,
          "outcome" => outcome
      }

      assert {:ok, wire} = ToolFinished.encode_wire(native)
      refute Map.has_key?(wire, "operation_id")
      assert wire["reason"] == reason
      assert wire["tool_id"] == tool_id
      assert wire["artifacts"] == []
      assert ToolFinished.decode_wire(wire) == {:ok, native}
    end
  end

  test "the receipt-backed variant refuses reasons, null tools and missing operations" do
    for reason <- ["PRIVATE_REASON", "", "denied"] do
      assert ToolFinished.encode_wire(%{receipt([]) | "reason" => reason}) == :error
    end

    assert ToolFinished.encode_wire(%{receipt([]) | "tool_id" => nil}) == :error

    for operation <- [nil, "", :binary.copy(<<1>>, 65_537), :op, 1] do
      assert ToolFinished.encode_wire(%{receipt([]) | "operation_id" => operation}) == :error
    end

    # Removing the operation member from a receipt that carried artifacts can
    # never fit the operation-less variant; there is no fallback between them.
    assert ToolFinished.encode_wire(Map.delete(receipt([artifact(1)]), "operation_id")) == :error
    assert ToolFinished.encode_wire(%{operation_less() | "artifacts" => [artifact(1)]}) == :error
  end

  test "every native member rejects omission, alternate keys, private members and structs" do
    for native <- [receipt([artifact(1)]), operation_less()] do
      for key <- Map.keys(native) do
        if key != "operation_id" do
          assert ToolFinished.encode_wire(Map.delete(native, key)) == :error, key
        end

        alternate = native |> Map.delete(key) |> Map.put(String.to_atom(key), native[key])
        assert ToolFinished.encode_wire(alternate) == :error, key
      end

      for key <- ~w(private_reason diagnostic credentials thinking job grant receipt) do
        assert ToolFinished.encode_wire(Map.put(native, key, "PRIVATE_CANARY")) == :error
      end

      for envelope <- [:kind, :event_id, :event_sequence] do
        assert ToolFinished.encode_wire(Map.put(native, envelope, "tool.finished")) == :error
      end

      assert ToolFinished.encode_wire(Map.put(native, :__struct__, __MODULE__)) == :error
    end

    for value <- [nil, [], "tool.finished", %{}] do
      assert ToolFinished.encode_wire(value) == :error
      assert ToolFinished.decode_wire(value) == :error
    end
  end

  test "native scalars refuse invalid UTF-8, runtime terms and over-bound values" do
    for reason <- [<<0xFF>>, "a" <> <<0xC3>>, :reason, 1, %{}, :binary.copy("a", 131_073)] do
      assert ToolFinished.encode_wire(%{operation_less() | "reason" => reason}) == :error
    end

    assert {:ok, _} =
             ToolFinished.encode_wire(%{
               operation_less()
               | "reason" => :binary.copy("é", 65_536)
             })

    assert ToolFinished.encode_wire(%{
             operation_less()
             | "reason" => :binary.copy("é", 65_536) <> "a"
           }) == :error

    for tool_id <- ["", "Loopex", "a..b", "1a", :loopex, :binary.copy("a", 129)] do
      assert ToolFinished.encode_wire(%{operation_less() | "tool_id" => tool_id}) == :error
      assert ToolFinished.encode_wire(%{receipt([]) | "tool_id" => tool_id}) == :error
    end

    for outcome <- [nil, :completed, "bound_reached", "COMPLETED"] do
      assert ToolFinished.encode_wire(%{operation_less() | "outcome" => outcome}) == :error
      assert ToolFinished.encode_wire(%{receipt([]) | "outcome" => outcome}) == :error
    end

    for size <- [-1, @max + 1, "1", 1.0, nil] do
      assert ToolFinished.encode_wire(receipt([%{artifact(1) | "size" => size}])) == :error
    end

    for {key, value} <- [
          {"digest", String.upcase(@digest)},
          {"role", "tool_input"},
          {"use_locator", "use:" <> @digest},
          {"locator", ""},
          {"locator", "a\u0000b"},
          {"locator", :binary.copy("x", 1_025)},
          {"media_type", :binary.copy("m", 256)},
          {"use_canonicalization_version", "loopex.canonical.v2"}
        ] do
      assert ToolFinished.encode_wire(receipt([Map.put(artifact(1), key, value)])) == :error
    end

    assert ToolFinished.encode_wire(receipt([Map.put(artifact(1), "path", "/private")])) ==
             :error
  end

  test "identity boundaries hold for every opaque member in both directions" do
    for key <- ~w(run_id turn_id tool_call_id operation_id), size <- [1, 65_536] do
      bytes = :binary.copy(<<255>>, size)
      native = Map.put(receipt([]), key, bytes)
      assert {:ok, wire} = ToolFinished.encode_wire(native)
      assert ToolFinished.decode_wire(wire) == {:ok, native}
    end

    for key <- ~w(run_id turn_id tool_call_id operation_id) do
      assert ToolFinished.encode_wire(Map.put(receipt([]), key, :binary.copy(<<255>>, 65_537))) ==
               :error

      {:ok, wire} = ToolFinished.encode_wire(receipt([]))

      for invalid <- [Wire.encode_identity(:binary.copy(<<255>>, 65_537)), "AB", "AA==", ""] do
        assert ToolFinished.decode_wire(Map.put(wire, key, invalid)) == :error
      end
    end
  end

  test "the largest reason fits one complete foreground and daemon event frame" do
    native = %{
      operation_less()
      | "reason" => :binary.copy("\"", 131_072),
        "run_id" => :binary.copy(<<255>>, 65_536)
    }

    assert {:ok, data} = ToolFinished.encode_wire(native)

    record = %{
      "type" => "event",
      "session_id" => Wire.encode_identity(:binary.copy("s", 256)),
      "event" => %{
        "kind" => "tool.finished",
        "event_id" => Wire.encode_identity(:binary.copy(<<255>>, 65_536)),
        "event_sequence" => Wire.encode_u64(@max),
        "data" => data
      }
    }

    assert {:ok, frame} = Frame.encode(record)
    frame = IO.iodata_to_binary(frame)
    assert byte_size(frame) <= Frame.output_record_bytes()
    line = binary_part(frame, 0, byte_size(frame) - 1)
    assert {:ok, ^record} = Frame.decode(line, Frame.output_record_bytes())
    assert ToolFinished.decode_wire(record["event"]["data"]) == {:ok, native}
  end

  test "all literal vectors decode exactly or refuse the whole value" do
    fixture = read("vectors/tool-finished.v1.json")
    assert fixture["format"] == "loopex.experimental.payload-vectors/1"
    assert fixture["contract"] == "tool_finished"
    assert length(fixture["cases"]) == 196
    assert Enum.count(fixture["cases"], &Map.has_key?(&1, "decoded")) == 29

    for vector <- fixture["cases"] do
      if vector["error"] do
        assert ToolFinished.decode_wire(vector["input"]) == :error, vector["name"]
      else
        assert {:ok, native} = ToolFinished.decode_wire(vector["input"]), vector["name"]
        assert retained(native) == vector["decoded"], vector["name"]
        assert Map.has_key?(native, "operation_id") == (vector["variant"] == "receipt_backed")
        assert ToolFinished.encode_wire(native) == {:ok, vector["input"]}, vector["name"]
      end
    end
  end

  test "both complete manifests embed the exact standalone grammar and change with it" do
    schema = read("schema/tool-finished.v1.json")
    assert schema["selection"] == "exact_member_key_set_without_fallback"

    assert schema["variants"]["receipt_backed"]["required"] ==
             ~w(run_id turn_id tool_call_id operation_id tool_id outcome reason artifacts)

    assert schema["variants"]["operation_less"]["required"] ==
             ~w(run_id turn_id tool_call_id tool_id outcome reason artifacts)

    assert schema["variants"]["receipt_backed"]["reason"] == nil
    assert schema["variants"]["operation_less"]["reason"]["maximum_bytes"] == 131_072

    assert schema["variants"]["operation_less"]["artifacts"] == %{
             "type" => "array",
             "exact" => []
           }

    for contract <- [Session, V2] do
      definitions = contract.manifest()["payload_definitions"]
      assert definitions["nested"]["tool_finished"] == schema

      assert definitions["records"]["event"]["event_data_by_kind"]["tool.finished"] == %{
               "definition_ref" => "tool_finished"
             }

      for path <- [
            ["variants", "operation_less", "reason", "maximum_bytes"],
            ["variants", "receipt_backed", "operation_id"],
            ["variants", "operation_less", "operation_id"]
          ] do
        changed =
          put_in(
            contract.manifest(),
            ["payload_definitions", "nested", "tool_finished" | path],
            "changed"
          )

        refute Canonical.digest(changed) == contract.schema_digest()
      end
    end

    for {relative, digest} <- [
          {"schema/tool-finished.v1.json",
           "62446d5e307f631aae78ae6418bafd6c6f4f52d6fb35f0ceb91da87a5f1b19d4"},
          {"vectors/tool-finished.v1.json",
           "be179d2088911e1669b72c746f1602ed499ec1d85d2e18f3e3a774776803f9e0"}
        ] do
      assert Canonical.digest_bytes(File.read!(path(relative))) == digest
    end
  end

  @tag :node_client
  test "independent Node consumes every literal and byte boundary" do
    node = System.find_executable("node") || flunk("Node is required for tool terminal vectors")
    root = Path.expand("../../..", __DIR__)

    argv = [
      Path.join(root, "clients/node/tool-finished-vectors.mjs"),
      path("vectors/tool-finished.v1.json"),
      path("schema/tool-finished.v1.json")
    ]

    {output, status} = System.cmd(node, argv, stderr_to_stdout: true)
    assert status == 0, output

    assert {:ok,
            %{
              "contract" => "tool_finished",
              "checked" => 196,
              "positive" => 29,
              "boundary_checks" => 34
            }} = Frame.decode(String.trim_trailing(output, "\n"), 65_536)
  end

  defp receipt(artifacts) do
    %{
      "run_id" => <<0, 255, 10>>,
      "turn_id" => "turn" <> <<128>>,
      "tool_call_id" => "ask-1",
      "operation_id" => <<254, 0, ?o, ?p>>,
      "tool_id" => "loopex.read",
      "outcome" => "completed",
      "reason" => nil,
      "artifacts" => artifacts
    }
  end

  defp operation_less do
    receipt([]) |> Map.delete("operation_id") |> Map.put("tool_id", "loopex.ask")
  end

  defp artifact(size) do
    %{
      "digest" => @digest,
      "size" => size,
      "locator" => "artifact:1",
      "media_type" => "text/plain",
      "role" => "tool_output",
      "use_canonicalization_version" => "loopex.canonical.v1",
      "use_digest" => @use_digest,
      "use_locator" => "use:" <> @use_digest
    }
  end

  defp retained(native) do
    Map.new(native, fn
      {key, value} when key in ~w(run_id turn_id tool_call_id operation_id) ->
        {key, %{"opaque_hex" => Base.encode16(value, case: :lower)}}

      {"artifacts", artifacts} ->
        {"artifacts", Enum.map(artifacts, &Map.update!(&1, "size", fn size -> "#{size}" end))}

      pair ->
        pair
    end)
  end

  defp read(relative), do: relative |> path() |> File.read!() |> JSON.decode!()
  defp path(relative), do: Path.join(Path.expand("../priv", __DIR__), relative)
end
