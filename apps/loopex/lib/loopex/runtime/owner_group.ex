defmodule Loopex.Runtime.OwnerGroup do
  @moduledoc false

  use GenServer

  @timer_slice_ms 3_600_000

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options) when is_list(options), do: GenServer.start_link(__MODULE__, options)

  @doc false
  @spec workers(pid()) :: {:ok, pid()} | {:error, :owner_group_unavailable}
  def workers(group) when is_pid(group) do
    try do
      GenServer.call(group, :workers, :infinity)
    catch
      :exit, _reason -> {:error, :owner_group_unavailable}
    end
  end

  @doc false
  @spec attach(pid(), pid()) :: :ok | {:error, :owner_group_unavailable}
  def attach(group, coordinator) when is_pid(group) and is_pid(coordinator) do
    try do
      GenServer.call(group, {:attach, coordinator}, :infinity)
    catch
      :exit, _reason -> {:error, :owner_group_unavailable}
    end
  end

  @doc false
  def retain_provider(group, guard, reference, grace, work_bound) do
    bounded_call(group, {:retain_provider, guard, reference, grace}, work_bound)
  end

  @doc false
  def bind_provider(group, reference, worker, work_bound) do
    bounded_call(group, {:bind_provider, reference, worker}, work_bound)
  end

  @doc false
  def retain_resource(group, reference, resource, work_bound) do
    bounded_call(group, {:retain_resource, reference, resource}, work_bound)
  end

  @doc false
  def provider_cleanup(group, reference, sampled) do
    bounded_call(
      group,
      {:provider_cleanup, reference, sampled},
      {:monotonic, sampled.observation_deadline}
    )
  end

  # Concept: retaining cleanup identities cannot outlive the original work/window.
  # Technical depth: one OTP request alias spans all native timer slices. Expiry
  # abandons it without resending, renewing the cutoff or admitting a late reply.
  defp bounded_call(group, request, bound) do
    if bound_remaining(bound) == 0 do
      {:error, :owner_group_unavailable}
    else
      request_id = :gen_server.send_request(group, request)
      await_bounded_reply(request_id, bound)
    end
  end

  defp await_bounded_reply(request_id, bound) do
    case bound_remaining(bound) do
      0 ->
        _ = :gen_server.receive_response(request_id, 0)
        {:error, :owner_group_unavailable}

      remaining ->
        case :gen_server.wait_response(request_id, min(remaining, @timer_slice_ms)) do
          {:reply, reply} ->
            if bound_remaining(bound) > 0,
              do: reply,
              else: {:error, :owner_group_unavailable}

          {:error, _reason} ->
            {:error, :owner_group_unavailable}

          :timeout ->
            await_bounded_reply(request_id, bound)
        end
    end
  end

  defp bound_remaining({:system, deadline}),
    do: max(deadline - System.system_time(:millisecond), 0)

  defp bound_remaining({:monotonic, deadline}),
    do: max(deadline - System.monotonic_time(:millisecond), 0)

  @impl GenServer
  def init(_options) do
    # Concept: model and policy work share the lifetime of the session owner
    # incarnation that started them.
    #
    # Technical depth: the private Task.Supervisor is linked to this group, not
    # to Runtime.Workers. Executor and cleanup tasks stay on Runtime.Workers, so
    # ending this group cannot terminate evidence-producing effectful work.
    Process.flag(:trap_exit, true)
    {:ok, workers} = Task.Supervisor.start_link()
    {:ok, %{workers: workers, coordinator: nil, monitor: nil, providers: %{}}}
  end

  @impl GenServer
  def handle_call(:workers, _from, state), do: {:reply, {:ok, state.workers}, state}

  def handle_call({:attach, coordinator}, _from, %{coordinator: nil} = state) do
    monitor = Process.monitor(coordinator)
    {:reply, :ok, %{state | coordinator: coordinator, monitor: monitor}}
  end

  def handle_call({:attach, _coordinator}, _from, state),
    do: {:reply, {:error, :owner_group_unavailable}, state}

  def handle_call({:retain_provider, guard, reference, grace}, {retainer, _}, state)
      when is_pid(guard) and is_reference(reference) and is_integer(grace) and grace > 0 do
    if Map.has_key?(state.providers, reference) do
      {:reply, {:error, :owner_group_unavailable}, state}
    else
      caretaker = if retainer == state.coordinator, do: nil, else: retainer
      caretaker_monitor = if caretaker, do: Process.monitor(caretaker), else: nil

      provider = %{
        guard: guard,
        guard_monitor: Process.monitor(guard),
        worker: nil,
        worker_monitor: nil,
        resource: nil,
        resource_monitor: nil,
        caretaker: caretaker,
        caretaker_monitor: caretaker_monitor,
        retainer: retainer,
        original_members: Enum.filter([guard, caretaker], &is_pid/1),
        grace: grace,
        cleanup: nil
      }

      {:reply, :ok, %{state | providers: Map.put(state.providers, reference, provider)}}
    end
  end

  def handle_call({:bind_provider, reference, worker}, {retainer, _}, state)
      when is_pid(worker) do
    case state.providers do
      %{^reference => %{worker: nil, retainer: ^retainer} = provider} ->
        provider = %{
          provider
          | worker: worker,
            worker_monitor: Process.monitor(worker),
            original_members: [worker | provider.original_members]
        }

        {:reply, :ok, %{state | providers: Map.put(state.providers, reference, provider)}}

      _ ->
        {:reply, {:error, :owner_group_unavailable}, state}
    end
  end

  def handle_call({:retain_resource, reference, resource}, {guard, _}, state)
      when is_pid(resource) do
    case state.providers do
      %{^reference => %{guard: ^guard, resource: nil} = provider} ->
        provider = %{
          provider
          | resource: resource,
            resource_monitor: Process.monitor(resource),
            original_members: [resource | provider.original_members]
        }

        {:reply, :ok, %{state | providers: Map.put(state.providers, reference, provider)}}

      _ ->
        {:reply, {:error, :owner_group_unavailable}, state}
    end
  end

  def handle_call({:provider_cleanup, reference, sampled}, {caller, _}, state) do
    {reply, providers} = select_cleanup(state.providers, reference, sampled, caller)
    {:reply, reply, %{state | providers: providers}}
  end

  @impl GenServer
  def handle_info(
        {:DOWN, monitor, :process, coordinator, _reason},
        %{monitor: monitor, coordinator: coordinator} = state
      ) do
    # Concept: the group is the barrier between a dead owner and its successor.
    #
    # Technical depth: terminate/2 synchronously stops the private supervisor
    # before this process emits DOWN. Control monitors this process rather than
    # the coordinator, so it cannot dispatch the successor while an old model
    # or policy task remains alive.
    {:stop, :normal, state}
  end

  def handle_info({:EXIT, workers, reason}, %{workers: workers} = state),
    do: {:stop, {:owner_workers_stopped, reason}, state}

  def handle_info({:DOWN, monitor, :process, pid, _reason}, state) do
    providers = retire_provider(state.providers, monitor, pid)

    completed =
      Enum.filter(providers, fn {_reference, provider} -> provider_complete?(provider) end)

    # Concept: actor DOWN cannot discard the last native child identity.
    # Technical depth: ordinary retirement spends only the already selected
    # observation cutoff. A missing/failed fence retains identities through the
    # existing unproved group termination, never a live provider-history map.
    if Enum.any?(completed, fn {_reference, provider} -> is_nil(provider.cleanup) end) do
      {:stop, :provider_cleanup_unproved, %{state | providers: providers}}
    else
      providers = retire_supervised_members(providers, state.workers, :await)

      if Enum.any?(providers, fn {_reference, provider} -> provider_complete?(provider) end),
        do: {:stop, :provider_cleanup_unproved, %{state | providers: providers}},
        else: {:noreply, %{state | providers: providers}}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, %{workers: workers, coordinator: coordinator} = state) do
    if is_pid(coordinator) and Process.alive?(coordinator),
      do: Process.exit(coordinator, :shutdown)

    if Process.alive?(workers) do
      # Concept: registered resources stay alive while their guards prove cleanup.
      # Technical depth: bulk Task.Supervisor termination kills resource siblings
      # before waiting for guards. Spend each invocation's original window first;
      # the unchanged subtree stop remains the final owner/successor barrier.
      providers = begin_provider_cleanup(state.providers)
      await_provider_cleanup(providers, workers)
      if Process.alive?(workers), do: Supervisor.stop(workers, :shutdown, :infinity)
    end

    :ok
  end

  defp select_cleanup(providers, reference, sampled, caller) do
    case providers do
      %{^reference => provider}
      when caller == provider.guard or caller == provider.worker or
             caller == provider.retainer ->
        cleanup = earlier_cleanup(provider.cleanup, sampled)
        notify_cleanup(provider, reference, cleanup)
        {{:ok, cleanup}, Map.put(providers, reference, %{provider | cleanup: cleanup})}

      _ ->
        {{:error, :owner_group_unavailable}, providers}
    end
  end

  # Concept: cleanup notices reach only invocation-local window consumers.
  # Technical depth: the ordinary coordinator obtains the window by its bounded
  # call reply; only a distinct caretaker receives and caches a window notice.
  defp notify_cleanup(provider, reference, cleanup) do
    for pid <- Enum.uniq([provider.guard, provider.worker, provider.caretaker]), is_pid(pid) do
      send(pid, {:loopex_provider_cleanup_window, self(), reference, cleanup})
    end
  end

  defp earlier_cleanup(nil, sampled), do: sampled

  defp earlier_cleanup(retained, sampled) do
    %{
      cooperative_deadline: min(retained.cooperative_deadline, sampled.cooperative_deadline),
      observation_deadline: min(retained.observation_deadline, sampled.observation_deadline)
    }
  end

  defp begin_provider_cleanup(providers) do
    started = System.monotonic_time(:millisecond)

    Map.new(providers, fn {reference, provider} ->
      if is_nil(provider.cleanup) and provider_complete?(provider) do
        # No selected window exists for this failed startup-only record. Keep
        # its native identities for unproved fallback without selecting one.
        {reference, provider}
      else
        {:ok, %{executor_observe_ms: observation}} =
          Loopex.Executor.cancellation_bounds(provider.grace)

        sampled = %{
          cooperative_deadline: started + provider.grace,
          observation_deadline: started + observation
        }

        cleanup = earlier_cleanup(provider.cleanup, sampled)
        notify_cleanup(provider, reference, cleanup)

        # Concept: normal owner cleanup stops its runtime result worker normally.
        # Technical depth: normal runtime work never traps exits or invokes host code;
        # it waits for a permit or its separate guard's evidence. Shutdown normally
        # terminates it without a failure report. Fault logging may run host filters; retain its
        # original monitor and force-kill fallback for trapping/blocking filters. The guard and
        # resource keep the selected window; final supervisor stop gates group DOWN.
        if is_pid(provider.worker), do: Process.exit(provider.worker, :shutdown)

        if is_pid(provider.guard) do
          send(
            provider.guard,
            {:loopex_provider_tree_stop, reference, make_ref(), self(), cleanup}
          )
        end

        {reference, %{provider | cleanup: cleanup}}
      end
    end)
  end

  defp await_provider_cleanup(providers, _workers) when map_size(providers) == 0, do: :ok

  defp await_provider_cleanup(providers, workers) do
    providers = retire_supervised_members(providers, workers)
    now = System.monotonic_time(:millisecond)

    {expired, remaining} =
      Enum.split_with(providers, fn {_ref, provider} ->
        is_nil(provider.cleanup) or now >= provider.cleanup.observation_deadline
      end)

    for {reference, provider} <- expired do
      if is_pid(provider.guard) do
        try do
          Loopex.Runtime.SessionCoordinator.force_owned_provider(
            provider.guard,
            reference,
            provider.cleanup
          )
        catch
          :exit, :provider_cleanup_unproved -> :ok
        end
      end

      if is_pid(provider.worker), do: Process.exit(provider.worker, :kill)
      if is_pid(provider.caretaker), do: Process.exit(provider.caretaker, :kill)
    end

    remaining = Map.new(remaining)

    if map_size(remaining) > 0 do
      deadline =
        remaining |> Map.values() |> Enum.map(& &1.cleanup.observation_deadline) |> Enum.min()

      wait =
        if Enum.all?(remaining, fn {_ref, provider} ->
             is_nil(provider.guard) and is_nil(provider.worker) and is_nil(provider.resource) and
               is_nil(provider.caretaker)
           end) do
          0
        else
          wait_slice(deadline)
        end

      receive do
        {:DOWN, monitor, :process, pid, _reason} ->
          await_provider_cleanup(retire_provider(remaining, monitor, pid), workers)

        {:"$gen_call", from, {:provider_cleanup, reference, sampled}} ->
          {reply, remaining} = select_cleanup(remaining, reference, sampled, elem(from, 0))
          GenServer.reply(from, reply)
          await_provider_cleanup(remaining, workers)

        {:"$gen_call", from, _construction} ->
          GenServer.reply(from, {:error, :owner_group_unavailable})
          await_provider_cleanup(remaining, workers)

        {:EXIT, ^workers, _reason} ->
          :ok

        _message ->
          await_provider_cleanup(remaining, workers)
      after
        wait ->
          :erlang.yield()
          await_provider_cleanup(remaining, workers)
      end
    end
  end

  # Concept: actor DOWN and supervisor membership removal are distinct observations.
  # Technical depth: only the original retained PIDs are checked; no child start
  # payloads are inspected. Every query spends the same observation remainder,
  # avoiding a fresh late-monitor race when bulk termination begins.
  defp retire_supervised_members(providers, workers, progress \\ :once) do
    completed =
      Enum.filter(providers, fn {_reference, provider} ->
        provider_complete?(provider) and not is_nil(provider.cleanup)
      end)

    if completed == [] do
      providers
    else
      deadline =
        completed
        |> Enum.map(fn {_reference, provider} ->
          provider.cleanup.observation_deadline
        end)
        |> Enum.min()

      remaining = wait_slice(deadline)

      if remaining == 0 do
        providers
      else
        try do
          members =
            GenServer.call(workers, :which_children, remaining)
            |> Enum.map(fn {_id, pid, _type, _modules} -> pid end)

          if System.monotonic_time(:millisecond) >= deadline do
            providers
          else
            retained =
              Enum.reduce(completed, providers, fn {reference, provider}, retained ->
                if Enum.any?(provider.original_members, &(&1 in members)),
                  do: retained,
                  else: Map.delete(retained, reference)
              end)

            if progress == :await and
                 Enum.any?(retained, fn {_reference, provider} ->
                   provider_complete?(provider)
                 end) do
              # Concept: a live native supervisor may still be reducing genuine EXITs.
              # Technical depth: a successful intermediate census spends only the
              # selected observation remainder; fault, nil window and expiry do
              # not obtain another allowance or a positive retirement result.
              :erlang.yield()
              retire_supervised_members(retained, workers, :await)
            else
              retained
            end
          end
        catch
          :exit, _ -> providers
        end
      end
    end
  end

  defp wait_slice(deadline),
    do: min(max(deadline - System.monotonic_time(:millisecond), 0), @timer_slice_ms)

  defp provider_complete?(provider),
    do:
      is_nil(provider.guard) and is_nil(provider.worker) and is_nil(provider.resource) and
        is_nil(provider.caretaker)

  defp retire_provider(providers, monitor, pid) do
    Enum.reduce(providers, %{}, fn {reference, provider}, retained ->
      provider =
        cond do
          provider.guard == pid and provider.guard_monitor == monitor ->
            %{provider | guard: nil, guard_monitor: nil}

          provider.worker == pid and provider.worker_monitor == monitor ->
            %{provider | worker: nil, worker_monitor: nil}

          provider.resource == pid and provider.resource_monitor == monitor ->
            %{provider | resource: nil, resource_monitor: nil}

          provider.caretaker == pid and provider.caretaker_monitor == monitor ->
            %{provider | caretaker: nil, caretaker_monitor: nil}

          true ->
            provider
        end

      Map.put(retained, reference, provider)
    end)
  end

  @impl GenServer
  def format_status(status) do
    status
    |> Map.put(:state, :redacted_owner_group_state)
    |> Map.put(:message, :redacted_owner_group_message)
    |> Map.put(:reason, :redacted_owner_group_reason)
    |> Map.put(:log, [])
  end
end
