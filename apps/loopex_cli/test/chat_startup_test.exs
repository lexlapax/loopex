Code.require_file("../../loopex/test/support/m1_runtime_helper.exs", __DIR__)
Code.require_file("../../loopex/test/support/agent_loop_helper.exs", __DIR__)

defmodule LoopexCli.ChatStartupTest do
  use ExUnit.Case, async: false
  alias LoopexCli.Output.Memory
  @moduletag capture_log: true
  alias LoopexCli.ChatDriver
  alias Loopex.AgentLoopFixture, as: Fixture

  setup do
    fixture = Fixture.start(script: [%{text: "done", calls: []}], tools: [])
    on_exit(fn -> Fixture.stop(fixture) end)
    {:ok, session} = Loopex.create_session(fixture.runtime, %{}, command_id: "create")
    {:ok, input} = StringIO.open("one\n/wait\n/quit\n", encoding: :latin1)
    {:ok, output} = Memory.start()
    %{fixture: fixture, session: session, input: input, output: output}
  end

  test "readiness leaves stdin and events untouched and run reuses the exact attachment holders",
       f do
    test = self()

    facade = fn module, function, args ->
      if function in [:attach, :next_event], do: send(test, {:facade, function, self()})
      apply(module, function, args)
    end

    {:ok, driver} = driver(f, facade: facade, cleanup_grace_ms: 5000)
    assert {:ok, %{cleanup_grace_ms: 5000}} = ChatDriver.prepare(driver)
    state = :sys.get_state(driver)
    assert map_size(state.workers) == 2
    assert state.input_worker == nil
    assert state.reader_busy == false
    assert_receive {:facade, :attach, command}
    assert_receive {:facade, :attach, reader}
    assert MapSet.new([command, reader]) == MapSet.new(Map.keys(state.workers))
    refute_receive {:facade, :next_event, _}
    assert {"one\n/wait\n/quit\n", ""} == StringIO.contents(f.input)
    assert {"", ""} == Memory.contents(f.output)
    assert Loopex.AgentLoopTestModel.dispatched(f.fixture.model) == []
    assert {:ok, _} = ChatDriver.prepare(driver)

    assert %{exit_code: 0, cleanup: :confirmed} = ChatDriver.run(driver)
    refute_receive {:facade, :attach, _}
    assert_receive {:facade, :next_event, event_holder}
    assert event_holder == state.reader
    assert length(Loopex.AgentLoopTestModel.dispatched(f.fixture.model)) == 1
    assert :sys.get_state(driver).workers == %{}
    assert ChatDriver.close(driver, :confirmed) == 0
  end

  test "only the creating host can prepare or begin input", f do
    {:ok, driver} = driver(f)
    outsider = Task.async(fn -> {ChatDriver.prepare(driver), ChatDriver.run(driver)} end)

    assert {{:error, :invalid_chat_driver_call}, {:error, :invalid_chat_driver_call}} =
             Task.await(outsider)

    assert :sys.get_state(driver).workers == %{}
    assert {:ok, _} = ChatDriver.prepare(driver)
    assert %{exit_code: 0} = ChatDriver.run(driver)
    assert ChatDriver.close(driver, :confirmed) == 0
  end

  test "readiness preserves an actual prepared resume until its holder activates", f do
    assert :ok = Loopex.stop(f.fixture.runtime)

    restarted =
      Fixture.start(script: [%{text: "resumed", calls: []}], tools: [], store: f.fixture.store)

    on_exit(fn -> Fixture.stop(restarted) end)

    {:ok, {:prepared, activation}} =
      Loopex.prepare_resume_session(restarted.runtime, f.session, "resume")

    before = Fixture.records(restarted, f.session)
    {:ok, driver} = driver(%{f | fixture: restarted}, cleanup_grace_ms: 5000)
    assert {:ok, %{active_run_id: nil}} = ChatDriver.prepare(driver)
    assert Fixture.records(restarted, f.session) == before
    assert {:ok, _} = Loopex.prepared_session_configuration(activation)
    assert Loopex.AgentLoopTestModel.dispatched(restarted.model) == []
    assert {"one\n/wait\n/quit\n", ""} == StringIO.contents(f.input)
    assert {:ok, session} = Loopex.activate_resume(activation)
    assert session == f.session
    assert %{exit_code: 0, cleanup: :confirmed} = ChatDriver.run(driver)
    assert length(Loopex.AgentLoopTestModel.dispatched(restarted.model)) == 1
    assert ChatDriver.close(driver, :confirmed) == 0
  end

  test "captured grace validation refuses before starting a writer", f do
    for grace <- [0, -1, 1.5, "5000", Integer.pow(2, 64)] do
      assert {:error, :invalid_chat_cleanup_grace} = driver(f, cleanup_grace_ms: grace)
    end

    assert {"", ""} == Memory.contents(f.output)
    assert {"one\n/wait\n/quit\n", ""} == StringIO.contents(f.input)
  end

  test "interrupt before either startup call never opens attachments or reads input", f do
    for operation <- [:prepare, :run] do
      test = self()

      facade = fn module, function, args ->
        send(test, {:unexpected_facade, function})
        apply(module, function, args)
      end

      # Each transport owner acquires its own output target exclusively.
      {:ok, output} = Memory.start()
      {:ok, driver} = driver(%{f | output: output}, facade: facade, cleanup_grace_ms: 1234)
      ChatDriver.interrupt(driver)
      state = :sys.get_state(driver)
      assert state.stopping
      assert state.cleanup_grace_ms == 1234
      assert state.workers == %{}
      result = apply(ChatDriver, operation, [driver])

      if operation == :prepare do
        assert {:error, %{exit_code: 1, cleanup: :unknown}} = result
      else
        assert %{exit_code: 1, cleanup: :unknown} = result
      end

      refute_receive {:unexpected_facade, _}
      assert {"one\n/wait\n/quit\n", ""} == StringIO.contents(f.input)
      assert ChatDriver.close(driver, :confirmed) == 1
    end
  end

  test "interrupt while startup status is blocked captures one grace and submits one ordinary abort",
       f do
    {host, driver, command} = blocked_startup(f)
    ChatDriver.interrupt(driver)
    stopped = :sys.get_state(driver)
    assert stopped.pending == :startup_status
    assert stopped.stopping
    assert stopped.cleanup_grace_ms == 5000
    assert is_integer(stopped.deadline)
    assert stopped.cutoff_timer != nil
    send(command, :release)
    assert_receive {:startup_command, %{type: :abort}}, 1000
    assert_receive {:prepared, ^host, {:error, %{exit_code: 1, cleanup: :confirmed}}}, 5000
    assert :sys.get_state(driver).deadline == stopped.deadline
    assert :sys.get_state(driver).workers == %{}
    assert {"one\n/wait\n/quit\n", ""} == StringIO.contents(f.input)
    assert Loopex.AgentLoopTestModel.dispatched(f.fixture.model) == []
    refute_receive {:startup_command, _}
    send(host, :close)
    assert_receive {:closed, ^host, 1}
  end

  test "second startup interrupt joins the blocked holder and reports unknown without an abort",
       f do
    {host, driver, command} = blocked_startup(f)
    monitor = Process.monitor(command)
    assert self() in elem(Process.info(command, :monitored_by), 1)
    ChatDriver.interrupt(driver)
    deadline = :sys.get_state(driver).deadline
    ChatDriver.interrupt(driver)
    assert_receive {:prepared, ^host, {:error, %{exit_code: 1, cleanup: :unknown}}}, 1000
    assert_receive {:DOWN, ^monitor, :process, ^command, :killed}, 1000
    assert :sys.get_state(driver).deadline == deadline
    refute_receive {:startup_command, _}
    assert {"one\n/wait\n/quit\n", ""} == StringIO.contents(f.input)
    send(host, :close)
    assert_receive {:closed, ^host, 1}
  end

  test "startup holder loss reaps its peer and returns a failure that remains closable", f do
    {host, driver, command} = blocked_startup(f)
    state = :sys.get_state(driver)
    monitors = Enum.map(Map.keys(state.workers), &{&1, Process.monitor(&1)})
    for {pid, _} <- monitors, do: assert(self() in elem(Process.info(pid, :monitored_by), 1))
    Process.exit(command, :kill)

    assert_receive {:prepared, ^host,
                    {:error, %{exit_code: 1, cleanup: :unknown, transport: :chat_worker_failed}}},
                   1000

    for {pid, monitor} <- monitors do
      assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}, 1000
    end

    refute_receive {:startup_command, _}
    assert :sys.get_state(driver).workers == %{}
    send(host, :close)
    assert_receive {:closed, ^host, 1}
  end

  test "interrupt after readiness settles without reopening actors or consuming stdin", f do
    {:ok, driver} = driver(f, cleanup_grace_ms: 5000)
    assert {:ok, _} = ChatDriver.prepare(driver)
    ChatDriver.interrupt(driver)
    assert %{exit_code: 1, cleanup: :confirmed} = ChatDriver.run(driver)
    assert :sys.get_state(driver).workers == %{}
    assert {"one\n/wait\n/quit\n", ""} == StringIO.contents(f.input)
    assert Loopex.AgentLoopTestModel.dispatched(f.fixture.model) == []
    assert ChatDriver.close(driver, :confirmed) == 1
  end

  test "a mismatched captured grace refuses startup without mutation or input", f do
    before = Fixture.records(f.fixture, f.session)
    test = self()

    facade = fn module, function, args ->
      if function == :command, do: send(test, {:unexpected_command, args})
      apply(module, function, args)
    end

    {:ok, driver} = driver(f, cleanup_grace_ms: 17, facade: facade)

    assert {:error, %{transport: :chat_cleanup_grace_mismatch, cleanup: :unknown}} =
             ChatDriver.prepare(driver)

    join_remaining_workers(driver)
    assert Fixture.records(f.fixture, f.session) == before
    refute_receive {:unexpected_command, _}
    assert {"one\n/wait\n/quit\n", ""} == StringIO.contents(f.input)
    assert ChatDriver.close(driver, :confirmed) == 1
  end

  test "unavailable startup status refuses and joins both attachments", f do
    facade = fn module, function, args ->
      if function == :session_status,
        do: {:error, :unavailable},
        else: apply(module, function, args)
    end

    {:ok, driver} = driver(f, facade: facade)

    assert {:error, %{transport: :session_unavailable, cleanup: :unknown}} =
             ChatDriver.prepare(driver)

    join_remaining_workers(driver)
    assert ChatDriver.close(driver, :unknown) == 1
  end

  defp driver(f, options \\ []),
    do: ChatDriver.start_link(f.fixture.runtime, f.session, f.input, {:owned, f.output}, options)

  defp join_remaining_workers(driver) do
    for pid <- Map.keys(:sys.get_state(driver).workers) do
      monitor = Process.monitor(pid)
      assert_receive {:DOWN, ^monitor, :process, ^pid, reason}, 1000
      assert reason in [:killed, :noproc]
      refute Process.alive?(pid)
    end
  end

  defp blocked_startup(f) do
    test = self()
    first_status = make_ref()

    facade = fn module, function, args ->
      if function == :session_status and Process.get(first_status) == nil do
        Process.put(first_status, :seen)
        send(test, {:blocked_startup, self()})
        receive do: (:release -> :ok)
      end

      if function == :command, do: send(test, {:startup_command, List.last(args)})
      apply(module, function, args)
    end

    host =
      spawn(fn ->
        {:ok, driver} = driver(f, facade: facade, cleanup_grace_ms: 5000)
        send(test, {:driver, self(), driver})
        send(test, {:prepared, self(), ChatDriver.prepare(driver)})

        receive do
          :close -> send(test, {:closed, self(), ChatDriver.close(driver, :confirmed)})
        end
      end)

    on_exit(fn -> if Process.alive?(host), do: Process.exit(host, :kill) end)
    assert_receive {:driver, ^host, driver}
    assert_receive {:blocked_startup, command}
    {host, driver, command}
  end
end
