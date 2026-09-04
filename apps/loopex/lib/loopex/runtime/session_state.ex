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
  @context_receipt_keys Enum.sort(~w(
                          blocks context_record_byte_ceiling context_token_budget
                          descriptor_canonicalization_version ordered_descriptor_digest
                          project_resource provider_estimated_tokens provider_identity
                          provider_revision record_byte_cost selector_identity
                          selector_revision token_estimator totals transformer_identity
                          transformer_revision
                        ))
  @uint64_max 18_446_744_073_709_551_615
  @descriptor_canonicalization_version "loopex.canonical.v1"
  @descriptor_digest_domain "loopex.context.descriptors.v1"
  @context_refusal_keys Enum.sort([
                          :kind,
                          "run_id",
                          "turn_id",
                          "category",
                          "dimension",
                          "token_estimator",
                          "descriptor_canonicalization_version",
                          "project_disposition",
                          "system_message_count",
                          "session_message_count",
                          "steer_message_count",
                          "tool_definition_count",
                          "provider_estimated_tokens",
                          "context_token_budget",
                          "record_byte_cost",
                          "context_record_byte_ceiling",
                          "ordered_descriptor_digest",
                          "observed",
                          "limit"
                        ])
  @context_project_dispositions ~w(
    not_evaluated_required_failure no_manifest manifest_rejected over_limit
    no_decision binding_changed staged_empty context_token_budget
    context_record_bytes
  )

  alias Loopex.ArtifactStore
  alias Loopex.Bounds
  alias Loopex.Conversation
  alias Loopex.Runtime.ContextAdmission
  alias Loopex.Runtime.ProviderAttempt
  alias Loopex.Store
  alias LoopexProtocol.Canonical
  alias LoopexProtocol.ToolDefinition

  @receipt_required_fields [
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
  @receipt_optional_fields [
    :cleanup_grace_ms,
    :cleanup_confirmation,
    :process_probe,
    :receipt_retention_bound_ms,
    :effective_deadline_ms,
    :run_deadline_ms
  ]
  @receipt_cleanup_confirmations ["confirmed", "unconfirmed"]
  @max_cleanup_grace_ms 18_446_744_073_709_551_615
  @receipt_outcomes [
    :completed,
    :failed,
    :denied,
    :cancelled,
    :outcome_unknown,
    :cancelled_workspace_lease_lost
  ]
  @provider_credential_name "LOOPEX_PROVIDER_API_KEY"
  @max_receipt_text_bytes 1_024
  @unsafe_receipt_text ~r/[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]/u
  @environment_name ~r/\A[A-Za-z_][A-Za-z0-9_]*\z/
  @receipt_job_identity_fields [
    :protocol_version,
    :job_id,
    :operation_id,
    :attempt,
    :session_id,
    :run_id,
    :turn_id,
    :tool_call_id,
    :canonical_request_digest,
    :fencing_token,
    :tool_id,
    :tool_version
  ]

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
          context_budgets: map(),
          context_refusal: map() | nil,
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
            # The context-admission ceiling each run committed at its own prompt
            # admission. ADR 0017 keeps it out of `bounds` because it can never
            # produce `bound_reached`, and keeps it per run because promotion,
            # succession, and restart must all reuse the value the predecessor
            # committed rather than whatever the current process now defaults to.
            context_budgets: %{},
            # The transient marker ADR 0017 installs when the first row of a
            # context refusal has been applied and its terminal has not. It is
            # in-memory only: it changes no durable-derived run state, and a
            # recovery that reaches the durable head still holding it is
            # incomplete history rather than a settled session.
            context_refusal: nil,
            deadlines: %{},
            steer: %{},
            follow_up: nil,
            charged: %{},
            # The cleanup period this session declares, which ADR 0009 makes a
            # session configuration value with a default rather than something
            # read back from whatever the hand happened to report. The run's
            # terminal reports it, so an operator can tell a clean cooperative
            # stop from a forced kill that was confirmed and from a termination
            # that could not be confirmed at all. It defaults to the port's own
            # number so a coordinator that declared none still names a period
            # rather than an absence, and the same number is handed to the
            # executor that performs the cleanup.
            cleanup_grace_ms: Loopex.Executor.default_cleanup_grace_ms(),
            # The run an operator durably aborted whose ending has not been
            # committed yet. ADR 0009 orders the admission before the cleanup, so
            # this is the state that exists between them: real, recoverable, and
            # what lets a recovering owner tell "nobody asked to stop" from
            # "somebody asked and this owner never wrote down what happened".
            aborting: nil,
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
         # Concept: half a refusal is not a settled session.
         #
         # Technical depth: reaching the durable head with the transient marker
         # still installed means the terminal row that completes the pair is
         # missing, which is incomplete history rather than a run to resume.
         nil <- state.context_refusal,
         {:ok, event_sequence} <- replay_event_sequences(events),
         true <- expected_public_history?(events, state.expected_events),
         {:ok, projection} <- replay_projection(events, event_sequence),
         true <- projection.active_run_id == state.active_run_id do
      {:ok, %{state | event_sequence: event_sequence}}
    else
      false -> {:error, :private_public_projection_mismatch}
      %{} -> {:error, :incomplete_context_refusal_pair}
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
       active_run: nil,
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
        active_run: active_run,
        anchor_projection: anchor_projection
      }) do
    case {requested_anchor, anchor_projection} do
      {nil, _projection} ->
        {:ok, %{tail: tail, snapshot: public_snapshot(session_id, tail, active_run)}}

      {anchor, {:set, anchor_active_run}} when anchor <= tail ->
        {:ok, %{tail: tail, snapshot: public_snapshot(session_id, anchor, anchor_active_run)}}

      {_anchor, _projection} ->
        {:error, :cursor_expired}
    end
  end

  def finish_snapshot_scan(_scan), do: {:error, :invalid_public_history}

  # Concept: the snapshot says which run is active and how far along it is.
  #
  # Technical depth: ADR 0017's revision 2 carries the phase beside the identity,
  # so an operator attaching after prompt admission but before the first staged
  # request can tell an admitted, unstaged run from a started one. The two active
  # members are nil together or non-nil together; no phase is ever inferred from
  # the identity alone.
  defp public_snapshot(session_id, event_sequence, nil) do
    %{
      snapshot_revision: 2,
      session_id: session_id,
      event_sequence: event_sequence,
      active_run_id: nil,
      active_run_phase: nil
    }
  end

  defp public_snapshot(session_id, event_sequence, {run_id, phase}) do
    %{
      snapshot_revision: 2,
      session_id: session_id,
      event_sequence: event_sequence,
      active_run_id: run_id,
      active_run_phase: phase
    }
  end

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

  The context-admission ceiling one run committed at its own prompt admission.

  ## Technical depth

  Read back exactly as committed, never recomputed from current runtime
  configuration. ADR 0017 makes promotion, succession, and restart all reuse
  this value, so a default that changed between the admission and the recovery
  cannot re-decide how large a request the run was allowed to stage. An unknown
  run answers `nil`, which a settled session is entitled to report.
  """
  @spec context_token_budget(t(), binary() | nil) :: pos_integer() | nil
  def context_token_budget(%__MODULE__{} = state, run_id) when is_binary(run_id),
    do: Map.get(state.context_budgets, run_id)

  def context_token_budget(%__MODULE__{}, _run_id), do: nil

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

  The precedence is over continuing, too, and that is why the owner asks this
  before it dispatches anything at all rather than only where a turn settles or
  a bound was reached. An unknown effect ends the affected run: feeding its
  result back to the model would resume a loop past an outcome that is already
  terminal, and running the calls still queued behind it in the same assistant
  batch would carry on producing effects past one.
  """
  @spec unproven_effect?(t(), binary()) :: boolean()
  def unproven_effect?(%__MODULE__{} = state, run_id) do
    state
    |> elements(run_id)
    |> Enum.any?(&(&1.kind == :tool_result and &1.outcome == :outcome_unknown))
  end

  @doc """
  ## Concept

  Records the cleanup period this session was configured with.

  ## Technical depth

  ADR 0009 makes the grace a declared session configuration value, so it is
  applied to the reconstructed state once, by the owner that holds the
  configuration, rather than being replayed from history: it describes how this
  owner will stop work, not what already happened. Every run terminal this owner
  commits reports it.
  """
  @spec declare_cleanup_grace(t(), pos_integer()) :: t()
  def declare_cleanup_grace(%__MODULE__{} = state, grace)
      when is_integer(grace) and grace > 0,
      do: %{state | cleanup_grace_ms: grace}

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
  def propose_run_terminal(%__MODULE__{} = state, run_id, proposed, detail)
      when is_binary(run_id) and
             proposed in ["completed", "bound_reached", "outcome_unknown", "cancelled", "failed"] do
    record = run_terminal_record(state, run_id, proposed, detail)

    internal_proposal(
      state,
      stable_id("run-terminal", run_id, record["outcome"]),
      record
    )
  end

  @doc false
  @spec propose_model_request(t(), binary(), Loopex.Model.request(), keyword()) ::
          {:ok, proposal()}
          | {:refused, map()}
          | {:refused_not_required_only, map()}
          | {:error, term()}
  def propose_model_request(%__MODULE__{} = state, run_id, request, options \\ [])
      when is_binary(run_id) and is_map(request) and is_list(options) do
    applied_steer = Keyword.get(options, :applied_steer)
    context_receipt = Keyword.get(options, :context_receipt)

    work = Map.get(state.pending_work, run_id, %{turn_number: 1})
    turn_number = next_turn_number(work)
    turn_id = stable_id("turn", run_id, turn_number)

    record = %{
      "run_id" => run_id,
      "turn_id" => turn_id,
      "operation_id" => model_operation_id(run_id, turn_number),
      "staged_request_digest" => request.staged_request_digest,
      "request" => encode_plain(request),
      "applied_steer" => applied_steer,
      "context_receipt" => context_receipt,
      kind: "model_request_committed"
    }

    # Concept: a request that cannot be staged is refused here, before any
    # provider sees it, and one that can is committed with the attempt that may
    # send it.
    #
    # Technical depth: admission runs against the exact record about to be
    # proposed, so what is judged is what would have been written. A refusal
    # returns the compact projection its caller commits instead of this
    # transaction; it never becomes a partially staged request. ADR 0018 then
    # makes the attempt-open row the only dispatch authority, so the admitted
    # request row alone must never be enough to call a provider: committing them
    # separately would leave a window in which the bytes exist and the authority
    # does not, and a crash inside it would hand a successor a staged request
    # whose attempt nobody opened.
    with {:ok, fixed} <- admit_context_candidate(record),
         {:ok, opened} <-
           ProviderAttempt.opened_record(%{
             run_id: run_id,
             turn_id: turn_id,
             operation_id: model_operation_id(run_id, turn_number),
             attempt: 1,
             staged_request_digest: request.staged_request_digest
           }) do
      internal_proposal(
        state,
        stable_id("model-request", run_id, request.staged_request_digest),
        [fixed, opened]
      )
    else
      {:refused, refusal} ->
        context_refusal_result(record, refusal, work, turn_number)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp admit_context_candidate(%{"context_receipt" => receipt} = record) when is_map(receipt) do
    observations = %{
      system_class_tokens: get_in(receipt, ["totals", "by_provenance", "system", "token_cost"]),
      provider_estimated_tokens: Map.get(receipt, "provider_estimated_tokens"),
      context_token_budget: Map.get(receipt, "context_token_budget"),
      context_record_byte_ceiling: Store.max_item_bytes(),
      context_record_depth_limit: Store.max_item_depth(),
      context_record_cardinality_limit: Store.max_item_cardinality()
    }

    # Concept: only a structurally inadmissible candidate skips the fixed point,
    # and it skips it to be named, not to be waved through.
    #
    # Technical depth: a record that breaches Store depth or cardinality has no
    # convergent self-size, so it is handed to the admission boundary unresolved
    # and refused there by its exact structural dimension. Every other failure --
    # a non-convergent fixed point, or data the Store rejects outright -- is
    # returned as it stands. ADR 0017 makes non-convergence the exact
    # Store-unavailable reason `:context_record_preflight_unavailable` and
    # forbids manufacturing a dimension, terminal, or dispatch from it;
    # continuing with an unconverged record would stage a request whose receipt
    # states a byte cost of zero.
    with {:ok, candidate} <- record_byte_cost_candidate(record),
         :ok <- ContextAdmission.preflight_required_candidate(candidate, observations) do
      {:ok, candidate}
    end
  end

  defp admit_context_candidate(record), do: resolve_record_byte_cost(record)

  defp record_byte_cost_candidate(record) do
    case resolve_record_byte_cost(record) do
      {:ok, fixed} -> {:ok, fixed}
      {:error, {:item_structure_exceeded, _dimension, _observed, _limit}} -> {:ok, record}
      {:error, reason} -> {:error, reason}
    end
  end

  # Concept: the refusal keeps what an operator can act on and nothing that
  # caused it.
  #
  # Technical depth: the four counts partition the exact descriptor sequence
  # whose bytes produced the token estimate and the ordered digest, so
  # incrementing or reclassifying one without changing that sequence is refused
  # by the live constructor. No descriptor body, source reference, or oversized
  # candidate is retained, which is what makes the refusal's size independent of
  # history length.
  defp context_refusal_result(record, refusal, work, turn_number) do
    receipt = Map.fetch!(record, "context_receipt")
    blocks = Map.fetch!(receipt, "blocks")
    request = Map.fetch!(record, "request")
    tools = length(Map.get(request, "tools", []))
    messages = length(blocks) - tools
    steer = if Map.get(record, "applied_steer"), do: 1, else: 0

    message_blocks = Enum.take(blocks, messages)
    system = Enum.count(message_blocks, &(&1["provenance_class"] == "system"))
    session = Enum.count(message_blocks, &(&1["provenance_class"] == "session")) - steer

    if system + session + steer + tools == length(blocks) do
      {:refused,
       compact_refusal(receipt, refusal, work, turn_number, %{
         system: system,
         session: session,
         steer: steer,
         tools: tools
       })}
    else
      {:refused_not_required_only, refusal}
    end
  end

  # Concept: four counts that do not add up to the sequence they claim to
  # describe are not a refusal an operator can trust.
  #
  # Technical depth: ADR 0017 gives the compact refusal exactly the system,
  # session, steer, and tool counts, and makes their sum the descriptor count of
  # the sequence whose bytes produced `provider_estimated_tokens` and
  # `ordered_descriptor_digest`. There is no count for a project descriptor, so a
  # candidate carrying one cannot be described by this record at all, and the
  # reducer cannot detect that later: recovery holds no descriptor bodies. The
  # live constructor is the only place with that preimage, so a candidate whose
  # sequence is not the required-only one is reported as
  # `:refused_not_required_only` -- enough for its caller to withhold the
  # optional class and re-decide, and never a record that can be retained
  defp compact_refusal(receipt, refusal, work, turn_number, counts) do
    %{
      "run_id" => Map.fetch!(work, :run_id),
      "turn_id" => stable_id("turn", Map.fetch!(work, :run_id), turn_number),
      "category" => "context_budget_exceeded",
      "dimension" => Map.fetch!(refusal, "dimension"),
      "token_estimator" => Bounds.estimator(),
      "descriptor_canonicalization_version" => @descriptor_canonicalization_version,
      "project_disposition" => refusal_project_disposition(receipt),
      "system_message_count" => counts.system,
      "session_message_count" => counts.session,
      "steer_message_count" => counts.steer,
      "tool_definition_count" => counts.tools,
      "provider_estimated_tokens" => Map.fetch!(receipt, "provider_estimated_tokens"),
      "context_token_budget" => Map.fetch!(receipt, "context_token_budget"),
      "record_byte_cost" => Map.fetch!(refusal, "record_byte_cost"),
      "context_record_byte_ceiling" => Store.max_item_bytes(),
      "ordered_descriptor_digest" => Map.fetch!(receipt, "ordered_descriptor_digest"),
      "observed" => Map.fetch!(refusal, "observed"),
      "limit" => Map.fetch!(refusal, "limit"),
      kind: "context_admission_refused_v1"
    }
  end

  # Technical depth: a truthfully empty staged manifest keeps `staged_empty`
  # rather than being relabelled absent or declined, and an eligible project
  # that was never reached because required content already failed says exactly
  # that instead of suggesting it was staged.
  defp refusal_project_disposition(receipt) do
    case Map.fetch!(receipt, "project_resource") do
      %{"disposition" => "staged", "detail" => %{"entries" => []}} -> "staged_empty"
      %{"disposition" => "staged"} -> "not_evaluated_required_failure"
      %{"disposition" => disposition} -> disposition
    end
  end

  # Concept: the record says how large it is, and that statement is true of the
  # record that actually contains it.
  #
  # Technical depth: the cost cannot be measured against a value its own
  # insertion invalidates, so ADR 0017 resolves it by fixed point: start at zero,
  # measure the normalized candidate, write that count back, and repeat until the
  # embedded value equals the next measurement. The sequence is monotone and can
  # only move when the deterministic integer encoding crosses one of finitely
  # many widths, so it converges; failing to converge is Store unavailability
  # rather than a fabricated context dimension. Nothing is encoded here -- the
  # shared Store sizer answers without allocating the candidate.
  defp resolve_record_byte_cost(%{"context_receipt" => receipt} = record)
       when is_map(receipt) do
    if Map.has_key?(receipt, "record_byte_cost") do
      converge_record_byte_cost(record, 0, 8)
    else
      {:ok, record}
    end
  end

  defp resolve_record_byte_cost(record), do: {:ok, record}

  defp converge_record_byte_cost(_record, _current, 0),
    do: {:error, :context_record_preflight_unavailable}

  defp converge_record_byte_cost(record, current, fuel) do
    candidate = put_in(record, ["context_receipt", "record_byte_cost"], current)

    case Loopex.Store.normalize_and_measure_item(:record, candidate) do
      {:ok, normalized, ^current} -> {:ok, normalized}
      {:ok, _normalized, measured} -> converge_record_byte_cost(record, measured, fuel - 1)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  ## Concept

  The deterministic identity of one staged model operation.

  ## Technical depth

  Derived from the run and its turn number, so every attempt of one operation
  names the same identity and a successor rebuilding the run from the journal
  derives the identity its predecessor used. ADR 0018 does not accept an
  adapter-supplied identity here.
  """
  @spec model_operation_id(binary(), pos_integer()) :: binary()
  def model_operation_id(run_id, turn_number),
    do: stable_id("model-operation", run_id, turn_number)

  @doc """
  ## Concept

  Opens the one retry version one of the attempt record permits.

  ## Technical depth

  Legal only from `model_retry_permitted`, which exists only after an exact
  attempt-one settlement whose transport was `not_dispatched`. Applying the
  record consumes that permission permanently, so a proved non-commit may
  re-present the identical bytes while a committed open can never be repeated.
  """
  @spec propose_model_attempt_open(t(), binary()) :: {:ok, proposal()} | {:error, term()}
  def propose_model_attempt_open(%__MODULE__{} = state, run_id) when is_binary(run_id) do
    with %{stage: "model_retry_permitted", next_attempt: attempt, request: request} = work <-
           Map.get(state.pending_work, run_id),
         {:ok, opened} <-
           ProviderAttempt.opened_record(%{
             run_id: run_id,
             turn_id: work.turn_id,
             operation_id: model_operation_id(run_id, work.turn_number),
             attempt: attempt,
             staged_request_digest: request.staged_request_digest
           }) do
      internal_proposal(
        state,
        stable_id("model-attempt-open", run_id, {request.staged_request_digest, attempt}),
        opened
      )
    else
      {:error, reason} -> {:error, reason}
      _other -> {:error, :no_retry_permitted}
    end
  end

  @doc """
  ## Concept

  Admits an elapsed run deadline against the attempt it interrupted.

  ## Technical depth

  A separate durable row rather than a field of the settlement, because the
  journal order of abort, deadline, and settlement is what classifies the
  attempt. A stop signal is cleanup only and never reaches here.
  """
  @spec propose_model_termination(t(), binary(), non_neg_integer()) ::
          {:ok, proposal()} | {:error, term()}
  def propose_model_termination(%__MODULE__{} = state, run_id, observed)
      when is_binary(run_id) and is_integer(observed) do
    with %{stage: "model_attempt_open", request: request} = work <-
           Map.get(state.pending_work, run_id),
         deadline when is_integer(deadline) <- Map.get(state.deadlines, run_id),
         true <- observed >= deadline do
      record = %{
        "run_id" => run_id,
        "turn_id" => work.turn_id,
        "operation_id" => model_operation_id(run_id, work.turn_number),
        "attempt" => work.model_attempt,
        "staged_request_digest" => request.staged_request_digest,
        "cause" => "deadline",
        "deadline" => deadline,
        "observed" => observed,
        kind: "model_termination_admitted_v1"
      }

      internal_proposal(
        state,
        stable_id(
          "model-termination",
          run_id,
          {request.staged_request_digest, work.model_attempt}
        ),
        record
      )
    else
      _other -> {:error, :no_open_model_attempt}
    end
  end

  @doc """
  ## Concept

  Settles one provider attempt: what the transport is known to have done, what
  the answer cost, whether it entered the conversation, and what happens next —
  as one indivisible verdict.

  ## Technical depth

  `outcome` is the only thing the caller supplies. Everything else in the
  twelve-key record is derived here from committed history, because the members
  are not independent: which termination won is journal order, whether the
  answer is canonical follows from that, and the accounting follows from the
  transport and the reply's own usage. A caller that could name them separately
  could name a combination ADR 0018 calls invalid history.
  """
  @spec propose_model_attempt_settled(
          t(),
          binary(),
          {:reply, term()} | :not_dispatched | :dispatched_or_unknown | :owner_loss
        ) :: {:ok, proposal()} | {:error, term()}
  def propose_model_attempt_settled(%__MODULE__{} = state, run_id, outcome)
      when is_binary(run_id) do
    case Map.get(state.pending_work, run_id) do
      %{stage: "model_attempt_open"} = work ->
        settle_open_attempt(state, run_id, work, outcome)

      _absent ->
        {:error, :no_open_model_attempt}
    end
  end

  defp settle_open_attempt(state, run_id, work, outcome) do
    request = work.request
    attempt = work.model_attempt
    termination = attempt_termination(state, run_id, work, outcome)
    {result, conversation, usage} = attempt_result(work, outcome, termination)
    transport = attempt_transport(outcome)
    next = attempt_next(transport, termination, result, attempt)
    accounting = attempt_accounting(transport, usage)

    settlement = %{
      "run_id" => run_id,
      "turn_id" => work.turn_id,
      "operation_id" => model_operation_id(run_id, work.turn_number),
      "attempt" => attempt,
      "staged_request_digest" => request.staged_request_digest,
      "transport" => transport,
      "termination" => termination,
      "conversation" => conversation,
      "next" => next,
      "result" => result,
      "accounting" => accounting,
      kind: "model_attempt_settled_v1"
    }

    records =
      if next == "terminal" do
        [
          settlement,
          run_terminal_record(state, run_id, attempt_terminal(termination, result), %{
            bound: termination == "deadline" && "deadline",
            observed: termination == "deadline" && Map.get(state.deadlines, run_id),
            declared_limit: termination == "deadline" && Map.get(state.deadlines, run_id),
            reason: terminal_reason(result)
          })
        ]
      else
        [settlement]
      end

    internal_proposal(
      state,
      stable_id("model-attempt-settled", run_id, {request.staged_request_digest, attempt}),
      records
    )
  end

  # Concept: the first committed of abort, deadline, and settlement classifies
  # the attempt, and this reads that order rather than restating it.
  #
  # Technical depth: an owner loss is the weakest of the three: it is claimed
  # only where neither an admitted abort nor an admitted deadline already won,
  # because a recovered attempt whose run was already aborted ends as the abort
  # its operator asked for, not as an anonymous succession.
  defp attempt_termination(state, run_id, work, outcome) do
    cond do
      match?(%{run_id: ^run_id}, state.aborting) -> "abort"
      Map.get(work, :model_termination) == "deadline" -> "deadline"
      outcome == :owner_loss -> "owner_loss"
      true -> nil
    end
  end

  defp attempt_transport(:not_dispatched), do: "not_dispatched"
  defp attempt_transport(_other), do: "dispatched_or_unknown"

  # Concept: a reply that cannot be retained truthfully becomes the compact
  # unreadable answer, and it keeps whatever complete usage the provider did
  # report.
  #
  # Technical depth: the settlement is preflighted at its exact retained size
  # before it is proposed. A reply that passed validation but whose complete
  # settlement does not fit is compacted here rather than discovered at the
  # Store boundary, where the run would have no verdict at all.
  #
  # Both ways a reply can fail to be retained land in the same compact record.
  # ADR 0018 combination 5 is the only combination that names
  # `unreadable_model_answer`, and it is the answer this runtime could not read,
  # whether it contradicted itself or would not fit; combination 3's
  # `model_call_failed` names an attempt that returned no answer at all -- a
  # live ambiguous error or a recovered open attempt -- and takes the estimated
  # remaining allowance because there is no reported figure to keep. Complete
  # usage the provider did report survives either compaction, because
  # combination 5 "preserves complete reported usage when available"; the
  # validated reply supplies it where canonicalization succeeded, and the raw
  # answer's normalized usage supplies it where canonicalization refused the
  # reply before there was a validated one.
  #
  # The raw answer reaches `canonical_reply/2` unmeasured on purpose: that
  # function admits it against ADR 0017's plain-data, depth, cardinality and
  # byte ceilings before it projects anything, which is the order M2's row-one
  # obligation fixes. Measuring here instead would put the settlement check
  # after a projection that has already walked and copied the whole answer. The
  # settlement measurement below stays where it is, because the ceiling that
  # decides what is retained applies to the record, not to the reply.
  defp attempt_result(work, {:reply, raw}, termination) do
    case ProviderAttempt.canonical_reply(raw, work.request) do
      {:ok, reply} ->
        result = %{"kind" => "reply", "reply" => reply}
        conversation = if termination, do: "evidence_only", else: "canonical"

        if reply_settlement_fits?(work, result, reply["usage"], termination, conversation) do
          {result, conversation, reply["usage"]}
        else
          {unreadable_result(), "none", reply["usage"]}
        end

      {:error, _reason} ->
        {unreadable_result(), "none", raw_reply_usage(raw)}
    end
  end

  defp attempt_result(_work, _outcome, _termination),
    do: {%{"kind" => "error", "category" => "model_call_failed"}, "none", nil}

  defp unreadable_result, do: %{"kind" => "error", "category" => "unreadable_model_answer"}

  # Concept: the compact answer is preflighted against the same ceiling the
  # complete one is measured with.
  #
  # Technical depth: measured on the intended settlement rather than the reply,
  # since the Store retains the record. The paired terminal is a separate item
  # and is measured on its own.
  #
  # The candidate carries the termination and conversation this settlement will
  # actually commit, not a fixed pair. A settlement terminated by an admitted
  # abort or deadline is longer than an unterminated canonical one -- `nil`
  # against `"deadline"`, `"canonical"` against `"evidence_only"` -- so
  # preflighting the shorter pair admits, at the exact byte ceiling, a record
  # the Store then refuses. ADR 0018 requires that refusal never be discovered
  # there, because the run would be left with no verdict at all. `next` stays
  # `"terminal"` because it is the longest of the three values the member can
  # take, and the member is not settled until the result it depends on is
  # chosen.
  defp reply_settlement_fits?(work, result, usage, termination, conversation) do
    candidate = %{
      "run_id" => work.run_id,
      "turn_id" => work.turn_id,
      "operation_id" => model_operation_id(work.run_id, work.turn_number),
      "attempt" => work.model_attempt,
      "staged_request_digest" => work.request.staged_request_digest,
      "transport" => "dispatched_or_unknown",
      "termination" => termination,
      "conversation" => conversation,
      "next" => "terminal",
      "result" => result,
      "accounting" => attempt_accounting("dispatched_or_unknown", usage),
      kind: "model_attempt_settled_v1"
    }

    case Store.normalize_and_measure_item(:record, candidate) do
      {:ok, _normalized, bytes} -> bytes <= Store.max_item_bytes()
      {:error, _refused} -> false
    end
  end

  defp raw_reply_usage(raw) when is_map(raw) and not is_struct(raw) do
    case Map.get(raw, :usage, Map.get(raw, "usage", :absent)) do
      :absent -> nil
      usage -> ProviderAttempt.normalize_usage(usage)
    end
  end

  defp raw_reply_usage(_raw), do: nil

  defp attempt_accounting("not_dispatched", _usage),
    do: %{"source" => "none", "basis" => "not_dispatched"}

  defp attempt_accounting(_transport, %{
         "status" => "reported",
         "input_tokens" => input,
         "output_tokens" => output
       }),
       do: %{"source" => "reported", "input_tokens" => input, "output_tokens" => output}

  defp attempt_accounting(_transport, _usage),
    do: %{"source" => "estimated", "basis" => "remaining_allowance"}

  defp attempt_next("not_dispatched", nil, _result, attempt) do
    if attempt < ProviderAttempt.attempt_limit(), do: "retry", else: "terminal"
  end

  defp attempt_next(_transport, nil, %{"kind" => "reply", "reply" => reply}, _attempt) do
    if reply["tool_calls"] == [], do: "terminal", else: "continue"
  end

  defp attempt_next(_transport, _termination, _result, _attempt), do: "terminal"

  defp attempt_terminal("abort", _result), do: "cancelled"
  defp attempt_terminal("deadline", _result), do: "bound_reached"
  defp attempt_terminal(_termination, %{"kind" => "reply"}), do: "completed"
  defp attempt_terminal(_termination, _result), do: "failed"

  defp terminal_reason(%{"kind" => "error", "category" => category}), do: category
  defp terminal_reason(_result), do: nil

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
      "job" => encode_plain(Map.from_struct(job)),
      "grant" => encode_plain(grant),
      kind: "effect_intent_committed"
    }

    # Concept: the durable record of what this runtime is about to do is measured
    # before anything is dispatched, and one byte too many is an ordinary
    # pre-effect refusal rather than a surprise from the Store.
    #
    # Technical depth: ADR 0016 requires the complete effect-intent item to be
    # normalized and measured against the Store's fixed ceiling before its
    # transaction. Reaching the Store first would either commit an intent whose
    # own record cannot be retained or return a generic Store error for a
    # condition this runtime can name exactly, and the call still owes the
    # conversation the truthful terminal `effect_intent_record_too_large`.
    case Store.validate_private_record(record) do
      :ok ->
        internal_proposal(state, stable_id("effect-intent", run_id, job.job_id), record)

      {:error, {:item_too_large, _observed, _limit}} ->
        {:error, :effect_intent_record_too_large}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc false
  @spec propose_executor_fact(t(), binary(), map()) :: {:ok, proposal()} | {:error, term()}
  def propose_executor_fact(%__MODULE__{} = state, run_id, receipt)
      when is_binary(run_id) and is_map(receipt) do
    with %{stage: "effect_dispatched", job: job} <- Map.get(state.pending_work, run_id),
         {:ok, receipt} <- canonical_executor_receipt(receipt, job) do
      record = %{
        "run_id" => run_id,
        "receipt" => encode_plain(receipt),
        kind: "executor_receipt_committed"
      }

      internal_proposal(state, stable_id("executor-fact", run_id, receipt.job_id), record)
    else
      _other -> {:error, :invalid_executor_receipt}
    end
  end

  @doc false
  @spec propose_reconciled_executor_fact(t(), binary(), map(), binary()) ::
          {:ok, proposal()} | {:error, term()}
  def propose_reconciled_executor_fact(%__MODULE__{} = state, run_id, receipt, query_id)
      when is_binary(run_id) and is_map(receipt) and is_binary(query_id) do
    with %{stage: "effect_dispatched", job: job} <- Map.get(state.pending_work, run_id),
         {:ok, receipt} <- canonical_executor_receipt(receipt, job) do
      record = %{
        "run_id" => run_id,
        "receipt" => encode_plain(receipt),
        "reconciliation_query_id" => query_id,
        kind: "executor_receipt_committed"
      }

      # Concept: a solicited current-owner receipt is a new reconciliation
      # decision, not a retry of the stale predecessor's live-result transaction.
      #
      # Technical depth: ADR 0006 makes every proved non-commit terminal for its
      # transaction ID. A predecessor may already have consumed the live
      # `executor-fact` ID with `stale_owner_epoch`; reusing it with current-owner
      # bindings must then conflict. The query ID names the separately validated
      # current-epoch decision and is already bound by the reconciliation response.
      internal_proposal(
        state,
        stable_id("executor-reconciliation-fact", run_id, query_id),
        record
      )
    else
      _other -> {:error, :invalid_executor_receipt}
    end
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
      "context_token_budget" => Map.fetch!(command.resolved_bounds, :context_token_budget),
      kind: "prompt_admitted_v2"
    }

    events = prompt_events(state.session_id, command.command_id, run_id, command.content)

    admitted_proposal(state, command, digest, "prompt", record, events, reply)
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

        admitted_proposal(
          state,
          command,
          digest,
          "steer",
          record,
          [],
          {:accepted, command.command_id}
        )
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

      admitted_proposal(
        state,
        command,
        digest,
        "follow_up",
        record,
        [],
        {:accepted, command.command_id},
        promoted_follow_up_events(state, command)
      )
    end
  end

  defp propose_new(
         %__MODULE__{active_run_id: nil} = state,
         %{type: :follow_up} = command,
         digest
       ),
       do: refusal(state, command, digest, "follow_up", "rejected_no_active_run", :no_active_run)

  # Concept: the admission says an abort was asked for. What it achieved is a
  # separate fact, committed after the cleanup that produced it.
  #
  # Technical depth: this record used to carry the run's ending, which meant the
  # cleanup had to have happened before it could be written at all -- so the
  # coordinator cancelled first and committed afterwards. A host that died in
  # between left no record anyone had asked, though the effect process might
  # already be dead. ADR 0009 orders it the other way round, and every other run
  # ending already uses two records: `command_admitted` and then
  # `run_terminal_committed`. The abort was the only ending folding both into
  # one.
  #
  # The queues are still resolved here, because Outcome 3 requires a durably
  # admitted abort to resolve a queued steer and follow-up, and that is true the
  # moment the abort is admitted rather than when its cleanup finishes.
  defp propose_new(%__MODULE__{active_run_id: run_id} = state, %{type: :abort} = command, digest)
       when is_binary(run_id) do
    record = %{
      "command_id" => command.command_id,
      "command_digest" => digest,
      "command_type" => "abort",
      "admission" => "accepted",
      "run_id" => run_id,
      kind: "command_admitted"
    }

    {_patch, queue_events} = cancel_queues(state, run_id)

    build_proposal(
      state,
      command.command_id,
      record,
      queue_events,
      {:accepted, command.command_id}
    )
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

  # Concept: only a command that would otherwise be accepted is measured.
  #
  # Technical depth: ADR 0011's active-run, matching-run, and queue preconditions
  # decide first, so a refusal here is always about durable representability
  # rather than a command that had another answer waiting. Replay is unaffected:
  # a retained refusal answers before any of this runs again.
  # Concept: the follow-up is measured against the event promotion will
  # deterministically emit, not only against its own record.
  #
  # Technical depth: promotion's successor run and event identities are already
  # derivable at admission, so the exact unstamped payload Store will validate
  # can be built and sized now. These candidates are measured and discarded; the
  # events promotion actually emits are produced by the reducer when the
  # predecessor's terminal applies.
  defp promoted_follow_up_events(state, command) do
    prompt_events(
      state.session_id,
      command.command_id,
      promoted_run_id(state, command),
      command.content
    )
  end

  defp admitted_proposal(state, command, digest, type, record, events, reply, candidates \\ nil) do
    run_id = Map.get(record, "run_id") || promoted_run_id(state, command)

    case preflight_command(state, record, candidates || events, run_id) do
      :ok ->
        build_proposal(state, command.command_id, record, events, reply)

      {:refused, dimension, candidate, observed} ->
        command_too_large(state, command, digest, type, dimension, candidate, observed)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp promoted_run_id(state, command),
    do: stable_id("run", state.session_id, command.command_id)

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

  # Concept: the session's cleanup period is reconstructed from the record that
  # committed it, never supplied by whatever process happens to be recovering.
  #
  # Technical depth: ADR 0016 replaces ADR 0009's `session_genesis` with
  # `session_genesis_v2`, whose outer and runtime-configuration key sets are both
  # closed. This reducer refuses the legacy kind outright, so no decoder can
  # upgrade old bytes by supplying a default, and refuses an unknown key, an
  # empty configuration, or a value outside the positive unsigned 64-bit domain
  # rather than recovering a session whose committed period nobody can name.
  defp replay_record(
         %{journal_version: 0} = state,
         %{
           journal_version: 1,
           owner_epoch: 0,
           owner_incarnation_id: nil,
           payload: %{kind: "session_genesis_v2"} = payload
         }
       ) do
    case genesis_cleanup_grace(payload) do
      {:ok, grace} -> {:ok, %{state | journal_version: 1, cleanup_grace_ms: grace}}
      :error -> {:error, :invalid_session_genesis}
    end
  end

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
           payload: %{kind: kind} = record
         }
       )
       when kind in ["command_admitted", "prompt_admitted_v2", "command_admission_refused_v1"] do
    # Technical depth: a pending refusal marker admits exactly one next row, and
    # a command row is not it. The tail guard was applied only to the internal
    # clause below, so a validly stamped command row landing between a refusal
    # and its terminal replayed, splitting the pair ADR 0017 makes indivisible.
    # The two clauses partition every replayable kind, so the guard has to hold
    # in both for the invariant to be about the journal rather than one clause.
    if version == state.journal_version + 1 and owner_epoch == state.owner_epoch and
         incarnation == state.owner_incarnation_id and is_binary(incarnation) and
         admissible_command_kind?(kind, record) and context_refusal_tail?(state, kind) do
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
              "context_admission_refused_v1",
              "deadline_staging_failed_v1",
              "model_request_committed",
              "model_attempt_opened_v1",
              "model_attempt_settled_v1",
              "model_termination_admitted_v1",
              "effect_intent_committed",
              "executor_receipt_committed",
              "outcome_unknown_committed",
              "run_terminal_committed",
              "tool_result_committed"
            ] do
    if version == state.journal_version + 1 and owner_epoch == state.owner_epoch and
         incarnation == state.owner_incarnation_id and is_binary(incarnation) and
         context_refusal_tail?(state, kind) do
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

  defp genesis_cleanup_grace(
         %{"options" => options, "runtime_configuration" => configuration} = payload
       )
       when is_map(options) and is_map(configuration) do
    with 3 <- map_size(payload),
         1 <- map_size(configuration),
         {:ok, grace} <- Map.fetch(configuration, "cleanup_grace_ms"),
         true <- is_integer(grace) and grace >= 1 and grace <= @max_cleanup_grace_ms do
      {:ok, grace}
    else
      _other -> :error
    end
  end

  defp genesis_cleanup_grace(_payload), do: :error

  # Concept: nothing may come between a refusal and the terminal that completes
  # it.
  #
  # Technical depth: once the first row installs the marker, the immediately
  # next journal version must be the matching terminal. An intervening,
  # duplicated, or reordered row is invalid history, which is what makes the
  # pair one semantic unit across a pagination boundary as well as within a
  # single page. Both replayable record classes consult this, because a row that
  # is otherwise valid history -- correctly stamped, of an admitted kind, and
  # applying cleanly on its own -- is exactly the row no other check can refuse.
  defp context_refusal_tail?(%{context_refusal: nil}, _kind), do: true
  defp context_refusal_tail?(_state, "run_terminal_committed"), do: true
  defp context_refusal_tail?(_state, _kind), do: false

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

  # Concept: an accepted prompt must carry the ceiling its run committed.
  #
  # Technical depth: ADR 0017 gives the accepted prompt its own record kind, so
  # a history written before the context budget existed fails closed instead of
  # replaying as though the value were merely absent and then being handed
  # whatever the current process now defaults to. Every other admission keeps
  # the legacy kind, so only the accepted-prompt spelling is refused there.
  defp admissible_command_kind?("command_admitted", record),
    do: not (record["command_type"] == "prompt" and record["admission"] == "accepted")

  defp admissible_command_kind?("prompt_admitted_v2", record),
    do: record["command_type"] == "prompt" and record["admission"] == "accepted"

  # Technical depth: `observed` must be a positive integer strictly above the
  # fixed limit. A retained refusal at or below the ceiling describes a candidate
  # that would have fitted, which is invalid history rather than a refusal to
  # replay.
  defp admissible_command_kind?("command_admission_refused_v1", record) do
    record["admission"] == "rejected_durable_candidate_bytes" and
      record["limit"] == 65_536 and
      is_integer(record["observed"]) and record["observed"] > 65_536 and
      valid_refused_candidate?(record["dimension"], record["candidate"])
  end

  defp valid_refused_candidate?("command_record_bytes", candidate),
    do: candidate in ~w(prompt_record steer_record follow_up_record)

  defp valid_refused_candidate?("command_event_bytes", candidate),
    do: candidate == "follow_up_user_message_event"

  defp valid_refused_candidate?("future_bound_record_bytes", candidate),
    do: candidate in ~w(max_turns_private_terminal max_turns_public_finish
        token_budget_private_terminal token_budget_public_finish
        deadline_private_terminal deadline_public_finish)

  defp valid_refused_candidate?(_dimension, _candidate), do: false

  defp command_effect(
         %{active_run_id: nil} = state,
         record,
         "prompt",
         "accepted",
         command_id
       ) do
    with {:ok, run_id} <- record_binary(record, "run_id"),
         {:ok, content} <- record_binary(record, "content"),
         {:ok, declared} <- record_bounds(record),
         {:ok, context_budget} <- record_context_token_budget(record) do
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
        bounds: Map.put(state.bounds, run_id, declared),
        context_budgets: Map.put(state.context_budgets, run_id, context_budget)
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

  # Technical depth: an oversized command installs no run, steer, or follow-up,
  # emits no public event, and leaves every queue exactly as it was. Its retained
  # answer is the same composite the live caller received.
  defp command_effect(state, record, _type, "rejected_durable_candidate_bytes", _command_id) do
    reply =
      {:error,
       {:command_admission_too_large, Map.get(record, "dimension"), Map.get(record, "candidate"),
        Map.get(record, "observed"), 65_536}}

    {:ok, reply, state.active_run_id, state.pending_work, state.expected_events, %{}}
  end

  # Concept: a durable refusal token names one of the refusals this owner
  # writes, or it is not a record this owner can apply.
  #
  # Technical depth: the reason was `String.to_existing_atom/1` of a field read
  # straight out of the journal, unrescued where every comparable site rescues.
  # Whether it raised depended on which atoms the VM had loaded, so the same
  # durable history could replay on one node and abort recovery with an
  # `ArgumentError` on a colder one, and a token from another version aborted
  # rather than being refused. The mapping is closed over the tokens `refusal/6`
  # writes for these two command types; any other token is invalid history and
  # takes the ordinary typed refusal, creating no atom on either path.
  defp command_effect(state, _record, type, "rejected_" <> reason, _command_id)
       when type in ["steer", "follow_up"] do
    case rejected_command_reason(reason) do
      {:ok, refusal} ->
        {:ok, {:error, refusal}, state.active_run_id, state.pending_work, state.expected_events,
         %{}}

      :error ->
        {:error, :invalid_command_transition}
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
          state.expected_events, %{}}

  defp command_effect(
         %{active_run_id: active_run_id} = state,
         record,
         "abort",
         "accepted",
         command_id
       )
       when is_binary(active_run_id) do
    # Concept: an abort record says what the abort achieved, or it is not a
    # record this owner can apply.
    #
    # Technical depth: the outcome used to default to `cancelled` when the field
    # was absent — the strongest claim in the algebra, chosen by a record that
    # said nothing. A record replayed on recovery must never be read as claiming
    # more than it carries, and this is the one field carrying the
    # `outcome_unknown` precedence, so there is no honest weaker default: the
    # record names its outcome or it is refused like any other malformed abort.
    with {:ok, ^active_run_id} <- record_binary(record, "run_id") do
      # Concept: an abort cancels the queues as well as the run.
      #
      # Technical depth: a durably admitted abort resolves any queued steer and
      # any queued follow-up as cancelled, each recorded truthfully against its
      # own command_id. Leaving either queued would let work an operator
      # cancelled start itself a moment later.
      #
      # The run stays active and its pending work stays here, because neither is
      # over: the cleanup has not run and its result has not been committed. What
      # changes is the marker, and the marker is load-bearing twice over -- the
      # coordinator stops scheduling for a run that carries it, which is ADR
      # 0009's second step, and a recovering owner reads it to know an abort was
      # admitted whose outcome nobody wrote down.
      {patch, queue_events} = cancel_queues(state, active_run_id)

      {:ok, {:accepted, command_id}, active_run_id, state.pending_work,
       state.expected_events ++ queue_events,
       Map.put(patch, :aborting, %{run_id: active_run_id, command_id: command_id})}
    else
      _other -> {:error, :invalid_abort_record}
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

  defp rejected_command_reason("run_mismatch"), do: {:ok, :run_mismatch}
  defp rejected_command_reason("steer_pending"), do: {:ok, :steer_pending}
  defp rejected_command_reason("no_active_run"), do: {:ok, :no_active_run}
  defp rejected_command_reason("follow_up_pending"), do: {:ok, :follow_up_pending}
  defp rejected_command_reason(_reason), do: :error

  # Concept: an internal transition keeps one identity while its exact Store
  # presentation is unresolved, and receives a fresh one after ownership or the
  # durable head moves.
  #
  # Technical depth: ADR 0006 retains non-commits as terminal transaction
  # resolutions. A logical ID derived only from the run or operation can
  # therefore be consumed by a stale owner and poison the successor's different
  # immutable binding with `tx_id_conflict`. Binding the Store-facing ID to the
  # expected owner pair and journal version preserves exact `commit_unknown`
  # re-presentation while making every re-derivation from a new authoritative
  # head a new transaction. All internal transition constructors pass through
  # this boundary; command IDs retain their separate public idempotency contract.
  defp internal_proposal(state, logical_tx_id, record) when is_map(record),
    do: internal_proposal(state, logical_tx_id, [record])

  defp internal_proposal(state, logical_tx_id, records) when is_list(records) do
    with [_first | _rest] <- records,
         {:ok, next, events} <- apply_internal_records(state, records) do
      tx_id = internal_transaction_id(state, logical_tx_id)
      next = %{next | expected_events: state.expected_events ++ events}

      {:ok,
       %{tx_id: tx_id, records: records, events: events, next: next, reply: {:accepted, tx_id}}}
    else
      [] -> {:error, :empty_internal_proposal}
      {:error, reason} -> {:error, reason}
    end
  end

  defp apply_internal_records(state, records) do
    Enum.reduce_while(records, {:ok, state, []}, fn record, {:ok, current, events} ->
      case apply_internal_record(current, record) do
        {:ok, next, emitted} -> {:cont, {:ok, next, events ++ emitted}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp internal_transaction_id(state, logical_tx_id) do
    stable_id(
      "internal",
      state.session_id,
      {
        logical_tx_id,
        state.owner_epoch,
        state.owner_incarnation_id,
        state.journal_version
      }
    )
  end

  # Concept: the request row alone stages nothing observable.
  #
  # Technical depth: ADR 0018 makes the consecutive attempt-open row the
  # dispatch authority, so applying the request alone must expose no staged
  # request, attempt, stream domain, conversation, accounting, queue effect, or
  # public start. The decoded bytes are held under `:staged` until that row
  # arrives, which is why a page boundary between the two is legal and a
  # recovery that stops between them dispatches nothing.
  defp apply_internal_record(
         state,
         %{
           "run_id" => run_id,
           "turn_id" => turn_id,
           "operation_id" => operation_id,
           "staged_request_digest" => staged_request_digest,
           "request" => request,
           "applied_steer" => applied_steer,
           kind: "model_request_committed"
         } = record
       ) do
    with {:ok, request} <- decode_request(request),
         %{stage: stage} = work when stage in ["model_pending", "turn_settled"] <-
           Map.get(state.pending_work, run_id),
         :ok <- Loopex.Model.validate_request(request),
         turn_number = next_turn_number(work),
         true <- turn_id == stable_id("turn", run_id, turn_number),
         true <- operation_id == model_operation_id(run_id, turn_number),
         true <- staged_request_digest == request.staged_request_digest,
         :ok <- validate_context_receipt(state, record, request, run_id, applied_steer) do
      next_work =
        work
        |> Map.drop([:request, :model_attempt, :model_termination, :settlement, :next_attempt])
        |> Map.merge(%{
          stage: "model_request_pending_attempt_open",
          pending_calls: [],
          staged: %{
            turn_id: turn_id,
            turn_number: turn_number,
            request: request,
            applied_steer: applied_steer
          }
        })

      {:ok, put_pending(state, run_id, next_work), []}
    else
      _other -> {:error, :invalid_model_request_transition}
    end
  end

  # Concept: opening the attempt is what makes a staged request dispatchable.
  #
  # Technical depth: attempt one is the second row of the first-staging
  # transaction and promotes everything that row deferred — the turn, the staged
  # request, the run's deadline instant, any steer the request carried, and the
  # run's public start. Attempt two comes from `model_retry_permitted` alone and
  # consumes that permission permanently, which is what bounds the version-one
  # allowance across succession: the limit is read from committed history rather
  # than from whichever owner happens to be alive.
  defp apply_internal_record(state, %{kind: "model_attempt_opened_v1"} = record) do
    with :ok <- ProviderAttempt.validate_opened(record),
         run_id = record["run_id"],
         work when is_map(work) <- Map.get(state.pending_work, run_id) do
      open_model_attempt(state, run_id, work, record)
    else
      {:error, reason} -> {:error, reason}
      _other -> {:error, :invalid_model_attempt_open_transition}
    end
  end

  # Concept: a deadline is admitted against the attempt it interrupted before
  # anything settles it.
  #
  # Technical depth: the row changes no accounting, conversation, or terminal.
  # It fixes the journal order that later classifies the attempt, which is what
  # makes "abort versus deadline is journal order" a fact replay can read.
  defp apply_internal_record(state, %{kind: "model_termination_admitted_v1"} = record) do
    with :ok <- ProviderAttempt.validate_termination(record),
         run_id = record["run_id"],
         %{stage: "model_attempt_open", request: request} = work <-
           Map.get(state.pending_work, run_id),
         true <- attempt_identity_matches?(record, run_id, work, request),
         true <- record["deadline"] == Map.get(state.deadlines, run_id),
         nil <- Map.get(work, :model_termination) do
      {:ok, put_pending(state, run_id, Map.put(work, :model_termination, "deadline")), []}
    else
      {:error, reason} -> {:error, reason}
      _other -> {:error, :invalid_model_termination_transition}
    end
  end

  # Concept: one attempt's verdict is applied whole or not at all.
  #
  # Technical depth: a `terminal` settlement applies nothing on its own — it
  # installs `model_attempt_pending_terminal` holding its own bytes, and the
  # exact consecutive `run_terminal_committed` applies the accounting,
  # conversation, and ending together. `retry` and `continue` settlements are
  # complete in one row because neither ends the run.
  defp apply_internal_record(state, %{kind: "model_attempt_settled_v1"} = record) do
    with :ok <- ProviderAttempt.validate_settled(record),
         run_id = record["run_id"],
         %{stage: "model_attempt_open", request: request} = work <-
           Map.get(state.pending_work, run_id),
         true <- attempt_identity_matches?(record, run_id, work, request),
         true <- settlement_termination_agrees?(state, run_id, work, record) do
      apply_attempt_settlement(state, run_id, work, record)
    else
      {:error, reason} -> {:error, reason}
      _other -> {:error, :invalid_model_attempt_settlement_transition}
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
      # A call that ended without a receipt is the one case where the terminal's
      # only explanation is the reason it carries, so the public plane carries it
      # too: an operator reading `failed` with nothing beside it cannot tell a
      # refused argument from a durable record that would not fit.
      event =
        %{
          "run_id" => run_id,
          "turn_id" => Map.get(work, :turn_id),
          "tool_call_id" => tool_call_id,
          "tool_id" => called_tool_id(call),
          "outcome" => outcome,
          "reason" => reason,
          "artifacts" => [],
          event_id: stable_id("event-tool-finished", state.session_id, tool_call_id),
          kind: "tool.finished"
        }

      {:ok, next, [event]}
    else
      _other -> {:error, :invalid_tool_result_transition}
    end
  end

  # Concept: applying the refusal row alone changes nothing durable.
  #
  # Technical depth: ADR 0017 makes the refusal and its terminal one semantic
  # unit spread over two consecutive journal rows. The first row installs only a
  # transient marker: no run state moves, no event is emitted, no queue
  # resolves, and nothing is dispatched. A pagination boundary between the two
  # rows is legitimate and carries the marker into the next fetch. Reaching the
  # durable head with the marker still pending, or observing any intervening,
  # duplicated, or mismatched row, is invalid incomplete history.
  defp apply_internal_record(state, %{kind: "context_admission_refused_v1"} = refusal) do
    with :ok <- validate_context_refusal(state, refusal) do
      {:ok,
       %{
         state
         | context_refusal: %{
             run_id: Map.get(refusal, "run_id"),
             failure: context_failure(refusal)
           }
       }, []}
    end
  end

  # Concept: a run whose deadline cannot be represented never opens an attempt.
  #
  # Technical depth: ADR 0017 requires the clock reading and the checked
  # addition to be proved at first staging, before any model attempt or stream
  # domain exists. The compact first row never retains the invalid or giant
  # value -- only which of the two domain facts failed -- and is itself proved
  # representable. Its terminal completes the same transient-marker pair the
  # context refusal uses, so recovery applies no terminal effect until the
  # matching consecutive row arrives.
  defp apply_internal_record(state, %{kind: "deadline_staging_failed_v1"} = failure) do
    run_id = Map.get(failure, "run_id")
    work = Map.get(state.pending_work, run_id)

    with true <- map_size(failure) == 4,
         true <- run_id == state.active_run_id,
         %{stage: stage} <- work,
         true <- stage in ["model_pending", "turn_settled"],
         true <-
           Map.get(failure, "turn_id") == stable_id("turn", run_id, next_turn_number(work)),
         true <-
           Map.get(failure, "category") in ["clock_out_of_domain", "deadline_addition_overflow"] do
      {:ok, %{state | context_refusal: %{run_id: run_id, failure: deadline_failure()}}, []}
    else
      _invalid -> {:error, :invalid_deadline_staging_failure}
    end
  end

  defp apply_internal_record(
         state,
         %{
           "run_id" => run_id,
           "outcome" => outcome,
           "bound" => bound,
           "observed" => observed,
           "declared_limit" => declared_limit,
           "accounting_source" => accounting_source,
           "reconciliation_ref" => reconciliation_ref,
           "cleanup_grace_ms" => cleanup_grace_ms,
           "command_id" => command_id,
           "reason" => reason,
           kind: "run_terminal_committed"
         } = record
       ) do
    # Concept: a terminal that completes a settlement applies that settlement
    # first, in the same transaction.
    #
    # Technical depth: ADR 0018 defers every semantic effect of a terminal
    # settlement to its consecutive terminal row, so this is where the deferred
    # accounting, conversation, and stage transition are applied. A terminal
    # arriving against any other stage is the ordinary ending it always was.
    with {:ok, state, work, settled_events} <- complete_pending_terminal(state, run_id),
         %{stage: stage} <- work,
         true <-
           outcome in ["completed", "bound_reached", "outcome_unknown", "cancelled", "failed"],
         true <- terminal_admitted?(state, run_id, stage, outcome, bound),
         true <- is_nil(reason) or is_binary(reason),
         {:ok, state, failure} <- consume_context_refusal(state, run_id, outcome, record) do
      # Concept: bound_reached carries the bound and the observed value and
      # nothing else.
      #
      # Technical depth: the declared limit that value was measured against and
      # the accounting source that produced it are siblings of the outcome in
      # this record, recorded beside it rather than inside it, so the run
      # terminal algebra keeps exactly the shape the vision fixes.
      event =
        run_finished_event(
          state.session_id,
          run_id,
          outcome,
          reconciliation_ref,
          cleanup_grace_ms,
          command_id
        )
        |> Map.merge(
          case outcome do
            "bound_reached" ->
              %{
                "bound" => bound,
                "observed" => observed,
                "declared_limit" => declared_limit,
                "accounting_source" => accounting_source
              }

            "failed" ->
              %{}
              |> then(&if(failure, do: Map.put(&1, "failure", failure), else: &1))
              |> then(&if(reason, do: Map.put(&1, "reason", reason), else: &1))

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

      {:ok, %{state | aborting: nil},
       settled_events ++ [event] ++ steer_events ++ promotion_events}
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
        run_finished_event(
          state.session_id,
          run_id,
          "outcome_unknown",
          reconciliation_ref,
          state.cleanup_grace_ms
        )
      ]

      # Concept: reconciliation settles the same operator queues as every other
      # run ending.
      #
      # Technical depth: this record used to clear the active run directly. That
      # stranded a steer and follow-up admitted while the recovered effect awaited
      # its operator decision, and the stale follow-up could later start behind an
      # unrelated run. Resolve and promote inside this proposal so the public
      # terminal and everything it unblocks remain one durable transaction.
      {state, steer_events} = resolve_steer(state, run_id, "run_terminal")
      {state, promotion_events} = promote_follow_up(state, run_id)

      {:ok, state, events ++ steer_events ++ promotion_events}
    else
      _other -> {:error, :invalid_outcome_unknown_transition}
    end
  end

  defp apply_internal_record(_state, _record), do: {:error, :invalid_internal_transition}

  # Concept: only the deadline and an unprovable effect may end a run that is
  # still mid-turn.
  #
  # Technical depth: every other bound is evaluated between turns, so a terminal
  # arriving from any other stage would mean a bound was applied to a turn nobody
  # settled. The deadline is the one bound that also binds work already in
  # flight — it can abort a request the provider may already have billed — so it
  # is admitted from any stage. So is a committed `outcome_unknown`, and it must
  # be: the calls remaining in an assistant batch leave the run at
  # `effect_pending`, a stage no turn has settled, and requiring settlement
  # there is what let the run keep dispatching effects behind an outcome that
  # was already terminal. The claim is checked rather than trusted — this admits
  # `outcome_unknown` only from a run whose committed elements actually hold an
  # unprovable effect.
  # A run an operator durably aborted may end `cancelled`, and only such a run
  # may: `cancelled` claims cancellation caused the termination, and a run nobody
  # asked to stop cannot make that claim. It may also end `outcome_unknown`,
  # which is what an unproved cleanup gives it, whatever stage it had reached.
  defp terminal_admitted?(%{aborting: %{run_id: run_id}}, run_id, _stage, outcome, _bound)
       when outcome in ["cancelled", "outcome_unknown"],
       do: true

  defp terminal_admitted?(_state, _run_id, "turn_settled", _outcome, _bound), do: true

  # Concept: a context refusal ends the run at the request-staging boundary and
  # nowhere else.
  #
  # Technical depth: ADR 0017 admits the refusal pair only from `model_pending`
  # or `turn_settled`, before any staged request, provider attempt, effect
  # intent, or executor job exists for that turn. The same pair presented from a
  # later stage is invalid history rather than authority to abandon work that is
  # already in flight.
  defp terminal_admitted?(_state, _run_id, stage, "failed", _bound)
       when stage in ["model_pending", "turn_settled"],
       do: true

  defp terminal_admitted?(state, run_id, _stage, "outcome_unknown", _bound),
    do: unproven_effect?(state, run_id)

  defp terminal_admitted?(_state, _run_id, _stage, outcome, "deadline")
       when outcome in ["bound_reached", "outcome_unknown"],
       do: true

  defp terminal_admitted?(_state, _run_id, _stage, _outcome, _bound), do: false

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
          # ADR 0013 as amended by ADR 0017: promotion inherits all four
          # committed values from the predecessor rather than reading whatever
          # the current process now defaults to.
          context_budgets:
            Map.put(state.context_budgets, promoted, Map.get(state.context_budgets, run_id)),
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

  # Concept: opening the attempt promotes everything the request row deferred.
  #
  # Technical depth: attempt one and attempt two reach `model_attempt_open` from
  # two different states, and neither may reach it from the other's. Attempt one
  # comes only from a staged request whose open row is the next one; attempt two
  # comes only from a retry permission an exact attempt-one `not_dispatched`
  # settlement created, and consumes it.
  defp open_model_attempt(
         state,
         run_id,
         %{stage: "model_request_pending_attempt_open", staged: staged} = work,
         record
       ) do
    with 1 <- record["attempt"],
         true <- record["run_id"] == run_id,
         true <- record["turn_id"] == staged.turn_id,
         true <- record["operation_id"] == model_operation_id(run_id, staged.turn_number),
         true <- record["staged_request_digest"] == staged.request.staged_request_digest do
      request = staged.request

      next_work =
        work
        |> Map.delete(:staged)
        |> Map.merge(%{
          stage: "model_attempt_open",
          turn_id: staged.turn_id,
          turn_number: staged.turn_number,
          request: request,
          model_attempt: 1,
          model_termination: nil,
          pending_calls: []
        })

      state = %{state | deadlines: Map.put_new(state.deadlines, run_id, request.deadline)}
      {state, steer_events} = apply_staged_steer(state, run_id, staged.applied_steer)

      {:ok, put_pending(state, run_id, next_work),
       run_started_events(
         state.session_id,
         Map.get(work, :command_id),
         run_id,
         staged.turn_number
       ) ++
         steer_events}
    else
      _other -> {:error, :invalid_model_attempt_open_transition}
    end
  end

  defp open_model_attempt(
         state,
         run_id,
         %{stage: "model_retry_permitted", next_attempt: expected, request: request} = work,
         record
       ) do
    with ^expected <- record["attempt"],
         true <- record["run_id"] == run_id,
         true <- record["turn_id"] == work.turn_id,
         true <- record["operation_id"] == model_operation_id(run_id, work.turn_number),
         true <- record["staged_request_digest"] == request.staged_request_digest do
      next_work =
        work
        |> Map.delete(:next_attempt)
        |> Map.merge(%{stage: "model_attempt_open", model_attempt: expected})

      {:ok, put_pending(state, run_id, next_work), []}
    else
      _other -> {:error, :invalid_model_attempt_open_transition}
    end
  end

  defp open_model_attempt(_state, _run_id, _work, _record),
    do: {:error, :invalid_model_attempt_open_transition}

  # Concept: a steer becomes applied in the same transaction that opens the
  # attempt carrying it, and nowhere else.
  #
  # Technical depth: its exact bytes enter the conversation as a user-role
  # element here, so the record of what was said and the record of what was sent
  # cannot disagree. A steer is never recorded applied unless a committed
  # request actually carried it and an attempt actually opened over it.
  defp apply_staged_steer(state, _run_id, nil), do: {state, []}

  defp apply_staged_steer(state, run_id, applied_steer) do
    case Map.get(state.steer, run_id) do
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
  end

  defp attempt_identity_matches?(record, run_id, work, request) do
    record["run_id"] == run_id and record["turn_id"] == work.turn_id and
      record["operation_id"] == model_operation_id(run_id, work.turn_number) and
      record["attempt"] == work.model_attempt and
      record["staged_request_digest"] == request.staged_request_digest
  end

  # Concept: which termination won is journal order, so a settlement may only
  # state the one the journal already fixed.
  #
  # Technical depth: `owner_loss` is admitted only where neither an abort nor a
  # deadline had already won, because a recovered attempt whose run was already
  # aborted ends as the abort its operator asked for.
  defp settlement_termination_agrees?(state, run_id, work, record) do
    case record["termination"] do
      "abort" -> match?(%{run_id: ^run_id}, state.aborting)
      "deadline" -> Map.get(work, :model_termination) == "deadline"
      "owner_loss" -> no_committed_termination?(state, run_id, work)
      nil -> no_committed_termination?(state, run_id, work)
    end
  end

  defp no_committed_termination?(state, run_id, work) do
    not match?(%{run_id: ^run_id}, state.aborting) and
      Map.get(work, :model_termination) != "deadline"
  end

  defp apply_attempt_settlement(state, run_id, work, %{"next" => "retry"} = record) do
    next_work =
      work
      |> Map.drop([:model_attempt, :model_termination])
      |> Map.merge(%{
        stage: "model_retry_permitted",
        next_attempt: record["attempt"] + 1
      })

    {:ok, put_pending(state, run_id, next_work), []}
  end

  defp apply_attempt_settlement(state, run_id, work, %{"next" => "continue"} = record),
    do: apply_settled_verdict(state, run_id, work, record)

  defp apply_attempt_settlement(state, run_id, work, %{"next" => "terminal"} = record) do
    next_work = Map.merge(work, %{stage: "model_attempt_pending_terminal", settlement: record})

    {:ok, put_pending(state, run_id, next_work), []}
  end

  # Concept: the deferred half of a terminal settlement, applied by the exact
  # terminal row that completes it.
  #
  # Technical depth: a settlement row applied alone installs
  # `model_attempt_pending_terminal` and changes nothing an operator or a
  # projection can see. This is where that verdict finally lands, inside the
  # same transaction as the ending it belongs to, so a page boundary between the
  # two rows exposes no half-applied run.
  defp complete_pending_terminal(state, run_id) do
    case Map.get(state.pending_work, run_id) do
      %{stage: "model_attempt_pending_terminal", settlement: settlement} = work ->
        case apply_settled_verdict(state, run_id, Map.delete(work, :settlement), settlement) do
          {:ok, next, events} -> {:ok, next, Map.get(next.pending_work, run_id), events}
          {:error, reason} -> {:error, reason}
        end

      %{} = work ->
        {:ok, state, work, []}

      _absent ->
        {:error, :invalid_run_terminal_transition}
    end
  end

  # Concept: the settlement's accounting and its conversation are applied
  # together or not at all.
  #
  # Technical depth: the durable reply is read back by key and never rebuilt.
  # Tool generations are resolved from the staged request's own tools rather
  # than retained a second time, so the settlement stays the exact twelve-key
  # record and replay still names the tool each call resolved to.
  defp apply_settled_verdict(state, run_id, work, record) do
    state = apply_attempt_accounting(state, run_id, record["accounting"])

    case {record["conversation"], record["result"]} do
      {"canonical", %{"kind" => "reply", "reply" => reply}} ->
        case normalize_calls(settled_calls(reply), request_generations(work.request)) do
          {:ok, calls} ->
            assistant = %{
              kind: :assistant_message,
              run_id: run_id,
              turn_number: work.turn_number,
              content: reply["text"],
              # Concept: the retained element names each call the way the reply
              # named it.
              #
              # Technical depth: the dispatch queue keys calls by
              # `tool_call_id`, which is the identity the executor boundary
              # binds. The conversation element keeps that member and adds the
              # adapter's own `id` beside it, so a projection reads back the
              # bytes the provider produced rather than a renamed copy of them.
              tool_calls: Enum.map(calls, &Map.put(&1, :id, &1.tool_call_id)),
              stop_reason: if(calls == [], do: "end_turn", else: "tool_use"),
              usage: reply["usage"]
            }

            next_work =
              if calls == [] do
                Map.merge(work, %{stage: "turn_settled", pending_calls: []})
              else
                Map.merge(work, %{stage: "effect_pending", pending_calls: calls})
              end

            next =
              state
              |> append_element(run_id, assistant)
              |> put_pending(run_id, next_work)

            {:ok, next, [assistant_event(state.session_id, run_id, work.turn_id, reply["text"])]}

          :error ->
            {:error, :invalid_model_tool_call}
        end

      _no_canonical_answer ->
        next_work = Map.merge(work, %{stage: "turn_settled", pending_calls: []})
        {:ok, put_pending(state, run_id, next_work), []}
    end
  end

  defp settled_calls(reply) do
    Enum.map(reply["tool_calls"], fn call ->
      %{id: call["id"], name: call["name"], arguments: call["arguments"]}
    end)
  end

  defp request_generations(%{tools: tools}) when is_list(tools) do
    Map.new(tools, fn definition ->
      {Map.get(definition, "name"),
       definition |> LoopexProtocol.ToolDefinition.generation() |> Tuple.to_list()}
    end)
  rescue
    _error -> %{}
  end

  defp request_generations(_request), do: %{}

  # Concept: `estimated` consumes the exact remaining cumulative allowance, not
  # a repeat of one turn's own estimate.
  #
  # Technical depth: ADR 0018 makes the conservative charge run-control truth,
  # so it sets cumulative tokens to the committed budget and adds exactly the
  # difference. Reaching the limit that way is not itself `bound_reached`; the
  # ordinary next pre-staging check remains the selector.
  defp apply_attempt_accounting(state, _run_id, %{"source" => "none"}), do: state

  defp apply_attempt_accounting(state, run_id, %{
         "source" => "reported",
         "input_tokens" => input,
         "output_tokens" => output
       }),
       do: charge_run(state, run_id, input + output, :reported)

  defp apply_attempt_accounting(state, run_id, %{"source" => "estimated"}) do
    budget = state.bounds |> Map.get(run_id, %{}) |> Map.get(:token_budget, 0)
    charged = Map.get(state.charged, run_id, %{tokens: 0, source: nil})
    charge_run(state, run_id, max(budget - charged.tokens, 0), :estimated)
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
  # Concept: a committed context ceiling is read back exactly as it was written.
  #
  # Technical depth: ADR 0017 bounds it to positive unsigned 64-bit so the
  # committed value is always compactly persistable. A record missing it, or
  # carrying a value outside that domain, is unavailable history rather than an
  # invitation to substitute a current process default.
  defp record_context_token_budget(record) do
    case Map.get(record, "context_token_budget") do
      value when is_integer(value) and value > 0 and value <= 18_446_744_073_709_551_615 ->
        {:ok, value}

      _other ->
        {:error, :invalid_context_token_budget_record}
    end
  end

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
    valid =
      Enum.all?(@receipt_job_identity_fields, &(Map.get(receipt, &1) == Map.get(job, &1))) and
        receipt.session_epoch_at_dispatch == job.origin_session_epoch and
        receipt.executor_epoch == job.origin_executor_epoch and
        receipt.executor_identity == job.executor_identity and
        optional_receipt_field_matches?(receipt, :run_deadline_ms, job.run_deadline) and
        effective_deadline_within_run?(receipt, job.run_deadline)

    if valid, do: :ok, else: {:error, :receipt_identity_mismatch}
  end

  defp put_pending(state, run_id, work),
    do: %{state | pending_work: Map.put(state.pending_work, run_id, work)}

  defp encode_plain(value) when value in [nil, true, false], do: value
  defp encode_plain(value) when is_atom(value), do: Atom.to_string(value)

  defp encode_plain(value) when is_binary(value) or is_integer(value) or is_float(value),
    do: value

  defp encode_plain(value) when is_list(value), do: Enum.map(value, &encode_plain/1)

  defp encode_plain(value) when is_map(value) do
    Map.new(value, fn {key, nested} ->
      encoded_key = if is_atom(key), do: Atom.to_string(key), else: key
      {encoded_key, encode_plain(nested)}
    end)
  end

  # Concept: a stream statistic that is not a count is refused before it becomes
  # durable, not after.
  #
  # Technical depth: `progress_count` is the number ADR 0011 closes a complete
  # domain on, and a consumer compares it against what arrived to detect loss.
  # Zero is exact and needs no sentinel; anything below it is not a count.
  defp validate_stream_count(count) when is_integer(count) and count >= 0, do: :ok
  defp validate_stream_count(_count), do: {:error, :invalid_stream_count}

  defp encode_plain_unique(value)
       when is_binary(value) or is_integer(value) or is_float(value) or
              value in [nil, true, false],
       do: {:ok, value}

  defp encode_plain_unique(value) when is_list(value) do
    Enum.reduce_while(value, {:ok, []}, fn nested, {:ok, encoded} ->
      case encode_plain_unique(nested) do
        {:ok, item} -> {:cont, {:ok, [item | encoded]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp encode_plain_unique(value) when is_map(value) and not is_struct(value) do
    Enum.reduce_while(value, {:ok, %{}}, fn {key, nested}, {:ok, encoded} ->
      encoded_key = if is_atom(key), do: Atom.to_string(key), else: key

      with true <- is_binary(encoded_key),
           false <- Map.has_key?(encoded, encoded_key),
           {:ok, item} <- encode_plain_unique(nested) do
        {:cont, {:ok, Map.put(encoded, encoded_key, item)}}
      else
        _other -> {:halt, {:error, :invalid_plain_record}}
      end
    end)
  end

  defp encode_plain_unique(_value), do: {:error, :invalid_plain_record}

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

  # Concept: a job reconstructed from the journal is the same named value the
  # dispatcher built, including the wall instant it was authorized under.
  #
  # Technical depth: `effective_job_deadline` is retained rather than recomputed.
  # Recomputing it on recovery would silently extend a recovered job's authority
  # past the instant its committed intent was bound to, which is exactly the
  # refresh ADR 0016 forbids.
  # Concept: a job reconstructed from the journal is the same named value the
  # dispatcher built, including the wall instant it was authorized under.
  #
  # Technical depth: `effective_job_deadline` is retained rather than recomputed.
  # Recomputing it on recovery would silently extend a recovered job's authority
  # past the instant its committed intent was bound to, which is exactly the
  # refresh ADR 0016 forbids.
  defp decode_job(encoded) do
    fields = Loopex.Executor.job_fields() ++ Loopex.Executor.JobRequest.derived_fields()

    with {:ok, decoded} <- decode_top(encoded, fields) do
      {:ok, struct!(Loopex.Executor.JobRequest, decoded)}
    end
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
    # Concept: the executor's declared periods and programs survive
    # reconstruction where an executor reported them, and their absence is not a
    # malformed receipt.
    #
    # Technical depth: ADR 0009 asks for the cleanup grace to be readable through
    # the session and reported in the run's terminal evidence. The shipped local
    # executor writes it into every receipt and it was dropped here, so a
    # coordinator rebuilding from the journal could not name the period a job ran
    # under and the terminal had nothing to report. They are optional rather than
    # required because the port promises `{:ok, map()}` and says nothing about
    # them: an executor with no operating-system work to bound has no period to
    # declare, and demanding one would refuse a conforming receipt.
    with {:ok, receipt} <- decode_top(encoded, @receipt_required_fields),
         {:ok, outcome} <- decode_receipt_outcome(receipt.outcome),
         :ok <- validate_receipt_output(receipt.output),
         :ok <- validate_stream_count(receipt.progress_count),
         :ok <- validate_non_negative_integer(receipt.observed_at_ms),
         :ok <- validate_child_environment_names(receipt.child_environment_names),
         false <- receipt.provider_credential_present,
         {:ok, artifacts} <- decode_artifacts(receipt.artifacts),
         optional <- decode_optional(encoded, @receipt_optional_fields),
         :ok <- validate_optional_receipt_fields(optional),
         decoded <- Map.merge(optional, %{receipt | outcome: outcome, artifacts: artifacts}),
         :ok <- validate_cleanup_relation(decoded) do
      {:ok, decoded}
    else
      _other -> {:error, :invalid_plain_receipt}
    end
  end

  defp validate_receipt_output(output) when is_binary(output), do: :ok
  defp validate_receipt_output(_output), do: {:error, :invalid_plain_receipt}

  # Concept: environment evidence contains names, never assignments or values.
  # A receipt that says the provider credential reached a child is not an
  # ordinary terminal fact this runtime can safely continue past.
  #
  # Technical depth: Store plain-data validation accepts any binary, including
  # `NAME=secret`, terminal-control text, and the provider key itself. Those
  # values used to be projected into the durable receipt before anything judged
  # their meaning. The closed grammar keeps this field an inventory of names and
  # the separate boolean is admitted only at its credential-free value. Invalid
  # UTF-8 is tested before the Unicode predicate so a hostile binary cannot make
  # receipt validation raise.
  defp validate_child_environment_names(names) when is_list(names) do
    if Enum.all?(names, &valid_child_environment_name?/1),
      do: :ok,
      else: {:error, :invalid_plain_receipt}
  end

  defp validate_child_environment_names(_names), do: {:error, :invalid_plain_receipt}

  defp valid_child_environment_name?(name) when is_binary(name) do
    name != "" and byte_size(name) <= @max_receipt_text_bytes and String.valid?(name) and
      Regex.match?(@environment_name, name) and name != @provider_credential_name and
      not Regex.match?(@unsafe_receipt_text, name)
  end

  defp valid_child_environment_name?(_name), do: false

  defp validate_optional_receipt_fields(optional) do
    validators = [
      cleanup_grace_ms: &validate_non_negative_integer/1,
      cleanup_confirmation: &validate_cleanup_confirmation/1,
      receipt_retention_bound_ms: &validate_retention_bound/1,
      effective_deadline_ms: &validate_positive_integer/1,
      run_deadline_ms: &validate_positive_integer/1,
      process_probe: &validate_receipt_text/1
    ]

    Enum.reduce_while(validators, :ok, fn {field, validator}, :ok ->
      case Map.fetch(optional, field) do
        {:ok, value} ->
          case validator.(value) do
            :ok -> {:cont, :ok}
            {:error, _reason} = error -> {:halt, error}
          end

        :error ->
          {:cont, :ok}
      end
    end)
  end

  defp validate_non_negative_integer(value) when is_integer(value) and value >= 0, do: :ok
  defp validate_non_negative_integer(_value), do: {:error, :invalid_plain_receipt}

  # Concept: whether the job's captured process group was actually confirmed
  # gone is a two-valued fact, and anything else is not an answer.
  #
  # Technical depth: ADR 0016 admits exactly `confirmed` and `unconfirmed`. A
  # third word, a boolean, or an absent-but-present-as-nil value is a receipt
  # this runtime cannot read, and it fails closed rather than being coerced into
  # the safer-looking half.
  defp validate_cleanup_confirmation(value) when value in @receipt_cleanup_confirmations, do: :ok
  defp validate_cleanup_confirmation(_value), do: {:error, :invalid_plain_receipt}

  defp validate_retention_bound(value)
       when is_integer(value) and value >= 1 and value <= @max_cleanup_grace_ms,
       do: :ok

  defp validate_retention_bound(_value), do: {:error, :invalid_plain_receipt}

  # Concept: an unproved cleanup and a settled operation cannot both be true of
  # one job.
  #
  # Technical depth: ADR 0016 keeps cleanup truth independent of operation
  # truth, with exactly one relation between them: an unconfirmed cleanup is
  # conforming only beside `outcome_unknown`. A `completed` receipt claiming its
  # own cleanup was never confirmed asserts a settled effect whose owned group
  # may still be running, so it is refused rather than published.
  defp validate_cleanup_relation(%{cleanup_confirmation: "unconfirmed", outcome: outcome}) do
    if outcome == :outcome_unknown, do: :ok, else: {:error, :invalid_plain_receipt}
  end

  defp validate_cleanup_relation(_receipt), do: :ok

  defp validate_positive_integer(value) when is_integer(value) and value > 0, do: :ok
  defp validate_positive_integer(_value), do: {:error, :invalid_plain_receipt}

  defp validate_receipt_text(value) when is_binary(value) do
    if value != "" and byte_size(value) <= @max_receipt_text_bytes and String.valid?(value) and
         not Regex.match?(@unsafe_receipt_text, value),
       do: :ok,
       else: {:error, :invalid_plain_receipt}
  end

  defp validate_receipt_text(_value), do: {:error, :invalid_plain_receipt}

  defp optional_receipt_field_matches?(receipt, field, expected) do
    case Map.fetch(receipt, field) do
      {:ok, value} -> value == expected
      :error -> true
    end
  end

  defp effective_deadline_within_run?(receipt, run_deadline) do
    case Map.fetch(receipt, :effective_deadline_ms) do
      {:ok, deadline} -> deadline <= run_deadline
      :error -> true
    end
  end

  # Concept: only the bounded declared receipt crosses the journal
  # boundary; an executor's private terms and credentials do not hitchhike.
  #
  # Technical depth: normalize the one atom value the executor contract admits,
  # then normalize atom/binary keys without collisions and validate the complete
  # candidate against the Store's real private-record ceilings before projecting
  # only the declared receipt fields. Validation used to run first, even though
  # the shipped executor returns `outcome` as an atom; every real local receipt
  # was therefore rejected as non-plain while string-valued test doubles passed.
  # The projected receipt is checked against the committed job before the record
  # is built. A malformed or unsupported term therefore becomes an invalid
  # receipt that the coordinator reports unproven instead of an exception that
  # kills the owner. The rescue covers malformed list tails and other terms a
  # host adapter can return despite the callback's map boundary.
  defp canonical_executor_receipt(receipt, job) do
    with {:ok, encoded} <- encode_executor_receipt(receipt),
         :ok <-
           Store.validate_private_record(%{
             "receipt" => encoded,
             kind: "executor_receipt_candidate"
           }),
         projected <-
           Map.take(
             encoded,
             Enum.map(@receipt_required_fields ++ @receipt_optional_fields, &Atom.to_string/1)
           ),
         {:ok, decoded} <- decode_receipt(projected),
         :ok <- receipt_matches_job(decoded, job) do
      {:ok, decoded}
    else
      _other -> {:error, :invalid_executor_receipt}
    end
  rescue
    _exception -> {:error, :invalid_executor_receipt}
  catch
    _kind, _reason -> {:error, :invalid_executor_receipt}
  end

  defp encode_executor_receipt(receipt) do
    case {Map.fetch(receipt, :outcome), Map.fetch(receipt, "outcome")} do
      {{:ok, outcome}, :error} ->
        with {:ok, outcome} <- normalize_executor_outcome(outcome) do
          receipt
          |> Map.put(:outcome, outcome)
          |> normalize_cleanup_confirmation(:cleanup_confirmation)
          |> encode_plain_unique()
        end

      {:error, {:ok, outcome}} ->
        with {:ok, outcome} <- normalize_executor_outcome(outcome) do
          receipt
          |> Map.put("outcome", outcome)
          |> normalize_cleanup_confirmation("cleanup_confirmation")
          |> encode_plain_unique()
        end

      _missing_or_ambiguous ->
        {:error, :invalid_plain_record}
    end
  end

  # Concept: the cleanup fact crosses the journal boundary as the same kind of
  # word the outcome does.
  #
  # Technical depth: ADR 0016 states `cleanup_confirmation` as `confirmed` or
  # `unconfirmed`, and the shipped executor returns those as atoms exactly as it
  # returns its outcome. Plain-record encoding admits no atom, so an unnormalized
  # atom made every real receipt carrying the field unreadable. Only the atom
  # shape is rewritten here; whether the resulting word is one of the two the ADR
  # admits is decided by the validator, so a third atom is refused rather than
  # laundered into a string.
  defp normalize_cleanup_confirmation(receipt, key) do
    case Map.fetch(receipt, key) do
      {:ok, value} when is_atom(value) and not is_nil(value) and not is_boolean(value) ->
        Map.put(receipt, key, Atom.to_string(value))

      _absent_or_already_plain ->
        receipt
    end
  end

  defp normalize_executor_outcome(outcome) when outcome in @receipt_outcomes,
    do: {:ok, Atom.to_string(outcome)}

  defp normalize_executor_outcome(outcome) when is_binary(outcome), do: {:ok, outcome}
  defp normalize_executor_outcome(_outcome), do: {:error, :invalid_plain_record}

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

  defp decode_optional(encoded, fields) do
    Enum.reduce(fields, %{}, fn field, decoded ->
      case Map.fetch(encoded, Atom.to_string(field)) do
        {:ok, value} -> Map.put(decoded, field, value)
        :error -> decoded
      end
    end)
  end

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

    with {:ok, active_run} <- advance_public_projection(scan.active_run, event, expected) do
      anchor_projection =
        if scan.requested_anchor == expected,
          do: {:set, active_run},
          else: scan.anchor_projection

      {:ok,
       %{scan | tail: expected, active_run: active_run, anchor_projection: anchor_projection}}
    end
  end

  # Concept: a run becomes publicly visible when its prompt is admitted, and
  # publicly started only when its first request is staged.
  #
  # Technical depth: ADR 0017's phase machine. A user message from no active run
  # installs `admitted_unstaged` for that event's run; a later steer message for
  # that same run leaves the phase alone; a user message naming another run is
  # invalid. A matching first start advances to `started`, a second start or a
  # start for another run is invalid, and a matching finish clears both for any
  # valid terminal category, including a context refusal, an abort, or owner
  # loss before staging.
  defp advance_public_projection(
         nil,
         %{
           "run_id" => run_id,
           event_sequence: expected,
           event_id: event_id,
           kind: "user.message_appended"
         },
         expected
       )
       when is_binary(run_id) and byte_size(run_id) > 0 and is_binary(event_id),
       do: {:ok, {run_id, "admitted_unstaged"}}

  defp advance_public_projection(
         {run_id, _phase} = active,
         %{
           "run_id" => run_id,
           event_sequence: expected,
           event_id: event_id,
           kind: "user.message_appended"
         },
         expected
       )
       when is_binary(event_id),
       do: {:ok, active}

  defp advance_public_projection(
         {run_id, "admitted_unstaged"},
         %{
           "run_id" => run_id,
           event_sequence: expected,
           event_id: event_id,
           kind: "run.started"
         },
         expected
       )
       when is_binary(event_id),
       do: {:ok, {run_id, "started"}}

  defp advance_public_projection(
         {run_id, _phase},
         %{
           "run_id" => run_id,
           event_sequence: expected,
           event_id: event_id,
           kind: "run.finished"
         },
         expected
       )
       when is_binary(event_id),
       do: {:ok, nil}

  defp advance_public_projection(
         _active_run,
         %{event_sequence: expected, event_id: event_id, kind: kind},
         expected
       )
       when kind in ["run.started", "run.finished", "user.message_appended"] and
              is_binary(event_id),
       do: {:error, :invalid_public_run_transition}

  defp advance_public_projection(
         active_run,
         %{event_sequence: expected, event_id: event_id, kind: kind},
         expected
       )
       when is_binary(event_id) and is_binary(kind),
       do: {:ok, active_run}

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
      }
    ]
  end

  # Concept: a run is publicly started when its first request is actually
  # staged, not when its prompt was admitted.
  #
  # Technical depth: ADR 0017 separates the two so an operator attaching between
  # them can tell an admitted, unstaged run from a started one, and so recovery
  # can validate a later start or a pre-staging finish without inventing an
  # event. Only turn one emits it; later turns re-stage inside a run that is
  # already started.
  defp run_started_events(_session_id, _command_id, _run_id, turn_number)
       when turn_number != 1,
       do: []

  defp run_started_events(session_id, command_id, run_id, _turn_number) do
    [
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
      # A receipt is its own explanation, so this member is present and empty
      # rather than absent: a consumer must not have to tell "no reason" from
      # "this producer omitted the key".
      "reason" => nil,
      "artifacts" => Enum.map(artifacts, &public_artifact/1),
      event_id: stable_id("event-tool-finished", session_id, job.tool_call_id),
      kind: "tool.finished"
    }
  end

  # Concept: the public projection is the whole compact reference and none of the
  # private reason behind it.
  #
  # Technical depth: the three use members are the bounded, digest-derived half
  # of the artifact identity. Omitting them would leave an operator holding a
  # reference that `describe/2` cannot resolve, while inlining the use record
  # itself would put a session, run, operation, and tool-call identifier on the
  # public plane. Every member here is already validated plain data.
  defp public_artifact(reference) do
    %{
      "digest" => reference.digest,
      "media_type" => reference.media_type,
      "size" => reference.size,
      "role" => reference.role,
      "locator" => reference.locator,
      "use_canonicalization_version" => reference.use_canonicalization_version,
      "use_digest" => reference.use_digest,
      "use_locator" => reference.use_locator
    }
  end

  defp run_finished_event(session_id, run_id, outcome, reconciliation_ref, grace),
    do: run_finished_event(session_id, run_id, outcome, reconciliation_ref, grace, nil)

  defp run_terminal_record(state, run_id, proposed, detail) do
    outcome = run_outcome(state, run_id, proposed)

    %{
      "run_id" => run_id,
      "outcome" => outcome,
      "bound" => Map.get(detail, :bound),
      "observed" => Map.get(detail, :observed),
      "declared_limit" => Map.get(detail, :declared_limit),
      "accounting_source" => Map.get(detail, :accounting_source),
      # Concept: an ending that failed names the bounded category that failed
      # it, and never the provider's own words.
      #
      # Technical depth: ADR 0018 fixes exactly two categories, so an operator
      # renderer can say which one without a raw provider reason ever reaching a
      # retained, public, or rendered plane.
      "reason" => Map.get(detail, :reason),
      "reconciliation_ref" => terminal_reference(state, run_id, outcome, detail),
      # Concept: an ending that stopped work says what bounded the stopping.
      #
      # Technical depth: ADR 0009 requires the declared cleanup grace to be
      # reported in the terminal outcome's evidence, so an operator can tell a
      # clean cooperative stop from a forced kill that was confirmed and from a
      # termination that could not be confirmed at all. It is the session's own
      # declared value, which is what ADR 0009 makes it, and the same value the
      # composed executor is handed -- so the terminal names the period the
      # cleanup actually ran under. Reading it back off a receipt instead left
      # every ending that produced no receipt reporting `nil`: an abort admitted
      # before any executor answered, a run stopped between turns, and every
      # recovery, which are precisely the endings an operator needs the period
      # for.
      "cleanup_grace_ms" => state.cleanup_grace_ms,
      # Concept: an ending names the command that asked for it, where one did.
      #
      # Technical depth: the abort's admission and its outcome are two records
      # now, and without this nothing joins them. It used to be carried by the
      # abort's own `run.finished`, which no longer exists.
      "command_id" => aborting_command(state, run_id),
      kind: "run_terminal_committed"
    }
  end

  defp run_finished_event(session_id, run_id, outcome, reconciliation_ref, grace, command_id) do
    %{
      "run_id" => run_id,
      "outcome" => outcome,
      "reconciliation_ref" => reconciliation_ref,
      "cleanup_grace_ms" => grace,
      "command_id" => command_id,
      event_id: stable_id("event-run-finished", session_id, run_id),
      kind: "run.finished"
    }
  end

  defp aborting_command(%{aborting: %{run_id: run_id, command_id: command_id}}, run_id),
    do: command_id

  defp aborting_command(_state, _run_id), do: nil

  @doc """
  ## Concept

  The run an operator aborted whose ending has not been committed.

  ## Technical depth

  `nil` unless an abort was durably admitted and its terminal has not landed.
  The coordinator reads it twice: to stop scheduling for that run, and on
  recovery to tell "nobody asked to stop" from "somebody asked and this owner
  never wrote down what happened". The second must commit `outcome_unknown`,
  because the cleanup may have run, may have half run, and cannot be proved
  either way -- exactly the state that must never be blindly retried.
  """
  @spec aborting_run(t()) :: binary() | nil
  def aborting_run(%__MODULE__{aborting: %{run_id: run_id}}), do: run_id
  def aborting_run(%__MODULE__{}), do: nil

  # Concept: `outcome_unknown` outranks whatever asked the run to stop.
  #
  # Technical depth: this is the single place ADR 0009's run-outcome table is
  # read, and the table's third row is unconditional — "one `outcome_unknown`
  # among the owned operations finishes the run `outcome_unknown`, whatever
  # asked it to stop." An abort, a reached deadline, a declared bound and a
  # model that stopped on its own therefore all arrive at the same answer here
  # rather than each carrying its own copy of the rule. The defect this closes
  # is exactly what a second copy costs: cancellation derived the run outcome
  # from what cleanup achieved alone, so an abort landing on a run that already
  # held an unprovable effect published `cancelled` — a report an operator acts
  # on by doing nothing — over an effect nobody can account for.
  defp run_outcome(state, run_id, proposed) do
    if unproven_effect?(state, run_id), do: "outcome_unknown", else: proposed
  end

  # An ending that says the effect's truth is unknown must name what to
  # reconcile against. The reference is derived rather than required from the
  # caller, because the caller that proposed `completed` did not know its
  # outcome was about to be outranked.
  defp terminal_reference(state, run_id, "outcome_unknown", detail),
    do: Map.get(detail, :reconciliation_ref) || reconciliation_reference(state, run_id)

  defp terminal_reference(_state, _run_id, _outcome, detail),
    do: Map.get(detail, :reconciliation_ref)

  defp reconciliation_reference(state, run_id),
    do: stable_id("reconciliation", state.session_id, run_id)

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
          with {:ok, content} <- fetch_binary(command, :content) do
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
               {:ok, content} <- fetch_binary(command, :content) do
            {:ok, %{type: :steer, command_id: command_id, run_id: run_id, content: content}}
          else
            _other -> {:error, :invalid_command}
          end

        :follow_up ->
          with {:ok, content} <- fetch_binary(command, :content) do
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

  defp fetch_binary(command, key) when key in [:command_id, :run_id] do
    case fetch(command, key) do
      {:ok, value}
      when is_binary(value) and byte_size(value) > 0 and byte_size(value) <= @max_command_bytes ->
        {:ok, value}

      _other ->
        {:error, :invalid_command}
    end
  end

  # Concept: how much an operator may say is decided by whether it can be
  # written down, not by a second ceiling next to that one.
  #
  # Technical depth: ADR 0017 preserves the existing content domain and makes
  # representability an explicit durable admission result instead. Content is
  # still required to be a non-empty binary, but its size is decided by the
  # exact command-record measurement, which refuses an over-large body by name
  # and retains a compact refusal rather than collapsing it into the same
  # `invalid_command` a malformed request gets.
  defp fetch_binary(command, key) do
    case fetch(command, key) do
      {:ok, value} when is_binary(value) and byte_size(value) > 0 -> {:ok, value}
      _other -> {:error, :invalid_command}
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

  # Concept: a receipt is checked against the request it sits next to, never
  # against itself.
  #
  # Technical depth: an internally consistent receipt whose arithmetic balances
  # can still describe a different message set, a different tool projection, a
  # different descriptor order, or a different session source binding. ADR 0017
  # therefore makes validation record-relative: the expected descriptor sequence
  # is reconstructed from the exact final request members and the reducer's own
  # session, steer, and project bindings, and the retained list must equal it
  # member for member. Every cost, digest, bucket, total, and the ordered
  # descriptor digest are then recomputed rather than trusted.
  defp validate_context_receipt(state, record, request, run_id, applied_steer) do
    receipt = Map.get(record, "context_receipt")

    with :ok <- validate_receipt_shell(receipt),
         {:ok, sources} <- expected_context_sources(state, receipt, run_id, applied_steer),
         {:ok, expected} <- expected_context_blocks(request, sources),
         true <- Map.get(receipt, "blocks") == expected,
         :ok <- validate_receipt_totals(receipt, expected) do
      :ok
    else
      {:error, reason} -> {:error, reason}
      _mismatch -> {:error, :invalid_context_receipt}
    end
  end

  defp validate_receipt_shell(receipt) when is_map(receipt) do
    with true <- Enum.sort(Map.keys(receipt)) == @context_receipt_keys,
         true <- Map.get(receipt, "provider_identity") == "loopex.context.reference",
         true <- Map.get(receipt, "provider_revision") == 2,
         true <- Map.get(receipt, "transformer_identity") == nil,
         true <- Map.get(receipt, "transformer_revision") == nil,
         true <- Map.get(receipt, "selector_identity") == nil,
         true <- Map.get(receipt, "selector_revision") == nil,
         true <- Map.get(receipt, "token_estimator") == Bounds.estimator(),
         true <-
           Map.get(receipt, "descriptor_canonicalization_version") ==
             @descriptor_canonicalization_version,
         true <- Map.get(receipt, "context_record_byte_ceiling") == Store.max_item_bytes(),
         true <- positive_uint64?(Map.get(receipt, "context_token_budget")),
         :ok <- validate_project_receipt(Map.get(receipt, "project_resource")) do
      :ok
    else
      {:error, reason} -> {:error, reason}
      _invalid -> {:error, :invalid_context_receipt}
    end
  end

  defp validate_receipt_shell(_receipt), do: {:error, :invalid_context_receipt}

  # Concept: the three provenance buckets always sum back to the one outer
  # total.
  #
  # Technical depth: recomputed from the reconstructed descriptor list, so a
  # receipt whose own arithmetic is self-consistent but describes a different
  # list is still refused. `provider_estimated_tokens` is the outer token total
  # and never an independently retained number.
  defp validate_receipt_totals(receipt, blocks) do
    totals = expected_context_totals(blocks)

    if Map.get(receipt, "totals") == totals and
         Map.get(receipt, "provider_estimated_tokens") == totals["token_cost"] and
         Map.get(receipt, "ordered_descriptor_digest") == ordered_descriptor_digest(blocks) do
      :ok
    else
      {:error, :invalid_context_receipt}
    end
  end

  defp expected_context_blocks(request, sources) do
    tools = Enum.map(request.tools, &ToolDefinition.model_facing/1)
    members = request.messages ++ tools

    if length(request.messages) == length(sources) do
      {:ok,
       members
       |> Enum.zip(sources ++ Enum.map(request.tools, &expected_tool_source/1))
       |> Enum.map(fn {member, source} ->
         bytes = Canonical.encode(member)

         Map.merge(source, %{
           "content_digest" => Canonical.digest_bytes(bytes),
           "byte_cost" => byte_size(bytes),
           "token_cost" => Bounds.estimate(bytes)
         })
       end)}
    else
      {:error, :invalid_context_receipt}
    end
  end

  defp expected_tool_source(tool) do
    context_source(
      %{
        "kind" => "tool_definition",
        "tool_id" => Map.fetch!(tool, "tool_id"),
        "tool_version" => Map.fetch!(tool, "tool_version"),
        "definition_digest" => ToolDefinition.definition_digest(tool)
      },
      "system"
    )
  end

  # Concept: session and steer identities come from the reducer's own committed
  # lineage, not from the receipt being checked.
  #
  # Technical depth: the elements read here are the ones committed before this
  # request row, which is exactly the set the staging owner projected, and the
  # steer is the one this record says it applied. A receipt that renames a run,
  # command, turn, or call therefore stops matching even when its own digest was
  # recomputed to agree with the rename.
  defp expected_context_sources(state, receipt, run_id, applied_steer) do
    elements = Map.get(state.conversation, run_id, [])

    steer =
      case applied_steer && Map.get(state.steer, run_id) do
        %{command_id: ^applied_steer} ->
          [
            context_source(
              %{
                "kind" => "session_steer",
                "run_id" => run_id,
                "command_id" => applied_steer
              },
              "session"
            )
          ]

        _absent ->
          []
      end

    {:ok,
     [context_source(%{"kind" => "system", "identity" => "loopex.system.v1"}, "system")] ++
       expected_project_sources(Map.get(receipt, "project_resource")) ++
       Enum.map(Conversation.session_entries(elements), fn {reference, _message} ->
         context_source(reference, "session")
       end) ++ steer}
  end

  defp expected_project_sources(%{
         "disposition" => "staged",
         "detail" => %{
           "workspace_ref" => workspace_ref,
           "manifest_digest" => manifest_digest,
           "entries" => entries
         }
       })
       when is_list(entries) do
    Enum.map(entries, fn entry ->
      context_source(
        %{
          "kind" => "project_resource",
          "workspace_ref" => workspace_ref,
          "manifest_digest" => manifest_digest,
          "relative_label" => Map.get(entry, "relative_label")
        },
        "project_resource"
      )
    end)
  end

  defp expected_project_sources(_declined), do: []

  defp context_source(source_reference, provenance_class) do
    trust_class =
      case provenance_class do
        "system" -> "host_owned_trusted_brain_content"
        "session" -> "session_owned_durable_truth"
        "project_resource" -> "untrusted_behavior_shaping_data"
      end

    %{
      "source_reference" => source_reference,
      "provenance_class" => provenance_class,
      "trust_class" => trust_class
    }
  end

  defp expected_context_totals(blocks) do
    by_provenance =
      Map.new(~w(system session project_resource), fn provenance ->
        {provenance,
         sum_context_costs(Enum.filter(blocks, &(&1["provenance_class"] == provenance)))}
      end)

    Map.put(sum_context_costs(blocks), "by_provenance", by_provenance)
  end

  defp sum_context_costs(blocks) do
    Enum.reduce(blocks, %{"byte_cost" => 0, "token_cost" => 0}, fn block, totals ->
      %{
        "byte_cost" => totals["byte_cost"] + block["byte_cost"],
        "token_cost" => totals["token_cost"] + block["token_cost"]
      }
    end)
  end

  # Concept: the ordered descriptor list is bound by one digest, reproducible
  # only from the exact framing.
  #
  # Technical depth: domain byte, zero separator, then each descriptor's
  # eight-byte unsigned big-endian canonical length followed by its canonical
  # bytes. Reordering two descriptors, omitting a length, or changing one
  # descriptor changes the digest, and no aggregate encoding of the list is
  # allocated to compute it.
  defp ordered_descriptor_digest(blocks) do
    blocks
    |> Enum.reduce(
      :crypto.hash_update(:crypto.hash_init(:sha256), @descriptor_digest_domain <> <<0>>),
      fn block, context ->
        bytes = Canonical.encode(block)

        context
        |> :crypto.hash_update(<<byte_size(bytes)::unsigned-big-integer-size(64)>>)
        |> :crypto.hash_update(bytes)
      end
    )
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  # Concept: the project receipt is a closed shape, not an open detail map.
  #
  # Technical depth: ADR 0017 replaces ADR 0010's open map with exactly four
  # outer members and one exact detail shape per disposition. An unknown or
  # missing member in either is invalid history rather than something a later
  # reader is expected to ignore.
  defp validate_project_receipt(
         %{
           "class" => "project_resource",
           "receipt_revision" => 2,
           "disposition" => disposition,
           "detail" => detail
         } = receipt
       )
       when is_map(detail) do
    if map_size(receipt) == 4 and valid_project_detail?(disposition, detail) do
      :ok
    else
      {:error, :invalid_project_receipt}
    end
  end

  defp validate_project_receipt(_receipt), do: {:error, :invalid_project_receipt}

  defp valid_project_detail?("no_manifest", detail), do: detail == %{}

  defp valid_project_detail?("staged", detail),
    do:
      exact_keys?(detail, ~w(decision_source entries manifest_digest workspace_ref)) and
        is_list(Map.get(detail, "entries"))

  defp valid_project_detail?("manifest_rejected", detail),
    do: exact_keys?(detail, ~w(label reason))

  defp valid_project_detail?("over_limit", detail),
    do: exact_keys?(detail, ~w(dimension label limit observed))

  defp valid_project_detail?("no_decision", detail),
    do: exact_keys?(detail, ~w(manifest_digest))

  defp valid_project_detail?("binding_changed", detail),
    do: exact_keys?(detail, ~w(decision_manifest_digest expected_manifest_digest reason))

  defp valid_project_detail?(disposition, detail)
       when disposition in ["context_token_budget", "context_record_bytes"],
       do: exact_keys?(detail, ~w(dimension limit observed))

  defp valid_project_detail?(_disposition, _detail), do: false

  defp exact_keys?(map, keys), do: Enum.sort(Map.keys(map)) == keys

  defp positive_uint64?(value),
    do: is_integer(value) and value > 0 and value <= 18_446_744_073_709_551_615

  @doc false
  @spec propose_deadline_failure(t(), binary(), binary()) :: {:ok, proposal()} | {:error, term()}
  def propose_deadline_failure(%__MODULE__{} = state, run_id, category)
      when is_binary(run_id) and is_binary(category) do
    work = Map.get(state.pending_work, run_id, %{turn_number: 1})
    turn_id = stable_id("turn", run_id, next_turn_number(work))

    failure = %{
      "run_id" => run_id,
      "turn_id" => turn_id,
      "category" => category,
      kind: "deadline_staging_failed_v1"
    }

    terminal =
      state
      |> run_terminal_record(run_id, "failed", %{})
      |> Map.put("failure", deadline_failure())

    internal_proposal(state, stable_id("deadline-failure", run_id, turn_id), [failure, terminal])
  end

  @doc false
  @spec propose_context_refusal(t(), binary(), map()) :: {:ok, proposal()} | {:error, term()}
  def propose_context_refusal(%__MODULE__{} = state, run_id, refusal)
      when is_binary(run_id) and is_map(refusal) do
    terminal =
      state
      |> run_terminal_record(run_id, "failed", %{})
      |> Map.put("failure", context_failure(refusal))

    internal_proposal(
      state,
      stable_id("context-refusal", run_id, Map.fetch!(refusal, "turn_id")),
      [refusal, terminal]
    )
  end

  # Concept: the four fields an operator can act on, plus the one fact that
  # makes the ending final.
  #
  # Technical depth: ADR 0017 fixes this projection at exactly five members and
  # makes it exclusive to a failed context terminal. It copies the refusal's own
  # committed observations rather than deriving new ones, so the private
  # terminal, the public event, and the retained receipt cannot disagree.
  defp deadline_failure,
    do: %{"category" => "deadline_preflight_failed", "retryable" => false}

  defp context_failure(refusal) do
    %{
      "category" => Map.fetch!(refusal, "category"),
      "retryable" => false,
      "dimension" => Map.fetch!(refusal, "dimension"),
      "observed" => Map.fetch!(refusal, "observed"),
      "limit" => Map.fetch!(refusal, "limit")
    }
  end

  defp validate_context_refusal(state, refusal) do
    run_id = Map.get(refusal, "run_id")
    work = Map.get(state.pending_work, run_id)

    with true <- Enum.sort(Map.keys(refusal)) == @context_refusal_keys,
         true <- run_id == state.active_run_id,
         %{stage: stage} <- work,
         true <- stage in ["model_pending", "turn_settled"],
         true <- Map.get(refusal, "turn_id") == stable_id("turn", run_id, next_turn_number(work)),
         true <- Map.get(refusal, "category") == "context_budget_exceeded",
         true <- Map.get(refusal, "token_estimator") == Bounds.estimator(),
         true <-
           Map.get(refusal, "descriptor_canonicalization_version") ==
             @descriptor_canonicalization_version,
         true <- Map.get(refusal, "context_record_byte_ceiling") == Store.max_item_bytes(),
         true <-
           Map.get(refusal, "context_token_budget") == Map.get(state.context_budgets, run_id),
         true <- Map.get(refusal, "project_disposition") in @context_project_dispositions,
         true <- valid_descriptor_counts?(refusal),
         true <- valid_context_dimension?(refusal) do
      :ok
    else
      _invalid -> {:error, :invalid_context_refusal}
    end
  end

  defp valid_descriptor_counts?(refusal) do
    Enum.all?(
      ~w(system_message_count session_message_count steer_message_count tool_definition_count
         provider_estimated_tokens),
      &(is_integer(Map.get(refusal, &1)) and Map.get(refusal, &1) >= 0)
    ) and is_binary(Map.get(refusal, "ordered_descriptor_digest"))
  end

  # Concept: each dimension admits only the relations its own preimage makes
  # derivable.
  #
  # Technical depth: recovery has no descriptor bodies and no rejected candidate
  # from which to recompute a refusal, so it validates the relations that hold
  # by construction and treats the rest as committed observations the Store
  # transaction digest already protects. `record_byte_cost` is non-nil for the
  # byte dimension alone, because the token and structural dimensions are
  # decided before any record is constructed.
  defp valid_context_dimension?(%{
         "dimension" => "context_tokens",
         "observed" => observed,
         "limit" => limit,
         "provider_estimated_tokens" => estimated,
         "context_token_budget" => budget,
         "record_byte_cost" => nil
       }),
       do: observed == estimated and limit == budget and observed > limit

  defp valid_context_dimension?(%{
         "dimension" => "context_record_bytes",
         "observed" => observed,
         "limit" => limit,
         "record_byte_cost" => cost
       }),
       do: observed == cost and limit == 65_536 and observed > limit

  defp valid_context_dimension?(%{
         "dimension" => "context_record_depth",
         "observed" => observed,
         "limit" => limit,
         "record_byte_cost" => nil
       }),
       do: observed == 13 and limit == 12

  defp valid_context_dimension?(%{
         "dimension" => "context_record_cardinality",
         "observed" => observed,
         "limit" => limit,
         "record_byte_cost" => nil
       }),
       do: observed == 1_025 and limit == 1_024

  defp valid_context_dimension?(%{
         "dimension" => "system_class_tokens",
         "observed" => observed,
         "limit" => limit,
         "provider_estimated_tokens" => estimated,
         "record_byte_cost" => nil
       }),
       do: limit == 1_000 and observed >= limit and observed <= estimated

  defp valid_context_dimension?(_refusal), do: false

  # Concept: the terminal row is what makes the refusal real.
  #
  # Technical depth: the marker installed by the first row is consumed here and
  # both records apply as one semantic unit. A failed context terminal without a
  # pending marker, a marker whose refusal names another run, or a terminal
  # whose failure projection disagrees with the retained refusal is invalid
  # history rather than authority to abandon a run. Every other outcome must
  # arrive with no marker pending at all.
  defp consume_context_refusal(
         %{context_refusal: %{run_id: marked, failure: failure}} = state,
         run_id,
         "failed",
         record
       ) do
    if marked == run_id and Map.get(record, "failure") == failure do
      {:ok, %{state | context_refusal: nil}, failure}
    else
      {:error, :invalid_context_refusal_pair}
    end
  end

  # Concept: a run can fail for a reason that is not a context refusal.
  #
  # Technical depth: ADR 0018 adds terminal model-call failure, which ends a run
  # `failed` with a bounded category and no refusal marker. A `failed` terminal
  # is therefore paired with a refusal only when one was actually admitted; one
  # carrying a refusal projection without its marker, or a marker without its
  # projection, is still invalid history.
  defp consume_context_refusal(%{context_refusal: nil} = state, _run_id, "failed", record) do
    if Map.has_key?(record, "failure"),
      do: {:error, :invalid_context_refusal_pair},
      else: {:ok, state, nil}
  end

  defp consume_context_refusal(%{context_refusal: nil} = state, _run_id, outcome, record)
       when outcome != "failed" do
    if Map.has_key?(record, "failure"),
      do: {:error, :invalid_run_terminal_transition},
      else: {:ok, state, nil}
  end

  defp consume_context_refusal(_state, _run_id, _outcome, _record),
    do: {:error, :invalid_context_refusal_pair}

  # Concept: a command is only accepted if every durable fact it makes reachable
  # can actually be written down.
  #
  # Technical depth: ADR 0017 keeps the three bound domains as unbounded positive
  # integers, so an operator may name a value that is semantically valid and
  # still produces a terminal no Store item can hold. Rather than narrowing the
  # domain, the exact accepted record, the exact unstamped event deterministic
  # promotion emits, and every deterministic future bound terminal are measured
  # before the transaction is proposed. Measurement uses the same shared Store
  # sizer the transaction itself will use, so admission and commit cannot
  # disagree, and no giant candidate is ever encoded to learn it is too large.
  defp preflight_command(state, record, events, run_id) do
    with :ok <-
           preflight_candidate(:record, record, "command_record_bytes", command_candidate(record)),
         :ok <- preflight_events(events, record),
         :ok <- preflight_future_bounds(state, record, run_id) do
      :ok
    end
  end

  defp command_candidate(%{"command_type" => type}), do: "#{type}_record"

  # Technical depth: prompt's immediate user-message event is strictly dominated
  # by the accepted record that carries the same content plus more, so it is
  # measured as defence in depth but can never be the selected refusal. Only the
  # follow-up's deterministically promoted event is independently reachable.
  defp preflight_events(events, %{"command_type" => "follow_up"}) do
    Enum.reduce_while(events, :ok, fn event, :ok ->
      case preflight_candidate(
             :event,
             event,
             "command_event_bytes",
             "follow_up_user_message_event"
           ) do
        :ok -> {:cont, :ok}
        refusal -> {:halt, refusal}
      end
    end)
  end

  defp preflight_events(events, _record) do
    Enum.reduce_while(events, :ok, fn event, :ok ->
      case Store.normalize_and_measure_item(:event, event) do
        {:ok, _normalized, bytes} when bytes <= 65_536 -> {:cont, :ok}
        _other -> {:halt, {:error, :undominated_command_event}}
      end
    end)
  end

  defp preflight_candidate(plane, candidate, dimension, name) do
    case Store.normalize_and_measure_item(plane, candidate) do
      {:ok, _normalized, bytes} when bytes <= 65_536 -> :ok
      {:ok, _normalized, bytes} -> {:refused, dimension, name, bytes}
      {:error, reason} -> {:error, reason}
    end
  end

  # Concept: the conservative worst case of every bound this run can reach.
  #
  # Technical depth: `max_turns` reserves its own committed value. `token_budget`
  # reserves the largest one-turn overshoot after a call admitted with one token
  # remaining, because each complete provider usage member is a non-negative
  # unsigned 64-bit integer. `deadline_ms` reserves the maximum supported
  # absolute clock instant, not the configured duration, because that is what the
  # terminal actually carries. Each bound is measured on both planes and across
  # every legal accounting source, since a later provider result can lawfully
  # change the source without changing the run identity or the bound.
  defp preflight_future_bounds(_state, %{"command_type" => "steer"}, _run_id), do: :ok

  defp preflight_future_bounds(state, record, run_id) do
    max_turns = Map.get(record, "max_turns")
    token_budget = Map.get(record, "token_budget")

    if is_integer(max_turns) and is_integer(token_budget) do
      [
        {"max_turns", max_turns, max_turns},
        {"token_budget", token_budget, token_budget - 1 + 2 * @uint64_max},
        {"deadline", @uint64_max, @uint64_max}
      ]
      |> Enum.reduce_while(:ok, fn bound, :ok ->
        case preflight_bound(state, run_id, bound) do
          :ok -> {:cont, :ok}
          refusal -> {:halt, refusal}
        end
      end)
    else
      :ok
    end
  end

  defp preflight_bound(state, run_id, {bound, declared_limit, observed}) do
    [{:record, "private_terminal"}, {:event, "public_finish"}]
    |> Enum.reduce_while(:ok, fn {plane, suffix}, :ok ->
      candidate =
        Enum.max_by(
          Enum.map([nil, "reported", "estimated"], fn source ->
            future_bound_candidate(state, plane, run_id, bound, declared_limit, observed, source)
          end),
          &bound_candidate_size/1
        )

      case preflight_candidate(
             plane,
             candidate,
             "future_bound_record_bytes",
             "#{bound}_#{suffix}"
           ) do
        :ok -> {:cont, :ok}
        refusal -> {:halt, refusal}
      end
    end)
  end

  defp bound_candidate_size(candidate) do
    case Store.normalize_and_measure_item(
           if(Map.has_key?(candidate, :event_id), do: :event, else: :record),
           candidate
         ) do
      {:ok, _normalized, bytes} -> bytes
      {:error, _reason} -> 0
    end
  end

  defp future_bound_candidate(state, :record, run_id, bound, declared_limit, observed, source) do
    %{
      "run_id" => run_id,
      "outcome" => "bound_reached",
      "bound" => bound,
      "observed" => observed,
      "declared_limit" => declared_limit,
      "accounting_source" => source,
      "reconciliation_ref" => nil,
      "cleanup_grace_ms" => state.cleanup_grace_ms,
      "command_id" => nil,
      kind: "run_terminal_committed"
    }
  end

  defp future_bound_candidate(state, :event, run_id, bound, declared_limit, observed, source) do
    %{
      "run_id" => run_id,
      "outcome" => "bound_reached",
      "reconciliation_ref" => nil,
      "cleanup_grace_ms" => state.cleanup_grace_ms,
      "command_id" => nil,
      "bound" => bound,
      "observed" => observed,
      "declared_limit" => declared_limit,
      "accounting_source" => source,
      event_id: stable_id("event-run-finished", state.session_id, run_id),
      kind: "run.finished"
    }
  end

  # Concept: an oversized command mutates nothing and says exactly which
  # candidate it could not have written.
  #
  # Technical depth: the compact nine-key refusal carries no command body and no
  # resolved giant integer, is itself proved representable before it is proposed,
  # starts no run, model task, executor job, effect, or queue work, and emits no
  # public event. Replay derives the same answer from the retained record before
  # any current default or run state is consulted.
  defp command_too_large(state, command, digest, type, dimension, candidate, observed) do
    record = %{
      "command_id" => command.command_id,
      "command_digest" => digest,
      "command_type" => type,
      "admission" => "rejected_durable_candidate_bytes",
      "dimension" => dimension,
      "candidate" => candidate,
      "observed" => observed,
      "limit" => 65_536,
      kind: "command_admission_refused_v1"
    }

    reply = {:error, {:command_admission_too_large, dimension, candidate, observed, 65_536}}
    build_proposal(state, command.command_id, record, [], reply)
  end
end
