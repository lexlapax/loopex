defmodule LoopexDaemon.WireRecordsTest do
  use ExUnit.Case, async: true

  alias LoopexDaemon.WireRecords
  alias LoopexProtocol.Frame

  # Concept: what the daemon writes when it stops is byte for byte the
  # generation's literal vector for that reason.
  test "every daemon.stopping vector is exactly the record the daemon writes" do
    vectors =
      :loopex_protocol
      |> Application.app_dir("priv/vectors/loopex-experimental-2.json")
      |> File.read!()
      |> JSON.decode!()
      |> Map.fetch!("cases")
      |> Enum.filter(&String.starts_with?(&1["id"], "daemon_stopping_"))

    assert length(vectors) == 14

    for %{"raw_hex" => hex} <- vectors do
      bytes = Base.decode16!(hex, case: :lower)
      %{"reason" => reason} = JSON.decode!(bytes)
      assert encode(WireRecords.daemon_stopping(reason)) == bytes
    end
  end

  test "control records match the generation-two vectors exactly" do
    epoch = "epoch"

    assert encode(WireRecords.control_acquired("acquire-1", epoch, 30_000, false)) ==
             ~s({"method":"session.acquire_control","request_id":"acquire-1","result":{"expires_in_ms":"30000","writer_epoch":"ZXBvY2g"},"type":"result"}\n)

    assert encode(WireRecords.control_acquired("acquire-2", epoch, 30_000, true)) ==
             ~s({"method":"session.acquire_control","request_id":"acquire-2","result":{"expires_in_ms":"30000","renewed":true,"writer_epoch":"ZXBvY2g"},"type":"result"}\n)

    assert encode(WireRecords.control_released("release-1")) ==
             ~s({"method":"session.release_control","request_id":"release-1","result":{"released":true},"type":"result"}\n)

    assert encode(WireRecords.control_error("error-1", "control_held")) ==
             ~s({"code":"control_held","message":"control held.","request_id":"error-1","type":"error"}\n)

    assert encode(WireRecords.control_error("error-1", "control_not_held")) ==
             ~s({"code":"control_not_held","message":"control is not held by this connection","request_id":"error-1","type":"error"}\n)

    assert encode(WireRecords.control_error("error-1", "control_pending")) ==
             ~s({"code":"control_pending","message":"control pending.","request_id":"error-1","type":"error"}\n)
  end

  defp encode(record) do
    assert {:ok, encoded} = Frame.encode(record)
    IO.iodata_to_binary(encoded)
  end

  test "maintenance events share the closed codec with exact quantities and opaque identities" do
    path = Path.join(:code.priv_dir(:loopex_protocol), "vectors/maintenance-view.v1.json")
    cases = JSON.decode!(File.read!(path))["cases"]

    for name <- [
          "inactive",
          "run-captured-null-deadline",
          "compact-captured-ceilings",
          "run-unbounded-bounds.token_budget"
        ] do
      wire = Enum.find(cases, &(&1["name"] == name))["input"]
      assert {:ok, native} = LoopexProtocol.Session.MaintenanceView.decode_wire(wire)

      event =
        Map.merge(native, %{
          kind: "context.maintenance_changed",
          event_id: "view",
          event_sequence: 1
        })

      record = WireRecords.event("session", event)
      assert record["event"]["data"] == wire
      assert record["event"]["kind"] == "context.maintenance_changed"

      assert {:ok, ^native} =
               LoopexProtocol.Session.MaintenanceView.decode_wire(record["event"]["data"])
    end
  end

  test "both checkpoint owner kinds preserve opaque bytes in the daemon envelope" do
    for kind <- ["run", "compact"] do
      event = %{
        :kind => "context.compacted",
        :event_id => "event",
        :event_sequence => 1,
        "owner" => %{"kind" => kind, "id" => <<0, 255, 10>>}
      }

      record = WireRecords.event("session", event)
      assert record["event"]["data"] == %{"owner" => %{"kind" => kind, "id" => "AP8K"}}
      assert record["event"]["event_sequence"] == "1"
      assert {:ok, _} = Frame.encode(record)
    end
  end

  test "completed compaction events preserve each closed result and refuse private data" do
    path =
      Path.join(:code.priv_dir(:loopex_protocol), "vectors/standalone-compact-completion.v1.json")

    cases = JSON.decode!(File.read!(path))["cases"]

    for vector <- cases, is_nil(vector["error"]) do
      wire = vector["input"]
      assert {:ok, native} = LoopexProtocol.Session.CompactResult.decode_completion(wire)

      event =
        Map.merge(native, %{
          kind: "context.compaction_finished",
          event_id: "finished",
          event_sequence: 1
        })

      record = WireRecords.event("session", event)
      assert record["event"]["data"] == wire
      assert {:ok, _} = Frame.encode(record)

      assert_raise MatchError, fn ->
        WireRecords.event("session", Map.put(event, "source", "PRIVATE_COMPLETION_CANARY"))
      end
    end
  end

  test "compaction activity matches the closed foreground envelope for both owners and u64 edges" do
    for kind <- ["run", "compact"], base <- [0, 18_446_744_073_709_551_615] do
      item = compaction_item(kind, base)
      record = WireRecords.progress(<<255, 0>>, item)

      assert record == %{
               "type" => "progress",
               "session_id" => "_wA",
               "progress" => %{
                 "kind" => "context.compaction_progress",
                 "episode_id" => "AP8K",
                 "owner" => %{"kind" => kind, "id" => "_wCA"},
                 "stream_domain_id" => "MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY",
                 "progress_sequence" => "0",
                 "base_event_sequence" => Integer.to_string(base)
               }
             }

      assert {:ok, ^item} =
               LoopexProtocol.Session.CompactionProgress.decode_wire(record["progress"])

      assert {:ok, encoded} = Frame.encode(record)

      assert {:ok, ^record} =
               Frame.decode(
                 IO.iodata_to_binary(encoded) |> String.trim_trailing("\n"),
                 Frame.output_record_bytes()
               )
    end
  end

  test "malformed and oversized compaction items refuse whole without serializing private values" do
    item = compaction_item("run", 0)

    for invalid <- [
          Map.put(item, :summary, "PRIVATE_CANARY"),
          Map.put(item, :permit, fn -> :private end),
          Map.delete(item, :episode_id),
          Map.put(item, :owner, %{"kind" => "run", "id" => nil}),
          Map.put(item, :stream_domain_id, String.duplicate("A", 32)),
          Map.put(item, :episode_id, :binary.copy(<<255>>, 65_537)),
          Map.put(item, :base_event_sequence, 18_446_744_073_709_551_616),
          Map.put(item, :__struct__, __MODULE__),
          %{"kind" => "context.compaction_progress", "summary" => fn -> :private end}
        ] do
      assert :error = WireRecords.progress("session", invalid)
    end
  end

  test "maximum valid compaction identities fit the existing individual frame ceiling" do
    bytes = :binary.copy(<<255>>, 65_536)

    item = %{
      compaction_item("compact", 0)
      | episode_id: bytes,
        owner: %{"kind" => "compact", "id" => bytes}
    }

    record = WireRecords.progress("session", item)
    assert {:ok, encoded} = Frame.encode(record)
    assert IO.iodata_length(encoded) < Frame.output_record_bytes()

    assert {:ok, ^item} =
             LoopexProtocol.Session.CompactionProgress.decode_wire(record["progress"])
  end

  defp compaction_item(kind, base) do
    %{
      kind: "context.compaction_progress",
      episode_id: <<0, 255, 10>>,
      owner: %{"kind" => kind, "id" => <<255, 0, 128>>},
      stream_domain_id: "0123456789abcdef0123456789abcdef",
      progress_sequence: 0,
      base_event_sequence: base
    }
  end
end
