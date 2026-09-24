defmodule LoopexDaemon.LeaseOwner do
  @moduledoc """
  ## Concept

  One process serializes controller authority for one daemon session. It keeps
  the lease outside durable session truth, grants at most one connection at a
  time, admits one controller mutation at a time through the complete holder
  gate, renews only the current holder, preserves wire order through explicit
  release, and makes takeover eligible on the daemon's monotonic clock. It
  never waits on another daemon component inside a handler, and it reports the
  relay's exact answer for every permit it handles to the daemon owner.

  ## Technical depth

  The owner begins parked. Its linked daemon owner registers the exact
  pid/incarnation in the admission relay and then sends `:activate` as a
  plain message. Every request from the daemon owner arrives as
  `{:lease_request, daemon_owner, owner_incarnation, request}`; resolutions
  and discards keep their ref-tagged messages. Existing-owner acquire and
  release operations compare-and-set their actor-bound relay permit before
  changing state. A first acquisition is already claimed by the daemon actor
  before this child is started. Holder-changing grants, expiry and release
  are proposals: this process exposes no epoch or state transition until the
  daemon owner acknowledges the corresponding routing-mirror settlement.

  Every relay or registry request is an OTP request message. At most one is
  awaited at a time; while it is, acquisitions, releases, resumes, waiter
  deadlines and retirement requests wait in arrival order, while resolutions,
  discards, attachments, activation and the expiry timer are processed at
  once. After each answer, and after a resolution or expiry while nothing is
  awaited, the owner drains its work in a fixed order: pending operations,
  the expiry check, one waiter, the expiry re-arm, then one deferred input. A
  relay request unanswered for five seconds is reported once to the daemon
  owner, which names the relay lost while serving; the registry's answers
  carry no deadline here because the registry bounds its own relay steps.

  For each permit it is asked to handle, the owner sends exactly one terminal
  message, after the relay's answer: its grant or release proposal, or
  `{:lease_permit_settled, permit_id, owner, owner_incarnation, kind}` with
  `kind` one of `:result`, `:connection_lost`, `:shutdown` or `:invalid`. A
  permit the daemon owner discarded while it was awaited sends nothing.

  A mutation records a candidate renewal at its gate instant. Only the joined
  relay settlement and core disposition commit that deadline, and only for an
  accepted or admission-unknown call; refusal discards it. Writer epochs are
  fresh 128-bit opaque values. Lease and request deadlines use monotonic
  milliseconds; timer messages only prompt a live deadline check. Process
  status is fully redacted and lifecycle logs contain no session, connection,
  epoch, request or permit data. Once the daemon requests retirement from a
  free idle owner, the owner waits for the relay's exact session rows to
  clear, marks its binding retiring there, sends a pre-exit intent to the
  daemon, and exits normally only after the daemon acknowledges that intent.
  """

  use GenServer
  require Logger

  alias LoopexDaemon.{AdmissionRelay, ConnectionRegistry, WireRecords}

  @lease_term_ms 30_000
  @max_timer_ms 4_294_967_295
  @incarnation_bytes 16
  @max_session_bytes 256

  # Concept: each relay request this owner sends has its own five-second
  # instant; it only prompts one report to the daemon owner.
  @relay_request_ms 5_000

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
  def start_link(options), do: GenServer.start_link(__MODULE__, options, timeout: 5_000)

  @doc """
  ## Concept

  Sends one daemon-owner request to this lease owner without waiting.

  ## Technical depth

  `request` is `:activate`, `:retire_if_idle`,
  `{:first_acquire, permit_id, request_id, connection, connection_incarnation,
  request_deadline}`, `{:acquire, …}` with the same fields,
  `{:release, permit_id, request_id, connection, connection_incarnation,
  writer_epoch}` or `{:attachment, ack_ref, :opened | :closed, connection,
  connection_incarnation, attachment_id}`. Only the daemon owner that started
  this owner, naming its exact incarnation, is heard. Each permit's answer
  arrives later as its proposal or its `lease_permit_settled` notice; an
  attachment with an `ack_ref` is acknowledged with `{:lease_attachment_ack,
  ack_ref, owner, owner_incarnation}`; `:retire_if_idle` is answered only by
  the retirement intent.
  """
  @spec request(pid(), binary(), term()) :: :ok
  def request(owner, owner_incarnation, request) do
    send(owner, {:lease_request, self(), owner_incarnation, request})
    :ok
  end

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

  @doc """
  ## Concept

  Asks the lease owner to drop an acquire or release whose connection was
  lost before it was decided, so no later decision is made for a row the
  daemon owner settles as a connection loss.

  ## Technical depth

  The owner answers `{:lease_owner_resolution_ack, operation_ref, owner,
  owner_incarnation, :discard, result}`. It looks, in order, at the permit its
  awaited relay step names, its deferred inputs, its waiters and pending
  operations — each answering `:discarded`, after which every relay answer
  for that permit is cleanup-only and no notice is sent — then at its
  transition, answering `:proposed`, since its proposal reached the daemon
  owner first by same-sender order; otherwise it answers `:absent`.
  """
  @spec request_discard(pid(), reference(), binary(), term()) :: :ok
  def request_discard(owner, operation_ref, owner_incarnation, permit_id) do
    send(
      owner,
      {:daemon_lease_resolution, operation_ref, self(), owner_incarnation, :discard, permit_id}
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

  @doc """
  ## Concept

  Sends one connection's mutation or resume descriptor without blocking the
  connection's socket loop while the lease owner serializes it.

  ## Technical depth

  The request originates from the calling connection, which the lease owner
  authenticates as the caller. The reply is collected through the returned
  `:gen_server` request-identifier collection labelled with the origin.
  """
  @spec send_descriptor(pid(), tuple(), term(), term()) :: term()
  def send_descriptor(owner, descriptor, label, collection)
      when elem(descriptor, 0) in [:mutate, :resume] do
    :gen_server.send_request(owner, descriptor, label, collection)
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
    attachments = Keyword.get(options, :attachments, MapSet.new())

    if is_struct(attachments, MapSet) and is_pid(daemon_owner) and is_pid(relay) and
         is_pid(registry) and valid_session?(session_id) and
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
         attachments: attachments,
         in_flight: %{},
         pending_operations: [],
         awaiting: nil,
         deferred: :queue.new(),
         discarded: MapSet.new()
       }}
    else
      {:stop, :invalid_lease_owner_options}
    end
  end

  @impl true
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
      {:noreply, drain(state)}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:mutate, _, _, _, _, _, _, _}, _from, state),
    do: {:reply, {:error, :owner_unavailable}, state}

  def handle_call(
        {:resume, origin_id, request_id, command_id, connection_incarnation, writer_epoch, worker,
         task_fun} = request,
        from = {connection, _tag},
        %{phase: :active} = state
      ) do
    case validate_resume(
           origin_id,
           request_id,
           command_id,
           connection,
           connection_incarnation,
           writer_epoch,
           worker,
           task_fun
         ) do
      :ok -> {:noreply, accept_input(state, {:resume_call, request, from})}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:resume, _, _, _, _, _, _, _}, _from, state),
    do: {:reply, {:error, :owner_unavailable}, state}

  def handle_call(:status, _from, state) do
    {:reply,
     %{
       phase: public_phase(state),
       held: match?(%{status: :held}, state.lease),
       attachments: MapSet.size(state.attachments),
       in_flight: map_size(state.in_flight),
       queued_operations: length(state.pending_operations),
       waiting_acquires: length(state.waiters),
       awaiting: not is_nil(state.awaiting),
       deferred: :queue.len(state.deferred),
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

  # Concept: the awaited relay or registry answer continues its step, and
  # the owner then drains whatever work that answer unblocked.
  @impl true
  def handle_info(
        {[:alias | request], _reply} = message,
        %{awaiting: %{request: request}} = state
      ),
      do: {:noreply, awaited_answer(state, message)}

  def handle_info(
        {:DOWN, request, :process, _server, _reason} = message,
        %{awaiting: %{request: request}} = state
      ),
      do: {:noreply, awaited_answer(state, message)}

  # Concept: a relay request still unanswered at its instant is reported once
  # to the daemon owner, which names the relay lost while serving; the
  # request stays awaited and the daemon's fail-stop ends it.
  def handle_info({:lease_request_unanswered, request}, %{awaiting: %{request: request}} = state) do
    send(state.daemon_owner, {:lease_owner_relay_unanswered, self(), state.owner_incarnation})
    Logger.debug("loopex daemon lease owner relay request unanswered")
    {:noreply, put_in(state, [:awaiting, :timer], nil)}
  end

  def handle_info({:lease_request_unanswered, _request}, state), do: {:noreply, state}

  def handle_info(
        {:lease_request, daemon_owner, owner_incarnation, request},
        %{daemon_owner: daemon_owner, owner_incarnation: owner_incarnation} = state
      ),
      do: {:noreply, accept_request(state, request)}

  def handle_info({:lease_request, _daemon_owner, _owner_incarnation, _request}, state) do
    Logger.debug("loopex daemon lease owner request ignored")
    {:noreply, state}
  end

  # Concept: a daemon resolution is applied and acknowledged before this
  # owner starts any further relay request, so the acknowledgement measures
  # only this owner's own work.
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

    {:noreply, drain(state)}
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
    state = %{state | expiry_timer: nil, expiry_token: nil}

    state =
      if monotonic_ms() >= deadline,
        do: state,
        else: schedule_expiry(state, deadline)

    {:noreply, drain(state)}
  end

  def handle_info({:lease_expiry, _token, _deadline}, state), do: {:noreply, state}

  def handle_info(
        {:relay_owner_idle, relay, owner_incarnation},
        %{relay: relay, owner_incarnation: owner_incarnation} = state
      ),
      do: {:noreply, accept_input(state, :relay_owner_idle)}

  def handle_info({:acquire_deadline, permit_id, deadline}, state),
    do: {:noreply, accept_input(state, {:acquire_deadline, permit_id, deadline})}

  def handle_info(
        {:lease_mutation_classified, task_ref, origin_id, disposition},
        state
      )
      when disposition in @mutation_dispositions do
    case Map.fetch(state.in_flight, origin_id) do
      {:ok, %{task_ref: ^task_ref, disposition: nil} = mutation} ->
        mutation = %{mutation | disposition: disposition}
        state = put_in(state, [:in_flight, origin_id], mutation)
        {:noreply, drain(settle_mutation_if_ready(state, origin_id))}

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
        {:noreply, drain(settle_mutation_if_ready(state, origin_id))}

      _other ->
        {:noreply, state}
    end
  end

  # Concept: a resume's slot is freed by the relay's own removal of its
  # ticket, never by the registry's answer alone; the registry's answer only
  # supplies the disposition.
  #
  # Technical depth: while serving, the registry sends this notice only after
  # the relay accepted the settlement, and the relay then sends
  # `relay_lease_ticket_settled`, so the slot always frees. The registry sends
  # it without a relay settlement only when the relay refuses the settlement
  # during the stop (`transport != :serving`), when it abandons the flow at
  # teardown, or when the relay has exited; while serving, a refused
  # settlement exits the registry instead (`connections_lost`). In each of
  # those cases the stop's own barriers bound this lease owner, which the
  # freeze or teardown kills, so the unsettled slot cannot outlive the stop.
  def handle_info(
        {:registry_resume_settled, registry, origin_id, owner_incarnation, disposition},
        %{registry: registry, owner_incarnation: owner_incarnation} = state
      )
      when disposition in @mutation_dispositions do
    case Map.fetch(state.in_flight, origin_id) do
      {:ok, %{class: :session_resume, disposition: nil} = mutation} ->
        # The relay's own removal of this ticket, not the registry's answer,
        # frees the session's mutation slot; `relay_settled` waits for it.
        mutation = %{mutation | disposition: disposition}
        state = put_in(state, [:in_flight, origin_id], mutation)
        {:noreply, drain(settle_mutation_if_ready(state, origin_id))}

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
        GenServer.reply(descriptor.from, {:error, :ticket_unavailable})
        Logger.debug("loopex daemon queued mutation worker lost")
        state = %{state | pending_operations: remaining}

        state =
          if descriptor.class == :session_resume,
            do: accept_input(state, {:cancel_prepared, descriptor.origin_id}),
            else: state

        {:noreply, drain(state)}

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

  # Concept: activation and attachments are processed at once in any phase;
  # every other daemon request waits behind an awaited relay step.
  defp accept_request(%{phase: :starting} = state, :activate) do
    Logger.debug("loopex daemon lease owner active")
    drain(%{state | phase: :active})
  end

  defp accept_request(state, :activate), do: state

  defp accept_request(
         state,
         {:attachment, ack_ref, action, connection, connection_incarnation, attachment_id}
       )
       when action in [:opened, :closed] do
    state =
      if is_pid(connection) and valid_incarnation?(connection_incarnation) and
           is_binary(attachment_id) and byte_size(attachment_id) in 1..256 do
        key = {connection, connection_incarnation, attachment_id}

        attachments =
          case action do
            :opened -> MapSet.put(state.attachments, key)
            :closed -> MapSet.delete(state.attachments, key)
          end

        Logger.debug("loopex daemon lease attachment state changed")
        %{state | attachments: attachments}
      else
        state
      end

    if is_reference(ack_ref) do
      send(
        state.daemon_owner,
        {:lease_attachment_ack, ack_ref, self(), state.owner_incarnation}
      )
    end

    state
  end

  defp accept_request(state, request), do: accept_input(state, request)

  # Concept: a deferrable input runs now only when no relay or registry step
  # is awaited; otherwise it waits its turn in arrival order.
  defp accept_input(%{awaiting: nil} = state, input), do: drain(handle_input(state, input))

  defp accept_input(state, input),
    do: %{state | deferred: :queue.in(input, state.deferred)}

  defp handle_input(
         %{phase: :active, first_acquire_available: true} = state,
         {:first_acquire, permit_id, request_id, connection, connection_incarnation,
          request_deadline}
       ) do
    with :ok <-
           validate_acquire(
             permit_id,
             request_id,
             connection,
             connection_incarnation,
             request_deadline
           ),
         true <- state.lease == :free and is_nil(state.transition) do
      acquisition =
        acquisition(
          permit_id,
          request_id,
          connection,
          connection_incarnation,
          request_deadline,
          monotonic_ms(),
          :daemon
        )

      state = %{state | first_acquire_available: false}
      {state, _grant_ref} = propose_grant(state, acquisition)
      state
    else
      _invalid -> notify_permit(state, permit_id, :invalid)
    end
  end

  defp handle_input(state, {:first_acquire, permit_id, _, _, _, _}),
    do: notify_permit(state, permit_id, :invalid)

  defp handle_input(
         %{phase: :active} = state,
         {:acquire, permit_id, request_id, connection, connection_incarnation, request_deadline}
       ) do
    case validate_acquire(
           permit_id,
           request_id,
           connection,
           connection_incarnation,
           request_deadline
         ) do
      :ok ->
        acquisition =
          acquisition(
            permit_id,
            request_id,
            connection,
            connection_incarnation,
            request_deadline,
            monotonic_ms(),
            :owner
          )

        request =
          AdmissionRelay.claim_lease_permit_request(
            state.relay,
            permit_id,
            state.owner_incarnation
          )

        await(state, :relay, request, {:claim_acquire, acquisition})

      {:error, _reason} ->
        notify_permit(state, permit_id, :invalid)
    end
  end

  defp handle_input(
         %{phase: :active} = state,
         {:release, permit_id, request_id, connection, connection_incarnation, writer_epoch}
       ) do
    case validate_release(permit_id, request_id, connection, connection_incarnation, writer_epoch) do
      :ok ->
        descriptor = %{
          permit_id: permit_id,
          request_id: request_id,
          connection: connection,
          connection_incarnation: connection_incarnation,
          writer_epoch: writer_epoch
        }

        request =
          AdmissionRelay.claim_lease_permit_request(
            state.relay,
            permit_id,
            state.owner_incarnation
          )

        await(state, :relay, request, {:claim_release, descriptor})

      {:error, _reason} ->
        notify_permit(state, permit_id, :invalid)
    end
  end

  # Concept: a request this owner cannot take in its current phase is still
  # answered: it claims the permit and completes it `internal_failure`
  # through the relay, so no permit is left undecided.
  defp handle_input(state, {kind, permit_id, request_id, _, _, _})
       when kind in [:acquire, :release] and is_binary(request_id) do
    request =
      AdmissionRelay.claim_lease_permit_request(state.relay, permit_id, state.owner_incarnation)

    await(state, :relay, request, {:claim_refuse, permit_id, request_id})
  end

  defp handle_input(state, {kind, permit_id, _, _, _, _}) when kind in [:acquire, :release],
    do: notify_permit(state, permit_id, :invalid)

  defp handle_input(%{phase: :active} = state, :retire_if_idle) do
    if retirement_eligible?(state),
      do: begin_retirement(%{state | retirement_requested: true}),
      else: state
  end

  defp handle_input(state, :retire_if_idle), do: state

  defp handle_input(
         %{phase: :active, retirement_requested: true} = state,
         :relay_owner_idle
       ),
       do: begin_retirement(state)

  defp handle_input(state, :relay_owner_idle), do: state

  defp handle_input(state, {:acquire_deadline, permit_id, deadline}) do
    case Enum.split_with(state.waiters, &(&1.permit_id == permit_id)) do
      {[waiter], remaining} ->
        state = cancel_waiter_timer(%{state | waiters: remaining}, permit_id)

        if monotonic_ms() >= deadline do
          Logger.debug("loopex daemon lease acquire deadline reached")
          complete_control_error(state, waiter, "control_pending")
        else
          queue_acquisition(state, waiter)
        end

      _other ->
        state
    end
  end

  defp handle_input(
         %{phase: :active} = state,
         {:resume_call,
          {:resume, origin_id, request_id, command_id, connection_incarnation, writer_epoch,
           worker, task_fun}, {connection, _tag} = from}
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

    request =
      ConnectionRegistry.prepare_resume_request(
        state.registry,
        origin_id,
        state.session_id,
        command_id,
        state.owner_incarnation,
        eligibility
      )

    await(state, :registry, request, {:prepare_resume, descriptor})
  end

  defp handle_input(state, {:resume_call, _request, from}) do
    GenServer.reply(from, {:error, :owner_unavailable})
    state
  end

  defp handle_input(state, {:cancel_prepared, origin_id}) do
    request =
      ConnectionRegistry.cancel_prepared_resume_request(
        state.registry,
        origin_id,
        state.owner_incarnation
      )

    await(state, :registry, request, :cancel_prepared)
  end

  # Concept: one relay or registry step is awaited at a time.
  #
  # Technical depth: a relay request has a five-second instant that only
  # prompts a report; a registry request has none.
  defp await(state, target, request, step) do
    timer =
      if target == :relay,
        do: Process.send_after(self(), {:lease_request_unanswered, request}, @relay_request_ms)

    %{state | awaiting: %{request: request, step: step, timer: timer}}
  end

  defp awaited_answer(state, message) do
    %{request: request, step: step, timer: timer} = state.awaiting
    if timer, do: cancel_timer(timer)
    state = %{state | awaiting: nil}

    response =
      case :gen_server.check_response(message, request) do
        {:reply, reply} -> {:reply, reply}
        _server_gone -> :down
      end

    state
    |> continue_step(step, response)
    |> drain()
  end

  # Concept: a permit the daemon owner discarded while its step was awaited
  # takes nothing from the relay's answer: no notice and no decision.
  defp continue_step(state, {kind, %{permit_id: permit_id}} = step, response)
       when kind in [:claim_acquire, :claim_release] do
    if MapSet.member?(state.discarded, permit_id),
      do: %{state | discarded: MapSet.delete(state.discarded, permit_id)},
      else: continue_claim(state, step, response)
  end

  defp continue_step(state, {:complete, permit_id, on_ok, result}, response) do
    fallback = WireRecords.request_error(result["request_id"], "internal_failure")

    cond do
      MapSet.member?(state.discarded, permit_id) ->
        %{state | discarded: MapSet.delete(state.discarded, permit_id)}

      response == {:reply, :ok} ->
        state
        |> apply_completion(on_ok)
        |> notify_permit(permit_id, :result)

      # Concept: a record the relay refuses as invalid never leaves the
      # client unanswered: the fixed internal-failure record replaces it once.
      response == {:reply, {:error, :invalid_result}} and result != fallback ->
        Logger.debug("loopex daemon lease result replaced after refusal")
        complete_permit(state, permit_id, fallback, nil)

      true ->
        notify_permit(state, permit_id, answer_kind(response))
    end
  end

  defp continue_step(state, {:promote_mutation, descriptor, _task_ref, _candidate}, response) do
    origin_id = descriptor.origin_id
    Process.demonitor(descriptor.worker_monitor, [:flush])

    case response do
      {:reply, {:ok, ^origin_id}} ->
        GenServer.reply(descriptor.from, {:ok, :admitted})
        Logger.debug("loopex daemon lease mutation admitted")
        admit_promoted(state, origin_id)

      {:reply, {:error, reason}} ->
        GenServer.reply(descriptor.from, {:error, reason})
        update_in(state.in_flight, &Map.delete(&1, origin_id))

      _relay_gone ->
        # The relay may have started the task before it was lost.
        GenServer.reply(descriptor.from, {:error, :promotion_outcome_unknown})
        update_in(state.in_flight, &Map.delete(&1, origin_id))
    end
  end

  defp continue_step(state, {:prepare_resume, descriptor}, response) do
    case response do
      {:reply, {:ok, {:waiting, _primary_origin_id}}} ->
        Process.demonitor(descriptor.worker_monitor, [:flush])
        GenServer.reply(descriptor.from, {:ok, :admitted})
        Logger.debug("loopex daemon queued resume joined primary")
        state

      {:reply, {:ok, preparation}} when preparation in [:prepared, :unreserved] ->
        enqueue_mutation(state, descriptor)

      {:reply, {:error, :activation_ceiling_reached}} ->
        enqueue_mutation(state, descriptor)

      {:reply, {:error, reason}} ->
        Process.demonitor(descriptor.worker_monitor, [:flush])
        GenServer.reply(descriptor.from, {:error, reason})
        state

      :down ->
        Process.demonitor(descriptor.worker_monitor, [:flush])
        GenServer.reply(descriptor.from, {:error, :registry_unavailable})
        state
    end
  end

  defp continue_step(state, {:promote_resume, descriptor, _candidate}, response) do
    Process.demonitor(descriptor.worker_monitor, [:flush])
    origin_id = descriptor.origin_id

    case response do
      {:reply, {:ok, :admitted}} ->
        GenServer.reply(descriptor.from, {:ok, :admitted})
        Logger.debug("loopex daemon resume mutation admitted")
        admit_promoted(state, origin_id)

      {:reply, {:ok, {:waiting, _primary_origin_id}}} ->
        GenServer.reply(descriptor.from, {:ok, :admitted})
        Logger.debug("loopex daemon resume mutation joined")
        update_in(state.in_flight, &Map.delete(&1, origin_id))

      {:reply, {:ok, :completed}} ->
        GenServer.reply(descriptor.from, {:ok, :completed})
        Logger.debug("loopex daemon resume mutation refused")
        update_in(state.in_flight, &Map.delete(&1, origin_id))

      {:reply, {:error, reason}} ->
        GenServer.reply(descriptor.from, {:error, reason})
        update_in(state.in_flight, &Map.delete(&1, origin_id))

      # Concept: the registry may have started the resume before it was
      # lost, so its outcome is unknown and no refusal is written.
      :down ->
        GenServer.reply(descriptor.from, {:error, :promotion_outcome_unknown})
        update_in(state.in_flight, &Map.delete(&1, origin_id))
    end
  end

  defp continue_step(state, :cancel_prepared, _response), do: state

  defp continue_step(state, {:claim_refuse, permit_id, request_id}, response) do
    cond do
      MapSet.member?(state.discarded, permit_id) ->
        %{state | discarded: MapSet.delete(state.discarded, permit_id)}

      response == {:reply, :ok} ->
        record = WireRecords.request_error(request_id, "internal_failure")
        complete_permit(state, permit_id, record, nil)

      true ->
        notify_permit(state, permit_id, answer_kind(response))
    end
  end

  defp continue_step(state, :prepare_retirement, response) do
    case response do
      {:reply, :ok} ->
        retirement_ref = make_ref()

        send(
          state.daemon_owner,
          {:lease_owner_retirement_intent, retirement_ref, self(), state.owner_incarnation,
           state.session_id}
        )

        Logger.debug("loopex daemon lease owner retirement proposed")
        %{state | phase: :retiring, retirement_requested: true, retirement_ref: retirement_ref}

      {:reply, {:error, :owner_busy}} ->
        %{state | retirement_requested: true}

      _unavailable ->
        state
    end
  end

  defp continue_claim(state, {:claim_acquire, acquisition}, {:reply, :ok}),
    do: handle_acquisition(state, acquisition, monotonic_ms())

  defp continue_claim(state, {:claim_release, descriptor}, {:reply, :ok}) do
    if operation_blocked?(state) do
      Logger.debug("loopex daemon lease release queued")
      update_in(state.pending_operations, &(&1 ++ [{:release, descriptor}]))
    else
      perform_release(state, descriptor)
    end
  end

  defp continue_claim(state, {_kind, %{permit_id: permit_id}}, response),
    do: notify_permit(state, permit_id, answer_kind(response))

  defp apply_completion(state, nil), do: state

  defp apply_completion(%{lease: %{status: :held} = lease} = state, {:renew, deadline}) do
    Logger.debug("loopex daemon lease renewed")
    state |> Map.put(:lease, %{lease | deadline: deadline}) |> schedule_expiry(deadline)
  end

  defp apply_completion(state, {:renew, _deadline}), do: state

  # Concept: the relay's answer for a permit is reported to the daemon owner
  # exactly as the relay gave it.
  defp answer_kind({:reply, :ok}), do: :result
  defp answer_kind({:reply, {:error, :connection_lost}}), do: :connection_lost
  defp answer_kind({:reply, {:error, :result}}), do: :result

  # Concept: a permit the relay already answered its client for — its worker
  # was lost, or its owner loss was classified — is settled as a result.
  defp answer_kind({:reply, {:error, reason}}) when reason in [:permit_unavailable, :owner_lost],
    do: :result

  defp answer_kind({:reply, {:error, reason}})
       when reason in [:daemon_stopping, :shutdown_admitted, :shutdown_cancelled],
       do: :shutdown

  defp answer_kind(:down), do: :shutdown
  defp answer_kind(_other), do: :invalid

  # Concept: exactly one terminal notice per permit, never for one the daemon
  # owner discarded while it was awaited.
  defp notify_permit(state, permit_id, kind) do
    if MapSet.member?(state.discarded, permit_id) do
      %{state | discarded: MapSet.delete(state.discarded, permit_id)}
    else
      send(
        state.daemon_owner,
        {:lease_permit_settled, permit_id, self(), state.owner_incarnation, kind}
      )

      state
    end
  end

  # Concept: work runs in one fixed order after each answer, resolution or
  # expiry, until a relay or registry step is awaited or nothing is left.
  #
  # Technical depth: pending operations run before the expiry check, one
  # waiter and the expiry re-arm, and a deferred input is taken only when none
  # of those can advance, so older admitted work is decided before a later
  # arrival. A proposal from a waiter ends the drain until it resolves.
  defp drain(%{awaiting: nil} = state) do
    case drain_step(state) do
      {:progress, state} -> drain(state)
      {:stop, state} -> state
    end
  end

  defp drain(state), do: state

  defp drain_step(state) do
    cond do
      pending_ready?(state) ->
        {:progress, process_next_operation(state)}

      expiry_due?(state) ->
        {:progress, ensure_expiry_transition(state)}

      waiters_ready?(state) ->
        process_one_waiter(state)

      rearm_needed?(state) ->
        {:progress, schedule_expiry(state, state.lease.deadline)}

      not :queue.is_empty(state.deferred) ->
        {{:value, input}, deferred} = :queue.out(state.deferred)
        {:progress, handle_input(%{state | deferred: deferred}, input)}

      true ->
        {:stop, state}
    end
  end

  defp pending_ready?(%{phase: :active, pending_operations: [_ | _]} = state) do
    map_size(state.in_flight) == 0 and
      (is_nil(state.transition) or match?(%{kind: :expiry}, state.transition))
  end

  defp pending_ready?(_state), do: false

  defp expiry_due?(%{phase: :active, transition: nil, lease: %{status: :held} = lease} = state),
    do:
      map_size(state.in_flight) == 0 and state.pending_operations == [] and
        monotonic_ms() >= lease.deadline

  defp expiry_due?(_state), do: false

  defp waiters_ready?(%{phase: :active, transition: nil, waiters: [_ | _]} = state),
    do: map_size(state.in_flight) == 0 and state.pending_operations == []

  defp waiters_ready?(_state), do: false

  defp rearm_needed?(%{lease: %{status: :held, deadline: deadline}, expiry_timer: nil}),
    do: deadline > monotonic_ms()

  defp rearm_needed?(_state), do: false

  defp enqueue_mutation(state, descriptor) do
    update_in(state.pending_operations, &(&1 ++ [{:mutation, descriptor}]))
  end

  defp operation_blocked?(state) do
    not is_nil(state.transition) or map_size(state.in_flight) > 0 or
      state.pending_operations != []
  end

  defp begin_retirement(state) do
    if retirement_eligible?(state) do
      request =
        AdmissionRelay.prepare_lease_owner_retirement_request(
          state.relay,
          state.session_id,
          state.owner_incarnation
        )

      await(state, :relay, request, :prepare_retirement)
    else
      state
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

  defp apply_daemon_resolution(state, :discard, permit_id) do
    cond do
      awaited_permit?(state, permit_id) ->
        Logger.debug("loopex daemon lease owner awaited operation discarded")
        {:discarded, %{state | discarded: MapSet.put(state.discarded, permit_id)}}

      deferred_permit?(state, permit_id) ->
        deferred =
          state.deferred
          |> :queue.to_list()
          |> Enum.reject(&input_permit?(&1, permit_id))
          |> :queue.from_list()

        Logger.debug("loopex daemon lease owner deferred operation discarded")
        {:discarded, %{state | deferred: deferred}}

      true ->
        discard_queued(state, permit_id)
    end
  end

  defp apply_daemon_resolution(state, _action, _payload),
    do: {{:error, :invalid_operation}, state}

  defp discard_queued(state, permit_id) do
    {waiters, kept_waiters} = Enum.split_with(state.waiters, &(&1.permit_id == permit_id))

    {releases, kept_operations} =
      Enum.split_with(state.pending_operations, fn
        {:release, descriptor} -> descriptor.permit_id == permit_id
        _operation -> false
      end)

    cond do
      waiters != [] or releases != [] ->
        state = %{state | waiters: kept_waiters, pending_operations: kept_operations}
        Logger.debug("loopex daemon lease owner queued operation discarded")
        {:discarded, cancel_waiter_timer(state, permit_id)}

      match?(%{permit_id: ^permit_id}, state.transition) ->
        {:proposed, state}

      true ->
        {:absent, state}
    end
  end

  defp awaited_permit?(%{awaiting: %{step: {kind, %{permit_id: permit_id}}}}, permit_id)
       when kind in [:claim_acquire, :claim_release],
       do: true

  defp awaited_permit?(%{awaiting: %{step: {:complete, permit_id, _on_ok, _result}}}, permit_id),
    do: true

  defp awaited_permit?(%{awaiting: %{step: {:claim_refuse, permit_id, _request_id}}}, permit_id),
    do: true

  defp awaited_permit?(_state, _permit_id), do: false

  defp deferred_permit?(state, permit_id),
    do: Enum.any?(:queue.to_list(state.deferred), &input_permit?(&1, permit_id))

  defp input_permit?({kind, permit_id, _, _, _, _}, permit_id)
       when kind in [:acquire, :release, :first_acquire],
       do: true

  defp input_permit?(_input, _permit_id), do: false

  # Technical depth: a resolution applies only its state change; the caller
  # acknowledges it and only then drains any further work.
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

    Logger.debug("loopex daemon lease grant committed")
    {:ok, state}
  end

  defp resolve_grant_transition(state, transition, :cancelled, nil) do
    state =
      state
      |> cancel_waiter_timer(transition.permit_id)
      |> Map.put(:lease, transition.previous_lease)
      |> Map.put(:transition, nil)

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

    Logger.debug("loopex daemon lease release resolved")
    {:ok, state}
  end

  defp resolve_expiry_transition(state, lease) do
    state =
      state
      |> cancel_expiry_timer()
      |> Map.put(:lease, %{lease | status: :expired})
      |> Map.put(:transition, nil)

    Logger.debug("loopex daemon lease expiry resolved")
    {:ok, state}
  end

  defp retirement_eligible?(state) do
    free? =
      state.lease == :free or
        match?(%{status: status} when status in [:released, :expired], state.lease)

    state.phase == :active and not state.first_acquire_available and free? and
      is_nil(state.transition) and state.waiters == [] and state.pending_operations == [] and
      map_size(state.in_flight) == 0 and is_nil(state.awaiting) and
      :queue.is_empty(state.deferred)
  end

  defp process_next_operation(
         %{pending_operations: [{:mutation, descriptor} | remaining]} = state
       ) do
    state = %{state | pending_operations: remaining}

    if descriptor.class == :session_resume,
      do: promote_resume_mutation(state, descriptor),
      else: promote_direct_mutation(state, descriptor)
  end

  defp process_next_operation(%{pending_operations: [{:release, descriptor} | remaining]} = state) do
    perform_release(%{state | pending_operations: remaining}, descriptor)
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
        %{state | transition: transition}

      :error ->
        Logger.debug("loopex daemon lease release refused")
        result = WireRecords.control_error(descriptor.request_id, "control_not_held")
        complete_permit(state, descriptor.permit_id, result, nil)
    end
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

    request =
      AdmissionRelay.promote_lease_ticket_request(
        state.relay,
        origin_id,
        state.owner_incarnation,
        relay_task
      )

    state
    |> put_in(
      [:in_flight, origin_id],
      promoting_mutation(descriptor, task_ref, candidate_deadline)
    )
    |> await(:relay, request, {:promote_mutation, descriptor, task_ref, candidate_deadline})
  end

  # Concept: a mutation is in flight from the moment its promotion is sent,
  # because its task's classification and the relay's settlement can arrive
  # before the promotion's answer; neither is lost, and nothing settles until
  # the answer admits it.
  #
  # Technical depth: `promoted` is false until the answer admits the
  # mutation; any other answer removes the entry.
  defp promoting_mutation(descriptor, task_ref, candidate_deadline) do
    %{
      class: descriptor.class,
      command_id: Map.get(descriptor, :command_id),
      task_ref: task_ref,
      holder_pid: descriptor.connection,
      holder_incarnation: descriptor.connection_incarnation,
      writer_epoch: descriptor.writer_epoch,
      candidate_deadline: candidate_deadline,
      disposition: nil,
      relay_settled: false,
      promoted: false
    }
  end

  defp admit_promoted(state, origin_id) do
    state
    |> put_in([:in_flight, origin_id, :promoted], true)
    |> settle_mutation_if_ready(origin_id)
  end

  defp promote_resume_mutation(state, descriptor) do
    now = monotonic_ms()
    eligibility = if resume_holder_gate?(state, descriptor, now), do: :eligible, else: :ineligible
    attached = attached?(state, descriptor.connection, descriptor.connection_incarnation)
    candidate_deadline = if eligibility == :eligible, do: now + state.lease_term_ms
    control_refusal = WireRecords.request_error(descriptor.request_id, "control_not_held")

    capacity_refusal =
      WireRecords.request_error(descriptor.request_id, "activation_ceiling_reached")

    request =
      ConnectionRegistry.promote_resume_request(
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
      )

    state
    |> put_in(
      [:in_flight, descriptor.origin_id],
      promoting_mutation(descriptor, nil, candidate_deadline)
    )
    |> await(:registry, request, {:promote_resume, descriptor, candidate_deadline})
  end

  defp settle_mutation_if_ready(state, origin_id) do
    case Map.fetch(state.in_flight, origin_id) do
      {:ok, %{disposition: disposition, relay_settled: true, promoted: true} = mutation}
      when disposition in @mutation_dispositions ->
        state =
          if disposition in [:accepted, :admission_unknown] do
            commit_candidate_deadline(state, mutation)
          else
            state
          end

        state = update_in(state.in_flight, &Map.delete(&1, origin_id))
        Logger.debug("loopex daemon lease mutation settled")
        state

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

  defp attached?(state, connection, connection_incarnation) do
    Enum.any?(state.attachments, fn
      {^connection, ^connection_incarnation, _attachment_id} -> true
      _other -> false
    end)
  end

  # Concept: an acquisition is decided once its permit is claimed; a refusal
  # or renewal this owner decides itself completes through the relay and is
  # reported with the relay's answer.
  defp handle_acquisition(state, acquisition, now) do
    cond do
      now >= acquisition.request_deadline ->
        complete_control_error(state, acquisition, "control_pending")

      not is_nil(state.transition) ->
        queue_acquisition(state, acquisition)

      map_size(state.in_flight) > 0 and same_holder?(state.lease, acquisition) ->
        queue_acquisition(state, acquisition)

      match?(%{status: :held}, state.lease) and state.lease.deadline <= now ->
        state |> queue_acquisition(acquisition) |> ensure_expiry_transition()

      same_holder?(state.lease, acquisition) ->
        renew(state, acquisition, now)

      match?(%{status: :held}, state.lease) ->
        complete_control_error(state, acquisition, "control_held")

      true ->
        {state, _grant_ref} = propose_grant(state, acquisition)
        state
    end
  end

  # Technical depth: one waiter advances per drain step; a refusal or renewal
  # becomes the awaited relay step, and a proposal ends the drain.
  defp process_one_waiter(state) do
    [acquisition | remaining] = state.waiters
    state = cancel_waiter_timer(%{state | waiters: remaining}, acquisition.permit_id)
    now = monotonic_ms()

    cond do
      now >= acquisition.request_deadline ->
        {:progress, complete_control_error(state, acquisition, "control_pending")}

      match?(%{status: :held}, state.lease) and state.lease.deadline <= now ->
        state = %{state | waiters: [acquisition | state.waiters]}
        {:progress, ensure_expiry_transition(state)}

      same_holder?(state.lease, acquisition) ->
        {:progress, renew(state, acquisition, acquisition.admitted_at)}

      match?(%{status: :held}, state.lease) ->
        {:progress, complete_control_error(state, acquisition, "control_held")}

      true ->
        {state, _grant_ref} = propose_grant(state, acquisition)
        {:stop, state}
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

    complete_permit(state, acquisition.permit_id, result, {:renew, deadline})
  end

  defp complete_control_error(state, acquisition, code) do
    result = WireRecords.control_error(acquisition.request_id, code)
    complete_permit(state, acquisition.permit_id, result, nil)
  end

  defp complete_permit(state, permit_id, result, on_ok) do
    request =
      AdmissionRelay.complete_lease_permit_request(
        state.relay,
        permit_id,
        state.owner_incarnation,
        result
      )

    await(state, :relay, request, {:complete, permit_id, on_ok, result})
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

  # Technical depth: an acquisition's deadline is not validated here: one
  # already past is still claimed and refused `control_pending` through the
  # relay, so its client hears the relay-rendered answer.
  defp validate_acquire(
         {incarnation, slot, sequence},
         request_id,
         connection,
         connection_incarnation,
         request_deadline
       )
       when incarnation == connection_incarnation and slot in 0..31 and sequence > 0 and
              is_binary(request_id) and byte_size(request_id) in 1..64 and is_pid(connection) and
              is_integer(request_deadline),
       do: :ok

  defp validate_acquire(_, _, _, _, _), do: {:error, :invalid_operation}

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
