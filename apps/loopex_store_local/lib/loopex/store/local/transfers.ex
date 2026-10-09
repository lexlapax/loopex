defmodule Loopex.Store.Local.Transfers do
  @moduledoc """
  ## Concept

  The live transfers of one composed local artifact store. A transfer is opened
  once against an immutable object, verified whole before any chunk exists, and
  then read in bounded pieces until the caller closes it or its lifetime ends.

  ## Technical depth

  The responsive owner retains original caller bindings, four shared slots and
  retirement receipts. One original monitored I/O actor per transfer resolves the
  actual use, verifies the whole object into a private unlinked snapshot, and
  remains its reader until retirement. Accepted ADR0066 gives reserve/open one
  original context and clock; cancellation never queues behind filesystem I/O.
  The owner accepts physical retirement only after explicit descriptor cleanup
  and that actor's original normal DOWN. Retired proof retains its slot until an
  exact receipt acknowledgement; actor loss leaves occupied uncertainty.

  Nothing here is VM-global. A store composes one of these and carries it in its
  own handle, so two runtimes on one machine share no transfer state and neither
  can see the other's descriptors.
  """

  use GenServer

  alias Loopex.ArtifactStore

  @verify_block 64 * 1024
  @scratch "transfers"

  @doc """
  ## Concept

  Starts the transfer owner for one store root.

  ## Technical depth

  Unregistered: the caller keeps the pid in the store handle. Starting scavenges
  the scratch root, deleting only regular files it owns and never following
  links, which is the bounded defence for a platform or crash that left a
  snapshot behind before it could be unlinked.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options) when is_list(options), do: GenServer.start_link(__MODULE__, options)

  @doc false
  @spec reserve(pid(), map(), map()) :: {:ok, map()} | {:error, term()}
  def reserve(owner, request, context),
    do: GenServer.call(owner, {:reserve, request, context}, :infinity)

  @doc false
  @spec open(pid(), map(), map()) :: {:ok, map()} | {:error, term()}
  def open(owner, request, context),
    do: GenServer.call(owner, {:open, request, context}, :infinity)

  @doc false
  @spec read(pid(), binary(), pos_integer()) :: term()
  def read(owner, transfer_ref, length),
    do: GenServer.call(owner, {:read, transfer_ref, length}, :infinity)

  @doc false
  @spec close(pid(), map()) :: term()
  def close(owner, selector), do: GenServer.call(owner, {:close, selector}, :infinity)

  @doc false
  @spec live(pid()) :: [binary()]
  def live(owner) when is_pid(owner), do: GenServer.call(owner, :live)

  @doc false
  @spec reserve_job(pid(), integer()) :: {:ok, map()} | {:error, atom()}
  def reserve_job(owner, deadline),
    do: GenServer.call(owner, {:reserve_job, deadline}, :infinity)

  @doc false
  @spec release_job(pid(), reference()) :: :ok
  def release_job(owner, monitor), do: GenServer.call(owner, {:release_job, monitor}, :infinity)

  @doc false
  @spec job_window(map(), map(), map(), integer(), pid()) :: {:ok, binary()} | {:error, term()}
  def job_window(state, object, window, deadline, guardian) do
    with {:ok, source} <- object_path(state, object),
         {:ok, size} <- object_size(source, state.limits),
         :ok <- exact_size(size, object),
         {:ok, bounds} <- window_bounds(window, size),
         :ok <- reserve_open_work(size, state.limits.open_work_bytes),
         {:ok, snapshot, digest} <-
           verify_into_snapshot(state, source, size,
             open_deadline_ms:
               min(state.limits.open_deadline_ms, deadline - System.monotonic_time(:millisecond)),
             work_observer: guardian
           ) do
      try do
        if digest == object.digest do
          send(guardian, {:job_read_phase, self(), System.monotonic_time(:millisecond)})

          if bounds.length == 0 do
            {:ok, ""}
          else
            case :file.pread(snapshot, bounds.start, bounds.length) do
              {:ok, bytes} when byte_size(bytes) == bounds.length ->
                charge(guardian, :emitted, byte_size(bytes))
                {:ok, bytes}

              {:ok, bytes} ->
                charge(guardian, :emitted, byte_size(bytes))
                {:error, :artifact_unreadable}

              _ ->
                {:error, :artifact_unreadable}
            end
          end
        else
          {:error, :artifact_digest_mismatch}
        end
      after
        File.close(snapshot)
      end
    end
  end

  defp reserve_open_work(size, budget) do
    if 2 * size <= budget, do: :ok, else: {:error, :open_work_budget_exhausted}
  end

  @impl GenServer
  def init(options) do
    root = Keyword.fetch!(options, :root)
    scratch = Path.join(root, @scratch)
    File.mkdir_p!(scratch)
    scavenge(scratch)

    {:ok,
     %{
       root: root,
       scratch: scratch,
       limits: Keyword.get(options, :limits, ArtifactStore.transfer_limits()),
       transfers: %{},
       jobs: %{}
     }}
  end

  @impl GenServer
  def handle_call({:reserve_job, deadline}, {caller, _tag}, state) do
    with true <- Process.alive?(caller) and System.monotonic_time(:millisecond) < deadline,
         :ok <- admit_count(state) do
      monitor = Process.monitor(caller)
      placement = state |> Map.take([:root, :scratch, :limits]) |> Map.put(:job_monitor, monitor)
      {:reply, {:ok, placement}, %{state | jobs: Map.put(state.jobs, monitor, caller)}}
    else
      false -> {:reply, {:error, :open_deadline_exhausted}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:release_job, monitor}, {caller, _tag}, state) do
    if Map.get(state.jobs, monitor) == caller do
      Process.demonitor(monitor, [:flush])
      {:reply, :ok, %{state | jobs: Map.delete(state.jobs, monitor)}}
    else
      {:reply, :ok, state}
    end
  end

  # Concept: reservation owns capacity and the original caller before any I/O.
  # Technical depth: exact immutable request/context and one-use state prevent a
  # queued, changed or revoked opening from acquiring descriptors later.
  def handle_call({:reserve, request, context}, {caller, _tag}, state) do
    cond do
      not ArtifactStore.valid_transfer_request?(request) ->
        {:reply, {:error, :invalid_artifact_request}, state}

      not ArtifactStore.valid_open_context?(context) ->
        {:reply, {:error, :invalid_open_context}, state}

      Map.has_key?(state.transfers, context.transfer_ref) ->
        {:reply, {:error, :reservation_conflict}, state}

      not timely?(context.open_deadline_ms) or not Process.alive?(caller) ->
        {:reply, not_reserved(context, :open_deadline_exhausted), state}

      true ->
        case admit_count(state) do
          :ok ->
            monitor = Process.monitor(caller)

            record = %{
              request: request,
              context: context,
              caller: caller,
              caller_monitor: monitor,
              status: :reserved,
              worker: nil,
              worker_monitor: nil,
              work: empty_work(),
              proof: false,
              worker_joined: false,
              outcome: nil,
              open_from: nil,
              read_from: nil,
              close_from: nil,
              close_deadline: nil,
              close_selector_deadline: nil,
              close_timer: nil,
              read_timer: nil,
              read_deadline: nil,
              receipt: nil,
              timer: nil,
              lifetime_deadline: nil
            }

            if timely?(context.open_deadline_ms) and Process.alive?(caller) do
              next = put_record(state, context.transfer_ref, record)
              {:reply, {:ok, %{transfer_ref: context.transfer_ref}}, next}
            else
              Process.demonitor(monitor, [:flush])
              {:reply, not_reserved(context, :open_deadline_exhausted), state}
            end

          {:error, reason} ->
            {:reply, not_reserved(context, reason), state}
        end
    end
  end

  def handle_call({:open, request, context}, {caller, _tag} = from, state) do
    with true <- ArtifactStore.valid_transfer_request?(request),
         true <- ArtifactStore.valid_open_context?(context),
         {:ok, record} <- Map.fetch(state.transfers, context.transfer_ref),
         true <-
           record.request == request and record.context == context and record.caller == caller,
         true <- record.status == :reserved do
      if timely?(context.open_deadline_ms) and Process.alive?(caller) do
        owner = self()
        placement = Map.take(state, [:root, :scratch, :limits])

        {worker, monitor} =
          spawn_monitor(fn -> transfer_io(owner, placement, request, context) end)

        record = %{
          record
          | status: :verifying,
            worker: worker,
            worker_monitor: monitor,
            open_from: from
        }

        {:noreply, put_record(state, context.transfer_ref, record)}
      else
        record =
          record |> Map.put(:outcome, {:error, :open_deadline_exhausted}) |> retire_reserved()

        {:reply, open_failure(record), put_record(state, context.transfer_ref, record)}
      end
    else
      :error -> {:reply, {:error, :reservation_required}, state}
      false -> {:reply, {:error, :reservation_conflict}, state}
    end
  end

  def handle_call({:read, id, length}, from, state) do
    case Map.fetch(state.transfers, id) do
      {:ok, %{status: :live, read_from: nil} = record}
      when is_integer(length) and length > 0 ->
        deadline = System.monotonic_time(:millisecond) + state.limits.read_deadline_ms

        timer =
          Process.send_after(self(), {:read_expired, id, deadline}, state.limits.read_deadline_ms)

        send(record.worker, {:transfer_read, self(), id, length, deadline})
        record = %{record | read_from: from, read_deadline: deadline, read_timer: timer}
        {:noreply, put_record(state, id, record)}

      {:ok, %{status: :live}} when not (is_integer(length) and length > 0) ->
        {:reply, {:error, :invalid_chunk_length}, state}

      _ ->
        {:reply, {:error, :unknown_transfer}, state}
    end
  end

  def handle_call({:close, selector}, from, state) do
    if ArtifactStore.valid_close_context?(selector) do
      close_entry(state, selector, from)
    else
      {:reply, {:error, :invalid_close_context}, state}
    end
  end

  def handle_call(:live, _from, state), do: {:reply, Map.keys(state.transfers), state}

  @impl GenServer
  def handle_info({:transfer_work, id, worker, work}, state) do
    case Map.fetch(state.transfers, id) do
      {:ok, %{worker: ^worker} = record} ->
        {:noreply, put_record(state, id, %{record | work: work})}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:transfer_opened, id, worker, transfer, use, work}, state) do
    case Map.fetch(state.transfers, id) do
      {:ok, %{worker: ^worker, status: :verifying} = record} ->
        if timely?(record.context.open_deadline_ms) and Process.alive?(record.caller) do
          GenServer.reply(record.open_from, {:ok, %{transfer: transfer, use: use, work: work}})
          deadline = System.monotonic_time(:millisecond) + state.limits.lifetime_ms
          timer = Process.send_after(self(), {:expire, id}, state.limits.lifetime_ms)

          record = %{
            record
            | status: :live,
              work: work,
              open_from: nil,
              timer: timer,
              lifetime_deadline: deadline
          }

          {:noreply, put_record(state, id, record)}
        else
          record = %{record | outcome: {:error, :open_deadline_exhausted}, work: work}
          {:noreply, begin_retirement(state, id, record, record.context.open_deadline_ms + 5_000)}
        end

      {:ok, %{worker: ^worker} = record} ->
        send(worker, {:transfer_retire, self(), id})
        {:noreply, put_record(state, id, %{record | work: work})}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:transfer_read_result, id, worker, result}, state) do
    case Map.fetch(state.transfers, id) do
      {:ok, %{worker: ^worker, status: :live, read_from: from} = record} when not is_nil(from) ->
        cancel_timer(record.read_timer)

        reply =
          if timely?(record.read_deadline), do: result, else: {:error, :read_deadline_exhausted}

        GenServer.reply(from, reply)
        deadline = record.read_deadline
        record = %{record | read_from: nil, read_timer: nil, read_deadline: nil}

        if reply == {:error, :read_deadline_exhausted} do
          {:noreply, begin_retirement(state, id, record, deadline + 5_000)}
        else
          {:noreply, put_record(state, id, record)}
        end

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:transfer_retired, id, worker, outcome, work, proof}, state) do
    case Map.fetch(state.transfers, id) do
      {:ok, %{worker: ^worker} = record} ->
        record = %{record | status: :retiring, outcome: outcome, work: work, proof: proof}
        {:noreply, put_record(state, id, record)}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, monitor, :process, pid, reason}, state) do
    case Enum.find(state.transfers, fn {_id, record} ->
           record.worker_monitor == monitor and record.worker == pid
         end) do
      {id, record} ->
        record = %{record | worker_joined: true}

        record =
          if reason == :normal and record.proof do
            %{record | status: :retired, receipt: reference()}
          else
            %{record | status: :retiring, work: :unavailable, proof: false}
          end

        finish_waiters(record)
        record = %{record | open_from: nil, close_from: nil, read_from: nil}
        {:noreply, put_record(state, id, record)}

      nil ->
        case Enum.find(state.transfers, fn {_id, record} ->
               record.caller_monitor == monitor and record.caller == pid
             end) do
          {id, record} ->
            deadline = System.monotonic_time(:millisecond) + 5_000
            {:noreply, begin_retirement(state, id, record, deadline)}

          nil ->
            {:noreply, %{state | jobs: Map.delete(state.jobs, monitor)}}
        end
    end
  end

  def handle_info({:expire, id}, state) do
    case Map.fetch(state.transfers, id) do
      {:ok, record} ->
        {:noreply, begin_retirement(state, id, record, record.lifetime_deadline + 5_000)}

      :error ->
        {:noreply, state}
    end
  end

  def handle_info({:close_expired, id, deadline}, state) do
    case Map.fetch(state.transfers, id) do
      {:ok, %{close_deadline: ^deadline, close_from: from} = record} when not is_nil(from) ->
        GenServer.reply(from, {:error, :cleanup_unproved})
        {:noreply, put_record(state, id, %{record | close_from: nil})}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:read_expired, id, deadline}, state) do
    case Map.fetch(state.transfers, id) do
      {:ok, %{read_deadline: ^deadline, read_from: from} = record} when not is_nil(from) ->
        GenServer.reply(from, {:error, :read_deadline_exhausted})
        record = %{record | read_from: nil, read_deadline: nil}
        {:noreply, begin_retirement(state, id, record, deadline + 5_000)}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, state) do
    Enum.each(state.transfers, fn {id, record} ->
      if record.worker, do: send(record.worker, {:transfer_retire, self(), id})
    end)

    Enum.each(state.jobs, fn {_ref, worker} -> Process.exit(worker, :kill) end)
    :ok
  end

  defp close_entry(state, %{action: :acknowledge} = selector, _from) do
    case Map.fetch(state.transfers, selector.transfer_ref) do
      :error ->
        {:reply, :ok, state}

      {:ok, %{status: :retired, receipt: receipt} = record}
      when receipt == selector.receipt_ref ->
        Process.demonitor(record.caller_monitor, [:flush])
        cancel_timer(record.timer)
        cancel_timer(record.close_timer)
        {:reply, :ok, %{state | transfers: Map.delete(state.transfers, selector.transfer_ref)}}

      _ ->
        {:reply, {:error, :retirement_receipt_mismatch}, state}
    end
  end

  defp close_entry(state, %{action: :retire} = selector, from) do
    id = selector.transfer_ref

    case Map.fetch(state.transfers, id) do
      :error ->
        {:reply, {:unregistered, %{transfer_ref: id}}, state}

      {:ok, record} ->
        cond do
          record.context.open_deadline_ms != selector.open_deadline_ms ->
            {:reply, {:error, :invalid_close_context}, state}

          record.close_selector_deadline != nil and
              record.close_selector_deadline != selector.close_deadline_ms ->
            {:reply, {:error, :invalid_close_context}, state}

          record.status == :retired ->
            record = %{record | close_selector_deadline: selector.close_deadline_ms}
            {:reply, retired_reply(record), put_record(state, id, record)}

          record.close_from != nil ->
            {:reply, {:error, :cleanup_unproved}, state}

          true ->
            record = %{record | close_selector_deadline: selector.close_deadline_ms}
            next = begin_retirement(state, id, record, selector.close_deadline_ms)
            record = Map.fetch!(next.transfers, id)

            cond do
              record.status == :retired -> {:reply, retired_reply(record), next}
              not timely?(record.close_deadline) -> {:reply, {:error, :cleanup_unproved}, next}
              true -> {:noreply, put_record(next, id, %{record | close_from: from})}
            end
        end
    end
  end

  defp begin_retirement(state, id, record, deadline) do
    deadline = if record.close_deadline, do: min(record.close_deadline, deadline), else: deadline
    cancel_timer(record.timer)

    record =
      cond do
        record.status == :retired ->
          record

        record.worker == nil ->
          retire_reserved(record)

        true ->
          send(record.worker, {:transfer_retire, self(), id})
          %{record | status: :retiring, outcome: record.outcome || {:error, :cancelled}}
      end

    timer =
      record.close_timer ||
        Process.send_after(
          self(),
          {:close_expired, id, deadline},
          max(0, deadline - System.monotonic_time(:millisecond))
        )

    put_record(state, id, %{record | close_deadline: deadline, close_timer: timer})
  end

  defp retire_reserved(record),
    do: %{record | status: :retired, proof: true, worker_joined: true, receipt: reference()}

  defp finish_waiters(record) do
    cancel_timer(record.close_timer)
    cancel_timer(record.read_timer)
    if record.open_from, do: GenServer.reply(record.open_from, open_failure(record))

    if record.read_from do
      reason =
        if record.outcome == {:error, :read_deadline_exhausted},
          do: :read_deadline_exhausted,
          else: :unknown_transfer

      GenServer.reply(record.read_from, {:error, reason})
    end

    if record.close_from do
      reply =
        if record.status == :retired and timely?(record.close_deadline),
          do: retired_reply(record),
          else: {:error, :cleanup_unproved}

      GenServer.reply(record.close_from, reply)
    end
  end

  defp open_failure(%{work: :unavailable}), do: {:error, :transfers_unavailable}

  defp open_failure(record) do
    reason =
      case record.outcome do
        {:error, reason} -> reason
        _ -> :cancelled
      end

    {:error,
     %{
       reason: reason,
       transfer_ref: record.context.transfer_ref,
       work: record.work,
       state: record.status
     }}
  end

  defp retired_reply(record),
    do:
      {:retired,
       %{
         transfer_ref: record.context.transfer_ref,
         receipt_ref: record.receipt,
         work: record.work
       }}

  defp not_reserved(context, reason),
    do: {:error, %{reason: reason, transfer_ref: context.transfer_ref, state: :not_reserved}}

  defp put_record(state, id, record),
    do: %{state | transfers: Map.put(state.transfers, id, record)}

  defp timely?(deadline), do: System.monotonic_time(:millisecond) < deadline
  defp cancel_timer(nil), do: :ok
  defp cancel_timer(timer), do: Process.cancel_timer(timer)

  defp empty_work,
    do: %{
      source_read_bytes: 0,
      snapshot_write_debit: 0,
      metadata_read_bytes: 0,
      write_uncertain: false
    }

  defp emit(record, length, limits) do
    remaining = record.window_start + record.window_length - record.cursor

    cond do
      not (is_integer(length) and length > 0) ->
        {{:error, :invalid_chunk_length}, record}

      remaining <= 0 ->
        {{:ok, :complete}, record}

      true ->
        wanted = Enum.min([length, limits.chunk_bytes, remaining])

        case :file.pread(record.device, record.cursor, wanted) do
          {:ok, bytes} when byte_size(bytes) == wanted ->
            chunk = %{
              offset: record.cursor,
              bytes: bytes,
              chunk_digest: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)
            }

            {{:ok, chunk}, %{record | cursor: record.cursor + wanted}}

          _short_or_error ->
            {{:error, :artifact_unreadable}, record}
        end
    end
  end

  # Concept: the whole object is verified once, into the snapshot the chunks
  # will come from.
  #
  # Technical depth: a fixed buffer and no whole-object accumulator, so peak
  # memory is the buffer rather than the object. The work budget counts both the
  # source read and the snapshot write, and the deadline is elapsed time from
  # the start of this pass, so an object that is large or a filesystem that is
  # slow refuses rather than running unbounded.
  defp verify_into_snapshot(state, source, size, options) do
    deadline =
      System.monotonic_time(:millisecond) +
        Keyword.get(options, :open_deadline_ms, state.limits.open_deadline_ms)

    budget = Keyword.get(options, :open_work_bytes, state.limits.open_work_bytes)

    result =
      File.open(source, [:read, :binary, :raw], fn reader ->
        with {:ok, snapshot} <- open_snapshot(state) do
          case copy(
                 reader,
                 snapshot,
                 :crypto.hash_init(:sha256),
                 size,
                 deadline,
                 budget,
                 Keyword.get(options, :work_observer)
               ) do
            {:ok, digest} ->
              {:ok, snapshot, digest}

            {:error, reason} ->
              File.close(snapshot)
              {:error, reason}
          end
        end
      end)

    case result do
      {:ok, outcome} -> outcome
      {:error, :enoent} -> {:error, :unknown_artifact}
      {:error, reason} -> {:error, {:artifact_unreadable, reason}}
    end
  end

  defp copy(_reader, _snapshot, _context, _left, _deadline, budget, _observer) when budget < 0,
    do: {:error, :open_work_budget_exhausted}

  defp copy(reader, snapshot, context, left, deadline, budget, observer) do
    cond do
      System.monotonic_time(:millisecond) > deadline ->
        {:error, :open_deadline_exhausted}

      left == 0 ->
        {:ok, context |> :crypto.hash_final() |> Base.encode16(case: :lower)}

      true ->
        wanted = min(left, @verify_block)

        case :file.read(reader, wanted) do
          {:ok, bytes} when byte_size(bytes) == wanted ->
            charge(observer, :source_read, wanted)

            case :file.write(snapshot, bytes) do
              :ok ->
                charge(observer, :snapshot_written, wanted)

                copy(
                  reader,
                  snapshot,
                  :crypto.hash_update(context, bytes),
                  left - wanted,
                  deadline,
                  budget - 2 * wanted,
                  observer
                )

              {:error, reason} ->
                charge(observer, :snapshot_write_uncertain, wanted)
                {:error, {:artifact_unreadable, reason}}
            end

          {:ok, bytes} ->
            charge(observer, :source_read, byte_size(bytes))
            {:error, :artifact_truncated}

          _short_or_error ->
            {:error, :artifact_truncated}
        end
    end
  end

  defp charge(nil, _kind, _bytes), do: :ok
  defp charge(observer, kind, bytes), do: send(observer, {:job_storage_work, self(), kind, bytes})

  # Concept: a snapshot with no name.
  #
  # Technical depth: created owner-only under the store's own scratch root and
  # unlinked as soon as it is open, so it is reachable only through this
  # descriptor. A later process cannot read it, and nothing can replace the file
  # this transfer is reading from.
  defp open_snapshot(state) do
    path = Path.join(state.scratch, reference())

    case File.open(path, [:read, :write, :binary, :raw, :exclusive]) do
      {:ok, device} ->
        with :ok <- File.chmod(path, 0o600),
             :ok <- File.rm(path) do
          {:ok, device}
        else
          {:error, reason} ->
            File.close(device)
            File.rm(path)
            {:error, {:artifact_unreadable, reason}}
        end

      {:error, reason} ->
        {:error, {:artifact_unreadable, reason}}
    end
  end

  # Concept: one original I/O actor owns every descriptor until retirement.
  # Technical depth: the responsive owner never performs transfer I/O. The actor
  # checks revocation and the original clock around each operation, reports actual
  # work, closes descriptors in acquisition-scoped after blocks, then exits. Only
  # its explicit physical proof followed by its original normal DOWN earns a receipt.
  defp transfer_io(owner, placement, request, context) do
    monitor = Process.monitor(owner)
    Process.put(:transfer_work, empty_work())
    Process.put(:transfer_deadline, context.open_deadline_ms)
    Process.put(:transfer_proof, true)
    Process.put(:transfer_owner, {owner, context.transfer_ref, monitor})

    outcome =
      try do
        check_io!(context.open_deadline_ms)
        digest = binary_part(request.use_locator, 4, 64)
        path = Path.join([placement.root, "uses", binary_part(digest, 0, 2), digest])

        with {:ok, bytes} <- transfer_use_bytes(path, context),
             {:ok, use} <- Loopex.Store.Local.Artifacts.decode_use_bytes(bytes, digest),
             true <- ArtifactStore.valid_transfer_use?(use, request) do
          object = %{
            digest: use.object_digest,
            size: use.object_size,
            locator: use.object_locator
          }

          transfer_source(owner, placement, request, context, object, use)
        else
          false -> {:error, :artifact_use_mismatch}
          {:error, reason} -> {:error, closed_io_reason(reason)}
        end
      rescue
        _exception -> {:error, :artifact_unreadable}
      catch
        :throw, {:transfer_refused, reason} -> {:error, reason}
      end

    send(
      owner,
      {:transfer_retired, context.transfer_ref, self(), outcome, Process.get(:transfer_work),
       Process.get(:transfer_proof)}
    )

    Process.demonitor(monitor, [:flush])
  end

  defp transfer_use_bytes(path, context) do
    check_io!(context.open_deadline_ms)

    case File.open(path, [:read, :binary, :raw]) do
      {:ok, device} ->
        try do
          check_io!(context.open_deadline_ms)
          first = :file.read(device, context.metadata_read_bytes)
          charge_transfer_read(first, :metadata_read_bytes)
          check_io!(context.open_deadline_ms)

          with {:ok, bytes} when byte_size(bytes) <= 131_072 <- first do
            tail = :file.read(device, 1)
            charge_transfer_read(tail, :metadata_read_bytes)
            check_io!(context.open_deadline_ms)
            if tail == :eof, do: {:ok, bytes}, else: {:error, :artifact_integrity_failed}
          else
            _ -> {:error, :artifact_integrity_failed}
          end
        after
          close_device(device)
        end

      {:error, :enoent} ->
        {:error, :unknown_artifact_use}

      {:error, _} ->
        {:error, :artifact_unreadable}
    end
  end

  defp transfer_source(owner, placement, request, context, object, use) do
    check_io!(context.open_deadline_ms)

    with {:ok, path} <- object_path(placement, object),
         true <- object.size <= placement.limits.object_bytes,
         :ok <-
           reserve_open_work(
             object.size,
             min(context.object_work_bytes, placement.limits.open_work_bytes)
           ),
         {:ok, bounds} <- window_bounds(Map.take(request, [:start, :length]), object.size) do
      result =
        case File.open(path, [:read, :binary, :raw]) do
          {:ok, reader} ->
            try do
              check_io!(context.open_deadline_ms)
              verified_snapshot(reader, placement, object, context)
            after
              close_device(reader)
            end

          {:error, :enoent} ->
            {:error, :unknown_artifact}

          {:error, _} ->
            {:error, :artifact_unreadable}
        end

      case result do
        {:ok, snapshot, digest} ->
          try do
            check_io!(context.open_deadline_ms)

            if Process.get(:transfer_proof) do
              transfer = %{
                transfer_ref: context.transfer_ref,
                object: object,
                use_locator: request.use_locator,
                total_size: object.size,
                window_start: bounds.start,
                window_length: bounds.length,
                object_digest: digest
              }

              send(
                owner,
                {:transfer_opened, context.transfer_ref, self(), transfer, use,
                 Process.get(:transfer_work)}
              )

              record = Map.merge(transfer, %{device: snapshot, cursor: bounds.start})
              transfer_reader(owner, context.transfer_ref, record, placement.limits)
            else
              {:error, :artifact_unreadable}
            end
          after
            close_device(snapshot)
          end

        {:error, reason} ->
          {:error, reason}
      end
    else
      false -> {:error, :artifact_too_large}
      {:error, reason} -> {:error, reason}
    end
  end

  defp verified_snapshot(reader, placement, object, context) do
    with {:ok, before} <- :file.read_file_info(reader),
         true <- elem(before, 1) == object.size and elem(before, 2) == :regular,
         {:ok, snapshot} <- open_transfer_snapshot(placement) do
      result =
        try do
          check_io!(context.open_deadline_ms)

          with {:ok, digest} <-
                 transfer_copy(reader, snapshot, :crypto.hash_init(:sha256), object.size, context),
               {:ok, after_info} <- :file.read_file_info(reader),
               true <- stable_source?(before, after_info),
               true <- digest == object.digest do
            check_io!(context.open_deadline_ms)
            {:ok, snapshot, digest}
          else
            false -> {:error, :artifact_digest_mismatch}
            {:error, reason} -> {:error, closed_io_reason(reason)}
          end
        rescue
          exception ->
            close_device(snapshot)
            reraise exception, __STACKTRACE__
        catch
          kind, reason ->
            close_device(snapshot)
            :erlang.raise(kind, reason, __STACKTRACE__)
        end

      case result do
        {:ok, ^snapshot, _digest} ->
          result

        {:error, _reason} ->
          close_device(snapshot)
          result
      end
    else
      false -> {:error, :artifact_digest_mismatch}
      {:error, reason} -> {:error, closed_io_reason(reason)}
    end
  end

  defp open_transfer_snapshot(placement) do
    path = Path.join(placement.scratch, reference())
    check_io!(Process.get(:transfer_deadline))

    case File.open(path, [:read, :write, :binary, :raw, :exclusive]) do
      {:ok, device} ->
        # Acquisition immediately installs cleanup before chmod, unlink or clock checks.
        try do
          check_io!(Process.get(:transfer_deadline))

          with :ok <- File.chmod(path, 0o600),
               :ok <- File.rm(path) do
            {:ok, device}
          else
            {:error, _reason} ->
              close_device(device)
              remove_snapshot(path)
              {:error, :artifact_unreadable}
          end
        rescue
          exception ->
            close_device(device)
            remove_snapshot(path)
            reraise exception, __STACKTRACE__
        catch
          kind, reason ->
            close_device(device)
            remove_snapshot(path)
            :erlang.raise(kind, reason, __STACKTRACE__)
        end

      {:error, _reason} ->
        {:error, :artifact_unreadable}
    end
  end

  defp remove_snapshot(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, _reason} -> Process.put(:transfer_proof, false)
    end
  rescue
    _exception -> Process.put(:transfer_proof, false)
  catch
    _kind, _reason -> Process.put(:transfer_proof, false)
  end

  defp transfer_copy(reader, snapshot, hash, left, context) do
    check_io!(context.open_deadline_ms)

    if left == 0 do
      {:ok, hash |> :crypto.hash_final() |> Base.encode16(case: :lower)}
    else
      wanted = min(left, @verify_block)
      result = :file.read(reader, wanted)
      charge_transfer_read(result, :source_read_bytes)
      check_io!(context.open_deadline_ms)

      case result do
        {:ok, bytes} when byte_size(bytes) == wanted ->
          charge_transfer(:snapshot_write_debit, wanted)
          publish_work(Map.put(Process.get(:transfer_work), :write_uncertain, true))

          case :file.write(snapshot, bytes) do
            :ok ->
              publish_work(Map.put(Process.get(:transfer_work), :write_uncertain, false))
              check_io!(context.open_deadline_ms)

              transfer_copy(
                reader,
                snapshot,
                :crypto.hash_update(hash, bytes),
                left - wanted,
                context
              )

            {:error, _} ->
              work = Process.get(:transfer_work) |> Map.put(:write_uncertain, true)
              publish_work(work)
              {:error, :artifact_unreadable}
          end

        _ ->
          {:error, :artifact_integrity_failed}
      end
    end
  end

  defp transfer_reader(owner, id, record, limits) do
    {_owner, _id, monitor} = Process.get(:transfer_owner)

    receive do
      {:transfer_retire, ^owner, ^id} ->
        {:error, :cancelled}

      {:DOWN, ^monitor, :process, ^owner, _reason} ->
        {:error, :cancelled}

      {:transfer_read, ^owner, ^id, length, deadline} ->
        check_io!(deadline, :read_deadline_exhausted)
        {reply, next} = emit(record, length, limits)
        reply = if timely?(deadline), do: reply, else: {:error, :read_deadline_exhausted}
        send(owner, {:transfer_read_result, id, self(), reply})
        transfer_reader(owner, id, next, limits)
    end
  end

  defp check_io!(deadline, exhausted_reason \\ :open_deadline_exhausted) do
    {owner, id, monitor} = Process.get(:transfer_owner)

    receive do
      {:transfer_retire, ^owner, ^id} -> throw({:transfer_refused, :cancelled})
      {:DOWN, ^monitor, :process, ^owner, _reason} -> throw({:transfer_refused, :cancelled})
    after
      0 ->
        if not timely?(deadline), do: throw({:transfer_refused, exhausted_reason})
    end
  end

  defp stable_source?(before, after_info),
    do: Enum.all?([1, 2, 5, 6, 7, 9, 10, 11], &(elem(before, &1) == elem(after_info, &1)))

  defp close_device(device) do
    if File.close(device) != :ok, do: Process.put(:transfer_proof, false)
  rescue
    _exception -> Process.put(:transfer_proof, false)
  catch
    _kind, _reason -> Process.put(:transfer_proof, false)
  end

  defp charge_transfer_read({:ok, bytes}, key), do: charge_transfer(key, byte_size(bytes))
  defp charge_transfer_read(_result, _key), do: :ok

  defp charge_transfer(key, count) do
    work = Process.get(:transfer_work) |> Map.update!(key, &(&1 + count))
    publish_work(work)
  end

  defp publish_work(work) do
    Process.put(:transfer_work, work)
    {owner, id, _monitor} = Process.get(:transfer_owner)
    send(owner, {:transfer_work, id, self(), work})
  end

  defp closed_io_reason(reason)
       when reason in [
              :unknown_artifact_use,
              :artifact_use_mismatch,
              :artifact_integrity_failed,
              :artifact_digest_mismatch,
              :unknown_artifact,
              :artifact_too_large,
              :invalid_window,
              :open_deadline_exhausted,
              :open_work_budget_exhausted,
              :cancelled
            ],
       do: reason

  defp closed_io_reason(_reason), do: :artifact_unreadable

  defp scavenge(scratch) do
    case File.ls(scratch) do
      {:ok, entries} ->
        Enum.each(entries, fn entry ->
          path = Path.join(scratch, entry)

          case File.lstat(path) do
            {:ok, %File.Stat{type: :regular}} -> File.rm(path)
            _other -> :ok
          end
        end)

      {:error, _reason} ->
        :ok
    end
  end

  defp admit_count(state) do
    if map_size(state.transfers) + map_size(state.jobs) < state.limits.per_runtime,
      do: :ok,
      else: {:error, :transfer_limit_reached}
  end

  # The same two-level fan-out this store writes objects into; a transfer reads
  # the object where the adapter put it rather than inventing a second layout.
  defp object_path(state, %{locator: locator})
       when is_binary(locator) and byte_size(locator) == 64 do
    if locator =~ ~r/\A[0-9a-f]{64}\z/ do
      {:ok, Path.join([state.root, binary_part(locator, 0, 2), locator])}
    else
      {:error, :unknown_artifact}
    end
  end

  defp object_path(_state, _object), do: {:error, :unknown_artifact}

  defp object_size(source, limits) do
    case File.stat(source) do
      {:ok, %File.Stat{type: :regular, size: size}} when size <= limits.object_bytes ->
        {:ok, size}

      {:ok, %File.Stat{type: :regular}} ->
        {:error, :artifact_too_large}

      {:ok, _other} ->
        {:error, :unknown_artifact}

      {:error, :enoent} ->
        {:error, :unknown_artifact}

      {:error, reason} ->
        {:error, {:artifact_unreadable, reason}}
    end
  end

  defp exact_size(size, %{size: size}), do: :ok
  defp exact_size(_size, _object), do: {:error, :artifact_digest_mismatch}

  # Concept: the window is fixed here, once, against the object's real size.
  #
  # Technical depth: a window starting exactly at the end is an empty transfer,
  # which is a legitimate answer about an object a caller has already read;
  # one starting past the end names bytes that never existed and refuses.
  defp window_bounds(window, size) when is_map(window) do
    start = Map.get(window, :start, 0)
    length = Map.get(window, :length)

    cond do
      not (is_integer(start) and start >= 0) -> {:error, :invalid_window}
      start > size -> {:error, :invalid_window}
      is_nil(length) -> {:ok, %{start: start, length: size - start}}
      not (is_integer(length) and length >= 0) -> {:error, :invalid_window}
      start + length > size -> {:error, :invalid_window}
      true -> {:ok, %{start: start, length: length}}
    end
  end

  defp window_bounds(_window, _size), do: {:error, :invalid_window}

  defp reference, do: 16 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
end
