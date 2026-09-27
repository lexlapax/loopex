defmodule Loopex.LLM.ReqLLM.InProcess.PoolLifecycle do
  @moduledoc """
  ## Concept

  Own one request-free tagged HTTP/1 pool subtree until its cleanup is proved.

  ## Technical depth

  The owner spawn-monitors this start-blocked root before authorizing setup.
  The root monitors its owner, traps ordinary exits and retains each returned
  PID before requesting census acknowledgement. Recording uses fresh 1,000 ms
  cleanup-control bounds; an expired call cannot authorize setup progress.
  Only this root performs synchronous pool operations. A blocked dependency
  therefore cannot block the owner's independent deadline and cleanup loop.

  Configuration is extracted from one public Finch child specification and
  checked against a closed fixed projection. Inspection checks the recorded
  worker, exact children and both complete tagged Registry values. Teardown
  gracefully stops only the owned anonymous supervisor, consumes genuine
  descendant DOWN signals and polls exact registry absence at most 10 ms apart.
  Missing proof keeps this root alive with its reached obligations. Its normal
  DOWN, not an optional stopped message or parent termination, proves completion.
  Unexpected worker or pool-supervisor generation loss stays unproved even when
  replacements are discovered and gracefully reaped. Those replacement PIDs
  never overwrite the recorded roles or acquire dispatch authority.
  """

  alias Loopex.LLM.ReqLLM.Deadline
  alias Loopex.LLM.ReqLLM.InProcess.Route

  @retention [reuse_sessions: false, session_tickets: :disabled, keep_secrets: false]

  @doc """
  ## Concept

  Run the owner-created lifecycle root without receiving request or key data.

  ## Technical depth

  Input contains only owner PID, correlated reference, canonical base URL,
  reference tag and absolute native deadline. Start, inspection and stop
  commands must name that exact owner. Census entries are process-role/PID or
  registry-kind/tagged-identity tuples. Each recording reference is fresh and
  only its exact acknowledgement permits work to continue. Lost acknowledgement
  does not prevent graceful cleanup or the owner's independent census proof.
  """
  def run(%{owner: owner, reference: reference, base_url: base, tag: tag, deadline: deadline})
      when is_pid(owner) and is_reference(reference) and is_binary(base) and
             is_reference(tag) and is_integer(deadline) do
    Process.flag(:trap_exit, true)

    state = %{
      owner: owner,
      reference: reference,
      base: base,
      tag: tag,
      deadline: deadline,
      owner_monitor: Process.monitor(owner),
      owner_down: false,
      setup_deadline: nil,
      anonymous: nil,
      pool_supervisor: nil,
      worker: nil,
      identity: nil,
      expected: nil,
      pool: nil,
      spec: nil,
      registries: false,
      reported: MapSet.new(),
      monitors: %{},
      down: MapSet.new(),
      child_unknown: false,
      generation_unknown: false,
      stop_issued: false,
      worker_required: false
    }

    dormant(state)
  end

  defp dormant(state) do
    receive do
      {:loopex_pool_start, owner, reference}
      when owner == state.owner and reference == state.reference ->
        state = %{state | setup_deadline: min(state.deadline, control_deadline())}

        case control(state) do
          {:ok, state} -> prepare(state)
          other -> settle(other)
        end

      {:loopex_pool_stop, owner, stop_ref, deadline}
      when owner == state.owner and is_reference(stop_ref) and is_integer(deadline) ->
        unwind(state, {:stop, stop_ref}, capped(deadline))

      {:DOWN, monitor, :process, owner, _reason}
      when monitor == state.owner_monitor and owner == state.owner ->
        unwind(%{state | owner_down: true}, :failed, control_deadline())

      _unrelated ->
        dormant(state)
    end
  end

  defp prepare(state) do
    result =
      safely(fn ->
        {:ok, base} = Route.base_url(:ollama, state.base)
        true = base == state.base
        pool = Finch.Pool.new(base, tag: state.tag)
        identity = Finch.Pool.to_name(pool)
        [] = Registry.lookup(Req.Finch, identity)
        [] = Registry.lookup(Req.Finch.SupervisorRegistry, identity)

        options = [
          finch: Req.Finch,
          pool: pool,
          protocols: [:http1],
          size: 1,
          count: 1,
          start_pool_metrics?: false
        ]

        options =
          if pool.scheme == :https,
            do: options ++ [conn_opts: [transport_opts: @retention]],
            else: options

        # Concept: Casting must not create a host-selected key-log file.
        # Technical depth: This recheck is adjacent to the sole side-effecting cast.
        nil = System.get_env("SSLKEYLOGFILE")
        spec = Finch.Pool.child_spec(options)
        expected = expected_config(spec, pool, identity)
        {pool, identity, spec, expected}
      end)

    case result do
      {:ok, {pool, identity, spec, expected}} ->
        state = %{state | pool: pool, identity: identity, spec: spec, expected: expected}
        advance(state, &start_anonymous/1)

      :error ->
        unwind(state, :failed, control_deadline())
    end
  end

  defp expected_config(spec, pool, identity) do
    %{
      id: {Finch.Pool.Supervisor, ^identity},
      type: :supervisor,
      restart: :transient,
      start:
        {Finch.Pool.Supervisor, :start_link,
         [
           {{:via, Registry,
             {Req.Finch.SupervisorRegistry, ^identity, {Finch.HTTP1.Pool, 1, config}}},
            {Req.Finch, ^pool, same, false}}
         ]}
    } = spec

    true = map_size(spec) == 4 and same === config

    fixed = %{
      mod: Finch.HTTP1.Pool,
      size: 1,
      count: 1,
      conn_max_idle_time: :infinity,
      pool_max_idle_time: :infinity,
      start_pool_metrics?: false,
      wait_for_server_settings?: false,
      ping_interval: :infinity,
      max_connection_age: :infinity,
      max_connection_age_jitter: 0,
      conn_opts: config.conn_opts
    }

    true = config === fixed
    transport = %{timeout: 5_000, nodelay: true, keepalive: true}

    transport =
      if pool.scheme == :https, do: Map.merge(transport, Map.new(@retention)), else: transport

    true =
      exact_keyword?(config.conn_opts, %{
        protocols: [:http1],
        client_settings: [enable_push: false],
        ssl_key_log_file_device: nil,
        transport_opts: config.conn_opts[:transport_opts]
      })

    true = exact_keyword?(config.conn_opts[:transport_opts], transport)
    config
  end

  defp exact_keyword?(actual, expected) do
    Keyword.keyword?(actual) and length(actual) == map_size(expected) and
      Map.new(actual) === expected
  end

  defp start_anonymous(state) do
    case safely(fn -> DynamicSupervisor.start_link(strategy: :one_for_one) end) do
      {:ok, {:ok, pid}} ->
        state = %{state | anonymous: pid}

        record_then(state, [{:process, :anonymous_supervisor, pid}], fn state ->
          record_then(
            %{state | registries: true},
            [{:registry, :worker, state.identity}, {:registry, :supervisor, state.identity}],
            &start_pool/1
          )
        end)

      _failure ->
        unwind(state, :failed, control_deadline())
    end
  end

  defp start_pool(state) do
    state = %{state | child_unknown: true}

    case safely(fn -> DynamicSupervisor.start_child(state.anonymous, state.spec) end) do
      {:ok, {:ok, pid}} ->
        state = %{state | pool_supervisor: pid, child_unknown: false, worker_required: true}
        record_then(state, [{:process, :pool_supervisor, pid}], &find_worker/1)

      {:ok, {:error, {:already_started, _foreign}}} ->
        unwind(%{state | child_unknown: false}, :failed, control_deadline())

      _failure ->
        unwind(state, :failed, control_deadline())
    end
  end

  defp find_worker(state) do
    case safely(fn -> Supervisor.which_children(state.pool_supervisor) end) do
      {:ok, [{1, pid, :worker, [Finch.HTTP1.Pool]}]} when is_pid(pid) ->
        record_then(%{state | worker: pid}, [{:process, :http1_worker, pid}], &ready/1)

      _failure ->
        unwind(state, :failed, control_deadline())
    end
  end

  defp record_then(state, entries, next) do
    state = retain_entries(state, entries)
    state = mark_reported(state, entries)
    reference = make_ref()
    send(state.owner, {:loopex_pool_record, self(), reference, entries})

    case await_record(state, reference, control_deadline()) do
      {:ok, state} -> advance(state, next)
      other -> settle(other)
    end
  end

  defp retain_entries(state, entries) do
    Enum.reduce(entries, state, fn
      {:process, _role, pid}, state -> retain_pid(state, pid)
      {:registry, _kind, _identity}, state -> state
    end)
  end

  defp mark_reported(state, entries) do
    %{
      state
      | reported:
          Enum.reduce(entries, state.reported, fn
            {:process, role, _pid}, seen -> MapSet.put(seen, {:process, role})
            {:registry, kind, _identity}, seen -> MapSet.put(seen, {:registry, kind})
          end)
    }
  end

  defp retain_pid(state, pid) do
    if pid in Map.values(state.monitors),
      do: state,
      else: %{state | monitors: Map.put(state.monitors, Process.monitor(pid), pid)}
  end

  defp await_record(state, reference, deadline) do
    receive do
      {:loopex_pool_recorded, ^reference} ->
        {:ok, state}

      message ->
        case command(state, message) do
          {:ok, state} -> await_record(state, reference, deadline)
          other -> other
        end
    after
      slice(deadline, 1_000) ->
        if remaining(deadline) == 0,
          do: {:failed, state},
          else: await_record(state, reference, deadline)
    end
  end

  defp advance(state, next) do
    case control(state) do
      {:ok, state} -> next.(state)
      other -> settle(other)
    end
  end

  defp control(state) do
    receive do
      message ->
        case command(state, message) do
          {:ok, state} -> control(state)
          other -> other
        end
    after
      0 -> if remaining(state.setup_deadline) == 0, do: {:failed, state}, else: {:ok, state}
    end
  end

  defp command(state, {:loopex_pool_stop, owner, reference, deadline})
       when owner == state.owner and is_reference(reference) and is_integer(deadline),
       do: {:stop, state, reference, capped(deadline)}

  defp command(state, {:DOWN, ref, :process, owner, _reason})
       when ref == state.owner_monitor and owner == state.owner,
       do: {:failed, %{state | owner_down: true}}

  defp command(state, {:DOWN, ref, :process, pid, reason}) do
    if state.monitors[ref] == pid,
      do: {:failed, remember_down(state, ref, pid, reason)},
      else: {:ok, state}
  end

  defp command(state, {:EXIT, pid, _reason}) when pid == state.anonymous, do: {:failed, state}
  defp command(state, _unrelated), do: {:ok, state}

  # Concept: Graceful cleanup cannot repair a lost admitted generation.
  # Technical depth: Our supervisor stop sends :shutdown to both child roles.
  # Earlier death or any other reason irreversibly withholds normal root DOWN.
  defp remember_down(state, ref, pid, reason) do
    if state.monitors[ref] == pid do
      lost_generation =
        pid in [state.pool_supervisor, state.worker] and
          (not state.stop_issued or reason != :shutdown)

      %{
        state
        | down: MapSet.put(state.down, ref),
          generation_unknown: state.generation_unknown or lost_generation
      }
    else
      state
    end
  end

  defp settle({:failed, state}), do: unwind(state, :failed, control_deadline())

  defp settle({:stop, state, reference, deadline}),
    do: unwind(state, {:stop, reference}, deadline)

  defp ready(state) do
    if exact_pool?(state) and remaining(state.setup_deadline) > 0 do
      send(
        state.owner,
        {:loopex_pool_ready, self(), state.reference, state.worker, state.identity}
      )

      live(state)
    else
      unwind(state, :failed, control_deadline())
    end
  end

  defp exact_pool?(state) do
    safely(fn ->
      Process.alive?(state.worker) and
        Supervisor.which_children(state.pool_supervisor) ===
          [{1, state.worker, :worker, [Finch.HTTP1.Pool]}] and
        Registry.lookup(Req.Finch, state.identity) === [{state.worker, Finch.HTTP1.Pool}] and
        Registry.lookup(Req.Finch.SupervisorRegistry, state.identity) ===
          [{state.pool_supervisor, {Finch.HTTP1.Pool, 1, state.expected}}]
    end) == {:ok, true}
  end

  defp live(state) do
    receive do
      {:loopex_pool_inspect, owner, reference, deadline}
      when owner == state.owner and is_reference(reference) and is_integer(deadline) ->
        inspection_deadline = capped(deadline)

        accepted =
          remaining(inspection_deadline) > 0 and exact_pool?(state) and
            remaining(inspection_deadline) > 0

        send(
          state.owner,
          {:loopex_pool_inspected, self(), reference, if(accepted, do: :ok, else: :refused)}
        )

        if accepted, do: live(state), else: unwind(state, :failed, control_deadline())

      message ->
        case command(state, message) do
          {:ok, state} -> live(state)
          other -> settle(other)
        end
    end
  end

  defp unwind(state, ending, deadline) do
    state = discover(state)
    state = cleanup_records(state)
    state = %{state | stop_issued: true}

    _stop =
      if state.anonymous && Process.alive?(state.anonymous),
        do:
          safely(fn ->
            Supervisor.stop(state.anonymous, :normal, max(1, slice(deadline, 1_000)))
          end)

    await_proof(state, ending, deadline)
  end

  # Concept: Partial setup and restarted children still require real proof.
  # Technical depth: Discovery follows only our retained supervisor ancestry.
  # Registry PIDs are never adopted. An unrecoverable required worker stays unknown.
  defp discover(state) do
    state =
      if state.anonymous && Process.alive?(state.anonymous) do
        case safely(fn -> Supervisor.which_children(state.anonymous) end) do
          {:ok, children} ->
            Enum.reduce(children, state, fn
              {_, pid, :supervisor, [Finch.Pool.Supervisor]}, state when is_pid(pid) ->
                state = retain_pid(state, pid)

                state =
                  cond do
                    state.pool_supervisor == nil ->
                      %{state | pool_supervisor: pid, child_unknown: false, worker_required: true}

                    state.pool_supervisor != pid ->
                      %{state | generation_unknown: true}

                    true ->
                      state
                  end

                discover_workers(state, pid)

              _unexpected, state ->
                %{state | child_unknown: true}
            end)

          :error ->
            state
        end
      else
        state
      end

    if state.pool_supervisor && Process.alive?(state.pool_supervisor),
      do: discover_workers(state, state.pool_supervisor),
      else: state
  end

  defp discover_workers(state, supervisor) do
    case safely(fn -> Supervisor.which_children(supervisor) end) do
      {:ok, children} ->
        Enum.reduce(children, state, fn
          {1, pid, :worker, [Finch.HTTP1.Pool]}, state when is_pid(pid) ->
            state = retain_pid(state, pid)

            cond do
              supervisor != state.pool_supervisor -> %{state | generation_unknown: true}
              state.worker == nil -> %{state | worker: pid}
              state.worker != pid -> %{state | generation_unknown: true}
              true -> state
            end

          _unexpected, state ->
            %{state | child_unknown: true}
        end)

      :error ->
        state
    end
  end

  defp cleanup_records(state) do
    entries =
      for {role, pid} <- [pool_supervisor: state.pool_supervisor, http1_worker: state.worker],
          is_pid(pid),
          not MapSet.member?(state.reported, {:process, role}),
          do: {:process, role, pid}

    if entries != [] and not state.owner_down do
      state = mark_reported(state, entries)
      ref = make_ref()
      send(state.owner, {:loopex_pool_record, self(), ref, entries})
      # Concept: A missing receipt permits cleanup, never new work.
      # Technical depth: Locally retained monitors survive the acknowledgement wait.
      case await_record(state, ref, control_deadline()) do
        {:ok, state} -> state
        {:failed, state} -> state
        {:stop, state, _ref, _deadline} -> state
      end
    else
      state
    end
  end

  defp await_proof(state, ending, deadline) do
    cond do
      remaining(deadline) > 0 and map_size(state.monitors) == MapSet.size(state.down) and
        not state.child_unknown and not state.generation_unknown and
        not (state.worker_required and state.worker == nil) and
          registries_gone?(state) ->
        case ending do
          :failed ->
            send(state.owner, {:loopex_pool_failed, self(), state.reference})

          {:stop, ref} ->
            send(state.owner, {:loopex_pool_stopped, self(), ref})

          {:failed, ref} ->
            send(state.owner, {:loopex_pool_failed, self(), state.reference})
            send(state.owner, {:loopex_pool_stopped, self(), ref})
        end

        :ok

      remaining(deadline) == 0 ->
        send(state.owner, {:loopex_pool_unproved, self(), state.reference})
        unproved(state, ending)

      true ->
        receive do
          {:DOWN, ref, :process, pid, reason} ->
            state =
              cond do
                ref == state.owner_monitor and pid == state.owner -> %{state | owner_down: true}
                state.monitors[ref] == pid -> remember_down(state, ref, pid, reason)
                true -> state
              end

            await_proof(state, ending, deadline)

          _unrelated ->
            await_proof(state, ending, deadline)
        after
          slice(deadline, 10) -> await_proof(state, ending, deadline)
        end
    end
  end

  defp registries_gone?(%{registries: false}), do: true

  defp registries_gone?(state) do
    safely(fn ->
      Registry.lookup(Req.Finch, state.identity) == [] and
        Registry.lookup(Req.Finch.SupervisorRegistry, state.identity) == []
    end) == {:ok, true}
  end

  defp unproved(state, ending) do
    receive do
      {:loopex_pool_stop, owner, reference, deadline}
      when owner == state.owner and is_reference(reference) and is_integer(deadline) ->
        next =
          if ending == :failed or match?({:failed, _}, ending),
            do: {:failed, reference},
            else: {:stop, reference}

        unwind(state, next, capped(deadline))

      {:DOWN, ref, :process, owner, _reason}
      when ref == state.owner_monitor and owner == state.owner ->
        unwind(%{state | owner_down: true}, :failed, control_deadline())

      {:DOWN, ref, :process, pid, reason} ->
        unproved(remember_down(state, ref, pid, reason), ending)

      _unrelated ->
        unproved(state, ending)
    end
  end

  defp safely(fun) do
    {:ok, fun.()}
  rescue
    _error -> :error
  catch
    _kind, _reason -> :error
  end

  defp remaining(deadline),
    do: Deadline.remaining_timeout(deadline, System.monotonic_time(:native))

  defp control_deadline,
    do: System.monotonic_time(:native) + System.convert_time_unit(1_000, :millisecond, :native)

  defp capped(deadline), do: min(deadline, control_deadline())
  defp slice(deadline, maximum), do: min(remaining(deadline), maximum)
end
