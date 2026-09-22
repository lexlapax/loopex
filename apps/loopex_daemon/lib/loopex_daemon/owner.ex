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
  Each holder-changing grant, release, or expiry is one retained operation with
  one absolute deadline. Registry, relay, and lease-owner steps use exact
  ref-tagged acknowledgements; stale replies are ignored. A missed mirror
  deadline kills the exact registry and stops the daemon owner with
  `:connections_lost`. Status and formatted state expose counts only, and every
  lifecycle log is fixed and identity-free.
  """

  use GenServer
  require Logger

  alias LoopexDaemon.{AdmissionRelay, ConnectionRegistry, LeaseOwner, WireRecords}

  @owner_limit 512
  @mirror_deadline_ms 5_000
  @lease_term_ms 30_000
  @incarnation_bytes 16

  @typedoc false
  @type origin_id :: AdmissionRelay.origin_id()

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options), do: GenServer.start_link(__MODULE__, options)

  @doc false
  @spec components(pid()) :: %{
          relay: pid(),
          registry: pid(),
          daemon_incarnation: binary(),
          routing_incarnation: binary()
        }
  def components(owner), do: GenServer.call(owner, :components)

  @doc false
  @spec acquire_control(
          pid(),
          origin_id(),
          binary(),
          binary(),
          pid(),
          binary(),
          pid(),
          binary(),
          integer()
        ) ::
          {:ok, :completed | :proposed | :queued, pid(), binary()}
          | {:error, atom()}
  def acquire_control(
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
    GenServer.call(
      owner,
      {:acquire_control, permit_id, request_id, session_id, connection, connection_incarnation,
       worker, worker_incarnation, request_deadline}
    )
  end

  @doc false
  @spec release_control(
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
        ) ::
          {:ok, :completed | :proposed | :queued, pid(), binary()}
          | {:error, atom()}
  def release_control(
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
    GenServer.call(
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
  reference. Both answers are bounded by the relay control timeout.
  """
  @spec cut_admission(pid(), timeout()) :: {:ok, reference()} | {:error, atom()}
  def cut_admission(owner, timeout \\ 15_000) do
    GenServer.call(owner, :cut_admission, timeout)
  catch
    :exit, _timeout -> {:error, :relay_barrier_timeout}
  end

  @doc false
  @spec reap_uninitialized(pid(), reference()) :: :ok | {:error, atom()}
  def reap_uninitialized(owner, cut_ref),
    do: GenServer.call(owner, {:reap_uninitialized, cut_ref}, 15_000)

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

  @doc false
  @spec close_connections(pid(), map(), integer()) :: :ok | {:ok, :forced} | {:error, atom()}
  def close_connections(owner, record, deadline),
    do: GenServer.call(owner, {:close_connections, record, deadline}, :infinity)

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

  def handle_call(
        {:acquire_control, permit_id, request_id, session_id, connection, connection_incarnation,
         worker, worker_incarnation, request_deadline},
        _from,
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

    dispatch_acquire(state, requested)
  end

  def handle_call(
        {:release_control, permit_id, request_id, session_id, connection, connection_incarnation,
         worker, worker_incarnation, writer_epoch, request_deadline},
        _from,
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

    dispatch_release(state, requested)
  end

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
        state = put_in(state, [:mirror_operations, operation_ref, :step], :pop_owner)
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
    barrier = %{ref: ref, name: barrier_name(kind), from: from, timer: timer}
    {:noreply, put_in(state, [:stop, :barrier], barrier)}
  end

  def handle_call({:relay_barrier, _kind, _deadline}, _from, state),
    do: {:reply, {:error, :relay_barrier_unavailable}, state}

  def handle_call(:cut_admission, from, %{stop: nil} = state) do
    cut_ref = make_ref()
    send(state.relay, {:relay_barrier, cut_ref, :cut})
    Logger.debug("loopex daemon owner admission cut requested")
    {:noreply, %{state | stop: %{phase: :cutting, cut_ref: cut_ref, from: from, swept: false}}}
  end

  def handle_call(:cut_admission, _from, %{stop: %{cut_ref: cut_ref}} = state),
    do: {:reply, {:ok, cut_ref}, state}

  def handle_call({:reap_uninitialized, cut_ref}, from, %{stop: %{cut_ref: cut_ref}} = stop_state) do
    request = ConnectionRegistry.reap_uninitialized(stop_state.registry, cut_ref)

    case :gen_server.receive_response(request, 5_000) do
      {:reply, :ok} ->
        if stop_state.stop.swept,
          do: {:reply, :ok, stop_state},
          else: {:noreply, put_in(stop_state, [:stop, :from], from)}

      _other ->
        {:reply, {:error, :transport_sweep_failed}, stop_state}
    end
  end

  def handle_call({:reap_uninitialized, _cut_ref}, _from, state),
    do: {:reply, {:error, :transport_cut_unavailable}, state}

  def handle_call({:close_connections, record, deadline}, _from, state) do
    result = ConnectionRegistry.close_all(state.registry, record, deadline)
    {:reply, result, state}
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
        {:noreply, state}

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
              discard_claimed_owner_operations(state, owner, owner_incarnation, origins)
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

    case Map.get(state.owners, session_id) do
      %{phase: :live, pid: owner} ->
        _result =
          lease_owner_call(fn ->
            case action do
              :opened ->
                LeaseOwner.attachment_opened(
                  owner,
                  connection,
                  connection_incarnation,
                  attachment_id
                )

              :closed ->
                LeaseOwner.attachment_closed(
                  owner,
                  connection,
                  connection_incarnation,
                  attachment_id
                )
            end
          end)

      _other ->
        :ok
    end

    if is_reference(record_ref),
      do: send(registry, {:owner_attachment_recorded, self(), record_ref})

    Logger.debug("loopex daemon session attachment recorded")
    {:noreply, %{state | attachments: attachments}}
  end

  def handle_info(
        {:relay_barrier_ack, cut_ref, :cut, _payload},
        %{stop: %{phase: :cutting, cut_ref: cut_ref, from: from}} = state
      ) do
    reply =
      case :gen_server.receive_response(
             ConnectionRegistry.transport_closing(state.registry, cut_ref),
             5_000
           ) do
        {:reply, {:ok, ^cut_ref}} -> {:ok, cut_ref}
        _other -> {:error, :transport_gate_failed}
      end

    GenServer.reply(from, reply)
    Logger.debug("loopex daemon owner admission cut complete")
    {:noreply, %{state | stop: %{state.stop | phase: :cut, from: nil}}}
  end

  def handle_info(
        {:relay_barrier_ack, ref, name, payload},
        %{stop: %{barrier: %{ref: ref, name: name, from: from, timer: timer}}} = state
      )
      when name != :cut do
    Process.cancel_timer(timer)
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
    if state.stop.from, do: GenServer.reply(state.stop.from, :ok)
    {:noreply, %{state | stop: %{state.stop | swept: true, from: nil}}}
  end

  def handle_info({:mirror_deadline, operation_ref, deadline}, state) do
    case Map.get(state.mirror_operations, operation_ref) do
      %{deadline: ^deadline} ->
        if monotonic_ms() >= deadline do
          fail_connections(state)
        else
          timer =
            Process.send_after(
              self(),
              {:mirror_deadline, operation_ref, deadline},
              max(deadline - monotonic_ms(), 0)
            )

          {:noreply, put_in(state, [:mirror_operations, operation_ref, :timer], timer)}
        end

      _other ->
        {:noreply, state}
    end
  end

  def handle_info({:EXIT, registry, _reason}, %{registry: registry} = state),
    do: {:stop, :connections_lost, state}

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
            start_retirement_pop(state, session_id, row)

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
            continue_lost_owner_exit(state, session_id, row)
        end

      :error ->
        {:stop, :unexpected_linked_exit, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

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
      started_at: System.monotonic_time(:millisecond)
    }

    registry_options = [owner: self(), connection_context: context]

    registry_options =
      case Keyword.fetch(options, :connection_module) do
        {:ok, module} -> Keyword.put(registry_options, :connection_module, module)
        :error -> registry_options
      end

    ConnectionRegistry.start_link(registry_options)
  end

  defp install_session_owner(state, session_id) do
    cond do
      not valid_session?(session_id) ->
        {:error, :invalid_session}

      Map.has_key?(state.owners, session_id) ->
        {:error, :owner_conflict}

      owner_slot_count(state) >= @owner_limit ->
        {:error, :control_capacity_reached}

      true ->
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
            case AdmissionRelay.register_lease_owner(
                   state.relay,
                   session_id,
                   owner,
                   owner_incarnation
                 ) do
              :ok ->
                row = owner_row(owner, owner_incarnation)

                state =
                  state
                  |> put_in([:owners, session_id], row)
                  |> put_in([:owner_pids, owner], session_id)

                activate_installed_owner(owner)
                Logger.debug("loopex daemon lease owner installed")
                {:ok, state, row}

              _error ->
                discard_unregistered_owner(owner)
                {:error, :owner_conflict}
            end

          _error ->
            {:error, :owner_conflict}
        end
    end
  end

  defp dispatch_acquire(state, request) do
    case Map.fetch(state.operations, request.permit_id) do
      {:ok, %{request: ^request, phase: phase}}
      when phase in [:waiting_owner, :settling, :abandoned] ->
        {:reply, {:ok, :queued, self(), state.daemon_incarnation}, state}

      {:ok, %{request: ^request, owner_pid: pid, owner_incarnation: owner_incarnation}} ->
        {:reply, {:ok, :completed, pid, owner_incarnation}, state}

      {:ok, _other} ->
        {:reply, {:error, :permit_conflict}, state}

      :error ->
        case Map.get(state.owners, request.session_id) do
          %{phase: :live} = owner_row ->
            dispatch_existing_acquire(state, request, owner_row)

          %{phase: phase} = owner_row
          when phase in [:retirement_pending, :retiring, :starting_waiting_pop, :lost] ->
            dispatch_waiting_owner_acquire(state, request, owner_row)

          nil ->
            dispatch_first_acquire(state, request)

          _other ->
            {:reply, {:error, :owner_unavailable}, state}
        end
    end
  end

  defp dispatch_waiting_owner_acquire(state, request, owner_row) do
    cond do
      not is_nil(owner_row.successor) ->
        {:reply, {:error, :owner_unavailable}, state}

      not owner_row.slot_charged and owner_slot_count(state) >= @owner_limit ->
        {:reply, {:error, :control_capacity_reached}, state}

      true ->
        permit_id = request.permit_id
        start_op_ref = make_ref()

        with true <- valid_request?(request),
             {:ok, ^permit_id} <-
               AdmissionRelay.open_lease_permit(
                 state.relay,
                 request.connection,
                 permit_id,
                 request.class,
                 request.session_id,
                 self(),
                 state.daemon_incarnation,
                 request.worker,
                 request.worker_incarnation,
                 start_op_ref
               ),
             :ok <-
               AdmissionRelay.claim_lease_permit(
                 state.relay,
                 permit_id,
                 state.daemon_incarnation,
                 start_op_ref
               ) do
          operation = %{
            request: request,
            owner_pid: nil,
            owner_incarnation: nil,
            actor_pid: self(),
            actor_incarnation: state.daemon_incarnation,
            start_op_ref: start_op_ref,
            phase: :waiting_owner
          }

          phase =
            if owner_row.exit_consumed and owner_row.phase != :lost,
              do: :starting_waiting_pop,
              else: owner_row.phase

          owner_row = %{owner_row | phase: phase, slot_charged: true, successor: permit_id}

          state =
            state
            |> put_in([:owners, request.session_id], owner_row)
            |> put_in([:operations, permit_id], operation)

          Logger.debug("loopex daemon successor owner start retained")
          {:reply, {:ok, :queued, self(), state.daemon_incarnation}, state}
        else
          false -> {:reply, {:error, :invalid_operation}, state}
          {:error, reason} -> {:reply, {:error, reason}, state}
        end
    end
  end

  defp dispatch_first_acquire(state, request) do
    if owner_slot_count(state) >= @owner_limit do
      {:reply, {:error, :control_capacity_reached}, state}
    else
      open_first_acquire(state, request)
    end
  end

  defp open_first_acquire(state, request) do
    permit_id = request.permit_id
    start_op_ref = make_ref()

    with true <- valid_request?(request),
         {:ok, ^permit_id} <-
           AdmissionRelay.open_lease_permit(
             state.relay,
             request.connection,
             permit_id,
             request.class,
             request.session_id,
             self(),
             state.daemon_incarnation,
             request.worker,
             request.worker_incarnation,
             start_op_ref
           ),
         :ok <-
           AdmissionRelay.claim_lease_permit(
             state.relay,
             permit_id,
             state.daemon_incarnation,
             start_op_ref
           ),
         {:ok, state, owner_row} <- install_session_owner(state, request.session_id),
         operation =
           lease_operation(
             request,
             owner_row,
             self(),
             state.daemon_incarnation,
             start_op_ref
           ),
         state = put_in(state, [:operations, permit_id], operation),
         {:ok, disposition} <-
           first_acquire(owner_row.pid, request) do
      {:reply, {:ok, disposition, owner_row.pid, owner_row.incarnation}, state}
    else
      false -> {:reply, {:error, :invalid_operation}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  # Concept: a child that dies before it answers still owns the retained
  # acquire. Technical depth: the caller learns the result through the relay;
  # the child's linked `EXIT` either follows its proposal or proves none came.
  defp first_acquire(owner, request) do
    case lease_owner_call(fn ->
           LeaseOwner.first_acquire(
             owner,
             request.permit_id,
             request.request_id,
             request.connection,
             request.connection_incarnation,
             request.request_deadline
           )
         end) do
      {:error, :owner_down} -> {:ok, :queued}
      result -> result
    end
  end

  defp dispatch_existing_acquire(state, request, owner_row) do
    with {:ok, state, operation} <- open_existing_permit(state, request, owner_row),
         {:ok, disposition} <-
           existing_owner_call(fn ->
             LeaseOwner.acquire(
               owner_row.pid,
               request.permit_id,
               request.request_id,
               request.connection,
               request.connection_incarnation,
               request.request_deadline
             )
           end) do
      state = maybe_complete_direct_operation(state, request.permit_id, disposition)
      {:reply, {:ok, disposition, operation.owner_pid, operation.owner_incarnation}, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp dispatch_release(state, request) do
    case Map.fetch(state.operations, request.permit_id) do
      {:ok, %{request: ^request, owner_pid: pid, owner_incarnation: owner_incarnation}} ->
        {:reply, {:ok, :completed, pid, owner_incarnation}, state}

      {:ok, _other} ->
        {:reply, {:error, :permit_conflict}, state}

      :error ->
        with {:ok, owner_row} <- live_owner(state, request.session_id),
             {:ok, state, operation} <- open_existing_permit(state, request, owner_row),
             {:ok, disposition} <-
               existing_owner_call(fn ->
                 LeaseOwner.release(
                   owner_row.pid,
                   request.permit_id,
                   request.request_id,
                   request.connection,
                   request.connection_incarnation,
                   request.writer_epoch
                 )
               end) do
          state = maybe_complete_direct_operation(state, request.permit_id, disposition)
          {:reply, {:ok, disposition, operation.owner_pid, operation.owner_incarnation}, state}
        else
          {:error, reason} -> {:reply, {:error, reason}, state}
        end
    end
  end

  defp open_existing_permit(state, request, owner_row) do
    permit_id = request.permit_id

    with true <- valid_request?(request),
         {:ok, ^permit_id} <-
           AdmissionRelay.open_lease_permit(
             state.relay,
             request.connection,
             permit_id,
             request.class,
             request.session_id,
             owner_row.pid,
             owner_row.incarnation,
             request.worker,
             request.worker_incarnation
           ) do
      operation = lease_operation(request, owner_row, owner_row.pid, owner_row.incarnation)
      {:ok, put_in(state, [:operations, permit_id], operation), operation}
    else
      false -> {:error, :invalid_operation}
      {:error, reason} -> {:error, reason}
    end
  end

  # Concept: an existing owner's permit names that owner as its actor, so the
  # relay claims it when the owner dies. Technical depth: a call that observes
  # the death answers `:queued`; the relay's owner-loss refusal is the result.
  defp existing_owner_call(fun) do
    case lease_owner_call(fun) do
      {:error, :owner_down} -> {:ok, :queued}
      result -> result
    end
  end

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
    deadline = monotonic_ms() + state.mirror_deadline_ms
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
      deadline: deadline,
      timer: schedule_deadline(operation_ref, deadline),
      loss_ref: if(pending_loss, do: pending_loss.settlement_ref, else: nil)
    }

    state =
      state
      |> put_in([:operations, operation.request.permit_id, :phase], :settling)
      |> put_in([:mirror_operations, operation_ref], mirror_operation)
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

        deadline = monotonic_ms() + state.mirror_deadline_ms
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
          deadline: deadline,
          timer: schedule_deadline(operation_ref, deadline),
          loss_ref: if(pending_loss, do: pending_loss.settlement_ref, else: nil)
        }

        state =
          state
          |> put_in([:operations, operation.request.permit_id, :phase], :settling)
          |> put_in([:mirror_operations, operation_ref], mirror_operation)
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
    deadline = monotonic_ms() + state.mirror_deadline_ms

    mirror_operation = %{
      kind: :expiry,
      step: :clear,
      permit_id: nil,
      owner_pid: route.owner_pid,
      owner_incarnation: route.owner_incarnation,
      transition_ref: expiry_ref,
      row: route,
      deadline: deadline,
      timer: schedule_deadline(operation_ref, deadline),
      loss_ref: nil
    }

    state = put_in(state, [:mirror_operations, operation_ref], mirror_operation)

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
    deadline = monotonic_ms() + state.mirror_deadline_ms

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
      },
      deadline: deadline,
      timer: schedule_deadline(operation_ref, deadline)
    }

    state = put_in(state, [:mirror_operations, operation_ref], operation)

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

  defp start_owner_loss_pop(state, session_id, predecessor) do
    operation_ref = make_ref()
    classification_ref = make_ref()
    deadline = monotonic_ms() + state.mirror_deadline_ms

    operation = %{
      kind: :owner_loss,
      step: :pop_owner,
      permit_id: nil,
      owner_pid: predecessor.pid,
      owner_incarnation: predecessor.incarnation,
      classification_ref: classification_ref,
      close_ref: nil,
      holder: nil,
      row: %{
        session_id: session_id,
        owner_pid: predecessor.pid,
        owner_incarnation: predecessor.incarnation
      },
      deadline: deadline,
      timer: schedule_deadline(operation_ref, deadline)
    }

    state =
      state
      |> put_in([:mirror_operations, operation_ref], operation)
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
        discard_claimed_owner_operations(
          state,
          predecessor.pid,
          predecessor.incarnation,
          predecessor.loss_origins
        )
      else
        state
      end

    case refuse_unproposed_grants(state, predecessor.pid, predecessor.incarnation) do
      {:ok, state} -> continue_lost_owner_operation(state, session_id, predecessor)
      :error -> {:stop, :relay_lost, state}
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
      |> put_in([:mirror_operations, operation_ref, :step], :settle_result_after_owner_loss)

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
    |> Enum.sort_by(fn {_operation_ref, operation} -> operation.deadline end)
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
    |> Enum.reduce_while({:ok, state}, fn {permit_id, operation}, {:ok, acc} ->
      case refuse_unproposed_grant(acc, permit_id, operation) do
        {:ok, acc} -> {:cont, {:ok, acc}}
        :error -> {:halt, :error}
      end
    end)
  end

  defp refuse_unproposed_grant(state, permit_id, operation) do
    case Map.fetch(state.pending_dispositions, permit_id) do
      {:ok, loss} ->
        state = update_in(state.pending_dispositions, &Map.delete(&1, permit_id))
        {:noreply, state} = start_waiting_owner_loss_settlement(state, permit_id, operation, loss)
        {:ok, state}

      :error ->
        result = WireRecords.control_error(operation.request.request_id, "control_pending")

        case AdmissionRelay.complete_lease_permit(
               state.relay,
               permit_id,
               state.daemon_incarnation,
               result
             ) do
          :ok ->
            Logger.debug("loopex daemon unproposed lease grant refused")
            {:ok, update_in(state.operations, &Map.delete(&1, permit_id))}

          {:error, :connection_lost} ->
            {:ok, put_in(state, [:operations, permit_id, :phase], :abandoned)}

          {:error, _reason} ->
            :error
        end
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

  defp discard_claimed_owner_operations(state, owner, owner_incarnation, origins) do
    claimed = MapSet.new(origins)
    mirrored = mirrored_permits(state)

    operations =
      Enum.reduce(state.operations, state.operations, fn {permit_id, operation}, acc ->
        if operation.owner_pid == owner and operation.owner_incarnation == owner_incarnation and
             MapSet.member?(claimed, permit_id) and not MapSet.member?(mirrored, permit_id) do
          Map.delete(acc, permit_id)
        else
          acc
        end
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
        if deadline_reached?(operation) do
          fail_connections(state)
        else
          apply_registry_result(state, operation_ref, operation, result)
        end
    end
  end

  defp apply_registry_result(
         state,
         operation_ref,
         %{kind: :grant, step: :install} = operation,
         :ok
       ) do
    state = put_in(state, [:mirror_operations, operation_ref, :step], :select_result)
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
    state = put_in(state, [:mirror_operations, operation_ref, :step], :resolve_cancelled)

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
    state = put_in(state, [:mirror_operations, operation_ref, :step], :await_connection_loss)
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
        |> put_in(
          [:mirror_operations, operation_ref, :step],
          :settle_result_after_owner_loss
        )

      request_relay_result_settlement(state, operation_ref, operation)
      {:noreply, state}
    else
      state = put_in(state, [:mirror_operations, operation_ref, :step], :resolve_owner_grant)

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
      state = put_in(state, [:mirror_operations, operation_ref, :step], :resolve_owner_cancel)

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
    state = put_in(state, [:mirror_operations, operation_ref, :step], :settle_result)
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
      state = put_in(state, [:mirror_operations, operation_ref, :step], :resolve_owner_expiry)

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

  defp apply_registry_result(state, _operation_ref, _operation, _result),
    do: fail_connections(state)

  defp begin_owner_loss_classification(state, operation_ref, operation, holder) do
    holder_incarnation = if holder, do: holder.holder_incarnation, else: nil

    state =
      state
      |> put_in([:mirror_operations, operation_ref, :step], :await_classification)
      |> put_in([:mirror_operations, operation_ref, :holder], holder)
      |> put_in([:owners, operation.row.session_id, :mirror_complete], true)
      |> update_in([:routes], &Map.delete(&1, operation.row.session_id))

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
        if deadline_reached?(operation) do
          fail_connections(state)
        else
          apply_relay_result(state, operation_ref, operation, action, result)
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
    state = put_in(state, [:mirror_operations, operation_ref, :step], :resolve_granted)

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
    state = put_in(state, [:mirror_operations, operation_ref, :step], :resolve_owner_lost)

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
    {:noreply, put_in(state, [:mirror_operations, operation_ref, :step], :await_connection_loss)}
  end

  defp apply_relay_result(
         state,
         operation_ref,
         %{kind: :release, step: :select_result, row: row},
         :select_result,
         :ok
       ) do
    state = put_in(state, [:mirror_operations, operation_ref, :step], :clear)

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
    {:noreply, put_in(state, [:mirror_operations, operation_ref, :step], :await_connection_loss)}
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
      state = put_in(state, [:mirror_operations, operation_ref, :step], :resolve_owner_release)

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
      %{owner_pid: ^owner, owner_incarnation: ^owner_incarnation} = operation ->
        if deadline_reached?(operation) do
          fail_connections(state)
        else
          apply_owner_result(state, operation_ref, operation, action, result)
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
    state = put_in(state, [:mirror_operations, operation_ref, :step], :settle_result)
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
    state = put_in(state, [:mirror_operations, operation_ref, :step], :settle_disposition)
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
    state = put_in(state, [:mirror_operations, operation_ref, :step], :settle_disposition)
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
        {:stop, :relay_lost, state}
    end
  end

  defp continue_connection_loss(state, permit_id, loss) do
    case Enum.filter(state.mirror_operations, fn {_ref, operation} ->
           operation.permit_id == permit_id
         end) do
      [] ->
        case Map.fetch!(state.operations, permit_id) do
          %{phase: phase} = operation when phase in [:waiting_owner, :abandoned] ->
            start_waiting_owner_loss_settlement(state, permit_id, operation, loss)

          _operation ->
            retain_pending_connection_loss(state, permit_id, loss)
        end

      [{operation_ref, %{kind: :grant, step: :install} = operation}] ->
        operation = %{operation | step: :install_connection_lost, loss_ref: loss.settlement_ref}
        {:noreply, put_in(state, [:mirror_operations, operation_ref], operation)}

      [{_operation_ref, %{step: :install_connection_lost, loss_ref: loss_ref}}]
      when loss_ref == loss.settlement_ref ->
        {:noreply, state}

      [{operation_ref, %{kind: :grant, step: step, row: row} = operation}]
      when step in [:await_connection_loss, :select_result] ->
        operation = %{operation | step: :resolve_cancelled, loss_ref: loss.settlement_ref}
        state = put_in(state, [:mirror_operations, operation_ref], operation)

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
        state = put_in(state, [:mirror_operations, operation_ref], operation)

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
        {:noreply, put_in(state, [:pending_dispositions, permit_id], loss)}

      {:ok, ^loss} ->
        {:noreply, state}

      {:ok, _other} ->
        {:stop, :relay_lost, state}
    end
  end

  defp start_waiting_owner_loss_settlement(state, permit_id, operation, loss) do
    operation_ref = make_ref()
    deadline = monotonic_ms() + state.mirror_deadline_ms

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
      deadline: deadline,
      timer: schedule_deadline(operation_ref, deadline),
      loss_ref: loss.settlement_ref
    }

    state =
      state
      |> put_in([:operations, permit_id, :phase], :settling)
      |> put_in([:mirror_operations, operation_ref], settlement)

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
    state = put_in(state, [:mirror_operations, operation_ref, :step], :settle_disposition)
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

  defp maybe_complete_direct_operation(state, permit_id, :completed) do
    state
    |> update_in([:operations], &Map.delete(&1, permit_id))
    |> update_in([:pending_dispositions], &Map.delete(&1, permit_id))
  end

  defp maybe_complete_direct_operation(state, _permit_id, disposition)
       when disposition in [:proposed, :queued],
       do: state

  defp request_owner_retirement(state, owner, session_id) do
    case Map.get(state.owners, session_id) do
      %{pid: ^owner, phase: :live} = row ->
        case lease_owner_call(fn -> LeaseOwner.retire_if_idle(owner) end) do
          {:ok, :retiring} ->
            Logger.debug("loopex daemon lease owner retirement pending")
            {:noreply, put_in(state, [:owners, session_id], %{row | phase: :retirement_pending})}

          {:ok, :waiting} ->
            {:noreply, state}

          {:error, :not_idle} ->
            {:noreply, state}

          {:error, reason} when reason in [:daemon_stopping, :owner_unavailable, :owner_down] ->
            {:noreply, state}
        end

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
        if deadline_reached?(operation) do
          fail_connections(state)
        else
          case Map.get(state.owners, session_id) do
            %{
              pid: ^owner,
              incarnation: ^owner_incarnation,
              relay_loss_seen: true,
              relay_loss_ready: true,
              mirror_complete: true
            } = row ->
              row = %{row | classification_complete: true}
              state = put_in(state, [:owners, session_id], row)
              continue_owner_loss_notification(state, operation_ref, operation)

            _other ->
              {:stop, :relay_lost, state}
          end
        end

      nil ->
        {:stop, :relay_lost, state}
    end
  end

  defp continue_owner_loss_notification(state, operation_ref, %{holder: nil} = operation) do
    complete_owner_loss_notification(state, operation_ref, operation)
  end

  defp continue_owner_loss_notification(
         state,
         operation_ref,
         %{holder: holder} = operation
       ) do
    if Process.alive?(holder.holder_pid) do
      close_ref = make_ref()

      send(
        holder.holder_pid,
        {:daemon_control_owner_lost, self(), close_ref, operation.row.session_id,
         holder.holder_incarnation}
      )

      state =
        state
        |> put_in([:mirror_operations, operation_ref, :step], :await_holder_close)
        |> put_in([:mirror_operations, operation_ref, :close_ref], close_ref)

      Logger.debug("loopex daemon lost owner holder close start")
      {:noreply, state}
    else
      complete_owner_loss_notification(state, operation_ref, operation)
    end
  end

  defp continue_owner_loss_close(state, close_ref, connection, connection_incarnation) do
    case Enum.find(state.mirror_operations, fn {_operation_ref, operation} ->
           operation.kind == :owner_loss and operation.step == :await_holder_close and
             operation.close_ref == close_ref and operation.holder.holder_pid == connection and
             operation.holder.holder_incarnation == connection_incarnation
         end) do
      {operation_ref, operation} ->
        if deadline_reached?(operation) do
          fail_connections(state)
        else
          complete_owner_loss_notification(state, operation_ref, operation)
        end

      nil ->
        {:noreply, state}
    end
  end

  defp complete_owner_loss_notification(state, operation_ref, operation) do
    cancel_timer(operation.timer, operation_ref)

    state =
      state
      |> update_in([:mirror_operations], &Map.delete(&1, operation_ref))
      |> put_in([:owners, operation.row.session_id, :notification_complete], true)

    Logger.debug("loopex daemon lease owner loss notification complete")
    finish_owner_loss(state, operation.row.session_id)
  end

  defp finish_owner_loss(state, session_id) do
    case Map.get(state.owners, session_id) do
      %{
        exit_consumed: true,
        mirror_complete: true,
        classification_complete: true,
        notification_complete: true,
        successor: nil
      } ->
        Logger.debug("loopex daemon lease owner loss complete")
        {:noreply, update_in(state.owners, &Map.delete(&1, session_id))}

      %{
        exit_consumed: true,
        mirror_complete: true,
        classification_complete: true,
        notification_complete: true,
        successor: permit_id
      } = row
      when not is_nil(permit_id) ->
        start_waiting_successor(state, session_id, row, permit_id)

      _other ->
        {:noreply, state}
    end
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
        {:noreply, update_in(state.owners, &Map.delete(&1, session_id))}

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

  defp start_waiting_successor(state, session_id, predecessor, permit_id) do
    case Map.get(state.operations, permit_id) do
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
        case AdmissionRelay.register_lease_owner(
               state.relay,
               session_id,
               owner,
               owner_incarnation
             ) do
          :ok ->
            permit_id = operation.request.permit_id
            row = owner_row(owner, owner_incarnation)

            operation = %{
              operation
              | owner_pid: owner,
                owner_incarnation: owner_incarnation,
                phase: :opened
            }

            state =
              state
              |> put_in([:owners, session_id], row)
              |> put_in([:owner_pids, owner], session_id)
              |> put_in([:operations, permit_id], operation)

            activate_installed_owner(owner)

            case first_acquire(owner, operation.request) do
              {:ok, disposition} when disposition in [:proposed, :queued] ->
                Logger.debug("loopex daemon successor lease owner installed")
                {:noreply, state}

              {:error, :invalid_operation} ->
                {:stop, :lease_operation_invalid, state}
            end

          _error ->
            discard_unregistered_owner(owner)

            complete_waiting_successor(
              state,
              session_id,
              predecessor,
              operation,
              "control_pending"
            )
        end

      _error ->
        complete_waiting_successor(
          state,
          session_id,
          predecessor,
          operation,
          "control_pending"
        )
    end
  end

  defp complete_waiting_successor(state, session_id, predecessor, operation, code) do
    result = WireRecords.control_error(operation.request.request_id, code)

    case AdmissionRelay.complete_lease_permit(
           state.relay,
           operation.request.permit_id,
           state.daemon_incarnation,
           result
         ) do
      :ok ->
        state =
          state
          |> update_in([:operations], &Map.delete(&1, operation.request.permit_id))
          |> update_in([:pending_dispositions], &Map.delete(&1, operation.request.permit_id))

        state =
          case Map.get(state.owners, session_id) do
            ^predecessor -> update_in(state.owners, &Map.delete(&1, session_id))
            _other -> state
          end

        Logger.debug("loopex daemon successor owner start refused")
        {:noreply, state}

      {:error, :connection_lost} ->
        {:noreply, state}

      {:error, _reason} ->
        {:stop, :relay_lost, state}
    end
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
          update_in(state.owners, &Map.delete(&1, session_id))
        else
          put_in(state, [:owners, session_id], row)
        end

      _other ->
        state
    end
  end

  defp release_successor_reservation(state, _operation), do: state

  # Concept: a lease owner is a session-scoped child whose death never stops
  # the daemon owner. Technical depth: a synchronous call can observe that
  # death before the linked `EXIT` is consumed; the exit becomes
  # `{:error, :owner_down}` and the queued `EXIT` completes owner-loss handling.
  defp lease_owner_call(fun) do
    fun.()
  catch
    :exit, _reason -> {:error, :owner_down}
  end

  # Concept: a registered child that cannot activate is lost like any other
  # owner. Technical depth: killing it keeps the link, so the relay's owner
  # loss and the daemon's linked `EXIT` settle it on the ordinary path.
  defp activate_installed_owner(owner) do
    case lease_owner_call(fn -> LeaseOwner.activate(owner) end) do
      :ok -> :ok
      _error -> Process.exit(owner, :kill)
    end
  end

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
      loss_pop_started: false
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

  defp live_owner(state, session_id) do
    case Map.get(state.owners, session_id) do
      %{phase: :live} = row -> {:ok, row}
      _other -> {:error, :owner_unavailable}
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

  defp deadline_reached?(operation), do: monotonic_ms() >= operation.deadline

  defp schedule_deadline(operation_ref, deadline) do
    Process.send_after(
      self(),
      {:mirror_deadline, operation_ref, deadline},
      max(deadline - monotonic_ms(), 0)
    )
  end

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
