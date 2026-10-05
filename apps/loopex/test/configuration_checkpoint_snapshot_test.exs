defmodule Loopex.Runtime.ConfigurationCheckpointSnapshotTest do
  use ExUnit.Case, async: true

  alias Loopex.Runtime.SessionState
  alias LoopexProtocol.Session.{Checkpoint, Configuration}

  test "immutable configuration and successive checkpoints share every cursor across pages" do
    configuration = configuration()
    changed = %{configuration | "configuration_version" => 2, "model" => "other:model"}
    first = checkpoint()

    second = %{
      first
      | "checkpoint_id" => <<9, 255>>,
        "prior_checkpoint_id" => first["checkpoint_id"],
        "episode_id" => <<8, 255>>,
        "configuration_version" => 2,
        "source_excerpted" => true
    }

    events =
      stamp([
        change_maintenance(maintenance(first)),
        row("context.compacted", first),
        change_maintenance(nil),
        row("session.configured", %{"command_id" => "configure", "configuration" => changed}),
        change_maintenance(maintenance(second)),
        row("context.compacted", second),
        change_maintenance(nil)
      ])

    expected_checkpoints = [nil, nil, first, first, first, first, second, second]

    for width <- 1..length(events), anchor <- 0..length(events) do
      result = scan(events, anchor, width, configuration)
      assert result.configuration == if(anchor < 4, do: configuration, else: changed)
      assert result.checkpoint == Enum.at(expected_checkpoints, anchor)
      assert result.snapshot.configuration == result.configuration
      assert result.snapshot.checkpoint == result.checkpoint
      assert result.snapshot.event_sequence == anchor
      assert result.tail == length(events)
      refute Map.has_key?(result, :events)
      refute Map.has_key?(result, :checkpoints)
    end

    assert scan(events, nil, 1, configuration).configuration == changed
    assert scan(events, nil, 1, configuration).checkpoint == second
  end

  test "revision three requires a current seed and rejects inconsistent final views" do
    assert {:error, :invalid_public_configuration} =
             SessionState.start_snapshot_scan("session", 0, nil)

    {:ok, scan} = SessionState.start_snapshot_scan("session", 0, configuration())
    assert {:ok, %{snapshot: snapshot}} = SessionState.finish_snapshot_scan(scan)
    assert snapshot.snapshot_revision == 3
    assert {:ok, wire} = LoopexProtocol.Session.Snapshot.encode_wire(snapshot)
    assert {:ok, ^snapshot} = LoopexProtocol.Session.Snapshot.decode_wire(wire)

    for field <- [
          :configuration,
          :checkpoint,
          :active_maintenance,
          :open_interaction,
          :last_compact
        ] do
      assert Map.has_key?(snapshot, field)
    end

    admitted = maintenance(checkpoint()) |> Map.put("configuration_version", 2)
    {:ok, scan} = SessionState.start_snapshot_scan("session", nil, configuration())

    assert {:ok, scan} =
             SessionState.scan_snapshot_page(scan, stamp([change_maintenance(admitted)]))

    assert {:error, :invalid_public_snapshot} = SessionState.finish_snapshot_scan(scan)
  end

  test "configuration refuses private seeds, malformed changes, version gaps and active owners" do
    initial = configuration()
    {:ok, scan} = SessionState.start_snapshot_scan("session", nil, initial)
    next = %{initial | "configuration_version" => 2}
    change = row("session.configured", %{"command_id" => "change", "configuration" => next})

    for poisoned <- [
          Map.put(initial, "instructions_text", "PRIVATE_CONFIGURATION_CANARY"),
          Map.put(initial, "provider_mapping", %{"route" => "PRIVATE_CONFIGURATION_CANARY"}),
          Map.put(initial, "model_capabilities", %{}),
          %{initial | "configuration_version" => 0}
        ] do
      assert {:error, :invalid_public_configuration} =
               SessionState.start_snapshot_scan("session", 0, poisoned)
    end

    assert {:error, :invalid_public_configuration} =
             SessionState.scan_snapshot_page(scan, stamp([Map.put(change, "private", "canary")]))

    for altered <- [1, 3] do
      bad = put_in(change, ["configuration", "configuration_version"], altered)

      assert {:error, :invalid_public_configuration_transition} =
               SessionState.scan_snapshot_page(scan, stamp([bad]))
    end

    for events <- [
          [row("user.message_appended", %{"run_id" => "run"}), change],
          [change_maintenance(maintenance(checkpoint())), change],
          [change, change]
        ] do
      assert {:error, :invalid_public_configuration_transition} =
               SessionState.scan_snapshot_page(scan, stamp(events))
    end
  end

  test "checkpoint shape, episode, owner, capture, prior chain and inherited omission are checked" do
    first = checkpoint()
    first = %{first | "source_excerpted" => true}
    active = maintenance(first)
    admission = change_maintenance(active)
    {:ok, initial} = SessionState.start_snapshot_scan("session", nil, configuration())

    assert {:error, :invalid_public_checkpoint} =
             SessionState.scan_snapshot_page(
               initial,
               stamp([
                 admission,
                 row("context.compacted", Map.put(first, "summary", "PRIVATE_SUMMARY_CANARY"))
               ])
             )

    for altered <- [
          Map.put(first, "episode_id", "other"),
          put_in(first, ["owner", "id"], "other"),
          Map.put(first, "model", "other"),
          Map.put(first, "configuration_version", 2),
          Map.put(first, "prior_checkpoint_id", "missing")
        ] do
      assert {:error, :invalid_public_checkpoint_transition} =
               SessionState.scan_snapshot_page(
                 initial,
                 stamp([admission, row("context.compacted", altered)])
               )
    end

    assert {:error, :invalid_public_checkpoint_transition} =
             SessionState.scan_snapshot_page(initial, stamp([row("context.compacted", first)]))

    second = %{
      first
      | "checkpoint_id" => "second",
        "prior_checkpoint_id" => first["checkpoint_id"],
        "source_excerpted" => false
    }

    assert {:error, :invalid_public_checkpoint_transition} =
             SessionState.scan_snapshot_page(
               initial,
               stamp([
                 admission,
                 row("context.compacted", first),
                 row("context.compacted", second)
               ])
             )
  end

  test "exact configuration versions survive a historical anchor without retaining raw content" do
    initial = %{configuration() | "configuration_version" => Integer.pow(10, 100)}
    next = %{initial | "configuration_version" => initial["configuration_version"] + 1}
    event = row("session.configured", %{"command_id" => <<0, 255>>, "configuration" => next})
    assert scan(stamp([event]), 0, 1, initial).configuration == initial
    assert scan(stamp([event]), 1, 1, initial).configuration == next
  end

  defp scan(events, anchor, width, configuration) do
    {:ok, initial} = SessionState.start_snapshot_scan("session", anchor, configuration)

    scan =
      Enum.reduce(Enum.chunk_every(events, width), initial, fn page, scan ->
        assert {:ok, next} = SessionState.scan_snapshot_page(scan, page)
        next
      end)

    assert {:ok, result} = SessionState.finish_snapshot_scan(scan)
    result
  end

  defp configuration do
    {:ok, native} =
      Configuration.decode_wire(vector("configuration-projection.v1.json", "initial"))

    native
  end

  defp checkpoint do
    {:ok, native} =
      Checkpoint.decode_wire(vector("checkpoint-projection.v1.json", "run-covered-prefix"))

    put_in(native, ["owner", "kind"], "compact")
  end

  defp vector(file, name) do
    path = Path.join(:code.priv_dir(:loopex_protocol), "vectors/" <> file)
    Enum.find(JSON.decode!(File.read!(path))["cases"], &(&1["name"] == name))["input"]
  end

  defp maintenance(checkpoint) do
    checkpoint
    |> Map.take(~w(episode_id owner model reasoning configuration_version))
    |> Map.put("bounds", %{"max_attempts" => 4, "deadline_ms" => 60_000, "token_budget" => 32_768})
  end

  defp change_maintenance(value),
    do: row("context.maintenance_changed", %{"active_maintenance" => value})

  defp row(kind, data), do: Map.put(data, :kind, kind)

  defp stamp(events) do
    events
    |> Enum.with_index(1)
    |> Enum.map(fn {event, index} ->
      event |> Map.put(:event_id, "event-#{index}") |> Map.put(:event_sequence, index)
    end)
  end
end
