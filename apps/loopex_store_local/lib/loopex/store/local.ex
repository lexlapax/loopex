defmodule Loopex.Store.Local do
  @moduledoc """
  ## Concept

  The durable single-machine implementation of `Loopex.Store`. One explicitly
  referenced process serializes an append-only transaction log at a caller-
  chosen path; it has no registered name, implicit default path, or application-
  environment state.

  A completed Store call is already synced. If the process exits or loses a
  reply anywhere around the append, the caller receives `commit_unknown` and
  must re-present the exact transaction. Restart rebuilds every mapping,
  retained resolution, owner head, private record, and outbox row from the log
  before accepting a new call.

  ## Technical depth

  A `GenServer` provides the implementation's one local linearization order.
  `Loopex.Store.Local.State` computes a complete candidate frame without IO;
  `Loopex.Store.Local.Log` appends and syncs that frame; only then does the
  server adopt the new cache. Known transaction IDs return their retained
  result without appending. Replay recomputes each transition and requires the
  stored frame to equal the transition it should have produced, so replay audits
  commit-time fencing instead of granting stale write authority.

  Startup establishes the log file itself, not merely its path, and every append
  is fenced against that identity. A log unlinked or replaced underneath a live
  Store therefore ends the process commit-ambiguously instead of being recreated
  around the frame in flight, which would leave a headless history that recovery
  must refuse.

  Before startup exposes replayed state, the recovered file and parent
  directory are synced again. Thus complete bytes left readable after an
  interrupted write cannot become an acknowledged retained outcome until a
  successful recovery sync establishes their durability.

  One live process at a time writes a path, enforced by the physical writer
  marker `Loopex.Store.Local.WriterLock` describes. This process takes that
  marker at startup and gives it back on an orderly stop, so an embedder who
  stops a Store can open the same path again without recovering anything. A
  marker outliving an untrappable kill or a dead VM is broken only by the
  `:recover_stale_writer` option, which its caller must have earned.

  OTP status formatting removes the last transaction message, Store state,
  termination reason, and debug log before inspection or abnormal-termination
  reporting; private records and owner-incarnation capabilities never enter
  diagnostics.

  The optional fault probe is runtime-local test evidence. It receives only
  declared transition/fault-point identities and can continue, simulate reply
  loss, or kill the Store process. It never enters a durable frame.
  """

  use GenServer

  @behaviour Loopex.Store

  alias Loopex.Store
  alias Loopex.Store.Local.Log
  alias Loopex.Store.Local.State
  alias Loopex.Store.Local.WriterLock
  alias Loopex.Store.Transitions

  @call_timeout 30_000
  @fault_timeout 5_000

  @typedoc """
  ## Concept

  Configuration for one explicit durable local Store instance.

  ## Technical depth

  `:path` is required. `:fault_probe` is optional runtime-local test evidence
  and is never encoded or exposed through the Store port.

  `:recover_stale_writer` defaults to `false` and belongs to a trusted-local
  caller that already controls the runtime root and has established that the
  process tree which left the writer marker is gone. It is never a default and
  never speculative: an opener that has not established that fact leaves it
  absent and is refused by a marker it did not write.
  """
  @type option ::
          {:path, Path.t()} | {:fault_probe, pid()} | {:recover_stale_writer, boolean()}

  @doc """
  ## Concept

  Starts one durable Store at an explicit path.

  ## Technical depth

  Startup reads and semantically audits the entire bounded transaction history;
  a corrupt frame or illegal owner/version sequence prevents the process from
  starting. No process name is registered.

  Startup also takes the physical writer marker for the path, and a startup that
  fails after taking it gives it back before stopping, so a refused open leaves
  no marker naming a process that never ran.
  """
  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(options) when is_list(options) do
    GenServer.start_link(__MODULE__, options)
  end

  @impl Store
  def transact(reference, transaction) do
    GenServer.call(reference, {:transact, transaction}, @call_timeout)
  end

  @impl Store
  def transaction_status(reference, session_id, mutation_domain, tx_id) do
    GenServer.call(
      reference,
      {:transaction_status, session_id, mutation_domain, tx_id},
      @call_timeout
    )
  end

  @impl Store
  def runtime_command(reference, command) do
    GenServer.call(reference, {:runtime_command, command}, @call_timeout)
  end

  @impl Store
  def ownership_head(reference, session_id, mutation_domain) do
    GenServer.call(reference, {:ownership_head, session_id, mutation_domain}, @call_timeout)
  end

  @impl Store
  def load_records(reference, session_id, after_version, limit) do
    GenServer.call(reference, {:load_records, session_id, after_version, limit}, @call_timeout)
  end

  @impl Store
  def load_events(reference, session_id, after_sequence, limit) do
    GenServer.call(reference, {:load_events, session_id, after_sequence, limit}, @call_timeout)
  end

  @impl GenServer
  def init(options) do
    # Technical depth: exits are trapped so that an orderly stop reaches
    # `terminate/2` and gives the writer marker back. An untrappable kill, a VM
    # death, or a power loss still leaves the marker, which is why recovery
    # rather than release is what makes a successor able to open the path.
    Process.flag(:trap_exit, true)

    with {:ok, path} <- fetch_path(options),
         {:ok, log_identity} <- Log.prepare_path(path),
         {:ok, writer_lock} <-
           WriterLock.acquire(path, Keyword.get(options, :recover_stale_writer, false)) do
      recover(options, path, log_identity, writer_lock)
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl GenServer
  def terminate(_reason, %{writer_lock: writer_lock}), do: WriterLock.release(writer_lock)
  def terminate(_reason, _state), do: :ok

  # Concept: a startup that took the marker and then refused to run gives it
  # back, rather than leaving an exclusion behind for a process that never
  # existed.
  defp recover(options, path, log_identity, writer_lock) do
    with {:ok, frames, tail} <- Log.read(path),
         :ok <- repair_if_torn(path, tail),
         {:ok, state} <- State.replay(frames),
         :ok <- Log.sync_recovered(path) do
      {:ok,
       %{
         path: path,
         log_identity: log_identity,
         store: state,
         fault_probe: Keyword.get(options, :fault_probe),
         writer_lock: writer_lock
       }}
    else
      {:error, reason} ->
        WriterLock.release(writer_lock)
        {:stop, reason}
    end
  end

  @impl GenServer
  def handle_call({:transact, transaction}, _from, state) do
    case State.prepare(state.store, transaction) do
      {:known, outcome} ->
        reply_known(state, transaction, outcome)

      {:invalid, outcome} ->
        {:reply, outcome, state}

      {:new, next_store, frame, outcome} ->
        commit_new(state, transaction, next_store, frame, outcome)
    end
  end

  def handle_call(
        {:transaction_status, session_id, mutation_domain, tx_id},
        _from,
        state
      ) do
    {:reply, State.transaction_status(state.store, session_id, mutation_domain, tx_id), state}
  end

  def handle_call({:runtime_command, command}, _from, state) do
    {:reply, State.runtime_command(state.store, command), state}
  end

  def handle_call({:ownership_head, session_id, _mutation_domain}, _from, state) do
    {:reply, State.ownership_head(state.store, session_id), state}
  end

  def handle_call({:load_records, session_id, after_version, limit}, _from, state) do
    {:reply, State.load_records(state.store, session_id, after_version, limit), state}
  end

  def handle_call({:load_events, session_id, after_sequence, limit}, _from, state) do
    {:reply, State.load_events(state.store, session_id, after_sequence, limit), state}
  end

  @impl GenServer
  def format_status(status) do
    status
    |> Map.put(:state, :redacted_store_state)
    |> Map.put(:message, :redacted_store_message)
    |> Map.put(:reason, :redacted_store_reason)
    |> Map.put(:log, [])
  end

  defp reply_known(state, transaction, outcome) do
    with {:ok, transition} <- Transitions.id(transaction),
         :continue <- checkpoint(state.fault_probe, transition, :recovery_representation) do
      {:reply, outcome, state}
    else
      :return_unknown -> {:reply, unknown(transaction), state}
      {:error, reason} -> {:stop, reason, unknown(transaction), state}
    end
  end

  defp commit_new(state, transaction, next_store, frame, outcome) do
    with {:ok, transition} <- Transitions.id(transaction),
         :continue <- checkpoint(state.fault_probe, transition, :before_linearization),
         :ok <- Log.append(state.path, frame, state.log_identity) do
      committed = %{state | store: next_store}

      case checkpoint(
             state.fault_probe,
             transition,
             :after_linearization_before_result
           ) do
        :continue -> {:reply, outcome, committed}
        :return_unknown -> {:reply, unknown(transaction), committed}
        {:error, reason} -> {:stop, reason, unknown(transaction), committed}
      end
    else
      :return_unknown ->
        {:reply, unknown(transaction), state}

      {:error, reason} ->
        {:stop, reason, unknown(transaction), state}
    end
  end

  defp checkpoint(nil, transition, fault_point) do
    case Transitions.validate_pair(transition, fault_point) do
      :ok -> :continue
      {:error, reason} -> {:error, reason}
    end
  end

  defp checkpoint(probe, transition, fault_point) when is_pid(probe) do
    with :ok <- Transitions.validate_pair(transition, fault_point) do
      reference = make_ref()
      pair = {transition, fault_point}
      send(probe, {:loopex_store_fault_point, self(), reference, pair})

      receive do
        {:loopex_store_fault_action, ^reference, :continue} ->
          :continue

        {:loopex_store_fault_action, ^reference, :return_unknown} ->
          :return_unknown

        {:loopex_store_fault_action, ^reference, :kill} ->
          Process.exit(self(), :kill)

        {:loopex_store_fault_action, ^reference, _unknown} ->
          {:error, :unknown_fault_action}
      after
        @fault_timeout -> {:error, :fault_probe_timeout}
      end
    end
  end

  defp checkpoint(_probe, _transition, _fault_point), do: {:error, :invalid_fault_probe}

  defp unknown(transaction) do
    case Store.transaction_id(transaction) do
      {:ok, tx_id} -> {:commit_unknown, tx_id}
      {:error, _reason} -> {:not_committed, :invalid_transaction}
    end
  end

  defp fetch_path(options) do
    allowed = [:fault_probe, :path, :recover_stale_writer]

    cond do
      not Keyword.keyword?(options) ->
        {:error, :invalid_store_options}

      Enum.any?(Keyword.keys(options), &(&1 not in allowed)) ->
        {:error, :invalid_store_options}

      not is_boolean(Keyword.get(options, :recover_stale_writer, false)) ->
        {:error, :invalid_store_options}

      not (is_nil(Keyword.get(options, :fault_probe)) or
               is_pid(Keyword.get(options, :fault_probe))) ->
        {:error, :invalid_store_options}

      true ->
        case Keyword.fetch(options, :path) do
          {:ok, path} when is_binary(path) and byte_size(path) > 0 ->
            {:ok, Path.expand(path)}

          _other ->
            {:error, :store_path_required}
        end
    end
  end

  defp repair_if_torn(_path, :complete), do: :ok

  defp repair_if_torn(path, {:torn, offset, observed_size, observed_digest}) do
    Log.repair_torn_tail(path, offset, observed_size, observed_digest)
  end

  defp repair_if_torn(_path, {:corrupt, offset}), do: {:error, {:store_corrupt, offset}}
end
