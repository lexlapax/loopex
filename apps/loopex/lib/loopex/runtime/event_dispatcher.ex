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
       acknowledged: %{},
       counter: 0
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
        {:next_event, token, session_id, attachment_id, incarnation_id},
        _from,
        state
      ) do
    case fetch_attachment(state, token, session_id, attachment_id, incarnation_id) do
      {:ok, %{status: :active} = attachment} ->
        case :queue.out(attachment.queue) do
          {{:value, event}, queue} ->
            consumed = %{
              attachment
              | queue: queue,
                queue_depth: attachment.queue_depth - 1,
                cursor: event.event_sequence
            }

            next = put_attachment(state, consumed)
            {:reply, {:ok, event}, next}

          {:empty, _queue} ->
            pumped = pump(state, attachment)

            case :queue.out(pumped.queue) do
              {{:value, event}, queue} ->
                consumed = %{
                  pumped
                  | queue: queue,
                    queue_depth: pumped.queue_depth - 1,
                    cursor: event.event_sequence
                }

                next = put_attachment(state, consumed)
                {:reply, {:ok, event}, next}

              {:empty, _queue} when pumped.status == :active ->
                {:reply, {:error, :empty}, put_attachment(state, pumped)}

              {:empty, _queue} ->
                {:reply, {:disconnected, pumped.cursor}, put_attachment(state, pumped)}
            end
        end

      {:ok, attachment} ->
        {:reply, {:disconnected, attachment.cursor}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(
        {:attachment_status, token, session_id, attachment_id, incarnation_id},
        _from,
        state
      ) do
    reply =
      case fetch_attachment(state, token, session_id, attachment_id, incarnation_id) do
        {:ok, %{status: :active} = attachment} ->
          pumped = pump(state, attachment)

          {:ok,
           %{
             status: pumped.status,
             cursor: pumped.cursor,
             queue_depth: pumped.queue_depth,
             max_queue_depth: pumped.max_queue_depth,
             capacity: pumped.capacity
           }, pumped}

        {:ok, attachment} ->
          {:ok,
           %{
             status: attachment.status,
             cursor: attachment.cursor,
             queue_depth: attachment.queue_depth,
             max_queue_depth: attachment.max_queue_depth,
             capacity: attachment.capacity
           }, attachment}

        {:error, reason} ->
          {:error, reason}
      end

    case reply do
      {:ok, status, attachment} -> {:reply, {:ok, status}, put_attachment(state, attachment)}
      {:error, reason} -> {:reply, {:error, reason}, state}
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

  def handle_call({:acknowledge, session_id, position}, _from, state) do
    acknowledged = Map.update(state.acknowledged, session_id, position, &max(&1, position))
    {:reply, :ok, %{state | acknowledged: acknowledged}}
  end

  @impl GenServer
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

    {:noreply, %{state | attachments: retained, pending_scans: pending_scans}}
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

        GenServer.reply(pending.from, reply)
        {:noreply, next}
    end
  end

  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    case Enum.find(state.pending_scans, fn {_scan_id, pending} ->
           pending.caller_monitor == monitor
         end) do
      nil ->
        {:noreply, state}

      {scan_id, pending} ->
        Process.exit(pending.worker, :kill)
        {:noreply, %{state | pending_scans: Map.delete(state.pending_scans, scan_id)}}
    end
  end

  def handle_info({:EXIT, worker, _reason}, state) do
    case Enum.find(state.pending_scans, fn {_scan_id, pending} -> pending.worker == worker end) do
      nil ->
        {:noreply, state}

      {scan_id, pending} ->
        Process.demonitor(pending.caller_monitor, [:flush])
        GenServer.reply(pending.from, {:error, :store_unavailable})
        {:noreply, %{state | pending_scans: Map.delete(state.pending_scans, scan_id)}}
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
        metadata: transient_metadata(pending.options)
      }

      attachment = pump(state, attachment)

      retained =
        state.attachments
        |> Enum.reject(fn {_id, existing} -> existing.session_id == pending.session_id end)
        |> Map.new()

      next = %{
        state
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
