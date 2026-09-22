defmodule LoopexDaemon.SocketConnection do
  @moduledoc """
  ## Concept

  One accepted daemon client becomes live only after the registry has recorded
  socket ownership. Until then the process is inert and exists only so the
  listener can transfer one exact socket without an ownership gap.

  ## Technical depth

  `init/1` performs no IO or external call. It installs monitors on the exact
  registry and listener and waits. After the listener has transferred the
  socket and the registry has recorded that result, activation asks the
  registry to promote the provisional slot. Only a successful acknowledgement
  drops the listener monitor and reports `promotion_complete`. Registry loss,
  pre-promotion listener loss, abort, or deadline refusal closes the socket.
  Once promoted, nonblocking socket receives feed the shared strict JSONL frame
  decoder, while complete encoded replies enter the registry-owned bounded
  output queue. This process claims one exact frame and advances a nonblocking
  socket send until the kernel has accepted all of it; only then does it
  acknowledge emission so the registry can release the charge. The
  generation-two negotiation becomes visible only after the
  registry consumes the final initialize compare-and-set before its unchanged
  accept-time deadline. Partial input is bounded, and fixed protocol refusals
  contain no received bytes. The socket, buffered bytes and monitor handles are
  redacted from formatted process status.

  After initialization a connection composed with a daemon context registers
  its incarnation with the admission relay and serves requests through a
  `LoopexDaemon.RequestLedger`: every admitted request occupies one sequenced
  relay origin until exactly one answer is rendered. Blocking work runs in a
  monitored `LoopexDaemon.RequestWorker`; the relay, the daemon owner and the
  lease owners deliver results, cancellations and failures back to this
  process, which renders each as one correlated record. When the daemon owner
  reports the loss of this connection's granted session owner, the connection
  writes the one uncorrelated `control_owner_lost` record, stops reading,
  attempts to flush within a fixed bound, closes and only then acknowledges
  the exact close reference.
  """

  use GenServer
  require Logger

  alias LoopexDaemon.{
    AdmissionRelay,
    ConnectionProtocol,
    ConnectionRegistry,
    Owner,
    Request,
    RequestLedger,
    RequestWorker,
    WireRecords
  }

  alias LoopexProtocol.{Frame, Session.V2}

  @owner_loss_close_ms 1_000

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options), do: GenServer.start_link(__MODULE__, options)

  @doc false
  @spec activate(pid(), :socket.socket()) :: :ok
  def activate(connection, socket), do: GenServer.cast(connection, {:activate, socket})

  @impl true
  def init(options) do
    state = %{
      registry: Keyword.fetch!(options, :registry),
      registry_monitor: nil,
      listener: Keyword.fetch!(options, :listener),
      listener_monitor: nil,
      rollback_token: Keyword.fetch!(options, :rollback_token),
      incarnation: Keyword.fetch!(options, :connection_incarnation),
      initialize_deadline: Keyword.fetch!(options, :initialize_deadline),
      phase: :waiting,
      socket: nil,
      protocol: ConnectionProtocol.new(),
      input_buffer: "",
      discarding_oversize: false,
      receive_select: nil,
      send_select: nil,
      output_claim: nil,
      context: Keyword.get(options, :context),
      ledger: RequestLedger.new(Keyword.fetch!(options, :connection_incarnation)),
      workers: %{},
      closing: nil
    }

    Logger.debug("loopex daemon socket connection waiting")

    {:ok,
     %{
       state
       | registry_monitor: Process.monitor(state.registry),
         listener_monitor: Process.monitor(state.listener)
     }}
  end

  @impl true
  def handle_cast({:activate, socket}, %{phase: :waiting} = state) do
    if socket_owner?(socket, self()) do
      case ConnectionRegistry.promote(
             state.registry,
             state.rollback_token,
             state.incarnation
           ) do
        :ok ->
          Process.demonitor(state.listener_monitor, [:flush])

          send(
            state.listener,
            {:promotion_complete, state.rollback_token, state.incarnation, self()}
          )

          Logger.debug("loopex daemon socket connection promoted")

          send(self(), :receive_next)

          {:noreply, %{state | phase: :live, socket: socket, listener_monitor: nil}}

        {:error, _reason} ->
          {:stop, :normal, %{state | socket: socket}}
      end
    else
      {:stop, :socket_owner_unverified, state}
    end
  end

  def handle_cast({:activate, socket}, state) do
    if socket_owner?(socket, self()), do: :socket.close(socket)
    {:noreply, state}
  end

  @impl true
  def handle_info({:connection_abort, token, _reason}, %{rollback_token: token} = state),
    do: {:stop, :normal, state}

  def handle_info(:receive_next, %{phase: phase, receive_select: nil, closing: nil} = state)
      when phase in [:live, :initialized],
      do: arm_receive(state)

  def handle_info({:output_ready, incarnation}, %{incarnation: incarnation} = state),
    do: output_step(state)

  def handle_info(:flush_output, state), do: output_step(state)

  def handle_info(
        {:"$socket", socket, :select, handle},
        %{
          phase: phase,
          socket: socket,
          receive_select: {:select_info, :recv, handle}
        } = state
      )
      when phase in [:live, :initialized] do
    state = Map.put(state, :receive_select, nil)
    if state.closing, do: {:noreply, state}, else: arm_receive(state)
  end

  def handle_info(
        {:"$socket", socket, :abort, {handle, _reason}},
        %{socket: socket, receive_select: {:select_info, :recv, handle}} = state
      ),
      do: {:stop, :normal, %{state | receive_select: nil}}

  def handle_info(
        {:"$socket", socket, :select, handle},
        %{
          socket: socket,
          send_select: {:select_info, :send, handle} = continuation,
          output_claim: output_claim
        } = state
      )
      when not is_nil(output_claim) do
    state
    |> Map.put(:send_select, nil)
    |> attempt_output(continuation)
    |> output_result()
  end

  def handle_info(
        {:"$socket", socket, :abort, {handle, _reason}},
        %{socket: socket, send_select: {:select_info, :send, handle}} = state
      ) do
    Logger.debug("loopex daemon socket send aborted")
    {:stop, :normal, %{state | send_select: nil}}
  end

  def handle_info({:request_worker_result, origin, incarnation, result}, state),
    do: continue_worker(state, origin, incarnation, result)

  def handle_info({:relay_permit_result, origin, record}, state),
    do: render_result(state, origin, record)

  def handle_info({:relay_ticket_result, origin, record}, state),
    do: render_result(state, origin, record)

  def handle_info({:relay_permit_cancelled, origin, reason}, state)
      when reason in [:control_owner_lost, :daemon_stopping],
      do: render_refusal(state, origin, Atom.to_string(reason))

  def handle_info({:relay_ticket_cancelled, origin, reason}, state)
      when reason in [:control_owner_lost, :daemon_stopping],
      do: render_refusal(state, origin, Atom.to_string(reason))

  def handle_info({:relay_permit_failed, origin, _reason}, state),
    do: render_refusal(state, origin, "internal_failure")

  def handle_info({:relay_ticket_failed, origin, _reason}, state),
    do: render_refusal(state, origin, "internal_failure")

  def handle_info(
        {:daemon_control_owner_lost, owner, close_ref, session_id, incarnation},
        %{incarnation: incarnation, context: %{owner: owner}, closing: nil} = state
      )
      when is_reference(close_ref) and is_binary(session_id),
      do: begin_owner_loss_close(state, owner, close_ref, session_id)

  def handle_info(
        {:owner_loss_close_deadline, close_ref},
        %{closing: %{close_ref: close_ref}} = state
      ),
      do: finish_owner_loss_close(state)

  def handle_info(
        {:DOWN, monitor, :process, registry, _reason},
        %{registry: registry, registry_monitor: monitor} = state
      ),
      do: {:stop, :registry_lost, state}

  def handle_info({:DOWN, monitor, :process, _worker, _reason}, state)
      when is_map_key(state.workers, monitor),
      do: worker_lost(state, monitor)

  def handle_info(
        {:DOWN, monitor, :process, listener, _reason},
        %{phase: :waiting, listener: listener, listener_monitor: monitor} = state
      ),
      do: {:stop, :normal, state}

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.socket, do: :socket.close(state.socket)
    Logger.debug("loopex daemon socket connection closed")
    :ok
  end

  @impl GenServer
  def format_status(status) do
    status
    |> Map.put(:state, :redacted_socket_connection_state)
    |> Map.put(:message, :redacted_socket_connection_message)
    |> Map.put(:reason, :redacted_socket_connection_reason)
    |> Map.put(:log, [])
  end

  defp socket_owner?(socket, expected) do
    try do
      case :socket.info(socket) do
        %{owner: ^expected} -> true
        _other -> false
      end
    catch
      :error, _reason -> false
    end
  end

  defp arm_receive(state) do
    case :socket.recv(state.socket, 0, :nowait) do
      {:ok, bytes} when is_binary(bytes) and byte_size(bytes) > 0 ->
        case consume_bytes(state, bytes) do
          {:ok, state} ->
            send(self(), :receive_next)
            {:noreply, state}

          {:stop, state} ->
            {:stop, :normal, state}
        end

      {:ok, _empty} ->
        {:stop, :normal, state}

      {:select, select_info} ->
        {:noreply, %{state | receive_select: select_info}}

      {:error, :closed} ->
        {:stop, :normal, state}

      {:error, _reason} ->
        Logger.debug("loopex daemon socket receive failed")
        {:stop, :normal, state}
    end
  end

  defp consume_bytes(%{discarding_oversize: true} = state, bytes) do
    case :binary.match(bytes, "\n") do
      :nomatch ->
        {:ok, state}

      {offset, 1} ->
        rest_offset = offset + 1
        rest = binary_part(bytes, rest_offset, byte_size(bytes) - rest_offset)
        consume_data(%{state | discarding_oversize: false}, rest)
    end
  end

  defp consume_bytes(state, bytes), do: consume_data(state, state.input_buffer <> bytes)

  defp consume_data(state, data) do
    parts = :binary.split(data, "\n", [:global])
    {payloads, [partial]} = Enum.split(parts, -1)
    state = %{state | input_buffer: ""}

    case Enum.reduce_while(payloads, {:ok, state}, fn payload, {:ok, acc} ->
           case handle_payload(acc, payload) do
             {:ok, next} -> {:cont, {:ok, next}}
             {:stop, next} -> {:halt, {:stop, next}}
           end
         end) do
      {:stop, state} ->
        {:stop, state}

      {:ok, state} ->
        retain_partial(state, partial)
    end
  end

  defp retain_partial(state, partial) do
    if byte_size(partial) > frame_ceiling(state.protocol) do
      case send_record(state, invalid_frame(:frame_too_large)) do
        :ok ->
          Logger.debug("loopex daemon protocol frame refused")
          {:ok, %{state | input_buffer: "", discarding_oversize: true}}

        {:error, _reason} ->
          {:stop, state}
      end
    else
      {:ok, %{state | input_buffer: partial}}
    end
  end

  defp handle_payload(state, payload) do
    case Frame.decode(payload, frame_ceiling(state.protocol)) do
      {:ok, request} ->
        handle_request(state, request)

      {:error, reason} ->
        case send_record(state, invalid_frame(reason)) do
          :ok ->
            Logger.debug("loopex daemon protocol frame refused")
            {:ok, state}

          {:error, _send_reason} ->
            {:stop, state}
        end
    end
  end

  defp handle_request(state, request) do
    case ConnectionProtocol.handle(state.protocol, request) do
      {:request, parsed, protocol} ->
        serve(%{state | protocol: protocol}, parsed)

      {_kind, record, protocol, :none} ->
        case send_record(state, record) do
          :ok -> {:ok, %{state | protocol: protocol}}
          {:error, _reason} -> {:stop, state}
        end

      {:ok, record, protocol, :initialized} ->
        case ConnectionRegistry.initialize_complete(
               state.registry,
               state.rollback_token,
               state.incarnation
             ) do
          :ok ->
            with :ok <- register_relay(state),
                 :ok <- send_record(state, record) do
              Logger.debug("loopex daemon socket connection initialized")
              {:ok, %{state | protocol: protocol, phase: :initialized}}
            else
              {:error, _reason} -> {:stop, state}
            end

          {:error, _reason} ->
            {:stop, state}
        end
    end
  end

  defp register_relay(%{context: nil}), do: :ok

  defp register_relay(%{context: %{relay: relay}} = state) do
    case AdmissionRelay.register_connection(relay, state.incarnation, state.registry) do
      :ok ->
        :ok

      {:error, _reason} ->
        Logger.debug("loopex daemon socket connection relay registration refused")
        {:error, :relay_registration_refused}
    end
  end

  # Concept: a request is served only by a connection composed with the daemon
  # context, and only for the methods this build answers.
  defp serve(%{context: nil} = state, request),
    do: reply(state, WireRecords.request_error(request.request_id, "unsupported_method"))

  defp serve(state, %Request{operation: :session_acquire_control} = request) do
    session_id = request.fields.session_id

    case RequestLedger.reserve(
           state.ledger,
           session_id,
           request.request_id,
           {request.operation, request.fields}
         ) do
      :coalesced ->
        {:ok, state}

      {:error, :session_conflict} ->
        reply(state, WireRecords.invalid_request(request.request_id, "session_conflict"))

      {:ok, reserved} ->
        runtime = state.context.runtime

        begin_worker(state, reserved, request, fn ->
          Loopex.Runtime.session_existence(runtime, session_id)
        end)
    end
  end

  defp serve(state, %Request{operation: :session_release_control} = request) do
    case RequestLedger.admit_session(state.ledger, request.fields.session_id) do
      :ok ->
        begin_worker(state, state.ledger, request, fn -> :ok end)

      {:error, :session_conflict} ->
        reply(state, WireRecords.invalid_request(request.request_id, "session_conflict"))
    end
  end

  # Concept: a create is ticketed so the admission cut accounts for it, and
  # its read-only history lookup decides whether it may spend an activation.
  #
  # Technical depth: the ticket exists before the worker is bound, and the
  # worker's lookup precedes the registry's activation decision, so an exact
  # historical replay is answered even at the activation ceiling.
  defp serve(state, %Request{operation: :session_create} = request) do
    %{command_id: command_id, session_options: options} = request.fields
    runtime = state.context.runtime

    entry = %{
      operation: :session_create,
      fields: request.fields,
      worker: nil,
      worker_monitor: nil,
      worker_incarnation: nil
    }

    case RequestLedger.begin(state.ledger, request.request_id, entry) do
      {:ok, origin, ledger} ->
        case AdmissionRelay.open_ticket(state.context.relay, origin, :session_create) do
          {:ok, ^origin} ->
            state = %{state | ledger: ledger}

            {worker, monitor, incarnation} =
              RequestWorker.start(origin, fn ->
                Loopex.Runtime.lookup_create_result(runtime, command_id, options)
              end)

            ledger =
              RequestLedger.update(state.ledger, origin, fn entry ->
                %{
                  entry
                  | worker: worker,
                    worker_monitor: monitor,
                    worker_incarnation: incarnation
                }
              end)

            state = %{state | ledger: ledger, workers: Map.put(state.workers, monitor, origin)}

            case AdmissionRelay.bind_ticket_worker(
                   state.context.relay,
                   origin,
                   worker,
                   incarnation
                 ) do
              :ok ->
                {:ok, state}

              {:error, reason} ->
                {:noreply, state} = settle_locally(state, origin, ticket_refusal(reason))
                {:ok, state}
            end

          {:error, reason} ->
            reply(state, WireRecords.request_error(request.request_id, ticket_refusal(reason)))
        end

      {:error, :duplicate_request} ->
        reply(state, WireRecords.invalid_request(request.request_id, "duplicate_request"))

      {:error, :capacity_exceeded} ->
        reply(state, WireRecords.request_error(request.request_id, "capacity_exceeded"))
    end
  end

  defp serve(state, request),
    do: reply(state, WireRecords.request_error(request.request_id, "unsupported_method"))

  defp ticket_refusal(:daemon_stopping), do: "daemon_stopping"
  defp ticket_refusal(:capacity_exceeded), do: "capacity_exceeded"
  defp ticket_refusal(_reason), do: "internal_failure"

  # Concept: the request identity and the in-flight ceiling are checked before
  # any worker starts, and a refused request leaves no reservation behind.
  defp begin_worker(state, ledger, request, fun) do
    entry = %{
      operation: request.operation,
      fields: request.fields,
      worker: nil,
      worker_monitor: nil,
      worker_incarnation: nil
    }

    case RequestLedger.begin(ledger, request.request_id, entry) do
      {:ok, origin, ledger} ->
        {worker, monitor, incarnation} = RequestWorker.start(origin, fun)

        ledger =
          RequestLedger.update(ledger, origin, fn entry ->
            %{
              entry
              | worker: worker,
                worker_monitor: monitor,
                worker_incarnation: incarnation
            }
          end)

        {:ok, %{state | ledger: ledger, workers: Map.put(state.workers, monitor, origin)}}

      {:error, :duplicate_request} ->
        reply(state, WireRecords.invalid_request(request.request_id, "duplicate_request"))

      {:error, :capacity_exceeded} ->
        reply(state, WireRecords.request_error(request.request_id, "capacity_exceeded"))
    end
  end

  defp continue_worker(state, origin, incarnation, result) do
    case RequestLedger.fetch(state.ledger, origin) do
      {:ok, %{worker_incarnation: ^incarnation, worker_monitor: monitor} = entry}
      when is_reference(monitor) ->
        dispatch_prepared(state, origin, entry, result)

      _other ->
        {:noreply, state}
    end
  end

  defp dispatch_prepared(state, origin, %{operation: :session_acquire_control} = entry, result) do
    case result do
      {:ok, :present} ->
        state
        |> hand_to_relay(origin, entry, fn ->
          Owner.acquire_control(
            state.context.owner,
            origin,
            entry.request_id,
            entry.fields.session_id,
            self(),
            state.incarnation,
            entry.worker,
            entry.worker_incarnation,
            request_deadline()
          )
        end)

      {:ok, :absent} ->
        settle_locally(state, origin, "session_unknown")

      {:ok, :store_unavailable} ->
        settle_locally(state, origin, "store_unavailable")

      {:ok, :invalid_id} ->
        settle_locally(state, origin, "internal_failure")

      {:error, :runtime_unavailable} ->
        report_fatal(state, :runtime_lost)
        settle_locally(state, origin, "internal_failure")
    end
  end

  defp dispatch_prepared(state, origin, %{operation: :session_release_control} = entry, :ok) do
    hand_to_relay(state, origin, entry, fn ->
      Owner.release_control(
        state.context.owner,
        origin,
        entry.request_id,
        entry.fields.session_id,
        self(),
        state.incarnation,
        entry.worker,
        entry.worker_incarnation,
        entry.fields.writer_epoch,
        request_deadline()
      )
    end)
  end

  defp dispatch_prepared(state, origin, %{operation: :session_create} = entry, lookup) do
    %{command_id: command_id, session_options: options} = entry.fields
    request_id = entry.request_id

    {mode, task} =
      case lookup do
        {:ok, {:historical, session_id}} ->
          record = create_admission(request_id, command_id, :accepted, session_id)
          {:historical, fn -> {:no_activation, nil, record} end}

        {:ok, :absent} ->
          {:fresh, create_task(state.context, request_id, command_id, options)}

        {:ok, :conflict} ->
          record = create_admission(request_id, command_id, {:refused, :runtime_command_conflict})
          {:historical, fn -> {:no_activation, nil, record} end}

        {:ok, :store_unavailable} ->
          record = WireRecords.request_error(request_id, "store_unavailable")
          {:historical, fn -> {:no_activation, nil, record} end}

        {:error, :runtime_unavailable} ->
          report_fatal(state, :runtime_lost)
          record = WireRecords.request_error(request_id, "internal_failure")
          {:historical, fn -> {:no_activation, nil, record} end}

        _unexpected ->
          record = WireRecords.request_error(request_id, "internal_failure")
          {:historical, fn -> {:no_activation, nil, record} end}
      end

    ceiling = WireRecords.request_error(request_id, "activation_ceiling_reached")
    conflict = create_admission(request_id, command_id, {:refused, :runtime_command_conflict})

    case safe_call(fn ->
           ConnectionRegistry.promote_create(
             state.registry,
             origin,
             command_id,
             options_digest(options),
             mode,
             ceiling,
             conflict,
             task
           )
         end) do
      {:ok, _promotion} ->
        {:noreply, relay_owns_worker(state, origin, entry)}

      {:error, reason} ->
        settle_locally(state, origin, ticket_refusal(reason))
    end
  end

  # Concept: the relay task, not the connection, makes the activating call,
  # and it classifies exactly what core started.
  defp create_task(context, request_id, command_id, options) do
    runtime = context.runtime
    fatal_recipient = Map.get(context, :fatal_recipient)

    fn ->
      case Loopex.Runtime.create_session_detailed(runtime, command_id, options) do
        {:ok, %{session_id: session_id, disposition: disposition}} ->
          {disposition, session_id,
           create_admission(request_id, command_id, :accepted, session_id)}

        {:error, :runtime_unavailable} ->
          if is_pid(fatal_recipient),
            do: send(fatal_recipient, {:daemon_component_fatal, self(), :runtime_lost})

          {:no_activation, nil, WireRecords.request_error(request_id, "internal_failure")}

        {:error, reason, %{disposition: disposition}} ->
          {disposition, nil, create_admission(request_id, command_id, {:refused, reason})}

        _unexpected ->
          {:no_activation, nil, WireRecords.request_error(request_id, "internal_failure")}
      end
    end
  end

  defp create_admission(request_id, command_id, :accepted, session_id),
    do: WireRecords.admission(request_id, "session.create", command_id, :accepted, session_id)

  defp create_admission(request_id, command_id, {:refused, reason}) do
    word =
      if is_atom(reason) and not is_nil(reason),
        do: Atom.to_string(reason),
        else: "internal_failure"

    WireRecords.admission(request_id, "session.create", command_id, {:refused, word})
  end

  defp options_digest(options),
    do: options |> LoopexProtocol.Canonical.digest() |> Base.decode16!(case: :lower)

  # Concept: promotion retires the waiting worker; the relay reaps it, so its
  # exit is not this request's failure.
  defp relay_owns_worker(state, origin, entry) do
    Process.demonitor(entry.worker_monitor, [:flush])
    ledger = RequestLedger.update(state.ledger, origin, &%{&1 | worker_monitor: nil})
    %{state | ledger: ledger, workers: Map.delete(state.workers, entry.worker_monitor)}
  end

  # Concept: once the daemon owner accepts a lease operation, the relay owns
  # the worker's accounting and delivers the one answer.
  #
  # Technical depth: the connection stops monitoring the worker so the
  # worker's normal exit after `go` is not mistaken for its loss. A refused
  # hand-off kills the worker and settles the request here.
  defp hand_to_relay(state, origin, entry, call) do
    case safe_call(call) do
      {:ok, _disposition, _actor, _actor_incarnation} ->
        {:noreply, relay_owns_worker(state, origin, entry)}

      {:error, reason} ->
        settle_locally(state, origin, lease_refusal(reason))
    end
  end

  defp lease_refusal(:daemon_stopping), do: "daemon_stopping"
  defp lease_refusal(:control_capacity_reached), do: "control_capacity_reached"
  defp lease_refusal(:owner_unavailable), do: "control_pending"
  defp lease_refusal(:capacity_exceeded), do: "capacity_exceeded"
  defp lease_refusal(_reason), do: "internal_failure"

  defp safe_call(call) do
    call.()
  catch
    :exit, _reason -> {:error, :owner_unavailable}
  end

  defp settle_locally(state, origin, code) do
    {entry, ledger} = RequestLedger.complete(state.ledger, origin)
    state = %{state | ledger: ledger}

    state =
      case entry do
        %{worker_monitor: monitor, worker: worker} when is_reference(monitor) ->
          Process.demonitor(monitor, [:flush])
          Process.exit(worker, :kill)
          %{state | workers: Map.delete(state.workers, monitor)}

        _other ->
          state
      end

    state = release_reservation(state, entry)
    noreply_record(state, WireRecords.request_error(entry.request_id, code))
  end

  defp worker_lost(state, monitor) do
    {origin, workers} = Map.pop(state.workers, monitor)
    state = %{state | workers: workers}

    case RequestLedger.fetch(state.ledger, origin) do
      {:ok, entry} ->
        {_entry, ledger} = RequestLedger.complete(state.ledger, origin)
        state = release_reservation(%{state | ledger: ledger}, entry)
        Logger.debug("loopex daemon request worker lost")
        noreply_record(state, WireRecords.request_error(entry.request_id, "internal_failure"))

      :error ->
        {:noreply, state}
    end
  end

  defp render_result(state, origin, record) do
    case RequestLedger.complete(state.ledger, origin) do
      {nil, _ledger} ->
        {:noreply, state}

      {entry, ledger} ->
        state = %{state | ledger: ledger}

        state =
          if record["type"] == "result",
            do: bind_session(state, entry),
            else: release_reservation(state, entry)

        noreply_record(state, record)
    end
  end

  defp render_refusal(state, origin, code) do
    case RequestLedger.complete(state.ledger, origin) do
      {nil, _ledger} ->
        {:noreply, state}

      {entry, ledger} ->
        state = release_reservation(%{state | ledger: ledger}, entry)
        noreply_record(state, WireRecords.request_error(entry.request_id, code))
    end
  end

  defp bind_session(state, %{operation: :session_acquire_control} = entry) do
    ledger = RequestLedger.bind(state.ledger, entry.fields.session_id, entry.request_id)
    %{state | ledger: ledger}
  end

  defp bind_session(state, _entry), do: state

  defp release_reservation(state, %{request_id: request_id}),
    do: %{state | ledger: RequestLedger.clear_reservation(state.ledger, request_id)}

  defp release_reservation(state, nil), do: state

  # Concept: the holder of a lost session owner learns it once and is closed.
  #
  # Technical depth: the record is queued before reading stops; a bounded
  # timer caps the flush so a stalled peer cannot hold the daemon owner past
  # its mirror deadline. The acknowledgement follows the close.
  defp begin_owner_loss_close(state, owner, close_ref, session_id) do
    record = WireRecords.owner_lost_close(session_id, nil)
    Process.send_after(self(), {:owner_loss_close_deadline, close_ref}, @owner_loss_close_ms)
    state = %{state | closing: %{owner: owner, close_ref: close_ref}}
    Logger.debug("loopex daemon holder close for lost owner")

    case send_record(state, record) do
      :ok -> {:noreply, state}
      {:error, _reason} -> finish_owner_loss_close(state)
    end
  end

  defp finish_owner_loss_close(%{closing: %{owner: owner, close_ref: close_ref}} = state) do
    if state.socket, do: :socket.close(state.socket)
    Owner.owner_loss_connection_closed(owner, close_ref, state.incarnation)
    Logger.debug("loopex daemon holder close acknowledged")
    {:stop, :normal, %{state | socket: nil}}
  end

  defp report_fatal(%{context: %{fatal_recipient: recipient}}, class) when is_pid(recipient) do
    send(recipient, {:daemon_component_fatal, self(), class})
    :ok
  end

  defp report_fatal(_state, _class), do: :ok

  defp request_deadline,
    do: System.monotonic_time(:millisecond) + Map.fetch!(V2.limits(), "reply_wait_ms")

  defp reply(state, record) do
    case send_record(state, record) do
      :ok -> {:ok, state}
      {:error, _reason} -> {:stop, state}
    end
  end

  defp noreply_record(state, record) do
    case send_record(state, record) do
      :ok -> {:noreply, state}
      {:error, _reason} -> {:stop, :normal, state}
    end
  end

  defp send_record(state, record) do
    with {:ok, encoded} <- Frame.encode(record),
         :ok <- ConnectionRegistry.enqueue_output(state.registry, state.incarnation, encoded) do
      :ok
    else
      _other ->
        Logger.debug("loopex daemon socket output enqueue failed")
        {:error, :send_failed}
    end
  end

  defp output_step(%{output_claim: nil} = state) do
    case ConnectionRegistry.claim_output(state.registry, state.incarnation) do
      {:ok, frame_ref, bytes} ->
        state
        |> Map.put(:output_claim, %{frame_ref: frame_ref, remaining: bytes})
        |> attempt_output(nil)
        |> output_result()

      :empty ->
        if state.closing, do: finish_owner_loss_close(state), else: {:noreply, state}

      {:error, _reason} ->
        {:stop, :normal, state}
    end
  end

  defp output_step(%{send_select: nil} = state) do
    state
    |> attempt_output(nil)
    |> output_result()
  end

  defp output_step(state), do: {:noreply, state}

  defp attempt_output(%{output_claim: %{remaining: bytes}} = state, continuation) do
    result =
      if is_nil(continuation),
        do: :socket.send(state.socket, bytes, [], :nowait),
        else: :socket.send(state.socket, bytes, continuation, :nowait)

    case result do
      :ok ->
        complete_output(state)

      {:ok, rest} when is_binary(rest) and byte_size(rest) > 0 ->
        send(self(), :flush_output)
        {:ok, put_in(state, [:output_claim, :remaining], rest)}

      {:select, {select_info, rest}} when is_binary(rest) and byte_size(rest) > 0 ->
        {:ok,
         state
         |> Map.put(:send_select, select_info)
         |> put_in([:output_claim, :remaining], rest)}

      {:select, select_info} ->
        {:ok, %{state | send_select: select_info}}

      {:error, _reason} ->
        Logger.debug("loopex daemon socket send failed")
        {:stop, state}

      _other ->
        Logger.debug("loopex daemon socket send returned an unsupported disposition")
        {:stop, state}
    end
  end

  defp complete_output(%{output_claim: %{frame_ref: frame_ref}} = state) do
    case ConnectionRegistry.output_emitted(state.registry, state.incarnation, frame_ref) do
      :ok ->
        send(self(), :flush_output)
        {:ok, %{state | output_claim: nil, send_select: nil}}

      {:error, _reason} ->
        {:stop, state}
    end
  end

  defp output_result({:ok, state}), do: {:noreply, state}
  defp output_result({:stop, state}), do: {:stop, :normal, state}

  defp frame_ceiling(protocol) do
    limits = V2.limits()

    if ConnectionProtocol.initialized?(protocol),
      do: limits["frame_bytes"],
      else: limits["frame_bytes_before_initialization"]
  end

  defp invalid_frame(reason) do
    %{
      "type" => "error",
      "code" => "invalid_frame",
      "message" => frame_reason(reason)
    }
  end

  defp frame_reason(:frame_too_large), do: "the frame exceeds the ceiling in force"
  defp frame_reason(:invalid_utf8), do: "the frame is not valid UTF-8"
  defp frame_reason(:not_an_object), do: "a frame must be one JSON object"
  defp frame_reason(:trailing_bytes), do: "a frame carries bytes after its object"
  defp frame_reason(:truncated), do: "the frame ended early"
  defp frame_reason(:duplicate_member), do: "the frame repeats a member name"
  defp frame_reason(:depth_exceeded), do: "the frame nests beyond the admitted depth"
  defp frame_reason(:too_many_members), do: "a collection in the frame is too large"
  defp frame_reason(:string_too_large), do: "a string in the frame is too large"
  defp frame_reason(:integer_out_of_range), do: "an integer is outside the admitted range"
  defp frame_reason(:number_not_an_integer), do: "a number is not an integer"
  defp frame_reason(_reason), do: "the frame is malformed"
end
