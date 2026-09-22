defmodule LoopexDaemon.AdmissionRelay do
  @moduledoc """
  ## Concept

  One daemon process decides whether a post-initialize request entered service
  before shutdown. It retains the request's origin until the worker and its
  disposition are accounted for, so losing a socket never turns unfinished
  work into forgotten work.

  ## Technical depth

  This relay surface owns the lightweight query, read and artifact permit path
  plus the pending and queued origin states for ticketed core mutations. A
  registered connection may hold at most 32 origin rows, each
  named by its 128-bit connection incarnation, local slot and strictly
  increasing sequence. A worker is monitored and receives `go` only after the
  relay has atomically changed its row from pending to executing. Result,
  worker loss, connection loss, shutdown cancellation and the worker's exact
  `DOWN` are serialized here.

  The ref-tagged `cut` barrier changes admission to draining immediately,
  returns the exact frozen permit set and one absolute monotonic deadline, and
  refuses every later row as `daemon_stopping`. Pending rows crossing that
  deadline are cancelled without dispatch. Executing non-lease work remains
  tracked for its real result or connection retirement, as the accepted M5
  shutdown order requires. Ticketed calls and lease-operation permits extend
  this same bounded ledger in later slices. Ticket promotion and settlement
  extend the queued rows without changing their origin or worker ownership.
  """

  use GenServer
  require Logger

  alias LoopexProtocol.Frame

  @connection_limit 512
  @origins_per_connection 32
  @origin_limit @connection_limit * @origins_per_connection
  @control_timeout_ms 5_000
  @max_timer_ms 4_294_967_295
  @uint64_max 18_446_744_073_709_551_615

  @permit_classes [
    :session_inspect,
    :resources_catalog,
    :resources_read,
    :artifact_open_transfer,
    :artifact_read_chunk,
    :artifact_close_transfer,
    :session_list,
    :daemon_status
  ]

  @session_classes [:session_inspect, :resources_catalog, :resources_read]

  @ticket_classes [
    :session_create,
    :session_resume,
    :session_attach,
    :session_prompt,
    :session_steer,
    :session_follow_up,
    :session_abort,
    :session_respond_interaction,
    :session_admit_resources,
    :session_activate_skill
  ]

  @session_ticket_classes @ticket_classes -- [:session_create]
  @lease_ticket_classes @session_ticket_classes -- [:session_attach]
  @direct_lease_ticket_classes @lease_ticket_classes -- [:session_resume]

  @typedoc false
  @type origin_id :: {binary(), 0..31, pos_integer()}

  @typedoc false
  @type permit_class ::
          :session_inspect
          | :resources_catalog
          | :resources_read
          | :artifact_open_transfer
          | :artifact_read_chunk
          | :artifact_close_transfer
          | :session_list
          | :daemon_status

  @typedoc false
  @type ticket_class ::
          :session_create
          | :session_resume
          | :session_attach
          | :session_prompt
          | :session_steer
          | :session_follow_up
          | :session_abort
          | :session_respond_interaction
          | :session_admit_resources
          | :session_activate_skill

  @typedoc false
  @type owner_binding :: {pid(), binary()} | nil

  @typedoc false
  @type settlement_ref :: term()

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options), do: GenServer.start_link(__MODULE__, options)

  @doc false
  @spec register_connection(pid(), binary(), pid()) ::
          :ok
          | {:error,
             :capacity_exceeded
             | :connection_unavailable
             | :daemon_stopping
             | :invalid_connection}
  def register_connection(relay, incarnation, retirement_recipient) do
    GenServer.call(
      relay,
      {:register_connection, incarnation, retirement_recipient},
      @control_timeout_ms
    )
  end

  @doc false
  @spec register_registry(pid(), pid(), binary()) ::
          :ok | {:error, :invalid_registry | :registry_conflict}
  def register_registry(relay, registry, registry_incarnation) do
    GenServer.call(
      relay,
      {:register_registry, registry, registry_incarnation},
      @control_timeout_ms
    )
  end

  @doc false
  @spec register_lease_owner(pid(), binary(), pid(), binary()) ::
          :ok | {:error, :daemon_stopping | :invalid_owner | :owner_conflict}
  def register_lease_owner(relay, session_id, owner, owner_incarnation) do
    GenServer.call(
      relay,
      {:register_lease_owner, session_id, owner, owner_incarnation},
      @control_timeout_ms
    )
  end

  @doc false
  @spec settle_owner_loss(pid(), binary(), pid(), binary(), [origin_id()]) ::
          :ok | {:error, :owner_loss_unavailable | :owner_loss_unsettled}
  def settle_owner_loss(relay, session_id, owner, owner_incarnation, origins) do
    GenServer.call(
      relay,
      {:settle_owner_loss, session_id, owner, owner_incarnation, origins},
      @control_timeout_ms
    )
  end

  @doc false
  @spec open_permit(pid(), origin_id(), permit_class(), binary() | nil) ::
          {:ok, origin_id()}
          | {:error,
             :capacity_exceeded
             | :connection_unavailable
             | :daemon_stopping
             | :invalid_origin
             | :permit_conflict}
  def open_permit(relay, origin_id, class, session_id \\ nil) do
    GenServer.call(
      relay,
      {:open_permit, origin_id, class, session_id},
      @control_timeout_ms
    )
  end

  @doc false
  @spec open_ticket(pid(), origin_id(), ticket_class(), binary() | nil, owner_binding()) ::
          {:ok, origin_id()}
          | {:error,
             :capacity_exceeded
             | :connection_unavailable
             | :daemon_stopping
             | :invalid_origin
             | :ticket_conflict}
  def open_ticket(relay, origin_id, class, session_id \\ nil, owner_binding \\ nil) do
    GenServer.call(
      relay,
      {:open_ticket, origin_id, class, session_id, owner_binding},
      @control_timeout_ms
    )
  end

  @doc false
  @spec bind_ticket_worker(pid(), origin_id(), pid(), binary()) ::
          :ok
          | {:error,
             :connection_unavailable
             | :daemon_stopping
             | :invalid_worker
             | :ticket_unavailable}
  def bind_ticket_worker(relay, origin_id, worker, worker_incarnation) do
    GenServer.call(
      relay,
      {:bind_ticket_worker, origin_id, worker, worker_incarnation},
      @control_timeout_ms
    )
  end

  @doc false
  @spec promote_ticket(
          pid(),
          origin_id(),
          binary(),
          settlement_ref(),
          (-> map())
        ) ::
          {:ok, origin_id()}
          | {:error,
             :daemon_stopping
             | :invalid_promotion
             | :registry_unavailable
             | :ticket_unavailable}
  def promote_ticket(
        relay,
        origin_id,
        registry_incarnation,
        settlement_ref,
        task_fun
      ) do
    GenServer.call(
      relay,
      {:promote_ticket, origin_id, registry_incarnation, settlement_ref, task_fun},
      @control_timeout_ms
    )
  end

  @doc false
  @spec wait_for_ticket(pid(), origin_id(), origin_id(), binary()) ::
          {:ok, origin_id()}
          | {:error,
             :daemon_stopping
             | :invalid_waiter
             | :registry_unavailable
             | :ticket_unavailable}
  def wait_for_ticket(relay, origin_id, primary_origin_id, registry_incarnation) do
    GenServer.call(
      relay,
      {:wait_for_ticket, origin_id, primary_origin_id, registry_incarnation},
      @control_timeout_ms
    )
  end

  @doc false
  @spec promote_lease_ticket(pid(), origin_id(), binary(), (-> map())) ::
          {:ok, origin_id()}
          | {:error,
             :daemon_stopping
             | :invalid_promotion
             | :owner_unavailable
             | :ticket_unavailable}
  def promote_lease_ticket(relay, origin_id, owner_incarnation, task_fun) do
    GenServer.call(
      relay,
      {:promote_lease_ticket, origin_id, owner_incarnation, task_fun},
      @control_timeout_ms
    )
  end

  @doc false
  @spec settle_ticket(pid(), origin_id(), binary(), settlement_ref()) ::
          :ok | {:error, :registry_unavailable | :ticket_unavailable}
  def settle_ticket(relay, origin_id, registry_incarnation, settlement_ref) do
    GenServer.call(
      relay,
      {:settle_ticket, origin_id, registry_incarnation, settlement_ref},
      @control_timeout_ms
    )
  end

  @doc false
  @spec bind_worker(pid(), origin_id(), pid(), binary()) ::
          :ok
          | {:error,
             :connection_unavailable
             | :daemon_stopping
             | :invalid_worker
             | :permit_unavailable}
  def bind_worker(relay, origin_id, worker, worker_incarnation) do
    GenServer.call(
      relay,
      {:bind_worker, origin_id, worker, worker_incarnation},
      @control_timeout_ms
    )
  end

  @doc false
  @spec complete_permit(pid(), origin_id(), binary(), map()) ::
          :ok | {:error, :connection_lost | :invalid_result | :permit_unavailable}
  def complete_permit(relay, origin_id, worker_incarnation, result) do
    GenServer.call(
      relay,
      {:complete_permit, origin_id, worker_incarnation, result},
      @control_timeout_ms
    )
  end

  @doc false
  @spec status(pid()) :: %{
          phase: :serving | :draining,
          connections: non_neg_integer(),
          permits: non_neg_integer(),
          tickets: non_neg_integer(),
          pending: non_neg_integer(),
          queued: non_neg_integer(),
          ticketed: non_neg_integer(),
          waiting: non_neg_integer(),
          executing: non_neg_integer(),
          settling: non_neg_integer(),
          connection_limit: 512,
          origin_limit: 16_384,
          admission_deadline_set: boolean(),
          lease_owners: non_neg_integer(),
          owner_losses: non_neg_integer()
        }
  def status(relay), do: GenServer.call(relay, :status, @control_timeout_ms)

  @impl true
  def init(options) do
    Process.flag(:trap_exit, true)
    owner = Keyword.fetch!(options, :owner)
    admission_wait_ms = Keyword.fetch!(options, :admission_wait_ms)

    if is_pid(owner) and is_integer(admission_wait_ms) and admission_wait_ms > 0 and
         admission_wait_ms <= @max_timer_ms do
      Process.link(owner)
      Logger.debug("loopex daemon admission relay start")

      {:ok,
       %{
         owner: owner,
         admission_wait_ms: admission_wait_ms,
         phase: :serving,
         cut_ref: nil,
         cut_payload: nil,
         frozen_permits: MapSet.new(),
         frozen_tickets: MapSet.new(),
         admission_deadline: nil,
         deadline_timer: nil,
         connections: %{},
         connection_pids: %{},
         connection_monitors: %{},
         permits: %{},
         tickets: %{},
         worker_monitors: %{},
         ticket_task_monitors: %{},
         registry: nil,
         registry_monitor: nil,
         lease_owners: %{},
         lease_owner_monitors: %{},
         owner_losses: %{}
       }}
    else
      {:stop, :invalid_admission_relay_options}
    end
  end

  @impl true
  def handle_call(
        {:register_registry, registry, registry_incarnation},
        {caller, _tag},
        %{owner: caller} = state
      ) do
    cond do
      not is_pid(registry) or not valid_incarnation?(registry_incarnation) ->
        {:reply, {:error, :invalid_registry}, state}

      match?(%{pid: ^registry, incarnation: ^registry_incarnation}, state.registry) ->
        {:reply, :ok, state}

      not is_nil(state.registry) ->
        {:reply, {:error, :registry_conflict}, state}

      true ->
        monitor = Process.monitor(registry)

        state = %{
          state
          | registry: %{pid: registry, incarnation: registry_incarnation},
            registry_monitor: monitor
        }

        Logger.debug("loopex daemon admission relay registry registered")
        {:reply, :ok, state}
    end
  end

  def handle_call({:register_registry, _registry, _incarnation}, _from, state),
    do: {:reply, {:error, :invalid_registry}, state}

  def handle_call(
        {:register_lease_owner, session_id, owner, owner_incarnation},
        {caller, _tag},
        %{owner: caller} = state
      ) do
    binding = {owner, owner_incarnation}

    cond do
      validate_ticket_session(session_id) != :ok or not is_pid(owner) or
          not valid_incarnation?(owner_incarnation) ->
        {:reply, {:error, :invalid_owner}, state}

      match?(%{binding: ^binding}, Map.get(state.lease_owners, session_id)) ->
        {:reply, :ok, state}

      state.phase != :serving ->
        {:reply, {:error, :daemon_stopping}, state}

      Map.has_key?(state.lease_owners, session_id) or
          Enum.any?(state.lease_owners, fn {_session, row} -> elem(row.binding, 0) == owner end) ->
        {:reply, {:error, :owner_conflict}, state}

      true ->
        monitor = Process.monitor(owner)
        row = %{binding: binding, monitor: monitor}

        state = %{
          state
          | lease_owners: Map.put(state.lease_owners, session_id, row),
            lease_owner_monitors:
              Map.put(state.lease_owner_monitors, monitor, {session_id, binding})
        }

        Logger.debug("loopex daemon admission relay lease owner registered")
        {:reply, :ok, state}
    end
  end

  def handle_call({:register_lease_owner, _session, _owner, _incarnation}, _from, state),
    do: {:reply, {:error, :invalid_owner}, state}

  def handle_call(
        {:settle_owner_loss, session_id, owner, owner_incarnation, origins},
        {caller, _tag},
        %{owner: caller} = state
      ) do
    binding = {owner, owner_incarnation}

    case Map.fetch(state.owner_losses, binding) do
      {:ok, %{session_id: ^session_id, origins: retained_origins}}
      when is_list(origins) ->
        supplied = MapSet.new(origins)

        cond do
          MapSet.size(supplied) != length(origins) or supplied != retained_origins ->
            {:reply, {:error, :owner_loss_unavailable}, state}

          Enum.any?(retained_origins, &owner_loss_worker_live?(state, &1)) ->
            {:reply, {:error, :owner_loss_unsettled}, state}

          true ->
            state =
              Enum.reduce(retained_origins, state, fn origin_id, acc ->
                case Map.fetch(acc.tickets, origin_id) do
                  {:ok, ticket} ->
                    acc
                    |> remove_ticket(origin_id)
                    |> maybe_retire_connection(ticket.connection_incarnation)

                  :error ->
                    acc
                end
              end)

            state = update_in(state.owner_losses, &Map.delete(&1, binding))
            Logger.debug("loopex daemon admission relay owner loss settled")
            {:reply, :ok, state}
        end

      _other ->
        {:reply, {:error, :owner_loss_unavailable}, state}
    end
  end

  def handle_call(
        {:settle_owner_loss, _session, _owner, _incarnation, _origins},
        _from,
        state
      ),
      do: {:reply, {:error, :owner_loss_unavailable}, state}

  def handle_call(
        {:register_connection, incarnation, retirement_recipient},
        {caller, _tag},
        state
      ) do
    cond do
      not valid_incarnation?(incarnation) or not is_pid(retirement_recipient) ->
        {:reply, {:error, :invalid_connection}, state}

      exact_connection?(state, incarnation, caller, retirement_recipient) ->
        {:reply, :ok, state}

      state.phase != :serving ->
        {:reply, {:error, :daemon_stopping}, state}

      Map.has_key?(state.connections, incarnation) or
          Map.has_key?(state.connection_pids, caller) ->
        {:reply, {:error, :connection_unavailable}, state}

      map_size(state.connections) >= @connection_limit ->
        {:reply, {:error, :capacity_exceeded}, state}

      true ->
        monitor = Process.monitor(caller)

        connection = %{
          pid: caller,
          monitor: monitor,
          retirement_recipient: retirement_recipient,
          phase: :live,
          origins: MapSet.new(),
          sequence_by_slot: %{}
        }

        state = %{
          state
          | connections: Map.put(state.connections, incarnation, connection),
            connection_pids: Map.put(state.connection_pids, caller, incarnation),
            connection_monitors: Map.put(state.connection_monitors, monitor, incarnation)
        }

        Logger.debug("loopex daemon admission relay connection registered")
        {:reply, :ok, state}
    end
  end

  def handle_call({:open_permit, origin_id, class, session_id}, {caller, _tag}, state) do
    case existing_permit(state, origin_id, class, session_id, caller) do
      :exact ->
        {:reply, {:ok, origin_id}, state}

      :conflict ->
        {:reply, {:error, :permit_conflict}, state}

      :absent ->
        with :ok <- serving(state),
             {:ok, incarnation, slot, sequence} <- validate_origin(origin_id),
             {:ok, connection} <- caller_connection(state, incarnation, caller),
             :ok <- validate_class(class, session_id),
             :ok <- origin_capacity(state, connection),
             :ok <- sequence_available(connection, slot, sequence) do
          permit = %{
            origin_id: origin_id,
            class: class,
            session_id: session_id,
            connection_incarnation: incarnation,
            connection_pid: caller,
            phase: :pending,
            worker_pid: nil,
            worker_incarnation: nil,
            worker_monitor: nil,
            disposition: nil,
            result: nil
          }

          connection = %{
            connection
            | origins: MapSet.put(connection.origins, origin_id),
              sequence_by_slot: Map.put(connection.sequence_by_slot, slot, sequence)
          }

          state =
            state
            |> put_in([:connections, incarnation], connection)
            |> put_in([:permits, origin_id], permit)

          Logger.debug("loopex daemon admission relay permit opened")
          {:reply, {:ok, origin_id}, state}
        else
          {:error, reason} -> {:reply, {:error, reason}, state}
        end
    end
  end

  def handle_call(
        {:open_ticket, origin_id, class, session_id, owner_binding},
        {caller, _tag},
        state
      ) do
    case existing_ticket(state, origin_id, class, session_id, owner_binding, caller) do
      :exact ->
        {:reply, {:ok, origin_id}, state}

      :conflict ->
        {:reply, {:error, :ticket_conflict}, state}

      :absent ->
        with :ok <- serving(state),
             {:ok, incarnation, slot, sequence} <- validate_origin(origin_id),
             {:ok, connection} <- caller_connection(state, incarnation, caller),
             :ok <- validate_ticket_class(class, session_id, owner_binding),
             :ok <- validate_ticket_owner(state, class, session_id, owner_binding),
             :ok <- origin_capacity(state, connection),
             :ok <- sequence_available(connection, slot, sequence) do
          ticket = %{
            origin_id: origin_id,
            class: class,
            session_id: session_id,
            owner_binding: owner_binding,
            connection_incarnation: incarnation,
            connection_pid: caller,
            phase: :pending,
            worker_pid: nil,
            worker_incarnation: nil,
            worker_monitor: nil,
            disposition: nil,
            promoter_pid: nil,
            promoter_incarnation: nil,
            settlement_ref: nil,
            settlement_mode: nil,
            task_pid: nil,
            task_incarnation: nil,
            task_monitor: nil,
            task_down: false,
            result: nil,
            settlement_acked: false,
            result_delivered: false,
            promotion_waiters: [],
            primary_origin_id: nil,
            waiting_callers: []
          }

          connection = %{
            connection
            | origins: MapSet.put(connection.origins, origin_id),
              sequence_by_slot: Map.put(connection.sequence_by_slot, slot, sequence)
          }

          state =
            state
            |> put_in([:connections, incarnation], connection)
            |> put_in([:tickets, origin_id], ticket)

          Logger.debug("loopex daemon admission relay ticket opened")
          {:reply, {:ok, origin_id}, state}
        else
          {:error, reason} -> {:reply, {:error, reason}, state}
        end
    end
  end

  def handle_call(
        {:bind_ticket_worker, origin_id, worker, worker_incarnation},
        {caller, _tag},
        state
      ) do
    state = expire_if_due(state)

    if admission_expired?(state) do
      {:reply, {:error, :daemon_stopping}, state}
    else
      with {:ok, ticket} <- pending_ticket(state, origin_id),
           {:ok, _connection} <-
             caller_connection(state, ticket.connection_incarnation, caller),
           :ok <- bind_admitted(state, origin_id, :ticket),
           :ok <- valid_worker(worker, worker_incarnation, caller) do
        monitor = Process.monitor(worker)

        ticket = %{
          ticket
          | phase: :queued,
            worker_pid: worker,
            worker_incarnation: worker_incarnation,
            worker_monitor: monitor
        }

        state =
          state
          |> put_in([:tickets, origin_id], ticket)
          |> put_in([:worker_monitors, monitor], {:ticket, origin_id})

        Logger.debug("loopex daemon admission relay ticket queued")
        {:reply, :ok, state}
      else
        {:error, reason} -> {:reply, {:error, reason}, state}
      end
    end
  end

  def handle_call(
        {:promote_ticket, origin_id, registry_incarnation, settlement_ref, task_fun},
        from = {caller, _tag},
        state
      ) do
    state = expire_if_due(state)

    case promotion_repetition(
           state,
           origin_id,
           caller,
           registry_incarnation,
           settlement_ref
         ) do
      :complete ->
        {:reply, {:ok, origin_id}, state}

      {:waiting, ticket} ->
        ticket = %{ticket | promotion_waiters: [from | ticket.promotion_waiters]}
        {:noreply, put_in(state, [:tickets, origin_id], ticket)}

      :conflict ->
        {:reply, {:error, :invalid_promotion}, state}

      :absent ->
        with :ok <- promotion_admitted(state, origin_id),
             :ok <- authenticate_registry(state, caller, registry_incarnation),
             true <- is_function(task_fun, 0),
             {:ok, ticket} <- promotable_ticket(state, origin_id),
             true <- ticket.class in [:session_create, :session_resume, :session_attach] do
          start_ticket_promotion(
            state,
            ticket,
            from,
            caller,
            registry_incarnation,
            settlement_ref,
            task_fun,
            :registry
          )
        else
          false -> {:reply, {:error, :invalid_promotion}, state}
          {:error, reason} -> {:reply, {:error, reason}, state}
        end
    end
  end

  def handle_call(
        {:settle_ticket, origin_id, registry_incarnation, settlement_ref},
        {caller, _tag},
        state
      ) do
    with :ok <- authenticate_registry(state, caller, registry_incarnation),
         {:ok, ticket} <- selected_ticket(state, origin_id, caller, settlement_ref) do
      ticket = %{ticket | settlement_acked: true}
      state = put_in(state, [:tickets, origin_id], ticket)
      state = deliver_ticket_result(state, origin_id)
      Logger.debug("loopex daemon admission relay ticket settled")
      {:reply, :ok, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(
        {:promote_lease_ticket, origin_id, owner_incarnation, task_fun},
        from = {caller, _tag},
        state
      ) do
    state = expire_if_due(state)

    case promotion_repetition(state, origin_id, caller, owner_incarnation, :direct) do
      :complete ->
        {:reply, {:ok, origin_id}, state}

      {:waiting, ticket} ->
        ticket = %{ticket | promotion_waiters: [from | ticket.promotion_waiters]}
        {:noreply, put_in(state, [:tickets, origin_id], ticket)}

      :conflict ->
        {:reply, {:error, :invalid_promotion}, state}

      :absent ->
        with :ok <- promotion_admitted(state, origin_id),
             true <- is_function(task_fun, 0),
             {:ok, ticket} <- promotable_ticket(state, origin_id),
             true <- ticket.class in @direct_lease_ticket_classes,
             :ok <- authenticate_ticket_owner(state, ticket, caller, owner_incarnation) do
          start_ticket_promotion(
            state,
            ticket,
            from,
            caller,
            owner_incarnation,
            :direct,
            task_fun,
            :direct
          )
        else
          false -> {:reply, {:error, :invalid_promotion}, state}
          {:error, reason} -> {:reply, {:error, reason}, state}
        end
    end
  end

  def handle_call(
        {:wait_for_ticket, origin_id, primary_origin_id, registry_incarnation},
        from = {caller, _tag},
        state
      ) do
    state = expire_if_due(state)

    case waiting_repetition(
           state,
           origin_id,
           primary_origin_id,
           caller,
           registry_incarnation
         ) do
      :complete ->
        {:reply, {:ok, primary_origin_id}, state}

      {:waiting, ticket} ->
        ticket = %{ticket | waiting_callers: [from | ticket.waiting_callers]}
        {:noreply, put_in(state, [:tickets, origin_id], ticket)}

      :conflict ->
        {:reply, {:error, :invalid_waiter}, state}

      :absent ->
        with :ok <- promotion_admitted(state, origin_id),
             :ok <- authenticate_registry(state, caller, registry_incarnation),
             {:ok, ticket, primary} <- waiter_pair(state, origin_id, primary_origin_id) do
          ticket = %{
            ticket
            | phase: :waiting,
              primary_origin_id: primary_origin_id,
              waiting_callers: if(is_pid(ticket.worker_pid), do: [from], else: [])
          }

          state = put_in(state, [:tickets, origin_id], ticket)
          Logger.debug("loopex daemon admission relay ticket waiting")

          if is_pid(ticket.worker_pid) do
            if Process.alive?(ticket.worker_pid), do: Process.exit(ticket.worker_pid, :kill)
            {:noreply, state}
          else
            {:reply, {:ok, primary.origin_id}, state}
          end
        else
          {:error, reason} -> {:reply, {:error, reason}, state}
        end
    end
  end

  def handle_call(
        {:bind_worker, origin_id, worker, worker_incarnation},
        {caller, _tag},
        state
      ) do
    state = expire_if_due(state)

    if admission_expired?(state) do
      {:reply, {:error, :daemon_stopping}, state}
    else
      with {:ok, permit} <- pending_permit(state, origin_id),
           {:ok, _connection} <-
             caller_connection(state, permit.connection_incarnation, caller),
           :ok <- bind_admitted(state, origin_id, :permit),
           :ok <- valid_worker(worker, worker_incarnation, caller) do
        monitor = Process.monitor(worker)

        permit = %{
          permit
          | phase: :executing,
            worker_pid: worker,
            worker_incarnation: worker_incarnation,
            worker_monitor: monitor
        }

        state =
          state
          |> put_in([:permits, origin_id], permit)
          |> put_in([:worker_monitors, monitor], {:permit, origin_id})

        send(worker, {:relay_go, origin_id, worker_incarnation})
        Logger.debug("loopex daemon admission relay permit executing")
        {:reply, :ok, state}
      else
        {:error, reason} -> {:reply, {:error, reason}, state}
      end
    end
  end

  def handle_call(
        {:complete_permit, origin_id, worker_incarnation, result},
        {caller, _tag},
        state
      ) do
    case Map.fetch(state.permits, origin_id) do
      {:ok,
       %{
         phase: :executing,
         worker_pid: ^caller,
         worker_incarnation: ^worker_incarnation,
         disposition: nil
       } = permit} ->
        if bounded_record?(result) do
          permit = %{permit | phase: :settling, disposition: :result, result: result}
          state = put_in(state, [:permits, origin_id], permit)

          send(permit.connection_pid, {:relay_permit_result, origin_id, result})
          Logger.debug("loopex daemon admission relay permit result")
          {:reply, :ok, state}
        else
          {:reply, {:error, :invalid_result}, state}
        end

      {:ok, %{disposition: :connection_lost}} ->
        {:reply, {:error, :connection_lost}, state}

      _other ->
        {:reply, {:error, :permit_unavailable}, state}
    end
  end

  def handle_call(:status, _from, state) do
    permit_counts =
      Enum.reduce(state.permits, %{pending: 0, executing: 0, settling: 0}, fn
        {_id, %{phase: :pending}}, counts -> Map.update!(counts, :pending, &(&1 + 1))
        {_id, %{phase: :executing}}, counts -> Map.update!(counts, :executing, &(&1 + 1))
        {_id, %{phase: :settling}}, counts -> Map.update!(counts, :settling, &(&1 + 1))
      end)

    ticket_counts =
      Enum.reduce(
        state.tickets,
        %{pending: 0, queued: 0, ticketed: 0, waiting: 0, settling: 0},
        fn
          {_id, %{phase: :pending}}, counts -> Map.update!(counts, :pending, &(&1 + 1))
          {_id, %{phase: :queued}}, counts -> Map.update!(counts, :queued, &(&1 + 1))
          {_id, %{phase: :ticketed}}, counts -> Map.update!(counts, :ticketed, &(&1 + 1))
          {_id, %{phase: :waiting}}, counts -> Map.update!(counts, :waiting, &(&1 + 1))
          {_id, %{phase: :settling}}, counts -> Map.update!(counts, :settling, &(&1 + 1))
        end
      )

    {:reply,
     %{
       phase: state.phase,
       connections: map_size(state.connections),
       permits: map_size(state.permits),
       tickets: map_size(state.tickets),
       pending: permit_counts.pending + ticket_counts.pending,
       queued: ticket_counts.queued,
       ticketed: ticket_counts.ticketed,
       waiting: ticket_counts.waiting,
       executing: permit_counts.executing,
       settling: permit_counts.settling + ticket_counts.settling,
       connection_limit: @connection_limit,
       origin_limit: @origin_limit,
       admission_deadline_set: not is_nil(state.admission_deadline),
       lease_owners: map_size(state.lease_owners),
       owner_losses: map_size(state.owner_losses)
     }, state}
  end

  @impl true
  def handle_info({:relay_barrier, barrier_ref, :cut}, %{phase: :serving} = state)
      when is_reference(barrier_ref) do
    now = monotonic_ms()
    deadline = now + state.admission_wait_ms
    payload = cut_payload(state, deadline)
    frozen_permits = payload.permits |> Enum.map(&elem(&1, 0)) |> MapSet.new()
    frozen_tickets = payload.tickets |> Enum.map(&elem(&1, 0)) |> MapSet.new()

    timer =
      Process.send_after(self(), {:admission_deadline, barrier_ref}, state.admission_wait_ms)

    state = %{
      state
      | phase: :draining,
        cut_ref: barrier_ref,
        cut_payload: payload,
        frozen_permits: frozen_permits,
        frozen_tickets: frozen_tickets,
        admission_deadline: deadline,
        deadline_timer: timer
    }

    send(state.owner, {:relay_barrier_ack, barrier_ref, :cut, payload})
    Logger.debug("loopex daemon admission relay cut")
    {:noreply, state}
  end

  def handle_info(
        {:relay_barrier, barrier_ref, :cut},
        %{phase: :draining, cut_ref: barrier_ref} = state
      ) do
    send(state.owner, {:relay_barrier_ack, barrier_ref, :cut, state.cut_payload})
    {:noreply, state}
  end

  def handle_info({:relay_barrier, _barrier_ref, :cut}, state) do
    Logger.debug("loopex daemon admission relay stale barrier ignored")
    {:noreply, state}
  end

  def handle_info(
        {:admission_deadline, barrier_ref},
        %{phase: :draining, cut_ref: barrier_ref} = state
      ) do
    now = monotonic_ms()

    if now >= state.admission_deadline do
      state = expire_pending(state)
      Logger.debug("loopex daemon admission relay deadline reached")
      {:noreply, %{state | deadline_timer: nil}}
    else
      remaining = state.admission_deadline - now
      timer = Process.send_after(self(), {:admission_deadline, barrier_ref}, remaining)
      {:noreply, %{state | deadline_timer: timer}}
    end
  end

  def handle_info({:admission_deadline, _barrier_ref}, state), do: {:noreply, state}

  def handle_info(
        {:relay_ticket_result, task, origin_id, task_incarnation, result},
        state
      ) do
    case Map.fetch(state.tickets, origin_id) do
      {:ok,
       %{
         phase: :ticketed,
         task_pid: ^task,
         task_incarnation: ^task_incarnation,
         result: nil
       } = ticket} ->
        if bounded_record?(result) do
          ticket = %{ticket | phase: :settling, disposition: :result, result: result}
          state = put_in(state, [:tickets, origin_id], ticket)

          state =
            case ticket.settlement_mode do
              :registry ->
                send(
                  ticket.promoter_pid,
                  {:relay_ticket_settlement, self(), origin_id, ticket.settlement_ref, result}
                )

                state

              :direct ->
                state
                |> put_in([:tickets, origin_id, :settlement_acked], true)
                |> deliver_ticket_result(origin_id)
            end

          Logger.debug("loopex daemon admission relay ticket result selected")
          {:noreply, state}
        else
          {:stop, :relay_task_lost, state}
        end

      _other ->
        {:noreply, state}
    end
  end

  def handle_info(
        {:DOWN, monitor, :process, pid, reason},
        %{connection_monitors: connection_monitors} = state
      ) do
    cond do
      Map.has_key?(connection_monitors, monitor) ->
        incarnation = Map.fetch!(connection_monitors, monitor)
        state = connection_down(state, incarnation, pid)
        Logger.debug("loopex daemon admission relay connection retiring")
        {:noreply, state}

      state.registry_monitor == monitor ->
        {:stop, :registry_lost, state}

      Map.has_key?(state.lease_owner_monitors, monitor) ->
        lease_owner_down(state, monitor, pid, reason)

      Map.has_key?(state.ticket_task_monitors, monitor) ->
        ticket_task_down(state, monitor, pid, reason)

      true ->
        worker_down(state, monitor, pid, reason)
    end
  end

  def handle_info({:EXIT, owner, _reason}, %{owner: owner} = state),
    do: {:stop, :owner_lost, state}

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.permits, fn
      {_origin, %{worker_pid: worker}} when is_pid(worker) -> Process.exit(worker, :kill)
      _other -> :ok
    end)

    Enum.each(state.tickets, fn
      {_origin, ticket} ->
        if is_pid(ticket.worker_pid), do: Process.exit(ticket.worker_pid, :kill)
        if is_pid(ticket.task_pid), do: Process.exit(ticket.task_pid, :kill)
    end)

    Logger.debug("loopex daemon admission relay stop")
    :ok
  end

  @impl GenServer
  def format_status(status) do
    status
    |> Map.put(:state, :redacted_admission_relay_state)
    |> Map.put(:message, :redacted_admission_relay_message)
    |> Map.put(:reason, :redacted_admission_relay_reason)
    |> Map.put(:log, [])
  end

  defp serving(%{phase: :serving}), do: :ok
  defp serving(_state), do: {:error, :daemon_stopping}

  defp validate_origin({incarnation, slot, sequence})
       when is_binary(incarnation) and byte_size(incarnation) == 16 and
              is_integer(slot) and slot in 0..31 and is_integer(sequence) and
              sequence in 1..@uint64_max,
       do: {:ok, incarnation, slot, sequence}

  defp validate_origin(_origin_id), do: {:error, :invalid_origin}

  defp validate_class(class, session_id) when class in @session_classes do
    if is_binary(session_id) and byte_size(session_id) in 1..256,
      do: :ok,
      else: {:error, :invalid_origin}
  end

  defp validate_class(class, nil) when class in @permit_classes, do: :ok
  defp validate_class(_class, _session_id), do: {:error, :invalid_origin}

  defp validate_ticket_class(:session_create, nil, nil), do: :ok

  defp validate_ticket_class(:session_attach, session_id, nil),
    do: validate_ticket_session(session_id)

  defp validate_ticket_class(class, session_id, {owner, owner_incarnation})
       when class in @lease_ticket_classes and is_pid(owner) do
    with :ok <- validate_ticket_session(session_id),
         true <- valid_incarnation?(owner_incarnation) do
      :ok
    else
      _invalid -> {:error, :invalid_origin}
    end
  end

  defp validate_ticket_class(_class, _session_id, _owner_binding),
    do: {:error, :invalid_origin}

  defp validate_ticket_session(session_id) do
    if is_binary(session_id) and byte_size(session_id) in 1..256,
      do: :ok,
      else: {:error, :invalid_origin}
  end

  defp validate_ticket_owner(_state, class, _session_id, nil)
       when class in [:session_create, :session_attach],
       do: :ok

  defp validate_ticket_owner(state, class, session_id, owner_binding)
       when class in @lease_ticket_classes do
    case Map.get(state.lease_owners, session_id) do
      %{binding: ^owner_binding} -> :ok
      _other -> {:error, :invalid_origin}
    end
  end

  defp validate_ticket_owner(_state, _class, _session_id, _owner_binding),
    do: {:error, :invalid_origin}

  defp origin_capacity(state, connection) do
    cond do
      MapSet.size(connection.origins) >= @origins_per_connection ->
        {:error, :capacity_exceeded}

      map_size(state.permits) + map_size(state.tickets) >= @origin_limit ->
        {:error, :capacity_exceeded}

      true ->
        :ok
    end
  end

  defp sequence_available(connection, slot, sequence) do
    case Map.get(connection.sequence_by_slot, slot) do
      nil -> :ok
      previous when sequence > previous -> :ok
      _previous -> {:error, :invalid_origin}
    end
  end

  defp existing_permit(state, origin_id, class, session_id, caller) do
    cond do
      Map.has_key?(state.tickets, origin_id) ->
        :conflict

      true ->
        case Map.fetch(state.permits, origin_id) do
          {:ok, %{class: ^class, session_id: ^session_id, connection_pid: ^caller}} ->
            :exact

          {:ok, _other} ->
            :conflict

          :error ->
            :absent
        end
    end
  end

  defp existing_ticket(state, origin_id, class, session_id, owner_binding, caller) do
    cond do
      Map.has_key?(state.permits, origin_id) ->
        :conflict

      true ->
        case Map.fetch(state.tickets, origin_id) do
          {:ok,
           %{
             class: ^class,
             session_id: ^session_id,
             owner_binding: ^owner_binding,
             connection_pid: ^caller
           }} ->
            :exact

          {:ok, _other} ->
            :conflict

          :error ->
            :absent
        end
    end
  end

  defp pending_permit(state, origin_id) do
    case Map.fetch(state.permits, origin_id) do
      {:ok, %{phase: :pending} = permit} -> {:ok, permit}
      _other -> {:error, :permit_unavailable}
    end
  end

  defp pending_ticket(state, origin_id) do
    case Map.fetch(state.tickets, origin_id) do
      {:ok, %{phase: :pending} = ticket} -> {:ok, ticket}
      _other -> {:error, :ticket_unavailable}
    end
  end

  defp promotable_ticket(state, origin_id) do
    case Map.fetch(state.tickets, origin_id) do
      {:ok, %{phase: phase} = ticket} when phase in [:pending, :queued] -> {:ok, ticket}
      _other -> {:error, :ticket_unavailable}
    end
  end

  defp selected_ticket(state, origin_id, registry, settlement_ref) do
    case Map.fetch(state.tickets, origin_id) do
      {:ok,
       %{
         phase: :settling,
         disposition: :result,
         promoter_pid: ^registry,
         settlement_ref: ^settlement_ref
       } = ticket} ->
        {:ok, ticket}

      _other ->
        {:error, :ticket_unavailable}
    end
  end

  defp authenticate_registry(state, registry, registry_incarnation) do
    case state.registry do
      %{pid: ^registry, incarnation: ^registry_incarnation} -> :ok
      _other -> {:error, :registry_unavailable}
    end
  end

  defp authenticate_ticket_owner(state, ticket, owner, owner_incarnation) do
    binding = {owner, owner_incarnation}

    case Map.get(state.lease_owners, ticket.session_id) do
      %{binding: ^binding} when ticket.owner_binding == binding -> :ok
      _other -> {:error, :owner_unavailable}
    end
  end

  defp promotion_admitted(%{phase: :serving}, _origin_id), do: :ok

  defp promotion_admitted(%{phase: :draining} = state, origin_id) do
    if monotonic_ms() < state.admission_deadline and
         frozen_origin?(state, :ticket, origin_id),
       do: :ok,
       else: {:error, :daemon_stopping}
  end

  defp bind_admitted(%{phase: :serving}, _origin_id, _kind), do: :ok

  defp bind_admitted(%{phase: :draining} = state, origin_id, kind) do
    if monotonic_ms() < state.admission_deadline and frozen_origin?(state, kind, origin_id),
      do: :ok,
      else: {:error, :daemon_stopping}
  end

  defp promotion_repetition(
         state,
         origin_id,
         registry,
         registry_incarnation,
         settlement_ref
       ) do
    case Map.fetch(state.tickets, origin_id) do
      {:ok,
       %{
         phase: phase,
         promoter_pid: ^registry,
         promoter_incarnation: ^registry_incarnation,
         settlement_ref: ^settlement_ref,
         worker_pid: worker
       } = ticket}
      when phase in [:ticketed, :settling] ->
        if is_pid(worker), do: {:waiting, ticket}, else: :complete

      {:ok, %{phase: phase}} when phase in [:ticketed, :settling] ->
        :conflict

      _other ->
        :absent
    end
  end

  defp waiting_repetition(
         state,
         origin_id,
         primary_origin_id,
         registry,
         registry_incarnation
       ) do
    case Map.fetch(state.tickets, origin_id) do
      {:ok,
       %{
         phase: :waiting,
         primary_origin_id: ^primary_origin_id,
         worker_pid: worker
       } = ticket} ->
        case state.registry do
          %{pid: ^registry, incarnation: ^registry_incarnation} ->
            if(is_pid(worker), do: {:waiting, ticket}, else: :complete)

          _other ->
            :conflict
        end

      {:ok, %{phase: :waiting}} ->
        :conflict

      _other ->
        :absent
    end
  end

  defp waiter_pair(state, origin_id, primary_origin_id) when origin_id != primary_origin_id do
    with {:ok, %{phase: phase} = ticket} when phase in [:pending, :queued] <-
           Map.fetch(state.tickets, origin_id),
         {:ok, %{phase: primary_phase} = primary}
         when primary_phase in [:ticketed, :settling] <-
           Map.fetch(state.tickets, primary_origin_id),
         true <- primary.class in [:session_create, :session_resume, :session_attach],
         true <- ticket.class == primary.class,
         true <- ticket.session_id == primary.session_id,
         true <- ticket.owner_binding == primary.owner_binding do
      {:ok, ticket, primary}
    else
      _invalid -> {:error, :ticket_unavailable}
    end
  end

  defp waiter_pair(_state, _origin_id, _primary_origin_id),
    do: {:error, :invalid_waiter}

  defp start_ticket_promotion(
         state,
         ticket,
         from,
         registry,
         registry_incarnation,
         settlement_ref,
         task_fun,
         settlement_mode
       ) do
    origin_id = ticket.origin_id
    task_incarnation = random_incarnation()
    relay = self()

    {task, task_monitor} =
      spawn_monitor(fn ->
        receive do
          {:relay_ticket_go, ^relay, ^origin_id, ^task_incarnation} ->
            result = task_fun.()
            send(relay, {:relay_ticket_result, self(), origin_id, task_incarnation, result})
        end
      end)

    ticket = %{
      ticket
      | phase: :ticketed,
        promoter_pid: registry,
        promoter_incarnation: registry_incarnation,
        settlement_ref: settlement_ref,
        settlement_mode: settlement_mode,
        task_pid: task,
        task_incarnation: task_incarnation,
        task_monitor: task_monitor,
        task_down: false,
        result: nil,
        settlement_acked: false,
        result_delivered: false,
        promotion_waiters: if(is_pid(ticket.worker_pid), do: [from], else: [])
    }

    state =
      state
      |> put_in([:tickets, origin_id], ticket)
      |> put_in([:ticket_task_monitors, task_monitor], origin_id)

    send(task, {:relay_ticket_go, relay, origin_id, task_incarnation})
    Logger.debug("loopex daemon admission relay ticket promoted")

    if is_pid(ticket.worker_pid) do
      if Process.alive?(ticket.worker_pid), do: Process.exit(ticket.worker_pid, :kill)
      {:noreply, state}
    else
      {:reply, {:ok, origin_id}, state}
    end
  end

  defp valid_worker(worker, worker_incarnation, caller) do
    if is_pid(worker) and worker != caller and valid_incarnation?(worker_incarnation),
      do: :ok,
      else: {:error, :invalid_worker}
  end

  defp caller_connection(state, incarnation, caller) do
    case Map.fetch(state.connections, incarnation) do
      {:ok, %{pid: ^caller, phase: :live} = connection} -> {:ok, connection}
      _other -> {:error, :connection_unavailable}
    end
  end

  defp exact_connection?(state, incarnation, caller, retirement_recipient) do
    match?(
      %{pid: ^caller, retirement_recipient: ^retirement_recipient, phase: :live},
      Map.get(state.connections, incarnation)
    )
  end

  defp valid_incarnation?(incarnation),
    do: is_binary(incarnation) and byte_size(incarnation) == 16

  defp bounded_record?(result) when is_map(result) and not is_struct(result) do
    try do
      match?({:ok, _encoded}, Frame.encode(result))
    rescue
      _error -> false
    catch
      _kind, _reason -> false
    end
  end

  defp bounded_record?(_result), do: false

  defp cut_payload(state, deadline) do
    permits =
      state.permits
      |> Enum.map(fn {origin_id, permit} -> {origin_id, frozen_phase(permit.phase)} end)
      |> Enum.sort()

    tickets =
      state.tickets
      |> Enum.map(fn {origin_id, ticket} -> {origin_id, frozen_phase(ticket.phase)} end)
      |> Enum.sort()

    %{
      admission_deadline: deadline,
      tickets: tickets,
      permits: permits
    }
  end

  defp frozen_phase(:pending), do: :pending
  defp frozen_phase(:executing), do: :executing
  defp frozen_phase(:settling), do: :settling
  defp frozen_phase(:queued), do: :queued
  defp frozen_phase(:ticketed), do: :ticketed
  defp frozen_phase(:waiting), do: :waiting

  defp frozen_origin?(state, :permit, origin_id),
    do: MapSet.member?(state.frozen_permits, origin_id)

  defp frozen_origin?(state, :ticket, origin_id),
    do: MapSet.member?(state.frozen_tickets, origin_id)

  defp expire_if_due(%{phase: :draining} = state) do
    if monotonic_ms() >= state.admission_deadline, do: expire_pending(state), else: state
  end

  defp expire_if_due(state), do: state

  defp admission_expired?(%{phase: :draining} = state),
    do: monotonic_ms() >= state.admission_deadline

  defp admission_expired?(_state), do: false

  defp expire_pending(state) do
    state =
      state.permits
      |> Enum.filter(fn {_origin, permit} -> permit.phase == :pending end)
      |> Enum.reduce(state, fn {origin_id, permit}, acc ->
        send(permit.connection_pid, {:relay_permit_cancelled, origin_id, :daemon_stopping})
        remove_permit(acc, origin_id)
      end)

    state.tickets
    |> Enum.filter(fn {_origin, ticket} -> ticket.phase in [:pending, :queued] end)
    |> Enum.reduce(state, fn {origin_id, ticket}, acc ->
      send(ticket.connection_pid, {:relay_ticket_cancelled, origin_id, :daemon_stopping})

      case ticket do
        %{phase: :queued, worker_pid: worker} when is_pid(worker) ->
          if Process.alive?(worker), do: Process.exit(worker, :kill)

          ticket = %{
            ticket
            | phase: :settling,
              disposition: :shutdown_cancelled
          }

          put_in(acc, [:tickets, origin_id], ticket)

        %{phase: :pending} ->
          remove_ticket(acc, origin_id)
      end
    end)
  end

  defp connection_down(state, incarnation, pid) do
    case Map.fetch(state.connections, incarnation) do
      {:ok, %{pid: ^pid} = connection} ->
        connection = %{connection | phase: :closing}

        state =
          state
          |> put_in([:connections, incarnation], connection)
          |> update_in([:connection_pids], &Map.delete(&1, pid))
          |> update_in([:connection_monitors], &Map.delete(&1, connection.monitor))

        Enum.reduce(connection.origins, state, fn origin_id, acc ->
          lose_connection_origin(acc, origin_id)
        end)
        |> maybe_retire_connection(incarnation)

      _other ->
        state
    end
  end

  defp lose_connection_origin(state, origin_id) do
    cond do
      Map.has_key?(state.permits, origin_id) -> lose_connection_permit(state, origin_id)
      Map.has_key?(state.tickets, origin_id) -> lose_connection_ticket(state, origin_id)
      true -> state
    end
  end

  defp lose_connection_permit(state, origin_id) do
    case Map.fetch(state.permits, origin_id) do
      {:ok, %{phase: :pending}} ->
        remove_permit(state, origin_id)

      {:ok, %{worker_pid: worker} = permit} when is_pid(worker) ->
        if Process.alive?(worker), do: Process.exit(worker, :kill)

        disposition = permit.disposition || :connection_lost
        permit = %{permit | phase: :settling, disposition: disposition, result: nil}
        put_in(state, [:permits, origin_id], permit)

      _other ->
        state
    end
  end

  defp lose_connection_ticket(state, origin_id) do
    case Map.fetch(state.tickets, origin_id) do
      {:ok, %{phase: :pending}} ->
        remove_ticket(state, origin_id)

      {:ok, %{phase: :waiting, worker_pid: nil}} ->
        remove_ticket(state, origin_id)

      {:ok, %{phase: :waiting, worker_pid: worker} = ticket} when is_pid(worker) ->
        if Process.alive?(worker), do: Process.exit(worker, :kill)

        ticket = %{ticket | phase: :settling, disposition: :connection_lost}
        put_in(state, [:tickets, origin_id], ticket)

      {:ok, %{phase: :queued, worker_pid: worker} = ticket} when is_pid(worker) ->
        if Process.alive?(worker), do: Process.exit(worker, :kill)

        ticket = %{ticket | phase: :settling, disposition: :connection_lost}
        put_in(state, [:tickets, origin_id], ticket)

      _other ->
        state
    end
  end

  defp lease_owner_down(state, monitor, pid, _reason) do
    {{session_id, {^pid, owner_incarnation} = binding}, owner_monitors} =
      Map.pop(state.lease_owner_monitors, monitor)

    lease_owners =
      case Map.get(state.lease_owners, session_id) do
        %{binding: ^binding} -> Map.delete(state.lease_owners, session_id)
        _other -> state.lease_owners
      end

    state = %{
      state
      | lease_owner_monitors: owner_monitors,
        lease_owners: lease_owners
    }

    affected =
      state.tickets
      |> Enum.filter(fn
        {_origin_id, %{owner_binding: ^binding, phase: phase}}
        when phase in [:pending, :queued] ->
          true

        _other ->
          false
      end)
      |> Enum.map(&elem(&1, 0))
      |> MapSet.new()

    state =
      Enum.reduce(affected, state, fn origin_id, acc ->
        ticket = Map.fetch!(acc.tickets, origin_id)

        if is_pid(ticket.worker_pid) and Process.alive?(ticket.worker_pid),
          do: Process.exit(ticket.worker_pid, :kill)

        ticket = %{ticket | phase: :settling, disposition: :owner_lost}
        put_in(acc, [:tickets, origin_id], ticket)
      end)

    loss = %{session_id: session_id, origins: affected}
    state = put_in(state, [:owner_losses, binding], loss)

    send(
      state.owner,
      {:relay_owner_lost, self(), session_id, pid, owner_incarnation,
       affected |> MapSet.to_list() |> Enum.sort()}
    )

    if Enum.all?(affected, &(not owner_loss_worker_live?(state, &1))) do
      send(state.owner, {:relay_owner_loss_ready, self(), pid, owner_incarnation})
    end

    Logger.debug("loopex daemon admission relay lease owner lost")
    {:noreply, state}
  end

  defp owner_loss_worker_live?(state, origin_id) do
    match?(%{worker_pid: worker} when is_pid(worker), Map.get(state.tickets, origin_id))
  end

  defp worker_down(state, monitor, pid, _reason) do
    case Map.pop(state.worker_monitors, monitor) do
      {nil, _worker_monitors} ->
        {:noreply, state}

      {{:permit, origin_id}, worker_monitors} ->
        state = %{state | worker_monitors: worker_monitors}
        permit_worker_down(state, origin_id, pid)

      {{:ticket, origin_id}, worker_monitors} ->
        state = %{state | worker_monitors: worker_monitors}
        ticket_worker_down(state, origin_id, pid)
    end
  end

  defp permit_worker_down(state, origin_id, pid) do
    case Map.fetch(state.permits, origin_id) do
      {:ok, %{worker_pid: ^pid} = permit} ->
        state =
          if permit.disposition do
            remove_permit(state, origin_id)
          else
            if Process.alive?(permit.connection_pid) do
              send(
                permit.connection_pid,
                {:relay_permit_failed, origin_id, :worker_lost}
              )
            end

            remove_permit(state, origin_id)
          end

        Logger.debug("loopex daemon admission relay permit worker reaped")
        {:noreply, maybe_retire_connection(state, permit.connection_incarnation)}

      _other ->
        {:noreply, state}
    end
  end

  defp ticket_worker_down(state, origin_id, pid) do
    case Map.fetch(state.tickets, origin_id) do
      {:ok,
       %{
         worker_pid: ^pid,
         phase: :settling,
         disposition: :owner_lost,
         owner_binding: {owner, owner_incarnation}
       } = ticket} ->
        ticket = %{
          ticket
          | worker_pid: nil,
            worker_incarnation: nil,
            worker_monitor: nil
        }

        state = put_in(state, [:tickets, origin_id], ticket)

        case Map.get(state.owner_losses, {owner, owner_incarnation}) do
          %{origins: origins} ->
            if Enum.all?(origins, &(not owner_loss_worker_live?(state, &1))) do
              send(
                state.owner,
                {:relay_owner_loss_ready, self(), owner, owner_incarnation}
              )
            end

          _other ->
            :ok
        end

        Logger.debug("loopex daemon admission relay owner-loss worker reaped")
        {:noreply, state}

      {:ok, %{worker_pid: ^pid, phase: :waiting} = ticket} ->
        Enum.each(ticket.waiting_callers, fn from ->
          GenServer.reply(from, {:ok, ticket.primary_origin_id})
        end)

        ticket = %{
          ticket
          | worker_pid: nil,
            worker_incarnation: nil,
            worker_monitor: nil,
            waiting_callers: []
        }

        Logger.debug("loopex daemon admission relay waiting worker retired")
        {:noreply, put_in(state, [:tickets, origin_id], ticket)}

      {:ok, %{worker_pid: ^pid, phase: phase} = ticket}
      when phase in [:ticketed, :settling] and is_pid(ticket.task_pid) ->
        Enum.each(ticket.promotion_waiters, fn from ->
          GenServer.reply(from, {:ok, origin_id})
        end)

        ticket = %{
          ticket
          | worker_pid: nil,
            worker_incarnation: nil,
            worker_monitor: nil,
            promotion_waiters: []
        }

        state = put_in(state, [:tickets, origin_id], ticket)
        state = finalize_ticket_if_complete(state, origin_id)
        Logger.debug("loopex daemon admission relay ticket worker retired")
        {:noreply, state}

      {:ok, %{worker_pid: ^pid} = ticket} ->
        state =
          if ticket.disposition do
            Enum.each(ticket.waiting_callers, fn from ->
              GenServer.reply(from, {:error, :ticket_unavailable})
            end)

            Enum.each(ticket.promotion_waiters, fn from ->
              GenServer.reply(from, {:error, :ticket_unavailable})
            end)

            remove_ticket(state, origin_id)
          else
            if Process.alive?(ticket.connection_pid) do
              send(
                ticket.connection_pid,
                {:relay_ticket_failed, origin_id, :worker_lost}
              )
            end

            remove_ticket(state, origin_id)
          end

        Logger.debug("loopex daemon admission relay ticket worker reaped")
        {:noreply, maybe_retire_connection(state, ticket.connection_incarnation)}

      _other ->
        {:noreply, state}
    end
  end

  defp ticket_task_down(state, monitor, pid, _reason) do
    {origin_id, task_monitors} = Map.pop(state.ticket_task_monitors, monitor)
    state = %{state | ticket_task_monitors: task_monitors}

    case Map.fetch(state.tickets, origin_id) do
      {:ok, %{task_pid: ^pid, result: nil} = ticket} ->
        if state.phase == :serving do
          {:stop, :relay_task_lost, state}
        else
          ticket = %{ticket | task_down: true}
          Logger.debug("loopex daemon admission relay ticket task unresolved")
          {:noreply, put_in(state, [:tickets, origin_id], ticket)}
        end

      {:ok, %{task_pid: ^pid} = ticket} ->
        ticket = %{ticket | task_down: true}
        state = put_in(state, [:tickets, origin_id], ticket)
        state = finalize_ticket_if_complete(state, origin_id)
        Logger.debug("loopex daemon admission relay ticket task reaped")
        {:noreply, state}

      _other ->
        {:noreply, state}
    end
  end

  defp deliver_ticket_result(state, origin_id) do
    case Map.fetch(state.tickets, origin_id) do
      {:ok,
       %{
         settlement_acked: true,
         result_delivered: false,
         disposition: :result,
         result: result
       } = ticket} ->
        if Process.alive?(ticket.connection_pid) do
          send(ticket.connection_pid, {:relay_ticket_result, origin_id, result})
        end

        ticket = %{ticket | result_delivered: true}
        state = put_in(state, [:tickets, origin_id], ticket)
        state = deliver_waiting_results(state, origin_id, result)
        finalize_ticket_if_complete(state, origin_id)

      _other ->
        state
    end
  end

  defp deliver_waiting_results(state, primary_origin_id, result) do
    state.tickets
    |> Enum.filter(fn
      {_origin_id, %{phase: :waiting, primary_origin_id: ^primary_origin_id}} -> true
      _other -> false
    end)
    |> Enum.reduce(state, fn {origin_id, waiter}, acc ->
      if Process.alive?(waiter.connection_pid) do
        send(waiter.connection_pid, {:relay_ticket_result, origin_id, result})
      end

      acc
      |> remove_ticket(origin_id)
      |> maybe_retire_connection(waiter.connection_incarnation)
    end)
  end

  defp finalize_ticket_if_complete(state, origin_id) do
    case Map.fetch(state.tickets, origin_id) do
      {:ok,
       %{
         task_down: true,
         result_delivered: true,
         worker_pid: nil,
         connection_incarnation: incarnation
       }} ->
        state
        |> remove_ticket(origin_id)
        |> maybe_retire_connection(incarnation)

      _other ->
        state
    end
  end

  defp remove_permit(state, origin_id) do
    case Map.pop(state.permits, origin_id) do
      {nil, _permits} ->
        state

      {permit, permits} ->
        connections =
          case Map.fetch(state.connections, permit.connection_incarnation) do
            {:ok, connection} ->
              connection = %{connection | origins: MapSet.delete(connection.origins, origin_id)}
              Map.put(state.connections, permit.connection_incarnation, connection)

            :error ->
              state.connections
          end

        %{state | permits: permits, connections: connections}
    end
  end

  defp remove_ticket(state, origin_id) do
    case Map.pop(state.tickets, origin_id) do
      {nil, _tickets} ->
        state

      {ticket, tickets} ->
        connections =
          case Map.fetch(state.connections, ticket.connection_incarnation) do
            {:ok, connection} ->
              connection = %{connection | origins: MapSet.delete(connection.origins, origin_id)}
              Map.put(state.connections, ticket.connection_incarnation, connection)

            :error ->
              state.connections
          end

        %{state | tickets: tickets, connections: connections}
    end
  end

  defp maybe_retire_connection(state, incarnation) do
    case Map.fetch(state.connections, incarnation) do
      {:ok, %{phase: :closing, origins: origins} = connection} ->
        if MapSet.size(origins) == 0 do
          send(
            connection.retirement_recipient,
            {:relay_connection_retired, self(), incarnation}
          )

          Logger.debug("loopex daemon admission relay connection retired")
          %{state | connections: Map.delete(state.connections, incarnation)}
        else
          state
        end

      _other ->
        state
    end
  end

  defp monotonic_ms, do: System.monotonic_time(:millisecond)
  defp random_incarnation, do: :crypto.strong_rand_bytes(16)
end
