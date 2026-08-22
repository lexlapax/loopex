defmodule Loopex.Runtime.SessionState do
  @moduledoc """
  ## Concept

  The pure durable state and command transition for an M1 session. It rebuilds
  the current owner, command admissions, one active run, pending model intent,
  and public projection from Store-stamped history without performing IO.

  ## Technical depth

  Replays require consecutive journal and public-event positions. A command ID
  binds versioned canonical bytes: exact repetition returns the retained
  admission, changed bytes conflict, and a distinct prompt while a run is active
  commits one durable rejection instead of starting work. Proposed state is not
  authoritative until the Store receipt is admitted by runtime control's
  current-owner post-commit fence.
  """

  @max_command_bytes 65_536

  @typedoc """
  ## Concept

  The recovered durable projection owned by one current session coordinator.

  ## Technical depth

  `commands` binds canonical command digests to stable admission responses.
  `pending_work` contains plain model intents derived from committed prompt
  admissions; Workstream B makes them observable as eligible but does not
  dispatch them.
  """
  @type t :: %__MODULE__{
          session_id: binary(),
          owner_epoch: non_neg_integer(),
          owner_incarnation_id: binary() | nil,
          owner_transaction_id: binary() | nil,
          journal_version: non_neg_integer(),
          event_sequence: non_neg_integer(),
          active_run_id: binary() | nil,
          commands: map(),
          pending_work: map(),
          expected_events: [map()]
        }

  defstruct session_id: nil,
            owner_epoch: 0,
            owner_incarnation_id: nil,
            owner_transaction_id: nil,
            journal_version: 0,
            event_sequence: 0,
            active_run_id: nil,
            commands: %{},
            pending_work: %{},
            expected_events: []

  @typedoc """
  ## Concept

  A pure proposed command transition awaiting one Store transaction.

  ## Technical depth

  Records and events are normalized plain maps accepted by `Loopex.Store`.
  `next` excludes Store-assigned journal and event positions until a committed
  receipt supplies them.
  """
  @type proposal :: %{
          required(:tx_id) => binary(),
          required(:records) => nonempty_list(map()),
          required(:events) => [map()],
          required(:next) => t(),
          required(:reply) => {:accepted, binary()} | {:error, term()}
        }

  @doc """
  ## Concept

  Reconstructs one session from Store-stamped private and public history.

  ## Technical depth

  Both histories must be consecutive from one. Owner succession and command
  records update the private reducer; public events independently establish the
  stable outbox cursor. A malformed or semantically impossible row fails
  recovery rather than becoming current cache state.
  """
  @spec recover(binary(), [map()], [map()]) :: {:ok, t()} | {:error, term()}
  def recover(session_id, records, events)
      when is_binary(session_id) and is_list(records) and is_list(events) do
    with {:ok, state} <- replay_records(%__MODULE__{session_id: session_id}, records),
         {:ok, event_sequence} <- replay_event_sequences(events),
         true <- expected_public_history?(events, state.expected_events),
         {:ok, projection} <- replay_projection(events, event_sequence),
         true <- projection.active_run_id == state.active_run_id do
      {:ok, %{state | event_sequence: event_sequence}}
    else
      false -> {:error, :private_public_projection_mismatch}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  ## Concept

  Proposes one idempotent prompt or abort command against current durable state.

  ## Technical depth

  The reducer first canonicalizes the bounded command. Existing bindings return
  their retained response without another transaction. New accepted and
  rejected admissions both return Store-ready records so a later repetition
  cannot change merely because run state moved on.
  """
  @spec propose(t(), map()) ::
          {:ok, proposal()}
          | {:replayed, {:accepted, binary()} | {:error, term()}}
          | {:error, term()}
  def propose(%__MODULE__{} = state, command) when is_map(command) do
    with {:ok, normalized} <- normalize_command(command),
         {:ok, digest} <- command_digest(normalized) do
      case Map.fetch(state.commands, normalized.command_id) do
        {:ok, %{digest: ^digest, reply: reply}} ->
          {:replayed, reply}

        {:ok, _other_binding} ->
          {:error, :idempotency_conflict}

        :error ->
          propose_new(state, normalized, digest)
      end
    end
  end

  def propose(_state, _command), do: {:error, :invalid_command}

  @doc """
  ## Concept

  Applies Store-assigned positions to a proposed state after commit.

  ## Technical depth

  The receipt must cover exactly one non-empty private range. Public sequence
  advances only when the transaction carried outbox events. Malformed receipt
  data is refused before current cache adoption.
  """
  @spec commit_proposal(proposal(), map()) :: {:ok, t()} | {:error, term()}
  def commit_proposal(%{next: %__MODULE__{} = next, records: records, events: events}, receipt)
      when is_map(receipt) do
    with %{first: first, last: last} <- Map.get(receipt, :journal_versions),
         true <- first == next.journal_version + 1,
         true <- last == next.journal_version + length(records),
         {:ok, event_sequence} <- committed_event_sequence(next, events, receipt) do
      {:ok, %{next | journal_version: last, event_sequence: event_sequence}}
    else
      _other -> {:error, :invalid_store_receipt}
    end
  end

  @doc """
  ## Concept

  Builds an authoritative public snapshot at one committed event sequence.

  ## Technical depth

  The active-run projection is reduced only from durable outbox rows through
  the requested anchor. Event identities remain untouched; events after the
  anchor are excluded so an attachment can stream them contiguously.
  """
  @spec snapshot(binary(), non_neg_integer(), [map()]) :: {:ok, map()} | {:error, term()}
  def snapshot(session_id, anchor, events)
      when is_binary(session_id) and is_integer(anchor) and anchor >= 0 and is_list(events) do
    with {:ok, scan} <- start_snapshot_scan(session_id, anchor),
         {:ok, scan} <- scan_snapshot_page(scan, events),
         {:ok, %{snapshot: snapshot}} <- finish_snapshot_scan(scan) do
      {:ok, snapshot}
    end
  end

  def snapshot(_session_id, _anchor, _events), do: {:error, :invalid_snapshot_anchor}

  @doc """
  ## Concept

  Starts a bounded incremental reduction of durable public history for one
  attachment snapshot.

  ## Technical depth

  The requested anchor is either a non-negative durable cursor or `nil` for the
  Store tail observed by the scan. The accumulator retains only positions and
  active-run projection, never event pages.
  """
  @spec start_snapshot_scan(binary(), non_neg_integer() | nil) :: {:ok, map()} | {:error, term()}
  def start_snapshot_scan(session_id, requested_anchor)
      when is_binary(session_id) and
             (is_nil(requested_anchor) or
                (is_integer(requested_anchor) and requested_anchor >= 0)) do
    anchor_projection = if requested_anchor == 0, do: {:set, nil}, else: :pending

    {:ok,
     %{
       session_id: session_id,
       requested_anchor: requested_anchor,
       tail: 0,
       active_run_id: nil,
       anchor_projection: anchor_projection
     }}
  end

  def start_snapshot_scan(_session_id, _requested_anchor),
    do: {:error, :invalid_snapshot_anchor}

  @doc """
  ## Concept

  Reduces one bounded consecutive Store page into an attachment snapshot scan.

  ## Technical depth

  Every event is shape-, sequence-, and run-transition-validated. Only the
  compact projection is retained after the caller releases the page.
  """
  @spec scan_snapshot_page(map(), [map()]) :: {:ok, map()} | {:error, term()}
  def scan_snapshot_page(scan, events) when is_map(scan) and is_list(events) do
    Enum.reduce_while(events, {:ok, scan}, fn event, {:ok, current} ->
      case advance_snapshot_scan(current, event) do
        {:ok, next} -> {:cont, {:ok, next}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  def scan_snapshot_page(_scan, _events), do: {:error, :invalid_public_history}

  @doc """
  ## Concept

  Finalizes a paged attachment scan at its observed durable tail.

  ## Technical depth

  A requested cursor beyond the tail or not reached by consecutive history is
  refused. The result retains the snapshot anchor separately from the tail used
  to distinguish historical backlog from live overflow.
  """
  @spec finish_snapshot_scan(map()) ::
          {:ok, %{required(:snapshot) => map(), required(:tail) => non_neg_integer()}}
          | {:error, term()}
  def finish_snapshot_scan(%{
        session_id: session_id,
        requested_anchor: requested_anchor,
        tail: tail,
        active_run_id: active_run_id,
        anchor_projection: anchor_projection
      }) do
    case {requested_anchor, anchor_projection} do
      {nil, _projection} ->
        {:ok,
         %{
           tail: tail,
           snapshot: %{
             session_id: session_id,
             event_sequence: tail,
             active_run_id: active_run_id
           }
         }}

      {anchor, {:set, anchor_active_run_id}} when anchor <= tail ->
        {:ok,
         %{
           tail: tail,
           snapshot: %{
             session_id: session_id,
             event_sequence: anchor,
             active_run_id: anchor_active_run_id
           }
         }}

      {_anchor, _projection} ->
        {:error, :cursor_expired}
    end
  end

  def finish_snapshot_scan(_scan), do: {:error, :invalid_public_history}

  @doc """
  ## Concept

  Returns pending work derived from committed prompt admissions.

  ## Technical depth

  Work is sorted by run ID for deterministic inspection. The returned intent is
  not a dispatch grant; later work must pass the current-owner fence and the
  separately accepted Model and Executor boundaries.
  """
  @spec pending_work(t()) :: [map()]
  def pending_work(%__MODULE__{pending_work: work}) do
    work
    |> Map.values()
    |> Enum.sort_by(&Map.fetch!(&1, :run_id))
  end

  defp propose_new(%__MODULE__{active_run_id: nil} = state, %{type: :prompt} = command, digest) do
    run_id = stable_id("run", state.session_id, command.command_id)
    reply = {:accepted, command.command_id}

    record = %{
      "command_id" => command.command_id,
      "command_digest" => digest,
      "command_type" => "prompt",
      "admission" => "accepted",
      "run_id" => run_id,
      "content" => command.content,
      kind: "command_admitted"
    }

    events = prompt_events(state.session_id, command.command_id, run_id, command.content)

    build_proposal(state, command.command_id, record, events, reply)
  end

  defp propose_new(%__MODULE__{} = state, %{type: :prompt} = command, digest) do
    reply = {:error, :run_active}

    record = %{
      "command_id" => command.command_id,
      "command_digest" => digest,
      "command_type" => "prompt",
      "admission" => "rejected_run_active",
      kind: "command_admitted"
    }

    build_proposal(state, command.command_id, record, [], reply)
  end

  defp propose_new(%__MODULE__{active_run_id: run_id} = state, %{type: :abort} = command, digest)
       when is_binary(run_id) do
    reply = {:accepted, command.command_id}

    record = %{
      "command_id" => command.command_id,
      "command_digest" => digest,
      "command_type" => "abort",
      "admission" => "accepted",
      "run_id" => run_id,
      kind: "command_admitted"
    }

    event = abort_event(state.session_id, command.command_id, run_id)

    build_proposal(state, command.command_id, record, [event], reply)
  end

  defp propose_new(%__MODULE__{} = state, %{type: :abort} = command, digest) do
    reply = {:error, :no_active_run}

    record = %{
      "command_id" => command.command_id,
      "command_digest" => digest,
      "command_type" => "abort",
      "admission" => "rejected_no_active_run",
      kind: "command_admitted"
    }

    build_proposal(state, command.command_id, record, [], reply)
  end

  defp build_proposal(state, tx_id, record, events, reply) do
    case apply_command_record(state, record) do
      {:ok, next} -> {:ok, proposal(tx_id, record, events, next, reply)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp proposal(tx_id, record, events, next, reply) do
    %{tx_id: tx_id, records: [record], events: events, next: next, reply: reply}
  end

  defp replay_records(state, records) do
    result =
      Enum.reduce_while(records, {:ok, state}, fn record, {:ok, current} ->
        case replay_record(current, record) do
          {:ok, next} -> {:cont, {:ok, next}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)

    case result do
      {:ok, %{journal_version: version} = recovered} when version > 0 -> {:ok, recovered}
      {:ok, _empty} -> {:error, :missing_session_genesis}
      {:error, reason} -> {:error, reason}
    end
  end

  defp replay_record(
         %{journal_version: 0} = state,
         %{
           journal_version: 1,
           owner_epoch: 0,
           owner_incarnation_id: nil,
           payload: %{kind: "session_genesis"}
         }
       ),
       do: {:ok, %{state | journal_version: 1}}

  defp replay_record(
         state,
         %{
           journal_version: version,
           owner_epoch: owner_epoch,
           owner_incarnation_id: incarnation,
           payload: %{
             "prior_owner_epoch" => prior_epoch,
             "owner_epoch" => payload_epoch,
             "owner_incarnation_id" => payload_incarnation,
             "owner_transaction_id" => owner_transaction_id,
             kind: "owner_advanced"
           }
         }
       ) do
    if version == state.journal_version + 1 and prior_epoch == state.owner_epoch and
         owner_epoch == state.owner_epoch + 1 and payload_epoch == owner_epoch and
         is_binary(incarnation) and byte_size(incarnation) > 0 and
         payload_incarnation == incarnation and is_binary(owner_transaction_id) and
         byte_size(owner_transaction_id) > 0 do
      {:ok,
       %{
         state
         | journal_version: version,
           owner_epoch: owner_epoch,
           owner_incarnation_id: incarnation,
           owner_transaction_id: owner_transaction_id
       }}
    else
      {:error, :invalid_owner_transition}
    end
  end

  defp replay_record(
         state,
         %{
           journal_version: version,
           owner_epoch: owner_epoch,
           owner_incarnation_id: incarnation,
           payload: %{kind: "command_admitted"} = record
         }
       ) do
    if version == state.journal_version + 1 and owner_epoch == state.owner_epoch and
         incarnation == state.owner_incarnation_id and is_binary(incarnation) do
      case apply_command_record(state, record) do
        {:ok, next} -> {:ok, %{next | journal_version: version}}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :invalid_command_owner_stamp}
    end
  end

  defp replay_record(_state, _record), do: {:error, :invalid_private_history}

  defp apply_command_record(state, record) do
    with {:ok, command_id} <- record_binary(record, "command_id"),
         {:ok, digest} <- record_binary(record, "command_digest"),
         {:ok, command_type} <- record_binary(record, "command_type"),
         {:ok, admission} <- record_binary(record, "admission"),
         false <- Map.has_key?(state.commands, command_id),
         {:ok, reply, active_run_id, pending_work, expected_events} <-
           command_effect(state, record, command_type, admission, command_id) do
      command_binding = %{digest: digest, reply: reply}

      {:ok,
       %{
         state
         | active_run_id: active_run_id,
           pending_work: pending_work,
           expected_events: expected_events,
           commands: Map.put(state.commands, command_id, command_binding)
       }}
    else
      true -> {:error, :duplicate_command_record}
      {:error, reason} -> {:error, reason}
    end
  end

  defp command_effect(
         %{active_run_id: nil} = state,
         record,
         "prompt",
         "accepted",
         command_id
       ) do
    with {:ok, run_id} <- record_binary(record, "run_id"),
         {:ok, content} <- record_binary(record, "content") do
      work = %{type: "model", run_id: run_id, command_id: command_id, content: content}

      expected_events =
        state.expected_events ++ prompt_events(state.session_id, command_id, run_id, content)

      {:ok, {:accepted, command_id}, run_id, Map.put(state.pending_work, run_id, work),
       expected_events}
    end
  end

  defp command_effect(
         %{active_run_id: run_id} = state,
         _record,
         "prompt",
         "rejected_run_active",
         _command_id
       )
       when is_binary(run_id),
       do:
         {:ok, {:error, :run_active}, state.active_run_id, state.pending_work,
          state.expected_events}

  defp command_effect(
         %{active_run_id: active_run_id} = state,
         record,
         "abort",
         "accepted",
         command_id
       )
       when is_binary(active_run_id) do
    case record_binary(record, "run_id") do
      {:ok, ^active_run_id} ->
        expected_events =
          state.expected_events ++ [abort_event(state.session_id, command_id, active_run_id)]

        {:ok, {:accepted, command_id}, nil, Map.delete(state.pending_work, active_run_id),
         expected_events}

      _other ->
        {:error, :invalid_abort_record}
    end
  end

  defp command_effect(
         %{active_run_id: nil} = state,
         _record,
         "abort",
         "rejected_no_active_run",
         _command_id
       ),
       do: {:ok, {:error, :no_active_run}, nil, state.pending_work, state.expected_events}

  defp command_effect(_state, _record, _command_type, _admission, _command_id),
    do: {:error, :invalid_command_transition}

  defp record_binary(record, key) do
    case Map.fetch(record, key) do
      {:ok, value} when is_binary(value) and byte_size(value) > 0 -> {:ok, value}
      _other -> {:error, :invalid_command_record}
    end
  end

  defp replay_event_sequences(events) do
    Enum.reduce_while(events, {:ok, 0}, fn event, {:ok, prior} ->
      case event do
        %{event_sequence: sequence, event_id: event_id, kind: kind}
        when sequence == prior + 1 and is_binary(event_id) and is_binary(kind) ->
          {:cont, {:ok, sequence}}

        _other ->
          {:halt, {:error, :invalid_public_history}}
      end
    end)
  end

  defp replay_projection(events, anchor) do
    with {:ok, scan} <- start_snapshot_scan("replay", anchor),
         {:ok, scan} <- scan_snapshot_page(scan, events),
         {:ok, %{snapshot: %{active_run_id: active_run_id, event_sequence: ^anchor}}} <-
           finish_snapshot_scan(scan) do
      {:ok, %{active_run_id: active_run_id, sequence: anchor}}
    else
      {:error, :cursor_expired} -> {:error, :snapshot_cursor_unavailable}
      {:error, reason} -> {:error, reason}
    end
  end

  defp advance_snapshot_scan(scan, event) do
    expected = scan.tail + 1

    with {:ok, active_run_id} <- advance_public_projection(scan.active_run_id, event, expected) do
      anchor_projection =
        if scan.requested_anchor == expected,
          do: {:set, active_run_id},
          else: scan.anchor_projection

      {:ok,
       %{
         scan
         | tail: expected,
           active_run_id: active_run_id,
           anchor_projection: anchor_projection
       }}
    end
  end

  defp advance_public_projection(
         nil,
         %{
           "run_id" => run_id,
           event_sequence: expected,
           event_id: event_id,
           kind: "run.started"
         },
         expected
       )
       when is_binary(run_id) and byte_size(run_id) > 0 and is_binary(event_id),
       do: {:ok, run_id}

  defp advance_public_projection(
         active_run_id,
         %{
           "run_id" => active_run_id,
           event_sequence: expected,
           event_id: event_id,
           kind: "run.finished"
         },
         expected
       )
       when is_binary(active_run_id) and is_binary(event_id),
       do: {:ok, nil}

  defp advance_public_projection(
         _active_run_id,
         %{event_sequence: expected, event_id: event_id, kind: kind},
         expected
       )
       when kind in ["run.started", "run.finished"] and is_binary(event_id),
       do: {:error, :invalid_public_run_transition}

  defp advance_public_projection(
         active_run_id,
         %{event_sequence: expected, event_id: event_id, kind: kind},
         expected
       )
       when is_binary(event_id) and is_binary(kind),
       do: {:ok, active_run_id}

  defp advance_public_projection(_active_run_id, _event, _expected),
    do: {:error, :invalid_public_history}

  defp expected_public_history?(events, expected_events) do
    Enum.all?(events, &is_map/1) and
      Enum.map(events, &Map.delete(&1, :event_sequence)) == expected_events
  end

  defp prompt_events(session_id, command_id, run_id, content) do
    [
      %{
        "command_id" => command_id,
        "run_id" => run_id,
        "content" => content,
        event_id: stable_id("event-user", session_id, command_id),
        kind: "user.message_appended"
      },
      %{
        "command_id" => command_id,
        "run_id" => run_id,
        event_id: stable_id("event-run", session_id, command_id),
        kind: "run.started"
      }
    ]
  end

  defp abort_event(session_id, command_id, run_id) do
    %{
      "command_id" => command_id,
      "run_id" => run_id,
      "outcome" => "aborted",
      event_id: stable_id("event-abort", session_id, command_id),
      kind: "run.finished"
    }
  end

  defp committed_event_sequence(next, [], receipt) do
    case Map.get(receipt, :event_sequences) do
      nil -> {:ok, next.event_sequence}
      _other -> {:error, :unexpected_event_receipt}
    end
  end

  defp committed_event_sequence(next, events, receipt) do
    with %{first: first, last: last} <- Map.get(receipt, :event_sequences),
         true <- first == next.event_sequence + 1,
         true <- last == next.event_sequence + length(events) do
      {:ok, last}
    else
      _other -> {:error, :invalid_event_receipt}
    end
  end

  defp normalize_command(command) do
    with {:ok, command_id} <- fetch_binary(command, :command_id),
         {:ok, type} <- fetch_type(command) do
      case type do
        :prompt ->
          with {:ok, content} <- fetch_binary(command, :content),
               true <- byte_size(content) <= @max_command_bytes do
            {:ok, %{type: :prompt, command_id: command_id, content: content}}
          else
            _other -> {:error, :invalid_command}
          end

        :abort ->
          {:ok, %{type: :abort, command_id: command_id}}
      end
    end
  end

  defp fetch_type(command) do
    case fetch(command, :type) do
      {:ok, value} when value in [:prompt, "prompt"] -> {:ok, :prompt}
      {:ok, value} when value in [:abort, "abort"] -> {:ok, :abort}
      _other -> {:error, :invalid_command_type}
    end
  end

  defp fetch_binary(command, key) do
    case fetch(command, key) do
      {:ok, value}
      when is_binary(value) and byte_size(value) > 0 and byte_size(value) <= @max_command_bytes ->
        {:ok, value}

      _other ->
        {:error, :invalid_command}
    end
  end

  defp fetch(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(map, Atom.to_string(key))
    end
  end

  defp command_digest(command) do
    bytes = :erlang.term_to_binary(["loopex_command_v1", command], [:deterministic])
    {:ok, :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)}
  end

  defp stable_id(namespace, session_id, command_id) do
    bytes = :erlang.term_to_binary([namespace, session_id, command_id], [:deterministic])
    encoded = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
    String.slice(namespace, 0, 8) <> "_" <> binary_part(encoded, 0, 30)
  end
end
