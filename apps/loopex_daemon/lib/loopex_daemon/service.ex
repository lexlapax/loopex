defmodule LoopexDaemon.Service do
  @moduledoc """
  ## Concept

  One unlinked owner process holds every resource a daemon lifetime acquires
  for a state root: the host placement lock, the credential plane, the Store
  and runtime edges, the daemon index, the collaboration owner with its relay
  and connection registry, and the listening socket. It acquires them in one
  order, releases them in the reverse order with the Store last, and names the
  first failure so the operator receives one exact exit status.

  ## Technical depth

  The command process starts this owner with `GenServer.start/3`, monitors it
  and only then sends `{:go, owner_ref, sentinel}`; `init/1` acquires nothing
  and `handle_continue/2` waits for that exact message within
  `owner_start_gate_ms: 5_000`. Before every acquisition the owner drains an
  already forwarded stop or linked exit and checks that each component it has
  started is alive, so no lock, marker or socket is taken after a stop or
  failure was already queued. Composition runs through
  `LoopexComposition.start_edges/2` with the same checkpoint between its edges
  and returns exactly what it started.

  Readiness is arbitrated by the sentinel: the owner submits the line, then
  after the sentinel's exact output success rechecks every component and
  sends either release authorization or the startup fatal it observed; only
  the sentinel opens the parked listener. While running, a linked component's
  exit is classified into its fixed fatal class and ends in fail-stop; a
  forwarded `SIGTERM` runs the orderly stop: the admission cut and transport
  gate within `transport_cut_deadline_ms: 5_000`, listener stop, the bounded
  admission wait, the relay's `freeze_lease_ops` barrier with every lease row
  it names cleaned up without client output inside
  `relay_control_timeout_ms: 5_000`, a fresh 5 s
  `quiescing` barrier, core quiesce on core's own clock, then one shared
  `teardown_ms` deadline (30 s, against a measured 119 ms at full population)
  over `seal_after_quiesce`, one `daemon.stopping` record per connection and
  the `tearing_down` barrier, before the collaboration owner, runtime and
  edges stop in reverse order, the Store last and the bounded placement
  release. A barrier the relay does not acknowledge in time ends the stop as
  `relay_lost` fail-stop without calling quiesce; an unavailable census is
  `drain_failed`. Every
  lifecycle log line is fixed and identity-free; formatted status is redacted.
  """

  use GenServer
  require Logger

  alias Loopex.LLM.ReqLLM.{CredentialCustody, CredentialRegistry, CredentialToken}
  alias Loopex.Trace.Capability
  alias LoopexComposition.Placement

  alias LoopexDaemon.{
    ExitStatus,
    Listener,
    ListenerSocket,
    Owner,
    Readiness,
    SessionIndex,
    WireRecords
  }

  @owner_start_gate_ms 5_000
  @listener_park_ms 5_000
  @stop_wait_ms 5_000
  @store_stop_ms 30_000
  @placement_release_ms 5_000
  @close_connections_ms 5_000
  @default_admission_wait_ms 5_000
  @relay_control_timeout_ms 5_000
  @transport_cut_deadline_ms 5_000
  # Measured: an orderly stop at 512 attached connections took 119 ms (OTP 29,
  # Elixir 1.20.3, `maximum_population_test.exs`); 30 s keeps a wide margin.
  @default_teardown_ms 30_000
  # The readiness version is the source VERSION this build was compiled from.
  @version Path.join([__DIR__, "..", "..", "..", "..", "VERSION"])
           |> File.read!()
           |> String.trim()
  @external_resource Path.join([__DIR__, "..", "..", "..", "..", "VERSION"])

  @running_classes %{
    store: :store_lost,
    transfers: :transfers_lost,
    workspace_lease: :workspace_lease_lost,
    executor: :executor_lost,
    runtime_supervisor: :runtime_lost,
    credential_registry: :registry_lost,
    custody: :custody_lost,
    capability: :capability_lost,
    listener: :listener_lost
  }

  @doc false
  @spec start(keyword()) :: GenServer.on_start()
  def start(options) when is_list(options), do: GenServer.start(__MODULE__, options)

  @impl true
  def init(options) do
    Process.flag(:trap_exit, true)

    state = %{
      options: options,
      gate_deadline: monotonic_ms() + @owner_start_gate_ms,
      owner_ref: nil,
      sentinel: nil,
      sentinel_monitor: nil,
      phase: :starting,
      components: %{},
      pids: %{},
      placement: nil,
      placement_identity: nil,
      daemon_uid: nil,
      edges: %{},
      socket: nil,
      startup_ref: nil,
      pending_fatal: nil,
      progress_registry: nil,
      runtime_monitors: %{}
    }

    Logger.debug("loopex daemon service owner waiting for its gate")
    {:ok, state, {:continue, :start}}
  end

  @impl true
  def handle_continue(:start, state) do
    remaining = max(state.gate_deadline - monotonic_ms(), 0)

    receive do
      {:go, owner_ref, sentinel} when is_reference(owner_ref) and is_pid(sentinel) ->
        state = %{
          state
          | owner_ref: owner_ref,
            sentinel: sentinel,
            sentinel_monitor: Process.monitor(sentinel)
        }

        Logger.debug("loopex daemon service owner gate opened")
        run_startup(state)
    after
      remaining ->
        Logger.debug("loopex daemon service owner gate expired")
        {:stop, :normal, state}
    end
  end

  @impl true
  def handle_info(
        {:daemon_signal, owner_ref, :sigterm},
        %{owner_ref: owner_ref, phase: :running} = state
      ),
      do: orderly_stop(state)

  def handle_info(
        {:daemon_component_fatal, _reporter, :runtime_lost},
        %{phase: :running} = state
      ),
      do: fail_stop(state, :runtime_lost)

  def handle_info({:EXIT, pid, reason}, %{phase: :running} = state) do
    case classify_exit(state, pid, reason) do
      :ignore -> {:noreply, state}
      class -> fail_stop(state, class)
    end
  end

  def handle_info({:DOWN, monitor, :process, _pid, _reason}, %{phase: :running} = state)
      when is_map_key(state.runtime_monitors, monitor) do
    Logger.debug("loopex daemon runtime process lost")
    fail_stop(state, :runtime_lost)
  end

  def handle_info(
        {:DOWN, monitor, :process, _sentinel, _reason},
        %{sentinel_monitor: monitor, phase: :running} = state
      ) do
    Logger.debug("loopex daemon sentinel lost")
    orderly_stop(state)
  end

  # Concept: the runtime is composed before the connection registry exists, so
  # this owner is the runtime's session-routed progress sink and forwards each
  # item to the registry once it is running; earlier progress is dropped.
  def handle_info({:loopex_progress, session_id, item} = progress, state)
      when is_binary(session_id) and is_map(item) do
    registry = state.progress_registry || cached_registry(state)
    if is_pid(registry), do: send(registry, progress)
    {:noreply, %{state | progress_registry: registry}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, _state) do
    Logger.debug("loopex daemon service owner stop")
    :ok
  end

  @impl GenServer
  def format_status(status) do
    status
    |> Map.put(:state, :redacted_daemon_service_state)
    |> Map.put(:message, :redacted_daemon_service_message)
    |> Map.put(:reason, :redacted_daemon_service_reason)
    |> Map.put(:log, [])
  end

  # Concept: each acquisition happens only after a checkpoint proves no stop
  # or component failure is already waiting.
  defp run_startup(state) do
    result =
      with {:ok, state} <- step(state, :placement_lock_failed, &acquire_placement/1),
           {:ok, state} <- step(state, :credential_plane_start_failed, &start_credential_plane/1),
           {:ok, state} <- step(state, :composition_start_failed, &start_composition/1),
           {:ok, state} <- step(state, :session_index_corrupt, &start_index/1),
           {:ok, state} <- step(state, :daemon_services_start_failed, &start_collaboration/1),
           {:ok, state} <- step(state, :socket_permission_unverified, &open_socket/1),
           {:ok, state} <- step(state, :listener_start_failed, &start_listener/1) do
        begin_readiness(state)
      end

    case result do
      {:running, state} ->
        Logger.debug("loopex daemon service running")
        {:noreply, %{state | phase: :running}}

      {:stop, reason, state} ->
        finish_startup_failure(state, reason)
    end
  end

  # Concept: a raised, thrown or exited step is classified by the step it
  # interrupted, never by the raw term.
  defp step(state, class, fun) do
    case checkpoint(state) do
      :continue ->
        try do
          fun.(state)
        catch
          _kind, _reason -> {:stop, {:fatal, class}, state}
        end

      {:stop, reason} ->
        {:stop, reason, state}
    end
  end

  # Concept: a stop or failure already queued is honoured before the next
  # acquisition rather than after it.
  defp checkpoint(state) do
    receive do
      {:daemon_signal, owner_ref, :sigterm} when owner_ref == state.owner_ref ->
        {:stop, :operator_stop}

      {:EXIT, pid, reason} ->
        case classify_startup_exit(state, pid, reason) do
          :ignore -> checkpoint(state)
          class -> {:stop, {:fatal, class}}
        end
    after
      0 -> component_check(state)
    end
  end

  # Concept: before the listener may open, every started component is proved
  # alive and every already delivered exit is classified.
  defp component_check(state) do
    receive do
      {:EXIT, pid, reason} ->
        case classify_startup_exit(state, pid, reason) do
          :ignore -> component_check(state)
          class -> {:stop, {:fatal, class}}
        end
    after
      0 ->
        case Enum.find(state.pids, fn {_name, pid} -> not Process.alive?(pid) end) do
          nil -> :continue
          {:listener, _pid} -> {:stop, {:fatal, :listener_start_failed}}
          {:collaboration, _pid} -> {:stop, {:fatal, :daemon_services_start_failed}}
          {_name, _pid} -> {:stop, {:fatal, :composition_start_failed}}
        end
    end
  end

  defp acquire_placement(state) do
    root = option!(state, :state_root)

    case Placement.acquire(root) do
      {:ok, handle} ->
        with {:ok, %File.Stat{type: :regular, uid: uid}} <- File.stat(handle),
             {:ok, placement_identity} <- Loopex.runtime_placement_id(root) do
          Logger.debug("loopex daemon placement lock held")

          {:ok,
           %{state | placement: handle, daemon_uid: uid, placement_identity: placement_identity}}
        else
          _other -> {:stop, {:fatal, :placement_lock_failed}, %{state | placement: handle}}
        end

      {:error, {class, _detail}}
      when class in [:placement_active, :placement_unverifiable, :placement_lock_failed] ->
        {:stop, {:fatal, class}, state}

      _other ->
        {:stop, {:fatal, :placement_lock_failed}, state}
    end
  end

  defp start_credential_plane(state) do
    with {:ok, registry_pid} <- CredentialRegistry.start_link([]),
         state = track(state, :credential_registry, registry_pid),
         {:ok, registry} <- CredentialRegistry.handle(registry_pid),
         {:ok, custody_pid} <-
           CredentialCustody.start_link(credential: option!(state, :credential)),
         state = track(state, :custody, custody_pid),
         {:ok, custody} <- CredentialCustody.reference(custody_pid),
         token = CredentialToken.new(),
         :ok <- CredentialRegistry.put(registry, token, custody),
         {:ok, capability_pid} <- Capability.start_link([]),
         state = track(state, :capability, capability_pid),
         {:ok, capability} <- Capability.handle(capability_pid) do
      plane = %{
        capability: capability,
        model_options: [
          credential_token: token,
          credential_registry: registry,
          tracing_capability: capability
        ]
      }

      Logger.debug("loopex daemon credential plane started")

      # Custody now holds the one copy; the owner keeps none.
      state = %{state | options: Keyword.delete(state.options, :credential)}
      {:ok, put_in(state, [:components, :credential_plane], plane)}
    else
      _failure -> {:stop, {:fatal, :credential_plane_start_failed}, state}
    end
  end

  defp start_composition(state) do
    options =
      state.options
      |> Keyword.take([
        :workspace,
        :policy,
        :policy_identity,
        :provider_launch,
        :cleanup_grace_ms,
        :project_manifest,
        :project_decision,
        :resource_manifest,
        :artifact_transfers,
        :context_token_budget
      ])
      |> Keyword.put(:progress_to, {:session, self()})
      |> Keyword.merge(
        state_root: option!(state, :state_root),
        runtime_id: state.placement_identity,
        recover_stale_writer: true,
        credential_plane: state.components.credential_plane
      )

    interrupt = fn ->
      case checkpoint(state) do
        :continue -> :continue
        {:stop, reason} -> {:stop, reason}
      end
    end

    case LoopexComposition.start_edges(options, interrupt: interrupt) do
      {:ok, edges} ->
        Logger.debug("loopex daemon composition edges started")
        state = track_edges(state, edges)

        case monitor_runtime(state) do
          {:ok, state} -> {:ok, state}
          :error -> {:stop, {:fatal, :composition_start_failed}, state}
        end

      {:error, {:stop, reason}, partial} ->
        {:stop, reason, track_edges(state, partial)}

      {:error, reason, partial} ->
        {:stop, {:fatal, composition_class(reason)}, track_edges(state, partial)}
    end
  end

  defp start_index(state) do
    case SessionIndex.start_link(
           state_root: option!(state, :state_root),
           daemon_uid: state.daemon_uid
         ) do
      {:ok, index} ->
        Logger.debug("loopex daemon session index open")
        {:ok, track(state, :index, index)}

      {:error, class} when is_atom(class) ->
        if ExitStatus.fetch(class) != :error,
          do: {:stop, {:fatal, class}, state},
          else: {:stop, {:fatal, :session_index_corrupt}, state}

      _other ->
        {:stop, {:fatal, :session_index_corrupt}, state}
    end
  end

  defp start_collaboration(state) do
    case Owner.start_link(
           admission_wait_ms:
             Keyword.get(state.options, :admission_wait_ms, @default_admission_wait_ms),
           runtime: state.edges.runtime,
           fatal_recipient: self(),
           index: state.pids.index,
           placement_identity: state.placement_identity,
           socket_path: option!(state, :socket_path),
           state_root: option!(state, :state_root)
         ) do
      {:ok, owner} ->
        Logger.debug("loopex daemon collaboration services started")
        {:ok, track(state, :collaboration, owner)}

      _other ->
        {:stop, {:fatal, :daemon_services_start_failed}, state}
    end
  end

  defp open_socket(state) do
    case ListenerSocket.open_parked(option!(state, :socket_path), state.daemon_uid) do
      {:ok, socket} -> {:ok, %{state | socket: socket}}
      {:error, {class, _detail}} -> {:stop, {:fatal, class}, state}
    end
  end

  defp start_listener(state) do
    startup_ref = make_ref()
    components = Owner.components(state.pids.collaboration)

    case Listener.start_link(
           owner: self(),
           registry: components.registry,
           socket: state.socket,
           daemon_uid: state.daemon_uid,
           startup_ref: startup_ref
         ) do
      {:ok, listener} ->
        state = %{track(state, :listener, listener) | startup_ref: startup_ref, socket: nil}

        receive do
          {:listener_parked, ^startup_ref, ^listener} -> {:ok, state}
        after
          @listener_park_ms -> {:stop, {:fatal, :listener_start_failed}, state}
        end

      _other ->
        {:stop, {:fatal, :listener_start_failed}, state}
    end
  end

  # Concept: the sentinel alone decides whether the parked listener opens.
  defp begin_readiness(state) do
    incarnation =
      state.pids.collaboration
      |> Owner.components()
      |> Map.fetch!(:daemon_incarnation)
      |> Base.encode16(case: :lower)

    case Readiness.encode(
           option!(state, :state_root),
           option!(state, :socket_path),
           incarnation,
           @version
         ) do
      {:ok, line} ->
        send(
          state.sentinel,
          {:begin_readiness, state.owner_ref, state.startup_ref, state.pids.listener, line}
        )

        await_readiness(state)

      {:error, _reason} ->
        {:stop, {:fatal, :readiness_write_failed}, state}
    end
  end

  defp await_readiness(state) do
    %{owner_ref: owner_ref, startup_ref: startup_ref} = state

    receive do
      {:readiness_output_succeeded, ^owner_ref, ^startup_ref, _sentinel} ->
        case component_check(state) do
          :continue ->
            send(
              state.sentinel,
              {:readiness_release_authorized, owner_ref, startup_ref, self(), state.pids.listener}
            )

          {:stop, {:fatal, class}} ->
            {:ok, status} = ExitStatus.fetch(class)

            send(
              state.sentinel,
              {:readiness_startup_fatal, owner_ref, startup_ref, self(), state.pids.listener,
               class, status}
            )
        end

        await_readiness(state)

      {:readiness_disposition, ^owner_ref, ^startup_ref, :running} ->
        {:running, state}

      {:readiness_disposition, ^owner_ref, ^startup_ref, :operator_stop} ->
        {:stop, :operator_stop, state}

      {:readiness_disposition, ^owner_ref, ^startup_ref, {:fatal, class, _status}} ->
        {:stop, {:fatal, class}, state}

      {:EXIT, pid, reason} ->
        case classify_startup_exit(state, pid, reason) do
          :ignore ->
            await_readiness(state)

          class ->
            {:ok, status} = ExitStatus.fetch(class)

            send(
              state.sentinel,
              {:readiness_startup_fatal, owner_ref, startup_ref, self(), state.pids.listener,
               class, status}
            )

            await_readiness(state)
        end
    end
  end

  defp finish_startup_failure(state, reason) do
    status =
      case reason do
        :operator_stop -> ExitStatus.success()
        {:fatal, class} -> status!(class)
        {:fatal, class, _kind} -> status!(class)
      end

    Logger.debug("loopex daemon startup reverse cleanup")
    teardown(state)
    release_placement(state)
    report_exit(state, status)
    {:stop, :normal, %{state | phase: :stopped}}
  end

  # Concept: an orderly stop drains admitted work through core before any
  # component it depends on is stopped, and stops the Store last.
  defp orderly_stop(state) do
    Logger.debug("loopex daemon orderly stop start")
    state = %{state | phase: :stopping}
    collaboration = state.pids.collaboration
    components = Owner.components(collaboration)

    case Owner.cut_admission(collaboration, @transport_cut_deadline_ms) do
      {:ok, cut} ->
        state = stop_component(state, :listener)
        _ = Owner.reap_uninitialized(collaboration, cut)
        admitted_stop(state, collaboration, components)

      _unacknowledged ->
        fail_stop(state, :relay_lost)
    end
  end

  defp admitted_stop(state, collaboration, components) do
    await_admission(
      components.relay,
      Keyword.get(state.options, :admission_wait_ms, @default_admission_wait_ms)
    )

    drain_id = make_ref()

    with :ok <- freeze_lease_ops(collaboration, components.relay),
         {:ok, ^drain_id} <-
           Owner.barrier(collaboration, {:quiescing, drain_id}, relay_control_deadline()) do
      drain(state, collaboration, drain_id)
    else
      {:error, :connections_lost} -> fail_stop(state, :connections_lost)
      _missing_acknowledgement -> fail_stop(state, :relay_lost)
    end
  end

  # Concept: at the admission bound lease operations freeze; the collaboration
  # owner cleans up every row the relay names without client output, and each
  # named row must be terminal in the relay, all inside one fixed
  # relay-control deadline. Unfinished mirror work is `connections_lost`;
  # anything else is `relay_lost`; neither reaches core quiesce.
  defp freeze_lease_ops(collaboration, relay) do
    deadline = relay_control_deadline()

    case Owner.barrier(collaboration, {:freeze_lease_ops, deadline}, deadline) do
      {:ok, descriptors} when is_list(descriptors) ->
        await_frozen_rows(relay, Enum.map(descriptors, &elem(&1, 1)), deadline)

      {:error, :connections_lost} ->
        {:error, :connections_lost}

      _missing ->
        {:error, :relay_lost}
    end
  end

  defp await_frozen_rows(_relay, [], _deadline), do: :ok

  defp await_frozen_rows(relay, descriptors, deadline) do
    case safe(fn -> LoopexDaemon.AdmissionRelay.pending_origins(relay, descriptors) end) do
      0 ->
        :ok

      count when is_integer(count) ->
        if monotonic_ms() >= deadline do
          {:error, :relay_lost}
        else
          Process.sleep(10)
          await_frozen_rows(relay, descriptors, deadline)
        end

      _unavailable ->
        {:error, :relay_lost}
    end
  end

  # Concept: core owns the drain clock; everything after it shares one
  # teardown deadline, and a relay that misses a barrier inside it ends the
  # stop as `relay_lost`.
  defp drain(state, collaboration, drain_id) do
    case quiesce_responsive(state) do
      {:fatal, class} ->
        fail_stop(state, class)

      {:ok, _result} ->
        Logger.debug("loopex daemon quiesce complete")
        teardown_deadline = monotonic_ms() + teardown_ms(state)

        with {:ok, %{results: _results, unresolved: _unresolved}} <-
               Owner.barrier(
                 collaboration,
                 {:seal_after_quiesce, drain_id, teardown_deadline},
                 teardown_deadline
               ),
             _closed =
               Owner.close_connections(
                 collaboration,
                 WireRecords.daemon_stopping("operator_stop"),
                 min(monotonic_ms() + @close_connections_ms, teardown_deadline)
               ),
             {:ok, _owners} <- Owner.barrier(collaboration, :tearing_down, teardown_deadline),
             :none <- owned_loss(state) do
          teardown(state)
          release_placement(state)
          report_exit(state, ExitStatus.success())
          {:stop, :normal, %{state | phase: :stopped}}
        else
          {:fatal, class} -> fail_stop(state, class)
          _missing_acknowledgement -> fail_stop(state, :relay_lost)
        end

      {:error, :runtime_unavailable} ->
        Logger.debug("loopex daemon quiesce unavailable")
        fail_stop(state, :drain_failed)
    end
  end

  # Concept: the daemon's routes are bound to the runtime's exact Control and
  # EventDispatcher, so losing either — even one its supervisor restarts —
  # ends the daemon as `runtime_lost`.
  #
  # Technical depth: both are monitored once composition has started; the
  # monitors live only in this owner and are dropped when the runtime stops.
  defp monitor_runtime(%{edges: %{runtime: runtime}} = state) do
    case Loopex.Runtime.children(runtime) do
      {:ok, %{control: control, dispatcher: dispatcher}}
      when is_pid(control) and is_pid(dispatcher) ->
        monitors = Map.new([control, dispatcher], &{Process.monitor(&1), &1})
        {:ok, %{state | runtime_monitors: monitors}}

      _unavailable ->
        :error
    end
  end

  defp monitor_runtime(state), do: {:ok, state}

  # Concept: core quiesce runs in an unlinked helper so this owner still
  # consumes every owned component's exit while it drains; a component lost
  # during the drain ends the stop with that component's class, never success.
  #
  # Technical depth: the helper exits with the quiesce result as its reason. An
  # owned exit or runtime monitor that classifies as fatal kills the helper
  # first; an exit that classifies as ignorable is consumed and the wait
  # continues. Core owns the drain clock, so the wait is bounded by it.
  defp quiesce_responsive(state) do
    runtime = state.edges.runtime

    {helper, monitor} =
      spawn_monitor(fn -> exit({:quiesced, Loopex.Runtime.quiesce(runtime)}) end)

    await_quiesce(state, helper, monitor)
  end

  defp await_quiesce(state, helper, monitor) do
    receive do
      {:DOWN, ^monitor, :process, ^helper, {:quiesced, result}} ->
        result

      {:DOWN, ^monitor, :process, ^helper, _reason} ->
        {:error, :runtime_unavailable}

      {:DOWN, runtime_monitor, :process, _pid, _reason}
      when is_map_key(state.runtime_monitors, runtime_monitor) ->
        end_quiesce(helper, monitor, :runtime_lost)

      {:EXIT, pid, reason} ->
        case classify_exit(state, pid, reason) do
          :ignore -> await_quiesce(state, helper, monitor)
          class -> end_quiesce(helper, monitor, class)
        end
    end
  end

  defp end_quiesce(helper, monitor, class) do
    Logger.debug("loopex daemon component lost during quiesce")
    Process.exit(helper, :kill)
    Process.demonitor(monitor, [:flush])
    {:fatal, class}
  end

  # Concept: before an orderly stop reports success, any owned component that
  # was lost while the stop was running turns it into that component's
  # fail-stop.
  defp owned_loss(state) do
    receive do
      {:DOWN, runtime_monitor, :process, _pid, _reason}
      when is_map_key(state.runtime_monitors, runtime_monitor) ->
        Logger.debug("loopex daemon runtime process lost during stop")
        {:fatal, :runtime_lost}

      {:EXIT, pid, reason} ->
        case classify_exit(state, pid, reason) do
          :ignore ->
            owned_loss(state)

          class ->
            Logger.debug("loopex daemon component lost during stop")
            {:fatal, class}
        end
    after
      0 -> :none
    end
  end

  defp cached_registry(%{pids: %{collaboration: collaboration}}),
    do: progress_registry(collaboration)

  defp cached_registry(_state), do: nil

  defp progress_registry(collaboration) do
    Owner.components(collaboration).registry
  catch
    :exit, _unavailable -> nil
  end

  defp relay_control_deadline, do: monotonic_ms() + @relay_control_timeout_ms

  defp teardown_ms(state), do: Keyword.get(state.options, :teardown_ms, @default_teardown_ms)

  # Concept: a component failure ends the daemon without draining, but still
  # stops the executor and a live Store so their own cleanup is attempted.
  defp fail_stop(state, class) do
    Logger.debug("loopex daemon fail-stop start")
    status = status!(class)
    send(state.sentinel, {:daemon_fatal, state.owner_ref, class, status})
    state = %{state | phase: :failing}

    if pid = state.pids[:collaboration] do
      if Process.alive?(pid) do
        _ =
          safe(fn ->
            Owner.close_connections(
              pid,
              WireRecords.daemon_stopping(fatal_reason(class)),
              monotonic_ms() + @close_connections_ms
            )
          end)
      end
    end

    teardown(state)
    report_exit(state, status)
    {:stop, :normal, %{state | phase: :stopped}}
  end

  defp fatal_reason(class) when class in [:store_lost, :store_capacity_exceeded],
    do: Atom.to_string(class)

  defp fatal_reason(class), do: "fatal:" <> Atom.to_string(class)

  defp await_admission(relay, wait_ms) do
    deadline = monotonic_ms() + wait_ms
    await_admission_until(relay, deadline)
  end

  defp await_admission_until(relay, deadline) do
    settled =
      case safe(fn -> LoopexDaemon.AdmissionRelay.status(relay) end) do
        %{pending: 0, queued: 0} -> true
        _other -> false
      end

    cond do
      settled ->
        :ok

      monotonic_ms() >= deadline ->
        :ok

      true ->
        Process.sleep(10)
        await_admission_until(relay, deadline)
    end
  end

  # Concept: components stop in the reverse of their start, with the Store
  # after every component that could still write through it.
  defp teardown(state) do
    state
    |> stop_component(:listener)
    |> close_parked_socket()
    |> stop_component(:collaboration)
    |> stop_runtime()
    |> stop_component(:executor)
    |> stop_component(:workspace_lease)
    |> stop_component(:transfers)
    |> stop_component(:index)
    |> stop_component(:capability)
    |> stop_component(:custody)
    |> stop_component(:credential_registry)
    |> stop_component(:store, @store_stop_ms)
  end

  defp close_parked_socket(%{socket: nil} = state), do: state

  defp close_parked_socket(state) do
    _ = ListenerSocket.close(state.socket)
    %{state | socket: nil}
  end

  defp stop_runtime(%{edges: %{runtime: runtime, runtime_supervisor: supervisor}} = state) do
    Enum.each(state.runtime_monitors, fn {monitor, _pid} ->
      Process.demonitor(monitor, [:flush])
    end)

    Process.unlink(supervisor)
    _ = safe(fn -> Loopex.stop(runtime) end)
    ensure_down(supervisor, @stop_wait_ms)
    %{state | pids: Map.delete(state.pids, :runtime_supervisor)}
  end

  defp stop_runtime(state), do: state

  defp stop_component(state, name, wait_ms \\ @stop_wait_ms) do
    case Map.fetch(state.pids, name) do
      {:ok, pid} ->
        Process.unlink(pid)
        monitor = Process.monitor(pid)
        Process.exit(pid, :shutdown)

        receive do
          {:DOWN, ^monitor, :process, ^pid, _reason} -> :ok
        after
          wait_ms ->
            Process.exit(pid, :kill)

            receive do
              {:DOWN, ^monitor, :process, ^pid, _reason} -> :ok
            after
              @stop_wait_ms -> Process.demonitor(monitor, [:flush])
            end
        end

        flush_exit(pid)
        %{state | pids: Map.delete(state.pids, name)}

      :error ->
        state
    end
  end

  defp ensure_down(pid, wait_ms) do
    monitor = Process.monitor(pid)

    receive do
      {:DOWN, ^monitor, :process, ^pid, _reason} -> :ok
    after
      wait_ms ->
        Process.exit(pid, :kill)

        receive do
          {:DOWN, ^monitor, :process, ^pid, _reason} -> :ok
        after
          @stop_wait_ms -> Process.demonitor(monitor, [:flush])
        end
    end

    flush_exit(pid)
  end

  defp flush_exit(pid) do
    receive do
      {:EXIT, ^pid, _reason} -> :ok
    after
      0 -> :ok
    end
  end

  # Concept: the placement lock is released last, by a bounded helper, so a
  # blocked filesystem cannot hold the stop open.
  defp release_placement(%{placement: nil}), do: :ok

  defp release_placement(%{placement: handle}) do
    {helper, monitor} =
      spawn_monitor(fn -> exit({:placement_released, Placement.release(handle)}) end)

    receive do
      {:DOWN, ^monitor, :process, ^helper, {:placement_released, :ok}} ->
        Logger.debug("loopex daemon placement release attempted")
        :ok
    after
      @placement_release_ms ->
        Process.exit(helper, :kill)
        Logger.debug("loopex daemon placement release deadline reached")
        :ok
    end
  end

  defp report_exit(state, status) do
    if is_pid(state.sentinel), do: send(state.sentinel, {:daemon_exit, state.owner_ref, status})
    :ok
  end

  defp classify_exit(state, pid, reason) do
    case Map.get(state.components, {:pid, pid}) do
      nil -> :ignore
      :index -> :ignore
      :collaboration -> collaboration_class(reason)
      :store -> store_class(reason)
      name -> Map.get(@running_classes, name, :runtime_lost)
    end
  end

  defp classify_startup_exit(state, pid, reason) do
    case Map.get(state.components, {:pid, pid}) do
      nil -> :ignore
      :listener -> :listener_start_failed
      :collaboration -> :daemon_services_start_failed
      :store -> store_class(reason)
      _other -> :composition_start_failed
    end
  end

  defp collaboration_class(:relay_lost), do: :relay_lost
  defp collaboration_class(:connections_lost), do: :connections_lost
  defp collaboration_class(_reason), do: :relay_lost

  defp store_class({:store_capacity_exceeded, _detail}), do: :store_capacity_exceeded
  defp store_class(:store_capacity_exceeded), do: :store_capacity_exceeded
  defp store_class(_reason), do: :store_lost

  defp composition_class(reason),
    do: ExitStatus.store_open_class(reason) || :composition_start_failed

  defp track(state, name, pid) do
    %{
      state
      | pids: Map.put(state.pids, name, pid),
        components: Map.put(state.components, {:pid, pid}, name)
    }
  end

  defp track_edges(state, edges) do
    state = %{state | edges: edges}

    Enum.reduce(edges, state, fn
      {:runtime, _runtime}, acc -> acc
      {name, pid}, acc when is_pid(pid) -> track(acc, name, pid)
      _other, acc -> acc
    end)
  end

  defp status!(class) do
    {:ok, status} = ExitStatus.fetch(class)
    status
  end

  defp option!(state, key), do: Keyword.fetch!(state.options, key)

  defp safe(fun) do
    fun.()
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  defp monotonic_ms, do: System.monotonic_time(:millisecond)
end
