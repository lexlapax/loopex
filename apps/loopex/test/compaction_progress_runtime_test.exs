Code.require_file("support/m1_runtime_helper.exs", __DIR__)
Code.require_file("support/agent_loop_helper.exs", __DIR__)
Code.require_file("support/configured_genesis_helper.exs", __DIR__)

defmodule Loopex.Runtime.CompactionProgressTest do
  use ExUnit.Case, async: false

  alias Loopex.AgentLoopFixture, as: Fixture
  alias Loopex.AgentLoopTestModel
  alias Loopex.ConfiguredGenesisFixture, as: Genesis
  alias Loopex.M1RuntimeTestStore
  alias Loopex.Runtime.{Control, SessionState}
  alias Loopex.{CompactionProgress, Store, StreamDomain}

  test "standalone actual permit emits its committed owner binding and discards every summary delta" do
    {fixture, session, _activation} = history(:compact, [held_summary()])
    {:ok, attachment} = Loopex.attach(fixture.runtime, session, after_event_sequence: 0)
    coordinator = owner(fixture, session)
    control = control(fixture)
    :erlang.trace(control, true, [:send])
    assert {:accepted, "compact"} = Loopex.command(attachment, command())
    assert_receive {:holding, worker}, 5_000
    assert_receive {:loopex_progress, item}, 5_000
    live = :sys.get_state(coordinator)
    episode = live.durable.maintenance_episodes[item.episode_id]
    assert_item(item, session, episode, %{"kind" => "compact", "id" => "compact"})
    assert item.base_event_sequence == live.durable.event_sequence
    assert_positive_permit(control, worker, episode)
    assert live.compaction_relay in Task.Supervisor.children(live.workers)
    assert map_size(live.streams) == 0
    assert CompactionProgress.project(Map.put(item, :summary, "private summary")) == :error
    refute_receive {:loopex_progress, _}, 0

    monitor = Process.monitor(worker)
    send(worker, :release)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 5_000
    done = await_state(fixture, session, &is_nil(&1.pending_compact))
    assert done.commands["compact"].result["disposition"] == "checkpointed"
    assert Task.Supervisor.children(:sys.get_state(coordinator).owner_workers) == []
    assert Enum.count(Fixture.events(fixture, session), &(&1.kind == "context.compacted")) == 1

    assert Enum.count(
             Fixture.events(fixture, session),
             &(&1.kind == "context.compaction_finished")
           ) == 1

    refute Enum.any?(Fixture.records(fixture, session), &(&1.payload.kind == item.kind))
    refute Enum.any?(Fixture.events(fixture, session), &(&1.kind == item.kind))
    assert done.commands["compact"].result == Loopex.command(attachment, command())
    refute_receive {:loopex_progress, _}, 0

    relay = live.compaction_relay
    relay_monitor = Process.monitor(relay)
    kill_owner(coordinator)
    assert_receive {:DOWN, ^relay_monitor, :process, ^relay, :killed}, 5_000

    {:ok, {:prepared, activation}} =
      Loopex.prepare_resume_session(fixture.runtime, session, "replay")

    assert {:ok, ^session} = Loopex.activate_resume(activation)
    {:ok, resumed} = Loopex.attach(fixture.runtime, session, after_event_sequence: 0)
    assert done.commands["compact"].result == Loopex.command(resumed, command())
    assert :sys.get_state(owner(fixture, session)).compaction_relay == nil
    assert length(AgentLoopTestModel.dispatched(fixture.model)) == 1
    refute_receive {:loopex_progress, _}, 0
    :erlang.trace(control, false, [:all])
  end

  test "automatic actual permit emits the real run owner and keeps its outcome durable" do
    {fixture, session, activation} = history(:run, [held_summary(), %{text: "answer", calls: []}])
    coordinator = owner(fixture, session)
    control = control(fixture)
    :erlang.trace(control, true, [:send])
    assert {:ok, ^session} = Loopex.activate_resume(activation)
    assert_receive {:holding, worker}, 5_000
    assert_receive {:loopex_progress, item}, 5_000
    live = :sys.get_state(coordinator)
    run = live.durable.active_run_id
    episode = live.durable.maintenance_episodes[item.episode_id]
    assert_item(item, session, episode, %{"kind" => "run", "id" => run})
    assert item.base_event_sequence == live.durable.event_sequence
    assert_positive_permit(control, worker, episode)
    send(worker, :release)
    done = await_state(fixture, session, &is_nil(&1.active_run_id))
    assert is_binary(done.active_checkpoint)
    assert length(AgentLoopTestModel.dispatched(fixture.model)) == 2
    progress = drain_progress()
    refute Enum.any?(progress, &(&1.kind == "context.compaction_progress"))
    refute Enum.any?(progress, &(Map.get(&1, :stream_domain_id) == item.stream_domain_id))
    assert Enum.count(progress, &(&1.kind == :model_stream_closed)) == 1
    refute Enum.any?(progress, &(Map.get(&1, :text) == "private summary delta"))
    :erlang.trace(control, false, [:all])
  end

  test "a permitted retry has a new domain while one relay retains no attempt history" do
    {fixture, session, _activation} =
      history(:compact, [
        %{raw_result: {:error, {:not_dispatched, "model_call_failed"}}},
        held_summary()
      ])

    {:ok, attachment} = Loopex.attach(fixture.runtime, session, after_event_sequence: 0)
    assert {:accepted, "compact"} = Loopex.command(attachment, command())
    assert_receive {:holding, worker}, 5_000
    assert_receive {:loopex_progress, first}, 5_000
    assert_receive {:loopex_progress, retry}, 5_000
    refute first.stream_domain_id == retry.stream_domain_id
    assert first.episode_id == retry.episode_id
    assert first.owner == retry.owner
    assert first.progress_sequence == 0 and retry.progress_sequence == 0
    opens = records(fixture, session, "maintenance_attempt_opened_v1")
    assert Enum.map(opens, & &1["attempt"]) == [1, 2]

    for {item, opened} <- Enum.zip([first, retry], opens) do
      assert item.stream_domain_id ==
               StreamDomain.derive(
                 :compaction,
                 session,
                 opened["operation_id"],
                 opened["attempt"]
               )
    end

    relay = :sys.get_state(owner(fixture, session)).compaction_relay
    assert is_pid(relay)

    assert Enum.count(
             Task.Supervisor.children(:sys.get_state(owner(fixture, session)).workers),
             &(&1 == relay)
           ) == 1

    send(worker, :release)
    completed = await_state(fixture, session, &is_nil(&1.pending_compact))
    assert completed.commands["compact"].result["usage"]["attempts"] == 2
    assert :sys.get_state(owner(fixture, session)).compaction_relay == relay
    refute_receive {:loopex_progress, _}, 0
  end

  test "further summary operations each expose only one domain and sequence zero" do
    script = for _ <- 1..4, do: summary()
    contents = for letter <- ["a", "b", "c", "d"], do: String.duplicate(letter, 18_000)
    {fixture, session, _activation} = history(:compact, script, contents: contents)
    {:ok, attachment} = Loopex.attach(fixture.runtime, session, after_event_sequence: 0)
    assert {:accepted, "compact"} = Loopex.command(attachment, command())
    completed = await_state(fixture, session, &is_nil(&1.pending_compact))
    assert completed.commands["compact"].result["usage"]["attempts"] == 3
    activity = drain_progress()
    assert length(activity) == 3

    assert Enum.all?(
             activity,
             &(&1.kind == "context.compaction_progress" and &1.progress_sequence == 0)
           )

    assert length(Enum.uniq_by(activity, & &1.stream_domain_id)) == 3
    assert length(Enum.uniq_by(activity, & &1.episode_id)) == 1
    opens = records(fixture, session, "maintenance_attempt_opened_v1")
    assert length(Enum.uniq_by(opens, & &1["operation_id"])) == 3

    for {item, opened} <- Enum.zip(activity, opens) do
      assert item.stream_domain_id ==
               StreamDomain.derive(
                 :compaction,
                 session,
                 opened["operation_id"],
                 opened["attempt"]
               )
    end
  end

  test "negative actual permit cannot open the activity relay or invoke the adapter" do
    {fixture, session, _activation} = history(:compact, [summary()])
    control = control(fixture)
    :sys.replace_state(control, &%{&1 | wall_clock: fn -> 18_446_744_073_709_551_615 end})
    :erlang.trace(control, true, [:send])
    {:ok, attachment} = Loopex.attach(fixture.runtime, session, after_event_sequence: 0)
    assert {:accepted, "compact"} = Loopex.command(attachment, command())

    assert_receive {:trace, ^control, :send, {_reply, {:error, :deadline_elapsed}}, _coordinator},
                   5_000

    state = :sys.get_state(owner(fixture, session))
    assert state.compaction_relay == nil
    assert AgentLoopTestModel.dispatched(fixture.model) == []
    refute_receive {:loopex_progress, _}, 0
    :erlang.trace(control, false, [:all])
  end

  test "preparation refusal supplies durable failure without progress or a relay" do
    {fixture, session, _activation} = history(:compact, [], instructions: nil)
    {:ok, attachment} = Loopex.attach(fixture.runtime, session, after_event_sequence: 0)
    assert {:accepted, "compact"} = Loopex.command(attachment, command())
    done = await_state(fixture, session, &is_nil(&1.pending_compact))

    assert done.commands["compact"].result["failure"]["cause"] ==
             "maintenance_instructions_unconfigured"

    assert :sys.get_state(owner(fixture, session)).compaction_relay == nil
    assert AgentLoopTestModel.dispatched(fixture.model) == []
    refute_receive {:loopex_progress, _}, 0
  end

  test "current owner rejects private payload and stale owner cannot send through a live relay" do
    {fixture, session, _activation} = history(:compact, [held_summary()])
    {:ok, attachment} = Loopex.attach(fixture.runtime, session, after_event_sequence: 0)
    assert {:accepted, "compact"} = Loopex.command(attachment, command())
    assert_receive {:holding, worker}, 5_000
    assert_receive {:loopex_progress, item}, 5_000
    coordinator = owner(fixture, session)
    state = :sys.get_state(coordinator)

    assert Control.project_progress(
             state.control,
             session,
             state.owner,
             state.compaction_relay,
             Map.put(item, :summary, "private")
           ) == {:error, :invalid_compaction_progress}

    stale = Map.update!(state.owner, :owner_epoch, &(&1 + 1))

    assert Control.project_progress(state.control, session, stale, state.compaction_relay, item) ==
             {:error, :superseded_owner}

    refute_receive {:loopex_progress, _}, 0
    send(worker, :release)
    _ = await_state(fixture, session, &is_nil(&1.pending_compact))
  end

  test "owner death while provider is held loses activity without successor replay or closure" do
    {fixture, session, _activation} = history(:compact, [held_summary()])
    {:ok, attachment} = Loopex.attach(fixture.runtime, session, after_event_sequence: 0)
    assert {:accepted, "compact"} = Loopex.command(attachment, command())
    assert_receive {:holding, worker}, 5_000
    assert_receive {:loopex_progress, item}, 5_000
    predecessor = owner(fixture, session)
    relay = :sys.get_state(predecessor).compaction_relay
    joins = for pid <- [worker, relay], do: {pid, Process.monitor(pid)}
    kill_owner(predecessor)

    for {pid, monitor} <- joins do
      assert_receive {:DOWN, ^monitor, :process, ^pid, reason}, 5_000
      assert reason in [:killed, :shutdown]
    end

    {:ok, {:prepared, activation}} =
      Loopex.prepare_resume_session(fixture.runtime, session, "lost-owner")

    assert :sys.get_state(owner(fixture, session)).compaction_relay == nil
    assert {:ok, ^session} = Loopex.activate_resume(activation)
    done = await_state(fixture, session, &is_nil(&1.pending_compact))
    assert done.commands["compact"].result["cleanup"] == "unknown"
    assert length(AgentLoopTestModel.dispatched(fixture.model)) == 1
    refute_receive {:loopex_progress, _}, 0

    assert Enum.count(
             Fixture.events(fixture, session),
             &(&1.kind == "context.compaction_finished")
           ) == 1

    refute Enum.any?(Fixture.events(fixture, session), &(&1.kind == item.kind))
  end

  test "dropped activity and a delayed relay do not hold provider settlement or infer its outcome" do
    {fixture, session, _activation} = history(:compact, [held_summary()], progress_to: nil)
    {:ok, attachment} = Loopex.attach(fixture.runtime, session, after_event_sequence: 0)
    assert {:accepted, "compact"} = Loopex.command(attachment, command())
    assert_receive {:holding, worker}, 5_000
    relay = :sys.get_state(owner(fixture, session)).compaction_relay
    true = :erlang.suspend_process(relay)
    send(worker, :release)
    done = await_state(fixture, session, &is_nil(&1.pending_compact))
    assert done.commands["compact"].result["disposition"] == "checkpointed"
    true = :erlang.resume_process(relay)
    {:ok, _reattached} = Loopex.attach(fixture.runtime, session, after_event_sequence: 0)
    assert recover(fixture, session).commands["compact"].result == done.commands["compact"].result
    refute_receive {:loopex_progress, _}, 0
  end

  for phase <- [
        :before_linearization,
        :after_linearization_before_result,
        :recovery_representation
      ] do
    @phase phase
    test "opened attempt #{@phase} uncertainty permits activity only after resolution and a positive permit" do
      {fixture, session, _activation} = history(:compact, [held_summary()])

      assert :ok =
               M1RuntimeTestStore.hold_next_record_before_linearization(
                 fixture.store,
                 "maintenance_attempt_opened_v1",
                 self()
               )

      {:ok, attachment} = Loopex.attach(fixture.runtime, session, after_event_sequence: 0)
      assert {:accepted, "compact"} = Loopex.command(attachment, command())

      assert_receive {:record_held_before_linearization, waiter, _store,
                      "maintenance_attempt_opened_v1", transaction},
                     5_000

      assert Enum.any?(transaction.records, &(&1.kind == "maintenance_attempt_opened_v1"))
      assert records(fixture, session, "maintenance_attempt_opened_v1") == []
      assert AgentLoopTestModel.dispatched(fixture.model) == []
      refute_receive {:loopex_progress, _}, 0
      predecessor = owner(fixture, session)
      predecessor_monitor = Process.monitor(predecessor)
      assert :ok = M1RuntimeTestStore.inject(fixture.store, {:session_journal_commit, @phase})
      M1RuntimeTestStore.release(waiter)

      case @phase do
        :recovery_representation ->
          # Concept: two unknown answers fence the old owner rather than
          # authorizing a provider attempt.
          # Technical depth: this fixture returns unknown both at the first
          # linearized commit and at its exact representation. The existing
          # compact owner stops; the successor recovers the committed open row
          # conservatively and never emits activity for that inherited attempt.
          assert_receive {:DOWN, ^predecessor_monitor, :process, ^predecessor,
                          {:compact_commit_failed, :commit_unknown}},
                         5_000

          assert AgentLoopTestModel.dispatched(fixture.model) == []
          refute_receive {:loopex_progress, _}, 0

          {:ok, {:prepared, activation}} =
            Loopex.prepare_resume_session(fixture.runtime, session, "unknown-open")

          assert :sys.get_state(owner(fixture, session)).compaction_relay == nil
          assert {:ok, ^session} = Loopex.activate_resume(activation)
          done = await_state(fixture, session, &is_nil(&1.pending_compact))
          assert done.commands["compact"].result["usage"]["attempts"] == 1
          assert done.commands["compact"].result["cleanup"] == "unknown"
          assert AgentLoopTestModel.dispatched(fixture.model) == []
          assert length(records(fixture, session, "maintenance_attempt_opened_v1")) == 1
          refute_receive {:loopex_progress, _}, 0

        _resolved_within_original_owner ->
          assert_receive {:holding, worker}, 5_000
          assert_receive {:loopex_progress, item}, 5_000
          [opened] = records(fixture, session, "maintenance_attempt_opened_v1")

          assert item.stream_domain_id ==
                   StreamDomain.derive(
                     :compaction,
                     session,
                     opened["operation_id"],
                     opened["attempt"]
                   )

          send(worker, :release)
          done = await_state(fixture, session, &is_nil(&1.pending_compact))
          assert done.commands["compact"].result["usage"]["attempts"] == 1
          assert length(AgentLoopTestModel.dispatched(fixture.model)) == 1
          Process.demonitor(predecessor_monitor, [:flush])
          refute_receive {:loopex_progress, _}, 0
      end

      assert MapSet.member?(
               M1RuntimeTestStore.observed(fixture.store),
               {:session_journal_commit, @phase}
             )
    end
  end

  test "a committed open attempt with lost owner reply produces no successor activity" do
    {fixture, session, _activation} = history(:compact, [summary()])

    assert :ok =
             M1RuntimeTestStore.delay_after_record(
               fixture.store,
               "maintenance_attempt_opened_v1",
               self()
             )

    {:ok, attachment} = Loopex.attach(fixture.runtime, session, after_event_sequence: 0)
    predecessor = owner(fixture, session)
    assert {:accepted, "compact"} = Loopex.command(attachment, command())

    assert_receive {:record_linearized, waiter, _store, "maintenance_attempt_opened_v1",
                    _transition, {:committed, _tx, _receipt}},
                   5_000

    assert length(records(fixture, session, "maintenance_attempt_opened_v1")) == 1
    assert AgentLoopTestModel.dispatched(fixture.model) == []
    refute_receive {:loopex_progress, _}, 0
    kill_owner(predecessor)
    M1RuntimeTestStore.release(waiter)

    {:ok, {:prepared, activation}} =
      Loopex.prepare_resume_session(fixture.runtime, session, "lost-open-reply")

    assert :sys.get_state(owner(fixture, session)).compaction_relay == nil
    assert {:ok, ^session} = Loopex.activate_resume(activation)
    done = await_state(fixture, session, &is_nil(&1.pending_compact))
    assert done.commands["compact"].result["cleanup"] == "unknown"
    assert AgentLoopTestModel.dispatched(fixture.model) == []
    refute_receive {:loopex_progress, _}, 0
  end

  test "owner loss between positive permit and projection refuses the queued activity" do
    {fixture, session, _activation} = history(:compact, [held_summary()])
    control = control(fixture)
    observer = self()

    hook = fn
      :armed,
      {:in,
       {:"$gen_call", _from,
        {:project_progress, _session, _owner, relay,
         %{kind: "context.compaction_progress"} = item}}},
      _extra ->
        send(observer, {:activity_admission_held, self(), relay, item})
        receive do: (:release_activity_admission -> :held)

      state, _event, _extra ->
        state
    end

    assert :ok = :sys.install(control, {hook, :armed})

    on_exit(fn ->
      if Process.alive?(control) do
        send(control, :release_activity_admission)

        try do
          :sys.remove(control, hook)
        catch
          :exit, _reason -> :ok
        end
      end
    end)

    {:ok, attachment} = Loopex.attach(fixture.runtime, session, after_event_sequence: 0)
    predecessor = owner(fixture, session)
    assert {:accepted, "compact"} = Loopex.command(attachment, command())
    assert_receive {:holding, _worker}, 5_000
    assert_receive {:activity_admission_held, ^control, relay, item}, 5_000
    relay_monitor = Process.monitor(relay)
    refute_receive {:loopex_progress, _}, 0
    kill_owner(predecessor)
    assert_receive {:DOWN, ^relay_monitor, :process, ^relay, :killed}, 5_000
    send(control, :release_activity_admission)
    assert :ok = :sys.remove(control, hook)

    {:ok, {:prepared, activation}} =
      Loopex.prepare_resume_session(fixture.runtime, session, "projection-loss")

    assert {:ok, ^session} = Loopex.activate_resume(activation)
    done = await_state(fixture, session, &is_nil(&1.pending_compact))
    assert done.commands["compact"].result["cleanup"] == "unknown"
    refute_receive {:loopex_progress, _}, 0
    refute Enum.any?(Fixture.events(fixture, session), &(&1.kind == item.kind))
  end

  for phase <- [:before_send, :after_send] do
    @phase phase
    test "lost actual Control reply #{@phase} produces no activity or successor redispatch" do
      {fixture, session, _activation} = history(:compact, [held_summary()])
      control = control(fixture)
      observer = self()

      hook = fn
        :armed, {:in, {:"$gen_call", _from, {:provider_dispatch, binding, authority}}}, _extra ->
          send(observer, {:permit_admission_held, self(), binding, authority})
          receive do: (:release_permit_admission -> :held)

        state, _event, _extra ->
          state
      end

      assert :ok = :sys.install(control, {hook, :armed})
      :erlang.trace(control, true, [:send])

      on_exit(fn ->
        if Process.alive?(control) do
          send(control, :release_permit_admission)

          try do
            :sys.remove(control, hook)
            :erlang.trace(control, false, [:all])
          catch
            :exit, _reason -> :ok
          end
        end
      end)

      {:ok, attachment} = Loopex.attach(fixture.runtime, session, after_event_sequence: 0)
      predecessor = owner(fixture, session)
      assert {:accepted, "compact"} = Loopex.command(attachment, command())
      assert_receive {:permit_admission_held, ^control, binding, authority}, 5_000
      true = :erlang.suspend_process(predecessor)
      provider_worker = authority.worker

      if @phase == :before_send do
        monitor = Process.monitor(provider_worker)
        Process.exit(provider_worker, :kill)
        assert_receive {:DOWN, ^monitor, :process, ^provider_worker, :killed}, 5_000
      end

      send(control, :release_permit_admission)
      assert :ok = :sys.remove(control, hook)

      case @phase do
        :before_send ->
          assert_receive {:trace, ^control, :send,
                          {_reply, {:error, :provider_worker_unavailable}}, ^predecessor},
                         5_000

          assert AgentLoopTestModel.dispatched(fixture.model) == []

        :after_send ->
          assert_receive {:trace, ^control, :send,
                          {:loopex_provider_permit, _reference, ^binding}, ^provider_worker},
                         5_000

          assert_receive {:holding, _callback}, 5_000
          assert length(AgentLoopTestModel.dispatched(fixture.model)) == 1
      end

      # The original owner is frozen while its actual reply queues. Killing it
      # prevents adoption of either the negative or positive reply; no fake
      # callback or replacement Control route produces this uncertainty.
      refute_receive {:loopex_progress, _}, 0
      kill_owner(predecessor)

      {:ok, {:prepared, activation}} =
        Loopex.prepare_resume_session(fixture.runtime, session, "lost-permit-#{@phase}")

      assert :sys.get_state(owner(fixture, session)).compaction_relay == nil
      assert {:ok, ^session} = Loopex.activate_resume(activation)
      done = await_state(fixture, session, &is_nil(&1.pending_compact))
      assert done.commands["compact"].result["cleanup"] == "unknown"
      assert length(records(fixture, session, "maintenance_attempt_opened_v1")) == 1

      assert length(AgentLoopTestModel.dispatched(fixture.model)) ==
               if(@phase == :after_send, do: 1, else: 0)

      refute_receive {:loopex_progress, _}, 0
    end
  end

  test "delayed non-nil activity arrives after durable completion without reopening or reattachment replay" do
    {fixture, session, _activation} = history(:compact, [held_summary()])
    control = control(fixture)
    observer = self()

    hook = fn
      :armed,
      {:in,
       {:"$gen_call", _from,
        {:project_progress, _session, _owner, relay,
         %{kind: "context.compaction_progress"} = item}}},
      _extra ->
        true = :erlang.suspend_process(relay)
        send(observer, {:activity_relay_suspended, relay, item})
        :held

      state, _event, _extra ->
        state
    end

    assert :ok = :sys.install(control, {hook, :armed})
    {:ok, attachment} = Loopex.attach(fixture.runtime, session, after_event_sequence: 0)
    assert {:accepted, "compact"} = Loopex.command(attachment, command())
    assert_receive {:holding, worker}, 5_000
    assert_receive {:activity_relay_suspended, relay, item}, 5_000
    assert :ok = :sys.remove(control, hook)

    on_exit(fn ->
      if Process.alive?(control) and Process.alive?(relay) do
        try do
          :sys.replace_state(control, fn state ->
            try do
              :erlang.resume_process(relay)
            catch
              :error, _reason -> :ok
            end

            state
          end)
        catch
          :exit, _reason -> :ok
        end
      end
    end)

    refute_receive {:loopex_progress, _}, 0
    send(worker, :release)
    done = await_state(fixture, session, &is_nil(&1.pending_compact))
    assert done.commands["compact"].result["disposition"] == "checkpointed"
    assert item.base_event_sequence < done.event_sequence
    {:ok, _reattached} = Loopex.attach(fixture.runtime, session, after_event_sequence: 0)
    refute_receive {:loopex_progress, _}, 0
    # The actual Control debug hook owns this suspension. Resume in that same
    # process; a test-process resume does not release Control's suspension.
    :sys.replace_state(control, fn state ->
      true = :erlang.resume_process(relay)
      state
    end)

    assert_receive {:loopex_progress, ^item}, 5_000
    assert recover(fixture, session).commands["compact"].result == done.commands["compact"].result
    assert done.commands["compact"].result == Loopex.command(attachment, command())
    assert length(AgentLoopTestModel.dispatched(fixture.model)) == 1
    refute_receive {:loopex_progress, _}, 0
  end

  defp summary do
    %{
      text:
        ~s({"summary":"retain this fact","carry_forward":{"files_read":[],"files_changed":[]}}),
      reply_overrides: %{completion: "natural", continuation: nil},
      usage: %{input_tokens: 37, output_tokens: 19}
    }
  end

  defp held_summary, do: Map.merge(summary(), %{hold: self(), deltas: ["private summary delta"]})

  defp command do
    %{
      type: :compact,
      command_id: "compact",
      bounds: %{"max_attempts" => 4, "deadline_ms" => 60_000, "token_budget" => 32_768}
    }
  end

  # The old idle runtime exits before pure current proposals are committed.
  # The resumed coordinator performs real preparation, Store commits, permits,
  # model calls and cleanup; the fixture does not simulate those producers.
  defp history(kind, script, options \\ []) do
    prior = Fixture.start(script: [], tools: [])
    on_exit(fn -> Fixture.stop(prior) end)
    configuration = Genesis.configuration()

    {:ok, session} =
      Loopex.create_session(prior.runtime, %{},
        command_id: "create",
        genesis: Genesis.genesis([], configuration)
      )

    assert :ok = Loopex.stop(prior.runtime)
    current = recover(prior, session)

    contents =
      Keyword.get(options, :contents, [
        String.duplicate("old ", if(kind == :run, do: 7_500, else: 2_000))
      ])

    current =
      Enum.reduce(Enum.with_index(contents), current, fn {content, index}, state ->
        {:ok, admitted} =
          SessionState.propose(
            state,
            %{type: :prompt, command_id: "old-#{index}", content: content},
            defaults()
          )

        state = retain(prior, state, admitted)

        {:ok, ended} =
          SessionState.propose_run_terminal(state, state.active_run_id, "failed", %{
            reason: "model_call_failed"
          })

        retain(prior, state, ended)
      end)

    selection = %{
      "model" => configuration["model"],
      "reasoning" => "none",
      "model_capabilities" => %{
        configuration["model_capabilities"]
        | "reasoning_levels" => ["none", "default"]
      },
      "provider_mapping" => %{configuration["provider_mapping"] | "thinking_disabled" => true}
    }

    instructions =
      Keyword.get(options, :instructions, %{"version" => "summary.v1", "body" => "Keep facts"})

    if kind == :run do
      {:ok, admitted} =
        SessionState.propose(
          current,
          %{type: :prompt, command_id: "active", content: "protected"},
          defaults()
        )

      current = retain(prior, current, admitted)
      {:ok, capture} = Loopex.Runtime.MaintenanceConfiguration.capture_instructions(instructions)

      {:ok, episode} =
        SessionState.propose_maintenance_episode(
          current,
          current.active_run_id,
          selection,
          capture,
          System.system_time(:millisecond)
        )

      retain(prior, current, episode)
    end

    fixture =
      Fixture.start(
        script: script,
        tools: [],
        store: prior.store,
        maintenance_model: selection,
        maintenance_instructions: instructions,
        progress_to: Keyword.get(options, :progress_to, self())
      )

    on_exit(fn -> Fixture.stop(fixture) end)

    {:ok, {:prepared, activation}} =
      Loopex.prepare_resume_session(fixture.runtime, session, "prepare")

    {fixture, session, activation}
  end

  defp defaults,
    do: %{
      max_turns: 8,
      deadline_ms: 60_000,
      token_budget: 100_000,
      context_token_budget: 8_192,
      admitted_at: System.system_time(:millisecond)
    }

  defp recover(fixture, session) do
    retained = M1RuntimeTestStore.inspect_state(fixture.store).sessions[session]
    {:ok, state} = SessionState.recover(session, retained.records, retained.events)
    state
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

    assert {:committed, _, receipt} = Store.transact(store, transaction)
    {:ok, next} = SessionState.commit_proposal(proposal, receipt)
    next
  end

  defp owner(fixture, session), do: :sys.get_state(control(fixture)).sessions[session].coordinator

  defp control(fixture) do
    {:ok, %{control: control}} = Loopex.Runtime.children(fixture.runtime)
    control
  end

  defp kill_owner(coordinator) do
    monitor = Process.monitor(coordinator)
    Process.exit(coordinator, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^coordinator, :killed}, 5_000
  end

  defp await_state(fixture, session, predicate),
    do: await_state(fixture, session, predicate, System.monotonic_time(:millisecond) + 5_000)

  defp await_state(fixture, session, predicate, cutoff) do
    state = recover(fixture, session)

    if predicate.(state) do
      state
    else
      assert System.monotonic_time(:millisecond) < cutoff
      Process.sleep(1)
      await_state(fixture, session, predicate, cutoff)
    end
  end

  defp assert_item(item, session, episode, owner) do
    assert {:ok, ^item} = CompactionProgress.project(item)
    assert item.episode_id == episode["episode_id"]
    assert item.owner == owner

    assert item.stream_domain_id ==
             StreamDomain.derive(
               :compaction,
               session,
               episode["operation_id"],
               episode["model_attempt"]
             )

    assert item.progress_sequence == 0
  end

  defp assert_positive_permit(control, worker, episode) do
    assert_receive {:trace, ^control, :send, {:loopex_provider_permit, _, binding},
                    permit_worker},
                   5_000

    assert is_pid(permit_worker)
    refute permit_worker == worker
    assert binding["episode_id"] == episode["episode_id"]
    assert binding["operation_id"] == episode["operation_id"]
    assert binding["attempt"] == episode["model_attempt"]
    assert binding["staged_request_digest"] == episode["request"].staged_request_digest
  end

  defp records(fixture, session, kind),
    do: for(%{payload: %{kind: ^kind} = row} <- Fixture.records(fixture, session), do: row)

  defp drain_progress do
    receive do
      {:loopex_progress, item} -> [item | drain_progress()]
    after
      0 -> []
    end
  end
end
