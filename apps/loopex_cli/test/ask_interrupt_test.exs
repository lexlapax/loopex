defmodule LoopexCli.AskInterruptTest do
  use ExUnit.Case, async: false

  alias LoopexCli.Interrupt

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

    %{manager: manager}
  end

  test "ordinary finish restores the default handler in one manager turn", %{manager: manager} do
    reference = make_ref()

    assert {:ok, ^manager} = Interrupt.install_ask(self(), reference)
    assert [Interrupt] = :gen_event.which_handlers(manager)
    assert Interrupt.ask_live(manager, reference)
    assert Interrupt.ask_phase(manager, reference) == :idle
    assert Interrupt.ask_phase(manager, make_ref()) == :unavailable
    refute Interrupt.ask_live(manager, make_ref())
    assert {:ok, :ordinary} = Interrupt.finish_ask(manager, reference)
    assert [:erl_signal_handler] = :gen_event.which_handlers(manager)
    refute Interrupt.ask_live(manager, reference)
  end

  if Code.ensure_loaded?(:prim_tty_sighandler) do
    test "the OTP tty handler remains installed through ask and finish", %{manager: manager} do
      tty_state = %{parent: self(), reader: make_ref()}
      assert :ok = :gen_event.add_handler(manager, :prim_tty_sighandler, tty_state)
      reference = make_ref()

      assert {:ok, ^manager} = Interrupt.install_ask(self(), reference)

      assert Enum.sort(:gen_event.which_handlers(manager)) ==
               Enum.sort([Interrupt, :prim_tty_sighandler])

      assert {:ok, :ordinary} = Interrupt.finish_ask(manager, reference)

      assert Enum.sort(:gen_event.which_handlers(manager)) ==
               [:erl_signal_handler, :prim_tty_sighandler]
    end

    test "ask can install with only OTP's tty handler and restores the default", %{
      manager: manager
    } do
      assert :ok = :gen_event.delete_handler(manager, :erl_signal_handler, [])
      tty_state = %{parent: self(), reader: make_ref()}
      assert :ok = :gen_event.add_handler(manager, :prim_tty_sighandler, tty_state)
      reference = make_ref()

      assert {:ok, ^manager} = Interrupt.install_ask(self(), reference)

      assert Enum.sort(:gen_event.which_handlers(manager)) ==
               Enum.sort([Interrupt, :prim_tty_sighandler])

      assert {:ok, :ordinary} = Interrupt.finish_ask(manager, reference)

      assert Enum.sort(:gen_event.which_handlers(manager)) ==
               [:erl_signal_handler, :prim_tty_sighandler]
    end
  end

  test "an unrelated pre-existing handler is refused without changing ownership", %{
    manager: manager
  } do
    foreign = {:erl_signal_handler, :foreign}
    assert :ok = :gen_event.add_handler(manager, foreign, [])
    before = :gen_event.which_handlers(manager)

    assert {:error, :interrupt_handler_unavailable} = Interrupt.install_ask(self(), make_ref())
    assert :gen_event.which_handlers(manager) == before
  end

  test "a first signal wins only when serialized before finish", %{manager: manager} do
    reference = make_ref()
    assert {:ok, ^manager} = Interrupt.install_ask(self(), reference)

    :ok = :gen_event.notify(manager, :sigterm)
    assert_receive {^manager, ^reference, :interrupt}, 1_000
    assert Interrupt.ask_phase(manager, reference) == :stopping
    refute_receive {^manager, ^reference, :interrupt}, 0

    assert {:ok, :interrupted} = Interrupt.finish_ask(manager, reference)
    assert [:erl_signal_handler] = :gen_event.which_handlers(manager)
  end

  test "wrong reference and duplicate installation leave the incumbent intact", %{
    manager: manager
  } do
    reference = make_ref()
    assert {:ok, ^manager} = Interrupt.install_ask(self(), reference)

    assert {:error, :interrupt_handler_unavailable} =
             Interrupt.finish_ask(manager, make_ref())

    assert {:error, :interrupt_handler_unavailable} =
             Interrupt.install_ask(self(), make_ref())

    assert [Interrupt] = :gen_event.which_handlers(manager)
    assert {:ok, :ordinary} = Interrupt.finish_ask(manager, reference)
    assert [:erl_signal_handler] = :gen_event.which_handlers(manager)
  end

  test "main-process loss retires only its ask handler", %{manager: manager} do
    parent = self()

    {main, main_monitor} =
      spawn_monitor(fn ->
        reference = make_ref()
        send(parent, {:installed, self(), reference, Interrupt.install_ask(self(), reference)})

        receive do
          :release -> :ok
        end
      end)

    assert {:installed, ^main, _reference, {:ok, ^manager}} =
             await_main(main, main_monitor, :installed)

    assert [Interrupt] = :gen_event.which_handlers(manager)
    send(main, :release)
    assert_receive {:DOWN, ^main_monitor, :process, ^main, :normal}, 1_000
    assert_handlers(manager, [:erl_signal_handler])
  end

  test "a live manager that loses its registered name cannot finish ask", %{manager: manager} do
    reference = make_ref()
    assert {:ok, ^manager} = Interrupt.install_ask(self(), reference)
    {:ok, replacement} = :gen_event.start()

    try do
      Process.unregister(:erl_signal_server)
      true = Process.register(replacement, :erl_signal_server)
      refute Interrupt.ask_live(manager, reference)

      assert {:error, :interrupt_handler_unavailable} =
               Interrupt.finish_ask(manager, reference)

      assert [Interrupt] = :gen_event.which_handlers(manager)
    after
      if Process.whereis(:erl_signal_server) == replacement,
        do: Process.unregister(:erl_signal_server)

      if Process.alive?(replacement), do: :gen_event.stop(replacement)
      if Process.alive?(manager), do: Process.register(manager, :erl_signal_server)
    end

    assert {:ok, :ordinary} = Interrupt.finish_ask(manager, reference)
    assert [:erl_signal_handler] = :gen_event.which_handlers(manager)
  end

  test "handler removal is visible even while its manager remains live", %{manager: manager} do
    reference = make_ref()
    assert {:ok, ^manager} = Interrupt.install_ask(self(), reference)
    assert Interrupt.ask_live(manager, reference)
    assert :ok = :gen_event.delete_handler(manager, Interrupt, :fault_injected)
    refute Interrupt.ask_live(manager, reference)
  end

  test "a swap queued after installation timeout is retired when the manager resumes", %{
    manager: manager
  } do
    parent = self()
    gate = make_ref()
    Application.put_env(:loopex_cli, :ask_install_observed, {parent, gate})

    {main, main_monitor} =
      spawn_monitor(fn ->
        reference = make_ref()
        send(parent, {:late_install_result, self(), Interrupt.install_ask(self(), reference)})

        receive do
          :release -> :ok
        end
      end)

    try do
      assert {:ask_install_observed, installer, ^manager, ^main, _reference} =
               await_main(main, main_monitor, :ask_install_observed)

      :erlang.trace_pattern({Interrupt, :init, 1}, true, [:global])
      :erlang.trace(manager, true, [:call])
      assert :erlang.suspend_process(manager)
      send(installer, {:ask_install_continue, gate})
      assert_queued_swap(manager)

      assert {:late_install_result, ^main, {:error, :interrupt_handler_unavailable}} =
               await_main(main, main_monitor, :late_install_result)

      assert :erlang.resume_process(manager)
      assert_receive {:trace, ^manager, :call, {Interrupt, :init, [_]}}, 1_000
      assert_handlers(manager, [:erl_signal_handler])
      send(main, :release)
      assert_receive {:DOWN, ^main_monitor, :process, ^main, :normal}, 1_000
    after
      :erlang.trace(manager, false, [:call])
      :erlang.trace_pattern({Interrupt, :init, 1}, false, [:global])
      Application.delete_env(:loopex_cli, :ask_install_observed)
      if suspended?(manager), do: :erlang.resume_process(manager)
      send(main, :release)
    end
  end

  test "an installer retires when its main dies before the admission handshake", %{
    manager: manager
  } do
    parent = self()
    gate = make_ref()
    Application.put_env(:loopex_cli, :ask_install_observed, {parent, gate})

    {main, main_monitor} =
      spawn_monitor(fn ->
        reference = make_ref()
        send(parent, {:main_install_result, Interrupt.install_ask(self(), reference)})
      end)

    try do
      assert {:ask_install_observed, installer, ^manager, ^main, _reference} =
               await_main(main, main_monitor, :ask_install_observed)

      installer_monitor = Process.monitor(installer)
      assert :erlang.suspend_process(main)
      send(installer, {:ask_install_continue, gate})
      assert_handlers(manager, [Interrupt])
      assert Process.alive?(installer)

      Process.exit(main, :kill)
      assert_receive {:DOWN, ^main_monitor, :process, ^main, :killed}, 1_000
      assert_handlers(manager, [:erl_signal_handler])
      assert_receive {:DOWN, ^installer_monitor, :process, ^installer, :normal}, 1_000
    after
      Application.delete_env(:loopex_cli, :ask_install_observed)
      if Process.alive?(main), do: Process.exit(main, :kill)
    end
  end

  # Concept: every wait below ends on the awaited actor's own progress, never
  # on a test clock.
  # Technical depth: the main process, its installer and the signal manager
  # run in their own processes, so a fixed window would measure host-load
  # scheduling rather than the product. Reports end on the tagged message or
  # the main process's DOWN; polls end on the awaited state; the ExUnit test
  # timeout bounds both.
  defp await_main(main, monitor, tag) do
    receive do
      message when is_tuple(message) and elem(message, 0) == tag ->
        message

      {:DOWN, ^monitor, :process, ^main, reason} ->
        flunk("main exited before #{inspect(tag)}: #{inspect(reason)}")
    end
  end

  defp assert_handlers(manager, expected) do
    if :gen_event.which_handlers(manager) != expected do
      Process.sleep(10)
      assert_handlers(manager, expected)
    end
  end

  defp assert_queued_swap(manager) do
    {:messages, messages} = Process.info(manager, :messages)

    unless Enum.any?(messages, &match?({_, _, {:swap_handler, _, _, _, _}}, &1)) do
      Process.sleep(10)
      assert_queued_swap(manager)
    end
  end

  defp suspended?(manager) do
    case Process.info(manager, :status) do
      {:status, :suspended} -> true
      _ -> false
    end
  end
end
