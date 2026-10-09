defmodule Loopex.Runtime.CreationCarrier do
  @moduledoc false

  # Concept: Control owns each decision; this guardian owns one permitted call's lifetime.
  # Technical depth: the private TaskSupervisor, worker and guardian have original
  # monitors before permit. Only their original DOWN signals prove retirement.
  # A retired RPC can still be queued in Store and never proves Store cancellation.
  alias Loopex.Executor
  alias Loopex.Runtime.TaskSupervisor
  alias Loopex.Store
  alias __MODULE__.PreparationGroup

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
    TaskSupervisor.start_child(
      workers,
      fn ->
        if match?({:prepare_configuration, _, _, _, _, _}, action) do
          guard_preparation(
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
          )
        else
          guard(control, incarnation, invocation, permit, store, action, cutoff, grace, cleanup)
        end
      end,
      shutdown: :infinity
    )
  end

  defp guard(control, incarnation, invocation, permit, store, action, cutoff, grace, cleanup) do
    Process.flag(:trap_exit, true)
    owner_monitor = Process.monitor(control)
    guardian = self()
    await_ownership(control, owner_monitor, incarnation, invocation, permit, cutoff)
    {:ok, group} = TaskSupervisor.start_link()
    group_monitor = Process.monitor(group)

    {:ok, worker} =
      TaskSupervisor.start_child(
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

        result =
          if allowed,
            do: invoke(store, action, guardian, permit, cutoff),
            else: {:undispatched, unavailable(action)}

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

  defp invoke(
         {:preparation_group, inventory, group},
         {:prepare_configuration, model, current, changes, definitions, context},
         guardian,
         permit,
         cutoff
       ),
       do:
         prepare(
           model,
           current,
           changes,
           definitions,
           context,
           guardian,
           permit,
           cutoff,
           inventory,
           group
         )

  defp invoke(store, action, _guardian, _permit, _cutoff), do: call(store, action)

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

  # Concept: initial model preparation is owned before any session exists.
  # Technical depth: the preparation group is a direct runtime worker. Both it
  # and this guardian retain original child/resource monitors before callback
  # acknowledgement; guardian loss cannot detach the group from runtime stop.
  defp guard_preparation(
         runtime_workers,
         control,
         incarnation,
         invocation,
         permit,
         _store,
         action,
         cutoff,
         grace,
         cleanup
       ) do
    Process.flag(:trap_exit, true)
    owner_monitor = Process.monitor(control)
    guardian = self()
    await_ownership(control, owner_monitor, incarnation, invocation, permit, cutoff)

    {:ok, group} =
      PreparationGroup.start(
        runtime_workers,
        guardian,
        control,
        {incarnation, invocation, permit},
        cutoff,
        grace,
        cleanup
      )

    group_monitor = Process.monitor(group)

    receive do
      {:creation_preparation_group_ready, ^group, workers, inventory} ->
        workers_monitor = Process.monitor(workers)

        {:ok, worker, request} =
          PreparationGroup.child(
            group,
            fn ->
              work(
                control,
                guardian,
                incarnation,
                invocation,
                permit,
                {:preparation_group, inventory, group},
                action,
                cutoff
              )
            end,
            cutoff
          )

        worker_monitor = Process.monitor(worker)
        PreparationGroup.release(group, request, worker)

        send(
          control,
          {:creation_carrier_ready, incarnation, invocation, permit, guardian, group, worker}
        )

        preparation_await(%{
          control: control,
          owner_monitor: owner_monitor,
          incarnation: incarnation,
          invocation: invocation,
          permit: permit,
          group: group,
          group_monitor: group_monitor,
          group_down: false,
          workers: workers,
          workers_monitor: workers_monitor,
          workers_down: false,
          worker: worker,
          worker_monitor: worker_monitor,
          worker_down: false,
          children: %{},
          resource: nil,
          inventory: inventory,
          action: action,
          cutoff: cutoff,
          grace: grace,
          cleanup: cleanup,
          stopping: false,
          closing: false,
          outcome: nil,
          retired: nil,
          fallback: false
        })

      {:DOWN, ^group_monitor, :process, ^group, _} ->
        preparation_unproved(control, incarnation, invocation, permit)

      {:DOWN, ^owner_monitor, :process, ^control, _} ->
        retained = select_cleanup(cleanup, nil, grace)
        PreparationGroup.retire(group, retained)

        preparation_startup_join(
          group,
          group_monitor,
          control,
          incarnation,
          invocation,
          permit,
          retained
        )
    after
      max(cutoff - now(), 0) ->
        retained = select_cleanup(cleanup, nil, grace)
        PreparationGroup.retire(group, retained)

        preparation_startup_join(
          group,
          group_monitor,
          control,
          incarnation,
          invocation,
          permit,
          retained
        )
    end
  end

  defp preparation_startup_join(group, monitor, control, incarnation, invocation, permit, cleanup) do
    receive do
      {:DOWN, ^monitor, :process, ^group, _} ->
        preparation_unproved(control, incarnation, invocation, permit)
    after
      max(cleanup.observe - now(), 0) ->
        Process.exit(group, :kill)
        preparation_unproved(control, incarnation, invocation, permit)
    end
  end

  defp prepare(
         model,
         current,
         changes,
         definitions,
         context,
         guardian,
         permit,
         cutoff,
         inventory,
         group
       ) do
    registrar = fn pid, reference ->
      # Concept: only the first offer enters this invocation's resource custody.
      # Technical depth: one irrevocable row precedes owner waits and survives
      # callback DOWN. Refused distinct offers retain their existing host custody;
      # no PID membership restriction or additional resource collection is added.
      if :ets.insert_new(inventory, {:resource, pid, reference}) do
        send(group, {:resource_offered, inventory})
        preparation_request(guardian, permit, {:resource, pid, reference}, cutoff)
      else
        {:error, :unavailable}
      end
    end

    starter =
      Loopex.Runtime.ProviderLifetime.Starter.new(fn child ->
        preparation_request(guardian, permit, {:child, child}, cutoff)
      end)

    Loopex.Runtime.ProviderLifetime.scoped(registrar, starter, fn ->
      model.module.prepare_configuration(current, changes, definitions, context, model.options)
    end)
  rescue
    _ -> :unavailable
  catch
    _, _ -> :unavailable
  end

  defp preparation_request(guardian, permit, operation, cutoff) do
    monitor = Process.monitor(guardian)
    request = make_ref()
    send(guardian, {:creation_preparation_request, self(), permit, request, operation})

    result =
      receive do
        {:creation_preparation_reply, ^guardian, ^permit, ^request, result} -> result
        {:DOWN, ^monitor, :process, ^guardian, _} -> {:error, :unavailable}
        {:creation_stop, ^permit} -> {:error, :unavailable}
      after
        max(cutoff - now(), 0) -> {:error, :unavailable}
      end

    Process.demonitor(monitor, [:flush])
    result
  end

  defp preparation_await(state) do
    state = preparation_pending_resource(state)

    state =
      if state.worker_down and not state.closing,
        do: preparation_close(state, nil, false),
        else: state

    all_down =
      state.worker_down and state.group_down and state.workers_down and
        Enum.all?(state.children, fn {_pid, child} -> child.down end) and
        (is_nil(state.resource) or state.resource.down)

    cond do
      all_down and state.retired == true and not state.fallback and now() < state.cleanup.observe ->
        joined(state)

      all_down and state.closing ->
        preparation_unproved(state.control, state.incarnation, state.invocation, state.permit)

      state.closing and now() >= state.cleanup.observe ->
        preparation_force(state)
        preparation_unproved(state.control, state.incarnation, state.invocation, state.permit)

      true ->
        preparation_receive(state)
    end
  end

  defp preparation_receive(state) do
    deadline = if state.closing, do: state.cleanup.observe, else: state.cutoff

    receive do
      {:creation_preparation_request, worker, permit, request, operation}
      when permit == state.permit ->
        if worker == state.worker or match?(%{down: false}, state.children[worker]) do
          preparation_await(preparation_register(state, worker, request, operation))
        else
          preparation_await(preparation_reply(state, worker, request, {:error, :unavailable}))
        end

      {:"ETS-TRANSFER", inventory, group, :creation_preparation_resource}
      when inventory == state.inventory and group == state.group ->
        preparation_await(state)

      {:creation_outcome, worker, permit, outcome}
      when worker == state.worker and permit == state.permit ->
        preparation_await(%{state | outcome: outcome})

      {:creation_preparation_retired, group, proved, cleanup} when group == state.group ->
        retained = select_cleanup(state.cleanup, cleanup, state.grace)
        preparation_await(%{state | retired: proved, cleanup: retained})

      {:DOWN, monitor, :process, pid, _} ->
        preparation_await(preparation_down(state, monitor, pid))

      {:creation_retire, control, incarnation, invocation, permit, cleanup}
      when control == state.control and incarnation == state.incarnation and
             invocation == state.invocation and permit == state.permit ->
        preparation_await(preparation_close(state, cleanup, true))

      {:EXIT, pid, _reason} ->
        if pid == state.group,
          do: preparation_await(state),
          else: preparation_await(preparation_close(state, nil, true))
    after
      max(deadline - now(), 0) ->
        if state.closing do
          preparation_force(state)
          preparation_unproved(state.control, state.incarnation, state.invocation, state.permit)
        else
          preparation_await(preparation_close(state, nil, true))
        end
    end
  end

  defp preparation_register(state, caller, request, operation) do
    state = preparation_pending_resource(state)

    if not state.closing and now() < state.cutoff do
      case operation do
        {:child, child} when is_function(child, 0) ->
          case PreparationGroup.child(state.group, child, state.cutoff) do
            {:ok, pid, ownership} ->
              retained = %{monitor: Process.monitor(pid), down: false}
              state = %{state | children: Map.put(state.children, pid, retained)}
              PreparationGroup.release(state.group, ownership, pid)
              preparation_reply(state, caller, request, {:ok, pid})

            _ ->
              preparation_reply(state, caller, request, {:error, :unavailable})
          end

        {:resource, pid, reference} when is_pid(pid) and is_reference(reference) ->
          if match?(%{pid: ^pid, reference: ^reference}, state.resource) do
            case PreparationGroup.resource(state.group, pid, reference, state.cutoff) do
              :ok ->
                preparation_reply(state, caller, request, {:managed, self(), state.grace})

              _ ->
                state = preparation_reply(state, caller, request, {:error, :unavailable})
                preparation_close(%{state | fallback: true}, nil, true)
            end
          else
            preparation_reply(state, caller, request, {:error, :unavailable})
          end

        _ ->
          preparation_reply(state, caller, request, {:error, :unavailable})
      end
    else
      # Admission may refuse during closing; first-offer custody remains retained.
      preparation_reply(state, caller, request, {:error, :unavailable})
    end
  end

  defp preparation_reply(state, caller, request, reply) do
    send(caller, {:creation_preparation_reply, self(), state.permit, request, reply})
    state
  end

  defp preparation_down(state, monitor, pid) do
    cond do
      monitor == state.owner_monitor and pid == state.control ->
        preparation_close(state, nil, true)

      monitor == state.worker_monitor and pid == state.worker ->
        %{state | worker_down: true}

      monitor == state.group_monitor and pid == state.group ->
        state = %{state | group_down: true}

        if is_nil(state.retired) do
          state = state |> preparation_pending_resource() |> Map.put(:fallback, true)
          state = preparation_close(state, nil, true)
          preparation_force(state)
          state
        else
          state
        end

      monitor == state.workers_monitor and pid == state.workers ->
        %{state | workers_down: true}

      is_map(state.resource) and monitor == state.resource.monitor and pid == state.resource.pid ->
        %{state | resource: %{state.resource | down: true}}

      true ->
        case state.children do
          %{^pid => %{monitor: ^monitor} = child} ->
            %{state | children: Map.put(state.children, pid, %{child | down: true})}

          _ ->
            state
        end
    end
  end

  # Concept: callback loss cannot erase an already admitted first offer.
  # Technical depth: group ownership transfers the one-row table to this guardian
  # on group loss. Re-read after original producer DOWN before any final verdict.
  defp preparation_pending_resource(%{resource: nil} = state) do
    case :ets.lookup(state.inventory, :resource) do
      [{:resource, pid, reference}] ->
        resource = %{pid: pid, reference: reference, monitor: Process.monitor(pid), down: false}
        if state.fallback, do: Process.exit(pid, :kill)
        %{state | resource: resource}

      [] ->
        state
    end
  rescue
    ArgumentError -> %{state | fallback: true}
  end

  defp preparation_pending_resource(state), do: state

  defp preparation_close(state, requested, stopped) do
    cleanup = select_cleanup(state.cleanup, requested, state.grace)

    if not state.closing do
      # Capture is distinct from stopping. A valid result may proceed, spending
      # this same observation window in every later Store and activation phase.
      send(
        state.control,
        {:creation_preparation_cleanup, state.incarnation, state.invocation, state.permit, self(),
         cleanup}
      )
    end

    if stopped and not state.stopping do
      send(
        state.control,
        {:creation_carrier_stopping, state.incarnation, state.invocation, state.permit, self(),
         cleanup}
      )
    end

    PreparationGroup.retire(state.group, cleanup)
    %{state | closing: true, stopping: state.stopping or stopped, cleanup: cleanup}
  end

  defp preparation_force(state) do
    state = preparation_pending_resource(state)
    if not state.worker_down, do: Process.exit(state.worker, :kill)
    for {pid, child} <- state.children, not child.down, do: Process.exit(pid, :kill)

    if is_map(state.resource) and not state.resource.down,
      do: Process.exit(state.resource.pid, :kill)

    if not state.workers_down, do: Process.exit(state.workers, :kill)
    if not state.group_down, do: Process.exit(state.group, :kill)
  end

  defp preparation_unproved(control, incarnation, invocation, permit) do
    send(control, {:creation_cleanup_unproved, incarnation, invocation, permit, self()})
    exit(:creation_cleanup_unproved)
  end

  defp now, do: System.monotonic_time(:millisecond)
end

defmodule Loopex.Runtime.CreationCarrier.PreparationGroup do
  @moduledoc false
  use GenServer
  alias Loopex.Executor
  alias Loopex.Runtime.TaskSupervisor

  # Concept: preparation resources have a second owner if their guardian dies.
  # Technical depth: this invocation-local group retains original monitors before
  # starter/registration acknowledgement and never owns session or Store truth.
  def start(runtime_workers, guardian, control, identity, cutoff, grace, cleanup) do
    TaskSupervisor.start_child(
      runtime_workers,
      fn ->
        {:ok, state} =
          init({runtime_workers, guardian, control, identity, cutoff, grace, cleanup})

        send(
          guardian,
          {:creation_preparation_group_ready, self(), state.workers, state.inventory}
        )

        :gen_server.enter_loop(__MODULE__, [], state)
      end,
      shutdown: :infinity
    )
  end

  def workers(group, cutoff), do: call(group, :workers, cutoff)
  def child(group, child, cutoff), do: call(group, {:child, child}, cutoff)

  def resource(group, pid, reference, cutoff),
    do: call(group, {:resource, pid, reference}, cutoff)

  def release(group, request, pid), do: send(group, {:release, request, pid})
  def retire(group, cleanup), do: send(group, {:retire, cleanup})

  defp call(group, request, cutoff) do
    remaining = cutoff - now()
    if remaining > 0, do: GenServer.call(group, request, remaining), else: {:error, :unavailable}
  catch
    :exit, _ -> {:error, :unavailable}
  end

  @impl true
  def init({runtime_workers, guardian, control, identity, cutoff, grace, cleanup}) do
    Process.flag(:trap_exit, true)
    {:ok, workers} = TaskSupervisor.start_link()

    inventory =
      :ets.new(__MODULE__, [:set, :public, {:heir, guardian, :creation_preparation_resource}])

    {:ok,
     %{
       inventory: inventory,
       guardian: guardian,
       guardian_monitor: Process.monitor(guardian),
       identity: identity,
       control: control,
       control_monitor: Process.monitor(control),
       workers: workers,
       runtime_workers: runtime_workers,
       workers_monitor: Process.monitor(workers),
       workers_down: false,
       workers_stopping: false,
       cutoff: cutoff,
       grace: grace,
       cleanup: cleanup,
       closing: false,
       forced: false,
       children: %{},
       resource: nil,
       proved: true,
       timer: nil,
       timer_token: nil
     }}
  end

  @impl true
  def handle_call(:workers, {guardian, _}, %{guardian: guardian} = state),
    do: {:reply, {:ok, state.workers}, state}

  def handle_call({:child, child}, {guardian, _}, %{guardian: guardian, closing: false} = state)
      when is_function(child, 0) do
    if now() < state.cutoff do
      group = self()
      request = make_ref()

      result =
        TaskSupervisor.start_child(
          state.workers,
          fn ->
            owner = Process.monitor(group)

            receive do
              {:creation_child_owned, ^group, ^request} -> child.()
              {:DOWN, ^owner, :process, ^group, _} -> :ok
            after
              max(state.cutoff - now(), 0) -> :ok
            end
          end,
          restart: :temporary,
          shutdown: :brutal_kill
        )

      case result do
        {:ok, pid} ->
          retained = %{monitor: Process.monitor(pid), request: request, down: false}

          {:reply, {:ok, pid, request},
           %{state | children: Map.put(state.children, pid, retained)}}

        _ ->
          {:reply, {:error, :unavailable}, state}
      end
    else
      {:reply, {:error, :unavailable}, state}
    end
  end

  def handle_call({:resource, pid, reference}, {guardian, _}, %{guardian: guardian} = state)
      when is_pid(pid) and is_reference(reference) do
    state = retain_pending_resource(state)

    if not state.closing and now() < state.cutoff and
         match?(%{pid: ^pid, reference: ^reference, accepted: false}, state.resource) do
      {:reply, :ok, %{state | resource: %{state.resource | accepted: true}}}
    else
      {:reply, {:error, :unavailable}, state}
    end
  end

  def handle_call(_request, _from, state), do: {:reply, {:error, :unavailable}, state}

  @impl true
  def handle_info({:release, request, pid}, %{closing: false} = state) do
    case state.children do
      %{^pid => %{request: ^request, down: false}} ->
        if now() < state.cutoff, do: send(pid, {:creation_child_owned, self(), request})

      _ ->
        :ok
    end

    {:noreply, state}
  end

  def handle_info({:resource_offered, inventory}, %{inventory: inventory} = state) do
    state = retain_pending_resource(state)
    if state.closing, do: advance(begin_cleanup(state, nil)), else: {:noreply, state}
  end

  def handle_info({:retire, cleanup}, state), do: advance(begin_cleanup(state, cleanup))

  def handle_info({:DOWN, monitor, :process, pid, _}, state) do
    cond do
      monitor == state.guardian_monitor and pid == state.guardian ->
        advance(state |> retain_pending_resource() |> begin_cleanup(nil))

      monitor == state.control_monitor and pid == state.control ->
        advance(state |> retain_pending_resource() |> begin_cleanup(nil))

      monitor == state.workers_monitor and pid == state.workers ->
        advance(
          begin_cleanup(
            %{state | workers_down: true, proved: state.proved and state.workers_stopping},
            nil
          )
        )

      is_map(state.resource) and monitor == state.resource.monitor and pid == state.resource.pid ->
        resource = %{state.resource | down: true}
        advance(%{state | resource: resource, proved: state.proved and resource.acknowledged})

      true ->
        case state.children do
          %{^pid => %{monitor: ^monitor} = child} ->
            advance(%{state | children: Map.put(state.children, pid, %{child | down: true})})

          _ ->
            {:noreply, state}
        end
    end
  end

  def handle_info({:loopex_provider_resource_stopped, stop, pid}, %{resource: resource} = state)
      when is_map(resource) and is_reference(stop) and stop == resource.stop and
             pid == resource.pid do
    advance(%{state | resource: %{resource | acknowledged: true}})
  end

  def handle_info({:cleanup_tick, token}, %{timer_token: token} = state), do: advance(state)

  def handle_info({:EXIT, guardian, _}, %{guardian: guardian} = state),
    do: advance(state |> retain_pending_resource() |> begin_cleanup(nil))

  def handle_info({:EXIT, workers, _}, %{workers: workers} = state),
    do: advance(begin_cleanup(%{state | proved: state.proved and state.workers_stopping}, nil))

  def handle_info({:EXIT, parent, _}, %{runtime_workers: parent} = state),
    do: advance(state |> retain_pending_resource() |> begin_cleanup(nil))

  def handle_info(_message, state), do: {:noreply, state}

  defp begin_cleanup(state, requested) do
    state = retain_pending_resource(state)
    cleanup = select_cleanup(state.cleanup, requested, state.grace)
    resource = state.resource

    resource =
      if is_map(resource) and is_nil(resource.stop) do
        stop = make_ref()

        send(
          resource.pid,
          {:loopex_provider_resource_stop, resource.reference, stop, self(), cleanup.cooperative,
           cleanup.observe}
        )

        %{resource | stop: stop}
      else
        resource
      end

    if not state.closing do
      {incarnation, invocation, permit} = state.identity

      send(
        state.control,
        {:creation_preparation_cleanup, incarnation, invocation, permit, state.guardian, cleanup}
      )

      for {pid, child} <- state.children,
          not child.down,
          is_nil(resource) or pid != resource.pid,
          do: Process.exit(pid, :shutdown)
    end

    %{state | closing: true, cleanup: cleanup, resource: resource}
  end

  # Concept: first-offer custody survives the callback and either single owner loss.
  # Technical depth: the group owns an irrevocable one-row table with the guardian
  # as heir. An atomic first insert is custody admission; duplicate losers remain
  # refused. Only original admitted child DOWN makes the final inventory read stable.
  defp retain_pending_resource(%{resource: nil} = state) do
    case :ets.lookup(state.inventory, :resource) do
      [{:resource, pid, reference}] ->
        %{
          state
          | resource: %{
              pid: pid,
              reference: reference,
              monitor: Process.monitor(pid),
              stop: nil,
              acknowledged: false,
              down: false,
              accepted: false
            }
        }

      [] ->
        state
    end
  end

  defp retain_pending_resource(state), do: state

  defp advance(%{closing: false} = state), do: {:noreply, state}

  defp advance(state) do
    # Drain after every original child DOWN, including an offer made after the
    # first cleanup scan. The captured window is selected once, never renewed.
    state = begin_cleanup(state, nil)
    instant = now()

    state =
      if instant >= state.cleanup.cooperative do
        for {pid, child} <- state.children, not child.down, do: Process.exit(pid, :kill)

        if is_map(state.resource) and not state.resource.down,
          do: Process.exit(state.resource.pid, :kill)

        %{state | forced: true}
      else
        state
      end

    complete =
      Enum.all?(state.children, fn {_pid, child} -> child.down end) and
        (is_nil(state.resource) or state.resource.down)

    cond do
      complete and not state.workers_down and not state.workers_stopping ->
        try do
          Supervisor.stop(state.workers, :normal, max(state.cleanup.observe - instant, 1))
        catch
          :exit, _ -> Process.exit(state.workers, :kill)
        end

        {:noreply, arm(%{state | workers_stopping: true})}

      complete and state.workers_down ->
        proved =
          state.proved and instant < state.cleanup.observe and
            (is_nil(state.resource) or state.resource.acknowledged)

        send(state.guardian, {:creation_preparation_retired, self(), proved, state.cleanup})
        {:stop, :normal, state}

      instant >= state.cleanup.observe ->
        for {pid, child} <- state.children, not child.down, do: Process.exit(pid, :kill)

        if is_map(state.resource) and not state.resource.down,
          do: Process.exit(state.resource.pid, :kill)

        Process.exit(state.workers, :kill)
        send(state.guardian, {:creation_preparation_retired, self(), false, state.cleanup})
        {:stop, :creation_cleanup_unproved, state}

      true ->
        {:noreply, arm(state)}
    end
  end

  defp arm(state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    target = if state.forced, do: state.cleanup.observe, else: state.cleanup.cooperative
    token = make_ref()
    timer = Process.send_after(self(), {:cleanup_tick, token}, max(target - now(), 0))
    %{state | timer: timer, timer_token: token}
  end

  @impl true
  def terminate(_reason, state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    # Unexpected group failure is unproved. Its surviving guardian owns the
    # same handles and original monitors and joins fallback termination.
    if is_map(state.resource) and not state.resource.down,
      do: Process.exit(state.resource.pid, :kill)

    for {pid, child} <- state.children, not child.down, do: Process.exit(pid, :kill)
    if not state.workers_down, do: Process.exit(state.workers, :kill)
    :ok
  end

  defp select_cleanup(nil, nil, grace) do
    {:ok, bounds} = Executor.cancellation_bounds(grace)
    instant = now()
    %{cooperative: instant + grace, observe: instant + bounds.executor_observe_ms}
  end

  defp select_cleanup(nil, requested, _grace), do: requested
  defp select_cleanup(retained, nil, _grace), do: retained

  defp select_cleanup(retained, requested, _grace),
    do: %{
      cooperative: min(retained.cooperative, requested.cooperative),
      observe: min(retained.observe, requested.observe)
    }

  defp now, do: System.monotonic_time(:millisecond)
end
