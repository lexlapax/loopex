defmodule LoopexProtocol.Session.CreationCancellationTest do
  use ExUnit.Case, async: true

  alias LoopexProtocol.Frame
  alias LoopexProtocol.Session.CreationCancellation
  alias LoopexProtocol.Wire

  test "the approved opaque byte example is exactly six wire members" do
    assert {:ok, wire} = CreationCancellation.encode_wire(native())

    assert wire == %{
             "type" => "admission",
             "request_id" => "cancel-1",
             "method" => "session.create",
             "command_id" => "_w",
             "status" => "refused",
             "reason" => "creation_cancelled"
           }

    assert {:ok, decoded} = CreationCancellation.decode_wire(wire)
    assert decoded == native()
  end

  test "every opaque byte and the exact original identity limits survive" do
    for bytes <- [
          <<0>>,
          <<255>>,
          :binary.copy(<<255>>, 256),
          :erlang.list_to_binary(Enum.to_list(0..255))
        ] do
      value = %{native() | command_id: bytes}
      assert {:ok, wire} = CreationCancellation.encode_wire(value)
      assert {:ok, ^value} = CreationCancellation.decode_wire(wire)
    end

    for bytes <- ["", :binary.copy(<<255>>, 257)] do
      assert :error = CreationCancellation.encode_wire(%{native() | command_id: bytes})

      assert :error =
               CreationCancellation.decode_wire(
                 Map.put(wire(), "command_id", Wire.encode_identity(bytes))
               )
    end
  end

  test "request identities admit exact ASCII punctuation and one through sixty-four bytes" do
    for request <- [
          "r",
          ".",
          "_",
          "~",
          "-",
          "Ab09._~-",
          String.duplicate("r", 64),
          "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._"
        ] do
      value = %{native() | request_id: request}
      assert {:ok, encoded} = CreationCancellation.encode_wire(value)
      assert {:ok, ^value} = CreationCancellation.decode_wire(encoded)
    end
  end

  test "request identities reject extra bytes whitespace Unicode and nonstrings" do
    for request <- [
          "",
          String.duplicate("r", 65),
          "é",
          "🚀",
          " a",
          "a ",
          "a\n",
          "a\r",
          "a\t",
          "a\0",
          "a/b",
          "a+b",
          "a=b",
          "a:b",
          <<255>>,
          7,
          false,
          [],
          %{},
          nil
        ] do
      assert :error = CreationCancellation.encode_wire(%{native() | request_id: request})
      assert :error = CreationCancellation.decode_wire(Map.put(wire(), "request_id", request))
    end
  end

  test "wire command identity refuses alternate spellings before opaque-byte use" do
    for command <- [
          "",
          "_w=",
          "_w==",
          "_x",
          "/w",
          "+w",
          "_w\n",
          "_w ",
          " _w",
          "_\nw",
          "A",
          "%FF",
          "AA.A",
          "é",
          <<255>>,
          7,
          false,
          [],
          %{},
          nil,
          String.duplicate("_", 343)
        ] do
      assert :error = CreationCancellation.decode_wire(Map.put(wire(), "command_id", command))
    end
  end

  test "every required native and wire member refuses omission null or alternate key types" do
    for {native_key, wire_key} <- [
          type: "type",
          request_id: "request_id",
          method: "method",
          command_id: "command_id",
          status: "status",
          reason: "reason"
        ] do
      assert :error = CreationCancellation.encode_wire(Map.delete(native(), native_key))
      assert :error = CreationCancellation.encode_wire(Map.put(native(), native_key, nil))

      alternate =
        native() |> Map.delete(native_key) |> Map.put(wire_key, Map.fetch!(native(), native_key))

      assert :error = CreationCancellation.encode_wire(alternate)
      assert :error = CreationCancellation.decode_wire(Map.delete(wire(), wire_key))
      assert :error = CreationCancellation.decode_wire(Map.put(wire(), wire_key, nil))

      alternate =
        wire() |> Map.delete(wire_key) |> Map.put(native_key, Map.fetch!(wire(), wire_key))

      assert :error = CreationCancellation.decode_wire(alternate)
    end
  end

  test "accepted status another method or any other refusal cannot become cancellation" do
    for {key, wire_key, values} <- [
          {:type, "type", ["result", "progress", "", 0, false]},
          {:method, "method", ["session.resume", "session.compact", "", 0, false]},
          {:status, "status", ["accepted", "unknown", "", 0, false]},
          {:reason, "reason", ["store_unavailable", "creation_in_progress", "", 0, false]}
        ],
        value <- values do
      assert :error = CreationCancellation.encode_wire(Map.put(native(), key, value))
      assert :error = CreationCancellation.decode_wire(Map.put(wire(), wire_key, value))
    end
  end

  test "session disposition and unknown members refuse even when null" do
    for {native_key, wire_key} <- [
          session_id: "session_id",
          disposition: "disposition",
          extra: "extra",
          credentials: "credentials"
        ],
        value <- [nil, "PRIVATE_CANARY"] do
      assert :error = CreationCancellation.encode_wire(Map.put(native(), native_key, value))
      assert :error = CreationCancellation.decode_wire(Map.put(wire(), wire_key, value))
    end

    assert :error = CreationCancellation.encode_wire(Map.put(native(), :__struct__, __MODULE__))
    assert :error = CreationCancellation.decode_wire(Map.put(wire(), :__struct__, __MODULE__))

    for value <- [nil, [], "admission", 0, false] do
      assert :error = CreationCancellation.encode_wire(value)
      assert :error = CreationCancellation.decode_wire(value)
    end
  end

  test "standalone schema pins the complete cancellation record without serving activation" do
    schema = read_contract("schema/creation-cancelled-admission.v1.json")
    assert schema["contract"] == "creation_cancelled_admission"
    assert schema["revision"] == 1
    assert schema["activation"] == "standalone_payload_not_independently_served"
    assert schema["required"] == ~w(type request_id method command_id status reason)
    assert schema["additional_members"] == "refuse"
    assert schema["type"] == "admission" and schema["method"] == "session.create"
    assert schema["status"] == "refused" and schema["reason"] == "creation_cancelled"

    assert schema["request_id"] == %{
             "encoding" => "ascii",
             "min_bytes" => 1,
             "max_bytes" => 64,
             "grammar" => "[A-Za-z0-9._~-]+"
           }

    assert schema["command_id"] == %{
             "encoding" => "canonical_unpadded_base64url_of_original_opaque_bytes",
             "original_min_bytes" => 1,
             "original_max_bytes" => 256,
             "encoded_max_bytes" => 342
           }

    assert schema["forbidden_members"] == ~w(session_id disposition)
    assert schema["envelope"] == "complete_admission_record"
  end

  test "all retained literals agree with independent decoded byte expectations" do
    fixture = read_contract("vectors/creation-cancelled-admission.v1.json")
    assert fixture["format"] == "loopex.experimental.payload-vectors/1"
    assert fixture["contract"] == "creation_cancelled_admission"
    assert length(fixture["cases"]) == 102
    assert Enum.count(fixture["cases"], &Map.has_key?(&1, "decoded")) == 10

    for vector <- fixture["cases"] do
      if vector["error"] do
        assert CreationCancellation.decode_wire(vector["input"]) == :error, vector["name"]
      else
        assert {:ok, decoded} = CreationCancellation.decode_wire(vector["input"]), vector["name"]
        assert retained(decoded) == vector["decoded"], vector["name"]
        assert CreationCancellation.encode_wire(decoded) == {:ok, vector["input"]}, vector["name"]
      end
    end
  end

  test "schema and vectors are pinned as complete literal populations" do
    for {relative, digest} <- [
          {"schema/creation-cancelled-admission.v1.json",
           "410a328e4d98dcf4a96647fe3bdb9c458b588693f047101f3a3eab029349de3f"},
          {"vectors/creation-cancelled-admission.v1.json",
           "6846995cc9801c0ac72a0b843a819195b49cd8ac88b20fece4b75ed0d54f29ef"}
        ] do
      assert :crypto.hash(:sha256, File.read!(contract_path(relative)))
             |> Base.encode16(case: :lower) == digest
    end
  end

  test "the maximum complete record fits existing output framing and round-trips without session" do
    value = %{
      native()
      | request_id: String.duplicate("r", 64),
        command_id: :binary.copy(<<255>>, 256)
    }

    assert {:ok, record} = CreationCancellation.encode_wire(value)
    assert {:ok, encoded} = Frame.encode(record)
    encoded = IO.iodata_to_binary(encoded)
    assert byte_size(encoded) <= Frame.output_record_bytes()
    assert :binary.last(encoded) == ?\n
    payload = binary_part(encoded, 0, byte_size(encoded) - 1)
    assert {:ok, ^record} = Frame.decode(payload, Frame.output_record_bytes())
    assert {:ok, ^value} = CreationCancellation.decode_wire(record)
    refute Map.has_key?(record, "session_id")
    refute Map.has_key?(record, "disposition")
  end

  test "duplicate correlation and outcome members refuse before map conversion" do
    for literal <- [
          ~s({"type":"admission","request_id":"cancel-1","method":"session.create","command_id":"_w","status":"refused","reason":"creation_cancelled","request_id":"cancel-1"}),
          ~s({"type":"admission","request_id":"cancel-1","method":"session.create","command_id":"_w","status":"refused","reason":"creation_cancelled","command_id":"AA"}),
          ~s({"type":"admission","request_id":"cancel-1","method":"session.create","command_id":"_w","status":"refused","reason":"creation_cancelled","status":"refused"}),
          ~s({"type":"admission","request_id":"cancel-1","method":"session.create","command_id":"_w","status":"refused","reason":"creation_cancelled","reason":"creation_cancelled"})
        ] do
      assert {:error, :duplicate_member} = Frame.decode(literal, Frame.output_record_bytes())
    end
  end

  @tag :node_client
  test "independent Node checks every literal encode decode and inert byte boundary" do
    node =
      System.find_executable("node") || flunk("Node is required for cancellation conformance")

    root = Path.expand("../../..", __DIR__)

    argv = [
      Path.join(root, "clients/node/creation-cancellation-vectors.mjs"),
      contract_path("vectors/creation-cancelled-admission.v1.json"),
      contract_path("schema/creation-cancelled-admission.v1.json")
    ]

    {output, status} = System.cmd(node, argv, stderr_to_stdout: true)
    assert status == 0, output

    assert {:ok,
            %{
              "contract" => "creation_cancelled_admission",
              "checked" => 102,
              "boundary_checks" => 69
            }} = Frame.decode(String.trim_trailing(output, "\n"), 65_536)
  end

  defp native,
    do: %{
      type: "admission",
      request_id: "cancel-1",
      method: "session.create",
      command_id: <<255>>,
      status: "refused",
      reason: "creation_cancelled"
    }

  defp wire do
    {:ok, encoded} = CreationCancellation.encode_wire(native())
    encoded
  end

  defp retained(value),
    do: %{
      "type" => value.type,
      "request_id" => value.request_id,
      "method" => value.method,
      "command_id" => %{"opaque_hex" => Base.encode16(value.command_id, case: :lower)},
      "status" => value.status,
      "reason" => value.reason
    }

  defp contract_path(relative), do: Path.join([:code.priv_dir(:loopex_protocol), relative])
  defp read_contract(relative), do: relative |> contract_path() |> File.read!() |> JSON.decode!()
end
