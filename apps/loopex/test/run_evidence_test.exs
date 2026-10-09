Code.require_file("support/m1_runtime_helper.exs", __DIR__)
Code.require_file("support/agent_loop_helper.exs", __DIR__)

defmodule Loopex.RunEvidenceTest do
  use ExUnit.Case, async: false

  alias Loopex.AgentLoopFixture, as: Fixture
  alias Loopex.Runtime
  alias Loopex.Runtime.SessionState
  alias Loopex.Store
  alias LoopexProtocol.Canonical

  @runtime_id "agent-loop-runtime"
  @zero %{reported_input: 0, reported_output: 0, estimated: 0, unresolved: false}

  defmodule ReadStore do
    @moduledoc false
    @behaviour Store

    @impl Store
    def transact(reference, _), do: forbid(reference, :transact)
    @impl Store
    def transaction_status(reference, _, _, _), do: forbid(reference, :transaction_status)
    @impl Store
    def runtime_command(reference, _), do: forbid(reference, :runtime_command)
    @impl Store
    def load_events(reference, _, _, _), do: forbid(reference, :load_events)

    defp forbid(reference, operation) do
      send(Agent.get(reference, & &1.observer), {:forbidden_store_call, operation})
      raise("unexpected Store callback in run evidence")
    end

    @impl Store
    def creation_provenance(reference, runtime, %{kind: :session, session_id: session}) do
      state = Agent.get(reference, & &1)

      cond do
        state.mode == :unavailable -> :unavailable
        runtime != state.runtime -> :conflict
        Map.has_key?(state.sessions, session) -> {:historical, creation(session, state)}
        true -> :absent
      end
    end

    defp creation(session, state) do
      {:ok, transaction} =
        Store.create_session(state.runtime, "create-1", hd(state.sessions[session]).payload)

      %{
        version: 1,
        runtime_id: state.runtime,
        command_id: "create-1",
        session_id: session,
        genesis_version: 3,
        canonical_create_digest:
          Base.encode16(transaction.canonical_mutation_digest, case: :lower)
      }
    end

    @impl Store
    def ownership_head(reference, session, _) do
      records = Agent.get(reference, & &1.sessions[session])
      {:ok, %{owner_epoch: 1, journal_version: List.last(records).journal_version}}
    end

    @impl Store
    def load_records(reference, session, after_version, limit) do
      Agent.get(reference, fn state ->
        records =
          state.sessions[session]
          |> Enum.filter(&(&1.journal_version > after_version))
          |> Enum.take(limit)

        if state.mode == :gap, do: {:ok, Enum.drop(records, 1)}, else: {:ok, records}
      end)
    end
  end

  test "completed runs return exact reported usage, admission and terminal digest" do
    {records, session, run} =
      finished([
        %{
          text: "write",
          calls: [%{id: "c1", name: "write", arguments: %{"path" => "a"}}],
          usage: %{input_tokens: 10, output_tokens: 4}
        },
        %{text: "done", calls: [], usage: %{input_tokens: 3, output_tokens: 2}}
      ])

    assert {:ok, evidence} = SessionState.run_evidence(session, records, run)
    [admitted] = Enum.filter(records, &(&1.payload.kind == "prompt_admitted_v3"))
    [terminal] = Enum.filter(records, &(&1.payload.kind == "run_terminal_committed"))

    assert evidence == %{
             admission: %{
               command_id: "prompt-1",
               revision: 2,
               digest: admitted.payload["command_digest"]
             },
             terminal: %{
               state: "completed",
               journal_version: terminal.journal_version,
               record_digest: Canonical.digest(terminal.payload)
             },
             usage: %{reported_input: 13, reported_output: 6, estimated: 0, unresolved: false},
             through_version: List.last(records).journal_version
           }

    {runtime, reference} = read_runtime(%{session => records})
    assert Runtime.run_evidence(runtime, session, run) == {:ok, evidence}
    assert Runtime.run_evidence(runtime, session, run) == {:ok, evidence}
    assert Runtime.run_evidence(runtime, session, "missing-run") == {:error, :unknown_run}
    assert Runtime.run_evidence(runtime, "missing-session", run) == {:error, :unknown_run}
    assert Runtime.run_evidence(runtime, session, "") == {:error, :unknown_run}
    assert Runtime.run_evidence(:not_a_runtime, session, run) == {:error, :runtime_unavailable}
    refute_received {:forbidden_store_call, _}

    Agent.update(reference, &%{&1 | mode: :gap})
    assert Runtime.run_evidence(runtime, session, run) == {:error, :runtime_unavailable}
    Agent.update(reference, &%{&1 | mode: :unavailable})
    assert Runtime.run_evidence(runtime, session, run) == {:error, :runtime_unavailable}

    {other, _} = read_runtime(%{session => records}, "other-runtime")
    assert Runtime.run_evidence(other, session, run) == {:error, :unknown_run}
  end

  test "an incomplete usage pair is an estimated unresolved charge of the remaining allowance" do
    {records, session, run} =
      finished([%{text: "done", calls: [], usage: %{input_tokens: 5}}], bounds_token_budget: 900)

    assert {:ok, %{usage: usage, terminal: %{state: state}}} =
             SessionState.run_evidence(session, records, run)

    assert usage == %{reported_input: 0, reported_output: 0, estimated: 900, unresolved: true}
    assert state in ["completed", "bound_reached"]
  end

  test "failed, cancelled and live runs keep distinct terminals and honest usage" do
    {records, session, run} = finished([%{error: :provider_unavailable}])
    assert {:ok, failed} = SessionState.run_evidence(session, records, run)
    assert failed.terminal.state == "failed"
    {_bounds, charged} = SessionState.accounting(replay(session, records), run)

    assert failed.usage.reported_input + failed.usage.reported_output + failed.usage.estimated ==
             charged.tokens

    fixture =
      Fixture.start(script: [%{text: "held", calls: [], hold: self(), hold_timeout_ms: 30_000}])

    on_exit(fn -> Fixture.stop(fixture) end)
    {session, attachment, {:accepted, "prompt-1"}} = Fixture.run(fixture, "hold")
    assert_receive {:holding, worker}, 5_000
    live = Fixture.records(fixture, session)
    run = run_id(live)

    assert {:ok, %{terminal: nil, usage: @zero}} =
             SessionState.run_evidence(session, live, run)

    assert {:accepted, "abort-1"} =
             Loopex.command(attachment, %{type: :abort, command_id: "abort-1", run_id: run})

    send(worker, :release)
    await_finished(attachment, System.monotonic_time(:millisecond) + 5_000)
    records = Fixture.records(fixture, session)
    assert {:ok, cancelled} = SessionState.run_evidence(session, records, run)
    assert cancelled.terminal.state == "cancelled"
    assert cancelled.through_version == List.last(records).journal_version
  end

  test "the extracted receipt validator accepts exactly the committed fact for its job" do
    {records, session, _run} =
      finished([
        %{text: "write", calls: [%{id: "c1", name: "write", arguments: %{"path" => "a"}}]},
        %{text: "done", calls: []}
      ])

    [intent] = Enum.filter(records, &(&1.payload.kind == "effect_intent_committed_v2"))
    [fact] = Enum.filter(records, &(&1.payload.kind == "executor_receipt_committed_v2"))
    {:ok, %{job: job}} = SessionState.effect_history_projection(session, intent.payload)
    receipt = fact.payload["receipt"]

    assert {:ok, decoded} = SessionState.validate_executor_receipt(receipt, job)
    assert decoded.job_id == job.job_id and decoded.outcome == :completed

    for {changed_receipt, changed_job} <- [
          {Map.put(receipt, "attempt", job.attempt + 1), job},
          {receipt, %{job | fencing_token: job.fencing_token + 1}},
          {Map.put(receipt, "outcome", "invented"), job},
          {receipt, nil}
        ] do
      assert SessionState.validate_executor_receipt(changed_receipt, changed_job) ==
               {:error, :invalid_executor_receipt}
    end
  end

  defp finished(script, options \\ []) do
    fixture = Fixture.start(Keyword.put(options, :script, script))
    on_exit(fn -> Fixture.stop(fixture) end)
    {session, attachment, {:accepted, "prompt-1"}} = Fixture.run(fixture, "work")
    await_finished(attachment, System.monotonic_time(:millisecond) + 5_000)
    records = Fixture.records(fixture, session)
    Process.put(:events, Fixture.events(fixture, session))
    {records, session, run_id(records)}
  end

  defp run_id(records) do
    [admitted] = Enum.filter(records, &(&1.payload.kind == "prompt_admitted_v3"))
    admitted.payload["run_id"]
  end

  defp replay(session, records) do
    assert {:ok, state} = SessionState.recover(session, records, Process.get(:events))
    state
  end

  defp read_runtime(sessions, runtime_id \\ @runtime_id) do
    {:ok, reference} =
      Agent.start_link(fn ->
        %{runtime: @runtime_id, sessions: sessions, mode: :normal, observer: self()}
      end)

    Agent.update(reference, &%{&1 | observer: self()})
    {:ok, store} = Store.new(ReadStore, reference)

    {:ok, runtime} =
      Loopex.start_link(runtime_id: runtime_id, context_token_budget: 8_192, store: store)

    on_exit(fn -> Loopex.stop(runtime) end)
    # Control answers evidence reads only after its creation startup settles
    # (this read-only Store leaves creation unavailable);
    # without this the first read raced startup and saw runtime_unavailable.
    :ok = Loopex.ConfiguredGenesisFixture.await_creation_unavailable(runtime)
    {runtime, reference}
  end

  defp await_finished(attachment, deadline) do
    case Loopex.next_event(attachment) do
      {:ok, %{kind: "run.finished"}} ->
        :ok

      observation ->
        assert System.monotonic_time(:millisecond) < deadline,
               "run did not finish: #{inspect(observation)}"

        unless match?({:ok, %{}}, observation), do: Process.sleep(10)
        await_finished(attachment, deadline)
    end
  end
end
