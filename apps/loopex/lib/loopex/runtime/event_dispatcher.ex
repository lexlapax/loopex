defmodule Loopex.Runtime.EventDispatcher do
  @moduledoc """
  ## Concept

  The runtime-local delivery process for committed public events and transient
  planes. It reads the Store outbox as truth, owns finite attachment queues, and
  disconnects a slow caller without delaying session commits.

  ## Technical depth

  Attach, consumption, and status operations scan after each attachment's last
  fetched durable sequence; mutation replies are not a publication channel.
  Store-stamped event maps are queued unchanged. A queue never exceeds its
  configured capacity; the first live event that cannot fit disconnects the
  attachment at its last consumed sequence. Historical replay from a supplied
  cursor is paged lazily so a reconnecting caller can drain more than one
  queueful without a false overflow.

  Attachments, queued events and diagnostics are redacted from OTP
  status and disappear on dispatcher restart. The same durable outbox rows can
  then be attached and delivered again with identical IDs and sequences.

  Publication is fenced at the acknowledged position. A durable outbox row is
  delivered only once `Loopex.Runtime.Control` has recorded the commit that
  produced it as resolved, so a session whose owner is holding an unresolved
  `commit_unknown` publishes nothing from that transaction until the
  re-presentation settles. The fence binds both paths that reach the outbox: an
  attaching caller's snapshot scan stops at the same acknowledged position, so
  its anchor never reports run state derived from a row no consumer may yet
  read, and the attachment's first read starts there rather than at the durable
  tail. A session with no current owner in this runtime
  carries no fence, because no transaction of this runtime's is outstanding
  against it and its durable outbox is already reconstructed truth.
  """

  use GenServer

  alias Loopex.ArtifactStore
  alias Loopex.Instrumentation
  alias Loopex.Runtime.DiagnosticsAdmission
  alias Loopex.Runtime.Supervisor, as: RuntimeSupervisor
  alias Loopex.Runtime.SessionState
  alias Loopex.Store

  @max_page 1_024
  @max_transient_items 128
  @max_transient_bytes 65_536

  @doc """
  ## Concept

  Starts one unnamed dispatcher with an explicit Store and bounded capacity.

  ## Technical depth

  Optional diagnostic sinks receive best-effort messages through
  ordinary `send/2`; their mailbox state is outside the runtime and never a
  coordinator barrier.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options) when is_list(options), do: GenServer.start_link(__MODULE__, options)

  @doc false
  @spec stage_attachment(pid(), pid(), reference(), map()) :: :ok
  def stage_attachment(dispatcher, control, attach_ref, transaction)
      when is_pid(dispatcher) and is_pid(control) and is_reference(attach_ref) and
             is_map(transaction) do
    send(dispatcher, {:stage_attachment, control, attach_ref, transaction})
    :ok
  end

  @doc false
  @spec authorize_attachment(pid(), reference(), pid(), reference(), binary(), binary()) :: :ok
  def authorize_attachment(
        dispatcher,
        dispatcher_incarnation,
        control,
        attach_ref,
        attachment_id,
        incarnation_id
      )
      when is_pid(dispatcher) and is_reference(dispatcher_incarnation) and is_pid(control) and
             is_reference(attach_ref) do
    send(
      dispatcher,
      {:authorize_attachment, dispatcher_incarnation, control, attach_ref, attachment_id,
       incarnation_id}
    )

    :ok
  end

  @doc false
  @spec discard_staged_attachment(pid(), reference(), pid(), reference()) :: :ok
  def discard_staged_attachment(dispatcher, dispatcher_incarnation, control, attach_ref)
      when is_pid(dispatcher) and is_reference(dispatcher_incarnation) and is_pid(control) and
             is_reference(attach_ref) do
    send(
      dispatcher,
      {:discard_staged_attachment, dispatcher_incarnation, control, attach_ref}
    )

    :ok
  end

  @doc false
  @spec remove_published_attachment(
          pid(),
          reference(),
          pid(),
          reference(),
          binary(),
          binary()
        ) :: :ok
  def remove_published_attachment(
        dispatcher,
        dispatcher_incarnation,
        control,
        attach_ref,
        attachment_id,
        incarnation_id
      )
      when is_pid(dispatcher) and is_reference(dispatcher_incarnation) and is_pid(control) and
             is_reference(attach_ref) do
    send(
      dispatcher,
      {:remove_published_attachment, dispatcher_incarnation, control, attach_ref, attachment_id,
       incarnation_id}
    )

    :ok
  end

  @doc false
  @spec validate(pid(), reference(), binary(), binary(), binary()) :: :ok | {:error, term()}
  def validate(dispatcher, token, session_id, attachment_id, incarnation_id) do
    try do
      GenServer.call(
        dispatcher,
        {:validate_attachment, token, session_id, attachment_id, incarnation_id}
      )
    catch
      :exit, _reason -> {:error, :dispatcher_unavailable}
    end
  end

  @doc false
  @spec invalidate(pid(), binary()) :: :ok
  def invalidate(root, session_id) when is_pid(root) and is_binary(session_id) do
    case RuntimeSupervisor.children(root) do
      {:ok, %{dispatcher: dispatcher}} -> GenServer.cast(dispatcher, {:invalidate, session_id})
      _other -> :ok
    end
  end

  @doc false
  @spec invalidate_session(pid(), binary()) :: {:ok, [map()]} | {:error, :dispatcher_unavailable}
  def invalidate_session(dispatcher, session_id)
      when is_pid(dispatcher) and is_binary(session_id) do
    try do
      GenServer.call(dispatcher, {:invalidate_session, session_id}, :infinity)
    catch
      :exit, _reason -> {:error, :dispatcher_unavailable}
    end
  end

  @doc false
  @spec release_attachment(pid(), binary(), binary()) :: :ok
  def release_attachment(dispatcher, attachment_id, incarnation_id)
      when is_pid(dispatcher) and is_binary(attachment_id) and is_binary(incarnation_id) do
    try do
      GenServer.call(
        dispatcher,
        {:release_attachment, attachment_id, incarnation_id},
        :infinity
      )
    catch
      :exit, _reason -> :ok
    end
  end

  @doc false
  @spec release_holder(pid(), pid()) :: :ok
  def release_holder(dispatcher, holder) when is_pid(dispatcher) and is_pid(holder) do
    try do
      GenServer.call(dispatcher, {:release_holder, holder}, :infinity)
    catch
      :exit, _reason -> :ok
    end
  end

  # Concept: the position public delivery is allowed to reach.
  #
  # Technical depth: Control pushes this rather than the dispatcher pulling it,
  # because Control already calls into the dispatcher while handling
  # `route_command`, and a dispatcher that called Control back would close a
  # two-process cycle that one busy session could deadlock.
  #
  # It is a call rather than a cast, and it has to be. A caller told that its
  # command was accepted may read the events that command produced immediately,
  # and message order between Control and that caller is undefined, so a cast
  # leaves a window in which the fence withholds rows whose commit has already
  # resolved -- indistinguishable, to that reader, from a session that produced
  # nothing. Waiting here closes the window: the watermark is installed before
  # the commit's own reply travels. The wait is unbounded for the same reason
  # `Loopex.Runtime.Control.post_commit/5` is, and the reason is sharper here: a
  # deadline would leave the watermark behind durable truth permanently rather
  # than briefly, withholding every later row of that session for a commit that
  # in fact resolved.
  @doc false
  @spec acknowledge(pid(), binary(), non_neg_integer()) :: :ok
  def acknowledge(root, session_id, position)
      when is_pid(root) and is_binary(session_id) and is_integer(position) and position >= 0 do
    case RuntimeSupervisor.children(root) do
      {:ok, %{dispatcher: dispatcher}} ->
        try do
          GenServer.call(dispatcher, {:acknowledge, session_id, position}, :infinity)
        catch
          :exit, _reason -> :ok
        end

      _other ->
        :ok
    end
  end

  # Concept: a session this runtime no longer owns is no longer fenced by it.
  #
  # Technical depth: the fence exists to withhold rows one live owner has not
  # resolved. Once that owner is gone, the durable outbox is the only truth left
  # and a successor reconstructs from it, so retaining a stale watermark would
  # withhold committed history from every later reader for no protection.
  @doc false
  @spec release_fence(pid(), binary()) :: :ok
  def release_fence(root, session_id) when is_pid(root) and is_binary(session_id) do
    case RuntimeSupervisor.children(root) do
      {:ok, %{dispatcher: dispatcher}} ->
        GenServer.cast(dispatcher, {:release_fence, session_id})

      _other ->
        :ok
    end
  end

  @impl GenServer
  def init(options) do
    Process.flag(:trap_exit, true)

    incarnation = make_ref()

    {:ok,
     %{
       root: Keyword.fetch!(options, :root),
       token: Keyword.fetch!(options, :token),
       status: :initializing,
       incarnation: incarnation,
       registration_worker: nil,
       store: Keyword.fetch!(options, :store),
       capacity: Keyword.fetch!(options, :attachment_capacity),
       diagnostics_to: Keyword.fetch!(options, :diagnostics_to),
       attachments: %{},
       holders: %{},
       holder_monitors: %{},
       staged_attachments: %{},
       pending_reads: %{},
       read_monitors: %{},
       acknowledged: %{},
       admission: DiagnosticsAdmission.new(diagnostics_ceiling(options)),
       diagnostic_monitors: %{},
       drop_window_start: 0,
       artifact_store: Keyword.get(options, :artifact_store),
       transfer_limits: ArtifactStore.transfer_limits(),
       artifact_transfers: %{},
       artifact_monitors: %{}
     }, {:continue, :register_dispatcher}}
  end

  @impl GenServer
  def handle_continue(:register_dispatcher, state) do
    dispatcher = self()
    root = state.root
    token = state.token
    incarnation = state.incarnation

    worker =
      spawn_link(fn ->
        dispatcher_registration_worker(root, token, dispatcher, incarnation)
      end)

    registration_worker = %{pid: worker, monitor: Process.monitor(worker)}
    {:noreply, %{state | registration_worker: registration_worker}}
  end

  @impl GenServer
  def handle_call({:invalidate_session, session_id}, _from, state) do
    {removed, next} = invalidate_session_state(state, session_id)
    {:reply, {:ok, removed}, next}
  end

  def handle_call({:release_attachment, attachment_id, incarnation_id}, _from, state) do
    next =
      case Map.get(state.attachments, attachment_id) do
        %{incarnation_id: ^incarnation_id} -> drop_attachment(state, attachment_id)
        _other -> state
      end

    {:reply, :ok, next}
  end

  def handle_call({:release_holder, holder}, _from, state) do
    {:reply, :ok, drop_holder(state, holder, :holder_released)}
  end

  def handle_call(
        {:validate_attachment, token, session_id, attachment_id, incarnation_id},
        _from,
        state
      ) do
    {:reply, validate_attachment(state, token, session_id, attachment_id, incarnation_id), state}
  end

  def handle_call(
        {operation, token, session_id, attachment_id, incarnation_id, call_id},
        from,
        state
      )
      when operation in [:next_event, :attachment_status] do
    case fetch_attachment(state, token, session_id, attachment_id, incarnation_id) do
      {:ok, attachment} ->
        case Map.fetch(state.pending_reads, attachment_id) do
          {:ok, pending} ->
            {:reply, {:wait_for_attachment_read, pending.worker}, state}

          :error ->
            call = %{
              operation: operation,
              from: from,
              monitor: Process.monitor(elem(from, 0)),
              id: call_id
            }

            {:noreply, start_read(state, attachment, call)}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:diagnostic, token, item}, _from, state) do
    reply =
      if token == state.token and plain_transient?(item) do
        maybe_send(state.diagnostics_to, {:loopex_diagnostic, item})
        :ok
      else
        {:error, :invalid_diagnostic}
      end

    {:reply, reply, state}
  end

  # Concept: a sender on the asynchronous plane needs this runtime's admission
  # handle before it can claim a slot.
  #
  # Technical depth: the handle is plain data -- a table identifier, an atomics
  # reference, the ceiling and this dispatcher's pid -- and grants nothing but
  # the ability to offer an item that may be dropped. It is fetched through the
  # token-checked call, so a process without the runtime reference cannot reach
  # the plane at all.
  # Concept: attachment authority admits one original, bounded storage custodian.
  # Technical depth: callbacks run outside this serial owner. Pending, live and
  # retiring entries retain capacity, the original clock and both original
  # monitors, including after attachment removal. No callback result alone
  # proves retirement or releases credit.
  def handle_call(
        {:open_transfer, token, session_id, attachment_id, incarnation_id, request, context},
        from,
        state
      ) do
    with {:ok, attachment} <-
           fetch_attachment(state, token, session_id, attachment_id, incarnation_id),
         :active <- attachment.status,
         true <- ArtifactStore.valid_transfer_request?(request),
         true <- request.session_id === session_id,
         true <- ArtifactStore.valid_open_context?(context),
         true <- artifact_now() < context.open_deadline_ms,
         false <- Map.has_key?(state.artifact_transfers, context.transfer_ref),
         {:ok, store} <- artifact_store(state),
         :ok <- transfer_headroom(attachment, state),
         {:ok, state} <-
           reserve_connection_work(state, attachment.holder, open_work_reservation(state)) do
      {:noreply, begin_artifact_open(state, attachment, store, request, context, from)}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
      _other -> {:reply, {:error, :invalid_artifact_request}, state}
    end
  end

  def handle_call(
        {:read_transfer, token, session_id, attachment_id, incarnation_id, transfer_ref, length,
         deadline},
        from,
        state
      ) do
    with {:ok, attachment} <-
           fetch_attachment(state, token, session_id, attachment_id, incarnation_id),
         {:ok, %{phase: :live, invocation: :idle, read: nil} = entry} <-
           Map.fetch(state.artifact_transfers, transfer_ref),
         true <- artifact_entry_attachment?(entry, attachment),
         :ok <- validate_artifact_read_length(length),
         true <- is_integer(deadline) and artifact_now() < deadline,
         wanted =
           min(
             length,
             min(
               state.transfer_limits.chunk_bytes,
               entry.transfer.window_start + entry.transfer.window_length - entry.cursor
             )
           ),
         {:ok, state} <- reserve_connection_work(state, entry.holder, wanted) do
      read_id = make_ref()

      timer =
        Process.send_after(
          self(),
          {:artifact_read_expired, transfer_ref, read_id},
          max(0, deadline - artifact_now())
        )

      read = %{
        id: read_id,
        from: from,
        deadline: deadline,
        reserved: wanted,
        timer: timer,
        invocation_started_at: artifact_now()
      }

      send(
        entry.custodian,
        {:artifact_read, self(), transfer_ref, read_id, entry.transfer, length}
      )

      entry = %{entry | read: read, invocation: {:read, read_id}}
      {:noreply, put_artifact_entry(state, entry)}
    else
      :error -> {:reply, {:error, :unknown_transfer}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
      _other -> {:reply, {:error, :unknown_transfer}, state}
    end
  end

  def handle_call(
        {:close_transfer, token, session_id, attachment_id, incarnation_id, transfer_ref, anchor},
        from,
        state
      ) do
    with {:ok, attachment} <-
           fetch_attachment(state, token, session_id, attachment_id, incarnation_id),
         {:ok, entry} <- Map.fetch(state.artifact_transfers, transfer_ref),
         true <- artifact_entry_attachment?(entry, attachment),
         true <- is_integer(anchor) and anchor <= artifact_now(),
         true <- is_nil(entry.close_from) do
      expired = entry.cleanup != nil and artifact_now() >= entry.cleanup.close_deadline_ms
      if expired, do: GenServer.reply(from, {:error, :cleanup_unproved})
      entry = %{entry | close_from: if(expired, do: nil, else: from)}

      state =
        state |> put_artifact_entry(entry) |> retire_artifact(transfer_ref, :cancelled, anchor)

      {:noreply, observe_artifact_retirement(state, transfer_ref)}
    else
      :error -> {:reply, {:error, :unknown_transfer}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
      _other -> {:reply, {:error, :cleanup_unproved}, state}
    end
  end

  def handle_call({:diagnostics_admission, token}, _from, state) do
    if token == state.token do
      {:reply, {:ok, state.admission}, state}
    else
      {:reply, {:error, :invalid_diagnostic}, state}
    end
  end

  def handle_call({:acknowledge, session_id, position}, _from, state) do
    acknowledged = Map.update(state.acknowledged, session_id, position, &max(&1, position))
    {:reply, :ok, %{state | acknowledged: acknowledged}}
  end

  @impl GenServer
  def handle_cast({:cancel_attachment_read, attachment_id, call_id}, state) do
    case Map.fetch(state.pending_reads, attachment_id) do
      {:ok, %{current: %{id: ^call_id}} = pending} ->
        Process.exit(pending.worker, :kill)
        reply_read(pending.current, {:error, :runtime_unavailable})
        {:noreply, remove_read(state, attachment_id, pending)}

      _other ->
        {:noreply, state}
    end
  end

  def handle_cast(
        {:cancel_artifact_open, token, session, attachment, incarnation, context},
        state
      ) do
    case if(ArtifactStore.valid_open_context?(context),
           do: Map.get(state.artifact_transfers, context.transfer_ref),
           else: nil
         ) do
      %{
        context: ^context,
        session_id: ^session,
        attachment_id: ^attachment,
        incarnation_id: ^incarnation
      }
      when token === state.token ->
        anchor = min(artifact_now(), context.open_deadline_ms)
        {:noreply, retire_artifact(state, context.transfer_ref, :cancelled, anchor)}

      _other ->
        {:noreply, state}
    end
  end

  def handle_cast(
        {:cancel_artifact_read, token, session, attachment, incarnation, transfer_ref, deadline},
        state
      ) do
    case Map.get(state.artifact_transfers, transfer_ref) do
      %{
        session_id: ^session,
        attachment_id: ^attachment,
        incarnation_id: ^incarnation,
        read: %{deadline: ^deadline}
      }
      when token === state.token ->
        {:noreply, retire_artifact(state, transfer_ref, :cancelled, deadline)}

      _other ->
        {:noreply, state}
    end
  end

  def handle_cast({:release_fence, session_id}, state),
    do: {:noreply, %{state | acknowledged: Map.delete(state.acknowledged, session_id)}}

  def handle_cast({:invalidate, session_id}, state) do
    {_removed, next} = invalidate_session_state(state, session_id)
    {:noreply, next}
  end

  @impl GenServer
  def handle_info(
        {:dispatcher_seed, worker, incarnation, registration_ref, seed},
        %{
          status: :initializing,
          incarnation: incarnation,
          registration_worker: %{pid: worker}
        } = state
      )
      when is_reference(registration_ref) and is_map(seed) do
    acknowledged =
      Map.merge(state.acknowledged, seed, fn _session_id, current, seeded ->
        max(current, seeded)
      end)

    send(worker, {:dispatcher_seeded, self(), incarnation, registration_ref})
    {:noreply, %{state | acknowledged: acknowledged}}
  end

  def handle_info(
        {:dispatcher_ready_token, worker, incarnation, registration_ref, ready_token, control},
        %{
          status: :initializing,
          incarnation: incarnation,
          registration_worker: %{pid: worker}
        } = state
      )
      when is_reference(registration_ref) and is_reference(ready_token) and is_pid(control) do
    send(
      control,
      {:dispatcher_ready, self(), incarnation, registration_ref, ready_token}
    )

    {:noreply, %{state | status: :ready}}
  end

  def handle_info(
        {:dispatcher_registration_failed, worker, incarnation},
        %{incarnation: incarnation, registration_worker: %{pid: worker}} = state
      ) do
    {:stop, :dispatcher_registration_failed, state}
  end

  def handle_info({:stage_attachment, control, attach_ref, transaction}, state) do
    with true <- is_pid(control),
         true <- state.status == :ready,
         true <- is_reference(attach_ref),
         %{
           session_id: session_id,
           holder: holder,
           options: options,
           id: id,
           incarnation_id: incarnation_id,
           dispatcher_incarnation: dispatcher_incarnation
         } <- transaction,
         true <- dispatcher_incarnation == state.incarnation,
         true <- is_binary(session_id),
         true <- is_pid(holder),
         true <- is_list(options),
         true <- is_binary(id),
         true <- is_binary(incarnation_id),
         true <- Process.alive?(holder),
         false <- Map.has_key?(state.staged_attachments, attach_ref) do
      parent = self()
      scan_state = %{store: state.store, acknowledged: Map.take(state.acknowledged, [session_id])}
      bound = scan_bound(state, session_id)
      capacity = state.capacity

      worker =
        spawn_link(fn ->
          result =
            prepare_staged_scan(scan_state, transaction, bound, capacity)

          send(parent, {:staged_attachment_scan_finished, attach_ref, self(), result})
        end)

      pending =
        transaction
        |> Map.merge(%{
          attach_ref: attach_ref,
          control: control,
          worker: worker,
          phase: :scanning
        })

      next =
        state
        |> register_holder_pending(holder, attach_ref)
        |> Map.put(
          :staged_attachments,
          Map.put(state.staged_attachments, attach_ref, pending)
        )

      {:noreply, next}
    else
      _other ->
        send(
          control,
          {:attachment_stage_failed, self(), state.incarnation, attach_ref, :holder_unavailable}
        )

        {:noreply, state}
    end
  end

  def handle_info(
        {:staged_attachment_scan_finished, attach_ref, worker, result},
        state
      ) do
    case Map.get(state.staged_attachments, attach_ref) do
      %{worker: ^worker, phase: :scanning} = pending ->
        case result do
          {:ok, attachment, response} ->
            if holder_pending?(state, pending) do
              staged =
                pending
                |> Map.put(:phase, :staged)
                |> Map.put(:attachment, attachment)
                |> Map.put(:response, response)

              send(
                pending.control,
                {:attachment_staged, self(), state.incarnation, attach_ref, attachment.id,
                 attachment.incarnation_id, response}
              )

              {:noreply,
               %{
                 state
                 | staged_attachments: Map.put(state.staged_attachments, attach_ref, staged)
               }}
            else
              send(
                pending.control,
                {:attachment_stage_failed, self(), state.incarnation, attach_ref,
                 :holder_unavailable}
              )

              {:noreply, drop_staged_attachment(state, attach_ref)}
            end

          {:error, reason} ->
            send(
              pending.control,
              {:attachment_stage_failed, self(), state.incarnation, attach_ref, reason}
            )

            {:noreply, drop_staged_attachment(state, attach_ref)}
        end

      _other ->
        {:noreply, state}
    end
  end

  def handle_info(
        {:authorize_attachment, dispatcher_incarnation, control, attach_ref, attachment_id,
         incarnation_id},
        state
      ) do
    case {dispatcher_incarnation == state.incarnation,
          Map.get(state.staged_attachments, attach_ref)} do
      {true,
       %{
         control: ^control,
         phase: :staged,
         id: ^attachment_id,
         incarnation_id: ^incarnation_id
       } = pending} ->
        with true <- holder_pending?(state, pending),
             {:ok, prepared} <- prepare_replacement(state, pending) do
          attachment = pending.attachment

          next =
            prepared
            |> Map.put(
              :staged_attachments,
              Map.delete(prepared.staged_attachments, attach_ref)
            )
            |> Map.put(
              :attachments,
              Map.put(prepared.attachments, attachment_id, attachment)
            )
            |> finish_holder_pending(pending.holder, attach_ref, attachment_id)

          send(
            control,
            {:attachment_published, self(), state.incarnation, attach_ref, attachment_id,
             incarnation_id, pending.response}
          )

          {:noreply, next}
        else
          false ->
            send(
              control,
              {:attachment_stage_failed, self(), state.incarnation, attach_ref,
               :holder_unavailable}
            )

            {:noreply, drop_staged_attachment(state, attach_ref)}

          {:error, reason} ->
            send(
              control,
              {:attachment_stage_failed, self(), state.incarnation, attach_ref, reason}
            )

            {:noreply, drop_staged_attachment(state, attach_ref)}
        end

      _other ->
        send(
          control,
          {:attachment_stage_failed, self(), state.incarnation, attach_ref,
           :attachment_superseded}
        )

        {:noreply, state}
    end
  end

  def handle_info(
        {:discard_staged_attachment, dispatcher_incarnation, control, attach_ref},
        state
      ) do
    next =
      case {dispatcher_incarnation == state.incarnation,
            Map.get(state.staged_attachments, attach_ref)} do
        {true, %{control: ^control}} -> drop_staged_attachment(state, attach_ref)
        _other -> state
      end

    send(control, {:attachment_discarded, self(), state.incarnation, attach_ref})
    {:noreply, next}
  end

  def handle_info(
        {:remove_published_attachment, dispatcher_incarnation, control, attach_ref, attachment_id,
         incarnation_id},
        state
      ) do
    next =
      case {dispatcher_incarnation == state.incarnation,
            Map.get(state.attachments, attachment_id)} do
        {true, %{incarnation_id: ^incarnation_id}} -> drop_attachment(state, attachment_id)
        _other -> state
      end

    send(
      control,
      {:attachment_removed, self(), state.incarnation, attach_ref, attachment_id, incarnation_id}
    )

    {:noreply, next}
  end

  # Concept: one monitor per live sender on the asynchronous plane.
  #
  # Technical depth: a duplicate registration is ignored, and a registration
  # from a process that has already exited installs a monitor the VM resolves
  # at once, so the reconciliation below still runs for it.
  def handle_info({:loopex_diagnostic_monitor_me, pid}, state) when is_pid(pid) do
    {:noreply, monitor_sender(state, pid)}
  end

  # Concept: one admitted diagnostic item, forwarded and then released.
  #
  # Technical depth: the slot is freed once per admitted item, after the item
  # has been forwarded or discarded, with the exact triple the message carried.
  # The drop summary is published immediately after that release and therefore
  # before any further item this dispatcher forwards.
  def handle_info({:loopex_diagnostic_admission, pid, slot, ticket, item}, state) do
    state = forward_admitted(state, item)
    DiagnosticsAdmission.release(state.admission, slot, pid, ticket)
    {:noreply, report_drops(state)}
  end

  def handle_info(
        {:artifact_custodian_result, id, custodian, operation, result, completed_at},
        state
      )
      when is_integer(completed_at) do
    case Map.get(state.artifact_transfers, id) do
      %{custodian: ^custodian, invocation: ^operation} = entry ->
        entry = %{entry | invocation: :idle, callback_completed_at: completed_at}
        state = put_artifact_entry(state, entry)
        {:noreply, artifact_invocation_result(state, id, operation, result)}

      _other ->
        {:noreply, state}
    end
  end

  def handle_info({:artifact_observer_result, id, observer, operation, result}, state) do
    case Map.get(state.artifact_transfers, id) do
      %{observer: ^observer, observation: ^operation} = entry ->
        entry = %{entry | observation: :idle}
        state = put_artifact_entry(state, entry)
        {:noreply, artifact_observation_result(state, id, operation, result)}

      _other ->
        {:noreply, state}
    end
  end

  def handle_info({:artifact_open_expired, id}, state) do
    case Map.get(state.artifact_transfers, id) do
      %{phase: :live} ->
        {:noreply, state}

      %{context: context} ->
        state = retire_artifact(state, id, :open_deadline_exhausted, context.open_deadline_ms)

        {:noreply,
         reply_artifact_open(
           state,
           id,
           {:error, %{reason: :open_deadline_exhausted, cleanup: :unproved}}
         )}

      _other ->
        {:noreply, state}
    end
  end

  def handle_info({:artifact_close_expired, id}, state) do
    {:noreply, expire_artifact_cleanup(state, id)}
  end

  def handle_info({:artifact_lifetime_expired, id}, state) do
    case Map.get(state.artifact_transfers, id) do
      %{lifetime_deadline: deadline} when is_integer(deadline) ->
        {:noreply, retire_artifact(state, id, :cancelled, deadline)}

      _other ->
        {:noreply, state}
    end
  end

  def handle_info({:artifact_read_expired, id, read_id}, state) do
    case Map.get(state.artifact_transfers, id) do
      %{read: %{id: ^read_id} = read} = entry ->
        if read.from, do: GenServer.reply(read.from, {:error, :read_deadline_exhausted})
        entry = %{entry | read: %{read | from: nil}}

        {:noreply,
         state |> put_artifact_entry(entry) |> retire_artifact(id, :cancelled, read.deadline)}

      _other ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, monitor, :process, pid, reason}, state)
      when is_map_key(state.artifact_monitors, monitor) do
    {id, kind, original} = Map.fetch!(state.artifact_monitors, monitor)

    if pid === original do
      {:noreply, artifact_original_down(state, id, kind, reason)}
    else
      {:noreply, state}
    end
  end

  def handle_info(
        {:DOWN, monitor, :process, worker, _reason},
        %{registration_worker: %{pid: worker, monitor: monitor}} = state
      ) do
    if state.status == :ready do
      {:noreply, %{state | registration_worker: nil}}
    else
      {:stop, :dispatcher_registration_failed, state}
    end
  end

  def handle_info({:DOWN, monitor, :process, pid, _reason}, state)
      when is_map_key(state.diagnostic_monitors, pid) do
    if Map.fetch!(state.diagnostic_monitors, pid) == monitor do
      DiagnosticsAdmission.reconcile(state.admission, pid)

      {:noreply,
       report_drops(%{
         state
         | diagnostic_monitors: Map.delete(state.diagnostic_monitors, pid)
       })}
    else
      {:noreply, state}
    end
  end

  def handle_info({:DOWN, monitor, :process, holder, _reason}, state)
      when is_map_key(state.holder_monitors, monitor) do
    case Map.get(state.holder_monitors, monitor) do
      ^holder -> {:noreply, drop_holder(state, holder, :holder_unavailable)}
      _other -> {:noreply, state}
    end
  end

  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    {:noreply, cancel_read_caller(state, monitor)}
  end

  def handle_info({:EXIT, worker, _reason}, state) do
    case state.registration_worker do
      %{pid: ^worker, monitor: monitor} ->
        Process.demonitor(monitor, [:flush])

        if state.status == :ready do
          {:noreply, %{state | registration_worker: nil}}
        else
          {:stop, :dispatcher_registration_failed, state}
        end

      _other ->
        case Enum.find(state.staged_attachments, fn {_attach_ref, pending} ->
               pending.worker == worker and pending.phase == :scanning
             end) do
          {attach_ref, pending} ->
            send(
              pending.control,
              {:attachment_stage_failed, self(), state.incarnation, attach_ref,
               :store_unavailable}
            )

            {:noreply, drop_staged_attachment(state, attach_ref)}

          nil ->
            finish_read_worker_exit(state, worker)
        end
    end
  end

  def handle_info({:attachment_read_finished, id, read_id, attachment}, state) do
    case Map.fetch(state.pending_reads, id) do
      {:ok, %{read_id: ^read_id} = pending} ->
        {:noreply, finish_read(state, id, pending, attachment)}

      _other ->
        {:noreply, state}
    end
  end

  defp finish_read_worker_exit(state, worker) do
    case Enum.find(state.pending_reads, fn {_id, pending} -> pending.worker == worker end) do
      nil ->
        {:noreply, state}

      {id, pending} ->
        failed = disconnect(pending.attachment, :store_unavailable)
        {:noreply, finish_read(state, id, pending, failed)}
    end
  end

  @impl GenServer
  def format_status(status) do
    status
    |> Map.put(:state, :redacted_event_dispatcher_state)
    |> Map.put(:message, :redacted_event_dispatcher_message)
    |> Map.put(:reason, :redacted_event_dispatcher_reason)
    |> Map.put(:log, [])
  end

  # Concept: one slow attachment cannot hold the runtime's acknowledgement path.
  #
  # Technical depth: each attachment has at most one linked Store worker and
  # one retained caller. Concurrent callers wait in their own processes on that
  # worker, then retry through Runtime's private call protocol. The worker exits
  # only after its result is adopted or cancelled, so waiting carries no public
  # busy/empty result and no unbounded queue in the dispatcher. Only this process
  # adopts results against the captured incarnation and cursor.
  defp start_read(state, attachment, call) do
    if attachment.status == :active and publishable_limit(state, attachment) > 0 and
         (call.operation != :next_event or attachment.queue_depth == 0) do
      parent = self()
      read_id = make_ref()

      read_state = %{
        store: state.store,
        acknowledged: Map.take(state.acknowledged, [attachment.session_id])
      }

      worker =
        spawn_link(fn ->
          parent_monitor = Process.monitor(parent)
          result = pump(read_state, attachment)
          send(parent, {:attachment_read_finished, attachment.id, read_id, result})

          receive do
            {:read_adopted, ^read_id} -> Process.demonitor(parent_monitor, [:flush])
            {:DOWN, ^parent_monitor, :process, ^parent, _reason} -> :ok
          end
        end)

      pending = %{
        session_id: attachment.session_id,
        attachment: attachment,
        current: call,
        worker: worker,
        read_id: read_id,
        bound: scan_bound(state, attachment.session_id)
      }

      %{
        state
        | pending_reads: Map.put(state.pending_reads, attachment.id, pending),
          read_monitors: Map.put(state.read_monitors, call.monitor, attachment.id)
      }
    else
      {reply, next_attachment} = read_reply(call.operation, attachment)
      reply_read(call, reply)
      put_attachment(state, next_attachment)
    end
  end

  defp finish_read(state, id, pending, result) do
    case Map.fetch(state.attachments, id) do
      {:ok, current} when current == pending.attachment ->
        if current_read_fence?(state, pending) do
          answer_read(state, id, pending, result)
        else
          # A newly installed owner may have lowered an absent publication
          # fence. Re-read from the unchanged cursor under its current bound.
          start_read(remove_read(state, id, pending), current, pending.current)
        end

      _stale ->
        reply_read(pending.current, {:error, :stale_attachment})
        remove_read(state, id, pending)
    end
  end

  defp current_read_fence?(state, pending) do
    case {pending.bound, scan_bound(state, pending.session_id)} do
      {_prior, :unbounded} -> true
      {:unbounded, _current} -> false
      {prior, current} -> current >= prior
    end
  end

  defp answer_read(state, id, pending, attachment) do
    {reply, next_attachment} = read_reply(pending.current.operation, attachment)
    reply_read(pending.current, reply)
    remove_read(put_attachment(state, next_attachment), id, pending)
  end

  defp read_reply(:attachment_status, attachment) do
    status = Map.take(attachment, [:status, :cursor, :queue_depth, :max_queue_depth, :capacity])
    {{:ok, status}, attachment}
  end

  defp read_reply({:attach, installed}, attachment), do: {{:ok, installed}, attachment}

  defp read_reply(:next_event, %{status: :active} = attachment) do
    case :queue.out(attachment.queue) do
      {{:value, event}, queue} ->
        consumed = %{
          attachment
          | queue: queue,
            queue_depth: attachment.queue_depth - 1,
            cursor: event.event_sequence
        }

        {{:ok, event}, consumed}

      {:empty, _queue} ->
        {{:error, :empty}, attachment}
    end
  end

  defp read_reply(:next_event, attachment),
    do: {{:disconnected, attachment.cursor}, attachment}

  defp reply_read(call, reply) do
    Process.demonitor(call.monitor, [:flush])
    GenServer.reply(call.from, reply)
  end

  defp remove_read(state, id, pending) do
    send(pending.worker, {:read_adopted, pending.read_id})

    %{
      state
      | pending_reads: Map.delete(state.pending_reads, id),
        read_monitors: Map.delete(state.read_monitors, pending.current.monitor)
    }
  end

  defp cancel_read_caller(state, monitor) do
    case Map.fetch(state.read_monitors, monitor) do
      {:ok, id} ->
        pending = Map.fetch!(state.pending_reads, id)
        Process.exit(pending.worker, :kill)
        remove_read(state, id, pending)

      :error ->
        state
    end
  end

  # Concept: read no further than the position this runtime has acknowledged.
  #
  # Technical depth: the fence is applied to the read rather than to the queue,
  # so an unacknowledged row is never fetched, never counted against capacity,
  # and never advances `seen`. A later pump re-reads from the same position once
  # the watermark moves, which is what makes the withholding temporary rather
  # than a gap. With no watermark for the session the read is unbounded, which
  # is the dormant-session case: this runtime holds no transaction against it.
  defp pump(state, attachment) do
    cond do
      attachment.status != :active -> attachment
      publishable_limit(state, attachment) == 0 -> attachment
      true -> pump_page(state, attachment, publishable_limit(state, attachment))
    end
  end

  defp pump_page(state, attachment, limit) do
    case Store.load_events(state.store, attachment.session_id, attachment.seen, limit) do
      {:ok, []} ->
        attachment

      {:ok, events} when is_list(events) ->
        {next, disposition} = enqueue_events(attachment, events)

        cond do
          next.status != :active -> next
          disposition == :historical_backlog -> next
          length(events) == limit and next.queue_depth < next.capacity -> pump(state, next)
          true -> next
        end

      :unavailable ->
        disconnect(attachment, :store_unavailable)

      {:error, _reason} ->
        disconnect(attachment, :store_read_failed)
    end
  end

  defp publishable_limit(state, attachment) do
    room = attachment.capacity - attachment.queue_depth
    page = min(max(room + 1, 1), @max_page)

    case Map.fetch(state.acknowledged, attachment.session_id) do
      :error -> page
      {:ok, acknowledged} -> min(page, max(acknowledged - attachment.seen, 0))
    end
  end

  defp prepare_staged_scan(scan_state, transaction, bound, capacity) do
    with {:ok,
          %{
            tail: tail,
            snapshot: %{session_id: session_id, event_sequence: anchor} = snapshot
          } = result} <-
           scan_attachment(
             scan_state.store,
             transaction.session_id,
             transaction.options[:after_event_sequence],
             bound
           ),
         true <- session_id == transaction.session_id,
         true <- is_integer(anchor) and anchor >= 0,
         true <- is_integer(tail) and tail >= anchor do
      attachment = %{
        id: transaction.id,
        incarnation_id: transaction.incarnation_id,
        holder: transaction.holder,
        open_interaction: Map.get(result, :open_interaction),
        session_id: transaction.session_id,
        cursor: anchor,
        seen: anchor,
        replay_until: tail,
        queue: :queue.new(),
        queue_depth: 0,
        max_queue_depth: 0,
        capacity: capacity,
        status: :active,
        metadata: transient_metadata(transaction.options),
        transfers: %{},
        transfer_progress: %{}
      }

      response = %{
        id: transaction.id,
        incarnation_id: transaction.incarnation_id,
        snapshot: snapshot,
        open_interaction: Map.get(result, :open_interaction)
      }

      {:ok, pump(scan_state, attachment), response}
    else
      :unavailable -> {:error, :store_unavailable}
      {:error, reason} -> {:error, reason}
      _other -> {:error, :invalid_store_page}
    end
  end

  defp register_holder_pending(state, holder, attach_ref) do
    case Map.get(state.holders, holder) do
      nil ->
        monitor = Process.monitor(holder)

        entry = %{
          monitor: monitor,
          pending: MapSet.new([attach_ref]),
          attachments: MapSet.new(),
          transfer_debit: 0,
          transfer_reserved: 0,
          transfer_uncertain: false,
          alive: true
        }

        %{
          state
          | holders: Map.put(state.holders, holder, entry),
            holder_monitors: Map.put(state.holder_monitors, monitor, holder)
        }

      entry ->
        updated = %{entry | pending: MapSet.put(entry.pending, attach_ref)}
        %{state | holders: Map.put(state.holders, holder, updated)}
    end
  end

  defp drop_staged_attachment(state, attach_ref) do
    case Map.pop(state.staged_attachments, attach_ref) do
      {nil, _staged} ->
        state

      {pending, staged} ->
        if Process.alive?(pending.worker), do: Process.exit(pending.worker, :kill)

        state
        |> Map.put(:staged_attachments, staged)
        |> drop_holder_pending(pending.holder, attach_ref)
    end
  end

  defp holder_pending?(state, pending) do
    case Map.get(state.holders, pending.holder) do
      %{pending: refs} -> MapSet.member?(refs, pending.attach_ref)
      _other -> false
    end
  end

  defp finish_holder_pending(state, holder, attach_ref, attachment_id) do
    case Map.get(state.holders, holder) do
      nil ->
        state

      entry ->
        updated = %{
          entry
          | pending: MapSet.delete(entry.pending, attach_ref),
            attachments: MapSet.put(entry.attachments, attachment_id)
        }

        %{state | holders: Map.put(state.holders, holder, updated)}
    end
  end

  defp drop_holder_pending(state, holder, attach_ref) do
    update_holder(state, holder, fn entry ->
      %{entry | pending: MapSet.delete(entry.pending, attach_ref)}
    end)
  end

  defp drop_holder_attachment(state, holder, attachment_id) do
    update_holder(state, holder, fn entry ->
      %{entry | attachments: MapSet.delete(entry.attachments, attachment_id)}
    end)
  end

  defp update_holder(state, holder, update) do
    case Map.get(state.holders, holder) do
      nil ->
        state

      entry ->
        updated = update.(entry)

        # The original holder is the physical connection binding. Empty
        # attachment sets do not renew its nonrefundable connection debit.
        %{state | holders: Map.put(state.holders, holder, updated)}
    end
  end

  defp prepare_replacement(state, %{options: options, holder: holder, session_id: session_id}) do
    case options[:replace_attachment_id] do
      nil ->
        {:ok, state}

      attachment_id ->
        case Map.get(state.attachments, attachment_id) do
          %{holder: ^holder, session_id: ^session_id} ->
            {:ok, drop_attachment(state, attachment_id)}

          _other ->
            {:error, :stale_attachment}
        end
    end
  end

  defp invalidate_session_state(state, session_id) do
    staged_refs =
      state.staged_attachments
      |> Enum.filter(fn {_attach_ref, pending} -> pending.session_id == session_id end)
      |> Enum.map(&elem(&1, 0))

    state =
      Enum.reduce(staged_refs, state, fn attach_ref, current ->
        case Map.get(current.staged_attachments, attach_ref) do
          %{control: control} ->
            send(
              control,
              {:attachment_stage_failed, self(), current.incarnation, attach_ref,
               :attachment_superseded}
            )

            drop_staged_attachment(current, attach_ref)

          _other ->
            current
        end
      end)

    removed =
      state.attachments
      |> Enum.filter(fn {_id, attachment} -> attachment.session_id == session_id end)
      |> Enum.map(fn {id, attachment} ->
        %{
          attachment_id: id,
          attachment_incarnation: attachment.incarnation_id,
          holder: attachment.holder,
          cursor: attachment.cursor
        }
      end)

    next =
      Enum.reduce(removed, state, fn removed_attachment, current ->
        drop_attachment(current, removed_attachment.attachment_id)
      end)

    {removed, next}
  end

  defp drop_holder(state, holder, reason) do
    case Map.get(state.holders, holder) do
      nil ->
        state

      entry ->
        staged_refs =
          state.staged_attachments
          |> Enum.filter(fn {_attach_ref, pending} -> pending.holder == holder end)
          |> Enum.map(&elem(&1, 0))

        state =
          Enum.reduce(staged_refs, state, fn attach_ref, current ->
            case Map.get(current.staged_attachments, attach_ref) do
              %{control: control} ->
                send(
                  control,
                  {:attachment_stage_failed, self(), current.incarnation, attach_ref, reason}
                )

                drop_staged_attachment(current, attach_ref)

              _other ->
                current
            end
          end)

        attachment_ids = MapSet.to_list(entry.attachments)

        state =
          Enum.reduce(attachment_ids, state, fn attachment_id, current ->
            drop_attachment(current, attachment_id)
          end)

        if reason == :holder_unavailable do
          updated = %{Map.fetch!(state.holders, holder) | alive: false}
          state = %{state | holders: Map.put(state.holders, holder, updated)}
          forget_dead_artifact_holder(state, holder)
        else
          state
        end
    end
  end

  defp drop_attachment(state, attachment_id) do
    case Map.pop(state.attachments, attachment_id) do
      {nil, _attachments} ->
        state

      {attachment, attachments} ->
        state = cancel_attachment_read(%{state | attachments: attachments}, attachment_id)
        state = release_transfers(state, attachment)
        drop_holder_attachment(state, attachment.holder, attachment_id)
    end
  end

  defp cancel_attachment_read(state, attachment_id) do
    case Map.get(state.pending_reads, attachment_id) do
      nil ->
        state

      pending ->
        Process.exit(pending.worker, :kill)
        reply_read(pending.current, {:error, :stale_attachment})
        remove_read(state, attachment_id, pending)
    end
  end

  defp enqueue_events(attachment, events) do
    Enum.reduce_while(events, {attachment, :complete}, fn event, {current, _disposition} ->
      expected = current.seen + 1

      cond do
        not valid_event?(event, expected) ->
          {:halt, {disconnect(current, :invalid_outbox), :disconnected}}

        current.queue_depth < current.capacity ->
          queue = :queue.in(event, current.queue)
          depth = current.queue_depth + 1

          next = %{
            current
            | queue: queue,
              queue_depth: depth,
              max_queue_depth: max(current.max_queue_depth, depth),
              seen: event.event_sequence
          }

          {:cont, {next, :complete}}

        event.event_sequence <= current.replay_until ->
          {:halt, {current, :historical_backlog}}

        true ->
          {:halt, {disconnect(current, :overflow), :disconnected}}
      end
    end)
  end

  defp disconnect(attachment, reason) do
    %{
      attachment
      | status: {:disconnected, reason},
        queue: :queue.new(),
        queue_depth: 0
    }
  end

  defp fetch_attachment(state, token, session_id, attachment_id, incarnation_id) do
    with true <- token == state.token,
         {:ok, attachment} <- Map.fetch(state.attachments, attachment_id),
         true <- attachment.session_id == session_id,
         true <- attachment.incarnation_id == incarnation_id do
      {:ok, attachment}
    else
      _other -> {:error, :stale_attachment}
    end
  end

  defp validate_attachment(state, token, session_id, attachment_id, incarnation_id) do
    case fetch_attachment(state, token, session_id, attachment_id, incarnation_id) do
      {:ok, %{status: :active}} -> :ok
      {:ok, attachment} -> {:error, {:disconnected, attachment.cursor}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp put_attachment(state, attachment),
    do: %{state | attachments: Map.put(state.attachments, attachment.id, attachment)}

  # Concept: the same publication fence, applied to the attach scan.
  #
  # Technical depth: `publishable_limit/2` fences the pump, but an attaching
  # caller reaches the outbox by a second path, and an unfenced scan anchors its
  # snapshot at the durable tail. That tail can hold rows of an unresolved
  # `commit_unknown`, so an attachment installed on it would answer with truth
  # every already-attached consumer is withheld from and would set `seen` past
  # those rows, which are then never delivered on the event plane. The bound is
  # read from the dispatcher's own watermark map inside the call, because the
  # scan worker is a bare process with no dispatcher state, and a watermark read
  # later could only be higher -- a bound that is stale is conservative, never
  # permissive. With no watermark the scan is unbounded, for the reason the pump
  # is: nothing this runtime holds is outstanding against a session it does not
  # own, so no row of its reconstructed outbox is withheld.
  defp scan_bound(state, session_id), do: Map.get(state.acknowledged, session_id, :unbounded)

  # Concept: configuration at cursor zero is immutable creation truth.
  # Technical depth: read exactly the first private row in the existing scan
  # worker, then retain only its public configuration allowlist. Later private
  # rows may be newer than the requested or acknowledged cursor and are never
  # read by this path; subsequent changes come from the fenced public pages.
  defp scan_attachment(store, session_id, requested_anchor, bound) do
    with {:ok, [%{journal_version: 1, payload: payload}]} <-
           Store.load_records(store, session_id, 0, 1),
         {:ok, genesis} <- Loopex.Runtime.SessionGenesis.normalize(payload),
         configuration =
           Loopex.Runtime.SessionConfiguration.public_view(genesis["initial_configuration"]),
         {:ok, scan} <-
           SessionState.start_snapshot_scan(session_id, requested_anchor, configuration) do
      scan_event_pages(store, session_id, 0, scan, bound)
    else
      :unavailable -> {:error, :store_unavailable}
      {:error, reason} -> {:error, reason}
      _invalid -> {:error, :invalid_store_page}
    end
  end

  defp scan_event_pages(store, session_id, position, scan, bound) do
    case Store.load_events(store, session_id, position, scan_page_limit(position, bound)) do
      {:ok, []} ->
        SessionState.finish_snapshot_scan(scan)

      {:ok, rows} when is_list(rows) ->
        case Enum.split_while(rows, &(not beyond_scan_bound?(&1, bound))) do
          {admitted, []} ->
            continue_scan(store, session_id, position, scan, bound, admitted)

          {admitted, _withheld} ->
            with {:ok, bounded} <- SessionState.scan_snapshot_page(scan, admitted) do
              SessionState.finish_snapshot_scan(bounded)
            end
        end

      :unavailable ->
        {:error, :store_unavailable}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp continue_scan(store, session_id, position, scan, bound, rows) do
    with {:ok, next_scan} <- SessionState.scan_snapshot_page(scan, rows),
         %{event_sequence: next_position} when next_position > position <- List.last(rows) do
      scan_event_pages(store, session_id, next_position, next_scan, bound)
    else
      _other -> {:error, :invalid_store_page}
    end
  end

  # Concept: ask for one row more than the fence allows.
  #
  # Technical depth: the paging loop ends when a page falls short, and a bounded
  # scan has two ways to fall short -- the store ran out of history, or the
  # watermark did. Requesting the extra row lets one read answer both, so the
  # scan neither stops a page early on a session that has more readable history
  # nor spends another round trip proving it has none. A row past the bound is
  # never admitted to the snapshot; it is the witness that the fence, not the
  # store, ended the scan.
  defp scan_page_limit(_position, :unbounded), do: @max_page

  defp scan_page_limit(position, bound) when is_integer(bound),
    do: bound |> Kernel.-(position) |> max(0) |> Kernel.+(1) |> min(@max_page)

  # Technical depth: a row whose sequence is missing or malformed is deliberately
  # not withheld here. It stays in the admitted prefix so the snapshot scan
  # refuses it as invalid history, which is the answer it already gives; reading
  # it as "past the bound" would end the scan quietly on a corrupt page.
  defp beyond_scan_bound?(%{event_sequence: sequence}, bound)
       when is_integer(bound) and is_integer(sequence),
       do: sequence > bound

  defp beyond_scan_bound?(_row, _bound), do: false

  defp valid_event?(event, expected) do
    match?(
      %{event_sequence: ^expected, event_id: id, kind: kind}
      when is_binary(id) and is_binary(kind),
      event
    )
  end

  defp transient_metadata(options) do
    Map.new([:request_id, :client_id, :attachment_key], fn key -> {key, options[key]} end)
  end

  # Concept: the artifact store this runtime was composed with, if any.
  #
  # Technical depth: a runtime without one refuses the transfer family as
  # unsupported rather than reaching for a default. The optional capability
  # requires reserve/open/read/close together; bounded refusal carries no
  # compatibility path or alternate storage authority.
  defp artifact_store(%{artifact_store: %{module: module, handle: _handle} = store}) do
    if ArtifactStore.supports_transfer?(module),
      do: {:ok, store},
      else: {:error, :artifact_transfer_unsupported}
  end

  defp artifact_store(_state), do: {:error, :artifact_transfer_unsupported}

  # Concept: what one transfer has moved, from the moment it opened.
  #
  # Technical depth: accepted ADR 0030's transfer-lifecycle cut reports bytes and
  # chunks over a lifetime that spans three separate calls, so no single span can
  # measure it. The totals accumulate here and are reported exactly once, when
  # the transfer ends -- closed by its caller or released with its attachment.
  defp new_progress(attachment, transfer_ref, object) do
    span =
      Instrumentation.open_span([:artifact, :transfer], %{
        session_id: attachment.session_id,
        attachment_id: attachment.id,
        transfer_ref: transfer_ref,
        locator: object.locator
      })

    %{bytes: 0, chunks: 0, span: span}
  end

  defp record_read(attachment, transfer_ref, {:ok, %{bytes: bytes}}) when is_binary(bytes) do
    case Map.fetch(attachment.transfer_progress, transfer_ref) do
      {:ok, progress} ->
        progress = %{progress | bytes: progress.bytes + byte_size(bytes), chunks: progress.chunks + 1}
        %{attachment | transfer_progress: Map.put(attachment.transfer_progress, transfer_ref, progress)}

      :error ->
        attachment
    end
  end

  defp record_read(attachment, _transfer_ref, _result), do: attachment

  defp report_transfer(attachment, transfer_ref, disposition) do
    case Map.fetch(attachment.transfer_progress, transfer_ref) do
      {:ok, progress} ->
        Instrumentation.close_span(
          progress.span,
          %{bytes: progress.bytes, chunks: progress.chunks},
          %{
            session_id: attachment.session_id,
            attachment_id: attachment.id,
            transfer_ref: transfer_ref,
            disposition: disposition
          }
        )

      :error ->
        :ok
    end
  end

  defp read_category({:ok, :complete}), do: :complete
  defp read_category(result), do: Instrumentation.outcome(result)

  defp transfer_headroom(attachment, state) do
    connection_count =
      Enum.count(state.artifact_transfers, fn {_id, entry} ->
        entry.holder === attachment.holder
      end)

    if connection_count < state.transfer_limits.per_attachment and
         map_size(state.artifact_transfers) < state.transfer_limits.per_runtime,
       do: :ok,
       else: {:error, :transfer_limit_reached}
  end

  defp dispatcher_registration_worker(root, token, dispatcher, incarnation) do
    result =
      with {:ok, control} <- RuntimeSupervisor.control(root),
           {:ok, registration_ref, seed} <-
             safe_control_call(
               control,
               {:begin_dispatcher_registration, token, dispatcher, incarnation}
             ) do
        send(
          dispatcher,
          {:dispatcher_seed, self(), incarnation, registration_ref, seed}
        )

        receive do
          {:dispatcher_seeded, ^dispatcher, ^incarnation, ^registration_ref} ->
            case safe_control_call(
                   control,
                   {:finalize_dispatcher_registration, token, dispatcher, incarnation,
                    registration_ref}
                 ) do
              {:ok, ready_token} ->
                send(
                  dispatcher,
                  {:dispatcher_ready_token, self(), incarnation, registration_ref, ready_token,
                   control}
                )

                :ok

              _other ->
                :error
            end
        end
      else
        _other -> :error
      end

    if result != :ok do
      send(dispatcher, {:dispatcher_registration_failed, self(), incarnation})
    end
  end

  defp safe_control_call(control, message) do
    try do
      GenServer.call(control, message, :infinity)
    catch
      :exit, _reason -> {:error, :runtime_unavailable}
    end
  end

  defp release_transfers(state, attachment) do
    state.artifact_transfers
    |> Enum.filter(fn {_id, entry} -> artifact_entry_attachment?(entry, attachment) end)
    |> Enum.reduce(state, fn {id, _entry}, current ->
      report_transfer(attachment, id, :released)
      retire_artifact(current, id, :cancelled, artifact_now())
    end)
  end

  # Concept: the same original actors retain one opening through its whole life.
  # Technical depth: the custodian alone calls reserve/open/read; one persistent
  # observer alone calls retire/ack. Only exact messages and original DOWNs
  # advance custody. No timeout kills an actor and calls that a physical proof.
  defp begin_artifact_open(state, attachment, store, request, context, from) do
    dispatcher = self()
    id = context.transfer_ref

    metadata = %{
      session_id: attachment.session_id,
      attachment_id: attachment.id,
      transfer_ref: id
    }

    invocation_started_at = artifact_now()

    {custodian, custodian_monitor} =
      spawn_opt_artifact(fn ->
        artifact_custodian(dispatcher, id, store, request, context, metadata)
      end)

    {observer, observer_monitor} =
      spawn_opt_artifact(fn -> artifact_observer(dispatcher, id, store, metadata) end)

    caller_monitor = Process.monitor(elem(from, 0))

    timer =
      Process.send_after(
        self(),
        {:artifact_open_expired, id},
        max(0, context.open_deadline_ms - artifact_now())
      )

    entry = %{
      id: id,
      holder: attachment.holder,
      session_id: attachment.session_id,
      attachment_id: attachment.id,
      incarnation_id: attachment.incarnation_id,
      store: store,
      request: request,
      context: context,
      phase: :reserving,
      custodian: custodian,
      custodian_monitor: custodian_monitor,
      observer: observer,
      observer_monitor: observer_monitor,
      caller_monitor: caller_monitor,
      open_from: from,
      close_from: nil,
      invocation: :reserve,
      invocation_started_at: invocation_started_at,
      observation: :idle,
      permission: false,
      permission_issued_at: nil,
      failure_proof_deadline: nil,
      not_reserved: false,
      reserved: false,
      receipt: nil,
      acknowledged: false,
      custodian_down: nil,
      observer_down: nil,
      lost: false,
      cleanup: nil,
      reason: nil,
      open_timer: timer,
      close_timer: nil,
      lifetime_timer: nil,
      lifetime_deadline: nil,
      callback_completed_at: nil,
      read: nil,
      transfer: nil,
      cursor: nil,
      opening_work: nil,
      opening_charged: false,
      work_reserved: open_work_reservation(state),
      stopping: false
    }

    monitors =
      state.artifact_monitors
      |> Map.put(custodian_monitor, {id, :custodian, custodian})
      |> Map.put(observer_monitor, {id, :observer, observer})
      |> Map.put(caller_monitor, {id, :caller, elem(from, 0)})

    %{put_artifact_entry(state, entry) | artifact_monitors: monitors}
  end

  defp spawn_opt_artifact(function), do: :erlang.spawn_opt(function, [:link, :monitor])

  defp artifact_custodian(dispatcher, id, store, request, context, metadata) do
    monitor = Process.monitor(dispatcher)

    result =
      artifact_callback(fn -> store.module.reserve_transfer(store.handle, request, context) end)

    send(dispatcher, {:artifact_custodian_result, id, self(), :reserve, result, artifact_now()})
    artifact_custodian_loop(dispatcher, monitor, id, store, request, context, metadata)
  end

  defp artifact_custodian_loop(dispatcher, monitor, id, store, request, context, metadata) do
    receive do
      {:artifact_open_permission, ^dispatcher, ^id} ->
        result =
          artifact_callback(fn ->
            Instrumentation.span([:artifact, :open_transfer], metadata, fn ->
              store.module.open_transfer(store.handle, request, context)
            end)
          end)

        send(dispatcher, {:artifact_custodian_result, id, self(), :open, result, artifact_now()})
        artifact_custodian_loop(dispatcher, monitor, id, store, request, context, metadata)

      {:artifact_read, ^dispatcher, ^id, read_id, transfer, length} ->
        result =
          artifact_callback(fn ->
            Instrumentation.span(
              [:artifact, :read_transfer],
              Map.put(metadata, :requested, length),
              fn ->
                store.module.read_transfer(store.handle, transfer, length)
              end,
              &read_category/1
            )
          end)

        send(
          dispatcher,
          {:artifact_custodian_result, id, self(), {:read, read_id}, result, artifact_now()}
        )

        artifact_custodian_loop(dispatcher, monitor, id, store, request, context, metadata)

      {:artifact_finish, ^dispatcher, ^id} ->
        :ok

      {:DOWN, ^monitor, :process, ^dispatcher, _reason} ->
        exit(:dispatcher_lost)
    end
  end

  defp artifact_observer(dispatcher, id, store, metadata) do
    monitor = Process.monitor(dispatcher)
    artifact_observer_loop(dispatcher, monitor, id, store, metadata)
  end

  defp artifact_observer_loop(dispatcher, monitor, id, store, metadata) do
    receive do
      {:artifact_observe, ^dispatcher, ^id, operation, selector} ->
        result =
          artifact_callback(fn ->
            Instrumentation.span([:artifact, :close_transfer], metadata, fn ->
              store.module.close_transfer(store.handle, selector)
            end)
          end)

        send(dispatcher, {:artifact_observer_result, id, self(), operation, result})
        artifact_observer_loop(dispatcher, monitor, id, store, metadata)

      {:artifact_finish, ^dispatcher, ^id} ->
        :ok

      {:DOWN, ^monitor, :process, ^dispatcher, _reason} ->
        exit(:dispatcher_lost)
    end
  end

  defp artifact_callback(function) do
    try do
      function.()
    rescue
      _exception -> :callback_uncertain
    catch
      _kind, _reason -> :callback_uncertain
    end
  end

  defp artifact_invocation_result(state, id, :reserve, result) do
    entry = Map.fetch!(state.artifact_transfers, id)

    cond do
      ArtifactStore.valid_reserve_result?(result, entry.context) and match?({:ok, _}, result) ->
        entry = %{entry | reserved: true, phase: :reserved}
        state = put_artifact_entry(state, entry)

        if artifact_adoptable?(state, entry) do
          permission_issued_at = artifact_now()
          send(entry.custodian, {:artifact_open_permission, self(), id})

          put_artifact_entry(state, %{
            entry
            | permission: true,
              invocation: :open,
              phase: :opening,
              permission_issued_at: permission_issued_at,
              invocation_started_at: permission_issued_at
          })
        else
          state
          |> retire_artifact(id, :cancelled, artifact_cancel_anchor(entry))
          |> observe_artifact_retirement(id)
        end

      ArtifactStore.valid_reserve_result?(result, entry.context) ->
        {:error, failure} = result
        entry = %{entry | not_reserved: true, reason: failure.reason}
        state = state |> put_artifact_entry(entry) |> settle_never_reserved(id)

        state
        |> retire_artifact(id, failure.reason, artifact_cancel_anchor(entry))
        |> finish_artifact_actors(id)

      true ->
        state = retain_artifact_failure_bound(state, id, entry.invocation_started_at)
        retire_artifact(state, id, :transfers_unavailable, artifact_cancel_anchor(entry))
    end
  end

  defp artifact_invocation_result(state, id, :open, result) do
    entry = Map.fetch!(state.artifact_transfers, id)

    cond do
      ArtifactStore.valid_open_result?(result, entry.request, entry.context) and
          match?({:ok, _}, result) ->
        {:ok, opened} = result
        state = settle_opening_work(state, id, opened.work)
        entry = Map.fetch!(state.artifact_transfers, id)

        if artifact_adoptable?(state, entry) do
          attachment = Map.fetch!(state.attachments, entry.attachment_id)
          transfer = opened.transfer
          progress = new_progress(attachment, id, transfer.object)

          attachment = %{
            attachment
            | transfers: Map.put(attachment.transfers, id, transfer),
              transfer_progress: Map.put(attachment.transfer_progress, id, progress)
          }

          cancel_artifact_timer(entry.open_timer)
          lifetime_deadline = entry.callback_completed_at + state.transfer_limits.lifetime_ms

          timer =
            Process.send_after(
              self(),
              {:artifact_lifetime_expired, id},
              max(0, lifetime_deadline - artifact_now())
            )

          entry = %{
            entry
            | phase: :live,
              transfer: transfer,
              cursor: transfer.window_start,
              lifetime_timer: timer,
              lifetime_deadline: lifetime_deadline
          }

          state = state |> put_attachment(attachment) |> put_artifact_entry(entry)

          if artifact_now() < entry.context.open_deadline_ms do
            reply_artifact_open(state, id, {:ok, public_artifact_transfer(opened, entry.request)})
          else
            state =
              retire_artifact(state, id, :open_deadline_exhausted, entry.context.open_deadline_ms)

            reply_artifact_open(
              state,
              id,
              {:error, %{reason: :open_deadline_exhausted, cleanup: :unproved}}
            )
          end
        else
          state
          |> retire_artifact(id, :cancelled, artifact_cancel_anchor(entry))
          |> advance_artifact_cleanup(id)
        end

      ArtifactStore.valid_open_result?(result, entry.request, entry.context) ->
        {:error, failure} = result

        state =
          state
          |> settle_opening_work(id, failure.work)
          |> retain_artifact_failure_bound(id, entry.invocation_started_at)

        state
        |> retire_artifact(id, failure.reason, artifact_cancel_anchor(entry))
        |> advance_artifact_cleanup(id)

      true ->
        state = retain_artifact_failure_bound(state, id, entry.invocation_started_at)

        state
        |> retire_artifact(id, :transfers_unavailable, artifact_cancel_anchor(entry))
        |> advance_artifact_cleanup(id)
    end
  end

  defp artifact_invocation_result(state, id, {:read, read_id}, result) do
    entry = Map.fetch!(state.artifact_transfers, id)

    case entry.read do
      %{id: ^read_id} = read ->
        cancel_artifact_timer(read.timer)
        {valid, bytes} = artifact_read_result(result, entry, read.reserved)

        state =
          if valid,
            do: settle_connection_work(state, entry.holder, read.reserved, bytes),
            else: state

        timely = artifact_now() < read.deadline and entry.phase == :live

        reply =
          cond do
            valid and timely -> result
            artifact_now() >= read.deadline -> {:error, :read_deadline_exhausted}
            timely and match?({:error, reason} when is_atom(reason), result) -> result
            true -> {:error, :artifact_unreadable}
          end

        if read.from, do: GenServer.reply(read.from, reply)

        entry = %{
          entry
          | read: nil,
            cursor: if(valid, do: entry.cursor + bytes, else: entry.cursor)
        }

        state = put_artifact_entry(state, entry)

        # Concept: lifecycle totals count only a chunk admitted to its live caller.
        # Technical depth: physical work settles above even after retirement, but
        # an already removed public lifecycle must stay absent through read/ack joins.
        state =
          if valid and timely and not is_nil(read.from) do
            case Map.get(state.attachments, entry.attachment_id) do
              nil -> state
              attachment -> put_attachment(state, record_read(attachment, id, result))
            end
          else
            state
          end

        if not valid or not timely do
          state
          |> retain_artifact_failure_bound(id, read.invocation_started_at)
          |> retire_artifact(id, :cancelled, min(artifact_now(), read.deadline))
          |> advance_artifact_cleanup(id)
        else
          state
        end

      _other ->
        state
    end
  end

  defp validate_artifact_read_length(length) when is_integer(length) and length > 0, do: :ok
  defp validate_artifact_read_length(_length), do: {:error, :invalid_chunk_length}

  defp artifact_read_result(
         {:ok, %{offset: offset, bytes: bytes, chunk_digest: digest} = chunk},
         entry,
         length
       )
       when is_binary(bytes) and is_integer(offset) and is_binary(digest) do
    valid =
      map_size(chunk) == 3 and byte_size(bytes) > 0 and byte_size(bytes) <= length and
        offset === entry.cursor and
        offset + byte_size(bytes) <= entry.transfer.window_start + entry.transfer.window_length and
        digest === Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

    {valid, if(valid, do: byte_size(bytes), else: 0)}
  end

  defp artifact_read_result({:ok, :complete}, entry, _length),
    do: {entry.cursor === entry.transfer.window_start + entry.transfer.window_length, 0}

  defp artifact_read_result({:error, reason}, _entry, _length) when is_atom(reason),
    do: {false, 0}

  defp artifact_read_result(_result, _entry, _length), do: {false, 0}

  defp artifact_adoptable?(state, entry) do
    is_nil(entry.cleanup) and not entry.lost and entry.open_from != nil and
      Process.alive?(elem(entry.open_from, 0)) and artifact_now() < entry.context.open_deadline_ms and
      case Map.get(state.attachments, entry.attachment_id) do
        %{status: :active} = attachment ->
          Process.alive?(attachment.holder) and artifact_entry_attachment?(entry, attachment)

        _other ->
          false
      end
  end

  defp artifact_entry_attachment?(entry, attachment),
    do:
      entry.attachment_id === attachment.id and entry.session_id === attachment.session_id and
        entry.incarnation_id === attachment.incarnation_id and entry.holder === attachment.holder

  # Concept: expose only the accepted compact object and use references.
  # Technical depth: pure adoption validation has already bound this use to the
  # original session/digest and the transfer object. No metadata or work escapes.
  defp public_artifact_transfer(opened, request) do
    use = opened.use

    use_reference = %{
      digest: use.object_digest,
      size: use.object_size,
      locator: use.object_locator,
      media_type: use.media_type,
      role: use.role,
      use_canonicalization_version: use.canonicalization_version,
      use_digest: binary_part(request.use_locator, 4, 64),
      use_locator: request.use_locator
    }

    opened.transfer
    |> Map.take([:transfer_ref, :total_size, :window_start, :window_length, :object_digest])
    |> Map.put(:object_reference, opened.transfer.object)
    |> Map.put(:use_reference, use_reference)
  end

  # Concept: an untimed physical receipt never invents timely cleanup.
  # Technical depth: an opaque adapter supplies no actual minimum lifetime/read
  # duration. Permission P precedes every possible live expiry, so P+5000 is a
  # conservative ceiling for proving an unknown earlier Store retirement. It is
  # only proof eligibility: the real 600000ms timer and original D_close remain
  # unchanged. Longer-lived transfers may reclaim prospectively but report
  # cleanup_unproved. Classified deadlines cannot justify a longer lower bound
  # without actual adapter timing evidence; use each original invocation start.
  defp artifact_cleanup_timely?(entry, completed_at) do
    deadline = entry.cleanup.close_deadline_ms

    live_bound =
      is_nil(entry.permission_issued_at) or
        completed_at < entry.permission_issued_at + 5_000

    failure_bound =
      is_nil(entry.failure_proof_deadline) or
        completed_at < entry.failure_proof_deadline

    completed_at < deadline and entry.custodian_down.at < deadline and
      entry.observer_down.at < deadline and
      (entry.not_reserved or
         (completed_at < entry.context.open_deadline_ms + 5_000 and
            live_bound and failure_bound))
  end

  defp retain_artifact_failure_bound(state, id, invocation_started_at) do
    entry = Map.fetch!(state.artifact_transfers, id)
    put_artifact_entry(state, artifact_failure_bound(entry, invocation_started_at))
  end

  defp artifact_failure_bound(entry, invocation_started_at) do
    deadline = invocation_started_at + 5_000

    deadline =
      if is_nil(entry.failure_proof_deadline),
        do: deadline,
        else: min(deadline, entry.failure_proof_deadline)

    %{entry | failure_proof_deadline: deadline}
  end

  defp artifact_cancel_anchor(entry), do: min(artifact_now(), entry.context.open_deadline_ms)

  defp retire_artifact(state, id, reason, anchor) do
    case Map.get(state.artifact_transfers, id) do
      nil ->
        state

      entry ->
        entry =
          if is_nil(entry.cleanup) do
            deadline = anchor + state.transfer_limits.cleanup_deadline_ms

            selector = %{
              action: :retire,
              transfer_ref: id,
              open_deadline_ms: entry.context.open_deadline_ms,
              close_deadline_ms: deadline
            }

            timer =
              Process.send_after(
                self(),
                {:artifact_close_expired, id},
                max(0, deadline - artifact_now())
              )

            cancel_artifact_timer(entry.lifetime_timer)

            entry =
              if entry.read,
                do: artifact_failure_bound(entry, entry.read.invocation_started_at),
                else: entry

            %{entry | phase: :retiring, cleanup: selector, close_timer: timer, reason: reason}
          else
            %{entry | phase: :retiring}
          end

        state = state |> put_artifact_entry(entry) |> remove_artifact_public_transfer(entry)

        state =
          reply_artifact_open(state, id, {:error, %{reason: entry.reason, cleanup: :unproved}})

        state =
          if entry.read && entry.read.from do
            GenServer.reply(entry.read.from, {:error, :unknown_transfer})
            put_artifact_entry(state, %{entry | read: %{entry.read | from: nil}})
          else
            state
          end

        observe_artifact_retirement(state, id)
    end
  end

  defp observe_artifact_retirement(state, id) do
    entry = Map.fetch!(state.artifact_transfers, id)

    cond do
      entry.stopping ->
        state

      entry.not_reserved ->
        finish_artifact_actors(state, id)

      entry.receipt != nil ->
        advance_artifact_cleanup(state, id)

      entry.observation == :idle and is_nil(entry.observer_down) ->
        send(entry.observer, {:artifact_observe, self(), id, :retire, entry.cleanup})
        put_artifact_entry(state, %{entry | observation: :retire})

      true ->
        state
    end
  end

  defp artifact_observation_result(state, id, :retire, result) do
    entry = Map.fetch!(state.artifact_transfers, id)

    if ArtifactStore.valid_close_result?(result, entry.cleanup) and match?({:retired, _}, result) do
      {:retired, receipt} = result
      state = settle_opening_work(state, id, receipt.work)
      entry = Map.fetch!(state.artifact_transfers, id)
      entry = if entry.not_reserved, do: %{entry | lost: true}, else: entry
      state |> put_artifact_entry(%{entry | receipt: receipt}) |> advance_artifact_cleanup(id)
    else
      # Unregistered, malformed and unproved results supply no Store proof.
      # A conclusive original never-reserved reply instead requires this
      # invocation to finish and both original actors to join.
      if entry.not_reserved do
        finish_artifact_actors(state, id)
      else
        state =
          reply_artifact_open(state, id, {:error, %{reason: entry.reason, cleanup: :unproved}})

        entry = Map.fetch!(state.artifact_transfers, id)
        if entry.close_from, do: GenServer.reply(entry.close_from, {:error, :cleanup_unproved})
        put_artifact_entry(state, %{entry | close_from: nil})
      end
    end
  end

  defp artifact_observation_result(state, id, :acknowledge, result) do
    entry = Map.fetch!(state.artifact_transfers, id)
    selector = %{action: :acknowledge, transfer_ref: id, receipt_ref: entry.receipt.receipt_ref}

    if result === :ok and ArtifactStore.valid_close_result?(result, selector) do
      state |> put_artifact_entry(%{entry | acknowledged: true}) |> finish_artifact_actors(id)
    else
      state
    end
  end

  defp advance_artifact_cleanup(state, id) do
    entry = Map.fetch!(state.artifact_transfers, id)

    cond do
      entry.not_reserved ->
        finish_artifact_actors(state, id)

      entry.acknowledged ->
        finish_artifact_actors(state, id)

      entry.receipt != nil and entry.invocation == :idle and entry.observation == :idle and
        is_nil(entry.custodian_down) and is_nil(entry.observer_down) ->
        selector = %{
          action: :acknowledge,
          transfer_ref: id,
          receipt_ref: entry.receipt.receipt_ref
        }

        send(entry.observer, {:artifact_observe, self(), id, :acknowledge, selector})
        put_artifact_entry(state, %{entry | observation: :acknowledge})

      true ->
        state
    end
  end

  defp finish_artifact_actors(state, id) do
    entry = Map.fetch!(state.artifact_transfers, id)

    if not entry.stopping and entry.invocation == :idle and entry.observation == :idle and
         (entry.not_reserved or entry.acknowledged) do
      send(entry.custodian, {:artifact_finish, self(), id})
      send(entry.observer, {:artifact_finish, self(), id})
      put_artifact_entry(state, %{entry | stopping: true})
    else
      state
    end
  end

  defp artifact_original_down(state, id, :caller, _reason) do
    case Map.get(state.artifact_transfers, id) do
      nil ->
        state

      entry ->
        state = reply_artifact_open(state, id, nil)
        retire_artifact(state, id, :cancelled, artifact_cancel_anchor(entry))
    end
  end

  defp artifact_original_down(state, id, kind, reason) do
    case Map.get(state.artifact_transfers, id) do
      nil ->
        state

      entry ->
        evidence = %{reason: reason, at: artifact_now()}
        key = if kind == :custodian, do: :custodian_down, else: :observer_down
        entry = Map.put(entry, key, evidence)
        entry = if entry.stopping and reason === :normal, do: entry, else: %{entry | lost: true}
        state = put_artifact_entry(state, entry)

        if entry.stopping do
          maybe_release_artifact(state, id)
        else
          retire_artifact(state, id, :transfers_unavailable, artifact_now())
        end
    end
  end

  defp maybe_release_artifact(state, id) do
    entry = Map.fetch!(state.artifact_transfers, id)

    if not entry.lost and match?(%{reason: :normal}, entry.custodian_down) and
         match?(%{reason: :normal}, entry.observer_down) and
         (entry.not_reserved or entry.acknowledged) do
      cancel_artifact_timer(entry.open_timer)
      cancel_artifact_timer(entry.close_timer)
      cancel_artifact_timer(entry.lifetime_timer)
      if entry.open_from, do: Process.demonitor(entry.caller_monitor, [:flush])

      monitors =
        state.artifact_monitors
        |> Map.delete(entry.custodian_monitor)
        |> Map.delete(entry.observer_monitor)
        |> Map.delete(entry.caller_monitor)

      state = %{
        state
        | artifact_transfers: Map.delete(state.artifact_transfers, id),
          artifact_monitors: monitors
      }

      state = forget_dead_artifact_holder(state, entry.holder)

      # Sample after actual original joins and the one serial capacity release.
      # Each outstanding reply gets its own strict final check, never renewed time.
      if entry.open_from do
        timely = artifact_cleanup_timely?(entry, artifact_now())

        GenServer.reply(
          entry.open_from,
          {:error, %{reason: entry.reason, cleanup: if(timely, do: :proved, else: :unproved)}}
        )
      end

      if entry.close_from do
        timely = artifact_cleanup_timely?(entry, artifact_now())
        GenServer.reply(entry.close_from, if(timely, do: :ok, else: {:error, :cleanup_unproved}))
      end

      state
    else
      state
    end
  end

  defp expire_artifact_cleanup(state, id) do
    case Map.get(state.artifact_transfers, id) do
      nil ->
        state

      entry ->
        state =
          reply_artifact_open(state, id, {:error, %{reason: entry.reason, cleanup: :unproved}})

        entry = Map.fetch!(state.artifact_transfers, id)
        if entry.close_from, do: GenServer.reply(entry.close_from, {:error, :cleanup_unproved})
        put_artifact_entry(state, %{entry | close_from: nil})
    end
  end

  defp reply_artifact_open(state, id, result) do
    entry = Map.fetch!(state.artifact_transfers, id)

    if entry.open_from do
      if result, do: GenServer.reply(entry.open_from, result)
      Process.demonitor(entry.caller_monitor, [:flush])
      monitors = Map.delete(state.artifact_monitors, entry.caller_monitor)
      %{put_artifact_entry(state, %{entry | open_from: nil}) | artifact_monitors: monitors}
    else
      state
    end
  end

  defp remove_artifact_public_transfer(state, entry) do
    case Map.get(state.attachments, entry.attachment_id) do
      nil ->
        state

      attachment ->
        report_transfer(attachment, entry.id, :released)

        put_attachment(state, %{
          attachment
          | transfers: Map.delete(attachment.transfers, entry.id),
            transfer_progress: Map.delete(attachment.transfer_progress, entry.id)
        })
    end
  end

  defp put_artifact_entry(state, entry),
    do: %{state | artifact_transfers: Map.put(state.artifact_transfers, entry.id, entry)}

  defp artifact_now, do: System.monotonic_time(:millisecond)
  defp cancel_artifact_timer(nil), do: :ok
  defp cancel_artifact_timer(timer), do: Process.cancel_timer(timer)

  # Concept: connection work survives detach, replacement and live-holder release.
  # Technical depth: reserve worst-case work before I/O; reconcile only bounded
  # original evidence. Debits never refund. Lost accounting retains its original
  # conservative reservation instead of becoming a fabricated zero debit.
  defp open_work_reservation(state),
    do:
      max(
        1_048_576,
        state.transfer_limits.open_work_bytes + state.transfer_limits.metadata_read_bytes
      )

  defp reserve_connection_work(state, holder, amount) do
    case Map.get(state.holders, holder) do
      %{alive: true, transfer_uncertain: false} = entry ->
        if entry.transfer_debit + entry.transfer_reserved + amount <= 1_073_741_824 do
          updated = %{entry | transfer_reserved: entry.transfer_reserved + amount}
          {:ok, %{state | holders: Map.put(state.holders, holder, updated)}}
        else
          {:error, :open_work_budget_exhausted}
        end

      _other ->
        {:error, :transfers_unavailable}
    end
  end

  defp settle_connection_work(state, holder, reserved, actual) do
    entry = Map.fetch!(state.holders, holder)

    updated = %{
      entry
      | transfer_reserved: entry.transfer_reserved - reserved,
        transfer_debit: entry.transfer_debit + actual
    }

    %{state | holders: Map.put(state.holders, holder, updated)}
  end

  defp settle_never_reserved(state, id) do
    entry = Map.fetch!(state.artifact_transfers, id)
    state = settle_connection_work(state, entry.holder, entry.work_reserved, 1_048_576)
    put_artifact_entry(state, %{entry | opening_charged: true})
  end

  defp settle_opening_work(state, id, work) do
    entry = Map.fetch!(state.artifact_transfers, id)

    cond do
      not entry.opening_charged and ArtifactStore.valid_transfer_work?(work) ->
        actual =
          max(
            1_048_576,
            work.source_read_bytes + work.snapshot_write_debit + work.metadata_read_bytes
          )

        state = settle_connection_work(state, entry.holder, entry.work_reserved, actual)
        put_artifact_entry(state, %{entry | opening_charged: true, opening_work: work})

      entry.opening_charged and entry.opening_work !== work and
          entry.opening_work !== :unavailable ->
        # A producer contradicting its earlier completed accounting cannot
        # renew credit. Keep the original maximum reservation and seal further
        # artifact admission on this original connection; never clamp evidence.
        holder = Map.fetch!(state.holders, entry.holder)

        previous =
          if is_map(entry.opening_work),
            do:
              max(
                1_048_576,
                entry.opening_work.source_read_bytes + entry.opening_work.snapshot_write_debit +
                  entry.opening_work.metadata_read_bytes
              ),
            else: 1_048_576

        holder = %{
          holder
          | transfer_reserved: holder.transfer_reserved + entry.work_reserved - previous,
            transfer_uncertain: true
        }

        state = %{state | holders: Map.put(state.holders, entry.holder, holder)}
        put_artifact_entry(state, %{entry | opening_work: :unavailable})

      true ->
        state
    end
  end

  defp forget_dead_artifact_holder(state, holder) do
    case Map.get(state.holders, holder) do
      %{alive: false} = entry ->
        occupied =
          Enum.any?(state.artifact_transfers, fn {_id, transfer} -> transfer.holder === holder end)

        if not occupied and MapSet.size(entry.pending) == 0 and
             MapSet.size(entry.attachments) == 0 do
          %{
            state
            | holders: Map.delete(state.holders, holder),
              holder_monitors: Map.delete(state.holder_monitors, entry.monitor)
          }
        else
          state
        end

      _other ->
        state
    end
  end

  # Concept: the ceiling this runtime admits, which a host may lower.
  defp diagnostics_ceiling(options) do
    case Keyword.get(options, :diagnostics_ceiling) do
      ceiling when is_integer(ceiling) and ceiling > 0 -> ceiling
      _absent -> DiagnosticsAdmission.default_ceiling()
    end
  end

  defp monitor_sender(state, pid) do
    if Map.has_key?(state.diagnostic_monitors, pid) do
      state
    else
      monitor = Process.monitor(pid)
      %{state | diagnostic_monitors: Map.put(state.diagnostic_monitors, pid, monitor)}
    end
  end

  # Concept: an admitted item reaches the sink, or is discarded and counted.
  #
  # Technical depth: a runtime with no diagnostics sink has the plane switched
  # off and discards without counting, because a drop nobody can read is not a
  # loss a summary should report forever. A configured sink that is dead or
  # already holding a ceiling's worth of messages is the host's mailbox, which
  # Loopex cannot bound; discarding there is best-effort backpressure and is
  # counted as the loss it is.
  defp forward_admitted(%{diagnostics_to: nil} = state, _item), do: state

  defp forward_admitted(state, item) do
    if plain_transient?(item) and not sink_saturated?(state) do
      maybe_send(state.diagnostics_to, {:loopex_diagnostic, item})
      state
    else
      DiagnosticsAdmission.count_drop(state.admission)
      state
    end
  end

  defp sink_saturated?(%{diagnostics_to: sink, admission: admission}) do
    case Process.info(sink, :message_queue_len) do
      {:message_queue_len, queued} -> queued >= admission.ceiling
      nil -> true
    end
  end

  # Concept: once the backlog has drained, the host learns how much it lost.
  #
  # Technical depth: the count is taken with one atomic exchange, and the
  # window is the ticket range since the previous summary, which both sides can
  # agree on without a shared clock. Reporting only below half the ceiling
  # keeps the summary from displacing an admitted item in a full backlog.
  defp report_drops(%{diagnostics_to: nil} = state), do: state

  defp report_drops(state) do
    if DiagnosticsAdmission.drained?(state.admission) and
         DiagnosticsAdmission.pending_drops(state.admission) > 0 do
      window_end = DiagnosticsAdmission.ticket(state.admission)
      dropped = DiagnosticsAdmission.take_drops(state.admission)

      if dropped > 0 do
        maybe_send(
          state.diagnostics_to,
          {:loopex_diagnostic, drop_summary(state.drop_window_start, window_end, dropped)}
        )

        %{state | drop_window_start: window_end}
      else
        state
      end
    else
      state
    end
  end

  defp drop_summary(from_ticket, to_ticket, dropped) do
    %{
      "kind" => "diagnostics_dropped",
      "dropped" => dropped,
      "window" => %{"from_ticket" => from_ticket, "to_ticket" => to_ticket}
    }
  end

  defp maybe_send(nil, _message), do: :ok
  defp maybe_send(pid, message) when is_pid(pid), do: send(pid, message)

  defp plain_transient?(value) do
    match?(
      {:ok, _items_left, _bytes_left},
      transient_budget(value, 0, @max_transient_items, @max_transient_bytes)
    )
  end

  defp transient_budget(_value, depth, _items, _bytes) when depth > 8, do: :error

  defp transient_budget(value, _depth, items, bytes)
       when is_binary(value) and items > 0 and byte_size(value) <= bytes,
       do: {:ok, items - 1, bytes - byte_size(value)}

  defp transient_budget(value, _depth, items, bytes)
       when (is_integer(value) or is_float(value) or is_boolean(value) or is_nil(value)) and
              items > 0 and bytes >= 16,
       do: {:ok, items - 1, bytes - 16}

  defp transient_budget(value, depth, items, bytes) when is_list(value) and items > 0 do
    Enum.reduce_while(value, {:ok, items - 1, bytes}, fn item, {:ok, left_items, left_bytes} ->
      case transient_budget(item, depth + 1, left_items, left_bytes) do
        {:ok, next_items, next_bytes} -> {:cont, {:ok, next_items, next_bytes}}
        :error -> {:halt, :error}
      end
    end)
  end

  defp transient_budget(value, depth, items, bytes) when is_map(value) and items > 0 do
    Enum.reduce_while(value, {:ok, items - 1, bytes}, fn {key, item},
                                                         {:ok, left_items, left_bytes} ->
      with {:ok, key_items, key_bytes} <-
             transient_budget(key, depth + 1, left_items, left_bytes),
           {:ok, next_items, next_bytes} <-
             transient_budget(item, depth + 1, key_items, key_bytes) do
        {:cont, {:ok, next_items, next_bytes}}
      else
        :error -> {:halt, :error}
      end
    end)
  end

  defp transient_budget(_value, _depth, _items, _bytes), do: :error
end
