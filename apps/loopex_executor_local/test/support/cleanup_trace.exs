defmodule Loopex.Executor.Local.CodingToolsTest.CleanupTrace do
  @moduledoc false

  import ExUnit.Assertions, only: [assert: 2]
  @module Loopex.Executor.Local
  @calls [
    finish_guarded_output: 8,
    guard_children_gone?: 2,
    process_table_within: 2,
    await_launch_guard_exit: 7,
    kill_guarded_helper: 3,
    finish_guarded_helper: 2,
    await_helper_guard_exit: 5,
    launch_guard_exit_proved?: 2
  ]
  @limit 4096

  # Concept: failed cleanup assertions retain their original verdict and gain
  # a bounded account of the observed cleanup path.
  # Technical depth: the callback runs in its caller, preserving fixture and
  # executor ownership. Only this scope enables tracing; successful scopes must
  # prove delivery, teardown and observed calls for every expected iteration.
  def observe(iterations, callback, verify \\ fn _report -> :ok end) do
    handle = start(self())
    ExUnit.Callbacks.on_exit(fn -> ensure_stopped(handle) end)

    result =
      try do
        {:ok, callback.(handle)}
      catch
        kind, reason -> {:raised, kind, reason, __STACKTRACE__}
      end

    report =
      try do
        finish(handle)
      catch
        _, _ -> %{incomplete: true, reason: :trace_finish_failed}
      end

    case result do
      {:raised, kind, reason, stack} ->
        print_report(report)
        :erlang.raise(kind, reason, stack)

      {:ok, value} ->
        try do
          assert Map.get(report, :incomplete) == false, "cleanup trace is incomplete"
          assert Map.get(report, :owned_flags_removed) == true, "cleanup trace flags remain"

          for iteration <- iterations,
              function <- [:finish_guarded_output, :process_table_within],
              phase <- [:call, :return] do
            assert Enum.any?(report.events, fn event ->
                     event.iteration == iteration and event.function == function and
                       event.phase == phase
                   end),
                   "cleanup trace positive control is missing"
          end

          verify.(report)
          value
        catch
          kind, reason ->
            stack = __STACKTRACE__
            print_report(report)
            :erlang.raise(kind, reason, stack)
        end
    end
  end

  defp print_report(report) do
    IO.puts(
      :stderr,
      "LOOPEX_CLEANUP_TRACE " <> inspect(report, limit: :infinity, printable_limit: :infinity)
    )
  catch
    _, _ -> :ok
  end

  defp ensure_stopped(handle) do
    monitor = Process.monitor(handle)
    if Process.alive?(handle), do: finish(handle)

    stopped =
      receive do
        {:DOWN, ^monitor, :process, ^handle, _reason} -> true
      after
        1_000 ->
          Process.exit(handle, :kill)
          clear()

          receive do
            {:DOWN, ^monitor, :process, ^handle, _reason} -> :ok
          after
            1_000 -> :ok
          end

          false
      end

    Process.demonitor(monitor, [:flush])
    assert stopped, "cleanup tracer required forced teardown"

    for {name, arity} <- @calls do
      assert :erlang.trace_info({@module, name, arity}, :traced) == {:traced, false},
             "cleanup trace function pattern remains after teardown"
    end
  end

  def start(caller) when is_pid(caller) do
    Code.ensure_loaded!(@module)

    Enum.each(@calls, fn {name, arity} ->
      unless :erlang.trace_info({@module, name, arity}, :traced) == {:traced, false},
        do: raise("diagnostic function already traced")
    end)

    unless :erlang.trace_info(caller, :flags) == {:flags, []},
      do: raise("diagnostic caller already traced")

    tracer =
      spawn(fn ->
        try do
          loop(%{
            workers: %{caller => 1},
            caller_monitor: Process.monitor(caller),
            guards: %{},
            events: [],
            count: 0,
            overflow: false,
            incomplete: false,
            iteration: 0,
            markers: [],
            origin: System.monotonic_time(),
            pending: %{},
            done: nil,
            deadline: nil
          })
        catch
          _, _ -> clear()
        end
      end)

    try do
      Enum.each(@calls, fn {name, arity} ->
        1 = :erlang.trace_pattern({@module, name, arity}, [{:_, [], [{:return_trace}]}], [:local])
      end)

      1 =
        :erlang.trace(caller, true, [
          :call,
          :procs,
          :set_on_spawn,
          :monotonic_timestamp,
          {:tracer, tracer}
        ])

      tracer
    rescue
      _ ->
        clear()
        Process.exit(tracer, :kill)
        raise "diagnostic trace setup failed"
    end
  end

  def mark(handle, iteration) when is_integer(iteration),
    do: request(handle, {:mark, iteration, System.monotonic_time()})

  def finish(handle), do: request(handle, :finish)

  defp request(handle, action) do
    monitor = Process.monitor(handle)
    ref = make_ref()
    send(handle, {:request, self(), ref, action})

    result =
      receive do
        {^ref, answer} ->
          answer

        {:DOWN, ^monitor, :process, ^handle, _} ->
          %{incomplete: true, reason: :tracer_unavailable}
      after
        8_000 ->
          send(handle, :shutdown)

          receive do
            {:DOWN, ^monitor, :process, ^handle, _} ->
              %{incomplete: true, reason: :request_timeout}
          after
            6_000 ->
              Process.exit(handle, :kill)
              clear()

              receive do
                {:DOWN, ^monitor, :process, ^handle, _} -> :ok
              after
                1_000 -> :ok
              end

              %{incomplete: true, reason: :forced_tracer_shutdown}
          end
      end

    Process.demonitor(monitor, [:flush])
    result
  end

  defp clear do
    Enum.each(@calls, fn {name, arity} ->
      :erlang.trace_pattern({@module, name, arity}, false, [:local])
    end)
  end

  defp disable(pid) do
    try do
      :erlang.trace(pid, false, [:call, :procs, :set_on_spawn, :monotonic_timestamp])
    catch
      _, _ -> :ok
    end
  end

  defp barrier(s, pid) do
    disable(pid)

    try do
      ref = :erlang.trace_delivered(pid)
      %{s | pending: Map.put(s.pending, ref, pid)}
    catch
      _, _ -> %{s | incomplete: true}
    end
  end

  defp worker(s, pid) do
    if Map.has_key?(s.workers, pid) do
      s
    else
      next = %{s | workers: Map.put(s.workers, pid, map_size(s.workers) + 1)}
      if s.done, do: barrier(next, pid), else: next
    end
  end

  defp loop(%{done: done, pending: pending} = s) when done != nil and map_size(pending) == 0 do
    complete(s)
  end

  defp loop(s) do
    if s.deadline && System.monotonic_time(:millisecond) >= s.deadline,
      do: complete(%{s | incomplete: true}),
      else: receive_trace(s)
  end

  defp shutdown(s, done) do
    s = Enum.reduce(Map.keys(s.workers), s, &barrier(&2, &1))
    clear()
    %{s | done: done, deadline: s.deadline || System.monotonic_time(:millisecond) + 5_000}
  end

  defp receive_trace(s) do
    wait =
      if s.deadline, do: max(s.deadline - System.monotonic_time(:millisecond), 0), else: :infinity

    receive do
      {:request, from, ref, {:mark, iteration, time}} ->
        send(from, {ref, :ok})

        loop(%{
          s
          | iteration: iteration,
            markers: Enum.take([{time, iteration} | s.markers], @limit),
            overflow: s.overflow or length(s.markers) >= @limit
        })

      {:request, from, ref, :finish} ->
        loop(shutdown(s, {from, ref}))

      {:DOWN, monitor, :process, _caller, _reason} when monitor == s.caller_monitor ->
        loop(shutdown(%{s | incomplete: true}, :discard))

      :shutdown ->
        loop(shutdown(%{s | incomplete: true}, :discard))

      {:trace_delivered, pid, ref} ->
        if Map.get(s.pending, ref) == pid,
          do: loop(%{s | pending: Map.delete(s.pending, ref)}),
          else: loop(%{s | incomplete: true})

      {:trace_ts, _parent, :spawn, child, _entry, _time} ->
        loop(worker(s, child))

      {:trace_ts, pid, :call, {@module, function, args}, time} ->
        s = worker(s, pid)
        {details, s} = call(function, args, s, pid, time)
        loop(event(s, pid, function, :call, time, details))

      {:trace_ts, pid, :return_from, {@module, function, _arity}, result, time} ->
        s = worker(s, pid)
        details = returned(function, result, Map.get(s.guards, pid))
        s = %{s | incomplete: s.incomplete or Map.get(details, :unexpected_shape, false)}
        loop(event(s, pid, function, :return, time, details))

      _ ->
        loop(s)
    after
      wait -> complete(%{s | incomplete: true})
    end
  end

  defp complete(s) do
    Enum.each(Map.keys(s.workers), &disable/1)
    clear()

    clean =
      Enum.all?(Map.keys(s.workers), fn pid ->
        case :erlang.trace_info(pid, :flags) do
          :undefined ->
            true

          {:flags, flags} ->
            Enum.all?([:call, :procs, :set_on_spawn, :monotonic_timestamp], &(&1 not in flags))

          _ ->
            false
        end
      end)

    report = %{
      events: Enum.reverse(s.events),
      workers: map_size(s.workers),
      overflow: s.overflow,
      owned_flags_removed: clean,
      incomplete: s.incomplete or s.overflow or map_size(s.pending) != 0 or not clean,
      missing_barriers: map_size(s.pending)
    }

    case s.done do
      {from, ref} -> send(from, {ref, report})
      :discard -> :ok
    end
  end

  defp event(s, pid, function, phase, time, details) do
    if s.count == @limit do
      %{s | overflow: true}
    else
      item =
        Map.merge(details, %{
          worker: Map.fetch!(s.workers, pid),
          iteration:
            Enum.find_value(s.markers, 0, fn {at, iteration} -> if at <= time, do: iteration end),
          function: function,
          phase: phase,
          elapsed_us: System.convert_time_unit(time - s.origin, :native, :microsecond)
        })

      %{s | events: [item | s.events], count: s.count + 1}
    end
  end

  defp call(
         :finish_guarded_output,
         [_port, c, episode, _limit, _opts, _job, action, _observed],
         s,
         pid,
         time
       ) do
    {Map.merge(collector(c), %{
       action: enum(action, [:quiesce, :terminate]),
       remaining_ms: remaining(episode, time)
     }), %{s | guards: Map.put(s.guards, pid, membership(c.guard))}}
  end

  defp call(:guard_children_gone?, [g, episode], s, pid, time) do
    {Map.merge(guard(g), %{remaining_ms: remaining(episode, time)}),
     %{s | guards: Map.put_new(s.guards, pid, membership(g))}}
  end

  defp call(:process_table_within, [_program, bound], s, _pid, _time),
    do: {%{remaining_ms: number(bound)}, s}

  defp call(:await_launch_guard_exit, [_port, c, episode, _, _, _, _], s, _pid, time),
    do: {Map.put(collector(c), :remaining_ms, remaining(episode, time)), s}

  defp call(:kill_guarded_helper, [_port, c, _limit], s, _pid, _time), do: {collector(c), s}

  defp call(:finish_guarded_helper, [c, _limit], s, _pid, _time),
    do: {Map.put(collector(c), :ack_count, ack(c)), s}

  defp call(:await_helper_guard_exit, [_port, c, stop, _limit, overflow], s, _pid, time),
    do:
      {Map.merge(collector(c), %{
         remaining_ms: remaining(stop, time),
         overflow: overflow == true,
         ack_count: ack(c)
       }), s}

  defp call(:launch_guard_exit_proved?, [c, status], s, _pid, _time),
    do: {Map.put(collector(c), :port_status, number(status)), s}

  defp call(_, _, s, _, _time), do: {%{shape: :unexpected}, %{s | incomplete: true}}

  defp returned(:process_table_within, answer, g), do: table(answer, g)

  defp returned(:finish_guarded_output, result, _),
    do: %{
      confirmed: result[:confirmed] == true,
      quiescence: enum(result[:quiescence], [:quiescent, :terminated, :unconfirmed])
    }

  defp returned(:await_launch_guard_exit, {c, proved, _}, _),
    do: Map.put(collector(c), :proved, proved == true)

  defp returned(:await_helper_guard_exit, {c, proved, overflow}, _),
    do:
      Map.merge(collector(c), %{
        proved: proved == true,
        overflow: overflow == true,
        ack_count: ack(c)
      })

  defp returned(f, {:ok, c, _output}, _) when f in [:kill_guarded_helper, :finish_guarded_helper],
    do: Map.merge(collector(c), %{result: :ok, ack_count: ack(c)})

  defp returned(_, value, _) when is_boolean(value), do: %{result: value}

  defp returned(f, :error, _) when f in [:kill_guarded_helper, :finish_guarded_helper],
    do: %{result: :error}

  defp returned(_, _, _), do: %{result: :unexpected_shape, unexpected_shape: true}

  defp membership(g),
    do: Map.take(g, [:group, :anchor_pid, :os_pid, :carrier_in_group, :terminal_wrapper_pid])

  defp collector(c),
    do:
      Map.merge(guard(c.guard), %{
        protocol_valid: c.protocol_valid == true,
        command_status: number(c.command_status),
        control_buffer_empty: c.control_buffer == <<>>,
        control_buffer_bytes: byte_size(c.control_buffer)
      })

  defp guard(g),
    do: %{
      guard_state: enum(g.state, [:live, :release_sent, :kill_sent, :guard_missing]),
      announced: g.announced == true,
      wrapper_known: is_integer(g.terminal_wrapper_pid),
      carrier_in_group: g.carrier_in_group == true
    }

  defp enum(v, allowed), do: if(v in allowed, do: v, else: :other)
  defp number(v), do: if(is_integer(v), do: v, else: :missing)
  defp remaining({until, _, _}, time), do: remaining(until, time)

  defp remaining(until, time) when is_integer(until),
    do: until - System.convert_time_unit(time, :native, :millisecond)

  defp remaining(_, _), do: :missing

  defp ack(c) do
    bytes = IO.iodata_to_binary(Enum.reverse(c.chunks)) <> c.control_buffer
    needle = "\nloopex-signal-accepted:" <> c.guard.token <> ":KILL\n"

    case length(:binary.matches(bytes, needle)) do
      0 -> 0
      1 -> 1
      _ -> :multiple
    end
  end

  defp table({:answered, bytes, status, witness}, g) when is_binary(bytes) do
    parsed =
      bytes
      |> String.split("\n", trim: true)
      |> Enum.map(fn line ->
        case String.split(line) do
          [a, b] ->
            case {Integer.parse(a), Integer.parse(b)} do
              {{pid, ""}, {group, ""}} -> {pid, group}
              _ -> :invalid
            end

          _ ->
            :invalid
        end
      end)

    valid = Enum.all?(parsed, &is_tuple/1)

    base = %{
      result: :answered,
      bytes: byte_size(bytes),
      rows: length(parsed),
      status: number(status),
      valid_shape: valid,
      helper_witness: valid and {witness, witness} in parsed
    }

    if valid and is_map(g) do
      members = for {pid, group} <- parsed, group == g.group, do: pid
      expected = [g.anchor_pid] ++ if(g.carrier_in_group, do: [g.os_pid], else: [])

      allowed =
        expected ++ if(is_integer(g.terminal_wrapper_pid), do: [g.terminal_wrapper_pid], else: [])

      Map.merge(base, %{
        anchor_present: g.anchor_pid in members,
        carrier_present: g.os_pid in members,
        wrapper_present: g.terminal_wrapper_pid in members,
        expected_members_present: Enum.all?(expected, &(&1 in members)),
        unexpected_count: Enum.count(members, &(&1 not in allowed)),
        member_count: length(members)
      })
    else
      Map.put(base, :membership_context, :unavailable)
    end
  end

  defp table(:no_answer, _), do: %{result: :no_answer}
  defp table(_, _), do: %{result: :unexpected_shape, unexpected_shape: true}
end
