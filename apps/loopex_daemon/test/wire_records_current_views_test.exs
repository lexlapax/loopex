defmodule LoopexDaemon.WireRecordsCurrentViewsTest do
  use ExUnit.Case, async: true

  alias LoopexDaemon.WireRecords
  alias LoopexProtocol.Frame
  alias LoopexProtocol.Session.{CompactResult, Inspection, Snapshot}

  test "inspection projects complete captured idle, active, maintenance and question sources" do
    for vector <- accepted_vectors("inspection.v1.json") do
      assert {:ok, captured} = Inspection.decode_wire(vector["input"]), vector["name"]
      source = owner_observation(captured)
      projected = WireRecords.session_status(source)

      assert projected == vector["input"], vector["name"]
      assert map_size(projected) == 11
      assert {:ok, ^captured} = Inspection.decode_wire(projected)
      refute Map.has_key?(projected, "compact_pending")
      refute Map.has_key?(projected, "owner_epoch")
      refute Map.has_key?(projected, "journal_version")

      encoded = framed(WireRecords.result("inspect", "session.inspect", projected))
      refute encoded =~ "PRIVATE_OWNER_CANARY"
    end
  end

  test "native compact admission stays private for both pending states" do
    {:ok, captured} = Inspection.decode_wire(vector("inspection.v1.json", "idle-current-configuration"))

    for pending <- [false, true] do
      source = Map.put(owner_observation(captured), :compact_pending, pending)
      projected = WireRecords.session_status(source)
      assert {:ok, ^captured} = Inspection.decode_wire(projected)
      refute Map.has_key?(projected, "compact_pending")
    end
  end

  test "inspection retains exact huge bounds, queued identity order and captured cutoff" do
    wire = vector("inspection.v1.json", "active-policy-answer-exact-bounds")
    {:ok, captured} = Inspection.decode_wire(wire)
    assert WireRecords.session_status(owner_observation(captured)) == wire

    assert wire["active_bounds"]["max_turns"] == "184467440737095516160000000001"
    assert wire["active_bounds"]["deadline"] == "18446744073709551615"

    queued = vector("inspection.v1.json", "pending-work-order-preserved")
    {:ok, captured} = Inspection.decode_wire(queued)
    assert WireRecords.session_status(owner_observation(captured)) == queued
    assert length(queued["pending_work_ids"]) > 1
  end

  test "snapshot envelopes project all ten cursor views and repeat their own interaction" do
    for vector <- accepted_vectors("session-snapshot.v3.json") do
      assert {:ok, captured} = Snapshot.decode_wire(vector["input"]), vector["name"]
      record = WireRecords.snapshot("attach", captured)
      expected = vector["input"]

      assert record == %{
               "type" => "snapshot",
               "request_id" => "attach",
               "session_id" => expected["session_id"],
               "event_cursor" => expected["event_sequence"],
               "snapshot" => expected,
               "open_interaction" => expected["open_interaction"]
             }, vector["name"]

      assert map_size(record["snapshot"]) == 10
      assert {:ok, ^captured} = Snapshot.decode_wire(record["snapshot"])
      assert {:ok, ^record} = unframe(framed(record))
    end
  end

  test "snapshot completion preserves every accepted outcome and cleanup uncertainty" do
    {:ok, settled} = Snapshot.decode_wire(vector("session-snapshot.v3.json", "settled-checkpoint-and-completion"))

    for vector <- accepted_vectors("standalone-compact-completion.v1.json") do
      assert {:ok, completion} = CompactResult.decode_completion(vector["input"])
      captured = %{settled | last_compact: completion}
      record = WireRecords.snapshot("attach", captured)
      assert record["snapshot"]["last_compact"] == vector["input"], vector["name"]
      assert {:ok, ^captured} = Snapshot.decode_wire(record["snapshot"])
    end
  end

  test "inspection and attachment views preserve the same captured cursor and public data" do
    {:ok, idle} = Inspection.decode_wire(vector("inspection.v1.json", "idle-current-configuration"))
    {:ok, active} = Inspection.decode_wire(vector("inspection.v1.json", "active-before-deadline"))

    for name <- [
          "creation",
          "settled-checkpoint-and-completion",
          "pending-model-choice",
          "pending-model-text",
          "pending-policy-choice",
          "policy-answer-resolution-owed",
          "run-captured-null-deadline",
          "compact-captured-ceilings"
        ] do
      {:ok, captured} = Snapshot.decode_wire(vector("session-snapshot.v3.json", name))

      inspection = %{
        idle
        | event_sequence: captured.event_sequence,
          active_run_id: captured.active_run_id,
          active_bounds: if(is_nil(captured.active_run_id), do: nil, else: active.active_bounds),
          configuration: captured.configuration,
          checkpoint: captured.checkpoint,
          active_maintenance: captured.active_maintenance,
          open_interaction: captured.open_interaction
      }

      status = WireRecords.session_status(owner_observation(inspection))
      record = WireRecords.snapshot("attach", captured)
      assert record["event_cursor"] == status["event_sequence"], name
      assert record["open_interaction"] == status["open_interaction"], name

      for field <- ~w(active_run_id configuration checkpoint active_maintenance open_interaction) do
        assert record["snapshot"][field] == status[field], "#{name}: #{field}"
      end
    end
  end

  test "inspection refuses incomplete captures and malformed public members without defaults" do
    {:ok, captured} = Inspection.decode_wire(vector("inspection.v1.json", "active-policy-answer-exact-bounds"))

    for field <- [:event_sequence, :configuration, :active_bounds, :checkpoint, :active_maintenance] do
      assert_raise MatchError, fn ->
        WireRecords.session_status(Map.delete(owner_observation(captured), field))
      end
    end

    for invalid <- [
          %{captured | status: "active"},
          %{captured | configuration: nil},
          %{captured | event_sequence: 18_446_744_073_709_551_616},
          %{captured | active_bounds: nil},
          %{captured | active_bounds: Map.put(captured.active_bounds, :source, "PRIVATE_BOUND_CANARY")},
          %{captured | configuration: Map.put(captured.configuration, "credential_ref", "PRIVATE_CONFIG_CANARY")},
          %{captured | open_interaction: Map.put(captured.open_interaction, "permit", self())},
          %{captured | checkpoint: %{"summary" => "PRIVATE_CHECKPOINT_CANARY"}},
          %{captured | active_maintenance: %{"source" => "PRIVATE_MAINTENANCE_CANARY"}}
        ] do
      assert_raise MatchError, fn -> WireRecords.session_status(owner_observation(invalid)) end
    end
  end

  test "snapshots refuse private canaries, missing views and inconsistent question ownership" do
    {:ok, captured} = Snapshot.decode_wire(vector("session-snapshot.v3.json", "pending-model-choice"))
    {:ok, settled} = Snapshot.decode_wire(vector("session-snapshot.v3.json", "settled-checkpoint-and-completion"))
    {:ok, maintenance} = Snapshot.decode_wire(vector("session-snapshot.v3.json", "run-captured-null-deadline"))

    for invalid <- [
          Map.put(captured, :compact_pending, true),
          Map.put(captured, :private_recovery, "PRIVATE_SNAPSHOT_CANARY"),
          Map.delete(captured, :event_sequence),
          Map.delete(captured, :configuration),
          Map.delete(captured, :last_compact),
          %{captured | snapshot_revision: 2},
          %{captured | active_run_id: "another-run"},
          %{captured | event_sequence: 0},
          %{captured | configuration: Map.put(captured.configuration, "instructions_text", "PRIVATE_CONFIG_CANARY")},
          %{captured | open_interaction: Map.put(captured.open_interaction, "host_reference", self())},
          %{settled | checkpoint: Map.put(settled.checkpoint, "summary", "PRIVATE_CHECKPOINT_CANARY")},
          %{settled | last_compact: Map.put(settled.last_compact, "source", "PRIVATE_COMPLETION_CANARY")},
          %{maintenance | active_maintenance: Map.put(maintenance.active_maintenance, "source", "PRIVATE_MAINTENANCE_CANARY")}
        ] do
      assert_raise MatchError, fn -> WireRecords.snapshot("attach", invalid) end
    end
  end

  defp owner_observation(captured) do
    Map.merge(captured, %{
      owner_epoch: 47,
      journal_version: 63,
      compact_pending: true,
      private_recovery: %{credential_ref: "PRIVATE_OWNER_CANARY", process: self()}
    })
  end

  defp accepted_vectors(file), do: Enum.reject(vectors(file), & &1["error"])

  defp vector(file, name), do: Enum.find(vectors(file), &(&1["name"] == name))["input"]

  defp vectors(file) do
    :loopex_protocol
    |> Application.app_dir("priv/vectors/" <> file)
    |> File.read!()
    |> JSON.decode!()
    |> Map.fetch!("cases")
  end

  defp framed(record) do
    assert {:ok, encoded} = Frame.encode(record)
    IO.iodata_to_binary(encoded)
  end

  defp unframe(encoded),
    do: Frame.decode(String.trim_trailing(encoded, "\n"), Frame.output_record_bytes())
end
