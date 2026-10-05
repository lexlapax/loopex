Code.require_file("support/m1_runtime_helper.exs", __DIR__)
Code.require_file("support/agent_loop_helper.exs", __DIR__)

defmodule Loopex.ConfigurationCheckpointAdmissionTest do
  use ExUnit.Case, async: false

  alias Loopex.AgentLoopFixture, as: Fixture
  alias Loopex.AgentLoopTestModel, as: Script
  alias Loopex.ConfiguredGenesisFixture, as: Genesis
  alias Loopex.Runtime.{CompactionSummary, ProviderLifetime, SessionConfiguration, SessionState}
  alias Loopex.M1RuntimeTestStore, as: TestStore

  defmodule Preparing do
    @moduledoc false
    @behaviour Loopex.Model

    @impl true
    def complete(request, options, progress) do
      observer = Keyword.fetch!(options, :observer)
      controller = Keyword.fetch!(options, :controller)

      if hd(request.messages)["content"] == "summary.v1: Keep the facts" and
           Agent.get(controller, & &1.cleanup) do
        {:managed, starter} = ProviderLifetime.starter()
        stop_reference = make_ref()

        {:ok, child} =
          ProviderLifetime.start_child(starter, fn ->
            receive do
              {:loopex_provider_resource_stop, ^stop_reference, stop, guard, _, _} ->
                send(observer, {:cleanup_pending, self()})

                receive do
                  :release -> send(guard, {:loopex_provider_resource_stopped, stop, self()})
                end
            end
          end)

        {:managed, _guard, 5_000} = ProviderLifetime.register(child, stop_reference)
        send(observer, {:registered_resource, child})
      end

      Script.complete(request, Keyword.take(options, [:script, :max_tokens]), progress)
    end

    @impl true
    def prepare_configuration(current, authored, definitions, _context, options) do
      compatible =
        Agent.get_and_update(Keyword.fetch!(options, :controller), fn state ->
          {state.compatible, %{state | calls: state.calls + 1}}
        end)

      send(Keyword.fetch!(options, :observer), {:configuration_prepared, self()})
      canonical = Map.get(authored, "model", current["model"])

      SessionConfiguration.update(
        current,
        authored,
        Map.put(current["model_capabilities"], "model", canonical),
        Map.put(current["provider_mapping"], "canonical_terminal_tool_history", compatible),
        definitions
      )
    end
  end

  for coverage <- [:covered, :uncovered] do
    @coverage coverage
    test "#{coverage} terminal tool history determines configure capability after actual checkpoints" do
      later =
        if @coverage == :uncovered,
          do: [tool_turn("later"), %{error: :provider_failed}, summary_turn()],
          else: []

      f = fixture([tool_turn("old"), %{error: :provider_failed}, summary_turn()] ++ later,
        tools: [Fixture.tool_definition()], compatible: false)

      prompt(f, "old", String.duplicate("o", 12_000))
      old = recover(f)
      assert {:ok, true} = Loopex.Conversation.terminal_tool_history(
        SessionState.lineage_elements(old, :session), old.run_order)
      assert Enum.any?(SessionState.lineage_elements(old, :session), &(&1.kind == :tool_result))
      before = configure("before-coverage")
      assert {:error, :invalid_session_configuration} = Loopex.command(f.attachment, before)
      assert {:error, :invalid_session_configuration} = Loopex.command(f.attachment, before)
      assert calls(f) == 1
      assert recover(f).configuration == f.initial

      compact(f, "first-compact")
      covered = recover(f)
      assert covered.conversation == old.conversation
      assert MapSet.size(covered.compacted_sources) > 0
      assert {:error, :invalid_session_configuration} = Loopex.command(f.attachment, before)
      assert calls(f) == 1

      if @coverage == :uncovered do
        prompt(f, "later", "uncovered later tool turn")
        unchanged = recover(f)
        bad = configure("uncovered")
        assert {:error, :invalid_session_configuration} = Loopex.command(f.attachment, bad)
        assert {:error, :invalid_session_configuration} = Loopex.command(f.attachment, bad)
        assert calls(f) == 2
        assert recover(f).configuration == unchanged.configuration
        assert recover(f).active_checkpoint == covered.active_checkpoint
        compact(f, "second-compact")
      end

      committed = recover(f)
      assert {:ok, entries, nil} = SessionState.projected_lineage(committed, :session, 0)
      {:ok, summary} = CompactionSummary.project(committed.active_checkpoint,
        committed.checkpoints[committed.active_checkpoint]["summary"])
      assert entries == [summary]
      assert {:accepted, "after-coverage"} = Loopex.command(f.attachment, configure("after-coverage"))
      assert recover(f).configuration["provider_mapping"]["canonical_terminal_tool_history"] == false
      assert recover(f).configuration["configuration_version"] == 2
      assert_configured_request(f, "after-coverage-prompt", entries)
      assert_replay(f)
    end
  end

  for limiting <- [:tail, :summary] do
    @limiting limiting
    test "configure measures the exact committed #{@limiting} and preserves its refusal projection" do
      summary = if @limiting == :summary, do: String.duplicate("s", 3_000), else: "retained fact"
      tail = if @limiting == :tail, do: String.duplicate("t", 4_000), else: "surviving tail"
      f = fixture([normal("old finished"), summary_turn(summary), normal("tail finished")])
      prompt(f, "old", String.duplicate("o", 12_000))
      compact(f, "compact")
      prompt(f, "tail", tail)
      before = recover(f)
      {:ok, summary_entry} = CompactionSummary.project(before.active_checkpoint,
        before.checkpoints[before.active_checkpoint]["summary"])
      assert {:ok, entries, nil} = SessionState.projected_lineage(before, :session, 0)
      assert entries == [summary_entry] ++ elem(Loopex.Conversation.lineage_entries(
        SessionState.elements(before, List.last(before.run_order))), 1)
      assert Enum.count(entries, &(&1 == summary_entry)) == 1
      assert elem(List.last(entries), 1) == %{"role" => "assistant", "content" => "tail finished"}

      command = configure("too-small", %{"context_token_budget" => 600, "system_class_tokens" => 500})
      reason = if @limiting == :tail, do: :compaction_required, else: :invalid_session_configuration
      assert {:error, ^reason} = Loopex.command(f.attachment, command)
      assert {:error, ^reason} = Loopex.command(f.attachment, command)
      assert calls(f) == 1
      after_refusal = recover(f)
      assert after_refusal.configuration == before.configuration
      assert after_refusal.active_checkpoint == before.active_checkpoint
      assert after_refusal.conversation == before.conversation
      refute Enum.any?(Fixture.events(f, f.session), &(&1.kind == "session.configured"))
      assert [row] = configuration_rows(f)
      assert row.payload["configuration"] == nil
      assert_replay(f)

      assert {:accepted, "fits"} = Loopex.command(f.attachment, configure("fits"))
      assert_configured_request(f, "after-size-check", entries)
    end
  end

  for owner_kind <- [:compact, :automatic] do
    @owner_kind owner_kind
    test "#{owner_kind} preparation refuses configure before resolution and joins on cancellation" do
      f = maintenance_fixture(@owner_kind, [])
      coordinator = owner(f)
      supervisor = :sys.get_state(coordinator).owner_workers
      hold_next_worker(supervisor)
      begin_maintenance(f, @owner_kind)
      assert_receive {:held_preparation, worker}, 5_000
      monitor = Process.monitor(worker)
      command = configure("while-preparing")
      assert {:error, :configuration_not_settled} = Loopex.command(f.attachment, command)
      assert calls(f) == 0
      assert recover(f).configuration == f.initial
      assert {:accepted, "cancel"} = Loopex.command(f.attachment, %{type: :abort, command_id: "cancel"})
      assert_receive {:DOWN, ^monitor, :process, ^worker, reason}, 5_000
      assert reason in [:killed, :shutdown]
      await_settled(f)
      assert Task.Supervisor.children(supervisor) == []
      assert {:error, :configuration_not_settled} = Loopex.command(f.attachment, command)
      assert calls(f) == 0
      assert {:accepted, "settled"} = Loopex.command(f.attachment, configure("settled"))
      assert calls(f) == 1
      assert_replay(f)
    end

    test "#{owner_kind} summary work and registered cleanup refuse configure until exact joins" do
      f = maintenance_fixture(@owner_kind, [summary_turn("retained fact", hold: self())], cleanup: true)
      begin_maintenance(f, @owner_kind)
      assert_receive {:registered_resource, child}, 5_000
      child_monitor = Process.monitor(child)
      assert_receive {:holding, callback}, 5_000
      callback_monitor = Process.monitor(callback)
      assert {:error, :configuration_not_settled} = Loopex.command(f.attachment, configure("during-summary"))
      assert calls(f) == 0
      send(callback, :release)
      assert_receive {:DOWN, ^callback_monitor, :process, ^callback, :normal}, 5_000
      assert_receive {:cleanup_pending, ^child}, 5_000
      assert Process.alive?(child)
      assert {:error, :configuration_not_settled} = Loopex.command(f.attachment, configure("during-cleanup"))
      assert calls(f) == 0
      assert recover(f).configuration == f.initial
      send(child, :release)
      assert_receive {:DOWN, ^child_monitor, :process, ^child, :normal}, 5_000
      await_settled(f)
      state = :sys.get_state(owner(f))
      assert state.in_flight == %{}
      assert state.pending_cleanup == %{}
      assert Task.Supervisor.children(state.owner_workers) == []
      assert {:accepted, "settled"} = Loopex.command(f.attachment, configure("settled"))
      assert calls(f) == 1
      assert_replay(f)
    end

    test "#{owner_kind} committed checkpoint recovery refuses configure before maintenance completion" do
      f = maintenance_fixture(@owner_kind, [summary_turn("retained fact", hold: self())])
      begin_maintenance(f, @owner_kind)
      assert_receive {:holding, callback}, 5_000
      callback_monitor = Process.monitor(callback)
      kind = if @owner_kind == :compact,
        do: "standalone_compaction_checkpoint_committed_v1", else: "compaction_checkpoint_committed_v1"
      assert :ok = TestStore.delay_after_record(f.store, kind, self())
      send(callback, :release)
      assert_receive {:DOWN, ^callback_monitor, :process, ^callback, :normal}, 5_000
      assert_receive {:record_linearized, waiter, _, ^kind, :session_journal_commit, {:committed, _, _}}, 5_000
      waiter_monitor = Process.monitor(waiter)
      before = recover(f)
      assert is_binary(before.active_checkpoint)
      assert before.maintenance_episodes[before.active_maintenance]["stage"] == "checkpoint_committed"
      kill_owner(f)
      assert {:ok, {:prepared, activation}} = Loopex.prepare_resume_session(f.runtime, f.session, "recover")
      assert {:ok, attachment} = Loopex.attach(f.runtime, f.session, after_event_sequence: 0)
      resumed = %{f | attachment: attachment}
      command = configure("before-completion")
      assert {:error, :configuration_not_settled} = Loopex.command(attachment, command)
      assert calls(f) == 0
      assert recover(f).configuration == before.configuration
      assert recover(f).active_checkpoint == before.active_checkpoint
      TestStore.release(waiter)
      assert_receive {:DOWN, ^waiter_monitor, :process, ^waiter, :normal}, 5_000
      assert {:ok, session} = Loopex.activate_resume(activation)
      assert session == f.session
      await_settled(resumed)
      assert summary_count(f) == 1
      assert {:error, :configuration_not_settled} = Loopex.command(attachment, command)
      assert calls(f) == 0
      {:ok, entries, nil} = SessionState.projected_lineage(recover(f), :session, 0)
      assert {:accepted, "settled"} = Loopex.command(attachment, configure("settled"))
      assert_configured_request(resumed, "after-recovery", entries)
      assert_replay(f)
    end
  end

  # Concept: the test adapter exercises host preparation and managed cleanup.
  # Technical depth: history, checkpoints, refusals and owner succession all use
  # actual runtime/Store transactions. Model and executor replies are scripted;
  # these cases claim no provider transport or operating-system effect proof.
  defp fixture(script, options \\ []) do
    definitions = Keyword.get(options, :tools, [])
    initial = Genesis.configuration()
      |> Map.put("context_token_budget", Keyword.get(options, :context_token_budget, 8_192))
      |> Map.put("system_class_tokens", min(5_000, Keyword.get(options, :context_token_budget, 8_192)))
      |> put_in(["budget_origins", "context_token_budget"], "explicit")
      |> put_in(["provider_mapping", "canonical_terminal_tool_history"], true)
    observer = self()
    {:ok, controller} = Agent.start_link(fn -> %{calls: 0,
      compatible: Keyword.get(options, :compatible, true), cleanup: Keyword.get(options, :cleanup, false)} end)
    model = Script.start(script)
    executor = Loopex.AgentLoopTestExecutor.start()
    {store, handle} = TestStore.start_store(label: "configure-checkpoint")
    maintenance = %{"model" => initial["model"], "reasoning" => "none",
      "model_capabilities" => Map.put(initial["model_capabilities"], "reasoning_levels", ["none", "default"]),
      "provider_mapping" => Map.put(initial["provider_mapping"], "thinking_disabled", true)}
    {:ok, runtime} = Loopex.start_link(
      runtime_id: "configure-checkpoint", store: handle, cleanup_grace_ms: 5_000,
      context_token_budget: initial["context_token_budget"],
      model: %{module: Preparing, model: "scripted:v1",
        options: [script: model, controller: controller, observer: observer, max_tokens: 1_024]},
      maintenance_model: maintenance,
      maintenance_instructions: %{"version" => "summary.v1", "body" => "Keep the facts"},
      executor: %{module: Loopex.AgentLoopTestExecutor, reference: executor,
        identity: "agent-loop-executor", epoch: 1, fencing_token: 1,
        workspace_ref: "workspace-ref", workspace_lease: "workspace-lease"},
      bounds: Fixture.bounds(), sampling: %{"max_tokens" => 1_024},
      tools: definitions, active_tools: Enum.map(definitions, & &1["tool_id"]),
      policy: Loopex.AgentLoopTestPolicy, policy_identity: %{"id" => "test", "revision" => "1"},
      grant_decision: {:host_policy, :allow})

    on_exit(fn ->
      monitor = Process.monitor(runtime.supervisor)
      if Process.alive?(runtime.supervisor), do: Loopex.stop(runtime)
      assert_receive {:DOWN, ^monitor, :process, _, _}, 5_000
      for actor <- [controller, model, executor, store] do
        monitor = Process.monitor(actor)
        if Process.alive?(actor), do: GenServer.stop(actor, :normal, 1_000)
        assert_receive {:DOWN, ^monitor, :process, ^actor, _}, 1_000
      end
    end)

    {:ok, session} = Loopex.create_session(runtime, %{}, command_id: "create",
      genesis: Genesis.genesis(definitions, initial))
    {:ok, attachment} = Loopex.attach(runtime, session, after_event_sequence: 0)
    %{runtime: runtime, store: store, model: model, executor: executor,
      controller: controller, session: session, attachment: attachment, initial: initial}
  end

  defp maintenance_fixture(kind, summary_script, options \\ []) do
    options = if kind == :automatic, do: Keyword.put(options, :context_token_budget, 4_000), else: options
    f = fixture([normal("old finished")] ++ summary_script ++ [normal("current finished")], options)
    prompt(f, "old", String.duplicate("o", 12_000))
    f
  end

  defp begin_maintenance(f, :compact),
    do: assert({:accepted, "compact"} == Loopex.command(f.attachment, compact_command("compact")))
  defp begin_maintenance(f, :automatic),
    do: assert({:accepted, "automatic"} == Loopex.command(f.attachment,
      %{type: :prompt, command_id: "automatic", content: String.duplicate("c", 4_000)}))

  defp normal(text), do: %{text: text, calls: [], reply_overrides: %{completion: "natural", continuation: nil}}
  defp tool_turn(id), do: %{text: "", calls: [%{id: id, name: "write", arguments: %{"path" => "file"}}],
    reply_overrides: %{completion: "unknown", continuation: nil}}
  defp summary_turn(summary \\ "retained fact", options \\ []) do
    {:ok, encoded} = LoopexProtocol.Frame.encode(%{"v" => %{"summary" => summary,
      "carry_forward" => %{"files_read" => [], "files_changed" => []}}})
    bytes = IO.iodata_to_binary(encoded)
    normal(binary_part(bytes, 5, byte_size(bytes) - 7)) |> Map.merge(Map.new(options))
  end
  defp configure(id, changes \\ %{}), do: %{type: :configure, command_id: id,
    changes: Map.merge(%{"model" => "scripted:v2", "max_tokens" => 512, "context_token_budget" => 8_192}, changes)}
  defp compact_command(id), do: %{type: :compact, command_id: id,
    bounds: %{"max_attempts" => 4, "deadline_ms" => 60_000, "token_budget" => 32_768}}
  defp compact(f, id) do
    assert {:accepted, ^id} = Loopex.command(f.attachment, compact_command(id))
    completed = await_settled(f)
    assert completed.commands[id].result["disposition"] == "checkpointed"
    assert completed.commands[id].result["cleanup"] == "confirmed"
    assert is_binary(completed.active_checkpoint)
  end
  defp prompt(f, id, content) do
    assert {:accepted, ^id} = Loopex.command(f.attachment, %{type: :prompt, command_id: id, content: content})
    await_settled(f)
  end
  defp recover(f) do
    assert {:ok, state} = SessionState.recover(f.session, Fixture.records(f, f.session), Fixture.events(f, f.session))
    state
  end
  defp assert_replay(f) do
    replayed = recover(f)
    assert {:ok, status} = Loopex.session_status(f.runtime, f.session)
    assert status.configuration["configuration_version"] == replayed.configuration["configuration_version"]
    assert status.configuration["model"] == replayed.configuration["model"]
    assert replayed.active_maintenance == nil
    replayed
  end
  defp assert_configured_request(f, command, entries) do
    prompt(f, command, "next configured prompt")
    state = recover(f)
    run = List.last(state.run_order)
    assert state.run_configurations[run] == state.configuration
    assert state.run_configurations[run]["configuration_version"] == 2
    request = List.last(Script.dispatched(f.model))
    assert request.model == "scripted:v2"
    assert request.sampling["max_tokens"] == 512
    assert Enum.drop(request.messages, 1) == Enum.map(entries, &elem(&1, 1)) ++
      [%{"role" => "user", "content" => "next configured prompt"}]
    assert_replay(f)
  end
  defp calls(f), do: Agent.get(f.controller, & &1.calls)
  defp configuration_rows(f), do: Enum.filter(Fixture.records(f, f.session),
    &(&1.payload.kind == "session_configuration_admitted_v2"))
  defp summary_count(f), do: Enum.count(Script.dispatched(f.model),
    &(hd(&1.messages)["content"] == "summary.v1: Keep the facts"))
  defp owner(f) do
    {:ok, children} = Loopex.Runtime.children(f.runtime)
    :sys.get_state(children.control).sessions[f.session].coordinator
  end
  defp kill_owner(f) do
    coordinator = owner(f)
    monitor = Process.monitor(coordinator)
    Process.exit(coordinator, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^coordinator, :killed}, 5_000
  end
  defp await_settled(f, cutoff \\ nil) do
    cutoff = cutoff || System.monotonic_time(:millisecond) + 5_000
    state = recover(f)
    if is_nil(state.active_run_id) and is_nil(state.pending_compact) do
      state
    else
      assert System.monotonic_time(:millisecond) < cutoff
      Process.sleep(1)
      await_settled(f, cutoff)
    end
  end
  defp hold_next_worker(supervisor) do
    caller = self()
    hook = fn
      :armed, {:out, {:ok, worker}, _, _}, _ when is_pid(worker) ->
        true = :erlang.suspend_process(worker)
        send(caller, {:held_preparation, worker})
        :held
      state, _, _ -> state
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
