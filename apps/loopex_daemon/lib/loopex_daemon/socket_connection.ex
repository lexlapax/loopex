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

  Every exchange with the registry and the relay is a request message whose
  answer arrives in `handle_info/2`: the connection never waits inside a
  handler, so a stalled registry cannot keep it from an owner-loss close, a
  holder close, a relay record or EOF. The registry applies one connection's
  requests in the order they were sent, so output keeps its order and every
  enqueue still meets the output buffer's bounds and the succession reserve
  at the same point in that order. A registry exit while any request is
  outstanding stops the connection as `registry_lost`. Every registry request
  the registry answers by itself has a five-second instant: one still
  unanswered then is reported to the daemon owner, which names the registry
  `connections_lost` while serving.

  After initialization a connection composed with a daemon context registers
  its incarnation with the admission relay and serves requests through a
  `LoopexDaemon.RequestLedger`: every admitted request occupies one sequenced
  relay origin until exactly one answer is rendered. Blocking work runs in a
  monitored `LoopexDaemon.RequestWorker`; the relay, the daemon owner and the
  lease owners deliver results, cancellations and failures back to this
  process, which renders each as one correlated record. A request's relay
  open and bind and a create's or attach's registry promotion are request
  messages the connection never awaits inside a handler: each relay request
  has its own five-second instant, reported once to the daemon owner when
  unanswered, and a promotion carries no connection deadline because the
  registry's own relay instants bound it. When the daemon owner
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
    LeaseOwner,
    Owner,
    Request,
    RequestLedger,
    RequestWorker,
    WireRecords
  }

  alias LoopexProtocol.{Frame, Session.V2, Wire}

  @owner_loss_close_ms 1_000

  # Concept: each relay request this connection sends at a request's start has
  # its own five-second instant; the instant only prompts one report to the
  # daemon owner and never abandons the request.
  @relay_request_ms 5_000

  # Concept: each registry request this connection sends, other than a
  # create or attach promotion, has its own five-second instant; at it the connection reports the registry to the
  # daemon owner, which names it `connections_lost` while serving. The
  # request stays pending and the daemon's fail-stop ends it.
  @registry_request_ms 5_000

  @mutation_operations [
    :session_prompt,
    :session_steer,
    :session_follow_up,
    :session_abort,
    :session_respond_interaction,
    :session_admit_resources,
    :session_activate_skill
  ]

  @lease_ticket_operations [:session_resume | @mutation_operations]

  @session_queries [:session_inspect, :resources_catalog, :resources_read]

  @transfer_operations [
    :artifact_open_transfer,
    :artifact_read_chunk,
    :artifact_close_transfer
  ]

  # A permit's worker exits normally once it has completed its permit, which
  # it can do only after the relay's `go`; a ticket's worker never exits
  # normally before its ticket is bound and promoted.
  @permit_operations @session_queries ++ @transfer_operations ++ [:session_list, :daemon_status]

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options), do: GenServer.start_link(__MODULE__, options)

  @doc false
  @spec activate(pid(), :socket.socket()) :: :ok
  def activate(connection, socket), do: GenServer.cast(connection, {:activate, socket})

  @progress_records 32
  @progress_bytes 524_288

  # Concept: reading pauses while this many output enqueues are unanswered, so
  # a stalled registry cannot accumulate unbounded requests from one client;
  # below it the connection keeps reading and sees EOF.
  #
  # Technical depth: ADR 0023's durable writer holds at most 64 records. The
  # bound is checked before each receive, so one received batch may exceed
  # it by the frames that batch holds.
  @pending_output_limit 64

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
      enqueue_seq: 0,
      enqueues_pending: 0,
      input_paused: false,
      finishing_succession: false,
      deferred_stop: nil,
      context: Keyword.get(options, :context),
      ledger: RequestLedger.new(Keyword.fetch!(options, :connection_incarnation)),
      workers: %{},
      closing: nil,
      attachment: nil,
      output_cursors: :queue.new(),
      progress: :queue.new(),
      progress_bytes: 0,
      succession: nil,
      last_activity: System.monotonic_time(:millisecond),
      lease_expires_at: nil,
      calls: :gen_server.reqids_new(),
      exchanges: %{}
    }

    Logger.debug("loopex daemon socket connection waiting")

    {:ok,
     %{
       state
       | registry_monitor: Process.monitor(state.registry),
         listener_monitor: Process.monitor(state.listener)
     }}
  end

  # Concept: the slot promotion is a registry request; while it is answered
  # the connection is `:promoting` and owns the socket, so an abort or a
  # registry loss still closes it.
  #
  # Technical depth: a listener exit while promoting is left to the registry,
  # which decides the promotion; only the `:waiting` phase takes it as a
  # pre-promotion loss.
  @impl true
  def handle_cast({:activate, socket}, %{phase: :waiting} = state) do
    if socket_owner?(socket, self()) do
      request =
        ConnectionRegistry.connection_request(
          state.registry,
          {:promote, state.rollback_token, state.incarnation}
        )

      state = %{state | phase: :promoting, socket: socket}
      {:noreply, await_exchange(state, request, :registry, {:slot_promotion})}
    else
      {:stop, :socket_owner_unverified, state}
    end
  end

  def handle_cast({:activate, socket}, state) do
    if socket_owner?(socket, self()), do: :socket.close(socket)
    {:noreply, state}
  end

  # Concept: a connection whose buffered output the registry reclaimed under
  # aggregate pressure is an eviction like overflow or idleness: an attached
  # client is told `detached` at its last completely emitted cursor, best
  # effort, and then closed.
  #
  # Technical depth: the registry has already emptied this row and released its
  # charge; the record is one ordinary bounded write and the close is bounded
  # by `begin_final_close/2`'s deadline whether or not the write is admitted.
  @impl true
  def handle_info(
        {:connection_abort, token, :output_reclaimed},
        %{rollback_token: token, closing: nil, attachment: attached} = state
      )
      when attached != nil do
    Logger.debug("loopex daemon attachment detached by output reclamation")
    begin_detach_close(state)
  end

  def handle_info({:connection_abort, token, _reason}, %{rollback_token: token} = state),
    do: {:stop, :normal, state}

  def handle_info(:receive_next, %{phase: phase, receive_select: nil, closing: nil} = state)
      when phase in [:live, :initialized],
      do: arm_receive(state)

  def handle_info({:output_ready, incarnation}, %{incarnation: incarnation} = state),
    do: output_step(state)

  def handle_info(:flush_output, state), do: output_step(state)

  # Concept: progress is decoration: it waits behind durable output in a small
  # bounded queue and is dropped, oldest first, rather than ever delaying an
  # event.
  #
  # Technical depth: at most 32 records and 512 KiB of encoded progress wait,
  # ADR 0023's transient bound. The queue is written only when this
  # connection's durable output is empty.
  def handle_info(
        {:daemon_progress, session_id, item},
        %{attachment: %{session_id: session_id}} = state
      ) do
    case Frame.encode(WireRecords.progress(session_id, item)) do
      {:ok, encoded} ->
        state
        |> queue_progress(IO.iodata_to_binary(encoded))
        |> flush_progress()

      _unencodable ->
        {:noreply, state}
    end
  end

  def handle_info({:daemon_progress, _session_id, _item}, state), do: {:noreply, state}

  def handle_info(
        {:"$socket", socket, :select, handle},
        %{
          phase: phase,
          socket: socket,
          receive_select: {:select_info, _receive_tag, handle}
        } = state
      )
      when phase in [:live, :initialized] do
    state = Map.put(state, :receive_select, nil)
    if state.closing, do: {:noreply, state}, else: arm_receive(state)
  end

  def handle_info(
        {:"$socket", socket, :abort, {handle, _reason}},
        %{socket: socket, receive_select: {:select_info, _receive_tag, handle}} = state
      ),
      do: {:stop, :normal, %{state | receive_select: nil}}

  # Concept: a send the kernel could only partly accept resumes when the
  # socket is writable again.
  #
  # Technical depth: the select tag's shape differs across OTP releases —
  # `:send` on some, `{:send, continuation_data}` on others — so the
  # notification is matched by its unique handle alone. Matching the atom
  # left every frame larger than the kernel buffer stalled after its first
  # partial write.
  def handle_info(
        {:"$socket", socket, :select, handle},
        %{
          socket: socket,
          send_select: {:select_info, _send_tag, handle} = continuation,
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
        %{socket: socket, send_select: {:select_info, _send_tag, handle}} = state
      ) do
    Logger.debug("loopex daemon socket send aborted")
    {:stop, :normal, %{state | send_select: nil}}
  end

  # Concept: the relay's and the registry's answers to this connection's
  # requests arrive as messages, so a slow relay or registry never stops the
  # connection from serving its socket, delivering results or closing.
  def handle_info({[:alias | request], _reply} = message, state)
      when is_map_key(state.exchanges, request),
      do: exchange_answered(state, request, message)

  def handle_info({:DOWN, request, :process, _server, _reason} = message, state)
      when is_map_key(state.exchanges, request),
      do: exchange_answered(state, request, message)

  # Concept: a relay request still unanswered at its instant is reported once
  # to the daemon owner, which names the relay lost while serving; the
  # request stays pending and the daemon's fail-stop ends it.
  def handle_info({:relay_request_unanswered, request}, state)
      when is_map_key(state.exchanges, request) do
    send(state.context.owner, {:connection_relay_unanswered, self(), state.incarnation})
    Logger.debug("loopex daemon connection relay request unanswered")
    {:noreply, put_in(state, [:exchanges, request, :timer], nil)}
  end

  def handle_info({:relay_request_unanswered, _request}, state), do: {:noreply, state}

  # Concept: a registry request still unanswered at its instant is reported
  # to the daemon owner; the owner latches `connections_lost` once while
  # serving and treats every report after the admission cut as cleanup.
  #
  # Technical depth: a connection composed without a daemon context has no
  # owner to tell; its request simply stays pending.
  def handle_info({:registry_request_unanswered, request}, state)
      when is_map_key(state.exchanges, request) do
    case state.context do
      %{owner: owner} when is_pid(owner) ->
        report = {:connection_registry_unanswered, self(), state.incarnation, state.registry}
        send(owner, report)
        Logger.debug("loopex daemon connection registry request unanswered")

      _uncomposed ->
        :ok
    end

    {:noreply, put_in(state, [:exchanges, request, :timer], nil)}
  end

  def handle_info({:registry_request_unanswered, _request}, state), do: {:noreply, state}

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

  # Concept: a stop that reaches a connection still completing its
  # initialization follows the initialization reply, exactly as it would had
  # initialization been one step.
  def handle_info({:daemon_stopping, record}, %{phase: :initializing, deferred_stop: nil} = state)
      when is_map(record),
      do: {:noreply, %{state | deferred_stop: record}}

  def handle_info({:daemon_stopping, record}, %{closing: nil} = state) when is_map(record),
    do: begin_final_close(stop_pump(state), record)

  # Concept: a non-prepared owner succession invalidates this connection's
  # attachment, not the connection: the client is told `detached` at its last
  # emitted cursor through the reserved notice slot, the attachment is
  # cleared, and the connection stays open for the client to reattach.
  #
  # Technical depth: every other record this connection would write while the
  # notice is pending is held in order and written after the notice, when the
  # succession is finished and its reserve released. The notice is a registry
  # request: records produced before its answer are already held, and only
  # its acceptance sends the attachment invalidation. A refused notice closes
  # the connection with the `detached` record, then writes the held records.
  def handle_info(
        {:loopex_attachment_invalidated, session_id, attachment_id, _incarnation, _cursor},
        %{
          attachment: %{session_id: session_id, attachment_id: attachment_id} = attached,
          closing: nil
        } = state
      ) do
    state = stop_pump(state)
    cursor = attached.emitted_cursor || attached.snapshot_cursor

    case Frame.encode(WireRecords.detached(session_id, cursor)) do
      {:ok, encoded} ->
        request =
          ConnectionRegistry.connection_request(
            state.registry,
            {:enqueue_succession_notice, state.incarnation, IO.iodata_to_binary(encoded)}
          )

        state = %{
          state
          | attachment: nil,
            progress: :queue.new(),
            progress_bytes: 0,
            succession: :queue.new()
        }

        notice = {:notice, session_id, attachment_id, cursor}
        {:noreply, track_enqueue(state, request, nil, notice)}

      _unencodable ->
        begin_final_close(state, WireRecords.detached(session_id, cursor))
    end
  end

  def handle_info(
        {:loopex_attachment_invalidated, _session, _attachment, _incarnation, _cursor},
        state
      ),
      do: {:noreply, state}

  # Concept: an attached client that has been idle for the residency limit is
  # evicted like any other daemon eviction, with a record and a close; a
  # client holding a controller lease is exempt until release or expiry, and
  # eviction never touches a coordinator.
  def handle_info(:idle_check, %{closing: nil, attachment: attached} = state)
      when attached != nil do
    now = System.monotonic_time(:millisecond)
    holding = state.lease_expires_at != nil and now < state.lease_expires_at
    idle_ms = idle_eviction_ms(state)

    if not holding and now - state.last_activity >= idle_ms do
      Logger.debug("loopex daemon idle attachment evicted")
      begin_detach_close(state)
    else
      schedule_idle_check(state)
      {:noreply, state}
    end
  end

  def handle_info(:idle_check, %{closing: nil} = state) do
    schedule_idle_check(state)
    {:noreply, state}
  end

  def handle_info(:idle_check, state), do: {:noreply, state}

  def handle_info({:daemon_notice, record}, %{closing: nil} = state),
    do: noreply_record(state, record)

  def handle_info({:daemon_attachment, origin, attachment}, state) do
    ledger = RequestLedger.update(state.ledger, origin, &Map.put(&1, :attachment, attachment))
    {:noreply, %{state | ledger: ledger}}
  end

  def handle_info(
        {:attachment_event, pump, event},
        %{attachment: %{pump: pump}, closing: nil} = state
      ),
      do: deliver_event(state, event)

  # Concept: while a requested replacement is pending, the replaced
  # attachment's pump ending is the replacement taking effect; it is noted, and
  # the connection neither tells the client `detached` nor closes.
  def handle_info(
        {:attachment_disconnected, pump, _cursor},
        %{attachment: %{pump: pump, replacing: _replacement}, closing: nil} = state
      ),
      do: {:noreply, replaced_pump_ended(state)}

  def handle_info(
        {:attachment_failed, pump},
        %{attachment: %{pump: pump, replacing: _replacement}, closing: nil} = state
      ),
      do: {:noreply, replaced_pump_ended(state)}

  def handle_info(
        {:DOWN, monitor, :process, pump, _reason},
        %{attachment: %{pump: pump, pump_monitor: monitor, replacing: _replacement}, closing: nil} =
          state
      ),
      do: {:noreply, replaced_pump_ended(state)}

  def handle_info(
        {:attachment_disconnected, pump, _cursor},
        %{attachment: %{pump: pump}, closing: nil} = state
      ),
      do: begin_detach_close(state)

  def handle_info({:attachment_failed, pump}, %{attachment: %{pump: pump}, closing: nil} = state),
    do: begin_detach_close(state)

  def handle_info(
        {:DOWN, monitor, :process, pump, _reason},
        %{attachment: %{pump: pump, pump_monitor: monitor}, closing: nil} = state
      ),
      do: begin_detach_close(state)

  def handle_info(
        {:DOWN, monitor, :process, registry, _reason},
        %{registry: registry, registry_monitor: monitor} = state
      ),
      do: {:stop, :registry_lost, state}

  def handle_info({:DOWN, monitor, :process, _worker, reason}, state)
      when is_map_key(state.workers, monitor),
      do: worker_lost(state, monitor, reason)

  def handle_info(
        {:DOWN, monitor, :process, listener, _reason},
        %{phase: :waiting, listener: listener, listener_monitor: monitor} = state
      ),
      do: {:stop, :normal, state}

  def handle_info(message, state), do: collect_descriptor_reply(state, message)

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

  defp arm_receive(%{enqueues_pending: pending} = state)
       when pending >= @pending_output_limit,
       do: {:noreply, %{state | input_paused: true}}

  defp arm_receive(state) do
    case :socket.recv(state.socket, 0, :nowait) do
      {:ok, bytes} when is_binary(bytes) and byte_size(bytes) > 0 ->
        state |> consume_bytes(bytes) |> input_result()

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

  defp input_result({:ok, state}) do
    send(self(), :receive_next)
    {:noreply, state}
  end

  defp input_result({:pause, state}), do: {:noreply, state}
  defp input_result({:stop, state}), do: {:stop, :normal, state}

  # Concept: reading resumes once the unanswered output enqueues fall below
  # their bound again.
  defp resume_input(%{input_paused: true, enqueues_pending: pending} = state)
       when pending < @pending_output_limit do
    send(self(), :receive_next)
    %{state | input_paused: false}
  end

  defp resume_input(state), do: state

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
    consume_payloads(%{state | input_buffer: ""}, payloads, partial)
  end

  # Concept: frames after an `initialize` wait, unparsed and in wire order,
  # until the registry and the relay have answered that initialization.
  defp consume_payloads(state, [], partial), do: retain_partial(state, partial)

  defp consume_payloads(state, [payload | rest], partial) do
    case handle_payload(state, payload) do
      {:ok, state} -> consume_payloads(state, rest, partial)
      {:stop, state} -> {:stop, state}
      {:pause, state} -> {:pause, %{state | input_buffer: Enum.join(rest ++ [partial], "\n")}}
    end
  end

  defp retain_partial(state, partial) do
    if byte_size(partial) > frame_ceiling(state.protocol) do
      case send_record(state, invalid_frame(:frame_too_large)) do
        {:ok, state} ->
          Logger.debug("loopex daemon protocol frame refused")
          {:ok, %{state | input_buffer: "", discarding_oversize: true}}

        {:error, state} ->
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
          {:ok, state} ->
            Logger.debug("loopex daemon protocol frame refused")
            {:ok, state}

          {:error, state} ->
            {:stop, state}
        end
    end
  end

  defp handle_request(state, request) do
    state = %{state | last_activity: System.monotonic_time(:millisecond)}

    case ConnectionProtocol.handle(state.protocol, request) do
      {:request, parsed, protocol} ->
        serve(%{state | protocol: protocol}, parsed)

      {_kind, record, protocol, :none} ->
        case send_record(state, record) do
          {:ok, state} -> {:ok, %{state | protocol: protocol}}
          {:error, state} -> {:stop, state}
        end

      {:ok, record, protocol, :initialized} ->
        request =
          ConnectionRegistry.connection_request(
            state.registry,
            {:initialize_complete, state.rollback_token, state.incarnation}
          )

        state = %{state | phase: :initializing}
        {:pause, await_exchange(state, request, :registry, {:initialize, record, protocol})}
    end
  end

  # Concept: initialization completes in two request steps — the registry's
  # initialize compare-and-set, then the relay registration — and only then
  # is the negotiation reply written and input read again.
  #
  # Technical depth: a refusal at either step stops the connection without
  # the reply, as before. The relay step has its own five-second instant like
  # every relay request of this connection.
  defp continue_initialization(state, {:initialize, record, protocol}, {:reply, :ok}) do
    case state.context do
      nil ->
        finish_initialization(state, record, protocol)

      %{relay: relay} ->
        request =
          AdmissionRelay.register_connection_request(relay, state.incarnation, state.registry)

        {:noreply, await_exchange(state, request, :relay, {:register_relay, record, protocol})}
    end
  end

  defp continue_initialization(state, {:register_relay, record, protocol}, {:reply, :ok}),
    do: finish_initialization(state, record, protocol)

  defp continue_initialization(state, {:register_relay, _record, _protocol}, _refused) do
    Logger.debug("loopex daemon socket connection relay registration refused")
    {:stop, :normal, state}
  end

  defp continue_initialization(state, {:initialize, _record, _protocol}, _refused),
    do: {:stop, :normal, state}

  defp finish_initialization(state, record, protocol) do
    case send_record(state, record) do
      {:ok, state} ->
        Logger.debug("loopex daemon socket connection initialized")
        schedule_idle_check(state)
        state = %{state | protocol: protocol, phase: :initialized}

        case state.deferred_stop do
          nil ->
            state |> consume_data(state.input_buffer) |> input_result()

          record ->
            begin_final_close(%{state | deferred_stop: nil}, record)
        end

      {:error, state} ->
        {:stop, :normal, state}
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

    begin_ticket(state, state.ledger, request, :session_create, nil, fn ->
      Loopex.Runtime.lookup_create_result(runtime, command_id, options)
    end)
  end

  # Concept: attach reserves the connection's one session first, then its
  # ticket; only a session this daemon lifetime activated can be attached.
  #
  # Technical depth: a connection holds at most one attachment, so a second
  # attach without `replace` is refused locally with ADR 0023's
  # `attachment_conflict` before any gate, and `replace: true` names the
  # connection's exact current attachment to core.
  defp serve(state, %Request{operation: :session_attach} = request) do
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
        if state.attachment && request.fields.replace != true do
          reply(state, WireRecords.request_error(request.request_id, "attachment_conflict"))
        else
          begin_ticket(state, reserved, request, :session_attach, session_id, fn -> :ok end)
        end
    end
  end

  # Concept: an existing-session mutation is admitted only through the lease
  # owner of the one session this connection serves.
  #
  # Technical depth: the connection sends each descriptor to that owner in
  # wire order, immediately after its relay ticket binds a worker, so the
  # owner's queue preserves pipelined arrival order. A session with no
  # granted lease has no route and refuses `control_not_held` before any
  # ticket, exactly as a failed gate would.
  defp serve(state, %Request{operation: operation} = request)
       when operation in @mutation_operations do
    case RequestLedger.bound_session(state.ledger) do
      nil -> reply(state, WireRecords.request_error(request.request_id, "control_not_held"))
      session_id -> serve_lease_ticket(state, request, session_id)
    end
  end

  defp serve(state, %Request{operation: :session_resume} = request) do
    case RequestLedger.admit_session(state.ledger, request.fields.session_id) do
      :ok ->
        serve_lease_ticket(state, request, request.fields.session_id)

      {:error, :session_conflict} ->
        reply(state, WireRecords.invalid_request(request.request_id, "session_conflict"))
    end
  end

  # Concept: queries, reads and transfers take lightweight relay permits whose
  # work starts only after the relay admits them, so a query arriving after
  # the admission cut is refused without touching core.
  defp serve(state, %Request{operation: operation} = request)
       when operation in @session_queries do
    session_id = request.fields.session_id

    case RequestLedger.admit_session(state.ledger, session_id) do
      :ok ->
        begin_permit(state, request, operation, session_id, query_fun(state.context, request))

      {:error, :session_conflict} ->
        reply(state, WireRecords.invalid_request(request.request_id, "session_conflict"))
    end
  end

  defp serve(state, %Request{operation: operation} = request)
       when operation in @transfer_operations do
    case state.attachment do
      nil ->
        reply(state, WireRecords.not_attached(request.request_id))

      %{attachment: attachment} ->
        begin_permit(state, request, operation, nil, transfer_fun(attachment, request))
    end
  end

  defp serve(state, %Request{operation: :session_list} = request),
    do: begin_permit(state, request, :session_list, nil, list_fun(state, request))

  defp serve(state, %Request{operation: :daemon_status} = request),
    do: begin_permit(state, request, :daemon_status, nil, status_fun(state, request))

  defp serve(state, request),
    do: reply(state, WireRecords.request_error(request.request_id, "unsupported_method"))

  # Concept: a ticketed request opens its relay ticket, starts its worker and
  # binds it, each relay step by request message, so the connection keeps
  # serving while the relay answers.
  #
  # Technical depth: the ledger entry is `:opening` until the relay answers
  # the open and `:binding` until it answers the bind. The worker is started
  # only once the ticket exists and stays monitored until the bind answer; a
  # result it reports before that answer is held and dispatched after it. A
  # refused open answers the request and releases any session reservation, as
  # the request never began; a refused bind settles it.
  defp begin_ticket(
         state,
         ledger,
         request,
         class,
         session_id,
         fun,
         owner_binding \\ nil,
         after_bind \\ fn state, _origin -> {:ok, state} end
       ) do
    case RequestLedger.begin(ledger, request.request_id, new_entry(request, :opening)) do
      {:ok, origin, ledger} ->
        state = %{state | ledger: ledger}

        {:ok,
         open_ticket_exchange(state, origin, class, session_id, fun, owner_binding, after_bind)}

      {:error, :duplicate_request} ->
        reply(state, WireRecords.invalid_request(request.request_id, "duplicate_request"))

      {:error, :capacity_exceeded} ->
        reply(state, WireRecords.request_error(request.request_id, "capacity_exceeded"))
    end
  end

  defp open_ticket_exchange(state, origin, class, session_id, fun, owner_binding, after_bind) do
    ledger = RequestLedger.update(state.ledger, origin, &%{&1 | phase: :opening})

    request_id =
      AdmissionRelay.open_ticket_request(
        state.context.relay,
        origin,
        class,
        session_id,
        owner_binding
      )

    await_exchange(
      %{state | ledger: ledger},
      request_id,
      :relay,
      {:open_ticket, origin, fun, after_bind}
    )
  end

  defp open_ticket(state, origin, class, session_id, fun, owner_binding, after_bind),
    do:
      {:noreply,
       open_ticket_exchange(state, origin, class, session_id, fun, owner_binding, after_bind)}

  defp new_entry(request, phase \\ :ready) do
    %{
      method: request.method,
      operation: request.operation,
      fields: request.fields,
      phase: phase,
      prepared: nil,
      succession_reserved: false,
      worker: nil,
      worker_monitor: nil,
      worker_incarnation: nil
    }
  end

  defp start_request_worker(state, origin, fun) do
    {worker, monitor, incarnation} = RequestWorker.start(origin, fun)

    ledger =
      RequestLedger.update(state.ledger, origin, fn entry ->
        %{entry | worker: worker, worker_monitor: monitor, worker_incarnation: incarnation}
      end)

    %{state | ledger: ledger, workers: Map.put(state.workers, monitor, origin)}
  end

  defp ticket_refusal(:daemon_stopping), do: "daemon_stopping"
  defp ticket_refusal(:capacity_exceeded), do: "capacity_exceeded"
  defp ticket_refusal(_reason), do: "internal_failure"

  # Concept: the request identity and the in-flight ceiling are checked before
  # any worker starts, and a refused request leaves no reservation behind.
  defp begin_worker(state, ledger, request, fun) do
    case RequestLedger.begin(ledger, request.request_id, new_entry(request)) do
      {:ok, origin, ledger} ->
        {:ok, start_request_worker(%{state | ledger: ledger}, origin, fun)}

      {:error, :duplicate_request} ->
        reply(state, WireRecords.invalid_request(request.request_id, "duplicate_request"))

      {:error, :capacity_exceeded} ->
        reply(state, WireRecords.request_error(request.request_id, "capacity_exceeded"))
    end
  end

  # Concept: nothing new starts while the connection is closing: a worker
  # result that arrives then is discarded, so no create commits a session and
  # no attach installs during the close, and nothing is written.
  #
  # Technical depth: for a create, an attach, an acquire or a release this
  # is a definite outcome, not an unknown one: the result only prepares the
  # request, and no core task has started, because core work begins only
  # with the promotion or hand-off this result would have triggered.
  # Discarding kills the still-monitored worker, which the relay holds as the
  # ticket's bound worker, so the relay's ordinary worker-loss path removes
  # the ticket; the request's session reservation and any succession reserve
  # are released with it. A lease ticket's hand-off is different: the bind
  # answer itself hands the descriptor to the lease owner and gives the
  # worker to the relay, so a result discarded here may follow a hand-off
  # already made. That is acceptable: its worker is no longer monitored and
  # is not killed, nothing is written, the relay settles the ticket normally,
  # and the uncorrelated close stands for its answer.
  defp continue_worker(%{closing: closing} = state, origin, _incarnation, _result)
       when closing != nil do
    Logger.debug("loopex daemon connection worker result discarded while closing")
    {:noreply, discard_entry(state, origin)}
  end

  defp continue_worker(state, origin, incarnation, result) do
    case RequestLedger.fetch(state.ledger, origin) do
      {:ok, %{worker_incarnation: ^incarnation, worker_monitor: monitor, phase: :binding}}
      when is_reference(monitor) ->
        ledger = RequestLedger.update(state.ledger, origin, &%{&1 | prepared: {:held, result}})
        {:noreply, %{state | ledger: ledger}}

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
          Owner.acquire_control_request(
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
      Owner.release_control_request(
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

  defp dispatch_prepared(state, _origin, %{operation: operation}, _result)
       when operation in @lease_ticket_operations,
       do: {:noreply, state}

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

    request_id =
      ConnectionRegistry.promote_create_request(
        state.registry,
        origin,
        command_id,
        options_digest(options),
        mode,
        ceiling,
        conflict,
        task
      )

    {:noreply, promote(state, origin, request_id, :create)}
  end

  # Concept: the attach task installs the connection itself as the holder, so
  # the connection's exit releases every attachment it owns.
  #
  # Technical depth: an unattached connection first takes its succession
  # delivery reserve by a registry request, its entry `:reserving` until the
  # answer; a replacement transfers the one it holds. The task hands the core
  # attachment to this process before its snapshot record settles.
  defp dispatch_prepared(state, origin, %{operation: :session_attach} = entry, :ok) do
    if state.attachment do
      promote_attach(state, origin, entry, :ok, false)
    else
      request =
        ConnectionRegistry.connection_request(
          state.registry,
          {:reserve_succession, state.incarnation}
        )

      ledger = RequestLedger.update(state.ledger, origin, &%{&1 | phase: :reserving})

      {:noreply,
       await_exchange(%{state | ledger: ledger}, request, :registry, {:reserve, origin})}
    end
  end

  defp promote_attach(state, origin, entry, reserve, took_reserve) do
    %{session_id: session_id, after_event_sequence: after_sequence, replace: replace} =
      entry.fields

    request_id = entry.request_id

    ledger =
      RequestLedger.update(state.ledger, origin, &%{&1 | succession_reserved: took_reserve})

    state = %{state | ledger: ledger}

    # A replacement removes the current attachment in core before this
    # connection installs the new one, so the old pump's failure while it is
    # pending is expected, not a lost attachment. The mark names this
    # request's origin: only its own settlement may end it, and a later
    # replacement sent while it is pending never takes it over.
    state =
      if replace == true && is_map(state.attachment) &&
           not is_map_key(state.attachment, :replacing),
         do: put_in(state, [:attachment, :replacing], origin),
         else: state

    case reserve do
      :ok ->
        options =
          [after_event_sequence: after_sequence] ++
            if replace == true and state.attachment,
              do: [replace_attachment_id: state.attachment.attachment_id],
              else: []

        task = attach_task(state.context, origin, request_id, session_id, options)

        registry_request =
          ConnectionRegistry.promote_attach_request(
            state.registry,
            origin,
            state.incarnation,
            session_id,
            WireRecords.request_error(request_id, "session_dormant"),
            WireRecords.request_error(request_id, "capacity_exceeded"),
            task
          )

        {:noreply, promote(state, origin, registry_request, :attach)}

      {:error, _reason} ->
        settle_locally(state, origin, "capacity_exceeded")
    end
  end

  defp attach_task(context, origin, request_id, session_id, options) do
    runtime = context.runtime
    connection = self()
    fatal_recipient = Map.get(context, :fatal_recipient)

    fn ->
      case Loopex.Runtime.attach_for_holder(runtime, session_id, connection, options) do
        {:ok, attachment} ->
          {:ok, _runtime, _session_id, attachment_id, _incarnation} =
            Loopex.Attachment.routing(attachment)

          send(connection, {:daemon_attachment, origin, attachment})

          {:installed, attachment_id,
           WireRecords.snapshot(
             request_id,
             Loopex.Attachment.snapshot(attachment),
             Loopex.Attachment.open_interaction(attachment)
           )}

        {:error, :runtime_unavailable} ->
          if is_pid(fatal_recipient),
            do: send(fatal_recipient, {:daemon_component_fatal, self(), :runtime_lost})

          {:refused, WireRecords.request_error(request_id, "internal_failure")}

        {:error, reason} ->
          {:refused, WireRecords.request_error(request_id, attach_refusal(reason))}
      end
    end
  end

  defp attach_refusal(reason)
       when reason in [:attachment_superseded, :attachment_conflict, :attachment_request_conflict],
       do: "attachment_conflict"

  defp attach_refusal(:capacity_exceeded), do: "capacity_exceeded"
  defp attach_refusal(:session_unavailable), do: "session_unavailable"
  defp attach_refusal(_reason), do: "internal_failure"

  # Concept: the succession reserve's answer continues the attach that asked
  # for it; an attach that ended meanwhile releases a reserve it was granted,
  # so no reserve outlives its request.
  defp reserve_answered(state, origin, response) do
    case {RequestLedger.fetch(state.ledger, origin), response} do
      {{:ok, %{phase: :reserving} = entry}, {:reply, :ok}} when is_nil(state.closing) ->
        promote_attach(state, origin, entry, :ok, true)

      {{:ok, %{phase: :reserving} = entry}, {:reply, {:error, reason}}}
      when is_nil(state.closing) ->
        promote_attach(state, origin, entry, {:error, reason}, false)

      {{:ok, %{phase: :reserving}}, {:reply, granted}} ->
        Logger.debug("loopex daemon connection answer discarded while closing")
        state = mark_reserved(state, origin, granted == :ok)
        {:noreply, discard_entry(state, origin)}

      {_ended, {:reply, :ok}} ->
        {:noreply, release_succession(state)}

      _refused ->
        {:noreply, state}
    end
  end

  defp mark_reserved(state, origin, taken) do
    ledger = RequestLedger.update(state.ledger, origin, &%{&1 | succession_reserved: taken})
    %{state | ledger: ledger}
  end

  # Concept: a refused attach releases exactly the succession reserve it took
  # when it was dispatched, whatever this connection's attachment has become
  # since, so it can never release a reserve another request holds.
  defp release_taken_succession(state, %{succession_reserved: true}),
    do: release_succession(state)

  defp release_taken_succession(state, _entry), do: state

  # Technical depth: the release is a registry request whose answer is
  # consumed and ignored, as the call's answer was; it is ordered before every
  # later output request of this connection.
  defp release_succession(state) do
    request =
      ConnectionRegistry.connection_request(
        state.registry,
        {:release_succession, state.incarnation}
      )

    await_exchange(state, request, :registry, {:ignored})
  end

  # Concept: delivery starts only after the snapshot is queued, so a client
  # never receives an event for a cursor it has not been told about.
  defp install_attachment(state, entry, record) do
    case Map.get(entry, :attachment) do
      %Loopex.Attachment{} = attachment ->
        {:ok, _runtime, session_id, attachment_id, _incarnation} =
          Loopex.Attachment.routing(attachment)

        state = stop_pump(state)
        {pump, monitor} = LoopexDaemon.AttachmentPump.start(attachment)
        cursor = Map.get(Loopex.Attachment.snapshot(attachment), :event_sequence, 0)

        attached = %{
          attachment: attachment,
          attachment_id: attachment_id,
          session_id: session_id,
          pump: pump,
          pump_monitor: monitor,
          snapshot_cursor: cursor,
          emitted_cursor: nil
        }

        Logger.debug("loopex daemon connection attachment installed")
        {%{state | attachment: attached}, cursor, record}

      _missing ->
        {state, nil, record}
    end
  end

  defp replaced_pump_ended(state) do
    Logger.debug("loopex daemon replaced attachment pump ended")
    put_in(state, [:attachment, :pump_ended], true)
  end

  # Concept: every way an attach ends without installing comes here, so a
  # pending replacement's mark never outlives it. A replacement that did not
  # happen leaves the current attachment in place; if that attachment's pump
  # already ended, the attachment is gone, so after the refusal the client is
  # told `detached` at its last emitted cursor and the connection closes, which
  # also releases its delivery reserve.
  defp refuse_attach(state, origin, entry, record) do
    state = release_reservation(state, entry)

    case state.attachment do
      %{replacing: ^origin, pump_ended: true} ->
        case noreply_record(state, record) do
          {:noreply, state} -> begin_detach_close(state)
          stopped -> stopped
        end

      %{replacing: ^origin} = attached ->
        noreply_record(%{state | attachment: Map.delete(attached, :replacing)}, record)

      _other ->
        noreply_record(release_taken_succession(state, entry), record)
    end
  end

  defp stop_pump(%{attachment: %{pump: pump, pump_monitor: monitor}} = state) do
    Process.demonitor(monitor, [:flush])
    Process.exit(pump, :kill)
    state
  end

  defp stop_pump(state), do: state

  defp deliver_event(%{attachment: attached} = state, event) do
    state = %{state | last_activity: System.monotonic_time(:millisecond)}
    record = WireRecords.event(attached.session_id, event)
    held = state.succession != nil
    kind = {:event, attached.pump}

    # A sent event lets the pump continue once the registry accepts it; a
    # held one continues it at once, as it always has.
    case send_record(state, record, Map.fetch!(event, :event_sequence), kind) do
      {:ok, state} ->
        if held, do: LoopexDaemon.AttachmentPump.continue(attached.pump)
        {:noreply, state}

      {:error, state} ->
        begin_detach_close(state)
    end
  end

  # Concept: an attachment that cannot keep up is detached at the last
  # cursor this connection completely emitted, and the connection closes.
  defp begin_detach_close(%{attachment: attached} = state) do
    state = stop_pump(state)
    cursor = attached.emitted_cursor || attached.snapshot_cursor
    Logger.debug("loopex daemon attachment detached")
    begin_final_close(state, WireRecords.detached(attached.session_id, cursor))
  end

  # Concept: a connection the daemon ends writes one final record where its
  # transport accepts it and then closes, within a fixed bound.
  defp begin_final_close(state, record) do
    close_ref = make_ref()
    Process.send_after(self(), {:owner_loss_close_deadline, close_ref}, @owner_loss_close_ms)
    state = %{state | closing: %{owner: nil, close_ref: close_ref}}

    case send_record(state, record) do
      {:ok, state} -> {:noreply, state}
      {:error, state} -> finish_owner_loss_close(state)
    end
  end

  # Concept: the relay task, not the connection, makes the activating call,
  # and it classifies exactly what core started.
  defp create_task(context, request_id, command_id, options) do
    runtime = context.runtime
    fatal_recipient = Map.get(context, :fatal_recipient)

    connection = self()

    fn ->
      case Loopex.Runtime.create_session_detailed(runtime, command_id, options) do
        {:ok, %{session_id: session_id, disposition: disposition}} ->
          if disposition == :activated, do: publish_session(context, connection, session_id)

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
  defp relay_owns_worker(state, _origin, %{worker_monitor: nil}), do: state

  defp relay_owns_worker(state, origin, entry) do
    Process.demonitor(entry.worker_monitor, [:flush])
    ledger = RequestLedger.update(state.ledger, origin, &%{&1 | worker_monitor: nil})
    %{state | ledger: ledger, workers: Map.delete(state.workers, entry.worker_monitor)}
  end

  # Concept: a create or attach is promoted by a registry request this
  # connection never awaits, so no call timeout can turn a promotion that
  # may have committed into a refusal.
  #
  # Technical depth: the entry is `:promoting` until the registry answers.
  # The relay kills the waiting worker as part of promotion, so that worker's
  # exit while promoting is expected and only drops its monitor. The registry
  # answers once its relay step does; its own request instants bound that, so
  # the connection holds no deadline here.
  defp promote(state, origin, request_id, kind) do
    ledger = RequestLedger.update(state.ledger, origin, &%{&1 | phase: :promoting})
    await_exchange(%{state | ledger: ledger}, request_id, :registry, {:promote, origin, kind})
  end

  defp await_exchange(state, request_id, target, label) do
    timer =
      case target do
        :relay ->
          Process.send_after(self(), {:relay_request_unanswered, request_id}, @relay_request_ms)

        # A promotion's answer waits on the registry's relay flow, whose
        # own instants bound it, so the connection holds no deadline there.
        :registry when elem(label, 0) == :promote ->
          nil

        :registry ->
          Process.send_after(
            self(),
            {:registry_request_unanswered, request_id},
            @registry_request_ms
          )

        _owner ->
          nil
      end

    put_in(state, [:exchanges, request_id], %{label: label, timer: timer, target: target})
  end

  # Concept: each relay or registry answer continues exactly one request, and
  # a request the connection has already answered takes nothing from it.
  #
  # Technical depth: an exited relay answers the request `internal_failure`;
  # the daemon owner classifies the relay. An exited registry stops this
  # connection as `registry_lost` whatever it was asked, the same as its
  # monitor does, because a promotion or output it may have committed can no
  # longer be answered truthfully. The output path — enqueue, claim, emission
  # and succession finish — and initialization continue whether or not the
  # connection is closing, because the close itself writes through them.
  # Every other answer consumed once the connection is closing — after its
  # owner-loss close or its final close — is cleanup-only: the request's
  # unbound worker is killed, its entry completed and its reservations
  # released, and nothing is written, so no correlated record ever follows
  # the uncorrelated close.
  defp exchange_answered(state, request_id, message) do
    {exchange, exchanges} = Map.pop(state.exchanges, request_id)
    if exchange.timer, do: Process.cancel_timer(exchange.timer)
    state = %{state | exchanges: exchanges}

    response =
      case :gen_server.check_response(message, request_id) do
        {:reply, reply} -> {:reply, reply}
        _server_gone -> :down
      end

    label = exchange.label

    cond do
      response == :down and exchange.target == :registry ->
        Logger.debug("loopex daemon connection registry lost during an exchange")
        {:stop, :registry_lost, state}

      elem(label, 0) in [:enqueue, :claim, :emitted, :finish_succession, :ignored] ->
        output_answered(state, label, response)

      elem(label, 0) == :slot_promotion ->
        promotion_answered(state, response)

      elem(label, 0) in [:initialize, :register_relay] ->
        continue_initialization(state, label, response)

      elem(label, 0) == :reserve ->
        reserve_answered(state, elem(label, 1), response)

      state.closing ->
        close_exchange(state, label, response)

      true ->
        continue_exchange(state, label, response)
    end
  end

  defp promotion_answered(state, {:reply, :ok}) do
    Process.demonitor(state.listener_monitor, [:flush])

    send(
      state.listener,
      {:promotion_complete, state.rollback_token, state.incarnation, self()}
    )

    Logger.debug("loopex daemon socket connection promoted")
    send(self(), :receive_next)
    {:noreply, %{state | phase: :live, listener_monitor: nil}}
  end

  defp promotion_answered(state, _refused), do: {:stop, :normal, state}

  # Concept: while closing, an accepted hand-off leaves its worker to the
  # relay, which owns it once the permit exists. A hand-off whose owner
  # exited (`:down`) is also left alone: its worker exits on this
  # connection's own `DOWN`. Only a worker whose hand-off the owner refused
  # is ended here.
  defp close_exchange(state, {:handoff, origin}, response) do
    Logger.debug("loopex daemon connection answer discarded while closing")

    state =
      case {RequestLedger.fetch(state.ledger, origin), response} do
        {{:ok, %{phase: :handoff}}, {:reply, {:ok, :accepted, _actor, _incarnation}}} -> state
        {{:ok, %{phase: :handoff}}, :down} -> state
        {{:ok, %{phase: :handoff} = entry}, _refused} -> kill_handed_worker(state, entry)
        _answered -> state
      end

    {:noreply, discard_entry(state, origin)}
  end

  defp close_exchange(state, label, _response) do
    Logger.debug("loopex daemon connection answer discarded while closing")
    {:noreply, discard_entry(state, elem(label, 1))}
  end

  # A handed worker is no longer monitored; a request the owner answered
  # without a permit, or one abandoned by the close, still ends it.
  defp kill_handed_worker(state, %{worker: worker}) when is_pid(worker) do
    Process.exit(worker, :kill)
    state
  end

  defp kill_handed_worker(state, _entry), do: state

  # Concept: a request abandoned while the connection closes leaves nothing
  # behind and writes nothing.
  defp discard_entry(state, origin) do
    case RequestLedger.complete(state.ledger, origin) do
      {nil, _ledger} ->
        state

      {entry, ledger} ->
        %{state | ledger: ledger}
        |> release_unbound_worker(entry)
        |> release_reservation(entry)
        |> release_taken_succession(entry)
    end
  end

  # Concept: a worker the relay has not yet taken over belongs to this
  # connection, so a request that ends while its worker is unbound kills it
  # rather than leave it waiting for a `go` that will never come.
  defp release_unbound_worker(state, %{worker_monitor: monitor, worker: worker})
       when is_reference(monitor) do
    Process.demonitor(monitor, [:flush])
    Process.exit(worker, :kill)
    %{state | workers: Map.delete(state.workers, monitor)}
  end

  defp release_unbound_worker(state, _entry), do: state

  defp continue_exchange(state, {:open_ticket, origin, fun, after_bind}, {:reply, {:ok, origin}}) do
    case RequestLedger.fetch(state.ledger, origin) do
      {:ok, %{phase: :opening}} ->
        state = start_request_worker(state, origin, fun)
        ledger = RequestLedger.update(state.ledger, origin, &%{&1 | phase: :binding})
        state = %{state | ledger: ledger}
        {:ok, entry} = RequestLedger.fetch(state.ledger, origin)

        request_id =
          AdmissionRelay.bind_ticket_worker_request(
            state.context.relay,
            origin,
            entry.worker,
            entry.worker_incarnation
          )

        {:noreply, await_exchange(state, request_id, :relay, {:bind_ticket, origin, after_bind})}

      _answered ->
        {:noreply, state}
    end
  end

  defp continue_exchange(state, {:open_ticket, origin, _fun, _after_bind}, response),
    do: refuse_opening(state, origin, response)

  defp continue_exchange(state, {:bind_ticket, origin, after_bind}, {:reply, :ok}) do
    case RequestLedger.fetch(state.ledger, origin) do
      {:ok, %{phase: :binding}} ->
        ledger = RequestLedger.update(state.ledger, origin, &%{&1 | phase: :ready})

        case after_bind.(%{state | ledger: ledger}, origin) do
          {:ok, state} -> dispatch_held_result(state, origin)
          {:stop, state} -> {:stop, :normal, state}
        end

      _answered ->
        {:noreply, state}
    end
  end

  defp continue_exchange(state, {:bind_ticket, origin, _after_bind}, response),
    do: refuse_binding(state, origin, response)

  defp continue_exchange(state, {:open_permit, origin, fun}, {:reply, {:ok, origin}}) do
    case RequestLedger.fetch(state.ledger, origin) do
      {:ok, %{phase: :opening}} ->
        relay = state.context.relay
        {worker, monitor, incarnation} = RequestWorker.start_permit(origin, relay, fun)

        ledger =
          RequestLedger.update(state.ledger, origin, fn entry ->
            %{
              entry
              | phase: :binding,
                worker: worker,
                worker_monitor: monitor,
                worker_incarnation: incarnation
            }
          end)

        state = %{state | ledger: ledger, workers: Map.put(state.workers, monitor, origin)}
        request_id = AdmissionRelay.bind_worker_request(relay, origin, worker, incarnation)
        {:noreply, await_exchange(state, request_id, :relay, {:bind_permit, origin})}

      _answered ->
        {:noreply, state}
    end
  end

  defp continue_exchange(state, {:open_permit, origin, _fun}, response),
    do: refuse_opening(state, origin, response)

  defp continue_exchange(state, {:bind_permit, origin}, {:reply, :ok}) do
    case RequestLedger.fetch(state.ledger, origin) do
      {:ok, %{phase: :binding} = entry} ->
        ledger = RequestLedger.update(state.ledger, origin, &%{&1 | phase: :ready})
        {:noreply, relay_owns_worker(%{state | ledger: ledger}, origin, entry)}

      _answered ->
        {:noreply, state}
    end
  end

  defp continue_exchange(state, {:bind_permit, origin}, response),
    do: refuse_binding(state, origin, response)

  defp continue_exchange(state, {:handoff, origin}, response) do
    case {RequestLedger.fetch(state.ledger, origin), response} do
      {{:ok, %{phase: :handoff}}, {:reply, {:ok, :accepted, _actor, _actor_incarnation}}} ->
        ledger = RequestLedger.update(state.ledger, origin, &%{&1 | phase: :ready})
        {:noreply, %{state | ledger: ledger}}

      # Concept: the returned holder of a lost session owner is being closed
      # with its one uncorrelated record, so a request it sent is settled
      # without writing anything alongside that close.
      {{:ok, %{phase: :handoff} = entry}, {:reply, {:error, :holder_closed}}} ->
        Logger.debug("loopex daemon lease request of a closing holder settled")
        {:noreply, state |> kill_handed_worker(entry) |> discard_entry(origin)}

      {{:ok, %{phase: :handoff}}, {:reply, {:error, reason}}} ->
        settle_locally(state, origin, lease_refusal(reason))

      # Concept: an owner that exited is the daemon's fail-stop; whether the
      # relay opened the permit is unknown, so nothing is written and the
      # relay's record or the uncorrelated close answers the request.
      {{:ok, %{phase: :handoff}}, _owner_gone} ->
        Logger.debug("loopex daemon lease hand-off outcome unknown")
        ledger = RequestLedger.update(state.ledger, origin, &%{&1 | phase: :ready})
        {:noreply, %{state | ledger: ledger}}

      _answered ->
        {:noreply, state}
    end
  end

  defp continue_exchange(state, {:lease_route, origin, session_id}, response) do
    case {RequestLedger.fetch(state.ledger, origin), response} do
      {{:ok, %{phase: :routing} = entry}, {:reply, {:ok, owner, owner_incarnation}}} ->
        open_ticket(
          state,
          origin,
          entry.operation,
          session_id,
          fn -> :ok end,
          {owner, owner_incarnation},
          fn state, origin -> send_lease_descriptor(state, origin, owner) end
        )

      {{:ok, %{phase: :routing}}, _no_route} ->
        {entry, ledger} = RequestLedger.complete(state.ledger, origin)

        noreply_record(
          %{state | ledger: ledger},
          WireRecords.request_error(entry.request_id, "control_not_held")
        )

      _answered ->
        {:noreply, state}
    end
  end

  defp continue_exchange(state, {:promote, origin, _kind}, {:reply, reply}) do
    case {RequestLedger.fetch(state.ledger, origin), reply} do
      {{:ok, %{phase: :promoting} = entry}, {:ok, _promotion}} ->
        ledger = RequestLedger.update(state.ledger, origin, &%{&1 | phase: :ready})
        {:noreply, relay_owns_worker(%{state | ledger: ledger}, origin, entry)}

      # Concept: when the relay was lost or torn down with this promotion in
      # flight, whether core ran it is unknown, so no correlated refusal is
      # written; the request is left to the connection's uncorrelated close,
      # which the daemon's fail-stop or teardown always brings. Every other
      # refusal is definite: the registry or the relay decided it before any
      # core effect could start.
      {{:ok, %{phase: :promoting} = entry}, {:error, :promotion_outcome_unknown}} ->
        Logger.debug("loopex daemon connection promotion outcome unknown")
        ledger = RequestLedger.update(state.ledger, origin, &%{&1 | phase: :outcome_unknown})
        {:noreply, relay_owns_worker(%{state | ledger: ledger}, origin, entry)}

      {{:ok, %{phase: :promoting}}, {:error, reason}} ->
        settle_locally(state, origin, ticket_refusal(reason))

      _answered ->
        {:noreply, state}
    end
  end

  # A refused or unanswerable open answers the request that never began and
  # releases any session reservation it made.
  defp refuse_opening(state, origin, response) do
    case RequestLedger.fetch(state.ledger, origin) do
      {:ok, %{phase: :opening}} ->
        {entry, ledger} = RequestLedger.complete(state.ledger, origin)
        state = release_reservation(%{state | ledger: ledger}, entry)

        noreply_record(
          state,
          WireRecords.request_error(entry.request_id, relay_refusal(response))
        )

      _answered ->
        {:noreply, state}
    end
  end

  defp refuse_binding(state, origin, response) do
    case RequestLedger.fetch(state.ledger, origin) do
      {:ok, %{phase: :binding}} -> settle_locally(state, origin, relay_refusal(response))
      _answered -> {:noreply, state}
    end
  end

  defp relay_refusal({:reply, {:error, reason}}), do: ticket_refusal(reason)
  defp relay_refusal(_unanswerable), do: "internal_failure"

  # A worker result that arrived while its ticket was binding is dispatched
  # now, exactly as it would have been had the bind answered first.
  defp dispatch_held_result(state, origin) do
    case RequestLedger.fetch(state.ledger, origin) do
      {:ok, %{prepared: {:held, result}, worker_monitor: monitor} = entry}
      when is_reference(monitor) ->
        ledger = RequestLedger.update(state.ledger, origin, &%{&1 | prepared: nil})
        dispatch_prepared(%{state | ledger: ledger}, origin, %{entry | prepared: nil}, result)

      _none ->
        {:noreply, state}
    end
  end

  # Concept: an acquire or release is handed to the daemon owner by a
  # request this connection never waits in: the owner may hold it until its
  # session settles, and the connection keeps serving its socket, its
  # results and its closes meanwhile. The owner's acceptance hands the one
  # answer to the relay's permit; its refusal, which comes before any permit
  # exists, is answered here.
  #
  # Technical depth: before sending, the entry becomes `:handoff` and the
  # worker stops being monitored, so its normal exit after `go` is not taken
  # for its loss; its pid is kept so a refusal can kill it. No deadline of
  # the connection covers the owner's answer: the owner answers every
  # request exactly once, bounded by its own steps and the stop. A relay
  # record that arrives first is final, and the owner's later answer is then
  # cleanup only.
  defp hand_to_relay(state, origin, entry, send_request) do
    state = relay_owns_worker(state, origin, entry)
    ledger = RequestLedger.update(state.ledger, origin, &%{&1 | phase: :handoff})
    request_id = send_request.()
    {:noreply, await_exchange(%{state | ledger: ledger}, request_id, :owner, {:handoff, origin})}
  end

  defp lease_refusal(:daemon_stopping), do: "daemon_stopping"
  defp lease_refusal(:control_capacity_reached), do: "control_capacity_reached"
  defp lease_refusal(:owner_unavailable), do: "control_pending"
  defp lease_refusal(:capacity_exceeded), do: "capacity_exceeded"
  defp lease_refusal(:control_not_held), do: "control_not_held"
  defp lease_refusal(_reason), do: "internal_failure"

  defp settle_locally(state, origin, code) do
    {entry, ledger} = RequestLedger.complete(state.ledger, origin)
    state = %{state | ledger: ledger}

    state =
      case entry do
        %{worker_monitor: monitor, worker: worker} when is_reference(monitor) ->
          Process.demonitor(monitor, [:flush])
          Process.exit(worker, :kill)
          %{state | workers: Map.delete(state.workers, monitor)}

        %{worker: worker} when is_pid(worker) ->
          Process.exit(worker, :kill)
          state

        _other ->
          state
      end

    record = WireRecords.request_error(entry.request_id, code)

    if entry.operation == :session_attach,
      do: refuse_attach(state, origin, entry, record),
      else: noreply_record(release_reservation(state, entry), record)
  end

  # Concept: a worker's exit is its request's failure only when nothing else
  # can still answer the request.
  #
  # Technical depth: while promoting, the relay kills the waiting worker as
  # part of promotion. While a permit binds, a normal exit means the worker
  # already received its `go` and completed, and its exit overtook the
  # relay's bind answer, which comes from another sender; the bind answer or
  # the permit's result still follows, bounded by the bind request's own
  # instant. Only permits take this path: a ticket's worker cannot exit
  # normally while binding, so its held result always keeps its monitor.
  defp worker_lost(state, monitor, reason) do
    {origin, workers} = Map.pop(state.workers, monitor)
    state = %{state | workers: workers}

    case RequestLedger.fetch(state.ledger, origin) do
      {:ok, %{phase: :promoting}} ->
        ledger = RequestLedger.update(state.ledger, origin, &%{&1 | worker_monitor: nil})
        {:noreply, %{state | ledger: ledger}}

      {:ok, %{phase: :binding, operation: operation}}
      when reason == :normal and operation in @permit_operations ->
        Process.demonitor(monitor, [:flush])
        ledger = RequestLedger.update(state.ledger, origin, &%{&1 | worker_monitor: nil})
        {:noreply, %{state | ledger: ledger}}

      {:ok, entry} ->
        {_entry, ledger} = RequestLedger.complete(state.ledger, origin)
        state = %{state | ledger: ledger}
        Logger.debug("loopex daemon request worker lost")
        record = WireRecords.request_error(entry.request_id, "internal_failure")

        if entry.operation == :session_attach,
          do: refuse_attach(state, origin, entry, record),
          else: noreply_record(release_reservation(state, entry), record)

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

        case {entry.operation, record["type"]} do
          {:session_attach, "snapshot"} ->
            state = bind_attached_session(state, entry)
            {state, cursor, record} = install_attachment(state, entry, record)
            noreply_record(state, record, cursor)

          {:session_attach, _refused} ->
            refuse_attach(state, origin, entry, record)

          {_operation, "result"} ->
            noreply_record(bind_session(state, entry), record)

          {_operation, _other} ->
            noreply_record(release_reservation(state, entry), record)
        end
    end
  end

  defp render_refusal(state, origin, code) do
    case RequestLedger.complete(state.ledger, origin) do
      {nil, _ledger} ->
        {:noreply, state}

      {entry, ledger} ->
        state = release_unbound_worker(%{state | ledger: ledger}, entry)
        record = WireRecords.request_error(entry.request_id, code)

        if entry.operation == :session_attach,
          do: refuse_attach(state, origin, entry, record),
          else: noreply_record(release_reservation(state, entry), record)
    end
  end

  defp bind_session(state, %{operation: :session_acquire_control} = entry) do
    ledger = RequestLedger.bind(state.ledger, entry.fields.session_id, entry.request_id)
    %{state | ledger: ledger}
  end

  defp bind_session(state, _entry), do: state

  defp bind_attached_session(state, entry) do
    ledger = RequestLedger.bind(state.ledger, entry.fields.session_id, entry.request_id)
    %{state | ledger: ledger}
  end

  defp release_reservation(state, %{request_id: request_id}),
    do: %{state | ledger: RequestLedger.clear_reservation(state.ledger, request_id)}

  defp release_reservation(state, nil), do: state

  # Concept: the holder of a lost session owner learns it once and is closed.
  #
  # Technical depth: the record is queued before reading stops; a bounded
  # timer caps the flush so a stalled peer cannot hold the daemon owner past
  # its mirror deadline. The acknowledgement follows the close.
  defp begin_owner_loss_close(state, owner, close_ref, session_id) do
    state = stop_pump(state)
    record = WireRecords.owner_lost_close(session_id, emitted_cursor(state))
    Process.send_after(self(), {:owner_loss_close_deadline, close_ref}, @owner_loss_close_ms)
    state = %{state | closing: %{owner: owner, close_ref: close_ref}}
    Logger.debug("loopex daemon holder close for lost owner")

    case send_record(state, record) do
      {:ok, state} -> {:noreply, state}
      {:error, state} -> finish_owner_loss_close(state)
    end
  end

  defp finish_owner_loss_close(%{closing: %{owner: owner, close_ref: close_ref}} = state) do
    if state.socket, do: :socket.close(state.socket)
    if owner, do: Owner.owner_loss_connection_closed(owner, close_ref, state.incarnation)
    Logger.debug("loopex daemon connection close completed")
    {:stop, :normal, %{state | socket: nil}}
  end

  defp emitted_cursor(%{attachment: %{emitted_cursor: cursor, snapshot_cursor: snapshot}}),
    do: cursor || snapshot

  defp emitted_cursor(_state), do: nil

  defp report_fatal(%{context: %{fatal_recipient: recipient}}, class) when is_pid(recipient) do
    send(recipient, {:daemon_component_fatal, self(), class})
    :ok
  end

  defp report_fatal(_state, _class), do: :ok

  defp request_deadline,
    do: System.monotonic_time(:millisecond) + Map.fetch!(V2.limits(), "reply_wait_ms")

  defp reply(state, record) do
    case send_record(state, record) do
      {:ok, state} -> {:ok, state}
      {:error, state} -> {:stop, state}
    end
  end

  defp noreply_record(state, record, cursor \\ nil) do
    case send_record(state, record, cursor) do
      {:ok, state} -> {:noreply, state}
      {:error, state} -> {:stop, :normal, state}
    end
  end

  # Concept: every queued frame is remembered in emission order, so the last
  # completely emitted event cursor is known exactly.
  #
  # Technical depth: the enqueue is a registry request; its frame's cursor
  # joins the emission order when the registry accepts it, which is always
  # before that frame can be claimed. A refusal arrives later and is handled
  # by `output_answered/3` as this function's `{:error, state}` was: a record
  # that cannot be enqueued stops the connection, an event detaches, and a
  # closing connection completes its close.
  defp send_record(state, record, cursor \\ nil, kind \\ :record)

  defp send_record(%{succession: held} = state, record, cursor, _kind) when held != nil,
    do: {:ok, %{state | succession: :queue.in({record, cursor}, held)}}

  defp send_record(state, record, cursor, kind) do
    state = track_lease(state, record)

    case Frame.encode(record) do
      {:ok, encoded} ->
        {:ok, enqueue_output(state, encoded, cursor, kind)}

      _unencodable ->
        Logger.debug("loopex daemon socket output enqueue failed")
        {:error, state}
    end
  end

  defp enqueue_output(state, encoded, cursor, kind) do
    request =
      ConnectionRegistry.connection_request(
        state.registry,
        {:enqueue_output, state.incarnation, encoded}
      )

    track_enqueue(state, request, cursor, kind)
  end

  # Technical depth: `enqueue_seq` counts every enqueue sent, so a claim
  # answered `:empty` is final only when no enqueue was sent after it.
  defp track_enqueue(state, request, cursor, kind) do
    state = %{
      state
      | enqueue_seq: state.enqueue_seq + 1,
        enqueues_pending: state.enqueues_pending + 1
    }

    await_exchange(state, request, :registry, {:enqueue, cursor, kind})
  end

  defp output_step(%{output_claim: nil} = state) do
    request =
      ConnectionRegistry.connection_request(
        state.registry,
        {:claim_output, state.incarnation}
      )

    state = %{state | output_claim: :claiming}
    {:noreply, await_exchange(state, request, :registry, {:claim, state.enqueue_seq})}
  end

  defp output_step(%{output_claim: :claiming} = state), do: {:noreply, state}

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

  # Technical depth: the emission acknowledgement is a registry request sent
  # before the next claim, so the registry releases this frame's charge
  # before it answers that claim; a refused acknowledgement stops the
  # connection when its answer arrives.
  defp complete_output(%{output_claim: %{frame_ref: frame_ref}} = state) do
    request =
      ConnectionRegistry.connection_request(
        state.registry,
        {:output_emitted, state.incarnation, frame_ref}
      )

    send(self(), :flush_output)
    state = %{state | output_claim: nil, send_select: nil}
    {:ok, state |> await_exchange(request, :registry, {:emitted}) |> advance_emitted_cursor()}
  end

  defp advance_emitted_cursor(state) do
    case :queue.out(state.output_cursors) do
      {{:value, cursor}, cursors} when is_integer(cursor) and not is_nil(state.attachment) ->
        attachment = %{state.attachment | emitted_cursor: cursor}
        %{state | output_cursors: cursors, attachment: attachment}

      {{:value, _cursor}, cursors} ->
        %{state | output_cursors: cursors}

      {:empty, _cursors} ->
        state
    end
  end

  # The notice has been written: release the succession reserve, then write
  # the held records in the order they were produced. The release is a
  # registry request; records keep being held until it is answered.
  defp finish_succession(%{finishing_succession: true} = state), do: {:noreply, state}

  defp finish_succession(state) do
    request =
      ConnectionRegistry.connection_request(
        state.registry,
        {:finish_succession, state.incarnation}
      )

    state = %{state | finishing_succession: true}
    {:noreply, await_exchange(state, request, :registry, {:finish_succession})}
  end

  defp succession_finished(state, {:reply, :ok}) do
    held = state.succession
    state = %{state | succession: nil, finishing_succession: false}

    case send_records(state, :queue.to_list(held)) do
      {:ok, state} -> output_step(state)
      {:error, state} -> {:stop, :normal, state}
    end
  end

  defp succession_finished(state, _refused),
    do: {:noreply, %{state | finishing_succession: false}}

  defp send_records(state, records) do
    Enum.reduce_while(records, {:ok, state}, fn {record, cursor}, {:ok, acc} ->
      case send_record(acc, record, cursor) do
        {:ok, acc} -> {:cont, {:ok, acc}}
        {:error, acc} -> {:halt, {:error, acc}}
      end
    end)
  end

  # Concept: every output answer is consumed exactly once, whether or not the
  # connection is closing, because a close writes through the same path.
  #
  # Technical depth: an accepted enqueue places its cursor in emission order
  # and, for an event, lets the pump send the next one, so an attachment still
  # has at most one event awaiting the registry. A refused enqueue is the
  # synchronous refusal it replaces: a closing connection completes its close,
  # an event detaches its attachment, a succession notice closes with the
  # `detached` record, progress is dropped and any other record stops the
  # connection. A claim answered `:empty` after a later enqueue was sent is
  # claimed again, so neither a close nor a succession finish can overtake a
  # record already sent to the registry.
  defp output_answered(state, {:enqueue, cursor, kind}, {:reply, :ok}) do
    state =
      resume_input(%{
        state
        | enqueues_pending: state.enqueues_pending - 1,
          output_cursors: :queue.in(cursor, state.output_cursors)
      })

    case kind do
      {:event, pump} ->
        if match?(%{pump: ^pump}, state.attachment),
          do: LoopexDaemon.AttachmentPump.continue(pump)

        {:noreply, state}

      {:notice, _session_id, attachment_id, _cursor} ->
        request =
          ConnectionRegistry.connection_request(
            state.registry,
            {:attachment_invalidated, state.incarnation, attachment_id}
          )

        Logger.debug("loopex daemon attachment detached by succession")
        output_step(await_exchange(state, request, :registry, {:ignored}))

      _record ->
        {:noreply, state}
    end
  end

  defp output_answered(state, {:enqueue, _cursor, kind}, _refused) do
    state = resume_input(%{state | enqueues_pending: state.enqueues_pending - 1})
    Logger.debug("loopex daemon socket output enqueue failed")

    case kind do
      _any when state.closing != nil ->
        finish_owner_loss_close(state)

      {:notice, session_id, _attachment_id, cursor} ->
        held = state.succession
        state = %{state | succession: nil}

        case begin_final_close(state, WireRecords.detached(session_id, cursor)) do
          {:noreply, state} -> send_held_after_close(state, held)
          stopped -> stopped
        end

      {:event, pump} ->
        if match?(%{pump: ^pump}, state.attachment),
          do: begin_detach_close(state),
          else: {:stop, :normal, state}

      :progress ->
        {:noreply, state}

      :record ->
        {:stop, :normal, state}
    end
  end

  defp output_answered(state, {:claim, _seq}, {:reply, {:ok, frame_ref, bytes}}) do
    state
    |> Map.put(:output_claim, %{frame_ref: frame_ref, remaining: bytes})
    |> attempt_output(nil)
    |> output_result()
  end

  defp output_answered(%{enqueue_seq: current} = state, {:claim, seq}, {:reply, :empty})
       when current != seq,
       do: output_step(%{state | output_claim: nil})

  defp output_answered(state, {:claim, _seq}, {:reply, :empty}) do
    state = %{state | output_claim: nil}

    cond do
      state.closing -> finish_owner_loss_close(state)
      state.succession != nil -> finish_succession(state)
      :queue.is_empty(state.progress) -> {:noreply, state}
      true -> flush_progress(state)
    end
  end

  defp output_answered(state, {:claim, _seq}, _refused), do: {:stop, :normal, state}
  defp output_answered(state, {:emitted}, {:reply, :ok}), do: {:noreply, state}
  defp output_answered(state, {:emitted}, _refused), do: {:stop, :normal, state}

  defp output_answered(state, {:finish_succession}, response),
    do: succession_finished(state, response)

  defp output_answered(state, {:ignored}, _response), do: {:noreply, state}

  defp send_held_after_close(state, held) do
    case send_records(state, :queue.to_list(held)) do
      {:ok, state} -> {:noreply, state}
      {:error, state} -> finish_owner_loss_close(state)
    end
  end

  defp idle_eviction_ms(%{context: %{idle_eviction_ms: ms}}) when is_integer(ms) and ms > 0,
    do: ms

  defp idle_eviction_ms(_state), do: 600_000

  defp schedule_idle_check(state) do
    Process.send_after(self(), :idle_check, min(idle_eviction_ms(state), 60_000))
  end

  # The lease this connection holds is read from the control results it sends.
  defp track_lease(state, %{
         "type" => "result",
         "method" => "session.acquire_control",
         "result" => %{"expires_in_ms" => expires}
       }) do
    case Wire.u64(expires) do
      {:ok, ms} -> %{state | lease_expires_at: System.monotonic_time(:millisecond) + ms}
      :error -> state
    end
  end

  defp track_lease(state, %{"type" => "result", "method" => "session.release_control"}),
    do: %{state | lease_expires_at: nil}

  defp track_lease(state, _record), do: state

  defp queue_progress(state, encoded) do
    queue = :queue.in(encoded, state.progress)
    bytes = state.progress_bytes + byte_size(encoded)
    trim_progress(%{state | progress: queue, progress_bytes: bytes})
  end

  defp trim_progress(state) do
    if :queue.len(state.progress) > @progress_records or state.progress_bytes > @progress_bytes do
      {{:value, dropped}, queue} = :queue.out(state.progress)

      trim_progress(%{
        state
        | progress: queue,
          progress_bytes: state.progress_bytes - byte_size(dropped)
      })
    else
      state
    end
  end

  # Technical depth: durable output is empty only when nothing is claimed,
  # enqueued or awaiting the registry's acceptance; progress is then enqueued
  # one record at a time, directly, as before.
  defp flush_progress(state) do
    idle =
      state.output_claim == nil and :queue.is_empty(state.output_cursors) and
        state.enqueues_pending == 0

    with true <- idle,
         {{:value, encoded}, queue} <- :queue.out(state.progress) do
      state = %{
        state
        | progress: queue,
          progress_bytes: state.progress_bytes - byte_size(encoded)
      }

      state
      |> enqueue_output(encoded, nil, :progress)
      |> output_step()
    else
      _waiting -> {:noreply, state}
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

  # Concept: a lease-authorized request first asks the registry for its
  # session's route by a request message; its ledger entry is `:routing`
  # until the answer, so its identity and the in-flight ceiling are checked on
  # arrival. A session with no granted lease refuses `control_not_held`
  # before any ticket.
  #
  # Technical depth: the registry answers route requests in the order they
  # were sent, so tickets still open, bind and hand their descriptors to the
  # lease owner in wire order.
  defp serve_lease_ticket(state, request, session_id) do
    case RequestLedger.begin(state.ledger, request.request_id, new_entry(request, :routing)) do
      {:ok, origin, ledger} ->
        registry_request =
          ConnectionRegistry.connection_request(state.registry, {:lease_route, session_id})

        state = %{state | ledger: ledger}

        {:ok,
         await_exchange(state, registry_request, :registry, {:lease_route, origin, session_id})}

      {:error, :duplicate_request} ->
        reply(state, WireRecords.invalid_request(request.request_id, "duplicate_request"))

      {:error, :capacity_exceeded} ->
        reply(state, WireRecords.request_error(request.request_id, "capacity_exceeded"))
    end
  end

  # Concept: the relay owns a lease ticket's worker from binding onward, and
  # the connection learns the lease owner's disposition asynchronously.
  defp send_lease_descriptor(state, origin, owner) do
    {:ok, entry} = RequestLedger.fetch(state.ledger, origin)
    state = relay_owns_worker(state, origin, entry)
    descriptor = lease_descriptor(state, origin, entry)
    calls = LeaseOwner.send_descriptor(owner, descriptor, origin, state.calls)
    {:ok, %{state | calls: calls}}
  end

  defp lease_descriptor(state, origin, %{operation: :session_resume} = entry) do
    %{session_id: session_id, command_id: command_id, writer_epoch: epoch} = entry.fields

    {:resume, origin, entry.request_id, command_id, state.incarnation, epoch, entry.worker,
     resume_task(state.context, entry.request_id, session_id, command_id)}
  end

  defp lease_descriptor(state, origin, entry) do
    {:mutate, origin, entry.operation, entry.request_id, state.incarnation,
     entry.fields.writer_epoch, entry.worker, mutation_task(state, entry)}
  end

  defp collect_descriptor_reply(state, message) do
    case :gen_server.check_response(message, state.calls, true) do
      {{:reply, reply}, origin, calls} ->
        descriptor_answered(%{state | calls: calls}, origin, reply)

      {{:error, {_reason, _server}}, _origin, calls} ->
        {:noreply, %{state | calls: calls}}

      _not_a_descriptor_reply ->
        {:noreply, state}
    end
  end

  defp descriptor_answered(state, _origin, {:ok, disposition})
       when disposition in [:admitted, :completed],
       do: {:noreply, state}

  defp descriptor_answered(state, _origin, {:error, :promotion_outcome_unknown}) do
    Logger.debug("loopex daemon connection promotion outcome unknown")
    {:noreply, state}
  end

  defp descriptor_answered(state, origin, {:error, reason}) do
    case RequestLedger.fetch(state.ledger, origin) do
      {:ok, _entry} -> settle_locally(state, origin, descriptor_refusal(reason))
      :error -> {:noreply, state}
    end
  end

  defp descriptor_answered(state, _origin, _reply), do: {:noreply, state}

  defp descriptor_refusal(:daemon_stopping), do: "daemon_stopping"
  defp descriptor_refusal(:owner_unavailable), do: "control_not_held"
  defp descriptor_refusal(_reason), do: "internal_failure"

  # Concept: the mutation's core call runs in the relay task and is
  # classified into exactly one wire answer; `writer_epoch` authorized it and
  # never reaches core.
  defp mutation_task(state, entry) do
    attachment = state.attachment && state.attachment.attachment
    command = command_for(entry.operation, entry.fields)
    request_id = entry.request_id
    method = entry.method
    fatal_recipient = Map.get(state.context, :fatal_recipient)
    fn -> run_mutation(attachment, command, request_id, method, fatal_recipient) end
  end

  defp run_mutation(nil, _command, request_id, _method, _fatal_recipient),
    do: {:refused, WireRecords.request_error(request_id, "control_not_held")}

  defp run_mutation(attachment, command, request_id, method, fatal_recipient) do
    case Loopex.Runtime.command_for_daemon(attachment, command) do
      {:routed, _route, {:accepted, accepted_id}} ->
        {:accepted, WireRecords.admission(request_id, method, accepted_id, :accepted)}

      {:routed, _route, {:error, :commit_unknown}} ->
        {:admission_unknown, WireRecords.succession_error(request_id, "admission_unknown")}

      {:routed, _route, {:error, reason}} ->
        refused = {:refused, reason_word(reason)}
        {:refused, WireRecords.admission(request_id, method, command.command_id, refused)}

      {:error, {:admission_unknown, _route}} ->
        {:admission_unknown, WireRecords.succession_error(request_id, "admission_unknown")}

      {:error, {:superseded_before_admission, _route}} ->
        {:refused, WireRecords.request_error(request_id, "control_not_held")}

      {:error, {:attachment_route_invalidated, _attachment_id, _incarnation}} ->
        {:refused, WireRecords.request_error(request_id, "control_not_held")}

      {:error, :session_unavailable} ->
        {:refused, WireRecords.request_error(request_id, "session_unavailable")}

      {:error, :runtime_unavailable} ->
        if is_pid(fatal_recipient),
          do: send(fatal_recipient, {:daemon_component_fatal, self(), :runtime_lost})

        {:admission_unknown, WireRecords.succession_error(request_id, "admission_unknown")}

      # A reply outside the typed set cannot show the command was not
      # admitted, so the client is told the outcome is unknown and to retry
      # with the same command identity, never that it was refused.
      _unexpected ->
        Logger.debug("loopex daemon mutation reply outside the typed set")
        {:admission_unknown, WireRecords.succession_error(request_id, "admission_unknown")}
    end
  end

  defp command_for(:session_prompt, fields),
    do: %{type: :prompt, command_id: fields.command_id, content: fields.content}

  defp command_for(:session_follow_up, fields),
    do: %{type: :follow_up, command_id: fields.command_id, content: fields.content}

  defp command_for(:session_steer, fields) do
    %{
      type: :steer,
      command_id: fields.command_id,
      content: fields.content,
      run_id: fields.run_id
    }
  end

  defp command_for(:session_abort, fields), do: %{type: :abort, command_id: fields.command_id}

  defp command_for(:session_respond_interaction, fields) do
    %{
      type: :interaction_answer,
      command_id: fields.command_id,
      interaction_id: fields.interaction_id,
      choice_id: fields.choice_id
    }
  end

  defp command_for(:session_admit_resources, fields) do
    %{
      type: :admit_resources,
      command_id: fields.command_id,
      manifest_digest: fields.manifest_digest,
      decision: fields.decision
    }
  end

  defp command_for(:session_activate_skill, fields) do
    %{
      type: :activate_skill,
      command_id: fields.command_id,
      manifest_digest: fields.manifest_digest,
      pack_digest: fields.pack_digest,
      source_id: fields.source_id,
      name: fields.name,
      supporting_labels: fields.supporting_labels
    }
  end

  # Concept: a governed resume activates through the relay task, which
  # classifies both the lease disposition and whether core started a
  # coordinator.
  defp resume_task(context, request_id, session_id, command_id) do
    runtime = context.runtime
    fatal_recipient = Map.get(context, :fatal_recipient)
    connection = self()

    fn ->
      case Loopex.Runtime.resume_session_detailed(runtime, session_id, command_id) do
        {:ok, %{session_id: resumed, disposition: disposition}} ->
          if disposition == :activated, do: publish_session(context, connection, resumed)

          {:accepted, disposition,
           WireRecords.admission(request_id, "session.resume", command_id, :accepted, resumed)}

        {:error, :runtime_placement_mismatch, %{disposition: disposition}} ->
          {:refused, disposition, WireRecords.request_error(request_id, "composition_mismatch")}

        {:error, :commit_unknown, %{disposition: disposition}} ->
          {:admission_unknown, disposition,
           WireRecords.succession_error(request_id, "admission_unknown")}

        {:error, :recovery_required, %{disposition: disposition}} ->
          {:refused, disposition, WireRecords.request_error(request_id, "recovery_required")}

        {:error, reason, %{disposition: disposition}} ->
          refused = {:refused, reason_word(reason)}

          {:refused, disposition,
           WireRecords.admission(request_id, "session.resume", command_id, refused)}

        {:error, :runtime_unavailable} ->
          if is_pid(fatal_recipient),
            do: send(fatal_recipient, {:daemon_component_fatal, self(), :runtime_lost})

          {:admission_unknown, :no_activation,
           WireRecords.succession_error(request_id, "admission_unknown")}

        _unexpected ->
          Logger.debug("loopex daemon resume reply outside the typed set")

          {:admission_unknown, :no_activation,
           WireRecords.succession_error(request_id, "admission_unknown")}
      end
    end
  end

  # Concept: a session this daemon activated becomes discoverable, but a
  # failure to record it never makes it unusable. Only an invocation that
  # started the coordinator proves this daemon's placement for the session, so
  # a replay, an already-active answer or a concurrent activation publishes
  # nothing.
  #
  # Technical depth: the index row is written through its one owner; a write
  # failure tells the causing client with `daemon.notice`. The compatibility
  # directory entry is best effort with a fixed, identity-free warning.
  defp publish_session(context, connection, session_id) do
    case Map.get(context, :index) do
      nil ->
        :ok

      index ->
        case safe_index_record(index, session_id, Map.get(context, :placement_identity)) do
          {:error, :index_write_failed} ->
            send(connection, {:daemon_notice, WireRecords.index_write_failed(session_id)})

          _recorded_or_full ->
            :ok
        end
    end

    case {Map.get(context, :state_root), Map.get(context, :placement_identity)} do
      {root, placement} when is_binary(root) and is_binary(placement) ->
        case Loopex.track_session(root, session_id, placement) do
          :ok ->
            :ok

          {:error, _reason} ->
            Logger.warning("loopex daemon compatibility session entry not written")
        end

      _unconfigured ->
        :ok
    end
  end

  defp safe_index_record(index, session_id, placement) when is_binary(placement) do
    LoopexDaemon.SessionIndex.record(index, session_id, placement)
  catch
    :exit, _reason -> {:error, :index_write_failed}
  end

  defp safe_index_record(_index, _session_id, _placement), do: :ok

  defp reason_word(reason) when is_atom(reason) and not is_nil(reason),
    do: Atom.to_string(reason)

  defp reason_word(_reason), do: "internal_failure"

  # Concept: a permit opens and binds its worker by relay request messages,
  # exactly as a ticket does; the worker starts only once the permit exists
  # and waits for the relay's `go` before running.
  defp begin_permit(state, request, class, session_id, fun) do
    case RequestLedger.begin(state.ledger, request.request_id, new_entry(request, :opening)) do
      {:ok, origin, ledger} ->
        request_id =
          AdmissionRelay.open_permit_request(state.context.relay, origin, class, session_id)

        state = %{state | ledger: ledger}
        {:ok, await_exchange(state, request_id, :relay, {:open_permit, origin, fun})}

      {:error, :duplicate_request} ->
        reply(state, WireRecords.invalid_request(request.request_id, "duplicate_request"))

      {:error, :capacity_exceeded} ->
        reply(state, WireRecords.request_error(request.request_id, "capacity_exceeded"))
    end
  end

  defp query_fun(context, %Request{operation: :session_inspect} = request) do
    runtime = context.runtime
    %{request_id: request_id, method: method, fields: %{session_id: session_id}} = request

    fn ->
      case runtime_call(fn -> Loopex.Runtime.session_status(runtime, session_id) end) do
        {:ok, status} ->
          WireRecords.result(request_id, method, WireRecords.session_status(status))

        {:error, reason} ->
          query_refusal(request_id, reason)
      end
    end
  end

  defp query_fun(context, %Request{operation: :resources_catalog} = request) do
    runtime = context.runtime
    %{request_id: request_id, method: method, fields: %{session_id: session_id}} = request

    fn ->
      case runtime_call(fn -> Loopex.Runtime.resource_catalog(runtime, session_id) end) do
        {:ok, catalog} -> WireRecords.result(request_id, method, catalog)
        {:error, reason} -> query_refusal(request_id, reason)
      end
    end
  end

  defp query_fun(context, %Request{operation: :resources_read} = request) do
    runtime = context.runtime
    %{request_id: request_id, method: method, fields: fields} = request
    read = Map.take(fields, [:manifest_digest, :source_id, :name, :label])

    fn ->
      case runtime_call(fn -> Loopex.Runtime.read_resource(runtime, fields.session_id, read) end) do
        {:ok, resource} ->
          WireRecords.result(request_id, method, WireRecords.resource_read(resource))

        {:error, reason} ->
          query_refusal(request_id, reason)
      end
    end
  end

  defp query_refusal(request_id, :session_unavailable),
    do: WireRecords.request_error(request_id, "session_unavailable")

  defp query_refusal(request_id, :runtime_unavailable),
    do: WireRecords.request_error(request_id, "internal_failure")

  defp query_refusal(request_id, reason), do: WireRecords.facade_unavailable(request_id, reason)

  defp transfer_fun(attachment, %Request{operation: :artifact_open_transfer} = request) do
    %{request_id: request_id, method: method, fields: fields} = request
    reference = fields.reference

    open =
      %{
        object: %{digest: reference.digest, size: reference.size, locator: reference.locator},
        use_locator: reference.use_locator,
        start: fields.start_offset
      }
      |> then(fn open ->
        if fields.window_length, do: Map.put(open, :length, fields.window_length), else: open
      end)

    fn ->
      case runtime_call(fn -> Loopex.Runtime.open_artifact_transfer(attachment, open) end) do
        {:ok, transfer} ->
          WireRecords.result(request_id, method, WireRecords.transfer_opened(transfer))

        {:error, reason} ->
          WireRecords.transfer_refused(request_id, reason)
      end
    end
  end

  defp transfer_fun(attachment, %Request{operation: :artifact_read_chunk} = request) do
    %{request_id: request_id, method: method, fields: fields} = request

    fn ->
      case runtime_call(fn ->
             Loopex.Runtime.read_artifact_chunk(attachment, fields.transfer_ref, fields.length)
           end) do
        {:ok, chunk} -> WireRecords.result(request_id, method, WireRecords.transfer_chunk(chunk))
        {:error, reason} -> WireRecords.transfer_refused(request_id, reason)
      end
    end
  end

  defp transfer_fun(attachment, %Request{operation: :artifact_close_transfer} = request) do
    %{request_id: request_id, method: method, fields: fields} = request

    fn ->
      case runtime_call(fn ->
             Loopex.Runtime.close_artifact_transfer(attachment, fields.transfer_ref)
           end) do
        :ok -> WireRecords.result(request_id, method, %{"closed" => true})
        {:error, reason} -> WireRecords.transfer_refused(request_id, reason)
      end
    end
  end

  # Concept: the listing says what the daemon index records and what this
  # daemon knows about each row, and never reads the Store to say more.
  defp list_fun(state, request) do
    %{request_id: request_id, method: method, fields: fields} = request
    index = Map.get(state.context, :index)
    registry = state.registry

    fn ->
      page =
        if is_nil(index),
          do: {:ok, %{entries: [], index_full: false}},
          else: LoopexDaemon.SessionIndex.page(index, fields.after_session_id, fields.limit)

      case page do
        {:ok, page} ->
          ids = Enum.map(page.entries, & &1.session_id)
          facts = ConnectionRegistry.session_facts(registry, ids)
          WireRecords.result(request_id, method, WireRecords.session_page(page, facts))

        {:error, _reason} ->
          WireRecords.request_error(request_id, "internal_failure")
      end
    end
  end

  defp status_fun(state, request) do
    %{request_id: request_id, method: method} = request
    context = state.context
    registry = state.registry

    fn ->
      registry_status = ConnectionRegistry.status(registry)

      index_status =
        case Map.get(context, :index) do
          nil -> %{entries: 0, limit: 4_096, full: false}
          index -> LoopexDaemon.SessionIndex.status(index)
        end

      WireRecords.result(
        request_id,
        method,
        WireRecords.daemon_status(context, registry_status, index_status)
      )
    end
  end

  # Concept: a core call made from a request worker reports core loss as a
  # plain result instead of exiting the worker.
  defp runtime_call(fun) do
    fun.()
  catch
    :exit, _reason -> {:error, :runtime_unavailable}
  end
end
