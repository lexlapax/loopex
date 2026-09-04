defmodule Loopex.Store.Local.WriterLock do
  @moduledoc """
  ## Concept

  The durable local Store admits one process for a physical store path. A
  second ordinary opener fails closed instead of running another stale cache
  against the same transaction log.

  A holder that terminates in an orderly way gives its own marker back, so an
  ordinary stop leaves nothing behind for the next opener to reason about.
  Restart after an ungraceful VM or OS-process death is still explicit, because
  a killed holder never runs anything. The caller may recover the stale writer
  marker only after it controls the runtime root and has established that the
  prior process tree is gone. This marker is physical writer exclusion, not
  session ownership; ADR 0006 owner epochs and incarnation IDs remain the
  commit-authority fence.

  ## Technical depth

  Acquisition creates and syncs a sidecar with exclusive-create semantics.

  `release/1` is the orderly give-back: it deletes the marker only when the
  file still holds the exact bytes this holder wrote, so a release that arrives
  after someone else already recovered the path cannot remove a successor's
  lock. The comparison is not one kernel operation — OTP's file API exposes no
  compare-and-delete — but the holder is by construction the only live writer
  while its own bytes are present, so the window it leaves is the one that
  recovery already handles rather than a new one.

  A marker therefore remains after an untrappable kill, a whole-VM death, or a
  power loss, none of which run a release. `:recover_stale_writer` is the narrow
  trusted-local operation that breaks such a marker, and only after the prior
  process tree is known dead. Concurrent or speculative recovery is unsupported;
  automatic cleanup on open would introduce a check/delete race capable of
  removing a live successor's lock.
  """

  alias Loopex.Store.Local.Log

  @prefix "loopex_store_writer_v1\n"

  @typedoc false
  @type t :: %{path: Path.t(), marker: binary()}

  @doc false
  @spec acquire(Path.t(), boolean()) :: {:ok, t()} | {:error, term()}
  def acquire(store_path, recover_stale_writer)
      when is_binary(store_path) and is_boolean(recover_stale_writer) do
    path = store_path <> ".writer"

    with :ok <- maybe_recover(path, recover_stale_writer),
         {:ok, marker} <- create_marker(path) do
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

  defp maybe_recover(_path, false), do: :ok

  defp maybe_recover(path, true) do
    case File.rm(path) do
      :ok -> Log.sync_parent(path)
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, {:store_writer_recovery_failed, reason}}
    end
  end

  defp create_marker(path) do
    marker = @prefix <> Base.encode16(:crypto.strong_rand_bytes(32), case: :lower) <> "\n"

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
end
