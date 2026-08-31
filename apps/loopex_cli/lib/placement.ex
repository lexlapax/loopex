defmodule LoopexCli.Placement do
  @moduledoc """
  ## Concept

  Only one `loopex` process at a time may own a state root's runtime placement.
  A second one that tried would put two Runtime Controls on the same
  `(Store, runtime_id)` key, and the two would race for ownership of every
  session in that root.

  ## Technical depth

  [ADR 0008](../../../../docs/adr/0008-owner-succession-and-placement.md#concept)
  makes this the host's duty explicitly: Loopex provides no VM-global lock, and a
  kernel that invented one would be choosing a scope no host asked for. The
  command surface is the host here, so the exclusion lives here.

  It is a lock file created with `O_EXCL`, which is atomic on every filesystem
  this command supports: the first writer wins and every later one is refused
  rather than both believing they succeeded. The file records the owning
  operating-system process, so a lock left by a process that died can be
  recognised as stale rather than blocking the root forever — an operator whose
  laptop lost power should not have to delete a file they never knew existed.

  Reclamation and release run under a short, crash-reclaimable directory guard.
  Each successful acquisition also gets a hard-linked owner handle, so release
  removes the canonical lock only while that handle still names the same inode.
  A delayed release from an older acquisition therefore has no authority over a
  successor, and two stale-lock reclaimers cannot both become owners.

  Staleness is decided by asking the operating system whether that process is
  still the same process incarnation, not by a timeout or process identifier
  alone. Operating systems reuse process identifiers; binding the identifier to
  its observed start identity prevents an unrelated later process from
  inheriting or stranding the root. A timeout would either strand a healthy
  long-running session or hand a live root to a second owner, and there is no
  duration that avoids both.
  """

  @lock_record_version "loopex-placement-v1"

  @typedoc false
  @type process_probe :: (binary() -> {:ok, binary()} | {:error, term()})

  @doc """
  ## Concept

  Takes the placement lock for a state root, or says who holds it.

  ## Technical depth

  Returns an acquisition-specific path so a caller can release exactly the lock
  it took. A stale lock left by a dead process is reclaimed; a live one is
  refused with the owning process identifier, because an operator told only "in
  use" cannot tell a forgotten window from a genuine conflict.
  """
  @spec acquire(Path.t()) :: {:ok, Path.t()} | {:error, binary()}
  def acquire(state_root) do
    acquire(state_root, &process_incarnation/1)
  end

  @doc false
  @spec acquire(Path.t(), process_probe()) :: {:ok, Path.t()} | {:error, binary()}
  def acquire(state_root, process_probe)
      when is_binary(state_root) and is_function(process_probe, 1) do
    path = lock_path(state_root)
    File.mkdir_p!(Path.dirname(path))

    case with_guard(path, process_probe, fn -> acquire_locked(path, process_probe) end) do
      {:guard_error, reason} ->
        {:error, "the placement lock could not be taken: #{reason}"}

      result ->
        result
    end
  end

  @doc """
  ## Concept

  Releases a lock this process took.

  ## Technical depth

  Best effort. The acquisition-specific handle is compared with the canonical
  lock before deletion, so a late or repeated release cannot remove a successor.
  A lock left behind by a crash is reclaimed by the next acquirer through the
  liveness check rather than requiring this to have run.
  """
  @spec release(Path.t()) :: :ok
  def release(owner_handle) do
    with {:ok, path} <- canonical_path(owner_handle) do
      _ =
        with_guard(path, &process_incarnation/1, fn ->
          release_locked(path, owner_handle)
        end)
    end

    :ok
  end

  @doc """
  ## Concept

  Whether another live process currently owns this state root.

  ## Technical depth

  Used by `loopex cancel`, which applies only where no live owner holds the
  placement key. Reconciling a session out from under a running owner is exactly
  the race the lock exists to prevent, so the command refuses rather than
  competing.
  """
  @spec live_owner(Path.t()) :: {:ok, binary()} | :none | {:error, binary()}
  def live_owner(state_root) do
    live_owner(state_root, &process_incarnation/1)
  end

  @doc false
  @spec live_owner(Path.t(), process_probe()) ::
          {:ok, binary()} | :none | {:error, binary()}
  def live_owner(state_root, process_probe)
      when is_binary(state_root) and is_function(process_probe, 1) do
    path = lock_path(state_root)

    case File.read(path) do
      {:ok, bytes} ->
        with {:ok, owner} <- decode_owner(bytes) do
          case owner_status(owner, process_probe) do
            {:ok, :alive} -> {:ok, owner.pid}
            {:ok, :dead} -> :none
            {:error, reason} -> owner_probe_error(reason)
          end
        else
          :error -> :none
        end

      {:error, :enoent} ->
        :none

      {:error, reason} ->
        {:error, "the placement lock could not be read: #{inspect(reason)}"}
    end
  end

  defp acquire_locked(path, process_probe) do
    case File.read(path) do
      {:ok, bytes} ->
        case decode_owner(bytes) do
          {:ok, owner} ->
            case owner_status(owner, process_probe) do
              {:ok, :alive} ->
                {:error,
                 "another loopex process (pid #{owner.pid}) is using this state root; " <>
                   "stop it, or pass --state-root to work somewhere else"}

              {:ok, :dead} ->
                reclaim_owner(path, process_probe)

              {:error, reason} ->
                owner_probe_error(reason)
            end

          :error ->
            reclaim_owner(path, process_probe)
        end

      {:error, :enoent} ->
        cleanup_owner_handles(path)
        create_owner(path, process_probe)

      {:error, _reason} ->
        {:error, "a placement lock exists but could not be read: #{path}"}
    end
  end

  # The previous owner is gone, so the lock describes nothing. Reclaiming is
  # safe precisely because incarnation liveness was checked rather than assumed
  # from the file's age. The guard makes the read, removal, and successor
  # installation one serialized operation.
  defp reclaim_owner(path, process_probe) do
    cleanup_owner_handles(path)

    case File.rm(path) do
      :ok -> create_owner(path, process_probe)
      {:error, :enoent} -> acquire_locked(path, process_probe)
      {:error, reason} -> lock_error(reason)
    end
  end

  defp create_owner(path, process_probe) do
    with {:ok, owner} <- current_owner(process_probe) do
      case :file.open(path, [:write, :exclusive, :raw]) do
        {:ok, file} ->
          owner_handle = path <> ".owner-" <> identity()

          with :ok <- :file.write(file, encode_owner(owner)),
               :ok <- :file.close(file),
               :ok <- File.ln(path, owner_handle) do
            {:ok, owner_handle}
          else
            {:error, reason} ->
              _ = :file.close(file)
              _ = File.rm(path)
              lock_error(reason)
          end

        {:error, reason} ->
          lock_error(reason)
      end
    else
      {:error, reason} -> lock_error(reason)
    end
  end

  defp release_locked(path, owner_handle) do
    with {:ok, canonical} <- File.stat(path),
         {:ok, owner} <- File.stat(owner_handle),
         true <- same_file?(canonical, owner) do
      _ = File.rm(path)
    end

    _ = File.rm(owner_handle)
    :ok
  end

  defp same_file?(left, right) do
    left.inode == right.inode and left.major_device == right.major_device and
      left.minor_device == right.minor_device
  end

  defp cleanup_owner_handles(path) do
    directory = Path.dirname(path)
    prefix = Path.basename(path) <> ".owner-"

    case File.ls(directory) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&owner_handle_name?(&1, prefix))
        |> Enum.each(fn entry -> File.rm(Path.join(directory, entry)) end)

      {:error, _reason} ->
        :ok
    end
  end

  defp owner_handle_name?(entry, prefix) do
    case String.split(entry, prefix, parts: 2) do
      ["", identity] -> Regex.match?(~r/\A[0-9]+-[0-9]+-[0-9]+\z/, identity)
      _other -> false
    end
  end

  defp canonical_path(owner_handle) do
    basename = Path.basename(owner_handle)

    case Regex.run(~r/\A(.+)\.owner-[0-9]+-[0-9]+-[0-9]+\z/, basename) do
      [_whole, canonical] -> {:ok, Path.join(Path.dirname(owner_handle), canonical)}
      _other -> :error
    end
  end

  defp lock_error(:eexist), do: {:error, "another loopex process took this state root first"}

  defp lock_error(reason),
    do: {:error, "the placement lock could not be taken: #{inspect(reason)}"}

  # Concept: stale ownership is reclaimed without letting two observers both
  # become the owner.
  #
  # Technical depth: an already-populated contender directory is atomically
  # renamed into the guard name. A stale guard is removed by its exact marker;
  # if another contender has already replaced it, that marker is absent and its
  # non-empty successor directory cannot be removed by the older reclaimer.
  defp with_guard(path, process_probe, operation) do
    case take_guard(path, process_probe, 2_000) do
      {:ok, marker} ->
        try do
          operation.()
        after
          drop_guard(marker)
        end

      {:error, reason} ->
        {:guard_error, reason}
    end
  end

  defp take_guard(_path, _process_probe, 0),
    do: {:error, "placement lock coordination timed out"}

  defp take_guard(path, process_probe, attempts_left) do
    guard = guard_path(path)
    id = identity()
    contender = guard <> ".claim-" <> id
    marker_name = "owner-" <> id
    marker = Path.join(contender, marker_name)

    with {:ok, owner} <- current_owner(process_probe),
         :ok <- File.mkdir(contender),
         :ok <- File.write(marker, encode_owner(owner), [:exclusive]),
         :ok <- File.rename(contender, guard) do
      {:ok, Path.join(guard, marker_name)}
    else
      {:error, :eexist} ->
        cleanup_contender(contender, marker)
        contend_for_guard(path, process_probe, attempts_left)

      {:error, :enotempty} ->
        cleanup_contender(contender, marker)
        contend_for_guard(path, process_probe, attempts_left)

      {:error, reason} ->
        cleanup_contender(contender, marker)
        {:error, "guard creation failed: #{inspect(reason)}"}
    end
  end

  defp contend_for_guard(path, process_probe, attempts_left) do
    guard = guard_path(path)

    case File.ls(guard) do
      {:ok, []} ->
        _ = File.rmdir(guard)
        take_guard(path, process_probe, attempts_left - 1)

      {:ok, [entry]} ->
        marker = Path.join(guard, entry)

        if String.starts_with?(entry, "owner-") do
          reclaim_or_wait_for_guard(path, marker, process_probe, attempts_left)
        else
          {:error, "placement lock coordination data is malformed"}
        end

      {:ok, _entries} ->
        {:error, "placement lock coordination data is malformed"}

      {:error, :enoent} ->
        take_guard(path, process_probe, attempts_left - 1)

      {:error, reason} ->
        {:error, "guard inspection failed: #{inspect(reason)}"}
    end
  end

  defp reclaim_or_wait_for_guard(path, marker, process_probe, attempts_left) do
    case File.read(marker) do
      {:ok, bytes} ->
        case owner_record_status(bytes, process_probe) do
          {:ok, :alive} ->
            Process.sleep(1)
            take_guard(path, process_probe, attempts_left - 1)

          {:ok, :dead} ->
            if File.rm(marker) == :ok, do: File.rmdir(Path.dirname(marker))
            take_guard(path, process_probe, attempts_left - 1)

          {:error, reason} ->
            owner_probe_error(reason)
        end

      {:error, :enoent} ->
        take_guard(path, process_probe, attempts_left - 1)

      {:error, reason} ->
        {:error, "guard owner could not be read: #{inspect(reason)}"}
    end
  end

  defp cleanup_contender(contender, marker) do
    _ = File.rm(marker)
    _ = File.rmdir(contender)
    :ok
  end

  defp drop_guard(marker) do
    case File.rm(marker) do
      :ok -> File.rmdir(Path.dirname(marker))
      {:error, _reason} -> :ok
    end

    :ok
  end

  defp identity do
    Enum.join(
      [System.pid(), System.os_time(:nanosecond), System.unique_integer([:positive, :monotonic])],
      "-"
    )
  end

  defp guard_path(path), do: path <> ".guard"

  # Concept: ask the operating system which process owns an identifier, do not
  # guess from a clock or let a later process inherit an earlier one's claim.
  #
  # Technical depth: `ps` exposes a stable start identity for the lifetime of a
  # process. The lock stores that identity with the numeric pid. Re-probing and
  # comparing both turns pid reuse into a stale record instead of a false live
  # owner. A malformed or legacy pid-only record is unattributed and therefore
  # reclaimable.
  defp current_owner(process_probe) do
    pid = System.pid()

    case process_probe.(pid) do
      {:ok, incarnation} -> {:ok, %{pid: pid, incarnation: incarnation}}
      {:error, reason} -> {:error, {:process_incarnation_unavailable, reason}}
    end
  end

  defp owner_record_status(bytes, process_probe) do
    case decode_owner(bytes) do
      {:ok, owner} -> owner_status(owner, process_probe)
      :error -> {:error, :malformed_owner_record}
    end
  end

  defp owner_status(%{pid: pid, incarnation: expected}, process_probe) do
    case process_probe.(pid) do
      {:ok, ^expected} -> {:ok, :alive}
      {:ok, _different_incarnation} -> {:ok, :dead}
      {:error, :process_absent} -> {:ok, :dead}
      {:error, reason} -> {:error, {:process_incarnation_unavailable, reason}}
    end
  end

  defp owner_probe_error(reason),
    do: {:error, "the placement owner could not be verified: #{inspect(reason)}"}

  defp encode_owner(%{pid: pid, incarnation: incarnation}) do
    encoded = Base.url_encode64(incarnation, padding: false)
    [@lock_record_version, "\n", pid, "\n", encoded, "\n"]
  end

  defp decode_owner(bytes) when is_binary(bytes) do
    with [@lock_record_version, pid, encoded, ""] <- String.split(bytes, "\n"),
         {number, ""} when number > 0 <- Integer.parse(pid),
         true <- Integer.to_string(number) == pid,
         {:ok, incarnation} when incarnation != "" <-
           Base.url_decode64(encoded, padding: false) do
      {:ok, %{pid: pid, incarnation: incarnation}}
    else
      _invalid -> :error
    end
  end

  defp process_incarnation(pid) when is_binary(pid) do
    try do
      case System.cmd("/bin/ps", ["-o", "lstart=", "-p", pid],
             stderr_to_stdout: true,
             env: [{"LC_ALL", "C"}]
           ) do
        {output, 0} ->
          case String.trim(output) do
            "" -> {:error, :empty_process_identity}
            incarnation -> {:ok, incarnation}
          end

        {_output, _status} ->
          {:error, :process_absent}
      end
    rescue
      ErlangError -> {:error, :process_probe_failed}
    end
  end

  defp lock_path(state_root), do: Path.join(state_root, "placement.lock")
end
