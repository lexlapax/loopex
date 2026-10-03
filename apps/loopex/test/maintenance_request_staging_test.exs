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

    spent =
      put_in(state.charged[run], %{
        reported_tokens: 9_000,
        estimated_tokens: 0,
        total_tokens: 9_000,
        accounting_source: "reported"
      })

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
        bounds()
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
