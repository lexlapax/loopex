Code.require_file("support/configured_genesis_helper.exs", __DIR__)

defmodule Loopex.Runtime.StandaloneCompactProjectionTest do
  use ExUnit.Case, async: true

  alias Loopex.ConfiguredGenesisFixture, as: Genesis
  alias Loopex.Runtime.{ContextAdmission, MaintenanceConfiguration, SessionState}
  alias Loopex.Store
  alias LoopexProtocol.Session.ContextFailure
  alias LoopexProtocol.ToolDefinition

  @uint64_max 18_446_744_073_709_551_615

  test "standalone admission freezes command bounds and an absolute cutoff without a run" do
    for bounds <- [
          %{max_attempts: 4, deadline_ms: 60_000, token_budget: 32_768},
          %{max_attempts: 1, deadline_ms: 1, token_budget: 1}
        ] do
      {state, history, events} = pending(["old fact"], bounds: bounds)

      assert {:ok, proposal} =
               SessionState.propose_standalone_maintenance_episode(
                 state,
                 maintenance_model(),
                 maintenance_instructions(),
                 1_000,
                 fn -> :ok end
               )

      [record] = proposal.records
      assert proposal.events == []
      assert record.kind == "standalone_maintenance_episode_admitted_v1"
      assert record["command_id"] == state.pending_compact["command_id"]
      assert record["episode_id"] == state.pending_compact["episode_id"]
      assert record["origin"] == "explicit"
      assert record["trigger"] == "explicit"
      assert record["targets"] == nil
      assert record["last_offending_source"] == nil
      assert record["bounds"] == state.pending_compact["bounds"]
      assert record["deadline"] == 1_000 + bounds.deadline_ms
      assert record["admitted_at"] == 1_000
      assert record["attempts"] == 0
      assert record["summary_ordinal"] == 1
      assert record["checkpoint_id"] == nil

      assert record["usage"] == %{
               "attempts" => 0,
               "reported_tokens" => 0,
               "estimated_tokens" => 0,
               "total_tokens" => 0
             }

      assert record["maintenance_configuration"]["selection"] == maintenance_model()
      assert record["maintenance_configuration"]["instructions"] == maintenance_instructions()
      assert {:ok, _} = Store.admit_bounded(record)
      refute Map.has_key?(record, "run_id")
      refute Map.has_key?(record, "staging_turn_id")
      refute Map.has_key?(record, "preparation_deadline")
      assert proposal.next.active_run_id == nil
      assert proposal.next.pending_work == %{}
      assert proposal.next.deadlines == %{}
      assert proposal.next.conversation == state.conversation
      assert proposal.next.charged == state.charged

      {committed, history, events} = commit(state, proposal, history, events)
      assert {:ok, ^committed} = SessionState.recover(state.session_id, history, events)
      episode = committed.maintenance_episodes[committed.active_maintenance]
      assert episode["session_version"] == committed.journal_version
      assert episode["stage"] == "source_preparation"
    end
  end

  test "standalone succession reuses capture before consulting new settings, clock or work" do
    {state, history, events} = pending(["old fact"])

    {:ok, proposal} =
      SessionState.propose_standalone_maintenance_episode(
        state,
        maintenance_model(),
        maintenance_instructions(),
        1_000,
        fn -> :ok end
      )

    {state, history, events} = commit(state, proposal, history, events)
    captured = state.maintenance_episodes[state.active_maintenance]

    succession = %{
      journal_version: state.journal_version + 1,
      owner_epoch: state.owner_epoch + 1,
      owner_incarnation_id: "successor",
      payload: %{
        :kind => "owner_advanced",
        "prior_owner_epoch" => state.owner_epoch,
        "owner_epoch" => state.owner_epoch + 1,
        "owner_incarnation_id" => "successor",
        "owner_transaction_id" => "successor-tx"
      }
    }

    assert {:ok, recovered} =
             SessionState.recover(state.session_id, history ++ [succession], events)

    assert recovered.owner_epoch == state.owner_epoch + 1

    assert {:retained, ^captured} =
             SessionState.propose_standalone_maintenance_episode(
               recovered,
               nil,
               nil,
               @uint64_max,
               fn -> flunk("retained episode remeasured") end
             )

    {:ok, abort} = SessionState.propose(recovered, %{type: :abort, command_id: "stop"})
    {cancelled, _, _} = commit(recovered, abort, history ++ [succession], events)

    assert {:retained, ^captured} =
             SessionState.propose_standalone_maintenance_episode(
               cancelled,
               %{},
               %{},
               nil,
               fn -> flunk("cancelled capture replaced") end
             )

    assert captured["deadline"] == 61_000
    assert captured["session_version"] == state.journal_version
  end

  test "standalone capture rejects rehashed substitutions and every forged fixed member" do
    {state, history, events} = pending(["old fact"])

    {:ok, proposal} =
      SessionState.propose_standalone_maintenance_episode(
        state,
        maintenance_model(),
        maintenance_instructions(),
        1_000,
        fn -> :ok end
      )

    record = hd(proposal.records)
    changed_capture = Map.put(record["maintenance_configuration"], "context_token_budget", 1_024)

    changed_capture =
      Map.put(
        changed_capture,
        "digest",
        LoopexProtocol.Canonical.digest(Map.delete(changed_capture, "digest"))
      )

    mutations = [
      &Map.put(&1, "extra", true),
      &Map.put(&1, "run_id", "invented"),
      &Map.put(&1, "preparation_deadline", 61_000),
      &Map.put(&1, "command_id", "other"),
      &Map.put(&1, "episode_id", "other"),
      &Map.put(&1, "configuration_version", 2),
      &Map.put(&1, "trigger", "ordinary_limit"),
      &Map.put(&1, "targets", %{}),
      &Map.put(&1, "origin", "automatic"),
      &Map.put(&1, "last_offending_source", %{}),
      &Map.put(&1, "deadline", 61_001),
      &Map.put(&1, "admitted_at", @uint64_max),
      &put_in(&1, ["bounds", "max_attempts"], 3),
      &Map.put(&1, "attempts", 1),
      &Map.put(&1, "summary_ordinal", 2),
      &Map.put(&1, "checkpoint_id", "invented"),
      &put_in(&1, ["usage", "total_tokens"], 1),
      &Map.put(&1, "maintenance_configuration", changed_capture)
    ]

    for changed <-
          Enum.map(mutations, & &1.(record)) ++
            Enum.map(Map.keys(record), &Map.delete(record, &1)) do
      assert {:error, _} =
               SessionState.recover(state.session_id, history ++ [row(state, changed)], events)
    end

    {admitted, admitted_history, events} = commit(state, proposal, history, events)

    assert {:error, :invalid_maintenance_episode_transition} =
             SessionState.recover(
               state.session_id,
               admitted_history ++ [row(admitted, record)],
               events
             )
  end

  test "empty history needs no summarizer and invalid clock admits no episode" do
    {empty, _, _} = pending([])

    assert {:unchanged, %{eligible_unit_count: 0}} =
             SessionState.propose_standalone_maintenance_episode(empty, nil, nil, 0, fn -> :ok end)

    assert empty.maintenance_episodes == %{}
    {state, _, _} = pending(["old fact"])

    for now <- [0, @uint64_max - 60_000] do
      assert {:ok, proposal} =
               SessionState.propose_standalone_maintenance_episode(
                 state,
                 maintenance_model(),
                 maintenance_instructions(),
                 now,
                 fn -> :ok end
               )

      assert hd(proposal.records)["deadline"] == now + 60_000
    end

    for now <- [nil, -1, @uint64_max - 59_999, @uint64_max + 1] do
      assert {:error, :maintenance_deadline_unrepresentable} =
               SessionState.propose_standalone_maintenance_episode(
                 state,
                 nil,
                 nil,
                 now,
                 fn -> flunk("invalid clock entered source work") end
               )
    end

    assert state.maintenance_episodes == %{}
  end

  test "standalone capture keeps configuration refusal order and cancellation before commitment" do
    {state, _, _} = pending(["old fact"])

    assert {:error, :maintenance_model_unconfigured} =
             SessionState.propose_standalone_maintenance_episode(state, nil, nil, 1_000, fn ->
               :ok
             end)

    assert {:error, :maintenance_instructions_unconfigured} =
             SessionState.propose_standalone_maintenance_episode(
               state,
               maintenance_model(),
               nil,
               1_000,
               fn -> :ok end
             )

    unsupported = put_in(maintenance_model(), ["provider_mapping", "thinking_disabled"], false)

    assert {:error, :maintenance_reasoning_unsupported} =
             SessionState.propose_standalone_maintenance_episode(
               state,
               unsupported,
               nil,
               1_000,
               fn -> :ok end
             )

    for stop_at <- 1..10 do
      counter = :counters.new(1, [])

      check = fn ->
        :counters.add(counter, 1, 1)
        if :counters.get(counter, 1) == stop_at, do: {:error, :cancelled}, else: :ok
      end

      assert {:error, :cancelled} =
               SessionState.propose_standalone_maintenance_episode(
                 state,
                 maintenance_model(),
                 maintenance_instructions(),
                 1_000,
                 check
               )

      assert :counters.get(counter, 1) == stop_at
    end

    assert state.maintenance_episodes == %{}
  end

  test "explicit selection releases every terminal unit even when the whole history fits" do
    for texts <- [[], ["first raw input", "second raw input"]] do
      {state, history, events} = pending(texts)

      assert {:ok, plan} =
               SessionState.preflight_standalone_compaction(state, 61_000, fn -> :ok end)

      assert plan.origin == "explicit"
      assert plan.trigger == "explicit"
      assert plan.targets == nil
      assert plan.last_offending_source == nil
      assert plan.before.failure == nil
      assert plan.before.rendering == :ok
      assert plan.eligible_unit_count == length(texts)
      assert plan.retained_tail == []
      assert plan.tail_tokens == 0
      assert state.maintenance_episodes == %{}
      assert state.deadlines == %{}
      assert {:ok, ^state} = SessionState.recover(state.session_id, history, events)
    end
  end

  test "hard overflow selects ordinary-limit repair under explicit origin" do
    {state, _, _} =
      pending([String.duplicate("x", 34_000)],
        context_token_budget: 1_000,
        system_class_tokens: 512
      )

    assert {:ok, plan} =
             SessionState.preflight_standalone_compaction(state, 61_000, fn -> :ok end)

    assert plan.trigger == "ordinary_limit"
    assert plan.origin == "explicit"
    assert plan.targets == nil
    assert plan.last_offending_source == nil
    assert plan.before.failure["dimension"] == "context_tokens"
    assert plan.eligible_unit_count == 1
    assert plan.retained_tail == []
    assert plan.tail_tokens == 0

    assert {:ok, capture} =
             SessionState.propose_standalone_maintenance_episode(
               state,
               maintenance_model(),
               maintenance_instructions(),
               1_000,
               fn -> :ok end
             )

    assert hd(capture.records)["trigger"] == "ordinary_limit"
    assert hd(capture.records)["origin"] == "explicit"
    assert hd(capture.records)["maintenance_configuration"]["context_token_budget"] == 1_000
  end

  test "cancellation during minimum-tail measurement prevents a selection result" do
    {state, _, _} = pending(["raw input"])
    counter = :counters.new(1, [])

    check = fn ->
      :counters.add(counter, 1, 1)
      if :counters.get(counter, 1) == 5, do: {:error, :cancelled}, else: :ok
    end

    assert {:error, :cancelled} =
             SessionState.preflight_standalone_compaction(state, 61_000, check)

    assert :counters.get(counter, 1) == 5
    assert state.maintenance_episodes == %{}
    assert state.active_maintenance == nil
    assert state.deadlines == %{}
  end

  test "empty history measures the complete command-bound view with an exact self-size" do
    {state, history, events} = pending([])
    assert {:ok, probe} = SessionState.preflight_standalone_context(state, 61_000, fn -> :ok end)
    assert probe.failure == nil
    assert probe.rendering == :ok
    assert probe.request.continuation == nil
    assert length(probe.request.messages) == 1
    assert probe.record["command_id"] == state.pending_compact["command_id"]
    assert probe.record["episode_id"] == state.pending_compact["episode_id"]
    assert probe.record["configuration_version"] == state.configuration["configuration_version"]

    assert MapSet.new(Map.keys(probe.record)) ==
             MapSet.new([
               :kind,
               "command_id",
               "episode_id",
               "configuration_version",
               "request",
               "context_receipt",
               "lineage_projection"
             ])

    assert probe.record.kind == "compact_context_probe_v1"
    assert probe.record["request"]["deadline"] == 61_000
    assert probe.receipt == probe.record["context_receipt"]
    exact_bytes = byte_size(:erlang.term_to_binary(probe.record, [:deterministic]))
    assert probe.receipt["record_byte_cost"] == exact_bytes

    assert {:ok, normalized, ^exact_bytes} =
             Store.normalize_and_measure_item(:record, probe.record)

    assert normalized == probe.record
    assert {:ok, ^state} = SessionState.recover(state.session_id, history, events)

    # Concept: a sizing view grants no authority or durable completion.
    # Technical depth: it is deliberately outside the journal grammar. The
    # owner still needs episode capture, source/dispatch and completion records.
    assert {:error, _} =
             SessionState.recover(state.session_id, history ++ [row(state, probe.record)], events)

    assert state.run_order == []
    assert state.maintenance_episodes == %{}
    assert state.active_run_id == nil
    assert state.deadlines == %{}
  end

  test "whole terminal history and a local minimum tail use the same fixed configuration" do
    {state, _, _} = pending(["first raw input", "second raw input"])
    raw = SessionState.lineage_elements(state, :session)
    assert {:ok, whole} = SessionState.preflight_standalone_context(state, 61_000, fn -> :ok end)

    assert Enum.map(tl(whole.request.messages), & &1["content"]) ==
             ["first raw input", "second raw input"]

    assert {:ok, tail} =
             SessionState.preflight_standalone_context(state, 61_000, fn -> :ok end, %{
               elements: []
             })

    assert tail.request.messages == [hd(whole.request.messages)]
    assert tail.request.model == whole.request.model
    assert tail.request.sampling == whole.request.sampling
    assert tail.request.deadline == whole.request.deadline
    assert tail.receipt["provider_estimated_tokens"] < whole.receipt["provider_estimated_tokens"]
    assert tail.receipt["record_byte_cost"] < whole.receipt["record_byte_cost"]
    assert SessionState.lineage_elements(state, :session) == raw
    assert state.active_maintenance == nil
    assert state.charged |> Map.values() |> Enum.all?(&(&1.tokens == 0))
  end

  test "standalone uses hard input limits even when a new thinking request would need headroom" do
    configuration =
      configuration(context_token_budget: 1_000, system_class_tokens: 512)
      |> put_in(["model_capabilities", "reasoning_levels"], ["default"])
      |> put_in(["provider_mapping", "mapping_revision"], "fixture.continuation.v1")
      |> put_in(["provider_mapping", "continuation_required"], true)

    {state, _, _} = pending([String.duplicate("x", 2_400)], configuration: configuration)
    assert {:ok, probe} = SessionState.preflight_standalone_context(state, 61_000, fn -> :ok end)
    targets = ContextAdmission.thinking_targets(1_000)
    assert probe.receipt["provider_estimated_tokens"] > targets["input_target"]
    assert probe.receipt["provider_estimated_tokens"] <= 1_000
    assert probe.failure == nil
    assert probe.request.continuation == nil
    assert probe.receipt["continuation_cost"] == nil
  end

  test "the captured input ceiling precedes an oversized whole-record view" do
    {state, _, _} =
      pending([String.duplicate("x", 34_000)],
        context_token_budget: 1_000,
        system_class_tokens: 512
      )

    assert {:ok, probe} = SessionState.preflight_standalone_context(state, 61_000, fn -> :ok end)
    assert probe.failure["dimension"] == "context_tokens"
    assert probe.failure["limit"] == 1_000
    assert probe.failure["hard_limit"] == 1_000
    assert probe.failure["measurement_scope"] == "ordinary"
    assert probe.failure["version"] == 2
    assert probe.failure["category"] == "context_budget_exceeded"
    assert probe.failure["retryable"] == false
    assert probe.receipt["record_byte_cost"] > Store.max_item_bytes()
    assert {:ok, _wire} = ContextFailure.project(probe.failure, :encode)
    refute Map.has_key?(probe.failure, "record_byte_cost")
  end

  test "byte refusal reports the exact oversized view without trimming original inputs" do
    {state, _, _} = pending([String.duplicate("x", 34_000)])
    raw = SessionState.lineage_elements(state, :session)
    assert {:ok, probe} = SessionState.preflight_standalone_context(state, 61_000, fn -> :ok end)
    exact_bytes = byte_size(:erlang.term_to_binary(probe.record, [:deterministic]))
    assert probe.receipt["provider_estimated_tokens"] <= 32_768
    assert probe.failure["dimension"] == "context_record_bytes"
    assert probe.failure["observed"] == exact_bytes
    assert probe.receipt["record_byte_cost"] == exact_bytes
    assert probe.failure["limit"] == 65_536
    assert probe.failure["hard_limit"] == 65_536
    assert {:ok, wire} = ContextFailure.project(probe.failure, :encode)
    assert wire["observed"] == Integer.to_string(exact_bytes)
    assert SessionState.lineage_elements(state, :session) == raw
    assert byte_size(List.last(probe.request.messages)["content"]) == 34_000
  end

  test "structural refusal precedes bytes and preserves the unresolved self-size" do
    {state, _, _} =
      pending(List.duplicate("x", Store.max_item_cardinality() - 1),
        definitions: [ToolDefinition.question_definition()]
      )

    assert {:ok, probe} = SessionState.preflight_standalone_context(state, 61_000, fn -> :ok end)
    assert probe.failure["dimension"] == "context_record_cardinality"
    assert probe.failure["observed"] == 1_025
    assert probe.failure["limit"] == 1_024
    assert probe.receipt["record_byte_cost"] == 0
    assert {:ok, _} = ContextFailure.project(probe.failure, :encode)
    assert length(probe.request.messages) == 1_024
    assert length(probe.request.tools) == 1
    assert length(probe.receipt["blocks"]) == 1_025
  end

  test "interruption stops the probe before and after canonical projection or sizing" do
    {state, _, _} = pending(["raw input"])

    for stop_at <- 1..4 do
      counter = :counters.new(1, [])

      check = fn ->
        :counters.add(counter, 1, 1)
        if :counters.get(counter, 1) == stop_at, do: {:error, :cancelled}, else: :ok
      end

      assert {:error, :cancelled} =
               SessionState.preflight_standalone_context(state, 61_000, check)

      assert :counters.get(counter, 1) == stop_at
    end

    assert state.maintenance_episodes == %{}
    assert state.deadlines == %{}
  end

  test "a pending accepted command owns the probe and cannot replace its fixed identity" do
    {state, _, _} = pending([])

    for replacement <- [
          %{run_id: "invented"},
          %{deadline: 999},
          %{configuration_version: 999},
          %{elements: nil},
          %{elements: "invented"}
        ] do
      assert {:error, :context_projection_invalid} =
               SessionState.preflight_standalone_context(
                 state,
                 61_000,
                 fn -> :ok end,
                 replacement
               )
    end

    for deadline <- [nil, 0, -1, 18_446_744_073_709_551_616] do
      assert {:error, :context_projection_invalid} =
               SessionState.preflight_standalone_context(state, deadline, fn -> :ok end)
    end

    for invalid <- [
          %{state | pending_compact: nil},
          %{state | pending_compact: Map.put(state.pending_compact, "abort_command_id", "abort")}
        ] do
      assert {:error, :context_projection_invalid} =
               SessionState.preflight_standalone_context(invalid, 61_000, fn ->
                 flunk("unowned or cancelled compact entered projection")
               end)
    end
  end

  test "unchanged completion atomically retains the exact result and event without an episode" do
    for bounds <- [
          %{max_attempts: 4, deadline_ms: 60_000, token_budget: 32_768},
          %{max_attempts: 1, deadline_ms: 1, token_budget: 1}
        ] do
      {state, history, events} = pending([], bounds: bounds)
      assert {:ok, proposal} = SessionState.propose_unchanged_compact(state, 1_000, fn -> :ok end)
      [record] = proposal.records
      [event] = proposal.events
      assert record.kind == "compact_command_completed_v1"
      assert record["observed_at"] == 1_000
      assert event.kind == "context.compaction_finished"

      assert Map.take(event, ~w(episode_id command_id result)) ==
               Map.take(record, ~w(episode_id command_id result))

      result = record["result"]

      assert result == %{
               "disposition" => "unchanged",
               "checkpoint_id" => nil,
               "failure" => nil,
               "usage" => %{
                 "attempts" => 0,
                 "reported_tokens" => 0,
                 "estimated_tokens" => 0,
                 "total_tokens" => 0
               },
               "cleanup" => "confirmed"
             }

      assert {:ok, wire} = LoopexProtocol.Session.CompactResult.encode_wire(result)
      assert {:ok, ^result} = LoopexProtocol.Session.CompactResult.decode_wire(wire)
      assert {:ok, _} = Store.admit_bounded(record)
      assert {:ok, _} = Store.admit_bounded(event)
      {completed, history, events} = commit(state, proposal, history, events)
      assert {:ok, ^completed} = SessionState.recover(state.session_id, history, events)
      assert completed.pending_compact == nil
      assert completed.commands["compact"].result == result
      assert completed.commands["compact"].reply == {:accepted, "compact"}

      for field <- [
            :conversation,
            :run_order,
            :pending_work,
            :bounds,
            :deadlines,
            :charged,
            :maintenance_episodes,
            :active_maintenance,
            :checkpoints,
            :active_checkpoint,
            :configuration,
            :tool_selection
          ] do
        assert Map.fetch!(completed, field) == Map.fetch!(state, field)
      end

      command = %{type: :compact, command_id: "compact", bounds: bounds}
      assert {:replayed, ^result} = SessionState.propose(completed, command)

      assert {:committed, :admitted, :accepted, nil} =
               SessionState.command_disposition(completed, "compact")

      assert {:error, :idempotency_conflict} =
               SessionState.propose(completed, %{command | bounds: %{bounds | deadline_ms: 2}})

      assert {:ok, fresh} = SessionState.propose(completed, %{command | command_id: "next"})
      assert fresh.reply == {:accepted, "next"}
      assert fresh.next.pending_compact["command_id"] == "next"
    end
  end

  test "unchanged replay refuses substituted results, identities, clocks and missing events" do
    {state, history, events} = pending([])
    {:ok, proposal} = SessionState.propose_unchanged_compact(state, 1_000, fn -> :ok end)
    {completed, full_history, full_events} = commit(state, proposal, history, events)
    record = hd(proposal.records)

    changes =
      [
        &Map.put(&1, "episode_id", "foreign"),
        &Map.put(&1, "command_id", "foreign"),
        &Map.put(&1, "observed_at", -1),
        &Map.put(&1, "observed_at", @uint64_max),
        &Map.put(&1, "run_id", "invented"),
        &put_in(&1, ["result", "checkpoint_id"], "invented"),
        &put_in(&1, ["result", "disposition"], "checkpointed"),
        &put_in(&1, ["result", "cleanup"], "unknown"),
        &put_in(&1, ["result", "failure"], %{"category" => "cancelled", "retryable" => false}),
        &put_in(&1, ["result", "usage", "attempts"], 1),
        &put_in(&1, ["result", "usage"], %{
          "attempts" => 0,
          "reported_tokens" => 1,
          "estimated_tokens" => 0,
          "total_tokens" => 1
        })
      ] ++ Enum.map(Map.keys(record), fn key -> &Map.delete(&1, key) end)

    for change <- changes do
      assert {:error, _} =
               SessionState.recover(
                 state.session_id,
                 history ++ [row(state, change.(record))],
                 full_events
               )
    end

    assert {:error, _} = SessionState.recover(state.session_id, full_history, events)

    assert {:error, _} =
             SessionState.recover(state.session_id, full_history, full_events ++ full_events)

    assert {:error, _} =
             SessionState.recover(
               state.session_id,
               full_history ++ [row(completed, record)],
               full_events
             )

    {nonempty, raw_history, raw_events} = pending(["retained raw fact"])

    assert {:error, _} =
             SessionState.recover(
               nonempty.session_id,
               raw_history ++ [row(nonempty, record)],
               raw_events ++
                 [Map.put(hd(proposal.events), :event_sequence, nonempty.event_sequence + 1)]
             )
  end

  test "unchanged completion refuses eligible history, aborts, captured episodes and invalid clocks" do
    {nonempty, _, _} = pending(["retained fact"])

    assert {:error, :compaction_required} =
             SessionState.propose_unchanged_compact(nonempty, 1_000, fn -> :ok end)

    {:ok, capture} =
      SessionState.propose_standalone_maintenance_episode(
        nonempty,
        maintenance_model(),
        maintenance_instructions(),
        1_000,
        fn -> :ok end
      )

    assert {:error, :maintenance_not_quiescent} =
             SessionState.propose_unchanged_compact(capture.next, 1_000, fn ->
               flunk("captured episode measured")
             end)

    {empty, history, events} = pending([])
    {:ok, abort} = SessionState.propose(empty, %{type: :abort, command_id: "stop"})
    {aborting, _, _} = commit(empty, abort, history, events)

    assert {:error, :maintenance_not_quiescent} =
             SessionState.propose_unchanged_compact(aborting, 1_000, fn ->
               flunk("aborted compact measured")
             end)

    for invalid <- [nil, -1, @uint64_max] do
      assert {:error, :maintenance_deadline_unrepresentable} =
               SessionState.propose_unchanged_compact(empty, invalid, fn ->
                 flunk("invalid clock measured")
               end)
    end

    {:ok, instructions} =
      Loopex.Runtime.Instructions.capture(%{
        "version" => "large.v1",
        "base" => String.duplicate("x", 2_000),
        "environment" => "",
        "appendix" => ""
      })

    configuration = Map.put(configuration(system_class_tokens: 500), "instructions", instructions)

    assert {:error, :invalid_session_configuration} =
             Loopex.Runtime.SessionConfiguration.validate(configuration, [])
  end

  test "every unchanged completion measurement and final proposal check can cancel" do
    {state, _, _} = pending([])
    callbacks = :atomics.new(1, [])

    assert {:ok, _} =
             SessionState.propose_unchanged_compact(state, 1_000, fn ->
               :atomics.add_get(callbacks, 1, 1)
               :ok
             end)

    count = :atomics.get(callbacks, 1)
    assert count > 1

    for stop <- 1..count do
      :atomics.put(callbacks, 1, 0)

      assert {:error, :cancelled} =
               SessionState.propose_unchanged_compact(state, 1_000, fn ->
                 if :atomics.add_get(callbacks, 1, 1) == stop, do: {:error, :cancelled}, else: :ok
               end)

      assert :atomics.get(callbacks, 1) == stop
      assert state.pending_compact != nil
      assert state.maintenance_episodes == %{}
    end
  end

  defp configuration(options) do
    Genesis.configuration()
    |> Map.put("context_token_budget", Keyword.get(options, :context_token_budget, 32_768))
    |> Map.put("system_class_tokens", Keyword.get(options, :system_class_tokens, 5_000))
    |> put_in(["budget_origins", "context_token_budget"], "explicit")
  end

  defp maintenance_model do
    source = Genesis.configuration()

    %{
      "model" => source["model"],
      "reasoning" => "none",
      "model_capabilities" => %{source["model_capabilities"] | "reasoning_levels" => ["none"]},
      "provider_mapping" => %{source["provider_mapping"] | "thinking_disabled" => true}
    }
  end

  defp maintenance_instructions do
    {:ok, captured} =
      MaintenanceConfiguration.capture_instructions(%{
        "version" => "summary.v1",
        "body" => "Keep facts 猫"
      })

    captured
  end

  defp pending(texts, options \\ []) do
    configuration = Keyword.get_lazy(options, :configuration, fn -> configuration(options) end)

    history = [
      %{
        journal_version: 1,
        owner_epoch: 0,
        owner_incarnation_id: nil,
        payload: Genesis.genesis(Keyword.get(options, :definitions, []), configuration)
      },
      %{
        journal_version: 2,
        owner_epoch: 1,
        owner_incarnation_id: "owner",
        payload: %{
          :kind => "owner_advanced",
          "prior_owner_epoch" => 0,
          "owner_epoch" => 1,
          "owner_incarnation_id" => "owner",
          "owner_transaction_id" => "owner-tx"
        }
      }
    ]

    {:ok, initial} = SessionState.recover("compact-projection-session", history, [])

    {state, history, events} =
      Enum.reduce(Enum.with_index(texts), {initial, history, []}, fn {text, index},
                                                                     {state, history, events} ->
        {:ok, prompt} =
          SessionState.propose(
            state,
            %{type: :prompt, command_id: "old-#{index}", content: text},
            %{
              max_turns: 8,
              deadline_ms: 60_000,
              token_budget: 10_000,
              context_token_budget: configuration["context_token_budget"]
            }
          )

        {state, history, events} = commit(state, prompt, history, events)

        {:ok, terminal} =
          SessionState.propose_run_terminal(state, state.active_run_id, "failed", %{
            reason: "model_call_failed"
          })

        commit(state, terminal, history, events)
      end)

    {:ok, compact} =
      SessionState.propose(state, %{
        type: :compact,
        command_id: "compact",
        bounds:
          Keyword.get(options, :bounds, %{
            max_attempts: 4,
            deadline_ms: 60_000,
            token_budget: 32_768
          })
      })

    {state, history, events} = commit(state, compact, history, events)
    assert {:ok, ^state} = SessionState.recover(state.session_id, history, events)
    {state, history, events}
  end

  defp row(state, payload),
    do: %{
      payload: payload,
      journal_version: state.journal_version + 1,
      owner_epoch: state.owner_epoch,
      owner_incarnation_id: state.owner_incarnation_id
    }

  defp commit(state, proposal, history, events) do
    rows =
      Enum.with_index(proposal.records, state.journal_version + 1)
      |> Enum.map(fn {payload, version} -> %{row(state, payload) | journal_version: version} end)

    added =
      Enum.with_index(proposal.events, state.event_sequence + 1)
      |> Enum.map(fn {event, sequence} -> Map.put(event, :event_sequence, sequence) end)

    receipt = %{
      journal_versions: %{
        first: state.journal_version + 1,
        last: state.journal_version + length(rows)
      },
      event_sequences:
        if(added == [],
          do: nil,
          else: %{first: state.event_sequence + 1, last: state.event_sequence + length(added)}
        )
    }

    {:ok, next} = SessionState.commit_proposal(proposal, receipt)
    {next, history ++ rows, events ++ added}
  end
end
