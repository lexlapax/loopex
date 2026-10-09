Code.require_file("../../loopex/test/support/agent_loop_adapters.exs", __DIR__)

defmodule LoopexComposition.MaintenanceStoreRestartTest do
  use ExUnit.Case, async: false

  alias Loopex.AgentLoopTestExecutor, as: Executor
  alias Loopex.AgentLoopTestModel, as: Model
  alias Loopex.ConfiguredGenesisFixture, as: Genesis
  alias Loopex.Runtime.SessionState
  alias Loopex.Store.Local

  @fact "The build target is release_candidate."
  @summary ~s({"summary":"The build target is release_candidate.","carry_forward":{"files_read":[],"files_changed":[]}})
  @compact %{
    type: :compact,
    command_id: "compact",
    bounds: %{"max_attempts" => 4, "deadline_ms" => 60_000, "token_budget" => 32_768}
  }

  for mode <- [:standalone, :automatic] do
    @mode mode
    test "#{mode} compaction survives a physical Local Store reopen without summary redispatch" do
      root =
        Path.join(
          System.tmp_dir!(),
          "loopex-m7-maintenance-#{Base.encode16(:crypto.strong_rand_bytes(12))}"
        )

      File.mkdir_p!(root)
      on_exit(fn -> File.rm_rf!(root) end)
      path = Path.join(root, "store.log")

      configuration =
        Genesis.configuration()
        |> Map.put("context_token_budget", if(@mode == :automatic, do: 3_000, else: 8_192))
        |> Map.put("system_class_tokens", 1_000)
        |> Map.update!("budget_origins", &Map.put(&1, "context_token_budget", "explicit"))

      script =
        if @mode == :standalone,
          do: [ordinary("first finished"), summary()],
          else: [ordinary("first finished"), summary(), ordinary("second finished")]

      first = start(path, configuration, script)

      assert {:ok, session} =
               Loopex.create_session(first.runtime, %{},
                 command_id: "create",
                 genesis: Genesis.genesis([], configuration)
               )

      assert {:ok, attachment} = Loopex.attach(first.runtime, session, after_event_sequence: 0)
      initial = @fact <> String.duplicate(" old history", 700)
      assert {:accepted, "first"} = prompt(attachment, "first", initial)
      assert await_event(attachment, "run.finished")["outcome"] == "completed"
      {initial_records, initial_events, initial_state} = retained(first.store, session)
      assert initial_state.active_checkpoint == nil

      if @mode == :standalone do
        assert {:accepted, "compact"} = Loopex.command(attachment, @compact)
        result = await_event(attachment, "context.compaction_finished")["result"]
        assert result["disposition"] == "checkpointed"
        assert result["usage"]["total_tokens"] == 56
      else
        assert {:accepted, "second"} =
                 prompt(attachment, "second", String.duplicate(" current input", 500))

        ending = await_event(attachment, "run.finished")
        assert ending["outcome"] == "completed", inspect(ending)
      end

      {records, events, before} = retained(first.store, session)
      assert Enum.take(records, length(initial_records)) == initial_records
      assert Enum.take(events, length(initial_events)) == initial_events

      assert before.conversation[hd(before.run_order)] ==
               initial_state.conversation[hd(before.run_order)]

      assert map_size(before.checkpoints) == 1
      assert before.active_run_id == nil
      assert before.active_maintenance == nil
      assert before.pending_compact == nil
      [episode] = Map.values(before.maintenance_episodes)
      assert episode["usage"]["attempts"] == 1
      assert episode["usage"]["reported_tokens"] == 56
      assert episode["usage"]["estimated_tokens"] == 0
      assert episode["usage"]["total_tokens"] == 56
      checkpoint = before.checkpoints[before.active_checkpoint]
      assert checkpoint["summary"]["summary"] == @fact
      compacted = Enum.filter(events, &(&1.kind == "context.compacted"))
      assert length(compacted) == 1

      assert hd(compacted)["owner"]["kind"] ==
               if(@mode == :standalone, do: "compact", else: "run")

      requests = Model.dispatched(first.model)
      maintenance = Enum.at(requests, 1)
      assert maintenance.tools == []
      assert maintenance.continuation == nil
      assert maintenance.sampling["max_tokens"] == 1_024
      assert Enum.any?(maintenance.messages, &String.contains?(&1["content"], initial))

      if @mode == :automatic do
        second_run = List.last(before.run_order)
        assert before.charged[second_run].tokens == 58
        assert_summary_projection(List.last(requests), initial, checkpoint)
        assert maintenance.deadline == List.last(requests).deadline
      else
        assert before.charged == initial_state.charged
      end

      assert Executor.jobs(first.executor) == []
      bytes = File.read!(path)
      stop(first)
      refute Process.alive?(first.runtime.supervisor)
      refute Process.alive?(first.store)
      refute Process.alive?(first.model)
      refute Process.alive?(first.executor)

      # Concept: the successor uses only the persisted log and the current host adapters.
      # Technical depth: every Store, runtime and fixture actor is new. No reducer
      # state or summary result is passed to the successor, whose script contains
      # only the next ordinary reply. Raw log bytes must survive reopening exactly.
      second = start(path, configuration, [ordinary("resumed finished")])
      assert File.read!(path) == bytes
      {reopened_records, reopened_events, reopened} = retained(second.store, session)
      assert reopened_records == records
      assert reopened_events == events
      assert reopened == before

      assert {:ok, ^session} =
               Loopex.resume_session(second.runtime, session, command_id: "resume")

      assert {:ok, resumed} =
               Loopex.attach(second.runtime, session, after_event_sequence: before.event_sequence)

      {_, _, recovered} = retained(second.store, session)
      assert recovered.configuration == before.configuration
      assert recovered.checkpoints == before.checkpoints
      assert recovered.compacted_sources == before.compacted_sources
      assert recovered.conversation == before.conversation
      assert recovered.maintenance_episodes == before.maintenance_episodes
      assert recovered.charged == before.charged
      assert recovered.deadlines == before.deadlines
      assert recovered.bounds == before.bounds
      assert recovered.run_configurations == before.run_configurations
      assert Model.dispatched(second.model) == []

      if @mode == :standalone do
        assert Loopex.command(resumed, @compact) == before.commands["compact"].result
        assert Model.dispatched(second.model) == []
      end

      assert {:accepted, "after-reopen"} = prompt(resumed, "after-reopen", "Which build target?")
      assert await_event(resumed, "run.finished")["outcome"] == "completed"
      assert [request] = Model.dispatched(second.model)
      assert_summary_projection(request, initial, checkpoint)

      assert List.last(request.messages) == %{
               "role" => "user",
               "content" => "Which build target?"
             }

      {final_records, final_events, final} = retained(second.store, session)
      assert Enum.take(final_records, length(records)) == records
      assert Enum.take(final_events, length(events)) == events
      assert final.checkpoints == before.checkpoints
      assert final.maintenance_episodes == before.maintenance_episodes
      assert Map.take(final.charged, before.run_order) == before.charged
      assert final.charged[List.last(final.run_order)].tokens == 2
      assert Enum.filter(final_events, &(&1.kind == "context.compacted")) == compacted
      assert Executor.jobs(second.executor) == []
      stop(second)
      refute Process.alive?(second.runtime.supervisor)
      refute Process.alive?(second.store)
      refute Process.alive?(second.model)
      refute Process.alive?(second.executor)
    end
  end

  for mode <- [:standalone, :automatic],
      {boundary, count, expected_kind} <- [
        {:preparation, 2, "standalone_maintenance_episode_admitted_v1"},
        {:staging, 3, "maintenance_request_committed_v1"},
        {:settlement, 1, "maintenance_attempt_settled_v3"},
        {:checkpoint, 2, "standalone_compaction_checkpoint_committed_v1"},
        {:publication, 3, "maintenance_episode_terminal_v1"}
      ],
      phase <- [
        :before_linearization,
        :after_linearization_before_result,
        :recovery_representation
      ] do
    @boundary boundary
    @commit_count count
    @crash_mode mode
    @late boundary in [:settlement, :checkpoint, :publication]
    @expected_kind if(mode == :automatic,
                     do:
                       case boundary do
                         :preparation -> "maintenance_episode_admitted_v1"
                         :checkpoint -> "compaction_checkpoint_committed_v1"
                         _ -> expected_kind
                       end,
                     else: expected_kind
                   )
    previous_kind =
      case boundary do
        :preparation ->
          if(mode == :automatic, do: "prompt_admitted_v3", else: "compact_command_admitted_v1")

        :staging ->
          if(mode == :automatic,
            do: "maintenance_episode_admitted_v1",
            else: "standalone_maintenance_episode_admitted_v1"
          )

        :settlement ->
          "maintenance_attempt_opened_v1"

        :checkpoint ->
          "maintenance_attempt_settled_v3"

        :publication ->
          if(mode == :automatic,
            do: "compaction_checkpoint_committed_v1",
            else: "standalone_compaction_checkpoint_committed_v1"
          )
      end

    @previous_kind previous_kind
    @phase phase
    test "#{mode} #{@boundary} recovers a physical Store crash at #{@phase}" do
      root =
        Path.join(
          System.tmp_dir!(),
          "loopex-m7-maintenance-cut-#{Base.encode16(:crypto.strong_rand_bytes(12))}"
        )

      File.mkdir_p!(root)
      on_exit(fn -> File.rm_rf!(root) end)
      path = Path.join(root, "store.log")
      caller = self()
      probe = spawn_link(fn -> fault_probe(caller, nil, 0) end)
      on_exit(fn -> stop_probe(probe) end)

      configuration =
        Genesis.configuration()
        |> Map.put("context_token_budget", if(@crash_mode == :automatic, do: 3_000, else: 8_192))
        |> Map.put("system_class_tokens", 1_000)
        |> Map.update!("budget_origins", &Map.put(&1, "context_token_budget", "explicit"))

      reply = if @late, do: Map.put(summary(), :hold, self()), else: summary()
      first = start(path, configuration, [ordinary("first finished"), reply], fault_probe: probe)
      Process.unlink(first.store)
      store_monitor = Process.monitor(first.store)

      assert {:ok, session} =
               Loopex.create_session(first.runtime, %{},
                 command_id: "create",
                 genesis: Genesis.genesis([], configuration)
               )

      assert {:ok, attachment} = Loopex.attach(first.runtime, session, after_event_sequence: 0)
      initial = @fact <> String.duplicate(" old history", 700)
      assert {:accepted, "first"} = prompt(attachment, "first", initial)
      assert await_event(attachment, "run.finished")["outcome"] == "completed"
      {initial_records, initial_events, initial_state} = retained(first.store, session)

      unless @late, do: arm_probe(probe, @commit_count, @phase)

      if @crash_mode == :standalone do
        assert {:accepted, "compact"} = Loopex.command(attachment, @compact)
      else
        assert {:accepted, "second"} =
                 Loopex.command(attachment, %{
                   type: :prompt,
                   command_id: "second",
                   content: String.duplicate(" current input", 500),
                   bounds: %{max_turns: 8, token_budget: 10_000, deadline_ms: 60_000}
                 })
      end

      if @late do
        assert_receive {:holding, callback}, 5_000
        callback_monitor = Process.monitor(callback)
        arm_probe(probe, @commit_count, @phase)
        send(callback, :release)
        assert_receive {:DOWN, ^callback_monitor, :process, ^callback, :normal}, 5_000
      end

      assert_receive {:held_store_point, store_pid, reference, @phase}, 5_000
      assert store_pid == first.store
      assert length(Model.dispatched(first.model)) == if(@late, do: 2, else: 1)

      # Concept: the physical Store dies at its own declared transaction cut.
      # Technical depth: the probe counts serialized session-journal transactions
      # from a captured command or held provider callback. It changes no frame,
      # outcome, receipt or clock. The reopened journal must independently prove
      # the selected record boundary and its all-or-nothing public outbox.
      send(store_pid, {:loopex_store_fault_action, reference, :kill})
      assert_receive {:DOWN, ^store_monitor, :process, ^store_pid, :killed}, 5_000
      stop(first)
      stop_probe(probe)
      refute Process.alive?(first.runtime.supervisor)
      refute Process.alive?(first.model)
      refute Process.alive?(first.executor)

      script =
        if @crash_mode == :standalone,
          do: [summary()],
          else:
            if(@late,
              do: [ordinary("resumed finished")],
              else: [summary(), ordinary("resumed finished")]
            )

      second = start(path, configuration, script, recover_stale_writer: true)
      {crash_records, crash_events, crash_state} = retained(second.store, session)
      assert Enum.take(crash_records, length(initial_records)) == initial_records
      assert Enum.take(crash_events, length(initial_events)) == initial_events

      assert Map.take(crash_state.conversation, initial_state.run_order) ==
               initial_state.conversation

      assert Map.take(crash_state.charged, initial_state.run_order) == initial_state.charged
      assert is_nil(crash_state.active_run_id) == (@crash_mode == :standalone)
      selected = Enum.filter(crash_records, &(&1.payload.kind == @expected_kind))

      if @phase == :before_linearization do
        assert selected == []
        assert List.last(crash_records).payload.kind == @previous_kind
      else
        assert length(selected) == 1

        assert @expected_kind in Enum.map(Enum.take(crash_records, -2), & &1.payload.kind)
      end

      if @boundary == :publication and @crash_mode == :standalone do
        assert Enum.count(crash_events, &(&1.kind == "context.compaction_finished")) ==
                 if(@phase == :before_linearization, do: 0, else: 1)
      end

      if @boundary == :checkpoint do
        assert map_size(crash_state.checkpoints) ==
                 if(@phase == :before_linearization, do: 0, else: 1)
      end

      assert {:ok, ^session} =
               Loopex.resume_session(second.runtime, session, command_id: "resume-cut")

      assert {:ok, resumed} =
               Loopex.attach(second.runtime, session,
                 after_event_sequence: initial_state.event_sequence
               )

      ending =
        await_event(
          resumed,
          if(@crash_mode == :standalone, do: "context.compaction_finished", else: "run.finished")
        )

      {records, events, state} = retained(second.store, session)
      [episode] = Map.values(state.maintenance_episodes)
      result = if(@crash_mode == :standalone, do: ending["result"], else: episode["result"])

      token_budget =
        if(@crash_mode == :standalone, do: @compact.bounds["token_budget"], else: 10_000)

      ambiguous? =
        (@boundary == :staging and @phase != :before_linearization) or
          (@boundary == :settlement and @phase == :before_linearization)

      if ambiguous? do
        assert result["disposition"] == "failed"
        assert result["usage"]["attempts"] == 1
        assert result["usage"]["reported_tokens"] == 0
        assert result["usage"]["estimated_tokens"] == token_budget
        assert result["usage"]["total_tokens"] == token_budget
        assert state.checkpoints == %{}
        assert Model.dispatched(second.model) == []
      else
        assert result["disposition"] == "checkpointed", inspect(result)
        assert result["checkpoint_id"] == state.active_checkpoint
        assert result["usage"]["attempts"] == 1
        assert result["usage"]["reported_tokens"] == 56
        assert result["usage"]["estimated_tokens"] == 0
        assert result["usage"]["total_tokens"] == 56
        assert map_size(state.checkpoints) == 1

        assert length(Model.dispatched(second.model)) ==
                 if(@late, do: 0, else: 1) +
                   if(@crash_mode == :automatic, do: 1, else: 0)

        if @crash_mode == :automatic do
          assert ending["outcome"] == "completed"

          assert_summary_projection(
            List.last(Model.dispatched(second.model)),
            initial,
            state.checkpoints[state.active_checkpoint]
          )
        end
      end

      assert result["cleanup"] == if(ambiguous?, do: "unknown", else: "confirmed")

      assert result["failure"] ==
               if(ambiguous?,
                 do: %{"category" => "model_call_failed", "retryable" => false},
                 else: nil
               )

      assert state.configuration == initial_state.configuration
      assert Map.take(state.conversation, initial_state.run_order) == initial_state.conversation
      assert Map.take(state.charged, initial_state.run_order) == initial_state.charged
      assert Map.take(state.deadlines, initial_state.run_order) == initial_state.deadlines

      if @crash_mode == :automatic do
        current_run = List.last(state.run_order)
        assert ending["run_id"] == current_run
        assert state.charged[current_run].tokens == if(ambiguous?, do: token_budget, else: 58)
      end

      assert state.active_maintenance == nil
      assert state.pending_compact == nil
      assert Enum.take(records, length(crash_records)) == crash_records
      assert Enum.take(events, length(crash_events)) == crash_events

      for kind <- [
            "maintenance_request_committed_v1",
            "maintenance_attempt_opened_v1",
            "maintenance_attempt_settled_v3",
            "maintenance_episode_terminal_v1"
          ] do
        assert Enum.count(records, &(&1.payload.kind == kind)) == 1
      end

      if @crash_mode == :standalone do
        assert Enum.count(records, &(&1.payload.kind == "compact_command_completed_v1")) == 1
        assert Enum.count(events, &(&1.kind == "context.compaction_finished")) == 1
        assert Loopex.command(resumed, @compact) == result
      else
        refute Enum.any?(records, &(&1.payload.kind == "compact_command_completed_v1"))

        assert Enum.count(
                 events,
                 &(&1.kind == "run.finished" and &1["run_id"] == ending["run_id"])
               ) == 1
      end

      assert Executor.jobs(second.executor) == []
      stop(second)
      refute Process.alive?(second.runtime.supervisor)
      refute Process.alive?(second.store)
      refute Process.alive?(second.model)
      refute Process.alive?(second.executor)
    end
  end

  defp start(path, configuration, script, store_options \\ []) do
    {:ok, store_pid} = Local.start_link(Keyword.put(store_options, :path, path))
    {:ok, store} = Loopex.Store.new(Local, store_pid)
    model = Model.start(script)
    executor = Executor.start()

    {:ok, runtime} =
      Loopex.start_link(
        runtime_id: "m7-maintenance-restart",
        store: store,
        context_token_budget: 8_192,
        model: %{module: Model, model: "scripted:v1", options: [script: model, max_tokens: 1_024]},
        maintenance_model: %{
          "model" => configuration["model"],
          "reasoning" => "none",
          "model_capabilities" => %{
            configuration["model_capabilities"]
            | "reasoning_levels" => ["none"]
          },
          "provider_mapping" => %{configuration["provider_mapping"] | "thinking_disabled" => true}
        },
        maintenance_instructions: %{"version" => "summary.v1", "body" => "Keep the facts"},
        executor: %{
          module: Executor,
          reference: executor,
          identity: "maintenance-restart-executor",
          epoch: 1,
          fencing_token: 1,
          workspace_ref: "workspace",
          workspace_lease: "lease"
        },
        tools: [],
        active_tools: [],
        policy: Loopex.AgentLoopTestPolicy,
        policy_identity: %{"id" => "maintenance-restart-policy", "revision" => "1"},
        grant_decision: {:host_policy, :allow}
      )

    fixture = %{runtime: runtime, store: store_pid, model: model, executor: executor}
    on_exit(fn -> stop(fixture) end)

    assert :ok =
             LoopexComposition.StartupGate.publication(
               LoopexComposition.StartupGate.await(runtime)
             )

    fixture
  end

  defp stop(fixture) do
    if Process.alive?(fixture.runtime.supervisor), do: Loopex.stop(fixture.runtime)

    for pid <- [fixture.store, fixture.model, fixture.executor] do
      if Process.alive?(pid), do: GenServer.stop(pid)
    end
  end

  defp prompt(attachment, id, content),
    do: Loopex.command(attachment, %{type: :prompt, command_id: id, content: content})

  defp ordinary(text),
    do: %{text: text, reply_overrides: %{completion: "natural", continuation: nil}}

  defp summary,
    do: Map.put(ordinary(@summary), :usage, %{input_tokens: 37, output_tokens: 19})

  defp assert_summary_projection(request, original, checkpoint) do
    assert Enum.at(request.messages, 1)["role"] == "user"

    assert {:ok, provenance} =
             LoopexProtocol.Frame.decode(Enum.at(request.messages, 1)["content"], 16_384)

    assert provenance ==
             Map.merge(checkpoint["summary"], %{
               "kind" => "compaction_summary",
               "checkpoint_id" => checkpoint["checkpoint_id"]
             })

    refute Enum.any?(request.messages, &String.contains?(&1["content"], original))
  end

  defp retained(store, session) do
    assert {:ok, records} = Local.load_records(store, session, 0, 1_000)
    assert {:ok, events} = Local.load_events(store, session, 0, 1_000)
    assert {:ok, state} = SessionState.recover(session, records, events)
    {records, events, state}
  end

  defp await_event(attachment, kind, cutoff \\ nil) do
    cutoff = cutoff || System.monotonic_time(:millisecond) + 5_000

    case Loopex.next_event(attachment) do
      {:ok, %{kind: ^kind} = event} ->
        event

      _ ->
        assert System.monotonic_time(:millisecond) < cutoff, "missing #{kind}"
        Process.sleep(10)
        await_event(attachment, kind, cutoff)
    end
  end

  defp arm_probe(probe, count, phase) do
    reference = make_ref()
    send(probe, {:arm, self(), reference, count, phase})
    assert_receive {:armed, ^reference}, 5_000
  end

  defp fault_probe(caller, target, count) do
    receive do
      {:arm, sender, reference, ordinal, phase} ->
        send(sender, {:armed, reference})
        fault_probe(caller, {ordinal, phase}, 0)

      {:loopex_store_fault_point, store, reference, {transition, phase}} ->
        count =
          if transition == :session_journal_commit and phase == :before_linearization,
            do: count + 1,
            else: count

        cond do
          transition == :session_journal_commit and target == {count, phase} ->
            send(caller, {:held_store_point, store, reference, phase})
            fault_probe(caller, nil, count)

          transition == :session_journal_commit and
            target == {count, :recovery_representation} and
              phase == :after_linearization_before_result ->
            send(store, {:loopex_store_fault_action, reference, :return_unknown})
            fault_probe(caller, target, count)

          true ->
            send(store, {:loopex_store_fault_action, reference, :continue})
            fault_probe(caller, target, count)
        end

      :stop ->
        :ok
    end
  end

  defp stop_probe(probe) do
    if Process.alive?(probe) do
      monitor = Process.monitor(probe)
      send(probe, :stop)
      assert_receive {:DOWN, ^monitor, :process, ^probe, :normal}, 5_000
    end
  end
end
