defmodule LoopexDaemon.Owner do
  @moduledoc """
  ## Concept

  One fixed daemon owner composes collaboration processes for a daemon
  lifetime. It keeps client-visible controller results behind the matching
  routing state, so a connection never receives an epoch the registry and
  per-session lease owner have not both committed.

  ## Technical depth

  The owner starts and links the admission relay and connection registry,
  binds their shared incarnation, and starts bounded per-session lease owners.
  Each holder-changing grant, release, expiry or owner loss is one retained
  operation whose every step has its own instant, fixed when the step's
  request is sent. Registry, relay, lease-owner and holder steps use exact
  ref-tagged acknowledgements; stale replies are ignored. A missed step names
  its owner: the registry is `:connections_lost` (the registry is killed), the
  relay is `:relay_lost`, a lease owner is killed and superseded, and a holder
  connection is killed and its exit completes the close. A relay request the
  registry reports unanswered while serving is also `:relay_lost`; the
  registry's own exit is always `:connections_lost`, since it never waits on
  the relay inside a call. After the admission cut, no step starts an
  instant, a holder close already sent is bound to the transport-cut instant,
  and no `control_owner_lost` form is emitted; the lease freeze cleans up every
  descriptor the relay names before core quiesce. Status and formatted state
  expose counts only, and every lifecycle log is fixed and identity-free.
  """

  use GenServer
  require Logger

  alias LoopexDaemon.{AdmissionRelay, ConnectionRegistry, LeaseOwner, WireRecords}

  @owner_limit 512
  @mirror_deadline_ms 5_000
  # Concept: the transport cut is decided at its deadline; this only lets the
  # decision made at that instant reach the waiting stop.
  @verdict_margin_ms 1_000
  # Concept: the registry answers its final close by the close deadline
  # itself; this is how much longer it may take before it is lost.
  @registry_close_margin_ms 500
  @lease_term_ms 30_000
  @incarnation_bytes 16

  # Concept: each relay request this owner sends, each lease owner's
  # attachment acknowledgement and each request held for a retiring lease
  # owner has its own five-second instant while serving.
  @relay_request_ms 5_000

  @typedoc false
  @type origin_id :: AdmissionRelay.origin_id()

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options), do: GenServer.start_link(__MODULE__, options, timeout: 10_000)

  @doc false
  @spec components(pid()) :: %{
          relay: pid(),
          registry: pid(),
          daemon_incarnation: binary(),
          routing_incarnation: binary()
        }
  def components(owner), do: GenServer.call(owner, :components)

  @doc """
  ## Concept

  Sends a connection's acquire to this owner without waiting: the answer
  arrives later as the request's reply, once the relay has opened the permit
  or before any permit exists, so the connection keeps serving meanwhile.

  ## Technical depth

  The request is `:gen_server.send_request/2`; its reply is
  `{:ok, :accepted, actor, actor_incarnation}` or `{:error, reason}`. The
  owner admits it only from the connection it names.
  """
  @spec acquire_control_request(
          pid(),
          origin_id(),
          binary(),
          binary(),
          pid(),
          binary(),
          pid(),
          binary(),
          integer()
        ) :: :gen_server.request_id()
  def acquire_control_request(
        owner,
        permit_id,
        request_id,
        session_id,
        connection,
        connection_incarnation,
        worker,
        worker_incarnation,
        request_deadline
      ) do
    :gen_server.send_request(
      owner,
      {:acquire_control, permit_id, request_id, session_id, connection, connection_incarnation,
       worker, worker_incarnation, request_deadline}
    )
  end

  @doc """
  ## Concept

  Sends a connection's release to this owner without waiting, exactly as
  `acquire_control_request/9` does for an acquire.

  ## Technical depth

  The reply is `{:ok, :accepted, actor, actor_incarnation}` or
  `{:error, reason}`; only the named connection is admitted.
  """
  @spec release_control_request(
          pid(),
          origin_id(),
          binary(),
          binary(),
          pid(),
          binary(),
          pid(),
          binary(),
          binary(),
          integer()
        ) :: :gen_server.request_id()
  def release_control_request(
        owner,
        permit_id,
        request_id,
        session_id,
        connection,
        connection_incarnation,
        worker,
        worker_incarnation,
        writer_epoch,
        request_deadline
      ) do
    :gen_server.send_request(
      owner,
      {:release_control, permit_id, request_id, session_id, connection, connection_incarnation,
       worker, worker_incarnation, writer_epoch, request_deadline}
    )
  end

  @doc false
  @spec status(pid()) :: %{
          phase: :serving,
          owner_slots: non_neg_integer(),
          live_owners: non_neg_integer(),
          retiring_owners: non_neg_integer(),
          lost_owners: non_neg_integer(),
          waiting_owner_starts: non_neg_integer(),
          lease_operations: non_neg_integer(),
          mirror_operations: non_neg_integer(),
          pending_dispositions: non_neg_integer(),
          granted_routes: non_neg_integer(),
          owner_limit: 512,
          mirror_deadline_ms: pos_integer()
        }
  def status(owner), do: GenServer.call(owner, :status)

  @doc false
  @spec release_retirement_pop(pid(), binary()) :: :ok | {:error, :invalid_operation}
  def release_retirement_pop(owner, session_id) do
    GenServer.call(owner, {:release_retirement_pop, session_id})
  end

  @doc """
  ## Concept

  Closes admission at the start of an orderly stop: the relay refuses every
  later request and the registry admits no later initialization.

  ## Technical depth

  The relay's ref-tagged cut acknowledgement is consumed here, then the
  registry's owner-authenticated transport gate is closed with the same
  reference. `timeout` fixes the one absolute transport-cut deadline, which
  `reap_uninitialized/3` reuses: a relay that has not acknowledged by that
  instant answers `{:error, :relay_lost}`, and a registry gate that has not
  answered by it answers `{:error, :connections_lost}` after the registry is
  killed. This owner decides at the deadline; the call waits
  `@verdict_margin_ms` longer only for that verdict to arrive. Consuming the
  cut makes every serving-private owner-loss and release clock cleanup-only:
  an owner-loss operation still in progress is rebound to that instant, and
  later dead-owner and mirror-pop facts join the stop barriers instead of
  starting a clock of their own.
  """
  @spec cut_admission(pid(), timeout()) :: {:ok, reference()} | {:error, atom()}
  def cut_admission(owner, timeout \\ 15_000) do
    GenServer.call(
      owner,
      {:cut_admission, monotonic_ms() + timeout},
      timeout + @verdict_margin_ms
    )
  catch
    :exit, _timeout -> {:error, :relay_barrier_timeout}
  end

  @doc """
  ## Concept

  Sweeps the uninitialized connections the transport gate marked, once the
  listener is gone, and answers only when the registry reports them all
  closed.

  ## Technical depth

  `deadline` is the transport-cut instant `cut_admission/2` began. A registry
  that has not acknowledged the empty sweep by then answers
  `{:error, :connections_lost}` after the registry is killed.
  """
  @spec reap_uninitialized(pid(), reference(), integer()) :: :ok | {:error, atom()}
  def reap_uninitialized(owner, cut_ref, deadline) do
    GenServer.call(
      owner,
      {:reap_uninitialized, cut_ref, deadline},
      max(deadline - monotonic_ms(), 0) + @verdict_margin_ms
    )
  catch
    :exit, _timeout -> {:error, :relay_barrier_timeout}
  end

  @doc """
  ## Concept

  Moves the admission relay through one ordered shutdown barrier and returns
  its exact acknowledgement, or refuses when the relay does not answer in
  time.

  ## Technical depth

  `kind` is `{:freeze_lease_ops, admission_deadline}`, `{:quiescing,
  drain_id}`, `{:seal_after_quiesce, drain_id, deadline}` or
  `:tearing_down`. The owner sends one fresh ref-tagged barrier and replies
  only with the acknowledgement carrying that reference and kind. `deadline`
  is an absolute monotonic instant; a missing acknowledgement is
  `{:error, :relay_barrier_timeout}`, which the daemon treats as `relay_lost`.
  """
  @spec barrier(pid(), term(), integer()) :: {:ok, term()} | {:error, atom()}
  def barrier(owner, kind, deadline) when is_integer(deadline) do
    wait = max(deadline - System.monotonic_time(:millisecond), 0)

    try do
      GenServer.call(owner, {:relay_barrier, kind, deadline}, wait + 1_000)
    catch
      :exit, _timeout -> {:error, :relay_barrier_timeout}
    end
  end

  @doc """
  ## Concept

  Tells this owner, without waiting, that the daemon owner is ending the
  daemon on a fatal class and is about to kill the relay itself.

  ## Technical depth

  Only the daemon owner named at start (`fatal_recipient`) may send it. After
  the mark the relay's exit is expected teardown rather than this owner's own
  `relay_lost`, so the connection registry it links stays up for the bounded
  `daemon.stopping` writes.
  """
  @spec fatal_teardown(pid()) :: :ok
  def fatal_teardown(owner) do
    send(owner, {:daemon_fatal_teardown, self()})
    :ok
  end

  @doc false
  @spec close_connections(pid(), map(), integer()) :: :ok | {:ok, :forced} | {:error, atom()}
  def close_connections(owner, record, deadline) do
    GenServer.call(
      owner,
      {:close_connections, record, deadline},
      max(deadline - monotonic_ms(), 0) + @verdict_margin_ms
    )
  catch
    :exit, _timeout -> {:error, :close_unavailable}
  end

  @doc false
  @spec owner_loss_connection_closed(pid(), reference(), binary()) :: :ok
  def owner_loss_connection_closed(owner, close_ref, connection_incarnation) do
    send(
      owner,
      {:owner_loss_connection_closed, close_ref, self(), connection_incarnation}
    )

    :ok
  end

  @impl true
  def init(options) do
    Process.flag(:trap_exit, true)

    daemon_incarnation = Keyword.get_lazy(options, :daemon_incarnation, &incarnation/0)
    routing_incarnation = Keyword.get_lazy(options, :routing_incarnation, &incarnation/0)
    admission_wait_ms = Keyword.fetch!(options, :admission_wait_ms)
    mirror_deadline_ms = Keyword.get(options, :mirror_deadline_ms, @mirror_deadline_ms)
    lease_term_ms = Keyword.get(options, :lease_term_ms, @lease_term_ms)
    retirement_pop_gate = Keyword.get(options, :retirement_pop_gate)
    retirement_exit_gate = Keyword.get(options, :retirement_exit_gate)

    if valid_options?(
         daemon_incarnation,
         routing_incarnation,
         admission_wait_ms,
         mirror_deadline_ms,
         lease_term_ms,
         retirement_pop_gate,
         retirement_exit_gate
       ) do
      with {:ok, relay} <-
             AdmissionRelay.start_link(
               owner: self(),
               owner_incarnation: daemon_incarnation,
               admission_wait_ms: admission_wait_ms
             ),
           {:ok, registry} <- start_registry(options, relay, daemon_incarnation),
           :ok <-
             AdmissionRelay.register_registry(relay, registry, routing_incarnation),
           :ok <- ConnectionRegistry.bind_relay(registry, relay, routing_incarnation) do
        Logger.debug("loopex daemon owner start")

        {:ok,
         %{
           phase: :serving,
           daemon_incarnation: daemon_incarnation,
           routing_incarnation: routing_incarnation,
           relay: relay,
           registry: registry,
           mirror_deadline_ms: mirror_deadline_ms,
           lease_term_ms: lease_term_ms,
           retirement_pop_gate: retirement_pop_gate,
           retirement_exit_gate: retirement_exit_gate,
           owners: %{},
           owner_pids: %{},
           operations: %{},
           mirror_operations: %{},
           pending_dispositions: %{},
           routes: %{},
           attachments: %{},
           attachment_acks: %{},
           relay_requests: %{},
           lost_holders: %{},
           fatal_recipient: Keyword.get(options, :fatal_recipient),
           fatal_teardown: false,
           close: nil,
           stop: nil
         }}
      else
        _error -> {:stop, :component_start_failed}
      end
    else
      {:stop, :invalid_owner_options}
    end
  end

  @impl true
  def handle_call(:components, _from, state) do
    {:reply,
     %{
       relay: state.relay,
       registry: state.registry,
       daemon_incarnation: state.daemon_incarnation,
       routing_incarnation: state.routing_incarnation
     }, state}
  end

  # Concept: a connection's own request is admitted only from that
  # connection, so the later reply reaches the process that holds the
  # request.
  #
  # Technical depth: this is the only path by which an acquire or a release
  # reaches this owner; a caller naming another connection is refused
  # `invalid_operation` before any permit exists.
  def handle_call(message, {caller, _tag} = from, state)
      when is_tuple(message) and tuple_size(message) in [9, 10] and
             elem(message, 0) in [:acquire_control, :release_control] do
    if caller == elem(message, 4),
      do: connection_request(message, from, state),
      else: {:reply, {:error, :invalid_operation}, state}
  end

  def handle_call(message, _from, state)
      when is_tuple(message) and tuple_size(message) > 0 and
             elem(message, 0) in [:acquire_control, :release_control],
      do: {:reply, {:error, :invalid_operation}, state}

  def handle_call(
        {:release_retirement_pop, session_id},
        {caller, _tag},
        %{retirement_pop_gate: caller} = state
      ) do
    case Enum.find(state.mirror_operations, fn {_operation_ref, operation} ->
           operation.kind == :retirement and operation.step == :pop_owner_blocked and
             operation.row.session_id == session_id
         end) do
      {operation_ref, operation} ->
        state = enter_step(state, operation_ref, :pop_owner)
        request_retirement_pop(state, operation_ref, operation)
        {:reply, :ok, state}

      nil ->
        {:reply, {:error, :invalid_operation}, state}
    end
  end

  def handle_call({:release_retirement_pop, _session_id}, _from, state),
    do: {:reply, {:error, :invalid_operation}, state}

  def handle_call({:relay_barrier, kind, deadline}, from, %{stop: %{}} = state) do
    ref = make_ref()
    send(state.relay, {:relay_barrier, ref, kind})
    wait = max(deadline - monotonic_ms(), 0)
    timer = Process.send_after(self(), {:relay_barrier_deadline, ref}, wait)
    Logger.debug("loopex daemon owner relay barrier requested")
    barrier = %{ref: ref, name: barrier_name(kind), from: from, timer: timer, descriptors: nil}
    {:noreply, put_in(state, [:stop, :barrier], barrier)}
  end

  def handle_call({:relay_barrier, _kind, _deadline}, _from, state),
    do: {:reply, {:error, :relay_barrier_unavailable}, state}

  def handle_call({:cut_admission, cut_deadline}, from, %{stop: nil} = state) do
    cut_ref = make_ref()
    state = stop_own_serving_operations(state, cut_deadline)
    send(state.relay, {:relay_barrier, cut_ref, :cut})
    Logger.debug("loopex daemon owner admission cut requested")

    timer =
      Process.send_after(
        self(),
        {:transport_cut_deadline, cut_ref},
        max(cut_deadline - monotonic_ms(), 0)
      )

    stop = %{
      phase: :cutting,
      cut_ref: cut_ref,
      cut_deadline: cut_deadline,
      cut_timer: timer,
      from: from,
      pending: nil,
      swept: false,
      tombstones: %{},
      killed: MapSet.new(),
      barrier: nil,
      frozen: false
    }

    {:noreply, %{state | stop: stop}}
  end

  def handle_call(
        {:cut_admission, _cut_deadline},
        _from,
        %{stop: %{cut_ref: cut_ref, phase: phase}} = state
      )
      when phase in [:cut, :sweeping, :swept],
      do: {:reply, {:ok, cut_ref}, state}

  def handle_call({:cut_admission, _cut_deadline}, _from, state),
    do: {:reply, {:error, :transport_cut_unavailable}, state}

  def handle_call(
        {:reap_uninitialized, cut_ref, deadline},
        from,
        %{stop: %{cut_ref: cut_ref, phase: :cut}} = state
      ) do
    timer =
      Process.send_after(
        self(),
        {:transport_sweep_deadline, cut_ref},
        max(deadline - monotonic_ms(), 0)
      )

    state = %{
      state
      | stop: %{
          state.stop
          | phase: :sweeping,
            from: from,
            cut_timer: timer,
            cut_deadline: deadline
        }
    }

    {:noreply, registry_request(state, :sweep, {:reap_uninitialized, cut_ref})}
  end

  def handle_call({:reap_uninitialized, _cut_ref, _deadline}, _from, state),
    do: {:reply, {:error, :transport_cut_unavailable}, state}

  # Concept: a registry that cannot answer its own bounded close is lost: it
  # is killed and the stop is told `connections_lost`, never left waiting.
  #
  # Technical depth: the close is asked of the registry by message and this
  # owner returns to its mailbox. The registry answers by `deadline` itself,
  # killing survivors if it must; one that has not answered
  # `@registry_close_margin_ms` later is lost. That decision lands inside the
  # caller's own margin on the same deadline, so the registry, not the relay,
  # is named. A repeated close joins the one in flight.
  def handle_call({:close_connections, _record, _deadline}, from, %{close: %{} = close} = state),
    do: {:noreply, %{state | close: %{close | froms: [from | close.froms]}}}

  def handle_call({:close_connections, record, deadline}, from, state) do
    ref = make_ref()
    send(state.registry, {:owner_request, self(), ref, {:close_all, record, deadline}})

    timer =
      Process.send_after(
        self(),
        {:close_connections_deadline, ref},
        max(deadline - monotonic_ms(), 0) + @registry_close_margin_ms
      )

    {:noreply, %{state | close: %{ref: ref, froms: [from], timer: timer}}}
  end

  def handle_call(:status, _from, state) do
    live = Enum.count(state.owners, fn {_session_id, row} -> row.phase == :live end)

    retiring =
      Enum.count(state.owners, fn {_session_id, row} ->
        row.phase in [:retirement_pending, :retiring]
      end)

    lost = Enum.count(state.owners, fn {_session_id, row} -> row.phase == :lost end)

    waiting =
      Enum.count(state.owners, fn {_session_id, row} -> not is_nil(Map.get(row, :successor)) end)

    {:reply,
     %{
       phase: state.phase,
       owner_slots: owner_slot_count(state),
       live_owners: live,
       retiring_owners: retiring,
       lost_owners: lost,
       waiting_owner_starts: waiting,
       lease_operations: map_size(state.operations),
       mirror_operations: map_size(state.mirror_operations),
       pending_dispositions: map_size(state.pending_dispositions),
       granted_routes: map_size(state.routes),
       owner_limit: @owner_limit,
       mirror_deadline_ms: state.mirror_deadline_ms
     }, state}
  end

  @impl true
  # Concept: the relay's answer to a request this owner sent continues the
  # one operation it belongs to.
  def handle_info({[:alias | request_id], _reply} = message, state)
      when is_map_key(state.relay_requests, request_id),
      do: relay_request_answered(state, request_id, message)

  def handle_info({:DOWN, request_id, :process, _relay, _reason} = message, state)
      when is_map_key(state.relay_requests, request_id),
      do: relay_request_answered(state, request_id, message)

  def handle_info({:owner_relay_unanswered, request_id}, state)
      when is_map_key(state.relay_requests, request_id) do
    if is_nil(state.stop),
      do: latch_relay_lost(state),
      else: {:noreply, put_in(state, [:relay_requests, request_id, :timer], nil)}
  end

  def handle_info({:owner_relay_unanswered, _request_id}, state), do: {:noreply, state}

  # Concept: a lease owner reports the relay's exact answer for each permit
  # it handled; this owner never infers an outcome from a missing reply.
  #
  # Technical depth: `:result` removes the operation — a retained connection
  # loss for the same permit cannot coexist with it, and the pair is the
  # relay's inconsistency. `:connection_lost` settles a disposition that
  # already arrived, or marks the operation `:superseded` so the disposition
  # settles it when it comes. `:shutdown` and `:invalid` remove the
  # operation; an `:invalid` first acquire, whose actor is this owner, is
  # refused through the relay. A notice for an operation that is already
  # settling as a connection loss, tombstoned or gone is cleanup-only, while
  # one for a grant or release this owner is mirroring is a lease owner
  # contradicting its own proposal.
  def handle_info({:lease_permit_settled, permit_id, owner, owner_incarnation, kind}, state)
      when kind in [:result, :connection_lost, :shutdown, :invalid] do
    case Map.fetch(state.operations, permit_id) do
      {:ok,
       %{owner_pid: ^owner, owner_incarnation: ^owner_incarnation, phase: :opened} = operation} ->
        settle_notice(state, permit_id, operation, kind)

      {:ok, %{phase: :settling}} ->
        if Enum.any?(state.mirror_operations, fn {_ref, mirror} ->
             mirror.permit_id == permit_id and mirror.kind in [:grant, :release]
           end),
           do: {:stop, :lease_operation_invalid, state},
           else: {:noreply, state}

      _cleanup ->
        {:noreply, state}
    end
  end

  def handle_info({:lease_attachment_ack, ack_ref, owner, owner_incarnation}, state) do
    case Map.get(state.attachment_acks, ack_ref) do
      %{owner: ^owner, owner_incarnation: ^owner_incarnation} = ack ->
        {:noreply, finish_attachment_ack(state, ack_ref, ack)}

      _other ->
        {:noreply, state}
    end
  end

  # Concept: a lease owner that has not acknowledged an attachment within its
  # own five-second step while serving is replaced; its exit completes the
  # acknowledgement.
  def handle_info({:attachment_ack_deadline, ack_ref}, %{stop: nil} = state) do
    case Map.get(state.attachment_acks, ack_ref) do
      %{owner: owner} ->
        Logger.debug("loopex daemon lease owner attachment acknowledgement late")
        Process.exit(owner, :kill)
        {:noreply, put_in(state, [:attachment_acks, ack_ref, :timer], nil)}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info({:attachment_ack_deadline, _ack_ref}, state), do: {:noreply, state}

  def handle_info({:held_request_deadline, session_id, owner}, %{stop: nil} = state) do
    case Map.get(state.owners, session_id) do
      %{pid: ^owner, held: held} when held != [] ->
        if Enum.any?(held, &(&1.reason == :actor_retiring)) do
          Logger.debug("loopex daemon retiring lease owner late")
          Process.exit(owner, :kill)
        end

        {:noreply, state}

      _other ->
        {:noreply, state}
    end
  end

  def handle_info({:held_request_deadline, _session_id, _owner}, state), do: {:noreply, state}

  # Concept: a lease owner reports a relay request it has waited on for five
  # seconds while serving; the relay is what failed, so the daemon names it
  # `relay_lost`. Any other report is cleanup-only.
  def handle_info({:lease_owner_relay_unanswered, owner, owner_incarnation}, state)
      when is_pid(owner) and is_binary(owner_incarnation) do
    current? =
      case Map.get(state.owner_pids, owner) do
        nil -> false
        session_id -> match?(%{incarnation: ^owner_incarnation}, state.owners[session_id])
      end

    if is_nil(state.stop) and not state.fatal_teardown and current?,
      do: latch_relay_lost(state),
      else: {:noreply, state}
  end

  # Concept: the lease freeze tombstones every barrier-owned operation, so a
  # proposal its actor sent before being killed creates no mirror row.
  def handle_info(
        {:lease_grant_proposed, _grant_ref, permit_id, _owner, _owner_incarnation, _session_id,
         _connection, _connection_incarnation, _writer_epoch, _request_deadline},
        %{stop: %{tombstones: tombstones}} = state
      )
      when is_map_key(tombstones, permit_id) do
    Logger.debug("loopex daemon tombstoned lease proposal ignored")
    {:noreply, state}
  end

  def handle_info(
        {:release_proposed, _release_ref, permit_id, _owner, _owner_incarnation,
         _holder_incarnation},
        %{stop: %{tombstones: tombstones}} = state
      )
      when is_map_key(tombstones, permit_id) do
    Logger.debug("loopex daemon tombstoned lease proposal ignored")
    {:noreply, state}
  end

  def handle_info(
        {:lease_grant_proposed, grant_ref, permit_id, owner, owner_incarnation, session_id,
         connection, connection_incarnation, writer_epoch, request_deadline},
        state
      ) do
    case Map.fetch(state.operations, permit_id) do
      {:ok,
       %{
         request: %{
           class: :session_acquire_control,
           session_id: ^session_id,
           connection: ^connection,
           connection_incarnation: ^connection_incarnation,
           request_deadline: ^request_deadline
         },
         owner_pid: ^owner,
         owner_incarnation: ^owner_incarnation,
         phase: :opened
       } = operation} ->
        start_grant_operation(
          state,
          operation,
          grant_ref,
          writer_epoch,
          request_deadline
        )

      _other ->
        {:stop, :lease_operation_invalid, state}
    end
  end

  def handle_info(
        {:release_proposed, release_ref, permit_id, owner, owner_incarnation, holder_incarnation},
        state
      ) do
    case Map.fetch(state.operations, permit_id) do
      {:ok,
       %{
         request: %{
           class: :session_release_control,
           connection_incarnation: ^holder_incarnation
         },
         owner_pid: ^owner,
         owner_incarnation: ^owner_incarnation,
         phase: :opened
       } = operation} ->
        start_release_operation(state, operation, release_ref)

      _other ->
        {:stop, :lease_operation_invalid, state}
    end
  end

  def handle_info(
        {:lease_expiry_proposed, expiry_ref, owner, owner_incarnation, session_id, holder,
         holder_incarnation, writer_epoch},
        state
      ) do
    case Map.get(state.routes, session_id) do
      %{
        owner_pid: ^owner,
        owner_incarnation: ^owner_incarnation,
        holder_pid: ^holder,
        holder_incarnation: ^holder_incarnation,
        writer_epoch: ^writer_epoch
      } = route ->
        start_expiry_operation(state, expiry_ref, route)

      _other ->
        {:stop, :lease_operation_invalid, state}
    end
  end

  def handle_info(
        {:mirror_applied, operation_ref, registry, routing_incarnation, result},
        %{registry: registry, routing_incarnation: routing_incarnation} = state
      ) do
    continue_registry_operation(state, operation_ref, result)
  end

  def handle_info(
        {:relay_lease_operation_ack, operation_ref, relay, daemon_incarnation, action, result},
        %{relay: relay, daemon_incarnation: daemon_incarnation} = state
      ) do
    continue_relay_operation(state, operation_ref, action, result)
  end

  def handle_info(
        {:lease_owner_resolution_ack, discard_ref, owner, owner_incarnation, :discard, _result},
        state
      ),
      do: settle_discarded_operation(state, discard_ref, owner, owner_incarnation)

  def handle_info(
        {:lease_owner_resolution_ack, operation_ref, owner, owner_incarnation, action, result},
        state
      ) do
    continue_owner_operation(state, operation_ref, owner, owner_incarnation, action, result)
  end

  def handle_info(
        {:relay_lease_disposition, relay, permit_id, :connection_lost, settlement_ref, class,
         session_id, actor, actor_incarnation, start_op_ref},
        %{relay: relay} = state
      ) do
    retain_connection_loss(
      state,
      permit_id,
      settlement_ref,
      class,
      session_id,
      actor,
      actor_incarnation,
      start_op_ref
    )
  end

  def handle_info(
        {:lease_owner_retirement_intent, retirement_ref, owner, owner_incarnation, session_id},
        state
      ) do
    case Map.get(state.owners, session_id) do
      %{
        pid: ^owner,
        incarnation: ^owner_incarnation,
        phase: phase,
        retirement_ref: nil
      } = row
      when phase in [:live, :retirement_pending] and is_reference(retirement_ref) ->
        row = %{row | phase: :retiring, retirement_ref: retirement_ref}
        state = put_in(state, [:owners, session_id], row)

        :ok = LeaseOwner.complete_retirement(owner, retirement_ref)
        Logger.debug("loopex daemon lease owner retirement acknowledged")
        {:noreply, release_row_holds(state, session_id)}

      _other ->
        {:stop, :lease_operation_invalid, state}
    end
  end

  def handle_info(
        {:relay_owner_retirement_complete, relay, session_id, owner, owner_incarnation},
        %{relay: relay} = state
      ) do
    case Map.get(state.owners, session_id) do
      %{pid: ^owner, incarnation: ^owner_incarnation, phase: phase} = row
      when phase in [:retiring, :starting_waiting_pop] ->
        state = put_in(state, [:owners, session_id], %{row | relay_complete: true})
        finish_owner_retirement(state, session_id)

      _other ->
        {:stop, :relay_lost, state}
    end
  end

  def handle_info(
        {:relay_owner_lost, relay, session_id, owner, owner_incarnation, origins},
        %{relay: relay} = state
      )
      when is_list(origins) do
    case Map.get(state.owners, session_id) do
      %{pid: ^owner, incarnation: ^owner_incarnation, loss_origins: nil} = row ->
        if MapSet.size(MapSet.new(origins)) == length(origins) do
          row = %{row | relay_loss_seen: true, loss_origins: origins}
          state = put_in(state, [:owners, session_id], row)

          state =
            if row.exit_consumed do
              discard_claimed_owner_operations(state, owner, owner_incarnation)
            else
              state
            end

          Logger.debug("loopex daemon lease owner loss retained")
          maybe_start_owner_loss_pop(state, session_id, owner, owner_incarnation)
        else
          {:stop, :relay_lost, state}
        end

      %{pid: ^owner, incarnation: ^owner_incarnation, loss_origins: ^origins} ->
        {:noreply, state}

      _other ->
        {:stop, :relay_lost, state}
    end
  end

  def handle_info(
        {:relay_owner_loss_ready, relay, owner, owner_incarnation},
        %{relay: relay} = state
      ) do
    case Map.get(state.owner_pids, owner) do
      session_id when is_binary(session_id) ->
        retain_owner_loss_ready(state, session_id, owner, owner_incarnation)

      nil ->
        case Enum.find(state.owners, fn {_session_id, row} ->
               row.pid == owner and row.incarnation == owner_incarnation
             end) do
          {session_id, _row} ->
            retain_owner_loss_ready(state, session_id, owner, owner_incarnation)

          nil ->
            {:stop, :relay_lost, state}
        end
    end
  end

  def handle_info(
        {:relay_owner_loss_classified_ack, relay, classification_ref, session_id, owner,
         owner_incarnation},
        %{relay: relay} = state
      ) do
    continue_owner_loss_classification(
      state,
      classification_ref,
      session_id,
      owner,
      owner_incarnation
    )
  end

  def handle_info(
        {:owner_loss_connection_closed, close_ref, connection, connection_incarnation},
        state
      ) do
    continue_owner_loss_close(
      state,
      close_ref,
      connection,
      connection_incarnation
    )
  end

  # Concept: an attachment becomes part of its session's mutation gate before
  # the attaching client can see its snapshot.
  #
  # Technical depth: the registry waits for this exact acknowledgement before
  # settling the attach ticket. A live lease owner receives the change now; a
  # later lease owner is seeded from the retained set when it starts.
  def handle_info(
        {:registry_attachment, registry, record_ref, action, session_id, connection,
         connection_incarnation, attachment_id},
        %{registry: registry} = state
      )
      when action in [:opened, :closed] do
    key = {connection, connection_incarnation, attachment_id}

    attachments =
      Map.update(state.attachments, session_id, MapSet.new([key]), fn keys ->
        if action == :opened, do: MapSet.put(keys, key), else: MapSet.delete(keys, key)
      end)

    attachments =
      if MapSet.size(Map.get(attachments, session_id)) == 0,
        do: Map.delete(attachments, session_id),
        else: attachments

    state = %{state | attachments: attachments}

    state =
      case Map.get(state.owners, session_id) do
        %{pid: owner, incarnation: owner_incarnation, exit_consumed: false}
        when is_pid(owner) ->
          ack_ref = if is_reference(record_ref), do: make_ref()

          :ok =
            LeaseOwner.request(owner, owner_incarnation, {
              :attachment,
              ack_ref,
              action,
              connection,
              connection_incarnation,
              attachment_id
            })

          if ack_ref,
            do: await_attachment_ack(state, ack_ref, record_ref, owner, owner_incarnation),
            else: state

        _no_lease_owner ->
          if is_reference(record_ref),
            do: send(registry, {:owner_attachment_recorded, self(), record_ref})

          state
      end

    Logger.debug("loopex daemon session attachment recorded")
    {:noreply, state}
  end

  # Concept: the relay acknowledgement and the registry gate share the one
  # transport-cut instant. An acknowledgement consumed at or after it is late,
  # so the relay, not the registry, is what failed.
  #
  # Technical depth: the gate is asked of the registry by message and this
  # owner returns to its mailbox, so a component exit that arrives while the
  # registry is silent is consumed at once and its class stands.
  def handle_info(
        {:relay_barrier_ack, cut_ref, :cut, _payload},
        %{stop: %{phase: :cutting, cut_ref: cut_ref} = stop} = state
      ) do
    if monotonic_ms() >= stop.cut_deadline do
      {:noreply, fail_cut(state, :relay_lost)}
    else
      state = put_in(state, [:stop, :phase], :gating)
      {:noreply, registry_request(state, :gate, {:transport_closing, cut_ref})}
    end
  end

  def handle_info(
        {:transport_cut_deadline, cut_ref},
        %{stop: %{phase: :cutting, cut_ref: cut_ref}} = state
      ),
      do: {:noreply, fail_cut(state, :relay_lost)}

  def handle_info(
        {:transport_cut_deadline, cut_ref},
        %{stop: %{phase: :gating, cut_ref: cut_ref}} = state
      ),
      do: {:noreply, fail_cut(state, :connections_lost)}

  def handle_info(
        {:transport_sweep_deadline, cut_ref},
        %{stop: %{phase: :sweeping, cut_ref: cut_ref}} = state
      ),
      do: {:noreply, fail_cut(state, :connections_lost)}

  def handle_info(
        {:owner_reply, registry, ref, reply},
        %{registry: registry, stop: %{pending: {kind, ref}}} = state
      ) do
    state = put_in(state, [:stop, :pending], nil)
    late = monotonic_ms() >= state.stop.cut_deadline

    case {kind, reply} do
      {:gate, {:ok, cut_ref}} when cut_ref == state.stop.cut_ref and not late ->
        Process.cancel_timer(state.stop.cut_timer)
        GenServer.reply(state.stop.from, {:ok, cut_ref})
        Logger.debug("loopex daemon owner admission cut complete")
        {:noreply, %{state | stop: %{state.stop | phase: :cut, from: nil}}}

      {:sweep, :ok} when not late ->
        {:noreply, maybe_finish_sweep(state)}

      _missing ->
        {:noreply, fail_cut(state, :connections_lost)}
    end
  end

  def handle_info(
        {:owner_reply, registry, ref, reply},
        %{registry: registry, close: %{ref: ref} = close} = state
      ) do
    Process.cancel_timer(close.timer)
    {:noreply, answer_close(state, reply)}
  end

  def handle_info({:owner_reply, _registry, _ref, _reply}, state), do: {:noreply, state}

  def handle_info({:close_connections_deadline, ref}, %{close: %{ref: ref}} = state) do
    Logger.debug("loopex daemon owner connection registry missed its close")
    Process.exit(state.registry, :kill)
    {:noreply, answer_close(state, {:error, :connections_lost})}
  end

  def handle_info({:close_connections_deadline, _ref}, state), do: {:noreply, state}

  # Concept: the registry reports a relay request it has waited on for five
  # seconds while serving; the relay is what failed, so the daemon names it
  # `relay_lost` exactly as if the relay had exited.
  #
  # Technical depth: the report latches, through `latch_relay_lost`, only
  # while this owner serves, no fatal teardown is marked and it names the
  # current registry and routing incarnation. The daemon owner is told once and the teardown mark keeps the
  # relay's coming exit from being reported again. Decision: the relay is
  # killed untrappably at once, as on every other relay-loss path, so the
  # registry does not keep its request pending until the fail-stop; its
  # request ends on the relay's exit as `relay_unavailable` and the registry
  # keeps serving (witness T13). Any other report is cleanup-only.
  def handle_info({:registry_relay_unanswered, registry, routing_incarnation}, state) do
    if registry == state.registry and routing_incarnation == state.routing_incarnation do
      Logger.debug("loopex daemon owner registry relay request unanswered")
      latch_relay_lost(state)
    else
      {:noreply, state}
    end
  end

  # Concept: a connection reports a relay request it opened for a client and
  # has waited on for five seconds while serving; the relay is what failed,
  # and the daemon names it `relay_lost` exactly as for the registry's report.
  #
  # Technical depth: the report latches, through `latch_relay_lost`, only
  # while this owner serves and no
  # fatal teardown is marked. It names the reporting connection, not the
  # relay, and any reporting pid is accepted by decision: there is no cheap
  # non-blocking way to ask the registry whether a pid is its connection, and
  # none is needed. This owner has exactly one relay for its lifetime, never
  # restarted, and every connection its registry starts is composed with that
  # relay, so any report concerns the current relay; once that relay has
  # exited, or any fatal class is latched, `fatal_teardown` is set and every
  # later report is cleanup-only.
  def handle_info({:connection_relay_unanswered, connection, connection_incarnation}, state)
      when is_pid(connection) and is_binary(connection_incarnation) do
    Logger.debug("loopex daemon owner connection relay request unanswered")
    latch_relay_lost(state)
  end

  # Concept: a connection reports a registry request it has waited on for
  # five seconds while serving; the registry is what failed, and the daemon
  # names it `connections_lost` exactly as if the registry had exited.
  #
  # Technical depth: the report latches, through `latch_connections_lost`,
  # only while this owner serves and no fatal teardown is marked, the same
  # guards as the connection's relay report, and only when it names this
  # owner's current registry. Any reporting pid is accepted for the same
  # reason as the relay report. After the admission cut the stop's own
  # deadlines govern, and every report is then cleanup-only, as is one naming
  # another registry.
  def handle_info(
        {:connection_registry_unanswered, connection, connection_incarnation, registry},
        %{registry: registry} = state
      )
      when is_pid(connection) and is_binary(connection_incarnation) do
    Logger.debug("loopex daemon owner connection registry request unanswered")
    latch_connections_lost(state)
  end

  def handle_info({:connection_registry_unanswered, _connection, _incarnation, _registry}, state),
    do: {:noreply, state}

  def handle_info({:daemon_fatal_teardown, recipient}, %{fatal_recipient: recipient} = state)
      when is_pid(recipient) do
    Logger.debug("loopex daemon owner fatal teardown marked")
    {:noreply, %{state | fatal_teardown: true}}
  end

  def handle_info(
        {:relay_barrier_ack, ref, :freeze_lease_ops, descriptors},
        %{stop: %{barrier: %{ref: ref, name: :freeze_lease_ops, descriptors: nil}}} = state
      ) do
    case begin_freeze_cleanup(state, descriptors) do
      {:ok, state} ->
        Logger.debug("loopex daemon owner lease freeze cleanup start")
        check_freeze(put_in(state, [:stop, :barrier, :descriptors], descriptors))

      {:error, class} ->
        finish_freeze(state, {:error, class})
    end
  end

  def handle_info({:freeze_check, ref}, %{stop: %{barrier: %{ref: ref}}} = state),
    do: check_freeze(state)

  def handle_info({:freeze_check, _ref}, state), do: {:noreply, state}

  # Concept: freeze cleanup unfinished at `freeze_deadline` names the component
  # that failed it: unfinished exact mirror work is `connections_lost`,
  # anything else the relay still owed is `relay_lost`.
  def handle_info(
        {:relay_barrier_deadline, ref},
        %{stop: %{barrier: %{ref: ref, name: :freeze_lease_ops, descriptors: descriptors}}} =
          state
      )
      when is_list(descriptors),
      do: finish_freeze(state, {:error, freeze_failure(state)})

  def handle_info(
        {:relay_barrier_ack, ref, name, payload},
        %{stop: %{barrier: %{ref: ref, name: name, from: from, timer: timer}}} = state
      )
      when name != :cut do
    Process.cancel_timer(timer)

    # The registry abandons its remaining relay flows once the relay tears
    # down; none of them can finish after this barrier.
    if name == :tearing_down, do: send(state.registry, {:registry_tearing_down, self()})

    GenServer.reply(from, {:ok, payload})
    Logger.debug("loopex daemon owner relay barrier acknowledged")
    {:noreply, put_in(state, [:stop, :barrier], nil)}
  end

  def handle_info(
        {:relay_barrier_deadline, ref},
        %{stop: %{barrier: %{ref: ref, from: from}}} = state
      ) do
    GenServer.reply(from, {:error, :relay_barrier_timeout})
    Logger.debug("loopex daemon owner relay barrier deadline reached")
    {:noreply, put_in(state, [:stop, :barrier], nil)}
  end

  def handle_info({:relay_barrier_deadline, _ref}, state), do: {:noreply, state}

  def handle_info(
        {:transport_uninitialized_empty, registry, cut_ref},
        %{registry: registry, stop: %{cut_ref: cut_ref}} = state
      ) do
    {:noreply, maybe_finish_sweep(put_in(state, [:stop, :swept], true))}
  end

  # Concept: a step whose instant passes names the component that owns it.
  def handle_info({:mirror_deadline, operation_ref, deadline}, state) do
    case Map.get(state.mirror_operations, operation_ref) do
      %{step_deadline: ^deadline} = operation ->
        if monotonic_ms() >= deadline do
          late_action(state, operation_ref, operation, late_class(operation))
        else
          timer = schedule_deadline(operation_ref, deadline)
          {:noreply, put_in(state, [:mirror_operations, operation_ref, :timer], timer)}
        end

      _other ->
        {:noreply, state}
    end
  end

  # Concept: a holder connection's exit completes its owner-loss close,
  # whether it acknowledged, crashed or was killed at its step.
  def handle_info({:DOWN, monitor, :process, _holder, _reason} = message, state) do
    case Enum.find(state.mirror_operations, fn {_operation_ref, operation} ->
           operation.kind == :owner_loss and operation.step == :await_holder_close and
             operation.holder_monitor == monitor
         end) do
      {operation_ref, operation} ->
        Logger.debug("loopex daemon lost owner holder exit completed its close")
        complete_owner_loss_notification(state, operation_ref, operation)

      nil ->
        unexpected_down(state, message)
    end
  end

  # Concept: the registry never waits on the relay inside a call, so its exit
  # is always its own: `connections_lost`. A final close still waiting is told
  # the same class.
  #
  # Technical depth: an exit during fatal teardown — including the registry
  # this owner killed on a connection's unanswered-request report — is
  # reported by no one again.
  def handle_info({:EXIT, registry, _reason}, %{registry: registry} = state) do
    state = if state.close, do: answer_close(state, {:error, :connections_lost}), else: state
    unless state.fatal_teardown, do: report_component_loss(state, :connections_lost)
    {:stop, :connections_lost, state}
  end

  # Concept: a relay exit never ends this owner while a daemon owner is
  # present, so the relay's exit itself cannot take down the connection
  # registry this owner links, whatever order the daemon owner's teardown
  # mark and that exit arrive in. A later request that needs the dead relay
  # can still end this owner, and the registry with it, before the stop
  # records are written; nothing is admitted either way, and the halt bounds
  # the window.
  #
  # Technical depth: an unexpected relay exit is reported to the daemon owner
  # as `relay_lost`, which fail-stops; an exit during fatal teardown, whether
  # the daemon owner or this owner killed the relay, is reported by no one
  # again. A transport-cut caller still waiting is answered `relay_lost`.
  # Without a daemon owner, as in unit tests, the old stop remains.
  def handle_info({:EXIT, relay, _reason}, %{relay: relay, fatal_recipient: recipient} = state)
      when is_pid(recipient) do
    unless state.fatal_teardown do
      Logger.debug("loopex daemon owner relay lost")
      send(recipient, {:daemon_component_fatal, self(), :relay_lost})
    end

    {:noreply, answer_pending_cut(%{state | fatal_teardown: true}, :relay_lost)}
  end

  def handle_info({:EXIT, relay, _reason}, %{relay: relay} = state),
    do: {:stop, :relay_lost, state}

  def handle_info({:EXIT, owner, reason}, state) do
    case Map.fetch(state.owner_pids, owner) do
      {:ok, session_id} ->
        case Map.fetch!(state.owners, session_id) do
          %{pid: ^owner, phase: :retiring, retirement_ref: retirement_ref} = row
          when is_reference(retirement_ref) and reason == :normal ->
            slot_charged = not is_nil(row.successor)
            phase = if slot_charged, do: :starting_waiting_pop, else: :retiring

            state =
              state
              |> put_in(
                [:owners, session_id],
                %{
                  row
                  | phase: phase,
                    exit_consumed: true,
                    slot_charged: slot_charged
                }
              )
              |> update_in([:owner_pids], &Map.delete(&1, owner))

            Logger.debug("loopex daemon lease owner retirement exit consumed")

            state
            |> finish_owner_attachment_acks(owner)
            |> release_row_holds(session_id)
            |> start_retirement_pop(session_id, row)

          %{pid: ^owner} = row ->
            slot_charged = not is_nil(row.successor)

            row = %{
              row
              | phase: :lost,
                exit_consumed: true,
                slot_charged: slot_charged
            }

            state =
              state
              |> put_in([:owners, session_id], row)
              |> update_in([:owner_pids], &Map.delete(&1, owner))

            Logger.debug("loopex daemon lease owner exit retained")
            _ = reason

            state
            |> finish_owner_attachment_acks(owner)
            |> continue_lost_owner_exit(session_id, row)
        end

      :error ->
        {:stop, :unexpected_linked_exit, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp unexpected_down(state, _message), do: {:noreply, state}

  # Concept: the transport cut asks the registry by message, never by a call
  # this owner would block in.
  #
  # Technical depth: the registry authenticates the request by this owner's
  # pid, answers it exactly as the matching call, and sends the answer back as
  # `{:owner_reply, registry, ref, reply}`.
  defp registry_request(state, kind, request) do
    ref = make_ref()
    send(state.registry, {:owner_request, self(), ref, request})
    put_in(state, [:stop, :pending], {kind, ref})
  end

  defp answer_close(%{close: close} = state, reply) do
    Enum.each(close.froms, &GenServer.reply(&1, reply))
    %{state | close: nil}
  end

  defp report_component_loss(%{fatal_recipient: recipient}, class) when is_pid(recipient) do
    Logger.debug("loopex daemon owner reported a component loss")
    send(recipient, {:daemon_component_fatal, self(), class})
    :ok
  end

  defp report_component_loss(_state, _class), do: :ok

  defp answer_pending_cut(%{stop: %{phase: phase, from: from} = stop} = state, class)
       when phase in [:cutting, :gating, :sweeping] and not is_nil(from) do
    Process.cancel_timer(stop.cut_timer)
    GenServer.reply(from, {:error, class})
    %{state | stop: %{stop | phase: :cut_failed, from: nil, pending: nil}}
  end

  defp answer_pending_cut(state, _class), do: state

  defp maybe_finish_sweep(%{stop: %{phase: :sweeping, pending: nil, swept: true}} = state) do
    Process.cancel_timer(state.stop.cut_timer)
    GenServer.reply(state.stop.from, :ok)
    Logger.debug("loopex daemon owner uninitialized sweep complete")
    %{state | stop: %{state.stop | phase: :swept, from: nil}}
  end

  defp maybe_finish_sweep(state), do: state

  # Concept: a transport-cut step that missed its deadline is decided at once:
  # the caller hears the class, and the component that missed it is killed at
  # that instant so it can do no further work, without awaiting its reap.
  #
  # Technical depth: the relay's or registry's linked exit then stops this
  # owner with the same class the caller has already latched.
  defp fail_cut(state, class) do
    Process.cancel_timer(state.stop.cut_timer)
    if from = state.stop.from, do: GenServer.reply(from, {:error, class})
    Logger.debug("loopex daemon owner transport cut missed its deadline")
    state = %{state | stop: %{state.stop | phase: :cut_failed, from: nil, pending: nil}}

    # A relay killed here is fatal teardown: its exit must not end this owner
    # and the registry with it, which would cut off the stop records.
    case class do
      :relay_lost ->
        Process.exit(state.relay, :kill)
        %{state | fatal_teardown: true}

      :connections_lost ->
        Process.exit(state.registry, :kill)
        state
    end
  end

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.owners, fn {_session_id, row} ->
      if Process.alive?(row.pid), do: Process.exit(row.pid, :kill)
    end)

    if Process.alive?(state.registry), do: Process.exit(state.registry, :kill)
    if Process.alive?(state.relay), do: Process.exit(state.relay, :kill)
    Logger.debug("loopex daemon owner stop")
    :ok
  end

  @impl GenServer
  def format_status(status) do
    status
    |> Map.put(:state, :redacted_daemon_owner_state)
    |> Map.put(:message, :redacted_daemon_owner_message)
    |> Map.put(:reason, :redacted_daemon_owner_reason)
    |> Map.put(:log, [])
  end

  # Concept: every connection the registry starts serves through this daemon
  # owner and its relay. Technical depth: the context is plain process and
  # runtime references; the runtime is absent only in component tests.
  defp start_registry(options, relay, daemon_incarnation) do
    context = %{
      owner: self(),
      relay: relay,
      daemon_incarnation: daemon_incarnation,
      runtime: Keyword.get(options, :runtime),
      fatal_recipient: Keyword.get(options, :fatal_recipient),
      index: Keyword.get(options, :index),
      placement_identity: Keyword.get(options, :placement_identity),
      socket_path: Keyword.get(options, :socket_path),
      state_root: Keyword.get(options, :state_root),
      started_at: System.monotonic_time(:millisecond),
      idle_eviction_ms: Keyword.get(options, :idle_eviction_ms, 600_000)
    }

    registry_options = [owner: self(), connection_context: context]

    registry_options =
      case Keyword.fetch(options, :connection_module) do
        {:ok, module} -> Keyword.put(registry_options, :connection_module, module)
        :error -> registry_options
      end

    ConnectionRegistry.start_link(registry_options)
  end

  defp connection_request(
         {:acquire_control, permit_id, request_id, session_id, connection, connection_incarnation,
          worker, worker_incarnation, request_deadline},
         from,
         state
       ) do
    requested = %{
      class: :session_acquire_control,
      permit_id: permit_id,
      request_id: request_id,
      session_id: session_id,
      connection: connection,
      connection_incarnation: connection_incarnation,
      worker: worker,
      worker_incarnation: worker_incarnation,
      request_deadline: request_deadline,
      writer_epoch: nil,
      phase: :opened
    }

    admit_request(state, requested, from)
  end

  defp connection_request(
         {:release_control, permit_id, request_id, session_id, connection, connection_incarnation,
          worker, worker_incarnation, writer_epoch, request_deadline},
         from,
         state
       ) do
    requested = %{
      class: :session_release_control,
      permit_id: permit_id,
      request_id: request_id,
      session_id: session_id,
      connection: connection,
      connection_incarnation: connection_incarnation,
      worker: worker,
      worker_incarnation: worker_incarnation,
      request_deadline: request_deadline,
      writer_epoch: writer_epoch,
      phase: :opened
    }

    admit_request(state, requested, from)
  end

  defp connection_request(_malformed, _from, state),
    do: {:reply, {:error, :invalid_operation}, state}

  # Concept: a connection's acquire or release is admitted without this owner
  # waiting on the relay or a lease owner: the relay's open is a request
  # message, and the connection is answered once the relay acknowledges it —
  # `{:ok, :accepted, actor, actor_incarnation}` — or refused before any
  # permit exists. The relay's permit then carries the one client answer.
  #
  # Technical depth: an operation is `:opening` until the relay answers the
  # open; a fresh or successor acquire, whose actor is this owner, is then
  # `:claiming` until the relay answers its claim. A request for a session
  # whose lease owner is still registering waits in that row's
  # `pending_dispatch` and is dispatched, in order, once registration
  # completes. After the lease freeze no lease request reaches the relay.
  #
  # An identical request for a permit already answered is answered again
  # with the same acceptance; any other request naming a known permit is
  # `permit_conflict`.
  defp admit_request(state, request, from) do
    cond do
      Map.has_key?(state.operations, request.permit_id) ->
        {:reply, repeated_answer(state, Map.fetch!(state.operations, request.permit_id), request),
         state}

      not valid_request?(request) ->
        {:reply, {:error, :invalid_operation}, state}

      true ->
        {:noreply, dispatch(state, request, from)}
    end
  end

  defp repeated_answer(state, %{request: request} = operation, request)
       when not is_map_key(operation, :reply_to) do
    cond do
      operation.phase in [:waiting_owner, :settling, :abandoned] ->
        {:ok, :accepted, self(), state.daemon_incarnation}

      is_pid(operation.owner_pid) ->
        {:ok, :accepted, operation.owner_pid, operation.owner_incarnation}

      true ->
        {:error, :permit_conflict}
    end
  end

  defp repeated_answer(_state, _operation, _request), do: {:error, :permit_conflict}

  # Concept: the returned holder of a lost session owner is being closed
  # with its one uncorrelated record, so any request it sends meanwhile is
  # answered `holder_closed`, which its connection settles without writing.
  defp dispatch(state, request, from) do
    if lost_owner_holder?(state, request) do
      GenServer.reply(from, {:error, :holder_closed})
      state
    else
      dispatch_session(state, request, from)
    end
  end

  # Technical depth: while the row is `:lost` its granted route still names
  # the holder until classification moves it to `lost_holders`; a live row's
  # route names a holder that is not being closed, so it never counts.
  defp lost_owner_holder?(state, request) do
    lost? = match?(%{phase: :lost}, Map.get(state.owners, request.session_id))

    if lost?,
      do: returned_holder?(state, request),
      else: holder_named?(Map.get(state.lost_holders, request.session_id), request)
  end

  defp dispatch_session(state, request, from) do
    case Map.get(state.owners, request.session_id) do
      _row when is_map(state.stop) and state.stop.frozen ->
        GenServer.reply(from, {:error, :daemon_stopping})
        state

      # Concept: a request for a session with held requests waits behind them,
      # so the held ones are dispatched first and per-session order holds.
      %{held: [_ | _] = held} ->
        entry = %{request: request, from: from, reason: :queued, owner: nil, timer: nil}
        put_in(state, [:owners, request.session_id, :held], held ++ [entry])

      %{phase: :live} = row ->
        open_existing(state, request, from, row)

      %{phase: :registering} = row ->
        pending = row.pending_dispatch ++ [{request, from}]
        put_in(state, [:owners, request.session_id, :pending_dispatch], pending)

      %{phase: phase} = row
      when phase in [:retirement_pending, :retiring, :starting_waiting_pop, :lost] and
             request.class == :session_acquire_control ->
        dispatch_waiting_owner_acquire(state, request, from, row)

      nil when request.class == :session_acquire_control ->
        dispatch_first_acquire(state, request, from)

      _other ->
        GenServer.reply(from, {:error, :owner_unavailable})
        state
    end
  end

  defp open_existing(state, request, from, row) do
    request_id =
      AdmissionRelay.open_lease_permit_request(
        state.relay,
        request.connection,
        request.permit_id,
        request.class,
        request.session_id,
        row.pid,
        row.incarnation,
        request.worker,
        request.worker_incarnation
      )

    operation =
      request
      |> lease_operation(row, row.pid, row.incarnation)
      |> Map.merge(%{phase: :opening, reply_to: from})

    state
    |> put_in([:operations, request.permit_id], operation)
    |> relay_request(request_id, {:open, request.permit_id})
  end

  defp dispatch_waiting_owner_acquire(state, request, from, owner_row) do
    cond do
      not is_nil(owner_row.successor) ->
        GenServer.reply(from, {:error, :owner_unavailable})
        state

      not owner_row.slot_charged and owner_slot_count(state) >= @owner_limit ->
        GenServer.reply(from, {:error, :control_capacity_reached})
        state

      true ->
        phase =
          if owner_row.exit_consumed and owner_row.phase != :lost,
            do: :starting_waiting_pop,
            else: owner_row.phase

        owner_row = %{
          owner_row
          | phase: phase,
            slot_charged: true,
            successor: request.permit_id
        }

        state
        |> put_in([:owners, request.session_id], owner_row)
        |> open_daemon_actor(request, from)
    end
  end

  defp dispatch_first_acquire(state, request, from) do
    if owner_slot_count(state) >= @owner_limit do
      GenServer.reply(from, {:error, :control_capacity_reached})
      state
    else
      row = %{owner_row(nil, nil) | phase: :registering, first_permit: request.permit_id}

      state
      |> put_in([:owners, request.session_id], row)
      |> open_daemon_actor(request, from)
    end
  end

  # Concept: a fresh or successor acquire names this owner as its actor, so
  # it is opened and then claimed by this owner before any lease owner acts.
  defp open_daemon_actor(state, request, from) do
    start_op_ref = make_ref()

    request_id =
      AdmissionRelay.open_lease_permit_request(
        state.relay,
        request.connection,
        request.permit_id,
        request.class,
        request.session_id,
        self(),
        state.daemon_incarnation,
        request.worker,
        request.worker_incarnation,
        start_op_ref
      )

    operation = %{
      request: request,
      owner_pid: nil,
      owner_incarnation: nil,
      actor_pid: self(),
      actor_incarnation: state.daemon_incarnation,
      start_op_ref: start_op_ref,
      phase: :opening,
      reply_to: from
    }

    state
    |> put_in([:operations, request.permit_id], operation)
    |> relay_request(request_id, {:open, request.permit_id})
  end

  # Concept: each relay request this owner sends has its own five-second
  # instant while serving; a relay that has not answered by it is lost.
  #
  # Technical depth: a request sent after the admission cut arms no instant:
  # the stop's own phase deadlines govern it.
  defp relay_request(state, request_id, continuation) do
    timer =
      if is_nil(state.stop),
        do: Process.send_after(self(), {:owner_relay_unanswered, request_id}, @relay_request_ms)

    put_in(state, [:relay_requests, request_id], %{continuation: continuation, timer: timer})
  end

  defp relay_request_answered(state, request_id, message) do
    {%{continuation: continuation, timer: timer}, requests} =
      Map.pop(state.relay_requests, request_id)

    if timer, do: Process.cancel_timer(timer)
    state = %{state | relay_requests: requests}

    response =
      case :gen_server.check_response(message, request_id) do
        {:reply, reply} -> {:reply, reply}
        _relay_gone -> :down
      end

    relay_answered(state, continuation, response)
  end

  defp relay_answered(state, {:open, permit_id}, response) do
    case Map.fetch(state.operations, permit_id) do
      {:ok, %{phase: :opening} = operation} -> open_answered(state, operation, response)
      _gone -> {:noreply, state}
    end
  end

  defp relay_answered(state, {:claim, permit_id}, response) do
    case Map.fetch(state.operations, permit_id) do
      {:ok, %{phase: :claiming} = operation} -> claim_answered(state, operation, response)
      _gone -> {:noreply, state}
    end
  end

  defp relay_answered(state, {:register, session_id, owner, owner_incarnation}, response) do
    case Map.get(state.owners, session_id) do
      %{phase: phase, pid: ^owner, incarnation: ^owner_incarnation} = row
      when phase in [:registering, :lost] ->
        register_answered(state, session_id, row, response)

      _other ->
        {:noreply, state}
    end
  end

  defp relay_answered(state, {:complete, permit_id, purpose}, response) do
    case {response, Map.fetch(state.operations, permit_id)} do
      {{:reply, :ok}, {:ok, %{phase: :refusing} = operation}} ->
        state =
          state
          |> update_in([:operations], &Map.delete(&1, permit_id))
          |> update_in([:pending_dispositions], &Map.delete(&1, permit_id))

        completed(state, operation, purpose)

      {{:reply, {:error, :connection_lost}}, {:ok, %{phase: :refusing}}} ->
        {:noreply, put_in(state, [:operations, permit_id, :phase], :abandoned)}

      {_answer, {:ok, %{phase: :refusing}}} when is_nil(state.stop) ->
        latch_relay_lost(state)

      # Concept: during the stop the relay may refuse the completion
      # (`daemon_stopping`, `owner_lost`); the permit is then the barrier's,
      # which settles it through its descriptor.
      {_answer, {:ok, %{phase: :refusing}}} ->
        {:noreply, state}

      _gone ->
        {:noreply, state}
    end
  end

  defp open_answered(state, operation, {:reply, {:ok, permit_id}})
       when permit_id == operation.request.permit_id do
    cond do
      operation.actor_pid == self() and lease_relay_closed?(state) ->
        GenServer.reply(operation.reply_to, {:ok, :accepted, self(), state.daemon_incarnation})

        state
        |> put_in([:operations, permit_id], %{
          Map.delete(operation, :reply_to)
          | phase: :refusing
        })
        |> undo_first_acquire(operation)
        |> noreply()

      operation.actor_pid == self() ->
        claim_opened(state, operation, permit_id)

      true ->
        hand_opened(state, operation, permit_id)
    end
  end

  defp open_answered(state, operation, {:reply, {:error, reason}})
       when reason in [:actor_retiring, :actor_lost] do
    state
    |> update_in([:operations], &Map.delete(&1, operation.request.permit_id))
    |> hold_request(operation, reason)
    |> opening_removed(operation)
  end

  # Concept: the relay refusing an actor this owner still has live means the
  # two disagree about that actor, which is the relay's loss; the request is
  # still answered. A refusal naming a lease owner this owner has already
  # moved past — its retirement or exit overtook the open — is held like any
  # other refusal of a departing actor.
  defp open_answered(state, operation, {:reply, {:error, :invalid_actor}}) do
    state = update_in(state.operations, &Map.delete(&1, operation.request.permit_id))

    if actor_live?(state, operation) do
      GenServer.reply(operation.reply_to, {:error, :owner_unavailable})
      state |> undo_daemon_actor_start(operation) |> latch_relay_lost()
    else
      reason =
        if match?(%{phase: :lost}, Map.get(state.owners, operation.request.session_id)),
          do: :actor_lost,
          else: :actor_retiring

      state
      |> hold_request(operation, reason)
      |> opening_removed(operation)
    end
  end

  defp open_answered(state, operation, response) do
    reason =
      case response do
        {:reply, {:error, reason}} -> reason
        _relay_gone -> :daemon_stopping
      end

    GenServer.reply(operation.reply_to, {:error, reason})

    state
    |> update_in([:operations], &Map.delete(&1, operation.request.permit_id))
    |> undo_daemon_actor_start(operation)
    |> opening_removed(operation)
  end

  defp claim_opened(state, operation, permit_id) do
    request_id =
      AdmissionRelay.claim_lease_permit_request(
        state.relay,
        permit_id,
        state.daemon_incarnation,
        operation.start_op_ref
      )

    state
    |> put_in([:operations, permit_id], %{operation | phase: :claiming})
    |> relay_request(request_id, {:claim, permit_id})
    |> noreply()
  end

  defp hand_opened(state, operation, permit_id) do
    GenServer.reply(
      operation.reply_to,
      {:ok, :accepted, operation.actor_pid, operation.actor_incarnation}
    )

    operation = operation |> Map.delete(:reply_to) |> Map.put(:phase, :opened)
    state = put_in(state, [:operations, permit_id], operation)

    :ok =
      LeaseOwner.request(
        operation.owner_pid,
        operation.owner_incarnation,
        lease_owner_request(operation.request)
      )

    {:noreply, state}
  end

  defp actor_live?(_state, %{actor_pid: actor}) when actor == self(), do: true

  defp actor_live?(state, operation) do
    match?(
      %{phase: :live, pid: pid, incarnation: incarnation, exit_consumed: false}
      when pid == operation.owner_pid and incarnation == operation.owner_incarnation,
      Map.get(state.owners, operation.request.session_id)
    )
  end

  # Concept: an open still awaiting the relay keeps a lost owner's pop
  # waiting, since its answer may yet hand that owner a permit; once the
  # answer removes the operation, the pop is checked again.
  defp opening_removed(state, %{owner_pid: owner} = operation) when is_pid(owner) do
    maybe_start_owner_loss_pop(
      state,
      operation.request.session_id,
      owner,
      operation.owner_incarnation
    )
  end

  defp opening_removed(state, _daemon_actor), do: {:noreply, state}

  # Technical depth: a fresh acquire is answered once its lease owner is
  # started, naming that owner; a successor acquire is answered naming this
  # owner, which acts for it until its lease owner starts.
  defp claim_answered(state, operation, {:reply, :ok}) do
    permit_id = operation.request.permit_id
    {from, operation} = Map.pop(operation, :reply_to)
    state = put_in(state, [:operations, permit_id], operation)

    case Map.get(state.owners, operation.request.session_id) do
      %{phase: :registering, first_permit: ^permit_id, pid: nil} ->
        start_registering_owner(state, operation, from)

      %{successor: ^permit_id} = row ->
        GenServer.reply(from, {:ok, :accepted, self(), state.daemon_incarnation})
        Logger.debug("loopex daemon successor owner start retained")
        state = put_in(state, [:operations, permit_id, :phase], :waiting_owner)

        if row.phase == :lost,
          do: finish_owner_loss(state, operation.request.session_id),
          else: finish_owner_retirement(state, operation.request.session_id)

      # Concept: a claimed permit whose session row is gone is still
      # answered: this owner is its actor, so it refuses it through the relay.
      _row ->
        GenServer.reply(from, {:ok, :accepted, self(), state.daemon_incarnation})
        Logger.debug("loopex daemon claimed lease permit without an owner row refused")
        state = put_in(state, [:operations, permit_id, :phase], :refusing)
        code = if state.stop, do: "daemon_stopping", else: "control_pending"
        refuse_permit(state, operation, code, :registration_failed)
    end
  end

  # Concept: a claim refused `connection_lost` follows the relay's
  # connection-loss disposition for the same permit, which this owner
  # retained while it waited for the claim; that disposition is settled now.
  #
  # Technical depth: the relay sends the disposition before it answers the
  # later claim, so it is normally retained; if it is not, the `:abandoned`
  # operation is settled when it arrives.
  defp claim_answered(state, operation, {:reply, {:error, :connection_lost}}) do
    permit_id = operation.request.permit_id
    GenServer.reply(operation.reply_to, {:error, :connection_lost})
    operation = operation |> Map.delete(:reply_to) |> Map.put(:phase, :abandoned)

    state =
      state
      |> put_in([:operations, permit_id], operation)
      |> undo_first_acquire(operation)

    case Map.pop(state.pending_dispositions, permit_id) do
      {nil, _pending} ->
        {:noreply, state}

      {loss, pending} ->
        state = %{state | pending_dispositions: pending}
        start_waiting_owner_loss_settlement(state, permit_id, operation, loss)
    end
  end

  defp claim_answered(state, operation, response) do
    reason =
      case response do
        {:reply, {:error, reason}} -> reason
        _relay_gone -> :daemon_stopping
      end

    GenServer.reply(operation.reply_to, {:error, reason})
    state = update_in(state.operations, &Map.delete(&1, operation.request.permit_id))
    {:noreply, undo_daemon_actor_start(state, operation)}
  end

  # A fresh acquire's reserved row is dropped, and anything waiting on it is
  # dispatched again; a successor acquire gives back its reservation.
  defp undo_daemon_actor_start(state, %{actor_pid: actor} = operation) when actor == self() do
    state
    |> undo_first_acquire(operation)
    |> release_successor_reservation(%{
      kind: :queued_grant,
      permit_id: operation.request.permit_id,
      row: %{session_id: operation.request.session_id}
    })
  end

  defp undo_daemon_actor_start(state, _operation), do: state

  defp undo_first_acquire(state, operation) do
    permit_id = operation.request.permit_id
    session_id = operation.request.session_id

    case Map.get(state.owners, session_id) do
      %{phase: :registering, first_permit: ^permit_id, pid: nil} ->
        delete_row(state, session_id)

      _other ->
        state
    end
  end

  defp redispatch(state, requests),
    do: Enum.reduce(requests, state, fn {request, from}, acc -> dispatch(acc, request, from) end)

  # Concept: the fresh lease owner is started once its first permit is
  # claimed, and registered with the relay by request; the row stays
  # `:registering`, with its slot charged, until the relay answers.
  defp start_registering_owner(state, operation, from) do
    if lease_relay_closed?(state) do
      # Concept: after the freeze no lease owner is registered; the claimed
      # permit is the barrier's.
      GenServer.reply(from, {:ok, :accepted, self(), state.daemon_incarnation})

      state
      |> put_in([:operations, operation.request.permit_id, :phase], :refusing)
      |> undo_first_acquire(operation)
      |> noreply()
    else
      start_registering_child(state, operation, from)
    end
  end

  defp start_registering_child(state, operation, from) do
    session_id = operation.request.session_id
    owner_incarnation = incarnation()

    case LeaseOwner.start_link(
           daemon_owner: self(),
           relay: state.relay,
           registry: state.registry,
           session_id: session_id,
           owner_incarnation: owner_incarnation,
           lease_term_ms: state.lease_term_ms,
           retirement_exit_gate: state.retirement_exit_gate,
           attachments: Map.get(state.attachments, session_id, MapSet.new())
         ) do
      {:ok, owner} ->
        GenServer.reply(from, {:ok, :accepted, owner, owner_incarnation})

        operation = %{
          operation
          | owner_pid: owner,
            owner_incarnation: owner_incarnation,
            phase: :opened
        }

        row = Map.get(state.owners, session_id)
        row = %{row | pid: owner, incarnation: owner_incarnation}

        request_id =
          AdmissionRelay.register_lease_owner_request(
            state.relay,
            session_id,
            owner,
            owner_incarnation
          )

        state
        |> put_in([:owners, session_id], row)
        |> put_in([:owner_pids, owner], session_id)
        |> put_in([:operations, operation.request.permit_id], operation)
        |> relay_request(request_id, {:register, session_id, owner, owner_incarnation})
        |> noreply()

      _error ->
        GenServer.reply(from, {:ok, :accepted, self(), state.daemon_incarnation})

        state =
          state
          |> put_in([:operations, operation.request.permit_id, :phase], :refusing)
          |> undo_first_acquire(operation)

        refuse_permit(state, operation, "control_pending", :registration_failed)
    end
  end

  # Concept: on the relay's registration, in one handler, the lease owner is
  # activated, handed its first acquire, marked live and given every request
  # that waited for it, in order; same-sender order puts each after the
  # first acquire.
  #
  # Technical depth: a lease owner whose exit was already consumed was
  # registered dead, so the relay reports its loss and the ordinary
  # lost-owner path continues. A refused registration discards the child,
  # frees its slot, completes its first permit through the relay and
  # dispatches the waiting requests again from scratch.
  defp register_answered(state, session_id, %{phase: :registering} = row, {:reply, :ok}) do
    :ok = LeaseOwner.request(row.pid, row.incarnation, :activate)

    state =
      case Map.get(state.operations, row.first_permit) do
        %{phase: :opened, request: request} ->
          :ok =
            LeaseOwner.request(row.pid, row.incarnation, {
              :first_acquire,
              request.permit_id,
              request.request_id,
              request.connection,
              request.connection_incarnation,
              request.request_deadline
            })

          state

        _refused ->
          state
      end

    pending = row.pending_dispatch
    row = %{row | phase: :live, pending_dispatch: [], first_permit: nil}

    state =
      state
      |> put_in([:owners, session_id], row)
      |> update_in([:lost_holders], &Map.delete(&1, session_id))

    Logger.debug("loopex daemon lease owner installed")
    {:noreply, redispatch(state, pending)}
  end

  defp register_answered(state, _session_id, %{phase: :lost}, {:reply, :ok}),
    do: {:noreply, state}

  defp register_answered(state, session_id, row, _refused) do
    if not row.exit_consumed, do: discard_unregistered_owner(row.pid)

    state =
      state
      |> update_in([:owners], &Map.put(&1, session_id, %{row | pending_dispatch: []}))
      |> delete_row(session_id)
      |> update_in([:owner_pids], &Map.delete(&1, row.pid))

    state =
      case Map.get(state.operations, row.first_permit) do
        %{phase: :opened, actor_pid: actor} = operation when actor == self() ->
          code = if state.stop, do: "daemon_stopping", else: "control_pending"

          # Technical depth: the discarded child is no longer the permit's
          # lease owner, so the freeze matches the permit to this owner.
          operation = %{operation | owner_pid: nil, owner_incarnation: nil, phase: :refusing}
          state = put_in(state, [:operations, row.first_permit], operation)
          {:noreply, state} = refuse_permit(state, operation, code, :registration_failed)
          state

        _gone ->
          state
      end

    Logger.debug("loopex daemon lease owner registration refused")
    {:noreply, redispatch(state, row.pending_dispatch)}
  end

  # Concept: a permit this owner is the actor for is refused through the
  # relay; the operation is removed once the relay records the refusal.
  defp refuse_permit(state, operation, code, purpose) do
    if lease_relay_closed?(state) do
      state = update_in(state.operations, &Map.delete(&1, operation.request.permit_id))
      completed(state, operation, purpose)
    else
      result = refusal_record(operation.request.request_id, code)

      request_id =
        AdmissionRelay.complete_lease_permit_request(
          state.relay,
          operation.request.permit_id,
          state.daemon_incarnation,
          result
        )

      state
      |> relay_request(request_id, {:complete, operation.request.permit_id, purpose})
      |> noreply()
    end
  end

  # Technical depth: `daemon_stopping` is a request error, not a control
  # error, so each refusal code takes its own record shape.
  defp refusal_record(request_id, "daemon_stopping"),
    do: WireRecords.request_error(request_id, "daemon_stopping")

  defp refusal_record(request_id, code), do: WireRecords.control_error(request_id, code)

  defp completed(state, operation, :unproposed) do
    Logger.debug("loopex daemon unproposed lease grant refused")

    maybe_start_owner_loss_pop(
      state,
      operation.request.session_id,
      operation.owner_pid,
      operation.owner_incarnation
    )
  end

  defp completed(state, _operation, {:waiting_successor, session_id}) do
    state =
      case Map.get(state.owners, session_id) do
        %{successor: permit_id} when not is_nil(permit_id) ->
          delete_row(state, session_id)

        _other ->
          state
      end

    Logger.debug("loopex daemon successor owner start refused")
    {:noreply, state}
  end

  defp completed(state, _operation, _purpose), do: {:noreply, state}

  # Concept: a request the relay refused because its lease owner is retiring
  # or already lost is held, not answered: it is dispatched again once that
  # owner's retirement intent or loss notification settles the session, so
  # an acquire racing a retirement is never answered as a failure.
  #
  # Technical depth: a retiring hold has its own five-second instant while
  # serving, since the intent is the lease owner's own next step; a lease
  # owner that has not sent it by then is killed and the hold is dispatched
  # again at its exit. A lost hold waits for `finish_owner_loss`, which the
  # owner-loss steps bound; a loss already finished releases it at once.
  defp hold_request(state, operation, reason) do
    request = operation.request

    entry = %{
      request: request,
      from: operation.reply_to,
      reason: reason,
      owner: operation.owner_pid
    }

    case Map.get(state.owners, request.session_id) do
      _row when not is_nil(state.stop) ->
        GenServer.reply(entry.from, stopping_answer(state, request))
        state

      %{pid: pid} = row when pid == operation.owner_pid ->
        if (reason == :actor_retiring and is_reference(row.retirement_ref)) or loss_finished?(row) do
          release_held(state, [entry])
        else
          timer =
            if reason == :actor_retiring and is_nil(state.stop) do
              Process.send_after(
                self(),
                {:held_request_deadline, request.session_id, pid},
                @relay_request_ms
              )
            end

          Logger.debug("loopex daemon lease request held")
          held = row.held ++ [Map.put(entry, :timer, timer)]
          put_in(state, [:owners, request.session_id, :held], held)
        end

      _loss_or_retirement_finished ->
        release_held(state, [entry])
    end
  end

  defp loss_finished?(row) do
    row.phase == :lost and row.exit_consumed and row.mirror_complete and
      row.classification_complete and row.notification_complete
  end

  # Concept: a held request is answered as the settled session now allows:
  # the returned holder of a lost owner is already being closed and hears
  # nothing more, an acquire is dispatched again, and a release is refused
  # `control_not_held`, since the lease it named is gone.
  defp release_held(state, entries) do
    Enum.reduce(entries, state, fn entry, acc ->
      if entry[:timer], do: Process.cancel_timer(entry.timer)
      request = entry.request

      cond do
        returned_holder?(acc, request) ->
          GenServer.reply(entry.from, {:error, :holder_closed})
          acc

        request.class == :session_acquire_control ->
          dispatch(acc, request, entry.from)

        true ->
          GenServer.reply(entry.from, {:error, :control_not_held})
          acc
      end
    end)
  end

  # Concept: the returned holder of a session whose owner is lost is the
  # holder its granted route names, from the owner's loss until a successor
  # registers; that route is replaced by `lost_holders` when classification
  # begins, so one of the two always names it.
  #
  # Technical depth: a held request exists only for a retiring or lost row,
  # or behind one; a retiring row's lease is free and has no route, so a
  # route match on a held request is always the lost owner's holder.
  defp returned_holder?(state, request) do
    Enum.any?(
      [
        Map.get(state.lost_holders, request.session_id),
        Map.get(state.routes, request.session_id)
      ],
      &holder_named?(&1, request)
    )
  end

  defp holder_named?(holder, request) do
    match?(
      %{holder_pid: pid, holder_incarnation: incarnation}
      when pid == request.connection and incarnation == request.connection_incarnation,
      holder
    )
  end

  # Concept: after the cut a held request is refused `daemon_stopping`,
  # except the returned holder's, which hears only its uncorrelated close.
  defp stopping_answer(state, request) do
    if returned_holder?(state, request),
      do: {:error, :holder_closed},
      else: {:error, :daemon_stopping}
  end

  # Technical depth: every held entry is released in arrival order; the row
  # is emptied first, so a released acquire is not queued behind the ones
  # after it.
  defp release_row_holds(state, session_id) do
    case Map.get(state.owners, session_id) do
      %{held: [_ | _] = held} = row ->
        state = put_in(state, [:owners, session_id], %{row | held: []})
        release_held(state, held)

      _other ->
        state
    end
  end

  # Concept: no owner row is ever dropped with a request still waiting on
  # it: every held request and every request waiting for its registration is
  # answered or dispatched again once the row is gone.
  defp delete_row(state, session_id) do
    case Map.pop(state.owners, session_id) do
      {nil, _owners} ->
        state

      {row, owners} ->
        release_loss_waiters(%{state | owners: owners}, row)
    end
  end

  defp lease_owner_request(%{class: :session_acquire_control} = request) do
    {:acquire, request.permit_id, request.request_id, request.connection,
     request.connection_incarnation, request.request_deadline}
  end

  defp lease_owner_request(%{class: :session_release_control} = request) do
    {:release, request.permit_id, request.request_id, request.connection,
     request.connection_incarnation, request.writer_epoch}
  end

  # Concept: after the lease freeze this owner sends no lease request to the
  # relay.
  defp lease_relay_closed?(%{stop: %{frozen: true}}), do: true
  defp lease_relay_closed?(_state), do: false

  # Concept: a relay that does not answer, or answers inconsistently, is
  # lost: the daemon owner is told once, the teardown mark keeps the relay's
  # coming exit from being reported again, and the relay is killed.
  defp latch_relay_lost(%{fatal_teardown: true} = state), do: {:noreply, state}

  # Concept: once the stop has begun, its own deadlines govern; a relay
  # inconsistency is then cleanup only.
  defp latch_relay_lost(%{stop: stop} = state) when not is_nil(stop), do: {:noreply, state}

  defp latch_relay_lost(%{fatal_recipient: recipient} = state) when is_pid(recipient) do
    Logger.debug("loopex daemon owner relay exchange failed")
    report_component_loss(state, :relay_lost)
    Process.exit(state.relay, :kill)
    {:noreply, %{state | fatal_teardown: true}}
  end

  defp latch_relay_lost(state), do: {:stop, :relay_lost, state}

  # Concept: a late registry is named once and killed untrappably, so no
  # request queued at it is applied afterwards; the teardown mark keeps its
  # coming exit from being reported again.
  defp latch_connections_lost(%{fatal_teardown: true} = state), do: {:noreply, state}

  defp latch_connections_lost(%{stop: stop} = state) when not is_nil(stop),
    do: {:noreply, state}

  defp latch_connections_lost(%{fatal_recipient: recipient} = state) when is_pid(recipient) do
    Logger.debug("loopex daemon owner registry exchange failed")
    report_component_loss(state, :connections_lost)
    Process.exit(state.registry, :kill)
    {:noreply, %{state | fatal_teardown: true}}
  end

  defp latch_connections_lost(state), do: fail_connections(state)

  defp noreply(state), do: {:noreply, state}

  defp lease_operation(
         request,
         owner_row,
         actor_pid,
         actor_incarnation,
         start_op_ref \\ nil
       ) do
    %{
      request: request,
      owner_pid: owner_row.pid,
      owner_incarnation: owner_row.incarnation,
      actor_pid: actor_pid,
      actor_incarnation: actor_incarnation,
      start_op_ref: start_op_ref,
      phase: :opened
    }
  end

  defp start_grant_operation(state, operation, grant_ref, writer_epoch, _request_deadline) do
    operation_ref = make_ref()
    pending_loss = Map.get(state.pending_dispositions, operation.request.permit_id)

    row = %{
      permit_id: operation.request.permit_id,
      start_op_ref: operation.start_op_ref,
      session_id: operation.request.session_id,
      owner_pid: operation.owner_pid,
      owner_incarnation: operation.owner_incarnation,
      holder_pid: operation.request.connection,
      holder_incarnation: operation.request.connection_incarnation,
      writer_epoch: writer_epoch
    }

    mirror_operation = %{
      kind: :grant,
      step: if(pending_loss, do: :install_connection_lost, else: :install),
      permit_id: operation.request.permit_id,
      owner_pid: operation.owner_pid,
      owner_incarnation: operation.owner_incarnation,
      actor_pid: operation.actor_pid,
      actor_incarnation: operation.actor_incarnation,
      transition_ref: grant_ref,
      row: row,
      loss_ref: if(pending_loss, do: pending_loss.settlement_ref, else: nil)
    }

    state =
      state
      |> put_in([:operations, operation.request.permit_id, :phase], :settling)
      |> put_mirror(operation_ref, mirror_operation)
      |> update_in([:pending_dispositions], &Map.delete(&1, operation.request.permit_id))

    ConnectionRegistry.apply_mirror(
      state.registry,
      operation_ref,
      state.routing_incarnation,
      :install_provisional,
      row
    )

    Logger.debug("loopex daemon grant mirror settlement start")
    {:noreply, state}
  end

  defp start_release_operation(state, operation, release_ref) do
    case Map.fetch(state.routes, operation.request.session_id) do
      {:ok,
       %{
         owner_pid: owner_pid,
         owner_incarnation: owner_incarnation,
         holder_pid: holder,
         holder_incarnation: holder_incarnation
       } = route}
      when owner_pid == operation.owner_pid and
             owner_incarnation == operation.owner_incarnation and
             holder == operation.request.connection and
             holder_incarnation == operation.request.connection_incarnation ->
        operation_ref = make_ref()
        pending_loss = Map.get(state.pending_dispositions, operation.request.permit_id)

        mirror_operation = %{
          kind: :release,
          step: if(pending_loss, do: :resolve_owner_cancel, else: :select_result),
          permit_id: operation.request.permit_id,
          owner_pid: operation.owner_pid,
          owner_incarnation: operation.owner_incarnation,
          actor_pid: operation.actor_pid,
          actor_incarnation: operation.actor_incarnation,
          transition_ref: release_ref,
          row: route,
          superseded: false,
          loss_ref: if(pending_loss, do: pending_loss.settlement_ref, else: nil)
        }

        state =
          state
          |> put_in([:operations, operation.request.permit_id, :phase], :settling)
          |> put_mirror(operation_ref, mirror_operation)
          |> update_in([:pending_dispositions], &Map.delete(&1, operation.request.permit_id))

        if pending_loss do
          LeaseOwner.request_release_resolution(
            operation.owner_pid,
            operation_ref,
            operation.owner_incarnation,
            release_ref,
            :cancelled
          )
        else
          request_relay_selection(state, operation_ref, mirror_operation)
        end

        Logger.debug("loopex daemon release mirror settlement start")
        {:noreply, state}

      _other ->
        {:stop, :lease_operation_invalid, state}
    end
  end

  defp start_expiry_operation(state, expiry_ref, route) do
    operation_ref = make_ref()

    mirror_operation = %{
      kind: :expiry,
      step: :clear,
      permit_id: nil,
      owner_pid: route.owner_pid,
      owner_incarnation: route.owner_incarnation,
      transition_ref: expiry_ref,
      row: route,
      loss_ref: nil
    }

    state = put_mirror(state, operation_ref, mirror_operation)

    ConnectionRegistry.apply_mirror(
      state.registry,
      operation_ref,
      state.routing_incarnation,
      :clear_granted,
      route
    )

    Logger.debug("loopex daemon expiry mirror settlement start")
    {:noreply, state}
  end

  defp start_retirement_pop(state, session_id, predecessor) do
    operation_ref = make_ref()

    step = if is_pid(state.retirement_pop_gate), do: :pop_owner_blocked, else: :pop_owner

    operation = %{
      kind: :retirement,
      step: step,
      permit_id: nil,
      owner_pid: predecessor.pid,
      owner_incarnation: predecessor.incarnation,
      row: %{
        session_id: session_id,
        owner_pid: predecessor.pid,
        owner_incarnation: predecessor.incarnation
      }
    }

    state = put_mirror(state, operation_ref, operation)

    if step == :pop_owner_blocked do
      send(
        state.retirement_pop_gate,
        {:retirement_pop_blocked, self(), session_id}
      )
    else
      request_retirement_pop(state, operation_ref, operation)
    end

    Logger.debug("loopex daemon retired owner mirror pop start")
    {:noreply, state}
  end

  defp request_retirement_pop(state, operation_ref, operation) do
    ConnectionRegistry.apply_mirror(
      state.registry,
      operation_ref,
      state.routing_incarnation,
      :pop_owner_mirror,
      operation.row
    )
  end

  # Concept: while serving, an owner loss gets its own bounded pop and
  # classification exchange; after the admission cut the loss joins the stop
  # barriers and starts no clock of its own.
  defp start_owner_loss_pop(state, session_id, predecessor) do
    operation_ref = make_ref()
    classification_ref = make_ref()

    operation = %{
      kind: :owner_loss,
      step: :pop_owner,
      permit_id: nil,
      owner_pid: predecessor.pid,
      owner_incarnation: predecessor.incarnation,
      classification_ref: classification_ref,
      close_ref: nil,
      holder_monitor: nil,
      holder: nil,
      row: %{
        session_id: session_id,
        owner_pid: predecessor.pid,
        owner_incarnation: predecessor.incarnation
      }
    }

    state =
      state
      |> put_mirror(operation_ref, operation)
      |> put_in([:owners, session_id, :loss_pop_started], true)

    ConnectionRegistry.apply_mirror(
      state.registry,
      operation_ref,
      state.routing_incarnation,
      :pop_owner_mirror,
      operation.row
    )

    Logger.debug("loopex daemon lost owner mirror pop start")
    {:noreply, state}
  end

  defp continue_lost_owner_exit(state, session_id, predecessor) do
    state =
      if predecessor.loss_origins do
        discard_claimed_owner_operations(state, predecessor.pid, predecessor.incarnation)
      else
        state
      end

    state = settle_pending_owner_losses(state, predecessor.pid, predecessor.incarnation)

    case refuse_unproposed_grants(state, predecessor.pid, predecessor.incarnation) do
      {:noreply, state} -> continue_lost_owner_operation(state, session_id, predecessor)
      stopped -> stopped
    end
  end

  # Concept: a lost owner can leave more than one operation waiting on it — a
  # lease owner proposes a queued successor's grant before it acknowledges the
  # expiry that freed the lease — so every such operation is resolved, not the
  # first one found.
  defp continue_lost_owner_operation(state, session_id, predecessor) do
    case owner_mirror_operations(state, predecessor.pid, predecessor.incarnation) do
      [] ->
        maybe_start_owner_loss_pop(state, session_id, predecessor.pid, predecessor.incarnation)

      operations ->
        Enum.reduce(operations, {:noreply, state}, fn
          {operation_ref, operation}, {:noreply, acc} ->
            if Map.has_key?(acc.mirror_operations, operation_ref),
              do: resolve_lost_owner_operation(acc, session_id, operation_ref, operation),
              else: {:noreply, acc}

          _operation, stop ->
            stop
        end)
    end
  end

  defp resolve_lost_owner_operation(
         state,
         session_id,
         operation_ref,
         %{kind: :grant, step: :resolve_owner_grant} = operation
       ) do
    route = operation.row |> Map.drop([:permit_id, :start_op_ref]) |> Map.put(:phase, :granted)

    state =
      state
      |> put_in([:routes, session_id], route)
      |> enter_step(operation_ref, :settle_result_after_owner_loss)

    request_relay_result_settlement(state, operation_ref, operation)
    {:noreply, state}
  end

  defp resolve_lost_owner_operation(
         state,
         session_id,
         operation_ref,
         %{kind: kind, step: step} = operation
       )
       when {kind, step} in [release: :resolve_owner_release, expiry: :resolve_owner_expiry] do
    state = update_in(state.routes, &Map.delete(&1, session_id))
    complete_operation_after_owner_loss(state, operation_ref, operation)
  end

  defp resolve_lost_owner_operation(
         state,
         _session_id,
         operation_ref,
         %{step: :resolve_owner_cancel} = operation
       ),
       do: settle_cancelled_disposition(state, operation_ref, operation)

  defp resolve_lost_owner_operation(state, _session_id, _operation_ref, _operation),
    do: {:noreply, state}

  defp owner_mirror_operations(state, owner, owner_incarnation) do
    state.mirror_operations
    |> Enum.filter(fn {_operation_ref, operation} ->
      operation.owner_pid == owner and operation.owner_incarnation == owner_incarnation and
        operation.kind != :owner_loss
    end)
    |> Enum.sort_by(fn {_operation_ref, operation} -> operation.opened_at end)
  end

  # Concept: a fresh child's first acquire names the daemon as its actor, so
  # the relay never claims it when that child dies. Technical depth: the child
  # sends its proposal before it can exit, so at its consumed `EXIT` an opened,
  # unmirrored daemon-actor operation proves the child never proposed; it is
  # refused `control_pending`, or its retained connection loss is settled.
  defp refuse_unproposed_grants(state, owner, owner_incarnation) do
    mirrored = mirrored_permits(state)
    daemon = self()

    state.operations
    |> Enum.filter(fn {permit_id, operation} ->
      operation.owner_pid == owner and operation.owner_incarnation == owner_incarnation and
        operation.actor_pid == daemon and operation.phase == :opened and
        not MapSet.member?(mirrored, permit_id)
    end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce({:noreply, state}, fn
      {permit_id, operation}, {:noreply, acc} ->
        refuse_unproposed_grant(acc, permit_id, operation)

      _operation, stopped ->
        stopped
    end)
  end

  defp refuse_unproposed_grant(state, permit_id, operation) do
    case Map.fetch(state.pending_dispositions, permit_id) do
      {:ok, loss} ->
        state = update_in(state.pending_dispositions, &Map.delete(&1, permit_id))
        start_waiting_owner_loss_settlement(state, permit_id, operation, loss)

      :error ->
        state = put_in(state, [:operations, permit_id, :phase], :refusing)
        refuse_permit(state, operation, "control_pending", :unproposed)
    end
  end

  defp mirrored_permits(state) do
    state.mirror_operations
    |> Enum.map(fn {_operation_ref, operation} -> operation.permit_id end)
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
  end

  defp owner_mirror_operation(state, owner, owner_incarnation) do
    Enum.find(state.mirror_operations, fn {_operation_ref, operation} ->
      operation.owner_pid == owner and operation.owner_incarnation == owner_incarnation and
        operation.kind != :owner_loss
    end)
  end

  # Concept: once a lost owner's exit and the relay's loss report have both
  # been consumed, no answer from that owner can still come, so every
  # operation it was acting for that nothing else still settles is removed.
  #
  # Technical depth: the relay claims every permit of that actor whose
  # disposition was unset at its `DOWN` and renders its owner-loss refusal,
  # and it sent every earlier disposition first, so an operation that is not
  # mirrored, has no retained connection loss and is not still opening has
  # already been answered by the relay. Operations this owner acts for itself
  # are refused separately.
  defp discard_claimed_owner_operations(state, owner, owner_incarnation) do
    mirrored = mirrored_permits(state)
    daemon = self()

    operations =
      Map.reject(state.operations, fn {permit_id, operation} ->
        operation.owner_pid == owner and operation.owner_incarnation == owner_incarnation and
          operation.actor_pid != daemon and operation.phase != :opening and
          not MapSet.member?(mirrored, permit_id) and
          not Map.has_key?(state.pending_dispositions, permit_id)
      end)

    %{state | operations: operations}
  end

  defp maybe_start_owner_loss_pop(state, session_id, owner, owner_incarnation) do
    row = Map.get(state.owners, session_id)

    owner_operation? =
      Enum.any?(state.operations, fn {_permit_id, operation} ->
        operation.owner_pid == owner and operation.owner_incarnation == owner_incarnation
      end)

    cond do
      not match?(%{pid: ^owner, incarnation: ^owner_incarnation, phase: :lost}, row) ->
        {:noreply, state}

      row.loss_pop_started ->
        {:noreply, state}

      owner_mirror_operation(state, owner, owner_incarnation) != nil or owner_operation? ->
        {:noreply, state}

      true ->
        start_owner_loss_pop(state, session_id, row)
    end
  end

  defp continue_registry_operation(state, operation_ref, result) do
    case Map.get(state.mirror_operations, operation_ref) do
      nil ->
        {:noreply, state}

      operation ->
        case late_disposition(operation) do
          nil -> apply_registry_result(state, operation_ref, operation, result)
          late -> late_action(state, operation_ref, operation, late)
        end
    end
  end

  defp apply_registry_result(
         state,
         operation_ref,
         %{kind: :grant, step: :install} = operation,
         :ok
       ) do
    state = enter_step(state, operation_ref, :select_result)
    request_relay_selection(state, operation_ref, operation)
    {:noreply, state}
  end

  defp apply_registry_result(
         state,
         operation_ref,
         %{kind: :grant, step: :install_connection_lost, row: row},
         result
       )
       when result == :ok or result == {:error, :connection_not_live} do
    state = enter_step(state, operation_ref, :resolve_cancelled)

    ConnectionRegistry.apply_mirror(
      state.registry,
      operation_ref,
      state.routing_incarnation,
      {:resolve_provisional, :cancelled},
      row
    )

    {:noreply, state}
  end

  defp apply_registry_result(
         state,
         operation_ref,
         %{kind: :grant, step: :install},
         {:error, :connection_not_live}
       ) do
    state = enter_step(state, operation_ref, :await_connection_loss)
    {:noreply, state}
  end

  defp apply_registry_result(
         state,
         operation_ref,
         %{kind: :grant, step: :resolve_granted} = operation,
         :ok
       ) do
    if lost_owner?(state, operation) do
      route = operation.row |> Map.drop([:permit_id, :start_op_ref]) |> Map.put(:phase, :granted)

      state =
        state
        |> put_in([:routes, route.session_id], route)
        |> enter_step(operation_ref, :settle_result_after_owner_loss)

      request_relay_result_settlement(state, operation_ref, operation)
      {:noreply, state}
    else
      state = enter_step(state, operation_ref, :resolve_owner_grant)

      LeaseOwner.request_grant_resolution(
        operation.owner_pid,
        operation_ref,
        operation.owner_incarnation,
        operation.transition_ref,
        :granted,
        monotonic_ms()
      )

      {:noreply, state}
    end
  end

  defp apply_registry_result(
         state,
         operation_ref,
         %{kind: :grant, step: :resolve_cancelled} = operation,
         :ok
       ) do
    if lost_owner?(state, operation) do
      settle_cancelled_disposition(state, operation_ref, operation)
    else
      state = enter_step(state, operation_ref, :resolve_owner_cancel)

      LeaseOwner.request_grant_resolution(
        operation.owner_pid,
        operation_ref,
        operation.owner_incarnation,
        operation.transition_ref,
        :cancelled
      )

      {:noreply, state}
    end
  end

  defp apply_registry_result(
         state,
         operation_ref,
         %{kind: :grant, step: :resolve_owner_lost} = operation,
         :ok
       ),
       do: complete_operation_after_owner_loss(state, operation_ref, operation)

  defp apply_registry_result(
         state,
         operation_ref,
         %{kind: :release, step: :clear} = operation,
         :ok
       ) do
    state = enter_step(state, operation_ref, :settle_result)
    request_relay_result_settlement(state, operation_ref, operation)
    {:noreply, state}
  end

  defp apply_registry_result(
         state,
         operation_ref,
         %{kind: :expiry, step: :clear} = operation,
         :ok
       ) do
    if lost_owner?(state, operation) do
      state = update_in(state.routes, &Map.delete(&1, operation.row.session_id))
      complete_operation_after_owner_loss(state, operation_ref, operation)
    else
      state = enter_step(state, operation_ref, :resolve_owner_expiry)

      LeaseOwner.request_expiry_resolution(
        operation.owner_pid,
        operation_ref,
        operation.owner_incarnation,
        operation.transition_ref
      )

      {:noreply, state}
    end
  end

  defp apply_registry_result(
         state,
         operation_ref,
         %{kind: :owner_loss, step: :pop_owner} = operation,
         {:ok, :absent}
       ) do
    case Map.get(state.routes, operation.row.session_id) do
      nil ->
        begin_owner_loss_classification(state, operation_ref, operation, nil)

      _route ->
        fail_connections(state)
    end
  end

  defp apply_registry_result(
         state,
         operation_ref,
         %{kind: :owner_loss, step: :pop_owner} = operation,
         {:ok, {:holder, holder}}
       ) do
    case Map.get(state.routes, operation.row.session_id) do
      %{
        owner_pid: owner,
        owner_incarnation: owner_incarnation,
        holder_pid: holder_pid,
        holder_incarnation: holder_incarnation,
        writer_epoch: writer_epoch
      }
      when owner == operation.owner_pid and owner_incarnation == operation.owner_incarnation and
             holder_pid == holder.holder_pid and
             holder_incarnation == holder.holder_incarnation and
             writer_epoch == holder.writer_epoch ->
        begin_owner_loss_classification(state, operation_ref, operation, holder)

      _route ->
        fail_connections(state)
    end
  end

  defp apply_registry_result(
         state,
         operation_ref,
         %{kind: :retirement, step: :pop_owner} = operation,
         {:ok, :absent}
       ) do
    cancel_timer(operation.timer, operation_ref)

    state = update_in(state.mirror_operations, &Map.delete(&1, operation_ref))

    case Map.get(state.owners, operation.row.session_id) do
      %{
        pid: owner,
        incarnation: owner_incarnation,
        exit_consumed: true
      } = row
      when owner == operation.owner_pid and owner_incarnation == operation.owner_incarnation ->
        state = put_in(state, [:owners, operation.row.session_id], %{row | mirror_complete: true})
        Logger.debug("loopex daemon retired owner mirror pop complete")
        finish_owner_retirement(state, operation.row.session_id)

      _other ->
        fail_connections(state)
    end
  end

  defp apply_registry_result(
         state,
         operation_ref,
         %{kind: :grant, step: :install_shutdown} = operation,
         result
       )
       when result == :ok or result == {:error, :connection_not_live},
       do: cancel_shutdown_provisional(state, operation_ref, operation)

  defp apply_registry_result(
         state,
         operation_ref,
         %{kind: :grant, step: :cancel_shutdown} = operation,
         :ok
       ),
       do: finish_shutdown_operation(state, operation_ref, operation)

  defp apply_registry_result(state, _operation_ref, _operation, _result),
    do: fail_connections(state)

  defp begin_owner_loss_classification(state, operation_ref, operation, holder) do
    holder_incarnation = if holder, do: holder.holder_incarnation, else: nil

    state =
      state
      |> enter_step(operation_ref, :await_classification)
      |> put_in([:mirror_operations, operation_ref, :holder], holder)
      |> put_in([:owners, operation.row.session_id, :mirror_complete], true)
      |> update_in([:routes], &Map.delete(&1, operation.row.session_id))

    state =
      if holder,
        do: put_in(state, [:lost_holders, operation.row.session_id], holder),
        else: state

    :ok =
      AdmissionRelay.classify_owner_loss(
        state.relay,
        operation.classification_ref,
        state.daemon_incarnation,
        operation.row.session_id,
        operation.owner_pid,
        operation.owner_incarnation,
        holder_incarnation
      )

    Logger.debug("loopex daemon lost owner classification start")
    {:noreply, state}
  end

  defp continue_relay_operation(state, operation_ref, action, result) do
    case Map.get(state.mirror_operations, operation_ref) do
      nil ->
        {:noreply, state}

      operation ->
        case late_disposition(operation) do
          nil -> apply_relay_result(state, operation_ref, operation, action, result)
          late -> late_action(state, operation_ref, operation, late)
        end
    end
  end

  defp apply_relay_result(
         state,
         operation_ref,
         %{kind: :grant, step: :select_result, row: row},
         :select_result,
         :ok
       ) do
    state = enter_step(state, operation_ref, :resolve_granted)

    ConnectionRegistry.apply_mirror(
      state.registry,
      operation_ref,
      state.routing_incarnation,
      {:resolve_provisional, :granted},
      row
    )

    {:noreply, state}
  end

  defp apply_relay_result(
         state,
         operation_ref,
         %{kind: :grant, step: :select_result, row: row},
         :select_result,
         {:error, :owner_lost}
       ) do
    state = enter_step(state, operation_ref, :resolve_owner_lost)

    ConnectionRegistry.apply_mirror(
      state.registry,
      operation_ref,
      state.routing_incarnation,
      {:resolve_provisional, :cancelled},
      row
    )

    {:noreply, state}
  end

  defp apply_relay_result(
         state,
         operation_ref,
         %{kind: :grant, step: :select_result},
         :select_result,
         {:error, :connection_lost}
       ) do
    {:noreply, enter_step(state, operation_ref, :await_connection_loss)}
  end

  defp apply_relay_result(
         state,
         operation_ref,
         %{kind: :release, step: :select_result, row: row},
         :select_result,
         :ok
       ) do
    state = enter_step(state, operation_ref, :clear)

    ConnectionRegistry.apply_mirror(
      state.registry,
      operation_ref,
      state.routing_incarnation,
      :clear_granted,
      row
    )

    {:noreply, state}
  end

  defp apply_relay_result(
         state,
         operation_ref,
         %{kind: :release, step: :select_result} = operation,
         :select_result,
         {:error, :owner_lost}
       ),
       do: complete_operation_after_owner_loss(state, operation_ref, operation)

  defp apply_relay_result(
         state,
         operation_ref,
         %{kind: :release, step: :select_result},
         :select_result,
         {:error, :connection_lost}
       ) do
    {:noreply, enter_step(state, operation_ref, :await_connection_loss)}
  end

  defp apply_relay_result(
         state,
         _operation_ref,
         %{step: step},
         :select_result,
         {:error, :connection_lost}
       )
       when step in [:resolve_cancelled, :resolve_owner_cancel, :settle_disposition],
       do: {:noreply, state}

  defp apply_relay_result(
         state,
         operation_ref,
         %{kind: :grant, step: :settle_result_after_owner_loss} = operation,
         :settle_result,
         :ok
       ),
       do: complete_operation_after_owner_loss(state, operation_ref, operation)

  defp apply_relay_result(
         state,
         operation_ref,
         %{kind: :grant, step: :settle_result} = operation,
         :settle_result,
         :ok
       ) do
    if lost_owner?(state, operation),
      do: complete_operation_after_owner_loss(state, operation_ref, operation),
      else: complete_grant(state, operation_ref, operation)
  end

  defp apply_relay_result(
         state,
         operation_ref,
         %{kind: :release, step: :settle_result} = operation,
         :settle_result,
         :ok
       ) do
    if lost_owner?(state, operation) do
      state = update_in(state.routes, &Map.delete(&1, operation.row.session_id))
      complete_operation_after_owner_loss(state, operation_ref, operation)
    else
      state = enter_step(state, operation_ref, :resolve_owner_release)

      LeaseOwner.request_release_resolution(
        operation.owner_pid,
        operation_ref,
        operation.owner_incarnation,
        operation.transition_ref,
        :released
      )

      {:noreply, state}
    end
  end

  defp apply_relay_result(
         state,
         operation_ref,
         %{step: :settle_disposition} = operation,
         :settle_disposition,
         :ok
       ),
       do: complete_cancelled_operation(state, operation_ref, operation)

  # Concept: the freeze won this permit before the relay consumed the daemon's
  # result selection, so whatever the relay answers is cleanup-only.
  defp apply_relay_result(
         state,
         operation_ref,
         %{step: :select_shutdown} = operation,
         :select_result,
         _cleanup_only
       ) do
    case operation.kind do
      :grant -> cancel_shutdown_provisional(state, operation_ref, operation)
      :release -> finish_shutdown_operation(state, operation_ref, operation)
    end
  end

  defp apply_relay_result(state, _operation_ref, _operation, _action, _result),
    do: {:stop, :relay_lost, state}

  defp continue_owner_operation(
         state,
         operation_ref,
         owner,
         owner_incarnation,
         action,
         result
       ) do
    case Map.get(state.mirror_operations, operation_ref) do
      # Concept: a restoration superseded at `owner_restore_deadline` killed
      # its owner; that owner's queued acknowledgement is cleanup-only.
      %{superseded: true} ->
        Logger.debug("loopex daemon superseded owner acknowledgement ignored")
        {:noreply, state}

      %{owner_pid: ^owner, owner_incarnation: ^owner_incarnation} = operation ->
        case late_disposition(operation) do
          nil -> apply_owner_result(state, operation_ref, operation, action, result)
          late -> late_action(state, operation_ref, operation, late)
        end

      _other ->
        {:noreply, state}
    end
  end

  defp apply_owner_result(
         state,
         operation_ref,
         %{kind: :grant, step: :resolve_owner_grant} = operation,
         :grant,
         :ok
       ) do
    route = operation.row |> Map.drop([:permit_id, :start_op_ref]) |> Map.put(:phase, :granted)
    state = put_in(state, [:routes, route.session_id], route)
    state = enter_step(state, operation_ref, :settle_result)
    request_relay_result_settlement(state, operation_ref, operation)
    {:noreply, state}
  end

  defp apply_owner_result(
         state,
         operation_ref,
         %{kind: :grant, step: :resolve_owner_cancel} = operation,
         :grant,
         :ok
       ) do
    state = enter_step(state, operation_ref, :settle_disposition)
    request_relay_disposition_settlement(state, operation_ref, operation)
    {:noreply, state}
  end

  defp apply_owner_result(
         state,
         operation_ref,
         %{kind: :release, step: :resolve_owner_cancel} = operation,
         :release,
         :ok
       ) do
    state = enter_step(state, operation_ref, :settle_disposition)
    request_relay_disposition_settlement(state, operation_ref, operation)
    {:noreply, state}
  end

  defp apply_owner_result(
         state,
         operation_ref,
         %{kind: :release, step: :resolve_owner_release} = operation,
         :release,
         :ok
       ) do
    state = update_in(state.routes, &Map.delete(&1, operation.row.session_id))
    complete_operation_and_retire(state, operation_ref, operation)
  end

  defp apply_owner_result(
         state,
         operation_ref,
         %{kind: :expiry, step: :resolve_owner_expiry} = operation,
         :expiry,
         :ok
       ) do
    state = update_in(state.routes, &Map.delete(&1, operation.row.session_id))
    complete_operation_and_retire(state, operation_ref, operation)
  end

  defp apply_owner_result(state, _operation_ref, _operation, _action, _result),
    do: {:stop, :lease_operation_invalid, state}

  defp retain_connection_loss(
         state,
         permit_id,
         settlement_ref,
         class,
         session_id,
         actor,
         actor_incarnation,
         start_op_ref
       ) do
    loss = %{
      settlement_ref: settlement_ref,
      class: class,
      session_id: session_id,
      actor_pid: actor,
      actor_incarnation: actor_incarnation,
      start_op_ref: start_op_ref
    }

    case Map.fetch(state.operations, permit_id) do
      {:ok, operation} ->
        if valid_connection_loss?(operation, loss) do
          continue_connection_loss(state, permit_id, loss)
        else
          {:stop, :relay_lost, state}
        end

      :error ->
        if orphan_loss_actor?(state, loss),
          do: settle_orphan_connection_loss(state, permit_id, loss),
          else: {:stop, :relay_lost, state}
    end
  end

  # Concept: a client disconnect never fail-stops the daemon. An actor call
  # can fail before the relay tells this owner the connection was lost — the
  # request worker dies with its connection, so the claim fails, or the loss
  # wins between the claim and a direct result — and the opened operation is
  # dropped with the call's error. The relay still retains that row as
  # `connection_lost` and names its exact actor, so the loss is settled here
  # without a reply.
  #
  # Technical depth: the disposition is accepted only when its actor is this
  # daemon owner, for a fresh acquire's start reference, or the exact lease
  # owner registered for that session; anything else is still `relay_lost`.
  # A no-reply settlement record is rebuilt from the disposition's own fields
  # and settled like an abandoned operation, which deletes it on the relay's
  # acknowledgement.
  defp orphan_loss_actor?(state, loss) do
    cond do
      loss.actor_pid == self() ->
        loss.actor_incarnation == state.daemon_incarnation and is_reference(loss.start_op_ref) and
          loss.class == :session_acquire_control

      is_nil(loss.start_op_ref) ->
        match?(
          %{pid: pid, incarnation: incarnation}
          when pid == loss.actor_pid and incarnation == loss.actor_incarnation,
          Map.get(state.owners, loss.session_id)
        )

      true ->
        false
    end
  end

  defp settle_orphan_connection_loss(state, permit_id, loss) do
    owner = if loss.actor_pid == self(), do: nil, else: loss.actor_pid
    owner_incarnation = if owner, do: loss.actor_incarnation, else: nil

    operation = %{
      request: %{class: loss.class, session_id: loss.session_id, permit_id: permit_id},
      owner_pid: owner,
      owner_incarnation: owner_incarnation,
      actor_pid: loss.actor_pid,
      actor_incarnation: loss.actor_incarnation,
      start_op_ref: loss.start_op_ref,
      phase: :abandoned
    }

    Logger.debug("loopex daemon dropped lease operation connection loss settlement start")
    state = put_in(state, [:operations, permit_id], operation)
    start_waiting_owner_loss_settlement(state, permit_id, operation, loss)
  end

  defp continue_connection_loss(state, permit_id, loss) do
    case Enum.filter(state.mirror_operations, fn {_ref, operation} ->
           operation.permit_id == permit_id
         end) do
      [] ->
        case Map.fetch!(state.operations, permit_id) do
          %{phase: phase} = operation when phase in [:waiting_owner, :abandoned, :superseded] ->
            start_waiting_owner_loss_settlement(state, permit_id, operation, loss)

          _operation ->
            retain_pending_connection_loss(state, permit_id, loss)
        end

      [{operation_ref, %{kind: :grant, step: :install} = operation}] ->
        operation = %{operation | loss_ref: loss.settlement_ref}

        state
        |> put_in([:mirror_operations, operation_ref], operation)
        |> enter_step(operation_ref, :install_connection_lost)
        |> noreply()

      [{_operation_ref, %{step: :install_connection_lost, loss_ref: loss_ref}}]
      when loss_ref == loss.settlement_ref ->
        {:noreply, state}

      [{operation_ref, %{kind: :grant, step: step, row: row} = operation}]
      when step in [:await_connection_loss, :select_result] ->
        operation = %{operation | step: :resolve_cancelled, loss_ref: loss.settlement_ref}

        state =
          state
          |> put_in([:mirror_operations, operation_ref], operation)
          |> enter_step(operation_ref, :resolve_cancelled)

        ConnectionRegistry.apply_mirror(
          state.registry,
          operation_ref,
          state.routing_incarnation,
          {:resolve_provisional, :cancelled},
          row
        )

        {:noreply, state}

      [{operation_ref, %{kind: :release, step: step} = operation}]
      when step in [:await_connection_loss, :select_result] ->
        operation = %{operation | step: :resolve_owner_cancel, loss_ref: loss.settlement_ref}

        state =
          state
          |> put_in([:mirror_operations, operation_ref], operation)
          |> enter_step(operation_ref, :resolve_owner_cancel)

        if lost_owner?(state, operation) do
          settle_cancelled_disposition(state, operation_ref, operation)
        else
          LeaseOwner.request_release_resolution(
            operation.owner_pid,
            operation_ref,
            operation.owner_incarnation,
            operation.transition_ref,
            :cancelled
          )

          {:noreply, state}
        end

      [{_operation_ref, %{step: step, loss_ref: loss_ref}}]
      when step in [:resolve_cancelled, :resolve_owner_cancel, :settle_disposition] and
             loss_ref == loss.settlement_ref ->
        {:noreply, state}

      _other ->
        {:stop, :relay_lost, state}
    end
  end

  defp retain_pending_connection_loss(state, permit_id, loss) do
    case Map.fetch(state.pending_dispositions, permit_id) do
      :error ->
        Logger.debug("loopex daemon connection loss retained")

        state =
          state
          |> put_in([:pending_dispositions, permit_id], loss)
          |> request_queued_discard(permit_id)

        {:noreply, state}

      {:ok, retained} ->
        if Map.delete(retained, :discard_ref) == loss,
          do: {:noreply, state},
          else: {:stop, :relay_lost, state}
    end
  end

  # Concept: an existing lease owner may still hold a claimed acquire or
  # release queued when its connection is lost; it would never propose it, so
  # the daemon owner tells that exact owner to discard it and settles the
  # connection loss itself.
  #
  # Technical depth: the discard reference is kept on the retained loss. The
  # owner answers after any proposal it already sent for that permit, so a
  # proposal consumes the loss first and the answer then finds nothing to
  # settle; otherwise the answer starts the no-reply relay settlement, which
  # deletes the operation. An owner whose exact `EXIT` was already consumed
  # can answer nothing, so its loss is settled at once instead. A fresh
  # child's first acquire always proposes, so it needs no discard.
  defp request_queued_discard(state, permit_id) do
    case Map.fetch!(state.operations, permit_id) do
      %{actor_pid: owner, owner_pid: owner, owner_incarnation: owner_incarnation} = operation
      when is_pid(owner) and owner != self() ->
        if live_owner_incarnation?(state, operation) do
          discard_ref = make_ref()
          :ok = LeaseOwner.request_discard(owner, discard_ref, owner_incarnation, permit_id)
          put_in(state, [:pending_dispositions, permit_id, :discard_ref], discard_ref)
        else
          {loss, state} = pop_in(state, [:pending_dispositions, permit_id])
          Logger.debug("loopex daemon lost owner queued operation settlement start")

          {:noreply, state} =
            start_waiting_owner_loss_settlement(state, permit_id, operation, loss)

          state
        end

      _fresh_or_waiting ->
        state
    end
  end

  defp live_owner_incarnation?(state, operation) do
    match?(
      %{pid: pid, incarnation: incarnation, exit_consumed: false}
      when pid == operation.owner_pid and incarnation == operation.owner_incarnation,
      Map.get(state.owners, operation.request.session_id)
    )
  end

  defp settle_discarded_operation(state, discard_ref, owner, owner_incarnation) do
    with {permit_id, loss} <-
           Enum.find(state.pending_dispositions, fn {_permit_id, loss} ->
             Map.get(loss, :discard_ref) == discard_ref
           end),
         {:ok, %{owner_pid: ^owner, owner_incarnation: ^owner_incarnation} = operation} <-
           Map.fetch(state.operations, permit_id) do
      Logger.debug("loopex daemon discarded lease operation settlement start")
      state = update_in(state.pending_dispositions, &Map.delete(&1, permit_id))
      start_waiting_owner_loss_settlement(state, permit_id, operation, loss)
    else
      _consumed_by_a_proposal -> {:noreply, state}
    end
  end

  # Concept: a lost owner answers no discard, so every connection loss still
  # retained for one of its unproposed operations is settled without it.
  defp settle_pending_owner_losses(state, owner, owner_incarnation) do
    state.pending_dispositions
    |> Enum.filter(fn {permit_id, _loss} ->
      match?(
        %{actor_pid: ^owner, owner_pid: ^owner, owner_incarnation: ^owner_incarnation},
        Map.get(state.operations, permit_id)
      )
    end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce(state, fn {permit_id, loss}, acc ->
      acc = update_in(acc.pending_dispositions, &Map.delete(&1, permit_id))
      operation = Map.fetch!(acc.operations, permit_id)
      {:noreply, acc} = start_waiting_owner_loss_settlement(acc, permit_id, operation, loss)
      acc
    end)
  end

  defp start_waiting_owner_loss_settlement(state, permit_id, operation, loss) do
    operation_ref = make_ref()

    settlement = %{
      kind: :queued_grant,
      step: :settle_disposition,
      permit_id: permit_id,
      owner_pid: nil,
      owner_incarnation: nil,
      actor_pid: operation.actor_pid,
      actor_incarnation: operation.actor_incarnation,
      transition_ref: nil,
      row: %{session_id: operation.request.session_id},
      loss_ref: loss.settlement_ref
    }

    state =
      state
      |> put_in([:operations, permit_id, :phase], :settling)
      |> put_mirror(operation_ref, settlement)

    request_relay_disposition_settlement(state, operation_ref, settlement)
    Logger.debug("loopex daemon queued successor connection loss settlement start")
    {:noreply, state}
  end

  defp valid_connection_loss?(operation, loss) do
    is_reference(loss.settlement_ref) and operation.request.class == loss.class and
      operation.request.session_id == loss.session_id and operation.actor_pid == loss.actor_pid and
      operation.actor_incarnation == loss.actor_incarnation and
      operation.start_op_ref == loss.start_op_ref
  end

  defp request_relay_selection(state, operation_ref, operation) do
    request_id = operation_request_id(state, operation.permit_id)

    result =
      case operation.kind do
        :grant ->
          WireRecords.control_acquired(
            request_id,
            operation.row.writer_epoch,
            state.lease_term_ms,
            false
          )

        :release ->
          WireRecords.control_released(request_id)
      end

    AdmissionRelay.request_lease_result_selection(
      state.relay,
      operation_ref,
      state.daemon_incarnation,
      operation.permit_id,
      operation.actor_pid,
      operation.actor_incarnation,
      operation.transition_ref,
      result
    )
  end

  defp request_relay_result_settlement(state, operation_ref, operation) do
    AdmissionRelay.request_lease_result_settlement(
      state.relay,
      operation_ref,
      state.daemon_incarnation,
      operation.permit_id,
      operation.transition_ref
    )
  end

  defp request_relay_disposition_settlement(state, operation_ref, operation) do
    AdmissionRelay.request_lease_disposition_settlement(
      state.relay,
      operation_ref,
      state.daemon_incarnation,
      operation.permit_id,
      :connection_lost,
      operation.loss_ref
    )
  end

  defp complete_grant(state, operation_ref, operation) do
    complete_operation(state, operation_ref, operation)
  end

  # Concept: a cancelled operation may be the last thing an owner loss waits
  # for. Technical depth: after its relay disposition settles, a lost owner
  # re-checks its mirror pop; a live fresh-grant owner is asked to retire.
  defp complete_cancelled_operation(state, operation_ref, operation) do
    {:noreply, state} = complete_operation(state, operation_ref, operation)
    session_id = operation.row.session_id

    case Map.get(state.owners, session_id) do
      %{phase: :lost, pid: owner, incarnation: owner_incarnation} ->
        maybe_start_owner_loss_pop(state, session_id, owner, owner_incarnation)

      _row when operation.kind == :grant ->
        request_owner_retirement(state, operation.owner_pid, session_id)

      _row ->
        {:noreply, state}
    end
  end

  defp settle_cancelled_disposition(state, operation_ref, operation) do
    state = enter_step(state, operation_ref, :settle_disposition)
    request_relay_disposition_settlement(state, operation_ref, operation)
    Logger.debug("loopex daemon lost owner cancellation settlement start")
    {:noreply, state}
  end

  defp complete_operation_and_retire(state, operation_ref, operation) do
    {:noreply, state} = complete_operation(state, operation_ref, operation)
    request_owner_retirement(state, operation.owner_pid, operation.row.session_id)
  end

  defp complete_operation_after_owner_loss(state, operation_ref, operation) do
    {:noreply, state} = complete_operation(state, operation_ref, operation)

    Logger.debug("loopex daemon lost owner operation settlement complete")

    maybe_start_owner_loss_pop(
      state,
      operation.row.session_id,
      operation.owner_pid,
      operation.owner_incarnation
    )
  end

  defp complete_operation(state, operation_ref, operation) do
    cancel_timer(operation.timer, operation_ref)

    state = %{
      state
      | mirror_operations: Map.delete(state.mirror_operations, operation_ref),
        operations:
          if(operation.permit_id,
            do: Map.delete(state.operations, operation.permit_id),
            else: state.operations
          ),
        pending_dispositions:
          if(operation.permit_id,
            do: Map.delete(state.pending_dispositions, operation.permit_id),
            else: state.pending_dispositions
          )
    }

    state = release_successor_reservation(state, operation)

    Logger.debug("loopex daemon mirror settlement complete")
    {:noreply, state}
  end

  # Concept: retirement is requested without waiting; the lease owner's
  # retirement intent is its only answer.
  defp request_owner_retirement(state, owner, session_id) do
    case Map.get(state.owners, session_id) do
      %{pid: ^owner, incarnation: owner_incarnation, phase: :live} ->
        :ok = LeaseOwner.request(owner, owner_incarnation, :retire_if_idle)
        {:noreply, state}

      _other ->
        {:noreply, state}
    end
  end

  defp retain_owner_loss_ready(state, session_id, owner, owner_incarnation) do
    case Map.get(state.owners, session_id) do
      %{pid: ^owner, incarnation: ^owner_incarnation, relay_loss_seen: true} = row ->
        Logger.debug("loopex daemon lease owner loss workers reaped")
        {:noreply, put_in(state, [:owners, session_id], %{row | relay_loss_ready: true})}

      %{pid: ^owner, incarnation: ^owner_incarnation, relay_loss_ready: true} ->
        {:noreply, state}

      _other ->
        {:stop, :relay_lost, state}
    end
  end

  defp continue_owner_loss_classification(
         state,
         classification_ref,
         session_id,
         owner,
         owner_incarnation
       ) do
    case Enum.find(state.mirror_operations, fn {_operation_ref, operation} ->
           operation.kind == :owner_loss and operation.step == :await_classification and
             operation.classification_ref == classification_ref and
             operation.row.session_id == session_id and operation.owner_pid == owner and
             operation.owner_incarnation == owner_incarnation
         end) do
      {operation_ref, operation} ->
        # Concept: a classification consumed after its step's instant is the
        # relay's lateness, never the registry's.
        case {late_disposition(operation), Map.get(state.owners, session_id)} do
          {nil,
           %{
             pid: ^owner,
             incarnation: ^owner_incarnation,
             relay_loss_seen: true,
             relay_loss_ready: true,
             mirror_complete: true
           } = row} ->
            row = %{row | classification_complete: true}
            state = put_in(state, [:owners, session_id], row)
            continue_owner_loss_notification(state, operation_ref, operation)

          {nil, _other} ->
            {:stop, :relay_lost, state}

          {late, _row} ->
            late_action(state, operation_ref, operation, late)
        end

      nil ->
        {:stop, :relay_lost, state}
    end
  end

  defp continue_owner_loss_notification(state, operation_ref, %{holder: nil} = operation) do
    complete_owner_loss_notification(state, operation_ref, operation)
  end

  # Concept: a classification consumed after the admission cut emits no
  # `control_owner_lost` form; the later `daemon.stopping`/EOF path closes the
  # holder, and the loss completes as part of the stop.
  defp continue_owner_loss_notification(%{stop: %{}} = state, operation_ref, operation) do
    Logger.debug("loopex daemon lost owner holder close left to the stop")
    complete_owner_loss_notification(state, operation_ref, operation)
  end

  # Concept (P3): the holder is monitored before it is told, so its close
  # completes on whichever comes first — its acknowledgement or its exit for
  # any reason, including one that happened before the send; a holder still
  # silent at its step's instant is killed and its exit completes the close.
  defp continue_owner_loss_notification(
         state,
         operation_ref,
         %{holder: holder} = operation
       ) do
    monitor = Process.monitor(holder.holder_pid)
    close_ref = make_ref()

    send(
      holder.holder_pid,
      {:daemon_control_owner_lost, self(), close_ref, operation.row.session_id,
       holder.holder_incarnation}
    )

    state =
      state
      |> put_in([:mirror_operations, operation_ref], %{
        operation
        | close_ref: close_ref,
          holder_monitor: monitor
      })
      |> enter_step(operation_ref, :await_holder_close)

    Logger.debug("loopex daemon lost owner holder close start")
    {:noreply, state}
  end

  defp continue_owner_loss_close(state, close_ref, connection, connection_incarnation) do
    case Enum.find(state.mirror_operations, fn {_operation_ref, operation} ->
           operation.kind == :owner_loss and operation.step == :await_holder_close and
             operation.close_ref == close_ref and operation.holder.holder_pid == connection and
             operation.holder.holder_incarnation == connection_incarnation
         end) do
      {operation_ref, operation} ->
        complete_owner_loss_notification(state, operation_ref, operation)

      nil ->
        {:noreply, state}
    end
  end

  defp complete_owner_loss_notification(state, operation_ref, operation) do
    cancel_timer(operation.timer, operation_ref)

    if operation.holder_monitor,
      do: Process.demonitor(operation.holder_monitor, [:flush])

    state =
      state
      |> update_in([:mirror_operations], &Map.delete(&1, operation_ref))
      |> put_in([:owners, operation.row.session_id, :notification_complete], true)

    Logger.debug("loopex daemon lease owner loss notification complete")
    finish_owner_loss(state, operation.row.session_id)
  end

  # Concept: once a lost owner's pop, classification and holder close are
  # done, every request that waited on that loss is answered or dispatched
  # again, and the session serves its next owner.
  defp finish_owner_loss(state, session_id) do
    case Map.get(state.owners, session_id) do
      %{
        exit_consumed: true,
        mirror_complete: true,
        classification_complete: true,
        notification_complete: true,
        successor: nil
      } = row ->
        Logger.debug("loopex daemon lease owner loss complete")
        _ = row
        {:noreply, delete_row(state, session_id)}

      %{
        exit_consumed: true,
        mirror_complete: true,
        classification_complete: true,
        notification_complete: true,
        successor: permit_id
      } = row
      when not is_nil(permit_id) ->
        state =
          put_in(state, [:owners, session_id], %{row | held: [], pending_dispatch: []})

        case start_waiting_successor(state, session_id, row, permit_id) do
          {:noreply, state} -> {:noreply, release_loss_waiters(state, row)}
          stopped -> stopped
        end

      _other ->
        {:noreply, state}
    end
  end

  defp release_loss_waiters(state, row) do
    state
    |> release_held(row.held)
    |> redispatch(row.pending_dispatch)
  end

  defp finish_owner_retirement(state, session_id) do
    case Map.get(state.owners, session_id) do
      %{
        exit_consumed: true,
        relay_complete: true,
        mirror_complete: true,
        successor: nil
      } ->
        Logger.debug("loopex daemon lease owner retirement complete")
        {:noreply, delete_row(state, session_id)}

      %{
        exit_consumed: true,
        relay_complete: true,
        mirror_complete: true,
        successor: permit_id
      } = row
      when not is_nil(permit_id) ->
        start_waiting_successor(state, session_id, row, permit_id)

      _other ->
        {:noreply, state}
    end
  end

  # Technical depth: a successor whose open or claim the relay has not yet
  # answered is started by that answer.
  defp start_waiting_successor(state, session_id, predecessor, permit_id) do
    case Map.get(state.operations, permit_id) do
      %{phase: phase} when phase in [:opening, :claiming] ->
        {:noreply, state}

      %{phase: :waiting_owner, request: %{session_id: ^session_id} = request} = operation ->
        if request.request_deadline <= monotonic_ms() do
          complete_waiting_successor(
            state,
            session_id,
            predecessor,
            operation,
            "control_pending"
          )
        else
          materialize_waiting_successor(state, session_id, predecessor, operation)
        end

      _other ->
        {:stop, :lease_operation_invalid, state}
    end
  end

  defp materialize_waiting_successor(state, session_id, predecessor, operation) do
    if lease_relay_closed?(state),
      do:
        complete_waiting_successor(state, session_id, predecessor, operation, "daemon_stopping"),
      else: start_waiting_owner(state, session_id, operation)
  end

  defp start_waiting_owner(state, session_id, operation) do
    owner_incarnation = incarnation()

    case LeaseOwner.start_link(
           daemon_owner: self(),
           relay: state.relay,
           registry: state.registry,
           session_id: session_id,
           owner_incarnation: owner_incarnation,
           lease_term_ms: state.lease_term_ms,
           retirement_exit_gate: state.retirement_exit_gate,
           attachments: Map.get(state.attachments, session_id, MapSet.new())
         ) do
      {:ok, owner} ->
        permit_id = operation.request.permit_id

        row = %{
          owner_row(owner, owner_incarnation)
          | phase: :registering,
            first_permit: permit_id
        }

        operation = %{
          operation
          | owner_pid: owner,
            owner_incarnation: owner_incarnation,
            phase: :opened
        }

        request_id =
          AdmissionRelay.register_lease_owner_request(
            state.relay,
            session_id,
            owner,
            owner_incarnation
          )

        state
        |> put_in([:owners, session_id], row)
        |> put_in([:owner_pids, owner], session_id)
        |> put_in([:operations, permit_id], operation)
        |> relay_request(request_id, {:register, session_id, owner, owner_incarnation})
        |> noreply()

      _error ->
        complete_waiting_successor(state, session_id, nil, operation, "control_pending")
    end
  end

  defp complete_waiting_successor(state, session_id, _predecessor, operation, code) do
    state = put_in(state, [:operations, operation.request.permit_id, :phase], :refusing)
    refuse_permit(state, operation, code, {:waiting_successor, session_id})
  end

  defp release_successor_reservation(
         state,
         %{kind: :queued_grant, permit_id: permit_id, row: %{session_id: session_id}}
       ) do
    case Map.get(state.owners, session_id) do
      %{successor: ^permit_id} = row ->
        slot_charged = not row.exit_consumed

        phase =
          if row.exit_consumed and row.phase != :lost,
            do: :retiring,
            else: row.phase

        row = %{row | phase: phase, successor: nil, slot_charged: slot_charged}

        retired =
          row.phase != :lost and row.exit_consumed and row.relay_complete and row.mirror_complete

        lost =
          row.phase == :lost and row.exit_consumed and row.mirror_complete and
            row.classification_complete and row.notification_complete

        if retired or lost do
          state |> put_in([:owners, session_id], row) |> delete_row(session_id)
        else
          put_in(state, [:owners, session_id], row)
        end

      _other ->
        state
    end
  end

  defp release_successor_reservation(state, _operation), do: state

  # Concept: a child the relay never registered has no owner-loss path.
  # Technical depth: it is unlinked, killed and its possible `EXIT` flushed.
  defp discard_unregistered_owner(owner) do
    Process.unlink(owner)
    Process.exit(owner, :kill)

    receive do
      {:EXIT, ^owner, _reason} -> :ok
    after
      0 -> :ok
    end
  end

  defp owner_row(owner, owner_incarnation) do
    %{
      pid: owner,
      incarnation: owner_incarnation,
      phase: :live,
      slot_charged: true,
      successor: nil,
      retirement_ref: nil,
      exit_consumed: false,
      relay_complete: false,
      mirror_complete: false,
      relay_loss_seen: false,
      relay_loss_ready: false,
      loss_origins: nil,
      classification_complete: false,
      notification_complete: false,
      loss_pop_started: false,
      first_permit: nil,
      pending_dispatch: [],
      held: []
    }
  end

  defp owner_slot_count(state) do
    Enum.count(state.owners, fn {_session_id, row} -> Map.get(row, :slot_charged, true) end)
  end

  defp fail_connections(state) do
    if Process.alive?(state.registry), do: Process.exit(state.registry, :kill)
    Logger.debug("loopex daemon mirror settlement deadline reached")
    {:stop, :connections_lost, state}
  end

  defp operation_request_id(state, permit_id) do
    state.operations |> Map.fetch!(permit_id) |> get_in([:request, :request_id])
  end

  defp lost_owner?(state, operation) do
    case Map.get(state.owners, operation.row.session_id) do
      %{
        pid: owner,
        incarnation: owner_incarnation,
        phase: :lost
      }
      when owner == operation.owner_pid and owner_incarnation == operation.owner_incarnation ->
        true

      _other ->
        false
    end
  end

  defp valid_request?(request) do
    request.class in [:session_acquire_control, :session_release_control] and
      is_binary(request.request_id) and byte_size(request.request_id) in 1..256 and
      valid_session?(request.session_id) and is_pid(request.connection) and
      valid_incarnation?(request.connection_incarnation) and is_pid(request.worker) and
      valid_incarnation?(request.worker_incarnation) and is_integer(request.request_deadline) and
      request.request_deadline > monotonic_ms()
  end

  defp valid_options?(
         daemon_incarnation,
         routing_incarnation,
         admission_wait_ms,
         mirror_deadline_ms,
         lease_term_ms,
         retirement_pop_gate,
         retirement_exit_gate
       ) do
    valid_incarnation?(daemon_incarnation) and valid_incarnation?(routing_incarnation) and
      is_integer(admission_wait_ms) and admission_wait_ms > 0 and
      is_integer(mirror_deadline_ms) and mirror_deadline_ms > 0 and
      mirror_deadline_ms <= @mirror_deadline_ms and is_integer(lease_term_ms) and
      lease_term_ms > 0 and (is_nil(retirement_pop_gate) or is_pid(retirement_pop_gate)) and
      (is_nil(retirement_exit_gate) or is_pid(retirement_exit_gate))
  end

  defp valid_session?(session_id),
    do: is_binary(session_id) and byte_size(session_id) in 1..256

  defp valid_incarnation?(value),
    do: is_binary(value) and byte_size(value) == @incarnation_bytes

  # Concept: a message consumed at or after its step's instant is not a
  # success; the step's owner decides what follows: a late registry step is
  # `connections_lost`, a late relay step `relay_lost`, a late lease owner is
  # replaced, and a late holder connection is killed.
  #
  # Technical depth: a lease owner late restoring a cancelled release is
  # superseded by settling the connection loss at once; one late with its
  # release acknowledgement, or with any other resolution, is killed and its
  # exit resolves the operation through the ordinary lost-owner path. A step
  # entered after the admission cut has no instant.
  defp late_disposition(%{step_deadline: deadline} = operation) when is_integer(deadline) do
    if monotonic_ms() >= deadline, do: late_class(operation), else: nil
  end

  defp late_disposition(_operation), do: nil

  defp late_class(%{step_owner: :registry}), do: :connections_lost
  defp late_class(%{step_owner: :relay}), do: :relay_lost
  defp late_class(%{step_owner: :connection}), do: :kill_holder
  defp late_class(%{kind: :release, step: :resolve_owner_cancel}), do: :supersede
  defp late_class(%{step_owner: :lease_owner}), do: :replace_owner

  defp late_action(state, _operation_ref, _operation, :connections_lost),
    do: fail_connections(state)

  defp late_action(state, _operation_ref, _operation, :relay_lost) do
    Logger.debug("loopex daemon relay step deadline reached")
    {:stop, :relay_lost, state}
  end

  defp late_action(state, operation_ref, operation, :supersede),
    do: supersede_release_restoration(state, operation_ref, operation)

  defp late_action(state, operation_ref, operation, :replace_owner),
    do: replace_late_owner(state, operation_ref, operation)

  # Concept (P3): a holder that has not acknowledged its owner-lost close by
  # its step's instant is killed; its monitored exit completes the close, and
  # that client gets EOF instead of its record.
  defp late_action(state, operation_ref, operation, :kill_holder) do
    Process.exit(operation.holder.holder_pid, :kill)
    Logger.debug("loopex daemon lost owner holder close missed its step")

    operation = %{operation | timer: nil, step_deadline: nil}
    {:noreply, put_in(state, [:mirror_operations, operation_ref], operation)}
  end

  # Concept (P2): a lease owner that misses its own step — a resolution or a
  # release acknowledgement — is killed and superseded, scoped to its
  # session; the registry is not blamed and the daemon keeps serving.
  #
  # Technical depth: the operation keeps its step and becomes `superseded`,
  # so a queued owner acknowledgement is cleanup-only; the owner's exact
  # `EXIT` resolves the operation through the ordinary lost-owner path
  # (`resolve_lost_owner_operation`), which enters the next step with its own
  # instant. The killed pid is recorded while a stop is in progress so the
  # freeze barrier joins its loss.
  defp replace_late_owner(state, operation_ref, operation) do
    Process.exit(operation.owner_pid, :kill)
    cancel_timer(operation.timer, operation_ref)
    operation = %{operation | superseded: true, timer: nil, step_deadline: nil}

    state =
      state
      |> put_in([:mirror_operations, operation_ref], operation)
      |> record_stop_kill(operation.owner_pid)

    Logger.debug("loopex daemon late lease owner superseded")
    {:noreply, state}
  end

  # Concept: a lease owner that has not restored its held state within its
  # step, or whose restoration acknowledgement is consumed after it, cannot
  # keep `release_pending`: the daemon kills that exact owner and settles the
  # connection loss without a reply, and the ordinary owner-loss path then
  # handles the dead owner.
  #
  # Technical depth: the operation becomes `superseded`, so a queued owner
  # acknowledgement is cleanup-only; the no-reply relay settlement is a
  # relay step with its own instant. The killed pid is recorded while a stop
  # is in progress so the freeze barrier joins its loss.
  defp supersede_release_restoration(state, operation_ref, operation) do
    Process.exit(operation.owner_pid, :kill)
    operation = %{operation | superseded: true}

    state =
      state
      |> put_in([:mirror_operations, operation_ref], operation)
      |> enter_step(operation_ref, :settle_disposition)
      |> record_stop_kill(operation.owner_pid)

    request_relay_disposition_settlement(state, operation_ref, operation)
    Logger.debug("loopex daemon release restoration superseded")
    {:noreply, state}
  end

  defp record_stop_kill(%{stop: %{killed: killed}} = state, pid),
    do: put_in(state, [:stop, :killed], MapSet.put(killed, pid))

  defp record_stop_kill(state, _pid), do: state

  # Concept: the relay's freeze returns one fixed tagged descriptor per lease
  # row it still names; the daemon owner cleans each one up from that set and
  # its own exact records, never by scanning for actors, and emits no client
  # output. The freeze barrier answers only when every provisional, pending or
  # stale operation mirror is gone and every killed owner's loss has joined.
  #
  # Technical depth: a malformed or duplicated set, a wrong tag, or a missing
  # or mismatched required record is `relay_lost`. A `shutdown_admitted` row's
  # operation is tombstoned. For an existing-owner actor that exact owner is
  # killed; for a fresh acquire, whose actor is this owner, the start record
  # either names no child (`not_materialized`), releasing its reserved slot,
  # or names the exact child, which is killed. A provisional mirror the row
  # installed is resolved cancelled. A `settling_release` whose owner has not
  # restored is superseded at once. Settling rows otherwise finish through
  # their ordinary exact steps, whose relay settlements render nothing after
  # the freeze, and every killed owner's pop and classification run through
  # the stop-owned owner-loss path.
  defp begin_freeze_cleanup(state, descriptors) do
    if valid_descriptors?(descriptors) do
      Enum.reduce_while(descriptors, {:ok, state}, fn descriptor, {:ok, acc} ->
        case freeze_descriptor(acc, descriptor) do
          {:ok, acc} -> {:cont, {:ok, acc}}
          {:error, class} -> {:halt, {:error, class}}
        end
      end)
    else
      {:error, :relay_lost}
    end
  end

  defp valid_descriptors?(descriptors) when is_list(descriptors) do
    ids = Enum.map(descriptors, &descriptor_permit/1)
    Enum.all?(ids, &(not is_nil(&1))) and length(Enum.uniq(ids)) == length(ids)
  end

  defp valid_descriptors?(_descriptors), do: false

  defp descriptor_permit({:shutdown_admitted, permit_id, class, actor, incarnation, start_op_ref})
       when class in [:session_acquire_control, :session_release_control] and is_pid(actor) and
              (is_nil(start_op_ref) or is_reference(start_op_ref)),
       do: if(valid_incarnation?(incarnation), do: permit_id, else: nil)

  defp descriptor_permit(
         {:settling_acquire, permit_id, disposition, actor, incarnation, start_op_ref, op_ref}
       )
       when disposition in [:result, :connection_lost] and is_pid(actor) and
              (is_nil(start_op_ref) or is_reference(start_op_ref)) and is_reference(op_ref),
       do: if(valid_incarnation?(incarnation), do: permit_id, else: nil)

  defp descriptor_permit({:settling_release, permit_id, disposition, actor, incarnation, op_ref})
       when disposition in [:result, :connection_lost] and is_pid(actor) and is_reference(op_ref),
       do: if(valid_incarnation?(incarnation), do: permit_id, else: nil)

  defp descriptor_permit({:settling_owner_loss, permit_id, class, actor, incarnation, _op_ref})
       when class in [:session_acquire_control, :session_release_control] and is_pid(actor),
       do: if(valid_incarnation?(incarnation), do: permit_id, else: nil)

  defp descriptor_permit(_descriptor), do: nil

  defp freeze_descriptor(
         state,
         {:shutdown_admitted, permit_id, class, actor, actor_incarnation, start_op_ref}
       ) do
    case Map.fetch(state.operations, permit_id) do
      {:ok,
       %{
         request: %{class: ^class},
         actor_pid: ^actor,
         actor_incarnation: ^actor_incarnation,
         start_op_ref: ^start_op_ref
       } = operation} ->
        with {:ok, state} <- shutdown_mirror_operations(state, permit_id) do
          state =
            state
            |> update_in([:operations], &Map.delete(&1, permit_id))
            |> update_in([:pending_dispositions], &Map.delete(&1, permit_id))
            |> put_in([:stop, :tombstones, permit_id], :shutdown_admitted)

          shutdown_actor(state, operation)
        end

      _missing_or_mismatched ->
        {:error, :relay_lost}
    end
  end

  defp freeze_descriptor(
         state,
         {:settling_acquire, permit_id, disposition, actor, actor_incarnation, start_op_ref,
          op_ref}
       ) do
    case Map.fetch(state.operations, permit_id) do
      {:ok,
       %{
         request: %{class: :session_acquire_control},
         actor_pid: ^actor,
         actor_incarnation: ^actor_incarnation,
         start_op_ref: ^start_op_ref
       } = operation} ->
        freeze_settling(state, operation, disposition, op_ref)

      _missing_or_mismatched ->
        {:error, :relay_lost}
    end
  end

  defp freeze_descriptor(
         state,
         {:settling_release, permit_id, disposition, actor, actor_incarnation, op_ref}
       ) do
    case Map.fetch(state.operations, permit_id) do
      {:ok,
       %{
         request: %{class: :session_release_control},
         actor_pid: ^actor,
         actor_incarnation: ^actor_incarnation
       } = operation} ->
        freeze_settling(state, operation, disposition, op_ref)

      _missing_or_mismatched ->
        {:error, :relay_lost}
    end
  end

  defp freeze_descriptor(state, {:settling_owner_loss, _permit_id, _, _, _, _}),
    do: {:ok, state}

  # Concept: a settling row is matched to the exact retained record whose
  # settlement it names: the proposal's transition reference for a `result`,
  # and the retained connection-loss reference for `connection_lost`. Any
  # other pairing means the relay and the daemon owner disagree, which is
  # `relay_lost`.
  #
  # Technical depth: a matched row normally finishes through its ordinary
  # steps. A release whose owner has not restored is superseded at once. A
  # connection loss still retained without a mirror operation — its actor
  # never proposed — is settled here: an existing owner's operation is
  # tombstoned and its no-reply settlement started, and a fresh child is
  # killed so that its exact `EXIT` refuses the unproposed grant and settles
  # the retained loss.
  defp freeze_settling(state, operation, disposition, op_ref) do
    permit_id = operation.request.permit_id

    mirror =
      Enum.find(state.mirror_operations, fn {_operation_ref, mirror_operation} ->
        mirror_operation.permit_id == permit_id
      end)

    pending = Map.get(state.pending_dispositions, permit_id)

    case {disposition, mirror, pending} do
      {:result, {_operation_ref, %{transition_ref: ^op_ref}}, nil} ->
        {:ok, state}

      {:connection_lost,
       {operation_ref,
        %{kind: :release, step: :resolve_owner_cancel, loss_ref: ^op_ref} = release}, nil} ->
        {:noreply, state} = supersede_release_restoration(state, operation_ref, release)
        {:ok, state}

      {:connection_lost, {_operation_ref, %{loss_ref: ^op_ref}}, nil} ->
        {:ok, state}

      {:connection_lost, nil, %{settlement_ref: ^op_ref}} ->
        settle_unproposed_loss(state, operation, pending)

      _mismatched ->
        {:error, :relay_lost}
    end
  end

  # Technical depth: both branches tombstone the permit, so a proposal the
  # actor sent before its kill creates no mirror row. The fresh child's own
  # `EXIT` settles the retained loss through `refuse_unproposed_grants`; an
  # existing owner is killed too, so it cannot keep the queued operation or
  # leave a later proposal in `release_pending` or a proposed grant, and its
  # loss is settled here.
  defp settle_unproposed_loss(state, %{actor_pid: actor} = operation, _loss)
       when actor == self() do
    state
    |> put_in([:stop, :tombstones, operation.request.permit_id], :connection_lost)
    |> shutdown_actor(operation)
  end

  defp settle_unproposed_loss(state, operation, loss) do
    permit_id = operation.request.permit_id

    state =
      state
      |> update_in([:pending_dispositions], &Map.delete(&1, permit_id))
      |> put_in([:stop, :tombstones, permit_id], :connection_lost)

    with {:ok, state} <- shutdown_actor(state, operation) do
      Logger.debug("loopex daemon unproposed lease operation settled at freeze")
      {:noreply, state} = start_waiting_owner_loss_settlement(state, permit_id, operation, loss)
      {:ok, state}
    end
  end

  # Technical depth: a barrier-owned permit can have a mirror operation only
  # before its result was selected: a grant still installing or selecting, or
  # a release still selecting. Each becomes cleanup-only; any later step means
  # the relay's barrier and the daemon's record disagree.
  defp shutdown_mirror_operations(state, permit_id) do
    state.mirror_operations
    |> Enum.filter(fn {_operation_ref, operation} -> operation.permit_id == permit_id end)
    |> Enum.reduce_while({:ok, state}, fn
      {operation_ref, %{kind: :grant, step: :install}}, {:ok, acc} ->
        {:cont, {:ok, enter_step(acc, operation_ref, :install_shutdown)}}

      {operation_ref, %{kind: kind, step: :select_result}}, {:ok, acc}
      when kind in [:grant, :release] ->
        {:cont, {:ok, enter_step(acc, operation_ref, :select_shutdown)}}

      _other, _acc ->
        {:halt, {:error, :relay_lost}}
    end)
  end

  defp shutdown_actor(state, %{actor_pid: actor, owner_pid: nil} = operation)
       when actor == self() do
    reservation = %{
      kind: :queued_grant,
      permit_id: operation.request.permit_id,
      row: %{session_id: operation.request.session_id}
    }

    Logger.debug("loopex daemon unmaterialized owner start tombstoned")
    {:ok, release_successor_reservation(state, reservation)}
  end

  defp shutdown_actor(state, operation) do
    case Map.get(state.owners, operation.request.session_id) do
      %{pid: pid, incarnation: incarnation}
      when pid == operation.owner_pid and incarnation == operation.owner_incarnation ->
        Process.exit(pid, :kill)
        Logger.debug("loopex daemon barrier-owned lease actor killed")
        {:ok, record_stop_kill(state, pid)}

      _missing_or_mismatched ->
        {:error, :relay_lost}
    end
  end

  defp cancel_shutdown_provisional(state, operation_ref, operation) do
    state = enter_step(state, operation_ref, :cancel_shutdown)

    ConnectionRegistry.apply_mirror(
      state.registry,
      operation_ref,
      state.routing_incarnation,
      {:resolve_provisional, :cancelled},
      operation.row
    )

    {:noreply, state}
  end

  defp finish_shutdown_operation(state, operation_ref, operation) do
    {:noreply, state} = complete_operation(state, operation_ref, operation)
    Logger.debug("loopex daemon barrier-owned mirror operation cleared")

    maybe_start_owner_loss_pop(
      state,
      operation.row.session_id,
      operation.owner_pid,
      operation.owner_incarnation
    )
  end

  defp check_freeze(state) do
    if freeze_settled?(state) do
      finish_freeze(state, {:ok, state.stop.barrier.descriptors})
    else
      Process.send_after(self(), {:freeze_check, state.stop.barrier.ref}, 5)
      {:noreply, state}
    end
  end

  defp freeze_settled?(state) do
    permits = Enum.map(state.stop.barrier.descriptors, &descriptor_permit/1)
    killed = state.stop.killed

    map_size(state.mirror_operations) == 0 and map_size(state.pending_dispositions) == 0 and
      map_size(state.relay_requests) == 0 and
      not Enum.any?(permits, &Map.has_key?(state.operations, &1)) and
      not Enum.any?(state.owners, fn {_session_id, row} ->
        row.phase == :lost or MapSet.member?(killed, row.pid)
      end)
  end

  @connections_steps [
    :install,
    :install_connection_lost,
    :install_shutdown,
    :resolve_granted,
    :resolve_cancelled,
    :resolve_owner_lost,
    :cancel_shutdown,
    :clear,
    :pop_owner
  ]

  # Concept: the step each unfinished operation waits on names the component
  # that failed the freeze. A missed registry acknowledgement, or a missed
  # holder-close acknowledgement from the connection, is `connections_lost`,
  # the same class the rebound transport-cut instant selects for a late holder
  # close; every other unfinished step — a relay selection, settlement or
  # classification, or a lease owner's `resolve_owner_*` answer the relay join
  # depends on — is `relay_lost`, so the registry is killed only when the
  # connection side is the late party.
  defp freeze_failure(state) do
    if Enum.any?(state.mirror_operations, fn {_operation_ref, operation} ->
         operation.step in @connections_steps
       end),
       do: :connections_lost,
       else: :relay_lost
  end

  defp finish_freeze(state, reply) do
    %{from: from, timer: timer} = state.stop.barrier
    Process.cancel_timer(timer)
    GenServer.reply(from, reply)

    case reply do
      {:error, :connections_lost} ->
        if Process.alive?(state.registry), do: Process.exit(state.registry, :kill)
        Logger.debug("loopex daemon owner lease freeze left mirror work unfinished")

      {:error, _relay_lost} ->
        Logger.debug("loopex daemon owner lease freeze left relay work unfinished")

      {:ok, _descriptors} ->
        Logger.debug("loopex daemon owner lease freeze cleanup complete")
    end

    state = if match?({:ok, _}, reply), do: put_in(state, [:stop, :frozen], true), else: state
    {:noreply, put_in(state, [:stop, :barrier], nil)}
  end

  # Concept: consuming the stop makes every serving-private mirror clock
  # cleanup-only.
  #
  # Technical depth: each timer is cancelled and its queued message flushed.
  # An owner-loss operation in progress is rebound to the transport-cut
  # instant; a release keeps its exact row but loses both serving instants;
  # every other mirror step loses its deadline, so the admission and freeze
  # barriers govern them.
  defp stop_own_serving_operations(state, cut_deadline) do
    state =
      state
      |> stop_own_relay_requests()
      |> stop_own_attachment_acks()
      |> answer_held_requests()

    operations =
      Map.new(state.mirror_operations, fn
        {operation_ref, %{step: :await_holder_close} = operation} ->
          cancel_timer(operation.timer, operation_ref)
          timer = schedule_deadline(operation_ref, cut_deadline)
          {operation_ref, %{operation | timer: timer, step_deadline: cut_deadline}}

        {operation_ref, operation} ->
          cancel_timer(operation.timer, operation_ref)
          {operation_ref, %{operation | timer: nil, step_deadline: nil}}
      end)

    %{state | mirror_operations: operations}
  end

  defp stop_own_relay_requests(state) do
    requests =
      Map.new(state.relay_requests, fn {request_id, request} ->
        if request.timer, do: Process.cancel_timer(request.timer)
        {request_id, %{request | timer: nil}}
      end)

    %{state | relay_requests: requests}
  end

  defp stop_own_attachment_acks(state) do
    acks =
      Map.new(state.attachment_acks, fn {ack_ref, ack} ->
        if ack.timer, do: Process.cancel_timer(ack.timer)
        {ack_ref, %{ack | timer: nil}}
      end)

    %{state | attachment_acks: acks}
  end

  # Concept: a request still held when admission closes had no permit, so it
  # is refused `daemon_stopping` like any request after the cut.
  defp answer_held_requests(state) do
    owners =
      Map.new(state.owners, fn {session_id, row} ->
        Enum.each(row.held, fn entry ->
          if entry[:timer], do: Process.cancel_timer(entry.timer)
          GenServer.reply(entry.from, stopping_answer(state, entry.request))
        end)

        {session_id, %{row | held: []}}
      end)

    %{state | owners: owners}
  end

  defp await_attachment_ack(state, ack_ref, record_ref, owner, owner_incarnation) do
    timer =
      if is_nil(state.stop),
        do: Process.send_after(self(), {:attachment_ack_deadline, ack_ref}, @relay_request_ms)

    ack = %{
      record_ref: record_ref,
      owner: owner,
      owner_incarnation: owner_incarnation,
      timer: timer
    }

    put_in(state, [:attachment_acks, ack_ref], ack)
  end

  defp finish_attachment_ack(state, ack_ref, ack) do
    if ack.timer, do: Process.cancel_timer(ack.timer)
    send(state.registry, {:owner_attachment_recorded, self(), ack.record_ref})
    update_in(state.attachment_acks, &Map.delete(&1, ack_ref))
  end

  defp finish_owner_attachment_acks(state, owner) do
    state.attachment_acks
    |> Enum.filter(fn {_ack_ref, ack} -> ack.owner == owner end)
    |> Enum.reduce(state, fn {ack_ref, ack}, acc -> finish_attachment_ack(acc, ack_ref, ack) end)
  end

  defp settle_notice(state, permit_id, operation, :result) do
    if Map.has_key?(state.pending_dispositions, permit_id) do
      latch_relay_lost(state)
    else
      state = update_in(state.operations, &Map.delete(&1, permit_id))
      Logger.debug("loopex daemon lease permit settled by its owner")

      maybe_start_owner_loss_pop(
        state,
        operation.request.session_id,
        operation.owner_pid,
        operation.owner_incarnation
      )
    end
  end

  defp settle_notice(state, permit_id, operation, :connection_lost) do
    case Map.pop(state.pending_dispositions, permit_id) do
      {nil, _pending} ->
        {:noreply, put_in(state, [:operations, permit_id, :phase], :superseded)}

      {loss, pending} ->
        state = %{state | pending_dispositions: pending}
        start_waiting_owner_loss_settlement(state, permit_id, operation, loss)
    end
  end

  defp settle_notice(state, permit_id, %{actor_pid: actor} = operation, :invalid)
       when actor == self() do
    state = put_in(state, [:operations, permit_id, :phase], :refusing)
    refuse_permit(state, operation, "control_pending", :unproposed)
  end

  # Concept: a lease owner that cannot settle a permit it was handed through
  # the relay disagrees with the relay about it; while serving that is the
  # relay's loss, whose fail-stop closes the waiting client.
  defp settle_notice(state, permit_id, _operation, :invalid) when is_nil(state.stop) do
    state = update_in(state.operations, &Map.delete(&1, permit_id))
    Logger.debug("loopex daemon lease permit left undecided by its owner")
    latch_relay_lost(state)
  end

  defp settle_notice(state, permit_id, operation, _shutdown_or_invalid) do
    state = update_in(state.operations, &Map.delete(&1, permit_id))

    maybe_start_owner_loss_pop(
      state,
      operation.request.session_id,
      operation.owner_pid,
      operation.owner_incarnation
    )
  end

  # Concept: each step of a lease operation has its own five-second instant,
  # fixed when the step's request is sent and never restarted; the step's
  # owner — the registry, the relay, a lease owner or a holder connection —
  # is the component its expiry names. A step entered after the admission cut
  # has no instant: the stop's own phase deadlines govern it.
  #
  # Technical depth: `enter_step/3` records `step`, `step_owner` and
  # `step_deadline` and rearms the operation's one timer; an operation is
  # added by `put_mirror/3`, which enters its first step.
  defp put_mirror(state, operation_ref, operation) do
    operation =
      operation
      |> Map.put_new(:opened_at, System.unique_integer([:monotonic]))
      |> Map.put_new(:superseded, false)
      |> Map.merge(%{timer: nil, step_owner: nil, step_deadline: nil})

    state
    |> put_in([:mirror_operations, operation_ref], operation)
    |> enter_step(operation_ref, operation.step)
  end

  defp enter_step(state, operation_ref, step) do
    case Map.fetch(state.mirror_operations, operation_ref) do
      {:ok, operation} ->
        cancel_timer(Map.get(operation, :timer), operation_ref)
        owner = step_owner(step)

        {deadline, timer} =
          if is_nil(state.stop) and not is_nil(owner) do
            deadline = monotonic_ms() + state.mirror_deadline_ms
            {deadline, schedule_deadline(operation_ref, deadline)}
          else
            {nil, nil}
          end

        operation =
          Map.merge(operation, %{
            step: step,
            step_owner: owner,
            step_deadline: deadline,
            timer: timer
          })

        put_in(state, [:mirror_operations, operation_ref], operation)

      :error ->
        state
    end
  end

  # Technical depth: the component whose own work each step waits on.
  @registry_steps [
    :install,
    :install_connection_lost,
    :resolve_granted,
    :resolve_cancelled,
    :resolve_owner_lost,
    :clear,
    :pop_owner,
    :install_shutdown,
    :cancel_shutdown
  ]
  @relay_steps [
    :select_result,
    :await_connection_loss,
    :settle_result,
    :settle_result_after_owner_loss,
    :settle_disposition,
    :await_classification,
    :select_shutdown
  ]
  @lease_owner_steps [
    :resolve_owner_grant,
    :resolve_owner_cancel,
    :resolve_owner_expiry,
    :resolve_owner_release
  ]

  defp step_owner(step) when step in @registry_steps, do: :registry
  defp step_owner(step) when step in @relay_steps, do: :relay
  defp step_owner(step) when step in @lease_owner_steps, do: :lease_owner
  defp step_owner(:await_holder_close), do: :connection
  defp step_owner(_gated), do: nil

  defp schedule_deadline(operation_ref, deadline) do
    Process.send_after(
      self(),
      {:mirror_deadline, operation_ref, deadline},
      max(deadline - monotonic_ms(), 0)
    )
  end

  defp cancel_timer(nil, _operation_ref), do: :ok

  defp cancel_timer(timer, operation_ref) do
    _ = Process.cancel_timer(timer, async: false, info: false)

    receive do
      {:mirror_deadline, ^operation_ref, _deadline} -> :ok
    after
      0 -> :ok
    end
  end

  defp incarnation, do: :crypto.strong_rand_bytes(@incarnation_bytes)
  defp barrier_name({name, _detail}), do: name
  defp barrier_name({name, _detail, _deadline}), do: name
  defp barrier_name(name) when is_atom(name), do: name

  defp monotonic_ms, do: System.monotonic_time(:millisecond)
end
