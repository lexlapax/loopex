Code.require_file("support/m1_runtime_helper.exs", __DIR__)
Code.require_file("support/agent_loop_helper.exs", __DIR__)
Code.require_file("support/configured_genesis_helper.exs", __DIR__)

defmodule Loopex.NativeInspectionTest do
  use ExUnit.Case, async: false

  alias Loopex.AgentLoopFixture, as: Fixture
  alias Loopex.ConfiguredGenesisFixture, as: Genesis
  alias Loopex.Runtime.SessionConfiguration
  alias Loopex.Runtime.SessionState

  test "an idle inspection and zero-cursor attachment use the immutable genesis without dispatch or private instructions" do
    fixture = start(script: [], tools: [])
    configuration = Genesis.configuration("PRIVATE_INSTRUCTION_CANARY")

    {:ok, session} =
      Loopex.create_session(fixture.runtime, %{},
        command_id: "create",
        genesis: Genesis.genesis([], configuration)
      )

    before = Fixture.records(fixture, session)
    assert {:ok, status} = Loopex.session_status(fixture.runtime, session)
    assert {:ok, attachment} = Loopex.attach(fixture.runtime, session, after_event_sequence: 0)
    snapshot = Loopex.snapshot(attachment)
    assert status.configuration == SessionConfiguration.public_view(configuration)
    assert snapshot.configuration == status.configuration
    assert status.event_sequence == snapshot.event_sequence
    assert status.active_maintenance == snapshot.active_maintenance
    assert status.checkpoint == snapshot.checkpoint
    assert status.open_interaction == snapshot.open_interaction
    assert status.active_run_id == nil and status.active_bounds == nil
    assert status.checkpoint == nil and status.active_maintenance == nil
    assert status.owner_epoch > 0 and status.journal_version == length(before)
    refute :erlang.term_to_binary({status, snapshot}) =~ "PRIVATE_INSTRUCTION_CANARY"
    refute Map.has_key?(status.configuration, "provider_mapping")
    refute Map.has_key?(status.configuration, "model_capabilities")
    assert Fixture.records(fixture, session) == before
    assert Loopex.AgentLoopTestModel.dispatched(fixture.model) == []
    assert Loopex.AgentLoopTestExecutor.jobs(fixture.executor) == []
  end

  test "actual compact maintenance, checkpoint, configuration and restart inspections agree with their own committed tails" do
    selected = Genesis.configuration()

    maintenance_model = %{
      "model" => selected["model"],
      "reasoning" => "none",
      "model_capabilities" => %{
        selected["model_capabilities"]
        | "reasoning_levels" => ["none", "default"]
      },
      "provider_mapping" => %{selected["provider_mapping"] | "thinking_disabled" => true}
    }

    fixture =
      start(
        tools: [],
        maintenance_model: maintenance_model,
        maintenance_instructions: %{"version" => "summary.v1", "body" => "Keep facts"},
        script: [
          %{text: "The task ended.", calls: []},
          %{
            text:
              ~s({"summary":"PRIVATE_SUMMARY_CANARY","carry_forward":{"files_read":[],"files_changed":[]}}),
            calls: [],
            hold: self(),
            reply_overrides: %{completion: "natural"}
          }
        ]
      )

    {session, attachment, {:accepted, "prompt-1"}} =
      Fixture.run(
        fixture,
        String.duplicate("An established durable fact. ", 40)
      )

    _settled = await_event(fixture, session, "session.settled")
    assert {:ok, before} = Loopex.session_status(fixture.runtime, session)
    assert before.checkpoint == nil and before.active_maintenance == nil

    assert {:accepted, "compact"} =
             Loopex.command(attachment, %{
               type: :compact,
               command_id: "compact",
               bounds: %{max_attempts: 4, deadline_ms: 60_000, token_budget: 32_768}
             })

    assert_receive {:holding, worker}, 5_000
    monitor = Process.monitor(worker)
    assert {:ok, held} = Loopex.session_status(fixture.runtime, session)
    assert held.active_run_id == nil and held.active_bounds == nil
    assert held.compact_pending === true
    assert map_size(held.active_maintenance) == 6
    assert held.active_maintenance["owner"] == %{"kind" => "compact", "id" => "compact"}
    assert held.checkpoint == nil
    assert held.configuration == before.configuration
    assert_public_tail(fixture, session, held)

    {:ok, held_attachment} =
      Loopex.attach(fixture.runtime, session, after_event_sequence: held.event_sequence)

    held_snapshot = Loopex.snapshot(held_attachment)
    assert held_snapshot.active_maintenance == held.active_maintenance
    send(worker, :release)
    assert_receive {:DOWN, ^monitor, :process, ^worker, _}, 5_000
    completed = await_event(fixture, session, "context.compaction_finished", 8_000)
    assert completed["result"]["disposition"] == "checkpointed"
    assert {:ok, after_compact} = Loopex.session_status(fixture.runtime, session)
    assert after_compact.active_maintenance == nil
    assert after_compact.compact_pending === false
    assert after_compact.checkpoint["owner"] == %{"kind" => "compact", "id" => "compact"}
    assert is_boolean(after_compact.checkpoint["source_excerpted"])
    assert after_compact.checkpoint["configuration_version"] == 1
    assert_public_tail(fixture, session, after_compact)
    refute :erlang.term_to_binary(after_compact) =~ "PRIVATE_SUMMARY_CANARY"
    records = Fixture.records(fixture, session)
    events = Fixture.events(fixture, session)

    for transform <- [
          &Map.put(&1, "source_excerpted", not &1["source_excerpted"]),
          &put_in(&1, ["owner", "id"], "different-command"),
          &Map.put(&1, "configuration_version", 2)
        ] do
      forged =
        Enum.map(events, fn event ->
          if event.kind == "context.compacted", do: transform.(event), else: event
        end)

      assert {:error, _} = SessionState.recover(session, records, forged)
    end

    assert {:ok, retained} = SessionState.recover(session, records, events)
    current = retained.configuration
    changes = %{"max_tokens" => 512}

    assert {:ok, candidate} =
             SessionConfiguration.update(
               current,
               changes,
               current["model_capabilities"],
               current["provider_mapping"],
               retained.tool_selection["definitions"]
             )

    assert {:accepted, "configure"} =
             Loopex.command_with_configuration(
               held_attachment,
               %{type: :configure, command_id: "configure", changes: changes},
               candidate
             )

    assert {:ok, configured} = Loopex.session_status(fixture.runtime, session)
    assert configured.configuration["configuration_version"] == 2
    assert configured.configuration["max_tokens"] == 512
    assert configured.checkpoint == after_compact.checkpoint
    assert_public_tail(fixture, session, configured)

    assert {:ok, historical} =
             Loopex.attach(fixture.runtime, session, after_event_sequence: held.event_sequence)

    assert Loopex.snapshot(historical) == held_snapshot
    assert :ok = Loopex.stop(fixture.runtime)
    restarted = start(script: [], tools: [], store: fixture.store, max_tokens: 7)

    assert {:ok, ^session} =
             Loopex.resume_session(restarted.runtime, session, command_id: "resume")

    assert {:ok, restored} = Loopex.session_status(restarted.runtime, session)
    assert restored.configuration == configured.configuration
    assert restored.checkpoint == configured.checkpoint
    assert restored.active_maintenance == nil
    assert restored.open_interaction == nil
    assert restored.active_bounds == nil
    assert restored.event_sequence == configured.event_sequence
    assert restored.owner_epoch > configured.owner_epoch
    assert_public_tail(restarted, session, restored)
    assert Loopex.AgentLoopTestModel.dispatched(restarted.model) == []
  end

  defp assert_public_tail(fixture, session, status) do
    events = Fixture.events(fixture, session)
    assert List.last(events).event_sequence == status.event_sequence

    initial =
      SessionConfiguration.public_view(
        hd(Fixture.records(fixture, session)).payload["initial_configuration"]
      )

    {:ok, scan} = SessionState.start_snapshot_scan(session, status.event_sequence, initial)
    {:ok, scan} = SessionState.scan_snapshot_page(scan, events)
    {:ok, result} = SessionState.finish_snapshot_scan(scan)
    assert result.snapshot.configuration == status.configuration
    assert result.snapshot.checkpoint == status.checkpoint
    assert result.snapshot.active_maintenance == status.active_maintenance
    assert result.snapshot.open_interaction == status.open_interaction
  end

  defp start(options) do
    fixture = Fixture.start(options)
    on_exit(fn -> Fixture.stop(fixture) end)
    fixture
  end

  defp await_event(fixture, session, kind, remaining \\ 5_000) do
    case Enum.find(Fixture.events(fixture, session), &(&1.kind == kind)) do
      nil when remaining > 0 ->
        Process.sleep(20)
        await_event(fixture, session, kind, remaining - 20)

      nil ->
        flunk("no #{kind} event arrived")

      event ->
        event
    end
  end
end
