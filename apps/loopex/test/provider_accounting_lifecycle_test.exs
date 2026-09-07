Code.require_file("support/m1_runtime_helper.exs", __DIR__)
Code.require_file("support/agent_loop_helper.exs", __DIR__)

defmodule Loopex.ProviderAccountingLifecycleTest do
  @moduledoc false
  use ExUnit.Case, async: false

  alias Loopex.AgentLoopFixture, as: Fixture
  alias Loopex.AgentLoopTestModel
  alias Loopex.Runtime.SessionState

  for cause <- [:abort, :deadline] do
    @cause cause
    test "compacted reply preserves earlier #{@cause}", _context do
      fixture =
        Fixture.start(script: [%{text: "held", calls: [], hold: self(), hold_timeout_ms: 30_000}])

      on_exit(fn -> Fixture.stop(fixture) end)

      {session, _attachment, {:accepted, "prompt-1"}} =
        Fixture.run(fixture, "compact after termination")

      assert_receive {:holding, _callback}, 5_000
      [request] = AgentLoopTestModel.dispatched(fixture.model)

      assert {:ok, state} =
               SessionState.recover(
                 session,
                 Fixture.records(fixture, session),
                 Fixture.events(fixture, session)
               )

      [work] = SessionState.pending_work(state)

      {:ok, terminated} =
        case @cause do
          :abort ->
            SessionState.propose(state, %{type: :abort, command_id: "abort-probe"})

          :deadline ->
            SessionState.propose_model_termination(
              state,
              work.run_id,
              Map.fetch!(state.deadlines, work.run_id)
            )
        end

      raw = %{
        text: "late valid reply",
        identity: %{provider: "scripted", model: "scripted:v1", endpoint: "in-process"},
        usage: %{input_tokens: 43, output_tokens: 17},
        tool_calls: [%{"id" => "deep", "name" => "write", "arguments" => nested(8)}],
        delta_count: 0,
        streamed: false,
        provider_response_id: nil,
        canonical_request_bytes: request.canonical_request_bytes,
        staged_request_digest: request.staged_request_digest
      }

      assert {:ok, proposal} =
               SessionState.propose_model_attempt_settled(
                 terminated.next,
                 work.run_id,
                 {:reply, raw}
               )

      [settlement, terminal] = proposal.records
      assert settlement["termination"] == Atom.to_string(@cause)

      assert settlement["result"]["accounting_evidence"]["kind"] ==
               "validated_reply_compaction_v1"

      assert terminal["outcome"] == if(@cause == :abort, do: "cancelled", else: "bound_reached")

      assert elem(SessionState.accounting(proposal.next, work.run_id), 1) == %{
               tokens: 60,
               source: :reported
             }
    end
  end

  test "a fresh prompt cannot reopen the legacy settlement allowance" do
    fixture = Fixture.start(script: [%{text: "one", calls: []}, %{text: "two", calls: []}])
    on_exit(fn -> Fixture.stop(fixture) end)
    {session, attachment, {:accepted, "prompt-1"}} = Fixture.run(fixture, "first run")

    assert await_finished(attachment)

    assert {:accepted, "prompt-2"} =
             Loopex.command(attachment, %{
               type: :prompt,
               command_id: "prompt-2",
               content: "second run"
             })

    assert await_finished(attachment)

    records = Fixture.records(fixture, session)
    events = Fixture.events(fixture, session)
    assert {:ok, _valid} = SessionState.recover(session, records, events)

    settlements = Enum.filter(records, &(&1.payload.kind == "model_attempt_settled_v2"))
    assert [first, second] = settlements
    refute first.payload["run_id"] == second.payload["run_id"]

    changed =
      Enum.map(records, fn record ->
        if record.journal_version == second.journal_version,
          do: %{record | payload: %{record.payload | kind: "model_attempt_settled_v1"}},
          else: record
      end)

    assert {:error, :provider_settlement_version_downgrade} =
             SessionState.recover(session, changed, events)
  end

  defp nested(0), do: "leaf"
  defp nested(depth), do: %{"n" => nested(depth - 1)}

  defp await_finished(attachment) do
    await_finished(attachment, System.monotonic_time(:millisecond) + 5_000)
  end

  defp await_finished(attachment, deadline) do
    case Loopex.next_event(attachment) do
      {:ok, %{kind: "run.finished"}} ->
        true

      {:ok, _event} ->
        await_finished(attachment, deadline)

      {:error, :empty} ->
        if System.monotonic_time(:millisecond) >= deadline do
          flunk("runtime did not finish within the detector's five-second bound")
        else
          Process.sleep(5)
          await_finished(attachment, deadline)
        end

      other ->
        flunk("unexpected runtime event result: #{inspect(other)}")
    end
  end
end
