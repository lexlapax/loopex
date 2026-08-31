defmodule Loopex.Store.Local.State do
  @moduledoc false

  alias Loopex.Store
  alias Loopex.Store.Transitions

  @schema_version 1

  @spec new() :: map()
  def new do
    %{
      next_session_number: 1,
      runtime_commands: %{},
      orphan_resolutions: %{},
      sessions: %{}
    }
  end

  @spec prepare(map(), map()) ::
          {:known, Store.outcome()}
          | {:new, map(), map(), Store.outcome()}
          | {:invalid, Store.outcome()}
  def prepare(state, transaction) when is_map(state) and is_map(transaction) do
    case retained_resolution(state, transaction) do
      {:ok, retained} ->
        resolve_known(retained, transaction)

      :absent ->
        prepare_unknown(state, transaction)

      :invalid_scope ->
        {:invalid, {:not_committed, :invalid_transaction}}
    end
  end

  @spec replay([map()]) :: {:ok, map()} | {:error, term()}
  def replay(frames) when is_list(frames) do
    frames
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, new()}, fn {frame, index}, {:ok, state} ->
      case replay_frame(state, frame) do
        {:ok, next} -> {:cont, {:ok, next}}
        {:error, reason} -> {:halt, {:error, {:invalid_history, index, reason}}}
      end
    end)
  end

  @spec transaction_status(map(), binary(), binary(), binary()) :: Store.transaction_status()
  def transaction_status(state, session_id, mutation_domain, tx_id) do
    resolutions =
      case Map.fetch(state.sessions, session_id) do
        {:ok, session} -> session.resolutions
        :error -> Map.get(state.orphan_resolutions, session_id, %{})
      end

    case fetch_resolution(resolutions, mutation_domain, tx_id) do
      {:ok, retained} -> status_of(retained.resolution)
      :absent -> :absent
    end
  end

  @spec ownership_head(map(), binary()) :: {:ok, Store.ownership_head()} | :absent
  def ownership_head(state, session_id) do
    case Map.fetch(state.sessions, session_id) do
      {:ok, session} ->
        {:ok,
         %{
           owner_epoch: session.owner_epoch,
           journal_version: session.journal_version
         }}

      :error ->
        :absent
    end
  end

  @spec runtime_command(map(), map()) ::
          :absent | {:error, :runtime_command_conflict} | {:open, map()} | {:completed, map()}
  def runtime_command(state, command) do
    case fetch_nested(state.runtime_commands, command.runtime_id, command.command_id) do
      :absent ->
        :absent

      {:ok, %{command: ^command, status: :open, generation: generation, candidate: candidate}} ->
        {:open, %{attempt_generation: generation, candidate_tx_id: candidate.tx_id}}

      {:ok,
       %{
         command: ^command,
         status: :completed,
         generation: generation,
         candidate: candidate,
         result: result
       }} ->
        {:completed,
         %{attempt_generation: generation, candidate_tx_id: candidate.tx_id, result: result}}

      {:ok, _changed_binding} ->
        {:error, :runtime_command_conflict}
    end
  end

  @spec load_records(map(), binary(), non_neg_integer(), pos_integer()) ::
          {:ok, [Store.private_record()]}
  def load_records(state, session_id, after_version, limit) do
    rows =
      case Map.fetch(state.sessions, session_id) do
        {:ok, session} ->
          session.records
          |> Enum.filter(&(Map.fetch!(&1, :journal_version) > after_version))
          |> Enum.take(limit)

        :error ->
          []
      end

    {:ok, rows}
  end

  @spec load_events(map(), binary(), non_neg_integer(), pos_integer()) ::
          {:ok, [Store.outbox_event()]}
  def load_events(state, session_id, after_sequence, limit) do
    rows =
      case Map.fetch(state.sessions, session_id) do
        {:ok, session} ->
          session.events
          |> Enum.filter(&(Map.fetch!(&1, :event_sequence) > after_sequence))
          |> Enum.take(limit)

        :error ->
          []
      end

    {:ok, rows}
  end

  defp resolve_known(retained, transaction) do
    case Store.immutable_binding(transaction) do
      {:ok, binding} when binding == retained.binding ->
        {:known, outcome_of(retained.resolution, tx_id(transaction))}

      _other ->
        {:known, {:not_committed, :tx_id_conflict}}
    end
  end

  defp prepare_unknown(state, transaction) do
    with :ok <- Store.validate_transaction(transaction),
         {:ok, transition} <- Transitions.id(transaction) do
      linearize(state, transition, transaction)
    else
      {:error, _reason} -> {:invalid, {:not_committed, :invalid_transaction}}
    end
  end

  defp linearize(state, :runtime_control_create_session, transaction) do
    {session_id, session_number} = allocate_session_id(state, transaction)
    genesis = stamp_genesis(transaction.genesis)

    receipt = %{
      type: :create_session,
      session_id: session_id,
      journal_version: 1
    }

    resolution = committed_resolution(receipt)
    retained = retained(transaction, resolution)

    session = %{
      runtime_id: transaction.runtime_id,
      owner_epoch: 0,
      owner_incarnation_id: nil,
      journal_version: 1,
      event_sequence: 0,
      records: [genesis],
      events: [],
      event_ids: %{},
      resolutions: %{}
    }

    runtime_commands =
      put_nested(
        state.runtime_commands,
        transaction.runtime_id,
        transaction.command_id,
        Map.put(retained, :session_id, session_id)
      )

    next = %{
      state
      | next_session_number: session_number + 1,
        runtime_commands: runtime_commands,
        sessions: Map.put(state.sessions, session_id, session)
    }

    frame = frame(:runtime_control_create_session, transaction, resolution, [genesis], [])
    {:new, next, frame, {:committed, transaction.command_id, receipt}}
  end

  defp linearize(state, :runtime_control_stage_owner_attempt, transaction) do
    case Map.fetch(state.sessions, transaction.session_id) do
      :error ->
        retain_absent_session(state, transaction)

      {:ok, session} ->
        command = owner_command_binding(transaction)

        reason = stage_refusal(state, session, transaction, command)

        if reason do
          retain_non_commit(state, session, transaction, reason)
        else
          resolution = committed_resolution(%{type: :stage_owner_attempt})

          staged = %{
            command: command,
            status: :open,
            generation: transaction.attempt_generation,
            candidate: transaction.candidate,
            result: nil
          }

          updated = %{
            session
            | resolutions: put_resolution(session.resolutions, transaction, resolution)
          }

          next =
            state
            |> put_session(transaction.session_id, updated)
            |> put_runtime_command(transaction.runtime_id, transaction.command_id, staged)

          frame =
            frame(:runtime_control_stage_owner_attempt, transaction, resolution, [], [])

          {:new, next, frame, {:committed, transaction.tx_id, %{type: :stage_owner_attempt}}}
        end
    end
  end

  defp linearize(state, :session_journal_advance_owner, transaction) do
    case Map.fetch(state.sessions, transaction.session_id) do
      :error ->
        retain_absent_session(state, transaction)

      {:ok, session} ->
        reason = succession_refusal(state, session, transaction)

        case reason do
          nil -> commit_succession(state, session, transaction)
          reason -> retain_non_commit(state, session, transaction, reason)
        end
    end
  end

  defp linearize(state, :session_journal_commit, transaction) do
    case Map.fetch(state.sessions, transaction.session_id) do
      :error ->
        retain_absent_session(state, transaction)

      {:ok, session} ->
        reason = ordinary_refusal(session, transaction)

        case reason do
          nil -> commit_records(state, session, transaction)
          reason -> retain_non_commit(state, session, transaction, reason)
        end
    end
  end

  defp commit_succession(state, session, transaction) do
    owner_epoch = session.owner_epoch + 1
    journal_version = session.journal_version + 1

    payload = %{
      "prior_owner_epoch" => session.owner_epoch,
      "owner_epoch" => owner_epoch,
      "owner_incarnation_id" => transaction.proposed_owner_incarnation_id,
      "owner_transaction_id" => transaction.tx_id,
      kind: "owner_advanced"
    }

    stamped = %{
      journal_version: journal_version,
      owner_epoch: owner_epoch,
      owner_incarnation_id: transaction.proposed_owner_incarnation_id,
      payload: payload
    }

    receipt = %{
      type: :advance_owner,
      owner_epoch: owner_epoch,
      owner_incarnation_id: transaction.proposed_owner_incarnation_id,
      journal_version: journal_version
    }

    resolution = committed_resolution(receipt)

    updated = %{
      session
      | owner_epoch: owner_epoch,
        owner_incarnation_id: transaction.proposed_owner_incarnation_id,
        journal_version: journal_version,
        records: session.records ++ [stamped],
        resolutions: put_resolution(session.resolutions, transaction, resolution)
    }

    next = put_session(state, transaction.session_id, updated)

    next =
      if Map.has_key?(transaction, :runtime_id) do
        {:ok, staged} =
          fetch_nested(next.runtime_commands, transaction.runtime_id, transaction.command_id)

        completed = %{staged | status: :completed, result: transaction.session_id}
        put_runtime_command(next, transaction.runtime_id, transaction.command_id, completed)
      else
        next
      end

    frame =
      frame(:session_journal_advance_owner, transaction, resolution, [stamped], [])

    {:new, next, frame, {:committed, transaction.tx_id, receipt}}
  end

  defp commit_records(state, session, transaction) do
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
        _events -> %{first: first_sequence, last: first_sequence + length(events) - 1}
      end

    receipt = %{
      type: :session_commit,
      journal_versions: %{first: first_version, last: last_version},
      event_sequences: event_sequences
    }

    resolution = committed_resolution(receipt)

    event_ids =
      Enum.reduce(events, session.event_ids, fn event, ids ->
        Map.put(ids, event.event_id, true)
      end)

    updated = %{
      session
      | journal_version: last_version,
        event_sequence: session.event_sequence + length(events),
        records: session.records ++ records,
        events: session.events ++ events,
        event_ids: event_ids,
        resolutions: put_resolution(session.resolutions, transaction, resolution)
    }

    next = put_session(state, transaction.session_id, updated)
    frame = frame(:session_journal_commit, transaction, resolution, records, events)
    {:new, next, frame, {:committed, transaction.tx_id, receipt}}
  end

  defp retain_non_commit(state, session, transaction, reason) do
    resolution = %{status: :not_committed, reason: reason}

    updated = %{
      session
      | resolutions: put_resolution(session.resolutions, transaction, resolution)
    }

    next = put_session(state, transaction.session_id, updated)
    {:ok, transition} = Transitions.id(transaction)
    frame = frame(transition, transaction, resolution, [], [])
    {:new, next, frame, {:not_committed, reason}}
  end

  defp retain_absent_session(state, transaction) do
    resolution = %{status: :not_committed, reason: :session_not_found}
    resolutions = Map.get(state.orphan_resolutions, transaction.session_id, %{})
    updated = put_resolution(resolutions, transaction, resolution)

    next = %{
      state
      | orphan_resolutions: Map.put(state.orphan_resolutions, transaction.session_id, updated)
    }

    {:ok, transition} = Transitions.id(transaction)
    frame = frame(transition, transaction, resolution, [], [])
    {:new, next, frame, {:not_committed, :session_not_found}}
  end

  defp replay_frame(
         state,
         %{
           schema_version: @schema_version,
           transaction: transaction
         } = frame
       ) do
    case prepare(state, transaction) do
      {:new, next, expected, _outcome} when expected == frame -> {:ok, next}
      {:new, _next, _expected, _outcome} -> {:error, :frame_does_not_match_transition}
      {:known, _outcome} -> {:error, :duplicate_transaction_frame}
      {:invalid, _outcome} -> {:error, :invalid_transaction_frame}
    end
  end

  defp replay_frame(_state, _frame), do: {:error, :invalid_frame_schema}

  defp retained_resolution(state, %{type: :create_session} = transaction) do
    fetch_nested(state.runtime_commands, transaction[:runtime_id], transaction[:command_id])
  end

  defp retained_resolution(state, transaction)
       when transaction.type in [:stage_owner_attempt, :advance_owner, :session_commit] do
    with session_id when is_binary(session_id) <- Map.get(transaction, :session_id),
         mutation_domain when is_binary(mutation_domain) <-
           Map.get(transaction, :mutation_domain),
         tx_id when is_binary(tx_id) <- Map.get(transaction, :tx_id),
         resolutions <- scoped_resolutions(state, session_id) do
      fetch_resolution(resolutions, mutation_domain, tx_id)
    else
      _other -> :invalid_scope
    end
  end

  defp retained_resolution(_state, _transaction), do: :invalid_scope

  defp succession_refusal(state, session, transaction) do
    cond do
      owner_command_refusal(state, transaction) != nil ->
        owner_command_refusal(state, transaction)

      transaction.expected_owner_epoch != session.owner_epoch ->
        :stale_owner_epoch

      transaction.expected_journal_version != session.journal_version ->
        :stale_journal_version

      true ->
        nil
    end
  end

  defp owner_command_refusal(state, %{runtime_id: runtime_id} = transaction) do
    command = owner_command_binding(transaction)

    case fetch_nested(state.runtime_commands, runtime_id, transaction.command_id) do
      {:ok,
       %{
         command: ^command,
         status: :open,
         generation: generation,
         candidate: %{tx_id: tx_id} = candidate
       }}
      when generation == transaction.attempt_generation and tx_id == transaction.tx_id ->
        case {Store.immutable_binding(candidate), Store.immutable_binding(transaction)} do
          {{:ok, binding}, {:ok, binding}} -> nil
          _mismatch -> :owner_candidate_conflict
        end

      {:ok, %{command: ^command, status: :completed}} ->
        :command_completed

      _other ->
        :runtime_command_conflict
    end
  end

  defp owner_command_refusal(_state, _transaction), do: nil

  defp stage_refusal(state, session, transaction, command) do
    cond do
      session.runtime_id != transaction.runtime_id ->
        :runtime_placement_mismatch

      unresolved_other_owner_command?(state, session, transaction) ->
        :owner_attempt_in_progress

      true ->
        case fetch_nested(
               state.runtime_commands,
               transaction.runtime_id,
               transaction.command_id
             ) do
          :absent ->
            if transaction.expected_generation == 0, do: nil, else: :stale_attempt_generation

          {:ok, %{command: ^command, status: :open, generation: generation}}
          when generation == transaction.expected_generation ->
            nil

          {:ok, %{command: ^command, status: :completed}} ->
            :command_completed

          {:ok, _changed_binding} ->
            :runtime_command_conflict
        end
    end
  end

  defp unresolved_other_owner_command?(state, session, transaction) do
    state.runtime_commands
    |> Enum.flat_map(fn {_runtime_id, commands} -> Map.values(commands) end)
    |> Enum.any?(fn
      %{
        command: %{session_id: session_id, mutation_domain: mutation_domain} = command,
        status: :open,
        candidate: candidate
      } ->
        same_command =
          command.runtime_id == transaction.runtime_id and
            command.command_id == transaction.command_id

        same_session_domain =
          session_id == transaction.session_id and
            mutation_domain == transaction.mutation_domain

        same_session_domain and not same_command and
          fetch_resolution(session.resolutions, mutation_domain, candidate.tx_id) == :absent

      _other ->
        false
    end)
  end

  defp ordinary_refusal(session, transaction) do
    cond do
      transaction.expected_owner_epoch != session.owner_epoch ->
        :stale_owner_epoch

      transaction.expected_owner_incarnation_id != session.owner_incarnation_id ->
        :stale_owner_incarnation_id

      transaction.expected_journal_version != session.journal_version ->
        :stale_journal_version

      Enum.any?(transaction.outbox, &Map.has_key?(session.event_ids, &1.event_id)) ->
        :duplicate_event_id

      true ->
        nil
    end
  end

  defp frame(transition, transaction, resolution, records, events) do
    %{
      schema_version: @schema_version,
      transition_id: transition,
      transaction: transaction,
      resolution: resolution,
      records: records,
      events: events
    }
  end

  defp stamp_genesis(payload) do
    %{
      journal_version: 1,
      owner_epoch: 0,
      owner_incarnation_id: nil,
      payload: payload
    }
  end

  defp committed_resolution(receipt), do: %{status: :committed, receipt: receipt}

  defp retained(transaction, resolution) do
    {:ok, binding} = Store.immutable_binding(transaction)
    %{binding: binding, resolution: resolution}
  end

  defp put_resolution(resolutions, transaction, resolution) do
    domain = Map.get(resolutions, transaction.mutation_domain, %{})
    retained = retained(transaction, resolution)

    Map.put(
      resolutions,
      transaction.mutation_domain,
      Map.put(domain, transaction.tx_id, retained)
    )
  end

  defp outcome_of(%{status: :committed, receipt: receipt}, tx_id),
    do: {:committed, tx_id, receipt}

  defp outcome_of(%{status: :not_committed, reason: reason}, _tx_id),
    do: {:not_committed, reason}

  defp status_of(%{status: :committed}), do: {:terminal, :committed}

  defp status_of(%{status: :not_committed, reason: reason}),
    do: {:terminal, {:not_committed, reason}}

  defp tx_id(%{type: :create_session, command_id: command_id}), do: command_id
  defp tx_id(%{tx_id: tx_id}), do: tx_id

  defp allocate_session_id(state, transaction) do
    allocate_session_id(state, transaction, state.next_session_number)
  end

  defp allocate_session_id(state, transaction, session_number) do
    bytes =
      :erlang.term_to_binary(
        [
          "loopex_session_id_v1",
          transaction.runtime_id,
          transaction.command_id,
          session_number
        ],
        [:deterministic]
      )

    encoded = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
    session_id = "s_" <> binary_part(encoded, 0, 30)

    if Map.has_key?(state.sessions, session_id) or
         Map.has_key?(state.orphan_resolutions, session_id) do
      allocate_session_id(state, transaction, session_number + 1)
    else
      {session_id, session_number}
    end
  end

  defp put_session(state, session_id, session) do
    %{state | sessions: Map.put(state.sessions, session_id, session)}
  end

  defp put_runtime_command(state, runtime_id, command_id, command) do
    %{
      state
      | runtime_commands: put_nested(state.runtime_commands, runtime_id, command_id, command)
    }
  end

  defp owner_command_binding(transaction) do
    %{
      runtime_id: transaction.runtime_id,
      command_id: transaction.command_id,
      command_kind: transaction.command_kind,
      session_id: transaction.session_id,
      mutation_domain: transaction.mutation_domain,
      succession_id: transaction.succession_id,
      canonical_command_bytes: transaction.canonical_command_bytes,
      canonical_command_digest: transaction.canonical_command_digest
    }
  end

  defp put_nested(outer, first, second, value) do
    Map.put(outer, first, Map.put(Map.get(outer, first, %{}), second, value))
  end

  defp fetch_nested(outer, first, second) when is_binary(first) and is_binary(second) do
    with {:ok, inner} <- Map.fetch(outer, first),
         {:ok, value} <- Map.fetch(inner, second) do
      {:ok, value}
    else
      :error -> :absent
    end
  end

  defp fetch_nested(_outer, _first, _second), do: :invalid_scope

  defp scoped_resolutions(state, session_id) do
    case Map.fetch(state.sessions, session_id) do
      {:ok, session} -> session.resolutions
      :error -> Map.get(state.orphan_resolutions, session_id, %{})
    end
  end

  defp fetch_resolution(resolutions, mutation_domain, tx_id) do
    with {:ok, domain} <- Map.fetch(resolutions, mutation_domain),
         {:ok, retained} <- Map.fetch(domain, tx_id) do
      {:ok, retained}
    else
      :error -> :absent
    end
  end
end
