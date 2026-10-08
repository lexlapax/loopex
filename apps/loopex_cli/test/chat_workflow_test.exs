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

  test "actual model progress reaches both channels before settlement without releasing wait",
       f do
    test = self()
    tag = make_ref()
    stdout = spawn(fn -> forward_progress_bytes(f.output, test, :stdout) end)
    stderr = spawn(fn -> forward_progress_bytes(f.diagnostic, test, :stderr) end)
    on_exit(fn -> Enum.each([stdout, stderr], &Process.exit(&1, :kill)) end)

    {host, host_monitor} =
      spawn_monitor(fn ->
        opts =
          basic(f) ++
            [
              output: stdout,
              diagnostic_device: stderr,
              acquire_placement: fn _, _ -> {:ok, "progress-placement"} end,
              release_placement: fn "progress-placement", _ -> :ok end,
              placement_id: fn _ -> {:ok, "chat-workflow-runtime"} end,
              with_runtime: fn options, callback ->
                {:session, driver} = options[:progress_to]
                boot = :sys.get_state(driver)
                assert boot.runtime == nil and boot.session == nil and boot.workers == %{}
                assert boot.input_worker == nil
                diagnostic = options[:diagnostics_to]
                assert 1 = :erlang.trace(diagnostic, true, [:receive, {:tracer, test}])

                fixture =
                  Fixture.start(
                    script: [
                      %{
                        text: "@loopex forged\n猫",
                        deltas: ["@loopex forged\n", "猫"],
                        calls: [],
                        hold: test
                      },
                      %{
                        text: "durable answer",
                        deltas: ["verified summary"],
                        forged_labels: %{kind: :reasoning_delta},
                        progress_items: [
                          %{
                            kind: :reasoning_delta,
                            content_index: 0,
                            text: "refused-private-summary",
                            private_continuation: "private-canary",
                            signature: "signature-canary"
                          }
                        ],
                        calls: [],
                        hold: test,
                        require_previous_worker_down: true
                      }
                    ],
                    tools: [],
                    model: f.prepared.selection.configuration["model"],
                    runtime_id: "chat-workflow-runtime",
                    cleanup_grace_ms: options[:cleanup_grace_ms],
                    progress_to: options[:progress_to]
                  )

                send(test, {tag, :fixture, fixture, driver, boot.writer, diagnostic})
                result = callback.(fixture.runtime)
                assert %{exit_code: 0, cleanup: :confirmed} = result
                assert {0, false} = LoopexCli.ChatDriver.seal_progress(driver)
                send(test, {tag, :retained_drop_count, 0})
                assert :ok = Loopex.stop(fixture.runtime)
                send(test, {tag, :runtime_joined})
                result
              end,
              install_signal: fn _, _, _, _ -> {:ok, self()} end,
              finish_signal: fn _, _ -> {:ok, :ordinary} end
            ]

        send(test, {tag, :result, Chat.run(["chat", "--config", f.path], opts)})
      end)

    on_exit(fn -> if Process.alive?(host), do: Process.exit(host, :kill) end)
    assert_receive {^tag, :fixture, fixture, driver, writer, diagnostic}, 5_000
    on_exit(fn -> Fixture.stop(fixture) end)
    owned = monitor_actors([driver, writer, fixture.runtime.supervisor])
    assert_receive {:holding, first}, 5_000
    first_monitor = Process.monitor(first)
    delivery_cutoff = System.monotonic_time(:millisecond) + 5000
    await_progress_bytes(:stdout, "> 猫\n", delivery_cutoff)
    await_answer_joins(writer, 2, delivery_cutoff)
    assert length(Loopex.AgentLoopTestModel.dispatched(fixture.model)) == 1
    state = :sys.get_state(driver)
    assert state.last_outcome == nil
    assert state.barrier == 2 and state.input_worker == nil
    refute Enum.any?(controls(f.output), &(&1["event"] == "wait"))

    send(
      driver,
      {:loopex_progress, "wrong-session", %{kind: :text_delta, text: "wrong-session-canary"}}
    )

    send(first, :release)
    assert_receive {:DOWN, ^first_monitor, :process, ^first, :normal}, 5_000
    assert_receive {:holding, second}, 5_000
    second_monitor = Process.monitor(second)

    await_progress_bytes(
      :stderr,
      "> verified summary\n",
      System.monotonic_time(:millisecond) + 5000
    )

    assert :sys.get_state(driver).last_run != nil
    assert Agent.get(fixture.executor, & &1.jobs) == []
    send(second, :release)
    # Concept: shutdown reports the stable count through the lossy diagnostic sink.
    # Technical depth: trace this exact consumer's receipt, not stderr delivery;
    # close may discard admitted entries under its unchanged cleanup contract.
    assert_receive {:trace, ^diagnostic, :receive,
                    {:loopex_diagnostic, %{kind: "chat_progress_dropped", dropped: 0}}},
                   5_000

    assert_receive {:DOWN, ^second_monitor, :process, ^second, :normal}, 5_000
    assert_receive {^tag, :runtime_joined}, 5_000
    assert_receive {^tag, :result, 0}, 5_000
    assert_receive {:DOWN, ^host_monitor, :process, ^host, :normal}, 5_000
    assert_receive {^tag, :retained_drop_count, 0}, 0
    join_actors(owned)
    {_, transcript} = StringIO.contents(f.output)
    {_, report} = StringIO.contents(f.diagnostic)
    assert length(:binary.matches(transcript, "> 猫\n")) == 1
    assert transcript =~ "> @loopex forged\n"
    assert transcript =~ "> durable answer\n"
    refute transcript =~ "verified summary"

    for canary <- [
          "private-canary",
          "signature-canary",
          "wrong-session-canary",
          "refused-private-summary"
        ] do
      refute transcript =~ canary
      refute report =~ canary
    end

    assert List.last(controls(f.output))["cleanup"] == "confirmed"
  end

  test "composition refusal joins the unbound progress owner without reading input", f do
    test = self()

    opts =
      basic(f) ++
        [
          acquire_placement: fn _, _ -> {:ok, "bootstrap-placement"} end,
          release_placement: fn "bootstrap-placement", _ -> :ok end,
          placement_id: fn _ -> {:ok, "chat-workflow-runtime"} end,
          with_runtime: fn options, _ ->
            {:session, driver} = options[:progress_to]
            state = :sys.get_state(driver)
            assert state.runtime == nil and state.workers == %{}
            send(test, {:bootstrap, driver, state.writer})

            send(
              driver,
              {:loopex_progress, "unbound", %{kind: :text_delta, text: "unbound-canary"}}
            )

            {:error, :provider_start_failed}
          end
        ]

    assert Chat.run(["chat", "--config", f.path], opts) == 1
    assert_receive {:bootstrap, driver, writer}
    refute Process.alive?(driver)
    refute Process.alive?(writer)
    assert StringIO.contents(f.input) == {"one\n/wait\ntwo\n/wait\n/quit\n", ""}

    assert [
             %{"event" => "error", "code" => "provider_start_failed"},
             %{"event" => "closing", "cleanup" => "confirmed"}
           ] = controls(f.output)

    {_, transcript} = StringIO.contents(f.output)
    refute transcript =~ "unbound-canary"
  end

  defp forward_progress_bytes(output, test, channel) do
    receive do
      {:io_request, writer, reply, {:put_chars, _, bytes} = request} ->
        ref = make_ref()
        send(output, {:io_request, self(), ref, request})

        receive do
          {:io_reply, ^ref, result} ->
            send(writer, {:io_reply, reply, result})
            send(test, {:progress_delivered, channel, IO.iodata_to_binary(bytes)})
        end

        forward_progress_bytes(output, test, channel)
    end
  end

  defp await_progress_bytes(channel, target, deadline) do
    receive do
      {:progress_delivered, ^channel, bytes} ->
        unless bytes == target, do: await_progress_bytes(channel, target, deadline)
    after
      max(deadline - System.monotonic_time(:millisecond), 0) ->
        flunk("actual progress not delivered")
    end
  end

  # Concept: duplicate suppression needs joined writes, not a forwarded IO reply.
  # Technical depth: observe the writer's actual per-domain delivery certificate
  # before releasing the held Model callback. Both observations spend one
  # original fixture cutoff; the test creates no additional wait allowance.
  defp await_answer_joins(writer, count, deadline) do
    receipts = :sys.get_state(writer).progress_delivery

    if Map.values(receipts) == [%{admitted: count, delivered: count, dropped: 0}] do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline,
        do: flunk("actual answer IO workers were not joined")

      Process.sleep(1)
      await_answer_joins(writer, count, deadline)
    end
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

  test "resumed installer refusal and exceptions abandon before outer runtime teardown", f do
    Enum.reduce([:refuse, :raise, :throw, :exit], [], fn fault, capabilities ->
      capability = resumed_startup_failure(f, fault)
      refute capability in capabilities
      [capability | capabilities]
    end)
  end

  test "actual guarded resume transfer loss retains unknown cleanup before outer teardown", f do
    assert is_reference(resumed_startup_failure(f, :guard_loss))
  end

  # Concept: each startup fault owns a fresh prepared capability and disposable
  # root, whose deletion requires the original actors' positive DOWN joins.
  # Technical depth: the callback observation precedes outer runtime stop. A
  # native guard loss spends one captured five-second endpoint and returns the
  # actual transfer result; no installer result or owner verdict is fabricated.
  defp resumed_startup_failure(f, fault) do
    tag = make_ref()

    Process.put(tag, %{
      root: nil,
      fixture: nil,
      actors: [],
      capture: nil,
      observation_failure: nil
    })

    try do
      bound = resumed_startup_context(f, tag)

      fixture =
        Fixture.start(
          script: [],
          tools: [],
          model: bound.prepared.selection.configuration["model"],
          runtime_id: "chat-workflow-runtime",
          cleanup_grace_ms: bound.prepared.selection.profile["session"]["cleanup_grace_ms"]
        )

      Process.put(tag, %{Process.get(tag) | fixture: fixture})

      resumed_capture_actors(tag, [
        fixture.runtime.supervisor,
        fixture.store,
        fixture.model,
        fixture.executor
      ])

      {:ok, children} = Loopex.Runtime.children(fixture.runtime)
      resumed_capture_actors(tag, Map.values(children))

      assert {:ok, session} =
               Loopex.create_session(fixture.runtime, bound.prepared.session_options,
                 command_id: "create-resume-startup-fault",
                 genesis: bound.prepared.genesis
               )

      assert :ok =
               Loopex.track_session(
                 Path.join(bound.root, "state"),
                 session,
                 "chat-workflow-runtime"
               )

      opts =
        options(bound, fixture)
        |> Keyword.put(:install_signal, fn driver, _, _, activation ->
          assert %Loopex.ResumeActivation{} = activation
          assert {:ok, retained} = Loopex.prepared_session_configuration(activation)
          assert retained.configuration == bound.prepared.selection.configuration
          assert retained.tool_selection == bound.prepared.genesis["tool_selection"]

          assert retained.cleanup_grace_ms ==
                   bound.prepared.selection.profile["session"]["cleanup_grace_ms"]

          state = :sys.get_state(driver)
          assert state.startup == :ready
          assert state.input_worker == nil

          assert Enum.sort(Enum.map(state.workers, fn {_, worker} -> worker.kind end)) ==
                   [:command, :reader]

          workers = Map.keys(state.workers)
          resumed_capture_actors(tag, [activation.coordinator, driver, state.writer | workers])

          capture = %{
            activation: activation,
            driver: driver,
            writer: state.writer,
            workers: workers,
            records: Fixture.records(fixture, session),
            events: Fixture.events(fixture, session),
            observed_before_stop: false,
            outer_joined: false,
            deadline: System.monotonic_time(:millisecond) + 5_000
          }

          Process.put(tag, %{Process.get(tag) | capture: capture})

          case fault do
            :refuse -> {:error, :interrupt_handler_unavailable}
            :raise -> raise "private resumed installer failure"
            :throw -> throw(:private_resumed_installer_failure)
            :exit -> exit(:private_resumed_installer_failure)
            :guard_loss -> resumed_guard_loss(tag, activation, capture.deadline)
          end
        end)
        |> Keyword.put(:with_runtime, fn _, callback ->
          try do
            result = callback.(fixture.runtime)
            capture = Process.get(tag).capture
            assert is_map(capture)
            assert Process.alive?(fixture.runtime.supervisor)
            assert Process.alive?(capture.activation.coordinator)
            assert Process.alive?(capture.driver)

            assert {:error, :resume_activation_abandoned} =
                     Loopex.prepared_session_configuration(capture.activation)

            assert {:error, :resume_activation_abandoned} =
                     Loopex.activate_resume(capture.activation)

            assert Fixture.records(fixture, session) == capture.records
            assert Fixture.events(fixture, session) == capture.events
            assert Loopex.AgentLoopTestModel.dispatched(fixture.model) == []
            assert Agent.get(fixture.executor, & &1.jobs) == []
            assert StringIO.contents(bound.input) == {"must remain unread\n/quit\n", ""}
            refute Enum.any?(controls(bound.output), &(&1["event"] == "closing"))
            resumed_join_actors(tag, capture.workers, capture.deadline)

            if fault == :guard_loss do
              assert capture.native_transfer_result == {:unresolved, :resume_handoff_unresolved}
              %{guard: guard, holder: holder, nonce: nonce} = capture.handoff

              assert_receive {^tag, :committed_before_guard_loss, ^guard, ^holder, ^nonce,
                              handoff, prepare, commit},
                             max(capture.deadline - System.monotonic_time(:millisecond), 0)

              assert is_reference(handoff) and is_reference(prepare) and is_reference(commit)
              reasons = resumed_join_actors(tag, [guard, holder], capture.deadline)
              assert reasons[guard] == :resume_fixture_guard_lost_before_ack
              assert reasons[holder] in [:resume_fixture_guard_lost_before_ack, :killed]
            end

            # Concept: guarded host callbacks can convert a failed assertion into
            # a startup refusal. The outer test therefore requires both positive
            # observations before it can accept that refusal as proof.
            # Technical depth: mark this cut before stop and the original joins
            # afterwards; the independent assertions run outside Chat.run/2.
            state = Process.get(tag)

            Process.put(tag, %{
              state
              | capture: Map.put(state.capture, :observed_before_stop, true)
            })

            assert :ok == Loopex.stop(fixture.runtime)

            resumed_join_actors(
              tag,
              [fixture.runtime.supervisor, capture.activation.coordinator | Map.values(children)],
              capture.deadline
            )

            state = Process.get(tag)
            Process.put(tag, %{state | capture: Map.put(state.capture, :outer_joined, true)})
            result
          catch
            kind, reason ->
              stacktrace = __STACKTRACE__
              state = Process.get(tag)

              Process.put(tag, %{
                state
                | observation_failure: {kind, reason, stacktrace}
              })

              :erlang.raise(kind, reason, stacktrace)
          end
        end)

      result = Chat.run(["chat", "--config", bound.path, "--resume", session], opts)

      # Concept: retain assertion failures outside the guarded host callback.
      # Technical depth: rethrow the original class, reason and stack before a
      # startup refusal can be accepted as this fixture's positive proof.
      case Process.get(tag).observation_failure do
        nil -> :ok
        {kind, reason, stacktrace} -> :erlang.raise(kind, reason, stacktrace)
      end

      assert result == 1
      capture = Process.get(tag).capture
      assert capture.observed_before_stop
      assert capture.outer_joined

      assert resumed_join_actors(tag, [capture.driver, capture.writer], capture.deadline) ==
               %{capture.driver => :normal, capture.writer => :normal}

      assert StringIO.contents(bound.input) == {"must remain unread\n/quit\n", ""}
      assert Loopex.AgentLoopTestModel.dispatched(fixture.model) == []
      assert Agent.get(fixture.executor, & &1.jobs) == []
      records = controls(bound.output)
      assert Enum.count(records, &(&1["event"] == "closing")) == 1
      assert List.last(records)["exit_code"] == 1

      assert List.last(records)["cleanup"] ==
               if(fault == :guard_loss, do: "unknown", else: "confirmed")

      {_, transcript} = StringIO.contents(bound.output)
      refute transcript =~ "private resumed installer failure"
      refute transcript =~ "private_resumed_installer_failure"
      capture.activation.capability
    after
      resumed_cleanup_fixture(tag)
    end
  end

  defp resumed_startup_context(f, tag) do
    root =
      Path.join(System.tmp_dir!(), "chat-resume-startup-#{System.unique_integer([:positive])}")

    Process.put(tag, %{Process.get(tag) | root: root})
    File.mkdir_p!(Path.join(root, "workspace"))
    File.mkdir!(Path.join(root, "state"))
    path = Path.join(root, "config.json")
    File.write!(path, :json.encode(f.profile))
    assert {:ok, prepared} = ChatConfiguration.load(["chat", "--config", path], root, nil)
    assert {:ok, input} = StringIO.open("must remain unread\n/quit\n", encoding: :latin1)
    resumed_capture_actors(tag, [input])
    assert {:ok, output} = StringIO.open("", encoding: :latin1)
    resumed_capture_actors(tag, [output])
    assert {:ok, diagnostic} = StringIO.open("", encoding: :latin1)
    resumed_capture_actors(tag, [diagnostic])

    %{
      f
      | root: root,
        path: path,
        prepared: prepared,
        input: input,
        output: output,
        diagnostic: diagnostic
    }
  end

  defp resumed_guard_loss(tag, activation, deadline) do
    installer = self()
    coordinator = activation.coordinator
    nonce = make_ref()

    {guard, guard_monitor} =
      spawn_monitor(fn ->
        installer_monitor = Process.monitor(installer)
        coordinator_monitor = Process.monitor(coordinator)

        holder =
          spawn_link(fn ->
            receive do
              :stop -> :ok
            after
              max(deadline - System.monotonic_time(:millisecond), 0) ->
                exit(:resume_fixture_holder_deadline)
            end
          end)

        holder_monitor = Process.monitor(holder)
        send(installer, {tag, :guard_ready, self(), holder})

        receive do
          {^tag, :participants_captured} ->
            resumed_transfer_guard(
              installer,
              coordinator,
              holder,
              nonce,
              tag,
              deadline,
              [installer_monitor, coordinator_monitor, holder_monitor],
              nil,
              nil
            )
        after
          max(deadline - System.monotonic_time(:millisecond), 0) ->
            exit(:resume_fixture_guard_deadline)
        end
      end)

    state = Process.get(tag)
    Process.put(tag, %{state | actors: [{guard, guard_monitor} | state.actors]})

    assert_receive {^tag, :guard_ready, ^guard, holder},
                   max(deadline - System.monotonic_time(:millisecond), 0)

    resumed_capture_actors(tag, [holder])
    assert Process.alive?(guard) and Process.alive?(holder)
    assert {:monitors, originals} = Process.info(guard, :monitors)

    assert MapSet.new(originals) ==
             MapSet.new([{:process, installer}, {:process, coordinator}, {:process, holder}])

    assert {:links, links} = Process.info(holder, :links)
    assert guard in links
    capture = Process.get(tag).capture
    handoff = %{guard: guard, holder: holder, nonce: nonce}
    Process.put(tag, %{Process.get(tag) | capture: Map.put(capture, :handoff, handoff)})
    send(guard, {tag, :participants_captured})
    result = Loopex.transfer_resume(activation, holder, {guard, nonce})
    assert result == {:unresolved, :resume_handoff_unresolved}
    state = Process.get(tag)
    Process.put(tag, %{state | capture: Map.put(state.capture, :native_transfer_result, result)})
    result
  end

  defp resumed_transfer_guard(
         installer,
         coordinator,
         holder,
         nonce,
         tag,
         deadline,
         monitors,
         pending,
         prepared
       ) do
    [installer_monitor, coordinator_monitor, holder_monitor] = monitors

    case {pending, prepared} do
      {handoff, {handoff, prepare}} when is_reference(handoff) and is_reference(prepare) ->
        send(
          coordinator,
          {:loopex_prepared_transfer_guard_ready, self(), holder, nonce, handoff, prepare}
        )

        receive do
          {:loopex_prepared_owner_verdict, ^coordinator, ^holder, ^nonce, ^handoff, commit,
           :committed}
          when is_reference(commit) ->
            send(
              installer,
              {tag, :committed_before_guard_loss, self(), holder, nonce, handoff, prepare, commit}
            )

            exit(:resume_fixture_guard_lost_before_ack)

          {:DOWN, monitor, :process, _, _}
          when monitor == installer_monitor or monitor == coordinator_monitor or
                 monitor == holder_monitor ->
            exit(:resume_fixture_participant_lost)
        after
          max(deadline - System.monotonic_time(:millisecond), 0) ->
            exit(:resume_fixture_guard_deadline)
        end

      _ ->
        receive do
          {:loopex_prepared_transfer_pending, ^installer, ^coordinator, ^holder, ^nonce, handoff}
          when is_reference(handoff) and pending == nil ->
            resumed_transfer_guard(
              installer,
              coordinator,
              holder,
              nonce,
              tag,
              deadline,
              monitors,
              handoff,
              prepared
            )

          {:loopex_prepared_owner_prepare, ^coordinator, ^holder, ^nonce, handoff, prepare}
          when is_reference(handoff) and is_reference(prepare) and prepared == nil ->
            resumed_transfer_guard(
              installer,
              coordinator,
              holder,
              nonce,
              tag,
              deadline,
              monitors,
              pending,
              {handoff, prepare}
            )

          {:DOWN, monitor, :process, _, _}
          when monitor == installer_monitor or monitor == coordinator_monitor or
                 monitor == holder_monitor ->
            exit(:resume_fixture_participant_lost)
        after
          max(deadline - System.monotonic_time(:millisecond), 0) ->
            exit(:resume_fixture_guard_deadline)
        end
    end
  end

  defp resumed_capture_actors(tag, pids) do
    state = Process.get(tag)
    captured = Enum.map(state.actors, &elem(&1, 0))
    fresh = Enum.uniq(pids) -- captured
    Enum.each(fresh, &Process.unlink/1)
    Process.put(tag, %{state | actors: monitor_actors(fresh) ++ state.actors})
  end

  defp resumed_join_actors(tag, pids, deadline) do
    joined =
      for {pid, reference} <- Process.get(tag).actors, pid in pids do
        assert_receive {:DOWN, ^reference, :process, ^pid, reason},
                       max(deadline - System.monotonic_time(:millisecond), 0)

        refute Process.alive?(pid)
        state = Process.get(tag)
        Process.put(tag, %{state | actors: List.keydelete(state.actors, pid, 0)})
        {pid, reason}
      end

    Map.new(joined)
  end

  defp resumed_cleanup_fixture(tag) do
    state = Process.get(tag)
    deadline = System.monotonic_time(:millisecond) + 5_000
    if state.fixture != nil, do: Fixture.stop(state.fixture)

    for {pid, _} <- Process.get(tag).actors do
      if Process.alive?(pid), do: Process.exit(pid, :kill)
    end

    resumed_join_actors(tag, Enum.map(Process.get(tag).actors, &elem(&1, 0)), deadline)
    assert Process.get(tag).actors == []
    if state.root != nil, do: File.rm_rf!(state.root)
    Process.delete(tag)
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
