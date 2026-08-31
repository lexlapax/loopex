_ = System.fetch_env!("LOOPEX_HOME")

defmodule Loopex.M1RuntimeTestStore do
  @moduledoc false

  use GenServer

  alias Loopex.Store
  alias Loopex.Store.Transitions

  @behaviour Store

  def start_store(options \\ []) do
    {:ok, pid} = GenServer.start(__MODULE__, options)
    {:ok, store} = Store.new(__MODULE__, pid)
    {pid, store}
  end

  def inject(pid, {transition, phase} = pair) do
    :ok = Transitions.validate_pair(transition, phase)
    GenServer.call(pid, {:inject, pair})
  end

  def delay_after_commit(pid, transition, observer) when is_pid(observer),
    do: GenServer.call(pid, {:delay_after_commit, transition, observer})

  # Concept: pause the caller after one transaction carrying a named record has
  # become durable.
  #
  # Technical depth: several session semantics are distinguished by records
  # inside the common `session_journal_commit` transaction shape. Delaying by
  # record kind lets a test crash the owner at that exact durable boundary
  # without inventing a product hook or accidentally stopping an earlier commit
  # that uses the same Store transition.
  def delay_after_record(pid, kind, observer) when is_binary(kind) and is_pid(observer),
    do: GenServer.call(pid, {:delay_after_record, kind, observer})

  # Concept: hold one named transaction before the Store decides it, while the
  # Store remains available to a successor.
  #
  # Technical depth: a stale-owner refusal is meaningful only when ownership
  # moves before the old transaction linearizes. Keeping the original caller
  # pending outside the GenServer lets an `advance_owner` transaction establish
  # that order without fabricating a refusal or blocking the serialized Store.
  def hold_next_record_before_linearization(pid, kind, observer)
      when is_binary(kind) and is_pid(observer),
      do: GenServer.call(pid, {:hold_next_record_before_linearization, kind, observer})

  def block_next_event_read(pid, observer) when is_pid(observer),
    do: GenServer.call(pid, {:block_next_event_read, observer})

  def release(waiter) when is_pid(waiter), do: send(waiter, :release)

  def inspect_state(pid), do: GenServer.call(pid, :inspect_state)
  def observed(pid), do: GenServer.call(pid, :observed)
  def injected(pid), do: GenServer.call(pid, :injected)
  def fail_reads(pid, enabled), do: GenServer.call(pid, {:fail_reads, enabled})

  # Concept: refuse one named kind of record, once.
  #
  # Technical depth: a Store may answer `not_committed` to any transaction, and a
  # coordinator that treats one particular refusal as a tidy fallback rather than
  # as a failure is what lets a run commit its ending with the operation it owns
  # unsettled. Refusing by record kind rather than by transition identity is what
  # lets a case name the transaction it means without knowing the identity a
  # given run happened to derive for it.
  def refuse_next_record(pid, kind) when is_binary(kind),
    do: GenServer.call(pid, {:refuse_next_record, kind})

  @impl Store
  def transact(pid, transaction), do: GenServer.call(pid, {:transact, transaction}, :infinity)

  @impl Store
  def transaction_status(pid, session_id, domain, tx_id),
    do: GenServer.call(pid, {:transaction_status, session_id, domain, tx_id})

  @impl Store
  def ownership_head(pid, session_id, _domain),
    do: GenServer.call(pid, {:ownership_head, session_id})

  @impl Store
  def load_records(pid, session_id, after_version, limit),
    do: GenServer.call(pid, {:load_records, session_id, after_version, limit})

  @impl Store
  def load_events(pid, session_id, after_sequence, limit),
    do: GenServer.call(pid, {:load_events, session_id, after_sequence, limit}, :infinity)

  @impl GenServer
  def init(options) do
    {:ok,
     %{
       label: Keyword.get(options, :label, "test-store"),
       next_session: 1,
       runtime_commands: %{},
       sessions: %{},
       resolutions: %{},
       status_queries: [],
       event_reads: [],
       injected: MapSet.new(),
       observed: MapSet.new(),
       faults: %{},
       recovery_setup: MapSet.new(),
       delayed: %{},
       delayed_records: %{},
       held_before_records: %{},
       pending_transactions: %{},
       event_read_block: nil,
       fail_reads: false,
       refuse_records: MapSet.new()
     }}
  end

  @impl GenServer
  def handle_call({:inject, {transition, phase} = pair}, _from, state) do
    recovery_setup =
      if phase == :recovery_representation,
        do: MapSet.put(state.recovery_setup, transition),
        else: state.recovery_setup

    {:reply, :ok,
     %{
       state
       | injected: MapSet.put(state.injected, pair),
         faults: Map.put(state.faults, pair, 1),
         recovery_setup: recovery_setup
     }}
  end

  def handle_call({:delay_after_commit, transition, observer}, _from, state) do
    {:reply, :ok, %{state | delayed: Map.put(state.delayed, transition, observer)}}
  end

  def handle_call({:delay_after_record, kind, observer}, _from, state) do
    {:reply, :ok, %{state | delayed_records: Map.put(state.delayed_records, kind, observer)}}
  end

  def handle_call({:hold_next_record_before_linearization, kind, observer}, _from, state) do
    {:reply, :ok,
     %{state | held_before_records: Map.put(state.held_before_records, kind, observer)}}
  end

  def handle_call({:block_next_event_read, observer}, _from, state) do
    {:reply, :ok, %{state | event_read_block: observer}}
  end

  def handle_call({:fail_reads, enabled}, _from, state) do
    {:reply, :ok, %{state | fail_reads: enabled == true}}
  end

  def handle_call({:refuse_next_record, kind}, _from, state) do
    {:reply, :ok, %{state | refuse_records: MapSet.put(state.refuse_records, kind)}}
  end

  def handle_call(:observed, _from, state), do: {:reply, state.observed, state}
  def handle_call(:injected, _from, state), do: {:reply, state.injected, state}

  def handle_call(:inspect_state, _from, state) do
    visible =
      Map.drop(state, [
        :faults,
        :delayed,
        :delayed_records,
        :held_before_records,
        :pending_transactions,
        :event_read_block
      ])

    {:reply, visible, state}
  end

  def handle_call({:transact, transaction}, from, state) do
    case held_before_record(state, transaction) do
      {kind, observer} -> hold_before_linearization(state, from, transaction, kind, observer)
      nil -> transact(state, from, transaction)
    end
  end

  def handle_call({:transaction_status, session_id, domain, tx_id}, _from, state) do
    result =
      case Map.get(state.resolutions, {session_id, domain, tx_id}) do
        %{outcome: {:committed, _tx, _receipt}} -> {:terminal, :committed}
        %{outcome: {:not_committed, reason}} -> {:terminal, {:not_committed, reason}}
        nil -> :absent
      end

    query = {session_id, domain, tx_id}
    {:reply, result, %{state | status_queries: state.status_queries ++ [query]}}
  end

  def handle_call({:ownership_head, _session_id}, _from, %{fail_reads: true} = state),
    do: {:reply, :unavailable, state}

  def handle_call({:ownership_head, session_id}, _from, state) do
    result =
      case Map.get(state.sessions, session_id) do
        nil ->
          :absent

        session ->
          {:ok,
           %{
             owner_epoch: session.owner_epoch,
             journal_version: session.journal_version
           }}
      end

    {:reply, result, state}
  end

  def handle_call(
        {:load_records, _session_id, _after_version, _limit},
        _from,
        %{fail_reads: true} = state
      ),
      do: {:reply, :unavailable, state}

  def handle_call({:load_records, session_id, after_version, limit}, _from, state) do
    records =
      state.sessions
      |> Map.get(session_id, empty_session())
      |> Map.fetch!(:records)
      |> Enum.filter(&(&1.journal_version > after_version))
      |> Enum.take(limit)

    {:reply, {:ok, records}, state}
  end

  def handle_call(
        {:load_events, _session_id, _after_sequence, _limit},
        _from,
        %{fail_reads: true} = state
      ),
      do: {:reply, :unavailable, state}

  def handle_call({:load_events, session_id, after_sequence, limit}, from, state) do
    events =
      state.sessions
      |> Map.get(session_id, empty_session())
      |> Map.fetch!(:events)
      |> Enum.filter(&(&1.event_sequence > after_sequence))
      |> Enum.take(limit)

    result = {:ok, events}

    event_read = %{
      session_id: session_id,
      after_sequence: after_sequence,
      limit: limit,
      returned: length(events)
    }

    state = %{state | event_reads: state.event_reads ++ [event_read]}

    case state.event_read_block do
      observer when is_pid(observer) ->
        waiter = delayed_reply(from, result)
        send(observer, {:event_history_read, waiter, self(), session_id, events})
        {:noreply, %{state | event_read_block: nil}}

      nil ->
        {:reply, result, state}
    end
  end

  @impl GenServer
  def handle_info({:release_before_linearization, token}, state) do
    case Map.pop(state.pending_transactions, token) do
      {nil, _pending} ->
        {:noreply, state}

      {{from, transaction}, pending} ->
        state = %{state | pending_transactions: pending}

        case transact(state, from, transaction) do
          {:reply, reply, next} ->
            GenServer.reply(from, reply)
            {:noreply, next}

          {:noreply, next} ->
            {:noreply, next}
        end
    end
  end

  defp transact(state, from, transaction) do
    case refused_kind(state, transaction) do
      nil ->
        admit(state, from, transaction)

      kind ->
        {:reply, {:not_committed, :refused_by_test_store},
         %{state | refuse_records: MapSet.delete(state.refuse_records, kind)}}
    end
  end

  defp held_before_record(%{held_before_records: held}, transaction) do
    transaction
    |> Map.get(:records, [])
    |> Enum.find_value(fn record ->
      kind = record_kind(record)

      case Map.fetch(held, kind) do
        {:ok, observer} -> {kind, observer}
        :error -> nil
      end
    end)
  end

  defp hold_before_linearization(state, from, transaction, kind, observer) do
    token = make_ref()
    server = self()

    waiter =
      spawn(fn ->
        receive do
          :release -> send(server, {:release_before_linearization, token})
        end
      end)

    send(observer, {:record_held_before_linearization, waiter, self(), kind, transaction})

    {:noreply,
     %{
       state
       | held_before_records: Map.delete(state.held_before_records, kind),
         pending_transactions: Map.put(state.pending_transactions, token, {from, transaction})
     }}
  end

  defp refused_kind(%{refuse_records: refused} = _state, transaction) do
    transaction
    |> Map.get(:records, [])
    |> Enum.map(&record_kind/1)
    |> Enum.find(&MapSet.member?(refused, &1))
  end

  defp record_kind(record) when is_map(record),
    do: Map.get(record, :kind) || Map.get(record, "kind")

  defp record_kind(_record), do: nil

  defp admit(state, from, transaction) do
    with :ok <- Store.validate_transaction(transaction),
         {:ok, transition} <- Transitions.id(transaction),
         {:ok, binding} <- Store.immutable_binding(transaction) do
      case retained(state, transaction) do
        {:ok, %{binding: ^binding, outcome: outcome}} ->
          {checkpoint, state} = checkpoint(state, transition, :recovery_representation)
          reply_checkpoint(checkpoint, from, state, transaction, outcome)

        {:ok, _other_binding} ->
          {:reply, {:not_committed, :tx_id_conflict}, state}

        :absent ->
          transact_new(state, from, transition, transaction, binding)
      end
    else
      _other -> {:reply, {:not_committed, :invalid_transaction}, state}
    end
  end

  defp transact_new(state, from, transition, transaction, binding) do
    {before, state} = checkpoint(state, transition, :before_linearization)

    case before do
      :unknown ->
        {:reply, unknown(transaction), state}

      :continue ->
        {state, outcome} = linearize(state, transaction, binding)

        {after_checkpoint, state} =
          checkpoint(state, transition, :after_linearization_before_result)

        case delayed_record(state, transaction) do
          {kind, observer} ->
            waiter = delayed_reply(from, outcome)
            send(observer, {:record_linearized, waiter, self(), kind, transition, outcome})

            {:noreply, %{state | delayed_records: Map.delete(state.delayed_records, kind)}}

          nil ->
            reply_after_linearization(
              state,
              from,
              transition,
              transaction,
              outcome,
              after_checkpoint
            )
        end
    end
  end

  defp reply_after_linearization(
         state,
         from,
         transition,
         transaction,
         outcome,
         after_checkpoint
       ) do
    cond do
      Map.has_key?(state.delayed, transition) ->
        {observer, delayed} = Map.pop(state.delayed, transition)
        waiter = delayed_reply(from, outcome)
        send(observer, {:transaction_linearized, waiter, self(), transition, outcome})
        {:noreply, %{state | delayed: delayed}}

      MapSet.member?(state.recovery_setup, transition) ->
        {:reply, unknown(transaction),
         %{state | recovery_setup: MapSet.delete(state.recovery_setup, transition)}}

      after_checkpoint == :unknown ->
        {:reply, unknown(transaction), state}

      true ->
        {:reply, outcome, state}
    end
  end

  defp delayed_record(%{delayed_records: delayed}, transaction) do
    transaction
    |> Map.get(:records, [])
    |> Enum.find_value(fn record ->
      kind = record_kind(record)

      case Map.fetch(delayed, kind) do
        {:ok, observer} -> {kind, observer}
        :error -> nil
      end
    end)
  end

  defp reply_checkpoint(:unknown, _from, state, transaction, _outcome),
    do: {:reply, unknown(transaction), state}

  defp reply_checkpoint(:continue, _from, state, _transaction, outcome),
    do: {:reply, outcome, state}

  defp checkpoint(state, transition, phase) do
    :ok = Transitions.validate_pair(transition, phase)
    pair = {transition, phase}
    observed = MapSet.put(state.observed, pair)

    case Map.get(state.faults, pair, 0) do
      count when count > 0 ->
        faults =
          if count == 1,
            do: Map.delete(state.faults, pair),
            else: Map.put(state.faults, pair, count - 1)

        {:unknown, %{state | observed: observed, faults: faults}}

      _zero ->
        {:continue, %{state | observed: observed}}
    end
  end

  defp linearize(state, %{type: :create_session} = transaction, binding) do
    session_id = "s_test_" <> Integer.to_string(state.next_session)

    genesis = %{
      journal_version: 1,
      owner_epoch: 0,
      owner_incarnation_id: nil,
      payload: transaction.genesis
    }

    receipt = %{type: :create_session, session_id: session_id, journal_version: 1}
    outcome = {:committed, transaction.command_id, receipt}

    retained = %{binding: binding, outcome: outcome, session_id: session_id}
    command_key = {transaction.runtime_id, transaction.command_id}

    session = %{
      owner_epoch: 0,
      owner_incarnation_id: nil,
      journal_version: 1,
      event_sequence: 0,
      records: [genesis],
      events: [],
      event_ids: MapSet.new()
    }

    next = %{
      state
      | next_session: state.next_session + 1,
        runtime_commands: Map.put(state.runtime_commands, command_key, retained),
        sessions: Map.put(state.sessions, session_id, session)
    }

    {next, outcome}
  end

  defp linearize(state, %{type: :advance_owner} = transaction, binding) do
    case Map.get(state.sessions, transaction.session_id) do
      nil ->
        retain_noncommit(state, transaction, binding, :session_not_found)

      session ->
        cond do
          transaction.expected_owner_epoch != session.owner_epoch ->
            retain_noncommit(state, transaction, binding, :stale_owner_epoch)

          transaction.expected_journal_version != session.journal_version ->
            retain_noncommit(state, transaction, binding, :stale_journal_version)

          true ->
            epoch = session.owner_epoch + 1
            version = session.journal_version + 1

            payload = %{
              "prior_owner_epoch" => session.owner_epoch,
              "owner_epoch" => epoch,
              "owner_incarnation_id" => transaction.proposed_owner_incarnation_id,
              "owner_transaction_id" => transaction.tx_id,
              kind: "owner_advanced"
            }

            stamped = %{
              journal_version: version,
              owner_epoch: epoch,
              owner_incarnation_id: transaction.proposed_owner_incarnation_id,
              payload: payload
            }

            receipt = %{
              type: :advance_owner,
              owner_epoch: epoch,
              owner_incarnation_id: transaction.proposed_owner_incarnation_id,
              journal_version: version
            }

            outcome = {:committed, transaction.tx_id, receipt}

            updated = %{
              session
              | owner_epoch: epoch,
                owner_incarnation_id: transaction.proposed_owner_incarnation_id,
                journal_version: version,
                records: session.records ++ [stamped]
            }

            next =
              state
              |> put_session(transaction.session_id, updated)
              |> put_resolution(transaction, binding, outcome)

            {next, outcome}
        end
    end
  end

  defp linearize(state, %{type: :session_commit} = transaction, binding) do
    case Map.get(state.sessions, transaction.session_id) do
      nil ->
        retain_noncommit(state, transaction, binding, :session_not_found)

      session ->
        refusal = session_commit_refusal(session, transaction)

        if is_nil(refusal) do
          first_version = session.journal_version + 1

          records =
            transaction.records
            |> Enum.with_index(first_version)
            |> Enum.map(fn {payload, version} ->
              %{
                journal_version: version,
                owner_epoch: session.owner_epoch,
                owner_incarnation_id: session.owner_incarnation_id,
                payload: payload
              }
            end)

          first_sequence = session.event_sequence + 1

          events =
            transaction.outbox
            |> Enum.with_index(first_sequence)
            |> Enum.map(fn {event, sequence} -> Map.put(event, :event_sequence, sequence) end)

          last_version = first_version + length(records) - 1

          event_sequences =
            case events do
              [] -> nil
              _rows -> %{first: first_sequence, last: first_sequence + length(events) - 1}
            end

          receipt = %{
            type: :session_commit,
            journal_versions: %{first: first_version, last: last_version},
            event_sequences: event_sequences
          }

          outcome = {:committed, transaction.tx_id, receipt}

          updated = %{
            session
            | journal_version: last_version,
              event_sequence: session.event_sequence + length(events),
              records: session.records ++ records,
              events: session.events ++ events,
              event_ids:
                Enum.reduce(events, session.event_ids, &MapSet.put(&2, Map.fetch!(&1, :event_id)))
          }

          next =
            state
            |> put_session(transaction.session_id, updated)
            |> put_resolution(transaction, binding, outcome)

          {next, outcome}
        else
          retain_noncommit(state, transaction, binding, refusal)
        end
    end
  end

  defp retained(state, %{type: :create_session} = transaction) do
    case Map.get(state.runtime_commands, {transaction.runtime_id, transaction.command_id}) do
      nil -> :absent
      retained -> {:ok, retained}
    end
  end

  defp retained(state, transaction) do
    case Map.get(
           state.resolutions,
           {transaction.session_id, transaction.mutation_domain, transaction.tx_id}
         ) do
      nil -> :absent
      retained -> {:ok, retained}
    end
  end

  defp retain_noncommit(state, transaction, binding, reason) do
    outcome = {:not_committed, reason}
    {put_resolution(state, transaction, binding, outcome), outcome}
  end

  defp put_resolution(state, transaction, binding, outcome) do
    key = {transaction.session_id, transaction.mutation_domain, transaction.tx_id}
    %{state | resolutions: Map.put(state.resolutions, key, %{binding: binding, outcome: outcome})}
  end

  defp put_session(state, session_id, session),
    do: %{state | sessions: Map.put(state.sessions, session_id, session)}

  defp session_commit_refusal(session, transaction) do
    cond do
      transaction.expected_owner_epoch != session.owner_epoch ->
        :stale_owner_epoch

      transaction.expected_owner_incarnation_id != session.owner_incarnation_id ->
        :stale_owner_incarnation_id

      transaction.expected_journal_version != session.journal_version ->
        :stale_journal_version

      Enum.any?(transaction.outbox, &MapSet.member?(session.event_ids, &1.event_id)) ->
        :duplicate_event_id

      true ->
        nil
    end
  end

  defp unknown(transaction) do
    {:ok, tx_id} = Store.transaction_id(transaction)
    {:commit_unknown, tx_id}
  end

  defp delayed_reply(from, reply) do
    spawn(fn ->
      receive do
        :release -> GenServer.reply(from, reply)
      end
    end)
  end

  defp empty_session do
    %{
      owner_epoch: 0,
      owner_incarnation_id: nil,
      journal_version: 0,
      event_sequence: 0,
      records: [],
      events: [],
      event_ids: MapSet.new()
    }
  end
end
