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

  for mode <- [:checkpoint_pending, :checkpoint_committed],
      phase <- [
        :before_linearization,
        :after_linearization_before_result,
        :recovery_representation
      ] do
    @mode mode
    @phase phase
    test "live #{@mode} checkpoint recovery resolves #{@phase} once before ordinary dispatch" do
      {fixture, session, episode} = retained_episode(@mode)
      :ok = M1RuntimeTestStore.inject(fixture.store, {:session_journal_commit, @phase})

      successor =
        start(
          store: fixture.store,
          script: [%{text: "ordinary continuation", calls: []}],
          tools: [],
          model: "changed:model"
        )

      {:ok, {:prepared, activation}} =
        Loopex.prepare_resume_session(successor.runtime, session, "resume")

      {:ok, children} = Loopex.Runtime.children(successor.runtime)
      coordinator = :sys.get_state(children.control).sessions[session].coordinator
      monitor = Process.monitor(coordinator)
      before = Fixture.records(successor, session)
      assert AgentLoopTestModel.dispatched(successor.model) == []
      assert :sys.get_state(coordinator).in_flight == %{}
      assert {:ok, ^session} = Loopex.activate_resume(activation)

      if @phase == :recovery_representation do
        assert_receive {:DOWN, ^monitor, :process, ^coordinator,
                        {:maintenance_checkpoint_failed, :commit_unknown}},
                       5_000

        uncertain_rows = Fixture.records(successor, session)

        assert Enum.count(
                 uncertain_rows,
                 &(&1.payload.kind == "compaction_checkpoint_committed_v1")
               ) == 1

        assert Enum.count(Fixture.events(successor, session), &(&1.kind == "context.compacted")) ==
                 1

        refute Enum.any?(uncertain_rows, &(&1.payload.kind == "model_request_committed_v2"))

        refute Enum.any?(
                 uncertain_rows,
                 &(&1.payload.kind == "run_terminal_committed" and
                     &1.payload["run_id"] == episode["run_id"])
               )

        assert AgentLoopTestModel.dispatched(successor.model) == []

        assert {:ok, ^session} =
                 Loopex.resume_session(successor.runtime, session,
                   command_id: "resolve-checkpoint"
                 )
      end

      rows = await_parent_terminal(successor, session, episode["run_id"], now() + 5_000)
      assert Enum.count(rows, &(&1.payload.kind == "compaction_checkpoint_committed_v1")) == 1

      assert [completed] =
               Enum.filter(rows, &(&1.payload.kind == "maintenance_episode_terminal_v1"))

      assert completed.payload["result"]["disposition"] == "checkpointed"
      assert completed.payload["result"]["usage"]["total_tokens"] == 56
      assert Enum.count(rows, &(&1.payload.kind == "maintenance_attempt_opened_v1")) == 1
      assert Enum.count(rows, &(&1.payload.kind == "maintenance_attempt_settled_v3")) == 1
      assert [ordinary] = AgentLoopTestModel.dispatched(successor.model)
      assert ordinary.model == "scripted:v1"
      assert ordinary.tools == []
      assert ordinary.continuation == nil
      assert Enum.at(ordinary.messages, 1)["role"] == "user"

      assert {:ok, provenance} =
               LoopexProtocol.Frame.decode(Enum.at(ordinary.messages, 1)["content"], 16_384)

      assert provenance["kind"] == "compaction_summary"
      assert provenance["checkpoint_id"] == completed.payload["result"]["checkpoint_id"]
      assert provenance["summary"] == "retained facts"
      assert List.last(ordinary.messages) == %{"role" => "user", "content" => "retained"}
      assert Agent.get(successor.executor, & &1.jobs) == []
      events = Fixture.events(successor, session)
      assert Enum.count(events, &(&1.kind == "context.compacted")) == 1

      assert MapSet.member?(
               M1RuntimeTestStore.observed(fixture.store),
               {:session_journal_commit, @phase}
             )

      assert {:ok, recovered} = SessionState.recover(session, rows, events)
      assert recovered.active_maintenance == nil
      assert recovered.active_run_id == nil
      assert recovered.charged[episode["run_id"]] == %{tokens: 58, source: :reported}

      assert hd(SessionState.elements(recovered, hd(recovered.run_order))).content ==
               String.duplicate("old", 1_000)

      assert length(rows) > length(before)
      stop_and_join(successor, session)
    end
  end

  for mode <- [
        :checkpoint_aborted,
        :checkpoint_expired,
        :checkpoint_committed_aborted,
        :checkpoint_committed_expired,
        :checkpoint_spent_tokens,
        :checkpoint_spent_turns
      ] do
    @mode mode
    @committed mode in [:checkpoint_committed_aborted, :checkpoint_committed_expired]
    test "retained #{@mode} summary cannot create another checkpoint or new dispatch" do
      {fixture, session, episode} = retained_episode(@mode)
      successor = start(store: fixture.store, script: [], tools: [])

      assert {:ok, ^session} =
               Loopex.resume_session(successor.runtime, session, command_id: "resume")

      rows = await_parent_terminal(successor, session, episode["run_id"], now() + 5_000)

      assert Enum.count(rows, &(&1.payload.kind == "compaction_checkpoint_committed_v1")) ==
               if(@committed, do: 1, else: 0)

      assert [completed] =
               Enum.filter(rows, &(&1.payload.kind == "maintenance_episode_terminal_v1"))

      assert completed.payload["result"]["disposition"] == "failed"

      if @committed do
        [checkpoint] =
          Enum.filter(rows, &(&1.payload.kind == "compaction_checkpoint_committed_v1"))

        assert completed.payload["result"]["checkpoint_id"] == checkpoint.payload["checkpoint_id"]
      else
        assert completed.payload["result"]["checkpoint_id"] == nil
      end

      expected =
        case @mode do
          mode when mode in [:checkpoint_aborted, :checkpoint_committed_aborted] -> "cancelled"
          _ -> "bound_reached"
        end

      assert completed.payload["result"]["failure"]["category"] == expected
      assert AgentLoopTestModel.dispatched(successor.model) == []
      assert Agent.get(successor.executor, & &1.jobs) == []

      assert {:ok, recovered} =
               SessionState.recover(session, rows, Fixture.events(successor, session))

      assert recovered.charged[episode["run_id"]].tokens ==
               if(@mode == :checkpoint_spent_tokens, do: 10_000, else: 56)

      stop_and_join(successor, session)
    end
  end

  for mode <- [:nonprogress, :exhausted],
      phase <- [
        :before_linearization,
        :after_linearization_before_result,
        :recovery_representation
      ] do
    @mode mode
    @phase phase
    @expected_tokens if(mode == :exhausted, do: 168, else: 56)
    @expected_attempts if(mode == :exhausted, do: 4, else: 1)
    @expected_checkpoints if(mode == :exhausted, do: 3, else: 0)
    @expected_messages if(mode == :exhausted, do: 3, else: 2)
    test "live #{@mode} ending resolves #{@phase} without another summary or ordinary dispatch" do
      {fixture, session, episode} = retained_episode(@mode)
      before = Fixture.records(fixture, session)
      {:ok, original} = SessionState.recover(session, before, Fixture.events(fixture, session))
      :ok = M1RuntimeTestStore.inject(fixture.store, {:session_journal_commit, @phase})
      successor = start(store: fixture.store, script: [], tools: [], model: "changed:model")

      {:ok, {:prepared, activation}} =
        Loopex.prepare_resume_session(successor.runtime, session, "resume")

      {:ok, children} = Loopex.Runtime.children(successor.runtime)
      coordinator = :sys.get_state(children.control).sessions[session].coordinator
      monitor = Process.monitor(coordinator)
      prepared = Fixture.records(successor, session)
      assert Enum.take(prepared, length(before)) == before
      assert [owner] = Enum.drop(prepared, length(before))
      assert owner.payload.kind == "owner_advanced"
      assert :sys.get_state(coordinator).in_flight == %{}
      assert AgentLoopTestModel.dispatched(successor.model) == []
      assert {:ok, ^session} = Loopex.activate_resume(activation)

      if @phase == :recovery_representation do
        assert_receive {:DOWN, ^monitor, :process, ^coordinator,
                        {:maintenance_checkpoint_failed, :commit_unknown}},
                       5_000

        assert AgentLoopTestModel.dispatched(successor.model) == []

        assert {:ok, ^session} =
                 Loopex.resume_session(successor.runtime, session, command_id: "resolve-#{@mode}")
      end

      rows = await_parent_terminal(successor, session, episode["run_id"], now() + 5_000)
      assert [prefix] = Enum.filter(rows, &(&1.payload.kind == "maintenance_episode_terminal_v1"))

      assert [refusal, terminal] =
               rows
               |> Enum.drop_while(&(&1.journal_version <= prefix.journal_version))
               |> Enum.take(2)

      assert Enum.count(rows, &(&1.payload.kind == "context_admission_refused_v2")) == 1

      assert Enum.count(
               rows,
               &(&1.payload.kind == "run_terminal_committed" and
                   &1.payload["run_id"] == episode["run_id"])
             ) == 1

      assert prefix.payload.kind == "maintenance_episode_terminal_v1"
      assert prefix.payload["result"]["usage"]["total_tokens"] == @expected_tokens
      assert prefix.payload["result"]["checkpoint_id"] == original.active_checkpoint
      assert prefix.payload["result"]["cleanup"] == "confirmed"
      assert refusal.payload.kind == "context_admission_refused_v2"
      assert refusal.payload["projection_state"] == "measured"
      assert refusal.payload["measurement_scope"] == "ordinary"
      assert refusal.payload["record_byte_cost"] == nil
      assert refusal.payload["system_message_count"] == 1
      assert refusal.payload["session_message_count"] == @expected_messages
      assert refusal.payload["episode_id"] == episode["episode_id"]

      case @mode do
        :nonprogress ->
          assert refusal.payload["failure"]["cause"] == "compaction_no_progress"

        :exhausted ->
          assert refusal.payload["failure"]["category"] == "context_budget_exceeded"
          assert refusal.payload["failure"]["dimension"] == "context_tokens"
          assert refusal.payload["failure"]["limit"] == 4_000

          assert refusal.payload["failure"]["observed"] ==
                   refusal.payload["provider_estimated_tokens"]

          assert refusal.payload["provider_estimated_tokens"] > 4_000
      end

      assert terminal.payload.kind == "run_terminal_committed"
      assert terminal.payload["failure"] == refusal.payload["failure"]
      assert prefix.payload["result"]["failure"] == refusal.payload["failure"]

      assert Enum.count(rows, &(&1.payload.kind == "maintenance_attempt_opened_v1")) ==
               @expected_attempts

      assert Enum.count(rows, &(&1.payload.kind == "maintenance_attempt_settled_v3")) ==
               @expected_attempts

      assert Enum.count(rows, &(&1.payload.kind == "compaction_checkpoint_committed_v1")) ==
               @expected_checkpoints

      assert Enum.count(Fixture.events(successor, session), &(&1.kind == "context.compacted")) ==
               @expected_checkpoints

      refute Enum.any?(rows, &(&1.payload.kind == "model_request_committed_v2"))

      assert MapSet.member?(
               M1RuntimeTestStore.observed(fixture.store),
               {:session_journal_commit, @phase}
             )

      assert {:ok, recovered} =
               SessionState.recover(session, rows, Fixture.events(successor, session))

      assert recovered.active_maintenance == nil
      assert recovered.active_run_id == nil

      assert recovered.charged[episode["run_id"]] == %{
               tokens: @expected_tokens,
               source: :reported
             }

      assert recovered.conversation == original.conversation
      assert recovered.active_checkpoint == original.active_checkpoint
      assert recovered.checkpoints == original.checkpoints

      assert recovered.maintenance_episodes[episode["episode_id"]]["usage"] == %{
               "attempts" => @expected_attempts,
               "reported_tokens" => @expected_tokens,
               "estimated_tokens" => 0,
               "total_tokens" => @expected_tokens
             }

      assert AgentLoopTestModel.dispatched(successor.model) == []
      assert Agent.get(successor.executor, & &1.jobs) == []
      stop_and_join(successor, session)
    end
  end

  for mode <- [:source_pending, :checkpoint_more],
      phase <- [
        :none,
        :before_linearization,
        :after_linearization_before_result,
        :recovery_representation
      ] do
    @mode mode
    @phase phase
    @expected_summaries if(mode == :checkpoint_more, do: 2, else: 1)
    @expected_tokens if(phase == :recovery_representation,
                       do: 10_000,
                       else: if(mode == :checkpoint_more, do: 114, else: 58)
                     )
    @expected_source if(phase == :recovery_representation, do: :estimated, else: :reported)
    @expected_checkpoints if(phase == :recovery_representation,
                            do: @expected_summaries - 1,
                            else: @expected_summaries
                          )
    test "live #{@mode} preparation resolves #{@phase} staging before any new dispatch" do
      {fixture, session, episode} = retained_episode(@mode)
      before = Fixture.records(fixture, session)
      {:ok, original} = SessionState.recover(session, before, Fixture.events(fixture, session))

      successor =
        start(
          store: fixture.store,
          model: "changed:model",
          tools: [],
          progress_to: self(),
          script: [
            %{
              text:
                ~s({"summary":"live retained facts","carry_forward":{"files_read":[],"files_changed":[]}}),
              usage: %{input_tokens: 37, output_tokens: 19},
              deltas: ["PRIVATE_SUMMARY_DELTA"],
              reply_overrides: %{completion: "natural", continuation: nil}
            },
            %{
              text: "continued",
              deltas: ["ordinary delta"],
              require_previous_worker_down: true,
              reply_overrides: %{completion: "natural", continuation: nil}
            }
          ]
        )

      unless @phase == :none do
        :ok = M1RuntimeTestStore.inject(fixture.store, {:session_journal_commit, @phase})
      end

      {:ok, {:prepared, activation}} =
        Loopex.prepare_resume_session(successor.runtime, session, "resume-live-source")

      assert AgentLoopTestModel.dispatched(successor.model) == []
      {:ok, children} = Loopex.Runtime.children(successor.runtime)
      coordinator = :sys.get_state(children.control).sessions[session].coordinator
      assert :sys.get_state(coordinator).in_flight == %{}
      monitor = Process.monitor(coordinator)
      assert {:ok, ^session} = Loopex.activate_resume(activation)

      if @phase == :recovery_representation do
        assert_receive {:DOWN, ^monitor, :process, ^coordinator,
                        {:maintenance_preparation_commit_failed, :commit_unknown}},
                       5_000

        assert AgentLoopTestModel.dispatched(successor.model) == []

        assert {:ok, ^session} =
                 Loopex.resume_session(successor.runtime, session,
                   command_id: "resolve-source-staging"
                 )
      end

      rows = await_parent_terminal(successor, session, episode["run_id"], now() + 5_000)

      if @phase == :recovery_representation do
        assert AgentLoopTestModel.dispatched(successor.model) == []
        refute Enum.any?(rows, &(&1.payload.kind == "model_request_committed_v2"))

        assert [ending] =
                 Enum.filter(rows, &(&1.payload.kind == "maintenance_episode_terminal_v1"))

        assert ending.payload["result"]["disposition"] == "failed"
        assert ending.payload["result"]["checkpoint_id"] == original.active_checkpoint
        assert ending.payload["result"]["usage"]["total_tokens"] == 10_000
        assert ending.payload["result"]["usage"]["attempts"] == @expected_summaries
      else
        assert [summary, ordinary] = AgentLoopTestModel.dispatched(successor.model)
        assert summary.model == "scripted:v1"
        assert summary.tools == []
        assert summary.continuation == nil
        assert summary.sampling["max_tokens"] == 1_024
        assert summary.deadline == ordinary.deadline

        assert {:ok, source} =
                 LoopexProtocol.Frame.decode(Enum.at(summary.messages, 1)["content"], 16_384)

        assert source["version"] == "loopex.compaction.source.v2"

        assert source["prior_checkpoint"] ==
                 if(original.active_checkpoint,
                   do: original.checkpoints[original.active_checkpoint]["summary"],
                   else: nil
                 )

        assert ordinary.model == "scripted:v1"
        assert ordinary.tools == []

        assert {:ok, provenance} =
                 LoopexProtocol.Frame.decode(Enum.at(ordinary.messages, 1)["content"], 16_384)

        assert provenance["kind"] == "compaction_summary"
        assert provenance["summary"] == "live retained facts"
        assert List.last(ordinary.messages) == %{"role" => "user", "content" => "retained"}
        assert_receive {:loopex_progress, %{kind: :text_delta, text: "ordinary delta"}}, 5_000
        refute_received {:loopex_progress, %{kind: :text_delta, text: "PRIVATE_SUMMARY_DELTA"}}

        assert Enum.count(rows, &(&1.payload.kind == "model_request_committed_v2")) == 1

        assert [ending] =
                 Enum.filter(rows, &(&1.payload.kind == "maintenance_episode_terminal_v1"))

        assert ending.payload["result"]["disposition"] == "checkpointed"
        assert ending.payload["result"]["usage"]["total_tokens"] == @expected_summaries * 56
        assert provenance["checkpoint_id"] == ending.payload["result"]["checkpoint_id"]
      end

      assert Enum.count(rows, &(&1.payload.kind == "maintenance_request_committed_v1")) ==
               @expected_summaries

      assert Enum.count(rows, &(&1.payload.kind == "maintenance_attempt_opened_v1")) ==
               @expected_summaries

      assert Enum.count(rows, &(&1.payload.kind == "maintenance_attempt_settled_v3")) ==
               @expected_summaries

      assert Enum.count(rows, &(&1.payload.kind == "compaction_checkpoint_committed_v1")) ==
               @expected_checkpoints

      unless @phase == :none do
        assert MapSet.member?(
                 M1RuntimeTestStore.observed(fixture.store),
                 {:session_journal_commit, @phase}
               )
      end

      assert {:ok, recovered} =
               SessionState.recover(session, rows, Fixture.events(successor, session))

      assert recovered.active_maintenance == nil
      assert recovered.active_run_id == nil

      assert recovered.charged[episode["run_id"]] == %{
               tokens: @expected_tokens,
               source: @expected_source
             }

      for old <- Enum.drop(recovered.run_order, -1) do
        assert SessionState.elements(recovered, old) == SessionState.elements(original, old)
      end

      assert Agent.get(successor.executor, & &1.jobs) == []
      coordinator = :sys.get_state(children.control).sessions[session].coordinator
      live = :sys.get_state(coordinator)
      assert live.in_flight == %{}
      assert live.streams == %{}
      assert Task.Supervisor.children(live.owner_workers) == []
      stop_and_join(successor, session)
    end
  end

  test "ordinary history overflow admits and completes one live automatic maintenance episode" do
    {fixture, session, run_id, configuration} = retained_automatic_prompt()

    selection = %{
      "model" => configuration["model"],
      "reasoning" => "none",
      "model_capabilities" => %{
        configuration["model_capabilities"]
        | "reasoning_levels" => ["none"]
      },
      "provider_mapping" => %{configuration["provider_mapping"] | "thinking_disabled" => true}
    }

    successor =
      start(
        store: fixture.store,
        tools: [],
        maintenance_model: selection,
        maintenance_instructions: %{"version" => "summary.v1", "body" => "Keep the facts"},
        script: [
          %{
            text:
              ~s({"summary":"old facts retained","carry_forward":{"files_read":[],"files_changed":[]}}),
            usage: %{input_tokens: 37, output_tokens: 19},
            reply_overrides: %{completion: "natural", continuation: nil}
          },
          %{text: "continued", reply_overrides: %{completion: "natural", continuation: nil}}
        ]
      )

    {:ok, {:prepared, activation}} =
      Loopex.prepare_resume_session(successor.runtime, session, "resume-automatic")

    assert AgentLoopTestModel.dispatched(successor.model) == []
    assert {:ok, ^session} = Loopex.activate_resume(activation)

    rows = await_parent_terminal(successor, session, run_id, now() + 5_000)

    assert Enum.count(rows, &(&1.payload.kind == "maintenance_episode_admitted_v1")) == 1,
           inspect(Enum.map(rows, & &1.payload.kind))

    assert Enum.count(rows, &(&1.payload.kind == "maintenance_request_committed_v1")) == 1
    assert Enum.count(rows, &(&1.payload.kind == "compaction_checkpoint_committed_v1")) == 1
    assert [ending] = Enum.filter(rows, &(&1.payload.kind == "maintenance_episode_terminal_v1"))
    assert ending.payload["result"]["disposition"] == "checkpointed"

    assert [summary, ordinary] = AgentLoopTestModel.dispatched(successor.model)
    assert summary.sampling["max_tokens"] == 1_024
    assert summary.tools == []
    assert ordinary.tools == []
    assert List.last(ordinary.messages) == %{"role" => "user", "content" => "retained"}
    assert Agent.get(successor.executor, & &1.jobs) == []

    assert {:ok, recovered} =
             SessionState.recover(session, rows, Fixture.events(successor, session))

    assert recovered.active_maintenance == nil
    assert recovered.active_run_id == nil
    stop_and_join(successor, session)
  end

  test "automatic maintenance without a selected summarizer ends in one durable refusal" do
    {fixture, session, run_id, _configuration} = retained_automatic_prompt()
    successor = start(store: fixture.store, tools: [], script: [])

    {:ok, {:prepared, activation}} =
      Loopex.prepare_resume_session(successor.runtime, session, "resume-unconfigured")

    assert {:ok, ^session} = Loopex.activate_resume(activation)
    rows = await_parent_terminal(successor, session, run_id, now() + 5_000)

    refute Enum.any?(rows, &(&1.payload.kind == "maintenance_episode_admitted_v1"))
    assert [refusal] = Enum.filter(rows, &(&1.payload.kind == "context_admission_refused_v2"))
    assert refusal.payload["episode_id"] == nil
    assert refusal.payload["failure"]["cause"] == "maintenance_model_unconfigured"

    assert [terminal] =
             Enum.filter(
               rows,
               &(&1.payload.kind == "run_terminal_committed" and &1.payload["run_id"] == run_id)
             )

    assert terminal.payload["outcome"] == "failed"
    assert terminal.payload["failure"] == refusal.payload["failure"]
    assert AgentLoopTestModel.dispatched(successor.model) == []
    assert Agent.get(successor.executor, & &1.jobs) == []

    assert {:ok, recovered} =
             SessionState.recover(session, rows, Fixture.events(successor, session))

    assert recovered.active_run_id == nil
    stop_and_join(successor, session)
  end

  test "an irreducible current prompt keeps its measured ordinary refusal" do
    {fixture, session, run_id, _configuration} =
      retained_automatic_prompt(String.duplicate("p", 20_000))

    successor = start(store: fixture.store, tools: [], script: [])

    {:ok, {:prepared, activation}} =
      Loopex.prepare_resume_session(successor.runtime, session, "resume-irreducible")

    assert {:ok, ^session} = Loopex.activate_resume(activation)
    rows = await_parent_terminal(successor, session, run_id, now() + 5_000)

    refute Enum.any?(rows, &(&1.payload.kind == "maintenance_episode_admitted_v1"))
    assert [refusal] = Enum.filter(rows, &(&1.payload.kind == "context_admission_refused_v2"))
    assert refusal.payload["failure"]["category"] == "context_budget_exceeded"
    assert refusal.payload["failure"]["dimension"] == "context_tokens"
    assert refusal.payload["failure"]["observed"] > 4_000
    assert AgentLoopTestModel.dispatched(successor.model) == []
    assert Agent.get(successor.executor, & &1.jobs) == []
    stop_and_join(successor, session)
  end

  defp await_parent_terminal(fixture, session, run, cutoff) do
    rows = Fixture.records(fixture, session)

    if Enum.any?(
         rows,
         &(&1.payload.kind == "run_terminal_committed" and &1.payload["run_id"] == run)
       ) do
      rows
    else
      assert now() < cutoff
      Process.sleep(1)
      await_parent_terminal(fixture, session, run, cutoff)
    end
  end

  defp retained_automatic_prompt(content \\ "retained") do
    fixture = start(script: [], tools: [])

    configuration =
      Genesis.configuration()
      |> Map.put("context_token_budget", 4_000)
      |> Map.put("system_class_tokens", 2_048)
      |> Map.update!("budget_origins", &Map.put(&1, "context_token_budget", "explicit"))

    {:ok, session} =
      Loopex.create_session(fixture.runtime, %{},
        command_id: "create",
        genesis: Genesis.genesis([], configuration)
      )

    assert :ok = Loopex.stop(fixture.runtime)

    {:ok, state} =
      SessionState.recover(
        session,
        Fixture.records(fixture, session),
        Fixture.events(fixture, session)
      )

    {:ok, old} =
      SessionState.propose(
        state,
        %{type: :prompt, command_id: "old", content: String.duplicate("o", 30_000)},
        %{
          max_turns: 8,
          token_budget: 10_000,
          deadline_ms: 60_000,
          context_token_budget: configuration["context_token_budget"]
        }
      )

    state = retain(fixture, state, old)

    {:ok, finished} =
      SessionState.propose_run_terminal(state, state.active_run_id, "failed", %{
        reason: "model_call_failed"
      })

    state = retain(fixture, state, finished)

    {:ok, prompt} =
      SessionState.propose(
        state,
        %{type: :prompt, command_id: "automatic", content: content},
        %{
          max_turns: 8,
          token_budget: 10_000,
          deadline_ms: 60_000,
          context_token_budget: configuration["context_token_budget"]
        }
      )

    state = retain(fixture, state, prompt)
    {fixture, session, state.active_run_id, configuration}
  end

  # Concept: recovery starts from a committed episode with no summary dispatch.
  # Technical depth: the fixture uses public exact creation, stops that runtime, then
  # commits prompt and episode reducer proposals through the actual
  # Store transaction boundary. This supplies the durable boundary the live
  # automatic trigger has not yet joined, without mutating coordinator cache.
  defp retained_episode(mode) do
    fixture = start(script: [], tools: [])

    configuration =
      if mode == :exhausted do
        Genesis.configuration(String.duplicate("s", 10_000))
        |> Map.put("system_class_tokens", 4_000)
        |> Map.put("context_token_budget", 4_000)
        |> Map.update!("budget_origins", &Map.put(&1, "context_token_budget", "explicit"))
      else
        Genesis.configuration()
      end

    {:ok, session} =
      Loopex.create_session(fixture.runtime, %{},
        command_id: "create",
        genesis: Genesis.genesis([], configuration)
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
            %{
              type: :prompt,
              command_id: "old",
              content:
                if(
                  mode in [
                    :exhausted,
                    :source_pending,
                    :checkpoint_more,
                    :checkpoint_pending,
                    :checkpoint_committed,
                    :checkpoint_committed_aborted,
                    :checkpoint_committed_expired,
                    :checkpoint_aborted,
                    :checkpoint_expired,
                    :checkpoint_spent_tokens,
                    :checkpoint_spent_turns
                  ],
                  do:
                    cond do
                      mode == :exhausted -> String.duplicate("o", 10_000)
                      mode in [:source_pending, :checkpoint_more] -> String.duplicate("o", 30_000)
                      true -> String.duplicate("old", 1_000)
                    end,
                  else: "original facts"
                )
            },
            %{
              max_turns: 8,
              token_budget: 10_000,
              deadline_ms: 60_000,
              context_token_budget: configuration["context_token_budget"]
            }
          )

        prior = retain(fixture, state, old)

        {:ok, ending} =
          SessionState.propose_run_terminal(prior, prior.active_run_id, "failed", %{
            reason: "model_call_failed"
          })

        retain(fixture, prior, ending)
      end

    state =
      if mode in [:exhausted, :checkpoint_more] do
        count = if mode == :exhausted, do: 3, else: 1

        Enum.reduce(1..count, state, fn ordinal, state ->
          {:ok, prompt} =
            SessionState.propose(
              state,
              %{
                type: :prompt,
                command_id: "old-#{ordinal}",
                content: String.duplicate("o", if(mode == :exhausted, do: 10_000, else: 30_000))
              },
              %{
                max_turns: 8,
                token_budget: 10_000,
                deadline_ms: 60_000,
                context_token_budget: configuration["context_token_budget"]
              }
            )

          state = retain(fixture, state, prompt)

          {:ok, ending} =
            SessionState.propose_run_terminal(state, state.active_run_id, "failed", %{
              reason: "model_call_failed"
            })

          retain(fixture, state, ending)
        end)
      else
        state
      end

    {:ok, prompt} =
      SessionState.propose(state, %{type: :prompt, command_id: "prompt", content: "retained"}, %{
        max_turns: if(mode == :checkpoint_spent_turns, do: 1, else: 8),
        token_budget: 10_000,
        deadline_ms: 60_000,
        context_token_budget: configuration["context_token_budget"]
      })

    state = retain(fixture, state, prompt)
    assert AgentLoopTestModel.dispatched(fixture.model) == []

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
          mode == :expired ->
            60_000

          mode in [
            :open_expired,
            :invalid_expired,
            :checkpoint_expired,
            :checkpoint_committed_expired
          ] ->
            60_002

          true ->
            0
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
      if mode in [:expired, :aborted, :source_pending] do
        state
      else
        {:ok, request} =
          SessionState.propose_maintenance_request(state, 1, admitted_at + 1, fn -> :ok end)

        retain(fixture, state, request)
      end

    state =
      if mode == :exhausted do
        {:ok, not_sent} = SessionState.propose_maintenance_attempt_settled(state, :not_dispatched)
        state = retain(fixture, state, not_sent)
        {:ok, retry} = SessionState.propose_maintenance_attempt_open(state)
        retain(fixture, state, retry)
      else
        state
      end

    state =
      if mode in [
           :exhausted,
           :checkpoint_more,
           :invalid,
           :incomplete,
           :invalid_aborted,
           :invalid_expired,
           :nonprogress,
           :checkpoint_pending,
           :checkpoint_committed,
           :checkpoint_committed_aborted,
           :checkpoint_committed_expired,
           :checkpoint_aborted,
           :checkpoint_expired,
           :checkpoint_spent_tokens,
           :checkpoint_spent_turns
         ] do
        request = state.maintenance_episodes[state.active_maintenance]["request"]

        raw =
          request
          |> retained_summary_reply()
          |> Map.put(
            :text,
            if(mode in [:invalid, :incomplete, :invalid_aborted, :invalid_expired],
              do: "{}",
              else:
                ~s({"summary":"retained facts","carry_forward":{"files_read":[],"files_changed":[]}})
            )
          )
          |> Map.put(
            :usage,
            if(mode == :checkpoint_spent_tokens,
              do: %{},
              else: %{input_tokens: 37, output_tokens: 19}
            )
          )
          |> Map.put(:completion, if(mode == :incomplete, do: "limit", else: "natural"))

        {:ok, settlement} = SessionState.propose_maintenance_attempt_settled(state, {:reply, raw})
        retain(fixture, state, settlement)
      else
        state
      end

    state =
      if mode in [
           :exhausted,
           :checkpoint_more,
           :checkpoint_committed,
           :checkpoint_committed_aborted,
           :checkpoint_committed_expired
         ] do
        {:ok, checkpoint} =
          SessionState.propose_maintenance_checkpoint(state, admitted_at + 2, fn -> :ok end)

        retain(fixture, state, checkpoint)
      else
        state
      end

    state =
      if mode == :exhausted do
        Enum.reduce(2..3, state, fn ordinal, state ->
          {:ok, request} =
            SessionState.propose_maintenance_request(state, 1, admitted_at + ordinal * 2, fn ->
              :ok
            end)

          state = retain(fixture, state, request)
          request = state.maintenance_episodes[state.active_maintenance]["request"]

          {:ok, settlement} =
            SessionState.propose_maintenance_attempt_settled(
              state,
              {:reply, retained_summary_reply(request)}
            )

          state = retain(fixture, state, settlement)

          {:ok, checkpoint} =
            SessionState.propose_maintenance_checkpoint(
              state,
              admitted_at + ordinal * 2 + 1,
              fn -> :ok end
            )

          retain(fixture, state, checkpoint)
        end)
      else
        state
      end

    if mode in [
         :aborted,
         :open_aborted,
         :invalid_aborted,
         :checkpoint_aborted,
         :checkpoint_committed_aborted
       ] do
      {:ok, abort} = SessionState.propose(state, %{type: :abort, command_id: "abort"})
      retain(fixture, state, abort)
    end

    if mode == :exhausted do
      assert state.maintenance_episodes[state.active_maintenance]["attempts"] == 4
      assert state.maintenance_episodes[state.active_maintenance]["summary_ordinal"] == 3
      assert map_size(state.checkpoints) == 3
      assert state.charged[state.active_run_id] == %{tokens: 168, source: :reported}

      assert {:error, {:checkpoint_requires_more_progress, _}} =
               SessionState.propose_maintenance_checkpoint_completion(
                 state,
                 admitted_at + 8,
                 fn -> :ok end
               )
    end

    {fixture, session, hd(admission.records)}
  end

  defp retained_summary_reply(request) do
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
