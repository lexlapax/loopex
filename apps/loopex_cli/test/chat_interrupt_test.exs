Code.require_file("../../loopex/test/support/m1_runtime_helper.exs", __DIR__)
Code.require_file("../../loopex/test/support/agent_loop_helper.exs", __DIR__)

defmodule LoopexCli.ChatInterruptTest do
  use ExUnit.Case, async: false
  @moduletag capture_log: true
  alias LoopexCli.{ChatDriver, Interrupt}
  alias Loopex.AgentLoopFixture, as: Fixture

  setup do
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

    fixture = Fixture.start(script: [%{text: "done", calls: []}], tools: [])
    on_exit(fn -> Fixture.stop(fixture) end)
    {:ok, session} = Loopex.create_session(fixture.runtime, %{}, command_id: "create")
    {:ok, input} = StringIO.open("one\n/wait\n/quit\n", encoding: :latin1)
    {:ok, output} = StringIO.open("", encoding: :latin1)
    %{manager: manager, fixture: fixture, session: session, input: input, output: output}
  end

  test "normal driver close preserves the route until exact host finish", f do
    {:ok, driver} = driver(f)
    assert {:ok, _} = ChatDriver.prepare(driver)
    ref = make_ref()
    assert {:ok, manager} = Interrupt.install_chat(driver, ref, 5000)
    assert manager == f.manager
    assert Interrupt.chat_live(manager, ref)
    refute Interrupt.chat_live(manager, make_ref())
    assert %{exit_code: 0, cleanup: :confirmed} = ChatDriver.run(driver)
    assert ChatDriver.close(driver, :confirmed) == 0
    refute Process.alive?(driver)
    assert Interrupt.chat_live(manager, ref)
    assert [Interrupt] == :gen_event.which_handlers(manager)
    assert {:ok, :ordinary} = Interrupt.finish_chat(manager, ref)
    assert [:erl_signal_handler] == :gen_event.which_handlers(manager)
    refute Interrupt.chat_live(manager, ref)
  end

  test "prepared chat transfers to the guarded holder and activates through that exact holder",
       f do
    {:ok, {:prepared, activation}} =
      Loopex.prepare_resume_session(f.fixture.runtime, f.session, "resume")

    {:ok, driver} = driver(f)
    {:ok, _} = ChatDriver.prepare(driver)
    ref = make_ref()
    assert {:ok, manager} = Interrupt.install_chat(driver, ref, 5000, activation)
    assert manager == f.manager

    assert {:error, :resume_activation_holder_mismatch} =
             Loopex.prepared_session_configuration(activation)

    assert {:ok, holder} = :gen_event.call(manager, Interrupt, {:prepared_holder, activation})
    monitor = Process.monitor(holder)
    assert self() in elem(Process.info(holder, :monitored_by), 1)
    assert {:ok, session} = Interrupt.activate_prepared(activation)
    assert session == f.session
    assert_receive {:DOWN, ^monitor, :process, ^holder, :normal}, 1000
    assert %{exit_code: 0, cleanup: :confirmed} = ChatDriver.run(driver)
    assert :ok = Loopex.stop(f.fixture.runtime)
    assert {:ok, :ordinary} = Interrupt.finish_chat(manager, ref)
    assert ChatDriver.close(driver, :confirmed) == 0
    assert length(Loopex.AgentLoopTestModel.dispatched(f.fixture.model)) == 1
  end

  test "an installed prepared chat signal fences holder activation without dispatch", f do
    {:ok, {:prepared, activation}} =
      Loopex.prepare_resume_session(f.fixture.runtime, f.session, "resume")

    {:ok, driver} = driver(f)
    {:ok, _} = ChatDriver.prepare(driver)
    ref = make_ref()
    assert {:ok, manager} = Interrupt.install_chat(driver, ref, 5000, activation)
    assert :ok = :gen_event.sync_notify(manager, :sigterm)
    assert %{exit_code: 1, cleanup: :confirmed} = ChatDriver.run(driver)
    assert {:error, :resume_activation_fenced} = Interrupt.activate_prepared(activation)
    assert Loopex.AgentLoopTestModel.dispatched(f.fixture.model) == []
    assert Agent.get(f.fixture.executor, & &1.jobs) == []
    assert {"one\n/wait\n/quit\n", ""} == StringIO.contents(f.input)
    assert {:ok, :interrupted} = Interrupt.finish_chat(manager, ref)
    assert ChatDriver.close(driver, :confirmed, 1) == 1
  end

  test "prepared chat abandonment uses the acknowledged holder and releases it", f do
    {:ok, {:prepared, activation}} =
      Loopex.prepare_resume_session(f.fixture.runtime, f.session, "resume")

    {:ok, driver} = driver(f)
    {:ok, _} = ChatDriver.prepare(driver)
    ref = make_ref()
    assert {:ok, manager} = Interrupt.install_chat(driver, ref, 5000, activation)
    assert {:ok, holder} = :gen_event.call(manager, Interrupt, {:prepared_holder, activation})
    monitor = Process.monitor(holder)
    assert :ok = Interrupt.abandon_prepared(activation)
    assert_receive {:DOWN, ^monitor, :process, ^holder, :normal}, 1000

    assert {:error, :resume_activation_abandoned} =
             Loopex.prepared_session_configuration(activation)

    ChatDriver.interrupt(driver)
    assert %{exit_code: 1, cleanup: :confirmed} = ChatDriver.run(driver)
    assert {:ok, :ordinary} = Interrupt.finish_chat(manager, ref)
    assert ChatDriver.close(driver, :confirmed) == 1
    assert Loopex.AgentLoopTestModel.dispatched(f.fixture.model) == []
  end

  test "driver loss withdraws a prepared chat holder and abandons before activation", f do
    Process.flag(:trap_exit, true)

    {:ok, {:prepared, activation}} =
      Loopex.prepare_resume_session(f.fixture.runtime, f.session, "resume")

    {:ok, driver} = driver(f)
    {:ok, _} = ChatDriver.prepare(driver)
    ref = make_ref()
    assert {:ok, manager} = Interrupt.install_chat(driver, ref, 5000, activation)
    assert {:ok, holder} = :gen_event.call(manager, Interrupt, {:prepared_holder, activation})
    monitor = Process.monitor(holder)
    assert self() in elem(Process.info(holder, :monitored_by), 1)
    Process.exit(driver, :kill)
    assert_receive {:EXIT, ^driver, :killed}, 1000
    assert_receive {^manager, ^ref, :chat_driver_down}, 1000
    assert_receive {:DOWN, ^monitor, :process, ^holder, :normal}, 1000
    assert {:error, :prepared_activation_not_installed} = Interrupt.activate_prepared(activation)
    await_abandoned(activation, System.monotonic_time(:millisecond) + 1000)
    assert Loopex.AgentLoopTestModel.dispatched(f.fixture.model) == []
    assert Agent.get(f.fixture.executor, & &1.jobs) == []
    assert {"one\n/wait\n/quit\n", ""} == StringIO.contents(f.input)
    assert {:error, :interrupt_handler_unavailable} = Interrupt.finish_chat(manager, ref)
    assert [:erl_signal_handler] == :gen_event.which_handlers(manager)
  end

  test "duplicate prepared installation retains its original guarded holder", f do
    {:ok, {:prepared, activation}} =
      Loopex.prepare_resume_session(f.fixture.runtime, f.session, "resume")

    {:ok, driver} = driver(f)
    {:ok, _} = ChatDriver.prepare(driver)
    ref = make_ref()
    assert {:ok, manager} = Interrupt.install_chat(driver, ref, 5000, activation)
    assert {:ok, holder} = :gen_event.call(manager, Interrupt, {:prepared_holder, activation})

    assert {:error, :interrupt_already_installed} =
             Interrupt.install_chat(driver, make_ref(), 5000, activation)

    assert {:ok, ^holder} = :gen_event.call(manager, Interrupt, {:prepared_holder, activation})
    assert Interrupt.chat_live(manager, ref)
    assert {:ok, _} = Interrupt.activate_prepared(activation)
    assert %{exit_code: 0} = ChatDriver.run(driver)
    assert {:ok, :ordinary} = Interrupt.finish_chat(manager, ref)
    assert ChatDriver.close(driver, :confirmed) == 0
  end

  test "a signal after input finished is reflected in the final closing exit", f do
    {:ok, driver} = driver(f)
    {:ok, _} = ChatDriver.prepare(driver)
    ref = make_ref()
    assert {:ok, manager} = Interrupt.install_chat(driver, ref, 5000)
    assert %{exit_code: 0, cleanup: :confirmed} = ChatDriver.run(driver)
    assert :ok = Loopex.stop(f.fixture.runtime)
    assert :ok = :gen_event.sync_notify(manager, :sigterm)
    assert {:ok, :interrupted} = Interrupt.finish_chat(manager, ref)
    assert ChatDriver.close(driver, :confirmed, 1) == 1
    {_, transcript} = StringIO.contents(f.output)
    assert transcript =~ "\"exit_code\":1"
    assert transcript =~ "\"cleanup\":\"confirmed\""
  end

  test "each installed signal reaches the prepared driver and fences actual resume activation",
       f do
    for signal <- Interrupt.signals() do
      {:ok, {:prepared, activation}} =
        Loopex.prepare_resume_session(f.fixture.runtime, f.session, "resume-#{signal}")

      {:ok, driver} = driver(f)
      assert {:ok, _} = ChatDriver.prepare(driver)
      ref = make_ref()
      assert {:ok, manager} = Interrupt.install_chat(driver, ref, 5000)
      assert :ok = :gen_event.sync_notify(manager, signal)
      assert %{exit_code: 1, cleanup: :confirmed} = ChatDriver.run(driver)
      assert {:error, :resume_activation_fenced} = Loopex.activate_resume(activation)
      assert {"one\n/wait\n/quit\n", ""} == StringIO.contents(f.input)
      assert Loopex.AgentLoopTestModel.dispatched(f.fixture.model) == []
      assert ChatDriver.close(driver, :confirmed) == 1
      assert {:ok, :interrupted} = Interrupt.finish_chat(manager, ref)
    end
  end

  test "second signal resolves a blocked unknown admission through the driver without another abort",
       f do
    test = self()

    facade = fn module, function, args ->
      case {function, args} do
        {:command, [_, %{type: :prompt} = command]} ->
          send(test, {:blocked_admission, self(), command.command_id})
          receive do: (:release -> apply(module, function, args))

        {:command, [_, %{type: :abort}]} ->
          send(test, :competing_abort)
          apply(module, function, args)

        _ ->
          apply(module, function, args)
      end
    end

    host =
      spawn(fn ->
        {:ok, driver} = driver(f, facade: facade)
        {:ok, _} = ChatDriver.prepare(driver)
        ref = make_ref()
        result = Interrupt.install_chat(driver, ref, 5000)
        send(test, {:installed, self(), driver, ref, result})
        send(test, {:run, self(), ChatDriver.run(driver)})

        receive do
          :close ->
            code = ChatDriver.close(driver, :confirmed)
            finished = Interrupt.finish_chat(f.manager, ref)
            send(test, {:closed, self(), code, finished})
        end
      end)

    on_exit(fn -> if Process.alive?(host), do: Process.exit(host, :kill) end)
    assert_receive {:installed, ^host, _driver, _ref, {:ok, manager}}, 1000
    assert_receive {:blocked_admission, worker, _id}, 1000
    monitor = Process.monitor(worker)
    assert self() in elem(Process.info(worker, :monitored_by), 1)
    assert :ok = :gen_event.sync_notify(manager, :sigterm)
    assert :ok = :gen_event.sync_notify(manager, :sigterm)
    assert_receive {:run, ^host, %{exit_code: 1, cleanup: :unknown}}, 1000
    assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}, 1000
    refute_receive :competing_abort
    assert Loopex.AgentLoopTestModel.dispatched(f.fixture.model) == []
    assert {"/wait\n/quit\n", ""} == StringIO.contents(f.input)
    send(host, :close)
    assert_receive {:closed, ^host, 1, {:ok, :interrupted}}, 1000
    {_, transcript} = StringIO.contents(f.output)
    assert transcript =~ "\"cleanup\":\"unknown\""
    assert transcript =~ "\"outcome\":\"commit_unknown\""
  end

  test "wrong references and competing chat or ask installation preserve the incumbent", f do
    {:ok, driver} = driver(f)
    {:ok, _} = ChatDriver.prepare(driver)
    ref = make_ref()
    assert {:ok, manager} = Interrupt.install_chat(driver, ref, 5000)
    assert {:error, :interrupt_handler_unavailable} = Interrupt.finish_chat(manager, make_ref())

    assert {:error, :interrupt_handler_unavailable} =
             Interrupt.install_chat(driver, make_ref(), 5000)

    assert {:error, :interrupt_handler_unavailable} = Interrupt.install_ask(self(), make_ref())
    assert Interrupt.chat_live(manager, ref)
    assert {:ok, :ordinary} = Interrupt.finish_chat(manager, ref)
    assert %{exit_code: 0} = ChatDriver.run(driver)
    assert ChatDriver.close(driver, :confirmed) == 0
  end

  test "invalid cleanup or a foreign handler refuses installation without manager mutation", f do
    {:ok, driver} = driver(f)
    before = :gen_event.which_handlers(f.manager)

    for grace <- [0, -1, Integer.pow(2, 64), "5000"] do
      assert {:error, :interrupt_handler_unavailable} =
               Interrupt.install_chat(driver, make_ref(), grace)

      assert :gen_event.which_handlers(f.manager) == before
    end

    foreign = {:erl_signal_handler, :foreign}
    assert :ok = :gen_event.add_handler(f.manager, foreign, [])
    before = :gen_event.which_handlers(f.manager)

    assert {:error, :interrupt_handler_unavailable} =
             Interrupt.install_chat(driver, make_ref(), 5000)

    assert :gen_event.which_handlers(f.manager) == before
    assert %{exit_code: 0} = ChatDriver.run(driver)
    assert ChatDriver.close(driver, :confirmed) == 0
  end

  test "normal host loss retires its exact route and all driver actors", f do
    test = self()

    {host, monitor} =
      spawn_monitor(fn ->
        {:ok, driver} = driver(f)
        {:ok, _} = ChatDriver.prepare(driver)
        ref = make_ref()
        send(test, {:installed, self(), driver, ref, Interrupt.install_chat(driver, ref, 5000)})
        receive do: (:exit -> :ok)
      end)

    assert_receive {:installed, ^host, driver, _ref, {:ok, manager}}, 1000
    state = :sys.get_state(driver)
    pids = [driver, state.writer | Map.keys(state.workers)]
    monitors = Enum.map(pids, &{&1, Process.monitor(&1)})
    for pid <- pids, do: assert(self() in elem(Process.info(pid, :monitored_by), 1))
    send(host, :exit)
    assert_receive {:DOWN, ^monitor, :process, ^host, :normal}, 1000
    for {pid, ref} <- monitors, do: assert_receive({:DOWN, ^ref, :process, ^pid, _}, 1000)
    await_handlers(manager, [:erl_signal_handler])
  end

  test "abrupt driver loss stays observable and cannot finish as ordinary cleanup", f do
    Process.flag(:trap_exit, true)
    {:ok, driver} = driver(f)
    {:ok, _} = ChatDriver.prepare(driver)
    ref = make_ref()
    assert {:ok, manager} = Interrupt.install_chat(driver, ref, 5000)
    Process.exit(driver, :kill)
    assert_receive {:EXIT, ^driver, :killed}, 1000
    assert_receive {^manager, ^ref, :chat_driver_down}, 1000
    refute Interrupt.chat_live(manager, ref)
    assert {:error, :interrupt_handler_unavailable} = Interrupt.finish_chat(manager, ref)
    assert [:erl_signal_handler] == :gen_event.which_handlers(manager)
  end

  test "handler loss and replacement manager fail exact route observation", f do
    {:ok, driver} = driver(f)
    {:ok, _} = ChatDriver.prepare(driver)
    ref = make_ref()
    assert {:ok, manager} = Interrupt.install_chat(driver, ref, 5000)
    assert :ok = :gen_event.delete_handler(manager, Interrupt, [])
    refute Interrupt.chat_live(manager, ref)
    assert {:error, :interrupt_handler_unavailable} = Interrupt.finish_chat(manager, ref)
    assert :ok = :gen_event.add_handler(manager, :erl_signal_handler, [])
    assert {:ok, ^manager} = Interrupt.install_chat(driver, ref, 5000)
    {:ok, replacement} = :gen_event.start()

    try do
      Process.unregister(:erl_signal_server)
      true = Process.register(replacement, :erl_signal_server)
      refute Interrupt.chat_live(manager, ref)
      assert {:error, :interrupt_handler_unavailable} = Interrupt.finish_chat(manager, ref)
    after
      Process.unregister(:erl_signal_server)
      true = Process.register(manager, :erl_signal_server)
      :gen_event.stop(replacement)
    end

    assert {:ok, :ordinary} = Interrupt.finish_chat(manager, ref)
    assert %{exit_code: 0} = ChatDriver.run(driver)
    assert ChatDriver.close(driver, :confirmed) == 0
  end

  test "a timed-out queued chat installation retires by its exact reference after manager resume",
       f do
    test = self()
    gate = make_ref()
    Application.put_env(:loopex_cli, :ask_install_observed, {test, gate})

    {host, host_monitor} =
      spawn_monitor(fn ->
        {:ok, driver} = driver(f)
        {:ok, _} = ChatDriver.prepare(driver)
        ref = make_ref()
        send(test, {:late_result, self(), Interrupt.install_chat(driver, ref, 5000)})

        receive do
          :cleanup ->
            ChatDriver.run(driver)
            ChatDriver.close(driver, :confirmed)
        end
      end)

    try do
      assert_receive {:ask_install_observed, installer, manager, ^host, _ref}, 1000
      installer_monitor = Process.monitor(installer)
      assert :erlang.suspend_process(manager)
      send(installer, {:ask_install_continue, gate})
      await_queued_swap(manager, System.monotonic_time(:millisecond) + 1000)
      assert_receive {:late_result, ^host, {:error, :interrupt_handler_unavailable}}, 2000
      assert :erlang.resume_process(manager)
      await_handlers(manager, [:erl_signal_handler])
      assert_receive {:DOWN, ^installer_monitor, :process, ^installer, :normal}, 1000
      assert {"one\n/wait\n/quit\n", ""} == StringIO.contents(f.input)
      send(host, :cleanup)
      assert_receive {:DOWN, ^host_monitor, :process, ^host, :normal}, 5000
    after
      Application.delete_env(:loopex_cli, :ask_install_observed)

      if Process.info(f.manager, :status) == {:status, :suspended},
        do: :erlang.resume_process(f.manager)

      if Process.alive?(host), do: Process.exit(host, :kill)
    end
  end

  defp driver(f, options \\ []),
    do:
      ChatDriver.start_link(
        f.fixture.runtime,
        f.session,
        f.input,
        f.output,
        Keyword.put(options, :cleanup_grace_ms, 5000)
      )

  defp await_handlers(manager, expected, cutoff \\ nil) do
    cutoff = cutoff || System.monotonic_time(:millisecond) + 1000
    actual = :gen_event.which_handlers(manager)

    if actual != expected do
      assert System.monotonic_time(:millisecond) < cutoff
      Process.sleep(10)
      await_handlers(manager, expected, cutoff)
    end
  end

  defp await_queued_swap(manager, cutoff) do
    {:messages, messages} = Process.info(manager, :messages)

    unless Enum.any?(messages, &match?({_, _, {:swap_handler, _, _, _, _}}, &1)) do
      assert System.monotonic_time(:millisecond) < cutoff
      Process.sleep(10)
      await_queued_swap(manager, cutoff)
    end
  end

  defp await_abandoned(activation, cutoff) do
    case Loopex.prepared_session_configuration(activation) do
      {:error, :resume_activation_abandoned} ->
        :ok

      {:error, :resume_activation_holder_mismatch} ->
        assert System.monotonic_time(:millisecond) < cutoff
        Process.sleep(10)
        await_abandoned(activation, cutoff)

      other ->
        flunk("prepared owner did not confirm abandonment: #{inspect(other)}")
    end
  end
end
