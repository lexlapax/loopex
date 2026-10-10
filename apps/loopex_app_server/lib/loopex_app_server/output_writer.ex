defmodule Loopex.AppServer.OutputWriter do
  @moduledoc """
  ## Concept

  An owned foreground writer places one already encoded record on inherited
  stdout. It releases that record only after the actual stdout child has been
  waited for and the proxy's entire process group has gone away. A failed writer
  is retired; its host must close the connection, including after a partial or
  complete record whose successful join was not observed.

  ## Technical depth

  This private host component implements accepted ADR 0058. Each admission
  captures a 5,000-ms write cutoff and its following 5,000-ms cleanup cutoff.
  One fixed Bash proxy owns one worker and one fresh 32-byte hexadecimal nonce.
  The proxy uses inherited fd 1 and private fd 3/4; it never uses the BEAM's
  shared IO request path. A positive result requires WRITTEN, CONTINUE, the
  proxy's exact-child wait, JOINED, actual port exit and a successful bounded
  physical process-table observation showing the anchored group absent.

  `start/0` retains its calling owner through an explicit monitor. It has no
  structural parent link that could terminate cleanup when that owner dies.
  `write/2` admits a single strict LF record up to 2 MiB and returns a reference.
  The owner receives `{:loopex_output_writer, writer, reference, result}`.
  On failure it first receives `{:loopex_output_writer_retired, writer,
  reference, reason}` so attachment retirement need not wait for cleanup.
  These are private host messages, never durable facts or public wire records.
  Output capacity remains the caller's charge until this component's terminal
  result; it supplies no queue, cancellation authority or session mutation.
  """

  use GenServer

  alias Loopex.Executor.Local

  @frame_bytes 2_097_152
  @control_bytes 512
  @write_ms 5_000
  @cleanup_ms 5_000
  @request_ms 30_000

  @doc false
  def start, do: GenServer.start(__MODULE__, self())

  @doc false
  def write(writer, frame) do
    if valid_frame?(frame) do
      GenServer.call(writer, {:write, frame}, @request_ms)
    else
      {:error, :invalid_frame}
    end
  end

  @doc false
  def stop(writer), do: GenServer.call(writer, :stop, @request_ms)

  @impl true
  def init(owner) do
    Process.flag(:trap_exit, true)

    {:ok,
     %{
       owner: owner,
       owner_monitor: Process.monitor(owner),
       sealed: false,
       stopping: false,
       stop_from: nil,
       last_cleanup: nil,
       active: nil
     }}
  end

  @impl true
  def handle_call(_request, {caller, _}, %{owner: owner} = state)
      when caller != owner do
    {:reply, {:error, :not_owner}, state}
  end

  def handle_call({:write, _frame}, _from, %{sealed: true} = state),
    do: {:reply, {:error, :retired}, state}

  def handle_call({:write, _frame}, _from, %{active: active} = state)
      when not is_nil(active),
      do: {:reply, {:error, :busy}, state}

  def handle_call({:write, frame}, _from, state) do
    if valid_frame?(frame) do
      admitted = now_ms()
      reference = make_ref()
      nonce = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)

      active = %{
        reference: reference,
        nonce: nonce,
        phase: :starting,
        admitted_at: admitted,
        write_cutoff: admitted + @write_ms,
        cleanup_cutoff: admitted + @write_ms + @cleanup_ms,
        port: nil,
        port_monitor: nil,
        leader: nil,
        group: nil,
        worker: nil,
        frame: frame,
        control: <<>>,
        written: false,
        written_at: nil,
        joined_at: nil,
        continued: false,
        waited: false,
        port_down: false,
        exit_status: nil,
        group_absent: false,
        reason: nil,
        retired_sent: false,
        stop_sent: false,
        write_timer: nil,
        cleanup_timer: nil
      }

      send(self(), {:launch, reference})

      active = %{
        active
        | write_timer: schedule(:write_cutoff, reference, active.write_cutoff),
          cleanup_timer: schedule(:cleanup_cutoff, reference, active.cleanup_cutoff)
      }

      {:reply, {:ok, reference}, %{state | active: active}}
    else
      {:reply, {:error, :invalid_frame}, state}
    end
  end

  def handle_call(
        :stop,
        _from,
        %{active: nil, last_cleanup: %{cleanup: :unproved} = facts} = state
      ),
      do: {:stop, :normal, {:error, :cleanup_unproved, facts}, state}

  def handle_call(:stop, _from, %{active: nil} = state),
    do: {:stop, :normal, {:ok, :idle}, state}

  def handle_call(:stop, from, state) do
    state = %{state | stopping: true, stop_from: from}
    {:noreply, retire(state, :stopped)}
  end

  @impl true
  def handle_info({:launch, reference}, %{active: %{reference: reference} = active} = state) do
    if now_ms() < active.write_cutoff do
      case open_proxy(active.nonce) do
        {:ok, port} ->
          monitor = :erlang.monitor(:port, port)
          active = %{active | port: port, port_monitor: monitor}
          state = %{state | active: active}

          case Port.info(port, :os_pid) do
            {:os_pid, leader} -> {:noreply, %{state | active: %{active | leader: leader}}}
            nil -> {:noreply, retire(state, :leader_unproved)}
          end

        :error ->
          {:noreply, retire(state, :launch_failed)}
      end
    else
      {:noreply, retire(state, :write_expired)}
    end
  end

  def handle_info({port, {:data, bytes}}, %{active: %{port: port} = active} = state)
      when is_binary(bytes) do
    if byte_size(active.control) + byte_size(bytes) <= @control_bytes do
      consume_control(%{state | active: %{active | control: active.control <> bytes}})
    else
      {:noreply, retire(state, :invalid_control)}
    end
  end

  def handle_info({port, {:exit_status, status}}, %{active: %{port: port} = active} = state) do
    state = %{state | active: %{active | exit_status: status}}
    {:noreply, port_ended(state)}
  end

  def handle_info(
        {:DOWN, monitor, :port, port, _reason},
        %{active: %{port: port, port_monitor: monitor} = active} = state
      ) do
    state = %{state | active: %{active | port_down: true}}
    {:noreply, port_ended(state)}
  end

  def handle_info(
        {:DOWN, monitor, :process, owner, _reason},
        %{owner: owner, owner_monitor: monitor} = state
      ) do
    if state.active == nil do
      {:stop, :normal, state}
    else
      {:noreply, retire(%{state | stopping: true}, :owner_lost)}
    end
  end

  def handle_info(
        {:write_cutoff, reference},
        %{active: %{reference: reference, phase: phase}} = state
      )
      when phase != :cleaning,
      do: {:noreply, retire(state, :write_expired)}

  def handle_info(
        {:cleanup_cutoff, reference},
        %{active: %{reference: reference}} = state
      ),
      do: finish(state, false)

  def handle_info(
        {:cleanup, reference},
        %{active: %{reference: reference, phase: :cleaning} = active} = state
      ) do
    state = send_stop(state)

    cond do
      now_ms() >= active.cleanup_cutoff ->
        finish(state, false)

      active.port == nil ->
        finish(state, true)

      active.port_down and is_integer(active.exit_status) ->
        case group_observation(active.leader, active.cleanup_cutoff) do
          {:ok, pairs} ->
            if now_ms() < active.cleanup_cutoff and
                 Enum.all?(pairs, fn {_pid, group} -> group != active.leader end) do
              finish(%{state | active: %{state.active | group_absent: true}}, true)
            else
              later_cleanup(state)
            end

          :unproved ->
            later_cleanup(state)
        end

      true ->
        later_cleanup(state)
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def format_status(status) do
    Map.new(status, fn
      {:state, state} -> {:state, %{sealed: state.sealed, active: state.active != nil}}
      {:message, _message} -> {:message, :redacted}
      {:log, _log} -> {:log, []}
      other -> other
    end)
  end

  defp consume_control(state) do
    case :binary.split(state.active.control, "\n") do
      [record, rest] ->
        state = %{state | active: %{state.active | control: rest}}
        state = control_record(state, record)
        consume_control(state)

      [_partial] ->
        {:noreply, state}
    end
  end

  defp control_record(%{active: %{phase: :starting} = active} = state, record) do
    expected = "READY #{active.nonce} #{active.leader}"

    if record == expected and now_ms() < active.write_cutoff do
      case group_observation(active.leader, active.write_cutoff) do
        {:ok, pairs} ->
          if {active.leader, active.leader} in pairs and now_ms() < active.write_cutoff do
            active = %{active | group: active.leader, phase: :writing}
            state = %{state | active: active}

            bytes = [
              "ALLOW ",
              active.nonce,
              "\nFRAME ",
              active.nonce,
              " ",
              Integer.to_string(byte_size(active.frame)),
              "\n",
              active.frame
            ]

            state = %{state | active: %{active | frame: nil}}
            if command(active.port, bytes), do: state, else: retire(state, :control_lost)
          else
            retire(state, :group_unproved)
          end

        :unproved ->
          retire(state, :group_unproved)
      end
    else
      retire(state, :invalid_control)
    end
  end

  defp control_record(%{active: %{phase: :writing} = active} = state, record) do
    received_at = now_ms()

    cond do
      received_at >= active.write_cutoff ->
        retire(state, :write_expired)

      record == "WRITTEN #{active.nonce}" and not active.written ->
        continue_if_ready(%{state | active: %{active | written: true, written_at: received_at}})

      active.worker == nil ->
        prefix = "STARTED #{active.nonce} "
        prefix_bytes = byte_size(prefix)

        case record do
          <<^prefix::binary-size(^prefix_bytes), worker::binary>> ->
            case decimal_pid(worker) do
              {:ok, pid} when pid != active.leader ->
                continue_if_ready(%{state | active: %{active | worker: pid}})

              _ ->
                retire(state, :invalid_control)
            end

          _ ->
            retire(state, :invalid_control)
        end

      true ->
        retire(state, :invalid_control)
    end
  end

  defp control_record(%{active: %{phase: :waiting} = active} = state, record) do
    received_at = now_ms()

    if record == "JOINED #{active.nonce} #{active.worker}" and
         received_at < active.write_cutoff do
      active = %{active | waited: true, joined_at: received_at, phase: :cleaning}
      state = %{state | active: active}
      send(self(), {:cleanup, active.reference})
      send_stop(state)
    else
      retire(state, :invalid_control)
    end
  end

  defp control_record(state, _record), do: retire(state, :invalid_control)

  # Concept: Bash 3.2 cannot report a subshell's own PID with BASHPID. The
  # leader reports its actual $!; the worker's WRITTEN can race that report.
  # Technical depth: both are single-use, nonce-bound barriers. CONTINUE is
  # sent only after both; the following JOINED must name the exact reported PID.
  defp continue_if_ready(%{active: %{written: true, worker: worker} = active} = state)
       when is_integer(worker) do
    if command(active.port, ["CONTINUE ", active.nonce, "\n"]) do
      %{state | active: %{active | continued: true, phase: :waiting}}
    else
      retire(state, :control_lost)
    end
  end

  defp continue_if_ready(state), do: state

  defp retire(%{active: active} = state, reason) do
    reason = active.reason || reason

    unless active.retired_sent do
      send(
        state.owner,
        {:loopex_output_writer_retired, self(), active.reference, reason}
      )
    end

    active = %{active | frame: nil, phase: :cleaning, reason: reason, retired_sent: true}
    send(self(), {:cleanup, active.reference})
    %{state | active: active, sealed: true} |> send_stop() |> resume_leader()
  end

  # Concept: a retired writer lets its own stopped group run its termination.
  # Technical depth: a job-control stop is not undone by Linux on the leader's
  # session-led, already orphaned group, so the leader would never read STOP or
  # reach its pipe timeout. Resuming only the leader is not enough: a leader in
  # `wait` for a stopped worker stays blocked, because Bash without job control
  # does not return from `wait` for a stopped child. While the anchored group is
  # observed live with the leader as its group ID, SIGCONT resumes that whole
  # group; it grants no new authority, and termination stays the live leader's
  # own group kill (ADR 0058).
  defp resume_leader(
         %{active: %{leader: leader, group: leader, port_down: false} = active} = state
       )
       when is_integer(leader) and not is_nil(active.port) do
    with {:ok, pairs} <- group_observation(leader, active.cleanup_cutoff),
         true <- {leader, leader} in pairs,
         remaining when remaining > 2 <- active.cleanup_cutoff - now_ms() do
      _ =
        Local.answer_within(
          "/bin/kill",
          ["-CONT", "--", "-" <> Integer.to_string(leader)],
          min(500, remaining)
        )
    end

    state
  end

  defp resume_leader(state), do: state

  defp send_stop(%{active: %{stop_sent: false, port: port} = active} = state)
       when not is_nil(port) do
    if command(port, ["STOP ", active.nonce, "\n"]) do
      %{state | active: %{active | stop_sent: true}}
    else
      state
    end
  end

  defp send_stop(state), do: state

  defp port_ended(%{active: active} = state) do
    cond do
      active.phase != :cleaning ->
        retire(state, :control_eof)

      active.control != <<>> ->
        retire(state, :invalid_control)

      true ->
        send(self(), {:cleanup, active.reference})
        state
    end
  end

  defp later_cleanup(state) do
    Process.send_after(
      self(),
      {:cleanup, state.active.reference},
      min(25, max(0, state.active.cleanup_cutoff - now_ms()))
    )

    {:noreply, state}
  end

  defp finish(%{active: active} = state, proved) do
    completed_at = now_ms()
    proved = proved and completed_at < active.cleanup_cutoff
    Process.cancel_timer(active.write_timer)
    Process.cancel_timer(active.cleanup_timer)
    # Concept: closing a driver after an unproved episode prevents local reuse
    # but supplies no process or successful cleanup acknowledgment.
    # Technical depth: a positive verdict needs actual exit_status and DOWN
    # plus physical group absence, or evidence that no proxy was ever opened.
    if not proved and active.port != nil and not active.port_down do
      try do
        Port.close(active.port)
      rescue
        ArgumentError -> :ok
      end
    end

    facts = %{
      leader: active.leader,
      group: active.group,
      worker: active.worker,
      worker_waited: active.waited,
      port_down: active.port_down,
      port_exit_status: active.exit_status,
      group_absent: active.group_absent,
      cleanup: if(proved, do: :joined, else: :unproved),
      admitted_at: active.admitted_at,
      written_at: active.written_at,
      joined_at: active.joined_at,
      cleanup_observed_at: if(proved, do: completed_at, else: nil),
      write_cutoff: active.write_cutoff,
      cleanup_cutoff: active.cleanup_cutoff
    }

    result =
      if proved and active.reason == nil and active.waited and active.continued do
        {:ok, facts}
      else
        {:error, if(proved, do: active.reason, else: :cleanup_unproved), facts}
      end

    send(state.owner, {:loopex_output_writer, self(), active.reference, result})

    if state.stop_from != nil do
      reply = if proved, do: {:ok, facts}, else: {:error, :cleanup_unproved, facts}
      GenServer.reply(state.stop_from, reply)
    end

    state = %{
      state
      | active: nil,
        sealed: state.sealed or not proved,
        stop_from: nil,
        last_cleanup: facts
    }

    if state.stopping, do: {:stop, :normal, state}, else: {:noreply, state}
  end

  defp group_observation(leader, cutoff) when is_integer(leader) and leader > 0 do
    remaining = cutoff - now_ms()

    if remaining > 2 do
      case Local.answer_within(
             "/bin/ps",
             ["-e", "-o", "pid=", "-o", "pgid="],
             min(500, div(remaining, 2))
           ) do
        {bytes, 0} ->
          lines = String.split(bytes, "\n", trim: true)

          if lines != [] and now_ms() < cutoff do
            Enum.reduce_while(lines, {:ok, []}, fn line, {:ok, pairs} ->
              case String.split(line) do
                [pid, group] ->
                  with {:ok, pid} <- decimal_pid(pid), {:ok, group} <- decimal_group(group) do
                    {:cont, {:ok, [{pid, group} | pairs]}}
                  else
                    _ -> {:halt, :unproved}
                  end

                _ ->
                  {:halt, :unproved}
              end
            end)
          else
            :unproved
          end

        _ ->
          :unproved
      end
    else
      :unproved
    end
  end

  defp group_observation(_leader, _cutoff), do: :unproved

  defp decimal_group("0"), do: {:ok, 0}
  defp decimal_group(bytes), do: decimal_pid(bytes)

  defp decimal_pid(bytes) do
    case Integer.parse(bytes) do
      {pid, ""} when pid > 0 ->
        if Integer.to_string(pid) == bytes, do: {:ok, pid}, else: :error

      _ ->
        :error
    end
  end

  defp command(port, bytes) do
    Port.command(port, bytes, [:nosuspend])
  rescue
    ArgumentError -> false
  end

  defp open_proxy(nonce) do
    script = Application.app_dir(:loopex_app_server, "priv/foreground_output_proxy.bash")

    {:ok,
     Port.open({:spawn_executable, ~c"/bin/bash"}, [
       :binary,
       :exit_status,
       :nouse_stdio,
       :hide,
       {:args,
        [~c"--noprofile", ~c"--norc", String.to_charlist(script), String.to_charlist(nonce)]},
       {:env, proxy_environment()}
     ])}
  rescue
    _ -> :error
  end

  defp proxy_environment do
    excluded = ~w(BASH_ENV ENV LOOPEX_PROVIDER_API_KEY OPENAI_API_KEY ANTHROPIC_API_KEY
                  ELIXIR_ERL_OPTIONS ERL_AFLAGS ERL_FLAGS ERL_ZFLAGS LD_PRELOAD
                  DYLD_INSERT_LIBRARIES DYLD_LIBRARY_PATH)

    clear = for {name, _value} <- System.get_env(), do: {String.to_charlist(name), false}

    clear ++
      Enum.map(excluded, &{String.to_charlist(&1), false}) ++
      [{~c"PATH", ~c"/usr/bin:/bin"}, {~c"LC_ALL", ~c"C"}]
  end

  defp valid_frame?(frame) when is_binary(frame) and byte_size(frame) in 2..@frame_bytes do
    size = byte_size(frame) - 1
    <<record::binary-size(^size), last>> = frame

    last == 10 and String.valid?(record) and
      :binary.match(record, ["\n", "\r", <<0>>]) == :nomatch
  end

  defp valid_frame?(_frame), do: false
  defp now_ms, do: System.monotonic_time(:millisecond)

  defp schedule(kind, reference, cutoff),
    do: Process.send_after(self(), {kind, reference}, max(0, cutoff - now_ms()))
end
