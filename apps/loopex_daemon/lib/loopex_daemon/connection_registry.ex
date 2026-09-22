defmodule LoopexDaemon.ConnectionRegistry do
  @moduledoc """
  ## Concept

  The daemon has one bounded inventory of accepted client sockets. A slot is
  charged from kernel accept until every process and socket owner for that
  incarnation has been accounted for.

  ## Technical depth

  The registry serializes reservation, waiting-child creation, socket-transfer
  disposition, promotion, initialization and teardown. It starts each waiting
  connection linked inside its callback, records and monitors the returned pid
  before unlinking it, and retains `listener_owned`, `transferring`, or
  `connection_owned` until cleanup has exact evidence for the real owner. The
  accept-time initialization deadline is calculated once and its timer only
  prompts a monotonic-clock check. Its owner-authenticated transport cut first
  freezes a fixed provisional and uninitialized population, then closes that
  population only after listener reap and acknowledges the exact cut reference
  when every marked row is gone. It also owns each connection's bounded encoded
  output queue and the daemon-wide commitment count. A frame stays charged
  while the socket process advances a nonblocking send and is released only by
  that exact process's complete-emission acknowledgement. For an initialized
  connection, the same authenticated row owns the derived attachment-succession
  reserve and its notice, serial-reply and terminal phases; unused reserve and
  encoded bytes are one aggregate commitment throughout. Both barrier entries
  return OTP asynchronous request identifiers so the daemon owner can classify
  other component exits while it waits under one absolute deadline. Private
  pids, references and tokens are redacted from formatted process status.

  The same serialized owner retains the daemon-lifetime activation set and
  every activation reservation. Exact create or resume repetition joins its
  primary reservation, a conflicting create binding is refused, and a session
  already activated in this daemon lifetime consumes no reservation. Resolving
  a reservation removes its exact binding before optionally adding the session
  to the monotonic activation set; a repeated resolution of an absent reference
  is an idempotent no-op.

  The registry also owns the bounded lease-routing mirror. The daemon owner
  publishes exact asynchronous operations against the registry incarnation;
  provisional rows install only for an initialized live connection, promotion
  may finish after that connection begins closing, and exact clears or owner
  pops cannot erase a successor row. Status reports only phase counts.
  """

  use GenServer
  require Logger

  alias LoopexDaemon.{AdmissionRelay, OutputBuffer, SocketConnection, SuccessionCapacity}
  alias LoopexProtocol.Session.V2

  @connection_limit 512
  @attachments_per_session 64
  @activation_limit 64
  @aggregate_output_bytes 536_870_912

  @typedoc false
  @type reservation :: %{
          rollback_token: binary(),
          initialize_deadline: integer()
        }

  @typedoc false
  @type request_id :: term()

  @typedoc false
  @type origin_id :: {binary(), 0..31, pos_integer()}

  @typedoc false
  @type activation_binding ::
          {:create, binary(), binary()} | {:resume, binary(), binary()}

  @typedoc false
  @type mirror_action ::
          :install_provisional
          | {:resolve_provisional, :granted | :cancelled}
          | :clear_granted
          | :pop_owner_mirror

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options), do: GenServer.start_link(__MODULE__, options)

  @doc false
  @spec reserve(pid(), pid(), reference(), integer()) ::
          {:ok, reservation()}
          | {:error,
             :capacity_exceeded
             | :initialize_deadline_expired
             | :reservation_unavailable
             | :transport_closing}
  def reserve(registry, listener, listener_incarnation, accepted_at) do
    GenServer.call(
      registry,
      {:reserve, listener, listener_incarnation, accepted_at}
    )
  end

  @doc false
  @spec start_connection(pid(), binary()) ::
          {:ok, pid(), binary()} | {:error, atom()}
  def start_connection(registry, rollback_token) do
    GenServer.call(registry, {:start_connection, rollback_token})
  end

  @doc false
  @spec begin_transfer(pid(), binary(), binary()) :: :ok | {:error, atom()}
  def begin_transfer(registry, rollback_token, connection_incarnation) do
    GenServer.call(registry, {:begin_transfer, rollback_token, connection_incarnation})
  end

  @doc false
  @spec transfer_result(pid(), binary(), binary(), :ok | {:error, term()}) ::
          :ok | {:error, atom()}
  def transfer_result(registry, rollback_token, connection_incarnation, result) do
    GenServer.call(
      registry,
      {:transfer_result, rollback_token, connection_incarnation, result}
    )
  end

  @doc false
  @spec promote(pid(), binary(), binary()) :: :ok | {:error, atom()}
  def promote(registry, rollback_token, connection_incarnation) do
    GenServer.call(registry, {:promote, rollback_token, connection_incarnation})
  end

  @doc false
  @spec initialize_complete(pid(), binary(), binary()) :: :ok | {:error, atom()}
  def initialize_complete(registry, rollback_token, connection_incarnation) do
    GenServer.call(registry, {:initialize_complete, rollback_token, connection_incarnation})
  end

  @doc false
  @spec enqueue_output(pid(), binary(), iodata()) ::
          :ok | {:error, :capacity_exceeded | :output_unavailable}
  def enqueue_output(registry, connection_incarnation, encoded) do
    GenServer.call(registry, {:enqueue_output, connection_incarnation, encoded})
  end

  @doc false
  @spec claim_output(pid(), binary()) ::
          {:ok, reference(), binary()} | :empty | {:error, :output_unavailable}
  def claim_output(registry, connection_incarnation) do
    GenServer.call(registry, {:claim_output, connection_incarnation})
  end

  @doc false
  @spec output_emitted(pid(), binary(), reference()) ::
          :ok | {:error, :output_unavailable}
  def output_emitted(registry, connection_incarnation, frame_ref) do
    GenServer.call(registry, {:output_emitted, connection_incarnation, frame_ref})
  end

  @doc false
  @spec reserve_succession(pid(), binary()) ::
          :ok | {:error, :capacity_exceeded | :reservation_unavailable}
  def reserve_succession(registry, connection_incarnation) do
    GenServer.call(registry, {:reserve_succession, connection_incarnation})
  end

  @doc false
  @spec release_succession(pid(), binary()) :: :ok | {:error, :succession_unavailable}
  def release_succession(registry, connection_incarnation) do
    GenServer.call(registry, {:release_succession, connection_incarnation})
  end

  @doc false
  @spec enqueue_succession_notice(pid(), binary(), iodata()) ::
          :ok | {:error, :succession_unavailable}
  def enqueue_succession_notice(registry, connection_incarnation, encoded) do
    GenServer.call(registry, {:enqueue_succession_notice, connection_incarnation, encoded})
  end

  @doc false
  @spec enqueue_succession_reply(pid(), binary(), iodata(), :after_notice | :without_notice) ::
          :ok | {:error, :succession_unavailable}
  def enqueue_succession_reply(
        registry,
        connection_incarnation,
        encoded,
        mode \\ :after_notice
      ) do
    GenServer.call(
      registry,
      {:enqueue_succession_reply, connection_incarnation, encoded, mode}
    )
  end

  @doc false
  @spec finish_succession(pid(), binary()) :: :ok | {:error, :succession_unavailable}
  def finish_succession(registry, connection_incarnation) do
    GenServer.call(registry, {:finish_succession, connection_incarnation})
  end

  @doc false
  @spec reserve_activation(pid(), origin_id(), activation_binding()) ::
          {:ok, {:primary, binary()} | {:duplicate, origin_id(), binary()} | :already_active}
          | {:error, :activation_ceiling_reached | :activation_conflict | :invalid_activation}
  def reserve_activation(registry, origin_id, binding) do
    GenServer.call(registry, {:reserve_activation, origin_id, binding})
  end

  @doc false
  @spec resolve_activation(pid(), binary(), :activated | :no_activation, binary() | nil) ::
          :ok | {:error, :activation_resolution_invalid}
  def resolve_activation(registry, reservation_ref, disposition, session_id \\ nil) do
    GenServer.call(
      registry,
      {:resolve_activation, reservation_ref, disposition, session_id}
    )
  end

  @doc """
  ## Concept

  Admits one `session.create` ticket against the daemon's per-lifetime
  activation ceiling before core can start a coordinator.

  ## Technical depth

  A `:fresh` create reserves its exact `{command_id, options digest}`
  activation binding first; an exact duplicate waits on the primary ticket, a
  conflicting binding completes `conflict_refusal`, and a full ceiling
  completes `ceiling_refusal`, neither calling core. A `:historical` replay
  reserves nothing because core returns its retained session without starting
  a coordinator. The relay task's classified disposition resolves the exact
  reservation before the ticket settles.
  """
  @spec promote_create(
          pid(),
          origin_id(),
          binary(),
          binary(),
          :fresh | :historical,
          map(),
          map(),
          (-> {:activated | :no_activation, binary() | nil, map()})
        ) ::
          {:ok, :admitted | {:waiting, origin_id()}}
          | {:error,
             :daemon_stopping
             | :invalid_activation
             | :invalid_promotion
             | :registry_unavailable
             | :relay_unavailable
             | :ticket_outstanding
             | :ticket_unavailable}
  def promote_create(
        registry,
        origin_id,
        command_id,
        digest,
        mode,
        ceiling_refusal,
        conflict_refusal,
        task_fun
      ) do
    GenServer.call(
      registry,
      {:promote_create, origin_id, command_id, digest, mode, ceiling_refusal, conflict_refusal,
       task_fun}
    )
  end

  @doc """
  ## Concept

  Admits one connection's `session.attach` ticket only for a session this
  daemon lifetime has activated and only within the per-session and
  per-daemon attachment ceilings.

  ## Technical depth

  The caller is the initialized connection itself. A dormant session or a
  full ceiling completes the supplied refusal through the relay without a core
  call. Otherwise the relay starts the monitored task whose classified result
  either installs the connection's one attachment, which the daemon owner
  records for the session's mutation gate before the snapshot settles, or
  restores the connection's previous attachment state.
  """
  @spec promote_attach(
          pid(),
          origin_id(),
          binary(),
          binary(),
          map(),
          map(),
          (-> {:installed, binary(), map()} | {:refused, map()})
        ) ::
          {:ok, :admitted}
          | {:error,
             :attachment_pending
             | :daemon_stopping
             | :invalid_promotion
             | :registry_unavailable
             | :relay_unavailable
             | :reservation_unavailable
             | :ticket_outstanding
             | :ticket_unavailable}
  def promote_attach(
        registry,
        origin_id,
        connection_incarnation,
        session_id,
        dormant_refusal,
        capacity_refusal,
        task_fun
      ) do
    GenServer.call(
      registry,
      {:promote_attach, origin_id, connection_incarnation, session_id, dormant_refusal,
       capacity_refusal, task_fun}
    )
  end

  @doc """
  ## Concept

  Names the lease owner currently routing a session's granted lease.

  ## Technical depth

  The mirror is routing, not authority: the named owner still decides every
  admission. Only a granted row routes; a session with no granted lease has
  no mutation route.
  """
  @spec lease_route(pid(), binary()) :: {:ok, pid(), binary()} | :none
  def lease_route(registry, session_id), do: GenServer.call(registry, {:lease_route, session_id})

  @doc """
  ## Concept

  Reports, for each named session, whether this daemon lifetime activated it
  and whether a controller lease currently routes it.

  ## Technical depth

  These are daemon facts from the one-way activation set and the granted
  routing mirror; neither reads core or the Store.
  """
  @spec session_facts(pid(), [binary()]) :: %{
          binary() => %{active: boolean(), controlled: boolean()}
        }
  def session_facts(registry, session_ids) when is_list(session_ids),
    do: GenServer.call(registry, {:session_facts, session_ids})

  @doc false
  @spec bind_relay(pid(), pid(), binary()) ::
          :ok | {:error, :invalid_relay | :owner_mismatch | :relay_conflict}
  def bind_relay(registry, relay, relay_incarnation) do
    GenServer.call(registry, {:bind_relay, relay, relay_incarnation})
  end

  @doc false
  @spec apply_mirror(pid(), reference(), binary(), mirror_action(), map()) :: :ok
  def apply_mirror(registry, op_ref, registry_incarnation, action, exact_row) do
    send(
      registry,
      {:apply_mirror, op_ref, self(), registry_incarnation, action, exact_row}
    )

    :ok
  end

  @doc false
  @spec prepare_resume(
          pid(),
          origin_id(),
          binary(),
          binary(),
          binary(),
          :eligible | :ineligible
        ) ::
          {:ok, :prepared | :unreserved | {:waiting, origin_id()}}
          | {:error,
             :activation_ceiling_reached
             | :activation_conflict
             | :daemon_stopping
             | :invalid_activation
             | :owner_unavailable
             | :registry_unavailable
             | :relay_unavailable
             | :ticket_unavailable}
  def prepare_resume(
        registry,
        origin_id,
        session_id,
        command_id,
        owner_incarnation,
        eligibility
      ) do
    GenServer.call(
      registry,
      {:prepare_resume, origin_id, session_id, command_id, owner_incarnation, eligibility}
    )
  end

  @doc false
  @spec cancel_prepared_resume(pid(), origin_id(), binary()) ::
          :ok | {:error, :owner_unavailable}
  def cancel_prepared_resume(registry, origin_id, owner_incarnation) do
    GenServer.call(registry, {:cancel_prepared_resume, origin_id, owner_incarnation})
  end

  @doc false
  @spec promote_resume(
          pid(),
          origin_id(),
          binary(),
          binary(),
          binary(),
          :eligible | :ineligible,
          boolean(),
          map(),
          map(),
          (-> {:accepted | :admission_unknown | :refused, :activated | :no_activation, map()})
        ) ::
          {:ok, :admitted | :completed | {:waiting, origin_id()}}
          | {:error,
             :activation_conflict
             | :daemon_stopping
             | :invalid_activation
             | :invalid_promotion
             | :owner_unavailable
             | :registry_unavailable
             | :relay_unavailable
             | :ticket_outstanding
             | :ticket_unavailable}
  def promote_resume(
        registry,
        origin_id,
        session_id,
        command_id,
        owner_incarnation,
        eligibility,
        attached,
        control_refusal,
        capacity_refusal,
        task_fun
      ) do
    GenServer.call(
      registry,
      {:promote_resume, origin_id, session_id, command_id, owner_incarnation, eligibility,
       attached, control_refusal, capacity_refusal, task_fun},
      :infinity
    )
  end

  @doc false
  @spec abort_provisional(pid(), binary(), :peer_credential_unverified | :handoff_failed) ::
          :ok | {:error, :abort_unavailable}
  def abort_provisional(registry, rollback_token, reason) do
    GenServer.call(registry, {:abort_provisional, rollback_token, reason})
  end

  @doc false
  @spec listener_closed(pid(), binary()) :: :ok | {:error, :close_acknowledgement_unavailable}
  def listener_closed(registry, rollback_token) do
    GenServer.call(registry, {:listener_closed, rollback_token})
  end

  @doc false
  @spec abort_provisional_for(pid(), reference()) :: :ok | {:error, :owner_mismatch}
  def abort_provisional_for(registry, listener_incarnation) do
    GenServer.call(registry, {:abort_provisional_for, listener_incarnation})
  end

  @doc false
  @spec transport_closing(pid(), reference()) :: request_id()
  def transport_closing(registry, cut_ref),
    do: :gen_server.send_request(registry, {:transport_closing, cut_ref})

  @doc false
  @spec reap_uninitialized(pid(), reference()) :: request_id()
  def reap_uninitialized(registry, cut_ref),
    do: :gen_server.send_request(registry, {:reap_uninitialized, cut_ref})

  @doc """
  ## Concept

  Ends every remaining connection at the end of an orderly or fatal stop,
  telling each initialized client why where its transport accepts one record.

  ## Technical depth

  Only the registry owner may ask. Each initialized live connection receives
  the exact encoded `daemon.stopping` record to write once before it closes;
  every other row is aborted or closed without a record. The call answers
  `:ok` once every row is gone, or `{:ok, :forced}` after killing the
  survivors at the absolute deadline, so a stalled peer cannot extend the stop.
  """
  @spec close_all(pid(), map(), integer()) :: :ok | {:ok, :forced} | {:error, :owner_mismatch}
  def close_all(registry, record, deadline)
      when is_map(record) and is_integer(deadline) do
    GenServer.call(registry, {:close_all, record, deadline}, :infinity)
  end

  @doc false
  @spec status(pid()) :: %{
          occupied: non_neg_integer(),
          provisional: non_neg_integer(),
          live: non_neg_integer(),
          closing: non_neg_integer(),
          transport: :serving | :closing,
          transport_marked: non_neg_integer(),
          output_bytes: non_neg_integer(),
          output_commitment: non_neg_integer(),
          output_commitment_limit: pos_integer(),
          succession_reservations: non_neg_integer(),
          active_sessions: non_neg_integer(),
          activation_reservations: non_neg_integer(),
          activation_preparations: non_neg_integer(),
          activations_used: non_neg_integer(),
          activation_limit: 64,
          routing_mirrors: non_neg_integer(),
          provisional_routing_mirrors: non_neg_integer(),
          granted_routing_mirrors: non_neg_integer(),
          limit: 512
        }
  def status(registry), do: GenServer.call(registry, :status)

  @impl true
  def init(options) do
    Process.flag(:trap_exit, true)
    owner = Keyword.fetch!(options, :owner)
    Process.link(owner)

    deadline_ms =
      Keyword.get(
        options,
        :initialize_deadline_ms,
        Map.fetch!(V2.limits(), "initialize_deadline_ms")
      )

    output_buffer_bytes =
      Keyword.get(options, :output_buffer_bytes, Map.fetch!(V2.limits(), "durable_queue_bytes"))

    aggregate_output_bytes =
      Keyword.get(options, :aggregate_output_bytes, @aggregate_output_bytes)

    succession_capacity = SuccessionCapacity.limits()

    deadline_valid =
      is_integer(deadline_ms) and deadline_ms > 0 and
        deadline_ms <= Map.fetch!(V2.limits(), "initialize_deadline_ms")

    output_valid =
      is_integer(output_buffer_bytes) and output_buffer_bytes > 0 and
        output_buffer_bytes <= Map.fetch!(V2.limits(), "durable_queue_bytes") and
        is_integer(aggregate_output_bytes) and aggregate_output_bytes >= output_buffer_bytes and
        aggregate_output_bytes <= @aggregate_output_bytes

    cond do
      not deadline_valid ->
        {:stop, :invalid_initialize_deadline}

      not output_valid ->
        {:stop, :invalid_output_limit}

      true ->
        Logger.debug("loopex daemon connection registry start")

        {:ok,
         %{
           owner: owner,
           connection_module: Keyword.get(options, :connection_module, SocketConnection),
           connection_context: Keyword.get(options, :connection_context),
           initialize_deadline_ms: deadline_ms,
           output_buffer_bytes: output_buffer_bytes,
           aggregate_output_bytes: aggregate_output_bytes,
           succession_notice_bytes: succession_capacity.notice_bytes,
           succession_reply_bytes: succession_capacity.reply_bytes,
           output_commitment: 0,
           activation_set: MapSet.new(),
           activation_reservations: %{},
           activation_bindings: %{},
           activation_origins: %{},
           activation_create_commands: %{},
           activation_preparations: %{},
           activation_preparation_monitors: %{},
           activation_promotions: %{},
           anonymous_activations: 0,
           attachments: %{},
           close_all: nil,
           activation_promotion_bindings: %{},
           relay: nil,
           routing_mirrors: %{},
           rows: %{},
           child_monitors: %{},
           listeners: %{},
           transport: :serving,
           transport_cut_ref: nil,
           transport_marked: MapSet.new(),
           transport_sweep_started: false,
           transport_sweep_acknowledged: false
         }}
    end
  end

  @impl true
  def handle_call(
        {:reserve, listener, listener_incarnation, accepted_at},
        {caller, _tag},
        state
      ) do
    now = now_ms()
    deadline = accepted_at + state.initialize_deadline_ms

    cond do
      state.transport != :serving ->
        {:reply, {:error, :transport_closing}, state}

      map_size(state.rows) >= @connection_limit ->
        {:reply, {:error, :capacity_exceeded}, state}

      caller != listener or not is_pid(listener) or not is_reference(listener_incarnation) or
        not is_integer(accepted_at) or accepted_at > now or now >= deadline ->
        reason =
          if caller == listener,
            do: :initialize_deadline_expired,
            else: :reservation_unavailable

        {:reply, {:error, reason}, state}

      true ->
        with {:ok, state} <- retain_listener(state, listener, listener_incarnation) do
          token = :crypto.strong_rand_bytes(16)
          timer = schedule_deadline(token, deadline, now)

          row = %{
            token: token,
            listener: listener,
            listener_incarnation: listener_incarnation,
            accepted_at: accepted_at,
            initialize_deadline: deadline,
            timer: timer,
            phase: :handing_off,
            transfer_disposition: :listener_owned,
            connection_pid: nil,
            connection_incarnation: nil,
            connection_monitor: nil,
            listener_closed: false,
            listener_down: false,
            connection_down: false,
            initialized: false,
            listener_close_requested: false,
            connection_abort_requested: false,
            output: OutputBuffer.new(state.output_buffer_bytes)
          }

          state =
            state
            |> put_in([:rows, token], row)
            |> add_listener_token(listener_incarnation, token)

          Logger.debug("loopex daemon accepted slot reserved")

          {:reply, {:ok, %{rollback_token: token, initialize_deadline: deadline}}, state}
        else
          {:error, reason} -> {:reply, {:error, reason}, state}
        end
    end
  end

  def handle_call({:start_connection, token}, {caller, _tag}, state) do
    case Map.fetch(state.rows, token) do
      {:ok, %{phase: :handing_off, connection_pid: nil, listener: ^caller} = row}
      when state.transport == :serving ->
        if before_deadline?(row) do
          start_waiting_connection(state, row)
        else
          state = request_abort(state, token, :initialize_deadline)
          {:reply, {:error, :initialize_deadline_expired}, state}
        end

      _other ->
        {:reply, {:error, :reservation_unavailable}, state}
    end
  end

  def handle_call({:begin_transfer, token, incarnation}, {caller, _tag}, state) do
    case Map.fetch(state.rows, token) do
      {:ok,
       %{
         phase: :handing_off,
         listener: ^caller,
         connection_incarnation: ^incarnation,
         transfer_disposition: :listener_owned
       } = row}
      when state.transport == :serving ->
        if before_deadline?(row) do
          row = %{row | transfer_disposition: :transferring}
          {:reply, :ok, put_in(state, [:rows, token], row)}
        else
          state = request_abort(state, token, :initialize_deadline)
          {:reply, {:error, :initialize_deadline_expired}, state}
        end

      _other ->
        {:reply, {:error, :transfer_unavailable}, state}
    end
  end

  def handle_call({:transfer_result, token, incarnation, result}, {caller, _tag}, state) do
    case Map.fetch(state.rows, token) do
      {:ok,
       %{
         listener: ^caller,
         connection_incarnation: ^incarnation,
         transfer_disposition: :transferring
       } = row} ->
        transfer_result_reply(state, row, result)

      _other ->
        {:reply, {:error, :transfer_unavailable}, state}
    end
  end

  def handle_call({:promote, token, incarnation}, {caller, _tag}, state) do
    case Map.fetch(state.rows, token) do
      {:ok,
       %{
         phase: :handing_off,
         transfer_disposition: :connection_owned,
         connection_pid: ^caller,
         connection_incarnation: ^incarnation
       } = row}
      when state.transport == :serving ->
        if before_deadline?(row) do
          row = %{row | phase: :live}
          state = put_in(state, [:rows, token], row)
          state = release_listener_token(state, row.listener_incarnation, token)
          {:reply, :ok, state}
        else
          state = request_abort(state, token, :initialize_deadline)
          {:reply, {:error, :initialize_deadline_expired}, state}
        end

      _other ->
        reason =
          if state.transport == :serving, do: :promotion_unavailable, else: :transport_closing

        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:initialize_complete, token, incarnation}, {caller, _tag}, state) do
    case Map.fetch(state.rows, token) do
      {:ok,
       %{
         phase: :live,
         initialized: false,
         connection_pid: ^caller,
         connection_incarnation: ^incarnation
       } = row}
      when state.transport == :serving ->
        if before_deadline?(row) do
          cancel_timer(row.timer, token)
          row = %{row | initialized: true, timer: nil}
          {:reply, :ok, put_in(state, [:rows, token], row)}
        else
          state = close_live(state, token, :initialize_deadline)
          {:reply, {:error, :initialize_deadline_expired}, state}
        end

      _other ->
        reason =
          if state.transport == :serving, do: :initialize_unavailable, else: :transport_closing

        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:enqueue_output, incarnation, encoded}, {caller, _tag}, state) do
    case connection_row(state, caller, incarnation) do
      {token, %{phase: phase} = row} when phase in [:live, :closing] ->
        before = OutputBuffer.commitment(row.output)
        wake_connection = OutputBuffer.empty?(row.output)

        case OutputBuffer.enqueue(row.output, encoded) do
          {:ok, output} ->
            after_enqueue = OutputBuffer.commitment(output)
            commitment = state.output_commitment + after_enqueue - before

            if commitment <= state.aggregate_output_bytes do
              row = %{row | output: output}
              state = %{put_in(state, [:rows, token], row) | output_commitment: commitment}
              if wake_connection, do: send(caller, {:output_ready, incarnation})
              {:reply, :ok, state}
            else
              Logger.debug("loopex daemon aggregate output capacity reached")
              {:reply, {:error, :capacity_exceeded}, close_live(state, token, :output_capacity)}
            end

          {:error, _reason} ->
            Logger.debug("loopex daemon connection output capacity reached")
            {:reply, {:error, :capacity_exceeded}, close_live(state, token, :output_capacity)}
        end

      _other ->
        {:reply, {:error, :output_unavailable}, state}
    end
  end

  def handle_call({:claim_output, incarnation}, {caller, _tag}, state) do
    case connection_row(state, caller, incarnation) do
      {token, %{phase: phase} = row} when phase in [:live, :closing] ->
        case OutputBuffer.claim(row.output) do
          {:ok, frame_ref, bytes, output} ->
            row = %{row | output: output}
            {:reply, {:ok, frame_ref, bytes}, put_in(state, [:rows, token], row)}

          {:empty, output} ->
            row = %{row | output: output}
            {:reply, :empty, put_in(state, [:rows, token], row)}

          {:error, :claimed} ->
            {:reply, {:error, :output_unavailable}, state}
        end

      _other ->
        {:reply, {:error, :output_unavailable}, state}
    end
  end

  def handle_call({:output_emitted, incarnation, frame_ref}, {caller, _tag}, state) do
    case connection_row(state, caller, incarnation) do
      {token, %{phase: phase} = row} when phase in [:live, :closing] ->
        before = OutputBuffer.commitment(row.output)

        case OutputBuffer.emitted(row.output, frame_ref) do
          {:ok, output} ->
            after_emit = OutputBuffer.commitment(output)
            row = %{row | output: output}

            state =
              %{
                put_in(state, [:rows, token], row)
                | output_commitment: state.output_commitment + after_emit - before
              }

            {:reply, :ok, state}

          {:error, :claim_mismatch} ->
            {:reply, {:error, :output_unavailable}, state}
        end

      _other ->
        {:reply, {:error, :output_unavailable}, state}
    end
  end

  def handle_call({:reserve_succession, incarnation}, {caller, _tag}, state) do
    case initialized_connection_row(state, caller, incarnation) do
      {token, row} ->
        before = OutputBuffer.commitment(row.output)

        case OutputBuffer.reserve_succession(
               row.output,
               state.succession_notice_bytes,
               state.succession_reply_bytes
             ) do
          {:ok, output} ->
            after_reserve = OutputBuffer.commitment(output)
            commitment = state.output_commitment + after_reserve - before

            if commitment <= state.aggregate_output_bytes do
              Logger.debug("loopex daemon succession output reserved")
              {:reply, :ok, put_output(state, token, row, output, commitment)}
            else
              Logger.debug("loopex daemon succession aggregate capacity reached")
              {:reply, {:error, :capacity_exceeded}, state}
            end

          {:error, :capacity_exceeded} ->
            Logger.debug("loopex daemon succession connection capacity reached")
            {:reply, {:error, :capacity_exceeded}, state}

          {:error, _reason} ->
            {:reply, {:error, :reservation_unavailable}, state}
        end

      _other ->
        {:reply, {:error, :reservation_unavailable}, state}
    end
  end

  def handle_call({:release_succession, incarnation}, {caller, _tag}, state) do
    update_succession(
      state,
      caller,
      incarnation,
      &OutputBuffer.release_succession/1,
      "loopex daemon succession output released"
    )
  end

  def handle_call(
        {:enqueue_succession_notice, incarnation, encoded},
        {caller, _tag},
        state
      ) do
    enqueue_succession(
      state,
      caller,
      incarnation,
      &OutputBuffer.enqueue_succession_notice(&1, encoded),
      "loopex daemon succession notice queued"
    )
  end

  def handle_call(
        {:enqueue_succession_reply, incarnation, encoded, mode},
        {caller, _tag},
        state
      )
      when mode in [:after_notice, :without_notice] do
    options = if mode == :without_notice, do: [without_notice: true], else: []

    enqueue_succession(
      state,
      caller,
      incarnation,
      &OutputBuffer.enqueue_succession_reply(&1, encoded, options),
      "loopex daemon succession reply queued"
    )
  end

  def handle_call({:enqueue_succession_reply, _incarnation, _encoded, _mode}, _from, state),
    do: {:reply, {:error, :succession_unavailable}, state}

  def handle_call({:finish_succession, incarnation}, {caller, _tag}, state) do
    update_succession(
      state,
      caller,
      incarnation,
      &OutputBuffer.finish_succession/1,
      "loopex daemon succession output complete"
    )
  end

  def handle_call(
        {:promote_create, origin_id, command_id, digest, mode, ceiling_refusal, conflict_refusal,
         task_fun},
        _from,
        state
      ) do
    with {:ok, relay, relay_incarnation} <- bound_relay(state),
         true <- mode in [:fresh, :historical] and is_function(task_fun, 0),
         true <- is_map(ceiling_refusal) and is_map(conflict_refusal) do
      promote_create_call(
        state,
        relay,
        relay_incarnation,
        origin_id,
        command_id,
        digest,
        mode,
        ceiling_refusal,
        conflict_refusal,
        task_fun
      )
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
      false -> {:reply, {:error, :invalid_activation}, state}
    end
  end

  def handle_call(
        {:promote_attach, origin_id, incarnation, session_id, dormant_refusal, capacity_refusal,
         task_fun},
        {caller, _tag},
        state
      ) do
    with {:ok, relay, relay_incarnation} <- bound_relay(state),
         {_token, _row} <- initialized_connection_row(state, caller, incarnation),
         true <- is_binary(session_id) and byte_size(session_id) in 1..256,
         true <- is_map(dormant_refusal) and is_map(capacity_refusal),
         true <- is_function(task_fun, 0),
         :ok <- attachment_not_pending(state, incarnation) do
      previous = Map.get(state.attachments, incarnation)

      cond do
        not MapSet.member?(state.activation_set, session_id) ->
          Logger.debug("loopex daemon attach refused for dormant session")

          promote_attach_refusal(
            state,
            relay,
            relay_incarnation,
            origin_id,
            dormant_refusal
          )

        not attachment_capacity?(state, session_id, previous) ->
          Logger.debug("loopex daemon attach capacity reached")

          promote_attach_refusal(
            state,
            relay,
            relay_incarnation,
            origin_id,
            capacity_refusal
          )

        true ->
          promote_attach_primary(
            state,
            relay,
            relay_incarnation,
            origin_id,
            caller,
            incarnation,
            session_id,
            previous,
            task_fun
          )
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
      nil -> {:reply, {:error, :reservation_unavailable}, state}
      false -> {:reply, {:error, :invalid_promotion}, state}
    end
  end

  def handle_call({:session_facts, session_ids}, _from, state) do
    facts =
      Map.new(session_ids, fn session_id ->
        controlled = match?(%{phase: :granted}, Map.get(state.routing_mirrors, session_id))

        {session_id,
         %{active: MapSet.member?(state.activation_set, session_id), controlled: controlled}}
      end)

    {:reply, facts, state}
  end

  def handle_call({:lease_route, session_id}, _from, state) do
    case Map.get(state.routing_mirrors, session_id) do
      %{phase: :granted, owner_pid: owner, owner_incarnation: owner_incarnation} ->
        {:reply, {:ok, owner, owner_incarnation}, state}

      _other ->
        {:reply, :none, state}
    end
  end

  def handle_call({:reserve_activation, origin_id, binding}, _from, state) do
    case reserve_activation_binding(state, origin_id, binding) do
      {:ok, reply, state} -> {:reply, {:ok, reply}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(
        {:resolve_activation, reservation_ref, disposition, session_id},
        _from,
        state
      ) do
    case resolve_activation_reservation(state, reservation_ref, disposition, session_id) do
      {:ok, state} -> {:reply, :ok, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(
        {:bind_relay, relay, relay_incarnation},
        {caller, _tag},
        %{owner: caller} = state
      ) do
    cond do
      not is_pid(relay) or not valid_incarnation?(relay_incarnation) ->
        {:reply, {:error, :invalid_relay}, state}

      match?(%{pid: ^relay, incarnation: ^relay_incarnation}, state.relay) ->
        {:reply, :ok, state}

      not is_nil(state.relay) ->
        {:reply, {:error, :relay_conflict}, state}

      true ->
        Logger.debug("loopex daemon connection registry relay bound")
        {:reply, :ok, %{state | relay: %{pid: relay, incarnation: relay_incarnation}}}
    end
  end

  def handle_call({:bind_relay, _relay, _relay_incarnation}, _from, state),
    do: {:reply, {:error, :owner_mismatch}, state}

  def handle_call(
        {:prepare_resume, origin_id, session_id, command_id, owner_incarnation, eligibility},
        {owner, _tag},
        state
      ) do
    with :ok <-
           validate_resume_identity(
             origin_id,
             session_id,
             command_id,
             owner_incarnation,
             eligibility
           ),
         {:ok, relay, relay_incarnation} <- bound_relay(state),
         :ok <-
           AdmissionRelay.authorize_resume_ticket(
             relay,
             origin_id,
             relay_incarnation,
             owner,
             owner_incarnation
           ) do
      prepare_resume_call(
        state,
        relay,
        relay_incarnation,
        owner,
        owner_incarnation,
        origin_id,
        session_id,
        command_id,
        eligibility
      )
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(
        {:cancel_prepared_resume, origin_id, owner_incarnation},
        {owner, _tag},
        state
      ) do
    case Map.fetch(state.activation_preparations, origin_id) do
      {:ok, %{owner: ^owner, owner_incarnation: ^owner_incarnation}} ->
        {:reply, :ok, release_resume_preparation(state, origin_id)}

      :error ->
        {:reply, :ok, state}

      _other ->
        {:reply, {:error, :owner_unavailable}, state}
    end
  end

  def handle_call(
        {:promote_resume, origin_id, session_id, command_id, owner_incarnation, eligibility,
         attached, control_refusal, capacity_refusal, task_fun},
        {owner, _tag},
        state
      ) do
    with :ok <-
           validate_resume_promotion(
             origin_id,
             session_id,
             command_id,
             owner_incarnation,
             eligibility,
             attached,
             control_refusal,
             capacity_refusal,
             task_fun
           ),
         {:ok, relay, relay_incarnation} <- bound_relay(state) do
      promote_resume_call(
        state,
        relay,
        relay_incarnation,
        owner,
        owner_incarnation,
        origin_id,
        session_id,
        command_id,
        eligibility,
        attached,
        control_refusal,
        capacity_refusal,
        task_fun
      )
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(
        {:abort_provisional, token, reason},
        {caller, _tag},
        state
      )
      when reason in [:peer_credential_unverified, :handoff_failed] do
    case Map.fetch(state.rows, token) do
      {:ok, %{listener: ^caller, phase: phase}} when phase in [:handing_off, :aborting] ->
        {:reply, :ok, request_abort(state, token, reason)}

      :error ->
        {:reply, :ok, state}

      _other ->
        {:reply, {:error, :abort_unavailable}, state}
    end
  end

  def handle_call({:abort_provisional, _token, _reason}, _from, state),
    do: {:reply, {:error, :abort_unavailable}, state}

  def handle_call(
        {:abort_provisional_for, listener_incarnation},
        {owner, _tag},
        %{owner: owner} = state
      ) do
    tokens =
      state.rows
      |> Enum.filter(fn {_token, row} ->
        row.listener_incarnation == listener_incarnation and
          row.phase in [:handing_off, :aborting]
      end)
      |> Enum.map(&elem(&1, 0))

    state = Enum.reduce(tokens, state, &request_abort(&2, &1, :listener_lost))
    {:reply, :ok, state}
  end

  def handle_call({:abort_provisional_for, _listener_incarnation}, _from, state),
    do: {:reply, {:error, :owner_mismatch}, state}

  def handle_call({:listener_closed, token}, {caller, _tag}, state) do
    case Map.fetch(state.rows, token) do
      {:ok,
       %{
         phase: :aborting,
         listener: ^caller,
         transfer_disposition: :listener_owned,
         listener_close_requested: true
       } = row} ->
        state = put_in(state, [:rows, token], %{row | listener_closed: true})
        {:reply, :ok, maybe_finish_abort(state, token)}

      :error ->
        {:reply, :ok, state}

      _other ->
        {:reply, {:error, :close_acknowledgement_unavailable}, state}
    end
  end

  def handle_call(
        {:transport_closing, cut_ref},
        {owner, _tag},
        %{owner: owner, transport: :serving} = state
      )
      when is_reference(cut_ref) do
    marked =
      state.rows
      |> Enum.filter(fn {_token, row} -> not row.initialized end)
      |> Enum.map(&elem(&1, 0))
      |> MapSet.new()

    state = %{
      state
      | transport: :closing,
        transport_cut_ref: cut_ref,
        transport_marked: marked
    }

    Logger.debug("loopex daemon connection transport gate closed")
    {:reply, {:ok, cut_ref}, state}
  end

  def handle_call(
        {:transport_closing, cut_ref},
        {owner, _tag},
        %{owner: owner, transport: :closing, transport_cut_ref: cut_ref} = state
      ),
      do: {:reply, {:ok, cut_ref}, state}

  def handle_call({:transport_closing, _cut_ref}, {owner, _tag}, %{owner: owner} = state),
    do: {:reply, {:error, :transport_cut_mismatch}, state}

  def handle_call({:transport_closing, _cut_ref}, _from, state),
    do: {:reply, {:error, :owner_mismatch}, state}

  def handle_call(
        {:reap_uninitialized, cut_ref},
        {owner, _tag},
        %{
          owner: owner,
          transport: :closing,
          transport_cut_ref: cut_ref,
          transport_sweep_started: false
        } = state
      ) do
    state = %{state | transport_sweep_started: true}
    Logger.debug("loopex daemon uninitialized connection sweep start")

    state =
      Enum.reduce(state.transport_marked, state, fn token, acc ->
        case Map.fetch(acc.rows, token) do
          {:ok, %{phase: phase}} when phase in [:handing_off, :aborting] ->
            request_abort(acc, token, :transport_closing)

          {:ok, %{phase: phase}} when phase in [:live, :closing] ->
            close_live(acc, token, :transport_closing)

          :error ->
            unmark_transport_row(acc, token)
        end
      end)
      |> maybe_acknowledge_transport_sweep()

    {:reply, :ok, state}
  end

  def handle_call(
        {:reap_uninitialized, cut_ref},
        {owner, _tag},
        %{owner: owner, transport_cut_ref: cut_ref, transport_sweep_started: true} = state
      ),
      do: {:reply, {:error, :transport_sweep_already_started}, state}

  def handle_call(
        {:reap_uninitialized, _cut_ref},
        {owner, _tag},
        %{owner: owner, transport: :serving} = state
      ),
      do: {:reply, {:error, :transport_cut_unavailable}, state}

  def handle_call({:reap_uninitialized, _cut_ref}, {owner, _tag}, %{owner: owner} = state),
    do: {:reply, {:error, :transport_cut_mismatch}, state}

  def handle_call({:reap_uninitialized, _cut_ref}, _from, state),
    do: {:reply, {:error, :owner_mismatch}, state}

  def handle_call({:close_all, record, deadline}, from, %{owner: owner} = state)
      when elem(from, 0) == owner do
    state =
      Enum.reduce(state.rows, %{state | transport: :stopping}, fn {token, row}, acc ->
        cond do
          row.phase in [:live, :closing] and row.initialized and is_pid(row.connection_pid) ->
            send(row.connection_pid, {:daemon_stopping, record})
            update_row(acc, token, &%{&1 | phase: :closing})

          row.phase in [:live, :closing] ->
            close_live(acc, token, :daemon_stopping)

          row.phase in [:handing_off, :aborting] ->
            request_abort(acc, token, :daemon_stopping)

          true ->
            acc
        end
      end)

    timer =
      Process.send_after(self(), {:close_all_deadline, deadline}, max(deadline - now_ms(), 0))

    Logger.debug("loopex daemon connection close-all start")
    {:noreply, maybe_finish_close_all(%{state | close_all: %{from: from, timer: timer}})}
  end

  def handle_call({:close_all, _record, _deadline}, _from, state),
    do: {:reply, {:error, :owner_mismatch}, state}

  def handle_call(:status, _from, state) do
    counts = Enum.frequencies_by(state.rows, fn {_token, row} -> row.phase end)

    mirror_counts =
      Enum.frequencies_by(state.routing_mirrors, fn {_session_id, row} -> row.phase end)

    {:reply,
     %{
       occupied: map_size(state.rows),
       provisional: Map.get(counts, :handing_off, 0) + Map.get(counts, :aborting, 0),
       live: Map.get(counts, :live, 0),
       closing: Map.get(counts, :closing, 0),
       transport: state.transport,
       transport_marked: MapSet.size(state.transport_marked),
       output_bytes:
         Enum.reduce(state.rows, 0, fn {_token, row}, total ->
           total + OutputBuffer.bytes(row.output)
         end),
       output_commitment: state.output_commitment,
       output_commitment_limit: state.aggregate_output_bytes,
       succession_reservations:
         Enum.count(state.rows, fn {_token, row} -> OutputBuffer.succession?(row.output) end),
       active_sessions: MapSet.size(state.activation_set),
       activation_reservations: map_size(state.activation_reservations),
       activation_preparations: map_size(state.activation_preparations),
       activations_used:
         MapSet.size(state.activation_set) + map_size(state.activation_reservations) +
           state.anonymous_activations,
       activation_limit: @activation_limit,
       attachments: map_size(state.attachments),
       routing_mirrors: map_size(state.routing_mirrors),
       provisional_routing_mirrors: Map.get(mirror_counts, :provisional, 0),
       granted_routing_mirrors: Map.get(mirror_counts, :granted, 0),
       limit: @connection_limit
     }, state}
  end

  @impl true
  def handle_info({:close_all_deadline, deadline}, %{close_all: %{from: from}} = state) do
    if now_ms() >= deadline do
      Enum.each(state.rows, fn {_token, row} ->
        if is_pid(row.connection_pid), do: Process.exit(row.connection_pid, :kill)
      end)

      GenServer.reply(from, {:ok, :forced})
      Logger.debug("loopex daemon connection close-all forced at deadline")
      {:noreply, %{state | close_all: nil}}
    else
      timer = Process.send_after(self(), {:close_all_deadline, deadline}, deadline - now_ms())
      {:noreply, put_in(state, [:close_all, :timer], timer)}
    end
  end

  def handle_info({:close_all_deadline, _deadline}, state), do: {:noreply, state}

  def handle_info({:initialize_deadline, token}, state) do
    case Map.fetch(state.rows, token) do
      {:ok, %{initialized: false} = row} ->
        if before_deadline?(row) do
          timer = schedule_deadline(token, row.initialize_deadline, now_ms())
          {:noreply, put_in(state, [:rows, token, :timer], timer)}
        else
          state =
            if row.phase in [:live, :closing],
              do: close_live(state, token, :initialize_deadline),
              else: request_abort(state, token, :initialize_deadline)

          {:noreply, state}
        end

      _other ->
        {:noreply, state}
    end
  end

  def handle_info(
        {:activation_resume_classified, classification_ref, settlement_ref, lease_disposition,
         activation_disposition, result},
        state
      ) do
    case Map.fetch(state.activation_promotions, settlement_ref) do
      {:ok, %{classification_ref: ^classification_ref, classification: nil} = promotion}
      when lease_disposition in [:accepted, :admission_unknown, :refused] and
             activation_disposition in [:activated, :no_activation] and is_map(result) ->
        classification = %{
          lease_disposition: lease_disposition,
          activation_disposition: activation_disposition,
          result: result
        }

        promotion = %{promotion | classification: classification}
        state = put_in(state, [:activation_promotions, settlement_ref], promotion)
        {:noreply, settle_resume_promotion(state, settlement_ref)}

      {:ok, %{classification_ref: ^classification_ref, classification: classification}}
      when not is_nil(classification) ->
        {:noreply, state}

      _other ->
        Logger.debug("loopex daemon activation classification invalid")
        {:stop, :activation_settlement_invalid, state}
    end
  end

  def handle_info(
        {:activation_create_classified, classification_ref, settlement_ref, disposition,
         session_id, result},
        state
      ) do
    case Map.fetch(state.activation_promotions, settlement_ref) do
      {:ok,
       %{kind: :create, classification_ref: ^classification_ref, classification: nil} =
           promotion}
      when disposition in [:activated, :no_activation] and is_map(result) and
             (is_nil(session_id) or is_binary(session_id)) ->
        classification = %{disposition: disposition, session_id: session_id, result: result}
        promotion = %{promotion | classification: classification}
        state = put_in(state, [:activation_promotions, settlement_ref], promotion)
        {:noreply, settle_create_promotion(state, settlement_ref)}

      _other ->
        Logger.debug("loopex daemon create classification invalid")
        {:stop, :activation_settlement_invalid, state}
    end
  end

  def handle_info(
        {:attachment_classified, classification_ref, settlement_ref, classification},
        state
      ) do
    case Map.fetch(state.activation_promotions, settlement_ref) do
      {:ok,
       %{kind: :attach, classification_ref: ^classification_ref, classification: nil} =
           promotion} ->
        promotion = %{promotion | classification: classification}
        state = put_in(state, [:activation_promotions, settlement_ref], promotion)
        {:noreply, settle_attach_promotion(state, settlement_ref)}

      _other ->
        Logger.debug("loopex daemon attach classification invalid")
        {:stop, :attachment_settlement_invalid, state}
    end
  end

  def handle_info({:owner_attachment_recorded, owner, record_ref}, %{owner: owner} = state)
      when is_reference(record_ref) do
    case Enum.find(state.activation_promotions, fn {_settlement_ref, promotion} ->
           Map.get(promotion, :record_ref) == record_ref
         end) do
      {settlement_ref, promotion} ->
        promotion = %{promotion | owner_acked: true}
        state = put_in(state, [:activation_promotions, settlement_ref], promotion)
        {:noreply, settle_attach_promotion(state, settlement_ref)}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info(
        {:relay_ticket_settlement, relay, origin_id, settlement_ref, result},
        %{relay: %{pid: relay}} = state
      ) do
    case Map.fetch(state.activation_promotions, settlement_ref) do
      {:ok, %{origin_id: ^origin_id, relay_result: nil} = promotion} when is_map(result) ->
        promotion = %{promotion | relay_result: result}
        state = put_in(state, [:activation_promotions, settlement_ref], promotion)
        {:noreply, settle_promotion(state, settlement_ref, promotion)}

      {:ok, %{origin_id: ^origin_id, relay_result: ^result}} ->
        {:noreply, state}

      _other ->
        Logger.debug("loopex daemon activation relay settlement invalid")
        {:stop, :activation_settlement_invalid, state}
    end
  end

  def handle_info(
        {:apply_mirror, op_ref, owner, registry_incarnation, action, exact_row},
        %{owner: owner, relay: %{incarnation: registry_incarnation}} = state
      )
      when is_reference(op_ref) do
    {result, state} = apply_routing_mirror(state, action, exact_row)

    send(
      owner,
      {:mirror_applied, op_ref, self(), registry_incarnation, result}
    )

    {:noreply, state}
  end

  def handle_info({:apply_mirror, _op_ref, _owner, _incarnation, _action, _row}, state) do
    Logger.debug("loopex daemon routing mirror request ignored")
    {:noreply, state}
  end

  def handle_info({:DOWN, monitor, :process, pid, _reason}, state) do
    cond do
      origin_id = Map.get(state.activation_preparation_monitors, monitor) ->
        case Map.get(state.activation_preparations, origin_id) do
          %{owner: ^pid, owner_monitor: ^monitor} ->
            Logger.debug("loopex daemon prepared resume owner lost")
            {:noreply, release_resume_preparation(state, origin_id, false)}

          _other ->
            {:noreply, state}
        end

      Map.has_key?(state.child_monitors, monitor) ->
        token = Map.fetch!(state.child_monitors, monitor)
        state = %{state | child_monitors: Map.delete(state.child_monitors, monitor)}
        state = update_row(state, token, &%{&1 | connection_down: true})
        {:noreply, connection_down(state, token)}

      listener_entry = listener_for_monitor(state, monitor, pid) ->
        {incarnation, _entry} = listener_entry
        {:noreply, listener_down(state, incarnation)}

      true ->
        {:noreply, state}
    end
  end

  def handle_info({:EXIT, owner, reason}, %{owner: owner} = state),
    do: {:stop, reason, state}

  def handle_info({:EXIT, pid, _reason}, state) do
    if tracked_connection_pid?(state, pid) do
      {:noreply, state}
    else
      {:stop, :unexpected_linked_exit, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.rows, fn {_token, row} ->
      if row.connection_pid, do: Process.exit(row.connection_pid, :kill)
    end)

    Logger.debug("loopex daemon connection registry stop")
    :ok
  end

  @impl GenServer
  def format_status(status) do
    status
    |> Map.put(:state, :redacted_connection_registry_state)
    |> Map.put(:message, :redacted_connection_registry_message)
    |> Map.put(:reason, :redacted_connection_registry_reason)
    |> Map.put(:log, [])
  end

  defp start_waiting_connection(state, row) do
    incarnation = :crypto.strong_rand_bytes(16)

    options = [
      registry: self(),
      listener: row.listener,
      rollback_token: row.token,
      connection_incarnation: incarnation,
      initialize_deadline: row.initialize_deadline,
      context: state.connection_context
    ]

    result =
      try do
        state.connection_module.start_link(options)
      catch
        :exit, _reason -> {:error, :connection_start_failed}
      end

    case result do
      {:ok, pid} ->
        monitor = Process.monitor(pid)

        row = %{
          row
          | connection_pid: pid,
            connection_incarnation: incarnation,
            connection_monitor: monitor
        }

        state =
          state
          |> put_in([:rows, row.token], row)
          |> put_in([:child_monitors, monitor], row.token)

        Process.unlink(pid)
        flush_temporary_exit(pid)

        if before_deadline?(row) do
          {:reply, {:ok, pid, incarnation}, state}
        else
          state = request_abort(state, row.token, :initialize_deadline)
          {:reply, {:error, :initialize_deadline_expired}, state}
        end

      {:error, _reason} ->
        state = request_abort(state, row.token, :connection_start_failed)
        {:reply, {:error, :connection_start_failed}, state}
    end
  end

  defp transfer_result_reply(state, row, :ok) do
    row = %{row | transfer_disposition: :connection_owned}
    state = put_in(state, [:rows, row.token], row)

    state =
      if row.phase == :aborting,
        do: request_abort(state, row.token, :transfer_aborted),
        else: state

    {:reply, :ok, state}
  end

  defp transfer_result_reply(state, row, {:error, _reason}) do
    row = %{row | transfer_disposition: :listener_owned}
    state = put_in(state, [:rows, row.token], row)
    state = request_abort(state, row.token, :transfer_failed)
    {:reply, {:error, :transfer_failed}, state}
  end

  defp transfer_result_reply(state, _row, _result),
    do: {:reply, {:error, :transfer_unavailable}, state}

  defp request_abort(state, token, reason) do
    case Map.fetch(state.rows, token) do
      {:ok, %{phase: phase} = row} when phase in [:handing_off, :aborting] ->
        abort_connection =
          not is_nil(row.connection_pid) and
            (row.transfer_disposition != :transferring or row.listener_down) and
            not row.connection_abort_requested

        close_listener =
          row.transfer_disposition == :listener_owned and not row.listener_down and
            not row.listener_close_requested

        row = %{
          row
          | phase: :aborting,
            connection_abort_requested: row.connection_abort_requested or abort_connection,
            listener_close_requested: row.listener_close_requested or close_listener
        }

        state = put_in(state, [:rows, token], row)

        if abort_connection,
          do: send(row.connection_pid, {:connection_abort, token, reason})

        if close_listener,
          do: send(row.listener, {:close_accepted, token})

        maybe_finish_abort(state, token)

      _other ->
        state
    end
  end

  defp maybe_finish_abort(state, token) do
    case Map.fetch(state.rows, token) do
      {:ok, %{phase: :aborting} = row} ->
        connection_gone = is_nil(row.connection_pid) or row.connection_down
        listener_evidence = row.listener_closed or row.listener_down

        complete =
          case row.transfer_disposition do
            :listener_owned -> connection_gone and listener_evidence
            :connection_owned -> connection_gone
            :transferring -> connection_gone and row.listener_down
          end

        if complete, do: remove_row(state, token), else: state

      _other ->
        state
    end
  end

  defp close_live(state, token, reason) do
    case Map.fetch(state.rows, token) do
      {:ok, %{phase: phase} = row} when phase in [:live, :closing] ->
        row = %{row | phase: :closing}
        if row.connection_pid, do: send(row.connection_pid, {:connection_abort, token, reason})
        put_in(state, [:rows, token], row)

      _other ->
        state
    end
  end

  defp maybe_finish_close_all(%{close_all: %{from: from, timer: timer}} = state)
       when map_size(state.rows) == 0 do
    _ = Process.cancel_timer(timer)
    GenServer.reply(from, :ok)
    Logger.debug("loopex daemon connection close-all complete")
    %{state | close_all: nil}
  end

  defp maybe_finish_close_all(state), do: state

  defp connection_down(state, token) do
    case Map.fetch(state.rows, token) do
      {:ok, %{phase: phase}} when phase in [:live, :closing] -> remove_row(state, token)
      {:ok, %{phase: :handing_off}} -> request_abort(state, token, :connection_lost)
      {:ok, %{phase: :aborting}} -> maybe_finish_abort(state, token)
      _other -> state
    end
  end

  defp listener_down(state, incarnation) do
    tokens =
      state.rows
      |> Enum.filter(fn {_token, row} -> row.listener_incarnation == incarnation end)
      |> Enum.map(&elem(&1, 0))

    state = update_in(state.listeners, &Map.delete(&1, incarnation))

    Enum.reduce(tokens, state, fn token, acc ->
      acc = update_row(acc, token, &%{&1 | listener_down: true})

      case get_in(acc, [:rows, token, :phase]) do
        phase when phase in [:handing_off, :aborting] ->
          acc |> request_abort(token, :listener_lost) |> maybe_finish_abort(token)

        _other ->
          acc
      end
    end)
  end

  defp remove_row(state, token) do
    case Map.pop(state.rows, token) do
      {nil, _rows} ->
        state

      {row, rows} ->
        cancel_timer(row.timer, token)
        state = release_row_attachment(state, row.connection_incarnation)

        child_monitors =
          if row.connection_monitor,
            do: Map.delete(state.child_monitors, row.connection_monitor),
            else: state.child_monitors

        state = %{
          state
          | rows: rows,
            child_monitors: child_monitors,
            output_commitment: state.output_commitment - OutputBuffer.commitment(row.output)
        }

        state = release_listener_token(state, row.listener_incarnation, token)

        state
        |> unmark_transport_row(token)
        |> maybe_acknowledge_transport_sweep()
        |> maybe_finish_close_all()
    end
  end

  defp retain_listener(state, listener, incarnation) do
    case Map.fetch(state.listeners, incarnation) do
      {:ok, %{pid: ^listener}} ->
        {:ok, state}

      {:ok, _different} ->
        {:error, :reservation_unavailable}

      :error ->
        monitor = Process.monitor(listener)
        entry = %{pid: listener, monitor: monitor, tokens: MapSet.new()}
        {:ok, put_in(state, [:listeners, incarnation], entry)}
    end
  end

  defp add_listener_token(state, incarnation, token) do
    update_in(state, [:listeners, incarnation, :tokens], &MapSet.put(&1, token))
  end

  defp release_listener_token(state, incarnation, token) do
    case Map.fetch(state.listeners, incarnation) do
      {:ok, entry} ->
        tokens = MapSet.delete(entry.tokens, token)

        if MapSet.size(tokens) == 0 do
          Process.demonitor(entry.monitor, [:flush])
          update_in(state.listeners, &Map.delete(&1, incarnation))
        else
          put_in(state, [:listeners, incarnation, :tokens], tokens)
        end

      :error ->
        state
    end
  end

  defp listener_for_monitor(state, monitor, pid) do
    Enum.find(state.listeners, fn {_incarnation, entry} ->
      entry.monitor == monitor and entry.pid == pid
    end)
  end

  defp tracked_connection_pid?(state, pid),
    do: Enum.any?(state.rows, fn {_token, row} -> row.connection_pid == pid end)

  defp connection_row(state, connection, incarnation) do
    Enum.find_value(state.rows, fn {token, row} ->
      if row.connection_pid == connection and row.connection_incarnation == incarnation,
        do: {token, row}
    end)
  end

  defp initialized_connection_row(state, connection, incarnation) do
    case connection_row(state, connection, incarnation) do
      {token, %{phase: :live, initialized: true} = row} -> {token, row}
      _other -> nil
    end
  end

  defp enqueue_succession(state, caller, incarnation, transition, message) do
    case initialized_connection_row(state, caller, incarnation) do
      {token, row} ->
        wake_connection = OutputBuffer.empty?(row.output)

        case transition.(row.output) do
          {:ok, output} ->
            state = put_output(state, token, row, output)
            if wake_connection, do: send(caller, {:output_ready, incarnation})
            Logger.debug(message)
            {:reply, :ok, state}

          {:error, _reason} ->
            Logger.debug("loopex daemon succession output invariant refused")
            {:reply, {:error, :succession_unavailable}, state}
        end

      _other ->
        {:reply, {:error, :succession_unavailable}, state}
    end
  end

  defp update_succession(state, caller, incarnation, transition, message) do
    case initialized_connection_row(state, caller, incarnation) do
      {token, row} ->
        case transition.(row.output) do
          {:ok, output} ->
            Logger.debug(message)
            {:reply, :ok, put_output(state, token, row, output)}

          {:error, _reason} ->
            {:reply, {:error, :succession_unavailable}, state}
        end

      _other ->
        {:reply, {:error, :succession_unavailable}, state}
    end
  end

  defp put_output(state, token, row, output) do
    before = OutputBuffer.commitment(row.output)
    commitment = state.output_commitment + OutputBuffer.commitment(output) - before
    put_output(state, token, row, output, commitment)
  end

  defp put_output(state, token, row, output, commitment) do
    row = %{row | output: output}
    %{put_in(state, [:rows, token], row) | output_commitment: commitment}
  end

  defp update_row(state, token, function) do
    case Map.fetch(state.rows, token) do
      {:ok, row} -> put_in(state, [:rows, token], function.(row))
      :error -> state
    end
  end

  defp apply_routing_mirror(state, :install_provisional, exact_row) do
    with {:ok, row} <- validate_provisional_mirror(exact_row),
         :ok <- mirror_connection_live(state, row),
         :ok <- mirror_slot_available(state, row) do
      case Map.fetch(state.routing_mirrors, row.session_id) do
        {:ok, ^row} ->
          {:ok, state}

        {:ok, _other} ->
          {{:error, :mirror_conflict}, state}

        :error ->
          Logger.debug("loopex daemon provisional routing mirror installed")
          {:ok, put_in(state, [:routing_mirrors, row.session_id], row)}
      end
    else
      {:error, reason} -> {{:error, reason}, state}
    end
  end

  defp apply_routing_mirror(state, {:resolve_provisional, :granted}, exact_row) do
    with {:ok, provisional} <- validate_provisional_mirror(exact_row) do
      granted = granted_mirror(provisional)

      case Map.fetch(state.routing_mirrors, provisional.session_id) do
        {:ok, ^provisional} ->
          Logger.debug("loopex daemon routing mirror granted")
          {:ok, put_in(state, [:routing_mirrors, provisional.session_id], granted)}

        {:ok, ^granted} ->
          {:ok, state}

        _other ->
          {{:error, :mirror_conflict}, state}
      end
    else
      {:error, reason} -> {{:error, reason}, state}
    end
  end

  defp apply_routing_mirror(state, {:resolve_provisional, :cancelled}, exact_row) do
    with {:ok, provisional} <- validate_provisional_mirror(exact_row) do
      case Map.fetch(state.routing_mirrors, provisional.session_id) do
        {:ok, ^provisional} ->
          Logger.debug("loopex daemon provisional routing mirror cancelled")
          {:ok, update_in(state.routing_mirrors, &Map.delete(&1, provisional.session_id))}

        :error ->
          {:ok, state}

        {:ok, _other} ->
          {{:error, :mirror_conflict}, state}
      end
    else
      {:error, reason} -> {{:error, reason}, state}
    end
  end

  defp apply_routing_mirror(state, :clear_granted, exact_row) do
    with {:ok, granted} <- validate_granted_mirror(exact_row) do
      case Map.fetch(state.routing_mirrors, granted.session_id) do
        {:ok, ^granted} ->
          Logger.debug("loopex daemon granted routing mirror cleared")
          {:ok, update_in(state.routing_mirrors, &Map.delete(&1, granted.session_id))}

        :error ->
          {:ok, state}

        {:ok, _other} ->
          {{:error, :mirror_conflict}, state}
      end
    else
      {:error, reason} -> {{:error, reason}, state}
    end
  end

  defp apply_routing_mirror(state, :pop_owner_mirror, exact_row) do
    with {:ok, owner} <- validate_mirror_owner(exact_row) do
      case Map.fetch(state.routing_mirrors, owner.session_id) do
        {:ok,
         %{
           phase: :granted,
           owner_pid: owner_pid,
           owner_incarnation: owner_incarnation
         } = mirror}
        when owner_pid == owner.owner_pid and owner_incarnation == owner.owner_incarnation ->
          route = %{
            holder_pid: mirror.holder_pid,
            holder_incarnation: mirror.holder_incarnation,
            writer_epoch: mirror.writer_epoch
          }

          Logger.debug("loopex daemon owner routing mirror popped")

          {{:ok, {:holder, route}},
           update_in(state.routing_mirrors, &Map.delete(&1, owner.session_id))}

        {:ok,
         %{
           phase: :provisional,
           owner_pid: owner_pid,
           owner_incarnation: owner_incarnation
         }}
        when owner_pid == owner.owner_pid and owner_incarnation == owner.owner_incarnation ->
          {{:error, :mirror_provisional}, state}

        _absent_or_successor ->
          {{:ok, :absent}, state}
      end
    else
      {:error, reason} -> {{:error, reason}, state}
    end
  end

  defp apply_routing_mirror(state, _action, _exact_row),
    do: {{:error, :invalid_mirror}, state}

  defp validate_provisional_mirror(
         %{
           permit_id: {permit_incarnation, _slot, _sequence} = permit_id,
           start_op_ref: start_op_ref,
           session_id: session_id,
           owner_pid: owner_pid,
           owner_incarnation: owner_incarnation,
           holder_pid: holder_pid,
           holder_incarnation: holder_incarnation,
           writer_epoch: writer_epoch
         } = row
       )
       when map_size(row) == 8 and is_pid(owner_pid) and is_pid(holder_pid) and
              (is_nil(start_op_ref) or is_reference(start_op_ref)) and is_binary(session_id) and
              byte_size(session_id) in 1..256 and is_binary(owner_incarnation) and
              byte_size(owner_incarnation) == 16 and is_binary(holder_incarnation) and
              byte_size(holder_incarnation) == 16 and permit_incarnation == holder_incarnation and
              is_binary(writer_epoch) and
              byte_size(writer_epoch) in 1..64 do
    case validate_activation_origin(permit_id) do
      :ok -> {:ok, Map.put(row, :phase, :provisional)}
      {:error, _reason} -> {:error, :invalid_mirror}
    end
  end

  defp validate_provisional_mirror(_row), do: {:error, :invalid_mirror}

  defp validate_granted_mirror(
         %{
           phase: :granted,
           session_id: session_id,
           owner_pid: owner_pid,
           owner_incarnation: owner_incarnation,
           holder_pid: holder_pid,
           holder_incarnation: holder_incarnation,
           writer_epoch: writer_epoch
         } = row
       )
       when map_size(row) == 7 and is_pid(owner_pid) and is_pid(holder_pid) and
              is_binary(session_id) and byte_size(session_id) in 1..256 and
              is_binary(owner_incarnation) and byte_size(owner_incarnation) == 16 and
              is_binary(holder_incarnation) and byte_size(holder_incarnation) == 16 and
              is_binary(writer_epoch) and byte_size(writer_epoch) in 1..64,
       do: {:ok, row}

  defp validate_granted_mirror(_row), do: {:error, :invalid_mirror}

  defp validate_mirror_owner(
         %{
           session_id: session_id,
           owner_pid: owner_pid,
           owner_incarnation: owner_incarnation
         } = owner
       )
       when map_size(owner) == 3 and is_pid(owner_pid) and is_binary(session_id) and
              byte_size(session_id) in 1..256 and is_binary(owner_incarnation) and
              byte_size(owner_incarnation) == 16,
       do: {:ok, owner}

  defp validate_mirror_owner(_owner), do: {:error, :invalid_mirror}

  defp granted_mirror(provisional) do
    provisional
    |> Map.drop([:permit_id, :start_op_ref])
    |> Map.put(:phase, :granted)
  end

  defp mirror_connection_live(state, mirror) do
    if Enum.any?(state.rows, fn {_token, row} ->
         row.phase == :live and row.initialized and row.connection_pid == mirror.holder_pid and
           row.connection_incarnation == mirror.holder_incarnation
       end),
       do: :ok,
       else: {:error, :connection_not_live}
  end

  defp mirror_slot_available(state, mirror) do
    if Map.has_key?(state.routing_mirrors, mirror.session_id) or
         map_size(state.routing_mirrors) < @connection_limit,
       do: :ok,
       else: {:error, :mirror_capacity_reached}
  end

  defp reserve_activation_binding(state, origin_id, binding) do
    with :ok <- validate_activation_origin(origin_id),
         {:ok, key, expected_session_id, create_command} <-
           normalize_activation_binding(binding),
         :ok <- activation_origin_available(state, origin_id, key),
         :ok <- activation_create_command_available(state, create_command) do
      case Map.fetch(state.activation_bindings, key) do
        {:ok, %{primary_origin_id: primary_origin_id, reservation_ref: reservation_ref}} ->
          if primary_origin_id == origin_id do
            {:ok, {:primary, reservation_ref}, state}
          else
            Logger.debug("loopex daemon activation reservation joined")
            {:ok, {:duplicate, primary_origin_id, reservation_ref}, state}
          end

        :error ->
          cond do
            not is_nil(expected_session_id) and
                MapSet.member?(state.activation_set, expected_session_id) ->
              Logger.debug("loopex daemon activation already counted")
              {:ok, :already_active, state}

            MapSet.size(state.activation_set) + map_size(state.activation_reservations) +
              state.anonymous_activations >= @activation_limit ->
              Logger.debug("loopex daemon activation capacity reached")
              {:error, :activation_ceiling_reached}

            true ->
              reservation_ref = :crypto.strong_rand_bytes(16)

              reservation = %{
                origin_id: origin_id,
                key: key,
                expected_session_id: expected_session_id,
                create_command: create_command
              }

              binding_entry = %{
                primary_origin_id: origin_id,
                reservation_ref: reservation_ref
              }

              state =
                state
                |> put_in([:activation_reservations, reservation_ref], reservation)
                |> put_in([:activation_bindings, key], binding_entry)
                |> put_in([:activation_origins, origin_id], %{
                  key: key,
                  reservation_ref: reservation_ref
                })
                |> put_create_command(create_command, reservation_ref)

              Logger.debug("loopex daemon activation slot reserved")
              {:ok, {:primary, reservation_ref}, state}
          end
      end
    end
  end

  defp resolve_activation_reservation(state, reservation_ref, disposition, session_id)
       when is_binary(reservation_ref) and byte_size(reservation_ref) == 16 and
              disposition in [:activated, :no_activation] do
    case Map.fetch(state.activation_reservations, reservation_ref) do
      :error ->
        {:ok, state}

      {:ok, reservation} ->
        with :ok <- validate_activation_resolution(reservation, disposition, session_id) do
          state = drop_activation_reservation(state, reservation_ref, reservation)

          state =
            if disposition == :activated do
              update_in(state.activation_set, &MapSet.put(&1, session_id))
            else
              state
            end

          Logger.debug("loopex daemon activation reservation resolved")
          {:ok, state}
        end
    end
  end

  defp resolve_activation_reservation(_state, _reservation_ref, _disposition, _session_id),
    do: {:error, :activation_resolution_invalid}

  defp normalize_activation_binding({:create, command_id, digest})
       when is_binary(command_id) and byte_size(command_id) in 1..256 and is_binary(digest) and
              byte_size(digest) == 32 do
    {:ok, {:create, command_id, digest}, nil, {command_id, digest}}
  end

  defp normalize_activation_binding({:resume, session_id, command_id})
       when is_binary(session_id) and byte_size(session_id) in 1..256 and is_binary(command_id) and
              byte_size(command_id) in 1..256 do
    {:ok, {:resume, session_id, command_id}, session_id, nil}
  end

  defp normalize_activation_binding(_binding), do: {:error, :invalid_activation}

  defp validate_activation_origin({incarnation, slot, sequence})
       when is_binary(incarnation) and byte_size(incarnation) == 16 and slot in 0..31 and
              is_integer(sequence) and sequence > 0,
       do: :ok

  defp validate_activation_origin(_origin_id), do: {:error, :invalid_activation}

  defp activation_origin_available(state, origin_id, key) do
    case Map.fetch(state.activation_origins, origin_id) do
      {:ok, %{key: ^key}} -> :ok
      {:ok, _other} -> {:error, :activation_conflict}
      :error -> :ok
    end
  end

  defp activation_create_command_available(_state, nil), do: :ok

  defp activation_create_command_available(state, {command_id, digest}) do
    case Map.fetch(state.activation_create_commands, command_id) do
      {:ok, %{digest: ^digest}} -> :ok
      {:ok, _other} -> {:error, :activation_conflict}
      :error -> :ok
    end
  end

  defp put_create_command(state, nil, _reservation_ref), do: state

  defp put_create_command(state, {command_id, digest}, reservation_ref) do
    put_in(state, [:activation_create_commands, command_id], %{
      digest: digest,
      reservation_ref: reservation_ref
    })
  end

  defp validate_activation_resolution(
         %{expected_session_id: expected_session_id},
         :activated,
         session_id
       )
       when is_binary(session_id) and byte_size(session_id) in 1..256 do
    if is_nil(expected_session_id) or expected_session_id == session_id,
      do: :ok,
      else: {:error, :activation_resolution_invalid}
  end

  defp validate_activation_resolution(_reservation, :no_activation, nil), do: :ok

  defp validate_activation_resolution(_reservation, _disposition, _session_id),
    do: {:error, :activation_resolution_invalid}

  defp drop_activation_reservation(state, reservation_ref, reservation) do
    state = %{
      state
      | activation_reservations: Map.delete(state.activation_reservations, reservation_ref),
        activation_bindings: Map.delete(state.activation_bindings, reservation.key),
        activation_origins: Map.delete(state.activation_origins, reservation.origin_id)
    }

    case reservation.create_command do
      {command_id, _digest} ->
        case Map.get(state.activation_create_commands, command_id) do
          %{reservation_ref: ^reservation_ref} ->
            update_in(state.activation_create_commands, &Map.delete(&1, command_id))

          _other ->
            state
        end

      nil ->
        state
    end
  end

  defp validate_resume_identity(
         origin_id,
         session_id,
         command_id,
         owner_incarnation,
         eligibility
       ) do
    with :ok <- validate_activation_origin(origin_id),
         {:ok, _key, _session_id, _create_command} <-
           normalize_activation_binding({:resume, session_id, command_id}),
         true <- valid_incarnation?(owner_incarnation),
         true <- eligibility in [:eligible, :ineligible] do
      :ok
    else
      _invalid -> {:error, :invalid_activation}
    end
  end

  defp prepare_resume_call(
         state,
         _relay,
         _relay_incarnation,
         _owner,
         _owner_incarnation,
         _origin_id,
         _session_id,
         _command_id,
         :ineligible
       ),
       do: {:reply, {:ok, :unreserved}, state}

  defp prepare_resume_call(
         state,
         relay,
         relay_incarnation,
         owner,
         owner_incarnation,
         origin_id,
         session_id,
         command_id,
         :eligible
       ) do
    case reserve_activation_binding(state, origin_id, {:resume, session_id, command_id}) do
      {:ok, {:primary, reservation_ref}, state} ->
        case retain_resume_preparation(
               state,
               owner,
               owner_incarnation,
               origin_id,
               session_id,
               command_id,
               reservation_ref
             ) do
          {:ok, state} -> {:reply, {:ok, :prepared}, state}
          {:error, reason} -> {:reply, {:error, reason}, state}
        end

      {:ok, {:duplicate, primary_origin_id, _reservation_ref}, state} ->
        case AdmissionRelay.wait_for_ticket(
               relay,
               origin_id,
               primary_origin_id,
               relay_incarnation
             ) do
          {:ok, ^primary_origin_id} ->
            Logger.debug("loopex daemon prepared resume joined primary")
            {:reply, {:ok, {:waiting, primary_origin_id}}, state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      {:ok, :already_active, state} ->
        {:reply, {:ok, :unreserved}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp retain_resume_preparation(
         state,
         owner,
         owner_incarnation,
         origin_id,
         session_id,
         command_id,
         reservation_ref
       ) do
    case Map.fetch(state.activation_preparations, origin_id) do
      {:ok,
       %{
         owner: ^owner,
         owner_incarnation: ^owner_incarnation,
         session_id: ^session_id,
         command_id: ^command_id,
         reservation_ref: ^reservation_ref
       }} ->
        {:ok, state}

      {:ok, _other} ->
        {:error, :activation_conflict}

      :error ->
        owner_monitor = Process.monitor(owner)

        preparation = %{
          owner: owner,
          owner_incarnation: owner_incarnation,
          owner_monitor: owner_monitor,
          session_id: session_id,
          command_id: command_id,
          reservation_ref: reservation_ref
        }

        state =
          state
          |> put_in([:activation_preparations, origin_id], preparation)
          |> put_in([:activation_preparation_monitors, owner_monitor], origin_id)

        Logger.debug("loopex daemon resume activation prepared")
        {:ok, state}
    end
  end

  defp claim_resume_preparation(
         state,
         owner,
         owner_incarnation,
         origin_id,
         session_id,
         command_id,
         reservation_ref
       ) do
    case Map.fetch(state.activation_preparations, origin_id) do
      {:ok,
       %{
         owner: ^owner,
         owner_incarnation: ^owner_incarnation,
         session_id: ^session_id,
         command_id: ^command_id,
         reservation_ref: ^reservation_ref
       } = preparation} ->
        {:ok, drop_resume_preparation(state, origin_id, preparation, true)}

      :error ->
        {:ok, state}

      _other ->
        {:error, :owner_unavailable}
    end
  end

  defp release_owned_resume_preparation(state, origin_id, owner, owner_incarnation) do
    case Map.fetch(state.activation_preparations, origin_id) do
      {:ok, %{owner: ^owner, owner_incarnation: ^owner_incarnation}} ->
        {:ok, release_resume_preparation(state, origin_id)}

      :error ->
        {:ok, state}

      _other ->
        {:error, :owner_unavailable}
    end
  end

  defp release_resume_preparation(state, origin_id, demonitor? \\ true) do
    case Map.fetch(state.activation_preparations, origin_id) do
      {:ok, preparation} ->
        state = drop_resume_preparation(state, origin_id, preparation, demonitor?)

        {:ok, state} =
          resolve_activation_reservation(
            state,
            preparation.reservation_ref,
            :no_activation,
            nil
          )

        state

      :error ->
        state
    end
  end

  defp drop_resume_preparation(state, origin_id, preparation, demonitor?) do
    if demonitor?, do: Process.demonitor(preparation.owner_monitor, [:flush])

    %{
      state
      | activation_preparations: Map.delete(state.activation_preparations, origin_id),
        activation_preparation_monitors:
          Map.delete(state.activation_preparation_monitors, preparation.owner_monitor)
    }
  end

  defp validate_resume_promotion(
         origin_id,
         session_id,
         command_id,
         owner_incarnation,
         eligibility,
         attached,
         control_refusal,
         capacity_refusal,
         task_fun
       ) do
    with :ok <- validate_activation_origin(origin_id),
         {:ok, _key, _session_id, _create_command} <-
           normalize_activation_binding({:resume, session_id, command_id}),
         true <- valid_incarnation?(owner_incarnation),
         true <- eligibility in [:eligible, :ineligible],
         true <- is_boolean(attached),
         true <- is_map(control_refusal) and not is_struct(control_refusal),
         true <- is_map(capacity_refusal) and not is_struct(capacity_refusal),
         true <- is_function(task_fun, 0) do
      :ok
    else
      _invalid -> {:error, :invalid_activation}
    end
  end

  defp bound_relay(%{relay: %{pid: relay, incarnation: incarnation}})
       when is_pid(relay) and is_binary(incarnation),
       do: {:ok, relay, incarnation}

  defp bound_relay(_state), do: {:error, :relay_unavailable}

  defp promote_resume_call(
         state,
         relay,
         relay_incarnation,
         owner,
         owner_incarnation,
         origin_id,
         session_id,
         command_id,
         eligibility,
         attached,
         control_refusal,
         capacity_refusal,
         task_fun
       ) do
    key = {:resume, session_id, command_id}

    case Map.fetch(state.activation_promotion_bindings, key) do
      {:ok, %{primary_origin_id: primary_origin_id}} when primary_origin_id != origin_id ->
        case AdmissionRelay.wait_for_ticket(
               relay,
               origin_id,
               primary_origin_id,
               relay_incarnation
             ) do
          {:ok, ^primary_origin_id} ->
            Logger.debug("loopex daemon resume joined primary")
            {:reply, {:ok, {:waiting, primary_origin_id}}, state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      {:ok, %{primary_origin_id: ^origin_id}} ->
        {:reply, {:ok, :admitted}, state}

      :error ->
        reserve_and_promote_resume(
          state,
          relay,
          relay_incarnation,
          owner,
          owner_incarnation,
          origin_id,
          session_id,
          command_id,
          eligibility,
          attached,
          control_refusal,
          capacity_refusal,
          task_fun
        )
    end
  end

  defp reserve_and_promote_resume(
         state,
         relay,
         relay_incarnation,
         owner,
         owner_incarnation,
         origin_id,
         _session_id,
         _command_id,
         :ineligible,
         _attached,
         control_refusal,
         _capacity_refusal,
         _task_fun
       ) do
    case release_owned_resume_preparation(state, origin_id, owner, owner_incarnation) do
      {:ok, state} ->
        refuse_resume(
          state,
          relay,
          relay_incarnation,
          owner,
          owner_incarnation,
          origin_id,
          control_refusal
        )

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp reserve_and_promote_resume(
         state,
         relay,
         relay_incarnation,
         owner,
         owner_incarnation,
         origin_id,
         session_id,
         command_id,
         :eligible,
         attached,
         control_refusal,
         capacity_refusal,
         task_fun
       ) do
    case reserve_activation_binding(state, origin_id, {:resume, session_id, command_id}) do
      {:ok, {:primary, reservation_ref}, state} ->
        case claim_resume_preparation(
               state,
               owner,
               owner_incarnation,
               origin_id,
               session_id,
               command_id,
               reservation_ref
             ) do
          {:ok, state} ->
            promote_resume_primary(
              state,
              relay,
              relay_incarnation,
              owner,
              owner_incarnation,
              origin_id,
              session_id,
              command_id,
              reservation_ref,
              task_fun
            )

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      {:ok, {:duplicate, primary_origin_id, _reservation_ref}, state} ->
        case AdmissionRelay.wait_for_ticket(
               relay,
               origin_id,
               primary_origin_id,
               relay_incarnation
             ) do
          {:ok, ^primary_origin_id} ->
            {:reply, {:ok, {:waiting, primary_origin_id}}, state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      {:ok, :already_active, state} when attached ->
        promote_resume_primary(
          state,
          relay,
          relay_incarnation,
          owner,
          owner_incarnation,
          origin_id,
          session_id,
          command_id,
          nil,
          task_fun
        )

      {:ok, :already_active, state} ->
        refuse_resume(
          state,
          relay,
          relay_incarnation,
          owner,
          owner_incarnation,
          origin_id,
          control_refusal
        )

      {:error, :activation_ceiling_reached} ->
        refuse_resume(
          state,
          relay,
          relay_incarnation,
          owner,
          owner_incarnation,
          origin_id,
          capacity_refusal
        )

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp promote_resume_primary(
         state,
         relay,
         relay_incarnation,
         owner,
         owner_incarnation,
         origin_id,
         session_id,
         command_id,
         reservation_ref,
         task_fun
       ) do
    settlement_ref = reservation_ref || :crypto.strong_rand_bytes(16)
    classification_ref = make_ref()
    registry = self()

    relay_task = fn ->
      case task_fun.() do
        {lease_disposition, activation_disposition, result}
        when lease_disposition in [:accepted, :admission_unknown, :refused] and
               activation_disposition in [:activated, :no_activation] and is_map(result) ->
          send(
            registry,
            {:activation_resume_classified, classification_ref, settlement_ref, lease_disposition,
             activation_disposition, result}
          )

          result

        _invalid ->
          exit(:invalid_activation_result)
      end
    end

    key = {:resume, session_id, command_id}

    promotion = %{
      origin_id: origin_id,
      key: key,
      owner: owner,
      owner_incarnation: owner_incarnation,
      session_id: session_id,
      reservation_ref: reservation_ref,
      classification_ref: classification_ref,
      classification: nil,
      relay_result: nil
    }

    state =
      state
      |> put_in([:activation_promotions, settlement_ref], promotion)
      |> put_in([:activation_promotion_bindings, key], %{
        primary_origin_id: origin_id,
        settlement_ref: settlement_ref
      })

    case AdmissionRelay.promote_resume_ticket(
           relay,
           origin_id,
           relay_incarnation,
           settlement_ref,
           owner,
           owner_incarnation,
           relay_task
         ) do
      {:ok, ^origin_id} ->
        Logger.debug("loopex daemon resume promoted")
        {:reply, {:ok, :admitted}, state}

      {:error, reason} ->
        state = drop_resume_promotion(state, settlement_ref, promotion)

        state =
          if reservation_ref do
            {:ok, state} =
              resolve_activation_reservation(
                state,
                reservation_ref,
                :no_activation,
                nil
              )

            state
          else
            state
          end

        {:reply, {:error, reason}, state}
    end
  end

  defp refuse_resume(
         state,
         relay,
         relay_incarnation,
         owner,
         owner_incarnation,
         origin_id,
         result
       ) do
    case AdmissionRelay.refuse_resume_ticket(
           relay,
           origin_id,
           relay_incarnation,
           owner,
           owner_incarnation,
           result
         ) do
      {:ok, ^origin_id} -> {:reply, {:ok, :completed}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp settle_promotion(state, settlement_ref, %{kind: :create}),
    do: settle_create_promotion(state, settlement_ref)

  defp settle_promotion(state, settlement_ref, %{kind: :attach}),
    do: settle_attach_promotion(state, settlement_ref)

  defp settle_promotion(state, settlement_ref, _promotion),
    do: settle_resume_promotion(state, settlement_ref)

  defp attachment_not_pending(state, incarnation) do
    case Map.get(state.attachments, incarnation) do
      %{phase: :pending} -> {:error, :attachment_pending}
      _other -> :ok
    end
  end

  # Concept: a replacement keeps the connection's one counted attachment;
  # every other attach must fit both ceilings.
  defp attachment_capacity?(state, session_id, previous) do
    replacing = match?(%{phase: :installed, session_id: ^session_id}, previous)

    per_session =
      Enum.count(state.attachments, fn {_incarnation, attachment} ->
        attachment.session_id == session_id
      end)

    replacing or
      (per_session < @attachments_per_session and
         map_size(state.attachments) < @connection_limit)
  end

  defp promote_attach_refusal(state, relay, relay_incarnation, origin_id, refusal) do
    promote_attach_ticket(
      state,
      relay,
      relay_incarnation,
      origin_id,
      %{refusal: true, incarnation: nil, session_id: nil, previous: nil},
      fn -> {:refused, refusal} end
    )
  end

  defp promote_attach_primary(
         state,
         relay,
         relay_incarnation,
         origin_id,
         connection,
         incarnation,
         session_id,
         previous,
         task_fun
       ) do
    pending = %{
      phase: :pending,
      session_id: session_id,
      connection: connection,
      attachment_id: nil
    }

    state = put_in(state, [:attachments, incarnation], pending)

    promote_attach_ticket(
      state,
      relay,
      relay_incarnation,
      origin_id,
      %{refusal: false, incarnation: incarnation, session_id: session_id, previous: previous},
      task_fun
    )
  end

  defp promote_attach_ticket(state, relay, relay_incarnation, origin_id, binding, task_fun) do
    settlement_ref = :crypto.strong_rand_bytes(16)
    classification_ref = make_ref()
    registry = self()

    relay_task = fn ->
      case task_fun.() do
        {:installed, attachment_id, result} = classification
        when is_binary(attachment_id) and is_map(result) ->
          send(
            registry,
            {:attachment_classified, classification_ref, settlement_ref, classification}
          )

          result

        {:refused, result} = classification when is_map(result) ->
          send(
            registry,
            {:attachment_classified, classification_ref, settlement_ref, classification}
          )

          result

        _invalid ->
          exit(:invalid_attachment_result)
      end
    end

    promotion =
      Map.merge(binding, %{
        kind: :attach,
        origin_id: origin_id,
        classification_ref: classification_ref,
        classification: nil,
        relay_result: nil,
        record_ref: nil,
        owner_acked: false
      })

    state = put_in(state, [:activation_promotions, settlement_ref], promotion)

    case AdmissionRelay.promote_ticket(
           relay,
           origin_id,
           relay_incarnation,
           settlement_ref,
           relay_task
         ) do
      {:ok, ^origin_id} ->
        Logger.debug("loopex daemon attach promoted")
        {:reply, {:ok, :admitted}, state}

      {:error, reason} ->
        state =
          state
          |> update_in([:activation_promotions], &Map.delete(&1, settlement_ref))
          |> restore_attachment(promotion)

        {:reply, {:error, reason}, state}
    end
  end

  defp restore_attachment(state, %{refusal: true}), do: state

  defp restore_attachment(state, %{incarnation: incarnation, previous: previous}) do
    case {Map.get(state.attachments, incarnation), previous} do
      {%{phase: :pending}, nil} -> update_in(state.attachments, &Map.delete(&1, incarnation))
      {%{phase: :pending}, previous} -> put_in(state, [:attachments, incarnation], previous)
      _other -> state
    end
  end

  # Concept: a successful attach becomes visible to its client only after the
  # daemon owner has recorded it for the session's mutation gate.
  defp settle_attach_promotion(state, settlement_ref) do
    case Map.fetch(state.activation_promotions, settlement_ref) do
      {:ok,
       %{classification: {:installed, attachment_id, result}, relay_result: result} = promotion} ->
        cond do
          promotion.owner_acked ->
            finish_attach_promotion(state, settlement_ref, promotion)

          not is_nil(promotion.record_ref) ->
            state

          true ->
            record_attachment(state, settlement_ref, promotion, attachment_id)
        end

      {:ok, %{classification: {:refused, result}, relay_result: result} = promotion} ->
        state
        |> restore_attachment(promotion)
        |> finish_attach_promotion(settlement_ref, promotion)

      {:ok, %{classification: classification, relay_result: relay_result}}
      when not is_nil(classification) and not is_nil(relay_result) ->
        exit(:attachment_settlement_invalid)

      _other ->
        state
    end
  end

  defp record_attachment(state, settlement_ref, promotion, attachment_id) do
    case Map.get(state.attachments, promotion.incarnation) do
      %{phase: :pending, connection: connection} = pending ->
        record_ref = make_ref()
        installed = %{pending | phase: :installed, attachment_id: attachment_id}

        case promotion.previous do
          %{phase: :installed, attachment_id: previous_id} = previous
          when previous_id != attachment_id ->
            notify_attachment(state, :closed, previous, promotion.incarnation, nil)

          _other ->
            :ok
        end

        notify_attachment(state, :opened, installed, promotion.incarnation, record_ref)
        Logger.debug("loopex daemon attachment recorded")

        state
        |> put_in([:attachments, promotion.incarnation], %{installed | connection: connection})
        |> put_in([:activation_promotions, settlement_ref], %{promotion | record_ref: record_ref})

      _connection_gone ->
        finish_attach_promotion(state, settlement_ref, promotion)
    end
  end

  defp notify_attachment(state, action, attachment, incarnation, record_ref) do
    send(
      state.owner,
      {:registry_attachment, self(), record_ref, action, attachment.session_id,
       attachment.connection, incarnation, attachment.attachment_id}
    )
  end

  defp finish_attach_promotion(state, settlement_ref, promotion) do
    case AdmissionRelay.settle_ticket(
           state.relay.pid,
           promotion.origin_id,
           state.relay.incarnation,
           settlement_ref
         ) do
      :ok ->
        Logger.debug("loopex daemon attach settled")
        update_in(state.activation_promotions, &Map.delete(&1, settlement_ref))

      {:error, _reason} ->
        exit(:attachment_settlement_failed)
    end
  end

  defp release_row_attachment(state, incarnation) do
    case Map.pop(state.attachments, incarnation) do
      {%{phase: :installed} = attachment, attachments} ->
        notify_attachment(state, :closed, attachment, incarnation, nil)
        %{state | attachments: attachments}

      {_pending_or_nil, attachments} ->
        %{state | attachments: attachments}
    end
  end

  defp promote_create_call(
         state,
         relay,
         relay_incarnation,
         origin_id,
         _command_id,
         _digest,
         :historical,
         _ceiling_refusal,
         _conflict_refusal,
         task_fun
       ) do
    promote_create_primary(state, relay, relay_incarnation, origin_id, nil, task_fun)
  end

  defp promote_create_call(
         state,
         relay,
         relay_incarnation,
         origin_id,
         command_id,
         digest,
         :fresh,
         ceiling_refusal,
         conflict_refusal,
         task_fun
       ) do
    case reserve_activation_binding(state, origin_id, {:create, command_id, digest}) do
      {:ok, {:primary, reservation_ref}, state} ->
        promote_create_primary(
          state,
          relay,
          relay_incarnation,
          origin_id,
          reservation_ref,
          task_fun
        )

      {:ok, {:duplicate, primary_origin_id, _reservation_ref}, state} ->
        case AdmissionRelay.wait_for_ticket(
               relay,
               origin_id,
               primary_origin_id,
               relay_incarnation
             ) do
          {:ok, ^primary_origin_id} -> {:reply, {:ok, {:waiting, primary_origin_id}}, state}
          {:error, reason} -> {:reply, {:error, reason}, state}
        end

      {:error, :activation_ceiling_reached} ->
        refusal = fn -> {:no_activation, nil, ceiling_refusal} end
        promote_create_primary(state, relay, relay_incarnation, origin_id, nil, refusal)

      {:error, :activation_conflict} ->
        refusal = fn -> {:no_activation, nil, conflict_refusal} end
        promote_create_primary(state, relay, relay_incarnation, origin_id, nil, refusal)

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  # Concept: the create ticket's task is started by the relay before this
  # promotion is acknowledged, and its classified disposition settles the
  # exact reservation before the client can learn the result.
  defp promote_create_primary(
         state,
         relay,
         relay_incarnation,
         origin_id,
         reservation_ref,
         task_fun
       ) do
    settlement_ref = reservation_ref || :crypto.strong_rand_bytes(16)
    classification_ref = make_ref()
    registry = self()

    relay_task = fn ->
      case task_fun.() do
        {disposition, session_id, result}
        when disposition in [:activated, :no_activation] and is_map(result) and
               (is_nil(session_id) or is_binary(session_id)) ->
          send(
            registry,
            {:activation_create_classified, classification_ref, settlement_ref, disposition,
             session_id, result}
          )

          result

        _invalid ->
          exit(:invalid_activation_result)
      end
    end

    promotion = %{
      kind: :create,
      origin_id: origin_id,
      reservation_ref: reservation_ref,
      classification_ref: classification_ref,
      classification: nil,
      relay_result: nil
    }

    state = put_in(state, [:activation_promotions, settlement_ref], promotion)

    case AdmissionRelay.promote_ticket(
           relay,
           origin_id,
           relay_incarnation,
           settlement_ref,
           relay_task
         ) do
      {:ok, ^origin_id} ->
        Logger.debug("loopex daemon create promoted")
        {:reply, {:ok, :admitted}, state}

      {:error, reason} ->
        state = update_in(state.activation_promotions, &Map.delete(&1, settlement_ref))

        state =
          if reservation_ref do
            {:ok, state} =
              resolve_activation_reservation(state, reservation_ref, :no_activation, nil)

            state
          else
            state
          end

        {:reply, {:error, reason}, state}
    end
  end

  defp settle_create_promotion(state, settlement_ref) do
    case Map.fetch(state.activation_promotions, settlement_ref) do
      {:ok,
       %{classification: %{result: result} = classification, relay_result: result} = promotion} ->
        with {:ok, state} <- account_create_promotion(state, promotion, classification),
             :ok <-
               AdmissionRelay.settle_ticket(
                 state.relay.pid,
                 promotion.origin_id,
                 state.relay.incarnation,
                 settlement_ref
               ) do
          Logger.debug("loopex daemon create activation settled")
          update_in(state.activation_promotions, &Map.delete(&1, settlement_ref))
        else
          _error -> exit(:activation_settlement_failed)
        end

      {:ok, %{classification: classification, relay_result: relay_result}}
      when not is_nil(classification) and not is_nil(relay_result) ->
        exit(:activation_settlement_invalid)

      _other ->
        state
    end
  end

  # Concept: every coordinator core starts counts against the ceiling, even
  # one whose create answered an error without naming its session.
  defp account_create_promotion(state, %{reservation_ref: nil}, %{disposition: :no_activation}),
    do: {:ok, state}

  defp account_create_promotion(
         state,
         %{reservation_ref: nil},
         %{disposition: :activated, session_id: session_id}
       ) do
    if is_binary(session_id),
      do: {:ok, update_in(state.activation_set, &MapSet.put(&1, session_id))},
      else: {:ok, update_in(state.anonymous_activations, &(&1 + 1))}
  end

  defp account_create_promotion(
         state,
         %{reservation_ref: reservation_ref},
         %{disposition: :activated, session_id: session_id}
       )
       when is_binary(session_id),
       do: resolve_activation_reservation(state, reservation_ref, :activated, session_id)

  defp account_create_promotion(
         state,
         %{reservation_ref: reservation_ref},
         %{disposition: :activated}
       ) do
    with {:ok, state} <-
           resolve_activation_reservation(state, reservation_ref, :no_activation, nil),
         do: {:ok, update_in(state.anonymous_activations, &(&1 + 1))}
  end

  defp account_create_promotion(
         state,
         %{reservation_ref: reservation_ref},
         %{disposition: :no_activation}
       ),
       do: resolve_activation_reservation(state, reservation_ref, :no_activation, nil)

  defp settle_resume_promotion(state, settlement_ref) do
    case Map.fetch(state.activation_promotions, settlement_ref) do
      {:ok,
       %{
         classification: %{
           lease_disposition: lease_disposition,
           activation_disposition: activation_disposition,
           result: result
         },
         relay_result: result
       } = promotion} ->
        with {:ok, state} <- account_resume_promotion(state, promotion, activation_disposition),
             :ok <-
               AdmissionRelay.settle_ticket(
                 state.relay.pid,
                 promotion.origin_id,
                 state.relay.incarnation,
                 settlement_ref
               ) do
          state = drop_resume_promotion(state, settlement_ref, promotion)

          send(
            promotion.owner,
            {:registry_resume_settled, self(), promotion.origin_id, promotion.owner_incarnation,
             lease_disposition}
          )

          Logger.debug("loopex daemon resume activation settled")
          state
        else
          _error -> exit(:activation_settlement_failed)
        end

      {:ok, %{classification: classification, relay_result: relay_result}}
      when not is_nil(classification) and not is_nil(relay_result) ->
        exit(:activation_settlement_invalid)

      _other ->
        state
    end
  end

  defp account_resume_promotion(
         state,
         %{reservation_ref: nil, session_id: session_id},
         disposition
       ) do
    if disposition == :no_activation or MapSet.member?(state.activation_set, session_id),
      do: {:ok, state},
      else: {:error, :activation_settlement_invalid}
  end

  defp account_resume_promotion(
         state,
         %{reservation_ref: reservation_ref, session_id: session_id},
         :activated
       ) do
    resolve_activation_reservation(state, reservation_ref, :activated, session_id)
  end

  defp account_resume_promotion(
         state,
         %{reservation_ref: reservation_ref},
         :no_activation
       ) do
    resolve_activation_reservation(state, reservation_ref, :no_activation, nil)
  end

  defp drop_resume_promotion(state, settlement_ref, promotion) do
    %{
      state
      | activation_promotions: Map.delete(state.activation_promotions, settlement_ref),
        activation_promotion_bindings:
          Map.delete(state.activation_promotion_bindings, promotion.key)
    }
  end

  defp before_deadline?(row), do: now_ms() < row.initialize_deadline

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp valid_incarnation?(incarnation),
    do: is_binary(incarnation) and byte_size(incarnation) == 16

  defp schedule_deadline(token, deadline, now) do
    Process.send_after(self(), {:initialize_deadline, token}, max(deadline - now, 0))
  end

  defp cancel_timer(nil, _token), do: :ok

  defp cancel_timer(timer, token) do
    _ = Process.cancel_timer(timer)

    receive do
      {:initialize_deadline, ^token} -> :ok
    after
      0 -> :ok
    end
  end

  defp flush_temporary_exit(pid) do
    receive do
      {:EXIT, ^pid, _reason} -> :ok
    after
      0 -> :ok
    end
  end

  defp unmark_transport_row(state, token) do
    %{state | transport_marked: MapSet.delete(state.transport_marked, token)}
  end

  defp maybe_acknowledge_transport_sweep(
         %{
           transport_sweep_started: true,
           transport_sweep_acknowledged: false,
           transport_marked: marked
         } = state
       ) do
    if MapSet.size(marked) == 0 do
      send(
        state.owner,
        {:transport_uninitialized_empty, self(), state.transport_cut_ref}
      )

      Logger.debug("loopex daemon uninitialized connection sweep complete")
      %{state | transport_sweep_acknowledged: true}
    else
      state
    end
  end

  defp maybe_acknowledge_transport_sweep(state), do: state
end
