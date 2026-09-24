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
  shutdown order requires. Ticketed calls and actor-bound acquire/release
  permits share that ledger. A lease permit records its intended actor before
  acknowledgement, retains the distinct request worker, and moves to execution
  only through the exact actor's compare-and-set. Result, connection loss and
  owner loss remain selected here until their owning coordinator settles them.
  The lease freeze wins every still-executing lease permit as terminal
  `shutdown_admitted` and names every lease row in one fixed tagged set; after
  it no lease settlement renders client output, and after the cut no owner
  loss sends a correlated `control_owner_lost` refusal.
  An idle lease owner moves to retiring only when no permit or ticket remains
  for its session; its actual monitored `DOWN` then reports retirement
  completion without being reclassified as owner loss. Daemon-owner result
  selection and settlement use exact ref-tagged messages, so the owner can keep
  classifying component exits while the relay serializes those transitions.
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

  @lease_permit_classes [:session_acquire_control, :session_release_control]

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
  @type lease_permit_class :: :session_acquire_control | :session_release_control

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
  @spec prepare_lease_owner_retirement(pid(), binary(), binary()) ::
          :ok
          | {:error, :daemon_stopping | :owner_busy | :owner_unavailable | :invalid_owner}
  def prepare_lease_owner_retirement(relay, session_id, owner_incarnation) do
    GenServer.call(
      relay,
      {:prepare_lease_owner_retirement, session_id, owner_incarnation},
      @control_timeout_ms
    )
  end

  @doc false
  @spec classify_owner_loss(
          pid(),
          reference(),
          binary(),
          binary(),
          pid(),
          binary(),
          binary() | nil
        ) :: :ok
  def classify_owner_loss(
        relay,
        classification_ref,
        daemon_incarnation,
        session_id,
        owner,
        owner_incarnation,
        holder_connection_incarnation
      ) do
    send(
      relay,
      {:relay_owner_loss_classification, self(), daemon_incarnation, classification_ref,
       session_id, owner, owner_incarnation, holder_connection_incarnation}
    )

    :ok
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
  @spec open_lease_permit(
          pid(),
          pid(),
          origin_id(),
          lease_permit_class(),
          binary(),
          pid(),
          binary(),
          pid(),
          binary(),
          reference() | nil
        ) ::
          {:ok, origin_id()}
          | {:error,
             :actor_lost
             | :actor_retiring
             | :capacity_exceeded
             | :connection_unavailable
             | :daemon_stopping
             | :invalid_actor
             | :invalid_origin
             | :invalid_worker
             | :permit_conflict}
  def open_lease_permit(
        relay,
        connection,
        origin_id,
        class,
        session_id,
        actor,
        actor_incarnation,
        worker,
        worker_incarnation,
        start_op_ref \\ nil
      ) do
    GenServer.call(
      relay,
      {:open_lease_permit, connection, origin_id, class, session_id, actor, actor_incarnation,
       worker, worker_incarnation, start_op_ref},
      @control_timeout_ms
    )
  end

  @doc false
  @spec claim_lease_permit(pid(), origin_id(), binary(), reference() | nil) ::
          :ok
          | {:error,
             :connection_lost
             | :daemon_stopping
             | :invalid_actor
             | :owner_lost
             | :permit_unavailable
             | :result
             | :shutdown_admitted
             | :shutdown_cancelled}
  def claim_lease_permit(relay, origin_id, actor_incarnation, start_op_ref \\ nil) do
    GenServer.call(
      relay,
      {:claim_lease_permit, origin_id, actor_incarnation, start_op_ref},
      @control_timeout_ms
    )
  end

  @doc false
  @spec complete_lease_permit(pid(), origin_id(), binary(), map()) ::
          :ok
          | {:error,
             :connection_lost
             | :invalid_actor
             | :invalid_result
             | :owner_lost
             | :permit_unavailable}
  def complete_lease_permit(relay, origin_id, actor_incarnation, result) do
    GenServer.call(
      relay,
      {:complete_lease_permit, origin_id, actor_incarnation, result},
      @control_timeout_ms
    )
  end

  @doc false
  @spec select_lease_result(
          pid(),
          origin_id(),
          pid(),
          binary(),
          reference(),
          map()
        ) ::
          :ok
          | {:error,
             :connection_lost
             | :invalid_actor
             | :invalid_result
             | :owner_lost
             | :permit_unavailable}
  def select_lease_result(
        relay,
        origin_id,
        actor,
        actor_incarnation,
        settlement_ref,
        result
      ) do
    GenServer.call(
      relay,
      {:select_lease_result, origin_id, actor, actor_incarnation, settlement_ref, result},
      @control_timeout_ms
    )
  end

  @doc false
  @spec settle_lease_result(pid(), origin_id(), reference()) ::
          :ok | {:error, :permit_unavailable | :worker_unsettled}
  def settle_lease_result(relay, origin_id, settlement_ref) do
    GenServer.call(
      relay,
      {:settle_lease_result, origin_id, settlement_ref},
      @control_timeout_ms
    )
  end

  @doc false
  @spec settle_lease_disposition(pid(), origin_id(), atom(), reference()) ::
          :ok | {:error, :permit_unavailable | :worker_unsettled}
  def settle_lease_disposition(relay, origin_id, disposition, settlement_ref) do
    GenServer.call(
      relay,
      {:settle_lease_disposition, origin_id, disposition, settlement_ref},
      @control_timeout_ms
    )
  end

  @doc false
  @spec request_lease_result_selection(
          pid(),
          reference(),
          binary(),
          origin_id(),
          pid(),
          binary(),
          reference(),
          map()
        ) :: :ok
  def request_lease_result_selection(
        relay,
        operation_ref,
        owner_incarnation,
        origin_id,
        actor,
        actor_incarnation,
        settlement_ref,
        result
      ) do
    send(
      relay,
      {:relay_lease_operation, operation_ref, self(), owner_incarnation, :select_result,
       {origin_id, actor, actor_incarnation, settlement_ref, result}}
    )

    :ok
  end

  @doc false
  @spec request_lease_result_settlement(
          pid(),
          reference(),
          binary(),
          origin_id(),
          reference()
        ) :: :ok
  def request_lease_result_settlement(
        relay,
        operation_ref,
        owner_incarnation,
        origin_id,
        settlement_ref
      ) do
    send(
      relay,
      {:relay_lease_operation, operation_ref, self(), owner_incarnation, :settle_result,
       {origin_id, settlement_ref}}
    )

    :ok
  end

  @doc false
  @spec request_lease_disposition_settlement(
          pid(),
          reference(),
          binary(),
          origin_id(),
          :connection_lost | :owner_lost,
          reference()
        ) :: :ok
  def request_lease_disposition_settlement(
        relay,
        operation_ref,
        owner_incarnation,
        origin_id,
        disposition,
        settlement_ref
      ) do
    send(
      relay,
      {:relay_lease_operation, operation_ref, self(), owner_incarnation, :settle_disposition,
       {origin_id, disposition, settlement_ref}}
    )

    :ok
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
             | :ticket_outstanding
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
  @spec promote_resume_ticket(
          pid(),
          origin_id(),
          binary(),
          settlement_ref(),
          pid(),
          binary(),
          (-> map())
        ) ::
          {:ok, origin_id()}
          | {:error,
             :daemon_stopping
             | :invalid_promotion
             | :owner_unavailable
             | :registry_unavailable
             | :ticket_outstanding
             | :ticket_unavailable}
  def promote_resume_ticket(
        relay,
        origin_id,
        registry_incarnation,
        settlement_ref,
        owner,
        owner_incarnation,
        task_fun
      ) do
    GenServer.call(
      relay,
      {:promote_ticket, origin_id, registry_incarnation, settlement_ref, task_fun,
       {owner, owner_incarnation}},
      @control_timeout_ms
    )
  end

  @doc false
  @spec authorize_resume_ticket(pid(), origin_id(), binary(), pid(), binary()) ::
          :ok
          | {:error,
             :daemon_stopping
             | :owner_unavailable
             | :registry_unavailable
             | :ticket_unavailable}
  def authorize_resume_ticket(
        relay,
        origin_id,
        registry_incarnation,
        owner,
        owner_incarnation
      ) do
    GenServer.call(
      relay,
      {:authorize_resume_ticket, origin_id, registry_incarnation, owner, owner_incarnation},
      @control_timeout_ms
    )
  end

  @doc false
  @spec refuse_resume_ticket(
          pid(),
          origin_id(),
          binary(),
          pid(),
          binary(),
          map()
        ) ::
          {:ok, origin_id()}
          | {:error,
             :daemon_stopping
             | :invalid_result
             | :owner_unavailable
             | :registry_unavailable
             | :ticket_outstanding
             | :ticket_unavailable}
  def refuse_resume_ticket(
        relay,
        origin_id,
        registry_incarnation,
        owner,
        owner_incarnation,
        result
      ) do
    GenServer.call(
      relay,
      {:refuse_resume_ticket, origin_id, registry_incarnation, owner, owner_incarnation, result},
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
             | :ticket_outstanding
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

  @doc """
  ## Concept

  The connection registry's requests to the relay, sent without waiting, so a
  slow relay delays only the registry flow that needs its answer.

  ## Technical depth

  Each function sends exactly the request its blocking counterpart above
  sends and returns the OTP request identifier. The registry consumes the
  answer, or the relay's exit, as a message under its own request instant.
  """
  @spec authorize_resume_ticket_request(pid(), origin_id(), binary(), pid(), binary()) ::
          :gen_server.request_id()
  def authorize_resume_ticket_request(
        relay,
        origin_id,
        registry_incarnation,
        owner,
        owner_incarnation
      ) do
    :gen_server.send_request(
      relay,
      {:authorize_resume_ticket, origin_id, registry_incarnation, owner, owner_incarnation}
    )
  end

  @doc false
  @spec wait_for_ticket_request(pid(), origin_id(), origin_id(), binary()) ::
          :gen_server.request_id()
  def wait_for_ticket_request(relay, origin_id, primary_origin_id, registry_incarnation) do
    :gen_server.send_request(
      relay,
      {:wait_for_ticket, origin_id, primary_origin_id, registry_incarnation}
    )
  end

  @doc false
  @spec promote_ticket_request(pid(), origin_id(), binary(), settlement_ref(), (-> map())) ::
          :gen_server.request_id()
  def promote_ticket_request(relay, origin_id, registry_incarnation, settlement_ref, task_fun) do
    :gen_server.send_request(
      relay,
      {:promote_ticket, origin_id, registry_incarnation, settlement_ref, task_fun}
    )
  end

  @doc false
  @spec promote_resume_ticket_request(
          pid(),
          origin_id(),
          binary(),
          settlement_ref(),
          pid(),
          binary(),
          (-> map())
        ) :: :gen_server.request_id()
  def promote_resume_ticket_request(
        relay,
        origin_id,
        registry_incarnation,
        settlement_ref,
        owner,
        owner_incarnation,
        task_fun
      ) do
    :gen_server.send_request(
      relay,
      {:promote_ticket, origin_id, registry_incarnation, settlement_ref, task_fun,
       {owner, owner_incarnation}}
    )
  end

  @doc false
  @spec refuse_resume_ticket_request(pid(), origin_id(), binary(), pid(), binary(), map()) ::
          :gen_server.request_id()
  def refuse_resume_ticket_request(
        relay,
        origin_id,
        registry_incarnation,
        owner,
        owner_incarnation,
        result
      ) do
    :gen_server.send_request(
      relay,
      {:refuse_resume_ticket, origin_id, registry_incarnation, owner, owner_incarnation, result}
    )
  end

  @doc false
  @spec settle_ticket_request(pid(), origin_id(), binary(), settlement_ref()) ::
          :gen_server.request_id()
  def settle_ticket_request(relay, origin_id, registry_incarnation, settlement_ref) do
    :gen_server.send_request(
      relay,
      {:settle_ticket, origin_id, registry_incarnation, settlement_ref}
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
          phase: :serving | :draining | :lease_ops_frozen | :quiescing | :sealed | :tearing_down,
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
          retiring_lease_owners: non_neg_integer(),
          owner_losses: non_neg_integer()
        }
  def status(relay, timeout \\ @control_timeout_ms),
    do: GenServer.call(relay, :status, timeout)

  @doc false
  @spec pending_origins(pid(), [binary()], timeout()) :: non_neg_integer()
  def pending_origins(relay, origin_ids, timeout \\ @control_timeout_ms)
      when is_list(origin_ids),
      do: GenServer.call(relay, {:pending_origins, origin_ids}, timeout)

  @impl true
  def init(options) do
    Process.flag(:trap_exit, true)
    owner = Keyword.fetch!(options, :owner)
    owner_incarnation = Keyword.fetch!(options, :owner_incarnation)
    admission_wait_ms = Keyword.fetch!(options, :admission_wait_ms)

    if is_pid(owner) and valid_incarnation?(owner_incarnation) and
         is_integer(admission_wait_ms) and admission_wait_ms > 0 and
         admission_wait_ms <= @max_timer_ms do
      Process.link(owner)
      Logger.debug("loopex daemon admission relay start")

      {:ok,
       %{
         owner: owner,
         owner_incarnation: owner_incarnation,
         admission_wait_ms: admission_wait_ms,
         phase: :serving,
         barrier: nil,
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
        row = %{binding: binding, monitor: monitor, phase: :live}

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
        {:prepare_lease_owner_retirement, session_id, owner_incarnation},
        {owner, _tag},
        state
      ) do
    binding = {owner, owner_incarnation}

    case Map.fetch(state.lease_owners, session_id) do
      {:ok, %{binding: ^binding, phase: :retiring}} ->
        {:reply, :ok, state}

      {:ok, %{binding: ^binding, phase: :live} = row} ->
        cond do
          state.phase != :serving ->
            {:reply, {:error, :daemon_stopping}, state}

          lease_session_busy?(state, session_id) ->
            {:reply, {:error, :owner_busy}, state}

          true ->
            Logger.debug("loopex daemon admission relay lease owner retiring")
            {:reply, :ok, put_in(state, [:lease_owners, session_id], %{row | phase: :retiring})}
        end

      {:ok, _other} ->
        {:reply, {:error, :owner_unavailable}, state}

      :error ->
        {:reply, {:error, :owner_unavailable}, state}
    end
  end

  def handle_call({:prepare_lease_owner_retirement, _, _}, _from, state),
    do: {:reply, {:error, :invalid_owner}, state}

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
            kind: :ordinary,
            class: class,
            session_id: session_id,
            connection_incarnation: incarnation,
            connection_pid: caller,
            phase: :pending,
            actor_pid: nil,
            actor_incarnation: nil,
            start_op_ref: nil,
            worker_pid: nil,
            worker_incarnation: nil,
            worker_monitor: nil,
            disposition: nil,
            settlement_ref: nil,
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
        {:open_lease_permit, connection_pid, origin_id, class, session_id, actor,
         actor_incarnation, worker, worker_incarnation, start_op_ref},
        {caller, _tag},
        %{owner: caller} = state
      ) do
    requested = %{
      kind: :lease,
      class: class,
      session_id: session_id,
      connection_pid: connection_pid,
      actor_pid: actor,
      actor_incarnation: actor_incarnation,
      worker_pid: worker,
      worker_incarnation: worker_incarnation,
      start_op_ref: start_op_ref
    }

    case existing_lease_permit(state, origin_id, requested) do
      :exact ->
        {:reply, {:ok, origin_id}, state}

      :conflict ->
        {:reply, {:error, :permit_conflict}, state}

      :absent ->
        with :ok <- serving(state),
             {:ok, incarnation, slot, sequence} <- validate_origin(origin_id),
             {:ok, connection} <- exact_live_connection(state, incarnation, connection_pid),
             :ok <- validate_lease_permit_class(class, session_id),
             :ok <-
               validate_lease_actor(
                 state,
                 class,
                 session_id,
                 actor,
                 actor_incarnation,
                 start_op_ref
               ),
             :ok <- valid_lease_worker(worker, worker_incarnation, connection_pid, actor),
             :ok <- origin_capacity(state, connection),
             :ok <- sequence_available(connection, slot, sequence) do
          monitor = Process.monitor(worker)

          permit = %{
            origin_id: origin_id,
            kind: :lease,
            class: class,
            session_id: session_id,
            connection_incarnation: incarnation,
            connection_pid: connection_pid,
            phase: :pending,
            actor_pid: actor,
            actor_incarnation: actor_incarnation,
            start_op_ref: start_op_ref,
            worker_pid: worker,
            worker_incarnation: worker_incarnation,
            worker_monitor: monitor,
            disposition: nil,
            settlement_ref: nil,
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
            |> put_in([:worker_monitors, monitor], {:permit, origin_id})

          Logger.debug("loopex daemon admission relay lease permit opened")
          {:reply, {:ok, origin_id}, state}
        else
          {:error, reason} -> {:reply, {:error, reason}, state}
        end
    end
  end

  def handle_call({:open_lease_permit, _, _, _, _, _, _, _, _, _}, _from, state),
    do: {:reply, {:error, :invalid_actor}, state}

  def handle_call(
        {:claim_lease_permit, origin_id, actor_incarnation, start_op_ref},
        {caller, _tag},
        state
      ) do
    state = expire_if_due(state)

    case Map.fetch(state.permits, origin_id) do
      {:ok,
       %{
         kind: :lease,
         phase: :executing,
         actor_pid: ^caller,
         actor_incarnation: ^actor_incarnation,
         start_op_ref: ^start_op_ref
       }} ->
        {:reply, :ok, state}

      {:ok,
       %{
         kind: :lease,
         phase: :pending,
         actor_pid: ^caller,
         actor_incarnation: ^actor_incarnation,
         start_op_ref: ^start_op_ref,
         worker_pid: worker,
         worker_incarnation: worker_incarnation
       } = permit} ->
        with :ok <- bind_admitted(state, origin_id, :permit),
             true <- is_pid(worker) and Process.alive?(worker) do
          permit = %{permit | phase: :executing}
          state = put_in(state, [:permits, origin_id], permit)
          send(worker, {:relay_go, origin_id, worker_incarnation})
          Logger.debug("loopex daemon admission relay lease permit executing")
          {:reply, :ok, state}
        else
          false -> {:reply, {:error, :permit_unavailable}, state}
          {:error, reason} -> {:reply, {:error, reason}, state}
        end

      # Concept: the permit's own actor learns the exact disposition that
      # already won the row, never a generic actor refusal.
      {:ok,
       %{
         kind: :lease,
         actor_pid: ^caller,
         actor_incarnation: ^actor_incarnation,
         start_op_ref: ^start_op_ref,
         disposition: disposition
       }}
      when not is_nil(disposition) ->
        {:reply, {:error, disposition}, state}

      {:ok, %{kind: :lease}} ->
        {:reply, {:error, :invalid_actor}, state}

      _other ->
        {:reply, {:error, :permit_unavailable}, state}
    end
  end

  def handle_call(
        {:complete_lease_permit, origin_id, actor_incarnation, result},
        {caller, _tag},
        state
      ) do
    case Map.fetch(state.permits, origin_id) do
      {:ok,
       %{
         kind: :lease,
         phase: :executing,
         actor_pid: ^caller,
         actor_incarnation: ^actor_incarnation,
         disposition: nil
       } = permit} ->
        if bounded_record?(result) do
          state = select_direct_lease_result(state, origin_id, permit, result)
          Logger.debug("loopex daemon admission relay lease result")
          {:reply, :ok, state}
        else
          {:reply, {:error, :invalid_result}, state}
        end

      {:ok, %{kind: :lease, disposition: disposition}}
      when disposition in [:connection_lost, :owner_lost] ->
        {:reply, {:error, disposition}, state}

      # Concept: the freeze already won this row, so a later actor result is
      # cleanup-only and reaches no client.
      {:ok, %{kind: :lease, disposition: :shutdown_admitted}} ->
        {:reply, {:error, :daemon_stopping}, state}

      {:ok, %{kind: :lease}} ->
        {:reply, {:error, :invalid_actor}, state}

      _other when state.phase in [:lease_ops_frozen, :quiescing, :sealed, :tearing_down] ->
        {:reply, {:error, :daemon_stopping}, state}

      _other ->
        {:reply, {:error, :permit_unavailable}, state}
    end
  end

  def handle_call(
        {:select_lease_result, origin_id, actor, actor_incarnation, settlement_ref, result},
        {caller, _tag},
        %{owner: caller} = state
      ) do
    {reply, state} =
      do_select_lease_result(
        state,
        origin_id,
        actor,
        actor_incarnation,
        settlement_ref,
        result
      )

    {:reply, reply, state}
  end

  def handle_call({:select_lease_result, _, _, _, _, _}, _from, state),
    do: {:reply, {:error, :invalid_actor}, state}

  def handle_call(
        {:settle_lease_result, origin_id, settlement_ref},
        {caller, _tag} = from,
        %{owner: caller} = state
      ) do
    state
    |> do_settle_lease_result(origin_id, settlement_ref)
    |> reply_or_defer(from, origin_id, :settle_result, {origin_id, settlement_ref})
  end

  def handle_call({:settle_lease_result, _, _}, _from, state),
    do: {:reply, {:error, :permit_unavailable}, state}

  def handle_call(
        {:settle_lease_disposition, origin_id, disposition, settlement_ref},
        {caller, _tag} = from,
        %{owner: caller} = state
      )
      when disposition in [:connection_lost, :owner_lost] do
    state
    |> do_settle_lease_disposition(origin_id, disposition, settlement_ref)
    |> reply_or_defer(
      from,
      origin_id,
      :settle_disposition,
      {origin_id, disposition, settlement_ref}
    )
  end

  def handle_call({:settle_lease_disposition, _, _, _}, _from, state),
    do: {:reply, {:error, :permit_unavailable}, state}

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
        from,
        state
      ) do
    handle_registry_promotion(
      origin_id,
      registry_incarnation,
      settlement_ref,
      task_fun,
      nil,
      from,
      state
    )
  end

  def handle_call(
        {:promote_ticket, origin_id, registry_incarnation, settlement_ref, task_fun,
         owner_binding},
        from,
        state
      ) do
    handle_registry_promotion(
      origin_id,
      registry_incarnation,
      settlement_ref,
      task_fun,
      owner_binding,
      from,
      state
    )
  end

  def handle_call(
        {:refuse_resume_ticket, origin_id, registry_incarnation, owner, owner_incarnation,
         result},
        from = {caller, _tag},
        state
      ) do
    state = expire_if_due(state)

    with :ok <- promotion_admitted(state, origin_id),
         :ok <- authenticate_registry(state, caller, registry_incarnation),
         true <- bounded_record?(result),
         {:ok, %{class: :session_resume} = ticket} <- promotable_ticket(state, origin_id),
         :ok <- authenticate_ticket_owner(state, ticket, owner, owner_incarnation),
         :ok <- mutation_slot_available(state, ticket) do
      select_registry_refusal(state, ticket, from, caller, registry_incarnation, result)
    else
      false -> {:reply, {:error, :invalid_result}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(
        {:authorize_resume_ticket, origin_id, registry_incarnation, owner, owner_incarnation},
        {caller, _tag},
        state
      ) do
    state = expire_if_due(state)

    with :ok <- promotion_admitted(state, origin_id),
         :ok <- authenticate_registry(state, caller, registry_incarnation),
         {:ok, %{class: :session_resume} = ticket} <- promotable_ticket(state, origin_id),
         :ok <- authenticate_ticket_owner(state, ticket, owner, owner_incarnation) do
      {:reply, :ok, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
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
             :ok <- authenticate_ticket_owner(state, ticket, caller, owner_incarnation),
             :ok <- mutation_slot_available(state, ticket) do
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

  def handle_call({:pending_origins, origin_ids}, _from, state),
    do: {:reply, Enum.count(origin_ids, &Map.has_key?(state.permits, &1)), state}

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
       retiring_lease_owners:
         Enum.count(state.lease_owners, fn {_session_id, row} -> row.phase == :retiring end),
       owner_losses: map_size(state.owner_losses)
     }, state}
  end

  @impl true
  def handle_info(
        {:relay_lease_operation, operation_ref, owner, owner_incarnation, action, payload},
        %{owner: owner, owner_incarnation: owner_incarnation} = state
      )
      when is_reference(operation_ref) do
    case apply_owner_lease_operation(state, action, payload) do
      {{:error, :worker_unsettled}, state} when action in [:settle_result, :settle_disposition] ->
        # Concept: a settlement that arrives before its request worker has
        # been reaped waits for that exact `DOWN` rather than failing.
        origin_id = elem(payload, 0)

        state =
          update_in(
            state,
            [:permits, origin_id],
            &Map.put(&1, :pending_settlement, {:message, operation_ref, action, payload})
          )

        Logger.debug("loopex daemon admission relay lease settlement awaits worker")
        {:noreply, state}

      {reply, state} ->
        send(
          owner,
          {:relay_lease_operation_ack, operation_ref, self(), owner_incarnation, action, reply}
        )

        {:noreply, state}
    end
  end

  def handle_info(
        {:relay_lease_operation, _operation_ref, _owner, _owner_incarnation, _action, _payload},
        state
      ) do
    Logger.debug("loopex daemon admission relay lease operation ignored")
    {:noreply, state}
  end

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

  # Concept: after the admission cut, stopping moves through four more
  # ordered barriers, each acknowledged once per reference and repeated
  # idempotently: lease operations freeze, the drain begins, tickets are
  # sealed after the drain, and the lease-owner set is frozen for teardown.
  #
  # Technical depth: `freeze_lease_ops` ends admission at once, cancels every
  # pending row as the deadline would, compare-and-sets every still-executing
  # lease permit to terminal `shutdown_admitted`, and returns one fixed tagged
  # descriptor per lease row the daemon owner must clean up inside its freeze
  # deadline: `shutdown_admitted` for the rows the barrier won, and
  # `settling_acquire`, `settling_release` or `settling_owner_loss` for rows
  # whose result, connection loss or owner loss was selected first. No claim,
  # promotion or owner registration is admitted from here on. `quiescing`
  # records the drain identity. `seal_after_quiesce` kills every remaining
  # ticket task, lets a queued real result win its `DOWN` until the given
  # absolute deadline, and returns the real-result and unresolved ticket sets,
  # abandoning the unresolved ones for this shutdown without calling them
  # settled. `tearing_down` returns the exact remaining lease-owner set.
  def handle_info(
        {:relay_barrier, ref, {:freeze_lease_ops, _deadline}},
        %{phase: :draining} = state
      )
      when is_reference(ref) do
    if state.deadline_timer, do: Process.cancel_timer(state.deadline_timer)
    now = monotonic_ms()

    state =
      expire_pending(%{
        state
        | deadline_timer: nil,
          admission_deadline: min(state.admission_deadline, now)
      })

    {descriptors, state} =
      state.permits
      |> Enum.filter(fn {_origin, permit} -> permit.kind == :lease end)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.flat_map_reduce(state, fn {origin_id, permit}, acc ->
        freeze_lease_permit(acc, origin_id, permit)
      end)

    state = %{state | phase: :lease_ops_frozen, barrier: {:freeze_lease_ops, ref, descriptors}}
    send(state.owner, {:relay_barrier_ack, ref, :freeze_lease_ops, descriptors})
    Logger.debug("loopex daemon admission relay lease operations frozen")
    {:noreply, state}
  end

  def handle_info(
        {:relay_barrier, ref, {:quiescing, drain_id}},
        %{phase: :lease_ops_frozen} = state
      )
      when is_reference(ref) do
    state = %{state | phase: :quiescing, barrier: {:quiescing, ref, drain_id}}
    send(state.owner, {:relay_barrier_ack, ref, :quiescing, drain_id})
    Logger.debug("loopex daemon admission relay quiescing")
    {:noreply, state}
  end

  def handle_info(
        {:relay_barrier, ref, {:seal_after_quiesce, drain_id, deadline}},
        %{phase: :quiescing, barrier: {:quiescing, _ref, drain_id}} = state
      )
      when is_reference(ref) and is_integer(deadline) do
    state = state |> kill_ticket_tasks() |> await_ticket_tasks(deadline)

    {real, unresolved} =
      Enum.split_with(state.tickets, fn {_origin, ticket} -> ticket.result != nil end)

    unresolved_ids = unresolved |> Enum.map(&elem(&1, 0)) |> Enum.sort()
    real_ids = real |> Enum.map(&elem(&1, 0)) |> Enum.sort()
    state = Enum.reduce(unresolved_ids, state, &abandon_ticket(&2, &1))
    payload = %{results: real_ids, unresolved: unresolved_ids}
    state = %{state | phase: :sealed, barrier: {:seal_after_quiesce, ref, payload}}
    send(state.owner, {:relay_barrier_ack, ref, :seal_after_quiesce, payload})
    Logger.debug("loopex daemon admission relay sealed")
    {:noreply, state}
  end

  def handle_info({:relay_barrier, ref, :tearing_down}, %{phase: :sealed} = state)
      when is_reference(ref) do
    owners =
      state.lease_owners
      |> Enum.map(fn {session_id, row} -> {session_id, row.binding} end)
      |> Enum.sort()

    state = %{state | phase: :tearing_down, barrier: {:tearing_down, ref, owners}}
    send(state.owner, {:relay_barrier_ack, ref, :tearing_down, owners})
    Logger.debug("loopex daemon admission relay tearing down")
    {:noreply, state}
  end

  def handle_info({:relay_barrier, ref, kind}, %{barrier: {name, ref, payload}} = state)
      when is_reference(ref) and kind != :cut do
    if barrier_name(kind) == name,
      do: send(state.owner, {:relay_barrier_ack, ref, name, payload})

    {:noreply, state}
  end

  def handle_info({:relay_barrier, _ref, kind}, state) when kind != :cut do
    Logger.debug("loopex daemon admission relay out-of-order barrier ignored")
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

  def handle_info(
        {:relay_owner_loss_classification, owner, daemon_incarnation, classification_ref,
         session_id, lease_owner, lease_owner_incarnation, holder_connection_incarnation},
        %{owner: owner, owner_incarnation: daemon_incarnation} = state
      )
      when is_reference(classification_ref) and is_pid(lease_owner) and
             is_binary(lease_owner_incarnation) and byte_size(lease_owner_incarnation) == 16 and
             (is_nil(holder_connection_incarnation) or
                (is_binary(holder_connection_incarnation) and
                   byte_size(holder_connection_incarnation) == 16)) do
    case validate_ticket_session(session_id) do
      :ok ->
        retain_owner_loss_classification(
          state,
          classification_ref,
          session_id,
          lease_owner,
          lease_owner_incarnation,
          holder_connection_incarnation
        )

      {:error, :invalid_origin} ->
        {:stop, :owner_loss_invalid, state}
    end
  end

  def handle_info({:relay_owner_loss_classification, _, _, _, _, _, _, _}, state),
    do: {:stop, :owner_loss_invalid, state}

  # Concept: the registry learns an incarnation's retirement exactly once it
  # holds no row here; an incarnation this relay never held, or already
  # retired, is answered at once.
  def handle_info({:connection_retirement_query, incarnation, recipient}, state)
      when is_pid(recipient) do
    unless Map.has_key?(state.connections, incarnation),
      do: send(recipient, {:relay_connection_retired, self(), incarnation})

    {:noreply, state}
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
      %{binding: ^owner_binding, phase: :live} -> :ok
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

  defp existing_lease_permit(state, origin_id, requested) do
    cond do
      Map.has_key?(state.tickets, origin_id) ->
        :conflict

      true ->
        case Map.fetch(state.permits, origin_id) do
          {:ok, permit} ->
            if Enum.all?(requested, fn {key, value} -> Map.get(permit, key) == value end),
              do: :exact,
              else: :conflict

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
      %{binding: ^binding, phase: :live} when ticket.owner_binding == binding -> :ok
      _other -> {:error, :owner_unavailable}
    end
  end

  defp validate_lease_permit_class(class, session_id)
       when class in @lease_permit_classes,
       do: validate_ticket_session(session_id)

  defp validate_lease_permit_class(_class, _session_id), do: {:error, :invalid_origin}

  defp validate_lease_actor(
         state,
         :session_acquire_control,
         _session_id,
         actor,
         actor_incarnation,
         start_op_ref
       )
       when actor == state.owner and actor_incarnation == state.owner_incarnation and
              is_reference(start_op_ref),
       do: :ok

  defp validate_lease_actor(
         state,
         class,
         session_id,
         actor,
         actor_incarnation,
         nil
       )
       when class in @lease_permit_classes do
    case Map.get(state.lease_owners, session_id) do
      %{binding: {^actor, ^actor_incarnation}, phase: :live} -> :ok
      %{binding: {^actor, ^actor_incarnation}, phase: :retiring} -> {:error, :actor_retiring}
      _other -> if lost_actor?(actor), do: {:error, :actor_lost}, else: {:error, :invalid_actor}
    end
  end

  defp validate_lease_actor(_state, _class, _session_id, _actor, _incarnation, _start_op_ref),
    do: {:error, :invalid_actor}

  # Concept: an actor is lost once the relay has consumed its exact `DOWN`.
  #
  # Technical depth: a lease-owner row leaves `lease_owners` only when its
  # monitored `DOWN` is consumed, so for an actor the daemon owner registered,
  # a dead local pid with no matching row means that `DOWN` was consumed.
  # Liveness alone cannot tell such an actor from a dead pid that was never
  # registered, which also answers `actor_lost`; the daemon owner names only
  # actors it registered. It says nothing about whether the relay has
  # finished that owner's loss, which may still be classifying. A live pid
  # with no matching row answers `invalid_actor`.
  defp lost_actor?(actor),
    do: is_pid(actor) and node(actor) == node() and not Process.alive?(actor)

  defp handle_registry_promotion(
         origin_id,
         registry_incarnation,
         settlement_ref,
         task_fun,
         owner_binding,
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
             :ok <- validate_registry_promotion(state, ticket, owner_binding),
             :ok <- mutation_slot_available(state, ticket) do
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

  defp validate_registry_promotion(_state, %{class: class}, nil)
       when class in [:session_create, :session_attach],
       do: :ok

  defp validate_registry_promotion(
         state,
         %{class: :session_resume} = ticket,
         {owner, owner_incarnation}
       ) do
    authenticate_ticket_owner(state, ticket, owner, owner_incarnation)
  end

  defp validate_registry_promotion(_state, _ticket, _owner_binding),
    do: {:error, :invalid_promotion}

  defp select_registry_refusal(
         state,
         ticket,
         from,
         registry,
         registry_incarnation,
         result
       ) do
    ticket = %{
      ticket
      | phase: :settling,
        disposition: :result,
        promoter_pid: registry,
        promoter_incarnation: registry_incarnation,
        settlement_ref: :registry_refusal,
        settlement_mode: :registry_refusal,
        task_pid: nil,
        task_incarnation: nil,
        task_monitor: nil,
        task_down: true,
        result: result,
        settlement_acked: true,
        result_delivered: false,
        promotion_waiters: if(is_pid(ticket.worker_pid), do: [from], else: [])
    }

    state = put_in(state, [:tickets, ticket.origin_id], ticket)
    Logger.debug("loopex daemon admission relay resume refused")

    if is_pid(ticket.worker_pid) do
      if Process.alive?(ticket.worker_pid), do: Process.exit(ticket.worker_pid, :kill)
      {:noreply, state}
    else
      state = deliver_ticket_result(state, ticket.origin_id)
      {:reply, {:ok, ticket.origin_id}, state}
    end
  end

  defp valid_lease_worker(worker, worker_incarnation, connection, actor) do
    if is_pid(worker) and worker != connection and worker != actor and
         valid_incarnation?(worker_incarnation),
       do: :ok,
       else: {:error, :invalid_worker}
  end

  defp promotion_admitted(%{phase: :serving}, _origin_id), do: :ok

  defp promotion_admitted(%{phase: :draining} = state, origin_id) do
    if monotonic_ms() < state.admission_deadline and
         frozen_origin?(state, :ticket, origin_id),
       do: :ok,
       else: {:error, :daemon_stopping}
  end

  defp promotion_admitted(_stopping, _origin_id), do: {:error, :daemon_stopping}

  defp bind_admitted(%{phase: :serving}, _origin_id, _kind), do: :ok

  defp bind_admitted(%{phase: :draining} = state, origin_id, kind) do
    if monotonic_ms() < state.admission_deadline and frozen_origin?(state, kind, origin_id),
      do: :ok,
      else: {:error, :daemon_stopping}
  end

  defp bind_admitted(_stopping, _origin_id, _kind), do: {:error, :daemon_stopping}

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

  defp mutation_slot_available(state, %{
         class: class,
         session_id: session_id,
         origin_id: origin_id
       })
       when class in @lease_ticket_classes do
    occupied? =
      Enum.any?(state.tickets, fn
        {^origin_id, _ticket} ->
          false

        {_other_origin, %{class: other_class, session_id: ^session_id, phase: phase}}
        when other_class in @lease_ticket_classes and phase in [:ticketed, :settling] ->
          true

        _other ->
          false
      end)

    if occupied?, do: {:error, :ticket_outstanding}, else: :ok
  end

  defp mutation_slot_available(_state, _ticket), do: :ok

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

  defp exact_live_connection(state, incarnation, connection_pid) do
    case Map.fetch(state.connections, incarnation) do
      {:ok, %{pid: ^connection_pid, phase: :live} = connection} -> {:ok, connection}
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

  defp select_direct_lease_result(state, origin_id, permit, result) do
    if Process.alive?(permit.connection_pid) do
      send(permit.connection_pid, {:relay_permit_result, origin_id, result})
    end

    permit = %{
      permit
      | phase: :settling,
        disposition: :result,
        settlement_ref: :direct,
        result: result
    }

    state = put_in(state, [:permits, origin_id], permit)

    if is_nil(permit.worker_pid) do
      state
      |> remove_permit(origin_id)
      |> maybe_retire_connection(permit.connection_incarnation)
    else
      state
    end
  end

  defp barrier_name({name, _detail}) when is_atom(name), do: name
  defp barrier_name({name, _detail, _deadline}) when is_atom(name), do: name
  defp barrier_name(name) when is_atom(name), do: name

  defp kill_ticket_tasks(state) do
    Enum.each(state.tickets, fn
      {_origin, %{task_pid: task, result: nil}} when is_pid(task) -> Process.exit(task, :kill)
      _other -> :ok
    end)

    state
  end

  # A queued real result wins the task's later `DOWN`; waiting stops at the
  # absolute deadline whatever remains.
  defp await_ticket_tasks(state, deadline) do
    open =
      Enum.any?(state.tickets, fn {_origin, ticket} ->
        is_pid(ticket.task_pid) and ticket.result == nil and not ticket.task_down
      end)

    if open do
      receive do
        {:relay_ticket_result, task, origin_id, task_incarnation, result} ->
          case Map.fetch(state.tickets, origin_id) do
            {:ok, %{task_pid: ^task, task_incarnation: ^task_incarnation, result: nil} = ticket} ->
              ticket = %{ticket | disposition: :result, result: result}
              await_ticket_tasks(put_in(state, [:tickets, origin_id], ticket), deadline)

            _other ->
              await_ticket_tasks(state, deadline)
          end

        {:DOWN, monitor, :process, _pid, _reason}
        when is_map_key(state.ticket_task_monitors, monitor) ->
          {origin_id, monitors} = Map.pop(state.ticket_task_monitors, monitor)
          state = %{state | ticket_task_monitors: monitors}

          state =
            if Map.has_key?(state.tickets, origin_id),
              do: put_in(state, [:tickets, origin_id, :task_down], true),
              else: state

          await_ticket_tasks(state, deadline)
      after
        max(deadline - monotonic_ms(), 0) -> state
      end
    else
      state
    end
  end

  defp abandon_ticket(state, origin_id) do
    Logger.debug("loopex daemon admission relay ticket abandoned for shutdown")
    remove_ticket(state, origin_id)
  end

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

  defp admission_expired?(%{phase: :serving}), do: false
  defp admission_expired?(_stopping), do: true

  defp expire_pending(state) do
    state =
      state.permits
      |> Enum.filter(fn {_origin, permit} -> permit.phase == :pending end)
      |> Enum.reduce(state, fn {origin_id, permit}, acc ->
        send(permit.connection_pid, {:relay_permit_cancelled, origin_id, :daemon_stopping})

        case permit do
          %{kind: :lease, worker_pid: worker} when is_pid(worker) ->
            if Process.alive?(worker), do: Process.exit(worker, :kill)

            permit = %{
              permit
              | phase: :settling,
                disposition: :shutdown_cancelled,
                settlement_ref: :admission_deadline
            }

            put_in(acc, [:permits, origin_id], permit)

          _ordinary ->
            remove_permit(acc, origin_id)
        end
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

  # Concept: the freeze is the one instant at which every lease row not yet
  # decided becomes the barrier's, so no actor result can reach a client after
  # it, and every row already decided is named with the exact settlement the
  # daemon owner still has to finish.
  #
  # Technical depth: an executing row with no disposition becomes terminal
  # `shutdown_admitted`: its request worker is killed and the row is removed
  # once that exact `DOWN` is consumed. A daemon-coordinated `result` or
  # `connection_lost` row stays settling and is named with its settlement
  # reference; an `owner_lost` row stays for its classification. A direct
  # result or `shutdown_cancelled` row is already terminal and only waits for
  # its worker's reap, so it is not named.
  defp freeze_lease_permit(state, origin_id, %{phase: :executing, disposition: nil} = permit) do
    if is_pid(permit.worker_pid) and Process.alive?(permit.worker_pid),
      do: Process.exit(permit.worker_pid, :kill)

    admitted = %{permit | phase: :settling, disposition: :shutdown_admitted, settlement_ref: nil}

    state =
      if is_nil(permit.worker_pid) do
        state
        |> remove_permit(origin_id)
        |> maybe_retire_connection(permit.connection_incarnation)
      else
        put_in(state, [:permits, origin_id], admitted)
      end

    Logger.debug("loopex daemon admission relay lease permit shutdown admitted")

    {[
       {:shutdown_admitted, origin_id, permit.class, permit.actor_pid, permit.actor_incarnation,
        permit.start_op_ref}
     ], state}
  end

  defp freeze_lease_permit(
         state,
         origin_id,
         %{phase: :settling, disposition: disposition, settlement_ref: settlement_ref} = permit
       )
       when disposition in [:result, :connection_lost] and is_reference(settlement_ref) do
    descriptor =
      case permit.class do
        :session_acquire_control ->
          {:settling_acquire, origin_id, disposition, permit.actor_pid, permit.actor_incarnation,
           permit.start_op_ref, settlement_ref}

        :session_release_control ->
          {:settling_release, origin_id, disposition, permit.actor_pid, permit.actor_incarnation,
           settlement_ref}
      end

    {[descriptor], state}
  end

  defp freeze_lease_permit(
         state,
         origin_id,
         %{phase: :settling, disposition: :owner_lost} = permit
       ) do
    {[
       {:settling_owner_loss, origin_id, permit.class, permit.actor_pid, permit.actor_incarnation,
        permit.settlement_ref}
     ], state}
  end

  defp freeze_lease_permit(state, _origin_id, _terminal_permit), do: {[], state}

  defp apply_owner_lease_operation(
         state,
         :select_result,
         {origin_id, actor, actor_incarnation, settlement_ref, result}
       ) do
    do_select_lease_result(
      state,
      origin_id,
      actor,
      actor_incarnation,
      settlement_ref,
      result
    )
  end

  defp apply_owner_lease_operation(
         state,
         :settle_result,
         {origin_id, settlement_ref}
       ) do
    do_settle_lease_result(state, origin_id, settlement_ref)
  end

  defp apply_owner_lease_operation(
         state,
         :settle_disposition,
         {origin_id, disposition, settlement_ref}
       )
       when disposition in [:connection_lost, :owner_lost] do
    do_settle_lease_disposition(state, origin_id, disposition, settlement_ref)
  end

  defp apply_owner_lease_operation(state, _action, _payload),
    do: {{:error, :permit_unavailable}, state}

  defp do_select_lease_result(
         state,
         origin_id,
         actor,
         actor_incarnation,
         settlement_ref,
         result
       ) do
    binding = {actor, actor_incarnation}

    case Map.fetch(state.permits, origin_id) do
      {:ok,
       %{
         kind: :lease,
         phase: :executing,
         actor_pid: ^actor,
         actor_incarnation: ^actor_incarnation,
         disposition: nil
       } = permit} ->
        cond do
          not is_reference(settlement_ref) ->
            {{:error, :invalid_actor}, state}

          not bounded_record?(result) ->
            {{:error, :invalid_result}, state}

          true ->
            permit = %{
              permit
              | phase: :settling,
                disposition: :result,
                settlement_ref: settlement_ref,
                result: result
            }

            Logger.debug("loopex daemon admission relay lease result selected")
            {:ok, put_in(state, [:permits, origin_id], permit)}
        end

      {:ok,
       %{
         kind: :lease,
         phase: :settling,
         disposition: :result,
         actor_pid: actor,
         actor_incarnation: actor_incarnation,
         settlement_ref: ^settlement_ref,
         result: ^result
       }}
      when {actor, actor_incarnation} == binding ->
        {:ok, state}

      {:ok, %{kind: :lease, disposition: disposition}}
      when disposition in [:connection_lost, :owner_lost] ->
        {{:error, disposition}, state}

      _other ->
        {{:error, :permit_unavailable}, state}
    end
  end

  defp do_settle_lease_result(state, origin_id, settlement_ref) do
    case Map.fetch(state.permits, origin_id) do
      {:ok,
       %{
         kind: :lease,
         phase: :settling,
         disposition: :result,
         settlement_ref: ^settlement_ref,
         worker_pid: nil,
         result: result
       } = permit} ->
        # Concept: a result settled after the lease freeze is terminal but
        # renders nothing; the later `daemon.stopping`/EOF path owns the client.
        if state.phase in [:serving, :draining] and Process.alive?(permit.connection_pid) do
          send(permit.connection_pid, {:relay_permit_result, origin_id, result})
        end

        state =
          state
          |> remove_permit(origin_id)
          |> maybe_retire_connection(permit.connection_incarnation)

        Logger.debug("loopex daemon admission relay lease result settled")
        {:ok, state}

      {:ok, %{kind: :lease, phase: :settling, disposition: :result}} ->
        {{:error, :worker_unsettled}, state}

      _other ->
        {{:error, :permit_unavailable}, state}
    end
  end

  defp do_settle_lease_disposition(state, origin_id, disposition, settlement_ref) do
    case Map.fetch(state.permits, origin_id) do
      {:ok,
       %{
         kind: :lease,
         phase: :settling,
         disposition: ^disposition,
         settlement_ref: ^settlement_ref,
         worker_pid: nil
       } = permit} ->
        state =
          state
          |> remove_permit(origin_id)
          |> maybe_retire_connection(permit.connection_incarnation)

        Logger.debug("loopex daemon admission relay lease disposition settled")
        {:ok, state}

      {:ok,
       %{
         kind: :lease,
         phase: :settling,
         disposition: ^disposition,
         settlement_ref: ^settlement_ref
       }} ->
        {{:error, :worker_unsettled}, state}

      _other ->
        {{:error, :permit_unavailable}, state}
    end
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
      {:ok, %{kind: :lease, disposition: nil} = permit} ->
        settlement_ref = make_ref()

        if is_pid(permit.worker_pid) and Process.alive?(permit.worker_pid),
          do: Process.exit(permit.worker_pid, :kill)

        permit = %{
          permit
          | phase: :settling,
            disposition: :connection_lost,
            settlement_ref: settlement_ref,
            result: nil
        }

        send(
          state.owner,
          {:relay_lease_disposition, self(), origin_id, :connection_lost, settlement_ref,
           permit.class, permit.session_id, permit.actor_pid, permit.actor_incarnation,
           permit.start_op_ref}
        )

        put_in(state, [:permits, origin_id], permit)

      {:ok, %{kind: :lease, worker_pid: worker} = permit} when is_pid(worker) ->
        if Process.alive?(worker), do: Process.exit(worker, :kill)
        put_in(state, [:permits, origin_id], permit)

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

  defp lease_owner_down(state, monitor, pid, reason) do
    {{session_id, {^pid, owner_incarnation} = binding}, owner_monitors} =
      Map.pop(state.lease_owner_monitors, monitor)

    owner_phase =
      case Map.get(state.lease_owners, session_id) do
        %{binding: ^binding, phase: phase} -> phase
        _other -> :lost
      end

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

    if owner_phase == :retiring and reason == :normal do
      send(
        state.owner,
        {:relay_owner_retirement_complete, self(), session_id, pid, owner_incarnation}
      )

      Logger.debug("loopex daemon admission relay lease owner retired")
      {:noreply, state}
    else
      classify_lease_owner_loss(state, session_id, pid, owner_incarnation, binding)
    end
  end

  defp classify_lease_owner_loss(state, session_id, pid, owner_incarnation, binding) do
    affected_tickets =
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

    affected_permits =
      state.permits
      |> Enum.filter(fn
        {_origin_id,
         %{
           kind: :lease,
           actor_pid: ^pid,
           actor_incarnation: ^owner_incarnation,
           disposition: nil,
           phase: phase
         }}
        when phase in [:pending, :executing] ->
          true

        _other ->
          false
      end)
      |> Enum.map(&elem(&1, 0))
      |> MapSet.new()

    affected = MapSet.union(affected_tickets, affected_permits)

    state =
      Enum.reduce(affected, state, fn origin_id, acc ->
        cond do
          Map.has_key?(acc.tickets, origin_id) ->
            ticket = Map.fetch!(acc.tickets, origin_id)

            if is_pid(ticket.worker_pid) and Process.alive?(ticket.worker_pid),
              do: Process.exit(ticket.worker_pid, :kill)

            ticket = %{ticket | phase: :settling, disposition: :owner_lost}
            put_in(acc, [:tickets, origin_id], ticket)

          Map.has_key?(acc.permits, origin_id) ->
            permit = Map.fetch!(acc.permits, origin_id)

            if is_pid(permit.worker_pid) and Process.alive?(permit.worker_pid),
              do: Process.exit(permit.worker_pid, :kill)

            permit = %{
              permit
              | phase: :settling,
                disposition: :owner_lost,
                settlement_ref: :owner_loss
            }

            put_in(acc, [:permits, origin_id], permit)
        end
      end)

    loss =
      case Map.get(state.owner_losses, binding) do
        %{session_id: ^session_id, classification: classification, down: false} ->
          %{
            session_id: session_id,
            origins: affected,
            classification: classification,
            down: true
          }

        nil ->
          %{
            session_id: session_id,
            origins: affected,
            classification: nil,
            down: true
          }

        _other ->
          :invalid
      end

    if loss == :invalid do
      {:stop, :owner_loss_invalid, state}
    else
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
      maybe_finish_owner_loss(state, binding)
    end
  end

  defp retain_owner_loss_classification(
         state,
         classification_ref,
         session_id,
         owner,
         owner_incarnation,
         holder_connection_incarnation
       ) do
    binding = {owner, owner_incarnation}

    classification = %{
      ref: classification_ref,
      holder_connection_incarnation: holder_connection_incarnation
    }

    case Map.get(state.owner_losses, binding) do
      %{session_id: ^session_id, classification: nil} = loss ->
        state = put_in(state, [:owner_losses, binding], %{loss | classification: classification})
        Logger.debug("loopex daemon admission relay owner loss classification retained")
        maybe_finish_owner_loss(state, binding)

      %{session_id: ^session_id, classification: ^classification} ->
        maybe_finish_owner_loss(state, binding)

      nil ->
        case Map.get(state.lease_owners, session_id) do
          %{binding: ^binding} ->
            loss = %{
              session_id: session_id,
              origins: nil,
              classification: classification,
              down: false
            }

            Logger.debug("loopex daemon admission relay early owner loss classification retained")
            {:noreply, put_in(state, [:owner_losses, binding], loss)}

          _other ->
            {:stop, :owner_loss_invalid, state}
        end

      _other ->
        {:stop, :owner_loss_invalid, state}
    end
  end

  defp maybe_finish_owner_loss(state, binding) do
    case Map.get(state.owner_losses, binding) do
      %{
        session_id: session_id,
        origins: %MapSet{} = origins,
        classification: %{ref: classification_ref} = classification,
        down: true
      } ->
        if Enum.any?(origins, &owner_loss_worker_live?(state, &1)) do
          {:noreply, state}
        else
          state =
            origins
            |> Enum.sort()
            |> Enum.reduce(state, fn origin_id, acc ->
              finish_owner_loss_origin(acc, origin_id, classification)
            end)
            |> update_in([:owner_losses], &Map.delete(&1, binding))

          {owner, owner_incarnation} = binding

          send(
            state.owner,
            {:relay_owner_loss_classified_ack, self(), classification_ref, session_id, owner,
             owner_incarnation}
          )

          Logger.debug("loopex daemon admission relay owner loss classified")
          {:noreply, state}
        end

      _other ->
        {:noreply, state}
    end
  end

  defp finish_owner_loss_origin(state, origin_id, classification) do
    cond do
      Map.has_key?(state.tickets, origin_id) ->
        ticket = Map.fetch!(state.tickets, origin_id)
        maybe_send_owner_loss_refusal(state, ticket, origin_id, classification)

        state
        |> remove_ticket(origin_id)
        |> maybe_retire_connection(ticket.connection_incarnation)

      Map.has_key?(state.permits, origin_id) ->
        permit = Map.fetch!(state.permits, origin_id)
        maybe_send_owner_loss_refusal(state, permit, origin_id, classification)

        state
        |> remove_permit(origin_id)
        |> maybe_retire_connection(permit.connection_incarnation)

      true ->
        state
    end
  end

  # Concept: after the admission cut ordinary owner-loss notification stops;
  # the stop barrier owns every claimed origin and the later
  # `daemon.stopping`/EOF path owns client notification.
  defp maybe_send_owner_loss_refusal(%{phase: phase}, _row, _origin_id, _classification)
       when phase != :serving,
       do: :ok

  defp maybe_send_owner_loss_refusal(
         _state,
         %{connection_incarnation: holder},
         _origin_id,
         %{holder_connection_incarnation: holder}
       )
       when not is_nil(holder),
       do: :ok

  defp maybe_send_owner_loss_refusal(_state, %{kind: :lease} = permit, origin_id, _classification) do
    send(permit.connection_pid, {:relay_permit_cancelled, origin_id, :control_owner_lost})
  end

  defp maybe_send_owner_loss_refusal(_state, ticket, origin_id, _classification) do
    send(ticket.connection_pid, {:relay_ticket_cancelled, origin_id, :control_owner_lost})
  end

  defp owner_loss_worker_live?(state, origin_id) do
    row = Map.get(state.tickets, origin_id) || Map.get(state.permits, origin_id)
    match?(%{worker_pid: worker} when is_pid(worker), row)
  end

  defp worker_down(state, monitor, pid, reason) do
    case Map.pop(state.worker_monitors, monitor) do
      {nil, _worker_monitors} ->
        {:noreply, state}

      {{:permit, origin_id}, worker_monitors} ->
        state = %{state | worker_monitors: worker_monitors}
        permit_worker_down(state, origin_id, pid, reason)

      {{:ticket, origin_id}, worker_monitors} ->
        state = %{state | worker_monitors: worker_monitors}
        ticket_worker_down(state, origin_id, pid)
    end
  end

  defp permit_worker_down(state, origin_id, pid, _reason) do
    case Map.fetch(state.permits, origin_id) do
      {:ok,
       %{
         kind: :lease,
         worker_pid: ^pid,
         phase: :settling,
         disposition: :owner_lost,
         actor_pid: owner,
         actor_incarnation: owner_incarnation
       } = permit} ->
        permit = clear_permit_worker(permit)
        state = put_in(state, [:permits, origin_id], permit)

        case Map.get(state.owner_losses, {owner, owner_incarnation}) do
          %{origins: origins} ->
            if Enum.all?(origins, &(not owner_loss_worker_live?(state, &1))) do
              send(state.owner, {:relay_owner_loss_ready, self(), owner, owner_incarnation})
            end

          _other ->
            :ok
        end

        Logger.debug("loopex daemon admission relay lease owner-loss worker reaped")
        maybe_finish_owner_loss(state, {owner, owner_incarnation})

      {:ok,
       %{
         kind: :lease,
         worker_pid: ^pid,
         phase: :settling,
         disposition: :result,
         settlement_ref: :direct
       } = permit} ->
        state =
          state
          |> remove_permit(origin_id)
          |> maybe_retire_connection(permit.connection_incarnation)

        Logger.debug("loopex daemon admission relay direct lease worker reaped")
        {:noreply, state}

      {:ok,
       %{kind: :lease, worker_pid: ^pid, phase: :settling, disposition: disposition} = permit}
      when disposition in [:shutdown_cancelled, :shutdown_admitted] ->
        state =
          state
          |> remove_permit(origin_id)
          |> maybe_retire_connection(permit.connection_incarnation)

        Logger.debug("loopex daemon admission relay cancelled lease worker reaped")
        {:noreply, state}

      {:ok, %{kind: :lease, worker_pid: ^pid, phase: phase} = permit}
      when phase in [:executing, :settling] ->
        {pending, permit} = Map.pop(clear_permit_worker(permit), :pending_settlement)
        Logger.debug("loopex daemon admission relay lease request worker reaped")
        state = put_in(state, [:permits, origin_id], permit)
        {:noreply, resume_pending_settlement(state, pending)}

      {:ok, %{kind: :lease, worker_pid: ^pid, phase: :pending} = permit} ->
        if Process.alive?(permit.connection_pid) do
          send(permit.connection_pid, {:relay_permit_failed, origin_id, :worker_lost})

          state =
            state
            |> remove_permit(origin_id)
            |> maybe_retire_connection(permit.connection_incarnation)

          Logger.debug("loopex daemon admission relay pending lease worker lost")
          {:noreply, state}
        else
          settlement_ref = make_ref()

          permit = %{
            clear_permit_worker(permit)
            | phase: :settling,
              disposition: :connection_lost,
              settlement_ref: settlement_ref,
              result: nil
          }

          send(
            state.owner,
            {:relay_lease_disposition, self(), origin_id, :connection_lost, settlement_ref,
             permit.class, permit.session_id, permit.actor_pid, permit.actor_incarnation,
             permit.start_op_ref}
          )

          Logger.debug("loopex daemon admission relay lease connection loss selected")
          {:noreply, put_in(state, [:permits, origin_id], permit)}
        end

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

  # Concept: a settlement that arrives before its request worker has been
  # reaped waits for that exact `DOWN` rather than failing.
  defp reply_or_defer({{:error, :worker_unsettled}, state}, from, origin_id, action, payload) do
    state =
      update_in(
        state,
        [:permits, origin_id],
        &Map.put(&1, :pending_settlement, {:call, from, action, payload})
      )

    Logger.debug("loopex daemon admission relay lease settlement awaits worker")
    {:noreply, state}
  end

  defp reply_or_defer({reply, state}, _from, _origin_id, _action, _payload),
    do: {:reply, reply, state}

  defp resume_pending_settlement(state, nil), do: state

  defp resume_pending_settlement(state, {:message, operation_ref, action, payload}) do
    {reply, state} = apply_owner_lease_operation(state, action, payload)

    send(
      state.owner,
      {:relay_lease_operation_ack, operation_ref, self(), state.owner_incarnation, action, reply}
    )

    state
  end

  defp resume_pending_settlement(state, {:call, from, action, payload}) do
    {reply, state} = apply_owner_lease_operation(state, action, payload)
    GenServer.reply(from, reply)
    state
  end

  defp clear_permit_worker(permit) do
    %{
      permit
      | worker_pid: nil,
        worker_incarnation: nil,
        worker_monitor: nil
    }
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
        maybe_finish_owner_loss(state, {owner, owner_incarnation})

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

      {:ok,
       %{
         worker_pid: ^pid,
         phase: :settling,
         settlement_mode: :registry_refusal,
         task_pid: nil
       } = ticket} ->
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
        state = deliver_ticket_result(state, origin_id)
        Logger.debug("loopex daemon admission relay refused resume worker retired")
        {:noreply, state}

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
       } = ticket} ->
        notify_lease_ticket_settled(state, ticket, origin_id)

        state
        |> remove_ticket(origin_id)
        |> maybe_retire_connection(incarnation)

      _other ->
        state
    end
  end

  # Concept: a lease owner advances to its next queued mutation only once the
  # relay has released the session's single mutation slot.
  #
  # Technical depth: a direct ticket's promoter is the lease owner. A resume is
  # promoted and settled through the registry, which tells the owner its
  # disposition before the relay has reaped the task and worker and freed the
  # slot, so the relay tells the session's registered lease owner itself when
  # it removes that ticket; the owner ignores a message for an origin it no
  # longer holds or an incarnation that is not its own.
  defp notify_lease_ticket_settled(_state, %{settlement_mode: :direct} = ticket, origin_id) do
    send(
      ticket.promoter_pid,
      {:relay_lease_ticket_settled, self(), origin_id, ticket.promoter_incarnation}
    )
  end

  defp notify_lease_ticket_settled(
         state,
         %{settlement_mode: :registry, class: class, session_id: session_id},
         origin_id
       )
       when class in @lease_ticket_classes do
    case Map.fetch(state.lease_owners, session_id) do
      {:ok, %{binding: {owner, owner_incarnation}}} ->
        send(owner, {:relay_lease_ticket_settled, self(), origin_id, owner_incarnation})

      :error ->
        :ok
    end
  end

  defp notify_lease_ticket_settled(_state, _ticket, _origin_id), do: :ok

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
        |> maybe_notify_lease_owner_idle(permit.session_id)
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
        |> maybe_notify_lease_owner_idle(ticket.session_id)
    end
  end

  defp maybe_notify_lease_owner_idle(state, nil), do: state

  defp maybe_notify_lease_owner_idle(state, session_id) do
    case Map.get(state.lease_owners, session_id) do
      %{binding: {owner, owner_incarnation}, phase: :live} ->
        unless lease_session_busy?(state, session_id) do
          send(owner, {:relay_owner_idle, self(), owner_incarnation})
        end

        state

      _other ->
        state
    end
  end

  defp lease_session_busy?(state, session_id) do
    Enum.any?(state.permits, fn {_origin_id, permit} -> permit.session_id == session_id end) or
      Enum.any?(state.tickets, fn {_origin_id, ticket} -> ticket.session_id == session_id end)
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
