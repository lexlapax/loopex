defmodule Loopex.Store.Local.JobRange do
  @moduledoc """
  ## Concept

  One approved read job verifies an artifact and retrieves one range. Its I/O
  runs in the executor-owned calling process, so that process's termination
  also releases every raw descriptor it opened.

  ## Technical depth

  A linked watchdog enforces open/read deadlines while the caller is in file
  I/O. It kills that disposable caller on expiry or transfer-owner loss. Normal
  return follows descriptor cleanup and watchdog termination. The shared
  transfer owner monitors the same caller to release its capacity on failure.
  One whole-window work reservation precedes storage. Observed reads, writes
  and emitted bytes debit it once; an unsuccessful write conservatively charges
  its entire attempted length. There is no reopen loop or new allowance within
  this call. The executor's retained job ledger owns repeated dispatch.
  """

  alias Loopex.{ArtifactStore, Runtime.ArtifactRead}
  alias Loopex.Store.Local.{Artifacts, Transfers}

  @minimum_open 1_048_576
  @job_work 1_073_741_824

  @doc false
  @spec read(map(), map()) :: {:ok, binary()} | {:error, term()}
  def read(%{transfers: owner} = handle, job) when is_pid(owner) do
    limits = ArtifactStore.transfer_limits()

    with {:ok, range} <- ArtifactRead.job_range(job),
         true <- range.reference.size <= limits.object_bytes,
         length = min(range.length, range.reference.size - range.offset),
         reservation = max(@minimum_open, 2 * range.reference.size + length),
         true <- reservation <= @job_work and 2 * range.reference.size <= limits.open_work_bytes,
         remaining = job.effective_job_deadline - System.system_time(:millisecond),
         true <- remaining > 0 do
      now = System.monotonic_time(:millisecond)
      job_deadline = now + remaining
      open_deadline = min(job_deadline, now + limits.open_deadline_ms)
      caller = self()
      nonce = make_ref()

      {watchdog, monitor} =
        :erlang.spawn_opt(
          fn ->
            watch(%{
              caller: caller,
              caller_monitor: Process.monitor(caller),
              owner_monitor: Process.monitor(owner),
              nonce: nonce,
              deadline: open_deadline,
              job_deadline: job_deadline,
              wall_deadline: job.effective_job_deadline,
              read_ms: limits.read_deadline_ms,
              phase: :open,
              reservation: reservation,
              charged: @minimum_open,
              work: %{}
            })
          end,
          [:link, :monitor]
        )

      try do
        with {:ok, placement} <- Transfers.reserve_job(owner, open_deadline) do
          try do
            with {:ok, use} <-
                   ArtifactStore.describe(%{module: Artifacts, handle: handle}, range.reference),
                 :ok <- provenance(use, range.source, job.session_id) do
              Transfers.job_window(
                placement,
                range.reference,
                %{start: range.offset, length: length},
                open_deadline,
                watchdog
              )
            end
          after
            Transfers.release_job(owner, placement.job_monitor)
          end
        end
      after
        # Concept: a successful callback leaves no watchdog behind.
        # Technical depth: I/O and capacity have already unwound. The monitor
        # still detects abnormal watchdog termination after unlinking; the
        # deadline retains precedence until the watchdog accepts closure.
        Process.unlink(watchdog)
        send(watchdog, {:job_range_closed, caller, nonce})

        receive do
          {:DOWN, ^monitor, :process, ^watchdog, :normal} ->
            :ok

          {:DOWN, ^monitor, :process, ^watchdog, reason} ->
            exit({:artifact_watchdog_failed, reason})
        end
      end
    else
      false -> {:error, :artifact_job_bound_exceeded}
      {:error, reason} -> {:error, reason}
    end
  end

  def read(_, _), do: {:error, :transfers_unavailable}

  defp provenance(use, source, session) do
    expected = %{
      "session_id" => session,
      "run_id" => source["run_id"],
      "operation_id" => source["operation_id"],
      "attempt" => source["attempt"],
      "tool_call_id" => source["tool_call_id"]
    }

    if use.metadata == expected, do: :ok, else: {:error, :artifact_use_mismatch}
  end

  defp watch(state) do
    remaining =
      min(
        state.deadline - System.monotonic_time(:millisecond),
        state.wall_deadline - System.system_time(:millisecond)
      )

    if remaining <= 0 do
      Process.exit(state.caller, :kill)
    else
      caller = state.caller
      nonce = state.nonce
      caller_monitor = state.caller_monitor
      owner_monitor = state.owner_monitor

      receive do
        {:job_range_closed, ^caller, ^nonce} ->
          if System.monotonic_time(:millisecond) >= state.deadline or
               System.system_time(:millisecond) >= state.wall_deadline do
            Process.exit(caller, :kill)
          else
            :ok
          end

        {:job_read_phase, ^caller, started} when state.phase == :open ->
          watch(%{
            state
            | phase: :read,
              deadline: min(state.job_deadline, started + state.read_ms)
          })

        {:job_storage_work, ^caller, kind, bytes} when is_integer(bytes) and bytes >= 0 ->
          work = Map.update(state.work, kind, bytes, &(&1 + bytes))
          charged = max(state.charged, Enum.sum(Map.values(work)))

          if charged <= state.reservation do
            watch(%{state | work: work, charged: charged})
          else
            Process.exit(caller, :kill)
          end

        {:DOWN, ^caller_monitor, :process, ^caller, _reason} ->
          :ok

        {:DOWN, ^owner_monitor, :process, _owner, _reason} ->
          Process.exit(caller, :kill)

        _other ->
          watch(state)
      after
        min(remaining, 100) -> watch(state)
      end
    end
  end
end
