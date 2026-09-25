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
  forwarded `SIGTERM` runs the orderly stop: one absolute
  `transport_cut_deadline_ms: 5_000`, begun before the relay cut, covers the
  relay acknowledgement, the registry gate, the listener's exact exit and the
  uninitialized-peer sweep, and a missing one fail-stops as `relay_lost`,
  `connections_lost` or `listener_lost`; then the bounded admission wait, the relay's `freeze_lease_ops` barrier with every lease row
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
  # Concept: the one reason this owner stops a component with. An exit with
  # exactly this reason is this owner's stop; any other exit, `:normal`
  # included, is the component's own.
  @owner_stop_reason {:shutdown, :loopex_owner_stop}
  @store_stop_ms 30_000
  @placement_release_ms 5_000
  @close_connections_ms 5_000
  @default_admission_wait_ms 5_000
  @relay_control_timeout_ms 5_000
  @transport_cut_deadline_ms 5_000
  # The collaboration owner decides each transport-cut step at the deadline;
  # this only lets that verdict arrive. Matches `Owner`'s own margin.
  @verdict_margin_ms 1_000
  # Measured: an orderly stop at 512 attached connections took 119 ms (OTP 29,
  # Elixir 1.20.3, `maximum_population_test.exs`); 30 s keeps a wide margin.
  @default_teardown_ms 30_000
  # A fail-stop's two awaited steps: the executor until `latched_at + 5_000`,
  # the Store until the earlier of its own 30 s and the sentinel's 35 s bound.
  @fatal_executor_ms 5_000
  # The loss reports a component may send the daemon owner in place of dying
  # with the wrong component's class.
  @reported_classes [:runtime_lost, :relay_lost, :connections_lost]
  @fatal_bound_ms 35_000
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
    listener: :listener_lost,
    index: :session_index_lost
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
      relay: nil,
      registry: nil,
      daemon_incarnation: nil,
      runtime_control: nil,
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
        {:daemon_component_fatal, _reporter, class},
        %{phase: :running} = state
      )
      when class in @reported_classes,
      do: fail_stop(state, class)

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
    if is_pid(state.registry), do: send(state.registry, progress)
    {:noreply, state}
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
  # or component failure is already waiting. The provider credential leaves
  # the owner's state before the first step, so no startup outcome — a
  # placement or credential-plane failure included — leaves it readable there.
  #
  # Technical depth: the credential lives only in this frame until the
  # credential-plane step hands it to custody; `step/3` returns the state it
  # was given on a raise, which is already the state without it.
  defp run_startup(state) do
    {credential, options} = Keyword.pop_first(state.options, :credential, :missing)
    state = %{state | options: options}
    plane = fn state -> start_credential_plane(state, credential) end

    result =
      with {:ok, state} <- step(state, :placement_lock_failed, &acquire_placement/1),
           {:ok, state} <- step(state, :credential_plane_start_failed, plane),
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

      {:daemon_component_fatal, _reporter, class}
      when class in [:relay_lost, :connections_lost] ->
        {:stop, {:fatal, :daemon_services_start_failed}}

      {:DOWN, monitor, :process, _pid, _reason}
      when is_map_key(state.runtime_monitors, monitor) ->
        {:stop, {:fatal, :composition_start_failed}}
    after
      0 ->
        case Enum.find(state.pids, fn {_name, pid} -> not Process.alive?(pid) end) do
          nil when is_pid(state.relay) ->
            if Process.alive?(state.relay),
              do: :continue,
              else: {:stop, {:fatal, :daemon_services_start_failed}}

          nil ->
            :continue

          {:listener, _pid} ->
            {:stop, {:fatal, :listener_start_failed}}

          {:collaboration, _pid} ->
            {:stop, {:fatal, :daemon_services_start_failed}}

          {_name, _pid} ->
            {:stop, {:fatal, :composition_start_failed}}
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

  defp start_credential_plane(state, :missing),
    do: {:stop, {:fatal, :credential_plane_start_failed}, state}

  defp start_credential_plane(state, credential) do
    with {:ok, registry_pid} <- CredentialRegistry.start_link([]),
         state = track(state, :credential_registry, registry_pid),
         {:ok, registry} <- CredentialRegistry.handle(registry_pid),
         {:ok, custody_pid} <-
           CredentialCustody.start_link(credential: credential),
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
        state = track(state, :collaboration, owner)

        # Concept: this is the one call made to the collaboration owner outside
        # a stop wait. Every later step, and the fail-stop path, uses what it
        # returns, so a collaboration owner that later stops answering can
        # never take this owner down with a call.
        case safe(fn -> Owner.components(owner) end) do
          %{relay: relay, registry: registry, daemon_incarnation: incarnation} ->
            {:ok, %{state | relay: relay, registry: registry, daemon_incarnation: incarnation}}

          _unavailable ->
            {:stop, {:fatal, :daemon_services_start_failed}, state}
        end

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

    case Listener.start_link(
           owner: self(),
           registry: state.registry,
           socket: state.socket,
           daemon_uid: state.daemon_uid,
           startup_ref: startup_ref
         ) do
      {:ok, listener} ->
        state = %{track(state, :listener, listener) | startup_ref: startup_ref, socket: nil}

        await_listener_park(state, listener, startup_ref, monotonic_ms() + @listener_park_ms)

      _other ->
        {:stop, {:fatal, :listener_start_failed}, state}
    end
  end

  # Concept: while the listener parks, an owned component lost first keeps its
  # own startup class.
  defp await_listener_park(state, listener, startup_ref, deadline) do
    receive do
      {:listener_parked, ^startup_ref, ^listener} ->
        {:ok, state}

      {:EXIT, pid, reason} when pid != listener ->
        case classify_startup_exit(state, pid, reason) do
          :ignore -> await_listener_park(state, listener, startup_ref, deadline)
          class -> {:stop, {:fatal, class}, state}
        end

      {:DOWN, monitor, :process, _pid, _reason}
      when is_map_key(state.runtime_monitors, monitor) ->
        {:stop, {:fatal, :composition_start_failed}, state}
    after
      remaining_ms(deadline) -> {:stop, {:fatal, :listener_start_failed}, state}
    end
  end

  # Concept: the sentinel alone decides whether the parked listener opens.
  defp begin_readiness(state) do
    incarnation = Base.encode16(state.daemon_incarnation, case: :lower)

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

  # Concept: a stop before readiness is still an operator stop, so its reverse
  # cleanup is held to the same rule as an orderly stop's: a component that
  # does not stop in time, or a placement release that fails, is that class,
  # never `0`. A startup failure already carries its class, which wins.
  defp finish_startup_failure(state, :operator_stop) do
    Logger.debug("loopex daemon startup reverse cleanup")

    with {:ok, state} <- orderly_teardown(state, monotonic_ms() + teardown_ms(state)),
         :ok <- release_placement(state) do
      report_exit(state, ExitStatus.success())
      {:stop, :normal, %{state | phase: :stopped}}
    else
      {:fatal, class, state} -> fail_stop(state, class)
      {:placement_failed, class} -> placement_failed(state, class)
    end
  end

  defp finish_startup_failure(state, reason) do
    status =
      case reason do
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
  #
  # Technical depth: the transport cut is one absolute deadline begun before
  # the relay cut, never a fresh clock per step. The relay acknowledgement and
  # registry gate, the listener's exact linked exit and the registry's empty
  # uninitialized sweep all land by it, or the stop fail-stops with the class of
  # whatever did not answer: `relay_lost`, `connections_lost` or
  # `listener_lost`. Each wait also consumes every owned component's exit.
  defp orderly_stop(state) do
    Logger.debug("loopex daemon orderly stop start")
    state = %{state | phase: :stopping}
    collaboration = state.pids.collaboration
    deadline = monotonic_ms() + @transport_cut_deadline_ms

    cut = fn -> Owner.cut_admission(collaboration, deadline - monotonic_ms()) end

    with {:ok, cut_ref} <- transport_step(state, cut, deadline, :relay_lost),
         {:ok, state} <- reap_listener(state, deadline),
         sweep = fn -> Owner.reap_uninitialized(collaboration, cut_ref, deadline) end,
         {:ok, :ok} <- transport_step(state, sweep, deadline, :connections_lost) do
      Logger.debug("loopex daemon transport cut complete")
      admitted_stop(state, collaboration)
    else
      {:fatal, class} -> fail_stop(state, class)
    end
  end

  # Concept: the collaboration owner decides each transport step at the cut
  # deadline and names what failed; an owner that gives no verdict at all is
  # itself lost, which is `relay_lost`.
  #
  # Technical depth: a success counts only if it reaches this owner by the
  # deadline, so a successful orderly stop never spends the verdict margin and
  # its published bound stands. The margin only lets a failure verdict decided
  # at the deadline arrive, and a fail-stop's own bound runs from its latch.
  # A success that arrives late is charged to the component that owns the
  # step: the relay for the cut, the registry for the sweep.
  defp transport_step(state, fun, deadline, late_class) do
    result = responsive(state, fun, deadline + @verdict_margin_ms)
    in_time = monotonic_ms() <= deadline

    case result do
      {:ok, {:ok, cut_ref}} when is_reference(cut_ref) and in_time -> {:ok, cut_ref}
      {:ok, :ok} when in_time -> {:ok, :ok}
      {:ok, {:ok, _cut_ref}} -> {:fatal, late_class}
      {:ok, :ok} -> {:fatal, late_class}
      {:ok, {:error, :connections_lost}} -> {:fatal, :connections_lost}
      {:fatal, class} -> {:fatal, class}
      _missing -> {:fatal, :relay_lost}
    end
  end

  # Concept: only the listener's exact linked exit proves no later accept can
  # arrive, so it is killed and that exit is awaited inside the cut deadline.
  defp reap_listener(state, deadline) do
    case Map.fetch(state.pids, :listener) do
      {:ok, listener} ->
        Process.exit(listener, :kill)
        await_listener_exit(state, listener, deadline)

      :error ->
        {:ok, state}
    end
  end

  defp await_listener_exit(state, listener, deadline) do
    receive do
      {:EXIT, ^listener, _reason} ->
        Logger.debug("loopex daemon listener reaped")

        {:ok,
         %{
           state
           | pids: Map.delete(state.pids, :listener),
             components: Map.delete(state.components, {:pid, listener})
         }}

      {:DOWN, runtime_monitor, :process, _pid, _reason}
      when is_map_key(state.runtime_monitors, runtime_monitor) ->
        {:fatal, :runtime_lost}

      {:daemon_component_fatal, _reporter, class}
      when class in @reported_classes ->
        {:fatal, class}

      {:EXIT, pid, reason} ->
        case classify_exit(state, pid, reason) do
          :ignore -> await_listener_exit(state, listener, deadline)
          class -> {:fatal, class}
        end
    after
      remaining_ms(deadline) ->
        Logger.debug("loopex daemon listener exit missed the transport cut")
        {:fatal, :listener_lost}
    end
  end

  # Concept: after the transport cut, the admission wait, the lease freeze,
  # the quiescing barrier, core quiesce, the seal, the stop records and the
  # tearing-down barrier run in one unlinked helper, so this owner keeps
  # consuming every owned component's exit for the whole drain. A component
  # lost at any point ends the stop with its own class, not with the class of
  # a barrier that timed out behind it.
  #
  # Technical depth: each step keeps its own bound inside the helper; core owns
  # the quiesce clock, so the wait is bounded by the steps themselves. The
  # helper answers `:drained` or the fatal class it selected; a helper that
  # ends without an answer is `relay_lost`.
  defp admitted_stop(state, collaboration) do
    plan = %{
      collaboration: collaboration,
      relay: state.relay,
      runtime: state.edges.runtime,
      admission_wait_ms:
        Keyword.get(state.options, :admission_wait_ms, @default_admission_wait_ms),
      teardown_ms: teardown_ms(state),
      diagnostic: Keyword.get(state.options, :diagnostic, :standard_error)
    }

    reporter = self()
    drain = fn -> drain_sequence(Map.put(plan, :reporter, reporter)) end

    with {:ok, {:drained, teardown_deadline}} <- responsive(state, drain, :infinity),
         :none <- owned_loss(state),
         {:ok, state} <- orderly_teardown(state, teardown_deadline),
         :ok <- release_placement(state) do
      report_exit(state, ExitStatus.success())
      {:stop, :normal, %{state | phase: :stopped}}
    else
      {:fatal, class, state} -> fail_stop(state, class)
      {:placement_failed, class} -> placement_failed(state, class)
      {:ok, {:fatal, class}} -> fail_stop(state, class)
      {:fatal, class} -> fail_stop(state, class)
      _unanswered -> fail_stop(state, :relay_lost)
    end
  end

  defp drain_sequence(plan) do
    await_admission(plan.relay, plan.admission_wait_ms)
    drain_id = make_ref()

    with :ok <- freeze_lease_ops(plan.collaboration, plan.relay),
         {:ok, ^drain_id} <-
           Owner.barrier(plan.collaboration, {:quiescing, drain_id}, relay_control_deadline()),
         {:ok, census} <- quiesce(plan) do
      Logger.debug("loopex daemon quiesce complete")
      stop_line(plan.diagnostic, census)
      seal_and_close(plan, drain_id)
    else
      {:error, :connections_lost} -> {:fatal, :connections_lost}
      {:error, :runtime_unavailable} -> {:fatal, :drain_failed}
      _missing_acknowledgement -> {:fatal, :relay_lost}
    end
  end

  # Concept: an orderly stop reports what core quiesce answered as one line on
  # standard error — the drain label, both budgets, the three counts and, for
  # every session left unknown, its stage and the head a successor compares
  # against. The line is operator evidence, not a restart input, and it is
  # attempted once and never awaited, so a blocked device cannot hold the stop.
  #
  # Technical depth: the line is built and written by an unlinked,
  # unmonitored writer, so a value the encoder refuses fails only that writer,
  # never this drain; the VM halt ends a writer blocked on its device.
  defp stop_line(device, census) do
    _writer = spawn(fn -> IO.puts(device, JSON.encode!(stop_record(census))) end)
    :ok
  end

  defp stop_record(census) do
    unknown =
      for {session_id, {:unknown, stage, head}} <- census.fences,
          do: %{
            stage: stage,
            session_id: session_id,
            owner_epoch: head.owner_epoch,
            journal_version: head.journal_version
          }

    no_head =
      for {session_id, {:unknown, :no_head}} <- census.fences,
          do: %{stage: :no_head, session_id: session_id}

    %{
      record: "daemon_stop",
      drain_id: census.drain_id,
      budget_ms: census.budget_ms,
      fence_budget_ms: census.fence_budget_ms,
      settled: length(census.settled),
      unsettled: length(census.unsettled),
      absent: length(census.absent),
      unknown: Enum.sort_by(unknown ++ no_head, & &1.session_id)
    }
  end

  # The daemon owner is told when core quiesce is active, because losing the
  # captured Control while the runtime root lives is `drain_failed` only then.
  defp quiesce(plan) do
    send(plan.reporter, {:quiesce_active, self(), true})

    try do
      Loopex.Runtime.quiesce(plan.runtime)
    catch
      _kind, _reason -> {:error, :runtime_unavailable}
    after
      send(plan.reporter, {:quiesce_active, self(), false})
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
    query = fn ->
      LoopexDaemon.AdmissionRelay.pending_origins(relay, descriptors, remaining_ms(deadline))
    end

    case safe(query) do
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
  defp seal_and_close(plan, drain_id) do
    collaboration = plan.collaboration
    teardown_deadline = monotonic_ms() + plan.teardown_ms

    with {:ok, %{results: _results, unresolved: _unresolved}} <-
           Owner.barrier(
             collaboration,
             {:seal_after_quiesce, drain_id, teardown_deadline},
             teardown_deadline
           ),
         closed when closed in [:ok, {:ok, :forced}] <-
           Owner.close_connections(
             collaboration,
             WireRecords.daemon_stopping("operator_stop"),
             min(monotonic_ms() + @close_connections_ms, teardown_deadline)
           ),
         {:ok, _owners} <- Owner.barrier(collaboration, :tearing_down, teardown_deadline) do
      {:drained, teardown_deadline}
    else
      {:error, :connections_lost} -> {:fatal, :connections_lost}
      _missing_acknowledgement -> {:fatal, :relay_lost}
    end
  end

  # Concept: the daemon's routes are bound to the runtime's exact Control and
  # EventDispatcher, so losing either — even one its supervisor restarts —
  # ends the daemon as `runtime_lost`.
  #
  # Technical depth: both are monitored once composition has started; the
  # monitors live only in this owner and are dropped when the runtime stops.
  defp monitor_runtime(%{edges: %{runtime: runtime}} = state) do
    case safe(fn -> Loopex.Runtime.children(runtime) end) do
      {:ok, %{control: control, dispatcher: dispatcher}}
      when is_pid(control) and is_pid(dispatcher) ->
        monitors = Map.new([control, dispatcher], &{Process.monitor(&1), &1})
        {:ok, %{state | runtime_monitors: monitors, runtime_control: control}}

      _unavailable ->
        :error
    end
  end

  defp monitor_runtime(state), do: {:ok, state}

  # Concept: a stop step that calls another process runs in an unlinked helper,
  # so this owner keeps consuming every owned component's exit while it waits.
  #
  # Technical depth: the helper exits with the call's result as its reason. An
  # owned exit or runtime monitor that classifies as fatal kills the helper and
  # returns that class; an exit that classifies as ignorable is consumed and
  # the wait continues. `until` is an absolute monotonic instant or `:infinity`.
  #
  # The helper's `DOWN` is matched by its pid, which only this monitor
  # watches, never by the monitor reference: a fresh reference received on in
  # a callee makes the compiler bind a receive marker here that this function
  # never uses, and that bookkeeping, in a process that also makes
  # synchronous calls and takes alias replies, crashes or spins the VM on
  # OTP 26–29 (`receive_marker_test.exs`).
  defp responsive(state, fun, until) do
    {helper, monitor} = spawn_monitor(fn -> exit({:responded, fun.()}) end)
    await_responsive(Map.put(state, :quiesce_active, false), helper, monitor, until)
  end

  defp await_responsive(state, helper, monitor, until) do
    receive do
      {:DOWN, _monitor, :process, ^helper, {:responded, result}} ->
        {:ok, result}

      {:DOWN, _monitor, :process, ^helper, _reason} ->
        :unavailable

      {:quiesce_active, ^helper, active} ->
        await_responsive(%{state | quiesce_active: active}, helper, monitor, until)

      {:DOWN, runtime_monitor, :process, pid, _reason}
      when is_map_key(state.runtime_monitors, runtime_monitor) ->
        end_responsive(helper, monitor, {:fatal, runtime_monitor_class(state, pid)})

      {:daemon_component_fatal, _reporter, class}
      when class in @reported_classes ->
        end_responsive(helper, monitor, {:fatal, class})

      {:EXIT, pid, reason} ->
        case classify_exit(state, pid, reason) do
          :ignore -> await_responsive(state, helper, monitor, until)
          class -> end_responsive(helper, monitor, {:fatal, class})
        end
    after
      remaining_ms(until) -> end_responsive(helper, monitor, :timeout)
    end
  end

  # Concept: the plan's split for a runtime process lost while the daemon
  # waits. During active quiesce, a captured Control found dead while the
  # runtime root still lives leaves no trustworthy census, which is
  # `drain_failed`, whichever monitor fired first; an EventDispatcher lost
  # while the root and Control live, a dead root, and any loss outside active
  # quiesce are `runtime_lost`.
  defp runtime_monitor_class(state, _pid) do
    root = get_in(state, [:edges, :runtime_supervisor])
    control = state.runtime_control

    if state.quiesce_active and is_pid(root) and Process.alive?(root) and is_pid(control) and
         not Process.alive?(control),
       do: :drain_failed,
       else: :runtime_lost
  end

  defp end_responsive(helper, monitor, result) do
    Logger.debug("loopex daemon stop wait ended without its result")
    Process.exit(helper, :kill)
    Process.demonitor(monitor)

    receive do
      {:DOWN, _monitor, :process, ^helper, _reason} -> :ok
    after
      0 -> :ok
    end

    result
  end

  defp remaining_ms(:infinity), do: :infinity
  defp remaining_ms(until), do: max(until - monotonic_ms(), 0)

  # Concept: before an orderly stop reports success, any owned component that
  # was lost while the stop was running turns it into that component's
  # fail-stop.
  defp owned_loss(state) do
    # A runtime-loss report after this owner stopped the runtime is its own doing.
    runtime_owned = Map.has_key?(state.pids, :runtime_supervisor)

    receive do
      {:DOWN, runtime_monitor, :process, _pid, _reason}
      when is_map_key(state.runtime_monitors, runtime_monitor) ->
        Logger.debug("loopex daemon runtime process lost during stop")
        {:fatal, :runtime_lost}

      {:daemon_component_fatal, _reporter, class}
      when class in [:relay_lost, :connections_lost] or
             (class == :runtime_lost and runtime_owned) ->
        Logger.debug("loopex daemon component lost during stop")
        {:fatal, class}

      {:EXIT, pid, reason} ->
        case classify_exit(state, pid, reason) do
          :ignore ->
            owned_loss(state)

          class ->
            Logger.debug("loopex daemon component lost during stop")
            {:fatal, class}
        end
    after
      0 -> relay_loss(state)
    end
  end

  # The relay is the collaboration owner's child, so its loss reaches this
  # owner only as that owner's later report; its own liveness is checked
  # directly so a relay lost before the drain answered can never be missed.
  defp relay_loss(%{relay: relay}) when is_pid(relay) do
    if Process.alive?(relay), do: :none, else: {:fatal, :relay_lost}
  end

  defp relay_loss(_state), do: :none

  defp relay_control_deadline, do: monotonic_ms() + @relay_control_timeout_ms

  defp teardown_ms(state), do: Keyword.get(state.options, :teardown_ms, @default_teardown_ms)

  # Concept: a component failure ends the daemon without draining. Service is
  # cut at once, clients are asked once to be told why, and only the two
  # components whose cleanup outlives the VM are stopped, each on a fixed
  # bound: the executor, whose stop ends its captured process groups, and a
  # live Store, whose stop releases its marker.
  #
  # Technical depth: the plan's fail-stop steps in order. The sentinel hears
  # the class first and owns the 35 s halt. The listener and relay are killed
  # untrappably and not awaited; the collaboration owner is marked first so
  # the relay's exit does not take the registry down with it. The registry
  # gets one ordinary message, never a call, except on `connections_lost`.
  # The executor is stopped until `latched_at + 5_000` and a live Store until
  # the earlier of 30 s from its start and `latched_at + 35_000`. Nothing else
  # is stopped: the VM halt ends it.
  defp fail_stop(state, class) do
    latched_at = monotonic_ms()
    Logger.debug("loopex daemon fail-stop start")
    status = status!(class)
    send(state.sentinel, {:daemon_fatal, state.owner_ref, class, status})
    state = %{state | phase: :failing}

    # The collaboration owner is this owner's linked child, and a GenServer
    # ends with its parent; unlinking keeps it, and the registry it links, up
    # for the stop records until the VM halts.
    if pid = state.pids[:collaboration] do
      Owner.fatal_teardown(pid)
      Process.unlink(pid)
    end

    for pid <- [state.pids[:listener], state.relay], is_pid(pid), do: Process.exit(pid, :kill)

    if class != :connections_lost and is_pid(state.registry) do
      send(
        state.registry,
        {:daemon_fatal_close, self(), WireRecords.daemon_stopping(fatal_reason(class))}
      )
    end

    state =
      if class == :executor_lost,
        do: state,
        else: stop_until(state, :executor, latched_at + @fatal_executor_ms)

    state =
      if class in [:store_lost, :store_capacity_exceeded],
        do: state,
        else:
          stop_until(
            state,
            :store,
            min(monotonic_ms() + @store_stop_ms, latched_at + @fatal_bound_ms)
          )

    Logger.debug("loopex daemon fail-stop complete")
    report_exit(state, status)
    {:stop, :normal, %{state | phase: :stopped}}
  end

  # Concept: a bounded stop that cannot be extended by the component: this
  # owner asks it to stop, waits only until the absolute deadline, and kills a
  # component still alive then.
  defp stop_until(state, name, deadline) do
    case Map.fetch(state.pids, name) do
      {:ok, pid} ->
        monitor = Process.monitor(pid)
        send(pid, {:system, {self(), :loopex_owner_stop}, {:terminate, @owner_stop_reason}})

        receive do
          {:DOWN, ^monitor, :process, ^pid, _reason} -> :ok
        after
          remaining_ms(deadline) ->
            Logger.debug("loopex daemon fail-stop component stop deadline reached")
            Process.exit(pid, :kill)
            Process.demonitor(monitor, [:flush])
        end

        flush_exit(pid)
        %{state | pids: Map.delete(state.pids, name)}

      :error ->
        state
    end
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
      case safe(fn -> LoopexDaemon.AdmissionRelay.status(relay, remaining_ms(deadline)) end) do
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

  # Concept: the orderly stop's teardown is part of the stop, so until success
  # is reported a component found dead that this owner did not stop is that
  # component's loss, not a clean exit.
  #
  # Technical depth: the same reverse order as `teardown/1`. Before each stop
  # every queued owned exit is classified; the stop itself is monitored, and a
  # component already gone, or ending for any reason but this owner's own
  # `:shutdown` or its kill after the stop wait, is classified by its running
  # class. The first loss ends the teardown and the stop fail-stops with the
  # components not yet stopped.
  defp orderly_teardown(state, deadline) do
    state = close_parked_socket(state)

    steps = [
      :listener,
      :collaboration,
      :runtime,
      :executor,
      :workspace_lease,
      :transfers,
      :index,
      :capability,
      :custody,
      :credential_registry,
      :store
    ]

    Enum.reduce_while(steps, {:ok, state}, fn step, {:ok, acc} ->
      with :none <- owned_loss(acc),
           {:ok, acc} <- orderly_stop_step(acc, step, deadline) do
        {:cont, {:ok, acc}}
      else
        {:fatal, class} -> {:halt, {:fatal, class, acc}}
        {:fatal, class, acc} -> {:halt, {:fatal, class, acc}}
      end
    end)
  end

  defp orderly_stop_step(state, :runtime, deadline), do: stop_runtime_bounded(state, deadline)

  # The relay is the collaboration owner's child and stops with it.
  defp orderly_stop_step(state, :collaboration, deadline) do
    with {:ok, state} <- stop_classified(state, :collaboration, deadline),
         do: {:ok, %{state | relay: nil}}
  end

  # The Store's stop is its own fixed phase, begun when the shared teardown
  # deadline is done with.
  defp orderly_stop_step(state, :store, _deadline),
    do: stop_classified(state, :store, monotonic_ms() + @store_stop_ms)

  defp orderly_stop_step(state, name, deadline), do: stop_classified(state, name, deadline)

  # Concept: this owner asks the component to stop and waits on it until the
  # absolute deadline, killing it then. A component killed at the deadline has not stopped in
  # time, which is its own class, never a clean exit.
  defp stop_classified(state, name, deadline) do
    case Map.fetch(state.pids, name) do
      {:ok, pid} ->
        Process.unlink(pid)

        result =
          await_requested_stop(pid, deadline)

        flush_exit(pid)
        state = %{state | pids: Map.delete(state.pids, name)}

        case result do
          :stopped ->
            {:ok, state}

          other ->
            Logger.debug("loopex daemon component lost or late during teardown")
            {:fatal, running_class(name, own_exit_reason(other)), state}
        end

      :error ->
        {:ok, state}
    end
  end

  # Concept: a stop counts as this owner's only when the component exits with
  # this owner's own stop reason; a component that ended any other way — even
  # with `:normal`, even after the request was sent — is that component's own
  # exit and is classified by its running class.
  #
  # Technical depth: this owner monitors the component and then itself sends
  # it the `sys` terminate request carrying `@owner_stop_reason`, the message
  # `GenServer.stop/3` and `Supervisor.stop/3` send. Signals from one sender
  # arrive in order, so the monitor is always in place before the component
  # can act on the request, and the `DOWN` reason is the component's real
  # exit reason. A stop sent from a second process could overtake the
  # monitor and turn a clean stop into `:noproc`. The monitor's `DOWN` reason
  # alone decides the result: `:stopped` for exactly that reason,
  # `:stopped_late` for a component killed at the deadline, and
  # `{:component_exit, reason}` otherwise — `:noproc` for a component already
  # gone included. The terminate request is answered by the component's exit
  # alone; nothing replies to it.
  @doc false
  @spec await_requested_stop(pid(), integer()) ::
          :stopped | :stopped_late | {:component_exit, term()}
  def await_requested_stop(pid, deadline) do
    reason = await_stopped(pid, deadline)

    case reason do
      @owner_stop_reason -> :stopped
      :stopped_late -> :stopped_late
      other -> {:component_exit, other}
    end
  end

  defp await_stopped(pid, deadline) do
    monitor = Process.monitor(pid)
    send(pid, {:system, {self(), :loopex_owner_stop}, {:terminate, @owner_stop_reason}})

    reason =
      receive do
        {:DOWN, ^monitor, :process, ^pid, reason} -> reason
      after
        remaining_ms(deadline) ->
          Logger.debug("loopex daemon teardown deadline reached")
          Process.exit(pid, :kill)

          receive do
            # A component that took the stop just as the deadline fell still
            # stopped as asked.
            {:DOWN, ^monitor, :process, ^pid, @owner_stop_reason} -> @owner_stop_reason
            {:DOWN, ^monitor, :process, ^pid, _reason} -> :stopped_late
          after
            @stop_wait_ms ->
              Process.demonitor(monitor, [:flush])
              :stopped_late
          end
      end

    reason
  end

  # Concept: the runtime tree is stopped by the same owner-sent request as any
  # component, within what remains of the shared deadline, never by the
  # unbounded `Loopex.stop/1`; a tree still up at the deadline is killed and is
  # `runtime_lost`. A runtime monitor that fired before this step is a loss,
  # not something to flush away.
  defp stop_runtime_bounded(
         %{edges: %{runtime_supervisor: supervisor}} = state,
         deadline
       )
       when is_pid(supervisor) do
    fired =
      Enum.any?(state.runtime_monitors, fn {monitor, _pid} ->
        Process.demonitor(monitor, [:info]) == false
      end)

    state = %{state | runtime_monitors: %{}}

    if fired do
      {:fatal, :runtime_lost, state}
    else
      Process.unlink(supervisor)

      result =
        await_requested_stop(supervisor, deadline)

      flush_exit(supervisor)
      state = %{state | pids: Map.delete(state.pids, :runtime_supervisor)}

      if result == :stopped,
        do: {:ok, state},
        else: {:fatal, :runtime_lost, state}
    end
  end

  defp stop_runtime_bounded(state, _deadline), do: {:ok, state}

  # A component's own exit is classified by the reason it gave.
  defp own_exit_reason({:component_exit, reason}), do: reason
  defp own_exit_reason(reason), do: reason

  defp running_class(:store, reason), do: store_class(reason)
  defp running_class(:collaboration, reason), do: collaboration_class(reason)
  defp running_class(name, _reason), do: Map.get(@running_classes, name, :runtime_lost)

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

  # Startup reverse cleanup: a class is already latched, so the bounded stop's
  # own verdict is not needed; the tree is never stopped with an unbounded call.
  defp stop_runtime(%{edges: %{runtime_supervisor: supervisor}} = state)
       when is_pid(supervisor) do
    Enum.each(state.runtime_monitors, fn {monitor, _pid} ->
      Process.demonitor(monitor, [:flush])
    end)

    {_verdict, state} =
      case stop_runtime_bounded(%{state | runtime_monitors: %{}}, monotonic_ms() + @stop_wait_ms) do
        {:ok, state} -> {:ok, state}
        {:fatal, _class, state} -> {:late, state}
      end

    state
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

  defp flush_exit(pid) do
    receive do
      {:EXIT, ^pid, _reason} -> :ok
    after
      0 -> :ok
    end
  end

  # Concept: the placement lock is released last, by a bounded helper, so a
  # blocked filesystem cannot hold the stop open. Exact `:ok` completes the
  # phase; a malformed result, an abnormal helper death or expiry is
  # `placement_lock_failed`, since a clean exit would claim a release that was
  # not proved.
  defp release_placement(%{placement: nil}), do: :ok

  defp release_placement(%{placement: handle}) do
    {helper, monitor} =
      spawn_monitor(fn -> exit({:placement_released, Placement.release(handle)}) end)

    receive do
      {:DOWN, ^monitor, :process, ^helper, {:placement_released, :ok}} ->
        Logger.debug("loopex daemon placement release attempted")
        :ok

      {:DOWN, ^monitor, :process, ^helper, _failed} ->
        Logger.debug("loopex daemon placement release failed")
        {:placement_failed, :placement_lock_failed}
    after
      @placement_release_ms ->
        Process.exit(helper, :kill)
        Logger.debug("loopex daemon placement release deadline reached")
        {:placement_failed, :placement_lock_failed}
    end
  end

  # Every component is already stopped; only the class and the sentinel's
  # latch remain.
  defp placement_failed(state, class) do
    status = status!(class)
    send(state.sentinel, {:daemon_fatal, state.owner_ref, class, status})
    report_exit(state, status)
    {:stop, :normal, %{state | phase: :stopped}}
  end

  defp report_exit(state, status) do
    if is_pid(state.sentinel), do: send(state.sentinel, {:daemon_exit, state.owner_ref, status})
    :ok
  end

  # Concept: a component that died on a call its callee never answered names
  # the callee, so a listener that died waiting on the registry is
  # `connections_lost`, not `listener_lost`.
  defp classify_exit(state, pid, reason) do
    case Map.get(state.components, {:pid, pid}) do
      nil -> :ignore
      _component -> callee_class(state, reason) || component_class(state, pid, reason)
    end
  end

  # A caller whose callee died on its own unanswered call exits with the
  # callee's reason wrapped inside its own; the innermost named component is
  # the one that actually stalled.
  defp callee_class(state, {why, {module, :call, [callee | _rest]}})
       when module in [GenServer, :gen_server, :gen] and is_pid(callee) do
    callee_class(state, why) || direct_callee_class(state, callee)
  end

  defp callee_class(_state, _reason), do: nil

  defp direct_callee_class(state, callee) do
    cond do
      callee == state.relay -> :relay_lost
      callee == state.registry -> :connections_lost
      true -> Map.get(@running_classes, Map.get(state.components, {:pid, callee}))
    end
  end

  defp component_class(state, pid, reason) do
    case Map.get(state.components, {:pid, pid}) do
      nil -> :ignore
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
