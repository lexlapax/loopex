defmodule Loopex.Store.Local.WriterLock do
  @moduledoc """
  ## Concept

  The durable local Store admits one process for a physical store path. A
  second ordinary opener fails closed instead of running another stale cache
  against the same transaction log.

  A holder that terminates in an orderly way gives its own marker back, so an
  ordinary stop leaves nothing behind for the next opener to reason about.
  Restart after an ungraceful VM or OS-process death is still explicit, because
  a killed holder never runs anything. The marker names the process that wrote
  it, and a caller asking to recover one is refused unless that holder is
  established to be gone — whoever is asking and whatever else they hold. This
  marker is physical writer exclusion, not session ownership; ADR 0006 owner
  epochs and incarnation IDs remain the commit-authority fence.

  ## Technical depth

  Acquisition creates and syncs a sidecar with exclusive-create semantics. The
  bytes are versioned — `loopex_store_writer_v2` — and record who is holding
  the path: the operating-system process identifier, that process's start
  identity as `/bin/ps` reports it, the BEAM process identifier of the Store
  process itself, and a random nonce that makes the marker unique to one
  acquisition.

  `release/1` is the orderly give-back: it deletes the marker only when the
  file still holds the exact bytes this holder wrote, so a release that arrives
  after someone else already recovered the path cannot remove a successor's
  lock. The comparison is not one kernel operation — OTP's file API exposes no
  compare-and-delete — but the holder is by construction the only live writer
  while its own bytes are present, so the window it leaves is the one that
  recovery already handles rather than a new one.

  A marker therefore remains after an untrappable kill, a whole-VM death, or a
  power loss, none of which run a release. `:recover_stale_writer` asks for such
  a marker to be broken, and it is broken only where the recorded holder is
  established to be gone:

    * the operating system reports no process with that identifier, or reports
      one whose start identity differs and whose identifier was therefore
      reused — the holder is gone and the marker is removed;
    * the identifier is this very operating-system process and its start
      identity matches, so the marker was written inside this VM and the
      recorded BEAM process can be asked directly — a dead one is gone, a live
      one is the writer;
    * anything else leaves the marker in place and the opener is refused with
      `{:store_writer_active, path}`: another live operating-system process, a
      probe that cannot answer, or a marker carrying no identity to check, such
      as a `loopex_store_writer_v1` one.

  Establishing the writer's own liveness, rather than the asking caller's
  authority, is what closes the case no runtime-root lock can. An embedded
  runtime holding this store inside its own VM takes no such lock, so a command
  that holds one has proved nothing whatever about that embedder; asserting
  recovery from there used to delete a live writer's marker and open a second
  Store on one log. Identifier reuse is defended against by the recorded start
  identity rather than by the number alone, which is why a probe that reports a
  live but differently started process reads as gone.

  The probe is `/bin/ps` asked for a process's start identity, the same
  portable mechanism the local executor uses to ask whether an operating-system
  process is still there. Where it cannot answer while a marker is being
  written, the open is refused (`store_writer_identity_unavailable`): a marker
  that recorded no identity could never be recovered automatically, and a store
  that cannot be recovered after its holder dies is worse than one that refuses
  to start until the probe works. The probe is bounded, so a helper that hangs
  cannot hang the open. A recovery request against a marker the store cannot
  verify — unreadable bytes, an undecodable or earlier-version record, a probe
  that failed or timed out — is refused as `store_writer_unverifiable`, which
  names the marker's path and the reason, and is different from
  `store_writer_active`, which is only ever said of a holder the probe found
  alive.
  """

  alias Loopex.Store.Local.Log

  @version "loopex_store_writer_v2"
  @probe "/bin/ps"
  # A helper that has not answered inside this bound is treated as unable to
  # answer; the open must not wait on it, and the answer is never absence.
  @probe_bound_ms 5_000

  @typedoc false
  @type t :: %{path: Path.t(), marker: binary()}

  @doc false
  @spec acquire(Path.t(), boolean()) :: {:ok, t()} | {:error, term()}
  def acquire(store_path, recover_stale_writer, probe \\ @probe)
      when is_binary(store_path) and is_boolean(recover_stale_writer) and is_binary(probe) do
    path = store_path <> ".writer"

    with :ok <- maybe_recover(path, recover_stale_writer, probe),
         {:ok, marker} <- create_marker(path, probe) do
      {:ok, %{path: path, marker: marker}}
    end
  end

  @doc false
  @spec release(t()) :: :ok
  def release(%{path: path, marker: marker}) do
    case File.read(path) do
      {:ok, ^marker} ->
        _ = File.rm(path)
        _ = Log.sync_parent(path)
        :ok

      _absent_or_foreign ->
        :ok
    end
  end

  defp maybe_recover(_path, false, _probe), do: :ok

  # A holder that is still there, or one this version cannot establish is gone,
  # keeps its marker. `create_marker/1` then refuses this opener with the same
  # sentence an ordinary second opener already gets, so an assertion that turned
  # out not to hold costs nothing beyond the refusal it should have had.
  defp maybe_recover(path, true, probe) do
    case holder(path, probe) do
      :gone -> remove_marker(path)
      :held -> :ok
      {:unverifiable, reason} -> {:error, {:store_writer_unverifiable, path, reason}}
    end
  end

  defp remove_marker(path) do
    case File.rm(path) do
      :ok -> Log.sync_parent(path)
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, {:store_writer_recovery_failed, reason}}
    end
  end

  defp holder(path, probe) do
    case File.read(path) do
      {:ok, bytes} -> holder_status(bytes, probe)
      {:error, :enoent} -> :gone
      {:error, reason} -> {:unverifiable, {:unreadable_marker, reason}}
    end
  end

  defp holder_status(bytes, probe) do
    case decode(bytes) do
      {:ok, holder} -> liveness(holder, probe)
      :error -> {:unverifiable, :undecodable_marker}
    end
  end

  defp liveness(%{os_pid: os_pid, incarnation: incarnation, process: process}, probe) do
    case process_incarnation(os_pid, probe) do
      {:ok, ^incarnation} -> same_process_liveness(os_pid, process)
      {:ok, _reused_identifier} -> :gone
      {:error, :process_absent} -> :gone
      {:error, unavailable} -> {:unverifiable, unavailable}
    end
  end

  # Concept: a Store killed inside a VM that is still running leaves a marker
  # nobody holds, and that VM may open the path again.
  #
  # Technical depth: the recorded BEAM process identifier can be asked only
  # where the recorded operating-system process is this one, because a BEAM
  # identifier written by another VM names nothing here. Reaching this clause
  # means the probe reported the recorded start identity for the recorded
  # number, so a number equal to ours was written by this very process.
  defp same_process_liveness(os_pid, process) do
    if os_pid == System.pid() and not alive?(process), do: :gone, else: :held
  end

  defp alive?(process) do
    Process.alive?(:erlang.list_to_pid(String.to_charlist(process)))
  rescue
    ArgumentError -> true
  end

  defp decode(bytes) do
    with [@version, os_pid, encoded, process, _nonce, ""] <- String.split(bytes, "\n"),
         {number, ""} when number > 0 <- Integer.parse(os_pid),
         true <- Integer.to_string(number) == os_pid,
         {:ok, incarnation} when incarnation != "" <-
           Base.url_decode64(encoded, padding: false) do
      {:ok, %{os_pid: os_pid, incarnation: incarnation, process: process}}
    else
      _unreadable -> :error
    end
  end

  defp create_marker(path, probe) do
    case marker_bytes(probe) do
      {:ok, marker} -> write_marker(path, marker)
      {:error, reason} -> {:error, {:store_writer_identity_unavailable, reason}}
    end
  end

  defp write_marker(path, marker) do
    case :file.open(String.to_charlist(path), [:raw, :write, :binary, :exclusive]) do
      {:ok, io} ->
        result =
          with :ok <- :file.write(io, marker),
               :ok <- :file.sync(io) do
            :ok
          end

        close_result = :file.close(io)

        case {result, close_result} do
          {:ok, :ok} ->
            case Log.sync_parent(path) do
              :ok ->
                {:ok, marker}

              {:error, reason} ->
                {:error, reason}
            end

          {{:error, reason}, _close} ->
            {:error, {:store_writer_lock_failed, reason}}

          {:ok, {:error, reason}} ->
            {:error, {:store_writer_lock_close_failed, reason}}
        end

      {:error, :eexist} ->
        {:error, {:store_writer_active, path}}

      {:error, reason} ->
        {:error, {:store_writer_lock_failed, reason}}
    end
  end

  defp marker_bytes(probe) do
    with {:ok, incarnation} <- process_incarnation(System.pid(), probe) do
      encoded = Base.url_encode64(incarnation, padding: false)

      {:ok,
       Enum.join(
         [
           @version,
           System.pid(),
           encoded,
           List.to_string(:erlang.pid_to_list(self())),
           Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)
         ],
         "\n"
       ) <> "\n"}
    end
  end

  # Concept: ask the operating system whether a process is still there, and
  # whether it is the same process that was there when the marker was written.
  #
  # Technical depth: `ps` reports a start identity that stays stable for one
  # process's whole life, so recording it beside the numeric identifier turns
  # identifier reuse into a stale marker rather than a false live holder. It is
  # the mechanism the local executor already uses for the same question, and the
  # dependency budget forbids this application from reaching into that executor
  # for it, so the one call is written here rather than shared through a package
  # neither may depend on. A probe that cannot be run at all answers with a
  # reason rather than with absence, because no answer is not evidence that a
  # process is gone.
  #
  # It runs in a process of its own because a Store traps exits. The helper's
  # port is linked to whoever opens it, and a trapping opener is left holding an
  # `{:EXIT, port, :normal}` message nothing asked for, which its `handle_info/2`
  # then reports as an unexpected message on every single open. A process that
  # does not trap discards that signal by existing.
  defp process_incarnation(os_pid, probe) do
    parent = self()
    reference = make_ref()
    {asker, monitor} = spawn_monitor(fn -> send(parent, {reference, ask(os_pid, probe)}) end)

    receive do
      {^reference, answer} ->
        Process.demonitor(monitor, [:flush])
        answer

      {:DOWN, ^monitor, :process, ^asker, reason} ->
        {:error, {:process_probe_failed, reason}}
    after
      @probe_bound_ms ->
        Process.demonitor(monitor, [:flush])
        Process.exit(asker, :kill)
        {:error, :process_probe_timeout}
    end
  end

  defp ask(os_pid, probe) do
    case System.cmd(probe, ["-o", "lstart=", "-p", os_pid],
           stderr_to_stdout: true,
           env: [{"LC_ALL", "C"}]
         ) do
      {output, 0} ->
        case String.trim(output) do
          "" -> {:error, :empty_process_identity}
          incarnation -> {:ok, incarnation}
        end

      # Concept: only the answer that says "no such process" is absence; a
      # helper that could not inspect has said nothing about the holder.
      #
      # Technical depth: `ps -p` exits 1 with no output when no process
      # matches. Any other status, or a status 1 that still printed something,
      # is a diagnostic — a helper that cannot see the process table, a
      # permission refusal, a malformed argument — and used to be read as
      # absence, so a second opener deleted a live holder's marker and two
      # writers shared one log. That reading contradicted the fail-closed rule
      # this module states for itself; the marker now stays held.
      {output, 1} ->
        if String.trim(output) == "",
          do: {:error, :process_absent},
          else: {:error, {:process_probe_failed, {:exit_status, 1}}}

      {_output, status} ->
        {:error, {:process_probe_failed, {:exit_status, status}}}
    end
  rescue
    ErlangError -> {:error, :process_probe_failed}
  end
end
