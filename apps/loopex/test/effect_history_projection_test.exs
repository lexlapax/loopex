Code.require_file("support/m1_runtime_helper.exs", __DIR__)
Code.require_file("support/agent_loop_helper.exs", __DIR__)

defmodule Loopex.EffectHistoryProjectionTest do
  use ExUnit.Case, async: false

  alias Loopex.AgentLoopFixture, as: Fixture
  alias Loopex.Runtime.SessionState

  setup do
    fixture =
      Fixture.start(
        script: [
          %{text: "write", calls: [%{id: "call-1", name: "write", arguments: %{"path" => "a"}}]},
          %{text: "done", calls: []}
        ]
      )

    on_exit(fn -> Fixture.stop(fixture) end)
    {session, attachment, {:accepted, "prompt-1"}} = Fixture.run(fixture, "implement")
    await_finished(attachment, System.monotonic_time(:millisecond) + 5_000)
    records = Fixture.records(fixture, session)
    intent = Enum.find(records, &(&1.payload.kind == "effect_intent_committed_v2"))
    receipt = Enum.find(records, &(&1.payload.kind == "executor_receipt_committed_v2"))
    assert intent
    assert receipt
    [fixture: fixture, session: session, intent: intent, receipt: receipt]
  end

  test "actual owner facts project the dispatched plain job and committed receipt", context do
    %{fixture: fixture, session: session, intent: intent, receipt: receipt} = context
    [dispatched] = Loopex.AgentLoopTestExecutor.jobs(fixture.executor)
    expected_job = Map.from_struct(dispatched)

    assert {:ok, %{kind: "intent", job: ^expected_job} = projection} =
             SessionState.effect_history_projection(session, intent.payload)

    refute Map.has_key?(projection.job, :__struct__)
    assert Map.keys(projection) |> Enum.sort() == [:job, :kind]
    refute Map.has_key?(projection, :grant)
    refute Map.has_key?(projection.job, :grant)
    refute Map.has_key?(projection.job, :owner_incarnation_id)

    assert {:ok,
            %{
              kind: "terminal",
              run_id: dispatched.run_id,
              tool_call_id: "call-1",
              disposition: "receipt_committed"
            }} == SessionState.effect_history_projection(session, receipt.payload)

    before = Loopex.M1RuntimeTestStore.inspect_state(fixture.store)
    assert {:ok, _} = SessionState.effect_history_projection(session, intent.payload)
    assert before == Loopex.M1RuntimeTestStore.inspect_state(fixture.store)

    assert {:error, :invalid_history} ==
             SessionState.effect_history_projection(session, %{
               intent.payload
               | kind: "effect_intent_committed"
             })

    assert {:error, :invalid_history} ==
             SessionState.effect_history_projection(session, %{
               receipt.payload
               | kind: "executor_receipt_committed"
             })

    for row <- [intent, receipt],
        do:
          assert(
            {:error, :invalid_history} == SessionState.effect_history_projection(session, row)
          )
  end

  test "intent scope and canonical bytes cannot be replaced or silently dropped", context do
    %{session: session, intent: %{payload: intent}} = context
    assert_closed(session, intent)
    assert_closed(session, intent, "job")
    assert_closed(session, intent, "grant")

    for altered <- [
          Map.put(intent, "run_id", "another-run"),
          put_in(intent, ["job", "session_id"], "another-session"),
          put_in(intent, ["job", "run_id"], "another-run"),
          put_in(intent, ["job", "canonical_request_bytes"], "changed"),
          put_in(intent, ["job", "canonical_request_digest"], String.duplicate("0", 64)),
          put_in(intent, ["job", "effective_job_deadline"], 0),
          put_in(intent, ["job", "effective_job_deadline"], intent["job"]["run_deadline"] + 1),
          put_in(intent, ["grant", "issued_by"], "model_output")
        ] do
      assert {:error, :invalid_history} = SessionState.effect_history_projection(session, altered)
    end

    changed_bytes = "different bytes"

    changed_digest =
      :crypto.hash(:sha256, changed_bytes) |> Base.encode16(case: :lower)

    forged =
      intent
      |> put_in(["job", "canonical_request_bytes"], changed_bytes)
      |> put_in(["job", "canonical_request_digest"], changed_digest)

    assert {:error, :invalid_history} = SessionState.effect_history_projection(session, forged)
    assert {:error, :invalid_history} = SessionState.effect_history_projection("another", intent)

    # A past captured deadline still belongs to historical evidence. Reads
    # validate its original bounds rather than granting fresh execution time.
    assert {:ok, %{job: %{effective_job_deadline: 1}}} =
             SessionState.effect_history_projection(
               session,
               put_in(intent, ["job", "effective_job_deadline"], 1)
             )
  end

  test "receipts keep their fact class independently of outcome and support reconciled facts",
       context do
    %{session: session, receipt: %{payload: record}} = context

    for outcome <-
          ~w(completed failed denied cancelled outcome_unknown cancelled_workspace_lease_lost) do
      changed = put_in(record, ["receipt", "outcome"], outcome)

      assert {:ok, %{disposition: "receipt_committed"}} =
               SessionState.effect_history_projection(session, changed)
    end

    assert {:ok, %{disposition: "receipt_committed"}} =
             SessionState.effect_history_projection(
               session,
               Map.put(record, "reconciliation_query_id", "query")
             )

    assert_closed(session, record)
    assert_closed(session, record, "receipt")

    for {field, value} <- [
          {"session_id", "other"},
          {"run_id", "other"},
          {"protocol_version", 2},
          {"attempt", 0},
          {"session_epoch_at_dispatch", -1},
          {"executor_epoch", "1"},
          {"fencing_token", nil},
          {"job_id", ""},
          {"tool_call_id", nil},
          {"canonical_request_digest", String.duplicate("A", 64)},
          {"outcome", "unknown"},
          {"output", nil},
          {"child_environment_names", ["NAME=value"]},
          {"provider_credential_present", true},
          {"artifacts", [%{"handle" => "invalid"}]},
          {"cleanup_confirmation", "maybe"}
        ] do
      assert {:error, :invalid_history} =
               SessionState.effect_history_projection(
                 session,
                 put_in(record, ["receipt", field], value)
               )
    end

    for value <- [nil, "", 1],
        do:
          assert(
            {:error, :invalid_history} ==
              SessionState.effect_history_projection(
                session,
                Map.put(record, "reconciliation_query_id", value)
              )
          )
  end

  test "core terminal disposition comes from the retained kind and outcome", context do
    %{session: session, intent: %{payload: intent}} = context

    record = %{
      "run_id" => intent["run_id"],
      "tool_call_id" => "call-1",
      "outcome" => "failed",
      "reason" => "receipt_committed outcome_unknown refused_before_effect",
      kind: "tool_result_committed_v2"
    }

    for {outcome, disposition} <- [
          {"failed", "refused_before_effect"},
          {"cancelled", "refused_before_effect"},
          {"completed", "outcome_unknown"},
          {"denied", "outcome_unknown"},
          {"outcome_unknown", "outcome_unknown"},
          {"cancelled_workspace_lease_lost", "outcome_unknown"}
        ] do
      assert {:ok,
              %{
                kind: "terminal",
                run_id: record["run_id"],
                tool_call_id: "call-1",
                disposition: disposition
              }} ==
               SessionState.effect_history_projection(session, %{record | "outcome" => outcome})
    end

    assert {:error, :invalid_history} ==
             SessionState.effect_history_projection(session, %{
               record
               | kind: "tool_result_committed"
             })

    assert_closed(session, record)

    for {field, value} <- [
          {"run_id", ""},
          {"tool_call_id", nil},
          {"outcome", "refused_before_effect"},
          {"reason", %{kind: "failed"}}
        ],
        do:
          assert(
            {:error, :invalid_history} ==
              SessionState.effect_history_projection(session, Map.put(record, field, value))
          )
  end

  test "run-level unknown retains a null call and unsupported or oversized facts refuse",
       context do
    %{session: session, intent: %{payload: intent}} = context

    record = %{
      "run_id" => intent["run_id"],
      "reconciliation_ref" => "reconciliation",
      kind: "outcome_unknown_committed_v2"
    }

    assert {:ok,
            %{
              kind: "terminal",
              run_id: record["run_id"],
              tool_call_id: nil,
              disposition: "outcome_unknown"
            }} == SessionState.effect_history_projection(session, record)

    assert {:error, :invalid_history} ==
             SessionState.effect_history_projection(session, %{
               record
               | kind: "outcome_unknown_committed"
             })

    assert_closed(session, record)

    for invalid <- [
          nil,
          %{},
          %{record | kind: "outcome_unknown_committed_v3"},
          %{record | "reconciliation_ref" => ""},
          %{record | "run_id" => nil},
          Map.put(record, "tool_call_id", "call-1"),
          Map.put(record, "reconciliation_ref", self()),
          put_in(
            intent,
            ["job", "validated_arguments", "oversized"],
            String.duplicate("a", 65_536)
          )
        ] do
      assert {:error, :invalid_history} = SessionState.effect_history_projection(session, invalid)
    end

    for invalid_session <- [nil, "", String.duplicate("s", 257)],
        do:
          assert(
            {:error, :invalid_history} ==
              SessionState.effect_history_projection(invalid_session, record)
          )
  end

  defp assert_closed(session, record, nested \\ nil) do
    value = if nested, do: record[nested], else: record
    keys = Map.keys(value)

    variants =
      Enum.map(keys, &Map.delete(value, &1)) ++
        [Map.put(value, "unknown", nil), value |> Map.delete(hd(keys)) |> Map.put("unknown", nil)]

    for variant <- variants do
      altered = if nested, do: Map.put(record, nested, variant), else: variant
      assert {:error, :invalid_history} = SessionState.effect_history_projection(session, altered)
    end
  end

  defp await_finished(attachment, deadline) do
    case Loopex.next_event(attachment) do
      {:ok, %{kind: "run.finished"}} ->
        :ok

      observation ->
        assert System.monotonic_time(:millisecond) < deadline,
               "run did not finish; last read: #{inspect(observation)}"

        unless match?({:ok, %{}}, observation), do: Process.sleep(10)
        await_finished(attachment, deadline)
    end
  end
end
