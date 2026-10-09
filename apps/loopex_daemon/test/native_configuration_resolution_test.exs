Code.require_file("../../loopex/test/support/m1_runtime_helper.exs", __DIR__)
Code.require_file("../../loopex/test/support/agent_loop_helper.exs", __DIR__)

defmodule LoopexDaemon.NativeConfigurationResolutionTest do
  @moduledoc """
  ## Concept

  Native daemon configuration admission uses the reference host resolver and
  the session's committed history, including checkpoints and maintenance.

  ## Technical depth

  These cases join Composition.Model.reference with Runtime.command_for_daemon.
  Host resolution is real; completion and Store/executor fixtures are scripted.
  They prove native admission, retained identity, replay and owned worker joins,
  without claiming wire, credential, physical Store or provider transport proof.
  """

  use ExUnit.Case, async: false

  alias Loopex.AgentLoopFixture, as: Fixture
  alias Loopex.AgentLoopTestModel, as: Script
  alias Loopex.ConfiguredGenesisFixture, as: Genesis
  alias Loopex.M1RuntimeTestStore, as: TestStore
  alias Loopex.Runtime.{CompactionSummary, Instructions, SessionConfiguration, SessionState}
  alias LoopexComposition.{Model, ProviderBindings}

  @authored_model "anthropic:claude-haiku-4-5"
  @canonical_model "anthropic:claude-haiku-4-5-20251001"
  @credential_name "M7_NATIVE_CONFIGURATION_REFERENCE"

  test "the native route retains the host-resolved alias and exact candidate once across owner recovery" do
    f = fixture([])

    {:ok, instructions} =
      Instructions.capture(%{
        "version" => "changed.v1",
        "base" => "exact changed bytes 猫",
        "environment" => "retained environment",
        "appendix" => "retained appendix"
      })

    command =
      configure("alias", %{
        "model" => @authored_model,
        "reasoning" => "high",
        "instructions" => instructions,
        "max_tokens" => 8_192
      })

    assert {:accepted, "alias"} = native(f, command)
    [row] = configuration_rows(f)
    candidate = row.payload["configuration"]
    assert candidate["model"] == @canonical_model
    assert candidate["reasoning"] == "high"
    assert candidate["max_tokens"] == 8_192
    assert candidate["instructions"] == instructions
    assert candidate["configuration_version"] == 2

    assert :ok =
             SessionConfiguration.validate_candidate(f.initial, command.changes, candidate, [])

    assert row.payload["changes"] ==
             Map.put(command.changes, "instructions", Map.take(instructions, ~w(version digest)))

    digest =
      :erlang.term_to_binary(["loopex_command_v1", command], [:deterministic])
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    assert row.payload["command_digest"] == digest
    assert row.payload["prior_configuration_version"] == 1
    assert row.payload["admission"] == "accepted"
    assert map_size(row.payload) == 8
    assert_resolution(f, [command.changes])
    assert {:accepted, "alias"} = native(f, command)

    assert {:error, :idempotency_conflict} =
             native(f, %{command | changes: Map.put(command.changes, "model", @canonical_model)})

    assert configuration_rows(f) == [row]
    assert_resolution(f, [command.changes])
    assert Script.dispatched(f.model) == []
    assert Loopex.AgentLoopTestExecutor.jobs(f.executor) == []
    assert_replay(f)

    owner = owner(f)
    monitor = Process.monitor(owner)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :killed}, 5_000
    assert {:ok, session} = Loopex.resume_session(f.runtime, f.session, command_id: "resume")
    assert session == f.session
    assert {:ok, attachment} = Loopex.attach(f.runtime, session, after_event_sequence: 0)
    resumed = %{f | attachment: attachment}
    assert {:accepted, "alias"} = native(resumed, command)
    assert recover(resumed).configuration == candidate
    assert configuration_rows(resumed) == [row]
    assert_resolution(resumed, [command.changes])
    assert Script.dispatched(f.model) == []
    assert Loopex.AgentLoopTestExecutor.jobs(f.executor) == []
    assert_replay(resumed)
  end

  test "an unadmitted host route refuses once without completion or a canonical candidate" do
    f = fixture([], provider_bindings: %{"openai" => credential()})
    command = configure("unadmitted", %{"model" => @authored_model})
    assert {:error, :configuration_not_prepared} = native(f, command)
    assert {:error, :configuration_not_prepared} = native(f, command)
    [row] = configuration_rows(f)
    assert row.payload["admission"] == "rejected_configuration_not_prepared"
    assert row.payload["changes"] == command.changes
    assert row.payload["configuration"] == nil
    assert recover(f).configuration == f.initial
    assert_resolution(f, [command.changes])
    assert Script.dispatched(f.model) == []
    assert Loopex.AgentLoopTestExecutor.jobs(f.executor) == []
    assert_replay(f)
  end

  for limiting <- [:tail, :summary] do
    @limiting limiting
    test "native host resolution admits only the exact committed #{@limiting} projection" do
      summary = if @limiting == :summary, do: String.duplicate("s", 3_000), else: "retained fact"
      tail = if @limiting == :tail, do: String.duplicate("t", 4_000), else: "surviving tail"
      f = fixture([normal("old finished"), summary_turn(summary), normal("tail finished")])
      prompt(f, "old", String.duplicate("o", 12_000))
      compact(f, "compact")
      prompt(f, "tail", tail)
      before = recover(f)

      {:ok, summary_entry} =
        CompactionSummary.project(
          before.active_checkpoint,
          before.checkpoints[before.active_checkpoint]["summary"]
        )

      assert {:ok, entries, nil} = SessionState.projected_lineage(before, :session, 0)

      assert entries ==
               [summary_entry] ++
                 elem(
                   Loopex.Conversation.lineage_entries(
                     SessionState.elements(before, List.last(before.run_order))
                   ),
                   1
                 )

      assert Enum.count(entries, &(&1 == summary_entry)) == 1
      assert elem(List.last(entries), 1)["content"] == "tail finished"

      command =
        configure("too-small", %{
          "model" => @authored_model,
          "max_tokens" => 512,
          "context_token_budget" => 600,
          "system_class_tokens" => 500
        })

      reason =
        if @limiting == :tail, do: :compaction_required, else: :invalid_session_configuration

      assert {:error, ^reason} = native(f, command)
      assert {:error, ^reason} = native(f, command)
      assert_resolution(f, [command.changes])
      after_refusal = recover(f)
      assert after_refusal.configuration == before.configuration
      assert after_refusal.active_checkpoint == before.active_checkpoint
      assert after_refusal.conversation == before.conversation
      assert [row] = configuration_rows(f)
      assert row.payload["configuration"] == nil
      assert row.payload["changes"] == command.changes
      refute Enum.any?(Fixture.events(f, f.session), &(&1.kind == "session.configured"))
      assert_replay(f)

      fitting = configure("fits", %{"model" => @authored_model, "max_tokens" => 512})
      assert {:accepted, "fits"} = native(f, fitting)
      assert recover(f).active_checkpoint == before.active_checkpoint
      assert_resolution(f, [command.changes, fitting.changes])
      prompt(f, "configured-prompt", "next configured prompt")
      state = recover(f)
      assert state.run_configurations[List.last(state.run_order)] == state.configuration
      request = List.last(Script.dispatched(f.model))
      assert request.model == @canonical_model
      assert request.sampling["max_tokens"] == 512

      assert Enum.drop(request.messages, 1) ==
               Enum.map(entries, &elem(&1, 1)) ++
                 [%{"role" => "user", "content" => "next configured prompt"}]

      assert_replay(f)
    end
  end

  test "active maintenance refuses the daemon-native command before any host resolution" do
    f = fixture([normal("old finished"), summary_turn("retained fact", hold: self())])
    prompt(f, "old", String.duplicate("o", 12_000))
    assert {:accepted, "compact"} = native(f, compact_command("compact"))
    assert_receive {:holding, callback}, 5_000
    monitor = Process.monitor(callback)
    pending = recover(f)

    assert pending.maintenance_episodes[pending.active_maintenance]["stage"] ==
             "model_attempt_open"

    command = configure("during-maintenance", %{"model" => @authored_model})
    assert {:error, :maintenance_active} = native(f, command)
    assert_resolution(f, [])
    assert recover(f).configuration == f.initial
    assert [row] = configuration_rows(f)
    assert row.payload["configuration"] == nil
    send(callback, :release)
    assert_receive {:DOWN, ^monitor, :process, ^callback, :normal}, 5_000
    completed = await_settled(f)
    assert is_binary(completed.active_checkpoint)
    assert completed.commands["compact"].result["disposition"] == "checkpointed"
    assert completed.commands["compact"].result["cleanup"] == "confirmed"
    assert {:error, :maintenance_active} = native(f, command)
    assert_resolution(f, [])
    fitting = configure("after-maintenance", %{"model" => @authored_model})
    assert {:accepted, "after-maintenance"} = native(f, fitting)
    assert_resolution(f, [fitting.changes])
    coordinator = :sys.get_state(owner(f))
    assert coordinator.in_flight == %{}
    assert coordinator.pending_cleanup == %{}
    assert Task.Supervisor.children(coordinator.owner_workers) == []
    assert_replay(f)
  end

  defp fixture(script, options \\ []) do
    bindings = %{"anthropic" => credential()}

    {:ok, initial} =
      ProviderBindings.resolve_configuration(
        %{
          "model" => @authored_model,
          "reasoning" => "default",
          "configuration_version" => 1,
          "instructions" => Genesis.configuration()["instructions"],
          "max_tokens" => 1_024,
          "context_token_budget" => 8_192,
          "system_class_tokens" => 5_000
        },
        bindings,
        []
      )

    {:ok, maintenance} = ProviderBindings.resolve_maintenance_model(@authored_model, bindings)
    trace = trace_resolution()
    model = Script.start(script)
    executor = Loopex.AgentLoopTestExecutor.start()
    {store, handle} = TestStore.start_store(label: "daemon-native-configuration")

    on_exit(fn ->
      for actor <- [model, executor, store] do
        monitor = Process.monitor(actor)
        if Process.alive?(actor), do: GenServer.stop(actor, :normal, 1_000)
        assert_receive {:DOWN, ^monitor, :process, ^actor, _}, 1_000
      end
    end)

    reference =
      Model.reference(
        %{module: Script, model: @canonical_model, options: [script: model, max_tokens: 1_024]},
        provider_bindings: Keyword.get(options, :provider_bindings, bindings)
      )

    assert {:ok, runtime} =
             Loopex.start_link(
               runtime_id: "daemon-native-configuration",
               store: handle,
               cleanup_grace_ms: 5_000,
               context_token_budget: 8_192,
               model: reference,
               maintenance_model: maintenance,
               maintenance_instructions: %{"version" => "summary.v1", "body" => "Keep the facts"},
               executor: %{
                 module: Loopex.AgentLoopTestExecutor,
                 reference: executor,
                 identity: "agent-loop-executor",
                 epoch: 1,
                 fencing_token: 1,
                 workspace_ref: "workspace-ref",
                 workspace_lease: "workspace-lease"
               },
               bounds: Fixture.bounds(),
               tools: [],
               active_tools: [],
               policy: Loopex.AgentLoopTestPolicy,
               policy_identity: %{"id" => "test", "revision" => "1"},
               grant_decision: {:host_policy, :allow}
             )

    on_exit(fn ->
      monitor = Process.monitor(runtime.supervisor)
      if Process.alive?(runtime.supervisor), do: Loopex.stop(runtime)
      assert_receive {:DOWN, ^monitor, :process, _, _}, 5_000
    end)

    :ok = Genesis.await_creation_ready(runtime)

    assert {:ok, session} =
             Loopex.create_session(runtime, %{},
               command_id: "create",
               genesis: Genesis.genesis([], initial)
             )

    assert {:ok, attachment} = Loopex.attach(runtime, session, after_event_sequence: 0)

    %{
      runtime: runtime,
      store: store,
      model: model,
      executor: executor,
      session: session,
      attachment: attachment,
      initial: initial,
      trace: trace
    }
  end

  defp credential, do: %{"credential" => %{"env" => @credential_name}}
  defp configure(id, changes), do: %{type: :configure, command_id: id, changes: changes}

  defp native(f, command) do
    assert {:routed, %Loopex.Runtime.DaemonRoute{}, reply} =
             Loopex.Runtime.command_for_daemon(f.attachment, command)

    reply
  end

  defp prompt(f, id, content) do
    assert {:accepted, ^id} = native(f, %{type: :prompt, command_id: id, content: content})
    await_settled(f)
  end

  defp compact_command(id),
    do: %{
      type: :compact,
      command_id: id,
      bounds: %{"max_attempts" => 4, "deadline_ms" => 60_000, "token_budget" => 32_768}
    }

  defp compact(f, id) do
    assert {:accepted, ^id} = native(f, compact_command(id))
    state = await_settled(f)
    assert state.commands[id].result["disposition"] == "checkpointed"
    assert state.commands[id].result["cleanup"] == "confirmed"
    assert is_binary(state.active_checkpoint)
  end

  defp normal(text),
    do: %{
      text: text,
      calls: [],
      reply_overrides: %{completion: "natural", continuation: nil}
    }

  defp summary_turn(summary, options \\ []) do
    {:ok, encoded} =
      LoopexProtocol.Frame.encode(%{
        "v" => %{
          "summary" => summary,
          "carry_forward" => %{"files_read" => [], "files_changed" => []}
        }
      })

    bytes = IO.iodata_to_binary(encoded)
    normal(binary_part(bytes, 5, byte_size(bytes) - 7)) |> Map.merge(Map.new(options))
  end

  defp recover(f) do
    snapshot = TestStore.inspect_state(f.store).sessions |> Map.fetch!(f.session)
    assert {:ok, state} = SessionState.recover(f.session, snapshot.records, snapshot.events)
    state
  end

  defp configuration_rows(f),
    do:
      Enum.filter(
        Fixture.records(f, f.session),
        &(&1.payload.kind == "session_configuration_admitted_v2")
      )

  defp assert_replay(f) do
    state = recover(f)
    assert {:ok, status} = Loopex.session_status(f.runtime, f.session)
    assert status.configuration == SessionConfiguration.public_view(state.configuration)
    refute :erlang.term_to_binary(Fixture.records(f, f.session)) =~ @credential_name
    refute :erlang.term_to_binary(Fixture.events(f, f.session)) =~ @credential_name
  end

  defp owner(f) do
    {:ok, children} = Loopex.Runtime.children(f.runtime)
    :sys.get_state(children.control).sessions[f.session].coordinator
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

  # Concept: observe actual host resolution without replacing its implementation.
  # Technical depth: a private trace session follows only this fixture's spawned
  # actors. Its delivery barrier retains calls, returns and original worker exits.
  defp trace_resolution do
    trace = :trace.session_create(:m7_daemon_native_configuration, self(), [])

    for {module, _, _} = function <- [
          {Model, :prepare_configuration, 5},
          {ProviderBindings, :resolve_configuration_routes, 3}
        ] do
      Code.ensure_loaded!(module)
      assert :trace.function(trace, function, [{:_, [], [{:return_trace}]}], [:local]) == 1
    end

    assert :trace.process(trace, self(), true, [:call, :procs, :set_on_spawn]) == 1

    on_exit(fn ->
      try do
        :trace.session_destroy(trace)
      catch
        :error, :badarg -> :ok
      end
    end)

    trace
  end

  defp assert_resolution(f, authored) do
    fence = :trace.delivered(f.trace, :all)
    key = {__MODULE__, f.trace}

    frames =
      collect_trace(fence, System.monotonic_time(:millisecond) + 5_000, Process.get(key, []))

    Process.put(key, frames)

    preparations =
      for {:trace, worker, :call, {Model, :prepare_configuration, args}} <- frames,
          do: {worker, args}

    assert Enum.map(preparations, fn {_worker, [_current, changes, [], _context, _options]} ->
             changes
           end) == authored

    routes =
      for {:trace, worker, :call, {ProviderBindings, :resolve_configuration_routes, args}} <-
            frames,
          do: {worker, args}

    assert length(routes) == length(authored)

    for {worker, [current, changes, [], context, options]} <- preparations do
      assert Enum.sort(Map.keys(context)) == [:cleanup_grace_ms, :deadline_monotonic_ms]
      assert context.cleanup_grace_ms == 5_000
      assert is_integer(context.deadline_monotonic_ms)
      assert Keyword.fetch!(options, :adapter) == Script
      assert Keyword.fetch!(options, :adapter_options) == [script: f.model, max_tokens: 1_024]
      host_bindings = options[:host_options][:provider_bindings]

      assert [{^worker, [declaration, providers, []]}] =
               Enum.filter(routes, &(elem(&1, 0) == worker))

      assert Enum.sort(providers) == Enum.sort(Map.keys(host_bindings))
      assert declaration["model"] == Map.get(changes, "model", current["model"])

      results =
        for {:trace, ^worker, :return_from, {Model, :prepare_configuration, 5}, result} <- frames,
            do: result

      assert [result] = results

      case result do
        {:ok, candidate} ->
          assert :ok = SessionConfiguration.validate_candidate(current, changes, candidate, [])

        {:error, :configuration_not_prepared} ->
          :ok
      end

      assert Enum.any?(frames, &match?({:trace, ^worker, :exit, :normal}, &1))
      refute Process.alive?(worker)
    end
  end

  defp collect_trace(fence, cutoff, frames) do
    remaining = cutoff - System.monotonic_time(:millisecond)
    assert remaining > 0

    receive do
      {:trace_delivered, :all, ^fence} -> frames
      {:trace, _, _, _} = frame -> collect_trace(fence, cutoff, frames ++ [frame])
      {:trace, _, _, _, _} = frame -> collect_trace(fence, cutoff, frames ++ [frame])
    after
      remaining -> flunk("original host resolution trace delivery did not complete")
    end
  end
end
