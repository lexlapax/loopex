Code.require_file("../../loopex/test/support/m1_runtime_helper.exs", __DIR__)
Code.require_file("../../loopex/test/support/agent_loop_helper.exs", __DIR__)

defmodule LoopexCli.ChatWorkflowTest do
  use ExUnit.Case, async: false
  @moduletag capture_log: true
  alias LoopexCli.{Chat, ChatConfiguration}
  alias Loopex.AgentLoopFixture, as: Fixture

  setup do
    root = Path.join(System.tmp_dir!(), "chat-workflow-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "workspace"))
    File.mkdir!(Path.join(root, "state"))
    path = Path.join(root, "config.json")

    profile = %{
      "schema_version" => 1,
      "providers" => %{"anthropic" => %{"credential" => %{"env" => "M7_WORKFLOW_SLOT"}}},
      "policy" => "allow-all",
      "paths" => %{"workspace" => "workspace", "state_root" => "state"},
      "session" => %{
        "model" => "anthropic:claude-haiku-4-5",
        "tools" => "none",
        "bounds" => %{"max_turns" => 8, "deadline_ms" => 1000, "token_budget" => 10000}
      }
    }

    File.write!(path, :json.encode(profile))
    {:ok, prepared} = ChatConfiguration.load(["chat", "--config", path], root, nil)
    {:ok, input} = StringIO.open("one\n/wait\ntwo\n/wait\n/quit\n", encoding: :latin1)
    {:ok, output} = StringIO.open("", encoding: :latin1)
    {:ok, diagnostic} = StringIO.open("", encoding: :latin1)
    on_exit(fn -> File.rm_rf!(root) end)

    %{
      root: root,
      path: path,
      profile: profile,
      prepared: prepared,
      input: input,
      output: output,
      diagnostic: diagnostic
    }
  end

  test "dispatch joins two prompts, settings and cleanup before closing", f do
    fixture = fixture(f, [%{text: "first", calls: []}, %{text: "second", calls: []}])

    assert :ok =
             LoopexCli.dispatch(["chat", "--config", f.path], chat_options: options(f, fixture))

    records = controls(f.output)
    assert [first, second, quit] = Enum.filter(records, &(&1["event"] == "wait"))
    assert quit["run_id"] == second["run_id"]
    assert first["state"] == "settled" and second["state"] == "settled"
    assert first["session_id"] == second["session_id"]
    assert first["run_id"] != second["run_id"]
    assert List.last(records)["cleanup"] == "confirmed"
    assert List.last(records)["exit_code"] == 0
    assert [_, request] = Loopex.AgentLoopTestModel.dispatched(fixture.model)
    assert Enum.any?(request.messages, &(&1["content"] == "one"))
    assert Enum.any?(request.messages, &(&1["content"] == "two"))
    {_, report} = StringIO.contents(f.diagnostic)
    assert report =~ "/session/model"
    refute report =~ "M7_WORKFLOW_SLOT"
    refute report =~ "model_capabilities"
    refute report =~ "provider_mapping"
  end

  test "file-enabled trace reaches diagnostics and joins before successful closing", f do
    assert_trace_workflow(f, true, [], true, "file#/trace/enabled")
  end

  test "no-trace overrides an enabled file through actual chat startup", f do
    assert_trace_workflow(f, true, ["--no-trace"], false, "flag")
  end

  test "trace overrides a disabled file through actual chat startup", f do
    assert_trace_workflow(f, false, ["--trace"], true, "flag")
  end

  test "resume uses the real prepared signal holder and retained conversation", f do
    isolated_signal_manager()
    original = fixture(f, [%{text: "first", calls: []}])

    {:ok, session} =
      Loopex.create_session(original.runtime, f.prepared.session_options,
        command_id: "create",
        genesis: f.prepared.genesis
      )

    assert :ok =
             Loopex.track_session(Path.join(f.root, "state"), session, "chat-workflow-runtime")

    {:ok, attachment} = Loopex.attach(original.runtime, session, after_event_sequence: 0)

    assert {:accepted, "first"} =
             Loopex.command(attachment, %{type: :prompt, command_id: "first", content: "before"})

    assert await_terminal(attachment, System.monotonic_time(:millisecond) + 5000)["outcome"] ==
             "completed"

    assert :ok = Loopex.stop(original.runtime)

    resumed =
      Fixture.start(
        script: [%{text: "second", calls: []}],
        store: original.store,
        tools: [],
        model: f.prepared.selection.configuration["model"],
        runtime_id: "chat-workflow-runtime"
      )

    on_exit(fn -> Fixture.stop(resumed) end)
    changed = put_in(f.profile, ["session", "model"], "anthropic:unknown-file-default")
    File.write!(f.path, :json.encode(changed))
    {:ok, input} = StringIO.open("after\n/wait\n/quit\n", encoding: :latin1)

    opts =
      options(%{f | input: input}, resumed)
      |> Keyword.delete(:install_signal)
      |> Keyword.delete(:finish_signal)

    result = Chat.run(["chat", "--config", f.path, "--resume", session], opts)
    assert result == 0, inspect(controls(f.output))
    assert [request] = Loopex.AgentLoopTestModel.dispatched(resumed.model)
    assert Enum.any?(request.messages, &(&1["content"] == "before"))
    assert Enum.any?(request.messages, &(&1["content"] == "after"))
    assert List.last(controls(f.output))["cleanup"] == "confirmed"
    {_, report} = StringIO.contents(f.diagnostic)
    assert report =~ "committed"
    refute report =~ "M7_WORKFLOW_SLOT"
  end

  test "unconfirmed composition makes a locally clean ending unknown", f do
    fixture = fixture(f, [%{text: "first", calls: []}, %{text: "second", calls: []}])
    assert Chat.run(["chat", "--config", f.path], options(f, fixture, :unconfirmed)) == 1
    assert List.last(controls(f.output))["cleanup"] == "unknown"
    assert List.last(controls(f.output))["exit_code"] == 1
  end

  test "signal refusal stops attachments before reading a prompt", f do
    fixture = fixture(f, [])

    opts =
      Keyword.put(options(f, fixture), :install_signal, fn _, _, _, _ ->
        {:error, :interrupt_handler_unavailable}
      end)

    assert Chat.run(["chat", "--config", f.path], opts) == 1
    assert {"one\n/wait\ntwo\n/wait\n/quit\n", ""} == StringIO.contents(f.input)
    assert Loopex.AgentLoopTestModel.dispatched(fixture.model) == []
    assert Enum.any?(controls(f.output), &(&1["code"] == "chat_signal_start_failed"))
    assert List.last(controls(f.output))["cleanup"] == "confirmed"
  end

  test "installer failure joins transport workers before outer cleanup", f do
    fixture = fixture(f, [])
    test = self()

    opts =
      Keyword.put(options(f, fixture), :install_signal, fn driver, _, _, _ ->
        send(test, {:driver, driver})
        raise "private failure must not reach output"
      end)

    assert Chat.run(["chat", "--config", f.path], opts) == 1
    assert_receive {:driver, driver}
    refute Process.alive?(driver)
    assert {"one\n/wait\ntwo\n/wait\n/quit\n", ""} == StringIO.contents(f.input)
    assert Loopex.AgentLoopTestModel.dispatched(fixture.model) == []
    {_, transcript} = StringIO.contents(f.output)
    refute transcript =~ "private failure"
    assert List.last(controls(f.output))["cleanup"] == "confirmed"
  end

  test "replaced workspace refuses before reading input", f do
    fixture = fixture(f, [])

    opts =
      Keyword.put(options(f, fixture), :install_signal, fn _, _, _, nil ->
        File.rename!(Path.join(f.root, "workspace"), Path.join(f.root, "original"))
        File.mkdir!(Path.join(f.root, "workspace"))
        {:ok, self()}
      end)

    assert Chat.run(["chat", "--config", f.path], opts) == 1
    assert {"one\n/wait\ntwo\n/wait\n/quit\n", ""} == StringIO.contents(f.input)
    assert Loopex.AgentLoopTestModel.dispatched(fixture.model) == []
    assert Enum.any?(controls(f.output), &(&1["code"] == "chat_activation_failed"))
  end

  test "malformed file opens no placement or runtime", f do
    File.write!(f.path, "{\"schema_version\":1,\"schema_version\":1}")

    opts =
      basic(f) ++
        [
          acquire_placement: fn _, _ -> flunk("early placement") end,
          with_runtime: fn _, _ -> flunk("early composition") end
        ]

    assert Chat.run(["chat", "--config", f.path], opts) == 1

    assert [%{"event" => "error"}, %{"event" => "closing", "cleanup" => "confirmed"}] =
             controls(f.output)
  end

  test "resource refusal precedes placement and credential acquisition", f do
    opts =
      basic(f) ++
        [
          read_directories: fn _, _ -> {:error, :skill_directory_unavailable} end,
          acquire_placement: fn _, _ -> flunk("early placement") end,
          with_runtime: fn _, _ -> flunk("early composition") end
        ]

    assert Chat.run(["chat", "--config", f.path], opts) == 1
    assert List.last(controls(f.output))["cleanup"] == "confirmed"
  end

  defp assert_trace_workflow(f, file_enabled, flags, enabled, origin) do
    trace = %{
      "enabled" => file_enabled,
      "level" => "returns",
      "modules" => ["Loopex.Runtime.SessionCoordinator"],
      "max_entry_bytes" => 1024,
      "max_entries_per_second" => 1000,
      "max_queue_entries" => 256
    }

    File.write!(f.path, :json.encode(Map.put(f.profile, "trace", trace)))
    test = self()
    tag = make_ref()
    device = spawn(fn -> trace_device(f.diagnostic, test) end)
    on_exit(fn -> Process.exit(device, :kill) end)

    {host, host_monitor} =
      spawn_monitor(fn ->
        opts =
          basic(f) ++
            [
              diagnostic_device: device,
              acquire_placement: fn _, _ -> {:ok, "trace-placement"} end,
              release_placement: fn "trace-placement", _ ->
                refute Enum.any?(controls(f.output), &(&1["event"] == "closing"))
                :ok
              end,
              placement_id: fn _ -> {:ok, "chat-workflow-runtime"} end,
              with_runtime: fn options, callback ->
                consumer = options[:diagnostics_to]
                assert is_pid(consumer)

                fixture =
                  Fixture.start(
                    script: [
                      %{text: "first", calls: [], hold: test},
                      %{text: "second", calls: [], require_previous_worker_down: true}
                    ],
                    tools: [],
                    model: f.prepared.selection.configuration["model"],
                    runtime_id: "chat-workflow-runtime",
                    cleanup_grace_ms: options[:cleanup_grace_ms],
                    diagnostics_to: consumer
                  )

                send(test, {tag, :fixture, fixture})

                {:ok, %{tracer: tracer}} =
                  Loopex.Runtime.Supervisor.children(fixture.runtime.supervisor)

                runtime_monitors =
                  monitor_actors([tracer, fixture.runtime.supervisor])

                send(self(), {tag, :runtime, fixture, consumer})
                result = callback.(fixture.runtime)
                assert %{exit_code: 0, cleanup: :confirmed} = result
                assert_receive {^tag, :diagnostic_monitors, diagnostic_monitors}, 0
                join_actors(diagnostic_monitors)
                refute Enum.any?(controls(f.output), &(&1["event"] == "closing"))
                assert :ok = Loopex.stop(fixture.runtime)
                join_actors(runtime_monitors)
                actors = [fixture.model, fixture.executor, fixture.store]
                actor_monitors = monitor_actors(actors)
                Enum.each(actors, &GenServer.stop(&1, :normal))
                join_actors(actor_monitors)
                send(test, {tag, :joined})
                result
              end,
              install_signal: fn driver, _, _, nil ->
                assert_receive {^tag, :runtime, fixture, consumer}, 0
                runtime = fixture.runtime
                assert Loopex.AgentLoopTestModel.dispatched(fixture.model) == []
                state = :sys.get_state(driver)
                assert state.startup == :ready
                assert MapSet.size(state.ready) == 2
                assert state.input_worker == nil and state.reader_busy == false
                assert state.cursor == 0 and state.sequence == 0
                assert StringIO.contents(f.input) == {"one\n/wait\ntwo\n/wait\n/quit\n", ""}

                assert state.configuration.selection.profile["trace"] ==
                         Map.put(trace, "enabled", enabled)

                assert state.configuration.selection.origins["/trace/enabled"] == origin

                if enabled do
                  assert {:ok,
                          %{
                            modules: [Loopex.Runtime.SessionCoordinator],
                            level: :returns,
                            sink: :diagnostics,
                            limits: %{
                              entry_bytes: 1024,
                              entries_per_second: 1000,
                              queued: 256
                            }
                          }} = Loopex.trace_status(runtime)
                else
                  assert {:error, :no_trace_session} = Loopex.trace_status(runtime)
                end

                assert_receive {:first_diagnostic_writer, ^device, writer}, 5_000

                {:ok, diagnostic_actors} =
                  LoopexComposition.DiagnosticConsumer.owned_processes(consumer)

                assert writer in diagnostic_actors
                send(self(), {tag, :diagnostic_monitors, monitor_actors(diagnostic_actors)})
                send(test, {tag, :ready, driver, state.writer, diagnostic_actors})
                send(device, :release)
                {:ok, self()}
              end,
              finish_signal: fn _, _ -> {:ok, :ordinary} end
            ]

        send(test, {tag, :result, Chat.run(["chat", "--config", f.path] ++ flags, opts)})
      end)

    on_exit(fn -> if Process.alive?(host), do: Process.exit(host, :kill) end)
    send(device, {:owner, host})
    assert_receive {^tag, :fixture, fixture}, 5_000

    on_exit(fn ->
      Fixture.stop(fixture)

      Enum.each([fixture.model, fixture.executor], fn actor ->
        if Process.alive?(actor), do: GenServer.stop(actor, :normal)
      end)
    end)

    assert_receive {^tag, :ready, driver, output_writer, diagnostic_actors}, 5_000
    output_monitors = monitor_actors([driver, output_writer])
    assert_receive {:holding, model}, 5_000
    model_monitor = Process.monitor(model)
    if enabled, do: await_trace_delivery(device, System.monotonic_time(:millisecond) + 5000)
    send(model, :release)
    assert_receive {:DOWN, ^model_monitor, :process, ^model, _}, 5_000
    assert_receive {^tag, :joined}, 5_000
    assert_receive {^tag, :result, 0}, 5_000
    assert_receive {:DOWN, ^host_monitor, :process, ^host, :normal}, 5_000
    join_actors(output_monitors)
    Enum.each(diagnostic_actors, &refute(Process.alive?(&1)))
    controls = controls(f.output)
    assert List.last(controls)["cleanup"] == "confirmed"
    assert List.last(controls)["exit_code"] == 0
    assert List.last(controls)["last_outcome"]["outcome"] == "completed"
    {"", report} = StringIO.contents(f.diagnostic)

    if enabled do
      assert report =~ "trace_call"
      assert report =~ "Loopex.Runtime.SessionCoordinator"
    else
      refute report =~ "trace_call"
      refute report =~ "trace_dropped"
    end

    refute report =~ "M7_WORKFLOW_SLOT"
    {_, transcript} = StringIO.contents(f.output)
    refute transcript =~ "trace_call"
    device_monitor = Process.monitor(device)
    Process.exit(device, :kill)
    assert_receive {:DOWN, ^device_monitor, :process, ^device, :killed}, 5_000
    io_monitors = monitor_actors([f.input, f.output, f.diagnostic])
    Enum.each([f.input, f.output, f.diagnostic], &GenServer.stop(&1, :normal))
    join_actors(io_monitors)
  end

  defp trace_device(output, test) do
    receive do
      {:owner, owner} ->
        receive do
          {:io_request, writer, reply, request} ->
            send(owner, {:first_diagnostic_writer, self(), writer})
            receive do: (:release -> :ok)
            deliver_trace_bytes(output, test, writer, reply, request)
            forward_trace_bytes(output, test)
        end
    end
  end

  defp forward_trace_bytes(output, test) do
    receive do
      {:io_request, writer, reply, request} ->
        deliver_trace_bytes(output, test, writer, reply, request)
        forward_trace_bytes(output, test)
    end
  end

  defp deliver_trace_bytes(output, test, writer, reply, {:put_chars, _, bytes} = request) do
    ref = make_ref()
    send(output, {:io_request, self(), ref, request})

    receive do
      {:io_reply, ^ref, result} ->
        send(writer, {:io_reply, reply, result})
        send(test, {:diagnostic_delivered, self(), IO.iodata_to_binary(bytes)})
    end
  end

  defp await_trace_delivery(device, deadline) do
    receive do
      {:diagnostic_delivered, ^device, bytes} ->
        unless bytes =~ "trace_call", do: await_trace_delivery(device, deadline)
    after
      max(deadline - System.monotonic_time(:millisecond), 0) ->
        flunk("actual trace bytes were not delivered")
    end
  end

  defp monitor_actors(pids), do: Enum.map(pids, &{&1, Process.monitor(&1)})

  defp join_actors(monitors) do
    for {pid, reference} <- monitors do
      assert_receive {:DOWN, ^reference, :process, ^pid, _}, 5_000
      refute Process.alive?(pid)
    end
  end

  defp fixture(f, script) do
    fixture =
      Fixture.start(
        script: script,
        tools: [],
        model: f.prepared.selection.configuration["model"],
        runtime_id: "chat-workflow-runtime",
        cleanup_grace_ms: f.prepared.selection.profile["session"]["cleanup_grace_ms"]
      )

    on_exit(fn -> Fixture.stop(fixture) end)
    fixture
  end

  defp basic(f),
    do: [
      cwd: f.root,
      home: nil,
      input: f.input,
      output: f.output,
      diagnostic_device: f.diagnostic,
      mode: :pipe
    ]

  defp options(f, fixture, cleanup \\ :confirmed) do
    basic(f) ++
      [
        acquire_placement: fn _, probe ->
          assert is_function(probe, 1)
          {:ok, "test-placement"}
        end,
        release_placement: fn "test-placement", _ ->
          refute Enum.any?(controls(f.output), &(&1["event"] == "closing"))
          :ok
        end,
        placement_id: fn _ -> {:ok, "chat-workflow-runtime"} end,
        with_runtime: fn options, callback ->
          assert options[:provider_bindings] == f.profile["providers"]
          assert options[:active_tools] == []
          result = callback.(fixture.runtime)
          refute Enum.any?(controls(f.output), &(&1["event"] == "closing"))
          assert :ok == Loopex.stop(fixture.runtime)

          if cleanup == :unconfirmed,
            do: {:error, {:composition_cleanup_unconfirmed, %{runtime: :unconfirmed}}},
            else: result
        end,
        install_signal: fn _, _, _, _ ->
          assert StringIO.contents(f.input) == {"one\n/wait\ntwo\n/wait\n/quit\n", ""}
          {:ok, self()}
        end,
        finish_signal: fn _, _ -> {:ok, :ordinary} end
      ]
  end

  defp isolated_signal_manager do
    original = Process.whereis(:erl_signal_server)
    {:ok, manager} = :gen_event.start()
    :ok = :gen_event.add_handler(manager, :erl_signal_handler, [])
    Process.unregister(:erl_signal_server)
    true = Process.register(manager, :erl_signal_server)

    on_exit(fn ->
      if Process.whereis(:erl_signal_server) == manager,
        do: Process.unregister(:erl_signal_server)

      if Process.alive?(manager), do: :gen_event.stop(manager)

      if is_pid(original) and Process.alive?(original),
        do: Process.register(original, :erl_signal_server)
    end)
  end

  defp await_terminal(attachment, deadline) do
    case Loopex.next_event(attachment) do
      {:ok, %{kind: "run.finished"} = event} ->
        event

      _ ->
        if System.monotonic_time(:millisecond) >= deadline,
          do: flunk("first prompt did not settle")

        Process.sleep(1)
        await_terminal(attachment, deadline)
    end
  end

  defp controls(output) do
    {_, transcript} = StringIO.contents(output)
    for "@loopex " <> json <- String.split(transcript, "\n"), do: :json.decode(json)
  end
end
