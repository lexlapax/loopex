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

  Staleness is decided by asking the operating system whether that process is
  still alive, not by a timeout. A timeout would either strand a healthy
  long-running session or hand a live root to a second owner, and there is no
  duration that avoids both.
  """

  @doc """
  ## Concept

  Takes the placement lock for a state root, or says who holds it.

  ## Technical depth

  Returns the lock path so a caller can release it. A stale lock left by a dead
  process is reclaimed; a live one is refused with the owning process identifier,
  because an operator told only "in use" cannot tell a forgotten window from a
  genuine conflict.
  """
  @spec acquire(Path.t()) :: {:ok, Path.t()} | {:error, binary()}
  def acquire(state_root) do
    path = lock_path(state_root)
    File.mkdir_p!(Path.dirname(path))

    case :file.open(path, [:write, :exclusive, :raw]) do
      {:ok, handle} ->
        :ok = :file.write(handle, System.pid())
        :ok = :file.close(handle)
        {:ok, path}

      {:error, :eexist} ->
        reclaim_or_refuse(path)

      {:error, reason} ->
        {:error, "the placement lock could not be taken: #{inspect(reason)}"}
    end
  end

  @doc """
  ## Concept

  Releases a lock this process took.

  ## Technical depth

  Best effort. A lock left behind by a crash is reclaimed by the next acquirer
  through the liveness check rather than requiring this to have run.
  """
  @spec release(Path.t()) :: :ok
  def release(path) do
    _ = File.rm(path)
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
  @spec live_owner(Path.t()) :: {:ok, binary()} | :none
  def live_owner(state_root) do
    path = lock_path(state_root)

    with {:ok, pid} <- File.read(path),
         true <- alive?(pid) do
      {:ok, pid}
    else
      _absent -> :none
    end
  end

  defp reclaim_or_refuse(path) do
    case File.read(path) do
      {:ok, pid} ->
        if alive?(pid) do
          {:error,
           "another loopex process (pid #{pid}) is using this state root; " <>
             "stop it, or pass --state-root to work somewhere else"}
        else
          # The previous owner is gone, so the lock describes nothing. Reclaiming
          # is safe precisely because liveness was checked rather than assumed
          # from the file's age.
          _ = File.rm(path)
          acquire_after_reclaim(path)
        end

      {:error, _reason} ->
        {:error, "a placement lock exists but could not be read: #{path}"}
    end
  end

  defp acquire_after_reclaim(path) do
    case :file.open(path, [:write, :exclusive, :raw]) do
      {:ok, handle} ->
        :ok = :file.write(handle, System.pid())
        :ok = :file.close(handle)
        {:ok, path}

      {:error, _reason} ->
        {:error, "another loopex process took this state root first"}
    end
  end

  # Concept: ask the operating system, do not guess from a clock.
  #
  # Technical depth: signal zero performs the permission and existence checks of
  # a real signal without delivering one, which is the standard way to ask
  # whether a process id is live. A non-numeric or absent value is treated as
  # dead, because a lock nobody can attribute is a lock nobody is holding.
  defp alive?(pid) do
    case Integer.parse(String.trim(pid)) do
      {number, _rest} when number > 0 ->
        match?(
          {_output, 0},
          System.cmd("/bin/kill", ["-0", Integer.to_string(number)], stderr_to_stdout: true)
        )

      _unparseable ->
        false
    end
  end

  defp lock_path(state_root), do: Path.join(state_root, "placement.lock")
end
