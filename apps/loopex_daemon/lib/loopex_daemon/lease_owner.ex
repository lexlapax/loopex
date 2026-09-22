defmodule LoopexDaemon.LeaseOwner do
  @moduledoc """
  ## Concept

  One process serializes controller authority for one daemon session. It keeps
  the lease outside durable session truth, grants at most one connection at a
  time, admits one controller mutation at a time through the complete holder
  gate, renews only the current holder, preserves wire order through explicit
  release, and makes takeover eligible on the daemon's monotonic clock.

  ## Technical depth

  The owner begins parked. Its linked daemon owner first installs the exact
  pid/incarnation in the admission relay and then activates it. Existing-owner
  acquire and release operations compare-and-set their actor-bound relay permit
  before changing state. A first acquisition is already claimed by the daemon
  actor before this child is started. Holder-changing grants, expiry and release
  are proposals: this process exposes no epoch or state transition until the
  daemon owner acknowledges the corresponding routing-mirror settlement.

  A mutation records a candidate renewal at its gate instant. Only the joined
  relay settlement and core disposition commit that deadline, and only for an
  accepted or admission-unknown call; refusal discards it. Expiry, a later
  mutation and explicit release wait for that join. Writer epochs are fresh
  128-bit opaque values. Lease and request deadlines use monotonic milliseconds;
  timer messages only prompt a live deadline check. Process status is fully
  redacted and lifecycle logs contain no session, connection, epoch, request or
  permit data. Once the daemon requests retirement from a free idle owner, the
  owner waits for the relay's exact session rows to clear, marks its binding
  retiring there, sends a pre-exit intent to the daemon, and exits normally only
  after the daemon acknowledges that exact intent. Daemon-owned grant, release
  and expiry resolutions also use authenticated ref-tagged messages so the
  fixed owner never blocks while this process commits the selected transition.
  """

  use GenServer
  require Logger

  alias LoopexDaemon.{AdmissionRelay, ConnectionRegistry, WireRecords}

  @lease_term_ms 30_000
  @max_timer_ms 4_294_967_295
  @incarnation_bytes 16
  @max_session_bytes 256

  @direct_mutation_classes [
    :session_prompt,
    :session_steer,
    :session_follow_up,
    :session_abort,
    :session_respond_interaction,
    :session_admit_resources,
    :session_activate_skill
  ]

  @mutation_dispositions [:accepted, :admission_unknown, :refused]

  @typedoc false
  @type permit_id :: AdmissionRelay.origin_id()

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options), do: GenServer.start_link(__MODULE__, options)

  @doc false
  @spec activate(pid()) :: :ok | {:error, :invalid_owner | :owner_unavailable}
  def activate(owner), do: GenServer.call(owner, :activate)

  @doc false
  @spec retire_if_idle(pid()) ::
          {:ok, :retiring | :waiting}
          | {:error, :daemon_stopping | :not_idle | :owner_unavailable}
  def retire_if_idle(owner), do: GenServer.call(owner, :retire_if_idle)

  @doc false
  @spec complete_retirement(pid(), reference()) :: :ok
  def complete_retirement(owner, retirement_ref) do
    GenServer.cast(owner, {:complete_retirement, self(), retirement_ref})
  end

  @doc false
  @spec release_retirement_exit(pid(), reference()) :: :ok
  def release_retirement_exit(owner, retirement_ref) do
    GenServer.cast(owner, {:release_retirement_exit, self(), retirement_ref})
  end

  @doc false
  @spec first_acquire(
          pid(),
          permit_id(),
          binary(),
          pid(),
          binary(),
          integer()
        ) ::
          {:ok, :proposed} | {:error, :invalid_operation | :owner_unavailable}
  def first_acquire(
        owner,
        permit_id,
        request_id,
        connection,
        connection_incarnation,
        request_deadline
      ) do
    GenServer.call(
      owner,
      {:first_acquire, permit_id, request_id, connection, connection_incarnation,
       request_deadline}
    )
  end

  @doc false
  @spec acquire(pid(), permit_id(), binary(), pid(), binary(), integer()) ::
          {:ok, :completed | :proposed | :queued}
          | {:error, :daemon_stopping | :invalid_actor | :invalid_operation | :permit_unavailable}
  def acquire(
        owner,
        permit_id,
        request_id,
        connection,
        connection_incarnation,
        request_deadline
      ) do
    GenServer.call(
      owner,
      {:acquire, permit_id, request_id, connection, connection_incarnation, request_deadline}
    )
  end

  @doc false
  @spec release(pid(), permit_id(), binary(), pid(), binary(), binary()) ::
          {:ok, :completed | :proposed | :queued}
          | {:error, :daemon_stopping | :invalid_actor | :invalid_operation | :permit_unavailable}
  def release(
        owner,
        permit_id,
        request_id,
        connection,
        connection_incarnation,
        writer_epoch
      ) do
    GenServer.call(
      owner,
      {:release, permit_id, request_id, connection, connection_incarnation, writer_epoch}
    )
  end

  @doc false
  @spec resolve_grant(pid(), reference(), :granted | :cancelled, integer() | nil) ::
          :ok | {:error, :invalid_operation}
  def resolve_grant(owner, grant_ref, disposition, granted_at \\ nil) do
    GenServer.call(owner, {:resolve_grant, grant_ref, disposition, granted_at})
  end

  @doc false
  @spec resolve_release(pid(), reference(), :released | :cancelled) ::
          :ok | {:error, :invalid_operation}
  def resolve_release(owner, release_ref, disposition) do
    GenServer.call(owner, {:resolve_release, release_ref, disposition})
  end

  @doc false
  @spec resolve_expiry(pid(), reference()) :: :ok | {:error, :invalid_operation}
  def resolve_expiry(owner, expiry_ref) do
    GenServer.call(owner, {:resolve_expiry, expiry_ref})
  end

  @doc false
  @spec request_grant_resolution(
          pid(),
          reference(),
          binary(),
          reference(),
          :granted | :cancelled,
          integer() | nil
        ) :: :ok
  def request_grant_resolution(
        owner,
        operation_ref,
        owner_incarnation,
        grant_ref,
        disposition,
        granted_at \\ nil
      ) do
    send(
      owner,
      {:daemon_lease_resolution, operation_ref, self(), owner_incarnation, :grant,
       {grant_ref, disposition, granted_at}}
    )

    :ok
  end

  @doc false
  @spec request_release_resolution(
          pid(),
          reference(),
          binary(),
          reference(),
          :released | :cancelled
        ) :: :ok
  def request_release_resolution(
        owner,
        operation_ref,
        owner_incarnation,
        release_ref,
        disposition
      ) do
    send(
      owner,
      {:daemon_lease_resolution, operation_ref, self(), owner_incarnation, :release,
       {release_ref, disposition}}
    )

    :ok
  end

  @doc false
  @spec request_expiry_resolution(pid(), reference(), binary(), reference()) :: :ok
  def request_expiry_resolution(owner, operation_ref, owner_incarnation, expiry_ref) do
    send(
      owner,
      {:daemon_lease_resolution, operation_ref, self(), owner_incarnation, :expiry, expiry_ref}
    )

    :ok
  end

  @doc false
  @spec attachment_opened(pid(), pid(), binary(), binary()) ::
          :ok | {:error, :invalid_operation}
  def attachment_opened(owner, connection, connection_incarnation, attachment_id) do
    GenServer.call(
      owner,
      {:attachment, :opened, connection, connection_incarnation, attachment_id}
    )
  end

  @doc false
  @spec attachment_closed(pid(), pid(), binary(), binary()) ::
          :ok | {:error, :invalid_operation}
  def attachment_closed(owner, connection, connection_incarnation, attachment_id) do
    GenServer.call(
      owner,
      {:attachment, :closed, connection, connection_incarnation, attachment_id}
    )
  end

  @doc false
  @spec mutate(
          pid(),
          permit_id(),
          atom(),
          binary(),
          binary(),
          binary(),
          pid(),
          (-> {:accepted | :admission_unknown | :refused, map()})
        ) ::
          {:ok, :admitted}
          | {:error,
             :daemon_stopping
             | :invalid_operation
             | :owner_unavailable
             | :ticket_outstanding
             | :ticket_unavailable}
  def mutate(
        owner,
        origin_id,
        class,
        request_id,
        connection_incarnation,
        writer_epoch,
        worker,
        task_fun
      ) do
    GenServer.call(
      owner,
      {:mutate, origin_id, class, request_id, connection_incarnation, writer_epoch, worker,
       task_fun},
      :infinity
    )
  end

  @doc false
  @spec resume(
          pid(),
          permit_id(),
          binary(),
          binary(),
          binary(),
          binary(),
          pid(),
          (-> {:accepted | :admission_unknown | :refused, :activated | :no_activation, map()})
        ) ::
          {:ok, :admitted | :completed}
          | {:error,
             :activation_conflict
             | :daemon_stopping
             | :invalid_operation
             | :invalid_promotion
             | :owner_unavailable
             | :registry_unavailable
             | :relay_unavailable
             | :ticket_outstanding
             | :ticket_unavailable}
  def resume(
        owner,
        origin_id,
        request_id,
        command_id,
        connection_incarnation,
        writer_epoch,
        worker,
        task_fun
      ) do
    GenServer.call(
      owner,
      {:resume, origin_id, request_id, command_id, connection_incarnation, writer_epoch, worker,
       task_fun},
      :infinity
    )
  end

  @doc false
  @spec status(pid()) :: map()
  def status(owner), do: GenServer.call(owner, :status)

  @impl true
  def init(options) do
    daemon_owner = Keyword.fetch!(options, :daemon_owner)
    relay = Keyword.fetch!(options, :relay)
    registry = Keyword.fetch!(options, :registry)
    session_id = Keyword.fetch!(options, :session_id)
    owner_incarnation = Keyword.fetch!(options, :owner_incarnation)
    lease_term_ms = Keyword.get(options, :lease_term_ms, @lease_term_ms)
    retirement_exit_gate = Keyword.get(options, :retirement_exit_gate)

    if is_pid(daemon_owner) and is_pid(relay) and is_pid(registry) and valid_session?(session_id) and
         valid_incarnation?(owner_incarnation) and valid_term?(lease_term_ms) and
         (is_nil(retirement_exit_gate) or is_pid(retirement_exit_gate)) do
      Process.link(daemon_owner)
      Logger.debug("loopex daemon lease owner start")

      {:ok,
       %{
         daemon_owner: daemon_owner,
         relay: relay,
         registry: registry,
         session_id: session_id,
         owner_incarnation: owner_incarnation,
         lease_term_ms: lease_term_ms,
         phase: :starting,
         first_acquire_available: true,
         lease: :free,
         transition: nil,
         expiry_timer: nil,
         expiry_token: nil,
         retirement_requested: false,
         retirement_ref: nil,
         retirement_exit_gate: retirement_exit_gate,
         retirement_exit_blocked: false,
         waiters: [],
         waiter_timers: %{},
         attachments: MapSet.new(),
         in_flight: %{},
         pending_operations: []
       }}
    else
      {:stop, :invalid_lease_owner_options}
    end
  end

  @impl true
  def handle_call(:activate, {caller, _tag}, %{daemon_owner: caller, phase: :starting} = state) do
    if Process.alive?(state.relay) do
      Logger.debug("loopex daemon lease owner active")
      {:reply, :ok, %{state | phase: :active}}
    else
      {:reply, {:error, :owner_unavailable}, state}
    end
  end

  def handle_call(:activate, {caller, _tag}, %{daemon_owner: caller, phase: :active} = state),
    do: {:reply, :ok, state}

  def handle_call(:activate, _from, state), do: {:reply, {:error, :invalid_owner}, state}

  def handle_call(
        :retire_if_idle,
        {caller, _tag},
        %{daemon_owner: caller, phase: :active} = state
      ) do
    if retirement_eligible?(state) do
      {reply, state} = begin_retirement(%{state | retirement_requested: true})
      {:reply, reply, state}
    else
      {:reply, {:error, :not_idle}, state}
    end
  end

  def handle_call(:retire_if_idle, _from, state),
    do: {:reply, {:error, :owner_unavailable}, state}

  def handle_call(
        {:first_acquire, permit_id, request_id, connection, connection_incarnation,
         request_deadline},
        {caller, _tag},
        %{daemon_owner: caller, phase: :active, first_acquire_available: true} = state
      ) do
    now = monotonic_ms()

    with :ok <-
           validate_acquire(
             permit_id,
             request_id,
             connection,
             connection_incarnation,
             request_deadline,
             now
           ),
         true <- state.lease == :free and is_nil(state.transition) do
      acquisition =
        acquisition(
          permit_id,
          request_id,
          connection,
          connection_incarnation,
          request_deadline,
          now,
          :daemon
        )

      state = %{state | first_acquire_available: false}
      {state, _grant_ref} = propose_grant(state, acquisition)
      {:reply, {:ok, :proposed}, state}
    else
      false -> {:reply, {:error, :invalid_operation}, state}
      {:error, _reason} -> {:reply, {:error, :invalid_operation}, state}
    end
  end

  def handle_call(
        {:first_acquire, _, _, _, _, _},
        {caller, _tag},
        %{daemon_owner: caller} = state
      ),
      do: {:reply, {:error, :invalid_operation}, state}

  def handle_call({:first_acquire, _, _, _, _, _}, _from, state),
    do: {:reply, {:error, :owner_unavailable}, state}

  def handle_call(
        {:acquire, permit_id, request_id, connection, connection_incarnation, request_deadline},
        {caller, _tag},
        %{daemon_owner: caller, phase: :active} = state
      ) do
    now = monotonic_ms()

    with :ok <-
           validate_acquire(
             permit_id,
             request_id,
             connection,
             connection_incarnation,
             request_deadline,
             now
           ),
         :ok <-
           AdmissionRelay.claim_lease_permit(
             state.relay,
             permit_id,
             state.owner_incarnation
           ) do
      acquisition =
        acquisition(
          permit_id,
          request_id,
          connection,
          connection_incarnation,
          request_deadline,
          now,
          :owner
        )

      {reply, state} = handle_acquisition(state, acquisition, now)
      {:reply, reply, state}
    else
      {:error, :invalid_operation} -> {:reply, {:error, :invalid_operation}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:acquire, _, _, _, _, _}, _from, state),
    do: {:reply, {:error, :invalid_operation}, state}

  def handle_call(
        {:release, permit_id, request_id, connection, connection_incarnation, writer_epoch},
        {caller, _tag},
        %{daemon_owner: caller, phase: :active} = state
      ) do
    with :ok <-
           validate_release(
             permit_id,
             request_id,
             connection,
             connection_incarnation,
             writer_epoch
           ),
         :ok <-
           AdmissionRelay.claim_lease_permit(
             state.relay,
             permit_id,
             state.owner_incarnation
           ) do
      descriptor = %{
        permit_id: permit_id,
        request_id: request_id,
        connection: connection,
        connection_incarnation: connection_incarnation,
        writer_epoch: writer_epoch
      }

      if operation_blocked?(state) do
        state = update_in(state.pending_operations, &(&1 ++ [{:release, descriptor}]))
        Logger.debug("loopex daemon lease release queued")
        {:reply, {:ok, :queued}, state}
      else
        {reply, state} = perform_release(state, descriptor)
        {:reply, reply, state}
      end
    else
      {:error, :invalid_operation} -> {:reply, {:error, :invalid_operation}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:release, _, _, _, _, _}, _from, state),
    do: {:reply, {:error, :invalid_operation}, state}

  def handle_call(
        {:mutate, origin_id, class, request_id, connection_incarnation, writer_epoch, worker,
         task_fun},
        from = {connection, _tag},
        %{phase: :active} = state
      ) do
    with :ok <-
           validate_mutation(
             origin_id,
             class,
             request_id,
             connection,
             connection_incarnation,
             writer_epoch,
             worker,
             task_fun
           ) do
      descriptor = %{
        origin_id: origin_id,
        class: class,
        request_id: request_id,
        connection: connection,
        connection_incarnation: connection_incarnation,
        writer_epoch: writer_epoch,
        worker: worker,
        worker_monitor: Process.monitor(worker),
        task_fun: task_fun,
        from: from
      }

      state = enqueue_mutation(state, descriptor)
      {:noreply, continue_session_work(state)}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:mutate, _, _, _, _, _, _, _}, _from, state),
    do: {:reply, {:error, :owner_unavailable}, state}

  def handle_call(
        {:resume, origin_id, request_id, command_id, connection_incarnation, writer_epoch, worker,
         task_fun},
        from = {connection, _tag},
        %{phase: :active} = state
      ) do
    with :ok <-
           validate_resume(
             origin_id,
             request_id,
             command_id,
             connection,
             connection_incarnation,
             writer_epoch,
             worker,
             task_fun
           ) do
      descriptor = %{
        origin_id: origin_id,
        class: :session_resume,
        request_id: request_id,
        command_id: command_id,
        connection: connection,
        connection_incarnation: connection_incarnation,
        writer_epoch: writer_epoch,
        worker: worker,
        worker_monitor: Process.monitor(worker),
        task_fun: task_fun,
        from: from
      }

      eligibility =
        if resume_holder_gate?(state, descriptor, monotonic_ms()),
          do: :eligible,
          else: :ineligible

      case ConnectionRegistry.prepare_resume(
             state.registry,
             origin_id,
             state.session_id,
             command_id,
             state.owner_incarnation,
             eligibility
           ) do
        {:ok, {:waiting, _primary_origin_id}} ->
          Process.demonitor(descriptor.worker_monitor, [:flush])
          Logger.debug("loopex daemon queued resume joined primary")
          {:reply, {:ok, :admitted}, state}

        {:ok, preparation} when preparation in [:prepared, :unreserved] ->
          state = enqueue_mutation(state, descriptor)
          {:noreply, continue_session_work(state)}

        {:error, :activation_ceiling_reached} ->
          state = enqueue_mutation(state, descriptor)
          {:noreply, continue_session_work(state)}

        {:error, reason} ->
          Process.demonitor(descriptor.worker_monitor, [:flush])
          {:reply, {:error, reason}, state}
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:resume, _, _, _, _, _, _, _}, _from, state),
    do: {:reply, {:error, :owner_unavailable}, state}

  def handle_call(
        {:resolve_grant, grant_ref, :granted, granted_at},
        {caller, _tag},
        %{daemon_owner: caller, transition: %{kind: :grant, ref: grant_ref} = transition} = state
      )
      when is_integer(granted_at) do
    {:ok, state} = resolve_grant_transition(state, transition, :granted, granted_at)
    {:reply, :ok, state}
  end

  def handle_call(
        {:resolve_grant, grant_ref, :cancelled, nil},
        {caller, _tag},
        %{daemon_owner: caller, transition: %{kind: :grant, ref: grant_ref} = transition} = state
      ) do
    {:ok, state} = resolve_grant_transition(state, transition, :cancelled, nil)
    {:reply, :ok, state}
  end

  def handle_call({:resolve_grant, _, _, _}, _from, state),
    do: {:reply, {:error, :invalid_operation}, state}

  def handle_call(
        {:resolve_release, release_ref, disposition},
        {caller, _tag},
        %{
          daemon_owner: caller,
          transition: %{kind: :release, ref: release_ref, lease: lease}
        } = state
      )
      when disposition in [:released, :cancelled] do
    {:ok, state} = resolve_release_transition(state, lease, disposition)
    {:reply, :ok, state}
  end

  def handle_call({:resolve_release, _, _}, _from, state),
    do: {:reply, {:error, :invalid_operation}, state}

  def handle_call(
        {:resolve_expiry, expiry_ref},
        {caller, _tag},
        %{
          daemon_owner: caller,
          transition: %{kind: :expiry, ref: expiry_ref, lease: lease}
        } = state
      ) do
    {:ok, state} = resolve_expiry_transition(state, lease)
    {:reply, :ok, state}
  end

  def handle_call({:resolve_expiry, _}, _from, state),
    do: {:reply, {:error, :invalid_operation}, state}

  def handle_call(
        {:attachment, action, connection, connection_incarnation, attachment_id},
        {caller, _tag},
        %{daemon_owner: caller, phase: :active} = state
      )
      when action in [:opened, :closed] do
    if is_pid(connection) and valid_incarnation?(connection_incarnation) and
         is_binary(attachment_id) and byte_size(attachment_id) in 1..256 do
      key = {connection, connection_incarnation, attachment_id}

      attachments =
        case action do
          :opened -> MapSet.put(state.attachments, key)
          :closed -> MapSet.delete(state.attachments, key)
        end

      Logger.debug("loopex daemon lease attachment state changed")
      {:reply, :ok, %{state | attachments: attachments}}
    else
      {:reply, {:error, :invalid_operation}, state}
    end
  end

  def handle_call({:attachment, _, _, _, _}, _from, state),
    do: {:reply, {:error, :invalid_operation}, state}

  def handle_call(:status, _from, state) do
    {:reply,
     %{
       phase: public_phase(state),
       held: match?(%{status: :held}, state.lease),
       attachments: MapSet.size(state.attachments),
       in_flight: map_size(state.in_flight),
       queued_operations: length(state.pending_operations),
       waiting_acquires: length(state.waiters),
       lease_term_ms: state.lease_term_ms,
       retirement_requested: state.retirement_requested,
       first_acquire_available: state.first_acquire_available
     }, state}
  end

  @impl true
  def handle_cast(
        {:complete_retirement, caller, retirement_ref},
        %{
          daemon_owner: caller,
          phase: :retiring,
          retirement_ref: retirement_ref,
          retirement_exit_blocked: false
        } = state
      )
      when is_reference(retirement_ref) do
    if is_pid(state.retirement_exit_gate) do
      send(
        state.retirement_exit_gate,
        {:retirement_exit_blocked, self(), state.owner_incarnation, retirement_ref}
      )

      Logger.debug("loopex daemon lease owner retirement exit blocked")
      {:noreply, %{state | retirement_exit_blocked: true}}
    else
      Logger.debug("loopex daemon lease owner retirement acknowledged")
      {:stop, :normal, state}
    end
  end

  def handle_cast({:complete_retirement, _caller, _retirement_ref}, state) do
    Logger.debug("loopex daemon lease owner retirement acknowledgement ignored")
    {:noreply, state}
  end

  def handle_cast(
        {:release_retirement_exit, caller, retirement_ref},
        %{
          retirement_exit_gate: caller,
          phase: :retiring,
          retirement_ref: retirement_ref,
          retirement_exit_blocked: true
        } = state
      )
      when is_reference(retirement_ref) do
    Logger.debug("loopex daemon lease owner retirement exit released")
    {:stop, :normal, state}
  end

  def handle_cast({:release_retirement_exit, _caller, _retirement_ref}, state) do
    Logger.debug("loopex daemon lease owner retirement exit release ignored")
    {:noreply, state}
  end

  @impl true
  def handle_info(
        {:daemon_lease_resolution, operation_ref, daemon_owner, owner_incarnation, action,
         payload},
        %{daemon_owner: daemon_owner, owner_incarnation: owner_incarnation} = state
      )
      when is_reference(operation_ref) do
    {reply, state} = apply_daemon_resolution(state, action, payload)

    send(
      daemon_owner,
      {:lease_owner_resolution_ack, operation_ref, self(), owner_incarnation, action, reply}
    )

    {:noreply, state}
  end

  def handle_info(
        {:daemon_lease_resolution, _operation_ref, _daemon_owner, _owner_incarnation, _action,
         _payload},
        state
      ) do
    Logger.debug("loopex daemon lease owner resolution ignored")
    {:noreply, state}
  end

  def handle_info({:lease_expiry, token, deadline}, %{expiry_token: token} = state) do
    if monotonic_ms() >= deadline do
      state = %{state | expiry_timer: nil, expiry_token: nil}
      {:noreply, ensure_expiry_transition(state)}
    else
      {:noreply, schedule_expiry(state, deadline)}
    end
  end

  def handle_info({:lease_expiry, _token, _deadline}, state), do: {:noreply, state}

  def handle_info(
        {:relay_owner_idle, relay, owner_incarnation},
        %{
          relay: relay,
          owner_incarnation: owner_incarnation,
          phase: :active,
          retirement_requested: true
        } = state
      ) do
    {_reply, state} = begin_retirement(state)
    {:noreply, state}
  end

  def handle_info({:acquire_deadline, permit_id, deadline}, state) do
    case Enum.split_with(state.waiters, &(&1.permit_id == permit_id)) do
      {[waiter], remaining} ->
        state = %{state | waiters: remaining}
        state = cancel_waiter_timer(state, permit_id)

        if monotonic_ms() >= deadline do
          _result = complete_control_error(state, waiter, "control_pending")
          Logger.debug("loopex daemon lease acquire deadline reached")
          {:noreply, state}
        else
          {:noreply, queue_acquisition(state, waiter)}
        end

      _other ->
        {:noreply, state}
    end
  end

  def handle_info(
        {:lease_mutation_classified, task_ref, origin_id, disposition},
        state
      )
      when disposition in @mutation_dispositions do
    case Map.fetch(state.in_flight, origin_id) do
      {:ok, %{task_ref: ^task_ref, disposition: nil} = mutation} ->
        mutation = %{mutation | disposition: disposition}
        state = put_in(state, [:in_flight, origin_id], mutation)
        {:noreply, settle_mutation_if_ready(state, origin_id)}

      _other ->
        {:noreply, state}
    end
  end

  def handle_info(
        {:relay_lease_ticket_settled, relay, origin_id, owner_incarnation},
        %{relay: relay, owner_incarnation: owner_incarnation} = state
      ) do
    case Map.fetch(state.in_flight, origin_id) do
      {:ok, %{relay_settled: false} = mutation} ->
        mutation = %{mutation | relay_settled: true}
        state = put_in(state, [:in_flight, origin_id], mutation)
        {:noreply, settle_mutation_if_ready(state, origin_id)}

      _other ->
        {:noreply, state}
    end
  end

  def handle_info(
        {:registry_resume_settled, registry, origin_id, owner_incarnation, disposition},
        %{registry: registry, owner_incarnation: owner_incarnation} = state
      )
      when disposition in @mutation_dispositions do
    case Map.fetch(state.in_flight, origin_id) do
      {:ok, %{class: :session_resume, disposition: nil} = mutation} ->
        mutation = %{mutation | disposition: disposition, relay_settled: true}
        state = put_in(state, [:in_flight, origin_id], mutation)
        {:noreply, settle_mutation_if_ready(state, origin_id)}

      _other ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, monitor, :process, worker, _reason}, state) do
    case Enum.split_with(state.pending_operations, fn
           {:mutation, descriptor} -> descriptor.worker_monitor == monitor
           _operation -> false
         end) do
      {[{:mutation, %{worker: ^worker} = descriptor}], remaining} ->
        cancel_prepared_resume(state, descriptor)
        GenServer.reply(descriptor.from, {:error, :ticket_unavailable})
        Logger.debug("loopex daemon queued mutation worker lost")
        {:noreply, continue_session_work(%{state | pending_operations: remaining})}

      _other ->
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    cancel_expiry_timer(state)
    Enum.each(state.waiter_timers, fn {_permit_id, timer} -> cancel_timer(timer) end)

    Enum.each(state.pending_operations, fn
      {:mutation, descriptor} -> Process.demonitor(descriptor.worker_monitor, [:flush])
      {:release, _descriptor} -> :ok
    end)

    Logger.debug("loopex daemon lease owner stop")
    :ok
  end

  @impl GenServer
  def format_status(status) do
    status
    |> Map.put(:state, :redacted_lease_owner_state)
    |> Map.put(:message, :redacted_lease_owner_message)
    |> Map.put(:reason, :redacted_lease_owner_reason)
    |> Map.put(:log, [])
  end

  defp enqueue_mutation(state, descriptor) do
    update_in(state.pending_operations, &(&1 ++ [{:mutation, descriptor}]))
  end

  defp operation_blocked?(state) do
    not is_nil(state.transition) or map_size(state.in_flight) > 0 or
      state.pending_operations != []
  end

  defp continue_session_work(state) do
    cond do
      map_size(state.in_flight) > 0 ->
        state

      match?(%{kind: :expiry}, state.transition) and state.pending_operations != [] ->
        process_next_operation(state)

      not is_nil(state.transition) ->
        state

      state.pending_operations != [] ->
        process_next_operation(state)

      true ->
        state
        |> ensure_expiry_transition()
        |> process_waiters()
    end
  end

  defp begin_retirement(state) do
    if retirement_eligible?(state) do
      begin_eligible_retirement(state)
    else
      {{:error, :not_idle}, state}
    end
  end

  defp apply_daemon_resolution(
         %{transition: %{kind: :grant, ref: grant_ref} = transition} = state,
         :grant,
         {grant_ref, :granted, granted_at}
       )
       when is_integer(granted_at) do
    resolve_grant_transition(state, transition, :granted, granted_at)
  end

  defp apply_daemon_resolution(
         %{transition: %{kind: :grant, ref: grant_ref} = transition} = state,
         :grant,
         {grant_ref, :cancelled, nil}
       ) do
    resolve_grant_transition(state, transition, :cancelled, nil)
  end

  defp apply_daemon_resolution(
         %{transition: %{kind: :release, ref: release_ref, lease: lease}} = state,
         :release,
         {release_ref, disposition}
       )
       when disposition in [:released, :cancelled] do
    resolve_release_transition(state, lease, disposition)
  end

  defp apply_daemon_resolution(
         %{transition: %{kind: :expiry, ref: expiry_ref, lease: lease}} = state,
         :expiry,
         expiry_ref
       ) do
    resolve_expiry_transition(state, lease)
  end

  defp apply_daemon_resolution(state, _action, _payload),
    do: {{:error, :invalid_operation}, state}

  defp resolve_grant_transition(state, transition, :granted, granted_at) do
    deadline = granted_at + state.lease_term_ms

    lease = %{
      status: :held,
      holder_pid: transition.connection,
      holder_incarnation: transition.connection_incarnation,
      writer_epoch: transition.writer_epoch,
      granted_at: granted_at,
      deadline: deadline
    }

    state =
      state
      |> cancel_waiter_timer(transition.permit_id)
      |> Map.put(:lease, lease)
      |> Map.put(:transition, nil)
      |> schedule_expiry(deadline)
      |> continue_session_work()

    Logger.debug("loopex daemon lease grant committed")
    {:ok, state}
  end

  defp resolve_grant_transition(state, transition, :cancelled, nil) do
    state =
      state
      |> cancel_waiter_timer(transition.permit_id)
      |> Map.put(:lease, transition.previous_lease)
      |> Map.put(:transition, nil)
      |> continue_session_work()

    Logger.debug("loopex daemon lease grant cancelled")
    {:ok, state}
  end

  defp resolve_release_transition(state, lease, disposition) do
    state = %{state | transition: nil}

    state =
      case disposition do
        :released ->
          state
          |> cancel_expiry_timer()
          |> Map.put(:lease, %{lease | status: :released})

        :cancelled ->
          %{state | lease: lease}
      end

    state = continue_session_work(state)

    Logger.debug("loopex daemon lease release resolved")
    {:ok, state}
  end

  defp resolve_expiry_transition(state, lease) do
    state =
      state
      |> cancel_expiry_timer()
      |> Map.put(:lease, %{lease | status: :expired})
      |> Map.put(:transition, nil)
      |> continue_session_work()

    Logger.debug("loopex daemon lease expiry resolved")
    {:ok, state}
  end

  defp begin_eligible_retirement(state) do
    case AdmissionRelay.prepare_lease_owner_retirement(
           state.relay,
           state.session_id,
           state.owner_incarnation
         ) do
      :ok ->
        retirement_ref = make_ref()

        send(
          state.daemon_owner,
          {:lease_owner_retirement_intent, retirement_ref, self(), state.owner_incarnation,
           state.session_id}
        )

        Logger.debug("loopex daemon lease owner retirement proposed")

        {{:ok, :retiring},
         %{state | phase: :retiring, retirement_requested: true, retirement_ref: retirement_ref}}

      {:error, :owner_busy} ->
        {{:ok, :waiting}, %{state | retirement_requested: true}}

      {:error, :daemon_stopping} ->
        {{:error, :daemon_stopping}, state}

      {:error, _reason} ->
        {{:error, :owner_unavailable}, state}
    end
  end

  defp retirement_eligible?(state) do
    free? =
      state.lease == :free or
        match?(%{status: status} when status in [:released, :expired], state.lease)

    state.phase == :active and not state.first_acquire_available and free? and
      is_nil(state.transition) and state.waiters == [] and state.pending_operations == [] and
      map_size(state.in_flight) == 0
  end

  defp process_next_operation(
         %{pending_operations: [{:mutation, descriptor} | remaining]} = state
       ) do
    state = %{state | pending_operations: remaining}

    case promote_mutation(state, descriptor) do
      {:ok, state} ->
        state

      {:joined, state} ->
        continue_session_work(state)

      {:error, reason, state} ->
        GenServer.reply(descriptor.from, {:error, reason})
        continue_session_work(state)
    end
  end

  defp process_next_operation(%{pending_operations: [{:release, descriptor} | remaining]} = state) do
    state = %{state | pending_operations: remaining}
    {reply, state} = perform_release(state, descriptor)

    if match?({:error, _reason}, reply) do
      Logger.debug("loopex daemon queued lease release settlement unavailable")
    end

    continue_session_work(state)
  end

  defp perform_release(state, descriptor) do
    case release_gate(
           state,
           descriptor.connection,
           descriptor.connection_incarnation,
           descriptor.writer_epoch,
           monotonic_ms()
         ) do
      {:ok, lease} ->
        release_ref = make_ref()

        transition = %{
          kind: :release,
          ref: release_ref,
          permit_id: descriptor.permit_id,
          request_id: descriptor.request_id,
          lease: lease
        }

        send(
          state.daemon_owner,
          {:release_proposed, release_ref, descriptor.permit_id, self(), state.owner_incarnation,
           descriptor.connection_incarnation}
        )

        Logger.debug("loopex daemon lease release proposed")
        {{:ok, :proposed}, %{state | transition: transition}}

      :error ->
        result = WireRecords.control_error(descriptor.request_id, "control_not_held")

        case AdmissionRelay.complete_lease_permit(
               state.relay,
               descriptor.permit_id,
               state.owner_incarnation,
               result
             ) do
          :ok ->
            Logger.debug("loopex daemon lease release refused")
            {{:ok, :completed}, state}

          {:error, reason} ->
            {{:error, reason}, state}
        end
    end
  end

  defp promote_mutation(state, descriptor) do
    if descriptor.class == :session_resume,
      do: promote_resume_mutation(state, descriptor),
      else: promote_direct_mutation(state, descriptor)
  end

  defp promote_direct_mutation(state, descriptor) do
    now = monotonic_ms()

    {candidate_deadline, task_fun} =
      if mutation_gate?(state, descriptor, now) do
        {now + state.lease_term_ms, descriptor.task_fun}
      else
        result = WireRecords.control_error(descriptor.request_id, "control_not_held")
        {nil, fn -> {:refused, result} end}
      end

    task_ref = make_ref()
    owner = self()
    origin_id = descriptor.origin_id

    relay_task = fn ->
      case task_fun.() do
        {disposition, result}
        when disposition in @mutation_dispositions and is_map(result) ->
          send(owner, {:lease_mutation_classified, task_ref, origin_id, disposition})
          result

        _invalid ->
          exit(:invalid_mutation_result)
      end
    end

    case AdmissionRelay.promote_lease_ticket(
           state.relay,
           origin_id,
           state.owner_incarnation,
           relay_task
         ) do
      {:ok, ^origin_id} ->
        Process.demonitor(descriptor.worker_monitor, [:flush])

        mutation = %{
          class: descriptor.class,
          command_id: nil,
          task_ref: task_ref,
          holder_pid: descriptor.connection,
          holder_incarnation: descriptor.connection_incarnation,
          writer_epoch: descriptor.writer_epoch,
          candidate_deadline: candidate_deadline,
          disposition: nil,
          relay_settled: false
        }

        GenServer.reply(descriptor.from, {:ok, :admitted})
        Logger.debug("loopex daemon lease mutation admitted")
        {:ok, put_in(state, [:in_flight, origin_id], mutation)}

      {:error, reason} ->
        Process.demonitor(descriptor.worker_monitor, [:flush])
        {:error, reason, state}
    end
  end

  defp promote_resume_mutation(state, descriptor) do
    now = monotonic_ms()
    eligibility = if resume_holder_gate?(state, descriptor, now), do: :eligible, else: :ineligible
    attached = attached?(state, descriptor.connection, descriptor.connection_incarnation)
    candidate_deadline = if eligibility == :eligible, do: now + state.lease_term_ms
    control_refusal = WireRecords.request_error(descriptor.request_id, "control_not_held")

    capacity_refusal =
      WireRecords.request_error(descriptor.request_id, "activation_ceiling_reached")

    case ConnectionRegistry.promote_resume(
           state.registry,
           descriptor.origin_id,
           state.session_id,
           descriptor.command_id,
           state.owner_incarnation,
           eligibility,
           attached,
           control_refusal,
           capacity_refusal,
           descriptor.task_fun
         ) do
      {:ok, :admitted} ->
        Process.demonitor(descriptor.worker_monitor, [:flush])

        mutation = %{
          class: :session_resume,
          command_id: descriptor.command_id,
          task_ref: nil,
          holder_pid: descriptor.connection,
          holder_incarnation: descriptor.connection_incarnation,
          writer_epoch: descriptor.writer_epoch,
          candidate_deadline: candidate_deadline,
          disposition: nil,
          relay_settled: false
        }

        GenServer.reply(descriptor.from, {:ok, :admitted})
        Logger.debug("loopex daemon resume mutation admitted")
        {:ok, put_in(state, [:in_flight, descriptor.origin_id], mutation)}

      {:ok, {:waiting, _primary_origin_id}} ->
        Process.demonitor(descriptor.worker_monitor, [:flush])
        GenServer.reply(descriptor.from, {:ok, :admitted})
        Logger.debug("loopex daemon resume mutation joined")
        {:joined, state}

      {:ok, :completed} ->
        Process.demonitor(descriptor.worker_monitor, [:flush])
        GenServer.reply(descriptor.from, {:ok, :completed})
        Logger.debug("loopex daemon resume mutation refused")
        {:joined, state}

      {:error, reason} ->
        Process.demonitor(descriptor.worker_monitor, [:flush])
        {:error, reason, state}
    end
  end

  defp settle_mutation_if_ready(state, origin_id) do
    case Map.fetch(state.in_flight, origin_id) do
      {:ok, %{disposition: disposition, relay_settled: true} = mutation}
      when disposition in @mutation_dispositions ->
        state =
          if disposition in [:accepted, :admission_unknown] do
            commit_candidate_deadline(state, mutation)
          else
            state
          end

        state = update_in(state.in_flight, &Map.delete(&1, origin_id))
        Logger.debug("loopex daemon lease mutation settled")
        continue_session_work(state)

      _other ->
        state
    end
  end

  defp commit_candidate_deadline(
         %{lease: %{status: :held} = lease} = state,
         %{
           holder_pid: holder_pid,
           holder_incarnation: holder_incarnation,
           writer_epoch: writer_epoch,
           candidate_deadline: candidate_deadline
         }
       )
       when is_integer(candidate_deadline) do
    if lease.holder_pid == holder_pid and
         lease.holder_incarnation == holder_incarnation and
         lease.writer_epoch == writer_epoch do
      lease = %{lease | deadline: candidate_deadline}
      state |> Map.put(:lease, lease) |> schedule_expiry(candidate_deadline)
    else
      state
    end
  end

  defp commit_candidate_deadline(state, _mutation), do: state

  defp mutation_gate?(
         %{lease: %{status: :held} = lease} = state,
         descriptor,
         now
       ) do
    lease.holder_pid == descriptor.connection and
      lease.holder_incarnation == descriptor.connection_incarnation and
      lease.writer_epoch == descriptor.writer_epoch and
      now < lease.deadline and
      attached?(state, descriptor.connection, descriptor.connection_incarnation)
  end

  defp mutation_gate?(_state, _descriptor, _now), do: false

  defp resume_holder_gate?(
         %{lease: %{status: :held} = lease},
         descriptor,
         now
       ) do
    lease.holder_pid == descriptor.connection and
      lease.holder_incarnation == descriptor.connection_incarnation and
      lease.writer_epoch == descriptor.writer_epoch and
      now < lease.deadline
  end

  defp resume_holder_gate?(_state, _descriptor, _now), do: false

  defp cancel_prepared_resume(state, %{class: :session_resume, origin_id: origin_id}) do
    case ConnectionRegistry.cancel_prepared_resume(
           state.registry,
           origin_id,
           state.owner_incarnation
         ) do
      :ok -> :ok
      {:error, _reason} -> Logger.debug("loopex daemon prepared resume cleanup unavailable")
    end
  end

  defp cancel_prepared_resume(_state, _descriptor), do: :ok

  defp attached?(state, connection, connection_incarnation) do
    Enum.any?(state.attachments, fn
      {^connection, ^connection_incarnation, _attachment_id} -> true
      _other -> false
    end)
  end

  defp handle_acquisition(state, acquisition, now) do
    cond do
      now >= acquisition.request_deadline ->
        _result = complete_control_error(state, acquisition, "control_pending")
        {{:ok, :completed}, state}

      not is_nil(state.transition) ->
        {{:ok, :queued}, queue_acquisition(state, acquisition)}

      map_size(state.in_flight) > 0 and same_holder?(state.lease, acquisition) ->
        {{:ok, :queued}, queue_acquisition(state, acquisition)}

      match?(%{status: :held}, state.lease) and state.lease.deadline <= now ->
        state = state |> queue_acquisition(acquisition) |> ensure_expiry_transition()
        {{:ok, :queued}, state}

      same_holder?(state.lease, acquisition) ->
        renew(state, acquisition, now)

      match?(%{status: :held}, state.lease) ->
        _result = complete_control_error(state, acquisition, "control_held")
        {{:ok, :completed}, state}

      true ->
        {state, _grant_ref} = propose_grant(state, acquisition)
        {{:ok, :proposed}, state}
    end
  end

  defp renew(state, acquisition, admitted_at) do
    deadline = admitted_at + state.lease_term_ms
    expires_in_ms = max(deadline - monotonic_ms(), 0)

    result =
      WireRecords.control_acquired(
        acquisition.request_id,
        state.lease.writer_epoch,
        expires_in_ms,
        true
      )

    case AdmissionRelay.complete_lease_permit(
           state.relay,
           acquisition.permit_id,
           state.owner_incarnation,
           result
         ) do
      :ok ->
        lease = %{state.lease | deadline: deadline}
        state = state |> Map.put(:lease, lease) |> schedule_expiry(deadline)
        Logger.debug("loopex daemon lease renewed")
        {{:ok, :completed}, state}

      {:error, reason} ->
        {{:error, reason}, state}
    end
  end

  defp propose_grant(state, acquisition) do
    grant_ref = make_ref()
    writer_epoch = :crypto.strong_rand_bytes(16)

    transition = %{
      kind: :grant,
      ref: grant_ref,
      permit_id: acquisition.permit_id,
      request_id: acquisition.request_id,
      connection: acquisition.connection,
      connection_incarnation: acquisition.connection_incarnation,
      request_deadline: acquisition.request_deadline,
      writer_epoch: writer_epoch,
      actor: acquisition.actor,
      previous_lease: state.lease
    }

    send(
      state.daemon_owner,
      {:lease_grant_proposed, grant_ref, acquisition.permit_id, self(), state.owner_incarnation,
       state.session_id, acquisition.connection, acquisition.connection_incarnation, writer_epoch,
       acquisition.request_deadline}
    )

    Logger.debug("loopex daemon lease grant proposed")
    {%{state | transition: transition}, grant_ref}
  end

  defp queue_acquisition(state, acquisition) do
    remaining = max(acquisition.request_deadline - monotonic_ms(), 0)

    timer =
      Process.send_after(
        self(),
        {:acquire_deadline, acquisition.permit_id, acquisition.request_deadline},
        remaining
      )

    %{
      state
      | waiters: state.waiters ++ [acquisition],
        waiter_timers: Map.put(state.waiter_timers, acquisition.permit_id, timer)
    }
  end

  defp process_waiters(%{transition: transition} = state) when not is_nil(transition), do: state
  defp process_waiters(%{waiters: []} = state), do: state

  defp process_waiters(state) do
    [acquisition | remaining] = state.waiters
    state = %{state | waiters: remaining}
    state = cancel_waiter_timer(state, acquisition.permit_id)
    now = monotonic_ms()

    cond do
      now >= acquisition.request_deadline ->
        _result = complete_control_error(state, acquisition, "control_pending")
        process_waiters(state)

      match?(%{status: :held}, state.lease) and state.lease.deadline <= now ->
        state = %{state | waiters: [acquisition | state.waiters]}
        ensure_expiry_transition(state)

      same_holder?(state.lease, acquisition) ->
        {_reply, state} = renew(state, acquisition, acquisition.admitted_at)
        process_waiters(state)

      match?(%{status: :held}, state.lease) ->
        _result = complete_control_error(state, acquisition, "control_held")
        process_waiters(state)

      true ->
        {state, _grant_ref} = propose_grant(state, acquisition)
        state
    end
  end

  defp ensure_expiry_transition(%{transition: transition} = state) when not is_nil(transition),
    do: state

  defp ensure_expiry_transition(%{lease: %{status: :held} = lease} = state) do
    if monotonic_ms() >= lease.deadline and map_size(state.in_flight) == 0 and
         state.pending_operations == [] do
      expiry_ref = make_ref()

      transition = %{
        kind: :expiry,
        ref: expiry_ref,
        lease: lease
      }

      send(
        state.daemon_owner,
        {:lease_expiry_proposed, expiry_ref, self(), state.owner_incarnation, state.session_id,
         lease.holder_pid, lease.holder_incarnation, lease.writer_epoch}
      )

      Logger.debug("loopex daemon lease expiry proposed")
      %{state | transition: transition}
    else
      state
    end
  end

  defp ensure_expiry_transition(state), do: state

  defp release_gate(
         %{transition: nil, lease: %{status: :held} = lease},
         connection,
         connection_incarnation,
         writer_epoch,
         now
       ) do
    if lease.holder_pid == connection and
         lease.holder_incarnation == connection_incarnation and
         lease.writer_epoch == writer_epoch and now < lease.deadline,
       do: {:ok, lease},
       else: :error
  end

  defp release_gate(_state, _connection, _connection_incarnation, _writer_epoch, _now),
    do: :error

  defp same_holder?(%{status: :held} = lease, acquisition) do
    lease.holder_pid == acquisition.connection and
      lease.holder_incarnation == acquisition.connection_incarnation
  end

  defp same_holder?(_lease, _acquisition), do: false

  defp complete_control_error(state, acquisition, code) do
    result = WireRecords.control_error(acquisition.request_id, code)

    AdmissionRelay.complete_lease_permit(
      state.relay,
      acquisition.permit_id,
      state.owner_incarnation,
      result
    )
  end

  defp acquisition(
         permit_id,
         request_id,
         connection,
         connection_incarnation,
         request_deadline,
         admitted_at,
         actor
       ) do
    %{
      permit_id: permit_id,
      request_id: request_id,
      connection: connection,
      connection_incarnation: connection_incarnation,
      request_deadline: request_deadline,
      admitted_at: admitted_at,
      actor: actor
    }
  end

  defp validate_acquire(
         {incarnation, slot, sequence},
         request_id,
         connection,
         connection_incarnation,
         request_deadline,
         now
       )
       when incarnation == connection_incarnation and slot in 0..31 and sequence > 0 and
              is_binary(request_id) and byte_size(request_id) in 1..64 and is_pid(connection) and
              is_integer(request_deadline) and request_deadline > now,
       do: :ok

  defp validate_acquire(_, _, _, _, _, _), do: {:error, :invalid_operation}

  defp validate_release(
         {incarnation, slot, sequence},
         request_id,
         connection,
         connection_incarnation,
         writer_epoch
       )
       when incarnation == connection_incarnation and slot in 0..31 and sequence > 0 and
              is_binary(request_id) and byte_size(request_id) in 1..64 and is_pid(connection) and
              is_binary(writer_epoch) and byte_size(writer_epoch) in 1..64,
       do: :ok

  defp validate_release(_, _, _, _, _), do: {:error, :invalid_operation}

  defp validate_mutation(
         {incarnation, slot, sequence},
         class,
         request_id,
         connection,
         connection_incarnation,
         writer_epoch,
         worker,
         task_fun
       )
       when incarnation == connection_incarnation and slot in 0..31 and sequence > 0 and
              class in @direct_mutation_classes and is_binary(request_id) and
              byte_size(request_id) in 1..64 and is_pid(connection) and
              is_binary(writer_epoch) and byte_size(writer_epoch) in 1..64 and is_pid(worker) and
              worker != connection and is_function(task_fun, 0),
       do: :ok

  defp validate_mutation(_, _, _, _, _, _, _, _), do: {:error, :invalid_operation}

  defp validate_resume(
         {incarnation, slot, sequence},
         request_id,
         command_id,
         connection,
         connection_incarnation,
         writer_epoch,
         worker,
         task_fun
       )
       when incarnation == connection_incarnation and slot in 0..31 and sequence > 0 and
              is_binary(request_id) and byte_size(request_id) in 1..64 and
              is_binary(command_id) and byte_size(command_id) in 1..256 and is_pid(connection) and
              is_binary(writer_epoch) and byte_size(writer_epoch) in 1..64 and is_pid(worker) and
              worker != connection and is_function(task_fun, 0),
       do: :ok

  defp validate_resume(_, _, _, _, _, _, _, _), do: {:error, :invalid_operation}

  defp schedule_expiry(state, deadline) do
    state = cancel_expiry_timer(state)
    token = make_ref()
    remaining = max(deadline - monotonic_ms(), 0)
    timer = Process.send_after(self(), {:lease_expiry, token, deadline}, remaining)
    %{state | expiry_timer: timer, expiry_token: token}
  end

  defp cancel_expiry_timer(%{expiry_timer: timer} = state) do
    cancel_timer(timer)
    %{state | expiry_timer: nil, expiry_token: nil}
  end

  defp cancel_waiter_timer(state, permit_id) do
    case Map.pop(state.waiter_timers, permit_id) do
      {nil, _timers} ->
        state

      {timer, timers} ->
        cancel_timer(timer)
        %{state | waiter_timers: timers}
    end
  end

  defp cancel_timer(nil), do: :ok

  defp cancel_timer(timer) do
    _remaining = Process.cancel_timer(timer, async: false, info: false)
    :ok
  end

  defp public_phase(%{phase: :starting}), do: :starting
  defp public_phase(%{phase: :retiring}), do: :retiring
  defp public_phase(%{transition: %{kind: :grant}}), do: :grant_pending
  defp public_phase(%{transition: %{kind: :release}}), do: :release_pending
  defp public_phase(%{transition: %{kind: :expiry}}), do: :expiry_pending
  defp public_phase(%{lease: %{status: status}}), do: status
  defp public_phase(_state), do: :free

  defp valid_session?(session_id),
    do: is_binary(session_id) and byte_size(session_id) in 1..@max_session_bytes

  defp valid_incarnation?(incarnation),
    do: is_binary(incarnation) and byte_size(incarnation) == @incarnation_bytes

  defp valid_term?(term),
    do: is_integer(term) and term > 0 and term <= @max_timer_ms

  defp monotonic_ms, do: System.monotonic_time(:millisecond)
end
