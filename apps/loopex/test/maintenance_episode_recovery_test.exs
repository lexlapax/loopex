Code.require_file("support/progress_test_consumer.exs", __DIR__)
Code.require_file("support/m1_runtime_helper.exs", __DIR__)
Code.require_file("support/agent_loop_helper.exs", __DIR__)
Code.require_file("support/configured_genesis_helper.exs", __DIR__)

defmodule Loopex.Runtime.MaintenanceEpisodeRecoveryTest do
  use ExUnit.Case, async: false
  import Loopex.ProgressTestConsumer

  alias Loopex.AgentLoopFixture, as: Fixture
  alias Loopex.AgentLoopTestModel
  alias Loopex.ConfiguredGenesisFixture, as: Genesis
  alias Loopex.M1RuntimeTestStore
  alias Loopex.Runtime.{MaintenanceConfiguration, SessionState}
  alias Loopex.Store

  test "thinking preparation continues past a hard-limit fit until the captured targets fit" do
    {fixture, session, run_id, configuration} =
      retained_automatic_prompt("retained",
        context_token_budget: 10_000,
        continuation_required: true,
        old_contents: [String.duplicate("a", 10_000), String.duplicate("b", 17_000)]
      )

    {:ok, original} =
      SessionState.recover(
        session,
        Fixture.records(fixture, session),
        Fixture.events(fixture, session)
      )

    selection = %{
      "model" => configuration["model"],
      "reasoning" => "none",
      "model_capabilities" => %{
        configuration["model_capabilities"]
        | "reasoning_levels" => ["none"]
      },
      "provider_mapping" => %{
        configuration["provider_mapping"]
        | "thinking_disabled" => true,
          "continuation_required" => false
      }
    }

    summary = %{
      text: ~s({"summary":"retained facts","carry_forward":{"files_read":[],"files_changed":[]}}),
      usage: %{input_tokens: 37, output_tokens: 19},
      reply_overrides: %{completion: "natural", continuation: nil}
    }

    capsule = %{
      "format" => "loopex.anthropic.content_refs.v1",
      "provider" => "anthropic",
      "model" => "scripted:v1",
      "status" => "closed",
      "content" => [
        %{
          "kind" => "text_ref",
          "byte_length" => 9,
          "template" => %{"type" => "text"},
          "field" => "text"
        }
      ]
    }

    successor =
      start(
        store: fixture.store,
        tools: [],
        maintenance_model: selection,
        maintenance_instructions: %{"version" => "summary.v1", "body" => "Keep the facts"},
        script: [
          summary,
          summary,
          %{
            text: "continued",
            require_previous_worker_down: true,
            reply_overrides: %{completion: "natural", continuation: capsule}
          }
        ]
      )

    assert {:ok, ^session} =
             Loopex.resume_session(successor.runtime, session, command_id: "resume-headroom")

    rows = await_parent_terminal(successor, session, run_id, now() + 5_000)
    assert List.last(rows).payload["outcome"] == "completed"
    assert [episode] = Enum.filter(rows, &(&1.payload.kind == "maintenance_episode_admitted_v1"))
    assert episode.payload["trigger"] == "thinking_headroom"

    assert episode.payload["targets"] == %{
             "revision" => "loopex.thinking_headroom.v1",
             "record_target" => 32_768,
             "input_target" => 5_000
           }

    assert Enum.count(rows, &(&1.payload.kind == "compaction_checkpoint_committed_v1")) == 2

    # Concept: ADR 0069 run evidence includes this run's own maintenance.
    # Technical depth: two summary attempts report 37/19 each and the ordinary
    # continuation reports the scripted 1/1, all charged to this run.
    assert {:ok, %{usage: usage, terminal: %{state: "completed"}}} =
             SessionState.run_evidence(session, rows, run_id)

    assert usage == %{reported_input: 75, reported_output: 39, estimated: 0, unresolved: false}

    [first_checkpoint, _] =
      Enum.filter(rows, &(&1.payload.kind == "compaction_checkpoint_committed_v1"))

    events = Fixture.events(successor, session)
    first_event = Enum.find(events, &(&1.kind == "context.compacted"))
    first_rows = Enum.take_while(rows, &(&1.journal_version <= first_checkpoint.journal_version))
    first_events = Enum.take_while(events, &(&1.event_sequence <= first_event.event_sequence))
    assert {:ok, partial} = SessionState.recover(session, first_rows, first_events)

    assert {:error, {:checkpoint_requires_more_progress, headroom}} =
             SessionState.propose_maintenance_checkpoint_completion(
               partial,
               partial.checkpoints[partial.active_checkpoint]["committed_at"],
               fn -> :ok end
             )

    assert headroom["category"] == "thinking_exchange_headroom"
    assert headroom["observed"] > headroom["limit"]
    assert headroom["observed"] <= headroom["hard_limit"]
    assert [first, second, ordinary] = AgentLoopTestModel.dispatched(successor.model)
    assert first.sampling["max_tokens"] == 1_024
    assert second.continuation == nil
    assert ordinary.continuation == nil
    assert first.deadline == second.deadline and second.deadline == ordinary.deadline
    assert first.tools == [] and second.tools == []
    assert [request] = Enum.filter(rows, &(&1.payload.kind == "model_request_committed_v2"))
    assert request.payload["context_receipt"]["provider_estimated_tokens"] <= 5_000
    assert request.payload["context_receipt"]["record_byte_cost"] <= 32_768

    assert {:ok, recovered} =
             SessionState.recover(session, rows, Fixture.events(successor, session))

    assert recovered.maintenance_episodes[episode.payload["episode_id"]]["usage"]["total_tokens"] ==
             112

    assert recovered.charged[run_id].tokens == 114

    for altered <- [
          put_in(episode, [:payload, "targets", "input_target"], 5_001),
          put_in(episode, [:payload, "targets", "revision"], "future"),
          put_in(episode, [:payload, "targets"], nil),
          update_in(episode, [:payload], &Map.delete(&1, "targets"))
        ] do
      changed =
        Enum.map(rows, fn row ->
          if row.journal_version == episode.journal_version, do: altered, else: row
        end)

      assert {:error, _} = SessionState.recover(session, changed, events)
    end

    for old <- Enum.drop(original.run_order, -1) do
      assert SessionState.elements(recovered, old) == SessionState.elements(original, old)
    end

    assert Agent.get(successor.executor, & &1.jobs) == []
    stop_and_join(successor, session)
  end

  test "irreducible initial thinking input refuses its target before any maintenance or ordinary dispatch" do
    {fixture, session, run_id, _configuration} =
      retained_automatic_prompt(String.duplicate("p", 7_000),
        context_token_budget: 3_000,
        continuation_required: true,
        old_contents: []
      )

    successor = start(store: fixture.store, tools: [], script: [])

    assert {:ok, ^session} =
             Loopex.resume_session(successor.runtime, session,
               command_id: "resume-irreducible-headroom"
             )

    rows = await_parent_terminal(successor, session, run_id, now() + 5_000)
    assert [refusal, terminal] = Enum.take(rows, -2)
    assert refusal.payload["failure"]["category"] == "thinking_exchange_headroom"
    assert refusal.payload["failure"]["dimension"] == "context_tokens"
    assert refusal.payload["failure"]["limit"] == 1_500
    assert refusal.payload["failure"]["hard_limit"] == 3_000
    assert refusal.payload["failure"]["observed"] > 1_500
    assert refusal.payload["failure"]["observed"] <= 3_000
    assert terminal.payload["failure"] == refusal.payload["failure"]
    refute Enum.any?(rows, &(&1.payload.kind == "maintenance_episode_admitted_v1"))
    assert AgentLoopTestModel.dispatched(successor.model) == []
    assert {:ok, _} = SessionState.recover(session, rows, Fixture.events(successor, session))

    for altered <- [
          put_in(refusal, [:payload, "targets", "input_target"], 1_501),
          put_in(refusal, [:payload, "targets", "revision"], "future"),
          put_in(refusal, [:payload, "failure", "hard_limit"], 3_001),
          put_in(refusal, [:payload, "failure", "observed"], 1_500)
        ] do
      changed =
        Enum.map(rows, fn row ->
          if row.journal_version == refusal.journal_version, do: altered, else: row
        end)

      assert {:error, _} =
               SessionState.recover(session, changed, Fixture.events(successor, session))
    end

    stop_and_join(successor, session)
  end

  for mode <- [:source_pending, :checkpoint_more] do
    @mode mode
    @tag :long_bound
    @tag timeout: 75_000
    test "the captured live #{@mode} cutoff joins a held source worker before ending" do
      {fixture, session, episode} = retained_episode(@mode)
      before = Fixture.records(fixture, session)
      {:ok, original} = SessionState.recover(session, before, Fixture.events(fixture, session))
      successor = start(store: fixture.store, tools: [], script: [])

      {:ok, {:prepared, activation}} =
        Loopex.prepare_resume_session(successor.runtime, session, "resume-live-source-cutoff")

      {:ok, children} = Loopex.Runtime.children(successor.runtime)
      coordinator = :sys.get_state(children.control).sessions[session].coordinator
      workers = :sys.get_state(coordinator).owner_workers
      hold_next_source_worker(workers)
      assert {:ok, ^session} = Loopex.activate_resume(activation)
      assert_receive {:held_maintenance_source_worker, worker}, 5_000

      assert [{_, {:maintenance_preparation, run_id, ^worker, metadata}}] =
               coordinator |> :sys.get_state() |> Map.fetch!(:in_flight) |> Map.to_list()

      assert run_id == episode["run_id"]
      assert episode["preparation_deadline"] == episode["admitted_at"] + 60_000
      assert System.system_time(:millisecond) < metadata.deadline

      if @mode == :source_pending do
        assert metadata.origin == :preparation
        assert metadata.deadline == episode["preparation_deadline"]
        assert original.deadlines == %{}
      else
        assert metadata.origin == :run
        assert metadata.deadline == original.deadlines[run_id]
      end

      monitor = Process.monitor(worker)
      captured_rows = Fixture.records(successor, session)
      refute Enum.any?(captured_rows, &(&1.payload.kind == "maintenance_episode_terminal_v1"))
      assert AgentLoopTestModel.dispatched(successor.model) == []

      # Concept: this case waits through the retained production cutoff.
      # Technical depth: no clock, episode or timer is replaced. The existing
      # 5,000-ms fixture join grace starts at that captured absolute deadline.
      join_wait = metadata.deadline - System.system_time(:millisecond) + 5_000
      assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}, join_wait
      assert System.system_time(:millisecond) >= metadata.deadline
      rows = await_parent_terminal(successor, session, run_id, now() + 5_000)
      ending = Enum.find(rows, &(&1.payload.kind == "maintenance_episode_terminal_v1"))
      assert ending.payload["episode_id"] == episode["episode_id"]
      assert ending.payload["result"]["checkpoint_id"] == original.active_checkpoint

      assert ending.payload["result"]["usage"] ==
               original.maintenance_episodes[episode["episode_id"]]["usage"]

      if @mode == :source_pending do
        assert [^ending, refusal, terminal] = Enum.take(rows, -3)
        assert refusal.payload.kind == "context_admission_refused_v2"
        assert terminal.payload["outcome"] == "failed"
        assert terminal.payload["failure"]["cause"] == "compaction_preparation_deadline"
        assert ending.payload["observed_at"] >= metadata.deadline
        assert terminal.payload["bound"] == nil
        assert terminal.payload["observed"] == nil
        refute Enum.any?(rows, &(&1.payload.kind == "run_deadline_committed"))
      else
        assert [^ending, terminal] = Enum.take(rows, -2)
        assert terminal.payload["outcome"] == "bound_reached"
        assert terminal.payload["bound"] == "deadline"
        refute Enum.any?(rows, &(&1.payload.kind == "context_admission_refused_v2"))
      end

      assert Enum.count(rows, &(&1.payload.kind == "maintenance_episode_terminal_v1")) == 1
      assert Enum.take(rows, length(captured_rows)) == captured_rows

      assert Enum.filter(rows, &(&1.payload.kind == "maintenance_request_committed_v1")) ==
               Enum.filter(before, &(&1.payload.kind == "maintenance_request_committed_v1"))

      assert AgentLoopTestModel.dispatched(successor.model) == []
      assert Agent.get(successor.executor, & &1.jobs) == []
      assert :sys.get_state(coordinator).in_flight == %{}
      assert Task.Supervisor.children(workers) == []

      assert {:ok, recovered} =
               SessionState.recover(session, rows, Fixture.events(successor, session))

      assert recovered.active_run_id == nil
      assert recovered.active_maintenance == nil
      assert recovered.active_checkpoint == original.active_checkpoint
      assert recovered.checkpoints == original.checkpoints
      assert recovered.charged == original.charged
      assert recovered.conversation == original.conversation
      stop_and_join(successor, session)
    end
  end

  for mode <- [:source_pending, :checkpoint_more] do
    @mode mode
    test "succession joins the held #{@mode} source worker before continuing its captured episode" do
      {fixture, session, episode} = retained_episode(@mode)
      before = Fixture.records(fixture, session)
      {:ok, original} = SessionState.recover(session, before, Fixture.events(fixture, session))

      successor =
        start(
          store: fixture.store,
          model: "changed:model",
          tools: [],
          script: [
            %{
              text:
                ~s({"summary":"continued retained facts","carry_forward":{"files_read":[],"files_changed":[]}}),
              usage: %{input_tokens: 37, output_tokens: 19},
              reply_overrides: %{completion: "natural", continuation: nil}
            },
            %{
              text: "continued",
              require_previous_worker_down: true,
              reply_overrides: %{completion: "natural", continuation: nil}
            }
          ]
        )

      {:ok, {:prepared, activation}} =
        Loopex.prepare_resume_session(successor.runtime, session, "resume-source-predecessor")

      {:ok, children} = Loopex.Runtime.children(successor.runtime)
      predecessor = :sys.get_state(children.control).sessions[session].coordinator
      predecessor_state = :sys.get_state(predecessor)
      hold_next_source_worker(predecessor_state.owner_workers)
      assert {:ok, ^session} = Loopex.activate_resume(activation)
      assert_receive {:held_maintenance_source_worker, worker}, 5_000

      assert [{_, {:maintenance_preparation, _, ^worker, _}}] =
               predecessor |> :sys.get_state() |> Map.fetch!(:in_flight) |> Map.to_list()

      captured_rows = Fixture.records(successor, session)
      captured_events = Fixture.events(successor, session)
      worker_monitor = Process.monitor(worker)
      predecessor_monitor = Process.monitor(predecessor)

      assert {:ok, {:prepared, replacement_activation}} =
               Loopex.prepare_resume_session(
                 successor.runtime,
                 session,
                 "resume-source-successor"
               )

      assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :killed}, 5_000
      assert_receive {:DOWN, ^predecessor_monitor, :process, ^predecessor, :normal}, 5_000
      replacement = :sys.get_state(children.control).sessions[session].coordinator
      replacement_state = :sys.get_state(replacement)
      assert replacement != predecessor
      assert replacement_state.durable.owner_epoch == predecessor_state.durable.owner_epoch + 1
      assert replacement_state.in_flight == %{}
      assert Task.Supervisor.children(replacement_state.owner_workers) == []

      paused = Fixture.records(successor, session)
      assert Enum.take(paused, length(captured_rows)) == captured_rows
      assert [owner] = Enum.drop(paused, length(captured_rows))
      assert owner.payload.kind == "owner_advanced"
      assert Fixture.events(successor, session) == captured_events
      assert AgentLoopTestModel.dispatched(successor.model) == []

      assert replacement_state.durable.maintenance_episodes[episode["episode_id"]] ==
               original.maintenance_episodes[episode["episode_id"]]

      assert replacement_state.durable.checkpoints == original.checkpoints
      assert replacement_state.durable.charged == original.charged
      assert {:ok, ^session} = Loopex.activate_resume(replacement_activation)
      rows = await_parent_terminal(successor, session, episode["run_id"], now() + 5_000)
      assert List.last(rows).payload["outcome"] == "completed"
      refute Enum.any?(rows, &(&1.payload.kind == "context_admission_refused_v2"))

      assert [ending] =
               Enum.filter(rows, &(&1.payload.kind == "maintenance_episode_terminal_v1"))

      assert ending.payload["episode_id"] == episode["episode_id"]
      assert ending.payload["result"]["disposition"] == "checkpointed"

      assert ending.payload["result"]["usage"]["total_tokens"] ==
               original.maintenance_episodes[episode["episode_id"]]["usage"]["total_tokens"] + 56

      assert [maintenance, ordinary] = AgentLoopTestModel.dispatched(successor.model)
      assert maintenance.model == episode["maintenance_configuration"]["selection"]["model"]
      assert ordinary.model == Genesis.configuration()["model"]

      assert {:ok, source} =
               LoopexProtocol.Frame.decode(Enum.at(maintenance.messages, 1)["content"], 16_384)

      assert source["prior_checkpoint"] ==
               if(original.active_checkpoint,
                 do: original.checkpoints[original.active_checkpoint]["summary"],
                 else: nil
               )

      assert Agent.get(successor.executor, & &1.jobs) == []

      assert {:ok, recovered} =
               SessionState.recover(session, rows, Fixture.events(successor, session))

      assert recovered.active_run_id == nil
      assert recovered.active_maintenance == nil

      for old <- Enum.drop(recovered.run_order, -1) do
        assert SessionState.elements(recovered, old) == SessionState.elements(original, old)
      end

      assert :sys.get_state(replacement).in_flight == %{}
      assert Task.Supervisor.children(replacement_state.owner_workers) == []
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
    test "a killed #{@mode} source worker joins before its #{@phase} unavailable ending" do
      {fixture, session, episode} = retained_episode(@mode)
      before = Fixture.records(fixture, session)
      {:ok, original} = SessionState.recover(session, before, Fixture.events(fixture, session))
      assert :ok = SessionState.preflight_run_history(original, episode["run_id"])
      successor = start(store: fixture.store, tools: [], script: [])

      {:ok, {:prepared, activation}} =
        Loopex.prepare_resume_session(successor.runtime, session, "resume-killed-source")

      {:ok, children} = Loopex.Runtime.children(successor.runtime)
      coordinator = :sys.get_state(children.control).sessions[session].coordinator
      coordinator_monitor = Process.monitor(coordinator)
      workers = :sys.get_state(coordinator).owner_workers
      hold_next_source_worker(workers)
      assert {:ok, ^session} = Loopex.activate_resume(activation)
      assert_receive {:held_maintenance_source_worker, worker}, 5_000

      assert [{_reference, {:maintenance_preparation, run_id, ^worker, metadata}}] =
               coordinator |> :sys.get_state() |> Map.fetch!(:in_flight) |> Map.to_list()

      assert run_id == episode["run_id"]
      assert metadata.journal_version == length(Fixture.records(successor, session))

      unless @phase == :none do
        :ok = M1RuntimeTestStore.inject(fixture.store, {:session_journal_commit, @phase})
      end

      monitor = Process.monitor(worker)
      Process.exit(worker, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}, 5_000

      rows = await_parent_terminal(successor, session, run_id, now() + 5_000)
      events = Fixture.events(successor, session)

      if @phase == :recovery_representation do
        assert_receive {:DOWN, ^coordinator_monitor, :process, ^coordinator,
                        {:context_preparation_failed, :commit_unknown}},
                       5_000

        assert {:ok, ^session} =
                 Loopex.resume_session(successor.runtime, session,
                   command_id: "resolve-source-failure"
                 )

        rows = Fixture.records(successor, session)
        assert Enum.count(rows, &(&1.payload.kind == "maintenance_episode_terminal_v1")) == 1
        assert Fixture.events(successor, session) == events
      else
        refute_received {:DOWN, ^coordinator_monitor, :process, ^coordinator, _}
        assert :sys.get_state(coordinator).in_flight == %{}
      end

      assert [ending, refusal, terminal] = Enum.take(rows, -3)
      assert ending.payload.kind == "maintenance_episode_terminal_v1"
      assert ending.payload["episode_id"] == episode["episode_id"]
      assert refusal.payload.kind == "context_admission_refused_v2"
      assert terminal.payload.kind == "run_terminal_committed"
      assert terminal.payload["outcome"] == "failed"

      assert terminal.payload["failure"] == %{
               "version" => 2,
               "category" => "context_preparation_failed",
               "retryable" => false,
               "measurement_scope" => nil,
               "cause" => "context_projection_invalid"
             }

      assert ending.payload["result"]["failure"] == terminal.payload["failure"]
      assert refusal.payload["failure"] == terminal.payload["failure"]

      assert ending.payload["result"]["usage"] ==
               original.maintenance_episodes[episode["episode_id"]]["usage"]

      assert ending.payload["result"]["checkpoint_id"] == original.active_checkpoint
      assert ending.payload["observed_at"] >= episode["admitted_at"]
      assert ending.payload["observed_at"] < metadata.deadline
      assert AgentLoopTestModel.dispatched(successor.model) == []
      assert Agent.get(successor.executor, & &1.jobs) == []

      assert Enum.filter(rows, &(&1.payload.kind == "maintenance_request_committed_v1")) ==
               Enum.filter(before, &(&1.payload.kind == "maintenance_request_committed_v1"))

      assert {:ok, recovered} =
               SessionState.recover(session, rows, Fixture.events(successor, session))

      assert recovered.active_maintenance == nil
      assert recovered.active_run_id == nil
      assert recovered.active_checkpoint == original.active_checkpoint
      assert recovered.checkpoints == original.checkpoints
      assert recovered.conversation == original.conversation
      assert recovered.charged == original.charged

      for changed <- [nil, episode["admitted_at"] - 1, metadata.deadline] do
        altered =
          Enum.map(rows, fn row ->
            if row.journal_version == ending.journal_version,
              do: put_in(row, [:payload, "observed_at"], changed),
              else: row
          end)

        assert {:error, _} = SessionState.recover(session, altered, events)
      end

      assert {:error, _} =
               SessionState.recover(session, List.delete(rows, ending), events)

      stop_and_join(successor, session)
    end
  end

  for mode <- [:source_pending, :checkpoint_more] do
    @mode mode
    test "abort joins the held #{@mode} source worker without replacing cancellation" do
      {fixture, session, episode} = retained_episode(@mode)
      before = Fixture.records(fixture, session)
      {:ok, original} = SessionState.recover(session, before, Fixture.events(fixture, session))
      successor = start(store: fixture.store, tools: [], script: [])

      {:ok, {:prepared, activation}} =
        Loopex.prepare_resume_session(successor.runtime, session, "resume-source-abort")

      {:ok, attachment} = Loopex.attach(successor.runtime, session, after_event_sequence: 0)
      {:ok, children} = Loopex.Runtime.children(successor.runtime)
      coordinator = :sys.get_state(children.control).sessions[session].coordinator
      hold_next_source_worker(:sys.get_state(coordinator).owner_workers)
      assert {:ok, ^session} = Loopex.activate_resume(activation)
      assert_receive {:held_maintenance_source_worker, worker}, 5_000

      assert [{_, {:maintenance_preparation, _, ^worker, _}}] =
               coordinator |> :sys.get_state() |> Map.fetch!(:in_flight) |> Map.to_list()

      monitor = Process.monitor(worker)

      assert {:accepted, "abort-held-source"} =
               Loopex.command(attachment, %{type: :abort, command_id: "abort-held-source"})

      assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}, 5_000
      rows = await_parent_terminal(successor, session, episode["run_id"], now() + 5_000)
      assert [ending, terminal] = Enum.take(rows, -2)
      assert ending.payload.kind == "maintenance_episode_terminal_v1"
      assert terminal.payload.kind == "run_terminal_committed"
      assert terminal.payload["outcome"] == "cancelled"
      assert terminal.payload["command_id"] == "abort-held-source"

      assert ending.payload["result"]["failure"] == %{
               "category" => "cancelled",
               "retryable" => false
             }

      assert ending.payload["result"]["checkpoint_id"] == original.active_checkpoint

      assert ending.payload["result"]["usage"] ==
               original.maintenance_episodes[episode["episode_id"]]["usage"]

      refute Enum.any?(rows, &(&1.payload.kind == "context_admission_refused_v2"))
      assert AgentLoopTestModel.dispatched(successor.model) == []
      assert Agent.get(successor.executor, & &1.jobs) == []

      assert {:ok, recovered} =
               SessionState.recover(session, rows, Fixture.events(successor, session))

      assert recovered.checkpoints == original.checkpoints
      assert recovered.charged == original.charged
      stop_and_join(successor, session)
    end
  end

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

      assert [view, %{"active_maintenance" => nil}] =
               Enum.filter(events, &(&1.kind == "context.maintenance_changed"))

      assert view["active_maintenance"]["episode_id"] == episode["episode_id"]
      assert view["active_maintenance"]["owner"]["kind"] == "run"
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
             &(&1.payload.kind == "outcome_unknown_committed_v2")
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
    @expected_cleanup if(mode in [:open, :open_aborted, :open_expired],
                        do: "unknown",
                        else: "confirmed"
                      )
    @forged_cleanup if(mode in [:open, :open_aborted, :open_expired],
                      do: "confirmed",
                      else: "unknown"
                    )
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

      assert prefix.payload["result"]["cleanup"] == @expected_cleanup
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

      forged =
        Enum.map(rows, fn
          %{payload: %{kind: "maintenance_episode_terminal_v1"}} = row ->
            put_in(row, [:payload, "result", "cleanup"], @forged_cleanup)

          row ->
            row
        end)

      assert {:error, :invalid_run_terminal_transition} =
               SessionState.recover(session, forged, Fixture.events(successor, session))

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

  for phase <- [
        :none,
        :before_linearization,
        :after_linearization_before_result,
        :recovery_representation
      ] do
    @phase phase
    test "live reply-reserve refusal resolves #{@phase} without dispatch or invented spending" do
      {fixture, session, episode} = retained_episode(:reserve_unavailable)

      {:ok, original} =
        SessionState.recover(
          session,
          Fixture.records(fixture, session),
          Fixture.events(fixture, session)
        )

      assert original.charged[episode["run_id"]] == %{tokens: 9_500, source: :reported}
      assert original.active_checkpoint != nil
      successor = start(store: fixture.store, script: [], tools: [])

      {:ok, {:prepared, activation}} =
        Loopex.prepare_resume_session(successor.runtime, session, "resume")

      {:ok, children} = Loopex.Runtime.children(successor.runtime)
      coordinator = :sys.get_state(children.control).sessions[session].coordinator
      monitor = Process.monitor(coordinator)
      assert :sys.get_state(coordinator).in_flight == %{}

      if @phase != :none,
        do: M1RuntimeTestStore.inject(fixture.store, {:session_journal_commit, @phase})

      assert {:ok, ^session} = Loopex.activate_resume(activation)

      if @phase == :recovery_representation do
        assert_receive {:DOWN, ^monitor, :process, ^coordinator,
                        {:maintenance_checkpoint_failed, :commit_unknown}},
                       5_000

        assert {:ok, ^session} =
                 Loopex.resume_session(successor.runtime, session, command_id: "resolve-reserve")
      end

      rows = await_parent_terminal(successor, session, episode["run_id"], now() + 5_000)
      assert [prefix] = Enum.filter(rows, &(&1.payload.kind == "maintenance_episode_terminal_v1"))

      assert [refusal, terminal] =
               rows
               |> Enum.drop_while(&(&1.journal_version <= prefix.journal_version))
               |> Enum.take(2)

      assert refusal.payload.kind == "context_admission_refused_v2"
      assert refusal.payload["failure"]["cause"] == "maintenance_reply_reserve_unavailable"
      assert refusal.payload["measurement_scope"] == nil
      assert refusal.payload["provider_estimated_tokens"] == nil
      assert terminal.payload.kind == "run_terminal_committed"
      assert terminal.payload["outcome"] == "failed"
      assert terminal.payload["failure"] == refusal.payload["failure"]
      assert prefix.payload["result"]["failure"] == refusal.payload["failure"]
      assert prefix.payload["result"]["usage"]["total_tokens"] == 9_500
      assert prefix.payload["result"]["checkpoint_id"] == original.active_checkpoint
      assert Enum.count(rows, &(&1.payload.kind == "maintenance_attempt_opened_v1")) == 1
      assert Enum.count(rows, &(&1.payload.kind == "maintenance_attempt_settled_v3")) == 1
      assert Enum.count(rows, &(&1.payload.kind == "context_admission_refused_v2")) == 1

      assert Enum.count(
               rows,
               &(&1.payload.kind == "run_terminal_committed" and
                   &1.payload["run_id"] == episode["run_id"])
             ) == 1

      refute Enum.any?(rows, &(&1.payload.kind == "model_request_committed_v2"))
      assert AgentLoopTestModel.dispatched(successor.model) == []
      assert Agent.get(successor.executor, & &1.jobs) == []

      assert {:ok, recovered} =
               SessionState.recover(session, rows, Fixture.events(successor, session))

      assert recovered.charged == original.charged
      assert recovered.checkpoints == original.checkpoints
      assert recovered.active_checkpoint == original.active_checkpoint
      assert recovered.active_run_id == nil
      assert recovered.active_maintenance == nil
      stop_and_join(successor, session)
      Process.demonitor(monitor, [:flush])
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
          progress_sink: Loopex.ProgressTestConsumer.open_sink(),
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
        assert_progress({:loopex_progress, %{kind: :text_delta, text: "ordinary delta"}}, 5_000)

        refute_progress_received(
          {:loopex_progress, %{kind: :text_delta, text: "PRIVATE_SUMMARY_DELTA"}}
        )

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

  test "an automatic episode with no fitting excerpt ends durably before dispatch" do
    {fixture, session, run_id, configuration} =
      retained_automatic_prompt("retained", context_token_budget: 800)

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
        maintenance_instructions: %{
          "version" => "summary.v1",
          "body" => String.duplicate("i", 2_048)
        },
        script: []
      )

    assert {:ok, ^session} =
             Loopex.resume_session(successor.runtime, session, command_id: "resume-excerpt")

    rows = await_parent_terminal(successor, session, run_id, now() + 5_000)
    assert [episode] = Enum.filter(rows, &(&1.payload.kind == "maintenance_episode_admitted_v1"))
    assert [ending] = Enum.filter(rows, &(&1.payload.kind == "maintenance_episode_terminal_v1"))
    assert ending.payload["episode_id"] == episode.payload["episode_id"]
    assert [refusal] = Enum.filter(rows, &(&1.payload.kind == "context_admission_refused_v2"))
    assert refusal.payload["failure"]["cause"] == "compaction_excerpt_budget_too_small"
    assert refusal.payload["episode_id"] == episode.payload["episode_id"]
    refute Enum.any?(rows, &(&1.payload.kind == "maintenance_request_committed_v1"))
    assert AgentLoopTestModel.dispatched(successor.model) == []
    assert Agent.get(successor.executor, & &1.jobs) == []
    assert {:ok, _} = SessionState.recover(session, rows, Fixture.events(successor, session))
    stop_and_join(successor, session)
  end

  test "a recovered checkpoint with an irreducible protected tail ends with its numeric refusal" do
    {fixture, session, episode} = retained_episode(:checkpoint_source_numeric)
    before = Fixture.records(fixture, session)
    successor = start(store: fixture.store, script: [], tools: [], model: "changed:model")

    assert {:ok, ^session} =
             Loopex.resume_session(successor.runtime, session,
               command_id: "resume-source-numeric"
             )

    rows = await_parent_terminal(successor, session, episode["run_id"], now() + 5_000)
    assert Enum.count(rows, &(&1.payload.kind == "maintenance_request_committed_v1")) == 1
    assert [ending] = Enum.filter(rows, &(&1.payload.kind == "maintenance_episode_terminal_v1"))
    assert ending.payload["result"]["checkpoint_id"] != nil
    assert [refusal] = Enum.filter(rows, &(&1.payload.kind == "context_admission_refused_v2"))
    assert refusal.payload["failure"]["dimension"] == "context_tokens"
    assert refusal.payload["episode_id"] == episode["episode_id"]
    assert length(rows) == length(before) + 4

    assert Enum.map(Enum.take(rows, -3), & &1.payload.kind) == [
             "maintenance_episode_terminal_v1",
             "context_admission_refused_v2",
             "run_terminal_committed"
           ]

    assert AgentLoopTestModel.dispatched(successor.model) == []
    assert Agent.get(successor.executor, & &1.jobs) == []

    assert {:ok, recovered} =
             SessionState.recover(session, rows, Fixture.events(successor, session))

    assert recovered.active_checkpoint == ending.payload["result"]["checkpoint_id"]
    stop_and_join(successor, session)
  end

  test "a live automatic episode refuses an oversized maintenance system message before source dispatch" do
    body = String.duplicate("i", 2_048)

    ceiling =
      Loopex.Bounds.estimate(
        LoopexProtocol.Canonical.encode(%{
          "role" => "system",
          "content" => "summary.v1: " <> body
        })
      )

    {fixture, session, run_id, configuration} =
      retained_automatic_prompt("retained", system_class_tokens: ceiling)

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
        maintenance_instructions: %{"version" => "summary.v1", "body" => body},
        script: []
      )

    assert {:ok, ^session} =
             Loopex.resume_session(successor.runtime, session, command_id: "resume-system-limit")

    rows = await_parent_terminal(successor, session, run_id, now() + 5_000)
    assert [episode] = Enum.filter(rows, &(&1.payload.kind == "maintenance_episode_admitted_v1"))
    assert [refusal] = Enum.filter(rows, &(&1.payload.kind == "context_admission_refused_v2"))
    assert refusal.payload["episode_id"] == episode.payload["episode_id"]
    assert refusal.payload["failure"]["measurement_scope"] == "maintenance"
    assert refusal.payload["failure"]["dimension"] == "system_class_tokens"
    assert refusal.payload["failure"]["observed"] == ceiling
    refute Enum.any?(rows, &(&1.payload.kind == "maintenance_request_committed_v1"))
    assert AgentLoopTestModel.dispatched(successor.model) == []
    assert Agent.get(successor.executor, & &1.jobs) == []
    assert {:ok, _} = SessionState.recover(session, rows, Fixture.events(successor, session))
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

  defp retained_automatic_prompt(content \\ "retained", options \\ []) do
    fixture = start(script: [], tools: [])

    configuration =
      Genesis.configuration()
      |> Map.put("context_token_budget", Keyword.get(options, :context_token_budget, 4_000))
      |> Map.put(
        "system_class_tokens",
        Keyword.get(
          options,
          :system_class_tokens,
          min(2_048, Keyword.get(options, :context_token_budget, 4_000))
        )
      )
      |> Map.update!("budget_origins", &Map.put(&1, "context_token_budget", "explicit"))
      |> put_in(
        ["provider_mapping", "continuation_required"],
        Keyword.get(options, :continuation_required, false)
      )

    configuration =
      if configuration["provider_mapping"]["continuation_required"] do
        configuration
        |> put_in(["provider_mapping", "mapping_revision"], "fixture.continuation.v1")
        |> put_in(["model_capabilities", "reasoning_levels"], ["default"])
      else
        configuration
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

    state =
      options
      |> Keyword.get(:old_contents, [String.duplicate("o", 30_000)])
      |> Enum.with_index()
      |> Enum.reduce(state, fn {text, index}, current ->
        {:ok, old} =
          SessionState.propose(
            current,
            %{
              type: :prompt,
              command_id: if(index == 0, do: "old", else: "old-#{index}"),
              content: text
            },
            %{
              max_turns: 8,
              token_budget: 10_000,
              deadline_ms: 60_000,
              context_token_budget: configuration["context_token_budget"]
            }
          )

        current = retain(fixture, current, old)

        {:ok, finished} =
          SessionState.propose_run_terminal(current, current.active_run_id, "failed", %{
            reason: "model_call_failed"
          })

        retain(fixture, current, finished)
      end)

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
      if mode in [:exhausted, :checkpoint_source_numeric] do
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
                    :reserve_unavailable,
                    :checkpoint_source_numeric,
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
                      mode == :exhausted ->
                        String.duplicate("o", 10_000)

                      mode in [
                        :source_pending,
                        :checkpoint_more,
                        :reserve_unavailable,
                        :checkpoint_source_numeric
                      ] ->
                        String.duplicate("o", 30_000)

                      true ->
                        String.duplicate("old", 1_000)
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
      if mode in [:exhausted, :checkpoint_more, :reserve_unavailable] do
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
           :reserve_unavailable,
           :checkpoint_source_numeric,
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
            cond do
              mode in [:invalid, :incomplete, :invalid_aborted, :invalid_expired] ->
                "{}"

              mode == :checkpoint_source_numeric ->
                ~s({"summary":"#{String.duplicate("g", 4_000)}","carry_forward":{"files_read":[],"files_changed":[]}})

              true ->
                ~s({"summary":"retained facts","carry_forward":{"files_read":[],"files_changed":[]}})
            end
          )
          |> Map.put(
            :usage,
            cond do
              mode == :checkpoint_spent_tokens -> %{}
              mode == :reserve_unavailable -> %{input_tokens: 9_000, output_tokens: 500}
              true -> %{input_tokens: 37, output_tokens: 19}
            end
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
           :reserve_unavailable,
           :checkpoint_source_numeric,
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

  # Concept: the source worker is held before it can prepare evidence.
  # Technical depth: the supervisor's synchronous debug hook suspends its exact
  # new task before replying to async_nolink. The coordinator then registers the
  # monitor while the worker is held; no scheduler race selects the fault PID.
  defp hold_next_source_worker(supervisor) do
    caller = self()

    hook = fn
      :armed, {:out, {:ok, worker}, _recipient, _state}, _extra when is_pid(worker) ->
        true = :erlang.suspend_process(worker)
        send(caller, {:held_maintenance_source_worker, worker})
        :held

      state, _event, _extra ->
        state
    end

    assert :ok = :sys.install(supervisor, {hook, :armed})

    on_exit(fn ->
      if Process.alive?(supervisor) do
        try do
          :sys.remove(supervisor, hook)
        catch
          :exit, _ -> :ok
        end
      end
    end)
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
