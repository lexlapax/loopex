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

  defp start(path, configuration, script) do
    {:ok, store_pid} = Local.start_link(path: path)
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
end
