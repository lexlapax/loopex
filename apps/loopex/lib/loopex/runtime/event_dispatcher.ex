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

  Attachments, queued events, progress, and diagnostics are redacted from OTP
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

  Optional progress and diagnostic sinks receive best-effort messages through
  ordinary `send/2`; their mailbox state is outside the runtime and never a
  coordinator barrier.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options) when is_list(options), do: GenServer.start_link(__MODULE__, options)

  @doc false
  @spec attach(pid(), reference(), binary(), keyword()) :: {:ok, map()} | {:error, term()}
  def attach(dispatcher, token, session_id, options),
    do: GenServer.call(dispatcher, {:attach, token, session_id, options}, :infinity)

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

    {:ok,
     %{
       token: Keyword.fetch!(options, :token),
       store: Keyword.fetch!(options, :store),
       capacity: Keyword.fetch!(options, :attachment_capacity),
       progress_to: Keyword.fetch!(options, :progress_to),
       diagnostics_to: Keyword.fetch!(options, :diagnostics_to),
       attachments: %{},
       pending_scans: %{},
       pending_reads: %{},
       read_monitors: %{},
       acknowledged: %{},
       counter: 0,
       admission: DiagnosticsAdmission.new(diagnostics_ceiling(options)),
       diagnostic_monitors: %{},
       drop_window_start: 0,
       artifact_store: Keyword.get(options, :artifact_store),
       transfer_limits: ArtifactStore.transfer_limits()
     }}
  end

  @impl GenServer
  def handle_call({:attach, token, session_id, options}, from, state) do
    with true <- token == state.token,
         true <- is_binary(session_id) do
      scan_id = make_ref()
      parent = self()
      store = state.store
      bound = scan_bound(state, session_id)

      worker =
        spawn_link(fn ->
          send(
            parent,
            {:attachment_scan_finished, scan_id,
             scan_attachment(store, session_id, options[:after_event_sequence], bound)}
          )
        end)

      pending = %{
        from: from,
        worker: worker,
        caller_monitor: Process.monitor(elem(from, 0)),
        session_id: session_id,
        options: options
      }

      next = %{state | pending_scans: Map.put(state.pending_scans, scan_id, pending)}
      {:noreply, next}
    else
      false -> {:reply, {:error, :invalid_attachment}, state}
    end
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

  def handle_call(
        {:progress, token, session_id, attachment_id, incarnation_id, item},
        _from,
        state
      ) do
    reply =
      with :ok <- validate_attachment(state, token, session_id, attachment_id, incarnation_id),
           true <- plain_transient?(item) do
        maybe_send(state.progress_to, {:loopex_progress, session_id, item})
        :ok
      else
        false -> {:error, :invalid_progress}
        {:error, reason} -> {:error, reason}
      end

    {:reply, reply, state}
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
  # Concept: the artifact transfer family, owned by the attachment that opened
  # it.
  #
  # Technical depth: accepted ADR 0028 binds a transfer to one session and one
  # attachment, so every call here revalidates that attachment before touching
  # the store, and a reference another attachment opened is unknown rather than
  # readable. The store does the reading; this process holds only the bounded
  # plain references and the per-attachment ceiling.
  def handle_call(
        {:open_transfer, token, session_id, attachment_id, incarnation_id, request},
        _from,
        state
      ) do
    with {:ok, attachment} <-
           fetch_attachment(state, token, session_id, attachment_id, incarnation_id),
         {:ok, store} <- artifact_store(state),
         :ok <- transfer_headroom(attachment, state),
         {:ok, object} <- transfer_object(request),
         {:ok, use_locator} <- transfer_use(request),
         {:ok, transfer} <-
           Instrumentation.span(
             [:artifact, :open_transfer],
             %{
               session_id: attachment.session_id,
               attachment_id: attachment.id,
               locator: object.locator,
               bytes: object.size
             },
             fn ->
               store.module.open_transfer(
                 store.handle,
                 object,
                 use_locator,
                 transfer_window(request)
               )
             end
           ) do
      next = %{
        attachment
        | transfers: Map.put(attachment.transfers, transfer.transfer_ref, transfer),
          transfer_progress:
            Map.put(
              attachment.transfer_progress,
              transfer.transfer_ref,
              new_progress(attachment, transfer.transfer_ref, object)
            )
      }

      {:reply, {:ok, Map.delete(transfer, :object)}, put_attachment(state, next)}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(
        {:read_transfer, token, session_id, attachment_id, incarnation_id, transfer_ref, length},
        _from,
        state
      ) do
    with {:ok, attachment} <-
           fetch_attachment(state, token, session_id, attachment_id, incarnation_id),
         {:ok, store} <- artifact_store(state),
         {:ok, transfer} <- Map.fetch(attachment.transfers, transfer_ref) do
      result =
        Instrumentation.span(
          [:artifact, :read_transfer],
          %{
            session_id: attachment.session_id,
            attachment_id: attachment.id,
            transfer_ref: transfer_ref,
            requested: length
          },
          fn -> store.module.read_transfer(store.handle, transfer, length) end,
          &read_category/1
        )

      {:reply, result, put_attachment(state, record_read(attachment, transfer_ref, result))}
    else
      :error -> {:reply, {:error, :unknown_transfer}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(
        {:close_transfer, token, session_id, attachment_id, incarnation_id, transfer_ref},
        _from,
        state
      ) do
    with {:ok, attachment} <-
           fetch_attachment(state, token, session_id, attachment_id, incarnation_id),
         {:ok, store} <- artifact_store(state),
         {:ok, transfer} <- Map.fetch(attachment.transfers, transfer_ref) do
      _released =
        Instrumentation.span(
          [:artifact, :close_transfer],
          %{
            session_id: attachment.session_id,
            attachment_id: attachment.id,
            transfer_ref: transfer_ref
          },
          fn -> store.module.close_transfer(store.handle, transfer) end
        )

      report_transfer(attachment, transfer_ref, :closed)

      next = %{
        attachment
        | transfers: Map.delete(attachment.transfers, transfer_ref),
          transfer_progress: Map.delete(attachment.transfer_progress, transfer_ref)
      }

      {:reply, :ok, put_attachment(state, next)}
    else
      :error -> {:reply, {:error, :unknown_transfer}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
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

  def handle_cast({:release_fence, session_id}, state),
    do: {:noreply, %{state | acknowledged: Map.delete(state.acknowledged, session_id)}}

  def handle_cast({:invalidate, session_id}, state) do
    retained =
      state.attachments
      |> Enum.reject(fn {_id, attachment} -> attachment.session_id == session_id end)
      |> Map.new()

    {cancelled, pending_scans} =
      Enum.reduce(state.pending_scans, {[], %{}}, fn {scan_id, pending},
                                                     {cancelled, retained_scans} ->
        if pending.session_id == session_id do
          {[pending | cancelled], retained_scans}
        else
          {cancelled, Map.put(retained_scans, scan_id, pending)}
        end
      end)

    Enum.each(cancelled, fn pending ->
      Process.demonitor(pending.caller_monitor, [:flush])
      Process.exit(pending.worker, :kill)
      GenServer.reply(pending.from, {:error, :attachment_superseded})
    end)

    next = cancel_session_reads(state, session_id)
    {:noreply, %{next | attachments: retained, pending_scans: pending_scans}}
  end

  @impl GenServer
  def handle_info({:attachment_scan_finished, scan_id, result}, state) do
    case Map.pop(state.pending_scans, scan_id) do
      {nil, _pending_scans} ->
        {:noreply, state}

      {pending, pending_scans} ->
        Process.demonitor(pending.caller_monitor, [:flush])

        {reply, next} =
          install_attachment(%{state | pending_scans: pending_scans}, pending, result)

        case reply do
          {:ok, %{id: id} = installed} ->
            call = %{
              operation: {:attach, installed},
              from: pending.from,
              monitor: Process.monitor(elem(pending.from, 0))
            }

            {:noreply, start_read(next, Map.fetch!(next.attachments, id), call)}

          error ->
            GenServer.reply(pending.from, error)
            {:noreply, next}
        end
    end
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

  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    case Enum.find(state.pending_scans, fn {_scan_id, pending} ->
           pending.caller_monitor == monitor
         end) do
      nil ->
        {:noreply, cancel_read_caller(state, monitor)}

      {scan_id, pending} ->
        Process.exit(pending.worker, :kill)
        {:noreply, %{state | pending_scans: Map.delete(state.pending_scans, scan_id)}}
    end
  end

  def handle_info({:EXIT, worker, _reason}, state) do
    case Enum.find(state.pending_scans, fn {_scan_id, pending} -> pending.worker == worker end) do
      nil ->
        case Enum.find(state.pending_reads, fn {_id, pending} ->
               pending.worker == worker
             end) do
          nil ->
            {:noreply, state}

          {id, pending} ->
            failed = disconnect(pending.attachment, :store_unavailable)
            {:noreply, finish_read(state, id, pending, failed)}
        end

      {scan_id, pending} ->
        Process.demonitor(pending.caller_monitor, [:flush])
        GenServer.reply(pending.from, {:error, :store_unavailable})
        {:noreply, %{state | pending_scans: Map.delete(state.pending_scans, scan_id)}}
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

  defp cancel_session_reads(state, session_id) do
    Enum.reduce(state.pending_reads, state, fn {id, pending}, current ->
      if pending.session_id == session_id do
        Process.exit(pending.worker, :kill)
        reply_read(pending.current, {:error, :stale_attachment})
        remove_read(current, id, pending)
      else
        current
      end
    end)
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

  defp install_attachment(
         state,
         pending,
         {:ok,
          %{
            tail: tail,
            snapshot: %{session_id: session_id, event_sequence: anchor} = snapshot
          }}
       )
       when session_id == pending.session_id and is_integer(tail) and tail >= anchor do
    if is_integer(anchor) and anchor >= 0 do
      counter = state.counter + 1
      attachment_id = fresh_id("attachment", pending.session_id, counter)
      incarnation_id = fresh_id("incarnation", pending.session_id, counter)

      attachment = %{
        id: attachment_id,
        incarnation_id: incarnation_id,
        session_id: pending.session_id,
        cursor: anchor,
        seen: anchor,
        replay_until: tail,
        queue: :queue.new(),
        queue_depth: 0,
        max_queue_depth: 0,
        capacity: state.capacity,
        status: :active,
        metadata: transient_metadata(pending.options),
        # The artifact transfers this attachment opened. Accepted ADR 0028 binds
        # a transfer to the attachment that opened it, so detaching, replacement
        # and overflow all release exactly what that attachment held and nothing
        # another one is still reading.
        transfers: %{},
        # What each open transfer has moved so far, for the lifecycle report a
        # transfer owes when it ends. Kept beside the transfers rather than
        # inside them, because the transfer term is the store's and is handed
        # back to it on every read.
        transfer_progress: %{}
      }

      # Concept: a replaced attachment's transfers end with it.
      #
      # Technical depth: accepted ADR 0028 releases every transfer the
      # attachment opened when it goes away, and a replacement is one of the
      # ways it goes away. Releasing here rather than waiting for the lifetime
      # timer is what keeps a reconnecting caller from holding descriptors it
      # can no longer read through.
      {superseded, kept} =
        Enum.split_with(state.attachments, fn {_id, existing} ->
          existing.session_id == pending.session_id
        end)

      Enum.each(superseded, fn {_id, existing} -> release_transfers(state, existing) end)
      retained = Map.new(kept)

      next = %{
        cancel_session_reads(state, pending.session_id)
        | counter: counter,
          attachments: Map.put(retained, attachment_id, attachment)
      }

      reply = %{
        id: attachment_id,
        incarnation_id: incarnation_id,
        snapshot: snapshot
      }

      {{:ok, reply}, next}
    else
      {{:error, :invalid_store_page}, state}
    end
  end

  defp install_attachment(state, _pending, :unavailable),
    do: {{:error, :store_unavailable}, state}

  defp install_attachment(state, _pending, {:error, reason}),
    do: {{:error, reason}, state}

  defp install_attachment(state, _pending, _result),
    do: {{:error, :invalid_store_page}, state}

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

  defp scan_attachment(store, session_id, requested_anchor, bound) do
    with {:ok, scan} <- SessionState.start_snapshot_scan(session_id, requested_anchor) do
      scan_event_pages(store, session_id, 0, scan, bound)
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

  defp fresh_id(namespace, session_id, counter) do
    bytes = :erlang.term_to_binary([namespace, session_id, counter, make_ref()], [:deterministic])
    encoded = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
    namespace <> "_" <> binary_part(encoded, 0, 30)
  end

  # Concept: the artifact store this runtime was composed with, if any.
  #
  # Technical depth: a runtime without one refuses the transfer family as
  # unsupported rather than reaching for a default, and so does a store whose
  # adapter predates the transfer triple. Both are bounded refusals a caller can
  # act on, which is what the capability check exists for.
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
    update_in(attachment.transfer_progress[transfer_ref], fn
      nil ->
        nil

      progress ->
        %{progress | bytes: progress.bytes + byte_size(bytes), chunks: progress.chunks + 1}
    end)
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
    if map_size(attachment.transfers) < state.transfer_limits.per_attachment,
      do: :ok,
      else: {:error, :transfer_limit_reached}
  end

  # Concept: a caller names an object and the use that describes it, and
  # nothing else crosses this boundary.
  #
  # Technical depth: the request is bounded plain data. No path, no adapter
  # handle and no private provenance appears in it or in what comes back: the
  # open response drops the object record the store resolved, because a caller
  # already holds the compact reference it named.
  defp transfer_object(%{object: %{digest: digest, size: size, locator: locator}})
       when is_binary(digest) and is_integer(size) and size >= 0 and is_binary(locator),
       do: {:ok, %{digest: digest, size: size, locator: locator}}

  defp transfer_object(_request), do: {:error, :invalid_artifact_request}

  defp transfer_use(%{use_locator: "use:" <> _digest = use_locator}), do: {:ok, use_locator}
  defp transfer_use(_request), do: {:error, :invalid_artifact_request}

  defp transfer_window(request) do
    %{start: Map.get(request, :start, 0)}
    |> then(fn window ->
      case Map.get(request, :length) do
        nil -> window
        length -> Map.put(window, :length, length)
      end
    end)
  end

  defp release_transfers(state, attachment) do
    case artifact_store(state) do
      {:ok, store} ->
        Enum.each(attachment.transfers, fn {ref, transfer} ->
          store.module.close_transfer(store.handle, transfer)
          report_transfer(attachment, ref, :released)
        end)

      {:error, _unsupported} ->
        :ok
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
