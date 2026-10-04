Code.require_file("support/configured_genesis_helper.exs", __DIR__)

defmodule Loopex.Runtime.MaintenanceRequestStagingTest do
  use ExUnit.Case, async: true
  alias Loopex.ConfiguredGenesisFixture, as: Genesis
  alias Loopex.Runtime.{MaintenanceConfiguration, SessionState}
  alias LoopexProtocol.{Canonical, Frame}
  alias Loopex.Store

  test "ordinary tail selection uses the actual configured request and excludes fixed instruction cost from preference" do
    {state, history, events} = admitted(List.duplicate(String.duplicate("x", 2_000), 3))
    run = state.active_run_id
    staging = ordinary_staging(state)
    project = ordinary_project()

    assert {:ok, choice} =
             SessionState.ordinary_compaction_tail(state, staging, :automatic, project, fn ->
               :ok
             end)

    assert choice.eligible_unit_count == 1
    assert length(choice.retained_tail) == 3
    assert choice.tail_tokens <= 2_048
    assert choice.released_unit_count == 0

    elements = Enum.flat_map(choice.retained_tail, & &1.elements)
    probe = %{staging | elements: elements}

    assert {:ok, candidate} =
             SessionState.reference_model_candidate(state, probe, [], project, nil)

    assert candidate.request.messages ==
             [
               %{
                 "role" => "system",
                 "content" =>
                   "host.v1: Follow the host's captured instructions.\n\ncaptured environment"
               }
             ] ++
               Enum.map(elements, &%{"role" => "user", "content" => &1.content})

    assert candidate.receipt["provider_estimated_tokens"] > choice.tail_tokens

    assert candidate.request.sampling ==
             Loopex.Runtime.SessionConfiguration.sampling(state.configuration)

    assert candidate.request.tools == []
    assert candidate.request.continuation == nil
    assert candidate.receipt["continuation_cost"] == nil

    # Measurement is allowed while maintenance fences ordinary intent.
    assert {:error, :maintenance_active} =
             SessionState.preflight_model_request(state, run, candidate.request)

    measured = %{state | active_maintenance: nil}

    assert {:ok, record} =
             SessionState.preflight_model_request(measured, run, candidate.request,
               context_receipt: candidate.receipt,
               lineage_projection: candidate.projection
             )

    assert {:ok, ^record, exact_bytes} = Store.normalize_and_measure_item(:record, record)
    assert record["context_receipt"]["record_byte_cost"] == exact_bytes
    assert {:ok, recovered} = SessionState.recover(state.session_id, history, events)
    assert recovered == state
  end

  test "fixed required content can refuse an otherwise small protected tail" do
    {state, _, _} =
      admitted(["old"],
        ordinary_body: String.duplicate("s", 2_000),
        current_content: String.duplicate("p", 1_500),
        system_class_tokens: 1_024,
        context_token_budget: 1_024
      )

    assert {:refused, refusal} =
             SessionState.ordinary_compaction_tail(
               state,
               ordinary_staging(state),
               :automatic,
               ordinary_project(),
               fn -> :ok end
             )

    assert refusal["dimension"] == "context_tokens"
    assert refusal["observed"] > 1_024
    assert refusal["limit"] == 1_024
    assert refusal["record_byte_cost"] == nil
  end

  test "mandatory tails above the preference fit hard limits and explicit selection covers all older units" do
    {state, _, _} =
      admitted(["older", "newer"],
        current_content: String.duplicate("p", 10_000),
        resources: true
      )

    for origin <- [:automatic, :explicit] do
      assert {:ok, choice} =
               SessionState.ordinary_compaction_tail(
                 state,
                 ordinary_staging(state),
                 origin,
                 ordinary_project(),
                 fn -> :ok end
               )

      assert choice.eligible_unit_count == 2
      assert length(choice.retained_tail) == 1
      assert choice.tail_tokens > 2_048
      assert hd(choice.retained_tail).protected?
    end
  end

  test "ordinary tail probes retain cancellation and complete-record refusal without dispatch" do
    {state, _, _} =
      admitted(["old"],
        current_content: String.duplicate("p", 33_000),
        context_token_budget: 16_384
      )

    assert {:refused, refusal} =
             SessionState.ordinary_compaction_tail(
               state,
               ordinary_staging(state),
               :automatic,
               ordinary_project(),
               fn -> :ok end
             )

    assert refusal["dimension"] == "context_record_bytes"
    assert refusal["observed"] > 65_536
    assert refusal["limit"] == 65_536
    assert refusal["record_byte_cost"] == refusal["observed"]

    assert {:error, :cancelled} =
             SessionState.ordinary_compaction_tail(
               state,
               ordinary_staging(state),
               :automatic,
               ordinary_project(),
               fn -> {:error, :cancelled} end
             )

    assert state.maintenance_episodes[state.active_maintenance]["attempts"] == 0
    assert state.maintenance_episodes[state.active_maintenance]["stage"] == "source_preparation"
  end

  test "cancellation after complete candidate measurement is a failure rather than a fit result" do
    {state, _, _} = admitted(["old"])
    counter = :atomics.new(1, [])

    check = fn ->
      if :atomics.add_get(counter, 1, 1) == 4, do: {:error, :cancelled}, else: :ok
    end

    assert {:error, :cancelled} =
             SessionState.ordinary_compaction_tail(
               state,
               ordinary_staging(state),
               :automatic,
               ordinary_project(),
               check
             )

    assert :atomics.get(counter, 1) == 4
    assert state.maintenance_episodes[state.active_maintenance]["attempts"] == 0

    old = hd(state.run_order)

    assert {:error, :maintenance_not_quiescent} =
             SessionState.ordinary_compaction_tail(
               state,
               %{ordinary_staging(state) | run_id: old},
               :automatic,
               ordinary_project(),
               fn -> flunk("inactive run entered candidate measurement") end
             )
  end

  defp ordinary_staging(state),
    do: %{
      run_id: state.active_run_id,
      elements: SessionState.lineage_elements(state, state.active_run_id),
      steer: SessionState.pending_steer(state, state.active_run_id),
      resources: state.run_resources[state.active_run_id],
      deadline: 61_001,
      excerpt_allowance: 0
    }

  defp ordinary_project,
    do: %{
      "class" => "project_resource",
      "receipt_revision" => 2,
      "disposition" => "not_evaluated_required_failure",
      "detail" => nil
    }

  test "pending checkpoint substitution proves strict exact progress from retained summary and originals" do
    {state, history, events} = pending_checkpoint(String.duplicate("o", 3_000))

    assert {:ok, candidate} =
             SessionState.preflight_maintenance_checkpoint(state, 2_000, fn -> :ok end)

    assert candidate.after.tokens < candidate.before.tokens
    assert candidate.after.record_bytes < candidate.before.record_bytes
    assert {:ok, _} = candidate.after.admission
    assert candidate.prior_checkpoint_id == nil

    assert candidate.covered_range ==
             state.maintenance_episodes[state.active_maintenance]["covered_range"]

    assert candidate.summary["covered_range_digest"] == candidate.covered_range["digest"]
    assert candidate.summary["source_excerpted"] == false
    assert candidate.after.request.messages |> Enum.at(1) == elem(candidate.entry, 1)

    assert List.last(candidate.after.request.messages) == %{
             "role" => "user",
             "content" => "protected"
           }

    assert candidate.before.request.tools == candidate.after.request.tools
    assert candidate.before.request.sampling == candidate.after.request.sampling
    assert candidate.before.request.deadline == candidate.after.request.deadline
    assert candidate.after.request.continuation == nil

    for measurement <- [candidate.before, candidate.after] do
      assert {:ok, normalized, size} =
               Store.normalize_and_measure_item(:record, measurement.record)

      assert normalized == measurement.record
      assert size == measurement.record_bytes
      assert size == measurement.record["context_receipt"]["record_byte_cost"]
    end

    assert {:ok, recovered} = SessionState.recover(state.session_id, history, events)

    assert {:ok, ^candidate} =
             SessionState.preflight_maintenance_checkpoint(recovered, 2_000, fn -> :ok end)

    assert recovered.charged[state.active_run_id] == %{tokens: 56, source: :reported}
    assert recovered.maintenance_episodes[state.active_maintenance]["checkpoint_id"] == nil
    assert recovered.conversation == state.conversation
  end

  test "pending substitution retains admission's steer across later input and owner succession" do
    {state, history, events} = pending_checkpoint(String.duplicate("o", 3_000))

    assert {:ok, original} =
             SessionState.preflight_maintenance_checkpoint(state, 2_000, fn -> :ok end)

    {:ok, steer} =
      SessionState.propose(state, %{
        type: :steer,
        command_id: "after-summary",
        run_id: state.active_run_id,
        content: "Apply this at the next ordinary request"
      })

    {state, rows, events} = commit(state, steer, events)
    owner = owner_advance(state)

    assert {:ok, successor} =
             SessionState.recover(state.session_id, history ++ rows ++ [owner], events)

    assert successor.owner_epoch == 2

    assert SessionState.pending_steer(successor, state.active_run_id).command_id ==
             "after-summary"

    assert successor.maintenance_episodes[state.active_maintenance]["ordinary_steer"] == nil

    assert {:ok, ^original} =
             SessionState.preflight_maintenance_checkpoint(successor, 2_000, fn -> :ok end)

    refute Enum.any?(
             original.after.request.messages,
             &(&1["content"] == "Apply this at the next ordinary request")
           )

    assert successor.charged == state.charged
  end

  test "a usable summary which grows the projection refuses without hiding its settled charge" do
    {state, history, events} = pending_checkpoint("small")

    assert {:error, :compaction_no_progress} =
             SessionState.preflight_maintenance_checkpoint(state, 2_000, fn -> :ok end)

    assert {:ok, recovered} = SessionState.recover(state.session_id, history, events)
    assert recovered.charged[state.active_run_id].tokens == 56

    assert recovered.maintenance_episodes[state.active_maintenance]["stage"] ==
             "checkpoint_pending"
  end

  test "nonprogress ends the episode and parent with the last measured ordinary projection" do
    {state, history, events} = pending_checkpoint("small")
    run = state.active_run_id
    episode = state.active_maintenance

    {:ok, candidate} =
      SessionState.reference_model_candidate(
        state,
        ordinary_staging(state),
        [],
        ordinary_project(),
        nil
      )

    assert Enum.map(candidate.request.messages, & &1["content"]) == [
             "host.v1: Follow the host's captured instructions.\n\ncaptured environment",
             "small",
             "protected"
           ]

    assert {:ok, proposal} =
             SessionState.propose_maintenance_nonprogress(state, 2_000, fn -> :ok end)

    assert [prefix, refusal, terminal] = proposal.records
    assert prefix.kind == "maintenance_episode_terminal_v1"
    assert prefix["observed_at"] == 2_000
    assert prefix["episode_id"] == episode
    assert prefix["result"]["usage"] == state.maintenance_episodes[episode]["usage"]
    assert prefix["result"]["disposition"] == "failed"
    assert prefix["result"]["checkpoint_id"] == nil
    assert prefix["result"]["cleanup"] == "confirmed"
    assert refusal.kind == "context_admission_refused_v2"
    assert refusal["projection_state"] == "measured"
    assert refusal["measurement_scope"] == "ordinary"
    assert refusal["system_message_count"] == 1
    assert refusal["session_message_count"] == 2
    assert refusal["steer_message_count"] == 0
    assert refusal["tool_definition_count"] == 0
    assert refusal["provider_estimated_tokens"] == candidate.receipt["provider_estimated_tokens"]
    assert refusal["record_byte_cost"] == nil
    assert refusal["targets"] == nil
    assert refusal["project_disposition"] == "not_evaluated_required_failure"
    assert refusal["configuration_version"] == state.configuration["configuration_version"]
    assert refusal["episode_id"] == episode

    framed =
      ["loopex.context.descriptors.v1", <<0>>] ++
        Enum.flat_map(candidate.receipt["blocks"], fn block ->
          bytes = Canonical.encode(block)
          [<<byte_size(bytes)::unsigned-big-integer-size(64)>>, bytes]
        end)

    assert refusal["ordered_descriptor_digest"] ==
             :crypto.hash(:sha256, framed) |> Base.encode16(case: :lower)

    assert refusal["failure"] == %{
             "version" => 2,
             "category" => "context_preparation_failed",
             "retryable" => false,
             "measurement_scope" => "ordinary",
             "cause" => "compaction_no_progress"
           }

    assert terminal.kind == "run_terminal_committed"
    assert terminal["outcome"] == "failed"
    assert terminal["failure"] == refusal["failure"]
    assert prefix["result"]["failure"] == refusal["failure"]
    assert [event, settled] = proposal.events
    assert event.kind == "run.finished"
    assert event["failure"] == refusal["failure"]
    assert settled.kind == "session.settled"
    assert settled["run_id"] == run

    assert {:ok, ^refusal, bytes} = Store.normalize_and_measure_item(:record, refusal)
    assert bytes == byte_size(:erlang.term_to_binary(refusal, [:deterministic]))
    assert bytes < 65_536
    refute inspect(refusal) =~ "small"
    refute inspect(refusal) =~ "protected"

    {next, rows, all_events} = commit(state, proposal, events)
    assert next.active_maintenance == nil
    assert next.active_run_id == nil
    assert next.active_checkpoint == nil
    assert next.checkpoints == %{}
    assert next.conversation == state.conversation
    assert next.charged == state.charged
    assert next.charged[run].tokens == 56
    assert next.maintenance_episodes[episode]["attempts"] == 1
    assert next.maintenance_episodes[episode]["stage"] == "settled"
    assert {:ok, ^next} = SessionState.recover(state.session_id, history ++ rows, all_events)

    assert {:error, :no_pending_maintenance_checkpoint} =
             SessionState.propose_maintenance_nonprogress(next, 2_000, fn -> :ok end)
  end

  test "nonprogress replay authenticates measurements clock and complete terminal ordering" do
    {state, history, events} = pending_checkpoint("small")
    {:ok, proposal} = SessionState.propose_maintenance_nonprogress(state, 2_000, fn -> :ok end)
    {_next, [prefix, refusal, terminal] = rows, all_events} = commit(state, proposal, events)

    changes = [
      {"system_message_count", 0},
      {"session_message_count", 3},
      {"steer_message_count", 1},
      {"tool_definition_count", 1},
      {"provider_estimated_tokens", 0},
      {"ordered_descriptor_digest", String.duplicate("0", 64)},
      {"record_byte_cost", 42},
      {"projection_state", "unavailable"},
      {"measurement_scope", nil},
      {"configuration_version", 99},
      {"episode_id", nil},
      {"targets", %{}},
      {"project_disposition", "staged"},
      {"project_resource_count", 1},
      {"failure", Map.put(refusal.payload["failure"], "measurement_scope", nil)}
    ]

    for {field, value} <- changes do
      altered = %{refusal | payload: Map.put(refusal.payload, field, value)}

      assert {:error, :invalid_context_refusal} =
               SessionState.recover(
                 state.session_id,
                 history ++ [prefix, altered, terminal],
                 all_events
               )
    end

    for time <- [nil, 1_000, 61_001] do
      altered = %{prefix | payload: Map.put(prefix.payload, "observed_at", time)}

      assert {:error, _} =
               SessionState.recover(
                 state.session_id,
                 history ++ [altered, refusal, terminal],
                 all_events
               )
    end

    for partial <- [
          [prefix],
          [prefix, refusal],
          [refusal, terminal],
          [prefix, terminal],
          [refusal, prefix, terminal],
          rows ++ rows
        ] do
      assert {:error, _} =
               SessionState.recover(
                 state.session_id,
                 history ++ restamp(state, partial),
                 all_events
               )
    end

    {useful, _, _} = pending_checkpoint(String.duplicate("o", 3_000))

    assert {:error, :checkpoint_makes_progress} =
             SessionState.propose_maintenance_nonprogress(useful, 2_000, fn -> :ok end)
  end

  test "nonprogress cannot override deadline cancellation or settled parent capacity" do
    {state, _, events} = pending_checkpoint("small")

    assert {:error, :run_deadline_reached} =
             SessionState.propose_maintenance_nonprogress(state, 61_001, fn ->
               flunk("elapsed parent entered nonprogress measurement")
             end)

    assert {:error, :run_deadline_reached} =
             SessionState.propose_maintenance_nonprogress(state, 2_000, fn ->
               {:error, :run_deadline_reached}
             end)

    {:ok, abort} = SessionState.propose(state, %{type: :abort, command_id: "abort-nonprogress"})
    {aborted, _, _} = commit(state, abort, events)

    assert {:error, :maintenance_not_quiescent} =
             SessionState.propose_maintenance_nonprogress(aborted, 2_000, fn ->
               flunk("cancelled parent entered nonprogress measurement")
             end)

    for options <- [[max_turns: 1], [usage: %{}]] do
      {spent, _, _} = pending_checkpoint("small", options)

      assert {:error, :maintenance_bounds_exhausted} =
               SessionState.propose_maintenance_nonprogress(spent, 2_000, fn ->
                 flunk("spent parent entered nonprogress measurement")
               end)
    end
  end

  test "strict progressing substitution may remain above an ordinary hard limit" do
    {state, _, _} =
      pending_checkpoint(String.duplicate("o", 3_000),
        current_content: String.duplicate("p", 33_000),
        context_token_budget: 16_384
      )

    assert {:ok, candidate} =
             SessionState.preflight_maintenance_checkpoint(state, 2_000, fn -> :ok end)

    assert candidate.after.tokens < candidate.before.tokens
    assert candidate.after.record_bytes < candidate.before.record_bytes
    assert {:refused, refusal} = candidate.after.admission
    assert refusal["dimension"] == "context_record_bytes"
    assert refusal["observed"] == candidate.after.record_bytes
    assert refusal["observed"] > 65_536
  end

  test "abort, elapsed deadline and cancellation win before checkpoint admission" do
    {state, _, events} = pending_checkpoint(String.duplicate("o", 3_000))

    assert {:error, :run_deadline_reached} =
             SessionState.preflight_maintenance_checkpoint(
               state,
               61_001,
               fn -> flunk("elapsed deadline entered projection") end
             )

    assert {:error, :cancelled} =
             SessionState.preflight_maintenance_checkpoint(
               state,
               2_000,
               fn -> {:error, :cancelled} end
             )

    assert {:ok, abort} =
             SessionState.propose(state, %{
               type: :abort,
               command_id: "checkpoint-abort",
               run_id: state.active_run_id
             })

    {aborted, _, _} = commit(state, abort, events)

    assert {:error, :maintenance_not_quiescent} =
             SessionState.preflight_maintenance_checkpoint(
               aborted,
               2_000,
               fn -> flunk("abort entered projection") end
             )

    assert aborted.charged == state.charged
    assert aborted.conversation == state.conversation
  end

  test "settled summary spending cannot create a checkpoint after a parent bound wins" do
    for options <- [[usage: %{}], [max_turns: 1]] do
      {state, _, _} = pending_checkpoint(String.duplicate("o", 3_000), options)

      assert {:error, :maintenance_bounds_exhausted} =
               SessionState.preflight_maintenance_checkpoint(state, 2_000, fn ->
                 flunk("spent parent bound entered checkpoint projection")
               end)

      assert state.maintenance_episodes[state.active_maintenance]["checkpoint_id"] == nil
    end
  end

  test "standalone session scope reuses a retained checkpoint and includes later terminal inputs" do
    {state, history, events} =
      pending_checkpoint(String.duplicate("old", 1_000), later_old_units: ["unsummarized middle"])

    raw = SessionState.lineage_elements(state, :session)
    originals = state.conversation_record_sources
    run_order = state.run_order
    {:ok, checkpoint} = SessionState.propose_maintenance_checkpoint(state, 2_000, fn -> :ok end)
    {state, rows, events} = commit(state, checkpoint, events)
    history = history ++ rows
    checkpoint_id = state.active_checkpoint

    {:ok, completion} =
      SessionState.propose_maintenance_checkpoint_completion(state, 2_001, fn -> :ok end)

    {state, rows, events} = commit(state, completion, events)
    history = history ++ rows

    {:ok, terminal} =
      SessionState.propose_run_terminal(state, state.active_run_id, "failed", %{
        reason: "model_call_failed"
      })

    {state, rows, events} = commit(state, terminal, events)
    history = history ++ rows
    assert state.active_run_id == nil
    assert state.pending_work == %{}

    {:ok, compact} =
      SessionState.propose(state, %{
        type: :compact,
        command_id: "standalone",
        bounds: %{max_attempts: 4, deadline_ms: 60_000, token_budget: 32_768}
      })

    {state, rows, events} = commit(state, compact, events)
    history = history ++ rows
    assert {:ok, ^state} = SessionState.recover(state.session_id, history, events)
    assert state.run_order == run_order
    assert state.conversation_record_sources == originals
    assert SessionState.lineage_elements(state, :session) == raw
    assert state.pending_compact["command_id"] == "standalone"

    assert {:ok, units} = SessionState.compaction_units(state, :session)
    assert Enum.map(units, & &1.kind) == [:inputs, :inputs]
    assert Enum.flat_map(units, & &1.elements) == Enum.drop(raw, 1)
    refute Enum.any?(units, & &1.protected?)

    assert {:ok, selected} =
             Loopex.Conversation.compaction_tail(units, :explicit, fn [] -> {:ok, 0} end)

    assert selected.eligible_unit_count == 2
    assert selected.retained_tail == []
    assert {:ok, entries, nil} = SessionState.projected_lineage(state, :session, 0)

    assert elem(hd(entries), 0) == %{
             "kind" => "compaction_summary",
             "checkpoint_id" => checkpoint_id
           }

    assert Enum.map(tl(entries), &elem(&1, 1)["content"]) ==
             ["unsummarized middle", "protected"]

    refute Enum.any?(tl(entries), fn {source, _} ->
             MapSet.member?(state.compacted_sources, source)
           end)

    assert {:ok, candidate} =
             SessionState.reference_model_candidate(
               state,
               %{
                 scope: :session,
                 elements: raw,
                 steer: nil,
                 deadline: 62_000,
                 excerpt_allowance: 0
               },
               [],
               ordinary_project(),
               nil
             )

    assert tl(candidate.request.messages) == Enum.map(entries, &elem(&1, 1))
    assert candidate.request.continuation == nil
    assert candidate.request.deadline == 62_000

    assert candidate.receipt["blocks"] |> Enum.at(1) |> Map.fetch!("source_reference") ==
             elem(hd(entries), 0)

    assert {:ok, probe} = SessionState.preflight_standalone_context(state, 62_000, fn -> :ok end)
    assert probe.failure == nil
    assert probe.rendering == :ok
    assert probe.request == candidate.request

    assert probe.record["context_receipt"]["record_byte_cost"] ==
             byte_size(:erlang.term_to_binary(probe.record, [:deterministic]))

    assert {:ok, minimum} =
             SessionState.preflight_standalone_context(state, 62_000, fn -> :ok end, %{
               elements: [],
               checkpoint_entries: [hd(entries)]
             })

    assert minimum.request.messages == [hd(probe.request.messages), elem(hd(entries), 1)]

    assert minimum.receipt["blocks"] |> Enum.at(1) |> Map.fetch!("source_reference") ==
             elem(hd(entries), 0)

    assert minimum.receipt["record_byte_cost"] < probe.receipt["record_byte_cost"]

    assert {:ok, plan} =
             SessionState.preflight_standalone_compaction(state, 62_000, fn -> :ok end)

    assert plan.trigger == "explicit"
    assert plan.eligible_unit_count == 2
    assert plan.retained_tail == []
    assert plan.tail_tokens == 0
    assert plan.before.request == probe.request
    assert plan.before.receipt == probe.receipt
    assert state.active_checkpoint == checkpoint_id
    assert state.conversation_record_sources == originals
  end

  test "checkpoint and event commit together while exact raw facts remain readable" do
    {state, history, events} =
      pending_checkpoint(String.duplicate("old", 1_000), later_old_units: ["unsummarized middle"])

    episode_id = state.active_maintenance
    run = state.active_run_id
    raw = SessionState.lineage_elements(state, run)
    {:ok, candidate} = SessionState.preflight_maintenance_checkpoint(state, 2_000, fn -> :ok end)

    assert {:ok, proposal} =
             SessionState.propose_maintenance_checkpoint(state, 2_000, fn -> :ok end)

    assert [record] = proposal.records
    assert record.kind == "compaction_checkpoint_committed_v1"
    assert record["checkpoint_id"] == candidate.checkpoint_id
    assert record["covered_range"] == candidate.covered_range
    assert record["consumed_range"] == candidate.covered_range
    assert record["summary"] == candidate.summary
    assert record["source_digest"] == state.maintenance_episodes[episode_id]["source_digest"]
    assert record["usage"]["total_tokens"] == 56
    assert record["model"] == state.maintenance_episodes[episode_id]["request"].model
    assert record["reasoning"] == "none"
    assert [event] = proposal.events
    assert event.kind == "context.compacted"
    assert event["checkpoint_id"] == record["checkpoint_id"]
    assert event["source_excerpted"] == false
    refute Map.has_key?(event, "summary")
    refute Map.has_key?(event, "source_digest")
    {next, rows, all_events} = commit(state, proposal, events)
    assert next.checkpoints[candidate.checkpoint_id] == record
    assert next.active_checkpoint == candidate.checkpoint_id
    assert next.maintenance_episodes[episode_id]["stage"] == "checkpoint_committed"
    assert next.active_maintenance == episode_id
    assert next.pending_work == state.pending_work
    assert next.charged == state.charged
    assert next.conversation == state.conversation
    assert SessionState.lineage_elements(next, run) == raw

    assert SessionState.elements(next, hd(next.run_order)) ==
             SessionState.elements(state, hd(state.run_order))

    assert {:ok, entries, nil} = SessionState.projected_lineage(next, run, 0)

    assert entries == [
             candidate.entry
             | Enum.map(Enum.drop(raw, 1), fn element ->
                 {Loopex.Conversation.source_reference(element),
                  %{"role" => "user", "content" => element.content}}
               end)
           ]

    assert {:ok, units} = SessionState.compaction_units(next, run)
    assert Enum.flat_map(units, & &1.elements) == Enum.drop(raw, 1)

    assert {:ok, candidate_after} =
             SessionState.reference_model_candidate(
               next,
               ordinary_staging(next),
               [],
               ordinary_project(),
               nil
             )

    assert candidate_after.request == candidate.after.request

    assert candidate_after.receipt ==
             candidate.after.record["context_receipt"] |> Map.put("record_byte_cost", 0)

    assert {:error, :maintenance_active} =
             SessionState.preflight_model_request(next, run, candidate_after.request)

    assert {:error, :no_pending_maintenance_checkpoint} =
             SessionState.propose_maintenance_checkpoint(next, 2_000, fn -> :ok end)

    assert {:ok, recovered} = SessionState.recover(state.session_id, history ++ rows, all_events)
    assert recovered == next

    assert {:error, :private_public_projection_mismatch} =
             SessionState.recover(state.session_id, history ++ rows, events)

    assert {:error, :private_public_projection_mismatch} =
             SessionState.recover(state.session_id, history, all_events)
  end

  test "checkpoint replay rejects forged coverage summary metadata charge and event" do
    {state, history, events} = pending_checkpoint(String.duplicate("o", 3_000))
    {:ok, proposal} = SessionState.propose_maintenance_checkpoint(state, 2_000, fn -> :ok end)
    {_next, rows, all_events} = commit(state, proposal, events)
    [record] = proposal.records

    mutations = [
      Map.put(record, "extra", true),
      Map.put(record, "checkpoint_id", "forged"),
      Map.put(record, "episode_id", "forged"),
      Map.put(record, "run_id", "forged"),
      Map.put(record, "summary_ordinal", 2),
      Map.put(record, "committed_at", 61_001),
      Map.put(record, "lineage", %{"session_id" => state.session_id, "through_run_id" => "forged"}),
      put_in(record, ["covered_range", "digest"], String.duplicate("0", 64)),
      put_in(record, ["consumed_range", "unit_count"], 2),
      Map.put(record, "prior_checkpoint_id", record["checkpoint_id"]),
      put_in(record, ["summary", "summary"], "rewritten"),
      put_in(record, ["summary", "source_excerpted"], true),
      Map.put(record, "strategy", "forged"),
      Map.put(record, "strategy_revision", 4),
      Map.put(record, "model", "forged"),
      Map.put(record, "reasoning", "high"),
      Map.put(record, "configuration_version", 2),
      put_in(record, ["usage", "total_tokens"], 57),
      Map.put(record, "source_digest", String.duplicate("0", 64))
    ]

    for forged <- mutations do
      assert {:error, :invalid_compaction_checkpoint_transition} =
               SessionState.recover(
                 state.session_id,
                 history ++ [%{hd(rows) | payload: forged}],
                 all_events
               )
    end

    forged_events = List.update_at(all_events, -1, &Map.put(&1, "source_excerpted", true))

    assert {:error, :private_public_projection_mismatch} =
             SessionState.recover(state.session_id, history ++ rows, forged_events)

    duplicate = %{hd(rows) | journal_version: hd(rows).journal_version + 1}

    assert {:error, :invalid_compaction_checkpoint_transition} =
             SessionState.recover(state.session_id, history ++ rows ++ [duplicate], all_events)
  end

  test "successor commits a settled checkpoint without another summary charge or attempt" do
    {state, history, events} = pending_checkpoint(String.duplicate("o", 3_000))
    owner = owner_advance(state)
    {:ok, successor} = SessionState.recover(state.session_id, history ++ [owner], events)
    {:ok, original} = SessionState.propose_maintenance_checkpoint(state, 2_000, fn -> :ok end)
    {:ok, proposal} = SessionState.propose_maintenance_checkpoint(successor, 2_000, fn -> :ok end)
    assert proposal.records == original.records
    assert proposal.events == original.events
    refute proposal.tx_id == original.tx_id
    {next, rows, all_events} = commit(successor, proposal, events)

    assert {:ok, recovered} =
             SessionState.recover(state.session_id, history ++ [owner] ++ rows, all_events)

    assert recovered == next
    assert recovered.charged == state.charged
    assert recovered.maintenance_episodes[state.active_maintenance]["attempts"] == 1
    assert recovered.maintenance_episodes[state.active_maintenance]["usage"]["attempts"] == 1
  end

  test "fitted checkpoint completion releases ordinary staging without ending the run or recharging" do
    {state, history, events} = pending_checkpoint(String.duplicate("o", 3_000))
    run = state.active_run_id
    episode_id = state.active_maintenance
    {:ok, checkpoint} = SessionState.propose_maintenance_checkpoint(state, 2_000, fn -> :ok end)
    {state, rows, events} = commit(state, checkpoint, events)
    history = history ++ rows

    assert {:ok, completed} =
             SessionState.propose_maintenance_checkpoint_completion(state, 2_001, fn -> :ok end)

    assert [terminal] = completed.records

    assert terminal["result"] == %{
             "disposition" => "checkpointed",
             "checkpoint_id" => state.active_checkpoint,
             "failure" => nil,
             "cleanup" => "confirmed",
             "usage" => state.maintenance_episodes[episode_id]["usage"]
           }

    assert completed.events == []
    {next, rows, events} = commit(state, completed, events)
    assert next.active_maintenance == nil
    assert next.active_run_id == run
    assert next.maintenance_episodes[episode_id]["stage"] == "settled"
    assert next.charged == state.charged
    assert next.conversation == state.conversation
    assert {:ok, recovered} = SessionState.recover(state.session_id, history ++ rows, events)
    assert recovered == next
    assert :ok == SessionState.preflight_run_history(next, run)

    {:ok, candidate} =
      SessionState.reference_model_candidate(
        next,
        ordinary_staging(next),
        [],
        %{
          "class" => "project_resource",
          "receipt_revision" => 2,
          "disposition" => "no_manifest",
          "detail" => %{}
        },
        nil
      )

    assert {:ok, ordinary} =
             SessionState.propose_model_request(next, run, candidate.request,
               context_receipt: candidate.receipt,
               lineage_projection: candidate.projection
             )

    {next, ordinary_rows, ordinary_events} = commit(next, ordinary, events)

    assert {:ok, replayed} =
             SessionState.recover(
               state.session_id,
               history ++ rows ++ ordinary_rows,
               ordinary_events
             )

    assert replayed == next
    assert replayed.charged == state.charged
    assert replayed.pending_work[run].request.messages == candidate.request.messages

    for changed <- [
          put_in(terminal, ["result", "usage", "total_tokens"], 57),
          Map.put(terminal, "observed_at", 61_001),
          put_in(terminal, ["result", "checkpoint_id"], "forged")
        ] do
      assert {:error, :invalid_maintenance_episode_transition} =
               SessionState.recover(
                 state.session_id,
                 history ++ [%{hd(rows) | payload: changed}],
                 events
               )
    end
  end

  test "partial committed checkpoint remains useful and cannot fabricate successful completion" do
    {state, history, events} =
      pending_checkpoint(String.duplicate("o", 3_000),
        current_content: String.duplicate("p", 33_000),
        context_token_budget: 16_384
      )

    {:ok, proposal} = SessionState.propose_maintenance_checkpoint(state, 2_000, fn -> :ok end)
    {next, rows, events} = commit(state, proposal, events)

    assert {:error, {:checkpoint_requires_more_progress, refusal}} =
             SessionState.propose_maintenance_checkpoint_completion(next, 2_001, fn -> :ok end)

    assert refusal["dimension"] == "context_record_bytes"
    assert refusal["observed"] > 65_536
    assert next.active_checkpoint != nil
    assert next.active_maintenance == state.active_maintenance
    assert {:ok, recovered} = SessionState.recover(state.session_id, history ++ rows, events)
    assert recovered == next

    {:ok, abort} =
      SessionState.propose(next, %{
        type: :abort,
        command_id: "partial-abort",
        run_id: next.active_run_id
      })

    {aborted, abort_rows, abort_events} = commit(next, abort, events)

    assert {:error, :maintenance_not_quiescent} =
             SessionState.propose_maintenance_checkpoint_completion(aborted, 2_001, fn -> :ok end)

    assert {:ok, ending} =
             SessionState.propose_run_terminal(aborted, aborted.active_run_id, "cancelled", %{})

    assert hd(ending.records)["result"]["checkpoint_id"] == next.active_checkpoint
    {ended, ending_rows, ending_events} = commit(aborted, ending, abort_events)
    assert ended.active_checkpoint == next.active_checkpoint
    assert ended.checkpoints == next.checkpoints
    assert ended.charged == next.charged

    assert {:ok, ^ended} =
             SessionState.recover(
               state.session_id,
               history ++ rows ++ abort_rows ++ ending_rows,
               ending_events
             )
  end

  test "a second prefix inherits the checkpoint and authenticates cumulative original coverage" do
    {state, history, events} =
      pending_checkpoint(String.duplicate("old", 10_000),
        later_old_units: [String.duplicate("later", 2_000)],
        ordinary_body: String.duplicate("s", 10_000),
        system_class_tokens: 4_000,
        context_token_budget: 4_000
      )

    episode = state.active_maintenance
    raw = state.conversation
    {:ok, first} = SessionState.propose_maintenance_checkpoint(state, 2_000, fn -> :ok end)
    {state, rows, events} = commit(state, first, events)
    history = history ++ rows
    prior = state.checkpoints[state.active_checkpoint]
    assert prior["summary"]["source_excerpted"] == true

    assert {:error, {:checkpoint_requires_more_progress, _}} =
             SessionState.propose_maintenance_checkpoint_completion(state, 2_001, fn -> :ok end)

    assert {:ok, request} =
             SessionState.propose_maintenance_request(state, 1, 2_001, fn -> :ok end)

    assert [record, opened] = request.records
    assert record["summary_ordinal"] == 2
    assert opened["attempt"] == 1
    refute record["operation_id"] == state.maintenance_episodes[episode]["operation_id"]
    assert record["request"]["deadline"] == state.deadlines[state.active_run_id]
    assert record["configuration_version"] == prior["configuration_version"]

    assert record["captured_session_version"] ==
             state.maintenance_episodes[episode]["session_version"]

    assert record["covered_range"]["first"] == prior["covered_range"]["first_kept"]
    assert record["source_excerpted"] == false

    assert {:ok, source} =
             Frame.decode(Enum.at(record["request"]["messages"], 1)["content"], 16_384)

    assert source["prior_checkpoint"] == prior["summary"]
    assert source["messages"]["kind"] == "complete"

    assert source["messages"]["value"] == [
             %{"role" => "user", "content" => String.duplicate("later", 2_000)}
           ]

    {state, rows, events} = commit(state, request, events)
    history = history ++ rows
    assert state.maintenance_episodes[episode]["attempts"] == 2
    assert state.maintenance_episodes[episode]["summary_ordinal"] == 2
    refute Map.has_key?(state.maintenance_episodes[episode], "settlement")
    refute Map.has_key?(state.maintenance_episodes[episode], "summary")

    {:ok, settlement} =
      SessionState.propose_maintenance_attempt_settled(
        state,
        {:reply, summary_reply(state.maintenance_episodes[episode]["request"])}
      )

    {state, rows, events} = commit(state, settlement, events)
    history = history ++ rows
    {:ok, second} = SessionState.propose_maintenance_checkpoint(state, 2_002, fn -> :ok end)
    assert [checkpoint] = second.records
    assert checkpoint["prior_checkpoint_id"] == prior["checkpoint_id"]
    assert checkpoint["consumed_range"] == record["covered_range"]
    assert checkpoint["covered_range"]["unit_count"] == 2
    assert checkpoint["covered_range"]["first"] == prior["covered_range"]["first"]
    assert checkpoint["covered_range"]["digest"] == independent_coverage(state, 2)
    assert checkpoint["covered_range"]["digest"] != prior["covered_range"]["digest"]
    assert checkpoint["summary"]["source_excerpted"] == true
    assert checkpoint["usage"]["attempts"] == 2
    assert checkpoint["usage"]["total_tokens"] == 112
    {state, rows, events} = commit(state, second, events)
    history = history ++ rows
    assert state.conversation == raw
    assert MapSet.size(state.compacted_sources) == 2
    assert {:ok, entries, nil} = SessionState.projected_lineage(state, state.active_run_id, 0)
    assert length(entries) == 2
    assert elem(hd(entries), 0)["checkpoint_id"] == checkpoint["checkpoint_id"]
    assert elem(List.last(entries), 1)["content"] == "protected"

    assert {:ok, completed} =
             SessionState.propose_maintenance_checkpoint_completion(state, 2_003, fn -> :ok end)

    {state, rows, events} = commit(state, completed, events)
    history = history ++ rows
    assert state.active_maintenance == nil
    assert state.active_run_id != nil
    assert state.charged[state.active_run_id].tokens == 112
    assert {:ok, ^state} = SessionState.recover(state.session_id, history, events)
  end

  test "further checkpoint replay refuses changed prior identity raw cuts and cumulative digests" do
    {state, history, events} =
      pending_checkpoint(String.duplicate("o", 30_000),
        later_old_units: [String.duplicate("p", 30_000)]
      )

    {:ok, first} = SessionState.propose_maintenance_checkpoint(state, 2_000, fn -> :ok end)
    {state, rows, events} = commit(state, first, events)
    history = history ++ rows
    {:ok, request} = SessionState.propose_maintenance_request(state, 1, 2_001, fn -> :ok end)
    {state, rows, events} = commit(state, request, events)
    history = history ++ rows

    {:ok, settlement} =
      SessionState.propose_maintenance_attempt_settled(
        state,
        {:reply, summary_reply(state.maintenance_episodes[state.active_maintenance]["request"])}
      )

    {state, rows, events} = commit(state, settlement, events)
    history = history ++ rows
    {:ok, second} = SessionState.propose_maintenance_checkpoint(state, 2_002, fn -> :ok end)
    {_next, [row], all_events} = commit(state, second, events)
    record = row.payload

    for forged <- [
          Map.put(record, "prior_checkpoint_id", nil),
          Map.put(record, "prior_checkpoint_id", record["checkpoint_id"]),
          Map.put(record, "covered_range", record["consumed_range"]),
          Map.put(record, "consumed_range", record["covered_range"]),
          put_in(record, ["covered_range", "digest"], record["consumed_range"]["digest"]),
          put_in(record, ["consumed_range", "first"], record["covered_range"]["first"]),
          put_in(record, ["summary", "source_excerpted"], false),
          Map.put(record, "summary_ordinal", 1),
          put_in(record, ["usage", "total_tokens"], 56)
        ] do
      assert {:error, :invalid_compaction_checkpoint_transition} =
               SessionState.recover(
                 state.session_id,
                 history ++ [%{row | payload: forged}],
                 all_events
               )
    end
  end

  test "a later nonprogress ending retains the useful prior checkpoint and charges each reply once" do
    {state, history, events} =
      pending_checkpoint(String.duplicate("o", 30_000),
        later_old_units: ["tiny"],
        current_content: String.duplicate("p", 33_000),
        context_token_budget: 16_384
      )

    {:ok, checkpoint} = SessionState.propose_maintenance_checkpoint(state, 2_000, fn -> :ok end)
    {state, rows, events} = commit(state, checkpoint, events)
    history = history ++ rows
    prior = state.active_checkpoint
    {:ok, request} = SessionState.propose_maintenance_request(state, 1, 2_001, fn -> :ok end)
    {state, rows, events} = commit(state, request, events)
    history = history ++ rows

    reply =
      state.maintenance_episodes[state.active_maintenance]["request"]
      |> summary_reply()
      |> Map.put(
        :text,
        summary_json(%{summary_output() | "summary" => String.duplicate("g", 1_000)})
      )

    {:ok, settlement} = SessionState.propose_maintenance_attempt_settled(state, {:reply, reply})
    {state, rows, events} = commit(state, settlement, events)
    history = history ++ rows

    assert {:error, :compaction_no_progress} =
             SessionState.propose_maintenance_checkpoint(state, 2_002, fn -> :ok end)

    assert {:ok, ending} =
             SessionState.propose_maintenance_nonprogress(state, 2_002, fn -> :ok end)

    assert [prefix, refusal, _terminal] = ending.records
    assert prefix["result"]["checkpoint_id"] == prior
    assert prefix["result"]["usage"]["total_tokens"] == 112
    assert refusal["session_message_count"] == 3
    {next, rows, events} = commit(state, ending, events)
    assert next.active_checkpoint == prior
    assert next.checkpoints == state.checkpoints
    assert next.conversation == state.conversation
    assert next.charged[state.active_run_id].tokens == 112
    assert {:ok, ^next} = SessionState.recover(state.session_id, history ++ rows, events)
  end

  test "fitted checkpoints cannot open a summary-only cycle and physical retries spend the episode ceiling" do
    {fit, _, events} = pending_checkpoint(String.duplicate("o", 3_000))
    {:ok, proposal} = SessionState.propose_maintenance_checkpoint(fit, 2_000, fn -> :ok end)
    {fit, _, _} = commit(fit, proposal, events)

    assert {:error, :maintenance_targets_fit} =
             SessionState.propose_maintenance_request(fit, 1, 2_001, fn -> :ok end)

    {state, history, events} =
      pending_checkpoint(String.duplicate("o", 10_000),
        later_old_units: List.duplicate(String.duplicate("o", 10_000), 3),
        ordinary_body: String.duplicate("s", 10_000),
        system_class_tokens: 4_000,
        context_token_budget: 4_000,
        retry_not_sent: true
      )

    {state, history, events} =
      Enum.reduce(1..3, {state, history, events}, fn ordinal, {state, history, events} ->
        {:ok, checkpoint} =
          SessionState.propose_maintenance_checkpoint(state, 2_000 + ordinal * 2, fn -> :ok end)

        {state, rows, events} = commit(state, checkpoint, events)
        history = history ++ rows
        assert state.maintenance_episodes[state.active_maintenance]["attempts"] == ordinal + 1
        assert state.maintenance_episodes[state.active_maintenance]["summary_ordinal"] == ordinal

        if ordinal == 3 do
          {state, history, events}
        else
          {:ok, request} =
            SessionState.propose_maintenance_request(state, 1, 2_001 + ordinal * 2, fn -> :ok end)

          {state, rows, events} = commit(state, request, events)
          history = history ++ rows

          {:ok, settlement} =
            SessionState.propose_maintenance_attempt_settled(
              state,
              {:reply,
               summary_reply(state.maintenance_episodes[state.active_maintenance]["request"])}
            )

          {state, rows, events} = commit(state, settlement, events)
          {state, history ++ rows, events}
        end
      end)

    assert state.maintenance_episodes[state.active_maintenance]["usage"] == %{
             "attempts" => 4,
             "reported_tokens" => 168,
             "estimated_tokens" => 0,
             "total_tokens" => 168
           }

    assert {:error, :maintenance_attempts_exhausted} =
             SessionState.propose_maintenance_request(state, 1, 2_008, fn ->
               flunk("spent episode entered preparation")
             end)

    assert state.active_checkpoint != nil
    assert state.charged[state.active_run_id].tokens == 168
    assert {:ok, ^state} = SessionState.recover(state.session_id, history, events)

    assert {:error, :run_deadline_reached} =
             SessionState.propose_maintenance_request(state, 1, 61_001, fn ->
               flunk("elapsed parent entered exhausted-episode preparation")
             end)

    {:ok, abort} = SessionState.propose(state, %{type: :abort, command_id: "exhausted-abort"})
    {aborted, _, _} = commit(state, abort, events)

    assert {:error, :maintenance_not_quiescent} =
             SessionState.propose_maintenance_request(aborted, 1, 2_008, fn ->
               flunk("cancelled parent entered exhausted-episode preparation")
             end)

    assert {:error, :maintenance_not_quiescent} =
             SessionState.propose_maintenance_exhaustion(aborted, 2_008, fn ->
               flunk("cancelled parent entered exhaustion measurement")
             end)

    assert {:error, :run_deadline_reached} =
             SessionState.propose_maintenance_exhaustion(state, 61_001, fn ->
               flunk("elapsed parent entered exhaustion measurement")
             end)

    assert {:ok, ending} =
             SessionState.propose_maintenance_exhaustion(state, 2_008, fn -> :ok end)

    assert [prefix, refusal, terminal] = ending.records
    assert prefix["result"]["checkpoint_id"] == state.active_checkpoint
    assert prefix["result"]["usage"]["attempts"] == 4
    assert prefix["result"]["usage"]["total_tokens"] == 168
    assert prefix["result"]["failure"] == refusal["failure"]
    assert refusal["episode_id"] == state.active_maintenance
    assert refusal["projection_state"] == "measured"
    assert refusal["measurement_scope"] == "ordinary"
    assert refusal["failure"]["category"] == "context_budget_exceeded"
    assert refusal["failure"]["dimension"] == "context_tokens"
    assert refusal["failure"]["limit"] == 4_000
    assert refusal["failure"]["hard_limit"] == 4_000
    assert refusal["failure"]["observed"] == refusal["provider_estimated_tokens"]
    assert refusal["provider_estimated_tokens"] > 4_000
    assert refusal["system_message_count"] == 1
    assert refusal["session_message_count"] == 3
    assert terminal["outcome"] == "failed"
    assert terminal["failure"] == refusal["failure"]
    assert {:ok, ^refusal, bytes} = Store.normalize_and_measure_item(:record, refusal)
    assert bytes == byte_size(:erlang.term_to_binary(refusal, [:deterministic]))

    {next, [prefix_row, refusal_row, terminal_row] = rows, all_events} =
      commit(state, ending, events)

    assert next.active_maintenance == nil
    assert next.active_run_id == nil
    assert next.active_checkpoint == state.active_checkpoint
    assert next.checkpoints == state.checkpoints
    assert next.conversation == state.conversation
    assert next.charged == state.charged
    assert {:ok, ^next} = SessionState.recover(state.session_id, history ++ rows, all_events)

    for {field, value} <- [
          {"provider_estimated_tokens", 0},
          {"episode_id", nil},
          {"session_message_count", 0},
          {"ordered_descriptor_digest", String.duplicate("0", 64)}
        ] do
      altered = %{refusal_row | payload: Map.put(refusal_row.payload, field, value)}

      assert {:error, :invalid_context_refusal} =
               SessionState.recover(
                 state.session_id,
                 history ++ [prefix_row, altered, terminal_row],
                 all_events
               )
    end

    for observed <- [nil, 1_000, 61_001] do
      altered = %{prefix_row | payload: Map.put(prefix_row.payload, "observed_at", observed)}

      assert {:error, _} =
               SessionState.recover(
                 state.session_id,
                 history ++ [altered, refusal_row, terminal_row],
                 all_events
               )
    end
  end

  defp pending_checkpoint(old, options \\ []) do
    {state, history, events} =
      admitted([old] ++ Keyword.get(options, :later_old_units, []), options)

    {:ok, opened} = propose(state, 1)
    {state, rows, events} = commit(state, opened, events)
    history = history ++ rows

    {state, history, events} =
      if Keyword.get(options, :retry_not_sent, false) do
        {:ok, unsent} = SessionState.propose_maintenance_attempt_settled(state, :not_dispatched)
        {state, rows, events} = commit(state, unsent, events)
        history = history ++ rows
        {:ok, retry} = SessionState.propose_maintenance_attempt_open(state)
        {state, rows, events} = commit(state, retry, events)
        {state, history ++ rows, events}
      else
        {state, history, events}
      end

    request = state.maintenance_episodes[state.active_maintenance]["request"]

    reply =
      case Keyword.fetch(options, :summary_text) do
        {:ok, text} ->
          request
          |> summary_reply()
          |> Map.put(:text, summary_json(%{summary_output() | "summary" => text}))

        :error ->
          summary_reply(request)
      end

    {:ok, settled} =
      SessionState.propose_maintenance_attempt_settled(
        state,
        {:reply,
         Map.put(
           reply,
           :usage,
           Keyword.get(options, :usage, %{input_tokens: 37, output_tokens: 19})
         )}
      )

    {state, rows, events} = commit(state, settled, events)
    {state, history ++ rows, events}
  end

  test "source staging binds originals, exact receipt and an adjacent attempt without ordinary work" do
    {state, history, events} = admitted(["early fact 猫", "another fact"])
    parent = state.active_run_id
    assert {:ok, candidate} = preflight(state, 2)
    assert candidate["captured_session_version"] == state.journal_version
    assert candidate["covered_range"]["unit_count"] == 2
    assert candidate["covered_range"]["record_count"] == 2
    assert candidate["covered_range"]["digest"] == independent_coverage(state, 2)
    assert candidate["covered_range"]["first_kept"]["run_id"] == parent
    assert candidate["request"]["deadline"] == 61_001
    assert candidate["request"]["tools"] == []
    assert candidate["request"]["continuation"] == nil
    assert length(candidate["request"]["messages"]) == 2
    assert candidate["request"]["sampling"]["max_tokens"] == 1_024
    receipt = candidate["context_receipt"]
    assert length(receipt["blocks"]) == 2

    assert receipt["project_resource"] == %{
             "class" => "project_resource",
             "receipt_revision" => 2,
             "disposition" => "not_evaluated_maintenance",
             "detail" => nil
           }

    assert receipt["totals"]["by_provenance"]["project_resource"] == %{
             "byte_cost" => 0,
             "token_cost" => 0
           }

    source = Enum.at(candidate["request"]["messages"], 1)["content"]
    assert candidate["source_digest"] == Canonical.digest_bytes(source)
    assert {:ok, decoded} = Frame.decode(source, 16_384)

    assert decoded["messages"]["value"] == [
             %{"role" => "user", "content" => "early fact 猫"},
             %{"role" => "user", "content" => "another fact"}
           ]

    assert {:ok, ^candidate, bytes} = Store.normalize_and_measure_item(:record, candidate)
    assert receipt["record_byte_cost"] == bytes

    assert {:ok, proposal} = propose(state, 2)
    assert [^candidate, opened] = proposal.records
    assert opened.kind == "maintenance_attempt_opened_v1"
    assert opened["episode_id"] == state.active_maintenance
    assert opened["staged_request_digest"] == candidate["staged_request_digest"]
    assert proposal.events == []
    assert proposal.next.pending_work == state.pending_work
    assert proposal.next.conversation == state.conversation
    assert proposal.next.charged == state.charged
    assert proposal.next.deadlines[parent] == 61_001
    episode = proposal.next.maintenance_episodes[state.active_maintenance]
    assert episode["stage"] == "model_attempt_open"
    assert episode["attempts"] == 1
    assert episode["request"].staged_request_digest == candidate["staged_request_digest"]
    refute Map.has_key?(episode, "staged")
    {committed, rows, events} = commit(state, proposal, events)
    assert {:ok, recovered} = SessionState.recover(state.session_id, history ++ rows, events)
    assert recovered.maintenance_episodes == committed.maintenance_episodes
    assert recovered.deadlines == committed.deadlines
    assert recovered.pending_work == state.pending_work

    assert {:error, :maintenance_active} =
             SessionState.preflight_model_request(recovered, parent, %{})

    assert {:error, :invalid_maintenance_episode_transition} =
             SessionState.propose_run_terminal(recovered, parent, "cancelled", %{})
  end

  test "replay rejects partial, interrupted, substituted and duplicate staging pairs" do
    {state, history, events} = admitted(["old"])
    {:ok, proposal} = propose(state, 1)
    {_next, [request, opened] = rows, all_events} = commit(state, proposal, events)

    assert {:error, :incomplete_maintenance_request_pair} ==
             SessionState.recover(state.session_id, history ++ [request], events)

    {:ok, steer} =
      SessionState.propose(state, %{
        type: :steer,
        command_id: "later",
        run_id: state.active_run_id,
        content: "new data"
      })

    {_next, [steer_row], _} = commit(state, steer, events)

    advance = %{
      request
      | owner_epoch: 2,
        owner_incarnation_id: "next",
        payload: %{
          :kind => "owner_advanced",
          "prior_owner_epoch" => 1,
          "owner_epoch" => 2,
          "owner_incarnation_id" => "next",
          "owner_transaction_id" => "next-tx"
        }
    }

    for inserted <- [request, steer_row, advance] do
      assert {:error, :incomplete_maintenance_request_pair} ==
               SessionState.recover(
                 state.session_id,
                 history ++ restamp(state, [request, inserted, opened]),
                 events
               )
    end

    for changed <- [
          put_in(rows, [Access.at(0), :payload, "episode_id"], "other"),
          put_in(rows, [Access.at(0), :payload, "summary_ordinal"], 2),
          put_in(
            rows,
            [Access.at(0), :payload, "captured_session_version"],
            state.journal_version - 1
          ),
          put_in(rows, [Access.at(0), :payload, "strategy_revision"], 2),
          put_in(rows, [Access.at(0), :payload, "source_digest"], String.duplicate("0", 64)),
          put_in(rows, [Access.at(0), :payload, "source_excerpted"], true),
          put_in(
            rows,
            [Access.at(0), :payload, "covered_range", "digest"],
            String.duplicate("0", 64)
          ),
          put_in(rows, [Access.at(0), :payload, "covered_range", "record_count"], 2),
          put_in(rows, [Access.at(0), :payload, "covered_range", "first_kept", "run_id"], "old"),
          put_in(rows, [Access.at(0), :payload, "request", "tools"], [%{}]),
          put_in(rows, [Access.at(0), :payload, "request", "deadline"], 61_002),
          put_in(rows, [Access.at(0), :payload, "context_receipt", "record_byte_cost"], 0),
          put_in(
            rows,
            [
              Access.at(0),
              :payload,
              "context_receipt",
              "blocks",
              Access.at(1),
              "source_reference",
              "source_digest"
            ],
            String.duplicate("0", 64)
          ),
          put_in(
            rows,
            [Access.at(0), :payload, "context_receipt", "project_resource", "disposition"],
            "no_manifest"
          ),
          put_in(rows, [Access.at(0), :payload, "extra"], true),
          update_in(rows, [Access.at(0), :payload], &Map.delete(&1, "covered_range")),
          put_in(rows, [Access.at(1), :payload, "summary_ordinal"], 2),
          put_in(rows, [Access.at(1), :payload, "attempt"], 2),
          put_in(rows, [Access.at(1), :payload, "staged_request_digest"], "other")
        ] do
      assert {:error, _} = SessionState.recover(state.session_id, history ++ changed, all_events)
    end

    assert {:error, _} =
             SessionState.recover(
               state.session_id,
               history ++ restamp(state, [opened, request]),
               events
             )

    assert {:error, _} =
             SessionState.recover(
               state.session_id,
               history ++ restamp(state, rows ++ rows),
               all_events
             )
  end

  test "selection covers whole units with excerpts and cannot cross the current input" do
    {state, _, _} = admitted(["tiny", String.duplicate("猫", 10_000), "later"])
    assert {:ok, record} = preflight(state, 3)
    assert record["source_excerpted"]
    assert record["covered_range"]["unit_count"] == 2
    assert record["covered_range"]["first_kept"]["run_id"] == Enum.at(state.run_order, 2)
    source = Enum.at(record["request"]["messages"], 1)["content"]
    assert {:ok, envelope} = Frame.decode(source, 16_384)
    assert envelope["messages"]["kind"] == "serialized_excerpt"
    assert envelope["messages"]["byte_length"] > 16_384
    assert {:error, :context_projection_invalid} == preflight(state, 4)
    assert {:error, :context_projection_invalid} == preflight(state, 0)
  end

  test "irreducible excerpt commits one replay-checked episode and parent refusal" do
    {state, history, events} =
      admitted([String.duplicate("o", 30_000)],
        context_token_budget: 800,
        system_class_tokens: 800,
        maintenance_body: String.duplicate("i", 2_048)
      )

    assert {:ok, proposal} =
             SessionState.propose_selected_maintenance_request(state, 1_001, fn -> :ok end)

    assert [episode_terminal, refusal, terminal] = proposal.records
    assert episode_terminal.kind == "maintenance_episode_terminal_v1"
    assert episode_terminal["observed_at"] == 1_001
    assert refusal.kind == "context_admission_refused_v2"
    assert refusal["failure"]["cause"] == "compaction_excerpt_budget_too_small"
    assert refusal["measurement_scope"] == nil
    assert refusal["episode_id"] == state.active_maintenance
    assert terminal.kind == "run_terminal_committed"
    assert terminal["failure"] == refusal["failure"]

    {next, rows, events} = commit(state, proposal, events)
    assert {:ok, ^next} = SessionState.recover(state.session_id, history ++ rows, events)

    for changed <- [
          put_in(rows, [Access.at(0), :payload, "observed_at"], 61_000),
          put_in(rows, [Access.at(1), :payload, "failure", "cause"], "compaction_no_progress"),
          put_in(rows, [Access.at(1), :payload, "episode_id"], nil)
        ] do
      assert {:error, _} = SessionState.recover(state.session_id, history ++ changed, events)
    end
  end

  test "a useful checkpoint followed by an irreducible protected tail retains its measured refusal" do
    {state, history, events} =
      pending_checkpoint(String.duplicate("o", 30_000),
        later_old_units: ["later"],
        ordinary_body: String.duplicate("s", 10_000),
        system_class_tokens: 4_000,
        context_token_budget: 4_000,
        summary_text: String.duplicate("g", 4_000)
      )

    assert {:ok, checkpoint} =
             SessionState.propose_maintenance_checkpoint(state, 2_000, fn -> :ok end)

    {state, rows, events} = commit(state, checkpoint, events)
    history = history ++ rows
    prior = state.active_checkpoint

    assert {:error, {:checkpoint_requires_more_progress, _}} =
             SessionState.propose_maintenance_checkpoint_completion(state, 2_001, fn -> :ok end)

    assert {:ok, proposal} =
             SessionState.propose_selected_maintenance_request(state, 2_001, fn -> :ok end)

    assert [episode_terminal, refusal, terminal] = proposal.records
    assert episode_terminal["result"]["checkpoint_id"] == prior
    assert refusal["failure"]["category"] == "context_budget_exceeded"
    assert refusal["failure"]["measurement_scope"] == "ordinary"
    assert refusal["failure"]["dimension"] == "context_tokens"
    assert refusal["episode_id"] == state.active_maintenance
    assert refusal["projection_state"] == "measured"
    assert terminal["failure"] == refusal["failure"]

    {next, rows, events} = commit(state, proposal, events)
    assert next.active_checkpoint == prior
    assert next.checkpoints == state.checkpoints
    assert {:ok, ^next} = SessionState.recover(state.session_id, history ++ rows, events)

    for changed <- [
          update_in(rows, [Access.at(1), :payload, "failure", "observed"], &(&1 + 1)),
          update_in(rows, [Access.at(1), :payload, "session_message_count"], &(&1 + 1)),
          put_in(
            rows,
            [Access.at(0), :payload, "observed_at"],
            state.deadlines[state.active_run_id]
          )
        ] do
      assert {:error, _} = SessionState.recover(state.session_id, history ++ changed, events)
    end
  end

  test "a protected record-byte overflow after a checkpoint keeps the exact measured dimension" do
    {state, history, events} =
      pending_checkpoint(String.duplicate("o", 30_000),
        later_old_units: ["later"],
        current_content: String.duplicate("p", 33_000),
        context_token_budget: 16_384
      )

    assert {:ok, checkpoint} =
             SessionState.propose_maintenance_checkpoint(state, 2_000, fn -> :ok end)

    {state, rows, events} = commit(state, checkpoint, events)
    history = history ++ rows

    assert {:ok, proposal} =
             SessionState.propose_selected_maintenance_request(state, 2_001, fn -> :ok end)

    assert [_episode_terminal, refusal, _run_terminal] = proposal.records
    assert refusal["failure"]["dimension"] == "context_record_bytes"
    assert refusal["record_byte_cost"] == refusal["failure"]["observed"]
    assert refusal["failure"]["observed"] > 65_536

    {next, rows, events} = commit(state, proposal, events)
    assert {:ok, ^next} = SessionState.recover(state.session_id, history ++ rows, events)
  end

  test "an already admitted initial episode retains an irreducible protected numeric refusal" do
    {state, history, events} =
      admitted(["old"],
        current_content: String.duplicate("p", 33_000),
        context_token_budget: 16_384
      )

    assert {:ok, proposal} =
             SessionState.propose_selected_maintenance_request(state, 1_001, fn -> :ok end)

    assert [episode_terminal, refusal, terminal] = proposal.records
    assert episode_terminal["result"]["checkpoint_id"] == nil
    assert refusal["failure"]["dimension"] == "context_record_bytes"
    assert refusal["episode_id"] == state.active_maintenance
    assert terminal["failure"] == refusal["failure"]

    {next, rows, events} = commit(state, proposal, events)
    assert {:ok, ^next} = SessionState.recover(state.session_id, history ++ rows, events)
  end

  test "captured clocks and spending prevent source intent while traversal errors survive" do
    {state, _, _} = admitted([String.duplicate("x", 30_000)])
    run = state.active_run_id

    assert {:error, :compaction_preparation_deadline} ==
             SessionState.preflight_maintenance_request(state, 1, 61_000, fn -> :ok end)

    expired = %{state | deadlines: %{run => 2_000}}

    assert {:error, :run_deadline_reached} ==
             SessionState.preflight_maintenance_request(expired, 1, 2_000, fn -> :ok end)

    cutoff = %{state | deadlines: %{run => 3_000}}
    assert {:ok, record} = preflight(cutoff, 1)
    assert record["request"]["deadline"] == 3_000

    already_charged = put_in(state.charged[run], %{tokens: 5, source: :reported})
    assert {:ok, _} = preflight(already_charged, 1)

    spent = put_in(state.charged[run], %{tokens: 9_000, source: :reported})

    assert {:error, :maintenance_bounds_exhausted} == preflight(spent, 1)

    for cause <- [:compaction_preparation_deadline, :run_deadline_reached, :cancelled] do
      counter = :counters.new(1, [])

      check = fn ->
        :counters.add(counter, 1, 1)
        if :counters.get(counter, 1) < 20, do: :ok, else: {:error, cause}
      end

      assert {:error, ^cause} = SessionState.propose_maintenance_request(state, 1, 1_001, check)
      assert :counters.get(counter, 1) == 20
    end
  end

  test "queued later input cannot alter an already captured source or its range" do
    {state, _, events} = admitted(["keep this"])
    assert {:ok, before} = preflight(state, 1)

    {:ok, steer} =
      SessionState.propose(state, %{
        type: :steer,
        command_id: "steer",
        run_id: state.active_run_id,
        content: "arrived after capture"
      })

    {after_steer, _, _} = commit(state, steer, events)
    assert {:ok, ^before} = preflight(after_steer, 1)
    source = before["covered_range"]["first"]

    forged =
      put_in(state.conversation_record_sources[source].journal_version, state.journal_version)

    assert {:error, :context_projection_invalid} == preflight(forged, 1)

    missing = %{
      state
      | conversation_record_sources: Map.delete(state.conversation_record_sources, source)
    }

    assert {:error, :context_projection_invalid} == preflight(missing, 1)
  end

  defp preflight(state, count),
    do: SessionState.preflight_maintenance_request(state, count, 1_001, fn -> :ok end)

  defp propose(state, count),
    do: SessionState.propose_maintenance_request(state, count, 1_001, fn -> :ok end)

  test "system refusal precedes source traversal and captured resource headers spend record bytes" do
    body = String.duplicate("x", 2_048)

    ceiling =
      Loopex.Bounds.estimate(
        Canonical.encode(%{"role" => "system", "content" => "summary.v1: " <> body})
      )

    {state, history, events} =
      admitted([String.duplicate("o", 30_000)],
        system_class_tokens: ceiling,
        maintenance_body: body
      )

    assert {:refused, refusal} =
             SessionState.preflight_maintenance_request(state, 1, 1_001, fn ->
               flunk("source traversal after system refusal")
             end)

    assert refusal["dimension"] == "system_class_tokens"
    assert refusal["limit"] == ceiling
    assert refusal["observed"] == ceiling
    assert refusal["record_byte_cost"] == nil

    assert {:ok, proposal} =
             SessionState.propose_selected_maintenance_request(state, 1_001, fn -> :ok end)

    assert [episode_terminal, numeric, terminal] = proposal.records
    assert episode_terminal["result"]["failure"] == numeric["failure"]
    assert numeric["failure"]["measurement_scope"] == "maintenance"
    assert numeric["failure"]["dimension"] == "system_class_tokens"
    assert numeric["failure"]["observed"] == ceiling
    assert numeric["provider_estimated_tokens"] == ceiling
    assert numeric["system_message_count"] == 1
    assert numeric["session_message_count"] == 0
    assert numeric["ordered_descriptor_digest"] != nil
    assert numeric["episode_id"] == state.active_maintenance
    assert terminal["failure"] == numeric["failure"]

    {next, rows, events} = commit(state, proposal, events)
    assert {:ok, ^next} = SessionState.recover(state.session_id, history ++ rows, events)

    altered = update_in(rows, [Access.at(1), :payload, "provider_estimated_tokens"], &(&1 + 1))
    assert {:error, _} = SessionState.recover(state.session_id, history ++ altered, events)

    {state, history, events} = admitted(["old"], resources: true)
    assert {:ok, candidate} = preflight(state, 1)
    receipt = candidate["context_receipt"]
    assert map_size(receipt) == 18
    header = receipt["resource_packs"]

    assert header ==
             Loopex.Runtime.ResourceContext.initial_header(
               state.run_resources[state.active_run_id]
             )

    assert header["status"] == "not_evaluated"
    assert header["blocks"] == []

    assert receipt["totals"]["by_provenance"]["resource_pack"] == %{
             "byte_cost" => 0,
             "token_cost" => 0
           }

    assert {:ok, ^candidate, bytes} = Store.normalize_and_measure_item(:record, candidate)
    assert receipt["record_byte_cost"] == bytes

    changed = %{
      state
      | resources: %{state.resources | "manifest_digest" => String.duplicate("b", 64)}
    }

    assert {:ok, ^candidate} = preflight(changed, 1)
    {:ok, proposal} = propose(state, 1)
    {_next, rows, events} = commit(state, proposal, events)
    assert {:ok, _} = SessionState.recover(state.session_id, history ++ rows, events)

    for field <- ["manifest_digest", "selection_digest"] do
      forged =
        put_in(
          rows,
          [Access.at(0), :payload, "context_receipt", "resource_packs", field],
          String.duplicate("c", 64)
        )

      assert {:error, :invalid_maintenance_request_transition} ==
               SessionState.recover(state.session_id, history ++ forged, events)
    end
  end

  test "abort admission prevents any new maintenance intent" do
    {state, _, events} = admitted(["old"])

    {:ok, abort} =
      SessionState.propose(state, %{
        type: :abort,
        command_id: "abort",
        run_id: state.active_run_id
      })

    {state, _, _} = commit(state, abort, events)
    assert {:error, :maintenance_not_quiescent} == propose(state, 1)
  end

  test "successful maintenance settlement charges once without ordinary conversation or events" do
    {state, history, events} = opened()
    episode_id = state.active_maintenance
    run = state.active_run_id
    request = state.maintenance_episodes[episode_id]["request"]

    for usage <- [%{input_tokens: 37, output_tokens: 19}, %{}] do
      raw = %{summary_reply(request) | usage: usage}

      assert {:ok, proposal} =
               SessionState.propose_maintenance_attempt_settled(state, {:reply, raw})

      assert [row] = proposal.records
      assert row.kind == "maintenance_attempt_settled_v3"
      assert proposal.events == []
      {next, rows, all_events} = commit(state, proposal, events)
      expected = if usage == %{}, do: 10_000, else: 56
      source = if usage == %{}, do: :estimated, else: :reported
      assert next.charged[run] == %{tokens: expected, source: source}
      episode = next.maintenance_episodes[episode_id]
      assert episode["stage"] == "checkpoint_pending"
      assert episode["usage"]["attempts"] == 1
      assert episode["usage"]["total_tokens"] == expected
      assert episode["usage"][Atom.to_string(source) <> "_tokens"] == expected
      assert episode["summary"] == summary_output()
      assert episode["checkpoint_id"] == nil
      assert next.pending_work == state.pending_work
      assert next.conversation == state.conversation

      assert {:ok, recovered} =
               SessionState.recover(state.session_id, history ++ rows, all_events)

      assert recovered.maintenance_episodes == next.maintenance_episodes
      assert recovered.charged == next.charged

      assert {:error, :no_open_maintenance_attempt} =
               SessionState.propose_maintenance_attempt_settled(next, {:reply, raw})

      assert {:error, _} =
               SessionState.recover(
                 state.session_id,
                 history ++ restamp(state, rows ++ rows),
                 all_events
               )

      for forged <- [
            Map.put(row, "extra", true),
            Map.put(row, "attempt", 2),
            Map.put(row, "staged_request_digest", "wrong"),
            put_in(row, ["accounting", "input_tokens"], 38)
          ] do
        assert {:error, _} =
                 SessionState.recover(
                   state.session_id,
                   history ++ restamp(state, [%{hd(rows) | payload: forged}]),
                   all_events
                 )
      end
    end
  end

  test "invalid or incomplete summaries retain reported usage and end the parent atomically" do
    {state, history, events} = opened()
    episode_id = state.active_maintenance
    request = state.maintenance_episodes[episode_id]["request"]
    raw = summary_reply(request)

    for {reply, cause} <- [
          {%{raw | completion: "limit"}, "maintenance_summary_incomplete"},
          {%{raw | completion: "unknown"}, "maintenance_summary_incomplete"},
          {%{raw | completion: "unknown", text: "not JSON"}, "maintenance_summary_incomplete"},
          {%{raw | text: "{}"}, "maintenance_summary_invalid"},
          {%{raw | text: summary_json(Map.put(summary_output(), "extra", true))},
           "maintenance_summary_invalid"},
          {%{
             raw
             | text: summary_json(%{summary_output() | "summary" => String.duplicate("x", 4095)})
           }, "maintenance_summary_invalid"},
          {%{raw | tool_calls: [%{id: "call", name: "forbidden", arguments: %{}}]},
           "maintenance_summary_invalid"}
        ] do
      assert {:ok, settlement_proposal} =
               SessionState.propose_maintenance_attempt_settled(state, {:reply, reply})

      assert [settlement] = settlement_proposal.records

      assert settlement["accounting"] == %{
               "source" => "reported",
               "input_tokens" => 37,
               "output_tokens" => 19
             }

      assert settlement_proposal.events == []
      {pending, settled_rows, pending_events} = commit(state, settlement_proposal, events)
      assert pending.maintenance_episodes[episode_id]["stage"] == "checkpoint_pending"
      assert pending.maintenance_episodes[episode_id]["summary_failure"] == cause
      assert pending.charged[state.active_run_id] == %{tokens: 56, source: :reported}

      assert {:ok, pending_replay} =
               SessionState.recover(state.session_id, history ++ settled_rows, pending_events)

      assert pending_replay.maintenance_episodes == pending.maintenance_episodes

      cause_atom =
        if cause == "maintenance_summary_invalid",
          do: :maintenance_summary_invalid,
          else: :maintenance_summary_incomplete

      assert {:ok, proposal} =
               SessionState.propose_context_preparation_failure(
                 pending,
                 state.active_run_id,
                 cause_atom
               )

      assert [prefix, refusal, terminal] = proposal.records
      assert prefix.kind == "maintenance_episode_terminal_v1"
      assert refusal.kind == "context_admission_refused_v2"
      assert refusal["failure"]["cause"] == cause
      assert terminal["failure"] == refusal["failure"]
      assert prefix["result"]["usage"]["total_tokens"] == 56
      {next, rows, all_events} = commit(pending, proposal, pending_events)
      assert next.active_run_id == nil
      assert next.active_maintenance == nil
      assert next.charged == pending.charged
      assert next.conversation == state.conversation
      assert next.maintenance_episodes[episode_id]["usage"]["attempts"] == 1

      assert {:ok, recovered} =
               SessionState.recover(state.session_id, history ++ settled_rows ++ rows, all_events)

      assert recovered.charged == next.charged
      assert recovered.maintenance_episodes == next.maintenance_episodes

      for broken <- [
            Enum.take(rows, 1),
            Enum.take(rows, 2),
            Enum.drop(rows, 1),
            put_in(rows, [Access.at(0), :payload, "result", "usage", "total_tokens"], 57),
            put_in(
              rows,
              [Access.at(2), :payload, "failure", "cause"],
              "maintenance_summary_incomplete_changed"
            )
          ] do
        assert {:error, _} =
                 SessionState.recover(
                   state.session_id,
                   history ++ settled_rows ++ restamp(pending, broken),
                   all_events
                 )
      end
    end
  end

  test "abort or deadline after canonical settlement wins before any checkpoint or summary refusal" do
    {state, history, events} = opened()
    run = state.active_run_id
    request = state.maintenance_episodes[state.active_maintenance]["request"]

    for text <- [summary_reply(request).text, "{}"] do
      {:ok, settled} =
        SessionState.propose_maintenance_attempt_settled(
          state,
          {:reply, %{summary_reply(request) | text: text}}
        )

      {pending, rows, settled_events} = commit(state, settled, events)
      settled_history = history ++ rows

      assert pending.maintenance_episodes[state.active_maintenance]["stage"] ==
               "checkpoint_pending"

      for ending <- [:abort, :deadline] do
        {pending, ending_history, ending_events} =
          if ending == :abort do
            {:ok, abort} =
              SessionState.propose(pending, %{
                type: :abort,
                command_id: "pending-abort",
                run_id: run
              })

            {next, rows, all_events} = commit(pending, abort, settled_events)

            assert {:error, :invalid_context_refusal} =
                     SessionState.propose_context_preparation_failure(
                       next,
                       run,
                       :maintenance_summary_invalid
                     )

            {next, settled_history ++ rows, all_events}
          else
            {pending, settled_history, settled_events}
          end

        ending_proposal =
          if ending == :abort do
            SessionState.propose_run_terminal(pending, run, "cancelled", %{})
          else
            SessionState.propose_run_terminal(pending, run, "bound_reached", %{
              bound: "deadline",
              observed: request.deadline,
              declared_limit: request.deadline,
              accounting_source: "reported"
            })
          end

        assert {:ok, terminal} = ending_proposal
        assert [prefix, _terminal] = terminal.records
        assert prefix["result"]["checkpoint_id"] == nil
        assert prefix["result"]["usage"]["total_tokens"] == 56
        {next, rows, all_events} = commit(pending, terminal, ending_events)
        assert next.charged == pending.charged

        assert {:ok, recovered} =
                 SessionState.recover(state.session_id, ending_history ++ rows, all_events)

        assert recovered.maintenance_episodes == next.maintenance_episodes
        assert recovered.active_maintenance == nil
      end
    end
  end

  test "only a proven not-dispatched first attempt permits the exact retained retry" do
    {state, history, events} = opened()
    episode_id = state.active_maintenance
    request = state.maintenance_episodes[episode_id]["request"]
    assert {:ok, first} = SessionState.propose_maintenance_attempt_settled(state, :not_dispatched)
    assert [row] = first.records
    assert row["next"] == "retry"
    {retry, rows, events} = commit(state, first, events)
    history = history ++ rows
    assert retry.maintenance_episodes[episode_id]["usage"]["attempts"] == 1
    assert retry.maintenance_episodes[episode_id]["usage"]["total_tokens"] == 0
    assert retry.charged == state.charged
    assert {:ok, second} = SessionState.propose_maintenance_attempt_open(retry)
    {second, rows, events} = commit(retry, second, events)
    history = history ++ rows
    assert second.maintenance_episodes[episode_id]["request"] == request
    assert second.deadlines == state.deadlines
    assert second.pending_work == state.pending_work

    for outcome <- [:not_dispatched, {:reply, summary_reply(request)}] do
      assert {:ok, final} = SessionState.propose_maintenance_attempt_settled(second, outcome)
      {next, rows, all_events} = commit(second, final, events)
      assert next.maintenance_episodes[episode_id]["usage"]["attempts"] == 2
      assert next.maintenance_episodes[episode_id]["attempts"] == 2

      assert next.maintenance_episodes[episode_id]["usage"]["total_tokens"] ==
               if(outcome == :not_dispatched, do: 0, else: 56)

      assert {:error, :no_retry_permitted} = SessionState.propose_maintenance_attempt_open(next)

      assert {:ok, recovered} =
               SessionState.recover(state.session_id, history ++ rows, all_events)

      assert recovered.maintenance_episodes == next.maintenance_episodes
    end

    {limited, _, limited_events} = admitted(["old"], max_turns: 1)
    {:ok, staged} = propose(limited, 1)
    {limited, _, limited_events} = commit(limited, staged, limited_events)
    {:ok, not_sent} = SessionState.propose_maintenance_attempt_settled(limited, :not_dispatched)
    {limited, _, _} = commit(limited, not_sent, limited_events)

    assert {:error, :maintenance_bounds_exhausted} =
             SessionState.propose_maintenance_attempt_open(limited)
  end

  test "the first admitted abort or deadline wins while late replies retain usage only" do
    {state, history, events} = opened()
    episode_id = state.active_maintenance
    request = state.maintenance_episodes[episode_id]["request"]

    for order <- [:deadline_first, :abort_first] do
      {terminated, history, events} =
        if order == :deadline_first do
          assert {:ok, deadline} =
                   SessionState.propose_maintenance_termination(state, request.deadline)

          {next, rows, events} = commit(state, deadline, events)
          {next, history ++ rows, events}
        else
          {state, history, events}
        end

      assert {:ok, abort} =
               SessionState.propose(terminated, %{
                 type: :abort,
                 command_id: "late-abort",
                 run_id: state.active_run_id
               })

      {terminated, rows, events} = commit(terminated, abort, events)
      history = history ++ rows
      winner = if order == :deadline_first, do: "deadline", else: "abort"
      assert terminated.maintenance_episodes[episode_id]["model_termination"] == winner

      assert {:error, :no_open_maintenance_attempt} =
               SessionState.propose_maintenance_termination(terminated, request.deadline + 1)

      for outcome <- [{:reply, summary_reply(request)}, :owner_loss] do
        assert {:ok, proposal} =
                 SessionState.propose_maintenance_attempt_settled(terminated, outcome)

        assert [prefix, settlement, terminal] = proposal.records
        assert settlement["termination"] == winner

        assert settlement["conversation"] ==
                 if(outcome == :owner_loss, do: "none", else: "evidence_only")

        assert terminal["outcome"] ==
                 if(winner == "deadline", do: "bound_reached", else: "cancelled")

        assert prefix["result"]["checkpoint_id"] == nil
        {next, rows, all_events} = commit(terminated, proposal, events)
        assert next.conversation == state.conversation

        assert {:ok, recovered} =
                 SessionState.recover(state.session_id, history ++ rows, all_events)

        assert recovered.maintenance_episodes == next.maintenance_episodes
        assert recovered.charged == next.charged
      end
    end
  end

  test "insufficient summary reserve fails atomically with honest charge and exact replay" do
    for remaining <- [1, 500, 1_023] do
      charge = 10_000 - remaining

      {state, history, events} =
        pending_checkpoint(String.duplicate("a", 30_000),
          later_old_units: [String.duplicate("b", 30_000)],
          usage: %{input_tokens: charge - 1, output_tokens: 1}
        )

      assert {:ok, checkpoint} =
               SessionState.propose_maintenance_checkpoint(state, 2_000, fn -> :ok end)

      {state, checkpoint_rows, events} = commit(state, checkpoint, events)
      history = history ++ checkpoint_rows

      run = state.active_run_id
      episode = state.active_maintenance

      assert {:error, :maintenance_bounds_exhausted} =
               SessionState.propose_selected_maintenance_request(state, 2_001, fn -> :ok end)

      assert {:ok, proposal} = SessionState.propose_maintenance_parent_bound(state, run)
      assert [prefix, refusal, terminal] = proposal.records
      assert prefix.kind == "maintenance_episode_terminal_v1"
      assert refusal.kind == "context_admission_refused_v2"

      assert refusal["failure"] == %{
               "version" => 2,
               "category" => "context_preparation_failed",
               "retryable" => false,
               "measurement_scope" => nil,
               "cause" => "maintenance_reply_reserve_unavailable"
             }

      assert terminal["outcome"] == "failed"
      assert terminal["failure"] == refusal["failure"]
      assert prefix["result"]["usage"]["total_tokens"] == charge
      assert prefix["result"]["checkpoint_id"] == state.active_checkpoint
      {next, rows, final_events} = commit(state, proposal, events)
      assert next.charged[run] == %{tokens: charge, source: :reported}
      assert next.active_run_id == nil
      assert next.active_maintenance == nil
      assert next.maintenance_episodes[episode]["usage"]["total_tokens"] == charge
      assert {:ok, ^next} = SessionState.recover(state.session_id, history ++ rows, final_events)

      for incomplete <- [Enum.take(rows, 1), Enum.take(rows, 2), Enum.drop(rows, 1)] do
        assert {:error, _} =
                 SessionState.recover(state.session_id, history ++ incomplete, final_events)
      end
    end
  end

  test "summary reserve refusal cannot override reached bounds or invent insufficient capacity" do
    for {charge, turns, expected} <- [
          {8_976, 8, nil},
          {9_500, 1, "max_turns"},
          {10_000, 8, "token_budget"}
        ] do
      {state, history, events} =
        pending_checkpoint("small",
          max_turns: turns,
          usage: %{input_tokens: charge - 1, output_tokens: 1}
        )

      run = state.active_run_id

      assert {:error, :invalid_context_refusal} =
               SessionState.propose_context_preparation_failure(
                 state,
                 run,
                 :maintenance_reply_reserve_unavailable
               )

      case expected do
        nil ->
          assert {:error, :maintenance_bounds_not_reached} =
                   SessionState.propose_maintenance_parent_bound(state, run)

          assert {:error, :compaction_no_progress} =
                   SessionState.preflight_maintenance_checkpoint(state, 2_000, fn -> :ok end)

        bound ->
          assert {:ok, proposal} = SessionState.propose_maintenance_parent_bound(state, run)
          assert [_, terminal] = proposal.records
          assert terminal["outcome"] == "bound_reached"
          assert terminal["bound"] == bound
          {next, rows, final_events} = commit(state, proposal, events)

          assert {:ok, ^next} =
                   SessionState.recover(state.session_id, history ++ rows, final_events)
      end
    end
  end

  test "a fitted checkpoint cannot claim an unnecessary reply-reserve failure" do
    {state, _, events} =
      pending_checkpoint(String.duplicate("a", 3_000),
        usage: %{input_tokens: 9_000, output_tokens: 500}
      )

    assert {:ok, checkpoint} =
             SessionState.propose_maintenance_checkpoint(state, 2_000, fn -> :ok end)

    {state, _, _} = commit(state, checkpoint, events)

    assert {:ok, _} =
             SessionState.propose_maintenance_checkpoint_completion(state, 2_001, fn -> :ok end)

    assert {:error, :invalid_context_refusal} =
             SessionState.propose_context_preparation_failure(
               state,
               state.active_run_id,
               :maintenance_reply_reserve_unavailable
             )
  end

  test "owner loss and malformed replies charge the remaining allowance without retry or checkpoint" do
    {state, history, events} = opened()
    episode_id = state.active_maintenance
    request = state.maintenance_episodes[episode_id]["request"]
    raw = summary_reply(request)

    for outcome <- [
          :owner_loss,
          {:reply, Map.put(raw, :extra, true)},
          {:reply, Map.drop(raw, [:completion, :continuation])},
          {:reply, Map.delete(raw, :completion)},
          {:reply, Map.delete(raw, :continuation)},
          {:reply, Map.delete(raw, :provider_response_id)}
        ] do
      assert {:ok, proposal} = SessionState.propose_maintenance_attempt_settled(state, outcome)
      assert [prefix, settlement, terminal] = proposal.records
      assert settlement["accounting"]["source"] == "estimated"
      assert prefix["result"]["usage"]["estimated_tokens"] == 10_000
      assert prefix["result"]["usage"]["reported_tokens"] == 0

      if match?({:reply, _}, outcome) do
        assert settlement["result"] == %{
                 "kind" => "error",
                 "category" => "unreadable_model_answer",
                 "accounting_evidence" => %{"kind" => "none"}
               }

        assert terminal["reason"] == "unreadable_model_answer"
      end

      {next, rows, all_events} = commit(state, proposal, events)
      assert next.charged[state.active_run_id] == %{tokens: 10_000, source: :estimated}
      assert next.maintenance_episodes[episode_id]["checkpoint_id"] == nil
      assert next.maintenance_episodes[episode_id]["usage"]["attempts"] == 1
      assert next.active_run_id == nil
      assert next.active_maintenance == nil
      assert next.conversation == state.conversation

      assert {:ok, recovered} =
               SessionState.recover(state.session_id, history ++ rows, all_events)

      assert recovered.charged == next.charged
      assert {:error, :no_retry_permitted} = SessionState.propose_maintenance_attempt_open(next)
    end
  end

  test "validated replies compacted at the settlement depth limit preserve exact usage" do
    {state, history, events} = opened()
    request = state.maintenance_episodes[state.active_maintenance]["request"]
    arguments = Enum.reduce(1..8, %{}, fn _, inner -> %{"nested" => inner} end)

    raw = %{
      summary_reply(request)
      | tool_calls: [%{id: "deep", name: "forbidden", arguments: arguments}]
    }

    assert {:ok, _canonical} = Loopex.Runtime.ProviderAttempt.canonical_reply(raw, request, false)

    assert {:ok, proposal} =
             SessionState.propose_maintenance_attempt_settled(state, {:reply, raw})

    assert [prefix, settlement, terminal] = proposal.records
    evidence = settlement["result"]["accounting_evidence"]
    assert evidence["kind"] == "validated_reply_compaction_v1"
    assert evidence["dimension"] == "record_depth"
    assert evidence["observed"] == 13
    assert evidence["limit"] == 12
    assert evidence["usage"]["input_tokens"] == 37
    assert settlement["accounting"]["source"] == "reported"
    assert terminal["reason"] == "unreadable_model_answer"
    assert prefix["result"]["usage"]["reported_tokens"] == 56
    {next, rows, all_events} = commit(state, proposal, events)
    assert next.charged[state.active_run_id] == %{tokens: 56, source: :reported}
    assert {:ok, recovered} = SessionState.recover(state.session_id, history ++ rows, all_events)
    assert recovered.charged == next.charged
  end

  test "an interrupted failed settlement cannot charge or admit unrelated commands or owner succession" do
    {state, history, events} = opened()

    assert {:ok, proposal} =
             SessionState.propose_maintenance_attempt_settled(
               state,
               :owner_loss
             )

    {_next, [prefix, settlement, terminal], all_events} = commit(state, proposal, events)

    {:ok, steer} =
      SessionState.propose(state, %{
        type: :steer,
        command_id: "interrupt",
        run_id: state.active_run_id,
        content: "later"
      })

    {_next, [command], _} = commit(state, steer, events)
    advance = owner_advance(state)

    for inserted <- [command, advance, settlement] do
      assert {:error, _} =
               SessionState.recover(
                 state.session_id,
                 history ++ restamp(state, [prefix, settlement, inserted, terminal]),
                 all_events
               )
    end

    assert {:error, _} =
             SessionState.recover(
               state.session_id,
               history ++ restamp(state, [settlement]),
               events
             )
  end

  test "a succeeding owner recovers the exact open request and settles its lost attempt once" do
    {state, history, events} = opened()
    [advance] = restamp(state, [owner_advance(state)])
    assert {:ok, recovered} = SessionState.recover(state.session_id, history ++ [advance], events)
    assert recovered.owner_epoch == 2
    assert recovered.maintenance_episodes == state.maintenance_episodes

    assert {:ok, proposal} =
             SessionState.propose_maintenance_attempt_settled(recovered, :owner_loss)

    {next, rows, all_events} = commit(recovered, proposal, events)
    assert next.active_maintenance == nil
    assert next.charged[state.active_run_id] == %{tokens: 10_000, source: :estimated}

    assert {:ok, replay} =
             SessionState.recover(state.session_id, history ++ [advance] ++ rows, all_events)

    assert replay.maintenance_episodes == next.maintenance_episodes

    assert {:error, :no_open_maintenance_attempt} =
             SessionState.propose_maintenance_attempt_settled(replay, :owner_loss)
  end

  defp owner_advance(state) do
    %{
      journal_version: state.journal_version + 1,
      owner_epoch: 2,
      owner_incarnation_id: "next",
      payload: %{
        :kind => "owner_advanced",
        "prior_owner_epoch" => 1,
        "owner_epoch" => 2,
        "owner_incarnation_id" => "next",
        "owner_transaction_id" => "next-tx"
      }
    }
  end

  defp opened do
    {state, history, events} = admitted(["old fact"])
    {:ok, proposal} = propose(state, 1)
    {state, rows, events} = commit(state, proposal, events)
    {state, history ++ rows, events}
  end

  defp summary_output,
    do: %{
      "summary" => "Retained facts 猫",
      "carry_forward" => %{"files_read" => ["lib/a.ex"], "files_changed" => []}
    }

  defp summary_json(value) do
    {:ok, bytes} = Frame.encode(%{"v" => value})
    bytes = IO.iodata_to_binary(bytes)
    binary_part(bytes, 5, byte_size(bytes) - 7)
  end

  defp summary_reply(request) do
    %{
      text: summary_json(summary_output()),
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

  defp admitted(texts, options \\ []) do
    configuration =
      Map.put(
        Genesis.configuration(
          Keyword.get(options, :ordinary_body, "Follow the host's captured instructions.")
        ),
        "system_class_tokens",
        Keyword.get(options, :system_class_tokens, 5_000)
      )
      |> Map.put("context_token_budget", Keyword.get(options, :context_token_budget, 8_192))
      |> Map.update!("budget_origins", fn origins ->
        if Keyword.has_key?(options, :context_token_budget),
          do: Map.put(origins, "context_token_budget", "explicit"),
          else: origins
      end)

    history = [
      %{
        journal_version: 1,
        owner_epoch: 0,
        owner_incarnation_id: nil,
        payload: Genesis.genesis([], configuration)
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

    {:ok, initial} = SessionState.recover("staging-session", history, [])

    {state, history, events} =
      Enum.reduce(Enum.with_index(texts), {initial, history, []}, fn {text, n},
                                                                     {state, history, events} ->
        {:ok, prompt} =
          SessionState.propose(
            state,
            %{type: :prompt, command_id: "old-#{n}", content: text},
            Map.put(bounds(), :context_token_budget, configuration["context_token_budget"])
          )

        {state, rows, events} = commit(state, prompt, events)
        history = history ++ rows

        {:ok, terminal} =
          SessionState.propose_run_terminal(state, state.active_run_id, "failed", %{
            reason: "model_call_failed"
          })

        {state, rows, events} = commit(state, terminal, events)
        {state, history ++ rows, events}
      end)

    {state, history, events} =
      if Keyword.get(options, :resources, false) do
        digest = String.duplicate("a", 64)

        decision = %{
          "manifest_digest" => digest,
          "workspace_ref" => "workspace",
          "trust_scope" => "project_skills",
          "decision_source" => "host_supplied",
          "issued_at" => "2026-10-03T00:00:00Z",
          "expires_at" => nil,
          "revocation_state" => "active"
        }

        {:ok, admission} =
          SessionState.propose_resource_command(
            state,
            %{
              type: :admit_resources,
              command_id: "resources",
              manifest_digest: digest,
              decision: decision
            },
            {:accepted, %{"workspace_ref" => "workspace", "manifest_digest" => digest}}
          )

        {next, rows, events} = commit(state, admission, events)
        {next, history ++ rows, events}
      else
        {state, history, events}
      end

    {:ok, prompt} =
      SessionState.propose(
        state,
        %{
          type: :prompt,
          command_id: "current",
          content: Keyword.get(options, :current_content, "protected")
        },
        Map.put(bounds(), :max_turns, Keyword.get(options, :max_turns, 8))
        |> Map.put(:context_token_budget, configuration["context_token_budget"])
      )

    {state, rows, events} = commit(state, prompt, events)
    history = history ++ rows
    parent = state.configuration

    selection = %{
      "model" => parent["model"],
      "reasoning" => "none",
      "model_capabilities" => %{parent["model_capabilities"] | "reasoning_levels" => ["none"]},
      "provider_mapping" => %{parent["provider_mapping"] | "thinking_disabled" => true}
    }

    {:ok, instructions} =
      MaintenanceConfiguration.capture_instructions(%{
        "version" => "summary.v1",
        "body" => Keyword.get(options, :maintenance_body, "Retain facts 猫")
      })

    {:ok, admission} =
      SessionState.propose_maintenance_episode(
        state,
        state.active_run_id,
        selection,
        instructions,
        1_000
      )

    {state, rows, events} = commit(state, admission, events)
    {state, history ++ rows, events}
  end

  defp bounds,
    do: %{max_turns: 8, token_budget: 10_000, deadline_ms: 60_000, context_token_budget: 8_192}

  defp restamp(state, rows),
    do:
      Enum.with_index(rows, state.journal_version + 1)
      |> Enum.map(fn {row, version} -> %{row | journal_version: version} end)

  defp commit(state, proposal, events) do
    rows =
      Enum.with_index(proposal.records, state.journal_version + 1)
      |> Enum.map(fn {payload, version} ->
        %{
          payload: payload,
          journal_version: version,
          owner_epoch: state.owner_epoch,
          owner_incarnation_id: state.owner_incarnation_id
        }
      end)

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
    {next, rows, events ++ added}
  end

  defp independent_coverage(state, count) do
    originals =
      state.run_order
      |> Enum.take(count)
      |> Enum.map(fn run -> hd(SessionState.elements(state, run)) end)
      |> Enum.map(&Loopex.Conversation.source_reference/1)
      |> Enum.map(&state.conversation_record_sources[&1])
      |> Enum.sort_by(& &1.journal_version)

    bytes = [
      "loopex.compaction.covered_records.v1",
      <<0>>
      | Enum.map(originals, fn original ->
          bytes =
            Canonical.encode(%{
              "journal_version" => original.journal_version,
              "record_digest" => original.record_digest,
              "record_byte_cost" => original.record_byte_cost
            })

          [<<byte_size(bytes)::unsigned-big-integer-size(64)>>, bytes]
        end)
    ]

    :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
  end
end
