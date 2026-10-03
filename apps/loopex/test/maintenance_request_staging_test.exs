Code.require_file("support/configured_genesis_helper.exs", __DIR__)

defmodule Loopex.Runtime.MaintenanceRequestStagingTest do
  use ExUnit.Case, async: true
  alias Loopex.ConfiguredGenesisFixture, as: Genesis
  alias Loopex.Runtime.{MaintenanceConfiguration, SessionState}
  alias LoopexProtocol.{Canonical, Frame}
  alias Loopex.Store

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

    {state, _, _} = admitted(["old"], system_class_tokens: ceiling, maintenance_body: body)

    assert {:refused, refusal} =
             SessionState.preflight_maintenance_request(state, 1, 1_001, fn ->
               flunk("source traversal after system refusal")
             end)

    assert refusal["dimension"] == "system_class_tokens"
    assert refusal["limit"] == ceiling
    assert refusal["observed"] == ceiling
    assert refusal["record_byte_cost"] == nil

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
          {Map.drop(raw, [:completion, :continuation]), "maintenance_summary_incomplete"},
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

  test "owner loss and malformed replies charge the remaining allowance without retry or checkpoint" do
    {state, history, events} = opened()
    episode_id = state.active_maintenance
    request = state.maintenance_episodes[episode_id]["request"]

    for outcome <- [:owner_loss, {:reply, Map.put(summary_reply(request), :extra, true)}] do
      assert {:ok, proposal} = SessionState.propose_maintenance_attempt_settled(state, outcome)
      assert [prefix, settlement, _terminal] = proposal.records
      assert settlement["accounting"]["source"] == "estimated"
      assert prefix["result"]["usage"]["estimated_tokens"] == 10_000
      {next, rows, all_events} = commit(state, proposal, events)
      assert next.charged[state.active_run_id] == %{tokens: 10_000, source: :estimated}
      assert next.maintenance_episodes[episode_id]["checkpoint_id"] == nil

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
        Genesis.configuration(),
        "system_class_tokens",
        Keyword.get(options, :system_class_tokens, 5_000)
      )

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
            bounds()
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
        %{type: :prompt, command_id: "current", content: "protected"},
        Map.put(bounds(), :max_turns, Keyword.get(options, :max_turns, 8))
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
