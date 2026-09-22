defmodule LoopexDaemon.SignalHandlerTest do
  use ExUnit.Case, async: true

  alias LoopexDaemon.SignalHandler

  test "replaces the default handler and routes only exact SIGTERM shapes" do
    {:ok, manager} = :gen_event.start()
    assert :ok = :gen_event.add_handler(manager, :erl_signal_handler, [])
    owner_ref = make_ref()
    test = self()

    set_signal = fn signal, disposition ->
      send(test, {:set_signal, signal, disposition})
      :ok
    end

    assert {:ok, handle} = SignalHandler.install_on(manager, self(), owner_ref, set_signal)
    assert_receive {:set_signal, :sigterm, :handle}
    assert handle.owner_ref == owner_ref
    assert handle.handler in :gen_event.which_handlers(manager)
    refute :erl_signal_handler in :gen_event.which_handlers(manager)

    assert :ok = :gen_event.sync_notify(manager, :sigquit)
    assert :ok = :gen_event.sync_notify(manager, {:sighup, self()})
    refute_receive {:daemon_signal, _, _}
    assert handle.handler in :gen_event.which_handlers(manager)

    assert :ok = :gen_event.sync_notify(manager, :sigterm)
    assert_receive {:daemon_signal, ^owner_ref, :sigterm}

    assert :ok = :gen_event.sync_notify(manager, {:sigterm, self()})
    assert_receive {:daemon_signal, ^owner_ref, :sigterm}
    assert handle.handler in :gen_event.which_handlers(manager)

    assert :ok = SignalHandler.uninstall(handle)
    refute handle.handler in :gen_event.which_handlers(manager)
    assert :ok = :gen_event.stop(manager)
  end

  test "refuses a second daemon handler without replacing the first" do
    {:ok, manager} = :gen_event.start()
    first_ref = make_ref()
    second_ref = make_ref()
    set_signal = fn _signal, _disposition -> :ok end

    assert {:ok, first} = SignalHandler.install_on(manager, self(), first_ref, set_signal)

    assert {:error, :signal_install_failed} =
             SignalHandler.install_on(manager, self(), second_ref, set_signal)

    assert first.handler in :gen_event.which_handlers(manager)
    refute {SignalHandler, second_ref} in :gen_event.which_handlers(manager)

    assert :ok = SignalHandler.uninstall(first)
    assert :ok = :gen_event.stop(manager)
  end

  test "normalizes setup refusal and leaves no daemon handler" do
    {:ok, manager} = :gen_event.start()
    assert :ok = :gen_event.add_handler(manager, :erl_signal_handler, [])
    owner_ref = make_ref()
    set_signal = fn _signal, _disposition -> {:error, :unsupported} end

    assert {:error, :signal_install_failed} =
             SignalHandler.install_on(manager, self(), owner_ref, set_signal)

    refute {SignalHandler, owner_ref} in :gen_event.which_handlers(manager)
    assert :erl_signal_handler in :gen_event.which_handlers(manager)
    assert :ok = :gen_event.stop(manager)
  end
end
