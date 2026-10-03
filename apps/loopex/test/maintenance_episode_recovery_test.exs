Code.require_file("support/m1_runtime_helper.exs", __DIR__)
Code.require_file("support/agent_loop_helper.exs", __DIR__)
Code.require_file("support/configured_genesis_helper.exs", __DIR__)

defmodule Loopex.Runtime.MaintenanceEpisodeRecoveryTest do
  use ExUnit.Case, async: false

  alias Loopex.AgentLoopFixture, as: Fixture
  alias Loopex.AgentLoopTestModel
  alias Loopex.ConfiguredGenesisFixture, as: Genesis
  alias Loopex.M1RuntimeTestStore
  alias Loopex.Runtime.{MaintenanceConfiguration, SessionState}
  alias Loopex.Store

  for phase <- [
        :before_linearization,
        :after_linearization_before_result,
        :recovery_representation
      ] do
    @phase phase
    test "a recovered preparation cutoff settles once through #{@phase} uncertainty" do
      {fixture, session, episode} = retained_episode(:expired)
      :ok = M1RuntimeTestStore.inject(fixture.store, {:session_journal_commit, @phase})
      successor = start(store: fixture.store, script: [], tools: [], model: "changed:model")

      {:ok, {:prepared, activation}} =
        Loopex.prepare_resume_session(successor.runtime, session, "resume")

      {:ok, children} = Loopex.Runtime.children(successor.runtime)
      coordinator = :sys.get_state(children.control).sessions[session].coordinator
      monitor = Process.monitor(coordinator)

      before = Fixture.records(successor, session)
      assert AgentLoopTestModel.dispatched(successor.model) == []
      refute Enum.any?(before, &(&1.payload.kind == "maintenance_episode_terminal_v1"))
      assert {:ok, ^session} = Loopex.activate_resume(activation)

      rows = await_terminal(successor, session, now() + 5_000)
      endings = Enum.filter(rows, &(&1.payload.kind == "maintenance_episode_terminal_v1"))
      assert [prefix] = endings
      assert prefix.payload["episode_id"] == episode["episode_id"]
      assert prefix.payload["result"]["usage"] == episode["usage"]
      assert prefix.payload["observed_at"] >= episode["preparation_deadline"]
      assert prefix.payload["result"]["failure"]["cause"] == "compaction_preparation_deadline"

      [refusal, terminal] = Enum.drop_while(rows, &(&1.journal_version <= prefix.journal_version))
      assert refusal.payload.kind == "context_admission_refused_v2"
      assert terminal.payload.kind == "run_terminal_committed"
      assert terminal.payload["outcome"] == "failed"
      assert terminal.payload["failure"] == prefix.payload["result"]["failure"]
      assert terminal.payload["bound"] == nil
      assert terminal.payload["observed"] == nil
      assert AgentLoopTestModel.dispatched(successor.model) == []
      assert Agent.get(successor.executor, & &1.jobs) == []

      assert MapSet.member?(
               M1RuntimeTestStore.observed(fixture.store),
               {:session_journal_commit, @phase}
             )

      events = Fixture.events(successor, session)
      assert Enum.count(events, &(&1.kind == "run.finished")) == 1
      assert {:ok, recovered} = SessionState.recover(session, rows, events)
      assert recovered.active_maintenance == nil
      assert recovered.active_run_id == nil
      assert recovered.deadlines == %{}
      assert recovered.maintenance_episodes[episode["episode_id"]]["stage"] == "settled"

      assert recovered.maintenance_episodes[episode["episode_id"]]["result"] ==
               prefix.payload["result"]

      if @phase == :recovery_representation do
        # Concept: unresolved commit uncertainty stops this owner fenced.
        # Technical depth: this phase forces both existing permitted
        # presentations to remain unknown. Join that exact exit, then recover
        # the retained transaction under a new owner; do not add retries.
        assert_receive {:DOWN, ^monitor, :process, ^coordinator,
                        {:maintenance_expiry_failed, :commit_unknown}},
                       5_000

        assert {:ok, ^session} =
                 Loopex.resume_session(successor.runtime, session, command_id: "resolve-ending")

        restored = Fixture.records(successor, session)
        assert Enum.count(restored, &(&1.payload.kind == "maintenance_episode_terminal_v1")) == 1
        assert Enum.count(restored, &(&1.payload.kind == "run_terminal_committed")) == 1
        assert Fixture.events(successor, session) == events
        assert AgentLoopTestModel.dispatched(successor.model) == []
        assert Agent.get(successor.executor, & &1.jobs) == []
      else
        refute_received {:DOWN, ^monitor, :process, ^coordinator, _}
      end

      stop_and_join(successor, session)
    end
  end

  test "a recovered abort before summary dispatch cancels instead of inventing an unknown effect" do
    {fixture, session, episode} = retained_episode(:aborted)
    successor = start(store: fixture.store, script: [], tools: [])

    assert {:ok, ^session} =
             Loopex.resume_session(successor.runtime, session, command_id: "resume")

    rows = await_terminal(successor, session, now() + 5_000)
    assert [prefix, terminal] = Enum.take(rows, -2)
    assert prefix.payload.kind == "maintenance_episode_terminal_v1"

    assert prefix.payload["result"]["failure"] == %{
             "category" => "cancelled",
             "retryable" => false
           }

    assert prefix.payload["result"]["cleanup"] == "confirmed"
    assert prefix.payload["result"]["usage"] == episode["usage"]
    assert terminal.payload["outcome"] == "cancelled"
    assert terminal.payload["command_id"] == "abort"
    assert terminal.payload["reconciliation_ref"] == nil

    refute Enum.any?(
             rows,
             &(&1.payload.kind in ["outcome_unknown_committed", "outcome_unknown_committed_v2"])
           )

    assert AgentLoopTestModel.dispatched(successor.model) == []
    assert Agent.get(successor.executor, & &1.jobs) == []

    assert {:ok, recovered} =
             SessionState.recover(session, rows, Fixture.events(successor, session))

    assert recovered.active_maintenance == nil
    assert recovered.active_run_id == nil
    stop_and_join(successor, session)
  end

  for mode <- [
        :open,
        :open_aborted,
        :open_expired,
        :invalid,
        :incomplete,
        :invalid_aborted,
        :invalid_expired
      ] do
    @mode mode
    test "live successor completes retained #{@mode} maintenance without another provider call" do
      {fixture, session, episode} = retained_episode(@mode)
      before = Fixture.records(fixture, session)
      successor = start(store: fixture.store, script: [], tools: [], model: "changed:model")

      assert {:ok, ^session} =
               Loopex.resume_session(successor.runtime, session, command_id: "resume")

      rows = await_terminal(successor, session, now() + 5_000)
      assert [prefix] = Enum.filter(rows, &(&1.payload.kind == "maintenance_episode_terminal_v1"))
      assert prefix.payload["episode_id"] == episode["episode_id"]
      assert prefix.payload["result"]["checkpoint_id"] == nil
      assert prefix.payload["result"]["cleanup"] == "confirmed"
      usage = prefix.payload["result"]["usage"]
      assert usage["attempts"] == 1
      reported = summary_reply_retained?(@mode)
      assert usage["total_tokens"] == if(reported, do: 56, else: 10_000)
      assert usage["reported_tokens"] == if(reported, do: 56, else: 0)
      assert usage["estimated_tokens"] == if(reported, do: 0, else: 10_000)
      failure = prefix.payload["result"]["failure"]

      case @mode do
        :open ->
          assert failure["category"] == "model_call_failed"

        mode when mode in [:open_aborted, :invalid_aborted] ->
          assert failure["category"] == "cancelled"

        mode when mode in [:open_expired, :invalid_expired] ->
          assert failure["category"] == "bound_reached"
          assert failure["bound"] == "deadline_ms"

        :invalid ->
          assert failure["cause"] == "maintenance_summary_invalid"

        :incomplete ->
          assert failure["cause"] == "maintenance_summary_incomplete"
      end

      assert Enum.count(rows, &(&1.payload.kind == "maintenance_attempt_settled_v3")) == 1
      assert Enum.count(rows, &(&1.payload.kind == "maintenance_attempt_opened_v1")) == 1

      if summary_refusal_expected?(@mode) do
        assert [^prefix, refusal, terminal] =
                 Enum.drop_while(rows, &(&1.journal_version < prefix.journal_version))

        assert refusal.payload.kind == "context_admission_refused_v2"
        assert terminal.payload["failure"] == refusal.payload["failure"]
        assert refusal.payload["failure"] == failure
      end

      assert AgentLoopTestModel.dispatched(successor.model) == []
      assert Agent.get(successor.executor, & &1.jobs) == []

      assert {:ok, recovered} =
               SessionState.recover(session, rows, Fixture.events(successor, session))

      assert recovered.active_maintenance == nil
      assert recovered.active_run_id == nil
      assert length(rows) > length(before)
      stop_and_join(successor, session)
    end
  end

  for mode <- [:open, :invalid],
      phase <- [
        :before_linearization,
        :after_linearization_before_result,
        :recovery_representation
      ] do
    @mode mode
    @phase phase
    test "live #{@mode} maintenance ending resolves #{@phase} uncertainty once" do
      {fixture, session, episode} = retained_episode(@mode)
      :ok = M1RuntimeTestStore.inject(fixture.store, {:session_journal_commit, @phase})
      successor = start(store: fixture.store, script: [], tools: [], model: "changed:model")

      {:ok, {:prepared, activation}} =
        Loopex.prepare_resume_session(successor.runtime, session, "resume")

      {:ok, children} = Loopex.Runtime.children(successor.runtime)
      coordinator = :sys.get_state(children.control).sessions[session].coordinator
      monitor = Process.monitor(coordinator)
      assert {:ok, ^session} = Loopex.activate_resume(activation)
      rows = await_terminal(successor, session, now() + 5_000)
      assert [prefix] = Enum.filter(rows, &(&1.payload.kind == "maintenance_episode_terminal_v1"))
      assert prefix.payload["episode_id"] == episode["episode_id"]

      assert prefix.payload["result"]["usage"]["total_tokens"] ==
               if(@mode == :open, do: 10_000, else: 56)

      assert prefix.payload["result"]["usage"]["attempts"] == 1

      assert MapSet.member?(
               M1RuntimeTestStore.observed(fixture.store),
               {:session_journal_commit, @phase}
             )

      if @phase == :recovery_representation do
        expected =
          if @mode == :open,
            do: {:model_result_failed, :commit_unknown},
            else: {:context_preparation_failed, :commit_unknown}

        assert_receive {:DOWN, ^monitor, :process, ^coordinator, ^expected}, 5_000

        assert {:ok, ^session} =
                 Loopex.resume_session(successor.runtime, session, command_id: "resolve-ending")
      else
        refute_received {:DOWN, ^monitor, :process, ^coordinator, _}
      end

      rows = Fixture.records(successor, session)
      events = Fixture.events(successor, session)
      assert Enum.count(rows, &(&1.payload.kind == "maintenance_episode_terminal_v1")) == 1
      assert Enum.count(rows, &(&1.payload.kind == "maintenance_attempt_settled_v3")) == 1

      assert Enum.count(
               events,
               &(&1.kind == "run.finished" and &1["run_id"] == episode["run_id"])
             ) == 1

      assert {:ok, replay} = SessionState.recover(session, rows, events)
      assert replay.active_maintenance == nil
      assert replay.charged[episode["run_id"]].tokens == if(@mode == :open, do: 10_000, else: 56)

      assert replay.maintenance_episodes[episode["episode_id"]]["result"] ==
               prefix.payload["result"]

      assert AgentLoopTestModel.dispatched(successor.model) == []
      assert Agent.get(successor.executor, & &1.jobs) == []
      stop_and_join(successor, session)
    end
  end

  # Concept: recovery starts from a committed episode with no summary dispatch.
  # Technical depth: the fixture uses public exact creation, stops that runtime, then
  # commits prompt and episode reducer proposals through the actual
  # Store transaction boundary. This supplies the durable boundary the live
  # automatic trigger has not yet joined, without mutating coordinator cache.
  defp retained_episode(mode) do
    fixture = start(script: [], tools: [])

    {:ok, session} =
      Loopex.create_session(fixture.runtime, %{},
        command_id: "create",
        genesis: Genesis.genesis([])
      )

    assert :ok = Loopex.stop(fixture.runtime)

    {:ok, state} =
      SessionState.recover(
        session,
        Fixture.records(fixture, session),
        Fixture.events(fixture, session)
      )

    # Concept: the retained prompt is undispatched by construction.
    # Technical depth: prepared resume pauses only recovered work, not a new
    # prompt. Commit this pure admission after the fixture owner has stopped,
    # through the same actual Store boundary used for episode admission below.
    state =
      if mode in [:expired, :aborted] do
        state
      else
        {:ok, old} =
          SessionState.propose(
            state,
            %{type: :prompt, command_id: "old", content: "original facts"},
            %{
              max_turns: 8,
              token_budget: 10_000,
              deadline_ms: 60_000,
              context_token_budget: 8_192
            }
          )

        prior = retain(fixture, state, old)

        {:ok, ending} =
          SessionState.propose_run_terminal(prior, prior.active_run_id, "failed", %{
            reason: "model_call_failed"
          })

        retain(fixture, prior, ending)
      end

    {:ok, prompt} =
      SessionState.propose(state, %{type: :prompt, command_id: "prompt", content: "retained"}, %{
        max_turns: 8,
        token_budget: 10_000,
        deadline_ms: 60_000,
        context_token_budget: 8_192
      })

    state = retain(fixture, state, prompt)
    assert AgentLoopTestModel.dispatched(fixture.model) == []

    configuration = Genesis.configuration()

    model = %{
      "model" => configuration["model"],
      "reasoning" => "none",
      "model_capabilities" => %{
        configuration["model_capabilities"]
        | "reasoning_levels" => ["none"]
      },
      "provider_mapping" => %{configuration["provider_mapping"] | "thinking_disabled" => true}
    }

    {:ok, instructions} =
      MaintenanceConfiguration.capture_instructions(%{
        "version" => "summary.v1",
        "body" => "Keep the facts"
      })

    admitted_at =
      System.system_time(:millisecond) -
        cond do
          mode == :expired -> 60_000
          mode in [:open_expired, :invalid_expired] -> 60_002
          true -> 0
        end

    {:ok, admission} =
      SessionState.propose_maintenance_episode(
        state,
        state.active_run_id,
        model,
        instructions,
        admitted_at
      )

    state = retain(fixture, state, admission)

    state =
      if mode in [:expired, :aborted] do
        state
      else
        {:ok, request} =
          SessionState.propose_maintenance_request(state, 1, admitted_at + 1, fn -> :ok end)

        retain(fixture, state, request)
      end

    state =
      if mode in [:invalid, :incomplete, :invalid_aborted, :invalid_expired] do
        request = state.maintenance_episodes[state.active_maintenance]["request"]

        raw = %{
          text: "{}",
          identity: %{provider: "scripted", model: request.model, endpoint: "in-process"},
          usage: %{input_tokens: 37, output_tokens: 19},
          tool_calls: [],
          delta_count: 0,
          streamed: false,
          provider_response_id: nil,
          canonical_request_bytes: request.canonical_request_bytes,
          staged_request_digest: request.staged_request_digest,
          completion: if(mode == :incomplete, do: "limit", else: "natural"),
          continuation: nil
        }

        {:ok, settlement} = SessionState.propose_maintenance_attempt_settled(state, {:reply, raw})
        retain(fixture, state, settlement)
      else
        state
      end

    if mode in [:aborted, :open_aborted, :invalid_aborted] do
      {:ok, abort} = SessionState.propose(state, %{type: :abort, command_id: "abort"})
      retain(fixture, state, abort)
    end

    {fixture, session, hd(admission.records)}
  end

  defp retain(fixture, state, proposal) do
    {:ok, store} = Store.new(M1RuntimeTestStore, fixture.store)

    {:ok, transaction} =
      Store.session_commit(
        state.session_id,
        "session",
        proposal.tx_id,
        state.owner_epoch,
        state.owner_incarnation_id,
        state.journal_version,
        proposal.records,
        proposal.events
      )

    assert {:committed, _tx, receipt} = Store.transact(store, transaction)
    assert {:ok, next} = SessionState.commit_proposal(proposal, receipt)
    next
  end

  defp start(options) do
    fixture = Fixture.start(options)
    on_exit(fn -> Fixture.stop(fixture) end)
    fixture
  end

  defp await_terminal(fixture, session, cutoff) do
    rows = Fixture.records(fixture, session)

    if Enum.any?(rows, &(&1.payload.kind == "maintenance_episode_terminal_v1")) do
      rows
    else
      assert now() < cutoff
      Process.sleep(1)
      await_terminal(fixture, session, cutoff)
    end
  end

  defp summary_reply_retained?(mode),
    do: mode in [:invalid, :incomplete, :invalid_aborted, :invalid_expired]

  defp summary_refusal_expected?(mode), do: mode in [:invalid, :incomplete]

  defp stop_and_join(fixture, session) do
    {:ok, children} = Loopex.Runtime.children(fixture.runtime)
    coordinator = :sys.get_state(children.control).sessions[session].coordinator
    # Concept: fixture teardown follows adoption, not just a visible Store row.
    # Technical depth: a system-state call joins that handler before shutdown so the
    # fixture does not race a committed-but-not-yet-adopted result with teardown.
    assert :sys.get_state(coordinator).durable.active_run_id == nil
    monitors = Enum.map([children.control, coordinator], &{&1, Process.monitor(&1)})
    assert :ok = Loopex.stop(fixture.runtime)

    for {pid, monitor} <- monitors do
      assert_receive {:DOWN, ^monitor, :process, ^pid, reason}, 5_000
      assert reason in [:normal, :shutdown]
    end
  end

  defp now, do: System.monotonic_time(:millisecond)
end
