defmodule LoopexDaemon.Sentinel do
  @moduledoc """
  ## Concept

  The command process is the daemon's lifecycle sentinel. It survives every
  way the daemon owner can end, routes every stop signal, alone decides
  whether the parked listener opens, and turns the daemon's outcome into one
  exact operating-system exit status.

  ## Technical depth

  `run/2` installs the `SIGTERM` route before any daemon resource exists,
  starts the owner unlinked with `GenServer.start/3`, monitors it and only
  then sends the exact `{:go, owner_ref, sentinel}` gate. Before readiness
  every signal is forwarded to the owner; during readiness
  `LoopexDaemon.StartupArbiter` consumes it; after the gate opens it is
  forwarded again for the orderly stop. The first fatal class the owner
  latches wins over any later report and arms a fixed 35-second watchdog, so
  a blocked teardown cannot hold the process past that bound. Owner death
  without a latch is `owner_lost`. The sentinel performs no daemon cleanup
  and no synchronous IO of its own beyond the arbiter's bounded writer.
  """

  require Logger

  alias LoopexDaemon.{ExitStatus, Service, SignalHandler, StartupArbiter}

  @fatal_watchdog_ms 35_000

  @doc """
  ## Concept

  Runs one daemon lifetime to completion and returns its exit status.

  ## Technical depth

  `options` accepts `:output` for the readiness device, `:install_signals`
  (default `true`) and `:notify`, a pid told the exact owner reference once
  the gate is sent so a test can route a stop without an operating-system
  signal. A readiness deadline hard-halt returns its status immediately.
  """
  @spec run(keyword(), keyword()) :: non_neg_integer()
  def run(service_options, options \\ []) when is_list(service_options) and is_list(options) do
    owner_ref = make_ref()

    case install(Keyword.get(options, :install_signals, true), owner_ref) do
      {:ok, handle} ->
        status = supervise(service_options, options, owner_ref)
        uninstall(handle)
        status

      {:error, :signal_install_failed} ->
        {:ok, status} = ExitStatus.fetch(:signal_install_failed)
        status
    end
  end

  defp supervise(service_options, options, owner_ref) do
    {:ok, owner} = Service.start(service_options)
    monitor = Process.monitor(owner)
    send(owner, {:go, owner_ref, self()})

    case Keyword.get(options, :notify) do
      pid when is_pid(pid) -> send(pid, {:loopex_daemon_sentinel, self(), owner_ref, owner})
      _none -> :ok
    end

    await(%{
      owner: owner,
      monitor: monitor,
      owner_ref: owner_ref,
      output: Keyword.get(options, :output, :stdio),
      latched: nil,
      watchdog: nil
    })
  end

  defp await(state) do
    %{owner: owner, monitor: monitor, owner_ref: owner_ref} = state

    receive do
      {:daemon_signal, ^owner_ref, :sigterm} ->
        send(owner, {:daemon_signal, owner_ref, :sigterm})
        await(state)

      {:begin_readiness, ^owner_ref, startup_ref, listener, line} ->
        case StartupArbiter.arbitrate(
               owner,
               monitor,
               owner_ref,
               startup_ref,
               listener,
               line,
               output: state.output
             ) do
          {:disposition, :running} ->
            await(state)

          {:disposition, :operator_stop} ->
            await(state)

          {:disposition, {:fatal, class, status}} ->
            await(latch(state, class, status))

          {:hard_halt, _class, status} ->
            status
        end

      {:daemon_fatal, ^owner_ref, class, status} ->
        await(latch(state, class, status))

      {:daemon_exit, ^owner_ref, status} ->
        Process.demonitor(monitor, [:flush])
        final_status(state, status)

      {:DOWN, ^monitor, :process, ^owner, _reason} ->
        {:ok, owner_lost} = ExitStatus.fetch(:owner_lost)
        final_status(state, owner_lost)

      {:sentinel_watchdog, ^owner_ref} ->
        Logger.debug("loopex daemon sentinel watchdog expired")
        final_status(state, 0)
    end
  end

  # Concept: the first fatal class is the operator's answer; later reports
  # cannot replace it.
  defp latch(%{latched: nil} = state, class, status) do
    timer = Process.send_after(self(), {:sentinel_watchdog, state.owner_ref}, @fatal_watchdog_ms)
    Logger.debug("loopex daemon fatal class latched")
    %{state | latched: {class, status}, watchdog: timer}
  end

  defp latch(state, _class, _status), do: state

  defp final_status(%{latched: {_class, status}}, _reported), do: status
  defp final_status(_state, reported), do: reported

  defp install(false, _owner_ref), do: {:ok, nil}
  defp install(true, owner_ref), do: SignalHandler.install(self(), owner_ref)

  defp uninstall(nil), do: :ok
  defp uninstall(handle), do: SignalHandler.uninstall(handle)
end
