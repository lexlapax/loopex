Code.require_file("support/m1_runtime_helper.exs", __DIR__)
Code.require_file("support/agent_loop_helper.exs", __DIR__)
Code.require_file("support/configured_genesis_helper.exs", __DIR__)

defmodule Loopex.Runtime.StandaloneCompactOwnerTest do
  use ExUnit.Case, async: false

  alias Loopex.AgentLoopFixture, as: Fixture
  alias Loopex.ConfiguredGenesisFixture, as: Genesis
  alias Loopex.Runtime.SessionState
  alias Loopex.{M1RuntimeTestStore, Store}

  test "empty compact completes without ordinary or maintenance model configuration" do
    {store_pid, store} = M1RuntimeTestStore.start_store(label: "modelless-compact")

    {:ok, runtime} =
      Loopex.start_link(
        context_token_budget: 8_192,
        runtime_id: "modelless-compact",
        store: store
      )

    fixture = %{runtime: runtime, store: store_pid}
    on_exit(fn -> Fixture.stop(fixture) end)

    :ok = Loopex.ConfiguredGenesisFixture.await_creation_ready(runtime)

    {:ok, session} =
      Loopex.create_session(runtime, %{}, command_id: "create", genesis: Genesis.genesis([]))

    {:ok, attachment} = Loopex.attach(runtime, session, after_event_sequence: 0)
    assert {:accepted, "compact"} = Loopex.command(attachment, command())
    completed = await_completed(fixture, session)
    result = completed.commands["compact"].result
    assert result["disposition"] == "unchanged"
    assert result["failure"] == nil
    assert completed.maintenance_episodes == %{}
    assert ^result = Loopex.command(attachment, command())

    assert {:ok, {:committed, :admitted, :accepted, nil}} =
             Loopex.command_disposition(attachment, "compact")

    kill_owner(fixture, session)
    {:ok, _} = Loopex.prepare_resume_session(runtime, session, "resume")
    {:ok, successor} = Loopex.attach(runtime, session, after_event_sequence: 0)
    assert ^result = Loopex.command(successor, command())

    assert Enum.count(
             Fixture.events(fixture, session),
             &(&1.kind == "context.compaction_finished")
           ) == 1
  end

  for {cause, options} <- [
        {"maintenance_model_unconfigured", []},
        {"maintenance_instructions_unconfigured", [maintenance_model: :eligible]},
        {"maintenance_reasoning_unsupported",
         [maintenance_model: :unsupported, maintenance_instructions: :present]}
      ] do
    @cause cause
    @options options
    test "nonempty compact reports #{@cause} before any attempt or episode" do
      {fixture, session} = history_fixture(@options)
      {:ok, attachment} = Loopex.attach(fixture.runtime, session, after_event_sequence: 0)
      assert {:accepted, "compact"} = Loopex.command(attachment, command())
      completed = await_completed(fixture, session)
      assert completed.commands["compact"].result["failure"] == preparation_failure(@cause)
      assert completed.maintenance_episodes == %{}
      assert completed.active_run_id == nil
      assert completed.pending_work == %{}
      assert completed.commands["compact"].result["usage"]["attempts"] == 0
      assert Loopex.AgentLoopTestModel.dispatched(fixture.model) == []

      refute Enum.any?(
               Fixture.records(fixture, session),
               &(&1.payload.kind == "standalone_maintenance_episode_admitted_v1")
             )
    end
  end

  for action <- [:abort, :worker_loss, :deadline] do
    @action action
    test "held initial preparation #{@action} joins its exact worker before zero-attempt completion" do
      {fixture, session} =
        history_fixture(maintenance_model: :eligible, maintenance_instructions: :present)

      {:ok, attachment} = Loopex.attach(fixture.runtime, session, after_event_sequence: 0)
      owner = owner(fixture, session)
      hold_worker(:sys.get_state(owner).owner_workers)
      deadline_ms = if @action == :deadline, do: 100, else: 60_000
      cmd = command(deadline_ms)
      assert {:accepted, "compact"} = Loopex.command(attachment, cmd)
      assert_receive {:held_compact_worker, worker}, 5_000
      monitor = Process.monitor(worker)
      owner_state = :sys.get_state(owner)
      [{_, {:compact_preparation, _, ^worker, metadata}}] = Map.to_list(owner_state.in_flight)

      case @action do
        :abort ->
          assert {:accepted, "stop"} =
                   Loopex.command(attachment, %{type: :abort, command_id: "stop"})

        :worker_loss ->
          Process.exit(worker, :kill)

        :deadline ->
          :ok
      end

      assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}, 5_000
      completed = await_completed(fixture, session)
      result = completed.commands["compact"].result
      assert result["disposition"] == "failed"
      assert result["cleanup"] == "confirmed"
      assert result["usage"] == zero_usage()
      assert completed.maintenance_episodes == %{}
      assert completed.active_run_id == nil
      assert :sys.get_state(owner).in_flight == %{}
      assert Task.Supervisor.children(:sys.get_state(owner).owner_workers) == []

      case @action do
        :abort ->
          assert result["failure"] == %{"category" => "cancelled", "retryable" => false}

        :worker_loss ->
          assert result["failure"] == preparation_failure("context_projection_invalid", nil)

        :deadline ->
          assert result["failure"]["bound"] == "deadline_ms"
          assert result["failure"]["declared_limit"] == metadata.deadline
          assert result["failure"]["observed"] >= metadata.deadline
          assert metadata.deadline - metadata.admitted_at == deadline_ms
      end

      assert Loopex.AgentLoopTestModel.dispatched(fixture.model) == []
    end
  end

  test "held preparation worker exits with its owner before a paused successor can cancel" do
    {fixture, session} =
      history_fixture(maintenance_model: :eligible, maintenance_instructions: :present)

    {:ok, attachment} = Loopex.attach(fixture.runtime, session, after_event_sequence: 0)
    predecessor = owner(fixture, session)
    hold_worker(:sys.get_state(predecessor).owner_workers)
    assert {:accepted, "compact"} = Loopex.command(attachment, command())
    assert_receive {:held_compact_worker, worker}, 5_000
    monitor = Process.monitor(worker)
    kill_owner(fixture, session)
    assert_receive {:DOWN, ^monitor, :process, ^worker, reason}, 5_000
    assert reason in [:shutdown, :killed]
    {:ok, _} = Loopex.prepare_resume_session(fixture.runtime, session, "recover-worker")
    {:ok, successor} = Loopex.attach(fixture.runtime, session, after_event_sequence: 0)
    state = :sys.get_state(owner(fixture, session))
    assert state.in_flight == %{}
    assert state.durable.pending_compact["command_id"] == "compact"
    assert state.durable.maintenance_episodes == %{}
    assert {:accepted, "stop"} = Loopex.command(successor, %{type: :abort, command_id: "stop"})

    assert await_completed(fixture, session).commands["compact"].result["failure"] ==
             %{"category" => "cancelled", "retryable" => false}

    assert Loopex.AgentLoopTestModel.dispatched(fixture.model) == []
  end

  test "captured standalone cancellation keeps the actual settings and terminal pair" do
    {fixture, session} =
      history_fixture(maintenance_model: :eligible, maintenance_instructions: :present)

    {:ok, attachment} = Loopex.attach(fixture.runtime, session, after_event_sequence: 0)
    assert {:accepted, "compact"} = Loopex.command(attachment, command())
    captured = await_state(fixture, session, &is_binary(&1.active_maintenance))
    episode = captured.maintenance_episodes[captured.active_maintenance]
    assert episode["deadline"] - episode["admitted_at"] == 60_000
    assert episode["bounds"] == command().bounds
    assert episode["maintenance_configuration"]["selection"] == model()
    assert episode["stage"] == "source_preparation"
    refute Map.has_key?(episode, "run_id")
    owner = owner(fixture, session)
    _ = :sys.get_state(owner)
    send(owner, {:compact_deadline, captured.active_maintenance, episode["deadline"] - 1})
    send(owner, {:compact_deadline, captured.active_maintenance, episode["deadline"]})
    assert :sys.get_state(owner).durable.active_maintenance == captured.active_maintenance
    assert {:accepted, "stop"} = Loopex.command(attachment, %{type: :abort, command_id: "stop"})
    completed = await_completed(fixture, session)
    result = completed.commands["compact"].result
    assert result["failure"] == %{"category" => "cancelled", "retryable" => false}
    assert result["usage"] == zero_usage()
    [terminal, completion] = Enum.take(Fixture.records(fixture, session), -2)
    assert terminal.payload.kind == "maintenance_episode_terminal_v1"
    assert completion.payload.kind == "compact_command_completed_v1"
    assert terminal.payload["result"] == completion.payload["result"]
    assert terminal.payload["observed_at"] == completion.payload["observed_at"]
    assert completed.maintenance_episodes[captured.active_maintenance]["stage"] == "settled"
    assert Loopex.AgentLoopTestModel.dispatched(fixture.model) == []
    send(owner, {:compact_deadline, captured.active_maintenance, episode["deadline"]})
    assert :sys.get_state(owner).durable.commands["compact"].result == result
  end

  test "captured standalone expiry retains its original absolute deadline" do
    {fixture, session} =
      history_fixture(maintenance_model: :eligible, maintenance_instructions: :present)

    {:ok, attachment} = Loopex.attach(fixture.runtime, session, after_event_sequence: 0)
    assert {:accepted, "compact"} = Loopex.command(attachment, command(1_000))
    captured = await_state(fixture, session, &is_binary(&1.active_maintenance))
    episode = captured.maintenance_episodes[captured.active_maintenance]
    completed = await_completed(fixture, session)
    failure = completed.commands["compact"].result["failure"]
    assert failure["bound"] == "deadline_ms"
    assert failure["declared_limit"] == episode["deadline"]
    assert failure["observed"] >= episode["deadline"]
    assert episode["deadline"] - episode["admitted_at"] == 1_000
    assert completed.commands["compact"].result["usage"] == zero_usage()
    assert Loopex.AgentLoopTestModel.dispatched(fixture.model) == []
  end

  for phase <- [
        :before_linearization,
        :after_linearization_before_result,
        :recovery_representation
      ] do
    @phase phase
    test "unchanged completion resolves #{@phase} once across exact owner succession" do
      fixture = start(script: [], tools: [])

      {:ok, session} =
        Loopex.create_session(fixture.runtime, %{},
          command_id: "create",
          genesis: Genesis.genesis([])
        )

      {:ok, attachment} = Loopex.attach(fixture.runtime, session, after_event_sequence: 0)
      owner = owner(fixture, session)
      hold_worker(:sys.get_state(owner).owner_workers)
      assert {:accepted, "compact"} = Loopex.command(attachment, command())
      assert_receive {:held_compact_worker, worker}, 5_000
      monitor = Process.monitor(worker)
      assert :ok = M1RuntimeTestStore.inject(fixture.store, {:session_journal_commit, @phase})

      :sys.replace_state(:sys.get_state(owner).owner_workers, fn supervisor_state ->
        true = :erlang.resume_process(worker)
        supervisor_state
      end)

      assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 5_000
      await_worker_adoption(owner, System.monotonic_time(:millisecond) + 5_000)
      # The internal transaction may resolve in this owner or seal it. Exact
      # owner exit precedes the successor's lookup in either case.
      kill_owner(fixture, session)
      {:ok, _} = Loopex.prepare_resume_session(fixture.runtime, session, "recover")
      {:ok, successor} = Loopex.attach(fixture.runtime, session, after_event_sequence: 0)
      completed = await_completed(fixture, session)
      result = completed.commands["compact"].result
      assert result["disposition"] == "unchanged"
      assert ^result = Loopex.command(successor, command())

      assert Enum.count(
               Fixture.records(fixture, session),
               &(&1.payload.kind == "compact_command_completed_v1")
             ) == 1

      assert Enum.count(
               Fixture.events(fixture, session),
               &(&1.kind == "context.compaction_finished")
             ) == 1

      assert completed.maintenance_episodes == %{}
      assert Loopex.AgentLoopTestModel.dispatched(fixture.model) == []
    end
  end

  for phase <- [
        :before_linearization,
        :after_linearization_before_result,
        :recovery_representation
      ] do
    @phase phase
    test "standalone capture resolves #{@phase} without renewing settings or cutoff" do
      {fixture, session} =
        history_fixture(maintenance_model: :eligible, maintenance_instructions: :present)

      {:ok, attachment} = Loopex.attach(fixture.runtime, session, after_event_sequence: 0)
      predecessor = owner(fixture, session)
      supervisor = :sys.get_state(predecessor).owner_workers
      hold_worker(supervisor)
      assert {:accepted, "compact"} = Loopex.command(attachment, command())
      assert_receive {:held_compact_worker, worker}, 5_000

      [{_, {:compact_preparation, _, ^worker, metadata}}] =
        Map.to_list(:sys.get_state(predecessor).in_flight)

      monitor = Process.monitor(worker)
      assert :ok = M1RuntimeTestStore.inject(fixture.store, {:session_journal_commit, @phase})

      :sys.replace_state(supervisor, fn state ->
        true = :erlang.resume_process(worker)
        state
      end)

      assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 5_000
      await_worker_adoption(predecessor, System.monotonic_time(:millisecond) + 5_000)
      kill_owner(fixture, session)
      {:ok, _} = Loopex.prepare_resume_session(fixture.runtime, session, "recover-capture")
      {:ok, successor} = Loopex.attach(fixture.runtime, session, after_event_sequence: 0)
      captured = await_state(fixture, session, &is_binary(&1.active_maintenance))
      episode = captured.maintenance_episodes[captured.active_maintenance]
      assert episode["admitted_at"] == metadata.admitted_at
      assert episode["deadline"] == metadata.deadline
      assert episode["maintenance_configuration"]["selection"] == model()
      assert episode["attempts"] == 0
      assert :sys.get_state(owner(fixture, session)).in_flight == %{}
      [view] = maintenance_views(fixture, session)
      assert view["active_maintenance"]["episode_id"] == episode["episode_id"]
      assert view["active_maintenance"]["owner"] == %{"kind" => "compact", "id" => "compact"}
      assert view["active_maintenance"]["bounds"] == episode["bounds"]

      assert Enum.count(
               Fixture.records(fixture, session),
               &(&1.payload.kind == "standalone_maintenance_episode_admitted_v1")
             ) == 1

      assert {:accepted, "stop"} = Loopex.command(successor, %{type: :abort, command_id: "stop"})
      assert await_completed(fixture, session).commands["compact"].result["usage"] == zero_usage()
      assert [^view, %{"active_maintenance" => nil}] = maintenance_views(fixture, session)
      assert Loopex.AgentLoopTestModel.dispatched(fixture.model) == []
    end

    test "captured cancellation resolves #{@phase} with its indivisible terminal and result" do
      {fixture, session} =
        history_fixture(maintenance_model: :eligible, maintenance_instructions: :present)

      {:ok, attachment} = Loopex.attach(fixture.runtime, session, after_event_sequence: 0)
      assert {:accepted, "compact"} = Loopex.command(attachment, command())
      captured = await_state(fixture, session, &is_binary(&1.active_maintenance))
      predecessor = owner(fixture, session)

      assert :ok =
               M1RuntimeTestStore.hold_next_record_before_linearization(
                 fixture.store,
                 "maintenance_episode_terminal_v1",
                 self()
               )

      assert {:accepted, "stop"} = Loopex.command(attachment, %{type: :abort, command_id: "stop"})

      assert_receive {:record_held_before_linearization, waiter, _,
                      "maintenance_episode_terminal_v1", transaction},
                     5_000

      assert Enum.map(transaction.records, & &1.kind) == [
               "maintenance_episode_terminal_v1",
               "compact_command_completed_v1"
             ]

      assert transaction.records |> hd() |> Map.fetch!("episode_id") ==
               captured.active_maintenance

      assert Enum.map(transaction.outbox, & &1.kind) == [
               "context.maintenance_changed",
               "context.compaction_finished"
             ]

      assert hd(transaction.outbox)["active_maintenance"] == nil
      [admission_view] = maintenance_views(fixture, session)
      assert admission_view["active_maintenance"]["episode_id"] == captured.active_maintenance

      assert :ok = M1RuntimeTestStore.inject(fixture.store, {:session_journal_commit, @phase})
      M1RuntimeTestStore.release(waiter)
      await_worker_adoption(predecessor, System.monotonic_time(:millisecond) + 5_000)
      kill_owner(fixture, session)
      {:ok, _} = Loopex.prepare_resume_session(fixture.runtime, session, "recover-terminal")
      {:ok, successor} = Loopex.attach(fixture.runtime, session, after_event_sequence: 0)
      completed = await_completed(fixture, session)
      result = completed.commands["compact"].result
      assert result["failure"] == %{"category" => "cancelled", "retryable" => false}
      assert result["usage"] == zero_usage()
      assert ^result = Loopex.command(successor, command())
      assert completed.active_maintenance == nil

      assert [^admission_view, %{"active_maintenance" => nil}] =
               maintenance_views(fixture, session)

      assert Enum.count(
               Fixture.records(fixture, session),
               &(&1.payload.kind == "maintenance_episode_terminal_v1")
             ) == 1

      assert Enum.count(
               Fixture.records(fixture, session),
               &(&1.payload.kind == "compact_command_completed_v1")
             ) == 1

      assert Enum.count(
               Fixture.events(fixture, session),
               &(&1.kind == "context.compaction_finished")
             ) == 1

      assert Loopex.AgentLoopTestModel.dispatched(fixture.model) == []
    end
  end

  for action <- [:worker_loss, :abort, :deadline] do
    @source_action action
    test "standalone source #{@source_action} joins the exact worker before zero-attempt completion" do
      {fixture, session} =
        history_fixture(maintenance_model: :eligible, maintenance_instructions: :present)

      {:ok, attachment} = Loopex.attach(fixture.runtime, session, after_event_sequence: 0)
      cmd = command(if @source_action == :deadline, do: 1_000, else: 60_000)
      assert {:accepted, "compact"} = Loopex.command(attachment, cmd)
      coordinator = owner(fixture, session)

      {worker, metadata} =
        await_source_worker(coordinator, System.monotonic_time(:millisecond) + 5_000)

      monitor = Process.monitor(worker)
      captured = recover(fixture, session)
      episode = captured.maintenance_episodes[captured.active_maintenance]
      assert metadata.origin == :compact
      assert metadata.deadline == episode["deadline"]

      case @source_action do
        :worker_loss ->
          Process.exit(worker, :kill)

        :abort ->
          assert {:accepted, "stop"} =
                   Loopex.command(attachment, %{type: :abort, command_id: "stop"})

        :deadline ->
          :ok
      end

      assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}, 5_000
      completed = await_completed(fixture, session)
      result = completed.commands["compact"].result
      assert result["usage"] == zero_usage()
      assert result["cleanup"] == "confirmed"

      case @source_action do
        :worker_loss ->
          assert result["failure"] == preparation_failure("context_projection_invalid", nil)

        :abort ->
          assert result["failure"]["category"] == "cancelled"

        :deadline ->
          assert result["failure"]["bound"] == "deadline_ms"
          assert result["failure"]["declared_limit"] == metadata.deadline
          assert result["failure"]["observed"] >= metadata.deadline
      end

      assert Loopex.AgentLoopTestModel.dispatched(fixture.model) == []
      assert completed.conversation == captured.conversation
      assert completed.charged == captured.charged
      assert Task.Supervisor.children(:sys.get_state(coordinator).owner_workers) == []
    end
  end

  for phase <- [
        :before_linearization,
        :after_linearization_before_result,
        :recovery_representation
      ] do
    @provider_phase phase
    test "standalone source request resolves #{@provider_phase} with one authenticated attempt" do
      {fixture, session} =
        history_fixture(
          maintenance_model: :eligible,
          maintenance_instructions: :present,
          script: [%{text: "invalid summary", reply_overrides: natural()}]
        )

      {:ok, attachment} = Loopex.attach(fixture.runtime, session, after_event_sequence: 0)
      assert {:accepted, "compact"} = Loopex.command(attachment, command())
      predecessor = owner(fixture, session)
      supervisor = :sys.get_state(predecessor).owner_workers

      {worker, _metadata} =
        await_source_worker(predecessor, System.monotonic_time(:millisecond) + 5_000)

      worker_monitor = Process.monitor(worker)
      captured = recover(fixture, session)
      episode = captured.maintenance_episodes[captured.active_maintenance]

      assert :ok =
               M1RuntimeTestStore.inject(
                 fixture.store,
                 {:session_journal_commit, @provider_phase}
               )

      :sys.replace_state(supervisor, fn state ->
        true = :erlang.resume_process(worker)
        state
      end)

      assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :normal}, 5_000
      await_worker_adoption(predecessor, System.monotonic_time(:millisecond) + 5_000)
      kill_owner(fixture, session)
      sent = length(Loopex.AgentLoopTestModel.dispatched(fixture.model))
      assert sent <= 1

      assert {:ok, {:prepared, activation}} =
               Loopex.prepare_resume_session(fixture.runtime, session, "resolve-source")

      paused = :sys.get_state(owner(fixture, session))
      assert paused.in_flight == %{}
      retained = paused.durable.maintenance_episodes[episode["episode_id"]]
      assert retained["maintenance_configuration"] == episode["maintenance_configuration"]
      assert retained["deadline"] == episode["deadline"]
      assert length(Loopex.AgentLoopTestModel.dispatched(fixture.model)) == sent
      assert {:ok, ^session} = Loopex.activate_resume(activation)
      completed = await_completed(fixture, session)
      result = completed.commands["compact"].result

      case retained["stage"] do
        "source_preparation" ->
          assert sent == 0
          assert length(Loopex.AgentLoopTestModel.dispatched(fixture.model)) == 1
          assert result["usage"]["reported_tokens"] == 2
          assert result["cleanup"] == "confirmed"

        "model_attempt_open" ->
          assert length(Loopex.AgentLoopTestModel.dispatched(fixture.model)) == sent
          assert result["usage"]["estimated_tokens"] == 32_768
          assert result["cleanup"] == "unknown"

        "settled" ->
          assert length(Loopex.AgentLoopTestModel.dispatched(fixture.model)) == sent
          assert result == paused.durable.commands["compact"].result
      end

      assert result["usage"]["attempts"] == 1
      assert completed.conversation == captured.conversation
      assert completed.charged == captured.charged
      records = Fixture.records(fixture, session)
      assert Enum.count(records, &(&1.payload.kind == "maintenance_request_committed_v1")) == 1
      assert Enum.count(records, &(&1.payload.kind == "maintenance_attempt_opened_v1")) == 1
      assert Enum.count(records, &(&1.payload.kind == "maintenance_attempt_settled_v3")) == 1

      assert Enum.count(
               Fixture.events(fixture, session),
               &(&1.kind == "context.compaction_finished")
             ) == 1

      assert MapSet.member?(
               M1RuntimeTestStore.observed(fixture.store),
               {:session_journal_commit, @provider_phase}
             )
    end

    test "standalone failed settlement resolves #{@provider_phase} once without redispatch" do
      {fixture, session} =
        live_history([%{text: "invalid summary", reply_overrides: natural(), hold: self()}])

      {:ok, attachment} = Loopex.attach(fixture.runtime, session, after_event_sequence: 0)
      assert {:accepted, "compact"} = Loopex.command(attachment, command())
      assert_receive {:holding, callback}, 5_000
      callback_monitor = Process.monitor(callback)
      predecessor = owner(fixture, session)
      before = recover(fixture, session)
      episode = before.maintenance_episodes[before.active_maintenance]

      assert :ok =
               M1RuntimeTestStore.hold_next_record_before_linearization(
                 fixture.store,
                 "maintenance_episode_terminal_v1",
                 self()
               )

      send(callback, :release)
      assert_receive {:DOWN, ^callback_monitor, :process, ^callback, :normal}, 5_000

      assert_receive {:record_held_before_linearization, waiter, _,
                      "maintenance_episode_terminal_v1", transaction},
                     5_000

      assert Enum.map(transaction.records, & &1.kind) ==
               [
                 "maintenance_episode_terminal_v1",
                 "maintenance_attempt_settled_v3",
                 "compact_command_completed_v1"
               ]

      result = List.last(transaction.records)["result"]
      assert result["usage"]["reported_tokens"] == 2

      assert :ok =
               M1RuntimeTestStore.inject(
                 fixture.store,
                 {:session_journal_commit, @provider_phase}
               )

      M1RuntimeTestStore.release(waiter)
      await_worker_adoption(predecessor, System.monotonic_time(:millisecond) + 5_000)
      kill_owner(fixture, session)

      assert {:ok, {:prepared, activation}} =
               Loopex.prepare_resume_session(fixture.runtime, session, "resolve-spent")

      assert {:ok, ^session} = Loopex.activate_resume(activation)
      completed = await_completed(fixture, session)
      assert completed.commands["compact"].result == result

      assert completed.maintenance_episodes[episode["episode_id"]]["deadline"] ==
               episode["deadline"]

      assert completed.conversation == before.conversation
      assert completed.charged == before.charged

      assert Enum.count(
               Fixture.records(fixture, session),
               &(&1.payload.kind == "maintenance_attempt_settled_v3")
             ) == 1

      assert Enum.count(
               Fixture.events(fixture, session),
               &(&1.kind == "context.compaction_finished")
             ) == 1

      assert length(Loopex.AgentLoopTestModel.dispatched(fixture.model)) == 1

      assert MapSet.member?(
               M1RuntimeTestStore.observed(fixture.store),
               {:session_journal_commit, @provider_phase}
             )
    end
  end

  test "live standalone provider settles invalid summary with exact usage and no run" do
    {fixture, session} = live_history([%{text: "invalid summary", reply_overrides: natural()}])
    {:ok, attachment} = Loopex.attach(fixture.runtime, session, after_event_sequence: 0)
    assert {:accepted, "compact"} = Loopex.command(attachment, command())
    completed = await_completed(fixture, session)
    result = completed.commands["compact"].result
    assert result["failure"] == preparation_failure("maintenance_summary_invalid", nil)
    assert result["cleanup"] == "confirmed"

    assert result["usage"] == %{
             "attempts" => 1,
             "reported_tokens" => 2,
             "estimated_tokens" => 0,
             "total_tokens" => 2
           }

    assert completed.active_run_id == nil
    assert completed.pending_work == %{}
    assert completed.deadlines == %{}
    assert completed.charged == %{}
    assert length(completed.run_order) == 1
    assert completed.checkpoints == %{}
    [request] = Loopex.AgentLoopTestModel.dispatched(fixture.model)
    assert request.tools == []
    assert request.continuation == nil
    assert request.sampling["reasoning"] == "none"

    assert request.deadline ==
             completed.maintenance_episodes |> Map.values() |> hd() |> Map.fetch!("deadline")

    assert :sys.get_state(owner(fixture, session)).in_flight == %{}
    assert Task.Supervisor.children(:sys.get_state(owner(fixture, session)).owner_workers) == []

    assert Enum.map(Enum.take(Fixture.records(fixture, session), -3), & &1.payload.kind) ==
             [
               "maintenance_episode_terminal_v1",
               "maintenance_attempt_settled_v3",
               "compact_command_completed_v1"
             ]

    assert ^result = Loopex.command(attachment, command())
    kill_owner(fixture, session)
    {:ok, _} = Loopex.prepare_resume_session(fixture.runtime, session, "spent-result")
    {:ok, resumed} = Loopex.attach(fixture.runtime, session, after_event_sequence: 0)
    assert ^result = Loopex.command(resumed, command())
    assert length(Loopex.AgentLoopTestModel.dispatched(fixture.model)) == 1
  end

  test "live standalone checkpoint completes and replays without a synthetic run or redispatch" do
    {fixture, session} =
      live_history(
        [
          %{
            text: summary(),
            reply_overrides: natural(),
            usage: %{input_tokens: 37, output_tokens: 19}
          }
        ],
        history_content: String.duplicate("f", 8_000)
      )

    before = recover(fixture, session)
    {:ok, attachment} = Loopex.attach(fixture.runtime, session, after_event_sequence: 0)

    cmd =
      command()
      |> put_in([:bounds, "max_attempts"], 1)
      |> put_in([:bounds, "token_budget"], 1_024)

    assert {:accepted, "compact"} = Loopex.command(attachment, cmd)
    completed = await_completed(fixture, session)
    result = completed.commands["compact"].result

    assert result == %{
             "disposition" => "checkpointed",
             "checkpoint_id" => completed.active_checkpoint,
             "failure" => nil,
             "cleanup" => "confirmed",
             "usage" => %{
               "attempts" => 1,
               "reported_tokens" => 56,
               "estimated_tokens" => 0,
               "total_tokens" => 56
             }
           }

    assert is_binary(result["checkpoint_id"])
    assert completed.active_maintenance == nil
    assert completed.conversation == before.conversation
    assert completed.run_order == before.run_order
    assert completed.charged == before.charged
    # Concept: ADR 0069 run evidence excludes standalone compaction usage.
    assert completed.run_usage == before.run_usage
    assert completed.deadlines == before.deadlines
    assert completed.active_run_id == nil
    assert completed.pending_work == %{}
    checkpoint = completed.checkpoints[result["checkpoint_id"]]
    assert checkpoint.kind == "standalone_compaction_checkpoint_committed_v1"
    assert checkpoint["command_id"] == "compact"
    refute Map.has_key?(checkpoint, "run_id")
    assert checkpoint["lineage"]["through_run_id"] == List.last(before.run_order)
    compacted = Enum.find(Fixture.events(fixture, session), &(&1.kind == "context.compacted"))
    assert compacted["owner"] == %{"kind" => "compact", "id" => "compact"}
    refute Map.has_key?(compacted, "run_id")

    assert Enum.map(Enum.take(Fixture.records(fixture, session), -3), & &1.payload.kind) ==
             [
               "standalone_compaction_checkpoint_committed_v1",
               "maintenance_episode_terminal_v1",
               "compact_command_completed_v1"
             ]

    coordinator = :sys.get_state(owner(fixture, session))
    assert coordinator.in_flight == %{}
    assert coordinator.pending_cleanup == %{}
    assert Task.Supervisor.children(coordinator.owner_workers) == []
    assert ^result = Loopex.command(attachment, cmd)

    kill_owner(fixture, session)
    {:ok, _} = Loopex.prepare_resume_session(fixture.runtime, session, "checkpoint-result")
    {:ok, resumed} = Loopex.attach(fixture.runtime, session, after_event_sequence: 0)
    assert ^result = Loopex.command(resumed, cmd)
    assert recover(fixture, session).active_checkpoint == result["checkpoint_id"]
    assert length(Loopex.AgentLoopTestModel.dispatched(fixture.model)) == 1
    assert Enum.count(Fixture.events(fixture, session), &(&1.kind == "context.compacted")) == 1

    assert Enum.count(
             Fixture.events(fixture, session),
             &(&1.kind == "context.compaction_finished")
           ) == 1
  end

  test "live standalone hard-limit repair continues through contiguous checkpoint prefixes" do
    contents = for letter <- ["a", "b", "c", "d"], do: String.duplicate(letter, 18_000)

    replies =
      for _ <- 1..4,
          do: %{
            text: summary(),
            reply_overrides: natural(),
            usage: %{input_tokens: 37, output_tokens: 19}
          }

    {fixture, session} = live_history(replies, history_contents: contents)
    before = recover(fixture, session)
    {:ok, attachment} = Loopex.attach(fixture.runtime, session, after_event_sequence: 0)
    assert {:accepted, "compact"} = Loopex.command(attachment, command())
    completed = await_completed(fixture, session)
    result = completed.commands["compact"].result
    assert result["disposition"] == "checkpointed"
    episode = completed.maintenance_episodes |> Map.values() |> hd()
    assert episode["trigger"] == "ordinary_limit"
    assert episode["attempts"] == 3

    assert result["usage"] == %{
             "attempts" => 3,
             "reported_tokens" => 168,
             "estimated_tokens" => 0,
             "total_tokens" => 168
           }

    checkpoints = completed.checkpoints |> Map.values() |> Enum.sort_by(& &1["summary_ordinal"])
    assert length(checkpoints) == 3
    assert Enum.map(checkpoints, & &1["summary_ordinal"]) == [1, 2, 3]
    assert Enum.map(checkpoints, & &1["covered_range"]["unit_count"]) == [1, 2, 3]
    assert Enum.map(checkpoints, & &1["consumed_range"]["unit_count"]) == [1, 1, 1]

    for {prior, next} <- Enum.zip(checkpoints, tl(checkpoints)) do
      assert next["prior_checkpoint_id"] == prior["checkpoint_id"]
      assert next["consumed_range"]["first"] == prior["covered_range"]["first_kept"]
    end

    assert List.last(checkpoints)["checkpoint_id"] == completed.active_checkpoint
    assert Enum.all?(checkpoints, &(&1["command_id"] == "compact"))
    assert completed.conversation == before.conversation
    assert completed.charged == before.charged
    assert completed.run_order == before.run_order
    assert completed.deadlines == before.deadlines
    assert length(Loopex.AgentLoopTestModel.dispatched(fixture.model)) == 3

    assert Enum.count(
             Fixture.events(fixture, session),
             &(&1.kind == "context.compaction_finished")
           ) == 1
  end

  for boundary <- [
        "standalone_compaction_checkpoint_committed_v1",
        "maintenance_episode_terminal_v1"
      ],
      phase <- [
        :before_linearization,
        :after_linearization_before_result,
        :recovery_representation
      ] do
    @checkpoint_boundary boundary
    @checkpoint_phase phase
    test "standalone #{@checkpoint_boundary} resolves #{@checkpoint_phase} without a second summary" do
      {fixture, session} =
        live_history(
          [
            %{
              text: summary(),
              reply_overrides: natural(),
              hold: self(),
              usage: %{input_tokens: 37, output_tokens: 19}
            }
          ],
          history_content: String.duplicate("f", 8_000)
        )

      {:ok, attachment} = Loopex.attach(fixture.runtime, session, after_event_sequence: 0)
      assert {:accepted, "compact"} = Loopex.command(attachment, command())
      assert_receive {:holding, callback}, 5_000
      callback_monitor = Process.monitor(callback)
      predecessor = owner(fixture, session)
      before = recover(fixture, session)
      episode = before.maintenance_episodes[before.active_maintenance]

      assert :ok =
               M1RuntimeTestStore.hold_next_record_before_linearization(
                 fixture.store,
                 @checkpoint_boundary,
                 self()
               )

      send(callback, :release)
      assert_receive {:DOWN, ^callback_monitor, :process, ^callback, :normal}, 5_000

      assert_receive {:record_held_before_linearization, waiter, _, @checkpoint_boundary,
                      transaction},
                     5_000

      if @checkpoint_boundary == "maintenance_episode_terminal_v1" do
        assert Enum.map(transaction.records, & &1.kind) ==
                 ["maintenance_episode_terminal_v1", "compact_command_completed_v1"]

        assert List.last(transaction.records)["result"]["disposition"] == "checkpointed"
      else
        assert [record] = transaction.records
        assert record["command_id"] == "compact"
        refute Map.has_key?(record, "run_id")
      end

      assert :ok =
               M1RuntimeTestStore.inject(
                 fixture.store,
                 {:session_journal_commit, @checkpoint_phase}
               )

      M1RuntimeTestStore.release(waiter)
      await_worker_adoption(predecessor, System.monotonic_time(:millisecond) + 5_000)
      kill_owner(fixture, session)

      assert {:ok, {:prepared, activation}} =
               Loopex.prepare_resume_session(fixture.runtime, session, "resolve-checkpoint")

      assert {:ok, ^session} = Loopex.activate_resume(activation)
      completed = await_completed(fixture, session)
      result = completed.commands["compact"].result
      assert result["disposition"] == "checkpointed"
      assert result["checkpoint_id"] == completed.active_checkpoint

      assert result["usage"] == %{
               "attempts" => 1,
               "reported_tokens" => 56,
               "estimated_tokens" => 0,
               "total_tokens" => 56
             }

      assert result["cleanup"] == "confirmed"
      retained_episode = completed.maintenance_episodes[episode["episode_id"]]

      for key <- [
            "deadline",
            "bounds",
            "maintenance_configuration",
            "configuration_version",
            "command_id"
          ] do
        assert retained_episode[key] == episode[key]
      end

      assert completed.conversation == before.conversation
      assert completed.charged == before.charged
      assert completed.run_order == before.run_order
      assert completed.deadlines == before.deadlines

      for kind <- [
            "maintenance_attempt_settled_v3",
            "standalone_compaction_checkpoint_committed_v1",
            "maintenance_episode_terminal_v1",
            "compact_command_completed_v1"
          ] do
        assert Enum.count(Fixture.records(fixture, session), &(&1.payload.kind == kind)) == 1
      end

      for kind <- ["context.compacted", "context.compaction_finished"] do
        assert Enum.count(Fixture.events(fixture, session), &(&1.kind == kind)) == 1
      end

      assert length(Loopex.AgentLoopTestModel.dispatched(fixture.model)) == 1

      assert MapSet.member?(
               M1RuntimeTestStore.observed(fixture.store),
               {:session_journal_commit, @checkpoint_phase}
             )
    end
  end

  test "live standalone valid but nonprogressing summary ends without checkpoint or another call" do
    {fixture, session} =
      live_history([
        %{
          text: summary(),
          reply_overrides: natural(),
          usage: %{input_tokens: 37, output_tokens: 19}
        }
      ])

    {:ok, attachment} = Loopex.attach(fixture.runtime, session, after_event_sequence: 0)
    assert {:accepted, "compact"} = Loopex.command(attachment, command())
    completed = await_completed(fixture, session)
    result = completed.commands["compact"].result
    assert result["failure"] == preparation_failure("compaction_no_progress", "ordinary")
    assert result["usage"]["reported_tokens"] == 56
    assert result["usage"]["attempts"] == 1
    assert completed.active_checkpoint == nil
    assert completed.charged == %{}
    refute Enum.any?(Fixture.events(fixture, session), &(&1.kind == "context.compacted"))

    assert Enum.count(
             Fixture.records(fixture, session),
             &(&1.payload.kind == "maintenance_attempt_settled_v3")
           ) == 1

    assert length(Loopex.AgentLoopTestModel.dispatched(fixture.model)) == 1
  end

  test "live standalone not-dispatched retry retains one request and physical attempt accounting" do
    {fixture, session} =
      live_history([
        %{raw_result: {:error, {:not_dispatched, "model_call_failed"}}},
        %{
          text: "invalid summary",
          reply_overrides: natural(),
          usage: %{input_tokens: 37, output_tokens: 19}
        }
      ])

    {:ok, attachment} = Loopex.attach(fixture.runtime, session, after_event_sequence: 0)
    assert {:accepted, "compact"} = Loopex.command(attachment, command())
    result = await_completed(fixture, session).commands["compact"].result

    assert result["usage"] == %{
             "attempts" => 2,
             "reported_tokens" => 56,
             "estimated_tokens" => 0,
             "total_tokens" => 56
           }

    [first, retry] = Loopex.AgentLoopTestModel.dispatched(fixture.model)
    assert first == retry
    records = Fixture.records(fixture, session)
    assert Enum.count(records, &(&1.payload.kind == "maintenance_request_committed_v1")) == 1
    assert Enum.count(records, &(&1.payload.kind == "maintenance_attempt_opened_v1")) == 2
    assert Enum.count(records, &(&1.payload.kind == "maintenance_attempt_settled_v3")) == 2
  end

  for action <- [:abort, :deadline] do
    @provider_action action
    test "live standalone #{@provider_action} collects late usage and joins the provider tree" do
      {fixture, session} =
        live_history([
          %{
            text: summary(),
            reply_overrides: natural(),
            usage: %{input_tokens: 37, output_tokens: 19},
            hold: self()
          }
        ])

      {:ok, attachment} = Loopex.attach(fixture.runtime, session, after_event_sequence: 0)
      cmd = command(if @provider_action == :deadline, do: 1_000, else: 60_000)
      assert {:accepted, "compact"} = Loopex.command(attachment, cmd)
      assert_receive {:holding, callback}, 5_000
      monitor = Process.monitor(callback)
      opened = recover(fixture, session)
      episode = opened.maintenance_episodes[opened.active_maintenance]
      assert episode["stage"] == "model_attempt_open"

      if @provider_action == :abort do
        assert {:accepted, "stop"} =
                 Loopex.command(attachment, %{type: :abort, command_id: "stop"})
      else
        await_state(fixture, session, fn state ->
          state.maintenance_episodes[episode["episode_id"]]["model_termination"] == "deadline"
        end)
      end

      send(callback, :release)
      assert_receive {:DOWN, ^monitor, :process, ^callback, :normal}, 5_000
      completed = await_completed(fixture, session)
      result = completed.commands["compact"].result
      assert result["cleanup"] == "confirmed"
      assert result["usage"]["reported_tokens"] == 56
      assert result["usage"]["attempts"] == 1

      if @provider_action == :abort do
        assert result["failure"] == %{"category" => "cancelled", "retryable" => false}
      else
        assert result["failure"]["bound"] == "deadline_ms"
        assert result["failure"]["declared_limit"] == episode["deadline"]
        assert result["failure"]["observed"] >= episode["deadline"]
        assert result["failure"]["accounting_source"] == "reported"
      end

      assert completed.active_checkpoint == nil
      assert :sys.get_state(owner(fixture, session)).pending_cleanup == %{}
      assert Task.Supervisor.children(:sys.get_state(owner(fixture, session)).owner_workers) == []
      assert length(Loopex.AgentLoopTestModel.dispatched(fixture.model)) == 1
    end
  end

  test "standalone expiry after a useful settled summary preserves usage without resettling" do
    {fixture, session} =
      live_history(
        [
          %{
            text: summary(),
            hold: self(),
            reply_overrides: natural(),
            usage: %{input_tokens: 37, output_tokens: 19}
          }
        ],
        history_content: String.duplicate("f", 8_000)
      )

    {:ok, attachment} = Loopex.attach(fixture.runtime, session, after_event_sequence: 0)
    assert {:accepted, "compact"} = Loopex.command(attachment, command(1_000))
    assert_receive {:holding, callback}, 5_000
    callback_monitor = Process.monitor(callback)
    before = recover(fixture, session)
    episode = before.maintenance_episodes[before.active_maintenance]

    assert :ok =
             M1RuntimeTestStore.hold_next_record_before_linearization(
               fixture.store,
               "maintenance_attempt_settled_v3",
               self()
             )

    send(callback, :release)
    assert_receive {:DOWN, ^callback_monitor, :process, ^callback, :normal}, 5_000

    assert_receive {:record_held_before_linearization, waiter, _,
                    "maintenance_attempt_settled_v3", transaction},
                   5_000

    assert [settlement] = transaction.records

    assert settlement["accounting"] == %{
             "source" => "reported",
             "input_tokens" => 37,
             "output_tokens" => 19
           }

    await_wall_cutoff(episode["deadline"], System.monotonic_time(:millisecond) + 5_000)
    M1RuntimeTestStore.release(waiter)
    completed = await_completed(fixture, session)
    result = completed.commands["compact"].result
    assert result["failure"]["bound"] == "deadline_ms"
    assert result["failure"]["observed"] >= episode["deadline"]
    assert result["failure"]["declared_limit"] == episode["deadline"]
    assert result["failure"]["accounting_source"] == "reported"

    assert result["usage"] == %{
             "attempts" => 1,
             "reported_tokens" => 56,
             "estimated_tokens" => 0,
             "total_tokens" => 56
           }

    assert result["usage"] == completed.maintenance_episodes[episode["episode_id"]]["usage"]
    assert result["cleanup"] == "confirmed"
    assert completed.active_checkpoint == nil
    assert completed.conversation == before.conversation

    assert Enum.count(
             Fixture.records(fixture, session),
             &(&1.payload.kind == "maintenance_attempt_settled_v3")
           ) == 1

    assert length(Loopex.AgentLoopTestModel.dispatched(fixture.model)) == 1
  end

  for recovery <- [:activate, :abort, :deadline] do
    @recovery recovery
    test "inherited standalone open attempt #{@recovery} remains paused and retains unknown cleanup" do
      {fixture, session} =
        live_history([%{text: summary(), reply_overrides: natural(), hold: self()}])

      {:ok, attachment} = Loopex.attach(fixture.runtime, session, after_event_sequence: 0)
      cmd = command(if @recovery == :deadline, do: 1_000, else: 60_000)
      assert {:accepted, "compact"} = Loopex.command(attachment, cmd)
      assert_receive {:holding, callback}, 5_000
      monitor = Process.monitor(callback)
      before = recover(fixture, session)
      original = before.maintenance_episodes[before.active_maintenance]
      kill_owner(fixture, session)
      assert_receive {:DOWN, ^monitor, :process, ^callback, _}, 5_000

      assert {:ok, {:prepared, activation}} =
               Loopex.prepare_resume_session(fixture.runtime, session, "recover-open")

      coordinator = owner(fixture, session)
      paused = :sys.get_state(coordinator)

      assert paused.durable.maintenance_episodes[before.active_maintenance]["stage"] ==
               "model_attempt_open"

      assert paused.in_flight == %{}
      assert paused.durable.owner_epoch > original["attempt_owner_epoch"]
      assert length(Loopex.AgentLoopTestModel.dispatched(fixture.model)) == 1

      if @recovery == :deadline do
        await_wall_cutoff(original["deadline"], System.monotonic_time(:millisecond) + 5_000)
        send(coordinator, {:compact_deadline, before.active_maintenance, original["deadline"]})
        send(coordinator, :advance_work)
        still_paused = :sys.get_state(coordinator)
        assert still_paused.durable.journal_version == paused.durable.journal_version
        assert still_paused.durable.pending_compact == paused.durable.pending_compact
        assert still_paused.in_flight == %{}
      end

      case @recovery do
        :abort ->
          {:ok, successor} = Loopex.attach(fixture.runtime, session, after_event_sequence: 0)

          assert {:accepted, "stop"} =
                   Loopex.command(successor, %{type: :abort, command_id: "stop"})

        _ ->
          assert {:ok, ^session} = Loopex.activate_resume(activation)
      end

      completed = await_completed(fixture, session)
      result = completed.commands["compact"].result
      assert result["cleanup"] == "unknown"

      assert result["usage"] == %{
               "attempts" => 1,
               "reported_tokens" => 0,
               "estimated_tokens" => 32_768,
               "total_tokens" => 32_768
             }

      expected =
        case @recovery do
          :activate -> "model_call_failed"
          :abort -> "cancelled"
          :deadline -> "bound_reached"
        end

      if @recovery == :deadline do
        assert result["failure"]["bound"] == "deadline_ms"
        assert result["failure"]["declared_limit"] == original["deadline"]
        assert result["failure"]["observed"] >= original["deadline"]
        assert result["failure"]["accounting_source"] == "estimated"
      end

      assert result["failure"]["category"] == expected
      assert completed.conversation == before.conversation
      assert completed.charged == before.charged
      assert completed.active_checkpoint == nil
      assert length(Loopex.AgentLoopTestModel.dispatched(fixture.model)) == 1
      assert Task.Supervisor.children(:sys.get_state(coordinator).owner_workers) == []
    end
  end

  test "live standalone irreducible excerpt retains the named unavailable refusal before any intent" do
    configuration =
      Genesis.configuration()
      |> Map.put("context_token_budget", 800)
      |> Map.put("system_class_tokens", 800)
      |> put_in(["budget_origins", "context_token_budget"], "explicit")

    {fixture, session} =
      live_history([],
        configuration: configuration,
        history_content: String.duplicate("o", 30_000),
        maintenance_instructions: %{
          "version" => "summary.v1",
          "body" => String.duplicate("i", 2_048)
        }
      )

    {:ok, attachment} = Loopex.attach(fixture.runtime, session, after_event_sequence: 0)
    assert {:accepted, "compact"} = Loopex.command(attachment, command())
    completed = await_completed(fixture, session)
    result = completed.commands["compact"].result
    assert result["failure"] == preparation_failure("compaction_excerpt_budget_too_small", nil)
    assert result["usage"] == zero_usage()
    assert result["cleanup"] == "confirmed"
    assert Loopex.AgentLoopTestModel.dispatched(fixture.model) == []

    refute Enum.any?(
             Fixture.records(fixture, session),
             &(&1.payload.kind == "maintenance_request_committed_v1")
           )

    assert completed.active_checkpoint == nil
  end

  test "live standalone source system refusal retains exact maintenance measurement before dispatch" do
    configuration = Genesis.configuration() |> Map.put("system_class_tokens", 64)

    {fixture, session} =
      live_history([],
        configuration: configuration,
        maintenance_instructions: %{
          "version" => "summary.v1",
          "body" => String.duplicate("s", 1_000)
        }
      )

    {:ok, attachment} = Loopex.attach(fixture.runtime, session, after_event_sequence: 0)
    assert {:accepted, "compact"} = Loopex.command(attachment, command())
    completed = await_completed(fixture, session)
    result = completed.commands["compact"].result
    assert result["failure"]["category"] == "context_budget_exceeded"
    assert result["failure"]["measurement_scope"] == "maintenance"
    assert result["failure"]["dimension"] == "system_class_tokens"
    assert result["failure"]["limit"] == 64

    capture =
      completed.maintenance_episodes
      |> Map.values()
      |> hd()
      |> Map.fetch!("maintenance_configuration")

    system = %{"role" => "system", "content" => capture["instructions"]["rendered_bytes"]}

    assert result["failure"]["observed"] ==
             Loopex.Bounds.estimate(LoopexProtocol.Canonical.encode(system))

    assert result["failure"]["observed"] > 64
    assert result["usage"] == zero_usage()
    assert Loopex.AgentLoopTestModel.dispatched(fixture.model) == []

    assert Enum.map(Enum.take(Fixture.records(fixture, session), -2), & &1.payload.kind) ==
             ["maintenance_episode_terminal_v1", "compact_command_completed_v1"]
  end

  test "exhausted standalone attempts retain a useful checkpoint and finish at their actual bound" do
    contents = for letter <- ["a", "b", "c", "d"], do: String.duplicate(letter, 18_000)

    {fixture, session} =
      live_history(
        [
          %{
            text: summary(),
            reply_overrides: natural(),
            usage: %{input_tokens: 37, output_tokens: 19}
          }
        ],
        history_contents: contents
      )

    {:ok, attachment} = Loopex.attach(fixture.runtime, session, after_event_sequence: 0)
    cmd = put_in(command(1_000), [:bounds, "max_attempts"], 1)
    assert {:accepted, "compact"} = Loopex.command(attachment, cmd)
    completed = await_completed(fixture, session)
    result = completed.commands["compact"].result
    assert result["disposition"] == "failed"
    assert is_binary(result["checkpoint_id"])
    assert result["usage"]["attempts"] == 1
    assert result["usage"]["reported_tokens"] == 56

    assert result["failure"] == %{
             "category" => "bound_reached",
             "retryable" => false,
             "bound" => "max_attempts",
             "observed" => 1,
             "declared_limit" => 1,
             "accounting_source" => nil
           }

    assert length(Loopex.AgentLoopTestModel.dispatched(fixture.model)) == 1
  end

  for budget <- [1, 1_023] do
    @initial_budget budget
    test "standalone initial budget #{@initial_budget} refuses the fixed reply before dispatch" do
      {fixture, session} = live_history([], history_content: String.duplicate("f", 8_000))
      {:ok, attachment} = Loopex.attach(fixture.runtime, session, after_event_sequence: 0)
      cmd = put_in(command(), [:bounds, "token_budget"], @initial_budget)
      assert {:accepted, "compact"} = Loopex.command(attachment, cmd)
      completed = await_completed(fixture, session)
      result = completed.commands["compact"].result

      assert result == %{
               "disposition" => "failed",
               "checkpoint_id" => nil,
               "failure" => %{
                 "category" => "bound_reached",
                 "retryable" => false,
                 "bound" => "token_budget",
                 "observed" => 0,
                 "declared_limit" => @initial_budget,
                 "accounting_source" => nil
               },
               "usage" => zero_usage(),
               "cleanup" => "confirmed"
             }

      assert Loopex.AgentLoopTestModel.dispatched(fixture.model) == []

      refute Enum.any?(
               Fixture.records(fixture, session),
               &(&1.payload.kind == "maintenance_request_committed_v1")
             )

      assert completed.active_maintenance == nil
      assert completed.charged == %{}
    end
  end

  for remaining <- [1, 1_023] do
    @remaining_tokens remaining
    test "standalone partial checkpoint retains #{@remaining_tokens} unspent tokens without another summary" do
      contents = for letter <- ["a", "b", "c", "d"], do: String.duplicate(letter, 18_000)

      {fixture, session} =
        live_history(
          [
            %{
              text: summary(),
              reply_overrides: natural(),
              usage: %{input_tokens: 999, output_tokens: 25}
            }
          ],
          history_contents: contents
        )

      before = recover(fixture, session)
      {:ok, attachment} = Loopex.attach(fixture.runtime, session, after_event_sequence: 0)
      cmd = put_in(command(), [:bounds, "token_budget"], 1_024 + @remaining_tokens)
      assert {:accepted, "compact"} = Loopex.command(attachment, cmd)
      completed = await_completed(fixture, session)
      result = completed.commands["compact"].result

      assert result["failure"] == %{
               "category" => "bound_reached",
               "retryable" => false,
               "bound" => "token_budget",
               "observed" => 1_024,
               "declared_limit" => 1_024 + @remaining_tokens,
               "accounting_source" => "reported"
             }

      assert result["disposition"] == "failed"
      assert result["checkpoint_id"] == completed.active_checkpoint
      assert is_binary(result["checkpoint_id"])

      assert result["usage"] == %{
               "attempts" => 1,
               "reported_tokens" => 1_024,
               "estimated_tokens" => 0,
               "total_tokens" => 1_024
             }

      assert result["cleanup"] == "confirmed"
      assert length(Loopex.AgentLoopTestModel.dispatched(fixture.model)) == 1
      assert completed.conversation == before.conversation
      assert completed.charged == before.charged
      assert completed.deadlines == before.deadlines
      assert map_size(completed.checkpoints) == 1

      assert Enum.map(Enum.take(Fixture.records(fixture, session), -2), & &1.payload.kind) ==
               ["maintenance_episode_terminal_v1", "compact_command_completed_v1"]
    end
  end

  for charged <- [1_024, 2_048] do
    @charged_tokens charged
    test "standalone actual token charge #{@charged_tokens} ends without discarding usage or creating a checkpoint" do
      {fixture, session} =
        live_history(
          [
            %{
              text: summary(),
              reply_overrides: natural(),
              usage: %{input_tokens: @charged_tokens - 25, output_tokens: 25}
            }
          ],
          history_content: String.duplicate("f", 8_000)
        )

      {:ok, attachment} = Loopex.attach(fixture.runtime, session, after_event_sequence: 0)
      cmd = put_in(command(), [:bounds, "token_budget"], 1_024)
      assert {:accepted, "compact"} = Loopex.command(attachment, cmd)
      completed = await_completed(fixture, session)
      result = completed.commands["compact"].result

      assert result["failure"] == %{
               "category" => "bound_reached",
               "retryable" => false,
               "bound" => "token_budget",
               "observed" => @charged_tokens,
               "declared_limit" => 1_024,
               "accounting_source" => "reported"
             }

      assert result["checkpoint_id"] == nil
      assert result["usage"]["total_tokens"] == @charged_tokens
      assert result["usage"]["attempts"] == 1
      assert completed.active_checkpoint == nil
      assert completed.charged == %{}
      assert length(Loopex.AgentLoopTestModel.dispatched(fixture.model)) == 1
    end
  end

  for mode <- [:initial, :partial],
      phase <- [
        :before_linearization,
        :after_linearization_before_result,
        :recovery_representation
      ] do
    @capacity_mode mode
    @capacity_phase phase
    test "standalone #{@capacity_mode} token bound resolves #{@capacity_phase} without spending again" do
      {fixture, session} =
        if @capacity_mode == :initial do
          live_history([], history_content: String.duplicate("f", 8_000))
        else
          contents = for letter <- ["a", "b", "c", "d"], do: String.duplicate(letter, 18_000)

          live_history(
            [
              %{
                text: summary(),
                reply_overrides: natural(),
                usage: %{input_tokens: 999, output_tokens: 25}
              }
            ],
            history_contents: contents
          )
        end

      before = recover(fixture, session)
      predecessor = owner(fixture, session)
      {:ok, attachment} = Loopex.attach(fixture.runtime, session, after_event_sequence: 0)
      budget = if @capacity_mode == :initial, do: 1_023, else: 1_025
      cmd = put_in(command(), [:bounds, "token_budget"], budget)

      assert :ok =
               M1RuntimeTestStore.hold_next_record_before_linearization(
                 fixture.store,
                 "maintenance_episode_terminal_v1",
                 self()
               )

      assert {:accepted, "compact"} = Loopex.command(attachment, cmd)

      assert_receive {:record_held_before_linearization, waiter, _,
                      "maintenance_episode_terminal_v1", transaction},
                     5_000

      assert [terminal, completed] = transaction.records
      assert terminal.kind == "maintenance_episode_terminal_v1"
      assert completed.kind == "compact_command_completed_v1"
      result = completed["result"]
      assert result["failure"]["bound"] == "token_budget"
      assert result["failure"]["declared_limit"] == budget
      assert result["failure"]["observed"] == if(@capacity_mode == :initial, do: 0, else: 1_024)
      assert result["usage"]["attempts"] == if(@capacity_mode == :initial, do: 0, else: 1)

      refute Enum.any?(
               Fixture.events(fixture, session),
               &(&1.kind == "context.compaction_finished")
             )

      assert :ok =
               M1RuntimeTestStore.inject(
                 fixture.store,
                 {:session_journal_commit, @capacity_phase}
               )

      M1RuntimeTestStore.release(waiter)
      await_worker_adoption(predecessor, System.monotonic_time(:millisecond) + 5_000)
      kill_owner(fixture, session)

      assert {:ok, {:prepared, activation}} =
               Loopex.prepare_resume_session(fixture.runtime, session, "resolve-capacity")

      assert {:ok, ^session} = Loopex.activate_resume(activation)
      next = await_completed(fixture, session)
      assert next.commands["compact"].result == result
      assert next.active_checkpoint == result["checkpoint_id"]
      assert next.charged == before.charged
      assert next.conversation == before.conversation
      assert next.deadlines == before.deadlines

      assert length(Loopex.AgentLoopTestModel.dispatched(fixture.model)) ==
               result["usage"]["attempts"]

      assert Enum.count(
               Fixture.events(fixture, session),
               &(&1.kind == "context.compaction_finished")
             ) == 1

      assert Enum.count(
               Fixture.records(fixture, session),
               &(&1.payload.kind == "compact_command_completed_v1")
             ) == 1
    end
  end

  defp natural, do: %{completion: "natural", continuation: nil}

  defp summary,
    do: ~s({"summary":"retain this fact","carry_forward":{"files_read":[],"files_changed":[]}})

  defp live_history(script, options \\ []),
    do:
      history_fixture(
        Keyword.merge(
          [
            maintenance_model: :eligible,
            maintenance_instructions: :present,
            source_preparation: :live,
            script: script
          ],
          options
        )
      )

  # Concept: live maintenance starts with actual settled canonical history.
  # Technical depth: the prior runtime exits before pure proposals use the
  # existing Store transaction boundary. A new runtime then resumes that same
  # journal; no live owner's state or clock is replaced by the fixture.
  defp history_fixture(options) do
    prior = start(script: [], tools: [])

    {:ok, session} =
      Loopex.create_session(prior.runtime, %{},
        command_id: "create",
        genesis:
          Genesis.genesis(
            [],
            Keyword.get_lazy(options, :configuration, fn -> Genesis.configuration() end)
          )
      )

    assert :ok = Loopex.stop(prior.runtime)
    state = recover(prior, session)

    contents =
      Keyword.get(options, :history_contents, [
        Keyword.get(options, :history_content, "retain this fact")
      ])

    _ =
      Enum.reduce(Enum.with_index(contents), state, fn {content, index}, state ->
        {:ok, prompt} =
          SessionState.propose(
            state,
            %{
              type: :prompt,
              command_id: if(index == 0, do: "old", else: "old-#{index}"),
              content: content
            },
            %{
              max_turns: 8,
              deadline_ms: 60_000,
              token_budget: 10_000,
              context_token_budget: state.configuration["context_token_budget"]
            }
          )

        state = retain(prior, state, prompt)

        {:ok, terminal} =
          SessionState.propose_run_terminal(state, state.active_run_id, "failed", %{
            reason: "model_call_failed"
          })

        retain(prior, state, terminal)
      end)

    source_live? = Keyword.get(options, :source_preparation) == :live

    options =
      options
      |> Keyword.drop([:configuration, :source_preparation, :history_content, :history_contents])
      |> Enum.map(fn
        {:maintenance_model, :eligible} ->
          {:maintenance_model, model()}

        {:maintenance_model, :unsupported} ->
          {:maintenance_model, Map.put(model(), "reasoning", "default")}

        {:maintenance_instructions, :present} ->
          {:maintenance_instructions, %{"version" => "summary.v1", "body" => "Keep facts"}}

        pair ->
          pair
      end)

    fixture = start(options ++ [script: [], tools: [], store: prior.store])
    {:ok, _} = Loopex.prepare_resume_session(fixture.runtime, session, "prepare")

    unless source_live?,
      do: hold_source_worker(:sys.get_state(owner(fixture, session)).owner_workers)

    {fixture, session}
  end

  defp model do
    source = Genesis.configuration()

    %{
      "model" => source["model"],
      "reasoning" => "none",
      "model_capabilities" => %{
        source["model_capabilities"]
        | "reasoning_levels" => ["none", "default"]
      },
      "provider_mapping" => %{source["provider_mapping"] | "thinking_disabled" => true}
    }
  end

  defp command(deadline_ms \\ 60_000),
    do: %{
      type: :compact,
      command_id: "compact",
      bounds: %{"max_attempts" => 4, "deadline_ms" => deadline_ms, "token_budget" => 32_768}
    }

  defp preparation_failure(cause, scope \\ "ordinary"),
    do: %{
      "version" => 2,
      "category" => "context_preparation_failed",
      "retryable" => false,
      "measurement_scope" => scope,
      "cause" => cause
    }

  defp zero_usage,
    do: %{"attempts" => 0, "reported_tokens" => 0, "estimated_tokens" => 0, "total_tokens" => 0}

  defp start(options) do
    fixture = Fixture.start(options)
    on_exit(fn -> Fixture.stop(fixture) end)
    fixture
  end

  defp owner(fixture, session) do
    {:ok, children} = Loopex.Runtime.children(fixture.runtime)
    :sys.get_state(children.control).sessions[session].coordinator
  end

  defp kill_owner(fixture, session) do
    pid = owner(fixture, session)
    monitor = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^pid, _}, 5_000
  end

  defp await_wall_cutoff(wall_cutoff, fixture_cutoff) do
    if System.system_time(:millisecond) < wall_cutoff do
      assert System.monotonic_time(:millisecond) < fixture_cutoff
      Process.sleep(1)
      await_wall_cutoff(wall_cutoff, fixture_cutoff)
    end
  end

  defp await_source_worker(coordinator, cutoff) do
    case Enum.find_value(:sys.get_state(coordinator).in_flight, fn
           {_, {:maintenance_preparation, {:compact, "compact"}, worker, metadata}} ->
             {worker, metadata}

           _ ->
             nil
         end) do
      nil ->
        assert System.monotonic_time(:millisecond) < cutoff
        Process.sleep(1)
        await_source_worker(coordinator, cutoff)

      value ->
        value
    end
  end

  defp await_worker_adoption(owner, cutoff) do
    try do
      if :sys.get_state(owner).in_flight != %{} do
        assert System.monotonic_time(:millisecond) < cutoff
        Process.sleep(1)
        await_worker_adoption(owner, cutoff)
      end
    catch
      :exit, _ -> :ok
    end
  end

  defp recover(fixture, session) do
    retained = M1RuntimeTestStore.inspect_state(fixture.store).sessions[session]

    {:ok, state} =
      SessionState.recover(
        session,
        retained.records,
        retained.events
      )

    state
  end

  defp await_completed(fixture, session),
    do: await_state(fixture, session, &is_nil(&1.pending_compact))

  defp await_state(fixture, session, predicate),
    do: await_state(fixture, session, predicate, System.monotonic_time(:millisecond) + 5_000)

  defp await_state(fixture, session, predicate, cutoff) do
    state = recover(fixture, session)

    if predicate.(state),
      do: state,
      else:
        (
          assert System.monotonic_time(:millisecond) < cutoff
          Process.sleep(1)
          await_state(fixture, session, predicate, cutoff)
        )
  end

  defp retain(fixture, state, proposal) do
    {:ok, store} = Store.new(M1RuntimeTestStore, fixture.store)

    {:ok, tx} =
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

    assert {:committed, _, receipt} = Store.transact(store, tx)
    {:ok, next} = SessionState.commit_proposal(proposal, receipt)
    next
  end

  defp maintenance_views(fixture, session),
    do: Enum.filter(Fixture.events(fixture, session), &(&1.kind == "context.maintenance_changed"))

  # Concept: initial-capture proofs stop at the source phase they exercise.
  # Technical depth: the Supervisor holds its second exact Task, after the
  # initial capture worker exits. Live-provider cases opt out explicitly;
  # production clocks and the source cutoff remain unchanged while it is held.
  defp hold_source_worker(supervisor) do
    hook = fn
      0, {:out, {:ok, worker}, _, _}, _ when is_pid(worker) ->
        1

      1, {:out, {:ok, worker}, _, _}, _ when is_pid(worker) ->
        true = :erlang.suspend_process(worker)
        2

      count, _, _ ->
        count
    end

    assert :ok = :sys.install(supervisor, {hook, 0})

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

  defp hold_worker(supervisor) do
    caller = self()

    hook = fn
      :armed, {:out, {:ok, worker}, _, _}, _ when is_pid(worker) ->
        true = :erlang.suspend_process(worker)
        send(caller, {:held_compact_worker, worker})
        :held

      state, _, _ ->
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
end
