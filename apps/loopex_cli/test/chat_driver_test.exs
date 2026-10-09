Code.require_file("../../loopex/test/support/m1_runtime_helper.exs", __DIR__)
Code.require_file("../../loopex/test/support/agent_loop_helper.exs", __DIR__)
Code.require_file("../../loopex/test/support/configured_genesis_helper.exs", __DIR__)

Code.require_file("support/recording_output_target.exs", __DIR__)

defmodule LoopexCli.ChatDriverTest do
  use ExUnit.Case, async: false
  alias LoopexCli.Test.RecordingOutputTarget
  alias LoopexCli.Output.Memory
  @moduletag capture_log: true
  alias LoopexCli.ChatDriver
  alias Loopex.AgentLoopFixture, as: Fixture

  for disposition <- [:unchanged, :checkpointed, :failed] do
    @compact_disposition disposition
    test "literal /compact reports #{@compact_disposition} through actual public completion and status" do
      assert_compact_disposition(@compact_disposition)
    end
  end

  defp assert_compact_disposition(disposition) do
    prepared = prepared_configuration()
    configuration = prepared.selection.configuration

    maintenance = %{
      "model" => configuration["model"],
      "reasoning" => "none",
      "model_capabilities" => %{
        configuration["model_capabilities"]
        | "reasoning_levels" => ["none", "default"]
      },
      "provider_mapping" => Map.put(configuration["provider_mapping"], "thinking_disabled", true)
    }

    options =
      if disposition == :checkpointed,
        do: [
          maintenance_model: maintenance,
          maintenance_instructions: %{"version" => "summary.v1", "body" => "Keep facts"}
        ],
        else: []

    script =
      if disposition == :unchanged,
        do: [],
        else: [%{text: String.duplicate("retained fact ", 400), calls: []}]

    script =
      if disposition == :checkpointed,
        do:
          script ++
            [
              %{
                text:
                  ~s({"summary":"retain this fact","carry_forward":{"files_read":[],"files_changed":[]}}),
                calls: [],
                reply_overrides: %{completion: "natural", continuation: nil}
              }
            ],
        else: script

    fixture = start_fixture(script, [model: configuration["model"]] ++ options)

    {:ok, session} =
      Loopex.create_session(fixture.runtime, prepared.session_options,
        command_id: "create",
        genesis: prepared.genesis
      )

    prefix = if disposition == :unchanged, do: "", else: "remember\n/wait\n"

    {:ok, input} =
      StringIO.open(prefix <> "/compact\n/wait\n/status\n/quit\n", encoding: :latin1)

    {:ok, output} = Memory.start()
    test = self()

    facade = fn module, function, arguments ->
      if function == :command and match?([_, %{type: :compact}], arguments),
        do: send(test, {:literal_compact, List.last(arguments)})

      apply(module, function, arguments)
    end

    {host, driver} =
      start_host(fixture.runtime, session, input, output,
        configuration: prepared,
        facade: facade
      )

    expected_exit = if disposition == :failed, do: 1, else: 0

    assert_receive {:provisional, ^host, %{exit_code: ^expected_exit, cleanup: :confirmed}},
                   5_000

    assert_receive {:literal_compact, command}

    assert command.bounds == %{
             "max_attempts" => 4,
             "deadline_ms" => 60_000,
             "token_budget" => 32_768
           }

    completion =
      Enum.find(Fixture.events(fixture, session), &(&1.kind == "context.compaction_finished"))

    assert completion["command_id"] == command.command_id
    assert completion["result"]["disposition"] == Atom.to_string(disposition)
    assert completion["result"]["cleanup"] == "confirmed"
    {transcript, _} = Memory.contents(output)
    rows = records(transcript)
    status = Enum.find(rows, &(&1["event"] == "status"))
    last = status["maintenance"]["last_compact"]
    assert last["command_id"] == Base.url_encode64(command.command_id, padding: false)
    assert last["episode_id"] == Base.url_encode64(completion["episode_id"], padding: false)
    assert last["result"]["disposition"] == Atom.to_string(disposition)
    refute Map.has_key?(last, "run_id")
    refute Map.has_key?(last, "outcome")
    assert status["maintenance"]["active_model"] == nil

    assert byte_position(transcript, "Compaction bounds:") <
             byte_position(transcript, "Compaction result:")

    assert byte_position(transcript, "Compaction bounds:") <
             byte_position(transcript, ~s("command_id":"#{last["command_id"]}"))

    acks = Enum.filter(rows, &(&1["event"] == "input"))

    assert Enum.find(acks, &(&1["command_id"] == last["command_id"]))["disposition"] ==
             "admitted"

    waits = Enum.filter(rows, &(&1["event"] == "wait"))
    assert List.last(waits)["state"] == "settled"

    if disposition == :unchanged,
      do: assert(List.last(waits)["outcome"] == nil),
      else: assert(List.last(waits)["outcome"]["outcome"] == "completed")

    expected_runs = if disposition == :unchanged, do: 0, else: 1

    assert Enum.count(Fixture.events(fixture, session), &(&1.kind == "run.finished")) ==
             expected_runs

    assert Agent.get(fixture.executor, & &1.jobs) == []
    assert :sys.get_state(driver).compact_commands == MapSet.new()
    assert :sys.get_state(driver).workers == %{}
    close_host_and_fixture(fixture, host, driver, expected_exit)
    {closed, _} = Memory.contents(output)
    closing = Enum.find(records(closed), &(&1["event"] == "closing"))
    assert closing["exit_code"] == expected_exit

    if disposition == :unchanged,
      do: assert(closing["last_outcome"] == nil),
      else: assert(closing["last_outcome"]["outcome"] == "completed")

    stop_devices([input, output], :gen_server)
  end

  test "literal /compact refuses active work and aborts without a maintenance result" do
    fixture = start_fixture([%{text: "must not publish", calls: [], hold: self()}])
    {:ok, session} = Loopex.create_session(fixture.runtime, %{}, command_id: "create")
    input = pipe_input("one\n")
    output = observing_output()
    {host, driver} = start_host(fixture.runtime, session, input, output)
    assert_receive {:holding, callback}, 5_000
    callback_monitor = Process.monitor(callback)
    send(input, {:bytes, "/compact\n"})
    assert_receive {:provisional, ^host, %{exit_code: 1, cleanup: :confirmed}}, 5_000
    assert_receive {:DOWN, ^callback_monitor, :process, ^callback, _}, 5_000
    refusal = await_record(&(&1["event"] == "input" and &1["input_sequence"] == "2"))
    assert refusal["disposition"] == "refused"
    assert refusal["code"] == "run_active"

    refute Enum.any?(
             Fixture.events(fixture, session),
             &(&1.kind == "context.compaction_finished")
           )

    assert :sys.get_state(driver).last_compact == nil
    assert :sys.get_state(driver).compact_commands == MapSet.new()
    close_host_and_fixture(fixture, host, driver, 1)
    stop_devices([input, output])
  end

  test "a replayed historical compact failure is visible without failing this invocation" do
    prepared = prepared_configuration()

    fixture =
      start_fixture([%{text: "retained fact", calls: []}],
        model: prepared.selection.configuration["model"]
      )

    {:ok, session} =
      Loopex.create_session(fixture.runtime, prepared.session_options,
        command_id: "create",
        genesis: prepared.genesis
      )

    {:ok, first_input} = StringIO.open("one\n/wait\n/compact\n/wait\n/quit\n", encoding: :latin1)
    {:ok, first_output} = Memory.start()

    {first_host, first_driver} =
      start_host(fixture.runtime, session, first_input, first_output, configuration: prepared)

    assert_receive {:provisional, ^first_host, %{exit_code: 1, cleanup: :confirmed}}, 5_000
    first_writer = elem(:sys.get_state(first_driver).output, 1)
    monitors = monitor_processes([first_host, first_driver, first_writer])
    send(first_host, {:close, :confirmed})
    assert_receive {:closed, ^first_host, 1}, 5_000
    assert_processes_joined(monitors)

    completion =
      Enum.find(Fixture.events(fixture, session), &(&1.kind == "context.compaction_finished"))

    assert completion["result"]["disposition"] == "failed"
    {:ok, input} = StringIO.open("/status\n/quit\n", encoding: :latin1)
    {:ok, output} = Memory.start()
    {host, driver} = start_host(fixture.runtime, session, input, output, configuration: prepared)
    assert_receive {:provisional, ^host, %{exit_code: 0, cleanup: :confirmed}}, 5_000
    {transcript, _} = Memory.contents(output)
    status = Enum.find(records(transcript), &(&1["event"] == "status"))
    assert status["maintenance"]["last_compact"]["result"]["disposition"] == "failed"

    assert status["maintenance"]["last_compact"]["command_id"] ==
             Base.url_encode64(completion["command_id"], padding: false)

    assert :sys.get_state(driver).compact_commands == MapSet.new()
    close_host_and_fixture(fixture, host, driver, 0)
    stop_devices([first_input, first_output, input, output], :gen_server)
  end

  test "status excludes a later compact completion while its earlier cursor read is held" do
    prepared = prepared_configuration()
    fixture = start_fixture([], model: prepared.selection.configuration["model"])

    {:ok, session} =
      Loopex.create_session(fixture.runtime, prepared.session_options,
        command_id: "create",
        genesis: prepared.genesis
      )

    input = pipe_input("/status\n")
    output = observing_output()
    test = self()

    facade = fn module, function, arguments ->
      result = apply(module, function, arguments)

      if function == :session_status do
        count = Process.get(:compact_status_reads, 0) + 1
        Process.put(:compact_status_reads, count)

        if count == 2 do
          reference = make_ref()
          send(test, {:held_compact_projection, self(), reference, result})

          receive do
            {:release_compact_projection, ^reference} -> :ok
          end
        end
      end

      result
    end

    {host, driver} =
      start_host(fixture.runtime, session, input, output, configuration: prepared, facade: facade)

    assert_receive {:held_compact_projection, command_worker, reference, {:ok, before}}, 5_000
    assert before.event_sequence == 0
    {:ok, attachment} = Loopex.attach(fixture.runtime, session, after_event_sequence: 0)

    assert {:accepted, "later-compact"} =
             Loopex.command(attachment, %{
               type: :compact,
               command_id: "later-compact",
               bounds: %{"max_attempts" => 4, "deadline_ms" => 60_000, "token_budget" => 32_768}
             })

    send(command_worker, {:release_compact_projection, reference})
    first = await_record(&(&1["event"] == "status"))
    assert first["maintenance"]["last_compact"] == nil
    send(input, {:bytes, "/wait\n/status\n/quit\n"})
    later = await_record(&(&1["event"] == "status"))

    assert later["maintenance"]["last_compact"]["command_id"] ==
             Base.url_encode64("later-compact", padding: false)

    assert_receive {:provisional, ^host, %{exit_code: 0, cleanup: :confirmed}}, 5_000
    close_host_and_fixture(fixture, host, driver, 0)
    stop_devices([input, output])
  end

  test "status shows the actual held compact model and wait joins its callback before completion" do
    prepared = prepared_configuration()
    configuration = prepared.selection.configuration

    maintenance = %{
      "model" => configuration["model"],
      "reasoning" => "none",
      "model_capabilities" =>
        Map.put(configuration["model_capabilities"], "reasoning_levels", ["none", "default"]),
      "provider_mapping" => Map.put(configuration["provider_mapping"], "thinking_disabled", true)
    }

    fixture =
      start_fixture(
        [
          %{text: String.duplicate("retained fact ", 400), calls: []},
          %{
            text:
              ~s({"summary":"retain this fact","carry_forward":{"files_read":[],"files_changed":[]}}),
            calls: [],
            hold: self(),
            reply_overrides: %{completion: "natural", continuation: nil}
          }
        ],
        model: configuration["model"],
        maintenance_model: maintenance,
        maintenance_instructions: %{"version" => "summary.v1", "body" => "Keep facts"}
      )

    {:ok, session} =
      Loopex.create_session(fixture.runtime, prepared.session_options,
        command_id: "create",
        genesis: prepared.genesis
      )

    input = pipe_input("remember\n/wait\n/compact\n")
    output = observing_output()
    {host, driver} = start_host(fixture.runtime, session, input, output, configuration: prepared)
    assert_receive {:holding, callback}, 5_000
    callback_monitor = Process.monitor(callback)
    send(input, {:bytes, "/status\n/wait\n"})
    status = await_record(&(&1["event"] == "status"))
    assert status["maintenance"]["active_model"] == maintenance["model"]
    assert status["maintenance"]["last_compact"] == nil
    assert {:ok, %{compact_pending: true}} = Loopex.session_status(fixture.runtime, session)
    send(callback, :release)
    assert_receive {:DOWN, ^callback_monitor, :process, ^callback, :normal}, 5_000
    barrier = await_record(&(&1["event"] == "wait" and &1["input_sequence"] == "5"))
    assert barrier["state"] == "settled"
    assert barrier["outcome"]["outcome"] == "completed"
    send(input, {:bytes, "/status\n/quit\n"})
    final_status = await_record(&(&1["event"] == "status"))
    assert final_status["maintenance"]["active_model"] == nil
    assert final_status["maintenance"]["last_compact"]["result"]["disposition"] == "checkpointed"
    assert_receive {:provisional, ^host, %{exit_code: 0, cleanup: :confirmed}}, 5_000
    close_host_and_fixture(fixture, host, driver, 0)
    stop_devices([input, output])
  end

  for display <- [:delivered, :failed, :lost, :interrupt] do
    @compact_display display
    test "compact waits for actual bound-display IO join and handles #{@compact_display} without premature admission" do
      fixture = start_fixture([])
      {:ok, session} = Loopex.create_session(fixture.runtime, %{}, command_id: "create")
      input = pipe_input("/compact\n/wait\n/quit\n")
      output = blocked_control_output(false)
      test = self()
      display = :ets.new(:compact_display_write, [:public])

      facade = fn module, function, arguments ->
        if function == :command and match?([_, %{type: :compact}], arguments) do
          assert [{:written, bounds}] = :ets.lookup(display, :written)
          assert bounds =~ "Compaction bounds"
          send(test, {:compact_submission, List.last(arguments)})
        end

        apply(module, function, arguments)
      end

      {host, driver} = start_host(fixture.runtime, session, input, output, facade: facade)
      assert_receive {:blocked_control_output, ^output}, 5_000

      %{output: chat_output, pending: {:compact_display, command, cutoff}} =
        :sys.get_state(driver)

      assert is_integer(cutoff)
      %{bytes: bytes, active: %{bytes: held}} = :sys.get_state(elem(chat_output, 1))
      assert bytes > 0 and held =~ "Compaction bounds"
      monitor = Process.monitor(output)
      refute_receive {:compact_submission, _}, 0

      refute Enum.any?(
               Fixture.records(fixture, session),
               &(&1.payload.kind == "compact_command_admitted_v1")
             )

      assert Loopex.AgentLoopTestModel.dispatched(fixture.model) == []
      assert Agent.get(fixture.executor, & &1.jobs) == []

      case @compact_display do
        :delivered ->
          true = :ets.insert(display, {:written, held})
          send(output, {:release_output, :ok})
          assert_receive {:written, ^held}, 5_000

        :failed ->
          send(output, {:release_output, {:error, :closed}})
          assert_receive {:DOWN, ^monitor, :process, ^output, :broken_output}, 5_000

        :lost ->
          Process.exit(output, :kill)
          assert_receive {:DOWN, ^monitor, :process, ^output, :killed}, 5_000

        :interrupt ->
          ChatDriver.interrupt(driver)
          assert :sys.get_state(driver).stopping
          send(output, {:release_output, :ok})
          assert_receive {:written, ^held}, 5_000
      end

      expected_exit = if @compact_display == :delivered, do: 0, else: 1
      assert_receive {:provisional, ^host, %{exit_code: ^expected_exit}}, 5_000

      if @compact_display == :delivered do
        assert_receive {:compact_submission, ^command}

        completion =
          Enum.find(Fixture.events(fixture, session), &(&1.kind == "context.compaction_finished"))

        assert completion["command_id"] == command.command_id
        assert completion["result"]["disposition"] == "unchanged"
      else
        refute_receive {:compact_submission, _}, 0

        refute Enum.any?(
                 Fixture.records(fixture, session),
                 &(&1.payload.kind == "compact_command_admitted_v1")
               )

        refute Enum.any?(
                 Fixture.events(fixture, session),
                 &(&1.kind == "context.compaction_finished")
               )
      end

      close_host_and_fixture(fixture, host, driver, expected_exit)

      if @compact_display in [:failed, :lost],
        do: stop_devices([input]),
        else: stop_devices([input, output])
    end
  end

  defp hold_compact_status(:interrupt, 2, test) do
    reference = make_ref()
    send(test, {:compact_status_held, self(), reference})

    receive do
      {:release_compact_status, ^reference} -> :ok
    end
  end

  defp hold_compact_status(_ending, _count, _test), do: :ok

  for ending <- [:unchanged, :interrupt] do
    @compact_ending ending
    test "a resumed external pre-episode compact holds wait until #{@compact_ending} completion" do
      fixture = start_fixture([])

      {:ok, session} =
        Loopex.create_session(fixture.runtime, %{},
          command_id: "create",
          genesis: Loopex.ConfiguredGenesisFixture.genesis([])
        )

      owner = compact_owner(fixture, session)
      hold_compact_advance(owner)
      {:ok, attachment} = Loopex.attach(fixture.runtime, session, after_event_sequence: 0)

      assert {:accepted, "external-compact"} =
               Loopex.command(attachment, %{
                 type: :compact,
                 command_id: "external-compact",
                 bounds: %{"max_attempts" => 4, "deadline_ms" => 60_000, "token_budget" => 32_768}
               })

      assert_receive {:compact_advance_held, ^owner}, 5_000
      monitor = Process.monitor(owner)
      Process.exit(owner, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^owner, :killed}, 5_000

      assert {:ok, {:prepared, activation}} =
               Loopex.prepare_resume_session(fixture.runtime, session, "observe-external-compact")

      assert {:ok, %{active_run_id: nil, compact_pending: true, active_maintenance: nil}} =
               Loopex.session_status(fixture.runtime, session)

      assert Fixture.events(fixture, session) == []
      {:ok, input} = StringIO.open("/wait\n/quit\n", encoding: :latin1)
      output = observing_output()
      test = self()

      ending = @compact_ending

      facade = fn module, function, arguments ->
        result = apply(module, function, arguments)

        if function == :session_status do
          count = Process.get(:compact_status_reads, 0) + 1
          Process.put(:compact_status_reads, count)
          send(test, {:compact_status_read, result})

          hold_compact_status(ending, count, test)
        end

        result
      end

      {host, driver} = start_host(fixture.runtime, session, input, output, facade: facade)
      assert_receive {:compact_status_read, {:ok, %{compact_pending: true}}}, 5_000
      assert_receive {:compact_status_read, {:ok, %{compact_pending: true}}}, 5_000
      state = :sys.get_state(driver)
      assert state.barrier == 1
      assert state.input_worker == nil
      assert state.cursor == 0
      assert {"/quit\n", ""} = StringIO.contents(input)
      admission = await_record(&(&1["event"] == "input"))
      assert admission["input_sequence"] == "1" and admission["disposition"] == "admitted"
      refute_receive {:written, _}, 20

      exit_code =
        case @compact_ending do
          :unchanged ->
            assert {:ok, ^session} = Loopex.activate_resume(activation)
            0

          :interrupt ->
            assert_receive {:compact_status_held, command_worker, reference}, 5_000
            assert :sys.get_state(driver).pending == :status
            ChatDriver.interrupt(driver)
            assert :sys.get_state(driver).stopping
            send(command_worker, {:release_compact_status, reference})
            1
        end

      assert_receive {:provisional, ^host,
                      %{exit_code: ^exit_code, cleanup: :confirmed, last_outcome: nil}},
                     5_000

      assert {:ok, %{compact_pending: false, active_run_id: nil}} =
               Loopex.session_status(fixture.runtime, session)

      completion =
        Enum.find(Fixture.events(fixture, session), &(&1.kind == "context.compaction_finished"))

      assert completion["command_id"] == "external-compact"
      assert completion["result"]["cleanup"] == "confirmed"

      expected_aborts =
        case @compact_ending do
          :interrupt -> 1
          :unchanged -> 0
        end

      assert Enum.count(
               Fixture.records(fixture, session),
               &(&1.payload.kind == "compact_abort_admitted_v1")
             ) == expected_aborts

      case @compact_ending do
        :unchanged -> assert completion["result"]["disposition"] == "unchanged"
        :interrupt -> assert completion["result"]["failure"]["category"] == "cancelled"
      end

      barrier = await_record(&(&1["event"] == "wait"))
      assert barrier["state"] == "settled"
      assert barrier["run_id"] == nil and barrier["outcome"] == nil
      assert :sys.get_state(driver).cursor >= completion.event_sequence
      assert Loopex.AgentLoopTestModel.dispatched(fixture.model) == []
      close_host_and_fixture(fixture, host, driver, exit_code)
      stop_devices([input], :gen_server)
      stop_devices([output])
    end
  end

  for invalid <- [:missing, nil, "false", 0] do
    @invalid_compact_pending invalid
    test "startup refuses native compact busy value #{inspect(invalid)}" do
      fixture = start_fixture([])
      {:ok, session} = Loopex.create_session(fixture.runtime, %{}, command_id: "create")
      {:ok, input} = StringIO.open("never read\n", encoding: :latin1)
      {:ok, output} = Memory.start()

      facade = fn
        Loopex, :session_status, arguments ->
          {:ok, status} = apply(Loopex, :session_status, arguments)

          {:ok,
           if(@invalid_compact_pending == :missing,
             do: Map.delete(status, :compact_pending),
             else: Map.put(status, :compact_pending, @invalid_compact_pending)
           )}

        module, function, arguments ->
          apply(module, function, arguments)
      end

      {:ok, driver} =
        ChatDriver.start_link(fixture.runtime, session, input, {:owned, output}, facade: facade)

      assert %{exit_code: 1, transport: :session_unavailable} = ChatDriver.run(driver)
      assert ChatDriver.close(driver, :confirmed) == 1
      assert {"never read\n", ""} = StringIO.contents(input)
      stop_devices([input, output], :gen_server)
    end
  end

  test "a configured byte refusal reaches wait and closing without a transport failure" do
    prepared = prepared_configuration()
    fixture = start_fixture([], model: prepared.selection.configuration["model"])

    {:ok, session} =
      Loopex.create_session(fixture.runtime, prepared.session_options,
        command_id: "create",
        genesis: prepared.genesis
      )

    prompt = String.duplicate("x", 33_000)
    {:ok, input} = StringIO.open(prompt <> "\n/wait\n/quit\n", encoding: :latin1)
    {:ok, output} = Memory.start()

    {:ok, driver} =
      ChatDriver.start_link(fixture.runtime, session, input, {:owned, output},
        configuration: prepared
      )

    assert %{exit_code: 1, cleanup: :confirmed, transport: nil} = ChatDriver.run(driver)
    assert ChatDriver.close(driver, :confirmed) == 1
    {transcript, _} = Memory.contents(output)
    controls = records(transcript)

    assert [barrier, quit_barrier] =
             Enum.filter(controls, &(&1["event"] == "wait" and &1["run_id"] != nil))

    assert Enum.map([barrier, quit_barrier], & &1["input_sequence"]) == ["2", "3"]
    assert quit_barrier["outcome"] == barrier["outcome"]
    assert quit_barrier["run_id"] == barrier["run_id"]
    failure = barrier["outcome"]["details"]["failure"]
    assert failure["version"] == 2
    assert failure["category"] == "context_budget_exceeded"
    assert failure["measurement_scope"] == "ordinary"
    assert failure["dimension"] == "context_record_bytes"
    assert String.to_integer(failure["observed"]) > 65_536
    assert failure["limit"] == "65536"
    assert failure["hard_limit"] == "65536"
    assert List.last(controls)["last_outcome"] == barrier["outcome"]
    assert List.last(controls)["cleanup"] == "confirmed"
    assert Loopex.AgentLoopTestModel.dispatched(fixture.model) == []
    assert Agent.get(fixture.executor, & &1.jobs) == []
    refute transcript =~ prompt
  end

  test "a second interrupt ends a blocked status read under the first captured cutoff" do
    prepared = prepared_configuration()
    fixture = start_fixture([], model: prepared.selection.configuration["model"])

    {:ok, session} =
      Loopex.create_session(fixture.runtime, prepared.session_options,
        command_id: "create",
        genesis: prepared.genesis
      )

    {:ok, input} = StringIO.open("/status\nnever read\n", encoding: :latin1)
    output = blocked_control_output(false)
    test = self()

    facade = fn
      Loopex, :trace_status, [_runtime] ->
        send(test, {:blocked_status, self()})
        receive do: (:release -> {:error, :no_trace_session})

      module, function, args ->
        apply(module, function, args)
    end

    {host, driver} =
      start_host(fixture.runtime, session, input, output, configuration: prepared, facade: facade)

    assert_receive {:blocked_status, worker}
    monitor = Process.monitor(worker)
    assert {:monitored_by, holders} = Process.info(worker, :monitored_by)
    assert self() in holders and driver in holders
    ChatDriver.interrupt(driver)
    captured = :sys.get_state(driver).deadline
    assert is_integer(captured)
    ChatDriver.interrupt(driver)
    assert_receive {:provisional, ^host, %{exit_code: 1, cleanup: :unknown}}, 5_000
    assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}
    assert_receive {:blocked_control_output, ^output}, 5_000
    stopped = :sys.get_state(driver)
    control_deadline = :sys.get_state(elem(stopped.output, 1)).delivery_deadline
    assert is_integer(control_deadline)
    assert stopped.deadline == min(captured, control_deadline)
    send(output, {:release_output, :ok})
    assert {"never read\n", ""} = StringIO.contents(input)
    assert Loopex.stop(fixture.runtime) == :ok
    send(host, {:close, :confirmed})
    assert_receive {:closed, ^host, 1}
    transcript = written_transcript()
    refute Enum.any?(records(transcript), &(&1["event"] == "status"))
    assert List.last(records(transcript))["cleanup"] == "unknown"
    stop_devices([output])
  end

  test "status follows confirmed configure and warns from the retained continuation mapping" do
    prepared = prepared_configuration()
    fixture = start_fixture([], model: prepared.selection.configuration["model"])

    {:ok, session} =
      Loopex.create_session(fixture.runtime, prepared.session_options,
        command_id: "create",
        genesis: prepared.genesis
      )

    {:ok, input} =
      StringIO.open("/configure {\"reasoning\":\"high\",\"max_tokens\":8192}\n/status\n/quit\n",
        encoding: :latin1
      )

    {:ok, output} = Memory.start()

    {:ok, driver} =
      ChatDriver.start_link(fixture.runtime, session, input, {:owned, output},
        configuration: prepared
      )

    assert %{exit_code: 0, cleanup: :confirmed} = ChatDriver.run(driver)
    assert ChatDriver.close(driver, :confirmed) == 0
    {transcript, _} = Memory.contents(output)
    status = Enum.find(records(transcript), &(&1["event"] == "status"))
    assert status["configuration_version"] == "2"
    assert status["reasoning"] == "high"
    assert status["maintenance"]["warning"] == "maintenance_unconfigured"
    assert status["maintenance"]["configured_model"] == nil
    assert Loopex.AgentLoopTestModel.dispatched(fixture.model) == []
  end

  test "status acknowledges before its closed committed projection and preserves two prompts" do
    prepared = prepared_configuration()

    fixture =
      start_fixture([%{text: "first", calls: []}, %{text: "second", calls: []}],
        model: prepared.selection.configuration["model"]
      )

    {:ok, session} =
      Loopex.create_session(fixture.runtime, prepared.session_options,
        command_id: "create",
        genesis: prepared.genesis
      )

    {:ok, input} =
      StringIO.open("/status\nfirst\n/wait\n/status\nsecond\n/wait\n/quit\n", encoding: :latin1)

    {:ok, output} = Memory.start()

    {:ok, driver} =
      ChatDriver.start_link(fixture.runtime, session, input, {:owned, output},
        configuration: prepared,
        bounds: %{max_turns: 8, deadline_ms: 1000, token_budget: 10000}
      )

    assert %{exit_code: 0, cleanup: :confirmed} = ChatDriver.run(driver)
    assert ChatDriver.close(driver, :confirmed) == 0
    {transcript, _} = Memory.contents(output)
    controls = records(transcript)
    statuses = Enum.filter(controls, &(&1["event"] == "status"))
    assert length(statuses) == 2

    for status <- statuses do
      assert status["configuration_version"] == "1"
      assert status["model"] == prepared.selection.configuration["model"]
      assert status["reasoning"] == "default"
      assert status["bounds"] == nil
      assert status["run_id"] == nil
      assert status["trace"] == %{"enabled" => false, "emitted" => "0", "dropped" => "0"}

      assert status["policy"] == %{
               "origin" => "registry",
               "id" => "LoopexCli.Policy.AllowAll",
               "revision" => "0.2.0",
               "fixture_manifest_digest" => nil
             }

      index = Enum.find_index(controls, &(&1 == status))
      assert Enum.at(controls, index - 1)["event"] == "input"
      assert Enum.at(controls, index - 1)["input_sequence"] == status["input_sequence"]
    end

    assert length(Loopex.AgentLoopTestModel.dispatched(fixture.model)) == 2
    refute transcript =~ "M7_CHAT_DRIVER_SLOT"
    refute transcript =~ "model_capabilities"
    refute transcript =~ "provider_mapping"
  end

  test "status reads live trace counters separately and excludes private trace fields" do
    prepared = prepared_configuration()
    fixture = start_fixture([], model: prepared.selection.configuration["model"])

    {:ok, session} =
      Loopex.create_session(fixture.runtime, prepared.session_options,
        command_id: "create",
        genesis: prepared.genesis
      )

    {:ok, input} = StringIO.open("/status\n/quit\n", encoding: :latin1)
    {:ok, output} = Memory.start()

    facade = fn
      Loopex, :trace_status, [_runtime] ->
        {:ok, %{emitted: 9_007_199_254_740_993, dropped: 2, sink: "private-trace-canary"}}

      module, function, args ->
        apply(module, function, args)
    end

    {:ok, driver} =
      ChatDriver.start_link(fixture.runtime, session, input, {:owned, output},
        configuration: prepared,
        facade: facade
      )

    assert %{exit_code: 0} = ChatDriver.run(driver)
    assert ChatDriver.close(driver, :confirmed) == 0
    {transcript, _} = Memory.contents(output)
    status = Enum.find(records(transcript), &(&1["event"] == "status"))

    assert status["trace"] == %{
             "enabled" => true,
             "emitted" => "9007199254740993",
             "dropped" => "2"
           }

    refute transcript =~ "private-trace-canary"
  end

  test "status refuses an unobserved external configuration instead of reusing stale mapping" do
    prepared = prepared_configuration()
    fixture = start_fixture([], model: prepared.selection.configuration["model"])

    {:ok, session} =
      Loopex.create_session(fixture.runtime, prepared.session_options,
        command_id: "create",
        genesis: prepared.genesis
      )

    {:ok, attachment} = Loopex.attach(fixture.runtime, session)

    {:ok, changes, candidate} =
      LoopexCli.ChatConfiguration.update(prepared, %{"max_tokens" => 1200})

    assert {:accepted, "outside"} =
             Loopex.command_with_configuration(
               attachment,
               %{
                 type: :configure,
                 command_id: "outside",
                 changes: changes
               },
               candidate
             )

    {:ok, input} = StringIO.open("/status\n/quit\n", encoding: :latin1)
    {:ok, output} = Memory.start()

    {:ok, driver} =
      ChatDriver.start_link(fixture.runtime, session, input, {:owned, output},
        configuration: prepared
      )

    assert %{exit_code: 1, cleanup: :confirmed} = ChatDriver.run(driver)
    assert ChatDriver.close(driver, :confirmed) == 1
    {transcript, _} = Memory.contents(output)
    refute Enum.any?(records(transcript), &(&1["event"] == "status"))
    assert Enum.any?(records(transcript), &(&1["code"] == "chat_status_unavailable"))
    assert {:ok, status} = Loopex.session_status(fixture.runtime, session)
    assert status.configuration["configuration_version"] == 2
  end

  test "new chat stages captured workspace facts and every selected immutable tool schema" do
    for profile <- ~w(none coding read-only) do
      prepared = prepared_configuration(profile)
      definitions = prepared.genesis["tool_selection"]["definitions"]
      captured = prepared.selection.configuration["instructions"]
      facts = JSON.decode!(captured["environment"])
      assert facts["workspace"] == prepared.selection.profile["paths"]["workspace"]
      assert facts["tool_profile"] == profile
      assert Enum.sort(Map.keys(facts)) == ~w(platform tool_profile workspace)
      assert Enum.sort(Map.keys(facts["platform"])) == ~w(architecture os)
      {_, native_os} = :os.type()

      assert facts["platform"]["os"] ==
               if(native_os in [:darwin, :linux], do: Atom.to_string(native_os), else: "other")

      fixture =
        start_fixture([%{text: "done", calls: []}],
          model: prepared.selection.configuration["model"],
          tools: definitions
        )

      {:ok, session} =
        Loopex.create_session(fixture.runtime, prepared.session_options,
          command_id: "create",
          genesis: prepared.genesis
        )

      {:ok, input} = StringIO.open("inspect this workspace\n/wait\n/quit\n", encoding: :latin1)
      {:ok, output} = Memory.start()

      {:ok, driver} =
        ChatDriver.start_link(fixture.runtime, session, input, {:owned, output},
          configuration: prepared
        )

      assert %{exit_code: 0, cleanup: :confirmed} = ChatDriver.run(driver)
      assert ChatDriver.close(driver, :confirmed) == 0
      [request] = Loopex.AgentLoopTestModel.dispatched(fixture.model)
      {:ok, rendered} = Loopex.Runtime.Instructions.render(captured)
      assert hd(request.messages) == %{"role" => "system", "content" => rendered}
      assert request.tools == definitions

      assert Enum.sort(Enum.map(request.tools, & &1["tool_id"])) ==
               Enum.sort(prepared.active_tools)

      assert Agent.get(fixture.executor, & &1.jobs) == []
      refute rendered =~ "M7_CHAT_DRIVER_SLOT"
      assert Fixture.records(fixture, session) |> hd() |> Map.fetch!(:payload) == prepared.genesis
    end
  end

  test "configure admission updates the host cache only after owner confirmation" do
    prepared = prepared_configuration()

    fixture =
      start_fixture([%{text: "first", calls: []}, %{text: "second", calls: []}],
        model: prepared.selection.configuration["model"]
      )

    {:ok, session} =
      Loopex.create_session(fixture.runtime, prepared.session_options,
        command_id: "create",
        genesis: prepared.genesis
      )

    {:ok, instructions} =
      Loopex.Runtime.Instructions.capture(%{
        "version" => "chat.configured.v1",
        "base" => "configured-instruction-canary",
        "environment" => "",
        "appendix" => ""
      })

    changes = %{
      "model" => "anthropic:claude-haiku-4-5",
      "reasoning" => "none",
      "instructions" => instructions,
      "max_tokens" => 4096,
      "context_token_budget" => 16_000,
      "system_class_tokens" => 4000
    }

    bytes =
      "one\n/wait\n/configure {\"max_tokens\":2048}\n/configure {\"max_tokens\":999999}\n/configure " <>
        IO.iodata_to_binary(:json.encode(changes)) <> "\ntwo\n/wait\n/quit\n"

    {:ok, input} = StringIO.open(bytes, encoding: :latin1)
    {:ok, output} = Memory.start()

    {:ok, driver} =
      ChatDriver.start_link(fixture.runtime, session, input, {:owned, output},
        configuration: prepared,
        mode: :interactive
      )

    assert %{exit_code: 0, cleanup: :confirmed} = ChatDriver.run(driver)
    assert ChatDriver.close(driver, :confirmed) == 0
    [first, second] = Loopex.AgentLoopTestModel.dispatched(fixture.model)
    assert first.sampling["max_tokens"] == 1024
    refute Map.has_key?(first.sampling, "reasoning")
    assert second.sampling["max_tokens"] == 4096
    assert second.sampling["reasoning"] == "none"
    assert second.sampling["provider_mapping"]["thinking_disabled"]
    {:ok, rendered} = Loopex.Runtime.Instructions.render(instructions)
    assert hd(second.messages)["content"] == rendered
    assert {:ok, status} = Loopex.session_status(fixture.runtime, session)
    assert status.configuration["configuration_version"] == 3
    assert status.configuration["max_tokens"] == 4096
    assert status.configuration["reasoning"] == "none"
    assert status.configuration["model"] == "anthropic:claude-haiku-4-5-20251001"
    assert status.configuration["context_token_budget"] == 16_000
    assert status.configuration["system_class_tokens"] == 4000
    assert status.configuration["instructions"] == Map.take(instructions, ~w(version digest))
    assert Enum.count(Fixture.events(fixture, session), &(&1.kind == "session.configured")) == 2
    {transcript, _} = Memory.contents(output)
    refute transcript =~ "configured-instruction-canary"
    acks = Enum.filter(records(transcript), &(&1["event"] == "input"))
    assert Enum.map(acks, & &1["input_sequence"]) == Enum.map(1..8, &Integer.to_string/1)

    assert Enum.map(acks, & &1["disposition"]) ==
             ~w(admitted admitted admitted refused admitted admitted admitted admitted)

    assert length(Enum.uniq(Enum.map(acks, & &1["command_id"]))) == 8
    assert Agent.get(fixture.executor, & &1.jobs) == []
  end

  test "configure unknown observes its exact command without reissuing or reading another input" do
    prepared = prepared_configuration()
    fixture = start_fixture([], model: prepared.selection.configuration["model"])

    {:ok, session} =
      Loopex.create_session(fixture.runtime, prepared.session_options,
        command_id: "create",
        genesis: prepared.genesis
      )

    {:ok, input} = StringIO.open("/configure {\"max_tokens\":2048}\nnever\n", encoding: :latin1)
    {:ok, output} = Memory.start()
    test = self()

    facade = fn module, function, args ->
      case function do
        :command_with_configuration ->
          assert {:accepted, id} = apply(module, function, args)
          send(test, {:configured, id})
          {:error, :commit_unknown}

        :command_disposition ->
          send(test, {:observed_configure, List.last(args)})
          apply(module, function, args)

        _ ->
          apply(module, function, args)
      end
    end

    {:ok, driver} =
      ChatDriver.start_link(fixture.runtime, session, input, {:owned, output},
        configuration: prepared,
        facade: facade
      )

    assert %{exit_code: 1, cleanup: :confirmed} = ChatDriver.run(driver)
    assert ChatDriver.close(driver, :confirmed) == 1
    assert_receive {:configured, id}
    assert_receive {:observed_configure, ^id}
    refute_receive {:configured, _}
    assert {"never\n", ""} = StringIO.contents(input)
    assert {:ok, status} = Loopex.session_status(fixture.runtime, session)
    assert status.configuration["configuration_version"] == 2
    assert Enum.count(Fixture.events(fixture, session), &(&1.kind == "session.configured")) == 1
    assert Loopex.AgentLoopTestModel.dispatched(fixture.model) == []
    {transcript, _} = Memory.contents(output)

    assert [%{"disposition" => "unknown", "code" => "commit_unknown"}] =
             Enum.filter(records(transcript), &(&1["event"] == "input"))
  end

  test "busy configure refusal does not advance the cache used after the wait barrier" do
    prepared = prepared_configuration()

    fixture =
      start_fixture([%{text: "first", calls: [], hold: self()}],
        model: prepared.selection.configuration["model"]
      )

    {:ok, session} =
      Loopex.create_session(fixture.runtime, prepared.session_options,
        command_id: "create",
        genesis: prepared.genesis
      )

    tail = "/configure {\"max_tokens\":4096}\n/wait\n/quit\n"

    {:ok, input} =
      StringIO.open("one\n/configure {\"max_tokens\":2048}\n/wait\n" <> tail,
        encoding: :latin1
      )

    output = observing_output()

    {host, _driver} =
      start_host(fixture.runtime, session, input, output,
        configuration: prepared,
        mode: :interactive
      )

    assert_receive {:holding, model}, 5_000

    refused =
      await_record(fn record ->
        record["event"] == "input" and record["input_sequence"] == "2"
      end)

    assert refused["disposition"] == "refused"
    assert refused["code"] == "configuration_not_settled"
    await_record(fn record -> record["event"] == "input" and record["input_sequence"] == "3" end)
    assert {^tail, ""} = StringIO.contents(input)
    assert {:ok, status} = Loopex.session_status(fixture.runtime, session)
    assert status.configuration["configuration_version"] == 1
    assert status.configuration["max_tokens"] == 1024
    send(model, :release)
    assert_receive {:provisional, ^host, %{exit_code: 0, cleanup: :confirmed}}, 5_000
    send(host, {:close, :confirmed})
    assert_receive {:closed, ^host, 0}, 5_000
    assert {:ok, configured} = Loopex.session_status(fixture.runtime, session)
    assert configured.configuration["configuration_version"] == 2
    assert configured.configuration["max_tokens"] == 4096
    assert Enum.count(Fixture.events(fixture, session), &(&1.kind == "session.configured")) == 1
  end

  test "retained-history configure refusal leaves the next candidate on the original version" do
    prepared = prepared_configuration()

    fixture =
      start_fixture([%{text: String.duplicate("a", 7000), calls: []}],
        model: prepared.selection.configuration["model"]
      )

    {:ok, session} =
      Loopex.create_session(fixture.runtime, prepared.session_options,
        command_id: "create",
        genesis: prepared.genesis
      )

    bytes =
      String.duplicate("p", 7000) <>
        "\n/wait\n/configure {\"context_token_budget\":600,\"system_class_tokens\":200}\n/configure {\"max_tokens\":2048}\n/wait\n/quit\n"

    {:ok, input} = StringIO.open(bytes, encoding: :latin1)
    {:ok, output} = Memory.start()

    {:ok, driver} =
      ChatDriver.start_link(fixture.runtime, session, input, {:owned, output},
        configuration: prepared,
        mode: :interactive
      )

    assert %{exit_code: 0, cleanup: :confirmed} = ChatDriver.run(driver)
    assert ChatDriver.close(driver, :confirmed) == 0
    {transcript, _} = Memory.contents(output)

    assert %{"code" => "compaction_required", "disposition" => "refused"} =
             Enum.find(
               records(transcript),
               &(&1["event"] == "input" and &1["input_sequence"] == "3")
             )

    assert {:ok, status} = Loopex.session_status(fixture.runtime, session)
    assert status.configuration["configuration_version"] == 2
    assert status.configuration["max_tokens"] == 2048
    assert status.configuration["system_class_tokens"] == 8000
    assert length(Loopex.AgentLoopTestModel.dispatched(fixture.model)) == 1
    assert Agent.get(fixture.executor, & &1.jobs) == []
  end

  test "two prompts use one conversation and acknowledgements precede caused output" do
    fixture =
      start_fixture([%{text: "first\n@loopex forged", calls: []}, %{text: "second", calls: []}])

    {:ok, session} = Loopex.create_session(fixture.runtime, %{}, command_id: "create")
    {:ok, input} = StringIO.open("one\n/wait\ntwo\n/wait\n/quit\n", encoding: :latin1)
    {:ok, output} = Memory.start()
    {:ok, driver} = ChatDriver.start_link(fixture.runtime, session, input, {:owned, output})
    monitor = Process.monitor(driver)

    assert %{exit_code: 0, transport: nil, last_outcome: %{outcome: :completed}} =
             ChatDriver.run(driver)

    # The result is provisional until the actual runtime is stopped.
    assert Loopex.stop(fixture.runtime) == :ok
    assert ChatDriver.close(driver, :confirmed) == 0
    assert_receive {:DOWN, ^monitor, :process, ^driver, :normal}
    {transcript, _} = Memory.contents(output)
    assert transcript =~ "> first\n> @loopex forged\n"
    assert transcript =~ "> second\n"
    records = records(transcript)
    admissions = Enum.filter(records, &(&1["event"] == "input"))
    assert Enum.map(admissions, & &1["input_sequence"]) == ~w(1 2 3 4 5)
    assert Enum.all?(admissions, &(&1["disposition"] == "admitted"))
    ids = Enum.map(admissions, & &1["command_id"])
    assert length(Enum.uniq(ids)) == 5
    waits = Enum.filter(records, &(&1["event"] == "wait"))
    assert [first, second, closing_wait] = waits
    assert first["input_sequence"] == "2" and second["input_sequence"] == "4"
    assert first["run_id"] != second["run_id"]
    assert closing_wait["run_id"] == second["run_id"]

    assert Enum.all?(
             waits,
             &(&1["state"] == "settled" and &1["outcome"]["outcome"] == "completed")
           )

    assert List.last(records)["cleanup"] == "confirmed"

    assert byte_position(transcript, ~s("input_sequence":"1")) <
             byte_position(transcript, "> first")

    assert byte_position(transcript, ~s("input_sequence":"3")) <
             byte_position(transcript, "> second")

    [one, two] = Loopex.AgentLoopTestModel.dispatched(fixture.model)
    assert List.last(one.messages)["content"] == "one"
    assert List.last(two.messages)["content"] == "two"
    assert Enum.any?(two.messages, &(&1["content"] == "first\n@loopex forged"))
  end

  test "unknown admission retains the existing control-output deadline through cleanup" do
    fixture = start_fixture([%{text: "must not publish", calls: [], hold: self()}])
    {:ok, session} = Loopex.create_session(fixture.runtime, %{}, command_id: "create")
    input = pipe_input("one\n")
    test = self()

    output = blocked_control_output()

    facade = fn module, function, args ->
      case {function, args} do
        {:command, [attachment, %{type: :prompt} = command]} ->
          assert {:accepted, _} = Loopex.command(attachment, command)
          {:error, :commit_unknown}

        {:command_disposition, [_, id]} ->
          send(test, {:blocked_disposition, self(), id})
          receive do: (:release -> apply(module, function, args))

        _ ->
          apply(module, function, args)
      end
    end

    {host, driver} = start_host(fixture.runtime, session, input, output, facade: facade)
    assert_receive {:holding, model}, 5_000
    assert_receive {:blocked_control_output, ^output}, 5_000
    assert_receive {:blocked_disposition, observer, command_id}, 5_000
    state = :sys.get_state(driver)
    output_deadline = :sys.get_state(elem(state.output, 1)).active.deadline
    assert is_integer(output_deadline)
    assert state.stopping and state.unresolved == command_id
    assert state.deadline <= output_deadline
    captured = state.deadline
    joined = monitor_processes([model | Map.keys(state.workers)])
    send(observer, :release)
    assert_receive {:provisional, ^host, %{exit_code: 1, cleanup: :confirmed}}, 5_000
    assert :sys.get_state(driver).deadline == captured
    assert_processes_joined(joined)
    send(output, {:release_output, :ok})
    closing = monitor_processes([host, driver, elem(state.output, 1), fixture.runtime.supervisor])
    assert Loopex.stop(fixture.runtime) == :ok
    assert_closing_deadline(host, driver, output, elem(state.output, 1), captured)
    send(output, :release_closing)
    assert_receive {:closed, ^host, 1}, 5_000
    assert_processes_joined(closing)
    actors = [fixture.model, fixture.executor, fixture.store]
    actor_monitors = monitor_processes(actors)
    Enum.each(actors, &GenServer.stop(&1, :normal))
    assert_processes_joined(actor_monitors)
    stop_devices([input, output])
  end

  test "EOF during an active run cancels it and joins the held model and chat workers" do
    fixture = start_fixture([%{text: "must not publish", calls: [], hold: self()}])
    {:ok, session} = Loopex.create_session(fixture.runtime, %{}, command_id: "create")
    input = pipe_input("one\n")
    output = observing_output()
    {host, driver} = start_host(fixture.runtime, session, input, output)
    assert_receive {:holding, model}, 5_000
    assert_receive {:blocked_input, ^input, input_worker}, 5_000
    {:ok, status} = Loopex.session_status(fixture.runtime, session)
    assert is_binary(status.active_run_id)
    assert status.open_interaction == nil
    state = :sys.get_state(driver)
    assert state.input_worker == input_worker
    workers = monitor_processes([model | Map.keys(state.workers)])
    send(input, :eof)

    assert_receive {:provisional, ^host,
                    %{
                      exit_code: 1,
                      cleanup: :confirmed,
                      transport: nil,
                      last_outcome: %{outcome: :cancelled}
                    }},
                   5_000

    assert_processes_joined(workers)
    barrier = await_record(&(&1["event"] == "wait"))
    assert barrier["state"] == "settled"
    assert barrier["run_id"] == LoopexProtocol.Wire.encode_identity(status.active_run_id)
    assert barrier["outcome"]["outcome"] == "cancelled"
    events = Fixture.events(fixture, session)
    assert Enum.find(events, &(&1.kind == "run.finished"))["outcome"] == "cancelled"
    refute Enum.any?(events, &(&1.kind == "assistant.message_appended"))
    assert length(Loopex.AgentLoopTestModel.dispatched(fixture.model)) == 1
    assert Loopex.AgentLoopTestExecutor.jobs(fixture.executor) == []
    close_host_and_fixture(fixture, host, driver, 1)
    closing = await_record(&(&1["event"] == "closing"))
    assert closing["cleanup"] == "confirmed"
    assert closing["exit_code"] == 1
    assert closing["last_outcome"] == barrier["outcome"]
    stop_devices([input, output])
  end

  test "EOF at an actual question cancels its exact interaction without another model turn" do
    definition = LoopexProtocol.ToolDefinition.question_definition()

    fixture =
      start_fixture(
        [
          %{
            text: "Which?",
            calls: [%{id: "ask-eof", name: "ask", arguments: %{"question" => "Explain"}}]
          },
          %{text: "must not dispatch", calls: []}
        ],
        tools: [definition]
      )

    {:ok, session} = Loopex.create_session(fixture.runtime, %{}, command_id: "create")
    input = pipe_input("one\n/wait\n")
    output = observing_output()
    {host, driver} = start_host(fixture.runtime, session, input, output)
    question = await_record(&(&1["event"] == "question"))
    barrier = await_record(&(&1["event"] == "wait"))
    assert barrier["state"] == "question"
    assert barrier["interaction_id"] == question["interaction_id"]
    {:ok, status} = Loopex.session_status(fixture.runtime, session)

    assert LoopexProtocol.Wire.encode_identity(status.open_interaction["interaction_id"]) ==
             question["interaction_id"]

    assert_receive {:blocked_input, ^input, input_worker}, 5_000
    state = :sys.get_state(driver)
    assert state.input_worker == input_worker
    workers = monitor_processes(Map.keys(state.workers))
    send(input, :eof)

    assert_receive {:provisional, ^host,
                    %{
                      exit_code: 1,
                      cleanup: :confirmed,
                      transport: nil,
                      last_outcome: %{outcome: :cancelled}
                    }},
                   5_000

    assert_processes_joined(workers)
    settled = await_record(&(&1["event"] == "wait" and &1["state"] == "settled"))
    assert settled["run_id"] == barrier["run_id"]
    assert settled["outcome"]["outcome"] == "cancelled"
    events = Fixture.events(fixture, session)
    cancelled = Enum.find(events, &(&1.kind == "interaction.cancelled"))

    assert LoopexProtocol.Wire.encode_identity(cancelled["interaction_id"]) ==
             question["interaction_id"]

    assert Enum.find(events, &(&1.kind == "run.finished"))["outcome"] == "cancelled"

    assert {:ok, %{active_run_id: nil, open_interaction: nil}} =
             Loopex.session_status(fixture.runtime, session)

    assert length(Loopex.AgentLoopTestModel.dispatched(fixture.model)) == 1
    assert Loopex.AgentLoopTestExecutor.jobs(fixture.executor) == []
    close_host_and_fixture(fixture, host, driver, 1)
    closing = await_record(&(&1["event"] == "closing"))
    assert closing["cleanup"] == "confirmed"
    assert closing["exit_code"] == 1
    assert closing["last_outcome"] == settled["outcome"]
    stop_devices([input, output])
  end

  test "empty idle EOF closes successfully without inventing a run or outcome" do
    fixture = start_fixture([])
    {:ok, session} = Loopex.create_session(fixture.runtime, %{}, command_id: "create")
    input = pipe_input("")
    output = observing_output()
    {host, driver} = start_host(fixture.runtime, session, input, output)
    assert_receive {:blocked_input, ^input, input_worker}, 5_000
    state = :sys.get_state(driver)
    assert state.input_worker == input_worker
    workers = monitor_processes(Map.keys(state.workers))
    send(input, :eof)

    assert_receive {:provisional, ^host,
                    %{exit_code: 0, cleanup: :confirmed, transport: nil, last_outcome: nil}},
                   5_000

    assert_processes_joined(workers)
    assert :sys.get_state(driver).sequence == 0

    assert {:ok, %{active_run_id: nil, open_interaction: nil}} =
             Loopex.session_status(fixture.runtime, session)

    events = Fixture.events(fixture, session)

    refute Enum.any?(
             events,
             &(&1.kind in ["run.started", "run.finished", "user.message_appended"])
           )

    assert Loopex.AgentLoopTestModel.dispatched(fixture.model) == []
    assert Loopex.AgentLoopTestExecutor.jobs(fixture.executor) == []
    close_host_and_fixture(fixture, host, driver, 0)

    assert await_record(&(&1["event"] == "closing")) == %{
             "v" => 1,
             "event" => "closing",
             "cleanup" => "confirmed",
             "exit_code" => 0,
             "last_outcome" => nil
           }

    stop_devices([input, output])
  end

  test "EOF after a settled wait retains the successful run and joins every chat actor" do
    fixture = start_fixture([%{text: "done", calls: []}])
    {:ok, session} = Loopex.create_session(fixture.runtime, %{}, command_id: "create")
    input = pipe_input("one\n/wait\n")
    output = observing_output()
    {host, driver} = start_host(fixture.runtime, session, input, output)
    settled = await_record(&(&1["event"] == "wait"))
    assert settled["state"] == "settled"
    assert settled["outcome"]["outcome"] == "completed"
    assert is_binary(settled["run_id"])
    assert_receive {:blocked_input, ^input, input_worker}, 5_000
    state = :sys.get_state(driver)
    assert state.input_worker == input_worker
    workers = monitor_processes(Map.keys(state.workers))
    send(input, :eof)

    assert_receive {:provisional, ^host,
                    %{
                      exit_code: 0,
                      cleanup: :confirmed,
                      transport: nil,
                      last_outcome: %{outcome: :completed}
                    }},
                   5_000

    assert_processes_joined(workers)
    closing_wait = await_record(&(&1["event"] == "wait"))
    assert closing_wait["state"] == "settled"
    assert closing_wait["run_id"] == settled["run_id"]
    assert closing_wait["outcome"] == settled["outcome"]
    assert :sys.get_state(driver).sequence == 2
    events = Fixture.events(fixture, session)
    assert [finished] = Enum.filter(events, &(&1.kind == "run.finished"))
    assert finished["outcome"] == "completed"
    assert settled["run_id"] == LoopexProtocol.Wire.encode_identity(finished["run_id"])
    assert length(Loopex.AgentLoopTestModel.dispatched(fixture.model)) == 1
    assert Loopex.AgentLoopTestExecutor.jobs(fixture.executor) == []
    close_host_and_fixture(fixture, host, driver, 0)
    closing = await_record(&(&1["event"] == "closing"))
    assert closing["cleanup"] == "confirmed"
    assert closing["exit_code"] == 0
    assert closing["last_outcome"] == settled["outcome"]
    stop_devices([input, output])
  end

  test "an unterminated EOF fragment refuses without a prompt and cancels active work" do
    assert_fragment_shutdown("incomplete", :unterminated_input_line)
  end

  test "a CR fragment at EOF refuses without a prompt and cancels active work" do
    assert_fragment_shutdown("incomplete\r", :invalid_input_line)
  end

  test "a successful later run retains an earlier failure in the closing exit code" do
    fixture =
      start_fixture([
        %{error: :provider_unavailable, deltas: ["uncommitted failure text"]},
        %{text: "recovered", calls: []}
      ])

    {:ok, session} = Loopex.create_session(fixture.runtime, %{}, command_id: "create")
    {:ok, input} = StringIO.open("one\n/wait\ntwo\n/wait\n/quit\n", encoding: :latin1)
    {:ok, output} = Memory.start()
    {host, driver} = start_host(fixture.runtime, session, input, output)

    assert_receive {:provisional, ^host,
                    %{
                      exit_code: 1,
                      cleanup: :confirmed,
                      transport: nil,
                      last_outcome: %{outcome: :completed}
                    }},
                   5_000

    events = Fixture.events(fixture, session)
    terminals = Enum.filter(events, &(&1.kind == "run.finished"))
    assert Enum.map(terminals, & &1["outcome"]) == ["failed", "completed"]
    assert length(Loopex.AgentLoopTestModel.dispatched(fixture.model)) == 2
    assert Loopex.AgentLoopTestExecutor.jobs(fixture.executor) == []
    close_host_and_fixture(fixture, host, driver, 1)
    {transcript, _} = Memory.contents(output)
    controls = records(transcript)
    [failed, successful, closing_wait] = Enum.filter(controls, &(&1["event"] == "wait"))
    assert failed["outcome"]["outcome"] == "failed"
    assert successful["outcome"]["outcome"] == "completed"
    assert failed["run_id"] != successful["run_id"]
    assert closing_wait["run_id"] == successful["run_id"]
    assert closing_wait["outcome"] == successful["outcome"]
    closing = List.last(controls)
    assert closing["event"] == "closing"
    assert closing["exit_code"] == 1
    assert closing["cleanup"] == "confirmed"
    assert closing["last_outcome"] == successful["outcome"]
    assert transcript =~ "> recovered\n"
    refute transcript =~ "> uncommitted failure text\n"
    stop_devices([input, output], :gen_server)
  end

  test "outer cleanup uncertainty prevents a successful closing record" do
    fixture = start_fixture([])
    {:ok, session} = Loopex.create_session(fixture.runtime, %{}, command_id: "create")
    {:ok, input} = StringIO.open("/quit\n", encoding: :latin1)
    {:ok, output} = Memory.start()
    {:ok, driver} = ChatDriver.start_link(fixture.runtime, session, input, {:owned, output})
    assert %{exit_code: 0, last_outcome: nil} = ChatDriver.run(driver)
    assert ChatDriver.close(driver, :unknown) == 1
    {transcript, _} = Memory.contents(output)

    assert List.last(records(transcript)) == %{
             "v" => 1,
             "event" => "closing",
             "exit_code" => 1,
             "cleanup" => "unknown",
             "last_outcome" => nil
           }
  end

  test "normal caller loss reaps blocked stdin and both facade attachment holders" do
    fixture = start_fixture([])
    {:ok, session} = Loopex.create_session(fixture.runtime, %{}, command_id: "create")
    test = self()

    input =
      spawn(fn ->
        receive do
          {:io_request, worker, _, _} ->
            send(test, {:input_worker, worker})
            receive do: (:stop -> :ok)
        end
      end)

    on_exit(fn -> Process.exit(input, :kill) end)
    {:ok, output} = Memory.start()

    facade = fn module, function, args ->
      if function == :attach, do: send(test, {:holder, self()})
      apply(module, function, args)
    end

    caller =
      spawn(fn ->
        {:ok, driver} =
          ChatDriver.start_link(fixture.runtime, session, input, {:owned, output}, facade: facade)

        send(test, {:driver, driver})
        :gen_server.send_request(driver, :run)
        receive do: (:leave -> :ok)
      end)

    assert_receive {:driver, driver}
    assert_receive {:holder, command}
    assert_receive {:holder, reader}
    assert_receive {:input_worker, input_worker}
    monitors = for pid <- [driver, command, reader, input_worker], do: {pid, Process.monitor(pid)}
    send(caller, :leave)

    for {pid, monitor} <- monitors do
      assert_receive {:DOWN, ^monitor, :process, ^pid, _}
      refute Process.alive?(pid)
    end
  end

  # Concept: an explicit abort ends its run while keeping the chat usable.
  # Technical depth: literal pipe input crosses the real driver and Core abort
  # path. Both model workers are held inside actual supervised attempts, and
  # the replacement checks its predecessor is gone before dispatch proceeds.
  test "literal abort settles the held run and permits a later prompt with exact actor joins" do
    fixture =
      start_fixture([
        %{text: "must not publish", calls: [], hold: self()},
        %{text: "continued", calls: [], hold: self(), require_previous_worker_down: true}
      ])

    {:ok, session} = Loopex.create_session(fixture.runtime, %{}, command_id: "create")
    input = pipe_input("one\n")
    output = observing_output()
    {host, driver} = start_host(fixture.runtime, session, input, output)
    assert_receive {:holding, first_model}, 5_000
    assert_receive {:blocked_input, ^input, first_reader}, 5_000
    first_model_monitor = Process.monitor(first_model)
    first_reader_monitor = Process.monitor(first_reader)
    first_ack = await_record(&(&1["event"] == "input" and &1["input_sequence"] == "1"))
    assert first_ack["disposition"] == "admitted"
    assert {:ok, status} = Loopex.session_status(fixture.runtime, session)
    assert is_binary(status.active_run_id)
    original_run = status.active_run_id
    wire_session = LoopexProtocol.Wire.encode_identity(session)
    wire_original_run = LoopexProtocol.Wire.encode_identity(original_run)

    send(input, {:bytes, "/abort\n/wait\n"})
    abort_ack = await_record(&(&1["event"] == "input" and &1["input_sequence"] == "2"))
    assert abort_ack["disposition"] == "admitted"
    assert abort_ack["command_id"] != first_ack["command_id"]
    assert_receive {:DOWN, ^first_model_monitor, :process, ^first_model, :killed}, 5_000
    assert_receive {:DOWN, ^first_reader_monitor, :process, ^first_reader, :normal}, 5_000
    refute Process.alive?(first_model)
    refute Process.alive?(first_reader)
    aborted_wait = await_record(&(&1["event"] == "wait" and &1["input_sequence"] == "3"))
    assert aborted_wait["state"] == "settled"
    assert aborted_wait["session_id"] == wire_session
    assert aborted_wait["run_id"] == wire_original_run
    assert aborted_wait["outcome"]["outcome"] == "cancelled"

    assert {:ok, %{active_run_id: nil, open_interaction: nil, status: :active}} =
             Loopex.session_status(fixture.runtime, session)

    assert {:ok, abort_command} = LoopexProtocol.Wire.identity(abort_ack["command_id"])

    assert [abort_record] =
             Enum.filter(Fixture.records(fixture, session), fn record ->
               record.payload.kind == "command_admitted" and
                 record.payload["command_type"] == "abort"
             end)

    assert abort_record.payload["command_id"] == abort_command
    assert abort_record.payload["run_id"] == original_run

    assert Enum.any?(Fixture.events(fixture, session), fn event ->
             event.kind == "run.finished" and event["run_id"] == original_run and
               event["outcome"] == "cancelled"
           end)

    assert_receive {:blocked_input, ^input, next_reader}, 5_000
    next_reader_monitor = Process.monitor(next_reader)
    send(input, {:bytes, "two\n/wait\n"})
    assert_receive {:holding, second_model}, 5_000
    second_model_monitor = Process.monitor(second_model)
    assert_receive {:DOWN, ^next_reader_monitor, :process, ^next_reader, :normal}, 5_000
    next_ack = await_record(&(&1["event"] == "input" and &1["input_sequence"] == "4"))
    assert next_ack["disposition"] == "admitted"

    assert length(
             Enum.uniq([first_ack["command_id"], abort_ack["command_id"], next_ack["command_id"]])
           ) == 3

    send(second_model, :release)
    assert_receive {:DOWN, ^second_model_monitor, :process, ^second_model, :normal}, 5_000
    refute Process.alive?(second_model)
    completed_wait = await_record(&(&1["event"] == "wait" and &1["input_sequence"] == "5"))
    assert completed_wait["state"] == "settled"
    assert completed_wait["session_id"] == wire_session
    assert completed_wait["run_id"] != wire_original_run
    assert completed_wait["outcome"]["outcome"] == "completed"
    assert_receive {:blocked_input, ^input, final_reader}, 5_000
    actors = monitor_processes(Map.keys(:sys.get_state(driver).workers))
    assert Enum.any?(actors, fn {pid, _monitor} -> pid == final_reader end)
    send(input, {:bytes, "/quit\n"})

    # Concept: later success does not erase the earlier cancelled ending.
    # Technical depth: the existing driver accumulates exit1 while its truthful
    # last outcome becomes completed; abort does not force transport shutdown.
    assert_receive {:provisional, ^host,
                    %{
                      exit_code: 1,
                      cleanup: :confirmed,
                      transport: nil,
                      last_outcome: %{outcome: :completed}
                    }},
                   5_000

    assert_processes_joined(actors)
    closing_wait = await_record(&(&1["event"] == "wait" and &1["input_sequence"] == "6"))
    assert closing_wait["run_id"] == completed_wait["run_id"]
    assert closing_wait["outcome"]["outcome"] == "completed"

    events = Fixture.events(fixture, session)

    assert Enum.map(Enum.filter(events, &(&1.kind == "run.finished")), & &1["outcome"]) ==
             ["cancelled", "completed"]

    assert Enum.map(
             Enum.filter(events, &(&1.kind == "assistant.message_appended")),
             & &1["content"]
           ) ==
             ["continued"]

    [one, two] = Loopex.AgentLoopTestModel.dispatched(fixture.model)
    assert List.last(one.messages)["content"] == "one"
    assert List.last(two.messages)["content"] == "two"
    assert Enum.any?(two.messages, &(&1["role"] == "user" and &1["content"] == "one"))
    refute Enum.any?(two.messages, &(&1["content"] == "must not publish"))
    assert Loopex.AgentLoopTestExecutor.jobs(fixture.executor) == []
    close_host_and_fixture(fixture, host, driver, 1)
    closing = await_record(&(&1["event"] == "closing"))
    assert closing["cleanup"] == "confirmed" and closing["exit_code"] == 1
    assert closing["last_outcome"]["outcome"] == "completed"
    stop_devices([input, output])
  end

  test "wait does not read the next prompt while an actual model call is held" do
    fixture =
      start_fixture([%{text: "first", calls: [], hold: self()}, %{text: "second", calls: []}])

    {:ok, session} = Loopex.create_session(fixture.runtime, %{}, command_id: "create")
    {:ok, input} = StringIO.open("one\n/wait\ntwo\n/wait\n/quit\n", encoding: :latin1)
    output = observing_output()
    {host, driver} = start_host(fixture.runtime, session, input, output)
    assert_receive {:holding, model}, 5_000
    await_record(fn record -> record["event"] == "input" and record["input_sequence"] == "2" end)
    assert {"two\n/wait\n/quit\n", ""} = StringIO.contents(input)
    assert length(Loopex.AgentLoopTestModel.dispatched(fixture.model)) == 1
    send(model, :release)
    assert_receive {:provisional, ^host, %{exit_code: 0, cleanup: :confirmed}}, 5_000
    send(host, {:close, :confirmed})
    assert_receive {:closed, ^host, 0}, 5_000
    refute Process.alive?(driver)
  end

  test "interrupt is responsive while stdin is blocked and joins its exact reader" do
    fixture = start_fixture([])
    {:ok, session} = Loopex.create_session(fixture.runtime, %{}, command_id: "create")
    test = self()

    input =
      spawn(fn ->
        receive do
          {:io_request, worker, _, _} ->
            send(test, {:blocked_input, worker})
            receive do: (:stop -> :ok)
        end
      end)

    on_exit(fn -> Process.exit(input, :kill) end)
    {:ok, output} = Memory.start()
    {host, driver} = start_host(fixture.runtime, session, input, output)
    assert_receive {:blocked_input, reader}
    monitor = Process.monitor(reader)
    ChatDriver.interrupt(driver)
    assert_receive {:provisional, ^host, %{exit_code: 1, cleanup: :confirmed}}, 5_000
    assert_receive {:DOWN, ^monitor, :process, ^reader, :killed}
    send(host, {:close, :confirmed})
    assert_receive {:closed, ^host, 1}
    {transcript, _} = Memory.contents(output)
    assert List.last(records(transcript))["cleanup"] == "confirmed"
  end

  test "the actual model question and wait barrier retain one opaque identity and exact answer" do
    definition = LoopexProtocol.ToolDefinition.question_definition()

    fixture =
      start_fixture(
        [
          %{
            text: "Which?",
            calls: [%{id: "ask-1", name: "ask", arguments: %{"question" => "Explain"}}]
          },
          %{text: "answered", calls: []}
        ],
        tools: [definition]
      )

    {:ok, session} = Loopex.create_session(fixture.runtime, %{}, command_id: "create")
    input = pipe_input("one\n/wait\n")
    output = observing_output()
    {host, _driver} = start_host(fixture.runtime, session, input, output)
    question = await_record(&(&1["event"] == "question"))
    barrier = await_record(&(&1["event"] == "wait"))
    assert question["producer"] == "model_tool"
    assert question["kind"] == "text" and question["choices"] == []
    assert barrier["state"] == "question"
    assert barrier["interaction_id"] == question["interaction_id"]

    send(
      input,
      {:bytes,
       "/answer " <>
         question["interaction_id"] <> ~s( --text " keep --choice literal ") <> "\n/wait\n/quit\n"}
    )

    assert_receive {:provisional, ^host, %{exit_code: 0, last_outcome: %{outcome: :completed}}},
                   5_000

    send(host, {:close, :confirmed})
    assert_receive {:closed, ^host, 0}, 5_000
    [_first, second] = Loopex.AgentLoopTestModel.dispatched(fixture.model)

    assert Enum.any?(
             second.messages,
             &(&1["role"] == "tool" and &1["content"] == " keep --choice literal ")
           )

    assert Loopex.AgentLoopTestExecutor.jobs(fixture.executor) == []
  end

  test "a lost command acknowledgement observes its exact identity before shutdown and never retries" do
    fixture = start_fixture([%{text: "done", calls: []}])
    {:ok, session} = Loopex.create_session(fixture.runtime, %{}, command_id: "create")
    {:ok, input} = StringIO.open("one\n/wait\ntwo\n", encoding: :latin1)
    {:ok, output} = Memory.start()
    test = self()

    facade = fn module, function, args ->
      case {function, args} do
        {:command, [attachment, %{type: :prompt} = command]} ->
          send(test, {:admitted_prompt, command.command_id})
          assert {:accepted, _} = Loopex.command(attachment, command)
          {:error, :commit_unknown}

        {:command, [_, %{type: :abort} = command]} ->
          send(test, {:shutdown_command, command.command_id})
          apply(module, function, args)

        {:command_disposition, [_, id]} ->
          send(test, {:observed_command, id})
          apply(module, function, args)

        _ ->
          apply(module, function, args)
      end
    end

    {host, _} = start_host(fixture.runtime, session, input, output, facade: facade)
    assert_receive {:admitted_prompt, command_id}
    assert_receive {:observed_command, ^command_id}
    assert_receive {:shutdown_command, shutdown_id}
    assert shutdown_id != command_id
    assert_receive {:provisional, ^host, %{exit_code: 1}}, 5_000
    refute_receive {:admitted_prompt, _}, 0
    assert {"/wait\ntwo\n", ""} = StringIO.contents(input)
    send(host, {:close, :confirmed})
    assert_receive {:closed, ^host, 1}
    {transcript, _} = Memory.contents(output)
    assert [ack] = Enum.filter(records(transcript), &(&1["event"] == "input"))
    assert ack["disposition"] == "unknown" and ack["code"] == "commit_unknown"
    assert ack["command_id"] == LoopexProtocol.Wire.encode_identity(command_id)
  end

  test "second interrupt joins a blocked admission worker without inventing an abort acknowledgement" do
    fixture = start_fixture([%{text: "done", calls: []}])
    {:ok, session} = Loopex.create_session(fixture.runtime, %{}, command_id: "create")
    {:ok, input} = StringIO.open("one\n/wait\ntwo\n", encoding: :latin1)
    output = blocked_control_output(false)
    test = self()

    facade = fn module, function, args ->
      case {function, args} do
        {:command, [attachment, %{type: :prompt} = command]} ->
          assert {:accepted, _} = Loopex.command(attachment, command)
          send(test, {:blocked_admission, self(), command.command_id})
          receive do: (:release -> {:error, :commit_unknown})

        {:command, [_, %{type: :abort}]} ->
          send(test, :unexpected_abort)
          apply(module, function, args)

        _ ->
          apply(module, function, args)
      end
    end

    {host, driver} = start_host(fixture.runtime, session, input, output, facade: facade)
    assert_receive {:blocked_admission, worker, id}
    worker_monitor = Process.monitor(worker)
    ChatDriver.interrupt(driver)
    initial = :sys.get_state(driver)
    assert is_integer(initial.deadline)
    ChatDriver.interrupt(driver)
    assert_receive {:provisional, ^host, %{exit_code: 1, cleanup: :unknown}}, 5_000
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :killed}
    refute_receive :unexpected_abort, 0
    assert_receive {:blocked_control_output, ^output}, 5_000
    stopped = :sys.get_state(driver)
    control_deadline = :sys.get_state(elem(stopped.output, 1)).delivery_deadline
    assert is_integer(control_deadline)
    assert stopped.deadline == min(initial.deadline, control_deadline)
    send(output, {:release_output, :ok})
    assert {"/wait\ntwo\n", ""} = StringIO.contents(input)
    assert Loopex.stop(fixture.runtime) == :ok
    send(host, {:close, :confirmed})
    assert_receive {:closed, ^host, 1}
    transcript = written_transcript()
    assert [ack] = Enum.filter(records(transcript), &(&1["event"] == "input"))
    assert ack["disposition"] == "unknown"
    assert [barrier] = Enum.filter(records(transcript), &(&1["event"] == "wait"))
    assert barrier["outcome"] == "commit_unknown"
    assert barrier["command_id"] == LoopexProtocol.Wire.encode_identity(id)
    assert List.last(records(transcript))["cleanup"] == "unknown"
    stop_devices([output])
  end

  test "broken output returns a fixed transport failure after the target is lost" do
    fixture = start_fixture([])
    {:ok, session} = Loopex.create_session(fixture.runtime, %{}, command_id: "create")
    # Concept: this case ends through actual output failure.
    # Technical depth: keep stdin open so provisional quit cannot race the
    # independent writer's error and exact DOWN notification.
    input = pipe_input("/wait\n")
    test = self()

    output = RecordingOutputTarget.start(test, fail_first: true)
    output_monitor = Process.monitor(output)
    on_exit(fn -> if Process.alive?(output), do: Process.exit(output, :kill) end)
    {:ok, driver} = ChatDriver.start_link(fixture.runtime, session, input, {:owned, output})
    writer = elem(:sys.get_state(driver).output, 1)
    closing = monitor_processes([driver, writer])
    assert %{exit_code: 1, transport: :output_failed} = ChatDriver.run(driver)
    assert_receive {:broken_output_fault, ^output}, 5_000
    assert_receive {:DOWN, ^output_monitor, :process, ^output, :broken_output}, 5_000
    assert :sys.get_state(driver).workers == %{}
    assert Loopex.stop(fixture.runtime) == :ok
    assert ChatDriver.close(driver, :confirmed) == 1
    assert_processes_joined(closing)
    stop_devices([input])
  end

  test "attachment-holder death preserves pending admission uncertainty and reaps remaining actors" do
    fixture = start_fixture([%{text: "done", calls: []}])
    {:ok, session} = Loopex.create_session(fixture.runtime, %{}, command_id: "create")
    {:ok, input} = StringIO.open("one\n/wait\n", encoding: :latin1)
    output = blocked_control_output()
    test = self()

    facade = fn module, function, args ->
      case {function, args} do
        {:command, [_, %{type: :prompt} = command]} ->
          send(test, {:pending_admission, self(), command.command_id})
          receive do: (:release -> apply(module, function, args))

        _ ->
          apply(module, function, args)
      end
    end

    {host, driver} = start_host(fixture.runtime, session, input, output, facade: facade)
    assert_receive {:pending_admission, worker, id}
    joins = monitor_processes(Map.keys(:sys.get_state(driver).workers))
    Process.exit(worker, :kill)

    assert_receive {:provisional, ^host,
                    %{exit_code: 1, transport: :chat_worker_failed, cleanup: :unknown}},
                   5_000

    assert_processes_joined(joins)
    assert_receive {:blocked_control_output, ^output}, 5_000
    state = :sys.get_state(driver)
    output_deadline = :sys.get_state(elem(state.output, 1)).delivery_deadline
    assert is_integer(output_deadline)
    assert state.finished
    assert state.deadline <= output_deadline
    send(output, {:release_output, :ok})
    closing = monitor_processes([host, driver, elem(state.output, 1)])
    assert_closing_deadline(host, driver, output, elem(state.output, 1), state.deadline)
    send(output, :release_closing)
    assert_receive {:closed, ^host, 1}
    assert_processes_joined(closing)
    barrier = await_record(&(&1["event"] == "wait"))
    assert barrier["outcome"] == "commit_unknown"
    assert barrier["command_id"] == LoopexProtocol.Wire.encode_identity(id)
    assert Loopex.AgentLoopTestModel.dispatched(fixture.model) == []
    stop_devices([output])
  end

  test "a malformed complete command is refused before the next valid prompt" do
    fixture = start_fixture([%{text: "done", calls: []}])
    {:ok, session} = Loopex.create_session(fixture.runtime, %{}, command_id: "create")
    {:ok, input} = StringIO.open("/answer broken\none\n/wait\n/quit\n", encoding: :latin1)
    {:ok, output} = Memory.start()

    {:ok, driver} =
      ChatDriver.start_link(fixture.runtime, session, input, {:owned, output}, mode: :interactive)

    assert %{exit_code: 0, transport: nil} = ChatDriver.run(driver)
    assert ChatDriver.close(driver, :confirmed) == 0
    {transcript, _} = Memory.contents(output)

    assert [refused, prompt, wait, quit] =
             Enum.filter(records(transcript), &(&1["event"] == "input"))

    assert refused["disposition"] == "refused" and refused["code"] == "invalid_chat_answer"
    assert Enum.map([refused, prompt, wait, quit], & &1["input_sequence"]) == ~w(1 2 3 4)
    assert length(Loopex.AgentLoopTestModel.dispatched(fixture.model)) == 1
  end

  test "pipe syntax refusal stops before a following prompt and exits nonzero" do
    fixture = start_fixture([])
    {:ok, session} = Loopex.create_session(fixture.runtime, %{}, command_id: "create")
    {:ok, input} = StringIO.open("/answer broken\nshould remain unread\n", encoding: :latin1)
    {:ok, output} = Memory.start()
    {:ok, driver} = ChatDriver.start_link(fixture.runtime, session, input, {:owned, output})
    assert %{exit_code: 1, last_outcome: nil} = ChatDriver.run(driver)
    assert {"should remain unread\n", ""} = StringIO.contents(input)
    assert Loopex.AgentLoopTestModel.dispatched(fixture.model) == []
    assert ChatDriver.close(driver, :confirmed) == 1
  end

  test "steer names the public active run and reaches the next model turn" do
    fixture =
      start_fixture(
        [
          %{
            text: "first",
            hold: self(),
            calls: [
              %{
                id: "steer-write",
                name: "write",
                arguments: %{"path" => "note.txt", "content" => "retained"}
              }
            ]
          },
          %{text: "steered", calls: [], require_previous_worker_down: true}
        ],
        tools: [Fixture.tool_definition()]
      )

    {:ok, session} = Loopex.create_session(fixture.runtime, %{}, command_id: "create")
    {:ok, input} = StringIO.open("one\n/steer exact steer\n/wait\n/quit\n", encoding: :latin1)
    output = observing_output()
    test = self()

    facade = fn
      module, :command, [attachment, %{type: :steer} = command] ->
        send(test, {:steer_target, command})
        apply(module, :command, [attachment, command])

      module, function, arguments ->
        apply(module, function, arguments)
    end

    {host, driver} = start_host(fixture.runtime, session, input, output, facade: facade)
    assert_receive {:holding, model}, 5_000
    monitor = Process.monitor(model)
    assert_receive {:steer_target, command}, 5_000
    assert {:ok, %{active_run_id: run}} = Loopex.session_status(fixture.runtime, session)
    assert command.run_id == run
    assert command.content == "exact steer"
    admitted = await_record(&(&1["event"] == "input" and &1["input_sequence"] == "2"))
    assert admitted["disposition"] == "admitted"
    await_record(&(&1["event"] == "input" and &1["input_sequence"] == "3"))
    send(model, :release)
    assert_receive {:DOWN, ^monitor, :process, ^model, :normal}, 5_000
    assert_receive {:provisional, ^host, %{exit_code: 0, cleanup: :confirmed}}, 5_000
    [_, steered] = Loopex.AgentLoopTestModel.dispatched(fixture.model)
    assert Enum.any?(steered.messages, &(&1["content"] == "exact steer"))
    assert [job] = Loopex.AgentLoopTestExecutor.jobs(fixture.executor)
    assert job.tool_call_id == "steer-write"
    close_host_and_fixture(fixture, host, driver, 0)
    stop_devices([output])
  end

  test "idle steer is locally refused and interactive chat still accepts a prompt" do
    fixture = start_fixture([%{text: "done", calls: []}])
    {:ok, session} = Loopex.create_session(fixture.runtime, %{}, command_id: "create")
    {:ok, input} = StringIO.open("/steer idle text\none\n/wait\n/quit\n", encoding: :latin1)
    {:ok, output} = Memory.start()

    {:ok, driver} =
      ChatDriver.start_link(fixture.runtime, session, input, {:owned, output}, mode: :interactive)

    assert %{exit_code: 0, cleanup: :confirmed} = ChatDriver.run(driver)
    assert ChatDriver.close(driver, :confirmed) == 0
    {transcript, _} = Memory.contents(output)
    [refused | admissions] = Enum.filter(records(transcript), &(&1["event"] == "input"))
    assert refused["disposition"] == "refused"
    assert refused["code"] == "no_active_run"
    assert Enum.map(admissions, & &1["input_sequence"]) == ~w(2 3 4)
    assert Enum.all?(admissions, &(&1["disposition"] == "admitted"))
    [request] = Loopex.AgentLoopTestModel.dispatched(fixture.model)
    refute Enum.any?(request.messages, &(&1["content"] == "idle text"))
  end

  test "steer refuses its observed run when a follow-up replaces it before admission" do
    fixture =
      start_fixture([
        %{text: "first", calls: [], hold: self()},
        %{text: "followed", calls: [], hold: self(), require_previous_worker_down: true}
      ])

    {:ok, session} = Loopex.create_session(fixture.runtime, %{}, command_id: "create")

    {:ok, input} =
      StringIO.open("one\n/follow-up next\n/steer stale text\n/wait\n/quit\n",
        encoding: :latin1
      )

    output = observing_output()
    test = self()

    facade = fn module, function, arguments ->
      result = apply(module, function, arguments)

      if function == :session_status and not Process.get(:steer_status_observed, false) do
        case result do
          {:ok, %{active_run_id: run}} when is_binary(run) ->
            Process.put(:steer_status_observed, true)
            send(test, {:steer_status_observed, self(), run})
            receive do: (:submit_observed_steer -> :ok)

          _ ->
            :ok
        end
      end

      result
    end

    {host, driver} =
      start_host(fixture.runtime, session, input, output, mode: :interactive, facade: facade)

    assert_receive {:holding, first}, 5_000
    assert_receive {:steer_status_observed, holder, old_run}, 5_000
    first_monitor = Process.monitor(first)
    send(first, :release)
    assert_receive {:DOWN, ^first_monitor, :process, ^first, :normal}, 5_000
    assert_receive {:holding, second}, 5_000
    second_monitor = Process.monitor(second)
    assert {:ok, %{active_run_id: new_run}} = Loopex.session_status(fixture.runtime, session)
    assert new_run != old_run
    send(holder, :submit_observed_steer)
    refused = await_record(&(&1["event"] == "input" and &1["input_sequence"] == "3"))
    assert refused["disposition"] == "refused"
    assert refused["code"] == "run_mismatch"
    await_record(&(&1["event"] == "input" and &1["input_sequence"] == "4"))
    send(second, :release)
    assert_receive {:DOWN, ^second_monitor, :process, ^second, :normal}, 5_000
    assert_receive {:provisional, ^host, %{exit_code: 0, cleanup: :confirmed}}, 5_000
    [_, request] = Loopex.AgentLoopTestModel.dispatched(fixture.model)
    assert Enum.any?(request.messages, &(&1["content"] == "next"))
    refute Enum.any?(request.messages, &(&1["content"] == "stale text"))
    close_host_and_fixture(fixture, host, driver, 0)
    stop_devices([output])
  end

  test "captured invocation bounds reach each prompt while queued follow-up inherits the active run" do
    fixture =
      start_fixture([
        %{text: "first", calls: [], hold: self()},
        %{text: "followed", calls: [], hold: self()}
      ])

    {:ok, session} = Loopex.create_session(fixture.runtime, %{}, command_id: "create")
    {:ok, input} = StringIO.open("one\n/follow-up next\n/wait\n/quit\n", encoding: :latin1)
    output = observing_output()
    huge = Integer.pow(10, 40)
    bounds = %{max_turns: huge, token_budget: huge + 1, deadline_ms: 60_000}
    {host, _} = start_host(fixture.runtime, session, input, output, bounds: bounds)
    assert_receive {:holding, first_worker}, 5_000
    await_record(fn record -> record["event"] == "input" and record["input_sequence"] == "3" end)
    assert {:ok, first_status} = Loopex.session_status(fixture.runtime, session)
    [first_request] = Loopex.AgentLoopTestModel.dispatched(fixture.model)
    assert first_status.active_bounds == Map.put(bounds, :deadline, first_request.deadline)
    assert {"/quit\n", ""} = StringIO.contents(input)
    send(first_worker, :release)
    assert_receive {:holding, second_worker}, 5_000
    assert {:ok, second_status} = Loopex.session_status(fixture.runtime, session)
    [^first_request, second_request] = Loopex.AgentLoopTestModel.dispatched(fixture.model)
    assert first_status.active_run_id != second_status.active_run_id
    assert second_status.active_bounds == Map.put(bounds, :deadline, second_request.deadline)
    assert {"/quit\n", ""} = StringIO.contents(input)
    send(second_worker, :release)

    assert_receive {:provisional, ^host, %{exit_code: 0, last_outcome: %{outcome: :completed}}},
                   5_000

    send(host, {:close, :confirmed})
    assert_receive {:closed, ^host, 0}, 5_000
  end

  defp pipe_input(bytes) do
    test = self()
    device = spawn(fn -> input_loop(bytes, nil, test) end)
    on_exit(fn -> Process.exit(device, :kill) end)
    device
  end

  defp input_loop(<<byte, rest::binary>>, {worker, reply}, test) do
    send(worker, {:io_reply, reply, <<byte>>})
    input_loop(rest, nil, test)
  end

  defp input_loop(:eof, {worker, reply}, test) do
    send(worker, {:io_reply, reply, :eof})
    input_loop(:eof, nil, test)
  end

  defp input_loop("", {worker, _} = pending, test) do
    send(test, {:blocked_input, self(), worker})
    await_input("", pending, test)
  end

  defp input_loop(bytes, pending, test), do: await_input(bytes, pending, test)

  defp await_input(bytes, pending, test) do
    receive do
      {:io_request, worker, reply, {:get_chars, _, _, 1}} ->
        input_loop(bytes, {worker, reply}, test)

      {:bytes, next} ->
        input_loop(bytes <> next, pending, test)

      :eof ->
        input_loop(:eof, pending, test)
    end
  end

  defp assert_fragment_shutdown(fragment, reason) do
    fixture = start_fixture([%{text: "must not publish", calls: [], hold: self()}])
    {:ok, session} = Loopex.create_session(fixture.runtime, %{}, command_id: "create")
    input = pipe_input("one\n" <> fragment)
    output = observing_output()
    {host, driver} = start_host(fixture.runtime, session, input, output)
    assert_receive {:holding, model}, 5_000
    assert_receive {:blocked_input, ^input, input_worker}, 5_000
    admitted = await_record(&(&1["event"] == "input"))
    assert admitted["input_sequence"] == "1"
    assert admitted["disposition"] == "admitted"
    {:ok, status} = Loopex.session_status(fixture.runtime, session)
    assert is_binary(status.active_run_id)
    state = :sys.get_state(driver)
    assert state.input_worker == input_worker
    workers = monitor_processes([model | Map.keys(state.workers)])
    send(input, :eof)

    assert_receive {:provisional, ^host,
                    %{
                      exit_code: 1,
                      cleanup: :confirmed,
                      transport: ^reason,
                      last_outcome: %{outcome: :cancelled}
                    }},
                   5_000

    assert_processes_joined(workers)
    refusal = await_record(&(&1["event"] == "error"))
    assert refusal["input_sequence"] == "1"
    assert refusal["code"] == Atom.to_string(reason)
    barrier = await_record(&(&1["event"] == "wait"))
    assert barrier["state"] == "settled"
    assert barrier["run_id"] == LoopexProtocol.Wire.encode_identity(status.active_run_id)
    assert barrier["outcome"]["outcome"] == "cancelled"
    assert :sys.get_state(driver).sequence == 1
    events = Fixture.events(fixture, session)
    assert [%{"content" => "one"}] = Enum.filter(events, &(&1.kind == "user.message_appended"))
    assert Enum.find(events, &(&1.kind == "run.finished"))["outcome"] == "cancelled"
    refute Enum.any?(events, &(&1.kind == "assistant.message_appended"))
    assert length(Loopex.AgentLoopTestModel.dispatched(fixture.model)) == 1
    assert Loopex.AgentLoopTestExecutor.jobs(fixture.executor) == []
    close_host_and_fixture(fixture, host, driver, 1)
    closing = await_record(&(&1["event"] == "closing"))
    assert closing["cleanup"] == "confirmed"
    assert closing["exit_code"] == 1
    assert closing["last_outcome"] == barrier["outcome"]
    stop_devices([input, output])
  end

  defp monitor_processes(pids), do: Enum.map(pids, &{&1, Process.monitor(&1)})

  defp compact_owner(fixture, session) do
    {:ok, children} = Loopex.Runtime.children(fixture.runtime)
    :sys.get_state(children.control).sessions[session].coordinator
  end

  defp hold_compact_advance(owner) do
    observer = self()

    hook = fn
      :armed, {:in, :advance_work}, _ ->
        send(observer, {:compact_advance_held, self()})
        receive do: (:release_compact_advance -> :spent)

      current, _, _ ->
        current
    end

    assert :ok = :sys.install(owner, {hook, :armed})
    on_exit(fn -> if Process.alive?(owner), do: Process.exit(owner, :kill) end)
  end

  defp assert_processes_joined(monitors) do
    for {pid, monitor} <- monitors do
      assert_receive {:DOWN, ^monitor, :process, ^pid, _}, 5_000
      refute Process.alive?(pid)
    end
  end

  defp close_host_and_fixture(fixture, host, driver, exit_code) do
    writer = elem(:sys.get_state(driver).output, 1)
    closing = monitor_processes([host, driver, writer, fixture.runtime.supervisor])
    assert Loopex.stop(fixture.runtime) == :ok
    send(host, {:close, :confirmed})
    assert_receive {:closed, ^host, ^exit_code}, 5_000
    assert_processes_joined(closing)
    actors = [fixture.model, fixture.executor, fixture.store]
    monitors = monitor_processes(actors)
    Enum.each(actors, &GenServer.stop(&1, :normal))
    assert_processes_joined(monitors)
  end

  defp stop_devices(devices, kind \\ :process) do
    monitors = monitor_processes(devices)

    case kind do
      :process -> Enum.each(devices, &Process.exit(&1, :kill))
      :gen_server -> Enum.each(devices, &GenServer.stop(&1, :normal))
    end

    assert_processes_joined(monitors)
  end

  defp start_host(runtime, session, input, output, options \\ []) do
    test = self()

    host =
      spawn(fn ->
        {:ok, driver} = ChatDriver.start_link(runtime, session, input, {:owned, output}, options)
        send(test, {:host_driver, self(), driver})
        send(test, {:provisional, self(), ChatDriver.run(driver)})

        receive do
          {:close, cleanup} -> send(test, {:closed, self(), ChatDriver.close(driver, cleanup)})
        end
      end)

    on_exit(fn -> if Process.alive?(host), do: Process.exit(host, :kill) end)
    assert_receive {:host_driver, ^host, driver}
    {host, driver}
  end

  # Concept: both blocked-closing fixtures observe finish admission before its state.
  # Technical depth: closing IO starts independently of the owner's following
  # finish call. Spend only the already-captured cutoff to observe that exact
  # driver/writer call; the subsequent serial query sees its retained deadline.
  defp assert_closing_deadline(host, driver, output, writer, captured) do
    assert 1 = :erlang.trace(writer, true, [:receive, {:tracer, self()}])

    try do
      send(host, {:close, :confirmed})
      assert_receive {:blocked_closing, ^output}, 5_000

      remaining = captured - System.monotonic_time(:millisecond)
      assert remaining >= 0

      assert_receive {:trace, ^writer, :receive,
                      {:"$gen_call", {^driver, _}, {_incarnation, {:finish, ^captured}}}},
                     remaining

      finish_deadline = :sys.get_state(writer).closing.cutoff
      assert is_integer(finish_deadline) and finish_deadline <= captured
    after
      try do
        :erlang.trace(writer, false, [:receive])
      rescue
        ArgumentError -> :ok
      end
    end
  end

  defp blocked_control_output(block_closing \\ true) do
    device = RecordingOutputTarget.start(self(), hold_first: true, block_closing: block_closing)
    on_exit(fn -> if Process.alive?(device), do: Process.exit(device, :kill) end)
    device
  end

  defp observing_output do
    device = RecordingOutputTarget.start(self())
    on_exit(fn -> Process.exit(device, :kill) end)
    device
  end

  defp written_transcript(acc \\ []) do
    receive do
      {:written, bytes} ->
        acc = [bytes | acc]

        if String.starts_with?(bytes, "@loopex ") and
             JSON.decode!(binary_part(bytes, 8, byte_size(bytes) - 8))["event"] == "closing",
           do: acc |> Enum.reverse() |> IO.iodata_to_binary(),
           else: written_transcript(acc)
    after
      5_000 -> flunk("closing transcript not delivered")
    end
  end

  defp await_record(predicate) do
    receive do
      {:written, "@loopex " <> json} ->
        record = JSON.decode!(json)
        if predicate.(record), do: record, else: await_record(predicate)

      {:written, _} ->
        await_record(predicate)
    after
      5_000 -> flunk("control record not delivered")
    end
  end

  defp start_fixture(script, options \\ []) do
    fixture = Fixture.start(Keyword.merge([script: script, tools: []], options))
    on_exit(fn -> Fixture.stop(fixture) end)
    fixture
  end

  defp prepared_configuration(tools \\ "none") do
    root =
      Path.join(
        System.tmp_dir!(),
        "chat-driver-config-" <> Base.encode16(:crypto.strong_rand_bytes(8))
      )

    File.mkdir_p!(Path.join(root, "workspace"))
    file = Path.join(root, "chat.json")

    profile = %{
      "schema_version" => 1,
      "providers" => %{"anthropic" => %{"credential" => %{"env" => "M7_CHAT_DRIVER_SLOT"}}},
      "policy" => "allow-all",
      "paths" => %{"workspace" => "workspace", "state_root" => "state"},
      "session" => %{
        "model" => "anthropic:claude-haiku-4-5",
        "tools" => tools,
        "system_class_tokens" => 8000,
        "max_tokens" => 1024,
        "bounds" => %{"max_turns" => 8, "deadline_ms" => 1000, "token_budget" => 10000}
      }
    }

    File.write!(file, :json.encode(profile))
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, prepared} = LoopexCli.ChatConfiguration.load(["chat", "--config", file], root, nil)
    prepared
  end

  defp records(transcript),
    do:
      transcript
      |> String.split("\n", trim: true)
      |> Enum.flat_map(fn
        "@loopex " <> json -> [JSON.decode!(json)]
        _ -> []
      end)

  defp byte_position(text, fragment), do: elem(:binary.match(text, fragment), 0)
end
