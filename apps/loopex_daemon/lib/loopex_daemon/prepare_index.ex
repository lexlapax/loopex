defmodule LoopexDaemon.PrepareIndex do
  @moduledoc """
  ## Concept

  `loopex daemon prepare-index` moves a released state root to the daemon
  once: while nothing else holds the root, it reads the legacy session
  directory strictly and publishes the daemon's first index as the union of
  whatever index already exists and every recorded session. An interrupted or
  refused import leaves the prior index exactly as it was.

  ## Technical depth

  The command process is the import sentinel. After the caller's validation it
  installs the daemon's `SIGTERM` route, starts an unlinked import owner, and
  only then sends the ref-tagged `:go`. The owner traps exits and alone holds
  the placement handle and the Store: it acquires placement, opens the Store
  with verified stale-writer recovery (which proves no live writer), prepares
  the `daemon/` directory, loads any canonical index, runs the strict scan in
  one monitored worker that holds no handle, forms the union, refuses a
  conflicting placement or a union over 4,096 rows, and publishes. A queued
  stop is drained before each of those steps; a stop during the scan kills the
  worker. Cleanup stops the Store within 30 s and releases placement through a
  5 s helper, once, on every path.

  The sentinel keeps the first consumed outcome: a success consumed before a
  stop exits `0`; a stop consumed first exits `prepare_index_interrupted` (110)
  even if success was already queued. A stop arms one absolute 40 s watchdog
  over the owner's cleanup. Nothing is written to standard output.
  """

  require Logger

  alias LoopexComposition.Placement
  alias LoopexDaemon.{LegacyImport, SignalHandler}
  alias LoopexDaemon.SessionIndex.{Codec, Storage}

  @interrupt_ms 40_000
  @store_stop_ms 30_000
  @placement_release_ms 5_000
  @held_store :"$loopex_prepare_index_store"
  @held_placement :"$loopex_prepare_index_placement"

  @doc """
  ## Concept

  Runs one import to completion and returns its outcome.

  ## Technical depth

  `state_root` is the validated, expanded root. `options` accepts
  `:install_signals` (default `true`), `:notify` — a pid told
  `{:loopex_prepare_index, sentinel, ref}` so a test can route a stop without
  an operating-system signal — and `:scan`, replacing the strict scan for
  tests. Returns `{:ok, rows}` with the published row count, or
  `{:error, class}` naming an `LoopexDaemon.ExitStatus` class.
  """
  @spec run(Path.t(), keyword()) :: {:ok, non_neg_integer()} | {:error, atom()}
  def run(state_root, options \\ []) when is_binary(state_root) do
    ref = make_ref()

    case install(Keyword.get(options, :install_signals, true), ref) do
      {:ok, handle} ->
        result = supervise(state_root, options, ref)
        uninstall(handle)
        result

      {:error, :signal_install_failed} ->
        {:error, :signal_install_failed}
    end
  end

  defp supervise(state_root, options, ref) do
    sentinel = self()
    scan = Keyword.get(options, :scan, &LegacyImport.scan/2)
    {owner, monitor} = spawn_monitor(fn -> owner(state_root, scan, ref, sentinel) end)
    send(owner, {:go, ref})

    case Keyword.get(options, :notify) do
      pid when is_pid(pid) -> send(pid, {:loopex_prepare_index, sentinel, ref})
      _none -> :ok
    end

    await(%{owner: owner, monitor: monitor, ref: ref, decided: nil, watchdog: nil})
  end

  defp await(%{owner: owner, monitor: monitor, ref: ref} = state) do
    receive do
      {:daemon_signal, ^ref, :sigterm} ->
        send(owner, {:import_stop, ref})

        state =
          if state.decided == nil do
            Logger.debug("loopex prepare-index stop consumed")

            %{
              state
              | decided: :interrupted,
                watchdog: Process.send_after(self(), {:import_watchdog, ref}, @interrupt_ms)
            }
          else
            state
          end

        await(state)

      {:import_result, ^ref, result} ->
        await(if state.decided == nil, do: %{state | decided: result}, else: state)

      {:DOWN, ^monitor, :process, ^owner, _reason} ->
        if state.watchdog, do: Process.cancel_timer(state.watchdog)
        outcome(state.decided)

      {:import_watchdog, ^ref} ->
        Logger.debug("loopex prepare-index interrupt watchdog expired")
        Process.exit(owner, :kill)
        {:error, :prepare_index_interrupted}
    end
  end

  defp outcome({:ok, count}), do: {:ok, count}
  defp outcome(:interrupted), do: {:error, :prepare_index_interrupted}
  defp outcome({:error, class}), do: {:error, class}
  defp outcome(nil), do: {:error, :owner_lost}

  # -- import owner

  defp owner(state_root, scan, ref, sentinel) do
    Process.flag(:trap_exit, true)

    receive do
      {:go, ^ref} -> :ok
    end

    state = %{root: state_root, ref: ref, placement: nil, store: nil, uid: nil}
    {result, _state} = run_import(state, scan)
    send(sentinel, {:import_result, ref, result})
    cleanup()
  end

  defp run_import(state, scan) do
    with :ok <- drain(state),
         {:ok, state} <- acquire_placement(state),
         :ok <- drain(state),
         {:ok, state} <- open_store(state),
         :ok <- drain(state),
         directory = Path.join(state.root, "daemon"),
         :ok <- prepare(directory, state.uid),
         {:ok, canonical} <- load(directory, state.uid),
         :ok <- drain(state),
         {:ok, legacy} <- run_scan(state, scan),
         :ok <- drain(state),
         {:ok, rows} <- union(canonical, legacy),
         :ok <- drain(state),
         :ok <- publish(directory, state.uid, rows) do
      Logger.debug("loopex prepare-index published the index")
      {{:ok, length(rows)}, state}
    else
      {:error, class, state} -> {{:error, class}, state}
      {:error, class} -> {{:error, class}, state}
      :stopped -> {:interrupted, state}
    end
  end

  # Concept: a queued stop or a lost Store ends the import at the next step.
  defp drain(state) do
    ref = state.ref
    store = state.store

    receive do
      {:import_stop, ^ref} -> :stopped
      {:EXIT, ^store, _reason} when is_pid(store) -> {:error, :store_lost}
    after
      0 -> :ok
    end
  end

  defp acquire_placement(state) do
    case Placement.acquire(state.root) do
      {:ok, handle} ->
        Process.put(@held_placement, handle)
        state = %{state | placement: handle}

        case File.stat(handle) do
          {:ok, %File.Stat{type: :regular, uid: uid}} -> {:ok, %{state | uid: uid}}
          _other -> {:error, :placement_lock_failed, state}
        end

      {:error, {class, _detail}}
      when class in [:placement_active, :placement_unverifiable, :placement_lock_failed] ->
        {:error, class}

      _other ->
        {:error, :placement_lock_failed}
    end
  end

  defp open_store(state) do
    path = Path.join(state.root, "store.log")

    case Loopex.Store.Local.start_link(path: path, recover_stale_writer: true) do
      {:ok, store} ->
        Process.put(@held_store, store)
        Logger.debug("loopex prepare-index store writer held")
        {:ok, %{state | store: store}}

      {:error, reason} ->
        flush_exits()
        {:error, store_class(reason), state}
    end
  end

  defp flush_exits do
    receive do
      {:EXIT, _pid, _reason} -> flush_exits()
    after
      0 -> :ok
    end
  end

  defp store_class({class, _detail})
       when class in [:store_writer_active, :store_writer_unverifiable, :store_log_too_large],
       do: class

  defp store_class(class)
       when class in [:store_writer_active, :store_writer_unverifiable, :store_log_too_large],
       do: class

  defp store_class(_reason), do: :store_writer_acquisition_failed

  defp prepare(directory, uid) do
    case Storage.prepare(directory, uid) do
      :ok -> :ok
      {:error, _reason} -> {:error, :state_root_unusable}
    end
  end

  defp load(directory, uid) do
    case Storage.load(directory, uid) do
      {:ok, :missing} ->
        {:ok, []}

      {:ok, rows} when is_list(rows) ->
        {:ok, rows}

      {:error, class} when class in [:session_index_too_large, :session_index_corrupt] ->
        {:error, class}

      {:error, _reason} ->
        {:error, :session_index_corrupt}
    end
  end

  # Concept: the unbounded enumeration runs in a worker that holds nothing,
  # so a stop can end it without waiting.
  defp run_scan(state, scan) do
    parent = self()
    root = state.root
    uid = state.uid

    {worker, monitor} =
      spawn_monitor(fn -> send(parent, {:scan_result, self(), scan.(root, uid)}) end)

    await_scan(state, worker, monitor)
  end

  defp await_scan(state, worker, monitor) do
    ref = state.ref
    store = state.store

    receive do
      {:scan_result, ^worker, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^worker, _reason} ->
        {:error, :session_index_corrupt}

      {:import_stop, ^ref} ->
        reap(worker, monitor)
        :stopped

      {:EXIT, ^store, _reason} ->
        reap(worker, monitor)
        {:error, :store_lost}
    end
  end

  defp reap(worker, monitor) do
    Process.exit(worker, :kill)

    receive do
      {:DOWN, ^monitor, :process, ^worker, _reason} -> :ok
    end
  end

  # Concept: the union never rebinds a session to a different placement.
  defp union(canonical, legacy) do
    merged =
      Enum.reduce_while(
        legacy,
        {:ok, Map.new(canonical, &{&1.session_id, &1.placement_identity})},
        fn
          row, {:ok, acc} ->
            case Map.fetch(acc, row.session_id) do
              :error -> {:cont, {:ok, Map.put(acc, row.session_id, row.placement_identity)}}
              {:ok, same} when same == row.placement_identity -> {:cont, {:ok, acc}}
              {:ok, _other} -> {:halt, {:error, :session_index_corrupt}}
            end
        end
      )

    with {:ok, entries} <- merged do
      if map_size(entries) > Codec.max_entries() do
        {:error, :session_index_too_large}
      else
        {:ok,
         entries
         |> Enum.map(fn {id, placement} -> %{session_id: id, placement_identity: placement} end)
         |> Enum.sort_by(& &1.session_id)}
      end
    end
  end

  defp publish(directory, uid, rows) do
    case Storage.publish(directory, uid, rows) do
      :ok -> :ok
      {:error, :session_index_full} -> {:error, :session_index_too_large}
      {:error, :invalid_index_entry} -> {:error, :session_index_corrupt}
      {:error, _reason} -> {:error, :session_index_write_failed}
    end
  end

  # Concept: cleanup runs once on every path: Store first, placement last,
  # each within its fixed bound.
  #
  # Technical depth: each resource is recorded in the owner's dictionary the
  # moment it is held, so an early refusal cannot hide one from cleanup.
  defp cleanup do
    stop_store(Process.get(@held_store))
    release_placement(Process.get(@held_placement))
  end

  defp stop_store(nil), do: :ok

  defp stop_store(store) do
    monitor = Process.monitor(store)
    Process.unlink(store)
    Process.exit(store, :shutdown)

    receive do
      {:DOWN, ^monitor, :process, ^store, _reason} ->
        Logger.debug("loopex prepare-index store stopped")
    after
      @store_stop_ms ->
        Process.exit(store, :kill)
        Logger.debug("loopex prepare-index store stop deadline reached")
    end
  end

  defp release_placement(nil), do: :ok

  defp release_placement(handle) do
    {helper, monitor} = spawn_monitor(fn -> exit({:released, Placement.release(handle)}) end)

    receive do
      {:DOWN, ^monitor, :process, ^helper, _reason} ->
        Logger.debug("loopex prepare-index placement release attempted")
    after
      @placement_release_ms ->
        Process.exit(helper, :kill)
        Logger.debug("loopex prepare-index placement release deadline reached")
    end
  end

  defp install(false, _ref), do: {:ok, nil}
  defp install(true, ref), do: SignalHandler.install(self(), ref)

  defp uninstall(nil), do: :ok
  defp uninstall(handle), do: SignalHandler.uninstall(handle)
end
