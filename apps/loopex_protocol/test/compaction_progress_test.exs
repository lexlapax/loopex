defmodule LoopexProtocol.Session.CompactionProgressTest do
  use ExUnit.Case, async: true

  alias LoopexProtocol.Session.CompactionProgress
  alias LoopexProtocol.Wire

  @max 18_446_744_073_709_551_615

  test "both actual owner kinds and opaque identities encode to the exact six wire members" do
    for kind <- ["run", "compact"], base <- [0, @max] do
      native = native(kind, base)
      assert {:ok, wire} = CompactionProgress.encode_wire(native)

      assert wire == %{
               "kind" => "context.compaction_progress",
               "episode_id" => "AP8K",
               "owner" => %{"kind" => kind, "id" => "_wCA"},
               "stream_domain_id" => "MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY",
               "progress_sequence" => "0",
               "base_event_sequence" => Integer.to_string(base)
             }

      assert {:ok, ^native} = CompactionProgress.decode_wire(wire)
    end
  end

  test "original byte ceilings admit one and 65536 bytes for each identity" do
    for size <- [1, 65_536] do
      bytes = :binary.copy(<<255>>, size)
      native = %{native() | episode_id: bytes, owner: %{"kind" => "run", "id" => bytes}}
      assert {:ok, wire} = CompactionProgress.encode_wire(native)
      assert {:ok, ^native} = CompactionProgress.decode_wire(wire)
    end
  end

  test "empty and oversized episode and owner identities refuse in either direction" do
    for bytes <- ["", :binary.copy(<<255>>, 65_537)] do
      for invalid <- [
            %{native() | episode_id: bytes},
            %{native() | owner: %{"kind" => "run", "id" => bytes}}
          ] do
        assert :error = CompactionProgress.encode_wire(invalid)
      end

      wire = wire()

      assert :error =
               CompactionProgress.decode_wire(
                 Map.put(wire, "episode_id", Wire.encode_identity(bytes))
               )

      assert :error =
               CompactionProgress.decode_wire(
                 Map.put(wire, "owner", %{"kind" => "run", "id" => Wire.encode_identity(bytes)})
               )
    end
  end

  test "each native required member rejects omission null and alternate keys" do
    native = native()

    for key <- Map.keys(native) do
      assert :error = CompactionProgress.encode_wire(Map.delete(native, key))
      assert :error = CompactionProgress.encode_wire(Map.put(native, key, nil))

      alternate =
        native |> Map.delete(key) |> Map.put(Atom.to_string(key), Map.fetch!(native, key))

      assert :error = CompactionProgress.encode_wire(alternate)
    end
  end

  test "each wire required member rejects omission null and alternate keys" do
    wire = wire()

    for key <- Map.keys(wire) do
      assert :error = CompactionProgress.decode_wire(Map.delete(wire, key))
      assert :error = CompactionProgress.decode_wire(Map.put(wire, key, nil))

      alternate =
        wire |> Map.delete(key) |> Map.put(String.to_existing_atom(key), Map.fetch!(wire, key))

      assert :error = CompactionProgress.decode_wire(alternate)
    end
  end

  test "plain maps exclude structs extra keys and private captures" do
    for key <- [:summary, :phase, :attempt, :credentials, :permit, :digest, :owner_epoch] do
      assert :error = CompactionProgress.encode_wire(Map.put(native(), key, "PRIVATE_CANARY"))

      assert :error =
               CompactionProgress.decode_wire(
                 Map.put(wire(), Atom.to_string(key), "PRIVATE_CANARY")
               )
    end

    assert :error = CompactionProgress.encode_wire(Map.put(native(), :__struct__, __MODULE__))
    assert :error = CompactionProgress.decode_wire(Map.put(wire(), :__struct__, __MODULE__))
    assert :error = CompactionProgress.encode_wire([])
    assert :error = CompactionProgress.decode_wire([])
  end

  test "the owner remains a plain closed string keyed actual run or compact identity" do
    for owner <- [
          %{"kind" => "other", "id" => "id"},
          %{kind: "run", id: "id"},
          %{"kind" => "run", "id" => "id", "run_id" => "private"},
          %{"kind" => "run"},
          %{"kind" => "run", "id" => nil},
          %{"kind" => "run", "id" => "id", :__struct__ => __MODULE__}
        ] do
      assert :error = CompactionProgress.encode_wire(%{native() | owner: owner})
      assert :error = CompactionProgress.decode_wire(Map.put(wire(), "owner", owner))
    end
  end

  test "domain requires exactly 32 lowercase hexadecimal native bytes" do
    for domain <- [
          "",
          String.duplicate("a", 31),
          String.duplicate("a", 33),
          String.duplicate("A", 32),
          String.duplicate("g", 32),
          :binary.copy(<<255>>, 32),
          nil
        ] do
      assert :error = CompactionProgress.encode_wire(%{native() | stream_domain_id: domain})

      if is_binary(domain) do
        assert :error =
                 CompactionProgress.decode_wire(
                   Map.put(wire(), "stream_domain_id", Wire.encode_identity(domain))
                 )
      end
    end
  end

  test "base admits only unsigned native integers and canonical u64 wire decimals" do
    for base <- [-1, @max + 1, 0.0, "0", false] do
      assert :error = CompactionProgress.encode_wire(%{native() | base_event_sequence: base})
    end

    for base <- [-1, 0, @max, "-1", "+0", "00", " 0", "0 ", "18446744073709551616", "0.0", "1e0"] do
      assert :error = CompactionProgress.decode_wire(Map.put(wire(), "base_event_sequence", base))
    end
  end

  test "sequence is exactly zero in its selected native or wire representation" do
    for sequence <- [1, -1, 0.0, "0", false] do
      assert :error = CompactionProgress.encode_wire(%{native() | progress_sequence: sequence})
    end

    for sequence <- [0, 0.0, "00", "+0", "1", "-1", "0 "] do
      assert :error =
               CompactionProgress.decode_wire(Map.put(wire(), "progress_sequence", sequence))
    end
  end

  test "each identity refuses padding noncanonical pad bits and other encodings" do
    for episode <- ["AP8K=", "AP8K\n", "AP8+", 7],
        owner <- ["_wCA=", "_wCA\n", "/wCA", nil] do
      assert :error = CompactionProgress.decode_wire(Map.put(wire(), "episode_id", episode))

      assert :error =
               CompactionProgress.decode_wire(
                 Map.put(wire(), "owner", %{"kind" => "run", "id" => owner})
               )
    end

    one = Map.put(wire(), "episode_id", "_x")
    assert :error = CompactionProgress.decode_wire(one)

    assert :error =
             CompactionProgress.decode_wire(
               Map.put(wire(), "owner", %{"kind" => "run", "id" => "_x"})
             )

    domain = wire()["stream_domain_id"]

    assert :error =
             CompactionProgress.decode_wire(Map.put(wire(), "stream_domain_id", domain <> "="))

    prefix = binary_part(domain, 0, byte_size(domain) - 1)

    assert :error =
             CompactionProgress.decode_wire(Map.put(wire(), "stream_domain_id", prefix <> "x"))
  end

  test "other kind values and any extra spelling refuse rather than select a generic codec" do
    for kind <- ["context.compaction_progress_closed", "text_delta", :compaction, "", nil] do
      assert :error = CompactionProgress.encode_wire(%{native() | kind: kind})
      assert :error = CompactionProgress.decode_wire(Map.put(wire(), "kind", kind))
    end

    assert :error =
             CompactionProgress.encode_wire(
               Map.put(native(), "kind", "context.compaction_progress")
             )

    assert :error =
             CompactionProgress.decode_wire(Map.put(wire(), :kind, "context.compaction_progress"))
  end

  test "standalone activity schema pins the six closed fields without generation activation" do
    schema = read_contract("schema/compaction-progress.v1.json")
    assert schema["contract"] == "compaction_progress"
    assert schema["revision"] == 1
    assert schema["activation"] == "standalone_payload_not_independently_served"

    assert schema["required"] ==
             ~w(kind episode_id owner stream_domain_id progress_sequence base_event_sequence)

    assert schema["additional_members"] == "refuse"
    assert schema["kind"] == "context.compaction_progress"
    assert schema["owner"] == "checkpoint_owner/1"

    assert schema["episode_id"] == %{
             "encoding" => "canonical_unpadded_base64url_of_original_opaque_bytes",
             "original_min_bytes" => 1,
             "original_max_bytes" => 65_536
           }

    assert schema["stream_domain_id"] == %{
             "encoding" => "canonical_unpadded_base64url_of_original_opaque_bytes",
             "original_bytes" => 32,
             "original_grammar" => "[0-9a-f]{32}"
           }

    assert schema["progress_sequence"] == %{
             "encoding" => "canonical_decimal_string",
             "constant" => "0"
           }

    assert schema["base_event_sequence"] == %{
             "encoding" => "canonical_decimal_string",
             "minimum" => "0",
             "maximum" => "18446744073709551615"
           }

    assert schema["delivery"] == "single_best_effort_observation_per_positively_permitted_attempt"
    assert schema["closure"] == "none"
  end

  test "all literal activity vectors preserve exact bytes or refuse the complete hostile shape" do
    fixture = read_contract("vectors/compaction-progress.v1.json")
    assert fixture["format"] == "loopex.experimental.payload-vectors/1"
    assert fixture["contract"] == "compaction_progress"
    assert length(fixture["cases"]) == 185
    assert Enum.count(fixture["cases"], &Map.has_key?(&1, "decoded")) == 10

    for vector <- fixture["cases"] do
      if vector["error"] do
        assert CompactionProgress.decode_wire(vector["input"]) == :error, vector["name"]
      else
        assert {:ok, native} = CompactionProgress.decode_wire(vector["input"]), vector["name"]
        assert retained_activity(native) == vector["decoded"], vector["name"]
        assert CompactionProgress.encode_wire(native) == {:ok, vector["input"]}, vector["name"]
      end
    end
  end

  test "retained literal identities and full opaque byte boundaries fit complete progress frames" do
    for {relative, digest} <- [
          {"schema/compaction-progress.v1.json",
           "9180e6bb1ba51a85c0806dd5761033bb9a16b53fde964d6e58d758d2d155617e"},
          {"vectors/compaction-progress.v1.json",
           "abba85710b11506ab9696f29245a639eebe3450576738dd59cfc43e725bc72e6"}
        ] do
      assert :crypto.hash(:sha256, File.read!(contract_path(relative)))
             |> Base.encode16(case: :lower) == digest
    end

    for kind <- ["run", "compact"], size <- [1, 65_536] do
      bytes = :binary.copy(<<255>>, size)
      value = %{native(kind, @max) | episode_id: bytes, owner: %{"kind" => kind, "id" => bytes}}
      assert {:ok, encoded} = CompactionProgress.encode_wire(value)
      record = %{"type" => "progress", "session_id" => "AA", "progress" => encoded}
      assert {:ok, frame} = LoopexProtocol.Frame.encode(record)
      frame = IO.iodata_to_binary(frame)
      assert byte_size(frame) <= LoopexProtocol.Frame.output_record_bytes()
      assert :binary.last(frame) == ?\n
      payload = binary_part(frame, 0, byte_size(frame) - 1)

      assert {:ok, ^record} =
               LoopexProtocol.Frame.decode(payload, LoopexProtocol.Frame.output_record_bytes())

      assert {:ok, ^value} = CompactionProgress.decode_wire(record["progress"])

      for overflow <- [
            %{value | episode_id: :binary.copy(<<255>>, 65_537)},
            %{value | owner: %{"kind" => kind, "id" => :binary.copy(<<255>>, 65_537)}}
          ] do
        assert CompactionProgress.encode_wire(overflow) == :error
      end
    end
  end

  @tag :node_client
  test "independent Node consumes every activity literal and byte descriptor boundary" do
    node = System.find_executable("node") || flunk("Node is required for activity conformance")
    root = Path.expand("../../..", __DIR__)

    argv = [
      Path.join(root, "clients/node/compaction-progress-vectors.mjs"),
      contract_path("vectors/compaction-progress.v1.json"),
      contract_path("schema/compaction-progress.v1.json")
    ]

    {output, status} = System.cmd(node, argv, stderr_to_stdout: true)
    assert status == 0, output

    assert {:ok,
            %{"contract" => "compaction_progress", "checked" => 185, "boundary_checks" => 51}} =
             LoopexProtocol.Frame.decode(String.trim_trailing(output, "\n"), 65_536)
  end

  defp retained_activity(value) do
    %{
      "kind" => value.kind,
      "episode_id" => %{"opaque_hex" => Base.encode16(value.episode_id, case: :lower)},
      "owner" => %{
        "kind" => value.owner["kind"],
        "id" => %{"opaque_hex" => Base.encode16(value.owner["id"], case: :lower)}
      },
      "stream_domain_id" => %{"opaque_hex" => Base.encode16(value.stream_domain_id, case: :lower)},
      "progress_sequence" => Integer.to_string(value.progress_sequence),
      "base_event_sequence" => Integer.to_string(value.base_event_sequence)
    }
  end

  defp contract_path(relative), do: Path.join([:code.priv_dir(:loopex_protocol), relative])
  defp read_contract(relative), do: relative |> contract_path() |> File.read!() |> JSON.decode!()

  defp native(kind \\ "run", base \\ 0) do
    %{
      kind: "context.compaction_progress",
      episode_id: <<0, 255, 10>>,
      owner: %{"kind" => kind, "id" => <<255, 0, 128>>},
      stream_domain_id: "0123456789abcdef0123456789abcdef",
      progress_sequence: 0,
      base_event_sequence: base
    }
  end

  defp wire do
    {:ok, wire} = CompactionProgress.encode_wire(native())
    wire
  end
end
