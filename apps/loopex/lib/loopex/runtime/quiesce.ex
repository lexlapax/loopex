defmodule Loopex.Runtime.Quiesce do
  @moduledoc false

  require Logger

  alias Loopex.Executor
  alias Loopex.Runtime.Control
  alias Loopex.Runtime.SessionCoordinator
  alias Loopex.Runtime.Supervisor, as: RuntimeSupervisor

  @admission_ms 70_000
  @initial_gate_ms 5_000
  @worker_reap_ms 5_000
  @status_census_ms 10_000
  @status_work_ms 5_000
  @coordinator_termination_ms 330_000
  @termination_projection_ms 5_000

  @type prepared :: %{
          drain_id: binary(),
          entries: [map()],
          admissions: %{binary() => term()},
          settled: [binary()],
          unsettled: [binary()],
          absent: [binary()],
          budget_ms: non_neg_integer(),
          control: pid(),
          session_supervisor: pid()
        }

  @doc false
  @spec prepare(pid(), reference()) :: {:ok, prepared()} | {:error, :runtime_unavailable}
  def prepare(root, token) when is_pid(root) and is_reference(token) do
    caller = self()
    call_ref = make_ref()

    {owner, monitor} =
      spawn_monitor(fn ->
        phase_owner(caller, call_ref, root, token)
      end)

    receive do
      {:loopex_quiesce_prepared, ^call_ref, ^owner, result} ->
        send(owner, {:loopex_quiesce_prepared_ack, call_ref, caller})
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^owner, _reason} ->
        {:error, :runtime_unavailable}
    end
  end

  def prepare(_root, _token), do: {:error, :runtime_unavailable}

  defp phase_owner(caller, call_ref, root, token) do
    Process.flag(:trap_exit, true)
    caller_monitor = Process.monitor(caller)
    started_at = now_ms()
    admission_deadline = started_at + @admission_ms
    drain_id = new_drain_id()

    Logger.debug("runtime quiesce phase owner started")

    result =
      with {:ok, children} <-
             resolve_children(root, caller, caller_monitor, started_at + @initial_gate_ms),
           control = Map.fetch!(children, :control),
           control_monitor = Process.monitor(control),
           context = %{
             caller: caller,
             caller_monitor: caller_monitor,
             control: control,
             control_monitor: control_monitor
           },
           {:ok, entries} <-
             install_gate(context, token, drain_id, started_at + @initial_gate_ms),
           {:ok, admissions} <-
             admit_aborts(context, entries, drain_id, admission_deadline),
           {:ok, release} <- release_cleanups(context, entries, admissions, drain_id),
           :ok <- await_released_terminals(context, release, drain_id),
           {:ok, classification} <-
             classify_sessions(context, entries, admissions, release, drain_id),
           {:ok, termination_entries} <-
             terminate_coordinators(
               context,
               token,
               drain_id,
               entries,
               Map.fetch!(children, :sessions)
             ) do
        {:ok,
         Map.merge(classification, %{
           drain_id: drain_id,
           entries: entries,
           admissions: admissions,
           budget_ms: release.budget_ms,
           control: control,
           session_supervisor: Map.fetch!(children, :sessions),
           termination_entries: termination_entries
         })}
      else
        _failure -> {:error, :runtime_unavailable}
      end

    Logger.debug("runtime quiesce preparation finished",
      outcome: if(match?({:ok, _}, result), do: :ok, else: :runtime_unavailable)
    )

    send(caller, {:loopex_quiesce_prepared, call_ref, self(), result})

    receive do
      {:loopex_quiesce_prepared_ack, ^call_ref, ^caller} -> :ok
      {:DOWN, ^caller_monitor, :process, ^caller, _reason} -> exit(:caller_lost)
    after
      @initial_gate_ms -> :ok
    end

    # A non-normal phase-owner exit is the final ownership barrier: any linked
    # worker whose kill signal is still in flight cannot outlive this call.
    exit(:shutdown)
  end

  defp resolve_children(root, caller, caller_monitor, deadline) do
    run_one_worker(
      fn -> RuntimeSupervisor.children(root) end,
      %{
        caller: caller,
        caller_monitor: caller_monitor,
        control: nil,
        control_monitor: nil
      },
      deadline
    )
  end

  defp install_gate(context, token, drain_id, deadline) do
    run_one_worker(
      fn ->
        Control.begin_quiesce(
          context.control,
          token,
          drain_id,
          remaining_ms(deadline)
        )
      end,
      context,
      deadline
    )
  end

  defp admit_aborts(context, entries, drain_id, admission_deadline) do
    work_deadline = admission_deadline - @worker_reap_ms
    phase_owner = self()

    {workers, initial} =
      Enum.reduce(entries, {%{}, %{}}, fn entry, {workers, results} ->
        session_id = entry.session_id

        case admission_target(entry) do
          {:call, coordinator, owner} ->
            pid =
              result_worker(session_id, fn ->
                SessionCoordinator.admit_quiesce_abort(
                  coordinator,
                  owner,
                  drain_id,
                  phase_owner
                )
              end)

            {Map.put(workers, pid, session_id), results}

          disposition ->
            {workers, Map.put(results, session_id, disposition)}
        end
      end)

    collect_workers(context, workers, initial, work_deadline, admission_deadline)
  end

  defp admission_target(%{status: :active, coordinator: coordinator, owner: owner})
       when is_pid(coordinator) and is_map(owner) do
    if Process.alive?(coordinator), do: {:call, coordinator, owner}, else: :absent
  end

  defp admission_target(%{status: status}) when status in [:acquiring, :awaiting_owner_barrier],
    do: :unsettled

  defp admission_target(_entry), do: :absent

  defp release_cleanups(context, entries, admissions, drain_id) do
    admitted =
      Enum.flat_map(entries, fn entry ->
        case Map.get(admissions, entry.session_id) do
          {:admitted, result} -> [{entry, result}]
          _other -> []
        end
      end)

    all_decided? =
      Enum.all?(admissions, fn {_session_id, result} ->
        match?({:admitted, _}, result) or
          result in [:rejected_no_active_run, :absent, :unsettled]
      end)

    if all_decided? do
      budget_ms = cancellation_budget(admitted)
      deadline = now_ms() + budget_ms
      phase_owner = self()

      workers =
        Map.new(admitted, fn {entry, _result} ->
          pid =
            result_worker(entry.session_id, fn ->
              SessionCoordinator.release_quiesce_cleanup(
                entry.coordinator,
                entry.owner,
                drain_id,
                phase_owner
              )
            end)

          {pid, entry.session_id}
        end)

      outer_deadline = max(deadline, now_ms() + @worker_reap_ms)

      case collect_workers(context, workers, %{}, deadline, outer_deadline) do
        {:ok, releases} ->
          {:ok,
           %{
             admitted: Map.new(admitted, fn {entry, result} -> {entry.session_id, result} end),
             entries: Map.new(entries, &{&1.session_id, &1}),
             releases: releases,
             budget_ms: budget_ms,
             cancellation_deadline: deadline
           }}

        {:error, :runtime_unavailable} = error ->
          error
      end
    else
      {:ok,
       %{
         admitted: %{},
         entries: Map.new(entries, &{&1.session_id, &1}),
         releases: %{},
         budget_ms: 0,
         cancellation_deadline: now_ms()
       }}
    end
  end

  defp cancellation_budget(admitted) do
    admitted
    |> Enum.map(fn {_entry, %{cleanup_grace_ms: grace}} ->
      {:ok, %{cli_backstop_ms: budget}} = Executor.cancellation_bounds(grace)
      budget
    end)
    |> Enum.max(fn -> 0 end)
  end

  defp await_released_terminals(_context, %{admitted: admitted}, _drain_id)
       when map_size(admitted) == 0,
       do: :ok

  defp await_released_terminals(context, release, drain_id) do
    waiting =
      Map.new(release.admitted, fn {session_id, result} ->
        entry = entry_for_session(release, session_id)
        {session_id, {result.run_id, entry.coordinator}}
      end)

    await_terminal_notifications(
      context,
      waiting,
      drain_id,
      release.cancellation_deadline
    )
  end

  defp entry_for_session(%{entries: entries}, session_id),
    do: Map.fetch!(entries, session_id)

  defp await_terminal_notifications(_context, waiting, _drain_id, _deadline)
       when map_size(waiting) == 0,
       do: :ok

  defp await_terminal_notifications(context, waiting, drain_id, deadline) do
    receive do
      {:loopex_quiesce_terminal, ^drain_id, session_id, run_id, coordinator} ->
        next =
          case Map.get(waiting, session_id) do
            {^run_id, ^coordinator} -> Map.delete(waiting, session_id)
            _other -> waiting
          end

        await_terminal_notifications(context, next, drain_id, deadline)

      {:DOWN, monitor, :process, pid, _reason}
      when monitor == context.caller_monitor and pid == context.caller ->
        exit(:caller_lost)

      {:DOWN, monitor, :process, pid, _reason}
      when monitor == context.control_monitor and pid == context.control ->
        {:error, :runtime_unavailable}

      {:EXIT, _pid, _reason} ->
        await_terminal_notifications(context, waiting, drain_id, deadline)
    after
      remaining_ms(deadline) -> :ok
    end
  end

  defp classify_sessions(context, entries, admissions, release, _drain_id) do
    {workers, initial} =
      Enum.reduce(entries, {%{}, %{}}, fn entry, {workers, results} ->
        session_id = entry.session_id

        case Map.get(admissions, session_id) do
          :rejected_no_active_run ->
            {workers, Map.put(results, session_id, :settled)}

          {:admitted, %{run_id: run_id}} ->
            pid =
              result_worker(session_id, fn ->
                classify_status(
                  SessionCoordinator.session_status(entry.coordinator, entry.owner),
                  run_id
                )
              end)

            {Map.put(workers, pid, session_id), results}

          :absent ->
            {workers, Map.put(results, session_id, :absent)}

          _failed_or_unsettled ->
            {workers, Map.put(results, session_id, :unsettled)}
        end
      end)

    started_at = now_ms()

    result =
      collect_workers(
        context,
        workers,
        initial,
        started_at + @status_work_ms,
        started_at + @status_census_ms
      )

    case result do
      {:ok, classifications} ->
        {:ok,
         %{
           settled: ids_with(classifications, :settled),
           unsettled: ids_without_settled_or_absent(classifications),
           absent: ids_with(classifications, :absent),
           release_results: release.releases
         }}

      {:error, :runtime_unavailable} = error ->
        error
    end
  end

  defp classify_status(
         {:ok, %{active_run_id: active_run_id, pending_work_ids: pending_work_ids}},
         run_id
       ) do
    if active_run_id != run_id and run_id not in pending_work_ids,
      do: :settled,
      else: :unsettled
  end

  defp classify_status(_unavailable, _run_id), do: :unsettled

  # Concept: no fence may race an ordinary session writer, including a writer
  # whose run already settled.
  #
  # Technical depth: the second projection reads the same frozen writer-domain
  # keys from the captured Control. Every current coordinator is monitored
  # before all DynamicSupervisor termination calls are issued together. At the
  # shared work cutoff, direct untrappable kills end both surviving coordinators
  # and workers blocked in the serialized supervisor. The final reserve admits
  # only their exact DOWN/EXIT signals.
  defp terminate_coordinators(context, token, drain_id, first_entries, session_supervisor) do
    started_at = now_ms()
    outer_deadline = started_at + @coordinator_termination_ms
    projection_deadline = started_at + @termination_projection_ms

    with {:ok, entries} <-
           run_one_worker(
             fn ->
               Control.quiesce_projection(
                 context.control,
                 token,
                 drain_id,
                 remaining_ms(projection_deadline)
               )
             end,
             context,
             projection_deadline
           ),
         true <- projection_keys(entries) == projection_keys(first_entries),
         :ok <-
           terminate_projected_coordinators(
             context,
             entries,
             session_supervisor,
             outer_deadline - @worker_reap_ms,
             outer_deadline
           ) do
      {:ok, entries}
    else
      _failure -> {:error, :runtime_unavailable}
    end
  end

  defp projection_keys(entries), do: entries |> Enum.map(& &1.session_id) |> Enum.sort()

  defp terminate_projected_coordinators(
         context,
         entries,
         session_supervisor,
         work_deadline,
         outer_deadline
       ) do
    coordinators =
      entries
      |> Enum.flat_map(fn
        %{coordinator: coordinator} when is_pid(coordinator) -> [coordinator]
        _without_coordinator -> []
      end)
      |> Enum.uniq()

    monitors =
      Map.new(coordinators, fn coordinator ->
        {Process.monitor(coordinator), coordinator}
      end)

    workers =
      Map.new(coordinators, fn coordinator ->
        worker =
          result_worker(coordinator, fn ->
            safe_terminate_child(session_supervisor, coordinator)
          end)

        {worker, coordinator}
      end)

    await_termination(
      context,
      coordinators,
      monitors,
      workers,
      work_deadline,
      outer_deadline,
      false
    )
  end

  defp safe_terminate_child(session_supervisor, coordinator) do
    try do
      DynamicSupervisor.terminate_child(session_supervisor, coordinator)
    catch
      :exit, _reason -> {:error, :runtime_unavailable}
    end
  end

  defp await_termination(
         _context,
         _coordinators,
         monitors,
         workers,
         _work_deadline,
         _outer_deadline,
         _cutoff?
       )
       when map_size(monitors) == 0 and map_size(workers) == 0,
       do: :ok

  defp await_termination(
         context,
         coordinators,
         monitors,
         workers,
         work_deadline,
         outer_deadline,
         cutoff?
       ) do
    deadline = if cutoff?, do: outer_deadline, else: work_deadline

    receive do
      {:DOWN, monitor, :process, coordinator, _reason} ->
        case Map.pop(monitors, monitor) do
          {^coordinator, remaining} ->
            await_termination(
              context,
              coordinators,
              remaining,
              workers,
              work_deadline,
              outer_deadline,
              cutoff?
            )

          {nil, _same} ->
            termination_control_down(
              context,
              monitor,
              coordinator,
              coordinators,
              monitors,
              workers,
              work_deadline,
              outer_deadline,
              cutoff?
            )
        end

      {:EXIT, worker, {:loopex_quiesce_worker_result, _operation_ref, coordinator, _result}} ->
        case Map.pop(workers, worker) do
          {^coordinator, remaining} ->
            await_termination(
              context,
              coordinators,
              monitors,
              remaining,
              work_deadline,
              outer_deadline,
              cutoff?
            )

          {nil, _same} ->
            await_termination(
              context,
              coordinators,
              monitors,
              workers,
              work_deadline,
              outer_deadline,
              cutoff?
            )
        end

      {:EXIT, worker, _reason} ->
        case Map.pop(workers, worker) do
          {nil, _same} ->
            await_termination(
              context,
              coordinators,
              monitors,
              workers,
              work_deadline,
              outer_deadline,
              cutoff?
            )

          {_coordinator, remaining} ->
            await_termination(
              context,
              coordinators,
              monitors,
              remaining,
              work_deadline,
              outer_deadline,
              cutoff?
            )
        end
    after
      remaining_ms(deadline) ->
        if cutoff? do
          {:error, :runtime_unavailable}
        else
          Enum.each(coordinators, fn coordinator ->
            if Process.alive?(coordinator), do: Process.exit(coordinator, :kill)
          end)

          kill_workers(workers)

          await_termination(
            context,
            coordinators,
            monitors,
            workers,
            work_deadline,
            outer_deadline,
            true
          )
        end
    end
  end

  defp termination_control_down(
         context,
         monitor,
         pid,
         coordinators,
         monitors,
         workers,
         work_deadline,
         outer_deadline,
         cutoff?
       ) do
    cond do
      monitor == context.caller_monitor and pid == context.caller ->
        kill_workers(workers)
        Enum.each(coordinators, &Process.exit(&1, :kill))
        exit(:caller_lost)

      monitor == context.control_monitor and pid == context.control ->
        kill_workers(workers)
        Enum.each(coordinators, &Process.exit(&1, :kill))
        {:error, :runtime_unavailable}

      true ->
        await_termination(
          context,
          coordinators,
          monitors,
          workers,
          work_deadline,
          outer_deadline,
          cutoff?
        )
    end
  end

  defp ids_with(results, disposition) do
    results
    |> Enum.filter(fn {_id, result} -> result == disposition end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.sort()
  end

  defp ids_without_settled_or_absent(results) do
    results
    |> Enum.reject(fn {_id, result} -> result in [:settled, :absent] end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.sort()
  end

  defp result_worker(session_id, work) do
    operation_ref = make_ref()

    spawn_link(fn ->
      result =
        try do
          work.()
        catch
          _kind, _reason -> {:error, :runtime_unavailable}
        end

      exit({:loopex_quiesce_worker_result, operation_ref, session_id, result})
    end)
  end

  defp run_one_worker(work, context, deadline) do
    session_id = "phase"
    worker = result_worker(session_id, work)

    case collect_workers(context, %{worker => session_id}, %{}, deadline, deadline) do
      {:ok, %{^session_id => result}} -> result
      _failure -> {:error, :runtime_unavailable}
    end
  end

  defp collect_workers(context, workers, results, work_deadline, outer_deadline) do
    collect_workers(context, workers, results, work_deadline, outer_deadline, false)
  end

  defp collect_workers(_context, workers, results, _work_deadline, _outer_deadline, _killed?)
       when map_size(workers) == 0,
       do: {:ok, results}

  defp collect_workers(context, workers, results, work_deadline, outer_deadline, killed?) do
    deadline = if killed?, do: outer_deadline, else: work_deadline

    receive do
      {:EXIT, pid, {:loopex_quiesce_worker_result, _operation_ref, session_id, result}} ->
        case Map.pop(workers, pid) do
          {^session_id, remaining} ->
            collect_workers(
              context,
              remaining,
              Map.put(results, session_id, result),
              work_deadline,
              outer_deadline,
              killed?
            )

          {nil, _same} ->
            collect_workers(
              context,
              workers,
              results,
              work_deadline,
              outer_deadline,
              killed?
            )
        end

      {:EXIT, pid, _reason} ->
        case Map.pop(workers, pid) do
          {nil, _same} ->
            collect_workers(
              context,
              workers,
              results,
              work_deadline,
              outer_deadline,
              killed?
            )

          {session_id, remaining} ->
            collect_workers(
              context,
              remaining,
              Map.put(results, session_id, {:error, :runtime_unavailable}),
              work_deadline,
              outer_deadline,
              killed?
            )
        end

      {:DOWN, monitor, :process, pid, _reason}
      when monitor == context.caller_monitor and pid == context.caller ->
        kill_workers(workers)
        exit(:caller_lost)

      {:DOWN, monitor, :process, pid, _reason}
      when monitor == context.control_monitor and pid == context.control ->
        kill_workers(workers)
        {:error, :runtime_unavailable}
    after
      remaining_ms(deadline) ->
        if killed? do
          {:error, :runtime_unavailable}
        else
          kill_workers(workers)

          collect_workers(
            context,
            workers,
            results,
            work_deadline,
            outer_deadline,
            true
          )
        end
    end
  end

  defp kill_workers(workers) do
    Enum.each(workers, fn {pid, _session_id} ->
      if Process.alive?(pid), do: Process.exit(pid, :kill)
    end)
  end

  defp new_drain_id do
    16 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
  end

  defp remaining_ms(deadline), do: max(deadline - now_ms(), 0)
  defp now_ms, do: System.monotonic_time(:millisecond)
end
