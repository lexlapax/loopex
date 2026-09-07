Code.require_file("support/m1_runtime_helper.exs", __DIR__)
Code.require_file("support/agent_loop_helper.exs", __DIR__)

defmodule Loopex.ProviderAccountingProvenanceTest do
  @moduledoc false
  use ExUnit.Case, async: false

  alias Loopex.AgentLoopFixture, as: Fixture
  alias Loopex.AgentLoopTestModel
  alias Loopex.Runtime.{ProviderAttempt, SessionState}
  alias Loopex.Store

  @v1 "model_attempt_settled_v1"
  @v2 "model_attempt_settled_v2"
  @max 18_446_744_073_709_551_615

  setup do
    fixture =
      Fixture.start(script: [%{text: "held", calls: [], hold: self(), hold_timeout_ms: 30_000}])

    on_exit(fn -> Fixture.stop(fixture) end)

    {session_id, _attachment, {:accepted, "prompt-1"}} =
      Fixture.run(fixture, "accounting provenance")

    assert_receive {:holding, callback}, 5_000
    [request] = AgentLoopTestModel.dispatched(fixture.model)
    records = Fixture.records(fixture, session_id)
    events = Fixture.events(fixture, session_id)
    assert {:ok, state} = SessionState.recover(session_id, records, events)
    [work] = SessionState.pending_work(state)

    %{
      fixture: fixture,
      callback: callback,
      session_id: session_id,
      request: request,
      state: state,
      work: work,
      records: records,
      events: events
    }
  end

  test "v2 compaction records exact Store byte observation and this reply's reported usage", c do
    for {target, input, output} <- [
          {65_535, 7, 5},
          {65_536, 11, 2},
          {65_537, 19, 3},
          {65_579, 23, 4}
        ] do
      raw = raw_reply(c, input, output)
      {:ok, _, fixed} = Store.normalize_and_measure_item(:record, full_settlement(c, raw))
      raw = %{raw | text: String.duplicate("x", target - fixed)}
      expected = full_settlement(c, raw)
      assert {:ok, _normalized, ^target} = Store.normalize_and_measure_item(:record, expected)
      assert :ok = ProviderAttempt.admitted_raw_reply(raw)

      assert {:ok, proposal} =
               SessionState.propose_model_attempt_settled(c.state, c.work.run_id, {:reply, raw})

      [settlement, terminal] = proposal.records
      assert settlement.kind == @v2

      assert settlement["accounting"] == %{
               "source" => "reported",
               "input_tokens" => input,
               "output_tokens" => output
             }

      if target <= 65_536 do
        assert settlement == expected
        assert terminal["outcome"] == "completed"
      else
        assert settlement["result"] ==
                 unreadable(compact(expected, "record_bytes", target, 65_536))

        assert terminal["outcome"] == "failed"
        assert settlement["next"] == "terminal"
        assert settlement["conversation"] == "none"
        refute inspect(proposal.events) =~ "accounting_evidence"

        refute inspect(SessionState.elements(proposal.next, c.work.run_id)) =~
                 "validated_reply_compaction"
      end

      for record <- proposal.records, do: assert(:ok == Store.validate_private_record(record))
      assert {:ok, replayed} = replay_proposal(c, proposal)

      assert SessionState.accounting(replayed, c.work.run_id) ==
               SessionState.accounting(proposal.next, c.work.run_id)

      assert elem(SessionState.accounting(replayed, c.work.run_id), 1) == %{
               tokens: input + output,
               source: :reported
             }
    end
  end

  test "depth compaction measures the continuable full reply and then terminates without tools",
       c do
    for {input, output} <- [{17, 4}, {31, 8}] do
      call = %{"id" => "call-depth", "name" => "write", "arguments" => nested(8)}
      raw = %{raw_reply(c, input, output) | tool_calls: [call]}
      expected = full_settlement(c, raw)
      assert expected["next"] == "continue"
      assert :ok = ProviderAttempt.admitted_raw_reply(raw)

      assert {:error, {:item_structure_exceeded, :depth, 13, 12}} =
               Store.normalize_and_measure_item(:record, expected)

      assert {:ok, proposal} =
               SessionState.propose_model_attempt_settled(c.state, c.work.run_id, {:reply, raw})

      [settlement, terminal] = proposal.records
      assert settlement["result"] == unreadable(compact(expected, "record_depth", 13, 12))
      assert settlement["next"] == "terminal"
      assert terminal["outcome"] == "failed"
      assert proposal.next.active_run_id == nil
      assert SessionState.pending_work(proposal.next) == []

      refute Enum.any?(
               proposal.events,
               &(&1.kind in ["tool.started", "assistant.message_appended"])
             )

      assert {:ok, _replayed} = replay_proposal(c, proposal)
    end
  end

  test "raw rejection never borrows plausible usage while unreported compaction stays estimated",
       c do
    raw = raw_reply(c, 7, 5)

    for invalid <- [
          %{raw | text: String.duplicate("x", 65_537)},
          %{raw | streamed: true},
          Map.put(raw, :unknown, "extra"),
          %{raw | tool_calls: Enum.map(1..1025, fn _ -> %{} end)}
        ] do
      {:ok, proposal} =
        SessionState.propose_model_attempt_settled(c.state, c.work.run_id, {:reply, invalid})

      assert hd(proposal.records)["result"] == unreadable(%{"kind" => "none"})
      assert hd(proposal.records)["accounting"] == estimated()
    end

    raw = %{
      raw
      | usage: %{},
        tool_calls: [%{"id" => "deep", "name" => "write", "arguments" => nested(8)}]
    }

    {:ok, proposal} =
      SessionState.propose_model_attempt_settled(c.state, c.work.run_id, {:reply, raw})

    assert hd(proposal.records)["result"]["accounting_evidence"]["usage"] == %{
             "status" => "unreported",
             "category" => "missing"
           }

    assert hd(proposal.records)["accounting"] == estimated()

    assert elem(SessionState.accounting(proposal.next, c.work.run_id), 1) == %{
             tokens: 1_000_000,
             source: :estimated
           }
  end

  test "v2 evidence rejects extra missing unknown keys enums limits and either reported-member mismatch",
       c do
    full = full_settlement(c, raw_reply(c, @max, @max))
    evidence = compact(full, "record_bytes", @max, 65_536)

    record = %{
      full
      | "result" => unreadable(evidence),
        "next" => "terminal",
        "conversation" => "none"
    }

    assert :ok = ProviderAttempt.validate_settled(record)

    invalid =
      for {path, value} <- [
            {["result", "accounting_evidence", "kind"], "future"},
            {["result", "accounting_evidence", "dimension"], "record_cardinality"},
            {["result", "accounting_evidence", "observed"], 65_536},
            {["result", "accounting_evidence", "observed"], -1},
            {["result", "accounting_evidence", "observed"], @max + 1},
            {["result", "accounting_evidence", "observed"], 65_537.0},
            {["result", "accounting_evidence", "limit"], 65_535},
            {["result", "accounting_evidence", "usage", "input_tokens"], @max - 1},
            {["result", "accounting_evidence", "usage", "output_tokens"], @max - 1},
            {["result", "accounting_evidence", "usage", "input_tokens"], @max + 1},
            {["next"], "continue"},
            {["termination"], "owner_loss"},
            {["result", "accounting_evidence"], %{"kind" => "none"}}
          ],
          do: put_in(record, path, value)

    invalid =
      invalid ++
        for path <- [
              [],
              ["result"],
              ["result", "accounting_evidence"],
              ["result", "accounting_evidence", "usage"]
            ],
            mutation <- [:missing, :extra] do
          alter = fn map ->
            if mutation == :missing,
              do: Map.delete(map, hd(Map.keys(map))),
              else: Map.put(map, "extra", 1)
          end

          if path == [], do: alter.(record), else: update_in(record, path, alter)
        end

    for candidate <- invalid do
      assert {:error, _reason} = ProviderAttempt.validate_settled(candidate)
    end

    for {observed, limit} <- [{12, 12}, {14, 12}, {13, 11}, {13, 13}] do
      candidate =
        put_in(
          record,
          ["result", "accounting_evidence"],
          compact(full, "record_depth", observed, limit)
        )

      assert {:error, _reason} = ProviderAttempt.validate_settled(candidate)
    end

    depth =
      put_in(record, ["result", "accounting_evidence"], compact(full, "record_depth", 13, 12))

    assert :ok = ProviderAttempt.validate_settled(depth)
  end

  test "legacy prefix replays but ambiguous v1 and downgrade after v2 refuse", c do
    {:ok, first} =
      SessionState.propose_model_attempt_settled(c.state, c.work.run_id, :not_dispatched)

    assert [retry] = first.records
    assert retry.kind == @v2
    {:ok, opened} = SessionState.propose_model_attempt_open(first.next, c.work.run_id)

    {:ok, final} =
      SessionState.propose_model_attempt_settled(
        opened.next,
        c.work.run_id,
        {:reply, raw_reply(c, 7, 5)}
      )

    all = %{final | records: first.records ++ opened.records ++ final.records}
    assert {:ok, replayed} = replay_proposal(c, all)
    assert replayed.provider_settlement_version == 2

    mixed = %{all | records: [Map.put(retry, :kind, @v1) | tl(all.records)]}
    assert {:ok, _legacy_prefix} = replay_proposal(c, mixed)
    legacy = %{all | records: Enum.map(all.records, &legacy_record/1)}
    assert {:ok, old} = replay_proposal(c, legacy)
    assert old.provider_settlement_version == 1

    downgrade = %{
      all
      | records: first.records ++ opened.records ++ Enum.map(final.records, &legacy_record/1)
    }

    assert {:error, :provider_settlement_version_downgrade} = replay_proposal(c, downgrade)

    for outcome <- [:owner_loss, {:reply, %{raw_reply(c, 7, 5) | streamed: true}}] do
      {:ok, proposal} =
        SessionState.propose_model_attempt_settled(c.state, c.work.run_id, outcome)

      legacy = %{proposal | records: Enum.map(proposal.records, &legacy_record/1)}
      assert {:ok, _old} = replay_proposal(c, legacy)
    end

    ambiguous = %{
      full_settlement(c, raw_reply(c, 7, 5))
      | "conversation" => "none",
        "result" => %{"kind" => "error", "category" => "unreadable_model_answer"},
        kind: @v1
    }

    assert {:error, :ambiguous_legacy_provider_accounting} =
             ProviderAttempt.validate_settled(ambiguous)

    assert {:error, _unknown} =
             ProviderAttempt.validate_settled(%{ambiguous | kind: "model_attempt_settled_v3"})
  end

  test "missing intervening duplicate reordered or mismatched terminal pairs never recover", c do
    {:ok, proposal} =
      SessionState.propose_model_attempt_settled(
        c.state,
        c.work.run_id,
        {:reply, raw_reply(c, 7, 5)}
      )

    [settlement, terminal] = proposal.records

    for records <- [
          [settlement],
          [terminal, settlement],
          [settlement, settlement, terminal],
          [settlement, terminal, terminal],
          [settlement, List.last(c.records).payload, terminal],
          [settlement, %{terminal | "run_id" => "other"}],
          [settlement, %{terminal | "outcome" => "failed"}],
          [settlement, %{terminal | "reason" => "unreadable_model_answer"}],
          [settlement, Map.put(terminal, "extra", 1)]
        ] do
      assert {:error, _reason} = replay_proposal(c, %{proposal | records: records})
    end

    assert {:ok, replayed} = replay_proposal(c, proposal)
    assert replayed.active_run_id == nil

    assert elem(SessionState.accounting(replayed, c.work.run_id), 1) == %{
             tokens: 12,
             source: :reported
           }
  end

  defp raw_reply(c, input, output) do
    %{
      text: "",
      identity: %{provider: "scripted", model: "scripted:v1", endpoint: "in-process"},
      usage: %{input_tokens: input, output_tokens: output},
      tool_calls: [],
      delta_count: 0,
      streamed: false,
      provider_response_id: nil,
      canonical_request_bytes: c.request.canonical_request_bytes,
      staged_request_digest: c.request.staged_request_digest
    }
  end

  defp full_settlement(c, raw) do
    {:ok, reply} = ProviderAttempt.canonical_reply(raw, c.request)

    %{
      "run_id" => c.work.run_id,
      "turn_id" => c.work.turn_id,
      "operation_id" => SessionState.model_operation_id(c.work.run_id, c.work.turn_number),
      "attempt" => 1,
      "staged_request_digest" => c.request.staged_request_digest,
      "transport" => "dispatched_or_unknown",
      "termination" => nil,
      "conversation" => "canonical",
      "next" => if(raw.tool_calls == [], do: "terminal", else: "continue"),
      "result" => %{"kind" => "reply", "reply" => reply},
      "accounting" => %{
        "source" => "reported",
        "input_tokens" => raw.usage.input_tokens,
        "output_tokens" => raw.usage.output_tokens
      },
      kind: @v2
    }
  end

  defp compact(full, dimension, observed, limit),
    do: %{
      "kind" => "validated_reply_compaction_v1",
      "usage" => full["result"]["reply"]["usage"],
      "dimension" => dimension,
      "observed" => observed,
      "limit" => limit
    }

  defp unreadable(evidence),
    do: %{
      "kind" => "error",
      "category" => "unreadable_model_answer",
      "accounting_evidence" => evidence
    }

  defp estimated, do: %{"source" => "estimated", "basis" => "remaining_allowance"}
  defp nested(0), do: "leaf"
  defp nested(depth), do: %{"n" => nested(depth - 1)}

  defp legacy_record(%{kind: @v2} = record) do
    %{record | "result" => Map.delete(record["result"], "accounting_evidence"), kind: @v1}
  end

  defp legacy_record(record), do: record

  defp replay_proposal(c, proposal) do
    records =
      for {payload, index} <- Enum.with_index(proposal.records, c.state.journal_version + 1),
          do: %{
            journal_version: index,
            owner_epoch: c.state.owner_epoch,
            owner_incarnation_id: c.state.owner_incarnation_id,
            payload: payload
          }

    events =
      for {event, index} <- Enum.with_index(proposal.events, c.state.event_sequence + 1),
          do:
            Map.merge(event, %{
              event_sequence: index
            })

    SessionState.recover(c.session_id, c.records ++ records, c.events ++ events)
  end
end
