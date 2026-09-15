defmodule Loopex.Store.Local.Transfers do
  @moduledoc """
  ## Concept

  The live transfers of one composed local artifact store. A transfer is opened
  once against an immutable object, verified whole before any chunk exists, and
  then read in bounded pieces until the caller closes it or its lifetime ends.

  ## Technical depth

  This process owns two things a plain adapter function cannot: the descriptor a
  transfer reads from and the timer that ends it. Accepted ADR 0028 requires the
  verified bytes to be copied into a transfer-owned snapshot, so a mutation of
  the original object after verification, including a same-inode same-size
  rewrite, cannot reach a chunk the open response's digest did not cover. The
  snapshot is created under the store's own scratch root with owner-only
  permissions and unlinked the moment it is open, so the operating system
  reclaims it when the descriptor closes or this process dies, and no path to it
  exists for a later process to read or replace.

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
  @spec open(pid(), map(), binary(), map(), keyword()) ::
          {:ok, ArtifactStore.transfer()} | {:error, term()}
  def open(owner, object, use_locator, window, options \\ []) when is_pid(owner) do
    GenServer.call(owner, {:open, object, use_locator, window, options}, :infinity)
  end

  @doc false
  @spec read(pid(), binary(), pos_integer()) ::
          {:ok, ArtifactStore.chunk()} | {:ok, :complete} | {:error, term()}
  def read(owner, transfer_ref, length) when is_pid(owner) do
    GenServer.call(owner, {:read, transfer_ref, length}, :infinity)
  end

  @doc false
  @spec close(pid(), binary()) :: :ok | {:error, term()}
  def close(owner, transfer_ref) when is_pid(owner) do
    GenServer.call(owner, {:close, transfer_ref}, :infinity)
  end

  @doc false
  @spec live(pid()) :: [binary()]
  def live(owner) when is_pid(owner), do: GenServer.call(owner, :live)

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
       transfers: %{}
     }}
  end

  @impl GenServer
  def handle_call({:open, object, use_locator, window, options}, _from, state) do
    with :ok <- admit_count(state),
         {:ok, source} <- object_path(state, object),
         {:ok, size} <- object_size(source, state.limits),
         :ok <- exact_size(size, object),
         {:ok, bounds} <- window_bounds(window, size),
         {:ok, snapshot, digest} <- verify_into_snapshot(state, source, size, options) do
      if digest == object.digest do
        transfer_ref = reference()

        record = %{
          transfer_ref: transfer_ref,
          object: object,
          use_locator: use_locator,
          total_size: size,
          window_start: bounds.start,
          window_length: bounds.length,
          object_digest: digest,
          cursor: bounds.start,
          device: snapshot,
          timer: Process.send_after(self(), {:expire, transfer_ref}, state.limits.lifetime_ms)
        }

        {:reply, {:ok, projection(record)},
         %{state | transfers: Map.put(state.transfers, transfer_ref, record)}}
      else
        File.close(snapshot)
        {:reply, {:error, :artifact_digest_mismatch}, state}
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:read, transfer_ref, length}, _from, state) do
    case Map.fetch(state.transfers, transfer_ref) do
      :error ->
        {:reply, {:error, :unknown_transfer}, state}

      {:ok, record} ->
        {reply, next} = emit(record, length, state.limits)
        {:reply, reply, %{state | transfers: Map.put(state.transfers, transfer_ref, next)}}
    end
  end

  def handle_call({:close, transfer_ref}, _from, state) do
    {:reply, :ok, release(state, transfer_ref)}
  end

  def handle_call(:live, _from, state), do: {:reply, Map.keys(state.transfers), state}

  @impl GenServer
  def handle_info({:expire, transfer_ref}, state), do: {:noreply, release(state, transfer_ref)}

  def handle_info(_message, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, state) do
    Enum.each(state.transfers, fn {_ref, record} -> File.close(record.device) end)
    :ok
  end

  # Concept: a transfer that ends releases its descriptor and its timer.
  #
  # Technical depth: the snapshot was unlinked at open, so closing the
  # descriptor is what actually reclaims the bytes. Releasing an unknown
  # reference is not an error: close, cancellation, lifetime expiry and
  # connection loss all reach here, and more than one of them can be true.
  defp release(state, transfer_ref) do
    case Map.pop(state.transfers, transfer_ref) do
      {nil, _remaining} ->
        state

      {record, remaining} ->
        Process.cancel_timer(record.timer)
        File.close(record.device)
        %{state | transfers: remaining}
    end
  end

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

    with {:ok, reader} <- File.open(source, [:read, :binary, :raw]),
         {:ok, snapshot} <- open_snapshot(state) do
      result = copy(reader, snapshot, :crypto.hash_init(:sha256), size, deadline, budget)
      File.close(reader)

      case result do
        {:ok, digest} ->
          {:ok, snapshot, digest}

        {:error, reason} ->
          File.close(snapshot)
          {:error, reason}
      end
    else
      {:error, :enoent} -> {:error, :unknown_artifact}
      {:error, reason} -> {:error, {:artifact_unreadable, reason}}
    end
  end

  defp copy(_reader, _snapshot, _context, _left, _deadline, budget) when budget < 0,
    do: {:error, :open_work_budget_exhausted}

  defp copy(reader, snapshot, context, left, deadline, budget) do
    cond do
      System.monotonic_time(:millisecond) > deadline ->
        {:error, :open_deadline_exhausted}

      left == 0 ->
        {:ok, context |> :crypto.hash_final() |> Base.encode16(case: :lower)}

      true ->
        wanted = min(left, @verify_block)

        case :file.read(reader, wanted) do
          {:ok, bytes} when byte_size(bytes) == wanted ->
            case :file.write(snapshot, bytes) do
              :ok ->
                copy(
                  reader,
                  snapshot,
                  :crypto.hash_update(context, bytes),
                  left - wanted,
                  deadline,
                  budget - 2 * wanted
                )

              {:error, reason} ->
                {:error, {:artifact_unreadable, reason}}
            end

          _short_or_error ->
            {:error, :artifact_truncated}
        end
    end
  end

  # Concept: a snapshot with no name.
  #
  # Technical depth: created owner-only under the store's own scratch root and
  # unlinked as soon as it is open, so it is reachable only through this
  # descriptor. A later process cannot read it, and nothing can replace the file
  # this transfer is reading from.
  defp open_snapshot(state) do
    path = Path.join(state.scratch, reference())

    with {:ok, device} <- File.open(path, [:read, :write, :binary, :raw, :exclusive]),
         :ok <- File.chmod(path, 0o600),
         :ok <- File.rm(path) do
      {:ok, device}
    else
      {:error, reason} -> {:error, {:artifact_unreadable, reason}}
    end
  end

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
    if map_size(state.transfers) < state.limits.per_runtime,
      do: :ok,
      else: {:error, :transfer_limit_reached}
  end

  # The same two-level fan-out this store writes objects into; a transfer reads
  # the object where the adapter put it rather than inventing a second layout.
  defp object_path(state, %{locator: locator})
       when is_binary(locator) and byte_size(locator) == 64 do
    {:ok, Path.join([state.root, binary_part(locator, 0, 2), locator])}
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

  defp projection(record) do
    Map.take(record, [
      :transfer_ref,
      :object,
      :use_locator,
      :total_size,
      :window_start,
      :window_length,
      :object_digest
    ])
  end

  defp reference, do: 16 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
end
