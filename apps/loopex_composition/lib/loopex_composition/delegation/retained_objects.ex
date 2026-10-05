defmodule LoopexComposition.Delegation.RetainedObjects do
  @moduledoc """
  ## Concept

  Retain the exact validated bytes of a helper catalog or creation object under
  its SHA-256 identity. One private owner serializes installation; a corrupt
  published object is refused rather than repaired or replaced.

  ## Technical depth

  ADR 0046 places these immutable objects below delegation/<runtime-id-sha256>
  under an existing host placement acquisition. Opening verifies that the
  acquisition's regular hard-linked handle still names this VM's placement
  lock, and retains physical directory identities. Every operation rechecks
  those identities and ownership. The Local writer lock supplies independent
  process exclusion; its existing format is reused without a new journal.

  Callers own canonical JSON and semantic validation before installation. This
  physical unit bounds UTF-8 bytes to 1 MiB and verifies exact digests on reads.
  It creates no catalog envelope, ledger transaction, accounting or receipt.
  Temporary-file sync precedes rename and strict directory sync. A failure after
  rename returns object_durability_unknown, never a durability acknowledgement.
  Repeated installation confirms the existing file and directory durability.
  Read success proves current integrity, not a previously lost acknowledgement.
  Paths are revalidated using ordinary OTP file identities under the exclusive
  trusted host lease; this is not isolation from host code changing the root.
  """

  use GenServer

  alias Loopex.Store.Local.{Log, WriterLock}
  alias LoopexComposition.Placement

  @cap 1_048_576

  @doc false
  def open(root, runtime_id, placement_owner, options \\ []) do
    case GenServer.start(__MODULE__, {self(), root, runtime_id, placement_owner, options}) do
      {:ok, owner} ->
        Process.link(owner)
        {:ok, owner}

      refusal ->
        refusal
    end
  end

  @doc false
  def install(owner, bytes), do: GenServer.call(owner, {:install, bytes}, :infinity)

  @doc false
  def read(owner, digest), do: GenServer.call(owner, {:read, digest}, :infinity)

  @impl true
  def init({caller, root, runtime_id, placement_owner, options}) do
    caller_monitor = Process.monitor(caller)

    with true <- is_binary(root) and Path.type(root) == :absolute and Path.expand(root) == root,
         true <- is_binary(runtime_id) and byte_size(runtime_id) in 1..256,
         true <- is_function(Keyword.get(options, :checkpoint, fn _ -> :ok end), 1),
         :ok <- physical_directory(root),
         :ok <- placement(root, placement_owner),
         {:ok, directory} <- directories(root, digest(runtime_id)),
         :ok <- placement(root, placement_owner),
         {:ok, identities} <- identities([root, Path.dirname(directory), directory]),
         :ok <- optional_writer_marker(Path.join(directory, "objects.writer")),
         {:ok, lock} <-
           WriterLock.acquire(
             Path.join(directory, "objects"),
             Keyword.get(options, :recover_stale_writer, false)
           ) do
      {:ok,
       %{
         root: root,
         placement_owner: placement_owner,
         directory: directory,
         identities: identities,
         lock: lock,
         caller_monitor: caller_monitor,
         checkpoint: Keyword.get(options, :checkpoint, fn _ -> :ok end)
       }}
    else
      false -> {:stop, :invalid_object_root}
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call({:install, bytes}, _from, state) do
    result =
      with :ok <- valid_bytes(bytes),
           :ok <- verify(state) do
        hash = digest(bytes)
        path = Path.join(state.directory, hash)

        case read_file(state, path) do
          {:ok, ^bytes} -> confirm_existing(state, path, hash)
          {:ok, _different} -> {:error, :object_integrity_conflict}
          {:error, :enoent} -> publish(state, path, hash, bytes)
          {:error, reason} -> {:error, reason}
        end
      end

    {:reply, result, state}
  end

  def handle_call({:read, hash}, _from, state) do
    result =
      with true <- is_binary(hash) and Regex.match?(~r/\A[0-9a-f]{64}\z/, hash),
           :ok <- verify(state),
           {:ok, bytes} <- read_file(state, Path.join(state.directory, hash)),
           true <- digest(bytes) == hash do
        {:ok, bytes}
      else
        false -> {:error, :invalid_or_corrupt_object}
        {:error, reason} -> {:error, reason}
      end

    {:reply, result, state}
  end

  @impl true
  def terminate(_reason, state), do: WriterLock.release(state.lock)

  @impl true
  def handle_info(
        {:DOWN, monitor, :process, _caller, _reason},
        %{caller_monitor: monitor} = state
      ),
      do: {:stop, :normal, state}

  defp confirm_existing(state, path, hash) do
    with :ok <- sync_file(path),
         :ok <- checkpoint(state, :existing_synced),
         :ok <- Log.sync_parent(path),
         :ok <- checkpoint(state, :directory_synced),
         {:ok, bytes} <- read_file(state, path),
         true <- digest(bytes) == hash do
      {:ok, hash}
    else
      false -> unknown(hash, :object_integrity_conflict)
      {:error, reason} -> unknown(hash, reason)
    end
  end

  # Concept: only this owner may publish; readers never promote temporary files.
  # Technical depth: the writer lock and serial mailbox prevent another installer
  # from racing the absent check. Only this invocation's exclusive temporary is
  # removed on a returned failure; process death leaves an unreferenced temporary.
  defp publish(state, path, hash, bytes) do
    temporary =
      Path.join(state.directory, ".tmp-" <> Base.encode16(:crypto.strong_rand_bytes(16)))

    try do
      with {:ok, io} <-
             :file.open(String.to_charlist(temporary), [:write, :raw, :binary, :exclusive]) do
        written =
          try do
            with :ok <- :file.write(io, bytes),
                 :ok <- checkpoint(state, :temporary_written),
                 :ok <- :file.sync(io),
                 :ok <- checkpoint(state, :temporary_synced),
                 :ok <- verify(state) do
              :ok
            end
          catch
            kind, reason ->
              :file.close(io)
              :erlang.raise(kind, reason, __STACKTRACE__)
          end

        closed = :file.close(io)

        with :ok <- written,
             :ok <- closed,
             {:error, :enoent} <- File.lstat(path),
             :ok <- File.rename(temporary, path) do
          with :ok <- checkpoint(state, :renamed),
               :ok <- Log.sync_parent(path),
               :ok <- checkpoint(state, :directory_synced),
               {:ok, published} <- read_file(state, path),
               true <- published == bytes do
            {:ok, hash}
          else
            false -> unknown(hash, :object_integrity_conflict)
            {:error, reason} -> unknown(hash, reason)
          end
        else
          {:ok, _existing} -> {:error, :object_integrity_conflict}
          {:error, reason} -> {:error, reason}
        end
      end
    after
      File.rm(temporary)
    end
  end

  defp unknown(hash, reason), do: {:error, {:object_durability_unknown, hash, reason}}

  defp checkpoint(state, step), do: state.checkpoint.(step)

  defp valid_bytes(bytes) when is_binary(bytes) and byte_size(bytes) in 1..@cap do
    if String.valid?(bytes), do: :ok, else: {:error, :invalid_object_bytes}
  end

  defp valid_bytes(_), do: {:error, :invalid_object_bytes}

  defp read_file(state, path) do
    with {:ok, %File.Stat{type: :regular} = expected} <- File.lstat(path),
         true <- expected.size <= @cap,
         {:ok, io} <- :file.open(String.to_charlist(path), [:read, :binary, :raw]) do
      try do
        with {:ok, record} <- :file.read_file_info(io),
             opened = File.Stat.from_record(record),
             true <- identity(opened) == identity(expected) and opened.type == :regular,
             {:ok, bytes} <- :file.read(io, @cap + 1),
             :ok <- valid_bytes(bytes),
             :ok <- verify(state),
             {:ok, current} <- File.lstat(path),
             true <- current.type == :regular and identity(current) == identity(expected) do
          {:ok, bytes}
        else
          false -> {:error, :invalid_or_corrupt_object}
          :eof -> {:error, :invalid_or_corrupt_object}
          {:error, reason} -> {:error, reason}
        end
      after
        :file.close(io)
      end
    else
      {:ok, _} -> {:error, :invalid_or_corrupt_object}
      false -> {:error, :invalid_or_corrupt_object}
      {:error, reason} -> {:error, reason}
    end
  end

  defp sync_file(path) do
    with {:ok, io} <- :file.open(String.to_charlist(path), [:read, :binary, :raw]) do
      result = :file.sync(io)
      closed = :file.close(io)
      with :ok <- result, do: closed
    end
  end

  defp verify(state) do
    with :ok <- physical_directory(state.root),
         :ok <- placement(state.root, state.placement_owner),
         {:ok, %File.Stat{type: :regular} = lock_stat} <- File.lstat(state.lock.path),
         true <- lock_stat.size == byte_size(state.lock.marker),
         {:ok, marker} <- File.read(state.lock.path),
         true <- marker == state.lock.marker do
      Enum.reduce_while(state.identities, :ok, fn {path, expected}, :ok ->
        case File.lstat(path) do
          {:ok, %File.Stat{type: :directory} = stat} ->
            if identity(stat) == expected,
              do: {:cont, :ok},
              else: {:halt, {:error, :object_root_changed}}

          _ ->
            {:halt, {:error, :object_root_changed}}
        end
      end)
    else
      false -> {:error, :object_writer_changed}
      {:ok, _} -> {:error, :object_writer_changed}
      {:error, reason} -> {:error, reason}
    end
  end

  defp placement(root, owner) when is_binary(owner) do
    lock = Path.join(root, "placement.lock")

    with true <-
           Path.dirname(owner) == root and
             String.starts_with?(Path.basename(owner), "placement.lock.owner-"),
         {:ok, %File.Stat{type: :regular} = acquired} <- File.lstat(owner),
         {:ok, %File.Stat{type: :regular} = current} <- File.lstat(lock),
         true <- identity(acquired) == identity(current),
         {:ok, pid} <- Placement.live_owner(root),
         true <- pid == System.pid() do
      :ok
    else
      _ -> {:error, :placement_ownership_unavailable}
    end
  end

  defp placement(_, _), do: {:error, :placement_ownership_unavailable}

  defp physical_directory(path) do
    with {:ok, %File.Stat{type: :directory}} <- File.lstat(path) do
      parent = Path.dirname(path)
      if parent == path, do: :ok, else: physical_directory(parent)
    else
      _ -> {:error, :invalid_object_root}
    end
  end

  defp directories(root, runtime_hash) do
    Enum.reduce_while(["delegation", runtime_hash], {:ok, root}, fn component, {:ok, parent} ->
      child = Path.join(parent, component)

      with :ok <- physical_directory(parent),
           :ok <- mkdir(child),
           :ok <- physical_directory(child),
           :ok <- Log.sync_parent(child) do
        {:cont, {:ok, child}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp mkdir(path) do
    case File.mkdir(path) do
      :ok -> :ok
      {:error, :eexist} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp optional_writer_marker(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} -> :ok
      {:error, :enoent} -> :ok
      _ -> {:error, :invalid_object_root}
    end
  end

  defp identities(paths) do
    Enum.reduce_while(paths, {:ok, []}, fn path, {:ok, held} ->
      case File.lstat(path) do
        {:ok, %File.Stat{type: :directory} = stat} ->
          {:cont, {:ok, [{path, identity(stat)} | held]}}

        _ ->
          {:halt, {:error, :invalid_object_root}}
      end
    end)
  end

  defp identity(stat), do: {stat.major_device, stat.minor_device, stat.inode}
  defp digest(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
