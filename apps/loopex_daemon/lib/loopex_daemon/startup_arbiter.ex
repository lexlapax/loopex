defmodule LoopexDaemon.StartupArbiter do
  @moduledoc """
  ## Concept

  The command process decides whether a prepared daemon may begin accepting
  clients. A visible readiness line alone grants nothing: the owner must still
  prove that every required component is alive, and an earlier stop or failure
  keeps the parked listener closed.

  ## Technical depth

  `arbitrate/7` runs in the command process after the owner has supplied one
  exact readiness request. It starts one monitored whole-line writer, applies
  one absolute deadline, and serializes writer completion, the owner's exact
  signal reference, owner failure, owner authorization and owner loss. Only
  the matching authorization sends the listener's `begin_accept` message.
  """

  require Logger

  alias LoopexDaemon.ExitStatus

  @output_deadline_ms 5_000

  @typedoc false
  @type disposition :: :running | :operator_stop | {:fatal, atom(), pos_integer()}

  @typedoc false
  @type result :: {:disposition, disposition()} | {:hard_halt, atom(), pos_integer()}

  @doc false
  @spec output_deadline_ms() :: 5_000
  def output_deadline_ms, do: @output_deadline_ms

  @doc """
  ## Concept

  Writes readiness and chooses the one startup disposition that may release the
  listener.

  ## Technical depth

  `owner_monitor` is the monitor the command process installed immediately
  after starting the unlinked owner. The same `owner_ref` authenticates the
  installed handler's orderly-stop message. Tests may select a shorter positive
  deadline and another IO device; production uses five seconds and standard
  output.
  """
  @spec arbitrate(pid(), reference(), reference(), reference(), pid(), binary(), keyword()) ::
          result()
  def arbitrate(
        owner_pid,
        owner_monitor,
        owner_ref,
        startup_ref,
        listener_pid,
        line,
        options \\ []
      )
      when is_pid(owner_pid) and is_reference(owner_monitor) and is_reference(owner_ref) and
             is_reference(startup_ref) and is_pid(listener_pid) and is_binary(line) and
             is_list(options) do
    output = Keyword.get(options, :output, :stdio)
    deadline_ms = Keyword.get(options, :deadline_ms, @output_deadline_ms)

    if is_integer(deadline_ms) and deadline_ms > 0 do
      parent = self()
      writer_tag = make_ref()
      deadline = monotonic_ms() + deadline_ms

      {writer, writer_monitor} =
        spawn_monitor(fn -> write_line(parent, writer_tag, output, line) end)

      Logger.debug("loopex daemon readiness write start")

      state = %{
        owner_pid: owner_pid,
        owner_monitor: owner_monitor,
        owner_ref: owner_ref,
        startup_ref: startup_ref,
        listener_pid: listener_pid,
        writer: writer,
        writer_monitor: writer_monitor,
        writer_tag: writer_tag,
        deadline: deadline
      }

      await_write(state)
    else
      raise ArgumentError, "invalid startup arbiter options"
    end
  end

  defp await_write(state) do
    receive_before_deadline(state, fn remaining ->
      receive do
        {:loopex_daemon_readiness_write, tag, :ok} when tag == state.writer_tag ->
          if before_deadline?(state) do
            retire_completed_writer(state)
            Logger.debug("loopex daemon readiness write complete")

            send(
              state.owner_pid,
              {:readiness_output_succeeded, state.owner_ref, state.startup_ref, self()}
            )

            await_authorization(%{state | writer: nil, writer_monitor: nil})
          else
            deadline_wins(state)
          end

        {:loopex_daemon_readiness_write, tag, :error} when tag == state.writer_tag ->
          if before_deadline?(state) do
            retire_completed_writer(state)
            fatal_wins(state, :readiness_write_failed)
          else
            deadline_wins(state)
          end

        {:DOWN, monitor, :process, writer, _reason}
        when monitor == state.writer_monitor and writer == state.writer ->
          if before_deadline?(state),
            do: fatal_wins(%{state | writer: nil, writer_monitor: nil}, :readiness_write_failed),
            else: deadline_wins(%{state | writer: nil, writer_monitor: nil})

        {:daemon_signal, owner_ref, :sigterm} when owner_ref == state.owner_ref ->
          if before_deadline?(state), do: stop_wins(state), else: deadline_wins(state)

        {:readiness_startup_fatal, owner_ref, startup_ref, owner_pid, listener_pid, class, status}
        when owner_ref == state.owner_ref and startup_ref == state.startup_ref and
               owner_pid == state.owner_pid and listener_pid == state.listener_pid ->
          cond do
            not before_deadline?(state) -> deadline_wins(state)
            valid_status?(class, status) -> fatal_wins(state, class)
            true -> await_write(state)
          end

        {:DOWN, monitor, :process, owner_pid, _reason}
        when monitor == state.owner_monitor and owner_pid == state.owner_pid ->
          if before_deadline?(state), do: owner_lost_wins(state), else: deadline_wins(state)
      after
        remaining -> deadline_wins(state)
      end
    end)
  end

  defp await_authorization(state) do
    receive_before_deadline(state, fn remaining ->
      receive do
        {:readiness_release_authorized, owner_ref, startup_ref, owner_pid, listener_pid}
        when owner_ref == state.owner_ref and startup_ref == state.startup_ref and
               owner_pid == state.owner_pid and listener_pid == state.listener_pid ->
          if before_deadline?(state), do: running_wins(state), else: deadline_wins(state)

        {:readiness_startup_fatal, owner_ref, startup_ref, owner_pid, listener_pid, class, status}
        when owner_ref == state.owner_ref and startup_ref == state.startup_ref and
               owner_pid == state.owner_pid and listener_pid == state.listener_pid ->
          cond do
            not before_deadline?(state) -> deadline_wins(state)
            valid_status?(class, status) -> fatal_wins(state, class)
            true -> await_authorization(state)
          end

        {:daemon_signal, owner_ref, :sigterm} when owner_ref == state.owner_ref ->
          if before_deadline?(state), do: stop_wins(state), else: deadline_wins(state)

        {:DOWN, monitor, :process, owner_pid, _reason}
        when monitor == state.owner_monitor and owner_pid == state.owner_pid ->
          if before_deadline?(state), do: owner_lost_wins(state), else: deadline_wins(state)
      after
        remaining -> deadline_wins(state)
      end
    end)
  end

  defp running_wins(state) do
    Logger.debug("loopex daemon readiness gate released")
    send(state.listener_pid, {:begin_accept, state.startup_ref})
    disposition(state, :running)
  end

  defp stop_wins(state) do
    stop_writer(state)
    Logger.debug("loopex daemon readiness stopped")
    disposition(state, :operator_stop)
  end

  defp fatal_wins(state, class) do
    stop_writer(state)
    {:ok, status} = ExitStatus.fetch(class)
    Logger.debug("loopex daemon readiness failed")
    disposition(state, {:fatal, class, status})
  end

  defp owner_lost_wins(state) do
    stop_writer(state)
    {:ok, status} = ExitStatus.fetch(:owner_lost)
    Logger.debug("loopex daemon owner lost during readiness")
    {:disposition, {:fatal, :owner_lost, status}}
  end

  defp deadline_wins(_state) do
    {:ok, status} = ExitStatus.fetch(:readiness_write_failed)
    Logger.debug("loopex daemon readiness deadline expired")
    {:hard_halt, :readiness_write_failed, status}
  end

  defp disposition(state, value) do
    send(state.owner_pid, {:readiness_disposition, state.owner_ref, state.startup_ref, value})
    {:disposition, value}
  end

  defp receive_before_deadline(state, receive_fun) do
    case state.deadline - monotonic_ms() do
      remaining when remaining > 0 -> receive_fun.(remaining)
      _expired -> deadline_wins(state)
    end
  end

  defp before_deadline?(state), do: monotonic_ms() < state.deadline

  defp valid_status?(class, status), do: ExitStatus.fetch(class) == {:ok, status}

  defp retire_completed_writer(state) do
    Process.demonitor(state.writer_monitor, [:flush])
    :ok
  end

  defp stop_writer(%{writer: nil}), do: :ok

  defp stop_writer(state) do
    Process.exit(state.writer, :kill)

    receive do
      {:DOWN, monitor, :process, writer, _reason}
      when monitor == state.writer_monitor and writer == state.writer ->
        :ok
    after
      1_000 ->
        Process.demonitor(state.writer_monitor, [:flush])
        :ok
    end
  end

  defp write_line(parent, tag, output, line) do
    result =
      try do
        case IO.binwrite(output, line) do
          :ok -> :ok
          _refused -> :error
        end
      rescue
        _refused -> :error
      catch
        _kind, _reason -> :error
      end

    send(parent, {:loopex_daemon_readiness_write, tag, result})
  end

  defp monotonic_ms, do: System.monotonic_time(:millisecond)
end
