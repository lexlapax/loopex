defmodule Loopex.Runtime.CreationCarrier do
  @moduledoc false

  # Concept: Control owns each decision; this guardian owns one permitted call's lifetime.
  # Technical depth: the private Task.Supervisor, worker and guardian have original
  # monitors before permit. Only their original DOWN signals prove retirement.
  # A retired RPC can still be queued in Store and never proves Store cancellation.
  alias Loopex.Executor
  alias Loopex.Store

  @slice 3_600_000

  @doc false
  def start(
        workers,
        control,
        incarnation,
        invocation,
        permit,
        store,
        action,
        cutoff,
        grace,
        cleanup
      ) do
    Task.Supervisor.start_child(
      workers,
      fn ->
        guard(control, incarnation, invocation, permit, store, action, cutoff, grace, cleanup)
      end,
      shutdown: :infinity
    )
  end

  defp guard(control, incarnation, invocation, permit, store, action, cutoff, grace, cleanup) do
    Process.flag(:trap_exit, true)
    owner_monitor = Process.monitor(control)
    guardian = self()
    await_ownership(control, owner_monitor, incarnation, invocation, permit, cutoff)
    {:ok, group} = Task.Supervisor.start_link()
    group_monitor = Process.monitor(group)

    {:ok, worker} =
      Task.Supervisor.start_child(
        group,
        fn ->
          work(control, guardian, incarnation, invocation, permit, store, action, cutoff)
        end,
        shutdown: :brutal_kill
      )

    worker_monitor = Process.monitor(worker)

    send(
      control,
      {:creation_carrier_ready, incarnation, invocation, permit, guardian, group, worker}
    )

    await(%{
      control: control,
      owner_monitor: owner_monitor,
      incarnation: incarnation,
      invocation: invocation,
      permit: permit,
      group: group,
      group_monitor: group_monitor,
      worker: worker,
      worker_monitor: worker_monitor,
      action: action,
      cutoff: cutoff,
      grace: grace,
      cleanup: cleanup,
      stopping: false,
      outcome: nil,
      worker_down: false,
      group_down: false
    })
  end

  defp await_ownership(control, monitor, incarnation, invocation, permit, cutoff) do
    receive do
      {:creation_guard_owned, ^control, ^incarnation, ^invocation, ^permit} -> :ok
      {:DOWN, ^monitor, :process, ^control, _} -> exit(:normal)
    after
      min(max(cutoff - now(), 0), @slice) ->
        if now() < cutoff,
          do: await_ownership(control, monitor, incarnation, invocation, permit, cutoff),
          else: exit(:normal)
    end
  end

  defp work(control, guardian, incarnation, invocation, permit, store, action, cutoff) do
    owner_monitor = Process.monitor(control)
    guardian_monitor = Process.monitor(guardian)

    await_permit(
      control,
      guardian,
      owner_monitor,
      guardian_monitor,
      incarnation,
      invocation,
      permit,
      store,
      action,
      cutoff
    )
  end

  defp await_permit(
         control,
         guardian,
         owner_monitor,
         guardian_monitor,
         incarnation,
         invocation,
         permit,
         store,
         action,
         cutoff
       ) do
    receive do
      {:creation_permit, ^control, ^incarnation, ^invocation, ^permit} ->
        # Concept: a permit spends the existing allowance, including queued stop signals.
        # Technical depth: no adapter callback runs if an original owner/guardian DOWN,
        # exact stop or the original cutoff is already observable at this boundary.
        allowed =
          receive do
            {:DOWN, ^owner_monitor, :process, ^control, _} -> false
            {:DOWN, ^guardian_monitor, :process, ^guardian, _} -> false
            {:creation_stop, ^permit} -> false
          after
            0 -> now() < cutoff
          end

        result = if allowed, do: call(store, action), else: {:undispatched, unavailable(action)}
        send(guardian, {:creation_outcome, self(), permit, result})

      {:DOWN, ^owner_monitor, :process, ^control, _} ->
        :ok

      {:DOWN, ^guardian_monitor, :process, ^guardian, _} ->
        :ok

      {:creation_stop, ^permit} ->
        :ok
    after
      min(max(cutoff - now(), 0), @slice) ->
        if now() < cutoff do
          await_permit(
            control,
            guardian,
            owner_monitor,
            guardian_monitor,
            incarnation,
            invocation,
            permit,
            store,
            action,
            cutoff
          )
        end
    end
  end

  defp call(store, action) do
    try do
      case action do
        {:transaction, transaction} -> Store.transact(store, transaction)
        {:recovery, request} -> Store.creation_recovery(store, request)
        {:provenance, runtime, selector} -> Store.creation_provenance(store, runtime, selector)
        {:genesis, session} -> Store.load_records(store, session, 0, 1)
        {:runtime_command, command} -> Store.runtime_command(store, command)
      end
    rescue
      _ -> unavailable(action)
    catch
      _, _ -> unavailable(action)
    end
  end

  defp unavailable({:transaction, transaction}) do
    {:ok, id} = Store.transaction_id(transaction)
    {:commit_unknown, id}
  end

  defp unavailable(_read), do: :unavailable

  defp await(%{worker_down: true} = state), do: retire_group(state)

  defp await(state) do
    deadline = if state.stopping, do: state.cleanup.cooperative, else: state.cutoff

    receive do
      {:creation_outcome, worker, permit, outcome}
      when worker == state.worker and permit == state.permit ->
        await(%{state | outcome: outcome})

      {:DOWN, monitor, :process, worker, _reason}
      when monitor == state.worker_monitor and worker == state.worker ->
        await(%{state | worker_down: true})

      {:DOWN, monitor, :process, owner, _reason}
      when monitor == state.owner_monitor and owner == state.control ->
        await(stop(state, nil))

      {:DOWN, monitor, :process, group, _reason}
      when monitor == state.group_monitor and group == state.group ->
        await(stop(%{state | group_down: true}, nil))

      {:creation_retire, control, incarnation, invocation, permit, cleanup}
      when control == state.control and incarnation == state.incarnation and
             invocation == state.invocation and permit == state.permit ->
        await(stop(state, cleanup))

      {:EXIT, pid, _reason} when pid != state.group ->
        await(stop(state, nil))

      {:EXIT, _pid, _reason} ->
        await(state)
    after
      min(max(deadline - now(), 0), @slice) ->
        if now() < deadline do
          await(state)
        else
          state = stop(state, nil)
          Process.exit(state.worker, :kill)
          await_forced(state)
        end
    end
  end

  defp stop(state, requested) do
    cleanup = select_cleanup(state.cleanup, requested, state.grace)

    if not state.stopping do
      send(
        state.control,
        {:creation_carrier_stopping, state.incarnation, state.invocation, state.permit, self(),
         cleanup}
      )
    end

    send(state.worker, {:creation_stop, state.permit})
    Process.exit(state.worker, :shutdown)
    %{state | cleanup: cleanup, stopping: true}
  end

  defp select_cleanup(nil, nil, grace) do
    {:ok, bounds} = Executor.cancellation_bounds(grace)
    instant = now()
    %{cooperative: instant + grace, observe: instant + bounds.executor_observe_ms}
  end

  defp select_cleanup(nil, cleanup, _grace), do: cleanup
  defp select_cleanup(cleanup, nil, _grace), do: cleanup

  defp select_cleanup(left, right, _grace),
    do: %{
      cooperative: min(left.cooperative, right.cooperative),
      observe: min(left.observe, right.observe)
    }

  defp await_forced(state) do
    receive do
      {:DOWN, monitor, :process, worker, _}
      when monitor == state.worker_monitor and worker == state.worker ->
        retire_group(%{state | worker_down: true})

      {:creation_outcome, worker, permit, outcome}
      when worker == state.worker and permit == state.permit ->
        await_forced(%{state | outcome: outcome})

      {:creation_retire, control, incarnation, invocation, permit, cleanup}
      when control == state.control and incarnation == state.incarnation and
             invocation == state.invocation and permit == state.permit ->
        await_forced(%{state | cleanup: select_cleanup(state.cleanup, cleanup, state.grace)})

      {:DOWN, monitor, :process, group, _}
      when monitor == state.group_monitor and group == state.group ->
        await_forced(%{state | group_down: true})

      {:EXIT, _pid, _reason} ->
        await_forced(state)
    after
      min(max(state.cleanup.observe - now(), 0), @slice) ->
        if now() < state.cleanup.observe do
          await_forced(state)
        else
          Process.exit(state.group, :kill)

          send(
            state.control,
            {:creation_cleanup_unproved, state.incarnation, state.invocation, state.permit,
             self()}
          )

          exit(:creation_cleanup_unproved)
        end
    end
  end

  defp retire_group(state) do
    deadline = if state.cleanup, do: state.cleanup.observe, else: state.cutoff

    if not state.group_down do
      try do
        Supervisor.stop(state.group, :normal, max(min(deadline - now(), @slice), 1))
      catch
        :exit, _ -> Process.exit(state.group, :kill)
      end
    end

    join_group(state, deadline)
  end

  defp join_group(%{group_down: true} = state, _deadline), do: joined(state)

  defp join_group(state, deadline) do
    receive do
      {:DOWN, monitor, :process, group, _}
      when monitor == state.group_monitor and group == state.group ->
        joined(state)

      {:EXIT, _pid, _reason} ->
        join_group(state, deadline)
    after
      min(max(deadline - now(), 0), @slice) ->
        if now() < deadline do
          join_group(state, deadline)
        else
          send(
            state.control,
            {:creation_cleanup_unproved, state.incarnation, state.invocation, state.permit,
             self()}
          )

          exit(:creation_cleanup_unproved)
        end
    end
  end

  defp joined(state) do
    send(
      state.control,
      {:creation_carrier_joined, state.incarnation, state.invocation, state.permit, self(),
       state.group, state.worker, state.outcome || unavailable(state.action)}
    )
  end

  defp now, do: System.monotonic_time(:millisecond)
end
