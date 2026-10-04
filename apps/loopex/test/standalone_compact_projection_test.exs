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

  test "undispatched cancellation is bound to the actual abort and commits one result" do
    for captured? <- [false, true] do
      {state, history, events} = pending(["retained fact"])

      {state, history, events} =
        if captured? do
          {:ok, capture} =
            SessionState.propose_standalone_maintenance_episode(
              state,
              maintenance_model(),
              maintenance_instructions(),
              1_000,
              fn -> :ok end
            )

          commit(state, capture, history, events)
        else
          {state, history, events}
        end

      failure = %{"category" => "cancelled", "retryable" => false}

      assert {:error, :invalid_compact_completion_transition} =
               SessionState.propose_standalone_compact_failure(state, failure, 1_001)

      {:ok, abort} = SessionState.propose(state, %{type: :abort, command_id: "stop"})
      {state, history, events} = commit(state, abort, history, events)

      assert {:ok, proposal} =
               SessionState.propose_standalone_compact_failure(state, failure, 1_001)

      assert Enum.map(proposal.records, & &1.kind) ==
               if(captured?,
                 do: ["maintenance_episode_terminal_v1", "compact_command_completed_v1"],
                 else: ["compact_command_completed_v1"]
               )

      assert length(proposal.events) == 1
      result = List.last(proposal.records)["result"]
      assert result["failure"] == failure

      assert result["usage"] == %{
               "attempts" => 0,
               "reported_tokens" => 0,
               "estimated_tokens" => 0,
               "total_tokens" => 0
             }

      {completed, history, events} = commit(state, proposal, history, events)
      assert {:ok, ^completed} = SessionState.recover(state.session_id, history, events)
      assert completed.pending_compact == nil
      assert completed.active_maintenance == nil
      assert completed.maintenance_terminal == nil
      assert completed.commands["compact"].result == result
      assert completed.conversation == state.conversation
      assert completed.charged == state.charged
      assert completed.active_run_id == nil

      if captured? do
        assert completed.maintenance_episodes[state.active_maintenance]["stage"] == "settled"
        assert completed.maintenance_episodes[state.active_maintenance]["result"] == result
      end
    end
  end

  test "captured failure prefix and completion are indivisible and authenticated on replay" do
    {state, history, events} = pending(["retained fact"])

    {:ok, capture} =
      SessionState.propose_standalone_maintenance_episode(
        state,
        maintenance_model(),
        maintenance_instructions(),
        1_000,
        fn -> :ok end
      )

    {state, history, events} = commit(state, capture, history, events)
    {:ok, abort} = SessionState.propose(state, %{type: :abort, command_id: "stop"})
    {state, history, events} = commit(state, abort, history, events)

    {:ok, proposal} =
      SessionState.propose_standalone_compact_failure(
        state,
        %{"category" => "cancelled", "retryable" => false},
        1_001
      )

    [prefix, completion] = proposal.records
    {_, full_history, full_events} = commit(state, proposal, history, events)

    assert {:error, _} =
             SessionState.recover(state.session_id, Enum.drop(full_history, -1), events)

    assert {:error, _} =
             SessionState.recover(
               state.session_id,
               history ++ [row(state, completion)],
               full_events
             )

    assert {:error, _} = SessionState.recover(state.session_id, full_history, events)

    for {first, last} <- [
          {Map.put(prefix, "episode_id", "foreign"), completion},
          {Map.put(prefix, "observed_at", 1_002), completion},
          {put_in(prefix, ["result", "cleanup"], "unknown"), completion},
          {prefix, Map.put(completion, "observed_at", 999)},
          {prefix, Map.put(completion, "command_id", "foreign")},
          {prefix, put_in(completion, ["result", "usage", "attempts"], 1)},
          {completion, prefix}
        ] do
      rows = [row(state, first), %{row(state, last) | journal_version: state.journal_version + 2}]
      assert {:error, _} = SessionState.recover(state.session_id, history ++ rows, full_events)
    end
  end

  test "deadline failure proves the same candidate or captured absolute cutoff with zero usage" do
    for captured? <- [false, true] do
      {state, history, events} = pending(["fact"])

      {state, history, events} =
        if captured? do
          {:ok, capture} =
            SessionState.propose_standalone_maintenance_episode(
              state,
              maintenance_model(),
              maintenance_instructions(),
              1_000,
              fn -> :ok end
            )

          commit(state, capture, history, events)
        else
          {state, history, events}
        end

      failure = %{
        "category" => "bound_reached",
        "retryable" => false,
        "bound" => "deadline_ms",
        "observed" => 61_001,
        "declared_limit" => 61_000,
        "accounting_source" => nil
      }

      clock = if captured?, do: 61_001, else: 1_000

      assert {:ok, proposal} =
               SessionState.propose_standalone_compact_failure(state, failure, clock)

      {completed, history, events} = commit(state, proposal, history, events)
      assert {:ok, ^completed} = SessionState.recover(state.session_id, history, events)
      assert completed.commands["compact"].result["failure"] == failure

      for changed <- [
            Map.put(failure, "declared_limit", 60_000),
            Map.put(failure, "observed", 60_999),
            Map.put(failure, "accounting_source", "reported"),
            Map.put(failure, "bound", "max_attempts"),
            Map.put(failure, "bound", "token_budget")
          ] do
        assert {:error, :invalid_compact_completion_transition} =
                 SessionState.propose_standalone_compact_failure(state, changed, clock)
      end
    end
  end

  test "unrepresentable admission clock completes without fabricating an episode" do
    {state, history, events} = pending([])
    failure = preparation_failure("maintenance_deadline_unrepresentable", nil)

    for clock <- [nil, @uint64_max] do
      assert {:ok, proposal} =
               SessionState.propose_standalone_compact_failure(state, failure, clock)

      {completed, rows, public} = commit(state, proposal, history, events)
      assert {:ok, ^completed} = SessionState.recover(state.session_id, rows, public)
      assert completed.maintenance_episodes == %{}
      assert completed.commands["compact"].result["failure"] == failure
      assert length(proposal.records) == 1
    end

    assert {:error, :invalid_compact_completion_transition} =
             SessionState.propose_standalone_compact_failure(state, failure, 1_000)
  end

  test "missing summarizer failures require eligible history and yield to a committed abort" do
    {state, history, events} = pending(["retained fact"])
    {empty, _, _} = pending([])

    for cause <-
          ~w(maintenance_model_unconfigured maintenance_instructions_unconfigured maintenance_reasoning_unsupported) do
      failure = preparation_failure(cause, "ordinary")

      assert {:ok, proposal} =
               SessionState.propose_standalone_compact_failure(state, failure, 1_000)

      {completed, rows, public} = commit(state, proposal, history, events)
      assert {:ok, ^completed} = SessionState.recover(state.session_id, rows, public)
      assert completed.maintenance_episodes == %{}

      assert {:error, :invalid_compact_completion_transition} =
               SessionState.propose_standalone_compact_failure(empty, failure, 1_000)

      {:ok, abort} = SessionState.propose(state, %{type: :abort, command_id: "stop"})
      {aborting, _, _} = commit(state, abort, history, events)

      assert {:error, :invalid_compact_completion_transition} =
               SessionState.propose_standalone_compact_failure(aborting, failure, 1_000)
    end
  end

  test "standalone source staging commits the existing episode request/open identity without a run" do
    {state, history, events} = captured_source(["first fact", "second fact"])
    raw = state.conversation
    episode = state.maintenance_episodes[state.active_maintenance]

    assert {:ok, proposal} =
             SessionState.propose_selected_maintenance_request(state, 1_500, fn -> :ok end)

    [staged, opened] = proposal.records
    assert staged.kind == "maintenance_request_committed_v1"
    assert opened.kind == "maintenance_attempt_opened_v1"
    assert staged["eligible_unit_count"] == 2
    assert staged["covered_range"]["unit_count"] == 2
    assert staged["covered_range"]["first_kept"] == nil
    assert staged["captured_session_version"] == episode["session_version"]
    assert staged["source_excerpted"] == false
    assert staged["request"]["deadline"] == episode["deadline"]
    assert staged["request"]["tools"] == []
    assert staged["request"]["continuation"] == nil
    assert staged["request"]["sampling"]["max_tokens"] == 1_024
    assert staged["request"]["sampling"]["reasoning"] == "none"

    assert staged["context_receipt"]["record_byte_cost"] ==
             byte_size(:erlang.term_to_binary(staged, [:deterministic]))

    assert {:ok, _} = Store.admit_bounded(staged)
    assert {:ok, _} = Store.admit_bounded(opened)

    assert {:ok, binding} =
             Loopex.Runtime.ProviderAttempt.binding_from_opened(state.session_id, opened)

    assert binding["episode_id"] == episode["episode_id"]
    assert binding["purpose"] == "compaction"
    assert binding["operation_id"] == staged["operation_id"]
    assert binding["staged_request_digest"] == staged["staged_request_digest"]
    refute Map.has_key?(binding, "run_id")
    refute Map.has_key?(binding, "turn_id")

    for row <- proposal.records do
      refute Map.has_key?(row, "run_id")
      refute Map.has_key?(row, "staging_turn_id")
      refute Map.has_key?(row, "preparation_deadline")
    end

    assert proposal.events == []
    {opened_state, history, events} = commit(state, proposal, history, events)
    assert {:ok, ^opened_state} = SessionState.recover(state.session_id, history, events)
    assert opened_state.active_run_id == nil
    assert opened_state.pending_work == %{}
    assert opened_state.deadlines == %{}
    assert opened_state.charged == state.charged
    assert opened_state.conversation == raw
    live = opened_state.maintenance_episodes[state.active_maintenance]
    assert live["stage"] == "model_attempt_open"
    assert live["attempts"] == 1
    assert live["model_attempt"] == 1
    assert live["deadline"] == episode["deadline"]
    assert live["request"].deadline == episode["deadline"]
    assert live["usage"] == episode["usage"]
  end

  test "standalone source staging preserves captured request identity through owner succession" do
    {state, history, events} = captured_source(["first fact", "second fact"])
    {:ok, before} = SessionState.propose_selected_maintenance_request(state, 1_500, fn -> :ok end)

    owner = %{
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

    {:ok, successor} = SessionState.recover(state.session_id, history ++ [owner], events)

    assert {:ok, after_value} =
             SessionState.propose_selected_maintenance_request(successor, 5_000, fn -> :ok end)

    [first_request, first_open] = before.records
    [later_request, later_open] = after_value.records
    assert Map.delete(first_request, "staged_at") == Map.delete(later_request, "staged_at")
    assert first_open == later_open
    assert first_request["request"]["deadline"] == 61_000
    {opened, history, events} = commit(successor, after_value, history ++ [owner], events)
    assert {:ok, ^opened} = SessionState.recover(state.session_id, history, events)
    assert opened.owner_epoch == successor.owner_epoch
    assert opened.charged == state.charged
    assert opened.deadlines == %{}
  end

  test "standalone source staging permits exactly the accepted fixed reply reserve" do
    {state, _, _} =
      captured_source(["fact"],
        bounds: %{max_attempts: 1, deadline_ms: 60_000, token_budget: 1_024}
      )

    assert {:ok, proposal} =
             SessionState.propose_selected_maintenance_request(state, 1_500, fn -> :ok end)

    assert hd(proposal.records)["request"]["sampling"]["max_tokens"] == 1_024
    episode = proposal.next.maintenance_episodes[state.active_maintenance]
    assert episode["bounds"]["token_budget"] == 1_024
    assert episode["attempts"] == 1
    assert episode["usage"]["total_tokens"] == 0
    assert proposal.next.bounds == state.bounds
    assert proposal.next.charged == state.charged
  end

  test "standalone source selection cannot strand a huge unit behind a small complete prefix" do
    {state, _, _} = captured_source(["small prefix", String.duplicate("x", 34_000)])

    assert {:ok, proposal} =
             SessionState.propose_selected_maintenance_request(state, 1_500, fn -> :ok end)

    record = hd(proposal.records)
    assert record["covered_range"]["unit_count"] == 2
    assert record["source_excerpted"] == true
    [_system, source] = record["request"]["messages"]
    assert byte_size(source["content"]) <= 16_384
    assert source["content"] =~ "serialized_excerpt"
    assert source["content"] =~ "loopex.compaction.messages_json.v1"
  end

  test "standalone request replay refuses separated opens and rehashed source/request substitutions" do
    {state, history, events} = captured_source(["first fact", "second fact"])

    {:ok, proposal} =
      SessionState.propose_selected_maintenance_request(state, 1_500, fn -> :ok end)

    [staged, opened] = proposal.records
    {_, full_history, full_events} = commit(state, proposal, history, events)

    assert {:error, _} =
             SessionState.recover(state.session_id, Enum.drop(full_history, -1), events)

    assert {:error, _} =
             SessionState.recover(state.session_id, history ++ [row(state, opened)], events)

    for change <- [
          &Map.put(&1, "run_id", "invented"),
          &Map.put(&1, "captured_session_version", state.journal_version + 1),
          &Map.put(&1, "staged_at", 61_000),
          &Map.put(&1, "eligible_unit_count", 1),
          &Map.put(&1, "source_digest", String.duplicate("0", 64)),
          &put_in(&1, ["covered_range", "unit_count"], 1),
          &put_in(&1, ["request", "deadline"], 61_001),
          &put_in(&1, ["request", "sampling", "max_tokens"], 1_025),
          &put_in(&1, ["context_receipt", "record_byte_cost"], 0)
        ] do
      bad = [
        row(state, change.(staged)),
        %{row(state, opened) | journal_version: state.journal_version + 2}
      ]

      assert {:error, _} = SessionState.recover(state.session_id, history ++ bad, full_events)
    end

    assert {:error, _} =
             SessionState.recover(
               state.session_id,
               history ++
                 [
                   row(state, staged),
                   %{row(state, staged) | journal_version: state.journal_version + 2}
                 ],
               events
             )
  end

  test "standalone request preparation checks the retained cutoff and actual abort before work" do
    {state, history, events} = captured_source(["retained fact"])

    for clock <- [nil, 999, 18_446_744_073_709_551_616] do
      assert {:error, :context_projection_invalid} =
               SessionState.propose_selected_maintenance_request(state, clock, fn -> :ok end)
    end

    assert {:error, :standalone_deadline_reached} =
             SessionState.propose_selected_maintenance_request(state, 61_000, fn -> :ok end)

    {:ok, abort} = SessionState.propose(state, %{type: :abort, command_id: "stop"})
    {aborting, _, _} = commit(state, abort, history, events)

    assert {:error, :maintenance_not_quiescent} =
             SessionState.propose_selected_maintenance_request(aborting, 1_500, fn ->
               flunk("aborted source traversed history")
             end)
  end

  test "every standalone source selection and staged-proposal check can cancel" do
    {state, _, _} = captured_source(["first fact", "second fact"])
    counter = :atomics.new(1, [])

    assert {:ok, _} =
             SessionState.propose_selected_maintenance_request(state, 1_500, fn ->
               :atomics.add_get(counter, 1, 1)
               :ok
             end)

    total = :atomics.get(counter, 1)
    assert total > 10

    for stop <- 1..total do
      :atomics.put(counter, 1, 0)

      assert {:error, :cancelled} =
               SessionState.propose_selected_maintenance_request(state, 1_500, fn ->
                 if :atomics.add_get(counter, 1, 1) == stop, do: {:error, :cancelled}, else: :ok
               end)

      assert :atomics.get(counter, 1) == stop
    end

    assert state.maintenance_episodes[state.active_maintenance]["attempts"] == 0
    assert state.deadlines == %{}
  end

  test "standalone readable settlement spends the episode and leaves a valid summary checkpoint pending" do
    {state, history, events} = opened_source()
    episode = state.maintenance_episodes[state.active_maintenance]
    raw = standalone_reply(episode["request"])

    assert {:ok, proposal} =
             SessionState.propose_maintenance_attempt_settled(state, {:reply, raw})

    assert [settlement] = proposal.records
    assert settlement.kind == "maintenance_attempt_settled_v3"
    assert settlement["conversation"] == "canonical"
    assert proposal.events == []
    {next, history, events} = commit(state, proposal, history, events)
    assert {:ok, ^next} = SessionState.recover(state.session_id, history, events)
    retained = next.maintenance_episodes[next.active_maintenance]
    assert retained["stage"] == "checkpoint_pending"

    assert retained["summary"] == %{
             "summary" => "retained facts",
             "carry_forward" => %{"files_read" => [], "files_changed" => []}
           }

    assert retained["usage"] == %{
             "attempts" => 1,
             "reported_tokens" => 56,
             "estimated_tokens" => 0,
             "total_tokens" => 56
           }

    assert next.charged == state.charged
    assert next.bounds == state.bounds
    assert next.deadlines == %{}
    assert next.pending_work == %{}
    assert next.conversation == state.conversation
    assert next.pending_compact == state.pending_compact

    assert {:error, :no_open_maintenance_attempt} =
             SessionState.propose_maintenance_attempt_settled(next, {:reply, raw}, 2_000)
  end

  test "standalone unreported canonical usage exhausts its own captured allowance without changing run charges" do
    {state, history, events} = opened_source()
    request = state.maintenance_episodes[state.active_maintenance]["request"]
    raw = %{standalone_reply(request) | usage: %{}}

    {:ok, proposal} =
      SessionState.propose_maintenance_attempt_settled(state, {:reply, raw}, 2_000)

    assert [prefix, settlement, completed] = proposal.records
    assert prefix.kind == "maintenance_episode_terminal_v1"
    assert settlement["accounting"]["source"] == "estimated"

    assert completed["result"]["failure"] == %{
             "category" => "bound_reached",
             "retryable" => false,
             "bound" => "token_budget",
             "observed" => 32_768,
             "declared_limit" => 32_768,
             "accounting_source" => "estimated"
           }

    assert completed["result"]["usage"] == %{
             "attempts" => 1,
             "reported_tokens" => 0,
             "estimated_tokens" => 32_768,
             "total_tokens" => 32_768
           }

    {next, history, events} = commit(state, proposal, history, events)
    assert {:ok, ^next} = SessionState.recover(state.session_id, history, events)
    assert next.charged == state.charged
    assert next.active_maintenance == nil
    assert next.pending_compact == nil
  end

  test "standalone readable invalid and incomplete summaries retain usage and close without a repair call" do
    for {change, cause} <- [
          {fn raw -> %{raw | text: "{}"} end, "maintenance_summary_invalid"},
          {fn raw -> %{raw | completion: "limit", text: "{}"} end,
           "maintenance_summary_incomplete"},
          {fn raw -> %{raw | completion: "unknown"} end, "maintenance_summary_incomplete"},
          {fn raw -> %{raw | tool_calls: [%{id: "call", name: "tool", arguments: %{}}]} end,
           "maintenance_summary_invalid"}
        ] do
      {state, history, events} = opened_source()

      raw =
        change.(standalone_reply(state.maintenance_episodes[state.active_maintenance]["request"]))

      assert {:ok, proposal} =
               SessionState.propose_maintenance_attempt_settled(state, {:reply, raw}, 2_000)

      assert [prefix, settlement, completed] = proposal.records
      assert settlement["conversation"] == "canonical"
      assert completed["result"]["failure"] == preparation_failure(cause, nil)
      assert completed["result"]["usage"]["reported_tokens"] == 56
      assert completed["result"]["usage"]["attempts"] == 1
      assert prefix["result"] == completed["result"]
      {next, history, events} = commit(state, proposal, history, events)
      assert {:ok, ^next} = SessionState.recover(state.session_id, history, events)
      assert next.commands["compact"].result == completed["result"]
      assert next.maintenance_episodes[completed["episode_id"]]["stage"] == "settled"
      assert next.charged == state.charged
      assert next.conversation == state.conversation
      assert next.active_run_id == nil
      assert List.last(events).kind == "context.compaction_finished"
      assert List.last(events)["result"] == completed["result"]

      assert {:replayed, result} =
               SessionState.propose(next, %{
                 type: :compact,
                 command_id: "compact",
                 bounds: state.pending_compact["bounds"]
               })

      assert result == completed["result"]
      refute Enum.any?(proposal.events, &(&1.kind == "run.finished"))
    end
  end

  test "standalone unreadable reply and provider failure preserve conservative spending and owner-loss cleanup" do
    for outcome <- [
          :owner_loss,
          {:error, :offline},
          {:reply, %{text: "unreadable", usage: %{input_tokens: 1, output_tokens: 1}}}
        ] do
      {state, history, events} = opened_source()

      assert {:ok, proposal} =
               SessionState.propose_maintenance_attempt_settled(state, outcome, 2_000)

      assert [_prefix, settlement, completed] = proposal.records

      assert settlement["accounting"] == %{
               "source" => "estimated",
               "basis" => "remaining_allowance"
             }

      assert completed["result"]["failure"] == %{
               "category" => "model_call_failed",
               "retryable" => false
             }

      assert completed["result"]["usage"] == %{
               "attempts" => 1,
               "reported_tokens" => 0,
               "estimated_tokens" => 32_768,
               "total_tokens" => 32_768
             }

      assert completed["result"]["cleanup"] ==
               if(outcome == :owner_loss, do: "unknown", else: "confirmed")

      {next, history, events} = commit(state, proposal, history, events)
      assert {:ok, ^next} = SessionState.recover(state.session_id, history, events)
      assert next.charged == state.charged
      assert next.pending_work == %{}
      assert next.deadlines == %{}
    end
  end

  test "standalone not-dispatched retry reuses request bytes and consumes only attempt allowance" do
    {state, history, events} = opened_source()
    episode = state.maintenance_episodes[state.active_maintenance]
    {:ok, first} = SessionState.propose_maintenance_attempt_settled(state, :not_dispatched, 2_000)
    assert [settlement] = first.records
    assert settlement["next"] == "retry"
    {state, history, events} = commit(state, first, history, events)

    assert state.maintenance_episodes[state.active_maintenance]["usage"] == %{
             "attempts" => 1,
             "reported_tokens" => 0,
             "estimated_tokens" => 0,
             "total_tokens" => 0
           }

    {:ok, retry} = SessionState.propose_maintenance_attempt_open(state)
    {state, history, events} = commit(state, retry, history, events)
    assert state.maintenance_episodes[state.active_maintenance]["request"] == episode["request"]

    assert state.maintenance_episodes[state.active_maintenance]["operation_id"] ==
             episode["operation_id"]

    assert state.maintenance_episodes[state.active_maintenance]["attempts"] == 2

    {:ok, failed} =
      SessionState.propose_maintenance_attempt_settled(state, :not_dispatched, 2_001)

    assert List.last(failed.records)["result"]["usage"] == %{
             "attempts" => 2,
             "reported_tokens" => 0,
             "estimated_tokens" => 0,
             "total_tokens" => 0
           }

    {next, history, events} = commit(state, failed, history, events)
    assert {:ok, ^next} = SessionState.recover(state.session_id, history, events)
    assert next.active_maintenance == nil
    assert {:error, :no_retry_permitted} = SessionState.propose_maintenance_attempt_open(next)
  end

  test "standalone not-dispatched attempt at its declared ceiling completes with exact max-attempts bound" do
    {state, history, events} =
      opened_source(bounds: %{max_attempts: 1, deadline_ms: 60_000, token_budget: 32_768})

    {:ok, proposal} =
      SessionState.propose_maintenance_attempt_settled(state, :not_dispatched, 2_000)

    assert [prefix, settlement, completed] = proposal.records
    assert settlement["next"] == "retry"
    assert prefix["result"] == completed["result"]

    assert completed["result"]["failure"] == %{
             "category" => "bound_reached",
             "retryable" => false,
             "bound" => "max_attempts",
             "observed" => 1,
             "declared_limit" => 1,
             "accounting_source" => nil
           }

    assert completed["result"]["usage"]["attempts"] == 1
    assert completed["result"]["usage"]["total_tokens"] == 0
    {next, history, events} = commit(state, proposal, history, events)
    assert {:ok, ^next} = SessionState.recover(state.session_id, history, events)
  end

  test "standalone admitted abort wins before deadline and charges readable late evidence once" do
    {state, history, events} = opened_source()
    {:ok, abort} = SessionState.propose(state, %{type: :abort, command_id: "stop"})
    {state, history, events} = commit(state, abort, history, events)

    assert {:error, :no_open_maintenance_attempt} =
             SessionState.propose_maintenance_termination(state, 61_000)

    raw = standalone_reply(state.maintenance_episodes[state.active_maintenance]["request"])

    {:ok, proposal} =
      SessionState.propose_maintenance_attempt_settled(state, {:reply, raw}, 61_001)

    assert [_prefix, settlement, completed] = proposal.records
    assert settlement["termination"] == "abort"
    assert settlement["conversation"] == "evidence_only"
    assert completed["result"]["failure"] == %{"category" => "cancelled", "retryable" => false}
    assert completed["result"]["usage"]["reported_tokens"] == 56
    {next, history, events} = commit(state, proposal, history, events)
    assert {:ok, ^next} = SessionState.recover(state.session_id, history, events)
  end

  test "standalone admitted deadline wins over later abort and reports its actual absolute observation" do
    {state, history, events} = opened_source()

    assert {:error, :no_open_maintenance_attempt} =
             SessionState.propose_maintenance_termination(state, 60_999)

    {:ok, deadline} = SessionState.propose_maintenance_termination(state, 61_000)
    {state, history, events} = commit(state, deadline, history, events)
    {:ok, abort} = SessionState.propose(state, %{type: :abort, command_id: "stop"})
    {state, history, events} = commit(state, abort, history, events)
    raw = standalone_reply(state.maintenance_episodes[state.active_maintenance]["request"])

    assert {:error, :invalid_compact_completion_transition} =
             SessionState.propose_maintenance_attempt_settled(state, {:reply, raw}, 60_999)

    {:ok, proposal} =
      SessionState.propose_maintenance_attempt_settled(state, {:reply, raw}, 61_001)

    assert [_prefix, settlement, completed] = proposal.records
    assert settlement["termination"] == "deadline"

    assert completed["result"]["failure"] == %{
             "category" => "bound_reached",
             "retryable" => false,
             "bound" => "deadline_ms",
             "observed" => 61_001,
             "declared_limit" => 61_000,
             "accounting_source" => "reported"
           }

    {next, history, events} = commit(state, proposal, history, events)
    assert {:ok, ^next} = SessionState.recover(state.session_id, history, events)
  end

  test "standalone failed settlement rejects missing or invalid completion clock and replay substitutions" do
    {state, history, events} = opened_source()

    for clock <- [nil, 1_499, @uint64_max + 1] do
      assert {:error, :invalid_compact_completion_transition} =
               SessionState.propose_maintenance_attempt_settled(state, :owner_loss, clock)
    end

    {:ok, proposal} = SessionState.propose_maintenance_attempt_settled(state, :owner_loss, 2_000)
    [prefix, settlement, completed] = proposal.records
    {next, full, full_events} = commit(state, proposal, history, events)
    assert {:ok, ^next} = SessionState.recover(state.session_id, full, full_events)

    for missing <- [0, 1, 2] do
      rows = List.delete_at(proposal.records, missing)

      bad =
        Enum.with_index(rows, state.journal_version + 1)
        |> Enum.map(fn {payload, v} -> %{row(state, payload) | journal_version: v} end)

      assert {:error, _} = SessionState.recover(state.session_id, history ++ bad, full_events)
    end

    for change <- [
          &put_in(&1, ["usage", "total_tokens"], 0),
          &put_in(&1, ["usage", "reported_tokens"], 32_768),
          &Map.put(&1, "cleanup", "confirmed"),
          &Map.put(&1, "failure", %{"category" => "cancelled", "retryable" => false}),
          &Map.put(&1, "checkpoint_id", "invented")
        ] do
      result = change.(completed["result"])
      changed = [%{prefix | "result" => result}, settlement, %{completed | "result" => result}]

      bad =
        Enum.with_index(changed, state.journal_version + 1)
        |> Enum.map(fn {payload, v} -> %{row(state, payload) | journal_version: v} end)

      assert {:error, _} = SessionState.recover(state.session_id, history ++ bad, full_events)
    end

    assert {:error, _} =
             SessionState.recover(
               state.session_id,
               full ++ [%{row(next, completed) | journal_version: next.journal_version + 1}],
               full_events
             )
  end

  test "standalone retry cannot open or adopt a deadline after an actual compact abort" do
    {state, history, events} = opened_source()
    {:ok, first} = SessionState.propose_maintenance_attempt_settled(state, :not_dispatched, 2_000)
    {state, history, events} = commit(state, first, history, events)
    {:ok, abort} = SessionState.propose(state, %{type: :abort, command_id: "stop"})
    {state, _, _} = commit(state, abort, history, events)
    assert {:error, :no_retry_permitted} = SessionState.propose_maintenance_attempt_open(state)
  end

  test "standalone settled retry and checkpoint cancellation retain spending without a second settlement" do
    for outcome <- [:not_dispatched, :summary] do
      {state, history, events} = opened_source()

      value =
        if(outcome == :summary,
          do:
            {:reply,
             standalone_reply(state.maintenance_episodes[state.active_maintenance]["request"])},
          else: outcome
        )

      {:ok, settled} = SessionState.propose_maintenance_attempt_settled(state, value, 2_000)
      {state, history, events} = commit(state, settled, history, events)
      usage = state.maintenance_episodes[state.active_maintenance]["usage"]
      {:ok, abort} = SessionState.propose(state, %{type: :abort, command_id: "stop"})
      {state, history, events} = commit(state, abort, history, events)
      failure = %{"category" => "cancelled", "retryable" => false}

      assert {:ok, completed} =
               SessionState.propose_standalone_compact_failure(state, failure, 61_001)

      assert [prefix, ending] = completed.records
      assert prefix.kind == "maintenance_episode_terminal_v1"
      assert ending.kind == "compact_command_completed_v1"
      assert ending["result"]["usage"] == usage
      {next, history, events} = commit(state, completed, history, events)
      assert {:ok, ^next} = SessionState.recover(state.session_id, history, events)
      assert next.maintenance_episodes[ending["episode_id"]]["usage"] == usage
      assert next.charged == state.charged
    end
  end

  test "standalone settled retry and checkpoint expiry retain the absolute cutoff and accounting source" do
    for outcome <- [:not_dispatched, :summary] do
      {state, history, events} = opened_source()

      value =
        if(outcome == :summary,
          do:
            {:reply,
             standalone_reply(state.maintenance_episodes[state.active_maintenance]["request"])},
          else: outcome
        )

      {:ok, settled} = SessionState.propose_maintenance_attempt_settled(state, value, 2_000)
      {state, history, events} = commit(state, settled, history, events)
      episode = state.maintenance_episodes[state.active_maintenance]
      source = if(outcome == :summary, do: "reported", else: nil)

      failure = %{
        "category" => "bound_reached",
        "retryable" => false,
        "bound" => "deadline_ms",
        "observed" => 61_001,
        "declared_limit" => 61_000,
        "accounting_source" => source
      }

      assert {:error, :invalid_compact_completion_transition} =
               SessionState.propose_standalone_compact_failure(state, failure, 60_999)

      assert {:ok, completed} =
               SessionState.propose_standalone_compact_failure(state, failure, 61_001)

      assert List.last(completed.records)["result"]["usage"] == episode["usage"]
      {next, history, events} = commit(state, completed, history, events)
      assert {:ok, ^next} = SessionState.recover(state.session_id, history, events)
      assert next.charged == state.charged
      assert next.maintenance_episodes[episode["episode_id"]]["usage"] == episode["usage"]
    end
  end

  test "standalone valid reported overshoot retains exact quantities above the captured ceiling" do
    {state, history, events} = opened_source()

    raw = %{
      standalone_reply(state.maintenance_episodes[state.active_maintenance]["request"])
      | usage: %{input_tokens: @uint64_max - 1, output_tokens: 1}
    }

    {:ok, proposal} =
      SessionState.propose_maintenance_attempt_settled(state, {:reply, raw}, 2_000)

    result = List.last(proposal.records)["result"]
    assert result["usage"]["total_tokens"] == @uint64_max
    assert result["usage"]["reported_tokens"] == @uint64_max
    assert result["failure"]["observed"] == @uint64_max
    assert result["failure"]["declared_limit"] == 32_768
    assert result["failure"]["accounting_source"] == "reported"
    {next, history, events} = commit(state, proposal, history, events)
    assert {:ok, ^next} = SessionState.recover(state.session_id, history, events)
    assert {:ok, encoded} = LoopexProtocol.Session.CompactResult.encode_wire(result)
    assert encoded["usage"]["total_tokens"] == Integer.to_string(@uint64_max)
  end

  test "standalone failure preparation cannot bypass or resettle an open attempt" do
    {state, _, _} = opened_source()

    assert {:error, :invalid_compact_completion_transition} =
             SessionState.propose_standalone_compact_failure(
               state,
               %{"category" => "model_call_failed", "retryable" => false},
               2_000
             )

    assert {:error, :cancelled} =
             SessionState.propose_standalone_compact_failure(
               state,
               %{"category" => "model_call_failed", "retryable" => false},
               2_000,
               fn -> {:error, :cancelled} end
             )
  end

  test "standalone pending checkpoint measures exact command-owned substitution without mutating facts" do
    {state, _, _} = settled_checkpoint([String.duplicate("f", 8_000)])
    original = state

    assert {:ok, candidate} =
             SessionState.preflight_maintenance_checkpoint(state, 2_001, fn -> :ok end)

    assert candidate.trigger == "explicit"
    assert candidate.before.record.kind == "compact_context_probe_v1"
    assert candidate.after.record.kind == "compact_context_probe_v1"
    assert candidate.before.record["command_id"] == "compact"
    assert candidate.after.record["command_id"] == "compact"
    assert candidate.after.record["request"]["deadline"] == 61_000

    assert candidate.before.record_bytes ==
             byte_size(:erlang.term_to_binary(candidate.before.record, [:deterministic]))

    assert candidate.after.record_bytes ==
             byte_size(:erlang.term_to_binary(candidate.after.record, [:deterministic]))

    assert candidate.after.record_bytes < candidate.before.record_bytes
    assert candidate.after.tokens < candidate.before.tokens
    assert candidate.after.rendering == :ok
    assert {:ok, _} = candidate.after.admission

    assert candidate.consumed_range ==
             state.maintenance_episodes[state.active_maintenance]["covered_range"]

    assert candidate.covered_range == candidate.consumed_range
    assert candidate.covered_range["first_kept"] == nil
    assert candidate.summary["covered_range_digest"] == candidate.covered_range["digest"]
    assert candidate.summary["source_excerpted"] == false
    assert candidate.prior_checkpoint_id == nil
    assert state == original
    assert state.checkpoints == %{}
    assert state.active_checkpoint == nil
    assert state.deadlines == %{}
  end

  test "standalone checkpoint authenticates its command and completes without a synthetic run" do
    {state, history, events} = settled_checkpoint([String.duplicate("f", 8_000)])
    original = state

    assert {:ok, proposal} =
             SessionState.propose_maintenance_checkpoint(state, 2_001, fn -> :ok end)

    assert [record] = proposal.records
    assert record.kind == "standalone_compaction_checkpoint_committed_v1"
    assert record["command_id"] == "compact"
    refute Map.has_key?(record, "run_id")
    assert record["lineage"]["through_run_id"] == List.last(state.run_order)
    assert record["covered_range"]["first_kept"] == nil
    assert [event] = proposal.events
    assert event["owner"] == %{"kind" => "compact", "id" => "compact"}
    refute Map.has_key?(event, "run_id")
    {checkpoint, checkpoint_history, checkpoint_events} = commit(state, proposal, history, events)

    assert {:ok, ^checkpoint} =
             SessionState.recover(state.session_id, checkpoint_history, checkpoint_events)

    assert checkpoint.conversation == original.conversation
    assert checkpoint.charged == original.charged
    assert checkpoint.deadlines == %{}
    assert checkpoint.active_run_id == nil
    assert checkpoint.run_order == original.run_order

    for owner <- [
          %{"kind" => "run", "id" => "compact"},
          %{"kind" => "compact", "id" => "different"},
          %{"kind" => "compact", "id" => "compact", "run_id" => "alias"}
        ] do
      altered = List.update_at(checkpoint_events, -1, &Map.put(&1, "owner", owner))
      assert {:error, _} = SessionState.recover(state.session_id, checkpoint_history, altered)
    end

    for mutation <- [
          Map.put(record, "command_id", "different"),
          Map.put(record, :kind, "compaction_checkpoint_committed_v1"),
          Map.put(record, "run_id", List.last(state.run_order)),
          put_in(record, ["lineage", "through_run_id"], "synthetic-run")
        ] do
      altered = List.update_at(checkpoint_history, -1, &%{&1 | payload: mutation})
      assert {:error, _} = SessionState.recover(state.session_id, altered, checkpoint_events)
    end

    assert {:ok, completion} =
             SessionState.propose_maintenance_checkpoint_completion(checkpoint, 2_002, fn ->
               :ok
             end)

    assert [prefix, completed] = completion.records
    assert prefix.kind == "maintenance_episode_terminal_v1"
    assert completed.kind == "compact_command_completed_v1"
    assert completed["result"]["disposition"] == "checkpointed"
    assert completed["result"]["checkpoint_id"] == record["checkpoint_id"]

    assert completed["result"]["usage"] ==
             state.maintenance_episodes[state.active_maintenance]["usage"]

    {next, final_history, final_events} =
      commit(checkpoint, completion, checkpoint_history, checkpoint_events)

    assert {:ok, ^next} = SessionState.recover(state.session_id, final_history, final_events)
    assert next.pending_compact == nil
    assert next.active_maintenance == nil
    assert next.charged == original.charged
    assert next.deadlines == %{}
    assert next.conversation == original.conversation
    assert next.commands["compact"].result == completed["result"]
    assert List.last(final_events).kind == "context.compaction_finished"

    assert {:error, _} =
             SessionState.recover(state.session_id, Enum.drop(final_history, -1), final_events)
  end

  test "standalone zero-attempt token refusal authenticates the reservation and cannot use the run-only cause" do
    {state, history, events} =
      captured_source(["retained original fact"],
        bounds: %{max_attempts: 4, deadline_ms: 60_000, token_budget: 1_023}
      )

    failure = %{
      "category" => "bound_reached",
      "retryable" => false,
      "bound" => "token_budget",
      "observed" => 0,
      "declared_limit" => 1_023,
      "accounting_source" => nil
    }

    for changed <- [
          Map.put(failure, "observed", 1),
          Map.put(failure, "declared_limit", 1_022),
          Map.put(failure, "accounting_source", "reported")
        ] do
      assert {:error, :invalid_compact_completion_transition} =
               SessionState.propose_standalone_compact_failure(state, changed, 2_000)
    end

    assert {:error, :maintenance_bounds_exhausted} =
             SessionState.propose_standalone_compact_failure(
               state,
               preparation_failure("maintenance_reply_reserve_unavailable", nil),
               2_000
             )

    assert {:error, :standalone_deadline_reached} =
             SessionState.propose_standalone_compact_failure(
               state,
               failure,
               state.maintenance_episodes[state.active_maintenance]["deadline"]
             )

    {:ok, completion} = SessionState.propose_standalone_compact_failure(state, failure, 2_000)
    {state, history, events} = commit(state, completion, history, events)
    assert {:ok, ^state} = SessionState.recover(state.session_id, history, events)
    assert state.commands["compact"].result["usage"]["attempts"] == 0
  end

  test "a fitted standalone checkpoint completes at its last attempt and refuses fabricated exhaustion" do
    {state, history, events} =
      settled_checkpoint([String.duplicate("f", 8_000)],
        bounds: %{max_attempts: 1, deadline_ms: 60_000, token_budget: 32_768}
      )

    {:ok, checkpoint} = SessionState.propose_maintenance_checkpoint(state, 2_001, fn -> :ok end)
    {state, history, events} = commit(state, checkpoint, history, events)

    failure = %{
      "category" => "bound_reached",
      "retryable" => false,
      "bound" => "max_attempts",
      "observed" => 1,
      "declared_limit" => 1,
      "accounting_source" => nil
    }

    assert {:error, :invalid_compact_completion_transition} =
             SessionState.propose_standalone_compact_failure(state, failure, 2_002)

    assert {:ok, completion} =
             SessionState.propose_maintenance_checkpoint_completion(state, 2_002, fn -> :ok end)

    {state, history, events} = commit(state, completion, history, events)
    assert state.commands["compact"].result["disposition"] == "checkpointed"
    assert {:ok, ^state} = SessionState.recover(state.session_id, history, events)
  end

  test "standalone abort and expiry after a committed checkpoint retain its usage and raw facts" do
    for action <- [:abort, :deadline] do
      {state, history, events} = settled_checkpoint([String.duplicate("f", 8_000)])
      original = state
      {:ok, checkpoint} = SessionState.propose_maintenance_checkpoint(state, 2_001, fn -> :ok end)
      {state, history, events} = commit(state, checkpoint, history, events)
      episode = state.maintenance_episodes[state.active_maintenance]

      {state, history, events, failure, clock} =
        if action == :abort do
          {:ok, abort} = SessionState.propose(state, %{type: :abort, command_id: "stop"})
          {state, history, events} = commit(state, abort, history, events)
          {state, history, events, %{"category" => "cancelled", "retryable" => false}, 2_002}
        else
          failure = %{
            "category" => "bound_reached",
            "retryable" => false,
            "bound" => "deadline_ms",
            "observed" => episode["deadline"],
            "declared_limit" => episode["deadline"],
            "accounting_source" => "reported"
          }

          {state, history, events, failure, episode["deadline"]}
        end

      assert {:ok, completion} =
               SessionState.propose_standalone_compact_failure(state, failure, clock)

      assert [prefix, completed] = completion.records
      assert prefix.kind == "maintenance_episode_terminal_v1"
      assert completed.kind == "compact_command_completed_v1"

      assert completed["result"] == %{
               "disposition" => "failed",
               "checkpoint_id" => state.active_checkpoint,
               "failure" => failure,
               "usage" => episode["usage"],
               "cleanup" => "confirmed"
             }

      {next, history, events} = commit(state, completion, history, events)
      assert {:ok, ^next} = SessionState.recover(state.session_id, history, events)
      assert next.active_checkpoint == state.active_checkpoint
      assert next.active_maintenance == nil
      assert next.pending_compact == nil
      assert next.charged == original.charged
      assert next.conversation == original.conversation
      assert next.run_order == original.run_order
      assert next.deadlines == original.deadlines
    end
  end

  test "standalone pending checkpoint uses hard ceilings after a source excerpt" do
    {state, _, _} =
      settled_checkpoint([String.duplicate("f", 8_000)],
        context_token_budget: 2_048,
        system_class_tokens: 512
      )

    episode = state.maintenance_episodes[state.active_maintenance]
    assert episode["trigger"] == "ordinary_limit"
    assert episode["source_excerpted"] == true

    assert {:ok, candidate} =
             SessionState.preflight_maintenance_checkpoint(state, 2_001, fn -> :ok end)

    assert candidate.before.admission |> elem(0) == :refused
    assert candidate.after.admission |> elem(0) == :ok
    assert candidate.after.record["context_receipt"]["context_token_budget"] == 2_048
    assert candidate.summary["source_excerpted"] == true
    assert candidate.after.record["request"]["continuation"] == nil
    assert candidate.after.record["context_receipt"]["continuation_cost"] == nil
  end

  test "standalone nonprogress ends with retained usage and no checkpoint or second settlement" do
    {state, history, events} = settled_checkpoint(["small fact"])
    failure = preparation_failure("compaction_no_progress", "ordinary")

    assert {:error, :compaction_no_progress} =
             SessionState.preflight_maintenance_checkpoint(state, 2_001, fn -> :ok end)

    assert {:ok, proposal} =
             SessionState.propose_standalone_compact_failure(state, failure, 2_001)

    assert [prefix, completed] = proposal.records
    assert prefix.kind == "maintenance_episode_terminal_v1"
    assert completed.kind == "compact_command_completed_v1"
    assert completed["result"]["failure"] == failure
    assert completed["result"]["usage"]["reported_tokens"] == 56
    {next, history, events} = commit(state, proposal, history, events)
    assert {:ok, ^next} = SessionState.recover(state.session_id, history, events)
    assert next.checkpoints == %{}
    assert next.compacted_sources == state.compacted_sources
    assert next.charged == state.charged
    assert next.conversation == state.conversation
    assert next.pending_compact == nil
    assert List.last(events).kind == "context.compaction_finished"
    refute Enum.any?(proposal.events, &(&1.kind == "context.compacted"))
    assert Enum.count(history, &(&1.payload.kind == "maintenance_attempt_settled_v3")) == 1
  end

  test "standalone useful substitution cannot claim a nonprogress ending" do
    {state, _, _} = settled_checkpoint([String.duplicate("f", 8_000)])

    assert {:error, :invalid_compact_completion_transition} =
             SessionState.propose_standalone_compact_failure(
               state,
               preparation_failure("compaction_no_progress", "ordinary"),
               2_001
             )
  end

  test "standalone checkpoint probes refuse abort, absolute expiry, changed range and clocks before traversal" do
    {state, history, events} = settled_checkpoint([String.duplicate("f", 8_000)])

    assert {:error, :standalone_deadline_reached} =
             SessionState.preflight_maintenance_checkpoint(state, 61_000, fn ->
               flunk("expired probe traversed")
             end)

    for clock <- [nil, -1, @uint64_max + 1] do
      assert {:error, :clock_out_of_domain} =
               SessionState.preflight_maintenance_checkpoint(state, clock, fn ->
                 flunk("invalid clock traversed")
               end)
    end

    assert {:error, :context_projection_invalid} =
             SessionState.preflight_maintenance_checkpoint(state, 1_499, fn ->
               flunk("pre-staging clock traversed")
             end)

    {:ok, abort} = SessionState.propose(state, %{type: :abort, command_id: "stop"})
    {aborting, _, _} = commit(state, abort, history, events)

    assert {:error, :maintenance_not_quiescent} =
             SessionState.preflight_maintenance_checkpoint(aborting, 2_001, fn ->
               flunk("aborted probe traversed")
             end)

    corrupted =
      put_in(
        state.maintenance_episodes[state.active_maintenance]["covered_range"]["digest"],
        String.duplicate("0", 64)
      )

    assert {:error, :context_projection_invalid} =
             SessionState.preflight_maintenance_checkpoint(corrupted, 2_001, fn -> :ok end)
  end

  test "every standalone pending checkpoint projection check can cancel without changing retained state" do
    {state, _, _} = settled_checkpoint([String.duplicate("f", 8_000)])
    counter = :atomics.new(1, [])

    {:ok, _} =
      SessionState.preflight_maintenance_checkpoint(state, 2_001, fn ->
        :atomics.add_get(counter, 1, 1)
        :ok
      end)

    total = :atomics.get(counter, 1)
    assert total > 10

    for stop <- 1..total do
      :atomics.put(counter, 1, 0)

      assert {:error, :cancelled} =
               SessionState.preflight_maintenance_checkpoint(state, 2_001, fn ->
                 if :atomics.add_get(counter, 1, 1) == stop, do: {:error, :cancelled}, else: :ok
               end)

      assert :atomics.get(counter, 1) == stop
    end

    assert state.active_checkpoint == nil
    assert state.maintenance_episodes[state.active_maintenance]["stage"] == "checkpoint_pending"
  end

  defp settled_checkpoint(texts, options \\ []) do
    {state, history, events} = captured_source(texts, options)

    {:ok, request} =
      SessionState.propose_selected_maintenance_request(state, 1_500, fn -> :ok end)

    {state, history, events} = commit(state, request, history, events)
    raw = standalone_reply(state.maintenance_episodes[state.active_maintenance]["request"])
    {:ok, settled} = SessionState.propose_maintenance_attempt_settled(state, {:reply, raw}, 2_000)
    commit(state, settled, history, events)
  end

  defp opened_source(options \\ []) do
    {state, history, events} = captured_source(["retained original fact"], options)

    {:ok, proposal} =
      SessionState.propose_selected_maintenance_request(state, 1_500, fn -> :ok end)

    commit(state, proposal, history, events)
  end

  defp standalone_reply(request) do
    %{
      text: ~s({"summary":"retained facts","carry_forward":{"files_read":[],"files_changed":[]}}),
      identity: %{provider: "scripted", model: request.model, endpoint: "in-process"},
      usage: %{input_tokens: 37, output_tokens: 19},
      tool_calls: [],
      delta_count: 0,
      streamed: false,
      provider_response_id: nil,
      canonical_request_bytes: request.canonical_request_bytes,
      staged_request_digest: request.staged_request_digest,
      completion: "natural",
      continuation: nil
    }
  end

  defp captured_source(texts, options \\ []) do
    {state, history, events} = pending(texts, options)

    {:ok, capture} =
      SessionState.propose_standalone_maintenance_episode(
        state,
        maintenance_model(),
        maintenance_instructions(),
        1_000,
        fn -> :ok end
      )

    commit(state, capture, history, events)
  end

  defp preparation_failure(cause, scope),
    do: %{
      "version" => 2,
      "category" => "context_preparation_failed",
      "retryable" => false,
      "measurement_scope" => scope,
      "cause" => cause
    }

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
