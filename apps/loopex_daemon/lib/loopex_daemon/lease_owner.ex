defmodule LoopexDaemon.LeaseOwner do
  @moduledoc """
  ## Concept

  One process serializes controller authority for one daemon session. It keeps
  the lease outside durable session truth, grants at most one connection at a
  time, renews only the current holder, preserves an explicit release until its
  daemon-owned mirror settlement is known, and makes takeover eligible on the
  daemon's monotonic clock.

  ## Technical depth

  The owner begins parked. Its linked daemon owner first installs the exact
  pid/incarnation in the admission relay and then activates it. Existing-owner
  acquire and release operations compare-and-set their actor-bound relay permit
  before changing state. A first acquisition is already claimed by the daemon
  actor before this child is started. Holder-changing grants, expiry and release
  are proposals: this process exposes no epoch or state transition until the
  daemon owner acknowledges the corresponding routing-mirror settlement.

  Writer epochs are fresh 128-bit opaque values. Lease and request deadlines
  use monotonic milliseconds; timer messages only prompt a live deadline check.
  Process status is fully redacted and lifecycle logs contain no session,
  connection, epoch, request or permit data.
  """

  use GenServer
  require Logger

  alias LoopexDaemon.{AdmissionRelay, WireRecords}

  @lease_term_ms 30_000
  @max_timer_ms 4_294_967_295
  @incarnation_bytes 16
  @max_session_bytes 256

  @typedoc false
  @type permit_id :: AdmissionRelay.origin_id()

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options), do: GenServer.start_link(__MODULE__, options)

  @doc false
  @spec activate(pid()) :: :ok | {:error, :invalid_owner | :owner_unavailable}
  def activate(owner), do: GenServer.call(owner, :activate)

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
          {:ok, :completed | :proposed}
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
  @spec status(pid()) :: map()
  def status(owner), do: GenServer.call(owner, :status)

  @impl true
  def init(options) do
    daemon_owner = Keyword.fetch!(options, :daemon_owner)
    relay = Keyword.fetch!(options, :relay)
    session_id = Keyword.fetch!(options, :session_id)
    owner_incarnation = Keyword.fetch!(options, :owner_incarnation)
    lease_term_ms = Keyword.get(options, :lease_term_ms, @lease_term_ms)

    if is_pid(daemon_owner) and is_pid(relay) and valid_session?(session_id) and
         valid_incarnation?(owner_incarnation) and valid_term?(lease_term_ms) do
      Process.link(daemon_owner)
      Logger.debug("loopex daemon lease owner start")

      {:ok,
       %{
         daemon_owner: daemon_owner,
         relay: relay,
         session_id: session_id,
         owner_incarnation: owner_incarnation,
         lease_term_ms: lease_term_ms,
         phase: :starting,
         first_acquire_available: true,
         lease: :free,
         transition: nil,
         expiry_timer: nil,
         expiry_token: nil,
         waiters: [],
         waiter_timers: %{},
         attachments: MapSet.new(),
         in_flight: %{}
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
    now = monotonic_ms()

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
      case release_gate(state, connection, connection_incarnation, writer_epoch, now) do
        {:ok, lease} ->
          release_ref = make_ref()

          transition = %{
            kind: :release,
            ref: release_ref,
            permit_id: permit_id,
            request_id: request_id,
            lease: lease
          }

          send(
            state.daemon_owner,
            {:release_proposed, release_ref, permit_id, self(), state.owner_incarnation,
             connection_incarnation}
          )

          Logger.debug("loopex daemon lease release proposed")
          {:reply, {:ok, :proposed}, %{state | transition: transition}}

        :error ->
          result = WireRecords.control_error(request_id, "control_not_held")

          case AdmissionRelay.complete_lease_permit(
                 state.relay,
                 permit_id,
                 state.owner_incarnation,
                 result
               ) do
            :ok ->
              Logger.debug("loopex daemon lease release refused")
              {:reply, {:ok, :completed}, state}

            {:error, reason} ->
              {:reply, {:error, reason}, state}
          end
      end
    else
      {:error, :invalid_operation} -> {:reply, {:error, :invalid_operation}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:release, _, _, _, _, _}, _from, state),
    do: {:reply, {:error, :invalid_operation}, state}

  def handle_call(
        {:resolve_grant, grant_ref, :granted, granted_at},
        {caller, _tag},
        %{daemon_owner: caller, transition: %{kind: :grant, ref: grant_ref} = transition} = state
      )
      when is_integer(granted_at) do
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
      |> process_waiters()

    Logger.debug("loopex daemon lease grant committed")
    {:reply, :ok, state}
  end

  def handle_call(
        {:resolve_grant, grant_ref, :cancelled, nil},
        {caller, _tag},
        %{daemon_owner: caller, transition: %{kind: :grant, ref: grant_ref} = transition} = state
      ) do
    state =
      state
      |> cancel_waiter_timer(transition.permit_id)
      |> Map.put(:lease, transition.previous_lease)
      |> Map.put(:transition, nil)
      |> process_waiters()

    Logger.debug("loopex daemon lease grant cancelled")
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

    state = state |> ensure_expiry_transition() |> process_waiters()

    Logger.debug("loopex daemon lease release resolved")
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
    state =
      state
      |> cancel_expiry_timer()
      |> Map.put(:lease, %{lease | status: :expired})
      |> Map.put(:transition, nil)
      |> process_waiters()

    Logger.debug("loopex daemon lease expiry resolved")
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
       waiting_acquires: length(state.waiters),
       lease_term_ms: state.lease_term_ms,
       first_acquire_available: state.first_acquire_available
     }, state}
  end

  @impl true
  def handle_info({:lease_expiry, token, deadline}, %{expiry_token: token} = state) do
    if monotonic_ms() >= deadline do
      state = %{state | expiry_timer: nil, expiry_token: nil}
      {:noreply, ensure_expiry_transition(state)}
    else
      {:noreply, schedule_expiry(state, deadline)}
    end
  end

  def handle_info({:lease_expiry, _token, _deadline}, state), do: {:noreply, state}

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

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    cancel_expiry_timer(state)
    Enum.each(state.waiter_timers, fn {_permit_id, timer} -> cancel_timer(timer) end)
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

  defp handle_acquisition(state, acquisition, now) do
    cond do
      now >= acquisition.request_deadline ->
        _result = complete_control_error(state, acquisition, "control_pending")
        {{:ok, :completed}, state}

      not is_nil(state.transition) ->
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
    if monotonic_ms() >= lease.deadline and map_size(state.in_flight) == 0 do
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
