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

  `conversation` holds the committed elements of each run, which
  `Loopex.Conversation` projects into the message list a turn stages. `bounds`
  holds each run's declared bounds exactly as they were committed at admission
  or promotion, and `charged` accumulates that run's token charge with the
  source that produced it.
  """
  alias Loopex.ArtifactStore
  alias Loopex.Bounds
  alias Loopex.Conversation

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
          conversation: map(),
          bounds: map(),
          deadlines: map(),
          steer: map(),
          follow_up: map() | nil,
          charged: map(),
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
            conversation: %{},
            bounds: %{},
            deadlines: %{},
            steer: %{},
            follow_up: nil,
            charged: %{},
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
  @spec propose(t(), map(), map()) ::
          {:ok, proposal()}
          | {:replayed, {:accepted, binary()} | {:error, term()}}
          | {:error, term()}
  def propose(state, command, resolved \\ %{})

  def propose(%__MODULE__{} = state, command, resolved)
      when is_map(command) and is_map(resolved) do
    with {:ok, normalized} <- normalize_command(command),
         {:ok, digest} <- command_digest(normalized) do
      case Map.fetch(state.commands, normalized.command_id) do
        {:ok, %{digest: ^digest, reply: reply}} ->
          {:replayed, reply}

        {:ok, _other_binding} ->
          {:error, :idempotency_conflict}

        :error ->
          propose_new(state, Map.put(normalized, :resolved_bounds, resolved), digest)
      end
    end
  end

  def propose(_state, _command, _resolved), do: {:error, :invalid_command}

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

  @doc """
  ## Concept

  The committed conversation elements of one run.

  ## Technical depth

  In commit order. `Loopex.Conversation` owns how they project into messages;
  this is only the store of what was committed, so a caller cannot get a
  projection that disagrees with the journal by asking a different function.
  """
  @spec elements(t(), binary()) :: [Conversation.element()]
  def elements(%__MODULE__{conversation: conversation}, run_id),
    do: Map.get(conversation, run_id, [])

  @doc """
  ## Concept

  The bounds declared for one run and the tokens charged against them so far.

  ## Technical depth

  Bounds are read back exactly as committed. A recovering owner never recomputes
  a deadline from its own clock, because that would hand a run back the downtime
  it slept through.
  """
  @spec accounting(t(), binary()) :: {map() | nil, map()}
  def accounting(%__MODULE__{} = state, run_id) do
    declared = Map.get(state.bounds, run_id)
    charged = Map.get(state.charged, run_id, %{tokens: 0, source: nil})

    {declared && Map.put(declared, :deadline, Map.get(state.deadlines, run_id)), charged}
  end

  @doc """
  ## Concept

  The steer waiting to join this run, if one is queued.

  ## Technical depth

  Read by the coordinator when it stages the next request, which is the single
  point where a steer can be applied. A steer is never applied anywhere else and
  is never recorded applied unless a committed request actually carried it.
  """

  @spec pending_steer(t(), binary()) :: map() | nil
  def pending_steer(%__MODULE__{} = state, run_id), do: queued_steer(state, run_id)

  @doc """
  ## Concept

  Whether this run holds an effect whose truth was never established.

  ## Technical depth

  A committed `outcome_unknown` tool result means nobody knows whether that
  effect happened. A run carrying one cannot honestly end `bound_reached` or
  `completed`, because both claim the run finished in a known state. This is what
  gives `outcome_unknown` precedence over every other terminal outcome.
  """
  @spec unproven_effect?(t(), binary()) :: boolean()
  def unproven_effect?(%__MODULE__{} = state, run_id) do
    state
    |> elements(run_id)
    |> Enum.any?(&(&1.kind == :tool_result and &1.outcome == :outcome_unknown))
  end

  @doc """
  ## Concept

  The follow-up waiting to become the next run, if one is queued.

  ## Technical depth

  At most one exists per session. It is promoted only when the active run
  reaches a terminal outcome, in that same transaction.
  """
  @spec pending_follow_up(t()) :: map() | nil
  def pending_follow_up(%__MODULE__{follow_up: follow_up}), do: follow_up

  @doc false
  @spec propose_run_terminal(t(), binary(), binary(), map()) ::
          {:ok, proposal()} | {:error, term()}
  def propose_run_terminal(%__MODULE__{} = state, run_id, outcome, detail)
      when is_binary(run_id) and outcome in ["completed", "bound_reached", "outcome_unknown"] do
    record = %{
      "run_id" => run_id,
      "outcome" => outcome,
      "bound" => Map.get(detail, :bound),
      "observed" => Map.get(detail, :observed),
      "declared_limit" => Map.get(detail, :declared_limit),
      "accounting_source" => Map.get(detail, :accounting_source),
      "reconciliation_ref" => Map.get(detail, :reconciliation_ref),
      kind: "run_terminal_committed"
    }

    internal_proposal(state, stable_id("run-terminal", run_id, outcome), record)
  end

  @doc false
  @spec propose_model_request(t(), binary(), Loopex.Model.request(), keyword()) ::
          {:ok, proposal()} | {:error, term()}
  def propose_model_request(%__MODULE__{} = state, run_id, request, options \\ [])
      when is_binary(run_id) and is_map(request) and is_list(options) do
    applied_steer = Keyword.get(options, :applied_steer)
    context_receipt = Keyword.get(options, :context_receipt)

    work = Map.get(state.pending_work, run_id, %{turn_number: 1})
    turn_number = next_turn_number(work)

    record = %{
      "run_id" => run_id,
      "turn_id" => stable_id("turn", run_id, turn_number),
      "request" => encode_plain(request),
      "applied_steer" => applied_steer,
      "context_receipt" => context_receipt,
      kind: "model_request_committed"
    }

    internal_proposal(
      state,
      stable_id("model-request", run_id, request.staged_request_digest),
      record
    )
  end

  @doc false
  @spec propose_model_result(t(), binary(), map(), map()) :: {:ok, proposal()} | {:error, term()}
  def propose_model_result(%__MODULE__{} = state, run_id, reply, generations \\ %{})
      when is_binary(run_id) and is_map(reply) and is_map(generations) do
    record = %{
      "run_id" => run_id,
      "reply" => encode_plain(reply),
      "generations" => encode_plain(generations),
      kind: "model_result_committed"
    }

    internal_proposal(
      state,
      stable_id("model-result", run_id, reply.staged_request_digest),
      record
    )
  end

  @doc false
  @spec propose_effect_intent(
          t(),
          binary(),
          Loopex.Executor.job_request(),
          Loopex.Executor.grant()
        ) :: {:ok, proposal()} | {:error, term()}
  def propose_effect_intent(%__MODULE__{} = state, run_id, job, grant)
      when is_binary(run_id) and is_map(job) and is_map(grant) do
    record = %{
      "run_id" => run_id,
      "job" => encode_plain(job),
      "grant" => encode_plain(grant),
      kind: "effect_intent_committed"
    }

    internal_proposal(state, stable_id("effect-intent", run_id, job.job_id), record)
  end

  @doc false
  @spec propose_executor_fact(t(), binary(), map()) :: {:ok, proposal()} | {:error, term()}
  def propose_executor_fact(%__MODULE__{} = state, run_id, receipt)
      when is_binary(run_id) and is_map(receipt) do
    record = %{
      "run_id" => run_id,
      "receipt" => encode_plain(receipt),
      kind: "executor_receipt_committed"
    }

    internal_proposal(state, stable_id("executor-fact", run_id, receipt.job_id), record)
  end

  @doc """
  ## Concept

  Commits a terminal fact for a tool call that never produced a receipt.

  ## Technical depth

  A call the run could not dispatch, or one whose executor answered with an
  error, still owes the conversation an answer. It becomes a terminal
  `failed` — or `denied`, once a host policy can refuse one — exactly as a
  completed call becomes `completed`, and the run then continues or terminates
  truthfully from there.

  This is what stops a tool problem from killing the session owner. A coordinator
  that exits on a failed tool loses the run's place in its own conversation and
  leaves an operator with nothing to read; recording the failure keeps the
  journal complete and the loop honest about what happened.


  """
  @spec propose_tool_result(t(), binary(), binary(), atom(), binary() | nil) ::
          {:ok, proposal()} | {:error, term()}
  def propose_tool_result(%__MODULE__{} = state, run_id, tool_call_id, outcome, reason)
      when is_binary(run_id) and is_binary(tool_call_id) and is_atom(outcome) do
    record = %{
      "run_id" => run_id,
      "tool_call_id" => tool_call_id,
      "outcome" => Atom.to_string(outcome),
      "reason" => reason,
      kind: "tool_result_committed"
    }

    internal_proposal(state, stable_id("tool-result", run_id, tool_call_id), record)
  end

  @doc """
  ## Concept

  Charges a turn that produced no complete reply.

  ## Technical depth

  Its request bytes plus that turn's committed output allowance, in full, marked
  estimated. That deliberately over-charges: charging zero would make aborting
  every turn the cheapest way to stay inside a budget, and a bound that can be
  evaded by giving up is not a bound.
  """
  @spec charge_incomplete_turn(t(), binary()) :: t()
  def charge_incomplete_turn(%__MODULE__{} = state, run_id) do
    case Map.get(state.pending_work, run_id) do
      %{request: request} ->
        {charge, source} =
          Bounds.charge(nil, request.canonical_request_bytes, Loopex.Model.max_tokens(request))

        charge_run(state, run_id, charge, source)

      _absent ->
        state
    end
  end

  @doc false
  @spec propose_outcome_unknown(t(), binary(), binary()) :: {:ok, proposal()} | {:error, term()}
  def propose_outcome_unknown(%__MODULE__{} = state, run_id, reconciliation_ref)
      when is_binary(run_id) and is_binary(reconciliation_ref) do
    record = %{
      "run_id" => run_id,
      "reconciliation_ref" => reconciliation_ref,
      kind: "outcome_unknown_committed"
    }

    internal_proposal(state, stable_id("outcome-unknown", run_id, reconciliation_ref), record)
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
      "max_turns" => command.resolved_bounds.max_turns,
      "token_budget" => command.resolved_bounds.token_budget,
      "deadline_ms" => command.resolved_bounds.deadline_ms,
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

  # Concept: a steer joins a run that is actually running.
  #
  # Technical depth: the queue is one deep. A second steer is refused with an
  # explicit reason rather than replacing the first or being coalesced into it,
  # because an operator whose earlier words were silently dropped has no way to
  # know it happened.
  defp propose_new(%__MODULE__{active_run_id: active} = state, %{type: :steer} = command, digest)
       when is_binary(active) do
    cond do
      command.run_id != active ->
        refusal(state, command, digest, "steer", "rejected_run_mismatch", :run_mismatch)

      queued_steer(state, active) != nil ->
        refusal(state, command, digest, "steer", "rejected_steer_pending", :steer_pending)

      true ->
        record = %{
          "command_id" => command.command_id,
          "command_digest" => digest,
          "command_type" => "steer",
          "admission" => "accepted",
          "run_id" => active,
          "content" => command.content,
          kind: "command_admitted"
        }

        build_proposal(state, command.command_id, record, [], {:accepted, command.command_id})
    end
  end

  defp propose_new(%__MODULE__{active_run_id: nil} = state, %{type: :steer} = command, digest),
    do: refusal(state, command, digest, "steer", "rejected_no_active_run", :no_active_run)

  # Concept: a follow-up waits for the run in front of it.
  #
  # Technical depth: it is admitted only while a run is active and starts a new
  # run once that run reaches a terminal outcome. Submitted while the session is
  # settled it is refused, because there is nothing to follow and a caller that
  # meant to start work should say so with a prompt.
  defp propose_new(
         %__MODULE__{active_run_id: active} = state,
         %{type: :follow_up} = command,
         digest
       )
       when is_binary(active) do
    if state.follow_up do
      refusal(
        state,
        command,
        digest,
        "follow_up",
        "rejected_follow_up_pending",
        :follow_up_pending
      )
    else
      record = %{
        "command_id" => command.command_id,
        "command_digest" => digest,
        "command_type" => "follow_up",
        "admission" => "accepted",
        "run_id" => active,
        "content" => command.content,
        kind: "command_admitted"
      }

      build_proposal(state, command.command_id, record, [], {:accepted, command.command_id})
    end
  end

  defp propose_new(
         %__MODULE__{active_run_id: nil} = state,
         %{type: :follow_up} = command,
         digest
       ),
       do: refusal(state, command, digest, "follow_up", "rejected_no_active_run", :no_active_run)

  defp propose_new(%__MODULE__{active_run_id: run_id} = state, %{type: :abort} = command, digest)
       when is_binary(run_id) do
    reply = {:accepted, command.command_id}
    outcome = abort_outcome(command)

    record = %{
      "command_id" => command.command_id,
      "command_digest" => digest,
      "command_type" => "abort",
      "admission" => "accepted",
      "run_id" => run_id,
      "outcome" => outcome,
      "reconciliation_ref" => abort_reference(state, run_id, outcome),
      kind: "command_admitted"
    }

    {_patch, queue_events} = cancel_queues(state, run_id)

    event =
      abort_event(
        state.session_id,
        command.command_id,
        run_id,
        outcome,
        abort_reference(state, run_id, outcome)
      )

    build_proposal(state, command.command_id, record, [event] ++ queue_events, reply)
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

  defp refusal(state, command, digest, type, admission, reason) do
    record = %{
      "command_id" => command.command_id,
      "command_digest" => digest,
      "command_type" => type,
      "admission" => admission,
      kind: "command_admitted"
    }

    build_proposal(state, command.command_id, record, [], {:error, reason})
  end

  defp queued_steer(state, run_id) do
    case Map.get(state.steer, run_id) do
      %{state: "queued"} = steer -> steer
      _other -> nil
    end
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

  defp replay_record(
         state,
         %{
           journal_version: version,
           owner_epoch: owner_epoch,
           owner_incarnation_id: incarnation,
           payload: %{kind: kind} = record
         }
       )
       when kind in [
              "model_request_committed",
              "model_result_committed",
              "effect_intent_committed",
              "executor_receipt_committed",
              "outcome_unknown_committed",
              "run_terminal_committed",
              "tool_result_committed"
            ] do
    if version == state.journal_version + 1 and owner_epoch == state.owner_epoch and
         incarnation == state.owner_incarnation_id and is_binary(incarnation) do
      case apply_internal_record(state, record) do
        {:ok, next, events} ->
          {:ok,
           %{
             next
             | journal_version: version,
               expected_events: state.expected_events ++ events
           }}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, :invalid_internal_owner_stamp}
    end
  end

  defp replay_record(_state, _record), do: {:error, :invalid_private_history}

  defp apply_command_record(state, record) do
    with {:ok, command_id} <- record_binary(record, "command_id"),
         {:ok, digest} <- record_binary(record, "command_digest"),
         {:ok, command_type} <- record_binary(record, "command_type"),
         {:ok, admission} <- record_binary(record, "admission"),
         false <- Map.has_key?(state.commands, command_id),
         {:ok, reply, active_run_id, pending_work, expected_events, patch} <-
           command_effect(state, record, command_type, admission, command_id) do
      command_binding = %{digest: digest, reply: reply}

      {:ok,
       Map.merge(
         %{
           state
           | active_run_id: active_run_id,
             pending_work: pending_work,
             expected_events: expected_events,
             commands: Map.put(state.commands, command_id, command_binding)
         },
         patch
       )}
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
         {:ok, content} <- record_binary(record, "content"),
         {:ok, declared} <- record_bounds(record) do
      work = %{
        type: "model",
        stage: "model_pending",
        run_id: run_id,
        command_id: command_id,
        content: content,
        turn_number: 1,
        pending_calls: []
      }

      # Concept: the prompt becomes the first element of the conversation.
      #
      # Technical depth: it is committed here rather than staged later, because
      # a projection reads only committed elements. The bounds are committed in
      # the same record, so a recovering owner re-presents the deadline that was
      # decided at admission instead of computing a new one from its own clock.
      element = %{
        kind: :user_message,
        run_id: run_id,
        command_id: command_id,
        content: content
      }

      expected_events =
        state.expected_events ++ prompt_events(state.session_id, command_id, run_id, content)

      patch = %{
        conversation: Map.put(state.conversation, run_id, [element]),
        bounds: Map.put(state.bounds, run_id, declared)
      }

      {:ok, {:accepted, command_id}, run_id, Map.put(state.pending_work, run_id, work),
       expected_events, patch}
    end
  end

  defp command_effect(
         %{active_run_id: active} = state,
         record,
         "steer",
         "accepted",
         command_id
       )
       when is_binary(active) do
    with {:ok, run_id} <- record_binary(record, "run_id"),
         true <- run_id == active,
         {:ok, content} <- record_binary(record, "content") do
      steer = %{command_id: command_id, content: content, state: "queued"}

      {:ok, {:accepted, command_id}, active, state.pending_work, state.expected_events,
       %{steer: Map.put(state.steer, active, steer)}}
    else
      _other -> {:error, :invalid_steer_record}
    end
  end

  defp command_effect(
         %{active_run_id: active} = state,
         record,
         "follow_up",
         "accepted",
         command_id
       )
       when is_binary(active) do
    with {:ok, content} <- record_binary(record, "content") do
      {:ok, {:accepted, command_id}, active, state.pending_work, state.expected_events,
       %{follow_up: %{command_id: command_id, content: content}}}
    end
  end

  defp command_effect(state, _record, type, "rejected_" <> reason, _command_id)
       when type in ["steer", "follow_up"] do
    {:ok, {:error, String.to_existing_atom(reason)}, state.active_run_id, state.pending_work,
     state.expected_events, %{}}
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
          state.expected_events, %{}}

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
        # Concept: an abort cancels the queues as well as the run.
        #
        # Technical depth: a durably admitted abort resolves any queued steer and
        # any queued follow-up as cancelled, each recorded truthfully against its
        # own command_id. Leaving either queued would let work an operator
        # cancelled start itself a moment later.
        {patch, queue_events} = cancel_queues(state, active_run_id)

        outcome = record_outcome(record)

        expected_events =
          state.expected_events ++
            [
              abort_event(
                state.session_id,
                command_id,
                active_run_id,
                outcome,
                Map.get(record, "reconciliation_ref")
              )
            ] ++ queue_events

        {:ok, {:accepted, command_id}, nil, Map.delete(state.pending_work, active_run_id),
         expected_events, patch}

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
       do: {:ok, {:error, :no_active_run}, nil, state.pending_work, state.expected_events, %{}}

  defp command_effect(_state, _record, _command_type, _admission, _command_id),
    do: {:error, :invalid_command_transition}

  defp internal_proposal(state, tx_id, record) do
    with {:ok, next, events} <- apply_internal_record(state, record) do
      next = %{next | expected_events: state.expected_events ++ events}
      {:ok, proposal(tx_id, record, events, next, {:accepted, tx_id})}
    end
  end

  defp apply_internal_record(state, %{
         "run_id" => run_id,
         "turn_id" => turn_id,
         "request" => request,
         "applied_steer" => applied_steer,
         "context_receipt" => _context_receipt,
         kind: "model_request_committed"
       }) do
    with {:ok, request} <- decode_request(request),
         %{stage: stage} = work when stage in ["model_pending", "turn_settled"] <-
           Map.get(state.pending_work, run_id),
         :ok <- Loopex.Model.validate_request(request),
         turn_number = next_turn_number(work),
         true <- turn_id == stable_id("turn", run_id, turn_number) do
      # Concept: staging a request is what advances the turn.
      #
      # Technical depth: a settled turn advances only here, inside the same
      # transaction that commits the bytes about to be dispatched. There is no
      # separate "turn advanced" record to fall out of step with the request it
      # was supposed to accompany.
      next_work =
        Map.merge(work, %{
          stage: "model_dispatched",
          turn_id: turn_id,
          turn_number: turn_number,
          request: request,
          pending_calls: []
        })

      deadlines = Map.put_new(state.deadlines, run_id, request.deadline)

      # Concept: a steer becomes applied in the same transaction that dispatches
      # the request carrying it, and nowhere else.
      #
      # Technical depth: its exact bytes enter the conversation as a user-role
      # element here, so the record of what was said and the record of what was
      # sent cannot disagree. A steer is never recorded applied unless a
      # committed request actually carried it.
      {state, events} =
        case applied_steer && Map.get(state.steer, run_id) do
          %{command_id: ^applied_steer, content: content} = steer ->
            element = %{
              kind: :user_message,
              run_id: run_id,
              command_id: applied_steer,
              content: content
            }

            {state
             |> append_element(run_id, element)
             |> Map.update!(:steer, &Map.put(&1, run_id, %{steer | state: "applied"})),
             [steer_event(state.session_id, applied_steer, run_id, "applied", nil)]}

          _absent ->
            {state, []}
        end

      {:ok, put_pending(%{state | deadlines: deadlines}, run_id, next_work), events}
    else
      _other -> {:error, :invalid_model_request_transition}
    end
  end

  defp apply_internal_record(state, %{
         "run_id" => run_id,
         "reply" => reply,
         "generations" => generations,
         kind: "model_result_committed"
       }) do
    with {:ok, reply} <- decode_reply(reply),
         %{stage: "model_dispatched", request: request} = work <-
           Map.get(state.pending_work, run_id),
         true <- reply.canonical_request_bytes == request.canonical_request_bytes,
         true <- reply.staged_request_digest == request.staged_request_digest,
         true <- is_binary(reply.text),
         true <- is_list(reply.tool_calls) do
      apply_model_reply(state, work, reply, generations)
    else
      _other -> {:error, :invalid_model_result_transition}
    end
  end

  defp apply_internal_record(state, %{
         "run_id" => run_id,
         "job" => job,
         "grant" => grant,
         kind: "effect_intent_committed"
       }) do
    with {:ok, job} <- decode_job(job),
         {:ok, grant} <- decode_grant(grant),
         %{stage: "effect_pending", pending_calls: [call | _rest], turn_id: turn_id} = work <-
           Map.get(state.pending_work, run_id),
         :ok <- Loopex.Executor.validate_job(job),
         true <- job.run_id == run_id and job.turn_id == turn_id,
         true <- job.tool_call_id == call.tool_call_id,
         true <- is_map(grant) do
      # Concept: calls run in the order the model asked for them.
      #
      # Technical depth: the dispatched call is the head of what remains, never
      # a call chosen by the coordinator, so a job that names any other call of
      # the same turn is refused here rather than quietly reordering the turn.
      next_work =
        Map.merge(work, %{stage: "effect_dispatched", job: job, grant: grant, tool_call: call})

      {:ok, put_pending(state, run_id, next_work), [tool_started_event(state.session_id, job)]}
    else
      _other -> {:error, :invalid_effect_intent_transition}
    end
  end

  defp apply_internal_record(state, %{
         "run_id" => run_id,
         "receipt" => receipt,
         kind: "executor_receipt_committed"
       }) do
    with {:ok, receipt} <- decode_receipt(receipt),
         %{stage: "effect_dispatched", job: job, tool_call: call} = work <-
           Map.get(state.pending_work, run_id),
         :ok <- receipt_matches_job(receipt, job),
         outcome = conversation_outcome(receipt.outcome),
         true <- outcome in Conversation.outcomes(),
         true <- Conversation.admits_result?(elements(state, run_id), run_id, call.tool_call_id) do
      result = %{
        kind: :tool_result,
        run_id: run_id,
        turn_number: work.turn_number,
        tool_call_id: call.tool_call_id,
        outcome: outcome,
        content: Conversation.result_content(outcome, receipt.output),
        artifacts: Map.get(receipt, :artifacts, [])
      }

      # Concept: the turn is over only when every call the model made has an
      # answer.
      #
      # Technical depth: remaining calls stay in the assistant's own order, so a
      # tool that finished early cannot jump ahead of one the model asked for
      # first. The next request may not be staged until this list empties.
      remaining = Enum.reject(work.pending_calls, &(&1.tool_call_id == call.tool_call_id))
      stage = if remaining == [], do: "turn_settled", else: "effect_pending"

      next_work =
        work
        |> Map.merge(%{stage: stage, pending_calls: remaining})
        |> Map.drop([:job, :grant, :tool_call])

      next =
        state
        |> append_element(run_id, result)
        |> put_pending(run_id, next_work)

      {:ok, next,
       [
         tool_finished_event(
           state.session_id,
           job,
           to_string(receipt.outcome),
           receipt.artifacts
         )
       ]}
    else
      _other -> {:error, :invalid_executor_receipt_transition}
    end
  end

  defp apply_internal_record(state, %{
         "run_id" => run_id,
         "tool_call_id" => tool_call_id,
         "outcome" => outcome,
         "reason" => reason,
         kind: "tool_result_committed"
       }) do
    with %{stage: "effect_" <> _phase, pending_calls: [call | _rest]} = work <-
           Map.get(state.pending_work, run_id),
         true <- call.tool_call_id == tool_call_id,
         {:ok, terminal} <- decode_receipt_outcome(outcome),
         terminal = conversation_outcome(terminal),
         true <- terminal in Conversation.outcomes(),
         true <- Conversation.admits_result?(elements(state, run_id), run_id, tool_call_id) do
      result = %{
        kind: :tool_result,
        run_id: run_id,
        turn_number: work.turn_number,
        tool_call_id: tool_call_id,
        outcome: terminal,
        content: Conversation.result_content(terminal, reason),
        artifacts: []
      }

      remaining = Enum.reject(work.pending_calls, &(&1.tool_call_id == tool_call_id))
      stage = if remaining == [], do: "turn_settled", else: "effect_pending"

      next_work =
        work
        |> Map.merge(%{stage: stage, pending_calls: remaining})
        |> Map.drop([:job, :grant, :tool_call])

      next =
        state
        |> append_element(run_id, result)
        |> put_pending(run_id, next_work)

      # Concept: a call that started must be seen to finish, and it must finish
      # under the name it started under.
      #
      # Technical depth: the operator saw `tool.started` for a dispatched call, so
      # it is owed a `tool.finished` even when no receipt exists. Without one a
      # failed call reads on the public plane as a tool that never ended, and
      # without the identity a denied call reads as an opaque identifier beside a
      # refusal — which is exactly the case an operator most needs to understand.
      # The generation is taken from the call the model actually made, so a
      # refused call names the tool it asked for rather than nothing.
      # A refused or failed call spilled nothing, and says so with an empty list
      # rather than an absent field: a consumer reading the public plane must not
      # have to distinguish "no artifacts" from "this producer omitted the key".
      event =
        %{
          "run_id" => run_id,
          "turn_id" => Map.get(work, :turn_id),
          "tool_call_id" => tool_call_id,
          "tool_id" => called_tool_id(call),
          "outcome" => outcome,
          "artifacts" => [],
          event_id: stable_id("event-tool-finished", state.session_id, tool_call_id),
          kind: "tool.finished"
        }

      {:ok, next, [event]}
    else
      _other -> {:error, :invalid_tool_result_transition}
    end
  end

  defp apply_internal_record(state, %{
         "run_id" => run_id,
         "outcome" => outcome,
         "bound" => bound,
         "observed" => observed,
         "declared_limit" => declared_limit,
         "accounting_source" => accounting_source,
         "reconciliation_ref" => reconciliation_ref,
         kind: "run_terminal_committed"
       }) do
    with %{stage: "turn_settled"} <- Map.get(state.pending_work, run_id),
         true <- outcome in ["completed", "bound_reached", "outcome_unknown"] do
      # Concept: bound_reached carries the bound and the observed value and
      # nothing else.
      #
      # Technical depth: the declared limit that value was measured against and
      # the accounting source that produced it are siblings of the outcome in
      # this record, recorded beside it rather than inside it, so the run
      # terminal algebra keeps exactly the shape the vision fixes.
      event =
        run_finished_event(state.session_id, run_id, outcome, reconciliation_ref)
        |> Map.merge(
          case outcome do
            "bound_reached" ->
              %{
                "bound" => bound,
                "observed" => observed,
                "declared_limit" => declared_limit,
                "accounting_source" => accounting_source
              }

            _completed ->
              %{}
          end
        )

      # Concept: ending a run resolves everything that was waiting behind it.
      #
      # Technical depth: a queued steer that never reached a request resolves
      # unapplied, carrying the reason the run ended, and is never auto-promoted
      # into a follow-up — an operator resubmits it under a new command if they
      # still mean it. A queued follow-up becomes the next run in this same
      # transaction, so there is no window in which the session looks settled
      # while work is still owed.
      {state, steer_events} = resolve_steer(state, run_id, unapplied_reason(outcome, bound))
      {state, promotion_events} = promote_follow_up(state, run_id)

      {:ok, state, [event] ++ steer_events ++ promotion_events}
    else
      _other -> {:error, :invalid_run_terminal_transition}
    end
  end

  defp apply_internal_record(state, %{
         "run_id" => run_id,
         "reconciliation_ref" => reconciliation_ref,
         kind: "outcome_unknown_committed"
       }) do
    with %{stage: "effect_dispatched", job: job} <- Map.get(state.pending_work, run_id),
         true <- is_binary(reconciliation_ref) and byte_size(reconciliation_ref) > 0 do
      events = [
        tool_finished_event(state.session_id, job, "outcome_unknown"),
        run_finished_event(state.session_id, run_id, "outcome_unknown", reconciliation_ref)
      ]

      {:ok, %{state | active_run_id: nil, pending_work: Map.delete(state.pending_work, run_id)},
       events}
    else
      _other -> {:error, :invalid_outcome_unknown_transition}
    end
  end

  defp apply_internal_record(_state, _record), do: {:error, :invalid_internal_transition}

  defp unapplied_reason("bound_reached", bound) when is_binary(bound), do: bound
  defp unapplied_reason(_outcome, _bound), do: "run_terminal"

  defp resolve_steer(state, run_id, reason) do
    case queued_steer(state, run_id) do
      nil ->
        {state, []}

      steer ->
        {Map.update!(state, :steer, &Map.put(&1, run_id, %{steer | state: "unapplied"})),
         [steer_event(state.session_id, steer.command_id, run_id, "unapplied", reason)]}
    end
  end

  defp promote_follow_up(%{follow_up: nil} = state, run_id) do
    {%{state | active_run_id: nil, pending_work: Map.delete(state.pending_work, run_id)}, []}
  end

  defp promote_follow_up(%{follow_up: follow_up} = state, run_id) do
    promoted = stable_id("run", state.session_id, follow_up.command_id)
    declared = Map.get(state.bounds, run_id)

    work = %{
      type: "model",
      stage: "model_pending",
      run_id: promoted,
      command_id: follow_up.command_id,
      content: follow_up.content,
      turn_number: 1,
      pending_calls: []
    }

    element = %{
      kind: :user_message,
      run_id: promoted,
      command_id: follow_up.command_id,
      content: follow_up.content
    }

    next =
      %{
        state
        | active_run_id: promoted,
          follow_up: nil,
          pending_work: state.pending_work |> Map.delete(run_id) |> Map.put(promoted, work),
          bounds: Map.put(state.bounds, promoted, declared),
          conversation: Map.put(state.conversation, promoted, [element])
      }

    {next, prompt_events(state.session_id, follow_up.command_id, promoted, follow_up.content)}
  end

  defp cancel_queues(state, run_id) do
    {steer_patch, steer_events} =
      case queued_steer(state, run_id) do
        nil ->
          {%{}, []}

        steer ->
          {%{steer: Map.put(state.steer, run_id, %{steer | state: "cancelled"})},
           [steer_event(state.session_id, steer.command_id, run_id, "cancelled", "aborted")]}
      end

    {follow_patch, follow_events} =
      case state.follow_up do
        nil ->
          {%{}, []}

        follow_up ->
          {%{follow_up: nil},
           [
             %{
               "command_id" => follow_up.command_id,
               "run_id" => run_id,
               "disposition" => "cancelled",
               "reason" => "aborted",
               event_id: stable_id("event-follow-up", state.session_id, follow_up.command_id),
               kind: "follow_up.resolved"
             }
           ]}
      end

    {Map.merge(steer_patch, follow_patch), steer_events ++ follow_events}
  end

  defp steer_event(session_id, command_id, run_id, disposition, reason) do
    %{
      "command_id" => command_id,
      "run_id" => run_id,
      "disposition" => disposition,
      "reason" => reason,
      event_id: stable_id("event-steer", session_id, command_id),
      kind: "steer.resolved"
    }
  end

  # Concept: one committed reply becomes one assistant message and the turn's
  # list of calls to run.
  #
  # Technical depth: the assistant message is built from the adapter's return
  # value and never assembled from deltas — core has nothing to assemble from,
  # which makes that structural rather than a rule to remember. A malformed,
  # truncated, or duplicated call never becomes a call entry: the whole batch is
  # refused, because a turn that silently dropped one of the model's calls would
  # project a conversation the model never had.
  #
  # No bound is evaluated here. Whether the run continues depends on wall clock,
  # and a decision that reads the clock cannot be replayed; the coordinator
  # therefore evaluates bounds against the settled turn and commits the outcome
  # as its own durable fact.
  defp apply_model_reply(state, work, reply, generations) do
    case normalize_calls(reply.tool_calls, generations) do
      {:ok, calls} ->
        run_id = work.run_id

        assistant = %{
          kind: :assistant_message,
          run_id: run_id,
          turn_number: work.turn_number,
          content: reply.text,
          tool_calls: calls,
          stop_reason: if(calls == [], do: "end_turn", else: "tool_use"),
          usage: reply.usage
        }

        {charge, source} =
          Bounds.charge(
            reply,
            work.request.canonical_request_bytes,
            Loopex.Model.max_tokens(work.request)
          )

        next_work =
          if calls == [] do
            Map.merge(work, %{stage: "turn_settled", pending_calls: []})
          else
            Map.merge(work, %{stage: "effect_pending", pending_calls: calls})
          end

        next =
          state
          |> append_element(run_id, assistant)
          |> charge_run(run_id, charge, source)
          |> put_pending(run_id, next_work)

        {:ok, next, [assistant_event(state.session_id, run_id, work.turn_id, reply.text)]}

      :error ->
        {:error, :invalid_model_tool_call}
    end
  end

  # Concept: turn one is turn one; every settled turn moves to the next.
  #
  # Technical depth: derived from the committed stage rather than from a counter
  # the coordinator carries, so a successor that recovers mid-run resumes the
  # same numbering the journal already describes.
  defp next_turn_number(%{stage: "turn_settled", turn_number: turn_number}), do: turn_number + 1
  defp next_turn_number(%{turn_number: turn_number}), do: turn_number

  # Concept: the bounds a run was admitted with, read back from its own record.
  #
  # Technical depth: all three are required and none has a default. A record
  # missing one refuses the replay rather than supplying a number no authority
  # committed, which is the same rule that refuses a session configured without
  # a sampling bound at start.
  defp record_bounds(record) do
    Bounds.declare(%{
      max_turns: Map.get(record, "max_turns"),
      token_budget: Map.get(record, "token_budget"),
      deadline_ms: Map.get(record, "deadline_ms")
    })
  end

  # Concept: the tool a call named, where the runtime knows it.
  #
  # Technical depth: a call whose name matched no active generation has no tool
  # identity to report, and reporting the model-supplied name in its place would
  # publish an unresolved string as though the runtime had accepted it.
  defp called_tool_id(%{generation: {tool_id, _version, _digest}}), do: tool_id
  defp called_tool_id(_call), do: nil

  defp normalize_calls(calls, generations) when is_list(calls) do
    normalized =
      Enum.reduce_while(calls, {:ok, []}, fn call, {:ok, acc} ->
        case call do
          %{id: id, name: name, arguments: arguments}
          when is_binary(id) and byte_size(id) > 0 and is_binary(name) and
                 byte_size(name) > 0 and is_map(arguments) ->
            entry = %{
              tool_call_id: id,
              name: name,
              arguments: arguments,
              generation: decode_generation(Map.get(generations, name))
            }

            {:cont, {:ok, [entry | acc]}}

          _other ->
            {:halt, :error}
        end
      end)

    with {:ok, reversed} <- normalized do
      calls = Enum.reverse(reversed)
      ids = Enum.map(calls, & &1.tool_call_id)

      if length(Enum.uniq(ids)) == length(ids), do: {:ok, calls}, else: :error
    end
  end

  defp normalize_calls(_calls, _generations), do: :error

  # Concept: a generation survives the journal as a list and comes back a tuple.
  #
  # Technical depth: plain encoding has no tuple, so the triple is stored as
  # three ordered members and rebuilt here. A name that resolved to nothing
  # stays nil and its call is never dispatched.
  defp decode_generation([tool_id, tool_version, digest]),
    do: {tool_id, tool_version, digest}

  defp decode_generation({_id, _version, _digest} = generation), do: generation
  defp decode_generation(_other), do: nil

  defp append_element(state, run_id, element) do
    %{
      state
      | conversation: Map.update(state.conversation, run_id, [element], &(&1 ++ [element]))
    }
  end

  defp charge_run(state, run_id, charge, source) do
    %{
      state
      | charged:
          Map.update(
            state.charged,
            run_id,
            %{tokens: charge, source: source},
            fn held -> %{tokens: held.tokens + charge, source: source} end
          )
    }
  end

  defp receipt_matches_job(receipt, job) do
    fields = [
      :job_id,
      :operation_id,
      :attempt,
      :session_id,
      :run_id,
      :turn_id,
      :tool_call_id,
      :canonical_request_digest,
      :fencing_token
    ]

    valid =
      Enum.all?(fields, &(Map.get(receipt, &1) == Map.get(job, &1))) and
        receipt.session_epoch_at_dispatch == job.origin_session_epoch and
        receipt.executor_epoch == job.origin_executor_epoch and
        receipt.executor_identity == job.executor_identity

    if valid, do: :ok, else: {:error, :receipt_identity_mismatch}
  end

  defp put_pending(state, run_id, work),
    do: %{state | pending_work: Map.put(state.pending_work, run_id, work)}

  defp encode_plain(value) when value in [nil, true, false], do: value
  defp encode_plain(value) when is_atom(value), do: Atom.to_string(value)
  defp encode_plain(value) when is_binary(value) or is_integer(value), do: value
  defp encode_plain(value) when is_list(value), do: Enum.map(value, &encode_plain/1)

  defp encode_plain(value) when is_map(value) do
    Map.new(value, fn {key, nested} ->
      encoded_key = if is_atom(key), do: Atom.to_string(key), else: key
      {encoded_key, encode_plain(nested)}
    end)
  end

  defp decode_request(encoded) do
    fields = [
      :canonicalization_version,
      :model,
      :messages,
      :tools,
      :sampling,
      :deadline,
      :continuation,
      :canonical_request_bytes,
      :staged_request_digest
    ]

    decode_top(encoded, fields)
  end

  defp decode_reply(encoded) do
    fields = [
      :text,
      :identity,
      :usage,
      :tool_calls,
      :canonical_request_bytes,
      :staged_request_digest
    ]

    # Concept: streaming statistics are additions, not requirements.
    #
    # Technical depth: `delta_count` and `streamed` are attempt-private evidence
    # about how a reply was produced. An adapter that does not stream has nothing
    # to say about them, and refusing its reply would make the arity change a
    # behaviour change for exactly the adapters ADR 0011 says stay conformant.
    # They default to "emitted nothing", which is what their absence means.
    with {:ok, reply} <- decode_top(encoded, fields),
         {:ok, calls} <- decode_tool_calls(reply.tool_calls) do
      {:ok,
       reply
       |> Map.put(:tool_calls, calls)
       |> Map.put(:delta_count, Map.get(encoded, "delta_count", 0))
       |> Map.put(:streamed, Map.get(encoded, "streamed", false))}
    end
  end

  defp decode_tool_calls(calls) when is_list(calls) do
    Enum.reduce_while(calls, {:ok, []}, fn call, {:ok, decoded} ->
      case decode_top(call, [:id, :name, :arguments]) do
        {:ok, found} -> {:cont, {:ok, [found | decoded]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, decoded} -> {:ok, Enum.reverse(decoded)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_tool_calls(_calls), do: {:error, :invalid_plain_record}

  defp decode_job(encoded) do
    decode_top(
      encoded,
      Loopex.Executor.job_fields() ++ [:canonical_request_bytes, :canonical_request_digest]
    )
  end

  defp decode_grant(encoded) do
    fields = Loopex.Executor.required_grant_bindings() ++ [:issued_by, :policy_context]

    with {:ok, grant} <- decode_top(encoded, fields),
         "host_policy_allow" <- grant.issued_by do
      {:ok, %{grant | issued_by: :host_policy_allow}}
    else
      _other -> {:error, :invalid_plain_grant}
    end
  end

  defp decode_receipt(encoded) do
    fields = [
      :protocol_version,
      :job_id,
      :operation_id,
      :attempt,
      :session_id,
      :run_id,
      :turn_id,
      :tool_call_id,
      :session_epoch_at_dispatch,
      :executor_epoch,
      :executor_identity,
      :canonical_request_digest,
      :fencing_token,
      :tool_id,
      :tool_version,
      :outcome,
      :output,
      :progress_count,
      :observed_at_ms,
      :child_environment_names,
      :provider_credential_present,
      :artifacts
    ]

    with {:ok, receipt} <- decode_top(encoded, fields),
         {:ok, outcome} <- decode_receipt_outcome(receipt.outcome),
         {:ok, artifacts} <- decode_artifacts(receipt.artifacts) do
      {:ok, %{receipt | outcome: outcome, artifacts: artifacts}}
    else
      _other -> {:error, :invalid_plain_receipt}
    end
  end

  # Concept: a spilled artifact crosses this boundary as plain bounded data.
  #
  # Technical depth: the reference is journalled and published, so it is checked
  # against the port's own predicate on the way in rather than trusted because
  # an executor sent it. A malformed reference fails the receipt instead of
  # reaching an operator as a retrieval handle that resolves to nothing.
  defp decode_artifacts(artifacts) when is_list(artifacts) do
    decoded = Enum.map(artifacts, &decode_artifact_reference/1)

    if Enum.all?(decoded, &ArtifactStore.valid_reference?/1),
      do: {:ok, decoded},
      else: :error
  end

  defp decode_artifacts(_artifacts), do: :error

  defp decode_artifact_reference(reference) when is_map(reference) do
    Map.new(reference, fn
      {key, value} when is_binary(key) -> {String.to_existing_atom(key), value}
      {key, value} -> {key, value}
    end)
  rescue
    ArgumentError -> %{}
  end

  defp decode_artifact_reference(_reference), do: %{}

  defp decode_receipt_outcome("completed"), do: {:ok, :completed}
  defp decode_receipt_outcome("failed"), do: {:ok, :failed}
  defp decode_receipt_outcome("denied"), do: {:ok, :denied}
  defp decode_receipt_outcome("cancelled"), do: {:ok, :cancelled}
  defp decode_receipt_outcome("outcome_unknown"), do: {:ok, :outcome_unknown}

  defp decode_receipt_outcome("cancelled_workspace_lease_lost"),
    do: {:ok, :cancelled_workspace_lease_lost}

  defp decode_receipt_outcome(_outcome), do: {:error, :invalid_plain_receipt}

  # Concept: what the model is told about a terminal outcome.
  #
  # Technical depth: the executor's own vocabulary is narrower in some cases and
  # wider in others. `cancelled_workspace_lease_lost` is a precise executor fact
  # retained in the receipt exactly as M1 named it; the conversation only needs
  # to know the call was cancelled, so it is narrowed here rather than adding a
  # sixth member to the closed conversation set.
  defp conversation_outcome(:cancelled_workspace_lease_lost), do: :cancelled
  defp conversation_outcome(outcome), do: outcome

  defp decode_top(encoded, fields) when is_map(encoded) do
    Enum.reduce_while(fields, {:ok, %{}}, fn field, {:ok, decoded} ->
      case Map.fetch(encoded, Atom.to_string(field)) do
        {:ok, value} -> {:cont, {:ok, Map.put(decoded, field, value)}}
        :error -> {:halt, {:error, :invalid_plain_record}}
      end
    end)
  end

  defp decode_top(_encoded, _fields), do: {:error, :invalid_plain_record}

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

  defp assistant_event(session_id, run_id, turn_id, content) do
    %{
      "run_id" => run_id,
      "turn_id" => turn_id,
      "content" => content,
      event_id: stable_id("event-assistant", session_id, turn_id),
      kind: "assistant.message_appended"
    }
  end

  # Concept: an operator watching a run should be able to see which tool started.
  #
  # Technical depth: the identity was previously carried only by the private job,
  # so a terminal reading the public plane could name the call but not the tool —
  # it rendered as an empty name beside an opaque identifier, which tells an
  # operator nothing about what their agent is doing. The generation is public
  # information: it is already inside the staged request the model was shown.
  defp tool_started_event(session_id, job) do
    %{
      "run_id" => job.run_id,
      "turn_id" => job.turn_id,
      "tool_call_id" => job.tool_call_id,
      "operation_id" => job.operation_id,
      "tool_id" => job.tool_id,
      "tool_version" => job.tool_version,
      event_id: stable_id("event-tool-started", session_id, job.tool_call_id),
      kind: "tool.started"
    }
  end

  # Concept: an operator can retrieve what a tool produced but the model was not
  # shown.
  #
  # Technical depth: the spilled reference travels on the public plane because
  # that is where an operator reads, and it carries the digest, media type, size
  # and role beside the opaque locator so a reader knows what they are asking for
  # before they ask. A tool that spilled nothing carries an empty list rather
  # than an absent field, so a consumer never has to distinguish the two.
  defp tool_finished_event(session_id, job, outcome, artifacts \\ []) do
    %{
      "run_id" => job.run_id,
      "turn_id" => job.turn_id,
      "tool_call_id" => job.tool_call_id,
      "operation_id" => job.operation_id,
      "tool_id" => job.tool_id,
      "outcome" => outcome,
      "artifacts" => Enum.map(artifacts, &public_artifact/1),
      event_id: stable_id("event-tool-finished", session_id, job.tool_call_id),
      kind: "tool.finished"
    }
  end

  defp public_artifact(reference) do
    %{
      "digest" => reference.digest,
      "media_type" => reference.media_type,
      "size" => reference.size,
      "role" => reference.role,
      "locator" => reference.locator
    }
  end

  defp run_finished_event(session_id, run_id, outcome, reconciliation_ref) do
    %{
      "run_id" => run_id,
      "outcome" => outcome,
      "reconciliation_ref" => reconciliation_ref,
      event_id: stable_id("event-run-finished", session_id, run_id),
      kind: "run.finished"
    }
  end

  # Concept: an abort says what actually happened to the work, not merely that
  # it was asked to stop.
  #
  # Technical depth: `cancelled` claims every owned operation reached a validated
  # terminal fact and every owned process tree was confirmed cleaned. Where the
  # executor could not confirm that, the run finishes `outcome_unknown` carrying
  # its reconciliation reference instead, because an operator told "cancelled"
  # about a process that may still be running has been told something false.
  defp abort_event(session_id, command_id, run_id, outcome, reconciliation_ref) do
    %{
      "command_id" => command_id,
      "run_id" => run_id,
      "outcome" => outcome,
      "reconciliation_ref" => reconciliation_ref,
      event_id: stable_id("event-abort", session_id, command_id),
      kind: "run.finished"
    }
  end

  # Concept: what the abort achieved travels beside the command, not inside it.
  #
  # Technical depth: the digest covers what the caller asked for, so a
  # re-presented abort returns its retained result rather than conflicting with
  # itself because cleanup went differently the second time. The disposition is
  # supplied separately, exactly as a run's resolved bounds are.
  defp abort_outcome(%{resolved_bounds: %{cleanup: :unconfirmed}}), do: "outcome_unknown"
  defp abort_outcome(_command), do: "cancelled"

  defp abort_reference(_state, _run_id, "cancelled"), do: nil

  defp abort_reference(state, run_id, _outcome),
    do: stable_id("reconciliation", state.session_id, run_id)

  defp record_outcome(record), do: Map.get(record, "outcome", "cancelled")

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

        # Concept: a steer must name the run it is steering.
        #
        # Technical depth: the runtime never infers whether new input is
        # steering or follow-up, so a steer that names no run, or names a
        # different one, is refused rather than retargeted. Guessing here would
        # put an operator's words into a run they did not mean.
        :steer ->
          with {:ok, run_id} <- fetch_binary(command, :run_id),
               {:ok, content} <- fetch_binary(command, :content),
               true <- byte_size(content) <= @max_command_bytes do
            {:ok, %{type: :steer, command_id: command_id, run_id: run_id, content: content}}
          else
            _other -> {:error, :invalid_command}
          end

        :follow_up ->
          with {:ok, content} <- fetch_binary(command, :content),
               true <- byte_size(content) <= @max_command_bytes do
            {:ok, %{type: :follow_up, command_id: command_id, content: content}}
          else
            _other -> {:error, :invalid_command}
          end
      end
    end
  end

  defp fetch_type(command) do
    case fetch(command, :type) do
      {:ok, value} when value in [:prompt, "prompt"] -> {:ok, :prompt}
      {:ok, value} when value in [:abort, "abort"] -> {:ok, :abort}
      {:ok, value} when value in [:steer, "steer"] -> {:ok, :steer}
      {:ok, value} when value in [:follow_up, "follow_up"] -> {:ok, :follow_up}
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
