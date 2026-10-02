defmodule Loopex.Store.Memory do
  @moduledoc """
  ## Concept

  A non-durable Store for short-lived embedded sessions. One explicitly
  referenced process owns all committed records. Stopping that process or
  losing the VM loses the history. There is no restart or replay promise.

  ## Technical depth

  The GenServer serializes the durable local store's pure transitions using
  Loopex.Store.Local.State. It writes no file, registers no name and keeps no
  application-global state. History grows across runs while the host keeps
  the process alive.

  An optional runtime-local fault probe exercises the conformance protocol
  at declared checkpoints. It receives identities, never records, and is absent
  from ordinary compositions. OTP status reports redact state, messages,
  termination reasons and debug logs.
  """

  use GenServer
  @behaviour Loopex.Store

  alias Loopex.Store
  alias Loopex.Store.Local.State
  alias Loopex.Store.Transitions

  @call_timeout 30_000
  @fault_timeout 5_000

  @doc """
  ## Concept

  Starts one linked, non-durable Store process with empty history.

  ## Technical depth

  The optional :fault_probe setting names a conformance-fixture PID. The caller
  or its supervisor owns the lifetime. No path or registered name is needed.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options \\ []) when is_list(options) do
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
  def ownership_head(reference, session_id, mutation_domain) do
    GenServer.call(reference, {:ownership_head, session_id, mutation_domain}, @call_timeout)
  end

  @impl Store
  def runtime_command(reference, command) do
    GenServer.call(reference, {:runtime_command, command}, @call_timeout)
  end

  @impl Store
  def creation_provenance(reference, runtime, selector),
    do: GenServer.call(reference, {:creation_provenance, runtime, selector}, @call_timeout)

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
    {:ok, %{store: State.new(), fault_probe: Keyword.get(options, :fault_probe)}}
  end

  @impl GenServer
  def handle_call({:transact, transaction}, _from, state) do
    case State.prepare(state.store, transaction) do
      {:known, outcome} -> reply_known(state, transaction, outcome)
      {:invalid, outcome} -> {:reply, outcome, state}
      {:new, next, _frame, outcome} -> commit_new(state, transaction, next, outcome)
    end
  end

  def handle_call({:transaction_status, session_id, mutation_domain, tx_id}, _from, state) do
    {:reply, State.transaction_status(state.store, session_id, mutation_domain, tx_id), state}
  end

  def handle_call({:ownership_head, session_id, _mutation_domain}, _from, state) do
    {:reply, State.ownership_head(state.store, session_id), state}
  end

  def handle_call({:runtime_command, command}, _from, state) do
    {:reply, State.runtime_command(state.store, command), state}
  end

  def handle_call({:creation_provenance, runtime, selector}, _from, state),
    do: {:reply, State.creation_provenance(state.store, runtime, selector), state}

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

  defp commit_new(state, transaction, next_store, outcome) do
    with {:ok, transition} <- Transitions.id(transaction),
         :continue <- checkpoint(state.fault_probe, transition, :before_linearization) do
      committed = %{state | store: next_store}

      case checkpoint(state.fault_probe, transition, :after_linearization_before_result) do
        :continue -> {:reply, outcome, committed}
        :return_unknown -> {:reply, unknown(transaction), committed}
        {:error, reason} -> {:stop, reason, unknown(transaction), committed}
      end
    else
      :return_unknown -> {:reply, unknown(transaction), state}
      {:error, reason} -> {:stop, reason, unknown(transaction), state}
    end
  end

  defp checkpoint(nil, transition, fault_point) do
    case Transitions.validate_pair(transition, fault_point) do
      :ok -> :continue
      {:error, reason} -> {:error, reason}
    end
  end

  # Concept: a probe can lose a reply without changing transaction identity.
  # Technical depth: only the exact checkpoint reference answers this wait.
  # Unknown actions refuse; a kill cannot return an acknowledged outcome.
  defp checkpoint(probe, transition, fault_point) when is_pid(probe) do
    with :ok <- Transitions.validate_pair(transition, fault_point) do
      reference = make_ref()
      send(probe, {:loopex_store_fault_point, self(), reference, {transition, fault_point}})

      receive do
        {:loopex_store_fault_action, ^reference, :continue} -> :continue
        {:loopex_store_fault_action, ^reference, :return_unknown} -> :return_unknown
        {:loopex_store_fault_action, ^reference, :kill} -> Process.exit(self(), :kill)
        {:loopex_store_fault_action, ^reference, _unknown} -> {:error, :unknown_fault_action}
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
end
