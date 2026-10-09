defmodule Loopex.Runtime.SessionState do
  @moduledoc """
  ## Concept

  The pure durable state and command transition for a session. It rebuilds
  the current owner, command admissions, one active run, pending model intent,
  and public projection from Store-stamped history without performing IO.

  ## Technical depth

  Replays require consecutive journal and public-event positions. A command ID
  binds versioned canonical bytes: exact repetition returns the retained
  admission, changed bytes conflict, and a distinct prompt while a run is active
  commits one durable rejection instead of starting work. Proposed state is not
  authoritative until the Store receipt is admitted by runtime control's
  current-owner post-commit fence.

  New tool-event record variants bind opaque IDs to session/run/turn/call.
  The effect-intent, executor-receipt, tool-result and outcome-unknown families
  use `_v2`; question response, expiry and question-cancelling abort variants
  select the same recipe. Their payload members and public event members remain
  unchanged. Superseded kinds refuse on replay; current records and retained
  events are never rewritten.

  Automatic maintenance admission retains the run's staging identity, bounds,
  frozen summarizer configuration and fixed preparation cutoff. Admission alone
  opens no provider attempt, changes no conversation and publishes no event.
  """

  @max_command_bytes 65_536

  @typedoc """
  ## Concept

  The recovered durable projection owned by one current session coordinator.

  ## Technical depth

  `commands` binds canonical command digests to stable admission responses.
  `pending_work` contains plain work intents derived from committed admissions.
  The session coordinator dispatches them only after the owner's durable fence.
  `maintenance_episodes` retains frozen maintenance admissions;
  `active_maintenance` blocks ordinary model staging until that episode settles.

  `run_order` retains admission and promotion order reconstructed from history.
  `conversation` holds the committed elements of each run, which
  `Loopex.Conversation` projects into the message list a turn stages.
  `conversation_record_sources` binds each element's source to the complete
  normalized original record's digest, cost and journal position. It retains no
  record copies and is reconstructed alongside conversation during replay.
  `bounds`
  holds each run's declared bounds exactly as they were committed at admission
  or promotion, and `charged` accumulates that run's token charge with the
  source that produced it.

  `session_options` retains the exact normalized genesis options, without
  interpreting a host's workspace binding or treating it as authority.
  `configuration`, `tool_selection` and `policy_defer_mode` retain v3 genesis
  truth. Recovery requires complete current genesis and never supplies missing
  settings from the live host.
  """
  @context_receipt_keys Enum.sort(~w(
                          blocks continuation_cost context_record_byte_ceiling context_token_budget
                          descriptor_canonicalization_version ordered_descriptor_digest
                          project_resource provider_estimated_tokens provider_identity
                          provider_revision record_byte_cost selector_identity
                          selector_revision token_estimator totals transformer_identity
                          transformer_revision
  ))
  @resource_context_receipt_keys Enum.sort(["resource_packs" | @context_receipt_keys])
  @resource_pack_header_keys Enum.sort(~w(version manifest_digest selection_digest status blocks))
  @resource_pack_row_keys Enum.sort(~w(pack file status))
  @resource_pack_header_bytes 8_192
  @resource_pack_max_rows 37
  @resource_catalog_index 64
  @resource_catalog_bytes 16_384
  @resource_instruction_bytes 65_536
  @resource_support_bytes 16_384
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
  @context_refusal_v2_keys Enum.sort(
                             (@context_refusal_keys -- ~w(category dimension observed limit)) ++
                               ~w(failure configuration_version episode_id targets projection_state measurement_scope)
                           )
  @context_refusal_optional_counts ~w(project_resource_count resource_pack_count)
  @context_refusal_v2_frozen_keys Enum.sort(
                                    @context_refusal_v2_keys ++ @context_refusal_optional_counts
                                  )

  alias Loopex.ArtifactStore
  alias Loopex.Bounds
  alias Loopex.Conversation
  alias Loopex.Interaction
  alias Loopex.ResourcePack
  alias Loopex.Runtime.ContextAdmission
  alias Loopex.Runtime.ArtifactPreparation
  alias Loopex.Runtime.ProviderAttempt
  alias Loopex.Runtime.MaintenanceConfiguration
  alias Loopex.Runtime.SessionGenesis
  alias Loopex.Runtime.SessionConfiguration
  alias Loopex.Runtime.Instructions
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
          session_options: map() | nil,
          configuration: map() | nil,
          tool_selection: map() | nil,
          policy_defer_mode: binary(),
          event_sequence: non_neg_integer(),
          active_run_id: binary() | nil,
          commands: map(),
          pending_work: map(),
          conversation: map(),
          conversation_record_sources: map(),
          artifact_sources: map(),
          tool_result_sources: map(),
          artifact_preparations: map(),
          checkpoints: map(),
          active_checkpoint: binary() | nil,
          compacted_sources: MapSet.t(),
          maintenance_episodes: map(),
          active_maintenance: binary() | nil,
          maintenance_terminal: map() | nil,
          pending_compact: map() | nil,
          prepared_tool_results: map(),
          run_order: [binary()],
          bounds: map(),
          context_budgets: map(),
          run_configurations: map(),
          context_refusal: map() | nil,
          deadlines: map(),
          steer: map(),
          follow_up: map() | nil,
          resources: map() | nil,
          run_resources: map(),
          charged: map(),
          run_usage: map(),
          interactions: map(),
          open_interaction: binary() | nil,
          expected_events: [map()]
        }

  defstruct session_id: nil,
            owner_epoch: 0,
            owner_incarnation_id: nil,
            owner_transaction_id: nil,
            journal_version: 0,
            session_options: nil,
            configuration: nil,
            tool_selection: nil,
            policy_defer_mode: "admit",
            event_sequence: 0,
            active_run_id: nil,
            commands: %{},
            pending_work: %{},
            conversation: %{},
            # Concept: summaries bind complete originals even when projection omits data.
            # Technical depth: replay derives one fixed-size digest/cost/position
            # per conversation source from the owning normalized record. Queued
            # inputs retain admission provenance when they are later promoted;
            # synthetic terminal results bind their actual terminal record.
            conversation_record_sources: %{},
            # Concept: artifact membership comes from this session's committed receipts.
            # Technical depth: this derived index contains full references and
            # canonical source-payload digests, never object contents or handles.
            artifact_sources: %{},
            # Concept: preparation retains receipt provenance without changing it.
            # Technical depth: this replay-derived index holds the original
            # record digest/cost and ADR 0015's five use labels, not output copies.
            tool_result_sources: %{},
            artifact_preparations: %{},
            # Concept: checkpoints change projection while original facts remain readable.
            # Technical depth: replay validates each whole-unit cut, then indexes
            # exact source identities. Journal positions cannot identify a cut:
            # queued inputs may have older admission positions than later units.
            checkpoints: %{},
            active_checkpoint: nil,
            compacted_sources: MapSet.new(),
            maintenance_episodes: %{},
            active_maintenance: nil,
            maintenance_terminal: nil,
            # Concept: a standalone compact owns a command, never a run.
            # Technical depth: admission retains only identity and explicit
            # bounds. Episode capture reads its clock later; this slot fences
            # fresh mutation and survives owner succession before that capture.
            pending_compact: nil,
            prepared_tool_results: %{},
            run_order: [],
            bounds: %{},
            # The context-admission ceiling each run committed at its own prompt
            # admission. ADR 0017 keeps it out of `bounds` because it can never
            # produce `bound_reached`, and keeps it per run because promotion,
            # succession, and restart must all reuse the value the predecessor
            # committed rather than whatever the current process now defaults to.
            context_budgets: %{},
            run_configurations: %{},
            # The transient marker ADR 0017 installs when the first row of a
            # context refusal has been applied and its terminal has not. It is
            # in-memory only: it changes no durable-derived run state, and a
            # recovery that reaches the durable head still holding it is
            # incomplete history rather than a settled session.
            context_refusal: nil,
            deadlines: %{},
            steer: %{},
            follow_up: nil,
            resources: nil,
            run_resources: %{},
            charged: %{},
            run_usage: %{},
            # ADRs 0021/0044 permit monotonic v1, v2, then v3 cutovers. This is
            # reconstructed from settled rows, never from runtime configuration.
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
            # The durable interactions accepted ADR 0024 adds, keyed by their
            # own identity, and the identity of the one that is still open. The
            # serial owner has at most one: `pending` while the question stands,
            # or `answered` while its policy resolution is still owed. A round
            # count lives with each interaction rather than beside it, because
            # the ceiling it enforces belongs to one tool decision and dies with
            # it.
            interactions: %{},
            open_interaction: nil,
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
         :ok <- complete_maintenance_pair(state),
         # Concept: half a refusal is not a settled session.
         #
         # Technical depth: reaching the durable head with the transient marker
         # still installed means the terminal row that completes the pair is
         # missing, which is incomplete history rather than a run to resume.
         nil <- state.context_refusal,
         :ok <- complete_attempt_pair(state),
         {:ok, event_sequence} <- replay_event_sequences(events),
         true <- expected_public_history?(events, state.expected_events),
         {:ok, initial_configuration} <- initial_public_configuration(records),
         {:ok, projection} <- replay_projection(events, event_sequence, initial_configuration),
         true <- projection.active_run_id == state.active_run_id,
         true <- projection.active_maintenance == maintenance_public_view(state),
         true <- projection.open_interaction == open_interaction(state),
         public_configuration = SessionConfiguration.public_view(state.configuration),
         true <- projection.configuration == public_configuration,
         true <- projection.checkpoint == checkpoint_public_view(state) do
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
  cannot change merely because run state moved on. A completed standalone
  compact returns ADR 0043's retained five-member result; its original admission
  remains available to the separate admission-disposition query.
  """
  @spec propose(t(), map(), map()) ::
          {:ok, proposal()}
          | {:replayed, {:accepted, binary()} | {:error, term()} | map()}
          | {:error, term()}
  def propose(state, command, resolved \\ %{})

  def propose(%__MODULE__{} = state, command, resolved)
      when is_map(command) and is_map(resolved) do
    with {:ok, normalized} <- normalize_command(command),
         {:ok, digest} <- command_digest(normalized) do
      case Map.fetch(state.commands, normalized.command_id) do
        {:ok, %{digest: ^digest, result: result}} ->
          {:replayed, result}

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

  # Concept: duplicate identity is decided before defaults or a clock are read.
  # Technical depth: the serial owner uses this same closed normalization as the
  # proposal and replay paths. Fresh commands carry no resolved host values here.
  @doc false
  def prepare_command(state, command) do
    with {:ok, normalized} <- normalize_command(command),
         {:ok, digest} <- command_digest(normalized) do
      case Map.fetch(state.commands, normalized.command_id) do
        {:ok, %{digest: ^digest, result: result}} -> {:replayed, result}
        {:ok, %{digest: ^digest, reply: reply}} -> {:replayed, reply}
        {:ok, _} -> {:error, :idempotency_conflict}
        :error -> {:new, normalized}
      end
    end
  end

  # Concept: host resolution follows the original authored command disposition.
  # Technical depth: the pure ordinary proposal performs normalization, digest,
  # duplicate lookup and settledness first. Only a fresh not-prepared configure
  # command may reach the optional Model callback. Other proposals retain their
  # existing refusal or replay, without invoking any host code.
  @doc false
  def prepare_configuration_command(state, command, owner_settled) do
    case propose(state, command, %{configuration_owner_settled: owner_settled}) do
      {:ok, %{reply: {:error, :configuration_not_prepared}}} ->
        case normalize_command(command) do
          {:ok, %{type: :configure} = normalized} -> {:new, normalized}
          _ -> {:error, :invalid_command}
        end

      result ->
        result
    end
  end

  # Concept: retained admission is evidence; an absent index entry is not absence.
  # Technical depth: this replay-derived view contains no Store or scheduling
  # effects. Refusal codes are the reducer's fixed atoms, never authored text.
  @doc false
  @spec command_disposition(t(), binary()) :: Loopex.Runtime.command_observation()
  def command_disposition(%__MODULE__{} = state, command_id) do
    case Map.get(state.commands, command_id) do
      %{reply: {:accepted, ^command_id}, run_id: run_id} ->
        {:committed, :admitted, :accepted, run_id}

      %{reply: {:error, code}, run_id: run_id} when is_atom(code) ->
        {:committed, :refused, code, run_id}

      %{
        reply:
          {:error, {:command_admission_too_large, _dimension, _candidate, _observed, _limit}},
        run_id: run_id
      } ->
        {:committed, :refused, :command_admission_too_large, run_id}

      _absent ->
        {:pending, nil, :commit_unknown, nil}
    end
  end

  @doc false
  @spec drain_abort_command_id(binary(), non_neg_integer()) :: binary()
  def drain_abort_command_id(session_id, owner_epoch)
      when is_binary(session_id) and is_integer(owner_epoch) and owner_epoch >= 0 do
    stable_id("drain_abort", session_id, owner_epoch)
  end

  @doc false
  @spec drain_abort_record?(map(), binary(), map(), binary() | nil) :: boolean()
  def drain_abort_record?(record, command_id, head, run_id)
      when is_map(record) and is_binary(command_id) and is_map(head) do
    {:ok, digest} = command_digest(%{type: :abort, command_id: command_id})
    payload = Map.get(record, :payload, %{})
    owner_epoch = Map.get(head, :owner_epoch)
    journal_version = Map.get(head, :journal_version)

    base? =
      is_integer(owner_epoch) and owner_epoch >= 0 and is_integer(journal_version) and
        journal_version >= 0 and Map.get(record, :owner_epoch) == owner_epoch and
        Map.get(record, :journal_version) == journal_version + 1 and
        Map.get(payload, :kind, Map.get(payload, "kind")) in [
          "command_admitted",
          "model_question_abort_admitted_v2"
        ] and
        Map.get(payload, "command_id") == command_id and
        Map.get(payload, "command_digest") == digest and
        Map.get(payload, "command_type") == "abort"

    case run_id do
      run_id when is_binary(run_id) ->
        base? and Map.get(payload, "admission") == "accepted" and
          Map.get(payload, "run_id") == run_id

      nil ->
        base? and Map.get(payload, "admission") == "rejected_no_active_run" and
          not Map.has_key?(payload, "run_id")
    end
  end

  def drain_abort_record?(_record, _command_id, _head, _run_id), do: false

  @doc false
  @spec drain_abort_binding(t(), binary()) :: :match | :collision | :absent
  def drain_abort_binding(%__MODULE__{} = state, command_id) when is_binary(command_id) do
    {:ok, digest} = command_digest(%{type: :abort, command_id: command_id})

    case Map.get(state.commands, command_id) do
      %{digest: ^digest, reply: {:accepted, ^command_id}} -> :match
      %{digest: ^digest, reply: {:error, :no_active_run}} -> :match
      nil -> :absent
      _other -> :collision
    end
  end

  @doc false
  @spec prepare_resource_command(t(), map()) ::
          {:new, map()} | {:replayed, term()} | {:error, term()}
  def prepare_resource_command(%__MODULE__{} = state, command) do
    with {:ok, normalized} <- normalize_resource_command(command),
         {:ok, digest} <- command_digest(normalized) do
      case Map.fetch(state.commands, normalized["command_id"]) do
        {:ok, %{digest: ^digest, reply: reply}} -> {:replayed, reply}
        {:ok, _other} -> {:error, :idempotency_conflict}
        :error -> {:new, normalized}
      end
    end
  end

  @doc false
  @spec propose_resource_command(t(), map(), {:accepted, map()} | {:refused, atom()}) ::
          {:ok, proposal()} | {:replayed, term()} | {:error, term()}
  def propose_resource_command(state, command, resolution) do
    with {:new, normalized} <- prepare_resource_command(state, command),
         {:ok, digest} <- command_digest(normalized),
         {:ok, disposition, resolved} <- resource_resolution(resolution),
         record = %{
           "command" => normalized,
           "command_digest" => digest,
           "disposition" => disposition,
           "resolved" => resolved,
           kind: "resource_command_v1"
         },
         {:ok, record, bytes} <- Store.normalize_and_measure_item(:record, record),
         true <- bytes <= 16_384,
         {:ok, next} <- apply_resource_record(state, record) do
      id = normalized["command_id"]

      {:ok,
       %{
         tx_id: internal_transaction_id(state, stable_id("resource", state.session_id, id)),
         records: [record],
         events: [],
         next: next,
         reply: next.commands[id].reply
       }}
    else
      false -> {:error, :invalid_command}
      other -> other
    end
  end

  @doc false
  @spec resource_selection_digest(map()) :: binary()
  def resource_selection_digest(resources) do
    Canonical.digest(%{
      "encoding" => Canonical.version(),
      "kind" => "loopex.resource_selection/1",
      "value" => Map.take(resources, ["decision", "selections"])
    })
  end

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
  @spec snapshot(binary(), non_neg_integer(), [map()], map()) :: {:ok, map()} | {:error, term()}
  def snapshot(session_id, anchor, events, initial_configuration)
      when is_binary(session_id) and is_integer(anchor) and anchor >= 0 and is_list(events) do
    with {:ok, scan} <- start_snapshot_scan(session_id, anchor, initial_configuration),
         {:ok, scan} <- scan_snapshot_page(scan, events),
         {:ok, %{snapshot: snapshot}} <- finish_snapshot_scan(scan) do
      {:ok, snapshot}
    end
  end

  def snapshot(_session_id, _anchor, _events, _initial_configuration),
    do: {:error, :invalid_snapshot_anchor}

  @doc """
  ## Concept

  Starts a bounded incremental reduction of durable public history for one
  attachment snapshot.

  ## Technical depth

  The requested anchor is either a non-negative durable cursor or `nil` for the
  Store tail observed by the scan. The accumulator retains only positions and
  run, interaction, configuration, checkpoint, maintenance and last-compact
  projections, never event pages. The immutable genesis configuration is required
  and uses the closed current configuration allowlist. Never seed this reduction
  from mutable current private state. Later settings come exclusively from
  consecutive committed session.configured rows. The requested anchor keeps its
  own bounded projection while scanning the tail.
  """
  @spec start_snapshot_scan(binary(), non_neg_integer() | nil, map()) ::
          {:ok, map()} | {:error, term()}
  def start_snapshot_scan(session_id, requested_anchor, initial_configuration)
      when is_binary(session_id) and
             (is_nil(requested_anchor) or
                (is_integer(requested_anchor) and requested_anchor >= 0)) do
    projection = %{
      active_run: nil,
      open_interaction: nil,
      configuration: initial_configuration,
      checkpoint: nil,
      active_maintenance: nil,
      last_compact: nil
    }

    with :ok <- valid_initial_public_configuration(initial_configuration) do
      {:ok,
       Map.merge(projection, %{
         session_id: session_id,
         requested_anchor: requested_anchor,
         tail: 0,
         anchor_projection: if(requested_anchor == 0, do: {:set, projection}, else: :pending)
       })}
    end
  end

  def start_snapshot_scan(_session_id, _requested_anchor, _initial_configuration),
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
          {:ok,
           %{
             required(:snapshot) => map(),
             required(:tail) => non_neg_integer(),
             required(:open_interaction) => map() | nil,
             required(:configuration) => map(),
             required(:checkpoint) => map() | nil,
             required(:active_maintenance) => map() | nil,
             required(:last_compact) => map() | nil
           }}
          | {:error, term()}
  def finish_snapshot_scan(
        %{
          session_id: session_id,
          requested_anchor: requested_anchor,
          tail: tail,
          anchor_projection: anchor_projection
        } = scan
      ) do
    case {requested_anchor, anchor_projection} do
      {nil, _projection} ->
        finish_snapshot_projection(session_id, tail, tail, scan)

      {anchor, {:set, projection}} when anchor <= tail ->
        finish_snapshot_projection(session_id, anchor, tail, projection)

      {_anchor, _projection} ->
        {:error, :cursor_expired}
    end
  end

  def finish_snapshot_scan(_scan), do: {:error, :invalid_public_history}

  # Concept: every snapshot view describes the same committed cursor.
  # Technical depth: the bounded projection already holds that cursor's six
  # views. The shared revision-3 codec validates the complete closed snapshot,
  # including ownership and configuration relationships, before publication.
  defp finish_snapshot_projection(session_id, anchor, tail, projection) do
    views =
      Map.take(
        projection,
        ~w(open_interaction configuration checkpoint active_maintenance last_compact)a
      )

    {run_id, phase} = projection.active_run || {nil, nil}

    snapshot =
      Map.merge(views, %{
        snapshot_revision: 3,
        session_id: session_id,
        event_sequence: anchor,
        active_run_id: run_id,
        active_run_phase: phase
      })

    case LoopexProtocol.Session.Snapshot.encode_wire(snapshot) do
      {:ok, _wire} -> {:ok, Map.merge(views, %{tail: tail, snapshot: snapshot})}
      :error -> {:error, :invalid_public_snapshot}
    end
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

  # Concept: a prepared host compares retained startup facts before work starts.
  # Technical depth: this is a plain projection of replayed options and work,
  # excluding completed effects and current launch defaults. The coordinator
  # must establish its holder/owner fence before returning this capture.
  @doc false
  @spec prepared_startup_capture(t()) :: {:ok, map()} | {:error, atom()}
  def prepared_startup_capture(%__MODULE__{} = state) do
    with true <- is_map(state.session_options) and not is_struct(state.session_options),
         {:ok, policy} <- startup_policy(state),
         {:ok, models, workspaces} <- startup_work(state) do
      capture = %{
        session_options: state.session_options,
        pending_policy_identity: policy,
        admitted_models: models |> Enum.uniq() |> Enum.sort(),
        admitted_workspace_refs: workspaces |> Enum.uniq() |> Enum.sort()
      }

      case Store.admit_bounded(capture) do
        {:ok, _bytes} -> {:ok, capture}
        {:error, _unrepresentable} -> {:error, :prepared_startup_too_large}
      end
    else
      _incomplete -> {:error, :prepared_startup_unavailable}
    end
  end

  defp startup_policy(%{open_interaction: nil}), do: {:ok, nil}

  defp startup_policy(%{interactions: interactions} = state) when is_map(interactions) do
    case open_interaction_record(state) do
      %{producer: "model_tool", policy_identity: nil, status: "pending"} ->
        {:ok, nil}

      %{policy_identity: %{"id" => id, "revision" => revision} = policy, status: status}
      when status in ["pending", "answered"] and map_size(policy) == 2 ->
        if startup_identity?(id, 256) and startup_identity?(revision, 256),
          do: {:ok, policy},
          else: :error

      _unavailable ->
        :error
    end
  end

  defp startup_policy(_state), do: :error

  defp startup_work(%{pending_work: work, run_configurations: configurations})
       when is_map(work) and is_map(configurations) do
    Enum.reduce_while(work, {:ok, [], []}, fn
      {run, %{stage: stage} = pending}, {:ok, models, refs} when is_binary(stage) ->
        with %{"model" => model} <- configurations[run],
             true <- startup_identity?(model, 512),
             {:ok, staged_models} <- startup_request_models(pending),
             {:ok, workspace_refs} <- startup_workspace_refs(pending) do
          {:cont, {:ok, [model | staged_models] ++ models, workspace_refs ++ refs}}
        else
          _unavailable -> {:halt, :error}
        end

      _unavailable, _acc ->
        {:halt, :error}
    end)
  end

  defp startup_work(_state), do: :error

  defp startup_request_models(work) do
    request =
      case Map.fetch(work, :request) do
        :error -> :absent
        {:ok, %{model: model}} -> model
        _invalid -> :invalid
      end

    staged =
      case Map.fetch(work, :staged) do
        :error -> :absent
        {:ok, %{request: %{model: model}}} -> model
        _invalid -> :invalid
      end

    models = Enum.reject([request, staged], &(&1 == :absent))

    if Enum.all?(models, &startup_identity?(&1, 512)), do: {:ok, models}, else: :error
  end

  defp startup_workspace_refs(%{stage: "effect_dispatched", job: job, grant: grant})
       when is_map(job) and is_map(grant) do
    reference = Map.get(job, :workspace_ref)

    if startup_identity?(reference, 256),
      do: {:ok, [reference]},
      else: :error
  end

  defp startup_workspace_refs(%{stage: "effect_dispatched"}), do: :error
  defp startup_workspace_refs(_work), do: {:ok, []}

  defp startup_identity?(value, limit) do
    is_binary(value) and byte_size(value) in 1..limit and String.valid?(value) and
      not String.contains?(value, <<0>>)
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

  The committed conversation through one admitted run or the whole session.

  ## Technical depth

  Admission and follow-up promotion append run identities during replay. This
  read includes earlier runs regardless of their terminal outcome, preserves
  element order within each run, and never includes a later run. The internal
  `:session` scope includes every admitted run in that same order for standalone
  compaction, without creating a prompt or run. Per-run reads remain available
  for accounting and staged-request validation.
  """
  @spec lineage_elements(t(), binary() | :session) :: [Conversation.element()]
  def lineage_elements(%__MODULE__{} = state, :session),
    do: Enum.flat_map(state.run_order, &elements(state, &1))

  def lineage_elements(%__MODULE__{} = state, run_id) do
    case Enum.split_while(state.run_order, &(&1 != run_id)) do
      {earlier, [^run_id | _later]} ->
        Enum.flat_map(earlier ++ [run_id], &elements(state, &1))

      {_earlier, []} ->
        []
    end
  end

  # Concept: selection protects work and native prefixes retained by this owner.
  # Technical depth: run order and pending work come from validated replay;
  # absence of pending work alone cannot release a run with an open interaction.
  @doc false
  @spec compaction_units(t(), binary() | :session) ::
          {:ok, [map()]} | {:error, :context_projection_invalid}
  def compaction_units(%__MODULE__{} = state, run_id),
    do:
      compaction_units_from(
        state,
        run_id,
        uncompacted_elements(state, lineage_elements(state, run_id))
      )

  defp compaction_units_from(state, run_id, elements) do
    if run_id == :session or run_id in state.run_order do
      interaction = open_interaction_record(state)
      interaction_run = interaction && interaction.run_id

      terminal_runs =
        Enum.reject(state.run_order, fn run ->
          Map.has_key?(state.pending_work, run) or run == interaction_run
        end)

      Conversation.compaction_units(
        elements,
        state.active_run_id,
        terminal_runs,
        Map.keys(frozen_lineage(state, state.active_run_id))
      )
    else
      {:error, :context_projection_invalid}
    end
  end

  @doc false
  @spec projected_lineage(t(), binary() | :session, non_neg_integer(), list() | nil) ::
          {:ok, list(), map() | nil} | {:error, atom()}
  def projected_lineage(state, run_id, allowance, elements \\ nil) do
    binding = state.tool_selection && state.tool_selection["artifact_read"]

    with {:ok, entries, projection} <-
           Loopex.Runtime.LineageProjection.project(
             prepared_elements(
               state,
               uncompacted_elements(state, elements || lineage_elements(state, run_id))
             ),
             binding,
             state.artifact_sources,
             frozen_lineage(state, if(run_id == :session, do: state.active_run_id, else: run_id)),
             allowance
           ),
         {:ok, checkpoint} <- checkpoint_entries(state) do
      {:ok, checkpoint ++ entries, projection}
    end
  end

  defp uncompacted_elements(state, elements),
    do:
      Enum.reject(
        elements,
        &MapSet.member?(state.compacted_sources, Conversation.source_reference(&1))
      )

  defp checkpoint_entries(%{active_checkpoint: nil}), do: {:ok, []}

  defp checkpoint_entries(state) do
    checkpoint = state.checkpoints[state.active_checkpoint]

    with {:ok, entry} <-
           Loopex.Runtime.CompactionSummary.project(
             state.active_checkpoint,
             checkpoint["summary"]
           ),
         do: {:ok, [entry]}
  end

  @doc false
  @spec preparation_sources(t(), binary(), list() | nil) ::
          {:ok, [map()]} | {:error, atom()}
  # Concept: storage work is selected from committed ordinary history only.
  # Technical depth: ordered candidates carry exact receipt identity, measured
  # source-record bytes, original text and the five existing provenance labels.
  # Native prefixes, explicit ranges, questions and already retained references
  # consume no preparation credit. The owner reserves credit before doing IO.
  def preparation_sources(state, run_id, elements \\ nil) do
    binding = state.tool_selection && state.tool_selection["artifact_read"]

    with {:ok, candidates} <-
           Loopex.Runtime.LineageProjection.preparation_candidates(
             prepared_elements(
               state,
               uncompacted_elements(state, elements || lineage_elements(state, run_id))
             ),
             binding,
             state.artifact_sources,
             frozen_lineage(state, run_id)
           ) do
      Enum.reduce_while(candidates, {:ok, []}, fn candidate, {:ok, sources} ->
        case Map.fetch(state.tool_result_sources, candidate.source_reference) do
          {:ok, original} ->
            source = Map.put(original, :content, candidate.message["content"])
            {:cont, {:ok, [source | sources]}}

          :error ->
            {:halt, {:error, :context_projection_invalid}}
        end
      end)
      |> case do
        {:ok, sources} -> {:ok, Enum.reverse(sources)}
        error -> error
      end
    end
  end

  @doc false
  @spec propose_preparation_reservation(t(), binary(), integer()) ::
          :ready | {:reserved, map(), map()} | {:ok, proposal()} | {:error, atom()}
  def propose_preparation_reservation(state, run_id, now) do
    with {:ok, identity} <- preparation_identity(state, run_id),
         :ok <- preflight_run_history(state, run_id),
         {:ok, sources} <- preparation_sources(state, run_id) do
      episode = state.artifact_preparations[identity["episode_id"]]

      case {episode, sources} do
        {%{"status" => "failed"}, _} ->
          {:ok, cause} = ArtifactPreparation.failure_cause(episode)
          {:error, cause}

        {%{"status" => "reserved"}, [source | _]} ->
          {:reserved, source, episode}

        {_, []} ->
          :ready

        {_, [source | _]} ->
          with {:ok, record} <-
                 ArtifactPreparation.reserve(
                   episode,
                   identity,
                   source,
                   now,
                   retained_run_deadline(state, run_id)
                 ) do
            internal_proposal(state, identity["episode_id"] <> ":reserve", record)
          end
      end
    end
  end

  # Concept: maintenance admission freezes one run's summarizer before work.
  # Technical depth: this internal proposal binds the next ordinary staging
  # identity, host capture and spending bounds. The fixed preparation cutoff is
  # recorded once; an existing episode is returned before consulting a changed
  # clock or host configuration. It grants no provider dispatch authority.
  @doc false
  def propose_maintenance_episode(
        state,
        run_id,
        selection,
        instructions,
        now,
        trigger \\ "ordinary_limit"
      )

  def propose_maintenance_episode(
        %__MODULE__{} = state,
        run_id,
        selection,
        instructions,
        now,
        trigger
      ) do
    with true <- trigger in ["ordinary_limit", "thinking_headroom"],
         {:ok, work, parent} <- maintenance_admission_context(state, run_id),
         targets = request_headroom_targets(state, run_id),
         true <- trigger != "thinking_headroom" or is_map(targets) do
      identity = stable_id("maintenance", run_id, next_turn_number(work))

      case Map.fetch(state.maintenance_episodes, identity) do
        {:ok, episode} ->
          {:retained, episode}

        :error ->
          with true <- is_nil(state.active_maintenance),
               :ok <- maintenance_clock(state, run_id, now),
               {:ok, capture} <- MaintenanceConfiguration.capture(selection, instructions, parent) do
            record = %{
              :kind => "maintenance_episode_admitted_v1",
              "episode_id" => identity,
              "run_id" => run_id,
              "staging_turn_id" => stable_id("turn", run_id, next_turn_number(work)),
              "trigger" => trigger,
              "targets" => targets,
              "origin" => "automatic",
              "configuration_version" => parent["configuration_version"],
              "maintenance_configuration" => capture,
              "bounds" => maintenance_bounds(state, run_id),
              "admitted_at" => now,
              "preparation_deadline" => now + 60_000,
              "attempts" => 0,
              "summary_ordinal" => 1,
              "checkpoint_id" => nil,
              "usage" => %{
                "attempts" => 0,
                "reported_tokens" => 0,
                "estimated_tokens" => 0,
                "total_tokens" => 0
              }
            }

            with {:ok, _} <- Store.admit_bounded(record) do
              internal_proposal(state, identity <> ":admit", record)
            end
          else
            false -> {:error, :maintenance_active}
            error -> error
          end
      end
    else
      false -> {:error, :maintenance_not_quiescent}
      {:error, _} = error -> error
    end
  end

  defp maintenance_admission_context(state, run_id) do
    case {state.active_run_id, state.pending_work[run_id], run_configuration(state, run_id)} do
      {^run_id, %{stage: stage} = work, %{} = parent}
      when stage in ["model_pending", "turn_settled"] ->
        if is_nil(state.aborting) and is_nil(state.open_interaction) and
             is_nil(state.context_refusal) and is_nil(work[:continuation_exchange]) and
             not unproven_effect?(state, run_id) and preparation_ready?(state, run_id) do
          {:ok, work, parent}
        else
          {:error, :maintenance_not_quiescent}
        end

      _ ->
        {:error, :maintenance_not_quiescent}
    end
  end

  # Concept: standalone maintenance retains the admitted command's own capture.
  # Technical depth: ADR 0043 gives it no run or preparation cutoff. Its exact
  # declared bounds and admission-time absolute deadline belong to the command;
  # the retained episode wins before consulting a new clock or host selection.
  # The private row implements that accepted capture without nullable run fields.
  # Whole-session/minimum-tail measurement precedes summarizer configuration.
  @doc false
  @spec propose_standalone_maintenance_episode(t(), term(), term(), term(), function()) ::
          {:ok, proposal()}
          | {:retained, map()}
          | {:unchanged, map()}
          | {:refused, term()}
          | {:error, term()}
  def propose_standalone_maintenance_episode(state, selection, instructions, now, check) do
    case state.pending_compact do
      %{"episode_id" => identity} ->
        case Map.fetch(state.maintenance_episodes, identity) do
          {:ok, episode} ->
            {:retained, episode}

          :error ->
            with {:ok, record} <-
                   standalone_maintenance_episode_record(
                     state,
                     selection,
                     instructions,
                     now,
                     check
                   ) do
              internal_proposal(state, identity <> ":admit", record)
            end
        end

      _ ->
        {:error, :maintenance_not_quiescent}
    end
  end

  defp standalone_maintenance_episode_record(state, selection, instructions, now, check) do
    with %{"abort_command_id" => nil} = pending <- state.pending_compact,
         true <- is_nil(state.active_maintenance),
         :ok <- standalone_maintenance_clock(pending, now),
         deadline = now + pending["bounds"]["deadline_ms"],
         {:ok, plan} <- preflight_standalone_compaction(state, deadline, check) do
      if plan.eligible_unit_count == 0 do
        {:unchanged, plan}
      else
        with {:ok, capture} <-
               MaintenanceConfiguration.capture(selection, instructions, state.configuration),
             :ok <- check.() do
          record = %{
            :kind => "standalone_maintenance_episode_admitted_v1",
            "episode_id" => pending["episode_id"],
            "command_id" => pending["command_id"],
            "trigger" => plan.trigger,
            "targets" => nil,
            "origin" => "explicit",
            "last_offending_source" => plan.last_offending_source,
            "configuration_version" => state.configuration["configuration_version"],
            "maintenance_configuration" => capture,
            "bounds" => pending["bounds"],
            "admitted_at" => now,
            "deadline" => deadline,
            "attempts" => 0,
            "summary_ordinal" => 1,
            "checkpoint_id" => nil,
            "usage" => %{
              "attempts" => 0,
              "reported_tokens" => 0,
              "estimated_tokens" => 0,
              "total_tokens" => 0
            }
          }

          with {:ok, _} <- Store.admit_bounded(record), do: {:ok, record}
        end
      end
    else
      {:refused, _} = refusal -> refusal
      {:error, _} = error -> error
      _ -> {:error, :maintenance_not_quiescent}
    end
  end

  defp standalone_maintenance_clock(pending, now) do
    if is_integer(now) and now >= 0 and
         now <= @uint64_max - pending["bounds"]["deadline_ms"],
       do: :ok,
       else: {:error, :maintenance_deadline_unrepresentable}
  end

  # Concept: an empty fitting session completes compact without a summarizer.
  # Technical depth: ADR 0043's unchanged result and completion event commit in
  # the same owner transaction. The exact current projection must fit and render
  # with no eligible raw units. No episode, provider attempt, usage or checkpoint
  # is created; replay proves the selection from the preceding durable state.
  @doc false
  @spec propose_unchanged_compact(t(), term(), function()) ::
          {:ok, proposal()} | {:error, term()} | {:refused, term()}
  def propose_unchanged_compact(state, now, check) do
    with {:ok, record} <- unchanged_compact_record(state, now, check),
         {:ok, proposal} <-
           internal_proposal(state, record["episode_id"] <> ":completed", record),
         :ok <- check.() do
      {:ok, proposal}
    end
  end

  defp unchanged_compact_record(state, now, check) do
    with %{"abort_command_id" => nil} = pending <- state.pending_compact,
         true <- is_nil(state.active_maintenance),
         false <- Map.has_key?(state.maintenance_episodes, pending["episode_id"]),
         :ok <- standalone_maintenance_clock(pending, now),
         {:ok, %{eligible_unit_count: 0}} <-
           preflight_standalone_compaction(
             state,
             now + pending["bounds"]["deadline_ms"],
             check
           ) do
      {:ok,
       %{
         :kind => "compact_command_completed_v1",
         "command_id" => pending["command_id"],
         "episode_id" => pending["episode_id"],
         "observed_at" => now,
         "result" => %{
           "disposition" => "unchanged",
           "checkpoint_id" => nil,
           "failure" => nil,
           "usage" => %{
             "attempts" => 0,
             "reported_tokens" => 0,
             "estimated_tokens" => 0,
             "total_tokens" => 0
           },
           "cleanup" => "confirmed"
         }
       }}
    else
      {:ok, _nonempty} -> {:error, :compaction_required}
      {:error, _} = error -> error
      {:refused, _} = refusal -> refusal
      _ -> {:error, :maintenance_not_quiescent}
    end
  end

  # Concept: compact failures complete their actual command without a run.
  # Technical depth: ADR 0043 retains zero usage before a provider attempt and
  # exact settled usage afterward. Captured episodes require the leading terminal
  # in the same transaction; the winning failure is rederived from the retained
  # settlement, actual abort, clock and limits. Nothing settles an open attempt.
  @doc false
  def propose_standalone_compact_failure(state, failure, clock, check \\ fn -> :ok end) do
    with {:ok, record} <- standalone_compact_failure_record(state, failure, clock, check),
         identity = record["episode_id"] <> ":completed",
         {:ok, proposal} <- internal_proposal(state, identity, record),
         :ok <- check.() do
      {:ok, proposal}
    end
  end

  defp standalone_compact_failure_record(state, failure, clock, check) do
    case state.maintenance_episodes[state.active_maintenance] do
      %{"attempts" => attempts, kind: "standalone_maintenance_episode_admitted_v1"}
      when attempts > 0 ->
        with :ok <- check.(),
             {:ok, record} <- standalone_settlement_completion_record(state, clock, check),
             true <- record["result"]["failure"] == failure,
             :ok <- check.() do
          {:ok, record}
        else
          {:error, _} = error -> error
          _ -> {:error, :invalid_compact_completion_transition}
        end

      _ ->
        zero_attempt_compact_failure_record(state, failure, clock, check)
    end
  end

  defp zero_attempt_compact_failure_record(state, failure, clock, check) do
    with %{} = pending <- state.pending_compact,
         episode = state.maintenance_episodes[pending["episode_id"]],
         true <- zero_attempt_standalone?(state, episode),
         true <- is_nil(clock) or (is_integer(clock) and clock >= 0 and clock <= @uint64_max),
         :ok <- zero_attempt_compact_failure(state, episode, failure, clock, check) do
      {:ok,
       %{
         :kind => "compact_command_completed_v1",
         "command_id" => pending["command_id"],
         "episode_id" => pending["episode_id"],
         "observed_at" => clock,
         "result" => %{
           "disposition" => "failed",
           "checkpoint_id" => nil,
           "failure" => failure,
           "usage" => %{
             "attempts" => 0,
             "reported_tokens" => 0,
             "estimated_tokens" => 0,
             "total_tokens" => 0
           },
           "cleanup" => "confirmed"
         }
       }}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_compact_completion_transition}
    end
  end

  defp zero_attempt_standalone?(state, nil), do: is_nil(state.active_maintenance)

  defp zero_attempt_standalone?(
         state,
         %{
           :kind => "standalone_maintenance_episode_admitted_v1",
           "stage" => "source_preparation",
           "attempts" => 0,
           "checkpoint_id" => nil
         } = episode
       ),
       do: state.active_maintenance == episode["episode_id"]

  defp zero_attempt_standalone?(_, _), do: false

  defp zero_attempt_compact_failure(state, episode, failure, clock, check) do
    with {:ok, _} <-
           LoopexProtocol.Session.CompactResult.encode_wire(%{
             "disposition" => "failed",
             "checkpoint_id" => nil,
             "failure" => failure,
             "usage" => %{
               "attempts" => 0,
               "reported_tokens" => 0,
               "estimated_tokens" => 0,
               "total_tokens" => 0
             },
             "cleanup" => "confirmed"
           }),
         true <- is_nil(episode) or (is_integer(clock) and clock >= episode["admitted_at"]) do
      zero_attempt_compact_cause(state, episode, failure, clock, check)
    else
      _ -> {:error, :invalid_compact_completion_transition}
    end
  end

  defp zero_attempt_compact_cause(state, _episode, %{"category" => "cancelled"}, _clock, _check) do
    if is_binary(state.pending_compact["abort_command_id"]),
      do: :ok,
      else: {:error, :invalid_compact_completion_transition}
  end

  defp zero_attempt_compact_cause(%{pending_compact: %{"abort_command_id" => abort}}, _, _, _, _)
       when is_binary(abort) do
    {:error, :invalid_compact_completion_transition}
  end

  defp zero_attempt_compact_cause(
         state,
         nil,
         %{
           "version" => 2,
           "category" => "context_preparation_failed",
           "measurement_scope" => nil,
           "cause" => "maintenance_deadline_unrepresentable"
         },
         clock,
         _check
       ) do
    if standalone_maintenance_clock(state.pending_compact, clock) != :ok,
      do: :ok,
      else: {:error, :invalid_compact_completion_transition}
  end

  defp zero_attempt_compact_cause(
         _state,
         _episode,
         %{
           "version" => 2,
           "category" => "context_preparation_failed",
           "measurement_scope" => nil,
           "cause" => "context_projection_invalid"
         },
         clock,
         _check
       )
       when is_integer(clock) do
    :ok
  end

  defp zero_attempt_compact_cause(
         state,
         episode,
         %{
           "category" => "bound_reached",
           "bound" => "deadline_ms",
           "observed" => observed,
           "declared_limit" => cutoff,
           "accounting_source" => nil
         },
         clock,
         _check
       )
       when is_integer(clock) do
    expected =
      if episode,
        do: episode["deadline"],
        else: clock + state.pending_compact["bounds"]["deadline_ms"]

    if expected <= @uint64_max and cutoff == expected and observed >= expected and
         observed <= @uint64_max do
      :ok
    else
      {:error, :invalid_compact_completion_transition}
    end
  end

  # Concept: standalone token bounds reserve the complete fixed reply before dispatch.
  # Technical depth: the existing compact bound permits an observed charge below
  # its ceiling when that reservation cannot fit. Prove the exact zero charge,
  # captured allowance and unexpired episode; the run-only reserve cause is unused.
  defp zero_attempt_compact_cause(
         state,
         %{} = episode,
         %{
           "category" => "bound_reached",
           "bound" => "token_budget",
           "observed" => 0,
           "declared_limit" => limit,
           "accounting_source" => nil
         },
         clock,
         _check
       ) do
    if limit == episode["bounds"]["token_budget"] and limit in 1..1_023,
      do: maintenance_source_clock(state, episode, clock),
      else: {:error, :invalid_compact_completion_transition}
  end

  defp zero_attempt_compact_cause(
         state,
         nil,
         %{
           "version" => 2,
           "category" => "context_preparation_failed",
           "measurement_scope" => "ordinary",
           "cause" => cause
         },
         clock,
         check
       )
       when cause in ~w(maintenance_model_unconfigured maintenance_instructions_unconfigured maintenance_reasoning_unsupported) do
    with :ok <- standalone_maintenance_clock(state.pending_compact, clock),
         {:ok, plan} <-
           preflight_standalone_compaction(
             state,
             clock + state.pending_compact["bounds"]["deadline_ms"],
             check
           ),
         true <- plan.eligible_unit_count > 0 do
      :ok
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_compact_completion_transition}
    end
  end

  defp zero_attempt_compact_cause(state, nil, %{"version" => 2} = failure, clock, check) do
    with :ok <- standalone_maintenance_clock(state.pending_compact, clock),
         {:refused, ^failure} <-
           preflight_standalone_compaction(
             state,
             clock + state.pending_compact["bounds"]["deadline_ms"],
             check
           ) do
      :ok
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_compact_completion_transition}
    end
  end

  defp zero_attempt_compact_cause(
         state,
         %{kind: "standalone_maintenance_episode_admitted_v1"},
         %{"version" => 2} = failure,
         clock,
         check
       ) do
    case selected_maintenance_source_result(state, clock, check) do
      {:error, :compaction_excerpt_budget_too_small} = result ->
        if standalone_source_failure(result) == failure,
          do: :ok,
          else: {:error, :invalid_compact_completion_transition}

      {:refused, %{} = _} = result ->
        if standalone_source_failure(result) == failure,
          do: :ok,
          else: {:error, :invalid_compact_completion_transition}

      {:error, _} = error ->
        error

      _ ->
        {:error, :invalid_compact_completion_transition}
    end
  end

  defp zero_attempt_compact_cause(_, _, _, _, _),
    do: {:error, :invalid_compact_completion_transition}

  # Concept: a source fit becomes dispatchable only with its complete request.
  # Technical depth: the caller supplies the eligible tail cut chosen by the
  # ordinary-request selector. This owner rejects cuts crossing protected work,
  # projects each whole unit lazily at q=0, and preflights every complete prefix
  # and excerpt against the exact receipt-bearing record. Nothing is committed
  # by preflight, and no current host setting or artifact is read.
  @doc false
  def preflight_maintenance_request(state, eligible_count, now, check)
      when is_integer(eligible_count) and eligible_count > 0 and is_function(check, 0) do
    with {:ok, episode} <- maintenance_source_episode(state, now, check),
         :ok <- maintenance_instruction_budget(episode),
         {:ok, deadline} <- maintenance_request_deadline(state, episode, now),
         {:ok, units} <- compaction_units(state, maintenance_scope(episode)),
         eligible = Enum.take_while(units, &(not &1.protected?)),
         true <- eligible_count <= length(eligible),
         selected = Enum.take(eligible, eligible_count),
         {:ok, streams} <- maintenance_source_streams(state, selected, check),
         {:ok, choice} <-
           Loopex.Runtime.CompactionSource.select(
             streams,
             maintenance_prior_summary(state),
             fn source, count ->
               case maintenance_request_candidate(
                      state,
                      episode,
                      units,
                      eligible_count,
                      count,
                      source,
                      deadline,
                      now,
                      check
                    ) do
                 {:ok, _record} -> :ok
                 other -> other
               end
             end,
             check
           ),
         %{source: source, unit_count: count} <- choice do
      maintenance_request_candidate(
        state,
        episode,
        units,
        eligible_count,
        count,
        source,
        deadline,
        now,
        check
      )
    else
      {:error, _} = error -> error
      {:refused, _} = refusal -> refusal
      _ -> {:error, :context_projection_invalid}
    end
  end

  def preflight_maintenance_request(_, _, _, _), do: {:error, :context_projection_invalid}

  # Concept: source preparation follows its owning run or explicit command.
  # Technical depth: the pure worker selects q=0 whole units under the ordinary
  # run's tail policy or the standalone command's whole-session release. Shared
  # source encoding and request sizing precede the adjacent request/open pair;
  # only that committed pair permits dispatch under the episode identity.
  @doc false
  def propose_selected_maintenance_request(state, now, check) do
    case selected_maintenance_source_result(state, now, check) do
      {:error, :compaction_excerpt_budget_too_small} = result
      when is_map(state.pending_compact) ->
        propose_standalone_compact_failure(state, standalone_source_failure(result), now, check)

      {:refused, %{} = _measurement} = result when is_map(state.pending_compact) ->
        propose_standalone_compact_failure(state, standalone_source_failure(result), now, check)

      {:error, :compaction_excerpt_budget_too_small}
      when is_nil(state.pending_compact) ->
        propose_maintenance_source_refusal(state, now, check)

      {:refused, %{} = _measurement}
      when is_nil(state.pending_compact) ->
        propose_maintenance_source_numeric_refusal(state, now, check)

      result ->
        result
    end
  end

  # Concept: a lost source worker ends its episode before any summary dispatch.
  # Technical depth: worker loss is an owner observation, not a rederived
  # history defect. Bind the existing unavailable cause to the exact eligible
  # source phase and retained clock; replay validates those durable boundaries.
  @doc false
  @spec propose_maintenance_source_failure(t(), binary(), integer()) ::
          {:ok, proposal()} | {:error, atom()}
  def propose_maintenance_source_failure(state, run_id, now) do
    with {:ok, episode} <- maintenance_source_episode(state, now, fn -> :ok end),
         true <- episode["run_id"] == run_id do
      refusal =
        unavailable_context_refusal(
          state,
          run_id,
          run_configuration(state, run_id),
          next_turn_number(state.pending_work[run_id]),
          "context_projection_invalid"
        )

      terminal =
        state
        |> run_terminal_record(run_id, "failed", %{})
        |> Map.put("failure", context_failure(refusal))

      build_internal_proposal(
        state,
        episode["episode_id"] <> ":source-failure",
        [refusal, terminal],
        now
      )
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_context_refusal}
    end
  end

  # Concept: standalone preparation retains the accepted measured or named refusal.
  # Technical depth: the zero-attempt result reselects the same frozen source at
  # its recorded clock. A captured system ceiling is maintenance scope; an
  # already-versioned whole-session minimum refusal retains ordinary scope.
  defp standalone_source_failure({:error, :compaction_excerpt_budget_too_small}),
    do: %{
      "version" => 2,
      "category" => "context_preparation_failed",
      "retryable" => false,
      "measurement_scope" => nil,
      "cause" => "compaction_excerpt_budget_too_small"
    }

  defp standalone_source_failure({:refused, %{"version" => 2} = failure}), do: failure

  defp standalone_source_failure({:refused, raw}),
    do:
      Map.take(raw, ~w(dimension observed limit))
      |> Map.merge(%{
        "version" => 2,
        "category" => "context_budget_exceeded",
        "retryable" => false,
        "measurement_scope" => "maintenance",
        "hard_limit" => raw["limit"]
      })

  defp selected_maintenance_source_result(%{pending_compact: %{}} = state, now, check) do
    with {:ok, episode} <- maintenance_source_episode(state, now, check),
         {:ok, choice} <- preflight_standalone_compaction(state, episode["deadline"], check),
         true <- choice.eligible_unit_count > 0 do
      propose_maintenance_request(state, choice.eligible_unit_count, now, check)
    else
      false -> {:error, :compaction_no_progress}
      result -> result
    end
  end

  defp selected_maintenance_source_result(state, now, check) do
    with {:ok, episode} <- maintenance_source_episode(state, now, check),
         {:ok, deadline} <- maintenance_request_deadline(state, episode, now),
         staging = %{
           run_id: episode["run_id"],
           elements: lineage_elements(state, episode["run_id"]),
           steer: episode["ordinary_steer"],
           resources: state.run_resources[episode["run_id"]],
           deadline: deadline,
           excerpt_allowance: 0
         },
         project = %{
           "class" => "project_resource",
           "receipt_revision" => 2,
           "disposition" => "not_evaluated_required_failure",
           "detail" => nil
         },
         {:ok, choice} <- ordinary_compaction_tail(state, staging, :automatic, project, check),
         true <- choice.eligible_unit_count > 0 do
      propose_maintenance_request(state, choice.eligible_unit_count, now, check)
    else
      false -> {:error, :compaction_no_progress}
      result -> result
    end
  end

  # Concept: an irreducible excerpt ends the episode and its parent before a
  # provider attempt exists.
  # Technical depth: no complete maintenance request was measured, so this
  # accepted named failure has no numeric observation. Replay reselects the
  # exact frozen source at the retained clock before accepting the refusal.
  defp propose_maintenance_source_refusal(state, now, check) do
    episode = state.maintenance_episodes[state.active_maintenance]
    run_id = episode["run_id"]
    work = state.pending_work[run_id]
    configuration = run_configuration(state, run_id)

    refusal =
      unavailable_context_refusal(
        state,
        run_id,
        configuration,
        next_turn_number(work),
        "compaction_excerpt_budget_too_small"
      )

    terminal =
      state
      |> run_terminal_record(run_id, "failed", %{})
      |> Map.put("failure", context_failure(refusal))

    with {:ok, proposal} <-
           build_internal_proposal(
             state,
             episode["episode_id"] <> ":source-refusal",
             [refusal, terminal],
             now
           ),
         :ok <- check.() do
      {:ok, proposal}
    end
  end

  # Concept: a protected ordinary tail that remains too large cannot be
  # repaired by another summary.
  # Technical depth: remeasure the exact minimum tail and retain its ordinary
  # v2 dimensions and descriptor counts, bound to the active episode. Initial
  # automatic admission already proved its protected tail fits, while
  # explicit and recovered episodes may reach this boundary directly.
  defp propose_maintenance_source_numeric_refusal(state, now, check) do
    with {:ok, refusal} <- maintenance_source_numeric_refusal(state, now, check),
         episode = state.maintenance_episodes[state.active_maintenance],
         terminal =
           state
           |> run_terminal_record(episode["run_id"], "failed", %{})
           |> Map.put("failure", context_failure(refusal)),
         {:ok, proposal} <-
           build_internal_proposal(
             state,
             episode["episode_id"] <> ":source-numeric-refusal",
             [refusal, terminal],
             now
           ),
         :ok <- check.() do
      {:ok, proposal}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_context_refusal}
    end
  end

  defp maintenance_source_numeric_refusal(state, now, check) do
    case state.maintenance_episodes[state.active_maintenance] do
      %{} = episode ->
        case maintenance_instruction_budget(episode) do
          {:refused, %{} = measurement} ->
            maintenance_system_numeric_refusal(state, episode, now, check, measurement)

          :ok ->
            ordinary_source_numeric_refusal(state, now, check)

          {:error, _} = error ->
            error
        end

      _ ->
        {:error, :invalid_context_refusal}
    end
  end

  defp ordinary_source_numeric_refusal(state, now, check) do
    with {:ok, episode, measurement} <- maintenance_source_numeric_measurement(state, now, check),
         {:refused, failure} <- measurement.admission,
         work = state.pending_work[episode["run_id"]],
         {:refused, refusal} <-
           context_refusal_result(
             state,
             measurement.record,
             failure,
             work,
             next_turn_number(work)
           ) do
      {:ok, Map.put(refusal, "episode_id", episode["episode_id"])}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_context_refusal}
    end
  end

  # Concept: an overlarge captured summarizer system message is a maintenance
  # measurement even though no source bytes have been traversed.
  # Technical depth: its sole descriptor is the exact captured system message.
  # The receipt's digest and cost come from that descriptor; a second source
  # projection would invent data after the accepted preflight-order refusal.
  defp maintenance_system_numeric_refusal(state, episode, now, check, raw) do
    capture = episode["maintenance_configuration"]
    instructions = capture["instructions"]
    system = %{"role" => "system", "content" => instructions["rendered_bytes"]}

    request = %{
      messages: [system],
      tools: [],
      continuation: nil,
      model: capture["selection"]["model"]
    }

    project = %{
      "class" => "project_resource",
      "receipt_revision" => 2,
      "disposition" => "not_evaluated_required_failure",
      "detail" => nil
    }

    with {:refused, ^raw} <- selected_maintenance_source_result(state, now, check),
         {:ok, receipt} <-
           reference_context_receipt(
             request,
             [context_source(SessionConfiguration.instruction_source(capture), "system")],
             project,
             capture["context_token_budget"],
             nil
           ),
         true <- receipt["provider_estimated_tokens"] == raw["observed"],
         work = state.pending_work[episode["run_id"]],
         compact =
           compact_refusal(
             receipt,
             raw,
             work,
             next_turn_number(work),
             %{system: 1, session: 0, steer: 0, tools: 0, project: 0, resources: 0}
           ),
         refusal = configured_refusal(compact, episode["configuration_version"], raw),
         refusal =
           refusal
           |> put_in(["failure", "measurement_scope"], "maintenance")
           |> Map.put("measurement_scope", "maintenance")
           |> Map.put("episode_id", episode["episode_id"]),
         :ok <- check.() do
      {:ok, refusal}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_context_refusal}
    end
  end

  defp maintenance_source_numeric_measurement(state, now, check) do
    episode = state.maintenance_episodes[state.active_maintenance]

    with %{"stage" => stage, "run_id" => run_id} <- episode,
         true <- stage in ["source_preparation", "checkpoint_committed"],
         true <- episode["attempts"] < episode["bounds"]["max_attempts"],
         :ok <- maintenance_instruction_budget(episode),
         {:refused, %{} = raw} <- selected_maintenance_source_result(state, now, check),
         {:ok, units} <- compaction_units(state, run_id),
         tail = Enum.drop_while(units, &(not &1.protected?)),
         true <- tail != [],
         {:ok, deadline} <- maintenance_request_deadline(state, episode, now),
         staging = %{
           run_id: run_id,
           elements: Enum.flat_map(tail, & &1.elements),
           steer: episode["ordinary_steer"],
           resources: state.run_resources[run_id],
           deadline: deadline,
           excerpt_allowance: 0
         },
         {selected, project, header} <- protected_tail_inputs(state, run_id),
         {:ok, measurement} <-
           checkpoint_projection_measurement(state, staging, project, header, check, selected),
         {:refused, ^raw} <- measurement.admission do
      {:ok, episode, measurement}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_context_refusal}
    end
  end

  defp protected_tail_inputs(state, run_id) do
    case frozen_context(state, run_id) do
      nil ->
        {[],
         %{
           "class" => "project_resource",
           "receipt_revision" => 2,
           "disposition" => "not_evaluated_required_failure",
           "detail" => nil
         }, Loopex.Runtime.ResourceContext.initial_header(state.run_resources[run_id])}

      frozen ->
        {frozen.selected, frozen.project, frozen.resources}
    end
  end

  @doc false
  def propose_maintenance_request(state, eligible_count, now, check) do
    with {:ok, record} <- preflight_maintenance_request(state, eligible_count, now, check),
         {:ok, opened} <-
           ProviderAttempt.opened_record(%{
             episode_id: record["episode_id"],
             summary_ordinal: record["summary_ordinal"],
             purpose: "compaction",
             operation_id: record["operation_id"],
             attempt: 1,
             staged_request_digest: record["staged_request_digest"]
           }),
         {:ok, proposal} <-
           internal_proposal(state, record["operation_id"] <> ":request", [record, opened]),
         :ok <- check.() do
      {:ok, proposal}
    end
  end

  # Concept: a further summary must consume new raw units after useful progress.
  # Technical depth: derive its ordinal from the committed checkpoint, preserve
  # the episode capture and deadline, and refuse another request when the current
  # substitution already fits. The next request/open pair promotes this derived
  # ordinal; no separate advancement fact or summary-only cycle is admitted.
  defp maintenance_source_episode(state, now, check) do
    with %{} = episode <- state.maintenance_episodes[state.active_maintenance],
         :ok <- maintenance_source_owner(state, episode),
         :ok <- maintenance_source_clock(state, episode, now),
         :ok <- maintenance_request_capacity(state, episode) do
      case episode do
        %{"stage" => "source_preparation", "attempts" => 0} ->
          {:ok, episode}

        %{"stage" => "checkpoint_committed", "checkpoint_id" => id} ->
          cond do
            id != state.active_checkpoint or now < state.checkpoints[id]["committed_at"] ->
              {:error, :context_projection_invalid}

            episode["attempts"] >= episode["bounds"]["max_attempts"] ->
              {:error, :maintenance_attempts_exhausted}

            true ->
              case maintenance_checkpoint_completion_record(state, now, check) do
                {:error, {:checkpoint_requires_more_progress, _refusal}} ->
                  {:ok, Map.update!(episode, "summary_ordinal", &(&1 + 1))}

                {:ok, _completion} ->
                  {:error, :maintenance_targets_fit}

                {:error, _} = error ->
                  error
              end
          end

        _ ->
          {:error, :context_projection_invalid}
      end
    else
      {:error, _} = error -> error
      _ -> {:error, :context_projection_invalid}
    end
  end

  # Concept: summaries cover the owning session or its active run directly.
  # Technical depth: an explicit compact has no synthetic run or staging turn.
  # Its pending command, idle ordinary state and current capture bind source
  # preparation; run-owned episodes retain their existing admission fence.
  defp maintenance_scope(%{kind: "standalone_maintenance_episode_admitted_v1"}), do: :session
  defp maintenance_scope(episode), do: episode["run_id"]

  defp maintenance_source_owner(
         state,
         %{kind: "standalone_maintenance_episode_admitted_v1"} = episode
       ) do
    case state.pending_compact do
      %{"episode_id" => id, "command_id" => command, "abort_command_id" => nil}
      when id == state.active_maintenance ->
        if id == episode["episode_id"] and command == episode["command_id"] and
             is_nil(state.active_run_id) and state.pending_work == %{} and
             is_nil(state.aborting) and is_nil(state.open_interaction) and
             is_nil(state.follow_up),
           do: :ok,
           else: {:error, :maintenance_not_quiescent}

      _ ->
        {:error, :maintenance_not_quiescent}
    end
  end

  defp maintenance_source_owner(state, episode) do
    case maintenance_admission_context(state, episode["run_id"]) do
      {:ok, _, _} -> :ok
      error -> error
    end
  end

  defp maintenance_prior_summary(%{active_checkpoint: nil}), do: nil

  defp maintenance_prior_summary(state),
    do: state.checkpoints[state.active_checkpoint]["summary"]

  defp maintenance_source_clock(
         _state,
         %{kind: "standalone_maintenance_episode_admitted_v1"} = episode,
         now
       ) do
    cond do
      not is_integer(now) or now < episode["admitted_at"] or now > @uint64_max ->
        {:error, :context_projection_invalid}

      now >= episode["deadline"] ->
        {:error, :standalone_deadline_reached}

      true ->
        :ok
    end
  end

  defp maintenance_source_clock(state, episode, now) do
    cond do
      not is_integer(now) or now < episode["admitted_at"] or now > @uint64_max ->
        {:error, :context_projection_invalid}

      is_integer(retained_run_deadline(state, episode["run_id"])) and
          now >= retained_run_deadline(state, episode["run_id"]) ->
        {:error, :run_deadline_reached}

      episode["attempts"] == 0 and now >= episode["preparation_deadline"] ->
        {:error, :compaction_preparation_deadline}

      true ->
        :ok
    end
  end

  defp maintenance_request_deadline(
         _state,
         %{kind: "standalone_maintenance_episode_admitted_v1"} = episode,
         _now
       ),
       do: {:ok, episode["deadline"]}

  defp maintenance_request_deadline(state, episode, now) do
    case Map.get(state.deadlines, episode["run_id"]) do
      nil ->
        duration = episode["bounds"]["deadline_ms"]

        if now <= @uint64_max - duration,
          do:
            {:ok,
             min(
               now + duration,
               retained_run_deadline(state, episode["run_id"]) || now + duration
             )},
          else: {:error, :maintenance_deadline_unrepresentable}

      deadline ->
        {:ok, deadline}
    end
  end

  defp maintenance_request_capacity(
         _state,
         %{kind: "standalone_maintenance_episode_admitted_v1"} = episode
       ) do
    if episode["attempts"] < episode["bounds"]["max_attempts"] and
         episode["bounds"]["token_budget"] - episode["usage"]["total_tokens"] >= 1_024,
       do: :ok,
       else: {:error, :maintenance_bounds_exhausted}
  end

  defp maintenance_request_capacity(state, episode) do
    run = episode["run_id"]
    {_bounds, charged} = accounting(state, run)

    if maintenance_parent_call_units(state, run) < episode["bounds"]["max_turns"] and
         episode["bounds"]["token_budget"] - charged.tokens >= 1_024,
       do: :ok,
       else: {:error, :maintenance_bounds_exhausted}
  end

  defp maintenance_parent_call_units(state, run) do
    ordinary = next_turn_number(state.pending_work[run]) - 1

    maintenance =
      state.maintenance_episodes
      |> Map.values()
      |> Enum.filter(&(&1["run_id"] == run))
      |> Enum.reduce(0, &(&1["attempts"] + &2))

    ordinary + maintenance
  end

  defp maintenance_instruction_budget(episode) do
    capture = episode["maintenance_configuration"]

    bytes =
      Canonical.encode(%{
        "role" => "system",
        "content" => capture["instructions"]["rendered_bytes"]
      })

    ContextAdmission.preflight_required_candidate(episode, %{
      system_class_tokens: Bounds.estimate(bytes),
      system_class_token_ceiling: capture["system_class_tokens"],
      provider_estimated_tokens: 0,
      context_token_budget: capture["context_token_budget"],
      context_record_byte_ceiling: Store.max_item_bytes(),
      context_record_depth_limit: Store.max_item_depth(),
      context_record_cardinality_limit: Store.max_item_cardinality()
    })
  end

  defp maintenance_source_streams(state, units, check) do
    binding = state.tool_selection && state.tool_selection["artifact_read"]

    Enum.reduce_while(units, {:ok, []}, fn unit, {:ok, streams} ->
      with :ok <- check.(),
           {:ok, stream} <-
             Loopex.Runtime.LineageProjection.stream(
               prepared_elements(state, unit.elements),
               binding,
               state.artifact_sources,
               %{},
               0,
               check
             ) do
        {:cont, {:ok, [stream | streams]}}
      else
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, streams} -> {:ok, Enum.reverse(streams)}
      error -> error
    end
  end

  # Concept: configured staging and compaction probes render the same request.
  # Technical depth: a run uses its captured configuration; a settled session
  # probe uses the current committed configuration and whole canonical history.
  # A session probe has no run, steer, continuation or optional resource intake.
  # Both paths construct plain request/receipt data without admission or IO.
  @doc false
  @spec reference_model_candidate(t(), map(), list(), map(), map() | nil) ::
          {:ok, map()} | {:error, term()}
  def reference_model_candidate(state, staging, selected, project, header) do
    with {:ok, scope, configuration, budget} <-
           reference_candidate_scope(state, staging, selected, header),
         {:ok, text} <- Instructions.render(configuration["instructions"]),
         {:ok, entries, projection} <-
           projected_lineage(
             state,
             scope,
             Map.get(staging, :excerpt_allowance, 2_048),
             staging.elements
           ),
         entries = replace_checkpoint_entries(entries, staging),
         {blocks, sources} = Enum.unzip(selected),
         steer = staging.steer,
         messages =
           [%{"role" => "system", "content" => text}] ++
             Enum.map(blocks, &%{"role" => "user", "content" => &1}) ++
             Enum.map(entries, &elem(&1, 1)) ++
             if(steer, do: [%{"role" => "user", "content" => steer.content}], else: []),
         {:ok, continuation} <-
           if(scope == :session,
             do: {:ok, nil},
             else:
               model_continuation(
                 state,
                 scope,
                 messages,
                 steer && steer.command_id,
                 projection
               )
           ),
         {:ok, request} <-
           Loopex.Model.request(configuration["model"], messages,
             continuation: continuation,
             tools: state.tool_selection["definitions"],
             sampling: SessionConfiguration.sampling(configuration),
             deadline: staging.deadline
           ),
         sources =
           [context_source(SessionConfiguration.instruction_source(configuration), "system")] ++
             sources ++
             Enum.map(entries, fn {reference, _} -> context_source(reference, "session") end) ++
             if(steer,
               do: [
                 context_source(
                   %{
                     "kind" => "session_steer",
                     "run_id" => scope,
                     "command_id" => steer.command_id
                   },
                   "session"
                 )
               ],
               else: []
             ),
         {:ok, receipt} <-
           reference_context_receipt(
             request,
             sources,
             project,
             budget,
             header
           ) do
      {:ok, %{request: request, receipt: receipt, projection: projection}}
    else
      nil -> {:error, :invalid_session_configuration}
      {:error, _} = error -> error
    end
  end

  # Concept: standalone measurement cannot borrow an unfinished run's settings.
  # Technical depth: the explicit scope is transient and never enters a request
  # or source reference. It permits no invented run ID, steer or fresh optional
  # resource data; replayed terminal history retains its original provenance.
  defp reference_candidate_scope(state, %{scope: :session, steer: nil} = staging, [], nil) do
    if not Map.has_key?(staging, :run_id) and is_nil(state.active_run_id) and
         state.pending_work == %{} and is_nil(state.open_interaction) and
         is_nil(state.aborting) and is_nil(state.follow_up) and is_map(state.configuration) do
      {:ok, :session, state.configuration, state.configuration["context_token_budget"]}
    else
      {:error, :context_projection_invalid}
    end
  end

  defp reference_candidate_scope(_state, %{scope: :session}, _selected, _header),
    do: {:error, :context_projection_invalid}

  defp reference_candidate_scope(state, %{run_id: run_id}, _selected, _header)
       when is_binary(run_id) do
    case run_configuration(state, run_id) do
      nil -> {:error, :invalid_session_configuration}
      configuration -> {:ok, run_id, configuration, context_token_budget(state, run_id)}
    end
  end

  defp reference_candidate_scope(_, _, _, _), do: {:error, :context_projection_invalid}

  defp replace_checkpoint_entries(entries, staging) do
    case Map.fetch(staging, :checkpoint_entries) do
      :error ->
        entries

      {:ok, checkpoint} ->
        checkpoint ++
          Enum.reject(entries, fn {source, _} -> source["kind"] == "compaction_summary" end)
    end
  end

  # Concept: standalone compact measures its current canonical session directly.
  # Technical depth: this transient Store sizing view binds the admitted command,
  # derived episode and current configuration to the exact request, receipt and
  # projection. Its seven members contain no run/turn/operation identity. The
  # shared fixed point and hard-limit order apply; thinking headroom is disabled.
  # Local tail/substitution probes may replace only elements/checkpoint entries.
  # No clock is read, artifact fetched, record committed or attempt opened.
  @doc false
  @spec preflight_standalone_context(t(), integer(), function(), map()) ::
          {:ok, map()} | {:error, term()}
  def preflight_standalone_context(state, deadline, check, replacement \\ %{})

  def preflight_standalone_context(%__MODULE__{} = state, deadline, check, replacement)
      when is_integer(deadline) and deadline in 1..@uint64_max and is_function(check, 0) and
             is_map(replacement) do
    with %{"abort_command_id" => nil} = pending <- state.pending_compact,
         true <- Enum.all?(Map.keys(replacement), &(&1 in [:elements, :checkpoint_entries])),
         :ok <- check.(),
         elements = Map.get(replacement, :elements, lineage_elements(state, :session)),
         true <- is_list(elements),
         staging =
           replacement
           |> Map.merge(%{
             scope: :session,
             elements: elements,
             steer: nil,
             deadline: deadline,
             excerpt_allowance: 0
           }),
         project = %{
           "class" => "project_resource",
           "receipt_revision" => 2,
           "disposition" => "not_evaluated_required_failure",
           "detail" => nil
         },
         {:ok, candidate} <- reference_model_candidate(state, staging, [], project, nil),
         :ok <- check.(),
         record = %{
           :kind => "compact_context_probe_v1",
           "command_id" => pending["command_id"],
           "episode_id" => pending["episode_id"],
           "configuration_version" => state.configuration["configuration_version"],
           "request" => encode_plain(candidate.request),
           "context_receipt" => candidate.receipt,
           "lineage_projection" => candidate.projection
         },
         {:ok, fixed, admission} <-
           preflight_context_candidate(record, state.configuration, false),
         :ok <- check.(),
         rendering =
           SessionConfiguration.preflight_history(
             state.configuration,
             uncompacted_elements(state, elements),
             state.run_order
           ),
         :ok <- check.() do
      failure =
        case admission do
          :ok ->
            nil

          {:refused, measurement} ->
            Map.take(measurement, ~w(dimension observed limit))
            |> Map.merge(%{
              "version" => 2,
              "category" => "context_budget_exceeded",
              "retryable" => false,
              "measurement_scope" => "ordinary",
              "hard_limit" => measurement["limit"]
            })
        end

      {:ok,
       Map.merge(candidate, %{
         receipt: fixed["context_receipt"],
         record: fixed,
         failure: failure,
         rendering: rendering
       })}
    else
      {:error, _} = error -> error
      _ -> {:error, :context_projection_invalid}
    end
  end

  def preflight_standalone_context(_, _, _, _), do: {:error, :context_projection_invalid}

  # Concept: explicit compaction releases terminal history before summarizer work.
  # Technical depth: hard failure wins over rendering-only repair; an already
  # fitting history still releases every eligible terminal unit. The protected
  # minimum keeps the prior checkpoint and must fit/render before host settings
  # can justify a dispatch. Rendering repair pins the last original tool source.
  # This measured plan is transient; episode admission retains its capture.
  @doc false
  @spec preflight_standalone_compaction(t(), integer(), function()) ::
          {:ok, map()} | {:refused, term()} | {:error, term()}
  def preflight_standalone_compaction(state, deadline, check) do
    with {:ok, before} <- preflight_standalone_context(state, deadline, check),
         {:ok, units} <- compaction_units(state, :session),
         {:ok, choice} <-
           Conversation.compaction_tail(units, :explicit, fn tail ->
             elements = Enum.flat_map(tail, & &1.elements)

             with {:ok, probe} <-
                    preflight_standalone_context(state, deadline, check, %{elements: elements}) do
               case {probe.failure, probe.rendering} do
                 {nil, :ok} ->
                   tokens =
                     probe.receipt["blocks"]
                     |> Enum.filter(
                       &(&1["provenance_class"] == "session" and
                           &1["source_reference"]["kind"] != "compaction_summary")
                     )
                     |> Enum.reduce(0, &(&1["token_cost"] + &2))

                   {:ok, tokens}

                 {%{} = failure, _} ->
                   {:refused, failure}

                 {nil, {:error, :canonical_history_rendering_unsupported}} ->
                   {:refused, :canonical_history_rendering_unsupported}

                 {nil, {:error, _} = error} ->
                   error
               end
             end
           end),
         {:ok, last_tool_source} <-
           Conversation.last_terminal_tool_source(
             uncompacted_elements(state, lineage_elements(state, :session)),
             state.run_order
           ),
         :ok <- check.() do
      trigger =
        cond do
          is_map(before.failure) ->
            "ordinary_limit"

          before.rendering == {:error, :canonical_history_rendering_unsupported} ->
            "canonical_rendering"

          before.rendering == :ok ->
            "explicit"

          true ->
            nil
        end

      if trigger do
        {:ok,
         Map.merge(choice, %{
           origin: "explicit",
           trigger: trigger,
           targets: nil,
           last_offending_source:
             if(trigger == "canonical_rendering", do: last_tool_source, else: nil),
           before: before
         })}
      else
        {:error, :context_projection_invalid}
      end
    end
  end

  # Concept: choose whole retained units against the ordinary request's real cost.
  # Technical depth: q=0 excludes removable excerpts and fresh optional bodies;
  # both legal empty resource headers must fit. Frozen context stays exact.
  # Fit includes captured instructions, tool definitions, steer, continuation,
  # metadata and the complete receipt-bearing record's fixed point. The tail
  # preference counts raw session descriptors, excluding fixed steer and prior
  # checkpoint cost. New thinking exchanges use their derived targets throughout
  # selection; open exchanges keep their exact prefix and hard ceilings. This
  # pure probe never opens an attempt.
  @doc false
  @spec ordinary_compaction_tail(t(), map(), :automatic | :explicit, map(), function()) ::
          {:ok, map()} | {:refused, term()} | {:error, term()}
  def ordinary_compaction_tail(state, staging, origin, project, check)
      when origin in [:automatic, :explicit] and is_function(check, 0) do
    with true <- state.active_run_id == staging.run_id,
         :ok <- check.(),
         configuration when is_map(configuration) <- run_configuration(state, staging.run_id),
         {:ok, units} <- compaction_units(state, staging.run_id) do
      {selected, project, headers} =
        case frozen_context(state, staging.run_id) do
          nil ->
            initial = Loopex.Runtime.ResourceContext.initial_header(staging.resources)
            reserved = initial && Map.put(initial, "status", "retained_content_missing")
            {[], project, Enum.uniq([initial, reserved])}

          frozen ->
            {frozen.selected, frozen.project, [frozen.resources]}
        end

      Conversation.compaction_tail(units, origin, fn tail ->
        elements = Enum.flat_map(tail, & &1.elements)
        probe = staging |> Map.put(:elements, elements) |> Map.put(:excerpt_allowance, 0)

        with :ok <- check.(),
             :ok <-
               SessionConfiguration.preflight_history(
                 configuration,
                 elements,
                 Enum.reject(state.run_order, &(&1 == staging.run_id))
               ) do
          Enum.reduce_while(headers, {:ok, 0}, fn header, {:ok, _} ->
            with :ok <- check.(),
                 {:ok, candidate} <-
                   reference_model_candidate(state, probe, selected, project, header),
                 record =
                   model_request_record(
                     state,
                     staging.run_id,
                     candidate.request,
                     [
                       applied_steer: staging.steer && staging.steer.command_id,
                       context_receipt: candidate.receipt,
                       lineage_projection: candidate.projection
                     ],
                     next_turn_number(state.pending_work[staging.run_id])
                   ),
                 {:ok, fixed} <- admit_context_candidate(record, state),
                 :ok <- check.() do
              tokens =
                fixed["context_receipt"]["blocks"]
                |> Enum.filter(
                  &(&1["provenance_class"] == "session" and
                      &1["source_reference"]["kind"] not in [
                        "session_steer",
                        "compaction_summary"
                      ])
                )
                |> Enum.reduce(0, &(&1["token_cost"] + &2))

              {:cont, {:ok, tokens}}
            else
              failure -> {:halt, failure}
            end
          end)
        else
          {:error, :canonical_history_rendering_unsupported} = error ->
            {:refused, elem(error, 1)}

          failure ->
            failure
        end
      end)
    else
      false -> {:error, :maintenance_not_quiescent}
      nil -> {:error, :invalid_session_configuration}
      {:error, _} = error -> error
    end
  end

  # Concept: a valid summary becomes useful only after exact substitution proves progress.
  # Technical depth: the pending reply is already settled and charged. This
  # pending-checkpoint probe authenticates its whole-unit cut against originals,
  # renders the owner-computed summary provenance, and measures both ordinary
  # q=0 candidates through the same complete record fixed point. Standalone
  # candidates retain their command identity and captured cutoff. It captures
  # no public or journal fact and consumes no provider attempt. Size-triggered
  # progress may remain above hard limits but decreases both bytes and tokens;
  # rendering repair advances raw coverage and must fit every hard limit.
  @doc false
  @spec preflight_maintenance_checkpoint(t(), integer(), function()) ::
          {:ok, map()} | {:error, term()}
  def preflight_maintenance_checkpoint(state, now, check)
      when is_function(check, 0) do
    with {:ok, candidate} <- pending_checkpoint_measurements(state, now, check) do
      if checkpoint_progress?(candidate),
        do: {:ok, candidate},
        else: {:error, :compaction_no_progress}
    end
  end

  defp checkpoint_progress?(%{trigger: "canonical_rendering"} = candidate),
    do: candidate.consumed_range["unit_count"] > 0 and match?({:ok, _}, candidate.after.admission)

  defp checkpoint_progress?(candidate),
    do:
      candidate.after.record_bytes < candidate.before.record_bytes and
        candidate.after.tokens < candidate.before.tokens

  defp pending_checkpoint_measurements(state, now, check) do
    with %{"stage" => "checkpoint_pending", "summary" => summary} = episode <-
           state.maintenance_episodes[state.active_maintenance],
         :ok <- pending_checkpoint_owner(state, episode, now),
         true <- episode["prior_checkpoint_id"] == state.active_checkpoint,
         :ok <- pending_checkpoint_capacity(state, episode),
         :ok <- check.(),
         {:ok, units} <- compaction_units(state, maintenance_scope(episode)),
         count = episode["covered_range"]["unit_count"],
         true <- count > 0 and count <= length(Enum.take_while(units, &(not &1.protected?))),
         {:ok, consumed} <- maintenance_covered_range(state, episode, units, count, check),
         true <- consumed == episode["covered_range"],
         {:ok, range} <- maintenance_checkpoint_coverage(state, episode, consumed, count, check),
         {:ok, captured} <-
           Loopex.Runtime.CompactionSummary.capture(
             summary,
             range["digest"],
             maintenance_prior_summary(state),
             episode["source_excerpted"]
           ),
         checkpoint_id =
           stable_id("compaction-checkpoint", episode["episode_id"], episode["summary_ordinal"]),
         {:ok, entry} <- Loopex.Runtime.CompactionSummary.project(checkpoint_id, captured),
         {:ok, before, after_value} <-
           pending_checkpoint_projections(state, episode, units, count, entry, check),
         :ok <- check.() do
      {:ok,
       %{
         checkpoint_id: checkpoint_id,
         prior_checkpoint_id: state.active_checkpoint,
         covered_range: range,
         consumed_range: consumed,
         summary: captured,
         entry: entry,
         trigger: episode["trigger"],
         before: before,
         after: after_value
       }}
    else
      false -> pending_checkpoint_refusal(state, now)
      {:error, _} = error -> error
      _ -> {:error, :no_pending_maintenance_checkpoint}
    end
  end

  # Concept: a pending summary remains under its actual owner's captured cutoff.
  # Technical depth: standalone measurement requires the idle command's current
  # binding and fixed episode deadline; run-owned measurement retains its active
  # run and deadline. Neither reads a new setting, clock or provider result.
  defp pending_checkpoint_owner(
         state,
         %{kind: "standalone_maintenance_episode_admitted_v1"} = episode,
         now
       ) do
    with :ok <- maintenance_source_owner(state, episode),
         true <- episode["trigger"] in ~w(explicit ordinary_limit canonical_rendering),
         true <- is_integer(now) and now >= episode["request_staged_at"] and now <= @uint64_max,
         true <- now < episode["deadline"] do
      :ok
    else
      false -> pending_checkpoint_refusal(state, now)
      {:error, _} = error -> error
    end
  end

  defp pending_checkpoint_owner(state, episode, now) do
    if episode["trigger"] in ~w(ordinary_limit thinking_headroom) and is_nil(state.aborting) and
         episode["run_id"] == state.active_run_id and is_integer(now) and
         now >= episode["request_staged_at"] and now <= @uint64_max and
         is_integer(retained_run_deadline(state, episode["run_id"])) and
         now < retained_run_deadline(state, episode["run_id"]),
       do: :ok,
       else: pending_checkpoint_refusal(state, now)
  end

  # Concept: both checkpoint owners compare the exact context they will expose.
  # Technical depth: standalone probes use their command-owned whole-session
  # record, existing fixed-point receipt and current hard limits. Run probes
  # retain frozen steer/resources and their run-owned record. Both substitute
  # one projected summary plus the unsummarized raw tail without altering history.
  defp pending_checkpoint_projections(
         state,
         %{kind: "standalone_maintenance_episode_admitted_v1"} = episode,
         units,
         count,
         entry,
         check
       ) do
    with {:ok, before} <-
           standalone_checkpoint_projection(
             state,
             episode,
             %{elements: Enum.flat_map(units, & &1.elements)},
             check
           ),
         {:ok, after_value} <-
           standalone_checkpoint_projection(
             state,
             episode,
             %{
               elements: units |> Enum.drop(count) |> Enum.flat_map(& &1.elements),
               checkpoint_entries: [entry]
             },
             check
           ) do
      {:ok, before, after_value}
    end
  end

  defp pending_checkpoint_projections(state, episode, units, count, entry, check) do
    staging = %{
      run_id: episode["run_id"],
      elements: Enum.flat_map(units, & &1.elements),
      steer: episode["ordinary_steer"],
      resources: state.run_resources[episode["run_id"]],
      deadline: retained_run_deadline(state, episode["run_id"]),
      excerpt_allowance: 0
    }

    project = %{
      "class" => "project_resource",
      "receipt_revision" => 2,
      "disposition" => "not_evaluated_required_failure",
      "detail" => nil
    }

    header = Loopex.Runtime.ResourceContext.initial_header(staging.resources)
    header = if(header, do: Map.put(header, "status", "retained_content_missing"), else: nil)

    after_staging =
      staging
      |> Map.put(:elements, units |> Enum.drop(count) |> Enum.flat_map(& &1.elements))
      |> Map.put(:checkpoint_entries, [entry])

    with {:ok, before} <-
           checkpoint_projection_measurement(state, staging, project, header, check),
         {:ok, after_value} <-
           checkpoint_projection_measurement(state, after_staging, project, header, check),
         do: {:ok, before, after_value}
  end

  defp standalone_checkpoint_projection(state, episode, replacement, check) do
    with {:ok, measured} <-
           preflight_standalone_context(state, episode["deadline"], check, replacement) do
      {:ok,
       Map.merge(measured, %{
         record_bytes: measured.receipt["record_byte_cost"],
         tokens: measured.receipt["provider_estimated_tokens"],
         admission:
           if(measured.failure, do: {:refused, measured.failure}, else: {:ok, measured.record})
       })}
    end
  end

  # Concept: checkpoint commitment retains a useful summary without completing its run.
  # Technical depth: the owner recomputes coverage and exact progress from the
  # settled reply. One proposal contains the private checkpoint and its public
  # event. The Store fence owns transaction identity and uncertain resolution;
  # no model call, accounting charge or raw conversation fact is added here.
  @doc false
  @spec propose_maintenance_checkpoint(t(), integer(), function()) ::
          {:ok, proposal()} | {:error, term()}
  def propose_maintenance_checkpoint(state, now, check) when is_function(check, 0) do
    with {:ok, candidate} <- preflight_maintenance_checkpoint(state, now, check),
         record = maintenance_checkpoint_record(state, candidate, now),
         {:ok, _} <- Store.admit_bounded(record),
         {:ok, proposal} <-
           internal_proposal(state, candidate.checkpoint_id <> ":checkpoint", record),
         :ok <- check.() do
      {:ok, proposal}
    end
  end

  # Concept: a settled summary that makes no progress ends its parent once.
  # Technical depth: preserve the last minimum ordinary projection's counts,
  # estimate and digest, with no invented numeric failure or record cost. The
  # episode terminal, measured refusal and parent terminal share one Store fence.
  # Replay repeats the exact substitution against retained originals and rejects
  # a failed progress claim for a useful summary. Settled usage is never charged again.
  @doc false
  @spec propose_maintenance_nonprogress(t(), integer(), function()) ::
          {:ok, proposal()} | {:error, term()}
  def propose_maintenance_nonprogress(state, now, check) when is_function(check, 0) do
    with {:ok, refusal} <- maintenance_nonprogress_refusal(state, now, check),
         terminal =
           state
           |> run_terminal_record(refusal["run_id"], "failed", %{})
           |> Map.put("failure", context_failure(refusal)),
         {:ok, proposal} <-
           build_internal_proposal(
             state,
             state.active_maintenance <> ":nonprogress",
             [refusal, terminal],
             now
           ),
         :ok <- check.() do
      {:ok, proposal}
    end
  end

  defp maintenance_nonprogress_refusal(state, now, check) do
    with {:ok, candidate} <- pending_checkpoint_measurements(state, now, check),
         false <- checkpoint_progress?(candidate),
         record = candidate.before.record,
         {:ok, counts} <- context_descriptor_counts(record) do
      run = state.active_run_id
      receipt = record["context_receipt"]
      configuration = run_configuration(state, run)
      turn = next_turn_number(state.pending_work[run])

      refusal =
        unavailable_context_refusal(state, run, configuration, turn, "compaction_no_progress")
        |> Map.merge(%{
          "failure" => %{
            "version" => 2,
            "category" => "context_preparation_failed",
            "retryable" => false,
            "measurement_scope" => "ordinary",
            "cause" => "compaction_no_progress"
          },
          "projection_state" => "measured",
          "measurement_scope" => "ordinary",
          "system_message_count" => counts.system,
          "session_message_count" => counts.session,
          "steer_message_count" => counts.steer,
          "tool_definition_count" => counts.tools,
          "provider_estimated_tokens" => receipt["provider_estimated_tokens"],
          "ordered_descriptor_digest" => receipt["ordered_descriptor_digest"],
          "project_disposition" => refusal_project_disposition(receipt, counts)
        })

      {:ok, refusal}
    else
      true -> {:error, :checkpoint_makes_progress}
      {:error, _} = error -> error
    end
  end

  # Concept: a fitted checkpoint releases its run or completes its compact command.
  # Technical depth: remeasure each owner's captured projection. Run completion
  # has no run terminal; standalone completion shares the episode-terminal
  # transaction. Neither charges again. Partial progress keeps the same episode,
  # capture and deadline until further maintenance or a truthful ending settles it.
  @doc false
  @spec propose_maintenance_checkpoint_completion(t(), integer(), function()) ::
          {:ok, proposal()} | {:error, term()}
  def propose_maintenance_checkpoint_completion(state, now, check) when is_function(check, 0) do
    with {:ok, record} <- maintenance_checkpoint_completion_record(state, now, check),
         {:ok, proposal} <-
           internal_proposal(state, state.active_maintenance <> ":completed", record),
         :ok <- check.() do
      {:ok, proposal}
    end
  end

  defp maintenance_checkpoint_completion_record(state, now, check) do
    with {:ok, episode, measurement} <- committed_checkpoint_measurement(state, now, check),
         {:ok, _} <- measurement.admission do
      result = %{
        "disposition" => "checkpointed",
        "checkpoint_id" => episode["checkpoint_id"],
        "failure" => nil,
        "usage" => episode["usage"],
        "cleanup" => "confirmed"
      }

      record = %{
        :kind => "maintenance_episode_terminal_v1",
        "episode_id" => episode["episode_id"],
        "observed_at" => now,
        "result" => result
      }

      if episode.kind == "standalone_maintenance_episode_admitted_v1",
        do:
          {:ok,
           record
           |> Map.put(:kind, "compact_command_completed_v1")
           |> Map.put("command_id", episode["command_id"])},
        else: {:ok, record}
    else
      {:refused, refusal} -> {:error, {:checkpoint_requires_more_progress, refusal}}
      {:error, _} = error -> error
    end
  end

  defp committed_checkpoint_measurement(%{pending_compact: %{}} = state, now, check) do
    with %{
           :kind => "standalone_maintenance_episode_admitted_v1",
           "stage" => "checkpoint_committed"
         } = episode <-
           state.maintenance_episodes[state.active_maintenance],
         true <- episode["checkpoint_id"] == state.active_checkpoint,
         true <-
           is_integer(now) and now >= state.checkpoints[state.active_checkpoint]["committed_at"],
         :ok <- pending_checkpoint_owner(state, episode, now),
         :ok <- pending_checkpoint_capacity(state, episode),
         {:ok, measurement} <- standalone_checkpoint_projection(state, episode, %{}, check) do
      {:ok, episode, measurement}
    else
      {:error, _} = error -> error
      _ -> {:error, :no_committed_maintenance_checkpoint}
    end
  end

  defp committed_checkpoint_measurement(state, now, check) do
    with %{"stage" => "checkpoint_committed", "checkpoint_id" => id} = episode <-
           state.maintenance_episodes[state.active_maintenance],
         true <- id == state.active_checkpoint and episode["run_id"] == state.active_run_id,
         true <- is_nil(state.aborting),
         true <-
           is_integer(now) and now >= state.checkpoints[id]["committed_at"] and now <= @uint64_max,
         true <- now < retained_run_deadline(state, episode["run_id"]),
         :ok <- pending_checkpoint_capacity(state, episode),
         staging = %{
           run_id: episode["run_id"],
           elements: lineage_elements(state, episode["run_id"]),
           steer: episode["ordinary_steer"],
           resources: state.run_resources[episode["run_id"]],
           deadline: retained_run_deadline(state, episode["run_id"]),
           excerpt_allowance: 0
         },
         project = %{
           "class" => "project_resource",
           "receipt_revision" => 2,
           "disposition" => "not_evaluated_required_failure",
           "detail" => nil
         },
         header = Loopex.Runtime.ResourceContext.initial_header(staging.resources),
         header =
           (if header do
              Map.put(header, "status", "retained_content_missing")
            else
              nil
            end),
         {:ok, measurement} <-
           checkpoint_projection_measurement(state, staging, project, header, check) do
      {:ok, episode, measurement}
    else
      {:error, _} = error -> error
      false -> pending_checkpoint_refusal(state, now)
      _ -> {:error, :no_committed_maintenance_checkpoint}
    end
  end

  # Concept: an exhausted episode retains partial checkpoints and its actual context failure.
  # Technical depth: four physical attempts are episode evidence, not a parent
  # attempt bound. Rebuild the last minimum ordinary candidate and retain its
  # measured refusal between the episode and parent terminals in one transaction.
  # Replay authenticates the ledger, current projection and captured clock again.
  @doc false
  @spec propose_maintenance_exhaustion(t(), integer(), function()) ::
          {:ok, proposal()} | {:error, term()}
  def propose_maintenance_exhaustion(state, now, check) when is_function(check, 0) do
    with {:ok, refusal} <- maintenance_exhaustion_refusal(state, now, check),
         {:ok, _} <- Store.admit_bounded(refusal),
         terminal =
           state
           |> run_terminal_record(refusal["run_id"], "failed", %{})
           |> Map.put("failure", context_failure(refusal)),
         {:ok, proposal} <-
           build_internal_proposal(
             state,
             state.active_maintenance <> ":exhausted",
             [refusal, terminal],
             now
           ),
         :ok <- check.() do
      {:ok, proposal}
    end
  end

  defp maintenance_exhaustion_refusal(state, now, check) do
    with {:ok, episode, measurement} <- committed_checkpoint_measurement(state, now, check),
         true <- episode["attempts"] == episode["bounds"]["max_attempts"],
         {:refused, failure} <- measurement.admission,
         work = state.pending_work[episode["run_id"]],
         {:refused, refusal} <-
           context_refusal_result(
             state,
             measurement.record,
             failure,
             work,
             next_turn_number(work)
           ) do
      {:ok, Map.put(refusal, "episode_id", episode["episode_id"])}
    else
      false -> {:error, :maintenance_episode_not_exhausted}
      {:ok, _} -> {:error, :maintenance_targets_fit}
      {:error, _} = error -> error
      _ -> {:error, :invalid_context_refusal}
    end
  end

  # Concept: maintenance capacity can end its parent before another summary dispatch.
  # Technical depth: derive the observed call units and token charge from the
  # committed episode ledger. The existing episode/run terminal transaction
  # validates these observations again and retains any useful partial checkpoint.
  @doc false
  @spec propose_maintenance_parent_bound(t(), binary()) :: {:ok, proposal()} | {:error, term()}
  def propose_maintenance_parent_bound(state, run) do
    {bounds, charged} = accounting(state, run)
    calls = maintenance_parent_call_units(state, run)

    detail =
      cond do
        charged.tokens >= bounds.token_budget ->
          %{
            bound: "token_budget",
            observed: charged.tokens,
            declared_limit: bounds.token_budget,
            accounting_source: charged.source && Atom.to_string(charged.source)
          }

        calls >= bounds.max_turns ->
          %{
            bound: "max_turns",
            observed: calls,
            declared_limit: bounds.max_turns,
            accounting_source: charged.source && Atom.to_string(charged.source)
          }

        true ->
          nil
      end

    cond do
      detail ->
        propose_run_terminal(state, run, "bound_reached", detail)

      validate_preparation_failure_cause(state, run, "maintenance_reply_reserve_unavailable") ==
          :ok ->
        propose_context_preparation_failure(state, run, :maintenance_reply_reserve_unavailable)

      true ->
        {:error, :maintenance_bounds_not_reached}
    end
  end

  # Concept: checkpoint ownership and original conversation lineage are distinct.
  # Technical depth: the authenticated episode chooses the private kind and
  # actual owner. Standalone lineage ends at the last original run traversed;
  # its command identity creates no run, deadline or run-accounting entry.
  defp maintenance_checkpoint_record(state, candidate, now) do
    episode = state.maintenance_episodes[state.active_maintenance]
    configuration = episode["maintenance_configuration"]

    owner =
      case episode.kind do
        "standalone_maintenance_episode_admitted_v1" ->
          %{
            :kind => "standalone_compaction_checkpoint_committed_v1",
            "command_id" => episode["command_id"]
          }

        "maintenance_episode_admitted_v1" ->
          %{:kind => "compaction_checkpoint_committed_v1", "run_id" => episode["run_id"]}
      end

    Map.merge(owner, %{
      "checkpoint_id" => candidate.checkpoint_id,
      "episode_id" => episode["episode_id"],
      "summary_ordinal" => episode["summary_ordinal"],
      "committed_at" => now,
      "lineage" => %{
        "session_id" => state.session_id,
        "through_run_id" =>
          if(episode.kind == "standalone_maintenance_episode_admitted_v1",
            do: List.last(state.run_order),
            else: episode["run_id"]
          )
      },
      "covered_range" => candidate.covered_range,
      "consumed_range" => candidate.consumed_range,
      "prior_checkpoint_id" => candidate.prior_checkpoint_id,
      "summary" => candidate.summary,
      "strategy" => "loopex.compaction.reference",
      "strategy_revision" => 3,
      "model" => configuration["selection"]["model"],
      "reasoning" => configuration["selection"]["reasoning"],
      "configuration_version" => episode["configuration_version"],
      "usage" => episode["usage"],
      "source_digest" => episode["source_digest"]
    })
  end

  # Concept: cumulative coverage authenticates originals rather than summaries.
  # Technical depth: authenticate the prior prefix before deriving the new raw
  # boundary. A nil first-kept identity ends that checkpoint's finite lineage;
  # later runs may append new units. Rebuild the prefix and hash original
  # journal records directly. Never hash a previous digest or trust a summed
  # count without proving the exact source identities already substituted.
  defp maintenance_checkpoint_coverage(
         %{active_checkpoint: nil},
         _episode,
         consumed,
         _count,
         _check
       ),
       do: {:ok, consumed}

  defp maintenance_checkpoint_coverage(state, episode, consumed, count, check) do
    prior = state.checkpoints[state.active_checkpoint]
    prior_count = prior["covered_range"]["unit_count"]

    with {:ok, originals} <-
           compaction_units_from(
             state,
             maintenance_scope(episode),
             lineage_elements(state, maintenance_scope(episode))
           ),
         covered = originals |> Enum.take(prior_count) |> Enum.flat_map(& &1.elements),
         true <- MapSet.new(covered, &Conversation.source_reference/1) == state.compacted_sources,
         %{elements: [next | _]} <- Enum.at(originals, prior_count),
         boundary = Conversation.source_reference(next),
         true <- boundary == consumed["first"],
         true <- maintenance_prior_boundary?(state, prior, boundary),
         {:ok, range} <-
           maintenance_covered_range(state, episode, originals, prior_count + count, check),
         true <-
           range["first_kept"] == consumed["first_kept"] and range["last"] == consumed["last"] do
      {:ok, range}
    else
      {:error, _} = error -> error
      _ -> {:error, :context_projection_invalid}
    end
  end

  # Concept: complete coverage ends at the original lineage retained then.
  # Technical depth: nil cannot release an unsummarized historical tail. Its
  # exact old source set must equal the authenticated prefix; a nonnil boundary
  # retains its original identity even when more conversation follows it.
  defp maintenance_prior_boundary?(state, prior, boundary) do
    case prior["covered_range"]["first_kept"] do
      nil ->
        prior_sources =
          state
          |> lineage_elements(prior["lineage"]["through_run_id"])
          |> MapSet.new(&Conversation.source_reference/1)

        prior_sources == state.compacted_sources

      first_kept ->
        first_kept == boundary
    end
  end

  defp pending_checkpoint_capacity(
         _state,
         %{kind: "standalone_maintenance_episode_admitted_v1"} = episode
       ),
       do:
         if(episode["usage"]["total_tokens"] < episode["bounds"]["token_budget"],
           do: :ok,
           else: {:error, :maintenance_bounds_exhausted}
         )

  defp pending_checkpoint_capacity(state, episode) do
    {_bounds, charged} = accounting(state, episode["run_id"])

    if charged.tokens < episode["bounds"]["token_budget"] and
         maintenance_parent_call_units(state, episode["run_id"]) < episode["bounds"]["max_turns"],
       do: :ok,
       else: {:error, :maintenance_bounds_exhausted}
  end

  defp pending_checkpoint_refusal(%{pending_compact: %{}} = state, now) do
    episode = state.maintenance_episodes[state.active_maintenance]

    cond do
      maintenance_abort?(state, episode) -> {:error, :maintenance_not_quiescent}
      not is_integer(now) or now < 0 or now > @uint64_max -> {:error, :clock_out_of_domain}
      now >= episode["deadline"] -> {:error, :standalone_deadline_reached}
      true -> {:error, :context_projection_invalid}
    end
  end

  defp pending_checkpoint_refusal(state, now) do
    episode = state.maintenance_episodes[state.active_maintenance]

    cond do
      not is_nil(state.aborting) ->
        {:error, :maintenance_not_quiescent}

      not is_integer(now) or now < 0 or now > @uint64_max ->
        {:error, :clock_out_of_domain}

      is_map(episode) and is_integer(retained_run_deadline(state, episode["run_id"])) and
          now >= retained_run_deadline(state, episode["run_id"]) ->
        {:error, :run_deadline_reached}

      true ->
        {:error, :compaction_no_progress}
    end
  end

  defp checkpoint_projection_measurement(state, staging, project, header, check, selected \\ []) do
    with :ok <- check.(),
         {:ok, candidate} <- reference_model_candidate(state, staging, selected, project, header),
         record =
           model_request_record(
             state,
             staging.run_id,
             candidate.request,
             [
               context_receipt: candidate.receipt,
               applied_steer: staging.steer && staging.steer.command_id,
               lineage_projection: candidate.projection
             ],
             next_turn_number(state.pending_work[staging.run_id])
           ),
         {:ok, fixed} <- resolve_record_byte_cost(record),
         :ok <- check.() do
      fit = admit_context_candidate(fixed, state)

      case fit do
        {kind, _} when kind in [:ok, :refused] ->
          {:ok,
           %{
             request: candidate.request,
             record: fixed,
             record_bytes: fixed["context_receipt"]["record_byte_cost"],
             tokens: fixed["context_receipt"]["provider_estimated_tokens"],
             admission: fit
           }}

        {:error, _} = error ->
          error
      end
    end
  end

  # Concept: ordinary and maintenance staging account for the same visible bytes.
  # Technical depth: the reference receipt builder shares replay's descriptor,
  # tool projection, estimator, provenance totals and ordered digest. It includes
  # continuation once and leaves exact complete-record fixed-point sizing to the
  # owning request constructor. A source/message mismatch refuses before zip.
  @doc false
  @spec reference_context_receipt(
          Loopex.Model.request(),
          list(),
          map(),
          pos_integer(),
          map() | nil
        ) ::
          {:ok, map()} | {:error, term()}
  def reference_context_receipt(request, sources, project, budget, header) do
    with true <- length(request.messages) == length(sources),
         {:ok, continuation} <-
           Loopex.Model.Continuation.cost(request.continuation, request.model, request.messages),
         {:ok, blocks} <- expected_context_blocks(request, sources) do
      totals =
        if header,
          do: expected_resource_context_totals(blocks),
          else: expected_context_totals(blocks)

      receipt = %{
        "provider_identity" => "loopex.context.reference",
        "provider_revision" => 4,
        "transformer_identity" => nil,
        "transformer_revision" => nil,
        "selector_identity" => nil,
        "selector_revision" => nil,
        "token_estimator" => "loopex.context_bytes.v2",
        "descriptor_canonicalization_version" => @descriptor_canonicalization_version,
        "blocks" => blocks,
        "totals" => totals,
        "continuation_cost" => continuation,
        "provider_estimated_tokens" =>
          totals["token_cost"] + if(continuation, do: continuation["token_cost"], else: 0),
        "context_token_budget" => budget,
        "context_record_byte_ceiling" => Store.max_item_bytes(),
        "record_byte_cost" => 0,
        "ordered_descriptor_digest" => ordered_descriptor_digest(blocks),
        "project_resource" => project
      }

      {:ok, if(header, do: Map.put(receipt, "resource_packs", header), else: receipt)}
    else
      false -> {:error, :context_receipt_source_mismatch}
      {:error, _} = error -> error
    end
  end

  defp maintenance_request_candidate(
         state,
         episode,
         units,
         eligible,
         count,
         source,
         deadline,
         now,
         check
       ) do
    capture = episode["maintenance_configuration"]

    with :ok <- check.(),
         {:ok, range} <- maintenance_covered_range(state, episode, units, count, check),
         {:ok, request} <-
           MaintenanceConfiguration.request(
             capture["selection"],
             capture["instructions"],
             source.bytes,
             deadline
           ),
         {:ok, receipt} <-
           reference_context_receipt(
             request,
             [
               context_source(SessionConfiguration.instruction_source(capture), "system"),
               context_source(
                 %{"kind" => "compaction_source", "source_digest" => source.digest},
                 "session"
               )
             ],
             %{
               "class" => "project_resource",
               "receipt_revision" => 2,
               "disposition" => "not_evaluated_maintenance",
               "detail" => nil
             },
             capture["context_token_budget"],
             Loopex.Runtime.ResourceContext.initial_header(state.run_resources[episode["run_id"]])
           ) do
      totals = receipt["totals"]

      record = %{
        :kind => "maintenance_request_committed_v1",
        "episode_id" => episode["episode_id"],
        "summary_ordinal" => episode["summary_ordinal"],
        "purpose" => "compaction",
        "operation_id" =>
          stable_id("maintenance-model", episode["episode_id"], episode["summary_ordinal"]),
        "configuration_version" => episode["configuration_version"],
        "captured_session_version" => episode["session_version"],
        "strategy_revision" => 3,
        "eligible_unit_count" => eligible,
        "covered_range" => range,
        "source_digest" => source.digest,
        "source_excerpted" => source.source_excerpted,
        "staged_at" => now,
        "staged_request_digest" => request.staged_request_digest,
        "request" => encode_plain(request),
        "context_receipt" => receipt
      }

      observations = %{
        system_class_tokens: totals["by_provenance"]["system"]["token_cost"],
        system_class_token_ceiling: capture["system_class_tokens"],
        provider_estimated_tokens: totals["token_cost"],
        context_token_budget: capture["context_token_budget"],
        context_record_byte_ceiling: Store.max_item_bytes(),
        context_record_depth_limit: Store.max_item_depth(),
        context_record_cardinality_limit: Store.max_item_cardinality()
      }

      with {:ok, candidate} <- record_byte_cost_candidate(record),
           :ok <- ContextAdmission.preflight_required_candidate(candidate, observations),
           :ok <- check.() do
        {:ok, candidate}
      end
    end
  end

  # Concept: coverage authenticates complete original records, including private evidence.
  # Technical depth: collect only small provenance tuples, deduplicate records by
  # their actual journal position, then hash them in journal order using the
  # domain and length framing below. Projected message digests remain separate.
  # Every original predates the episode's captured session version.
  defp maintenance_covered_range(state, episode, units, count, check) do
    sources =
      units
      |> Stream.take(count)
      |> Stream.flat_map(& &1.elements)
      |> Stream.map(&Conversation.source_reference/1)

    initial = {:ok, %{}, nil, nil, 0}

    sources
    |> Enum.reduce_while(initial, fn reference, {:ok, originals, first, _last, n} ->
      with :ok <- check.(),
           %{journal_version: version, record_digest: digest, record_byte_cost: bytes} = original <-
             state.conversation_record_sources[reference],
           true <- version < episode["session_version"],
           true <- is_nil(originals[version]) or originals[version] == original do
        {:cont,
         {:ok,
          Map.put(originals, version, %{
            journal_version: version,
            record_digest: digest,
            record_byte_cost: bytes
          }), first || reference, reference, n + 1}}
      else
        {:error, _} = error -> {:halt, error}
        _ -> {:halt, {:error, :context_projection_invalid}}
      end
    end)
    |> case do
      {:ok, originals, first, last, source_count} when source_count > 0 ->
        hash =
          :crypto.hash_update(
            :crypto.hash_init(:sha256),
            "loopex.compaction.covered_records.v1" <> <<0>>
          )

        originals
        |> Enum.sort_by(&elem(&1, 0))
        |> Enum.reduce_while({:ok, hash}, fn {version, original}, {:ok, hash} ->
          with :ok <- check.() do
            bytes =
              Canonical.encode(%{
                "journal_version" => version,
                "record_digest" => original.record_digest,
                "record_byte_cost" => original.record_byte_cost
              })

            {:cont,
             {:ok,
              hash
              |> :crypto.hash_update(<<byte_size(bytes)::unsigned-big-integer-size(64)>>)
              |> :crypto.hash_update(bytes)}}
          else
            error -> {:halt, error}
          end
        end)
        |> case do
          {:ok, hash} ->
            next = Enum.at(units, count)

            {:ok,
             %{
               "unit_count" => count,
               "record_count" => map_size(originals),
               "source_count" => source_count,
               "first" => first,
               "last" => last,
               "first_kept" => next && Conversation.source_reference(hd(next.elements)),
               "digest" => Base.encode16(:crypto.hash_final(hash), case: :lower)
             }}

          error ->
            error
        end

      error ->
        error
    end
  end

  defp maintenance_clock(state, run_id, now) do
    cond do
      not is_integer(now) or now < 0 or now > @uint64_max - 60_000 ->
        {:error, :maintenance_deadline_unrepresentable}

      is_integer(retained_run_deadline(state, run_id)) and
          retained_run_deadline(state, run_id) <= now ->
        {:error, :run_deadline_reached}

      true ->
        :ok
    end
  end

  defp maintenance_bounds(state, run_id) do
    state.bounds[run_id]
    |> Map.take([:max_turns, :token_budget, :deadline_ms])
    |> encode_plain()
    |> Map.merge(%{"max_attempts" => 4, "run_deadline" => retained_run_deadline(state, run_id)})
  end

  @doc false
  @spec propose_preparation_failure(t(), binary(), atom(), integer()) ::
          {:ok, proposal()} | {:error, atom()}
  def propose_preparation_failure(state, run_id, cause, now) do
    with {:ok, identity} <- preparation_identity(state, run_id),
         {:ok, [source | _]} <- preparation_sources(state, run_id),
         {:ok, record} <-
           ArtifactPreparation.failure(
             state.artifact_preparations[identity["episode_id"]],
             identity,
             source,
             now,
             cause
           ) do
      internal_proposal(state, identity["episode_id"] <> ":failure", record)
    else
      _ -> {:error, :invalid_artifact_preparation_transition}
    end
  end

  @doc false
  @spec propose_prepared_reference(t(), binary(), map(), integer()) ::
          {:ok, proposal()} | {:error, atom()}
  def propose_prepared_reference(state, run_id, reference, now) do
    with {:ok, identity} <- preparation_identity(state, run_id),
         {:ok, [source | _]} <- preparation_sources(state, run_id),
         {:ok, record} <-
           ArtifactPreparation.complete(
             state.artifact_preparations[identity["episode_id"]],
             source,
             reference,
             now
           ) do
      internal_proposal(state, identity["episode_id"] <> ":complete", record)
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_artifact_prepared_reference}
    end
  end

  defp preparation_identity(state, run_id) do
    case state.pending_work[run_id] do
      %{stage: stage} = work
      when stage in ["model_pending", "turn_settled"] and state.active_run_id == run_id and
             is_nil(state.open_interaction) and is_nil(state.aborting) ->
        turn_id = stable_id("turn", run_id, next_turn_number(work))

        {:ok,
         %{
           "episode_id" => stable_id("artifact-preparation", run_id, turn_id),
           "run_id" => run_id,
           "turn_id" => turn_id
         }}

      _ ->
        {:error, :invalid_artifact_preparation_transition}
    end
  end

  # Concept: a prepared reference changes projection eligibility, not the receipt.
  # Technical depth: only a transient element copy receives the replay-validated
  # reference; the original conversation and previously staged prefix stay exact.
  defp prepared_elements(state, elements) do
    Enum.map(elements, fn
      %{kind: :tool_result} = result ->
        source = %{
          "kind" => "session_tool_result",
          "run_id" => result.run_id,
          "turn" => result.turn_number,
          "call_id" => result.tool_call_id
        }

        case Map.fetch(state.prepared_tool_results, source) do
          {:ok, reference} ->
            Map.put(result, :artifacts, [reference | Map.get(result, :artifacts, [])])

          :error ->
            result
        end

      element ->
        element
    end)
  end

  defp preparation_ready?(state, run_id) do
    not Enum.any?(state.artifact_preparations, fn
      {_, %{"status" => "reserved", "run_id" => ^run_id}} -> true
      _ -> false
    end)
  end

  # Concept: each open exchange keeps every message already sent to its provider.
  # Technical depth: the latest settled request freezes appended results too;
  # the original base request alone would allow their prefixes to shrink later.
  defp frozen_lineage(state, run_id) do
    case get_in(state.pending_work, [run_id, :continuation_exchange]) do
      nil ->
        %{}

      exchange ->
        request = Map.get(exchange, :latest_request, exchange.base_request)
        receipt = Map.get(exchange, :latest_receipt, exchange.base_receipt)
        projection = Map.get(exchange, :latest_projection)
        ranges = if projection, do: projection["ranges"], else: []
        by_source = Map.new(ranges, &{&1["source_reference"], &1})

        request.messages
        |> Enum.zip(receipt["blocks"])
        |> Enum.filter(fn {_, block} -> block["provenance_class"] == "session" end)
        |> Map.new(fn {message, block} ->
          source = block["source_reference"]
          {source, %{message: message, range: by_source[source]}}
        end)
    end
  end

  # Concept: replay requires the current projection for the session's captured tools.
  # Technical depth: an absent projection is valid only when the configured
  # lineage constructor itself returns none. Artifact-capable sessions require
  # exact range provenance from their first request, without a historical cutover.
  defp projected_entries(state, run_id, nil),
    do: projected_entries_without_artifacts(state, run_id)

  defp projected_entries(state, run_id, %{"revision" => 1, "allowance" => allowance} = projection)
       when map_size(projection) == 3 do
    with {:ok, entries, ^projection} <- projected_lineage(state, run_id, allowance),
         do: {:ok, entries},
         else: (_ -> {:error, :context_projection_invalid})
  end

  defp projected_entries(_, _, _), do: {:error, :context_projection_invalid}

  defp projected_entries_without_artifacts(state, run_id) do
    with {:ok, entries, nil} <- projected_lineage(state, run_id, 0), do: {:ok, entries}
  end

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

  The configuration a run bound at admission, including promoted follow-ups.

  ## Technical depth

  The immutable projection references captured committed settings rather than
  current runtime defaults. Nil identifies an unknown run.
  """
  @spec run_configuration(t(), binary() | nil) :: map() | nil
  def run_configuration(%__MODULE__{} = state, run_id),
    do: Map.get(state.run_configurations, run_id)

  @doc """
  ## Concept

  Build the next continuation from this run's committed open exchange.

  ## Technical depth

  Source identities and full settlement digests come from recovered records.
  Message positions come from lineage source references, never content search.
  Every source binds the captured model/configuration and exact canonical text,
  arguments and results. The first request and every post-terminal run use nil.
  """
  @spec model_continuation(t(), binary(), [map()], binary() | nil, map() | nil) ::
          {:ok, map() | nil} | {:error, :context_projection_invalid}
  def model_continuation(state, run_id, messages, applied_steer, projection \\ nil) do
    case get_in(state.pending_work, [run_id, :continuation_exchange]) do
      nil -> {:ok, nil}
      exchange -> build_continuation(state, run_id, messages, applied_steer, exchange, projection)
    end
  end

  defp build_continuation(state, run_id, messages, applied_steer, exchange, projection) do
    configuration = run_configuration(state, run_id)

    with true <- is_map(configuration),
         {:ok, entries} <- projected_entries(state, run_id, projection),
         {:ok, steer} <- projected_steer(state, run_id, applied_steer),
         expected = Enum.map(entries, &elem(&1, 1)) ++ steer,
         offset = length(messages) - length(expected),
         true <- offset >= 1 and Enum.drop(messages, offset) == expected,
         true <-
           Enum.take(messages, length(exchange.base_request.messages)) ==
             exchange.base_request.messages,
         true <- exchange.base_request.model == configuration["model"],
         true <- length(exchange.sources) in 1..32,
         positions =
           Map.new(Enum.with_index(entries, offset), fn {{source, message}, index} ->
             {source, {message, index}}
           end),
         {:ok, sources} <- continuation_entries(exchange.sources, positions, []) do
      first = hd(exchange.sources).record

      envelope = %{
        "format" => "loopex.anthropic.content_refs.v1",
        "provider" => "anthropic",
        "model" => configuration["model"],
        "configuration_version" => configuration["configuration_version"],
        "exchange_id" => first["operation_id"],
        "base_request_digest" => exchange.base_request.staged_request_digest,
        "entries" => sources
      }

      case Loopex.Model.Continuation.expand(envelope, configuration["model"], messages) do
        {:ok, _} -> {:ok, envelope}
        _ -> {:error, :context_projection_invalid}
      end
    else
      _ -> {:error, :context_projection_invalid}
    end
  end

  defp continuation_entries([], _positions, entries), do: {:ok, Enum.reverse(entries)}

  defp continuation_entries([%{record: record, turn_number: turn} | rest], positions, entries) do
    run = record["run_id"]
    reference = %{"kind" => "session_assistant", "run_id" => run, "turn" => turn}
    reply = record["result"]["reply"]

    with {assistant, index} <- positions[reference],
         true <- assistant["content"] == reply["text"],
         true <- length(assistant["tool_calls"]) == length(reply["tool_calls"]),
         {:ok, calls} <-
           continuation_calls(
             reply["tool_calls"],
             assistant["tool_calls"],
             positions,
             run,
             turn,
             []
           ) do
      entry = %{
        "source" =>
          record
          |> Map.take(~w(run_id turn_id operation_id attempt))
          |> Map.put("settlement_digest", Canonical.digest(record)),
        "assistant_message_index" => index,
        "calls" => calls,
        "capsule" => reply["continuation"]
      }

      continuation_entries(rest, positions, [entry | entries])
    else
      _ -> {:error, :context_projection_invalid}
    end
  end

  defp continuation_calls([], [], _positions, _run, _turn, calls), do: {:ok, Enum.reverse(calls)}

  defp continuation_calls([native | rest], [canonical | calls], positions, run, turn, bindings) do
    reference = %{
      "kind" => "session_tool_result",
      "run_id" => run,
      "turn" => turn,
      "call_id" => native["id"]
    }

    with true <- native["arguments"] == canonical["arguments"],
         {result, index} <- positions[reference],
         true <- result["tool_call_id"] == canonical["tool_call_id"] do
      binding = %{
        "canonical_call_id" => canonical["tool_call_id"],
        "native_id" => native["id"],
        "result_message_index" => index
      }

      continuation_calls(rest, calls, positions, run, turn, [binding | bindings])
    else
      _ -> {:error, :context_projection_invalid}
    end
  end

  defp continuation_calls(_, _, _, _, _, _), do: {:error, :context_projection_invalid}

  @doc false
  @spec frozen_context(t(), binary()) :: map() | nil
  def frozen_context(state, run_id) do
    case get_in(state.pending_work, [run_id, :continuation_exchange]) do
      nil ->
        nil

      %{base_request: request, base_receipt: receipt} ->
        selected =
          request.messages
          |> Enum.zip(receipt["blocks"])
          |> Enum.flat_map(fn {message, block} ->
            if block["provenance_class"] in ["project_resource", "resource_pack"],
              do: [
                {message["content"],
                 Map.take(block, ~w(source_reference provenance_class trust_class))}
              ],
              else: []
          end)

        %{
          selected: selected,
          project: receipt["project_resource"],
          resources: receipt["resource_packs"]
        }
    end
  end

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

  One run's admission, ending and usage, as this reducer derives them.

  ## Technical depth

  ADR 0069's private run evidence. The complete Store-stamped private prefix is
  replayed through the ordinary reducer, so usage is the same split that run
  accounting folds live and after restart: reported input/output, estimated
  charges and whether any attempt's usage is unresolved. Run-owned maintenance
  is included; standalone compaction charges no run. Admission is the accepted
  prompt record that opened the run; terminal is the run's terminal record with
  its journal version and Canonical digest, or nil while the run is live.
  """
  @spec run_evidence(binary(), [map()], binary()) ::
          {:ok, map()} | {:error, :unknown_run | :invalid_history}
  def run_evidence(session_id, records, run_id)
      when is_binary(session_id) and is_list(records) and is_binary(run_id) do
    with {:ok, state} <- replay_records(%__MODULE__{session_id: session_id}, records),
         %{payload: admitted} <-
           Enum.find(records, fn %{payload: payload} ->
             payload[:kind] == "prompt_admitted_v3" and payload["run_id"] == run_id and
               payload["admission"] == "accepted"
           end) do
      terminal =
        Enum.find_value(records, fn %{payload: payload} = record ->
          if payload[:kind] == "run_terminal_committed" and payload["run_id"] == run_id,
            do: %{
              state: payload["outcome"],
              journal_version: record.journal_version,
              record_digest: Canonical.digest(payload)
            }
        end)

      {:ok,
       %{
         admission: %{
           command_id: admitted["command_id"],
           revision: admitted["command_revision"],
           digest: admitted["command_digest"]
         },
         terminal: terminal,
         usage:
           Map.get(state.run_usage, run_id, %{
             reported_input: 0,
             reported_output: 0,
             estimated: 0,
             unresolved: false
           }),
         through_version: state.journal_version
       }}
    else
      nil -> {:error, :unknown_run}
      {:error, _reason} -> {:error, :invalid_history}
    end
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
  @spec preflight_model_request(t(), binary(), Loopex.Model.request(), keyword()) ::
          {:ok, map()}
          | {:refused, map()}
          | {:refused_not_required_only, map()}
          | {:error, term()}
  def preflight_model_request(state, run_id, request, options \\ [])

  def preflight_model_request(
        %__MODULE__{active_maintenance: episode},
        _run_id,
        _request,
        _options
      )
      when not is_nil(episode),
      do: {:error, :maintenance_active}

  def preflight_model_request(%__MODULE__{} = state, run_id, request, options)
      when is_binary(run_id) and is_map(request) and is_list(options) do
    with configuration when is_map(configuration) <- run_configuration(state, run_id) do
      work = Map.get(state.pending_work, run_id, %{turn_number: 1})
      turn_number = next_turn_number(work)
      record = model_request_record(state, run_id, request, options, turn_number)

      case admit_context_candidate(record, state) do
        {:ok, fixed} -> {:ok, fixed}
        {:refused, refusal} -> context_refusal_result(state, record, refusal, work, turn_number)
        {:error, reason} -> {:error, reason}
      end
    else
      _ -> {:error, :invalid_session_configuration}
    end
  end

  def preflight_model_request(_state, _run_id, _request, _options),
    do: {:error, :invalid_model_request}

  @doc false
  @spec propose_model_request(t(), binary(), Loopex.Model.request(), keyword()) ::
          {:ok, proposal()}
          | {:refused, map()}
          | {:refused_not_required_only, map()}
          | {:error, term()}
  def propose_model_request(%__MODULE__{} = state, run_id, request, options \\ [])
      when is_binary(run_id) and is_map(request) and is_list(options) do
    work = Map.get(state.pending_work, run_id, %{turn_number: 1})
    turn_number = next_turn_number(work)
    turn_id = stable_id("turn", run_id, turn_number)

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
    with true <- preparation_ready?(state, run_id),
         {:ok, fixed} <- preflight_model_request(state, run_id, request, options),
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
      false ->
        {:error, :artifact_preparation_pending}

      {:refused, refusal} ->
        {:refused, refusal}

      {:refused_not_required_only, refusal} ->
        {:refused_not_required_only, refusal}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp model_request_record(state, run_id, request, options, turn_number) do
    kind =
      if is_nil(Map.get(state.run_resources, run_id)),
        do: "model_request_committed_v2",
        else: "model_request_committed_resources_v2"

    record = %{
      "run_id" => run_id,
      "turn_id" => stable_id("turn", run_id, turn_number),
      "operation_id" => model_operation_id(run_id, turn_number),
      "staged_request_digest" => request.staged_request_digest,
      "request" => encode_plain(request),
      "applied_steer" => Keyword.get(options, :applied_steer),
      "context_receipt" => Keyword.get(options, :context_receipt),
      "configuration_version" => run_configuration(state, run_id)["configuration_version"],
      kind: kind
    }

    # Concept: excerpt provenance is private staging data, not provider context.
    # Technical depth: ADR 0042 fixes the receipt at 17 or 18 outer keys. The
    # revisioned staging member is included in complete-record admission instead.
    case Keyword.get(options, :lineage_projection) do
      nil -> record
      projection -> Map.put(record, "lineage_projection", projection)
    end
  end

  defp admit_context_candidate(%{"context_receipt" => receipt} = record, state)
       when is_map(receipt) do
    case preflight_context_candidate(
           record,
           run_configuration(state, record["run_id"]),
           not is_nil(request_headroom_targets(state, record["run_id"]))
         ) do
      {:ok, fixed, :ok} -> {:ok, fixed}
      {:ok, _fixed, {:refused, _} = refusal} -> refusal
      {:error, _} = error -> error
    end
  end

  defp admit_context_candidate(record, _state), do: resolve_record_byte_cost(record)

  defp preflight_context_candidate(
         %{"context_receipt" => receipt} = record,
         configuration,
         reserve
       )
       when is_map(configuration) do
    observations = %{
      system_class_tokens: get_in(receipt, ["totals", "by_provenance", "system", "token_cost"]),
      provider_estimated_tokens: Map.get(receipt, "provider_estimated_tokens"),
      context_token_budget: Map.get(receipt, "context_token_budget"),
      context_record_byte_ceiling: Store.max_item_bytes(),
      context_record_depth_limit: Store.max_item_depth(),
      context_record_cardinality_limit: Store.max_item_cardinality(),
      reserve_thinking_exchange: reserve,
      system_class_token_ceiling: configuration["system_class_tokens"]
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
    with {:ok, candidate} <- record_byte_cost_candidate(record) do
      case ContextAdmission.preflight_required_candidate(candidate, observations) do
        :ok -> {:ok, candidate, :ok}
        {:refused, _} = refusal -> {:ok, candidate, refusal}
        {:error, _} = error -> error
      end
    end
  end

  defp preflight_context_candidate(_record, _configuration, _reserve),
    do: {:error, :invalid_session_configuration}

  # Concept: only a new ordinary exchange reserves continuation capacity.
  # Technical depth: an open exchange's immutable prefix uses its hard ceilings.
  # Every other probe derives the same targets from the retained configuration,
  # including tail selection and checkpoint progress; summarizer input is separate.
  defp request_headroom_targets(state, run_id) do
    case run_configuration(state, run_id) do
      %{"provider_mapping" => %{"continuation_required" => true}} = configuration ->
        if is_nil(get_in(state.pending_work, [run_id, :continuation_exchange])),
          do: ContextAdmission.thinking_targets(configuration["context_token_budget"]),
          else: nil

      _ ->
        nil
    end
  end

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
  # Technical depth: the counts partition the exact descriptor sequence
  # whose bytes produced the token estimate and the ordered digest, so
  # incrementing or reclassifying one without changing that sequence is refused
  # by the live constructor. No descriptor body, source reference, or oversized
  # candidate is retained, which is what makes the refusal's size independent of
  # history length.
  defp context_refusal_result(state, record, refusal, work, turn_number) do
    receipt = Map.fetch!(record, "context_receipt")
    frozen? = not is_nil(frozen_context(state, work.run_id))

    with {:ok, counts} <- context_descriptor_counts(record),
         true <- counts.project + counts.resources == 0 or frozen? do
      compact =
        compact_refusal(receipt, refusal, work, turn_number, counts)

      refusal = configured_refusal(compact, record["configuration_version"], refusal)

      refusal =
        if counts.project + counts.resources > 0 do
          Map.merge(refusal, %{
            "project_resource_count" => counts.project,
            "resource_pack_count" => counts.resources
          })
        else
          refusal
        end

      {:refused, refusal}
    else
      _ -> {:refused_not_required_only, refusal}
    end
  end

  defp context_descriptor_counts(record) do
    blocks = Map.fetch!(record["context_receipt"], "blocks")
    tools = length(Map.get(record["request"], "tools", []))
    messages = Enum.take(blocks, length(blocks) - tools)
    steer = if record["applied_steer"], do: 1, else: 0

    counts = %{
      system: Enum.count(messages, &(&1["provenance_class"] == "system")),
      session: Enum.count(messages, &(&1["provenance_class"] == "session")) - steer,
      steer: steer,
      tools: tools,
      project: Enum.count(messages, &(&1["provenance_class"] == "project_resource")),
      resources: Enum.count(messages, &(&1["provenance_class"] == "resource_pack"))
    }

    if Enum.all?(Map.values(counts), &nonnegative_uint64?/1) and
         Enum.sum(Map.values(counts)) == length(blocks),
       do: {:ok, counts},
       else: {:error, :invalid_context_refusal}
  end

  # Concept: A refusal describes every class in the measured candidate.
  #
  # Technical depth: required counts partition system, session, steer and tools.
  # A frozen optional prefix adds the approved project/resource counts. The live
  # constructor owns the descriptor preimage and proves the complete partition
  # before retaining the current refusal and its ordered digest.
  defp compact_refusal(receipt, refusal, work, turn_number, counts) do
    %{
      "run_id" => Map.fetch!(work, :run_id),
      "turn_id" => stable_id("turn", Map.fetch!(work, :run_id), turn_number),
      "category" => Map.get(refusal, "category", "context_budget_exceeded"),
      "dimension" => Map.fetch!(refusal, "dimension"),
      "token_estimator" => Bounds.estimator(),
      "descriptor_canonicalization_version" => @descriptor_canonicalization_version,
      "project_disposition" => refusal_project_disposition(receipt, counts),
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
      kind: "context_admission_refused_v2"
    }
  end

  defp configured_refusal(compact, version, measurement) do
    failure =
      Map.take(compact, ~w(category dimension observed limit))
      |> Map.merge(%{
        "version" => 2,
        "retryable" => false,
        "measurement_scope" => "ordinary",
        "hard_limit" => Map.get(measurement, "hard_limit", compact["limit"])
      })

    compact
    |> Map.drop(~w(category dimension observed limit))
    |> Map.merge(%{
      :kind => "context_admission_refused_v2",
      "failure" => failure,
      "token_estimator" => "loopex.context_bytes.v2",
      "configuration_version" => version,
      "episode_id" => nil,
      "targets" => Map.get(measurement, "targets"),
      "projection_state" => "measured",
      "measurement_scope" => "ordinary"
    })
  end

  # Technical depth: a truthfully empty staged manifest keeps `staged_empty`
  # rather than being relabelled absent or declined, and an eligible project
  # that was never reached because required content already failed says exactly
  # that instead of suggesting it was staged.
  defp refusal_project_disposition(receipt, %{project: project}) when project > 0,
    do: get_in(receipt, ["project_resource", "disposition"])

  defp refusal_project_disposition(receipt, _counts) do
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
         deadline when is_integer(deadline) <- retained_run_deadline(state, run_id),
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
    required = continuation_required?(state, run_id)
    {result, conversation, usage} = attempt_result(work, outcome, termination, required)
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
      kind: ProviderAttempt.settled_kind()
    }

    with {:ok, settlement} <- fit_attempt_settlement(settlement),
         {:ok, records} <- attempt_settlement_records(state, run_id, settlement),
         {:ok, proposal} <-
           internal_proposal(
             state,
             stable_id("model-attempt-settled", run_id, {request.staged_request_digest, attempt}),
             records
           ),
         {:ok, events} <- admit_attempt_items(:event, proposal.events) do
      {:ok, %{proposal | events: events}}
    end
  end

  # Concept: summary settlement uses the same transport and accounting truth.
  # Technical depth: successful output remains checkpoint-pending, with no
  # ordinary assistant. A failed summary defers its effects to the consecutive
  # run terminal or standalone completion; the episode terminal leads that
  # transaction. Standalone endings use the supplied owner's observed clock.
  @doc false
  def propose_maintenance_attempt_settled(state, outcome, observed_at \\ nil) do
    with %{"stage" => "model_attempt_open"} = episode <-
           state.maintenance_episodes[state.active_maintenance],
         request = episode["request"],
         work = %{request: request, model_termination: episode["model_termination"]},
         termination = maintenance_attempt_termination(state, episode, outcome),
         {result, conversation, usage} = attempt_result(work, outcome, termination, false),
         transport = attempt_transport(outcome),
         next = attempt_next(transport, termination, result, episode["model_attempt"]),
         record =
           Map.merge(maintenance_attempt_identity(episode), %{
             :kind => "maintenance_attempt_settled_v3",
             "transport" => transport,
             "termination" => termination,
             "conversation" => conversation,
             "next" => if(next == "continue", do: "terminal", else: next),
             "result" => result,
             "accounting" => attempt_accounting(transport, usage)
           }),
         {:ok, record} <- fit_attempt_settlement(record),
         {:ok, preview, _events} <- apply_internal_record(state, record),
         {:ok, records} <-
           maintenance_settlement_records(state, episode, record, preview, observed_at) do
      internal_proposal(
        state,
        episode["operation_id"] <>
          ":settle:" <>
          Integer.to_string(episode["model_attempt"]),
        records
      )
    else
      {:error, _} = error -> error
      _ -> {:error, :no_open_maintenance_attempt}
    end
  end

  defp maintenance_settlement_records(
         _state,
         %{kind: "standalone_maintenance_episode_admitted_v1"},
         record,
         preview,
         observed_at
       ) do
    episode = preview.maintenance_episodes[preview.active_maintenance]

    case standalone_settlement_failure(preview, episode, observed_at) do
      nil ->
        {:ok, [record]}

      _ ->
        with {:ok, completed} <- standalone_settlement_completion_record(preview, observed_at),
             do: {:ok, [record, completed]}
    end
  end

  defp maintenance_settlement_records(state, episode, record, _preview, _observed_at) do
    {:ok,
     if(maintenance_failed_settlement?(record),
       do: [record, maintenance_attempt_terminal(state, episode, record)],
       else: [record]
     )}
  end

  # Concept: standalone settlement spends its own allowance and completes its command.
  # Technical depth: the preceding attempt fixes cancellation, deadline and provider
  # failure. Failed settlements defer charging until the terminal/completion pair;
  # readable summary failures and exhausted retry allowances use already retained
  # charges. Replay derives this exact result and never charges a run or settles twice.
  defp standalone_settlement_completion_record(state, observed_at, check \\ fn -> :ok end) do
    with %{} = pending <- state.pending_compact,
         %{kind: "standalone_maintenance_episode_admitted_v1"} = episode <-
           state.maintenance_episodes[state.active_maintenance],
         true <-
           episode["command_id"] == pending["command_id"] and
             episode["episode_id"] == pending["episode_id"],
         true <-
           episode["stage"] in [
             "settlement_pending_terminal",
             "model_retry_permitted",
             "checkpoint_pending",
             "checkpoint_committed"
           ],
         true <-
           is_integer(observed_at) and observed_at >= episode["request_staged_at"] and
             observed_at <= @uint64_max,
         {_preview, charged} = standalone_settlement_charge(state, episode),
         {:ok, failure} <- standalone_completion_failure(state, charged, observed_at, check),
         true <- failure["bound"] != "deadline_ms" or observed_at >= episode["deadline"],
         result = %{
           "disposition" => "failed",
           "checkpoint_id" => episode["checkpoint_id"],
           "failure" => failure,
           "usage" => charged["usage"],
           "cleanup" =>
             if(
               episode["settlement"]["termination"] == "owner_loss" or
                 episode["attempt_owner_epoch"] != state.owner_epoch,
               do: "unknown",
               else: "confirmed"
             )
         },
         {:ok, _} <- LoopexProtocol.Session.CompactResult.encode_wire(result) do
      {:ok,
       %{
         :kind => "compact_command_completed_v1",
         "command_id" => pending["command_id"],
         "episode_id" => pending["episode_id"],
         "observed_at" => observed_at,
         "result" => result
       }}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_compact_completion_transition}
    end
  end

  defp standalone_completion_failure(state, episode, observed_at, check) do
    case standalone_settlement_failure(state, episode, observed_at) do
      %{} = failure -> {:ok, failure}
      nil -> standalone_nonprogress_failure(state, episode, observed_at, check)
    end
  end

  defp standalone_nonprogress_failure(
         state,
         %{"stage" => "checkpoint_pending"},
         observed_at,
         check
       ) do
    with {:ok, candidate} <- pending_checkpoint_measurements(state, observed_at, check),
         false <- checkpoint_progress?(candidate) do
      {:ok,
       %{
         "version" => 2,
         "category" => "context_preparation_failed",
         "retryable" => false,
         "measurement_scope" => "ordinary",
         "cause" => "compaction_no_progress"
       }}
    else
      true -> {:error, :invalid_compact_completion_transition}
      {:error, _} = error -> error
    end
  end

  defp standalone_nonprogress_failure(_, _, _, _),
    do: {:error, :invalid_compact_completion_transition}

  defp standalone_settlement_charge(state, %{"stage" => "settlement_pending_terminal"} = episode),
    do: charge_maintenance_settlement(state, episode, episode["settlement"])

  defp standalone_settlement_charge(state, episode), do: {state, episode}

  defp standalone_settlement_failure(state, episode, observed_at) do
    record = episode["settlement"]

    cond do
      record["termination"] == "abort" ->
        %{"category" => "cancelled", "retryable" => false}

      record["termination"] == "deadline" ->
        standalone_bound_failure(episode, "deadline_ms", observed_at, episode["deadline"])

      record["termination"] == "owner_loss" or
          (record["result"]["kind"] == "error" and record["next"] != "retry") ->
        %{"category" => "model_call_failed", "retryable" => false}

      episode["stage"] != "settlement_pending_terminal" and maintenance_abort?(state, episode) ->
        %{"category" => "cancelled", "retryable" => false}

      episode["stage"] != "settlement_pending_terminal" and is_integer(observed_at) and
          observed_at >= episode["deadline"] ->
        standalone_bound_failure(episode, "deadline_ms", observed_at, episode["deadline"])

      is_binary(episode["summary_failure"]) ->
        %{
          "version" => 2,
          "category" => "context_preparation_failed",
          "retryable" => false,
          "measurement_scope" => nil,
          "cause" => episode["summary_failure"]
        }

      episode["attempts"] >= episode["bounds"]["max_attempts"] and
          (episode["stage"] == "model_retry_permitted" or
             (episode["stage"] == "checkpoint_committed" and
                match?(
                  {:error, {:checkpoint_requires_more_progress, _}},
                  maintenance_checkpoint_completion_record(state, observed_at, fn -> :ok end)
                ))) ->
        standalone_bound_failure(
          episode,
          "max_attempts",
          episode["attempts"],
          episode["bounds"]["max_attempts"]
        )

      (episode["stage"] in ["checkpoint_pending", "model_retry_permitted"] and
         episode["usage"]["total_tokens"] >= episode["bounds"]["token_budget"]) or
          (episode["stage"] in ["model_retry_permitted", "checkpoint_committed"] and
             episode["bounds"]["token_budget"] - episode["usage"]["total_tokens"] < 1_024 and
             (episode["stage"] == "model_retry_permitted" or
                match?(
                  {:error, {:checkpoint_requires_more_progress, _}},
                  maintenance_checkpoint_completion_record(state, observed_at, fn -> :ok end)
                ))) ->
        standalone_bound_failure(
          episode,
          "token_budget",
          episode["usage"]["total_tokens"],
          episode["bounds"]["token_budget"]
        )

      true ->
        nil
    end
  end

  defp standalone_bound_failure(episode, bound, observed, declared) do
    source = if(bound == "max_attempts", do: nil, else: episode["accounting_source"])

    %{
      "category" => "bound_reached",
      "retryable" => false,
      "bound" => bound,
      "observed" => observed,
      "declared_limit" => declared,
      "accounting_source" => source
    }
  end

  @doc false
  def propose_maintenance_attempt_open(state) do
    with %{"stage" => "model_retry_permitted", "next_attempt" => 2} = episode <-
           state.maintenance_episodes[state.active_maintenance],
         true <- not maintenance_abort?(state, episode),
         true <- episode["attempts"] < episode["bounds"]["max_attempts"],
         :ok <- maintenance_request_capacity(state, episode),
         {:ok, opened} <-
           ProviderAttempt.opened_record(%{
             episode_id: episode["episode_id"],
             summary_ordinal: episode["summary_ordinal"],
             purpose: "compaction",
             operation_id: episode["operation_id"],
             attempt: 2,
             staged_request_digest: episode["request"].staged_request_digest
           }) do
      internal_proposal(state, episode["operation_id"] <> ":retry", opened)
    else
      {:error, _} = error -> error
      _ -> {:error, :no_retry_permitted}
    end
  end

  @doc false
  def propose_maintenance_termination(state, observed) do
    with %{"stage" => "model_attempt_open", "model_termination" => nil} = episode <-
           state.maintenance_episodes[state.active_maintenance],
         true <- not maintenance_abort?(state, episode),
         true <-
           is_integer(observed) and observed >= episode["request"].deadline and
             observed <= @uint64_max do
      row =
        Map.merge(maintenance_attempt_identity(episode), %{
          :kind => "maintenance_termination_admitted_v1",
          "cause" => "deadline",
          "deadline" => episode["request"].deadline,
          "observed" => observed
        })

      internal_proposal(state, episode["operation_id"] <> ":deadline", row)
    else
      _ -> {:error, :no_open_maintenance_attempt}
    end
  end

  defp maintenance_attempt_identity(episode) do
    %{
      "episode_id" => episode["episode_id"],
      "summary_ordinal" => episode["summary_ordinal"],
      "purpose" => "compaction",
      "operation_id" => episode["operation_id"],
      "attempt" => episode["model_attempt"],
      "staged_request_digest" => episode["request"].staged_request_digest
    }
  end

  defp maintenance_attempt_termination(state, episode, outcome) do
    cond do
      episode["model_termination"] in ["abort", "deadline"] -> episode["model_termination"]
      maintenance_abort?(state, episode) -> "abort"
      outcome == :owner_loss -> "owner_loss"
      true -> nil
    end
  end

  defp maintenance_abort?(state, %{kind: "standalone_maintenance_episode_admitted_v1"} = episode) do
    id = episode["episode_id"]

    match?(
      %{"episode_id" => ^id, "abort_command_id" => abort} when is_binary(abort),
      state.pending_compact
    )
  end

  defp maintenance_abort?(state, episode) do
    run = episode["run_id"]
    match?(%{run_id: ^run}, state.aborting)
  end

  defp maintenance_summary(%{
         "conversation" => "canonical",
         "result" => %{"kind" => "reply", "reply" => reply}
       }),
       do: Loopex.Runtime.CompactionSummary.from_reply(reply)

  defp maintenance_summary(_), do: {:error, :model_call_failed}

  defp maintenance_failed_settlement?(%{"next" => "retry"}), do: false

  defp maintenance_failed_settlement?(%{
         "conversation" => "canonical",
         "result" => %{"kind" => "reply"}
       }),
       do: false

  defp maintenance_failed_settlement?(_record), do: true

  defp maintenance_attempt_terminal(state, episode, record) do
    run = episode["run_id"]
    terminal = attempt_terminal_record(state, run, record)

    if record["termination"] == "deadline" do
      {charged_state, _episode} = charge_maintenance_settlement(state, episode, record)
      {_bounds, charged} = accounting(charged_state, run)

      terminal
      |> Map.put("outcome", "bound_reached")
      |> Map.put("accounting_source", charged.source && Atom.to_string(charged.source))
    else
      terminal
    end
  end

  defp charge_maintenance_settlement(state, episode, record) do
    {next, charge} =
      if maintenance_scope(episode) == :session do
        charge =
          case record["accounting"] do
            %{"source" => "none"} ->
              0

            %{"source" => "reported", "input_tokens" => input, "output_tokens" => output} ->
              input + output

            %{"source" => "estimated"} ->
              max(episode["bounds"]["token_budget"] - episode["usage"]["total_tokens"], 0)
          end

        {state, charge}
      else
        run = episode["run_id"]
        {_bounds, prior} = accounting(state, run)
        next = apply_attempt_accounting(state, run, record["accounting"])
        {_bounds, charged} = accounting(next, run)
        {next, charged.tokens - prior.tokens}
      end

    usage = episode["usage"]

    usage =
      usage
      |> Map.update!("attempts", &(&1 + 1))
      |> Map.update!("total_tokens", &(&1 + charge))

    usage =
      case record["accounting"]["source"] do
        "reported" -> Map.update!(usage, "reported_tokens", &(&1 + charge))
        "estimated" -> Map.update!(usage, "estimated_tokens", &(&1 + charge))
        "none" -> usage
      end

    episode = episode |> Map.put("usage", usage) |> Map.put("settlement", record)

    episode =
      if maintenance_scope(episode) == :session do
        source = record["accounting"]["source"]

        Map.put(
          episode,
          "accounting_source",
          if(source == "none", do: episode["accounting_source"], else: source)
        )
      else
        episode
      end

    {put_in(next.maintenance_episodes[episode["episode_id"]], episode), episode}
  end

  # Concept: failed summary accounting and its parent ending become visible together.
  # Technical depth: the exact deferred settlement determines the terminal and
  # any summary-failure projection. No supplied terminal may alter the reason,
  # usage, deadline or winning termination. The leading episode marker is
  # checked after these same charges apply, so it cannot invent usage either.
  defp complete_pending_maintenance_settlement(state, terminal) do
    case state.maintenance_episodes[state.active_maintenance] do
      %{"stage" => "settlement_pending_terminal", "settlement" => record} = episode ->
        if terminal == maintenance_attempt_terminal(state, episode, record) do
          {next, episode} = charge_maintenance_settlement(state, episode, record)
          episode = Map.put(episode, "stage", "settling")
          next = put_in(next.maintenance_episodes[state.active_maintenance], episode)

          {:ok, next}
        else
          {:error, :invalid_maintenance_settlement_pair}
        end

      _ ->
        {:ok, state}
    end
  end

  defp attempt_settlement_records(state, run_id, %{"next" => "terminal"} = settlement) do
    with {:ok, [terminal]} <-
           admit_attempt_items(:record, [attempt_terminal_record(state, run_id, settlement)]) do
      {:ok, [settlement, terminal]}
    end
  end

  defp attempt_settlement_records(_state, _run_id, settlement), do: {:ok, [settlement]}

  defp attempt_terminal_record(state, run_id, settlement) do
    termination = settlement["termination"]
    result = settlement["result"]

    run_terminal_record(state, run_id, attempt_terminal(termination, result), %{
      bound: termination == "deadline" && "deadline",
      observed: termination == "deadline" && retained_run_deadline(state, run_id),
      declared_limit: termination == "deadline" && retained_run_deadline(state, run_id),
      reason: terminal_reason(result)
    })
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

  # Concept: only an admitted canonical reply supplies accounting evidence.
  # Technical depth: raw Store admission precedes projection inside
  # `canonical_reply/3`; the run's captured mapping fixes its continuation
  # requirement. Malformed or refused input retains explicit `none`.
  defp attempt_result(work, {:reply, raw}, termination, required) do
    with {:ok, reply} <- ProviderAttempt.canonical_reply(raw, work.request, required),
         :ok <- Loopex.Model.Continuation.validate_reply_ids(work.request, reply) do
      result = %{"kind" => "reply", "reply" => reply}
      conversation = if termination, do: "evidence_only", else: "canonical"

      {result, conversation, reply["usage"]}
    else
      {:error, _reason} ->
        {unreadable_result(%{"kind" => "none"}), "none", nil}
    end
  end

  defp attempt_result(_work, _outcome, _termination, _required),
    do: {%{"kind" => "error", "category" => "model_call_failed"}, "none", nil}

  defp unreadable_result(evidence),
    do: %{
      "kind" => "error",
      "category" => "unreadable_model_answer",
      "accounting_evidence" => evidence
    }

  # Concept: the retained compact provenance describes this exact full verdict.
  # Technical depth: only Store byte/depth overages authorize omission. Usage
  # comes from the same immutable canonical reply inside the measured record;
  # its actual next action is measured, and compaction selects terminal even
  # when that full reply would have continued into tools. Every retained item
  # is normalized before transaction construction, so unknown-commit retries
  # retain these bytes without revisiting the discarded reply.
  defp fit_attempt_settlement(candidate) do
    case Store.normalize_and_measure_item(:record, candidate) do
      {:ok, normalized, bytes} when bytes <= 65_536 ->
        {:ok, normalized}

      {:ok, _normalized, bytes} ->
        compact_attempt_settlement(candidate, "record_bytes", bytes, 65_536)

      {:error, {:item_structure_exceeded, :depth, 13, 12}} ->
        compact_attempt_settlement(candidate, "record_depth", 13, 12)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp compact_attempt_settlement(
         %{"result" => %{"kind" => "reply", "reply" => reply}} = candidate,
         dimension,
         observed,
         limit
       ) do
    evidence = %{
      "kind" => "validated_reply_compaction_v1",
      "usage" => reply["usage"],
      "dimension" => dimension,
      "observed" => observed,
      "limit" => limit
    }

    compact = %{
      candidate
      | "result" => unreadable_result(evidence),
        "conversation" => "none",
        "next" => "terminal"
    }

    with {:ok, [normalized]} <- admit_attempt_items(:record, [compact]), do: {:ok, normalized}
  end

  defp compact_attempt_settlement(_candidate, _dimension, _observed, _limit),
    do: {:error, :invalid_attempt_settlement}

  defp admit_attempt_items(plane, items) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      case Store.normalize_and_measure_item(plane, item) do
        {:ok, normalized, bytes} when bytes <= 65_536 -> {:cont, {:ok, [normalized | acc]}}
        {:ok, _normalized, bytes} -> {:halt, {:error, {:item_too_large, bytes, 65_536}}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      {:error, reason} -> {:error, reason}
    end
  end

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
      kind: "effect_intent_committed_v2"
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

  @doc """
  ## Concept

  Projects a retained executor intent or tool terminal into private recovery
  evidence without returning the grant or granting dispatch authority.

  ## Technical depth

  ADR 0046's stateless history scan uses the same job, grant and receipt decoders
  as replay. The complete input and the projected row retain the Store item
  ceiling. Closed shapes, canonical job bytes/digest and exact session/run
  bindings are checked before projection. A receipt is a committed receipt even
  when its outcome is unknown; only core's failed/cancelled tool-result facts
  prove pre-effect refusal. Other tool-result outcomes remain unknown. This
  per-record decoder does not replay transitions or join records across pages;
  composition must join terminal rows to earlier intents by exact identities.
  Non-effect record kinds are outside this decoder.
  """
  @spec effect_history_projection(binary(), term()) :: {:ok, map()} | {:error, :invalid_history}
  def effect_history_projection(session_id, payload) do
    with true <- is_binary(session_id) and byte_size(session_id) in 1..256,
         {:ok, ^payload, bytes} <- Store.normalize_and_measure_item(:record, payload),
         true <- bytes <= 65_536,
         {:ok, projection} <- project_effect_history(session_id, payload),
         true <- :erlang.external_size(projection, [:deterministic]) <= 65_536 do
      {:ok, projection}
    else
      _invalid -> {:error, :invalid_history}
    end
  rescue
    _invalid -> {:error, :invalid_history}
  end

  defp project_effect_history(session_id, %{kind: kind} = record)
       when kind == "effect_intent_committed_v2" do
    job_fields = Loopex.Executor.job_fields() ++ Loopex.Executor.JobRequest.derived_fields()
    grant_fields = Loopex.Executor.required_grant_bindings() ++ [:issued_by, :policy_context]

    with true <- closed_history_map?(record, [:kind, "run_id", "job", "grant"]),
         true <- closed_history_map?(record["job"], Enum.map(job_fields, &Atom.to_string/1)),
         true <- closed_history_map?(record["grant"], Enum.map(grant_fields, &Atom.to_string/1)),
         {:ok, job} <- decode_job(record["job"]),
         :ok <- Loopex.Executor.validate_job(job),
         true <- job.session_id == session_id and job.run_id == record["run_id"],
         {:ok, _grant} <- decode_grant(record["grant"]) do
      {:ok, %{kind: "intent", job: Map.from_struct(job)}}
    else
      _invalid -> {:error, :invalid_history}
    end
  end

  defp project_effect_history(session_id, %{kind: kind} = record)
       when kind == "executor_receipt_committed_v2" do
    required = Enum.map(@receipt_required_fields, &Atom.to_string/1)
    optional = Enum.map(@receipt_optional_fields, &Atom.to_string/1)

    with true <-
           closed_history_map?(record, [:kind, "run_id", "receipt"], ["reconciliation_query_id"]),
         true <-
           not Map.has_key?(record, "reconciliation_query_id") or
             history_identity?(record["reconciliation_query_id"]),
         true <- closed_history_map?(record["receipt"], required, optional),
         {:ok, receipt} <- decode_receipt(record["receipt"]),
         true <- receipt.session_id == session_id and receipt.run_id == record["run_id"],
         true <- valid_history_receipt_identity?(receipt) do
      {:ok, history_terminal(receipt.run_id, receipt.tool_call_id, "receipt_committed")}
    else
      _invalid -> {:error, :invalid_history}
    end
  end

  defp project_effect_history(_session_id, %{kind: kind} = record)
       when kind == "tool_result_committed_v2" do
    with true <-
           closed_history_map?(record, [:kind, "run_id", "tool_call_id", "outcome", "reason"]),
         true <- history_identity?(record["run_id"]),
         true <- history_identity?(record["tool_call_id"]),
         true <- is_nil(record["reason"]) or is_binary(record["reason"]),
         {:ok, _outcome} <- decode_receipt_outcome(record["outcome"]) do
      disposition =
        if record["outcome"] in ["failed", "cancelled"],
          do: "refused_before_effect",
          else: "outcome_unknown"

      {:ok, history_terminal(record["run_id"], record["tool_call_id"], disposition)}
    else
      _invalid -> {:error, :invalid_history}
    end
  end

  defp project_effect_history(_session_id, %{kind: kind} = record)
       when kind == "outcome_unknown_committed_v2" do
    if closed_history_map?(record, [:kind, "run_id", "reconciliation_ref"]) and
         history_identity?(record["run_id"]) and history_identity?(record["reconciliation_ref"]) do
      {:ok, history_terminal(record["run_id"], nil, "outcome_unknown")}
    else
      {:error, :invalid_history}
    end
  end

  defp project_effect_history(_session_id, _record), do: {:error, :invalid_history}

  defp history_terminal(run_id, tool_call_id, disposition),
    do: %{kind: "terminal", run_id: run_id, tool_call_id: tool_call_id, disposition: disposition}

  defp closed_history_map?(map, required, optional \\ []) do
    required =
      if is_map(map) and not is_struct(map) and map["command_type"] in ["prompt", "follow_up"],
        do:
          required ++
            ["command_revision"] ++
            if(map["admission"] == "accepted", do: ["authored_bounds"], else: []),
        else: required

    is_map(map) and not is_struct(map) and Enum.all?(required, &Map.has_key?(map, &1)) and
      Map.keys(map) -- (required ++ optional) == []
  end

  defp valid_history_receipt_identity?(receipt) do
    identifiers = [
      :job_id,
      :operation_id,
      :session_id,
      :run_id,
      :turn_id,
      :tool_call_id,
      :executor_identity,
      :tool_id,
      :tool_version
    ]

    counters = [:session_epoch_at_dispatch, :executor_epoch, :fencing_token]

    receipt.protocol_version == 1 and Enum.all?(identifiers, &history_identity?(receipt[&1])) and
      is_integer(receipt.attempt) and receipt.attempt > 0 and
      Enum.all?(counters, &(is_integer(receipt[&1]) and receipt[&1] >= 0)) and
      resource_digest?(receipt.canonical_request_digest)
  end

  defp history_identity?(value), do: is_binary(value) and byte_size(value) in 1..8_192

  @doc """
  ## Concept

  Whether a receipt is a valid executor fact for one original job.

  ## Technical depth

  ADR 0069 extracts the exact check the reducer applies before committing an
  executor fact, so a host retaining a helper receipt uses the same closed
  plain schema, Store item bounds and job identity tuple rather than a copy.
  It is pure: no state, Store or clock. The result is the canonical decoded
  receipt; any other input is `:invalid_executor_receipt`.
  """
  @spec validate_executor_receipt(term(), term()) ::
          {:ok, map()} | {:error, :invalid_executor_receipt}
  def validate_executor_receipt(receipt, job) when is_map(receipt) and is_map(job),
    do: canonical_executor_receipt(receipt, job)

  def validate_executor_receipt(_receipt, _job), do: {:error, :invalid_executor_receipt}

  @doc false
  @spec propose_executor_fact(t(), binary(), map()) :: {:ok, proposal()} | {:error, term()}
  def propose_executor_fact(%__MODULE__{} = state, run_id, receipt)
      when is_binary(run_id) and is_map(receipt) do
    with %{stage: "effect_dispatched", job: job} <- Map.get(state.pending_work, run_id),
         {:ok, receipt} <- canonical_executor_receipt(receipt, job) do
      record = %{
        "run_id" => run_id,
        "receipt" => encode_plain(receipt),
        kind: "executor_receipt_committed_v2"
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
        kind: "executor_receipt_committed_v2"
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
      kind: "tool_result_committed_v2"
    }

    turn_id = get_in(state.pending_work, [run_id, :turn_id])
    internal_proposal(state, stable_id("tool-result-v2", run_id, {turn_id, tool_call_id}), record)
  end

  @doc false
  @spec propose_outcome_unknown(t(), binary(), binary()) :: {:ok, proposal()} | {:error, term()}
  def propose_outcome_unknown(%__MODULE__{} = state, run_id, reconciliation_ref)
      when is_binary(run_id) and is_binary(reconciliation_ref) do
    record = %{
      "run_id" => run_id,
      "reconciliation_ref" => reconciliation_ref,
      kind: "outcome_unknown_committed_v2"
    }

    internal_proposal(state, stable_id("outcome-unknown", run_id, reconciliation_ref), record)
  end

  # Concept: the transaction that retains one deferred question.
  #
  # Technical depth: everything the question is judged by is decided before the
  # transaction is attempted -- its identity, creation instant, effective expiry
  # and round -- so resolving an uncertain commit reuses this same preimage.
  # That is what stops two owners recovering the same creation from giving the
  # question two different lifetimes. The host's opaque reference rides as a
  # sibling field, retained and never projected.
  @doc false
  @spec propose_interaction_request(t(), map()) :: {:ok, proposal()} | {:error, term()}
  def propose_interaction_request(%__MODULE__{} = state, interaction) when is_map(interaction) do
    record =
      %{
        "interaction_id" => interaction.interaction_id,
        "run_id" => interaction.run_id,
        "turn" => interaction.turn,
        "tool_call_id" => interaction.tool_call_id,
        "interaction_request" => Interaction.to_record(interaction.request),
        "interaction_request_digest" => Interaction.digest(interaction.request),
        "policy_request_digest" => interaction.policy_request_digest,
        "round" => interaction.round,
        "created_at" => interaction.created_at,
        "expires_at" => interaction.expires_at,
        "policy_identity" => interaction.policy_identity,
        kind: "interaction_requested_v1"
      }
      |> then(fn row ->
        case Map.get(interaction.request, :decision_ref) do
          nil -> row
          reference -> Map.put(row, "decision_ref", reference)
        end
      end)

    internal_proposal(
      state,
      stable_id("interaction", state.session_id, interaction.interaction_id),
      record
    )
  end

  # Concept: retain an allowed model question before publishing its identity.
  # Technical depth: request and generation are rederived from the pending
  # committed call; creation and expiry are captured once before Store admission.
  @doc false
  def propose_model_question(state, run_id, created_at) do
    with %{stage: "effect_pending", pending_calls: [call | _]} = work <-
           Map.get(state.pending_work, run_id),
         {:ok, request} <- Interaction.model_request(call.arguments) do
      id = model_question_id(state, work, call)

      record = %{
        "producer" => "model_tool",
        "interaction_id" => id,
        "run_id" => run_id,
        "turn" => work.turn_number,
        "tool_call_id" => call.tool_call_id,
        "argument_digest" => Interaction.digest(call.arguments),
        "interaction_request" => Interaction.to_record(request),
        "interaction_request_digest" => Interaction.digest(request),
        "created_at" => created_at,
        "expires_at" =>
          Interaction.effective_expiry(created_at, 600_000, retained_run_deadline(state, run_id)),
        kind: "model_question_requested_v1"
      }

      internal_proposal(state, id, record)
    else
      _ -> {:error, :invalid_model_question_transition}
    end
  end

  @doc false
  def propose_model_question_expiry(state, interaction_id, settled_at) do
    internal_proposal(state, interaction_id <> ".expired", %{
      "interaction_id" => interaction_id,
      "disposition" => "expired",
      "answer" => nil,
      "settled_at" => settled_at,
      kind: "model_question_settled_v2"
    })
  end

  @doc false
  @spec propose_interaction_resolution(t(), binary(), binary(), binary() | nil) ::
          {:ok, proposal()} | {:error, term()}
  def propose_interaction_resolution(%__MODULE__{} = state, interaction_id, resolution, reason)
      when is_binary(interaction_id) and is_binary(resolution) do
    record =
      %{
        "interaction_id" => interaction_id,
        "resolution" => resolution,
        kind: "interaction_resolved_v1"
      }
      |> then(&if(is_binary(reason), do: Map.put(&1, "reason", reason), else: &1))

    internal_proposal(
      state,
      stable_id("interaction-resolution", interaction_id, resolution),
      record
    )
  end

  @doc false
  @spec open_interaction_record(t()) :: map() | nil
  def open_interaction_record(%__MODULE__{open_interaction: nil}), do: nil

  def open_interaction_record(%__MODULE__{open_interaction: interaction_id} = state),
    do: Map.get(state.interactions, interaction_id)

  @doc """
  ## Concept

  The open interaction, as a reader outside the session may see it.

  ## Technical depth

  Pending questions carry their producer and kind. An admitted policy answer
  remains open as `answered`, with its offered choice and command identity,
  until the policy callback resolves it. Model answers and terminal policy
  resolutions clear the open view. These observations grant no authority.
  """
  @spec open_interaction(t()) :: map() | nil
  def open_interaction(%__MODULE__{open_interaction: nil}), do: nil

  def open_interaction(%__MODULE__{open_interaction: interaction_id} = state) do
    case Map.get(state.interactions, interaction_id) do
      nil ->
        nil

      interaction ->
        view = interaction |> Interaction.view() |> Map.take(~w(interaction_id run_id turn
          tool_call_id status prompt choices expires_at))

        producer =
          if Map.get(interaction, :producer) == "model_tool",
            do: "model_tool",
            else: "policy_defer"

        view =
          view
          |> Map.put("producer", producer)
          |> Map.put("kind", Atom.to_string(interaction.request.kind))

        if interaction.status == "answered" and producer == "policy_defer" do
          view
          |> Map.put("answer_choice_id", interaction.choice_id)
          |> Map.put("answer_command_id", interaction.command_id)
        else
          view
        end
    end
  end

  # Concept: current inspection reads only facts the serial owner has admitted.
  # Technical depth: bounded public views derive from current retained captures,
  # not a scan of the full outbox on every status poll. Recovery independently
  # reduces the public prefix and verifies these same complete views. Unknown
  # proposals remain outside the admitted state; historical scans own their prefix.
  @doc false
  def inspection_views(state) do
    {:ok,
     %{
       configuration: SessionConfiguration.public_view(state.configuration),
       checkpoint: checkpoint_public_view(state),
       active_maintenance: maintenance_public_view(state),
       open_interaction: open_interaction(state)
     }}
  end

  # Concept: explicit maintenance cannot queue unrelated session mutation.
  # Technical depth: duplicate lookup precedes these clauses. Pending command
  # admission already owns the slot before an episode has a captured clock.
  # Concept: a fresh expired input records a refusal, never a run admission.
  # Technical depth: proposal identity and duplicate lookup already succeeded.
  # Retain the original sampled clock in this one immutable transaction; unknown
  # resolution and replay do not sample it again.
  defp propose_new(
         state,
         %{type: type, bounds: %{deadline_at_ms: ceiling}, resolved_bounds: %{admitted_at: now}} =
           command,
         digest
       )
       when type in [:prompt, :follow_up] and is_integer(now) and now >= ceiling do
    record =
      retain_authored_bounds(
        %{
          "command_id" => command.command_id,
          "command_digest" => digest,
          "command_type" => Atom.to_string(type),
          "admission" => "rejected_deadline_elapsed",
          "admitted_at" => now,
          "deadline_at_ms" => ceiling,
          kind: "command_admitted"
        },
        command
      )

    build_proposal(state, command.command_id, record, [], {:error, :deadline_elapsed})
  end

  defp propose_new(%{pending_compact: pending} = state, %{type: :abort} = command, digest)
       when is_map(pending) do
    record = %{
      :kind => "compact_abort_admitted_v1",
      "command_id" => command.command_id,
      "command_digest" => digest,
      "command_type" => "abort",
      "admission" => "accepted",
      "compact_command_id" => pending["command_id"],
      "episode_id" => pending["episode_id"]
    }

    admitted_proposal(
      state,
      command,
      digest,
      "abort",
      record,
      [],
      {:accepted, command.command_id}
    )
  end

  defp propose_new(%{pending_compact: pending} = state, command, digest)
       when is_map(pending) do
    refusal(
      state,
      command,
      digest,
      Atom.to_string(command.type),
      "rejected_maintenance_active",
      :maintenance_active
    )
  end

  defp propose_new(state, %{type: :compact} = command, digest) do
    admission = if is_nil(state.active_run_id), do: "accepted", else: "rejected_run_active"

    reply =
      if admission == "accepted", do: {:accepted, command.command_id}, else: {:error, :run_active}

    record = %{
      :kind => "compact_command_admitted_v1",
      "command_id" => command.command_id,
      "command_digest" => digest,
      "command_type" => "compact",
      "admission" => admission,
      "bounds" => command.bounds,
      "episode_id" => stable_id("compact", state.session_id, command.command_id)
    }

    admitted_proposal(state, command, digest, "compact", record, [], reply)
  end

  # Concept: configuration changes retain one candidate or one unchanged refusal.
  # Technical depth: host preparation is separate from authored command bytes.
  # Duplicate lookup has already happened; replay rederives the candidate from
  # captured facts, never from a catalog or a new runtime default. Owner history
  # preflight must precede supplying a prepared candidate at this pure boundary.
  defp propose_new(%{configuration: nil}, %{type: type}, _digest)
       when type in [:configure, :prompt],
       do: {:error, :invalid_session_configuration}

  defp propose_new(state, %{type: :configure} = command, digest) do
    candidate = command.resolved_bounds[:configuration_candidate]

    admission =
      cond do
        not configuration_settled?(state) ->
          "rejected_configuration_not_settled"

        command.resolved_bounds[:configuration_owner_settled] == false ->
          "rejected_configuration_owner_busy"

        is_nil(candidate) ->
          "rejected_configuration_not_prepared"

        configuration_candidate(state, command.changes, candidate) != :ok ->
          "rejected_invalid_session_configuration"

        command.resolved_bounds[:configuration_preflight] == :invalid_session_configuration ->
          "rejected_invalid_session_configuration"

        command.resolved_bounds[:configuration_preflight] == :compaction_required ->
          "rejected_configuration_compaction_required"

        true ->
          "accepted"
      end

    record = %{
      "command_type" => "configure",
      "command_id" => command.command_id,
      "command_digest" => digest,
      "admission" => admission,
      "changes" => configuration_record_changes(command.changes, admission),
      "prior_configuration_version" => configuration_version(state),
      "configuration" => if(admission == "accepted", do: candidate, else: nil),
      kind: "session_configuration_admitted_v2"
    }

    with {:ok, next} <- apply_command_record(state, record) do
      events = Enum.drop(next.expected_events, length(state.expected_events))

      admitted_proposal(
        state,
        command,
        digest,
        "configure",
        record,
        events,
        next.commands[command.command_id].reply
      )
    end
  end

  defp propose_new(%__MODULE__{active_run_id: nil} = state, %{type: :prompt} = command, digest) do
    run_id = command_run_id(state.session_id, command.command_id)
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
      "configuration_version" => configuration_version(state),
      kind: "prompt_admitted_v3"
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

    build_proposal(state, command.command_id, retain_authored_bounds(record, command), [], reply)
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
      kind:
        if(match?(%{producer: "model_tool"}, open_interaction_record(state)),
          do: "model_question_abort_admitted_v2",
          else: "command_admitted"
        )
    }

    {_patch, queue_events} = cancel_queues(state, run_id, record)

    build_proposal(
      state,
      command.command_id,
      record,
      queue_events,
      {:accepted, command.command_id}
    )
  end

  # Concept: an answer is admitted against the exact question it names, while
  # that question is still open and unanswered.
  #
  # Technical depth: accepted ADR 0024 commits the answer and its public
  # admission in one transaction. Every refusal here is a stable reason rather
  # than a silent no-op: an answer to a question that is not open, to a
  # different question than the one that is, to one already answered, or naming
  # a choice that was never offered. None of them reopens anything, and none of
  # them is evidence a host decided.
  defp propose_new(%__MODULE__{} = state, %{type: :interaction_answer} = command, digest) do
    case answerable(state, command) do
      {:ok, %{producer: "model_tool"} = interaction} ->
        model_question_response_proposal(state, command, digest, interaction)

      {:ok, interaction} ->
        record = %{
          "command_id" => command.command_id,
          "command_digest" => digest,
          "command_type" => "interaction_answer",
          "admission" => "accepted",
          "interaction_id" => interaction.interaction_id,
          "choice_id" => command.choice_id,
          "answer_digest" => Interaction.digest(%{choice_id: command.choice_id}),
          kind: "policy_interaction_answer_admitted_v1"
        }

        with {:ok, next} <- apply_command_record(state, record) do
          events = Enum.drop(next.expected_events, length(state.expected_events))

          admitted_proposal(
            state,
            command,
            digest,
            "interaction_answer",
            record,
            events,
            {:accepted, command.command_id}
          )
        end

      {:error, reason} ->
        refusal(
          state,
          command,
          digest,
          "interaction_answer",
          "rejected_" <> Atom.to_string(reason),
          reason
        )
    end
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

  # Concept: which answers this session will admit against which question.
  #
  # Technical depth: every refusal is a stable reason an operator can act on,
  # and none of them is a no-op: a late answer to a question that has already
  # resolved refuses rather than reopening it, and an answer naming a choice
  # that was never offered never reaches the host as though it had been.
  defp answerable(state, command) do
    case Map.get(state.interactions, command.interaction_id) do
      nil ->
        {:error, :interaction_absent}

      %{status: "pending"} = interaction ->
        cond do
          state.open_interaction != interaction.interaction_id ->
            {:error, :interaction_resolved}

          Map.get(interaction, :producer) == "model_tool" ->
            at = Map.get(command.resolved_bounds, :admitted_at)

            if is_integer(at) and at >= interaction.created_at and at < interaction.expires_at do
              case Interaction.model_answer(interaction.request, command_answer(command)) do
                {:ok, _} -> {:ok, interaction}
                _ -> {:error, :invalid_interaction_answer}
              end
            else
              {:error, :interaction_resolved}
            end

          not Interaction.offered?(interaction.request, Map.get(command, :choice_id)) ->
            {:error, :invalid_interaction_answer}

          true ->
            {:ok, interaction}
        end

      _resolved ->
        {:error, :interaction_resolved}
    end
  end

  defp command_answer(%{choice_id: id}), do: %{"choice_id" => id}
  defp command_answer(%{answer: answer}), do: answer

  defp model_question_response_proposal(state, command, digest, interaction) do
    answer = command_answer(command)
    disposition = if answer == %{"disposition" => "declined"}, do: "declined", else: "answered"

    record = %{
      "command_type" => "interaction_answer",
      "admission" => "accepted",
      "command_id" => command.command_id,
      "command_digest" => digest,
      "interaction_id" => interaction.interaction_id,
      "answer" => answer,
      "disposition" => disposition,
      "responded_at" => command.resolved_bounds.admitted_at,
      kind: "model_question_response_admitted_v2"
    }

    with {:ok, next} <- apply_command_record(state, record) do
      events = Enum.drop(next.expected_events, length(state.expected_events))

      admitted_proposal(
        state,
        command,
        digest,
        "interaction_answer",
        record,
        events,
        {:accepted, command.command_id}
      )
    end
  end

  defp refusal(state, command, digest, type, admission, reason) do
    record = %{
      "command_id" => command.command_id,
      "command_digest" => digest,
      "command_type" => type,
      "admission" => admission,
      kind: "command_admitted"
    }

    build_proposal(
      state,
      command.command_id,
      retain_authored_bounds(record, command),
      [],
      {:error, reason}
    )
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
    record = retain_authored_bounds(record, command)

    run_id =
      if type == "compact" or record.kind == "compact_abort_admitted_v1",
        do: nil,
        else: Map.get(record, "run_id") || promoted_run_id(state, command)

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
    do: command_run_id(state.session_id, command.command_id)

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

  defp replay_record(state, %{payload: %{kind: kind}} = record) do
    cond do
      not maintenance_request_tail?(state, kind) ->
        {:error, :incomplete_maintenance_request_pair}

      not maintenance_terminal_tail?(state, kind) ->
        {:error, :incomplete_maintenance_terminal_transaction}

      is_nil(pending_attempt_settlement(state)) or kind == "run_terminal_committed" or
          (kind == "compact_command_completed_v1" and is_map(state.pending_compact)) ->
        replay_admitted_record(state, record)

      true ->
        {:error, :incomplete_model_attempt_settlement_pair}
    end
  end

  defp replay_record(_state, _record), do: {:error, :invalid_private_history}

  defp pending_attempt_settlement(state) do
    Enum.find_value(state.pending_work, fn
      {_run_id, %{stage: "model_attempt_pending_terminal", settlement: settlement}} -> settlement
      _other -> nil
    end) ||
      case state.maintenance_episodes[state.active_maintenance] do
        %{"stage" => "settlement_pending_terminal", "settlement" => settlement} -> settlement
        _ -> nil
      end
  end

  defp complete_attempt_pair(state) do
    if is_nil(pending_attempt_settlement(state)),
      do: :ok,
      else: {:error, :incomplete_model_attempt_settlement_pair}
  end

  # Concept: the session's cleanup period is reconstructed from the record that
  # committed it, never supplied by whatever process happens to be recovering.
  #
  # Technical depth: the shared current decoder retains complete configuration,
  # tools and policy mode. Missing settings and superseded kinds refuse.
  defp replay_admitted_record(
         %{journal_version: 0} = state,
         %{
           journal_version: 1,
           owner_epoch: 0,
           owner_incarnation_id: nil,
           payload: %{kind: kind} = payload
         }
       )
       when kind == "session_genesis_v3" do
    case SessionGenesis.normalize(payload) do
      {:ok, genesis} ->
        grace = genesis["runtime_configuration"]["cleanup_grace_ms"]

        {:ok,
         %{
           state
           | journal_version: 1,
             cleanup_grace_ms: grace,
             session_options: genesis["options"],
             configuration: genesis["initial_configuration"],
             tool_selection: genesis["tool_selection"],
             policy_defer_mode: genesis["policy_defer_mode"]
         }}

      {:error, _reason} ->
        {:error, :invalid_session_genesis}
    end
  end

  defp replay_admitted_record(
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

  defp replay_admitted_record(
         state,
         %{
           journal_version: version,
           owner_epoch: owner_epoch,
           owner_incarnation_id: incarnation,
           payload: %{kind: "resource_command_v1"} = record
         }
       ) do
    if version == state.journal_version + 1 and owner_epoch == state.owner_epoch and
         incarnation == state.owner_incarnation_id and is_binary(incarnation) and
         context_refusal_tail?(state, "resource_command_v1") do
      case apply_resource_record(state, record) do
        {:ok, next} -> {:ok, %{next | journal_version: version}}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :invalid_resource_command_owner_stamp}
    end
  end

  defp replay_admitted_record(
         state,
         %{
           journal_version: version,
           owner_epoch: owner_epoch,
           owner_incarnation_id: incarnation,
           payload: %{kind: kind} = record
         }
       )
       when kind in [
              "command_admitted",
              "model_question_abort_admitted_v2",
              "prompt_admitted_v3",
              "model_question_response_admitted_v2",
              "policy_interaction_answer_admitted_v1",
              "session_configuration_admitted_v2",
              "compact_command_admitted_v1",
              "compact_abort_admitted_v1",
              "command_admission_refused_v1"
            ] do
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

  defp replay_admitted_record(
         state,
         %{
           journal_version: version,
           owner_epoch: owner_epoch,
           owner_incarnation_id: incarnation,
           payload: %{kind: kind} = record
         }
       )
       when kind in [
              "context_admission_refused_v2",
              "deadline_staging_failed_v1",
              "model_request_committed_v2",
              "model_request_committed_resources_v2",
              "model_attempt_opened_v1",
              "model_attempt_settled_v3",
              "model_termination_admitted_v1",
              "effect_intent_committed_v2",
              "executor_receipt_committed_v2",
              "tool_result_preparation_state_v1",
              "maintenance_episode_admitted_v1",
              "standalone_maintenance_episode_admitted_v1",
              "compact_command_completed_v1",
              "maintenance_episode_terminal_v1",
              "compaction_checkpoint_committed_v1",
              "standalone_compaction_checkpoint_committed_v1",
              "maintenance_request_committed_v1",
              "maintenance_attempt_opened_v1",
              "maintenance_attempt_settled_v3",
              "maintenance_termination_admitted_v1",
              "tool_result_reference_prepared",
              "tool_result_preparation_failed_v1",
              "outcome_unknown_committed_v2",
              "run_terminal_committed",
              "tool_result_committed_v2",
              "interaction_requested_v1",
              "interaction_resolved_v1",
              "model_question_requested_v1",
              "model_question_settled_v2"
            ] do
    if version == state.journal_version + 1 and owner_epoch == state.owner_epoch and
         incarnation == state.owner_incarnation_id and is_binary(incarnation) and
         context_refusal_tail?(state, kind) do
      case apply_admitted_internal_record(state, record, version) do
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

  defp replay_admitted_record(_state, _record), do: {:error, :invalid_private_history}

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
         :ok <- validate_authored_bounds_record(record),
         true <- admissible_pending_compact_command?(state, record),
         {:ok, record_source} <- original_record_source(record, state.journal_version + 1),
         {:ok, reply, active_run_id, pending_work, expected_events, patch} <-
           command_effect(state, record, command_type, admission, command_id) do
      run_id =
        record["run_id"] ||
          case Map.get(state.interactions, record["interaction_id"]) do
            %{run_id: run_id} -> run_id
            _absent -> nil
          end

      command_binding = %{
        digest: digest,
        reply: reply,
        run_id: run_id,
        record_source: record_source
      }

      next =
        Map.merge(
          %{
            state
            | active_run_id: active_run_id,
              pending_work: pending_work,
              expected_events: expected_events,
              commands: Map.put(state.commands, command_id, command_binding)
          },
          patch
        )

      retain_conversation_record_sources(state, next, record_source)
    else
      false -> {:error, :invalid_standalone_compact_transition}
      true -> {:error, :duplicate_command_record}
      {:error, reason} -> {:error, reason}
    end
  end

  defp admissible_pending_compact_command?(%{pending_compact: nil}, _record), do: true

  defp admissible_pending_compact_command?(_state, %{kind: "compact_abort_admitted_v1"}), do: true

  defp admissible_pending_compact_command?(_state, record),
    do: record.kind == "command_admitted" and record["admission"] == "rejected_maintenance_active"

  # Concept: an accepted prompt must carry the ceiling its run committed.
  #
  # Technical depth: accepted prompts use their current configuration-bound kind.
  # Other commands and rejected prompts use the generic admission kind. It never
  # admits an accepted prompt without its retained settings.
  defp admissible_command_kind?("command_admitted", record),
    do:
      not (record["command_type"] in ["prompt", "interaction_answer"] and
             record["admission"] == "accepted")

  defp admissible_command_kind?("policy_interaction_answer_admitted_v1", record),
    do: record["command_type"] == "interaction_answer" and record["admission"] == "accepted"

  defp admissible_command_kind?("model_question_abort_admitted_v2", record),
    do:
      closed_history_map?(record, [
        :kind,
        "command_id",
        "command_digest",
        "command_type",
        "admission",
        "run_id"
      ]) and record["command_type"] == "abort" and record["admission"] == "accepted"

  defp admissible_command_kind?("model_question_response_admitted_v2", record),
    do: record["command_type"] == "interaction_answer" and record["admission"] == "accepted"

  defp admissible_command_kind?("session_configuration_admitted_v2", record),
    do: record["command_type"] == "configure"

  defp admissible_command_kind?("compact_command_admitted_v1", record),
    do: record["command_type"] == "compact"

  defp admissible_command_kind?("compact_abort_admitted_v1", record),
    do: record["command_type"] == "abort" and record["admission"] == "accepted"

  defp admissible_command_kind?("prompt_admitted_v3", record),
    do:
      map_size(record) == 14 and record["command_type"] == "prompt" and
        record["admission"] == "accepted"

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
    do: candidate in ~w(prompt_record steer_record follow_up_record interaction_answer_record)

  defp valid_refused_candidate?("command_event_bytes", candidate),
    do: candidate == "follow_up_user_message_event"

  defp valid_refused_candidate?("future_bound_record_bytes", candidate),
    do: candidate in ~w(max_turns_private_terminal max_turns_public_finish
        token_budget_private_terminal token_budget_public_finish
        deadline_private_terminal deadline_public_finish)

  defp valid_refused_candidate?(_dimension, _candidate), do: false

  # Concept: accepted compact admission records no clock, prompt or run.
  # Technical depth: replay reconstructs the exact bounded command preimage and
  # idempotency digest. The pending slot alone is dispatch-inert and captures no
  # host model or instruction settings before episode admission.
  defp command_effect(
         state,
         %{kind: "compact_command_admitted_v1"} = record,
         "compact",
         admission,
         command_id
       ) do
    with true <-
           closed_history_map?(record, [
             :kind,
             "command_id",
             "command_digest",
             "command_type",
             "admission",
             "bounds",
             "episode_id"
           ]),
         {:ok, bounds} <- normalize_compact_bounds(record["bounds"]),
         true <- bounds == record["bounds"],
         {:ok, digest} <-
           command_digest(%{type: :compact, command_id: command_id, bounds: bounds}),
         true <- record["command_digest"] == digest,
         true <- record["episode_id"] == stable_id("compact", state.session_id, command_id) do
      case {admission, state.active_run_id} do
        {"accepted", nil} ->
          with true <- state.pending_work == %{} and is_nil(state.active_maintenance),
               true <-
                 is_nil(state.aborting) and is_nil(state.open_interaction) and
                   is_nil(state.follow_up) do
            pending = %{
              "command_id" => command_id,
              "episode_id" => record["episode_id"],
              "bounds" => bounds,
              "abort_command_id" => nil
            }

            {:ok, {:accepted, command_id}, nil, state.pending_work, state.expected_events,
             %{pending_compact: pending}}
          else
            _ -> {:error, :invalid_standalone_compact_transition}
          end

        {"rejected_run_active", run} when is_binary(run) ->
          {:ok, {:error, :run_active}, run, state.pending_work, state.expected_events, %{}}

        _ ->
          {:error, :invalid_standalone_compact_transition}
      end
    else
      _ -> {:error, :invalid_standalone_compact_transition}
    end
  end

  defp command_effect(
         %{pending_compact: pending} = state,
         %{kind: "compact_abort_admitted_v1"} = record,
         "abort",
         "accepted",
         command_id
       )
       when is_map(pending) do
    with true <-
           closed_history_map?(record, [
             :kind,
             "command_id",
             "command_digest",
             "command_type",
             "admission",
             "compact_command_id",
             "episode_id"
           ]),
         {:ok, digest} <- command_digest(%{type: :abort, command_id: command_id}),
         true <- record["command_digest"] == digest,
         true <- record["compact_command_id"] == pending["command_id"],
         true <- record["episode_id"] == pending["episode_id"] do
      pending =
        if is_nil(pending["abort_command_id"]),
          do: Map.put(pending, "abort_command_id", command_id),
          else: pending

      {:ok, {:accepted, command_id}, nil, state.pending_work, state.expected_events,
       %{pending_compact: pending}}
    else
      _ -> {:error, :invalid_standalone_compact_transition}
    end
  end

  defp command_effect(
         %{pending_compact: pending} = state,
         record,
         type,
         "rejected_maintenance_active",
         _command_id
       )
       when is_map(pending) and
              type in ~w(prompt steer follow_up configure compact interaction_answer) do
    if closed_history_map?(record, [
         :kind,
         "command_id",
         "command_digest",
         "command_type",
         "admission"
       ]),
       do:
         {:ok, {:error, :maintenance_active}, nil, state.pending_work, state.expected_events, %{}},
       else: {:error, :invalid_standalone_compact_transition}
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
         {:ok, declared} <- record_bounds(record),
         {:ok, context_budget} <- record_context_token_budget(record),
         {:ok, configuration} <- admitted_run_configuration(state, record, context_budget) do
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
        run_order: state.run_order ++ [run_id],
        bounds: Map.put(state.bounds, run_id, declared),
        context_budgets: Map.put(state.context_budgets, run_id, context_budget),
        run_configurations: Map.put(state.run_configurations, run_id, configuration),
        run_resources: Map.put(state.run_resources, run_id, state.resources)
      }

      {:ok, {:accepted, command_id}, run_id, Map.put(state.pending_work, run_id, work),
       expected_events, patch}
    end
  end

  defp command_effect(
         state,
         %{kind: "session_configuration_admitted_v2"} = record,
         "configure",
         admission,
         command_id
       ) do
    with true <- map_size(record) == 8,
         {:ok, changes} <- configuration_command_changes(record),
         command = %{type: :configure, command_id: command_id, changes: changes},
         {:ok, digest} <- command_digest(command),
         true <- digest == record["command_digest"],
         true <- record["prior_configuration_version"] == configuration_version(state) do
      case admission do
        "accepted" ->
          with true <- configuration_settled?(state),
               :ok <- configuration_candidate(state, command.changes, record["configuration"]),
               public = %{
                 "command_id" => command_id,
                 "configuration" => SessionConfiguration.public_view(record["configuration"])
               },
               {:ok, _} <- LoopexProtocol.Session.Configuration.encode_change(public) do
            event =
              Map.merge(public, %{
                event_id: stable_id("event-configuration", state.session_id, command_id),
                kind: "session.configured"
              })

            {:ok, {:accepted, command_id}, nil, state.pending_work,
             state.expected_events ++ [event], %{configuration: record["configuration"]}}
          else
            _ -> {:error, :invalid_configuration_transition}
          end

        refusal ->
          with true <- is_nil(record["configuration"]),
               {:ok, reason} <- configuration_refusal(state, refusal) do
            {:ok, {:error, reason}, state.active_run_id, state.pending_work,
             state.expected_events, %{}}
          else
            _ -> {:error, :invalid_configuration_transition}
          end
      end
    else
      _ -> {:error, :invalid_configuration_transition}
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
    with {:ok, content} <- record_binary(record, "content"),
         {:ok, authored} <- decode_retained_authored_bounds(record["authored_bounds"], :follow_up) do
      {:ok, {:accepted, command_id}, active, state.pending_work, state.expected_events,
       %{
         follow_up: %{
           command_id: command_id,
           content: content,
           authored_bounds: authored
         }
       }}
    end
  end

  # Concept: the admitted answer becomes the interaction's answered state.
  #
  # Technical depth: the same transaction that admitted the command carries this
  # transition, so there is no moment in which an operator was told their answer
  # was accepted while the question still reads as unanswered. The status means
  # policy resolution is owed and nothing more.
  defp command_effect(
         state,
         %{kind: kind} = record,
         "interaction_answer",
         "accepted",
         command_id
       )
       when kind == "model_question_response_admitted_v2" do
    with true <- map_size(record) == 9 and record["disposition"] in ["answered", "declined"],
         :ok <- model_question_command_binding(record),
         {:ok, next, events} <- settle_model_question(state, record) do
      {:ok, {:accepted, command_id}, next.active_run_id, next.pending_work,
       state.expected_events ++ events,
       %{
         interactions: next.interactions,
         open_interaction: next.open_interaction,
         conversation: next.conversation
       }}
    else
      _ -> {:error, :invalid_model_question_transition}
    end
  end

  defp command_effect(
         state,
         %{kind: "policy_interaction_answer_admitted_v1"} = record,
         "interaction_answer",
         "accepted",
         command_id
       ) do
    with true <-
           closed_history_map?(record, [
             :kind,
             "command_id",
             "command_digest",
             "command_type",
             "admission",
             "interaction_id",
             "choice_id",
             "answer_digest"
           ]),
         {:ok, interaction_id} <- record_binary(record, "interaction_id"),
         {:ok, choice_id} <- record_binary(record, "choice_id"),
         {:ok, command} <-
           normalize_command(%{
             type: :interaction_answer,
             command_id: command_id,
             interaction_id: interaction_id,
             choice_id: choice_id
           }),
         {:ok, digest} <- command_digest(command),
         true <- record["command_digest"] == digest,
         true <- record["answer_digest"] == Interaction.digest(%{choice_id: choice_id}),
         %{status: "pending"} = interaction <- Map.get(state.interactions, interaction_id),
         true <- state.open_interaction == interaction_id,
         true <- Map.get(interaction, :producer) != "model_tool",
         true <- Interaction.offered?(interaction.request, choice_id) do
      answered =
        interaction
        |> Map.put(:status, "answered")
        |> Map.put(:choice_id, choice_id)
        |> Map.put(:command_id, command_id)

      event = %{
        :kind => "interaction.answer_admitted",
        :event_id => stable_id("event-interaction-answer", state.session_id, command_id),
        "interaction_id" => interaction_id,
        "run_id" => interaction.run_id,
        "turn" => interaction.turn,
        "tool_call_id" => interaction.tool_call_id,
        "producer" => "policy_defer",
        "interaction_kind" => "choice",
        "status" => "answered",
        "answer_choice_id" => choice_id,
        "answer_command_id" => command_id
      }

      {:ok, {:accepted, command_id}, state.active_run_id, state.pending_work,
       state.expected_events ++ [event],
       %{interactions: Map.put(state.interactions, interaction_id, answered)}}
    else
      _other -> {:error, :invalid_interaction_answer_record}
    end
  end

  defp command_effect(_state, _record, "interaction_answer", "accepted", _command_id),
    do: {:error, :invalid_interaction_answer_record}

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
  defp command_effect(state, record, type, "rejected_deadline_elapsed", _command_id)
       when type in ["prompt", "follow_up"] do
    with ceiling <- record["deadline_at_ms"],
         {:ok, _} <- Bounds.authored(%{deadline_at_ms: ceiling}, :follow_up),
         now when is_integer(now) and now >= ceiling <- record["admitted_at"],
         true <-
           closed_history_map?(record, [
             :kind,
             "command_id",
             "command_digest",
             "command_type",
             "admission",
             "admitted_at",
             "deadline_at_ms"
           ]) do
      {:ok, {:error, :deadline_elapsed}, state.active_run_id, state.pending_work,
       state.expected_events, %{}}
    else
      _ -> {:error, :invalid_expired_command_refusal}
    end
  end

  defp command_effect(state, _record, type, "rejected_" <> reason, _command_id)
       when type in ["steer", "follow_up", "interaction_answer"] do
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
    with {:ok, ^active_run_id} <- record_binary(record, "run_id"),
         true <-
           match?(%{producer: "model_tool"}, open_interaction_record(state)) ==
             (record.kind == "model_question_abort_admitted_v2"),
         true <-
           record.kind != "model_question_abort_admitted_v2" or
             admissible_command_kind?(record.kind, record) do
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
      {patch, queue_events} = cancel_queues(state, active_run_id, record)

      {:ok, {:accepted, command_id}, active_run_id, state.pending_work,
       state.expected_events ++ queue_events,
       patch
       |> retain_maintenance_abort(state, active_run_id)
       |> Map.put(:aborting, %{run_id: active_run_id, command_id: command_id})}
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
  defp rejected_command_reason("interaction_absent"), do: {:ok, :interaction_absent}
  defp rejected_command_reason("interaction_resolved"), do: {:ok, :interaction_resolved}

  defp rejected_command_reason("invalid_interaction_answer"),
    do: {:ok, :invalid_interaction_answer}

  defp rejected_command_reason(_reason), do: :error

  defp configuration_version(%{configuration: nil}), do: nil
  defp configuration_version(state), do: state.configuration["configuration_version"]

  # Concept: an accepted instruction update retains its exact bytes once.
  # Technical depth: the candidate contains the captured instruction sections;
  # authored-change identity retains their version/digest descriptor. Replay
  # verifies that descriptor and reconstructs the full command preimage before
  # checking its digest, avoiding a second copy that would consume the Store
  # item ceiling without proving anything new. Refusals retain their raw changes.
  defp configuration_record_changes(changes, "accepted") do
    if Map.has_key?(changes, "instructions"),
      do: Map.update!(changes, "instructions", &Map.take(&1, ~w(version digest))),
      else: changes
  end

  defp configuration_record_changes(changes, _refusal), do: changes

  defp configuration_command_changes(record) do
    changes = record["changes"]

    if record["admission"] == "accepted" and is_map(changes) and
         Map.has_key?(changes, "instructions") do
      with %{} = candidate <- record["configuration"],
           %{} = instructions <- candidate["instructions"],
           true <- changes["instructions"] == Map.take(instructions, ~w(version digest)),
           restored = Map.put(changes, "instructions", instructions),
           :ok <- SessionConfiguration.validate_update(restored) do
        {:ok, restored}
      else
        _ -> :error
      end
    else
      case SessionConfiguration.validate_update(changes) do
        :ok -> {:ok, changes}
        _ -> :error
      end
    end
  end

  defp configuration_settled?(state) do
    is_nil(state.active_run_id) and state.pending_work == %{} and is_nil(state.aborting) and
      is_nil(state.open_interaction) and is_nil(state.context_refusal) and is_nil(state.follow_up) and
      is_nil(state.pending_compact) and
      not Enum.any?(state.conversation, fn {_run, elements} ->
        Enum.any?(elements, &(&1.kind == :tool_result and &1.outcome == :outcome_unknown))
      end)
  end

  defp configuration_candidate(
         %{configuration: current, tool_selection: selection} = state,
         changes,
         candidate
       )
       when is_map(current) and is_map(selection) and is_map(candidate) do
    case SessionConfiguration.validate_candidate(
           current,
           changes,
           candidate,
           selection["definitions"]
         ) do
      :ok ->
        SessionConfiguration.preflight_history(
          candidate,
          uncompacted_elements(state, lineage_elements(state, :session)),
          state.run_order
        )

      _ ->
        {:error, :invalid_configuration_transition}
    end
  end

  defp configuration_candidate(_, _, _), do: {:error, :invalid_configuration_transition}

  defp configuration_refusal(state, "rejected_configuration_not_settled") do
    if configuration_settled?(state), do: :error, else: {:ok, :configuration_not_settled}
  end

  defp configuration_refusal(
         %{configuration: configuration} = state,
         "rejected_configuration_not_prepared"
       )
       when is_map(configuration) do
    if configuration_settled?(state), do: {:ok, :configuration_not_prepared}, else: :error
  end

  defp configuration_refusal(
         %{configuration: configuration} = state,
         "rejected_invalid_session_configuration"
       )
       when is_map(configuration) do
    if configuration_settled?(state), do: {:ok, :invalid_session_configuration}, else: :error
  end

  # Concept: an owner can refuse a configuration before changing durable truth.
  # Technical depth: owner-worker quiescence and exact prospective request size
  # are admission observations, not reconstruction of a provider attempt. Their
  # captured unchanged replies remain stable after the owner or history changes.
  defp configuration_refusal(%{configuration: configuration} = state, admission)
       when is_map(configuration) and
              admission in [
                "rejected_configuration_owner_busy",
                "rejected_configuration_compaction_required"
              ] do
    if configuration_settled?(state) do
      {:ok,
       if(admission == "rejected_configuration_owner_busy",
         do: :configuration_not_settled,
         else: :compaction_required
       )}
    else
      :error
    end
  end

  defp configuration_refusal(_, _), do: :error

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
    build_internal_proposal(state, logical_tx_id, records, nil)
  end

  defp build_internal_proposal(state, logical_tx_id, records, observed_at) do
    with [_first | _rest] <- records,
         {:ok, records} <- maintenance_terminal_prefix(state, records, observed_at),
         {:ok, next, events} <- apply_internal_records(state, records),
         :ok <- complete_maintenance_pair(next) do
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
    records
    |> Enum.with_index(state.journal_version + 1)
    |> Enum.reduce_while({:ok, state, []}, fn {record, version}, {:ok, current, events} ->
      case apply_admitted_internal_record(current, record, version) do
        {:ok, next, emitted} -> {:cont, {:ok, next, events ++ emitted}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  # Concept: an episode and its owning run or compact command settle together.
  # Technical depth: ADR 0043 permits one leading episode terminal and then
  # the compact completion, run terminal or existing refusal/settlement pair.
  # The marker has no episode, accounting or public effect before that terminal.
  # Every replayed row, including commands and owner succession, obeys its tail.
  defp complete_maintenance_pair(%{maintenance_terminal: nil} = state) do
    if maintenance_request_tail?(state, nil),
      do: :ok,
      else: {:error, :incomplete_maintenance_request_pair}
  end

  defp complete_maintenance_pair(_state),
    do: {:error, :incomplete_maintenance_terminal_transaction}

  defp maintenance_request_tail?(state, kind) do
    case state.maintenance_episodes[state.active_maintenance] do
      %{"stage" => "request_pending_attempt_open"} -> kind == "maintenance_attempt_opened_v1"
      _ -> true
    end
  end

  defp maintenance_terminal_tail?(%{maintenance_terminal: nil}, _kind), do: true

  defp maintenance_terminal_tail?(%{maintenance_terminal: %{next: :ending}}, kind),
    do:
      kind in [
        "run_terminal_committed",
        "context_admission_refused_v2",
        "deadline_staging_failed_v1",
        "model_attempt_settled_v3",
        "maintenance_attempt_settled_v3"
      ]

  defp maintenance_terminal_tail?(%{maintenance_terminal: %{next: :run_terminal}}, kind),
    do: kind == "run_terminal_committed"

  defp maintenance_terminal_tail?(%{maintenance_terminal: %{next: :compact_settlement}}, kind),
    do: kind == "maintenance_attempt_settled_v3"

  defp maintenance_terminal_tail?(%{maintenance_terminal: %{next: :compact_terminal}}, kind),
    do: kind == "compact_command_completed_v1"

  defp apply_admitted_internal_record(state, %{kind: kind} = record, version) do
    if maintenance_terminal_tail?(state, kind) and maintenance_request_tail?(state, kind) do
      with {:ok, next, events} <- apply_internal_record(state, record),
           {:ok, next} <-
             retain_pending_settlement_source(next, record, version || state.journal_version + 1) do
        # Concept: dispatch retains the attempt's own authenticated position.
        # Technical depth: proposal and replay derive this from the envelope
        # sequence, including paired first opens and single-record retries.
        next = retain_attempt_open_version(next, record, version || state.journal_version + 1)

        next =
          if kind in [
               "maintenance_episode_admitted_v1",
               "standalone_maintenance_episode_admitted_v1"
             ],
             do:
               put_in(
                 next.maintenance_episodes[record["episode_id"]]["session_version"],
                 version || state.journal_version + 1
               ),
             else: next

        next =
          case {state.maintenance_terminal, next.maintenance_terminal, kind} do
            {%{next: :ending}, %{} = marker, kind} when kind != "run_terminal_committed" ->
              %{next | maintenance_terminal: %{marker | next: :run_terminal}}

            {%{next: :compact_settlement}, %{} = marker, "maintenance_attempt_settled_v3"} ->
              %{next | maintenance_terminal: %{marker | next: :compact_terminal}}

            _ ->
              next
          end

        with {:ok, events} <-
               maintenance_view_events(state, next, version || state.journal_version + 1, events) do
          if next.conversation == state.conversation do
            {:ok, next, events}
          else
            with {:ok, source} <-
                   original_record_source(record, version || state.journal_version + 1),
                 {:ok, next} <- retain_conversation_record_sources(state, next, source) do
              {:ok, next, events}
            end
          end
        end
      end
    else
      {:error, :incomplete_maintenance_terminal_transaction}
    end
  end

  defp retain_attempt_open_version(state, %{kind: "model_attempt_opened_v1"} = record, version),
    do: put_in(state.pending_work[record["run_id"]][:attempt_open_version], version)

  defp retain_attempt_open_version(state, %{kind: "maintenance_attempt_opened_v1"}, version),
    do:
      put_in(
        state.maintenance_episodes[state.active_maintenance]["attempt_open_version"],
        version
      )

  defp retain_attempt_open_version(state, _record, _version), do: state

  # Concept: public maintenance changes are committed facts of the serial owner.
  # Technical depth: proposal and recovery share this reducer. Derive only the
  # accepted allowlist from authenticated episode records, preserving captured
  # admission bounds rather than mutable counters. Emit a changed view before
  # that row's other events so a terminal outcome never precedes its inactive
  # view. The journal position fixes the identity across unknown-commit recovery;
  # unchanged stages, duplicate commands and owner succession add no view row.
  defp maintenance_view_events(prior, next, version, events) do
    before = maintenance_public_view(prior)
    after_view = maintenance_public_view(next)

    if before == after_view do
      {:ok, events}
    else
      payload = %{"active_maintenance" => after_view}

      event =
        Map.merge(payload, %{
          kind: "context.maintenance_changed",
          event_id: stable_id("event-maintenance-view", next.session_id, version)
        })

      with {:ok, _} <- LoopexProtocol.Session.MaintenanceView.encode_wire(payload),
           {:ok, _} <- Store.admit_bounded(event) do
        {:ok, [event | events]}
      else
        _ -> {:error, :invalid_maintenance_public_view}
      end
    end
  end

  defp maintenance_public_view(%{active_maintenance: nil}), do: nil

  defp maintenance_public_view(state) do
    episode = Map.fetch!(state.maintenance_episodes, state.active_maintenance)

    owner =
      case episode do
        %{"run_id" => run_id, kind: "maintenance_episode_admitted_v1"} ->
          %{"kind" => "run", "id" => run_id}

        %{"command_id" => command_id, kind: "standalone_maintenance_episode_admitted_v1"} ->
          %{"kind" => "compact", "id" => command_id}
      end

    %{
      "episode_id" => episode["episode_id"],
      "owner" => owner,
      "model" => episode["maintenance_configuration"]["selection"]["model"],
      "reasoning" => episode["maintenance_configuration"]["selection"]["reasoning"],
      "configuration_version" => episode["configuration_version"],
      "bounds" => episode["bounds"]
    }
  end

  defp original_record_source(record, version) do
    with {:ok, normalized, bytes} <- Store.normalize_and_measure_item(:record, record) do
      {:ok,
       %{
         record_digest: Canonical.digest(normalized),
         record_byte_cost: bytes,
         journal_version: version
       }}
    end
  end

  # Concept: a deferred assistant still belongs to the settlement that supplied it.
  # Technical depth: the terminal pair keeps the settlement's digest/position
  # alongside its existing pending row. The ending publishes that row's facts;
  # it supplies no replacement reply provenance across proposal or replay pages.
  defp retain_pending_settlement_source(
         state,
         %{"run_id" => run, kind: "model_attempt_settled_v3"} = record,
         version
       ) do
    case Map.get(state.pending_work, run) do
      %{stage: "model_attempt_pending_terminal"} = work ->
        with {:ok, source} <- original_record_source(record, version) do
          {:ok, put_pending(state, run, Map.put(work, :settlement_record_source, source))}
        end

      _ ->
        {:ok, state}
    end
  end

  defp retain_pending_settlement_source(state, _record, _version), do: {:ok, state}

  # Concept: promoting an input does not change which record originally admitted it.
  # Technical depth: only newly derived elements receive provenance. Questions,
  # receipt results and terminal-generated results bind the outer committed row,
  # rather than a synthetic nested tool-result payload used by a reducer helper.
  # Sources already retained cannot be overwritten by a later staging record.
  defp retain_conversation_record_sources(prior, next, source) do
    additions =
      next.conversation
      |> Stream.flat_map(fn {run, elements} ->
        previous = Map.get(prior.conversation, run, [])
        if elements == previous, do: [], else: Stream.drop(elements, length(previous))
      end)

    Enum.reduce_while(additions, {:ok, next}, fn element, {:ok, current} ->
      reference = Conversation.source_reference(element)

      original =
        case element do
          %{kind: :user_message, command_id: command} ->
            get_in(current.commands, [command, :record_source])

          %{kind: :assistant_message, run_id: run} ->
            case Map.get(prior.pending_work, run) do
              %{stage: "model_attempt_pending_terminal", settlement_record_source: original} ->
                original

              _ ->
                source
            end

          _ ->
            source
        end

      if is_map(original) and not Map.has_key?(current.conversation_record_sources, reference) do
        retained = Map.put(current.conversation_record_sources, reference, original)
        {:cont, {:ok, %{current | conversation_record_sources: retained}}}
      else
        {:halt, {:error, :context_projection_invalid}}
      end
    end)
  end

  defp compact_completion_record(%{pending_compact: %{}} = state, record)
       when record.kind == "compact_command_completed_v1" do
    case {record["result"]["disposition"], state.maintenance_episodes[state.active_maintenance]} do
      {"checkpointed", %{kind: "standalone_maintenance_episode_admitted_v1"}} ->
        maintenance_checkpoint_completion_record(state, record["observed_at"], fn -> :ok end)

      {_, %{"attempts" => attempts}} when attempts > 0 ->
        standalone_settlement_completion_record(state, record["observed_at"])

      _ ->
        compact_zero_attempt_completion_record(state, record)
    end
  end

  defp compact_completion_record(_, _), do: {:error, :invalid_compact_completion_transition}

  defp compact_zero_attempt_completion_record(
         state,
         %{"result" => %{"disposition" => "unchanged"}} = record
       ),
       do: unchanged_compact_record(state, record["observed_at"], fn -> :ok end)

  defp compact_zero_attempt_completion_record(
         state,
         %{"result" => %{"disposition" => "failed", "failure" => failure}} = record
       ),
       do:
         zero_attempt_compact_failure_record(state, failure, record["observed_at"], fn -> :ok end)

  defp compact_zero_attempt_completion_record(_, _),
    do: {:error, :invalid_compact_completion_transition}

  defp complete_standalone_episode(
         %{active_maintenance: nil, maintenance_terminal: nil} = state,
         _
       ),
       do: {:ok, state}

  defp complete_standalone_episode(state, record) do
    with %{episode_id: id, result: result, observed_at: clock, next: :compact_terminal} <-
           state.maintenance_terminal,
         true <-
           id == record["episode_id"] and result == record["result"] and
             clock == record["observed_at"] do
      {state, episode} = standalone_settlement_charge(state, state.maintenance_episodes[id])
      episode = episode |> Map.put("stage", "settled") |> Map.put("result", result)

      {:ok,
       %{
         state
         | active_maintenance: nil,
           maintenance_terminal: nil,
           maintenance_episodes: Map.put(state.maintenance_episodes, id, episode)
       }}
    else
      _ -> {:error, :invalid_compact_completion_transition}
    end
  end

  defp maintenance_terminal_prefix(%{active_maintenance: nil}, records, nil),
    do: {:ok, records}

  defp maintenance_terminal_prefix(state, records, observed_at) do
    case List.last(records) do
      %{kind: "compact_command_completed_v1"} = completed
      when is_binary(state.active_maintenance) ->
        {:ok,
         [
           %{
             :kind => "maintenance_episode_terminal_v1",
             "episode_id" => state.active_maintenance,
             "observed_at" => completed["observed_at"],
             "result" => completed["result"]
           }
           | records
         ]}

      %{kind: "run_terminal_committed"} = terminal ->
        with {:ok, preview} <- maintenance_ending_preview(state, records),
             {:ok, result} <- maintenance_run_result(preview, terminal) do
          prefix = %{
            :kind => "maintenance_episode_terminal_v1",
            "episode_id" => state.active_maintenance,
            "observed_at" => observed_at,
            "result" => result
          }

          {:ok, [prefix | records]}
        end

      _ ->
        {:ok, records}
    end
  end

  defp maintenance_ending_preview(state, [
         %{kind: "maintenance_attempt_settled_v3"} = record,
         terminal
       ]) do
    with {:ok, next, []} <- apply_internal_record(state, record),
         {:ok, next} <- complete_pending_maintenance_settlement(next, terminal) do
      {:ok, next}
    end
  end

  defp maintenance_ending_preview(state, _records), do: {:ok, state}

  defp retain_maintenance_abort(patch, state, run) do
    case state.maintenance_episodes[state.active_maintenance] do
      %{"run_id" => ^run, "stage" => "model_attempt_open", "model_termination" => nil} = episode ->
        Map.put(
          patch,
          :maintenance_episodes,
          Map.put(
            state.maintenance_episodes,
            state.active_maintenance,
            Map.put(episode, "model_termination", "abort")
          )
        )

      _ ->
        patch
    end
  end

  defp maintenance_run_result(state, terminal) do
    episode = Map.get(state.maintenance_episodes, state.active_maintenance)

    with %{"run_id" => run_id, "usage" => usage, "checkpoint_id" => checkpoint} <- episode,
         true <- episode["stage"] not in ["request_pending_attempt_open", "model_attempt_open"],
         true <- terminal["run_id"] == run_id,
         true <- maintenance_parent_bound_agrees?(state, terminal),
         {:ok, failure} <- maintenance_run_failure(terminal) do
      {:ok,
       %{
         "disposition" => "failed",
         "checkpoint_id" => checkpoint,
         "failure" => failure,
         "usage" => usage,
         "cleanup" =>
           if(
             terminal["outcome"] == "outcome_unknown" or
               unconfirmed_predecessor_cleanup?(state, episode),
             do: "unknown",
             else: "confirmed"
           )
       }}
    else
      _ -> {:error, :invalid_maintenance_episode_transition}
    end
  end

  # Concept: a failed run cannot confirm an inherited provider's cleanup.
  # Technical depth: the authenticated opening stamp binds the attempt to its
  # predecessor. Owner loss, or an abort/deadline that wins over that loss, has
  # no predecessor callback join. Completed reply settlements and episodes
  # without an opened attempt retain their existing confirmed cleanup proof.
  defp unconfirmed_predecessor_cleanup?(state, episode) do
    is_integer(episode["attempt_owner_epoch"]) and
      episode["attempt_owner_epoch"] != state.owner_epoch and
      is_map(episode["settlement"]) and
      episode["settlement"]["termination"] in ~w(owner_loss abort deadline)
  end

  # Concept: an episode reports the bound its parent actually reached.
  # Technical depth: copy the parent's captured ceiling and retained accounting,
  # not an episode attempt limit or a fresh duration. The terminal remains in
  # the parent's algebra, including its literal `deadline` branch.
  defp maintenance_parent_bound_agrees?(state, %{"outcome" => "bound_reached"} = terminal) do
    run_id = terminal["run_id"]
    {declared, charged} = accounting(state, run_id)
    observed = terminal["observed"]
    source = charged.source && Atom.to_string(charged.source)

    is_map(declared) and is_integer(observed) and observed >= 0 and
      terminal["accounting_source"] == source and
      case terminal["bound"] do
        "deadline" ->
          deadline = retained_run_deadline(state, run_id)
          is_integer(deadline) and terminal["declared_limit"] == deadline and observed >= deadline

        "token_budget" ->
          terminal["declared_limit"] == declared.token_budget and observed == charged.tokens and
            observed >= declared.token_budget

        "max_turns" ->
          terminal["declared_limit"] == declared.max_turns and
            observed == maintenance_parent_call_units(state, run_id) and
            observed >= declared.max_turns

        _ ->
          false
      end
  end

  defp maintenance_parent_bound_agrees?(_state, _terminal), do: true

  defp maintenance_run_failure(%{"outcome" => "cancelled"}),
    do: {:ok, %{"category" => "cancelled", "retryable" => false}}

  defp maintenance_run_failure(%{"outcome" => "bound_reached"} = terminal) do
    if terminal["bound"] in ["max_turns", "token_budget", "deadline"] do
      {:ok,
       %{
         "category" => "bound_reached",
         "retryable" => false,
         "bound" =>
           if(terminal["bound"] == "deadline", do: "deadline_ms", else: terminal["bound"]),
         "observed" => terminal["observed"],
         "declared_limit" => terminal["declared_limit"],
         "accounting_source" => terminal["accounting_source"]
       }}
    else
      {:error, :invalid_maintenance_episode_transition}
    end
  end

  defp maintenance_run_failure(%{
         "outcome" => "failed",
         "failure" => %{"category" => "deadline_preflight_failed"}
       }),
       do:
         {:ok,
          %{
            "version" => 2,
            "category" => "context_preparation_failed",
            "retryable" => false,
            "measurement_scope" => nil,
            "cause" => "maintenance_deadline_unrepresentable"
          }}

  defp maintenance_run_failure(%{"outcome" => "failed", "failure" => failure})
       when is_map(failure),
       do: {:ok, failure}

  defp maintenance_run_failure(%{"outcome" => "failed", "reason" => reason})
       when reason in ["model_call_failed", "unreadable_model_answer"],
       do: {:ok, %{"category" => "model_call_failed", "retryable" => false}}

  defp maintenance_run_failure(%{"outcome" => "outcome_unknown"}),
    do: {:ok, %{"category" => "model_call_failed", "retryable" => false}}

  defp maintenance_run_failure(_terminal),
    do: {:error, :invalid_maintenance_episode_transition}

  defp complete_maintenance_terminal(%{active_maintenance: nil} = state, _terminal),
    do: {:ok, state}

  defp complete_maintenance_terminal(state, terminal) do
    with %{episode_id: id, result: retained, observed_at: observed} <- state.maintenance_terminal,
         true <- id == state.active_maintenance,
         true <- valid_maintenance_ending_clock?(state, terminal, observed),
         {:ok, expected} <- maintenance_run_result(state, terminal),
         true <- retained == expected do
      episode =
        state.maintenance_episodes
        |> Map.fetch!(id)
        |> Map.put("stage", "settled")
        |> Map.put("result", retained)

      {:ok,
       %{
         state
         | active_maintenance: nil,
           maintenance_terminal: nil,
           maintenance_episodes: Map.put(state.maintenance_episodes, id, episode)
       }}
    else
      _ -> {:error, :invalid_maintenance_episode_transition}
    end
  end

  defp valid_maintenance_ending_clock?(state, terminal, observed) when is_integer(observed) do
    episode = Map.fetch!(state.maintenance_episodes, state.active_maintenance)
    deadline = Map.get(state.deadlines, episode["run_id"])

    case terminal do
      %{
        "outcome" => "failed",
        "failure" => %{"cause" => "compaction_preparation_deadline"}
      } ->
        episode["stage"] == "source_preparation" and episode["attempts"] == 0 and
          observed >= episode["preparation_deadline"] and
          (is_nil(deadline) or deadline > episode["preparation_deadline"])

      %{
        "outcome" => "failed",
        "failure" => %{"cause" => "compaction_no_progress"}
      } ->
        episode["stage"] == "checkpoint_pending" and
          observed >= episode["request_staged_at"] and is_integer(deadline) and
          observed < deadline

      %{
        "outcome" => "failed",
        "failure" => %{"cause" => "compaction_excerpt_budget_too_small"}
      } ->
        episode["stage"] in ["source_preparation", "checkpoint_committed"] and
          maintenance_source_clock(state, episode, observed) == :ok

      %{
        "outcome" => "failed",
        "failure" => %{"cause" => "context_projection_invalid"}
      } ->
        match?({:ok, _}, maintenance_source_episode(state, observed, fn -> :ok end))

      %{"outcome" => "failed", "failure" => %{"category" => "context_budget_exceeded"}} ->
        (episode["stage"] == "source_preparation" or
           (episode["stage"] == "checkpoint_committed" and
              observed >= state.checkpoints[episode["checkpoint_id"]]["committed_at"])) and
          maintenance_source_clock(state, episode, observed) == :ok

      %{"outcome" => "bound_reached", "bound" => "deadline"} ->
        is_integer(deadline) and deadline <= episode["preparation_deadline"] and
          observed >= deadline and terminal["observed"] == observed and
          terminal["declared_limit"] == deadline

      _ ->
        false
    end
  end

  defp valid_maintenance_ending_clock?(_state, terminal, nil),
    do:
      get_in(terminal, ["failure", "cause"]) not in [
        "compaction_preparation_deadline",
        "compaction_no_progress",
        "context_projection_invalid"
      ]

  # Concept: a recovered artifact job must name the original committed source.
  # Technical depth: recompute resolution from frozen request definitions and
  # preceding receipts; a self-consistent job digest cannot substitute a use,
  # range or source identity. Other generations retain their existing readers.
  defp artifact_job_matches?(
         state,
         work,
         %{generation: {"loopex.read", "1.1.0", _digest}} = call,
         job
       ) do
    definition =
      Enum.find(work.request.tools, &(ToolDefinition.generation(&1) == call.generation))

    with %{} <- definition,
         true <- job.tool_id == "loopex.read" and job.tool_version == "1.1.0",
         {:ok, expected} <-
           Loopex.Runtime.ArtifactRead.resolve(definition, call.arguments, state.artifact_sources) do
      job.validated_arguments == expected
    else
      _invalid -> false
    end
  end

  defp artifact_job_matches?(_state, _work, _call, _job), do: true

  # Concept: recovered output policy belongs to the original session and turn.
  # Technical depth: recompute from retained definitions and lineage rather than
  # accepting a self-consistent substituted job digest. Every current projection
  # generation requires the captured context, including reads.
  defp projection_job_matches?(work, %{generation: {id, version, _digest}} = call, job) do
    if is_map(job.artifact_policy) and Map.has_key?(job.artifact_policy, "projection") do
      with {:ok, binding} <-
             Loopex.Runtime.ArtifactReadCapabilities.resolve(work.request.tools) do
        expected =
          Loopex.Executor.JobRequest.artifact_policy(
            id,
            version,
            binding,
            Conversation.normalized_call_id(work.run_id, work.turn_number, call.tool_call_id)
          )

        job.tool_id == id and job.tool_version == version and job.artifact_policy == expected
      else
        _invalid -> false
      end
    else
      not Loopex.Executor.JobRequest.projection_generation?(id, version)
    end
  end

  defp projection_job_matches?(_work, _call, _job), do: false

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

  # Concept: a run ending cannot orphan its active maintenance episode.
  # Technical depth: ADR 0043 requires the episode terminal first in the same
  # transaction. Until it clears the active marker, both proposal and replay
  # refuse an ordinary run terminal, including abort and deadline endings.
  defp apply_internal_record(
         %{active_maintenance: episode, maintenance_terminal: nil},
         %{kind: "run_terminal_committed"}
       )
       when is_binary(episode),
       do: {:error, :invalid_maintenance_episode_transition}

  defp apply_internal_record(state, %{kind: kind} = record)
       when kind in [
              "compaction_checkpoint_committed_v1",
              "standalone_compaction_checkpoint_committed_v1"
            ] do
    with {:ok, candidate} <-
           preflight_maintenance_checkpoint(state, record["committed_at"], fn -> :ok end),
         expected = maintenance_checkpoint_record(state, candidate, record["committed_at"]),
         true <- record == expected,
         false <- Map.has_key?(state.checkpoints, candidate.checkpoint_id),
         episode = state.maintenance_episodes[state.active_maintenance],
         {:ok, units} <- compaction_units(state, maintenance_scope(episode)),
         {:ok, _} <- Store.admit_bounded(record) do
      covered =
        units
        |> Enum.take(candidate.consumed_range["unit_count"])
        |> Enum.flat_map(& &1.elements)
        |> Enum.map(&Conversation.source_reference/1)
        |> MapSet.new()

      episode =
        state.maintenance_episodes[state.active_maintenance]
        |> Map.put("checkpoint_id", candidate.checkpoint_id)
        |> Map.put("stage", "checkpoint_committed")

      next = %{
        state
        | checkpoints: Map.put(state.checkpoints, candidate.checkpoint_id, record),
          active_checkpoint: candidate.checkpoint_id,
          compacted_sources: MapSet.union(state.compacted_sources, covered),
          maintenance_episodes:
            Map.put(state.maintenance_episodes, state.active_maintenance, episode)
      }

      event =
        checkpoint_public_payload(record)
        |> Map.put(:kind, "context.compacted")
        |> Map.put(
          :event_id,
          stable_id("event-compacted", state.session_id, candidate.checkpoint_id)
        )

      with {:ok, _} <- Store.admit_bounded(event),
           {:ok, _} <-
             LoopexProtocol.Session.Checkpoint.encode_wire(
               Map.drop(event, [:kind, :event_id, :event_sequence])
             ) do
        {:ok, next, [event]}
      else
        _ -> {:error, :invalid_compaction_checkpoint_transition}
      end
    else
      _ -> {:error, :invalid_compaction_checkpoint_transition}
    end
  end

  defp apply_internal_record(
         %{pending_compact: nil} = state,
         %{
           :kind => "maintenance_episode_terminal_v1",
           "result" => %{"disposition" => "checkpointed"}
         } = record
       ) do
    with {:ok, expected} <-
           maintenance_checkpoint_completion_record(state, record["observed_at"], fn -> :ok end),
         true <- record == expected,
         {:ok, _} <- Store.admit_bounded(record) do
      id = state.active_maintenance

      episode =
        state.maintenance_episodes[id]
        |> Map.put("stage", "settled")
        |> Map.put("result", record["result"])

      {:ok,
       %{
         state
         | active_maintenance: nil,
           maintenance_episodes: Map.put(state.maintenance_episodes, id, episode)
       }, []}
    else
      _ -> {:error, :invalid_maintenance_episode_transition}
    end
  end

  defp apply_internal_record(state, %{kind: "maintenance_episode_terminal_v1"} = record) do
    with true <- closed_history_map?(record, [:kind, "episode_id", "observed_at", "result"]),
         true <- is_binary(state.active_maintenance),
         true <- record["episode_id"] == state.active_maintenance,
         nil <- state.maintenance_terminal,
         %{} = result <- record["result"],
         true <-
           closed_history_map?(result, ~w(disposition checkpoint_id failure usage cleanup)),
         true <-
           result["disposition"] == "failed" or
             (result["disposition"] == "checkpointed" and is_map(state.pending_compact)),
         true <-
           is_nil(record["observed_at"]) or
             (is_integer(record["observed_at"]) and record["observed_at"] >= 0 and
                record["observed_at"] <= 18_446_744_073_709_551_615),
         {:ok, _} <- Store.admit_bounded(record) do
      marker = %{
        episode_id: record["episode_id"],
        result: result,
        observed_at: record["observed_at"],
        next:
          case state.maintenance_episodes[state.active_maintenance] do
            %{"command_id" => _, "stage" => "model_attempt_open"} -> :compact_settlement
            %{"command_id" => _} -> :compact_terminal
            _ -> :ending
          end
      }

      {:ok, %{state | maintenance_terminal: marker}, []}
    else
      _ -> {:error, :invalid_maintenance_episode_transition}
    end
  end

  # Concept: a replayed episode is the same frozen admission, not a new one.
  # Technical depth: rebuild every derived identity, cutoff, bound and zero
  # counter against the preceding durable run. Recomputing only the capture's
  # digest would allow a consistently rehashed substitution of its parent limits.
  defp apply_internal_record(state, %{kind: "maintenance_episode_admitted_v1"} = record) do
    with true <-
           closed_history_map?(record, [
             :kind,
             "episode_id",
             "run_id",
             "staging_turn_id",
             "trigger",
             "targets",
             "origin",
             "configuration_version",
             "maintenance_configuration",
             "bounds",
             "admitted_at",
             "preparation_deadline",
             "attempts",
             "summary_ordinal",
             "checkpoint_id",
             "usage"
           ]),
         run_id = record["run_id"],
         {:ok, work, parent} <- maintenance_admission_context(state, run_id),
         identity = stable_id("maintenance", run_id, next_turn_number(work)),
         true <- is_nil(state.active_maintenance),
         false <- Map.has_key?(state.maintenance_episodes, identity),
         :ok <- maintenance_clock(state, run_id, record["admitted_at"]),
         :ok <-
           MaintenanceConfiguration.validate_capture(record["maintenance_configuration"], parent),
         true <-
           record["episode_id"] == identity and
             record["staging_turn_id"] == stable_id("turn", run_id, next_turn_number(work)) and
             record["configuration_version"] == parent["configuration_version"] and
             record["bounds"] == maintenance_bounds(state, run_id) and
             record["trigger"] in ["ordinary_limit", "thinking_headroom"] and
             record["targets"] == request_headroom_targets(state, run_id) and
             (record["trigger"] != "thinking_headroom" or is_map(record["targets"])) and
             record["origin"] == "automatic" and
             record["preparation_deadline"] == record["admitted_at"] + 60_000 and
             record["attempts"] == 0 and record["summary_ordinal"] == 1 and
             is_nil(record["checkpoint_id"]) and
             record["usage"] == %{
               "attempts" => 0,
               "reported_tokens" => 0,
               "estimated_tokens" => 0,
               "total_tokens" => 0
             } do
      episode =
        record
        |> Map.put("stage", "source_preparation")
        |> Map.put("ordinary_steer", pending_steer(state, run_id))

      {:ok,
       %{
         state
         | active_maintenance: identity,
           maintenance_episodes: Map.put(state.maintenance_episodes, identity, episode)
       }, []}
    else
      _ -> {:error, :invalid_maintenance_episode_transition}
    end
  end

  # Concept: replay reconstructs the same command-owned admission.
  # Technical depth: reproduce the accepted bounds, absolute cutoff, current
  # configuration, trigger and original rendering offender from the preceding
  # journal. Captured settings validate against that parent; current host options
  # never participate. The journal stamp supplies the captured session version.
  defp apply_internal_record(
         state,
         %{kind: "standalone_maintenance_episode_admitted_v1"} = record
       ) do
    with false <- Map.has_key?(state.maintenance_episodes, record["episode_id"]),
         %{"selection" => selection, "instructions" => instructions} <-
           record["maintenance_configuration"],
         {:ok, expected} <-
           standalone_maintenance_episode_record(
             state,
             selection,
             instructions,
             record["admitted_at"],
             fn -> :ok end
           ),
         true <- expected == record do
      episode = Map.put(record, "stage", "source_preparation")

      {:ok,
       %{
         state
         | active_maintenance: record["episode_id"],
           maintenance_episodes:
             Map.put(state.maintenance_episodes, record["episode_id"], episode)
       }, []}
    else
      _ -> {:error, :invalid_maintenance_episode_transition}
    end
  end

  # Concept: a completed command releases its slot only with retained evidence.
  # Technical depth: regenerate the closed completion row before installing its
  # result beside the original admission binding. The derived public event is
  # part of the same proposal; private replay refuses duplicate completions,
  # substituted results or identities, and unchanged over nonempty raw history.
  defp apply_internal_record(state, %{kind: "compact_command_completed_v1"} = record) do
    with {:ok, expected} <- compact_completion_record(state, record),
         true <- expected == record,
         command_id = record["command_id"],
         %{} = binding <- state.commands[command_id],
         false <- Map.has_key?(binding, :result),
         {:ok, _} <-
           LoopexProtocol.Session.CompactResult.encode_completion(
             Map.take(record, ~w(episode_id command_id result))
           ),
         {:ok, state} <- complete_standalone_episode(state, record) do
      completed = Map.take(record, ~w(episode_id command_id result))

      event =
        Map.merge(completed, %{
          kind: "context.compaction_finished",
          event_id: stable_id("event-compact-finished", state.session_id, command_id)
        })

      next = %{
        state
        | pending_compact: nil,
          commands:
            Map.put(state.commands, command_id, Map.put(binding, :result, record["result"]))
      }

      {:ok, next, [event]}
    else
      _ -> {:error, :invalid_compact_completion_transition}
    end
  end

  # Concept: the request row alone stages nothing observable.
  #
  # Technical depth: ADR 0018 makes the consecutive attempt-open row the
  # dispatch authority, so applying the request alone must expose no staged
  # request, attempt, stream domain, conversation, accounting, queue effect, or
  # public start. The decoded bytes are held under `:staged` until that row
  # arrives, which is why a page boundary between the two is legal and a
  # recovery that stops between them dispatches nothing.
  defp apply_internal_record(state, %{kind: "maintenance_request_committed_v1"} = record) do
    with episode when is_map(episode) <- state.maintenance_episodes[state.active_maintenance],
         true <- record["episode_id"] == state.active_maintenance,
         {:ok, expected} <-
           preflight_maintenance_request(
             state,
             record["eligible_unit_count"],
             record["staged_at"],
             fn -> :ok end
           ),
         true <- expected == record,
         {:ok, request} <- decode_request(record["request"]) do
      episode =
        episode
        |> Map.put("stage", "request_pending_attempt_open")
        |> Map.put("staged", %{request: request, record: record})

      {:ok, put_in(state.maintenance_episodes[state.active_maintenance], episode), []}
    else
      _ -> {:error, :invalid_maintenance_request_transition}
    end
  end

  defp apply_internal_record(state, %{kind: "maintenance_attempt_opened_v1"} = record) do
    case state.maintenance_episodes[state.active_maintenance] do
      %{"stage" => "model_retry_permitted"} = episode ->
        open_maintenance_retry(state, episode, record)

      _ ->
        open_first_maintenance_attempt(state, record)
    end
  end

  defp apply_internal_record(state, %{kind: "maintenance_termination_admitted_v1"} = record) do
    with :ok <- ProviderAttempt.validate_termination(record),
         %{"stage" => "model_attempt_open", "model_termination" => nil} = episode <-
           state.maintenance_episodes[state.active_maintenance],
         true <- not maintenance_abort?(state, episode),
         true <-
           Map.take(record, Map.keys(maintenance_attempt_identity(episode))) ==
             maintenance_attempt_identity(episode),
         true <- record["deadline"] == episode["request"].deadline do
      {:ok,
       put_in(
         state.maintenance_episodes[state.active_maintenance]["model_termination"],
         "deadline"
       ), []}
    else
      _ -> {:error, :invalid_maintenance_termination_transition}
    end
  end

  defp apply_internal_record(state, %{kind: "maintenance_attempt_settled_v3"} = record) do
    with %{"stage" => "model_attempt_open"} = episode <-
           state.maintenance_episodes[state.active_maintenance],
         :ok <- ProviderAttempt.validate_settled(record, episode["request"], false),
         true <-
           Map.take(record, Map.keys(maintenance_attempt_identity(episode))) ==
             maintenance_attempt_identity(episode),
         true <-
           record["termination"] ==
             maintenance_attempt_termination(
               state,
               episode,
               if(record["termination"] == "owner_loss", do: :owner_loss, else: nil)
             ) do
      cond do
        record["next"] == "retry" ->
          {next, episode} = charge_maintenance_settlement(state, episode, record)

          episode =
            episode |> Map.put("stage", "model_retry_permitted") |> Map.put("next_attempt", 2)

          {:ok, put_in(next.maintenance_episodes[state.active_maintenance], episode), []}

        maintenance_failed_settlement?(record) ->
          episode =
            episode
            |> Map.put("stage", "settlement_pending_terminal")
            |> Map.put("settlement", record)

          {:ok, put_in(state.maintenance_episodes[state.active_maintenance], episode), []}

        true ->
          {next, episode} = charge_maintenance_settlement(state, episode, record)
          episode = Map.put(episode, "stage", "checkpoint_pending")

          episode =
            case maintenance_summary(record) do
              {:ok, summary} -> Map.put(episode, "summary", summary)
              {:error, cause} -> Map.put(episode, "summary_failure", Atom.to_string(cause))
            end

          {:ok, put_in(next.maintenance_episodes[state.active_maintenance], episode), []}
      end
    else
      _ -> {:error, :invalid_maintenance_settlement_transition}
    end
  end

  defp apply_internal_record(
         state,
         %{
           "run_id" => run_id,
           "turn_id" => turn_id,
           "operation_id" => operation_id,
           "staged_request_digest" => staged_request_digest,
           "request" => request,
           "applied_steer" => applied_steer,
           kind: "model_request_committed_v2"
         } = record
       ) do
    with true <- is_nil(state.active_maintenance),
         true <- preparation_ready?(state, run_id),
         true <- is_nil(Map.get(state.run_resources, run_id)),
         {:ok, request} <- decode_request(request),
         %{stage: stage} = work when stage in ["model_pending", "turn_settled"] <-
           Map.get(state.pending_work, run_id),
         :ok <- Loopex.Model.validate_request(request),
         :ok <- validate_request_configuration(state, record, request, run_id),
         {:ok, continuation} <-
           model_continuation(
             state,
             run_id,
             request.messages,
             applied_steer,
             record["lineage_projection"]
           ),
         true <- request.continuation == continuation,
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
            context_receipt: record["context_receipt"],
            lineage_projection: record["lineage_projection"],
            applied_steer: applied_steer
          }
        })

      next = put_pending(state, run_id, next_work)
      {:ok, next, []}
    else
      _other -> {:error, :invalid_model_request_transition}
    end
  end

  defp apply_internal_record(
         state,
         %{
           "run_id" => run_id,
           "turn_id" => turn_id,
           "operation_id" => operation_id,
           "staged_request_digest" => staged_request_digest,
           "request" => request,
           "applied_steer" => applied_steer,
           kind: "model_request_committed_resources_v2"
         } = record
       ) do
    with true <- is_nil(state.active_maintenance),
         true <- preparation_ready?(state, run_id),
         true <- not is_nil(Map.get(state.run_resources, run_id)),
         true <-
           map_size(record) == if(Map.has_key?(record, "lineage_projection"), do: 10, else: 9),
         {:ok, request} <- decode_request(request),
         %{stage: stage} = work when stage in ["model_pending", "turn_settled"] <-
           Map.get(state.pending_work, run_id),
         :ok <- Loopex.Model.validate_request(request),
         :ok <- validate_request_configuration(state, record, request, run_id),
         {:ok, continuation} <-
           model_continuation(
             state,
             run_id,
             request.messages,
             applied_steer,
             record["lineage_projection"]
           ),
         true <- request.continuation == continuation,
         turn_number = next_turn_number(work),
         true <- turn_id == stable_id("turn", run_id, turn_number),
         true <- operation_id == model_operation_id(run_id, turn_number),
         true <- staged_request_digest == request.staged_request_digest,
         :ok <- validate_resource_context_receipt(state, record, request, run_id, applied_steer) do
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
            context_receipt: record["context_receipt"],
            lineage_projection: record["lineage_projection"],
            applied_steer: applied_steer
          }
        })

      next = put_pending(state, run_id, next_work)
      {:ok, next, []}
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
         true <- record["deadline"] == retained_run_deadline(state, run_id),
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
  defp apply_internal_record(state, %{kind: kind} = record)
       when kind in [
              "model_attempt_settled_v3"
            ] do
    with :ok <- ProviderAttempt.validate_settled(record),
         run_id = record["run_id"],
         %{stage: "model_attempt_open", request: request} = work <-
           Map.get(state.pending_work, run_id),
         true <- attempt_identity_matches?(record, run_id, work, request),
         :ok <- settlement_request_agrees?(state, record, run_id, request),
         true <- settlement_termination_agrees?(state, run_id, work, record) do
      apply_attempt_settlement(
        state,
        run_id,
        work,
        record
      )
    else
      {:error, reason} -> {:error, reason}
      _other -> {:error, :invalid_model_attempt_settlement_transition}
    end
  end

  defp apply_internal_record(
         state,
         %{
           "run_id" => run_id,
           "job" => job,
           "grant" => grant,
           kind: kind
         } = record
       )
       when kind == "effect_intent_committed_v2" do
    with true <-
           closed_history_map?(record, [:kind, "run_id", "job", "grant"]),
         true <- is_nil(state.open_interaction),
         {:ok, job} <- decode_job(job),
         {:ok, grant} <- decode_grant(grant),
         %{stage: "effect_pending", pending_calls: [call | _rest], turn_id: turn_id} = work <-
           Map.get(state.pending_work, run_id),
         :ok <- Loopex.Executor.validate_job(job),
         true <- job.run_id == run_id and job.turn_id == turn_id,
         true <- job.tool_call_id == call.tool_call_id,
         true <- artifact_job_matches?(state, work, call, job),
         true <- projection_job_matches?(work, call, job),
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

  defp apply_internal_record(
         state,
         %{
           "run_id" => run_id,
           "receipt" => receipt,
           kind: kind
         } = record
       )
       when kind == "executor_receipt_committed_v2" do
    with true <-
           closed_history_map?(record, [:kind, "run_id", "receipt"], ["reconciliation_query_id"]),
         {:ok, receipt} <- decode_receipt(receipt),
         %{stage: "effect_dispatched", job: job, tool_call: call} = work <-
           Map.get(state.pending_work, run_id),
         :ok <- receipt_matches_job(receipt, job),
         outcome = conversation_outcome(receipt.outcome),
         true <- outcome in Conversation.outcomes(),
         true <- Conversation.admits_result?(elements(state, run_id), run_id, call.tool_call_id),
         {:ok, normalized, source_bytes} <- Store.normalize_and_measure_item(:record, record) do
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
        |> retain_tool_result_source(result, normalized, source_bytes, job)
        |> Map.update!(:artifact_sources, fn sources ->
          Loopex.Runtime.ArtifactRead.retain(
            sources,
            receipt.artifacts,
            record,
            state.journal_version + 1,
            job
          )
        end)

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

  defp apply_internal_record(state, %{kind: "tool_result_preparation_state_v1"} = record) do
    run_id = record["run_id"]

    with {:ok, identity} <- preparation_identity(state, run_id),
         :ok <- preflight_run_history(state, run_id),
         {:ok, [source | _]} <- preparation_sources(state, run_id),
         {:ok, episode} <-
           ArtifactPreparation.replay_reservation(
             state.artifact_preparations[identity["episode_id"]],
             record,
             identity,
             source,
             retained_run_deadline(state, run_id)
           ) do
      {:ok,
       %{
         state
         | artifact_preparations:
             Map.put(state.artifact_preparations, identity["episode_id"], episode)
       }, []}
    else
      _ -> {:error, :invalid_artifact_preparation_transition}
    end
  end

  defp apply_internal_record(state, %{kind: "tool_result_reference_prepared"} = record) do
    run_id = record["run_id"]
    reference = decode_artifact_reference(record["reference"])

    with {:ok, identity} <- preparation_identity(state, run_id),
         {:ok, [source | _]} <- preparation_sources(state, run_id),
         {:ok, episode} <-
           ArtifactPreparation.replay_completion(
             state.artifact_preparations[identity["episode_id"]],
             record,
             source,
             reference
           ) do
      job = %{
        run_id: source.metadata["run_id"],
        operation_id: source.metadata["operation_id"],
        attempt: source.metadata["attempt"],
        tool_call_id: source.metadata["tool_call_id"]
      }

      {:ok,
       %{
         state
         | artifact_preparations:
             Map.put(state.artifact_preparations, identity["episode_id"], episode),
           prepared_tool_results:
             Map.put(state.prepared_tool_results, source.source_reference, reference),
           artifact_sources:
             Loopex.Runtime.ArtifactRead.retain(
               state.artifact_sources,
               [reference],
               record,
               state.journal_version + 1,
               job
             )
       }, []}
    else
      _ -> {:error, :invalid_artifact_preparation_transition}
    end
  end

  defp apply_internal_record(state, %{kind: "tool_result_preparation_failed_v1"} = record) do
    run_id = record["run_id"]

    with {:ok, identity} <- preparation_identity(state, run_id),
         {:ok, [source | _]} <- preparation_sources(state, run_id),
         {:ok, episode} <-
           ArtifactPreparation.replay_failure(
             state.artifact_preparations[identity["episode_id"]],
             record,
             identity,
             source
           ) do
      {:ok,
       %{
         state
         | artifact_preparations:
             Map.put(
               state.artifact_preparations,
               identity["episode_id"],
               episode
             )
       }, []}
    else
      _ -> {:error, :invalid_artifact_preparation_transition}
    end
  end

  defp apply_internal_record(state, %{kind: kind} = record)
       when kind == "tool_result_committed_v2" do
    case open_interaction_record(state) do
      %{producer: "model_tool", tool_call_id: id} ->
        if id == record["tool_call_id"],
          do: {:error, :invalid_tool_result_transition},
          else: apply_tool_result_record(state, record)

      _ ->
        apply_tool_result_record(state, record)
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
  defp apply_internal_record(state, %{kind: "context_admission_refused_v2"} = refusal) do
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
    with {:ok, state} <- complete_pending_maintenance_settlement(state, record),
         {:ok, state, work, settled_events} <- complete_pending_terminal(state, run_id, record),
         %{stage: stage} <- work,
         true <-
           outcome in ["completed", "bound_reached", "outcome_unknown", "cancelled", "failed"],
         true <- terminal_admitted?(state, run_id, stage, outcome, bound),
         true <- is_nil(reason) or is_binary(reason),
         {:ok, state, failure} <- consume_context_refusal(state, run_id, outcome, record),
         {:ok, state} <- complete_maintenance_terminal(state, record) do
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
      state = complete_terminal_conversation(state, run_id, work, outcome, reconciliation_ref)
      {state, steer_events} = resolve_steer(state, run_id, unapplied_reason(outcome, bound))
      {state, interaction_events} = cancel_open_interaction(state, run_id)
      {state, promotion_events} = promote_follow_up(state, run_id)

      {:ok, %{state | aborting: nil},
       settled_events ++
         [event] ++
         steer_events ++
         interaction_events ++
         promotion_events ++ session_settled(state, run_id, promotion_events)}
    else
      _other -> {:error, :invalid_run_terminal_transition}
    end
  end

  defp apply_internal_record(
         state,
         %{
           "run_id" => run_id,
           "reconciliation_ref" => reconciliation_ref,
           kind: kind
         } = record
       )
       when kind == "outcome_unknown_committed_v2" do
    with true <-
           closed_history_map?(record, [:kind, "run_id", "reconciliation_ref"]),
         %{stage: "effect_dispatched", job: job} = work <- Map.get(state.pending_work, run_id),
         true <- is_binary(reconciliation_ref) and byte_size(reconciliation_ref) > 0 do
      events = [
        tool_finished_event(
          state.session_id,
          job,
          "outcome_unknown",
          []
        ),
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
      state =
        complete_terminal_conversation(state, run_id, work, "outcome_unknown", reconciliation_ref)

      {state, steer_events} = resolve_steer(state, run_id, "run_terminal")
      {state, interaction_events} = cancel_open_interaction(state, run_id)
      {state, promotion_events} = promote_follow_up(state, run_id)

      {:ok, state,
       events ++
         steer_events ++
         interaction_events ++
         promotion_events ++ session_settled(state, run_id, promotion_events)}
    else
      _other -> {:error, :invalid_outcome_unknown_transition}
    end
  end

  # Concept: the host asked a bounded question instead of deciding, and the
  # session retains it before anyone can be told it was asked.
  #
  # Technical depth: accepted ADR 0024 gives the serial owner at most one open
  # interaction, so a request arriving while another is open is invalid history
  # rather than a second question. The round this creation carries is the count
  # of answer-then-defer transitions already spent on this tool decision, and a
  # fourth question is refused here: the ceiling lives in the reducer because it
  # must survive restart and replay rather than in whichever process happened to
  # ask.
  defp apply_internal_record(state, %{kind: "interaction_requested_v1"} = record) do
    with {:ok, interaction_id} <- record_binary(record, "interaction_id"),
         {:ok, run_id} <- record_binary(record, "run_id"),
         {:ok, tool_call_id} <- record_binary(record, "tool_call_id"),
         true <- run_id == state.active_run_id,
         true <- not model_question_call?(state, run_id, tool_call_id),
         false <- Map.has_key?(state.interactions, interaction_id),
         {:ok, request} <- interaction_request(record),
         {:ok, round} <- interaction_round(record),
         true <- round <= 2,
         {:ok, expires_at} <- record_integer(record, "expires_at"),
         {:ok, turn} <- record_integer(record, "turn"),
         true <- turn > 0,
         true <- creatable_round?(state, run_id, turn, tool_call_id, round) do
      # Concept: a repeated defer withdraws the answered question, not the tool decision.
      # Technical depth: derive the old neutral terminal and new pending fact
      # from this one creation row, only after its complete tuple is validated.
      {state, closed_events} = cancel_open_interaction(state, run_id)

      interaction = %{
        interaction_id: interaction_id,
        run_id: run_id,
        turn: turn,
        tool_call_id: tool_call_id,
        request: request,
        status: "pending",
        round: round,
        expires_at: expires_at,
        choice_id: nil,
        policy_identity: Map.get(record, "policy_identity")
      }

      {:ok,
       %{
         state
         | interactions: Map.put(state.interactions, interaction_id, interaction),
           open_interaction: interaction_id
       }, closed_events ++ [interaction_requested_event(state.session_id, interaction)]}
    else
      _other -> {:error, :invalid_interaction_transition}
    end
  end

  # Concept: every open question ends exactly once, and the way it ended is
  # public.
  #
  # Technical depth: an expiry, an abort and a policy result are ordinary
  # competing transitions ordered at the journal, and the first committed one
  # wins; a later one finds no open interaction and is invalid history rather
  # than a reopening. `allowed` is the only resolution a grant may follow, and
  # it is recorded here as the sibling decision rather than inferred from the
  # answer.
  defp apply_internal_record(state, %{kind: "interaction_resolved_v1"} = record) do
    with {:ok, interaction_id} <- record_binary(record, "interaction_id"),
         {:ok, resolution} <- interaction_resolution(record),
         %{} = interaction <- Map.get(state.interactions, interaction_id),
         true <- Map.get(interaction, :producer) != "model_tool",
         true <- interaction.status in ["pending", "answered"],
         true <- state.open_interaction == interaction_id,
         true <- resolvable?(interaction, resolution) do
      # Concept: a closed refusal still owes the suspended call its terminal fact.
      # Technical depth: reconstruct the owning record's optional reason for a
      # successor between interaction closure and tool-result commitment.
      resolved =
        interaction
        |> Map.put(:status, resolution_status(resolution))
        |> Map.put(:resolution_reason, Map.get(record, "reason"))

      {:ok,
       %{
         state
         | interactions: Map.put(state.interactions, interaction_id, resolved),
           open_interaction: nil
       }, [interaction_resolved_event(state.session_id, resolved, resolution, record)]}
    else
      _other -> {:error, :invalid_interaction_transition}
    end
  end

  defp apply_internal_record(state, %{kind: "model_question_requested_v1"} = record) do
    run_id = record["run_id"]

    with true <- map_size(record) == 11 and record["producer"] == "model_tool",
         true <- run_id == state.active_run_id and is_nil(state.open_interaction),
         %{stage: "effect_pending", pending_calls: [call | _]} = work <-
           state.pending_work[run_id],
         true <-
           call.generation == ToolDefinition.generation(ToolDefinition.question_definition()),
         true <-
           record["tool_call_id"] == call.tool_call_id and record["turn"] == work.turn_number,
         true <- record["interaction_id"] == model_question_id(state, work, call),
         false <- Map.has_key?(state.interactions, record["interaction_id"]),
         {:ok, request} <- Interaction.model_request(call.arguments),
         true <- record["argument_digest"] == Interaction.digest(call.arguments),
         true <- record["interaction_request"] == Interaction.to_record(request),
         true <- record["interaction_request_digest"] == Interaction.digest(request),
         created when is_integer(created) and created >= 0 and created <= @uint64_max <-
           record["created_at"],
         true <- record["expires_at"] > created and record["expires_at"] <= @uint64_max,
         true <-
           record["expires_at"] ==
             Interaction.effective_expiry(created, 600_000, retained_run_deadline(state, run_id)) do
      interaction = %{
        producer: "model_tool",
        interaction_id: record["interaction_id"],
        run_id: run_id,
        turn: work.turn_number,
        tool_call_id: call.tool_call_id,
        request: request,
        status: "pending",
        round: 0,
        created_at: created,
        expires_at: record["expires_at"],
        choice_id: nil,
        command_id: nil,
        policy_identity: nil,
        answer: nil,
        disposition: nil,
        settlement_sequence: nil,
        argument_digest: record["argument_digest"]
      }

      {:ok,
       %{
         state
         | interactions: Map.put(state.interactions, interaction.interaction_id, interaction),
           open_interaction: interaction.interaction_id
       }, [model_question_event(state.session_id, interaction, "interaction.requested")]}
    else
      _ -> {:error, :invalid_model_question_transition}
    end
  end

  defp apply_internal_record(state, %{kind: "model_question_settled_v2"} = record) do
    if map_size(record) == 5 and record["disposition"] == "expired" and is_nil(record["answer"]),
      do: settle_model_question(state, record),
      else: {:error, :invalid_model_question_transition}
  end

  defp apply_internal_record(_state, _record), do: {:error, :invalid_internal_transition}

  defp apply_tool_result_record(
         state,
         %{
           "run_id" => run_id,
           "tool_call_id" => tool_call_id,
           "outcome" => outcome,
           "reason" => reason,
           kind: kind
         } = record
       )
       when kind == "tool_result_committed_v2" do
    with true <-
           closed_history_map?(record, [:kind, "run_id", "tool_call_id", "outcome", "reason"]),
         %{stage: "effect_" <> _phase, pending_calls: [call | _rest]} = work <-
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
          event_id:
            tool_event_id(
              "event-tool-finished",
              state.session_id,
              run_id,
              Map.get(work, :turn_id),
              tool_call_id
            ),
          kind: "tool.finished"
        }

      {:ok, next, [event]}
    else
      _other -> {:error, :invalid_tool_result_transition}
    end
  end

  defp model_question_id(state, work, call),
    do:
      stable_id(
        "model-question",
        state.session_id,
        {work.run_id, work.turn_number, call.tool_call_id}
      )

  defp model_question_call?(state, run_id, id) do
    case state.pending_work[run_id] do
      %{pending_calls: [call | _]} ->
        call.tool_call_id == id and
          call.generation == ToolDefinition.generation(ToolDefinition.question_definition())

      _ ->
        false
    end
  end

  defp model_question_command_binding(record) do
    with {:ok, response} <- normalize_interaction_answer(%{answer: record["answer"]}),
         command <-
           Map.merge(
             %{
               type: :interaction_answer,
               command_id: record["command_id"],
               interaction_id: record["interaction_id"]
             },
             response
           ),
         {:ok, digest} <- command_digest(command),
         true <- digest == record["command_digest"] do
      :ok
    else
      _ -> {:error, :invalid_model_question_transition}
    end
  end

  # Concept: a model answer settles its question and original call together.
  # Technical depth: one row releases the slot, appends the exact answer to the
  # conversation and advances pending work. No policy resolution or executor
  # receipt is owed; command admission and its identity share this same row.
  defp settle_model_question(state, record) do
    id = record["interaction_id"]
    answer = record["answer"]
    disposition = record["disposition"]

    with %{producer: "model_tool", status: "pending"} = interaction <- state.interactions[id],
         true <- state.open_interaction == id,
         true <- question_settlement_time?(interaction, record),
         {:ok, content, outcome} <- model_question_result(interaction, disposition, answer),
         {:ok, next, events} <-
           apply_tool_result_record(state, %{
             "run_id" => interaction.run_id,
             "tool_call_id" => interaction.tool_call_id,
             "outcome" => outcome,
             "reason" => content,
             kind: "tool_result_committed_v2"
           }) do
      resolved = %{
        interaction
        | status: disposition,
          disposition: disposition,
          answer: answer,
          choice_id: if(is_map(answer), do: answer["choice_id"], else: nil),
          command_id: record["command_id"],
          settlement_sequence: state.journal_version + 1
      }

      resolved = Map.put(resolved, :command_digest, record["command_digest"])

      events =
        if outcome == "completed", do: Enum.map(events, &Map.put(&1, "reason", nil)), else: events

      {:ok,
       %{next | interactions: Map.put(next.interactions, id, resolved), open_interaction: nil},
       events ++
         [
           model_question_event(
             state.session_id,
             resolved,
             model_question_event_kind(disposition)
           )
         ]}
    else
      _ -> {:error, :invalid_model_question_transition}
    end
  end

  defp question_settlement_time?(interaction, %{"disposition" => "expired", "settled_at" => at}),
    do: is_integer(at) and at >= interaction.expires_at and at <= @uint64_max

  defp question_settlement_time?(_interaction, %{"disposition" => "cancelled"}), do: true

  defp question_settlement_time?(interaction, %{"responded_at" => at}),
    do: is_integer(at) and at >= interaction.created_at and at < interaction.expires_at

  defp question_settlement_time?(_, _), do: false

  defp model_question_result(interaction, "answered", answer) do
    case Interaction.model_answer(interaction.request, answer) do
      {:ok, %{"text" => text}} ->
        {:ok, text, "completed"}

      {:ok, %{"choice_id" => id}} ->
        choice = Enum.find(interaction.request.choices, &(&1.id == id))
        {:ok, choice.label, "completed"}

      _ ->
        :error
    end
  end

  defp model_question_result(_interaction, "declined", %{"disposition" => "declined"}),
    do: {:ok, "question_declined", "denied"}

  defp model_question_result(_interaction, "expired", nil),
    do: {:ok, "question_expired", "denied"}

  defp model_question_result(_interaction, "cancelled", nil), do: {:ok, nil, "cancelled"}

  defp model_question_result(_, _, _), do: :error

  defp model_question_event_kind("answered"), do: "interaction.answered"
  defp model_question_event_kind("declined"), do: "interaction.declined"
  defp model_question_event_kind("expired"), do: "interaction.expired"
  defp model_question_event_kind("cancelled"), do: "interaction.cancelled"

  defp model_question_event(session_id, interaction, kind) do
    Interaction.view(interaction)
    |> Map.delete("kind")
    |> Map.put("interaction_kind", Atom.to_string(interaction.request.kind))
    |> Map.put(:kind, kind)
    |> Map.put(
      :event_id,
      stable_id("model-question-event", session_id, {interaction.interaction_id, kind})
    )
  end

  # Concept: the owning transition closes its open question.
  #
  # Technical depth: a validated policy replacement uses the same neutral
  # cancellation as an ending. Every ending reaches here so no path leaves a
  # question standing
  # against a run that is over. Leaving one would be worse than cosmetic: the
  # session would refuse every later question, because the serial owner may hold
  # only one open, and an operator would be shown a question nobody can answer.
  defp cancel_open_interaction(state, run_id) do
    case open_interaction_record(state) do
      %{producer: "model_tool", run_id: ^run_id, interaction_id: interaction_id} = interaction ->
        cancelled = %{
          interaction
          | status: "cancelled",
            disposition: "cancelled",
            settlement_sequence: state.journal_version + 1
        }

        {%{
           state
           | interactions: Map.put(state.interactions, interaction_id, cancelled),
             open_interaction: nil
         }, [model_question_event(state.session_id, cancelled, "interaction.cancelled")]}

      %{run_id: ^run_id, interaction_id: interaction_id} = interaction ->
        cancelled = %{interaction | status: "cancelled"}

        {%{
           state
           | interactions: Map.put(state.interactions, interaction_id, cancelled),
             open_interaction: nil
         }, [interaction_resolved_event(state.session_id, cancelled, "cancelled", %{})]}

      _none ->
        {state, []}
    end
  end

  # Concept: a new question is admitted when none is open, or when the open one
  # has been answered and the host asked again about the same decision.
  #
  # Technical depth: accepted ADR 0024 fixes initial round zero and exactly
  # one increment for the same run, turn and tool decision. Creation derives
  # cancellation before requested in one transaction, preserving the old answer.
  # A pending or unrelated question cannot be replaced.
  defp creatable_round?(%{open_interaction: nil}, _run_id, _turn, _tool_call_id, round),
    do: round == 0

  defp creatable_round?(state, run_id, turn, tool_call_id, round) do
    case Map.get(state.interactions, state.open_interaction) do
      %{
        status: "answered",
        run_id: ^run_id,
        turn: ^turn,
        tool_call_id: ^tool_call_id,
        round: previous
      } = interaction ->
        Map.get(interaction, :producer) != "model_tool" and round == previous + 1

      _other ->
        false
    end
  end

  # Concept: only an answered question can resolve as a policy verdict, and only
  # an open one can expire or be cancelled.
  defp resolvable?(%{status: "answered"}, resolution) when resolution in ["allowed", "denied"],
    do: true

  defp resolvable?(%{status: status}, resolution)
       when status in ["pending", "answered"] and resolution in ["expired", "cancelled"],
       do: true

  defp resolvable?(_interaction, _resolution), do: false

  defp resolution_status("allowed"), do: "answered"
  defp resolution_status("denied"), do: "denied"
  defp resolution_status("expired"), do: "expired"
  defp resolution_status("cancelled"), do: "cancelled"

  defp interaction_resolution(record) do
    case Map.get(record, "resolution") do
      resolution when resolution in ["allowed", "denied", "expired", "cancelled"] ->
        {:ok, resolution}

      _other ->
        {:error, :invalid_interaction_resolution}
    end
  end

  defp interaction_round(record) do
    case Map.get(record, "round") do
      round when is_integer(round) and round >= 0 -> {:ok, round}
      _other -> {:error, :invalid_interaction_round}
    end
  end

  defp record_integer(record, key) do
    case Map.get(record, key) do
      value when is_integer(value) -> {:ok, value}
      _other -> {:error, :invalid_interaction_record}
    end
  end

  # Concept: a retained question is validated again on the way in.
  #
  # Technical depth: the journal is the only place this comes back from after a
  # restart, and a row written by another version or edited by hand is not a
  # question this owner will carry. Validating it here means the shape a
  # recovered owner acts on is the shape the accepted family admits.
  defp interaction_request(record),
    do: Interaction.from_record(Map.get(record, "interaction_request"))

  defp interaction_requested_event(session_id, interaction) do
    %{
      "interaction_id" => interaction.interaction_id,
      "run_id" => interaction.run_id,
      "turn" => interaction.turn,
      "tool_call_id" => interaction.tool_call_id,
      "prompt" => interaction.request.prompt,
      "choices" => Enum.map(interaction.request.choices, &%{"id" => &1.id, "label" => &1.label}),
      "expires_at" => interaction.expires_at,
      event_id: stable_id("event-interaction-requested", session_id, interaction.interaction_id),
      kind: "interaction.requested"
    }
  end

  # Concept: how a question ended, named as its own public fact.
  #
  # Technical depth: expiry and cancellation are distinct kinds rather than a
  # field of one, because a reader that filters on kind must be able to tell an
  # unanswered question that ran out of time from one an abort closed. A
  # resolution retains the owning turn and admitted answer command, including
  # when expiry or cancellation closes an answered question. An abort or timer
  # never supplies answer provenance, and the host's private reference stays
  # outside this public fact.
  defp interaction_resolved_event(session_id, interaction, resolution, record) do
    %{
      "interaction_id" => interaction.interaction_id,
      "run_id" => interaction.run_id,
      "turn" => interaction.turn,
      "tool_call_id" => interaction.tool_call_id,
      "resolution" => resolution,
      "answer_command_id" => Map.get(interaction, :command_id),
      event_id:
        stable_id("event-interaction-" <> resolution, session_id, interaction.interaction_id),
      kind: interaction_event_kind(resolution)
    }
    |> then(
      &if(Map.get(interaction, :command_id),
        do: Map.put(&1, "choice_id", interaction.choice_id),
        else: &1
      )
    )
    |> then(fn event ->
      case Map.get(record, "reason") do
        reason when is_binary(reason) -> Map.put(event, "reason", reason)
        _absent -> event
      end
    end)
  end

  defp interaction_event_kind("expired"), do: "interaction.expired"
  defp interaction_event_kind("cancelled"), do: "interaction.cancelled"
  defp interaction_event_kind(_resolved), do: "interaction.resolved"

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

  # Concept: a summary can spend a parent bound before its first ordinary turn.
  # Technical depth: only the consecutive run-owned episode-terminal marker
  # admits this ending from model-pending or turn-settled. The completion reducer
  # then authenticates exact parent limits, call units, token charge and source.
  defp terminal_admitted?(
         %{maintenance_terminal: %{episode_id: id}} = state,
         run,
         stage,
         "bound_reached",
         bound
       )
       when stage in ["model_pending", "turn_settled"] and bound in ["max_turns", "token_budget"] do
    id == state.active_maintenance and state.maintenance_episodes[id]["run_id"] == run
  end

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

  # Concept: a terminal fact closes outstanding calls without inventing success
  # or forgetting an uncertain effect when a later prompt projects the lineage.
  # Technical depth: these elements are derived during replay from the terminal
  # and its committed dispatch identity. Only that dispatched call can receive
  # unknown; unstarted calls are cancelled. Existing committed results win.
  defp complete_terminal_conversation(state, run_id, work, outcome, reference) do
    elements = elements(state, run_id)

    case Conversation.last_assistant(elements) do
      nil ->
        state

      assistant ->
        answered =
          elements
          |> Enum.filter(&(&1.kind == :tool_result and &1.turn_number == assistant.turn_number))
          |> MapSet.new(& &1.tool_call_id)

        Enum.reduce(assistant.tool_calls, state, fn call, current ->
          if MapSet.member?(answered, call.tool_call_id) do
            current
          else
            uncertain =
              outcome == "outcome_unknown" and work.stage == "effect_dispatched" and
                Map.get(Map.get(work, :job, %{}), :tool_call_id) == call.tool_call_id

            result_outcome = if uncertain, do: :outcome_unknown, else: :cancelled

            append_element(current, run_id, %{
              kind: :tool_result,
              run_id: run_id,
              turn_number: assistant.turn_number,
              tool_call_id: call.tool_call_id,
              outcome: result_outcome,
              content: Conversation.result_content(result_outcome, reference),
              artifacts: []
            })
          end
        end)
    end
  end

  defp promote_follow_up(%{follow_up: nil} = state, run_id) do
    {%{state | active_run_id: nil, pending_work: Map.delete(state.pending_work, run_id)}, []}
  end

  defp promote_follow_up(%{follow_up: follow_up} = state, run_id) do
    promoted = command_run_id(state.session_id, follow_up.command_id)
    declared = Map.get(state.bounds, run_id) |> Map.delete(:deadline_at_ms)

    declared =
      case follow_up.authored_bounds do
        %{deadline_at_ms: ceiling} -> Map.put(declared, :deadline_at_ms, ceiling)
        _ -> declared
      end

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
          run_configurations:
            Map.put(state.run_configurations, promoted, run_configuration(state, run_id)),
          run_resources: Map.put(state.run_resources, promoted, state.resources),
          run_order: state.run_order ++ [promoted],
          conversation: Map.put(state.conversation, promoted, [element])
      }

    {next, prompt_events(state.session_id, follow_up.command_id, promoted, follow_up.content)}
  end

  defp cancel_queues(state, run_id, record) do
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

    # Concept: an abort closes the open question too, in the same transaction
    # that admits it.
    #
    # Technical depth: accepted ADR 0024 makes a cancelled run leave its
    # interaction cancelled, and doing it here means an operator never sees a
    # question standing open against a run that is being stopped. A later answer
    # then finds it resolved and refuses, which is the race resolving in the
    # order the journal fixed rather than a reopening.
    {interaction_patch, interaction_events} =
      case open_interaction_record(state) do
        %{producer: "model_tool", run_id: ^run_id, interaction_id: id} ->
          {:ok, settled, events} =
            settle_model_question(state, %{
              "interaction_id" => id,
              "disposition" => "cancelled",
              "answer" => nil,
              "command_id" => record["command_id"],
              "command_digest" => record["command_digest"],
              kind: record.kind
            })

          {%{
             interactions: settled.interactions,
             open_interaction: nil,
             conversation: settled.conversation,
             pending_work: settled.pending_work
           }, events}

        %{run_id: ^run_id, interaction_id: interaction_id} = interaction ->
          cancelled = %{interaction | status: "cancelled"}

          {%{
             interactions: Map.put(state.interactions, interaction_id, cancelled),
             open_interaction: nil
           }, [interaction_resolved_event(state.session_id, cancelled, "cancelled", %{})]}

        _none ->
          {%{}, []}
      end

    {steer_patch |> Map.merge(follow_patch) |> Map.merge(interaction_patch),
     steer_events ++ follow_events ++ interaction_events}
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

  # Concept: only a committed not-sent verdict permits a second summary attempt.
  # Technical depth: retry consumes the retained allowance, parent capacity and
  # episode attempt count while reusing the exact operation and request bytes.
  defp open_maintenance_retry(state, episode, record) do
    with :ok <- ProviderAttempt.validate_opened(record),
         true <-
           Map.delete(record, :kind) ==
             Map.put(maintenance_attempt_identity(episode), "attempt", 2),
         true <- not maintenance_abort?(state, episode) and is_nil(episode["model_termination"]),
         true <- episode["attempts"] < episode["bounds"]["max_attempts"],
         :ok <- maintenance_request_capacity(state, episode) do
      episode =
        episode
        |> Map.delete("next_attempt")
        |> Map.merge(%{
          "stage" => "model_attempt_open",
          "model_attempt" => 2,
          "attempt_owner_epoch" => state.owner_epoch,
          "attempts" => episode["attempts"] + 1
        })

      {:ok, put_in(state.maintenance_episodes[state.active_maintenance], episode), []}
    else
      _ -> {:error, :invalid_maintenance_attempt_open_transition}
    end
  end

  # Concept: a successor cannot confirm a predecessor's provider cleanup.
  # Technical depth: the derived attempt owner epoch comes from the authenticated
  # journal stamp at open, not a new payload field. Replay retains it across
  # ownership changes, including when abort/deadline wins over owner-loss ending.
  defp open_first_maintenance_attempt(state, record) do
    with :ok <- ProviderAttempt.validate_opened(record),
         %{
           "stage" => "request_pending_attempt_open",
           "staged" => %{request: request, record: staged}
         } = episode <-
           state.maintenance_episodes[state.active_maintenance],
         true <- episode["attempts"] < episode["bounds"]["max_attempts"],
         true <-
           record["attempt"] == 1 and record["purpose"] == "compaction" and
             record["episode_id"] == state.active_maintenance and
             record["summary_ordinal"] == staged["summary_ordinal"] and
             record["operation_id"] == staged["operation_id"] and
             record["staged_request_digest"] == request.staged_request_digest do
      episode =
        episode
        |> Map.drop(["staged", "summary", "summary_failure", "settlement", "next_attempt"])
        |> Map.merge(%{
          "stage" => "model_attempt_open",
          "attempts" => episode["attempts"] + 1,
          "summary_ordinal" => staged["summary_ordinal"],
          "prior_checkpoint_id" => state.active_checkpoint,
          "request" => request,
          "request_staged_at" => staged["staged_at"],
          "request_context_receipt" => staged["context_receipt"],
          "covered_range" => staged["covered_range"],
          "source_digest" => staged["source_digest"],
          "source_excerpted" => staged["source_excerpted"],
          "operation_id" => staged["operation_id"],
          "model_attempt" => 1,
          "attempt_owner_epoch" => state.owner_epoch,
          "model_termination" => nil
        })

      next = put_in(state.maintenance_episodes[state.active_maintenance], episode)

      next =
        if maintenance_scope(episode) == :session,
          do: next,
          else: %{
            next
            | deadlines: Map.put_new(next.deadlines, episode["run_id"], request.deadline)
          }

      {:ok, next, []}
    else
      _ -> {:error, :invalid_maintenance_attempt_open_transition}
    end
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
          request_context_receipt: staged.context_receipt,
          request_lineage_projection: staged.lineage_projection,
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

  # Concept: recovered replies use the configuration captured for their run.
  # Technical depth: v3 capsules bind the committed request and that run's
  # immutable continuation requirement, rather than a later session setting.
  defp settlement_request_agrees?(
         state,
         %{kind: "model_attempt_settled_v3"} = record,
         run_id,
         request
       ) do
    with :ok <-
           ProviderAttempt.validate_settled(
             record,
             request,
             continuation_required?(state, run_id)
           ) do
      case record["result"] do
        %{"kind" => "reply", "reply" => reply} ->
          Loopex.Model.Continuation.validate_reply_ids(request, reply)

        _ ->
          :ok
      end
    end
  end

  defp continuation_required?(state, run_id) do
    case run_configuration(state, run_id) do
      nil -> false
      configuration -> configuration["provider_mapping"]["continuation_required"]
    end
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
  defp complete_pending_terminal(state, run_id, terminal) do
    case Map.get(state.pending_work, run_id) do
      %{stage: "model_attempt_pending_terminal", settlement: settlement} = work ->
        with true <- terminal == attempt_terminal_record(state, run_id, settlement),
             {:ok, next, events} <-
               apply_settled_verdict(state, run_id, Map.delete(work, :settlement), settlement) do
          {:ok, next, Map.get(next.pending_work, run_id), events}
        else
          {:error, reason} -> {:error, reason}
          _other -> {:error, :invalid_model_attempt_settlement_pair}
        end

      %{} = work ->
        with :ok <- complete_attempt_pair(state), do: {:ok, state, work, []}

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
              |> put_pending(run_id, retain_continuation(next_work, record, reply))

            {:ok, next, [assistant_event(state.session_id, run_id, work.turn_id, reply["text"])]}

          :error ->
            {:error, :invalid_model_tool_call}
        end

      _no_canonical_answer ->
        next_work = Map.merge(work, %{stage: "turn_settled", pending_calls: []})
        {:ok, put_pending(state, run_id, next_work), []}
    end
  end

  # Concept: only a canonical committed open reply extends native reuse.
  # Technical depth: sources retain their complete settlement, while the first
  # request/receipt freezes the prefix. Terminal removal of pending work drops
  # reuse; closed and evidence-only replies never start a later exchange.
  defp retain_continuation(work, %{kind: "model_attempt_settled_v3"} = record, %{
         "continuation" => %{"status" => "open"}
       }) do
    exchange =
      Map.get(work, :continuation_exchange, %{
        base_request: work.request,
        base_receipt: work.request_context_receipt,
        sources: []
      })

    source = %{record: record, turn_number: work.turn_number}

    Map.put(
      work,
      :continuation_exchange,
      Map.merge(exchange, %{
        sources: exchange.sources ++ [source],
        latest_request: work.request,
        latest_receipt: work.request_context_receipt,
        latest_projection: work.request_lineage_projection
      })
    )
  end

  defp retain_continuation(work, _record, _reply), do: Map.delete(work, :continuation_exchange)

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
       }) do
    state
    |> charge_run(run_id, input + output, :reported)
    |> record_run_usage(run_id, %{reported_input: input, reported_output: output})
  end

  defp apply_attempt_accounting(state, run_id, %{"source" => "estimated"}) do
    budget = state.bounds |> Map.get(run_id, %{}) |> Map.get(:token_budget, 0)
    charged = Map.get(state.charged, run_id, %{tokens: 0, source: nil})
    charge = max(budget - charged.tokens, 0)

    state
    |> charge_run(run_id, charge, :estimated)
    |> record_run_usage(run_id, %{estimated: charge, unresolved: true})
  end

  # Concept: the same fold that charges a run keeps its usage split by source.
  # Technical depth: ADR 0069's private run evidence reads this derived split.
  # It is rebuilt by replay, never stored, and every ordinary or run-owned
  # maintenance attempt passes through apply_attempt_accounting/3 exactly once.
  defp record_run_usage(state, run_id, delta) do
    usage =
      Map.get(state.run_usage, run_id, %{
        reported_input: 0,
        reported_output: 0,
        estimated: 0,
        unresolved: false
      })

    usage =
      Enum.reduce(delta, usage, fn
        {:unresolved, value}, acc -> %{acc | unresolved: acc.unresolved or value}
        {key, value}, acc -> Map.update!(acc, key, &(&1 + value))
      end)

    %{state | run_usage: Map.put(state.run_usage, run_id, usage)}
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

  defp admitted_run_configuration(
         %{configuration: configuration},
         %{kind: "prompt_admitted_v3"} = record,
         budget
       )
       when is_map(configuration) do
    if record["configuration_version"] == configuration["configuration_version"] and
         budget == configuration["context_token_budget"],
       do: {:ok, configuration},
       else: {:error, :invalid_run_configuration}
  end

  defp admitted_run_configuration(_state, _record, _budget),
    do: {:error, :invalid_run_configuration}

  # Concept: an authored ceiling fences preparation before a request exists.
  # Technical depth: the first staged request still starts the relative duration;
  # its immutable effective deadline supersedes this admission ceiling. Reading
  # it does not stage work, consult a clock, or change command disposition.
  defp retained_run_deadline(state, run_id) do
    Map.get(state.deadlines, run_id) || get_in(state.bounds, [run_id, :deadline_at_ms])
  end

  defp staged_run_deadline_agrees?(state, run_id, deadline) do
    ceiling = get_in(state.bounds, [run_id, :deadline_at_ms])
    staged = Map.get(state.deadlines, run_id)

    is_integer(deadline) and (is_nil(ceiling) or deadline <= ceiling) and
      (is_nil(staged) or deadline == staged)
  end

  defp record_bounds(record) do
    with {:ok, declared} <-
           Bounds.declare(%{
             max_turns: record["max_turns"],
             token_budget: record["token_budget"],
             deadline_ms: record["deadline_ms"]
           }),
         {:ok, authored} <- decode_retained_authored_bounds(record["authored_bounds"], :prompt),
         true <-
           Enum.all?(authored || %{}, fn
             {:deadline_at_ms, _} -> true
             {key, value} -> Map.get(declared, key) == value
           end) do
      case authored do
        %{deadline_at_ms: ceiling} -> {:ok, Map.put(declared, :deadline_at_ms, ceiling)}
        _ -> {:ok, declared}
      end
    else
      _ -> {:error, :invalid_declared_bounds}
    end
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

  defp initial_public_configuration([%{payload: payload} | _records]) do
    with {:ok, genesis} <- SessionGenesis.normalize(payload) do
      {:ok, SessionConfiguration.public_view(genesis["initial_configuration"])}
    end
  end

  defp initial_public_configuration([]), do: {:error, :invalid_public_configuration}

  defp valid_initial_public_configuration(configuration) do
    case LoopexProtocol.Session.Configuration.encode_wire(configuration) do
      {:ok, _wire} -> :ok
      :error -> {:error, :invalid_public_configuration}
    end
  end

  # Concept: inspection and checkpoint publication carry one bounded capture.
  # Technical depth: lookup only the active retained checkpoint. Its closed
  # public allowlist excludes summary text and private lineage/digest fields;
  # ownership and excerpting come from the same committed checkpoint record.
  defp checkpoint_public_view(%{active_checkpoint: nil}), do: nil

  defp checkpoint_public_view(state),
    do: checkpoint_public_payload(Map.fetch!(state.checkpoints, state.active_checkpoint))

  defp checkpoint_public_payload(record) do
    Map.take(
      record,
      ~w(checkpoint_id episode_id covered_range prior_checkpoint_id strategy strategy_revision model reasoning configuration_version usage)
    )
    |> Map.put(
      "owner",
      if(record.kind == "compaction_checkpoint_committed_v1",
        do: %{"kind" => "run", "id" => record["run_id"]},
        else: %{"kind" => "compact", "id" => record["command_id"]}
      )
    )
    |> Map.put("source_excerpted", record["summary"]["source_excerpted"])
  end

  defp checkpoint_projection_id(nil), do: nil
  defp checkpoint_projection_id(checkpoint), do: checkpoint["checkpoint_id"]

  defp replay_projection(events, anchor, initial_configuration) do
    with {:ok, scan} <- start_snapshot_scan("replay", anchor, initial_configuration),
         {:ok, scan} <- scan_snapshot_page(scan, events),
         {:ok,
          %{
            snapshot: %{active_run_id: active_run_id, event_sequence: ^anchor},
            active_maintenance: active_maintenance,
            configuration: configuration,
            checkpoint: checkpoint,
            open_interaction: open_interaction
          }} <-
           finish_snapshot_scan(scan) do
      {:ok,
       %{
         active_run_id: active_run_id,
         active_maintenance: active_maintenance,
         configuration: configuration,
         checkpoint: checkpoint,
         open_interaction: open_interaction,
         sequence: anchor
       }}
    else
      {:error, :cursor_expired} -> {:error, :snapshot_cursor_unavailable}
      {:error, reason} -> {:error, reason}
    end
  end

  defp advance_snapshot_scan(scan, event) do
    expected = scan.tail + 1

    with {:ok, open_interaction} <- advance_open_interaction(scan.open_interaction, event),
         {:ok, active_run} <- advance_public_projection(scan.active_run, event, expected),
         {:ok, maintenance} <- advance_maintenance_projection(scan.active_maintenance, event),
         :ok <- valid_public_maintenance_owner(maintenance, active_run, open_interaction),
         {:ok, configuration} <-
           advance_configuration_projection(
             scan.configuration,
             event,
             active_run,
             maintenance,
             open_interaction
           ),
         {:ok, checkpoint} <- advance_checkpoint_projection(scan.checkpoint, event, maintenance),
         {:ok, last_compact} <-
           advance_compact_projection(
             scan.last_compact,
             event,
             maintenance,
             active_run,
             open_interaction
           ) do
      projection = %{
        active_run: active_run,
        open_interaction: open_interaction,
        configuration: configuration,
        checkpoint: checkpoint,
        active_maintenance: maintenance,
        last_compact: last_compact
      }

      anchor_projection =
        if scan.requested_anchor == expected,
          do: {:set, projection},
          else: scan.anchor_projection

      {:ok,
       %{
         scan
         | tail: expected,
           active_run: active_run,
           open_interaction: open_interaction,
           configuration: configuration,
           checkpoint: checkpoint,
           active_maintenance: maintenance,
           last_compact: last_compact,
           anchor_projection: anchor_projection
       }}
    end
  end

  # Concept: configuration changes affect only cursors at or after their fact.
  # Technical depth: the shared codec rejects private fields and malformed
  # quantities. The next version advances exactly once, while the public prefix
  # is settled. The immutable seed and one latest change suffice; no history
  # index or live coordinator configuration is read by this reduction.
  defp advance_configuration_projection(
         current,
         %{kind: "session.configured"} = event,
         run,
         maintenance,
         interaction
       ) do
    payload = Map.drop(event, [:kind, :event_id, :event_sequence])

    with {:ok, _} <- LoopexProtocol.Session.Configuration.encode_change(payload),
         true <- is_nil(run) and is_nil(maintenance) and is_nil(interaction),
         next = payload["configuration"],
         prior_version = current["configuration_version"],
         true <- next["configuration_version"] == prior_version + 1 do
      {:ok, next}
    else
      :error -> {:error, :invalid_public_configuration}
      false -> {:error, :invalid_public_configuration_transition}
    end
  end

  defp advance_configuration_projection(current, _event, _run, _maintenance, _interaction),
    do: {:ok, current}

  # Concept: a snapshot retains the latest checkpoint's public provenance.
  # Technical depth: admit only a closed checkpoint from the currently captured
  # episode and owner. Its prior identity must match the previous checkpoint,
  # and inherited omissions cannot disappear. Summary bytes and source records
  # never enter the accumulator. Private recovery separately authenticates the
  # complete event against the owner's expected outbox.
  defp advance_checkpoint_projection(current, %{kind: "context.compacted"} = event, maintenance) do
    payload = Map.drop(event, [:kind, :event_id, :event_sequence])

    with {:ok, _} <- LoopexProtocol.Session.Checkpoint.encode_wire(payload),
         true <- is_map(maintenance),
         true <-
           Enum.all?(~w(episode_id owner model reasoning configuration_version), fn key ->
             payload[key] == maintenance[key]
           end),
         true <- payload["prior_checkpoint_id"] == checkpoint_projection_id(current),
         true <- is_nil(current) or not current["source_excerpted"] or payload["source_excerpted"] do
      {:ok, payload}
    else
      :error -> {:error, :invalid_public_checkpoint}
      false -> {:error, :invalid_public_checkpoint_transition}
    end
  end

  defp advance_checkpoint_projection(current, _event, _maintenance), do: {:ok, current}

  # Concept: historical maintenance comes from the same cursor as the run view.
  # Technical depth: retain one allowlisted view, plus the requested anchor's
  # view, rather than private episodes or event pages. Shape validation uses the
  # shared native codec. An active episode cannot be replaced by another owner
  # or episode, repeated unchanged rows are impossible, and run/question facts
  # cannot overlap maintenance. Recovery also compares this public reduction
  # with its independently reconstructed private capture.
  defp advance_maintenance_projection(current, %{kind: "context.maintenance_changed"} = event) do
    payload = Map.drop(event, [:kind, :event_id, :event_sequence])

    with {:ok, _} <- LoopexProtocol.Session.MaintenanceView.encode_wire(payload),
         next = payload["active_maintenance"],
         true <- current != next,
         true <- same_public_maintenance_episode?(current, next) do
      {:ok, next}
    else
      :error -> {:error, :invalid_public_maintenance_view}
      false -> {:error, :invalid_public_maintenance_transition}
    end
  end

  defp advance_maintenance_projection(current, _event), do: {:ok, current}

  defp same_public_maintenance_episode?(nil, _next), do: true
  defp same_public_maintenance_episode?(_current, nil), do: true

  defp same_public_maintenance_episode?(current, next),
    do: current["episode_id"] == next["episode_id"] and current["owner"] == next["owner"]

  defp valid_public_maintenance_owner(nil, _run, _interaction), do: :ok

  defp valid_public_maintenance_owner(
         %{"owner" => %{"kind" => "run", "id" => id}},
         {id, _phase},
         nil
       ),
       do: :ok

  defp valid_public_maintenance_owner(%{"owner" => %{"kind" => "compact"}}, nil, nil),
    do: :ok

  defp valid_public_maintenance_owner(_maintenance, _run, _interaction),
    do: {:error, :invalid_public_maintenance_transition}

  # Concept: retain only the last completed compact command at this cursor.
  # Technical depth: the result shares the closed event codec, including its
  # actual episode/command identity and exact usage. Completion follows release
  # of the maintenance view and cannot overlap a run or question. A repeated
  # last command refuses without retaining a growing command-history index;
  # recovery authenticates every row against the private owner's derived outbox.
  defp advance_compact_projection(
         current,
         %{kind: "context.compaction_finished"} = event,
         maintenance,
         run,
         interaction
       ) do
    payload = Map.drop(event, [:kind, :event_id, :event_sequence])

    with {:ok, _} <- LoopexProtocol.Session.CompactResult.encode_completion(payload),
         true <- is_nil(maintenance) and is_nil(run) and is_nil(interaction),
         true <- is_nil(current) or current["command_id"] != payload["command_id"] do
      {:ok, payload}
    else
      :error -> {:error, :invalid_public_compact_completion}
      false -> {:error, :invalid_public_compact_transition}
    end
  end

  defp advance_compact_projection(current, _event, _maintenance, _run, _interaction),
    do: {:ok, current}

  # Concept: the question that is open at this point in history, if any.
  #
  # Technical depth: accepted ADR 0023 gives an attachment a `open_interaction`
  # view at the same cursor as its snapshot, so two clients attaching at one
  # cursor cannot disagree about whether a question was waiting there. It is
  # projected from the same public events a client replays rather than read from
  # live coordinator state, because live state answers a different question: what
  # is open now, not what was open then. A resolution of any kind closes it, and
  # the kinds are distinct so a reader can tell an expiry from an abort.
  defp advance_open_interaction(nil, %{kind: "interaction.requested"} = event) do
    projected = %{
      "interaction_id" => event["interaction_id"],
      "run_id" => event["run_id"],
      "turn" => event["turn"],
      "tool_call_id" => event["tool_call_id"],
      "prompt" => event["prompt"],
      "choices" => event["choices"],
      "expires_at" => event["expires_at"],
      "status" => "pending",
      "producer" => if(event["producer"] == "model_tool", do: "model_tool", else: "policy_defer"),
      "kind" =>
        if(event["producer"] == "model_tool", do: event["interaction_kind"], else: "choice")
    }

    payload = Map.drop(event, [:kind, :event_id, :event_sequence])

    with true <-
           event["producer"] == "model_tool" or
             closed_history_map?(
               payload,
               ~w(interaction_id run_id turn tool_call_id prompt choices expires_at)
             ),
         {:ok, _} <- LoopexProtocol.Session.OpenInteraction.encode_wire(projected) do
      {:ok, projected}
    else
      _ -> {:error, :invalid_public_interaction}
    end
  end

  defp advance_open_interaction(
         %{"status" => "pending", "producer" => "policy_defer", "kind" => "choice"} = open,
         %{kind: "interaction.answer_admitted"} = event
       ) do
    payload = Map.drop(event, [:kind, :event_id, :event_sequence])

    with {:ok, _} <- LoopexProtocol.Session.OpenInteraction.encode_answer_admitted(payload),
         true <-
           Enum.all?(~w(interaction_id run_id turn tool_call_id), &(payload[&1] == open[&1])),
         true <- Enum.any?(open["choices"], &(&1["id"] == payload["answer_choice_id"])) do
      {:ok,
       open
       |> Map.put("status", "answered")
       |> Map.put("answer_choice_id", payload["answer_choice_id"])
       |> Map.put("answer_command_id", payload["answer_command_id"])}
    else
      _ -> {:error, :invalid_public_interaction_answer}
    end
  end

  defp advance_open_interaction(_open, %{kind: kind})
       when kind in ["interaction.requested", "interaction.answer_admitted"],
       do: {:error, :invalid_public_interaction_transition}

  # Concept: a policy terminal closes the exact open question and its retained answer.
  # Technical depth: the cursor authenticates all four owning fields and the
  # answer pair before closing the slot. Pending expiry or cancellation carries
  # no answer; an answered terminal preserves its admitted command and choice.
  defp advance_open_interaction(
         %{"producer" => "policy_defer", "kind" => "choice"} = open,
         %{kind: kind} = event
       )
       when kind in [
              "interaction.resolved",
              "interaction.expired",
              "interaction.cancelled",
              "interaction.answered",
              "interaction.declined"
            ] do
    payload = Map.drop(event, [:kind, :event_id, :event_sequence])
    command_id = payload["answer_command_id"]
    required = ~w(interaction_id run_id turn tool_call_id resolution answer_command_id)
    required = if is_nil(command_id), do: required, else: required ++ ["choice_id"]
    resolution = payload["resolution"]

    answer_matches? =
      case open["status"] do
        "pending" ->
          resolution in ["expired", "cancelled"] and is_nil(command_id)

        "answered" ->
          command_id == open["answer_command_id"] and
            payload["choice_id"] == open["answer_choice_id"]
      end

    with true <- closed_history_map?(payload, required, ["reason"]),
         true <-
           not Map.has_key?(payload, "reason") or
             (is_binary(payload["reason"]) and byte_size(payload["reason"]) <= 65_536),
         true <-
           Enum.all?(~w(interaction_id run_id turn tool_call_id), &(payload[&1] == open[&1])),
         true <- resolution in ["allowed", "denied", "expired", "cancelled"],
         true <- kind == interaction_event_kind(resolution),
         true <- answer_matches? do
      {:ok, nil}
    else
      _ -> {:error, :invalid_public_interaction_transition}
    end
  end

  defp advance_open_interaction(%{"interaction_id" => id}, %{kind: kind} = event)
       when kind in [
              "interaction.resolved",
              "interaction.expired",
              "interaction.cancelled",
              "interaction.answered",
              "interaction.declined"
            ] do
    if event["interaction_id"] == id,
      do: {:ok, nil},
      else: {:error, :invalid_public_interaction_transition}
  end

  defp advance_open_interaction(nil, %{kind: kind})
       when kind in [
              "interaction.resolved",
              "interaction.expired",
              "interaction.cancelled",
              "interaction.answered",
              "interaction.declined"
            ],
       do: {:error, :invalid_public_interaction_transition}

  defp advance_open_interaction(open, _event), do: {:ok, open}

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
      public_history_matches?(
        Enum.map(events, &Map.delete(&1, :event_sequence)),
        expected_events
      )
  end

  # Concept: retained public history must be exactly what replaying the private
  # records expects, except that a session recorded before the settled fact
  # existed stays readable.
  #
  # Technical depth: `session.settled` is an M4 repair of an accepted ADR 0011
  # fact core never published, so every session written before it ends its runs
  # with `run.finished` and nothing after. Requiring it here would make every
  # such session unreadable by this reducer, which is a migration no durable
  # history can perform: the rows are immutable and the fact was never written.
  # Only that one kind may be absent, and only where replay expects it; a
  # retained event the replay does not expect, a missing event of any other
  # kind, or any reordering still fails as it always did. The cost is that a
  # settled fact deleted from a recent history reads like an older session,
  # which is a fact derivable from the terminal beside it rather than durable
  # truth that would be falsified by its absence.
  defp public_history_matches?([], []), do: true

  defp public_history_matches?([event | retained], [event | expected]),
    do: public_history_matches?(retained, expected)

  defp public_history_matches?(retained, [%{kind: "session.settled"} | expected]),
    do: public_history_matches?(retained, expected)

  defp public_history_matches?(_retained, _expected), do: false

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
      event_id:
        tool_event_id(
          "event-tool-started",
          session_id,
          job.run_id,
          job.turn_id,
          job.tool_call_id
        ),
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
  defp tool_finished_event(session_id, job, outcome, artifacts) do
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
      event_id:
        tool_event_id(
          "event-tool-finished",
          session_id,
          job.run_id,
          job.turn_id,
          job.tool_call_id
        ),
      kind: "tool.finished"
    }
  end

  # Concept: a provider may reuse its call ID in a later turn or run.
  # Technical depth: the current record families bind every tool event to the
  # session, run, turn and call; superseded kinds refuse before projection.
  defp tool_event_id(namespace, session_id, run_id, turn_id, call_id),
    do: stable_id(namespace, session_id, {run_id, turn_id, call_id})

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

  # Concept: a session that ends a run with nothing queued behind it says so,
  # once, as a fact distinct from the run's own ending.
  #
  # Technical depth: accepted ADR 0011 fixes this shape: the terminal
  # transaction publishes `run.finished`, resolves the steer, and then either
  # promotes a queued follow-up or publishes `session.settled`. A finished run
  # whose follow-up was promoted publishes no settled fact, because the session
  # still owes work and an operator told otherwise would act on it. The event's
  # identity is derived from the session and the run that ended, so replaying
  # the same terminal produces the same fact rather than a second one.
  defp session_settled(_state, _run_id, [_promoted | _rest]), do: []

  defp session_settled(state, run_id, []) do
    [
      %{
        "run_id" => run_id,
        event_id: stable_id("event-session-settled", state.session_id, run_id),
        kind: "session.settled"
      }
    ]
  end

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

  @resource_refusals [
    :run_active,
    :resource_manifest_missing,
    :resource_binding_changed,
    :resource_not_admitted,
    :resource_not_found,
    :resource_selection_limit,
    :resource_support_not_found
  ]

  defp resource_resolution({:accepted, resolved}) when is_map(resolved),
    do: {:ok, "accepted", resolved}

  defp resource_resolution({:refused, reason}) when reason in @resource_refusals,
    do: {:ok, Atom.to_string(reason), nil}

  defp resource_resolution(_resolution), do: {:error, :invalid_resource_resolution}

  # Concept: resource command identity includes every selected label and trust
  # decision member. Historical command normalization keeps its own meaning.
  # Technical depth: fixed alias lookups reject duplicates and extra keys before
  # traversing bounded lists or computing the existing command digest framing.
  defp normalize_resource_command(command) do
    with true <- is_map(command) and not is_struct(command),
         {:ok, type} <- resource_alias(command, :type),
         {:ok, keys, type} <- resource_command_keys(type),
         {:ok, normalized} <- resource_members(command, keys),
         true <- resource_text?(normalized["command_id"], 256),
         true <- resource_digest?(normalized["manifest_digest"]) do
      normalize_resource_members(Map.put(normalized, "type", type))
    else
      _invalid -> {:error, :invalid_command}
    end
  end

  defp resource_command_keys(type) when type in [:admit_resources, "admit_resources"],
    do: {:ok, [:type, :command_id, :manifest_digest, :decision], "admit_resources"}

  defp resource_command_keys(type) when type in [:activate_skill, "activate_skill"],
    do:
      {:ok,
       [
         :type,
         :command_id,
         :manifest_digest,
         :source_id,
         :name,
         :pack_digest,
         :supporting_labels
       ], "activate_skill"}

  defp resource_command_keys(_type), do: :error

  defp resource_members(raw, keys) when is_map(raw) and not is_struct(raw) do
    if map_size(raw) <= length(keys) do
      Enum.reduce_while(keys, {:ok, %{}, 0}, fn key, {:ok, acc, seen} ->
        case resource_alias(raw, key) do
          {:ok, value} ->
            {:cont, {:ok, Map.put(acc, Atom.to_string(key), value), seen + 1}}

          :error when key == :supporting_labels ->
            {:cont, {:ok, Map.put(acc, "supporting_labels", []), seen}}

          _invalid ->
            {:halt, :error}
        end
      end)
      |> case do
        {:ok, normalized, seen} when seen == map_size(raw) -> {:ok, normalized}
        _invalid -> :error
      end
    else
      :error
    end
  end

  defp resource_members(_raw, _keys), do: :error

  defp resource_alias(raw, key) do
    case {Map.fetch(raw, key), Map.fetch(raw, Atom.to_string(key))} do
      {{:ok, value}, :error} -> {:ok, value}
      {:error, {:ok, value}} -> {:ok, value}
      {:error, :error} -> :error
      _duplicate -> {:error, :duplicate_alias}
    end
  end

  defp normalize_resource_members(%{"type" => "admit_resources", "decision" => nil} = command),
    do: {:ok, command}

  defp normalize_resource_members(%{"type" => "admit_resources"} = command) do
    case ResourcePack.normalize_decision(command["decision"]) do
      {:ok, decision} -> {:ok, Map.put(command, "decision", decision)}
      _invalid -> {:error, :invalid_command}
    end
  end

  defp normalize_resource_members(%{"type" => "activate_skill"} = command) do
    with true <- resource_text?(command["source_id"], 1_024),
         true <- resource_text?(command["name"], 64),
         true <- Regex.match?(~r/\A[a-z0-9]+(?:-[a-z0-9]+)*\z/, command["name"]),
         true <- resource_digest?(command["pack_digest"]),
         {:ok, labels} <- resource_labels(command["supporting_labels"], 8, []) do
      {:ok, Map.put(command, "supporting_labels", labels)}
    else
      _invalid -> {:error, :invalid_command}
    end
  end

  defp resource_labels([], _remaining, reversed), do: {:ok, Enum.reverse(reversed)}

  defp resource_labels([label | rest], remaining, reversed) when remaining > 0 do
    if resource_text?(label, 1_024) and label not in reversed do
      resource_labels(rest, remaining - 1, [label | reversed])
    else
      :error
    end
  end

  defp resource_labels(_labels, _remaining, _reversed), do: :error

  defp resource_text?(value, max) do
    is_binary(value) and byte_size(value) in 1..max and String.valid?(value) and
      not Regex.match?(~r/[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]/u, value)
  end

  defp resource_digest?(value),
    do: is_binary(value) and byte_size(value) == 64 and Regex.match?(~r/\A[0-9a-f]{64}\z/, value)

  defp apply_resource_record(state, record) do
    with true <- is_map(record) and map_size(record) == 5,
         %{kind: "resource_command_v1"} <- record,
         {:ok, normalized} <- normalize_resource_command(record["command"]),
         true <- normalized == record["command"],
         {:ok, digest} <- command_digest(normalized),
         true <- digest == record["command_digest"],
         false <- Map.has_key?(state.commands, normalized["command_id"]),
         {:ok, _record, bytes} <- Store.normalize_and_measure_item(:record, record),
         true <- bytes <= 16_384,
         {:ok, resources, reply} <- apply_resource_disposition(state, normalized, record) do
      binding = %{digest: digest, reply: reply, run_id: nil}

      {:ok,
       %{
         state
         | resources: resources,
           commands: Map.put(state.commands, normalized["command_id"], binding)
       }}
    else
      _invalid -> {:error, :invalid_resource_command_record}
    end
  end

  defp apply_resource_disposition(%{active_run_id: nil} = state, command, %{
         "disposition" => "accepted",
         "resolved" => resolved
       }) do
    with {:ok, resources} <- apply_resource_acceptance(state.resources, command, resolved) do
      {:ok, resources, {:accepted, command["command_id"]}}
    end
  end

  defp apply_resource_disposition(state, command, %{
         "disposition" => disposition,
         "resolved" => nil
       }) do
    reason = Enum.find(@resource_refusals, &(Atom.to_string(&1) == disposition))

    if not is_nil(reason) and valid_resource_refusal?(state, command, reason) do
      {:ok, state.resources, {:error, reason}}
    else
      :error
    end
  end

  defp apply_resource_disposition(_state, _command, _record), do: :error

  # Concept: a retained refusal remains an exact outcome of its command rather
  # than an interchangeable member of the resource error vocabulary.
  # Technical depth: replay validates every fact available in durable state but
  # preserves snapshot-dependent outcomes without consulting current content.
  defp valid_resource_refusal?(%{active_run_id: run_id}, _command, :run_active),
    do: not is_nil(run_id)

  defp valid_resource_refusal?(%{active_run_id: run_id}, _command, _reason)
       when not is_nil(run_id),
       do: false

  defp valid_resource_refusal?(
         %{resources: resources},
         %{"type" => "admit_resources", "decision" => decision} = command,
         reason
       ) do
    cond do
      is_map(decision) and decision["revocation_state"] == "active" ->
        reason in [:resource_manifest_missing, :resource_binding_changed]

      is_nil(resources) ->
        reason == :resource_not_admitted

      not disabled_resource_binding?(resources, command, decision) ->
        reason == :resource_binding_changed

      true ->
        false
    end
  end

  defp valid_resource_refusal?(%{resources: nil}, %{"type" => "activate_skill"}, reason),
    do: reason == :resource_not_admitted

  defp valid_resource_refusal?(
         %{resources: resources},
         %{"type" => "activate_skill", "manifest_digest" => manifest_digest} = command,
         reason
       ) do
    cond do
      manifest_digest != resources["manifest_digest"] ->
        reason == :resource_binding_changed

      is_nil(resources["decision"]) or resources["decision"]["revocation_state"] == "revoked" ->
        reason == :resource_not_admitted

      true ->
        active_resource_refusal?(resources, command, reason)
    end
  end

  defp valid_resource_refusal?(_state, _command, _reason), do: false

  defp disabled_resource_binding?(resources, command, nil),
    do: resources["manifest_digest"] == command["manifest_digest"]

  defp disabled_resource_binding?(resources, command, decision) do
    resources["manifest_digest"] == command["manifest_digest"] and
      decision["manifest_digest"] == resources["manifest_digest"] and
      decision["workspace_ref"] == resources["workspace_ref"]
  end

  defp active_resource_refusal?(_resources, _command, reason)
       when reason in [:resource_manifest_missing, :resource_binding_changed, :resource_not_found],
       do: true

  defp active_resource_refusal?(resources, _command, :resource_selection_limit),
    do: length(resources["selections"]) == 4

  defp active_resource_refusal?(_resources, command, :resource_support_not_found),
    do: command["supporting_labels"] != []

  defp active_resource_refusal?(_resources, _command, _reason), do: false

  defp apply_resource_acceptance(previous, %{"type" => "admit_resources"} = command, resolved) do
    decision = command["decision"]

    with true <- is_map(resolved) and map_size(resolved) == 2,
         true <- resource_text?(resolved["workspace_ref"], 1_024),
         true <- resolved["manifest_digest"] == command["manifest_digest"],
         true <- resource_admission_binding?(previous, command, resolved) do
      {:ok,
       %{
         "workspace_ref" => resolved["workspace_ref"],
         "manifest_digest" => resolved["manifest_digest"],
         "decision" => decision,
         "selections" => []
       }}
    else
      _invalid -> :error
    end
  end

  defp apply_resource_acceptance(previous, %{"type" => "activate_skill"} = command, resolved) do
    with %{"decision" => %{"revocation_state" => "active"}, "selections" => selections} <-
           previous,
         true <- previous["manifest_digest"] == command["manifest_digest"],
         true <- valid_resource_selection?(resolved, command["supporting_labels"]),
         existing = Enum.find_index(selections, &(&1["pack_index"] == resolved["pack_index"])),
         true <- not is_nil(existing) or length(selections) < 4 do
      selections =
        if is_nil(existing),
          do: selections ++ [resolved],
          else: List.replace_at(selections, existing, resolved)

      {:ok, %{previous | "selections" => selections}}
    else
      _invalid -> :error
    end
  end

  defp resource_admission_binding?(previous, command, resolved) do
    decision = command["decision"]
    active = is_map(decision) and decision["revocation_state"] == "active"

    decision_matches =
      is_nil(decision) or
        (decision["manifest_digest"] == resolved["manifest_digest"] and
           decision["workspace_ref"] == resolved["workspace_ref"])

    prior_matches =
      is_map(previous) and
        previous["manifest_digest"] == resolved["manifest_digest"] and
        previous["workspace_ref"] == resolved["workspace_ref"]

    decision_matches and (active or prior_matches)
  end

  defp valid_resource_selection?(resolved, labels) do
    with true <- is_map(resolved) and map_size(resolved) == 4,
         true <- resource_index?(resolved["pack_index"]),
         true <- resource_index?(resolved["instruction_file_index"]),
         true <- resource_digest?(resolved["instruction_digest"]),
         true <- valid_resource_support?(resolved["supporting_files"], labels, []) do
      Enum.all?(
        resolved["supporting_files"],
        &(&1["file_index"] != resolved["instruction_file_index"])
      )
    else
      _invalid -> false
    end
  end

  defp valid_resource_support?([], [], _seen), do: true

  defp valid_resource_support?([file | files], [_label | labels], seen) do
    is_map(file) and map_size(file) == 3 and resource_index?(file["file_index"]) and
      file["file_index"] not in seen and resource_digest?(file["digest"]) and
      is_integer(file["size"]) and file["size"] in 0..1_048_576 and
      valid_resource_support?(files, labels, [file["file_index"] | seen])
  end

  defp valid_resource_support?(_files, _labels, _seen), do: false
  defp resource_index?(value), do: is_integer(value) and value in 0..63

  defp normalize_command(command) do
    with {:ok, command_id} <- fetch_binary(command, :command_id),
         {:ok, type} <- fetch_type(command) do
      case type do
        :compact ->
          with true <- map_size(command) == 3,
               true <-
                 Enum.all?(
                   Map.keys(command),
                   &(&1 in [:type, "type", :command_id, "command_id", :bounds, "bounds"])
                 ),
               {:ok, bounds} <- fetch(command, :bounds),
               {:ok, bounds} <- normalize_compact_bounds(bounds) do
            {:ok, %{type: :compact, command_id: command_id, bounds: bounds}}
          else
            _ -> {:error, :invalid_command}
          end

        :configure ->
          with true <- map_size(command) == 3,
               true <-
                 Enum.all?(
                   Map.keys(command),
                   &(&1 in [:type, "type", :command_id, "command_id", :changes, "changes"])
                 ),
               {:ok, changes} <- fetch(command, :changes),
               :ok <- SessionConfiguration.validate_update(changes) do
            {:ok, %{type: :configure, command_id: command_id, changes: changes}}
          else
            _ -> {:error, :invalid_command}
          end

        :prompt ->
          with {:ok, content} <- fetch_binary(command, :content) do
            normalize_authored_bounds(command, %{
              type: :prompt,
              command_id: command_id,
              content: content
            })
          else
            _other -> {:error, :invalid_command}
          end

        :abort ->
          {:ok, %{type: :abort, command_id: command_id}}

        # Concept: an answer names the question it answers and the choice it
        # takes, and nothing else.
        #
        # Technical depth: neither field is inferred. An answer that named no
        # interaction would have to be matched against whatever happened to be
        # open, which is exactly how a late answer reopens a question that has
        # already resolved.
        :interaction_answer ->
          with {:ok, interaction_id} <- fetch_binary(command, :interaction_id),
               {:ok, response} <- normalize_interaction_answer(command) do
            {:ok,
             Map.merge(
               %{
                 type: :interaction_answer,
                 command_id: command_id,
                 interaction_id: interaction_id
               },
               response
             )}
          else
            _other -> {:error, :invalid_command}
          end

        # Concept: a steer must name the run it is steering.
        #
        # Technical depth: the runtime never infers whether new input is
        # steering or follow-up, so a steer that names no run, or names a
        # different one, is refused rather than retargeted. Guessing here would
        # put an operator's words into a run they did not mean.
        :steer ->
          with :error <- fetch(command, :bounds),
               {:ok, run_id} <- fetch_binary(command, :run_id),
               {:ok, content} <- fetch_binary(command, :content) do
            {:ok, %{type: :steer, command_id: command_id, run_id: run_id, content: content}}
          else
            _other -> {:error, :invalid_command}
          end

        :follow_up ->
          with {:ok, content} <- fetch_binary(command, :content) do
            normalize_authored_bounds(command, %{
              type: :follow_up,
              command_id: command_id,
              content: content
            })
          else
            _other -> {:error, :invalid_command}
          end
      end
    end
  end

  defp normalize_authored_bounds(original, normalized) do
    fields = [:type, :command_id, :content, :bounds]
    keys = Enum.flat_map(fields, &[&1, Atom.to_string(&1)])

    if Enum.all?(Map.keys(original), &(&1 in keys)) and
         Enum.all?(fields, fn field ->
           not (Map.has_key?(original, field) and Map.has_key?(original, Atom.to_string(field)))
         end) do
      case fetch(original, :bounds) do
        :error ->
          {:ok, normalized}

        {:ok, value} ->
          with {:ok, bounds} <- Bounds.authored(value, normalized.type),
               do: {:ok, Map.put(normalized, :bounds, bounds)}
      end
    else
      {:error, :invalid_command}
    end
  end

  # Concept: accepted identity retains the author's exact selected keys.
  # Technical depth: nil means omitted; an authored empty map stays empty.
  # The current retained representation has only fixed string keys, matching
  # Store plain data; replay reconstructs native atoms before identity checks.
  # Refusals retain revision and digest only: arbitrary positive quantities may
  # exceed the compact refusal ceiling. An expired refusal separately retains
  # its bounded absolute ceiling and original admission sample.
  defp retain_authored_bounds(record, %{type: type} = command)
       when type in [:prompt, :follow_up] do
    record = Map.put(record, "command_revision", 2)

    if record["admission"] == "accepted",
      do: Map.put(record, "authored_bounds", retained_authored_bounds(Map.get(command, :bounds))),
      else: record
  end

  defp retain_authored_bounds(record, _), do: record

  defp validate_authored_bounds_record(%{"command_type" => type} = record)
       when type in ["prompt", "follow_up"] do
    kind = if type == "prompt", do: :prompt, else: :follow_up

    with true <- record["command_revision"] == 2 do
      if record["admission"] == "accepted" do
        with true <- Map.has_key?(record, "authored_bounds"),
             :ok <- validate_retained_authored_bounds(record["authored_bounds"], kind),
             true <- retained_command_digest?(record, kind) do
          :ok
        else
          _ -> {:error, :invalid_authored_command_bounds}
        end
      else
        if Map.has_key?(record, "authored_bounds"),
          do: {:error, :invalid_authored_command_bounds},
          else: :ok
      end
    else
      _ -> {:error, :invalid_authored_command_bounds}
    end
  end

  defp validate_authored_bounds_record(_), do: :ok

  defp retained_authored_bounds(nil), do: nil

  defp retained_authored_bounds(bounds) do
    fields = %{
      max_turns: "max_turns",
      token_budget: "token_budget",
      deadline_ms: "deadline_ms",
      deadline_at_ms: "deadline_at_ms"
    }

    Map.new(bounds, fn {key, value} -> {Map.fetch!(fields, key), value} end)
  end

  defp validate_retained_authored_bounds(value, kind) do
    case decode_retained_authored_bounds(value, kind) do
      {:ok, _} -> :ok
      _ -> :error
    end
  end

  # Concept: current journals use one plain representation, with no atom-key fallback.
  # Technical depth: only these four literal keys become already-defined atoms.
  # Native command aliases belong at admission; stored quantities keep their
  # validated integer domains, and omission remains distinct from an empty map.
  defp decode_retained_authored_bounds(nil, _kind), do: {:ok, nil}

  defp decode_retained_authored_bounds(value, kind) when is_map(value) and not is_struct(value) do
    fields = %{
      "max_turns" => :max_turns,
      "token_budget" => :token_budget,
      "deadline_ms" => :deadline_ms,
      "deadline_at_ms" => :deadline_at_ms
    }

    if Enum.all?(Map.keys(value), &is_map_key(fields, &1)) do
      native = Map.new(value, fn {key, quantity} -> {Map.fetch!(fields, key), quantity} end)
      Bounds.authored(native, kind)
    else
      :error
    end
  end

  defp decode_retained_authored_bounds(_, _), do: :error

  defp retained_command_digest?(record, kind) do
    with {:ok, bounds} <- decode_retained_authored_bounds(record["authored_bounds"], kind) do
      command = %{type: kind, command_id: record["command_id"], content: record["content"]}
      command = if is_nil(bounds), do: command, else: Map.put(command, :bounds, bounds)
      command_digest(command) == {:ok, record["command_digest"]}
    else
      _ -> false
    end
  end

  defp normalize_interaction_answer(command) do
    case {fetch(command, :answer), fetch(command, :choice_id)} do
      {{:ok, answer}, :error} ->
        case LoopexProtocol.Session.Answer.normalize(answer) do
          {:ok, %{"choice_id" => id}} -> {:ok, %{choice_id: id}}
          {:ok, normalized} -> {:ok, %{answer: normalized}}
          :error -> :error
        end

      {:error, {:ok, id}} when is_binary(id) and byte_size(id) > 0 ->
        {:ok, %{choice_id: id}}

      _ ->
        :error
    end
  end

  defp fetch_type(command) do
    case fetch(command, :type) do
      {:ok, value} when value in [:prompt, "prompt"] ->
        {:ok, :prompt}

      {:ok, value} when value in [:configure, "configure"] ->
        {:ok, :configure}

      {:ok, value} when value in [:compact, "compact"] ->
        {:ok, :compact}

      {:ok, value} when value in [:abort, "abort"] ->
        {:ok, :abort}

      {:ok, value} when value in [:steer, "steer"] ->
        {:ok, :steer}

      {:ok, value} when value in [:follow_up, "follow_up"] ->
        {:ok, :follow_up}

      {:ok, value} when value in [:interaction_answer, "interaction_answer"] ->
        {:ok, :interaction_answer}

      _other ->
        {:error, :invalid_command_type}
    end
  end

  # Concept: explicit compact has its own finite declaration, without run bounds.
  # Technical depth: admission and replay share the closed three-field schema.
  # Atom/binary caller keys normalize to the same retained binary-key preimage;
  # duplicate spellings, omissions, extra keys and narrowed/oversized values refuse.
  @doc false
  @spec normalize_compact_bounds(term()) :: {:ok, map()} | {:error, :invalid_compact_bounds}
  def normalize_compact_bounds(bounds) when is_map(bounds) and map_size(bounds) == 3 do
    with {:ok, attempts} <- fetch(bounds, :max_attempts),
         {:ok, deadline} <- fetch(bounds, :deadline_ms),
         {:ok, tokens} <- fetch(bounds, :token_budget),
         true <- is_integer(attempts) and attempts in 1..4,
         true <- is_integer(deadline) and deadline in 1..60_000,
         true <- is_integer(tokens) and tokens in 1..32_768 do
      {:ok, %{"max_attempts" => attempts, "deadline_ms" => deadline, "token_budget" => tokens}}
    else
      _ -> {:error, :invalid_compact_bounds}
    end
  end

  def normalize_compact_bounds(_bounds), do: {:error, :invalid_compact_bounds}

  defp fetch_binary(command, key)
       when key in [:command_id, :run_id, :interaction_id, :choice_id] do
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

  @doc false
  # Concept: harmless admissions cannot replace an open provider authority.
  # Technical depth: Control uses the current closed command grammar on its
  # independently read tail. Accepted content recomputes its exact identity;
  # refused rows retain only the fields their current writers actually emit.
  def provider_attempt_tail_record?(record, run_id, session_id)
      when is_map(record) and not is_struct(record) do
    base = [:kind, "command_id", "command_digest", "command_type", "admission"]
    type = record["command_type"]
    admission = record["admission"]

    identity? =
      is_binary(record["command_id"]) and byte_size(record["command_id"]) > 0 and
        is_binary(record["command_digest"]) and
        Regex.match?(~r/\A[0-9a-f]{64}\z/, record["command_digest"])

    identity? and validate_authored_bounds_record(record) == :ok and
      case Map.get(record, :kind) do
        "command_admitted" when admission == "accepted" and type in ["steer", "follow_up"] ->
          command = %{
            type: if(type == "steer", do: :steer, else: :follow_up),
            command_id: record["command_id"],
            content: record["content"]
          }

          command = if type == "steer", do: Map.put(command, :run_id, run_id), else: command

          command =
            if type == "follow_up" do
              {:ok, authored} =
                decode_retained_authored_bounds(record["authored_bounds"], :follow_up)

              if is_nil(authored), do: command, else: Map.put(command, :bounds, authored)
            else
              command
            end

          validate_authored_bounds_record(record) == :ok and
            closed_history_map?(record, base ++ ["run_id", "content"]) and
            is_binary(run_id) and record["run_id"] == run_id and
            is_binary(record["content"]) and record["content"] != "" and
            command_digest(command) == {:ok, record["command_digest"]}

        "command_admitted" when admission == "rejected_deadline_elapsed" ->
          validate_authored_bounds_record(record) == :ok and
            closed_history_map?(record, base ++ ["admitted_at", "deadline_at_ms"]) and
            type in ["prompt", "follow_up"] and
            match?(
              {:ok, _},
              Bounds.authored(%{deadline_at_ms: record["deadline_at_ms"]}, :follow_up)
            ) and
            is_integer(record["admitted_at"]) and
            record["admitted_at"] >= record["deadline_at_ms"]

        "command_admitted" ->
          (closed_history_map?(record, base) and
             {type, admission} in [
               {"prompt", "rejected_run_active"},
               {"steer", "rejected_run_mismatch"},
               {"steer", "rejected_steer_pending"},
               {"steer", "rejected_no_active_run"},
               {"follow_up", "rejected_follow_up_pending"},
               {"follow_up", "rejected_no_active_run"},
               {"abort", "rejected_no_active_run"},
               {"interaction_answer", "rejected_interaction_absent"},
               {"interaction_answer", "rejected_interaction_resolved"},
               {"interaction_answer", "rejected_invalid_interaction_answer"}
             ]) or
            (closed_history_map?(record, base) and admission == "rejected_maintenance_active" and
               type in ~w(prompt steer follow_up configure compact interaction_answer))

        "command_admission_refused_v1" ->
          closed_history_map?(record, base ++ ["dimension", "candidate", "observed", "limit"]) and
            type in ~w(prompt steer follow_up interaction_answer) and
            admissible_command_kind?(record.kind, record)

        "session_configuration_admitted_v2" ->
          closed_history_map?(
            record,
            base ++ ["changes", "prior_configuration_version", "configuration"]
          ) and
            type == "configure" and admission == "rejected_configuration_not_settled" and
            is_nil(record["configuration"]) and
            is_integer(record["prior_configuration_version"]) and
            record["prior_configuration_version"] > 0 and
            SessionConfiguration.validate_update(record["changes"]) == :ok and
            command_digest(%{
              type: :configure,
              command_id: record["command_id"],
              changes: record["changes"]
            }) == {:ok, record["command_digest"]}

        "compact_command_admitted_v1" ->
          closed_history_map?(record, base ++ ["bounds", "episode_id"]) and
            type == "compact" and admission == "rejected_run_active" and
            normalize_compact_bounds(record["bounds"]) == {:ok, record["bounds"]} and
            record["episode_id"] == stable_id("compact", session_id, record["command_id"]) and
            command_digest(%{
              type: :compact,
              command_id: record["command_id"],
              bounds: record["bounds"]
            }) == {:ok, record["command_digest"]}

        _ ->
          false
      end
  end

  def provider_attempt_tail_record?(_record, _run_id, _session_id), do: false

  defp command_digest(command) do
    revision =
      if command[:type] in [:prompt, :follow_up],
        do: "loopex_command_v2",
        else: "loopex_command_v1"

    bytes = :erlang.term_to_binary([revision, command], [:deterministic])
    {:ok, :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)}
  end

  # Concept: a queued command and its promoted run share one retained identity.
  # Technical depth: the coordinator's transient allowance uses the reducer's
  # existing run derivation, never its distinct runtime-operation ID scheme.
  @doc false
  def command_run_id(session_id, command_id), do: stable_id("run", session_id, command_id)

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
         :ok <- validate_receipt_generation(receipt, request),
         :ok <-
           validate_lineage_projection(
             state,
             request,
             run_id,
             applied_steer,
             record["lineage_projection"]
           ),
         {:ok, sources} <- expected_context_sources(state, receipt, run_id, applied_steer),
         {:ok, expected} <- expected_context_blocks(request, sources),
         true <- Map.get(receipt, "blocks") == expected,
         :ok <- validate_receipt_totals(receipt, expected),
         {:ok, ^record} <- admit_context_candidate(record, state) do
      :ok
    else
      {:error, reason} -> {:error, reason}
      _mismatch -> {:error, :invalid_context_receipt}
    end
  end

  # Concept: a request must use the configuration its run actually admitted.
  # Technical depth: generation, sampling, instruction text, tools and budget
  # are compared with durable truth before receipt arithmetic can admit them.
  defp validate_request_configuration(state, record, request, run_id) do
    case run_configuration(state, run_id) do
      nil ->
        {:error, :invalid_request_configuration}

      configuration ->
        with true <-
               record.kind in [
                 "model_request_committed_v2",
                 "model_request_committed_resources_v2"
               ],
             true <-
               map_size(record) == if(Map.has_key?(record, "lineage_projection"), do: 10, else: 9),
             true <-
               not Map.has_key?(record, "lineage_projection") or
                 is_map(record["lineage_projection"]),
             true <- record["configuration_version"] == configuration["configuration_version"],
             true <- request.canonicalization_version == "loopex.model_request.v2",
             true <- request.model == configuration["model"],
             true <- staged_run_deadline_agrees?(state, run_id, request.deadline),
             true <- request.sampling == SessionConfiguration.sampling(configuration),
             true <- request.tools == state.tool_selection["definitions"],
             {:ok, text} <- Instructions.render(configuration["instructions"]),
             true <- List.first(request.messages) == %{"role" => "system", "content" => text},
             true <- get_in(record, ["context_receipt", "provider_revision"]) == 4,
             true <-
               get_in(record, ["context_receipt", "context_token_budget"]) ==
                 configuration["context_token_budget"] do
          :ok
        else
          _invalid -> {:error, :invalid_request_configuration}
        end
    end
  end

  # Concept: resource receipts bind the immutable resource selection and
  # only the resource bytes actually retained in the staged request.
  #
  # Technical depth: replay derives every resource descriptor from the frozen
  # run selection, closed row identities, and exact UTF-8 request messages. It
  # never consults a manifest, retained pack, filesystem, or network source.
  defp validate_resource_context_receipt(state, record, request, run_id, applied_steer) do
    receipt = Map.get(record, "context_receipt")
    resources = Map.get(state.run_resources, run_id)

    with :ok <- validate_resource_receipt_shell(receipt),
         :ok <- validate_receipt_generation(receipt, request),
         :ok <-
           validate_lineage_projection(
             state,
             request,
             run_id,
             applied_steer,
             record["lineage_projection"]
           ),
         {:ok, resource_sources} <-
           validate_resource_pack_header(
             receipt["resource_packs"],
             resources,
             request,
             state,
             run_id,
             applied_steer,
             length(expected_project_sources(receipt["project_resource"]))
           ),
         {:ok, sources} <-
           expected_resource_context_sources(
             state,
             receipt,
             run_id,
             applied_steer,
             resource_sources
           ),
         {:ok, expected} <- expected_context_blocks(request, sources),
         true <- receipt["blocks"] == expected,
         :ok <- validate_resource_receipt_totals(receipt, expected),
         {:ok, ^record} <- admit_context_candidate(record, state) do
      :ok
    else
      {:error, reason} -> {:error, reason}
      _mismatch -> {:error, :invalid_context_receipt}
    end
  end

  defp validate_resource_receipt_shell(receipt) when is_map(receipt) do
    with true <-
           Enum.sort(Map.keys(receipt)) == @resource_context_receipt_keys,
         true <- receipt["provider_identity"] == "loopex.context.reference",
         true <- receipt["provider_revision"] == 4,
         true <- receipt["transformer_identity"] == nil,
         true <- receipt["transformer_revision"] == nil,
         true <- receipt["selector_identity"] == nil,
         true <- receipt["selector_revision"] == nil,
         true <- receipt["token_estimator"] == "loopex.context_bytes.v2",
         true <-
           receipt["descriptor_canonicalization_version"] ==
             @descriptor_canonicalization_version,
         true <- receipt["context_record_byte_ceiling"] == Store.max_item_bytes(),
         true <- positive_uint64?(receipt["context_token_budget"]),
         :ok <- validate_project_receipt(receipt["project_resource"]) do
      :ok
    else
      {:error, reason} -> {:error, reason}
      _invalid -> {:error, :invalid_context_receipt}
    end
  end

  defp validate_resource_receipt_shell(_receipt), do: {:error, :invalid_context_receipt}

  defp validate_resource_pack_header(
         header,
         resources,
         request,
         state,
         run_id,
         applied_steer,
         project_count
       )
       when is_map(header) and is_map(resources) do
    with true <- Enum.sort(Map.keys(header)) == @resource_pack_header_keys,
         true <- header["version"] == 1,
         true <- resource_digest?(header["manifest_digest"]),
         true <- header["manifest_digest"] == resources["manifest_digest"],
         true <- header["selection_digest"] == resource_selection_digest(resources),
         {:ok, rows} <- bounded_resource_rows(header["blocks"], @resource_pack_max_rows, []),
         {:ok, bytes} <- Store.admit_bounded(header),
         true <- bytes <= @resource_pack_header_bytes,
         {:ok, staged_rows} <-
           validate_resource_header_disposition(header["status"], rows, resources),
         {:ok, messages} <-
           resource_messages(
             request,
             state,
             run_id,
             applied_steer,
             project_count,
             length(staged_rows)
           ),
         true <- length(messages) == length(staged_rows),
         {:ok, sources} <- resource_sources(staged_rows, messages, resources, []) do
      {:ok, sources}
    else
      _invalid -> {:error, :invalid_context_receipt}
    end
  end

  defp validate_resource_pack_header(
         _header,
         _resources,
         _request,
         _state,
         _run_id,
         _steer,
         _project_count
       ),
       do: {:error, :invalid_context_receipt}

  defp bounded_resource_rows([], _remaining, reversed), do: {:ok, Enum.reverse(reversed)}

  defp bounded_resource_rows([row | rows], remaining, reversed) when remaining > 0,
    do: bounded_resource_rows(rows, remaining - 1, [row | reversed])

  defp bounded_resource_rows(_rows, _remaining, _reversed),
    do: {:error, :invalid_context_receipt}

  defp validate_resource_header_disposition(status, rows, resources) do
    decision = resources["decision"]

    cond do
      is_nil(decision) and status == "no_decision" and rows == [] ->
        {:ok, []}

      is_map(decision) and decision["revocation_state"] == "revoked" and status == "revoked" and
          rows == [] ->
        {:ok, []}

      is_map(decision) and decision["revocation_state"] == "active" and
        status in ["binding_changed", "retained_content_missing", "metadata_budget"] and
          rows == [] ->
        {:ok, []}

      is_map(decision) and decision["revocation_state"] == "active" and status == "evaluated" ->
        validate_evaluated_resource_rows(rows, expected_resource_identities(resources), [])

      true ->
        {:error, :invalid_context_receipt}
    end
  end

  defp expected_resource_identities(resources) do
    catalog = [
      %{
        "pack" => @resource_catalog_index,
        "file" => @resource_catalog_index,
        digest: :catalog,
        limit: @resource_catalog_bytes,
        size: nil
      }
    ]

    instructions =
      Enum.map(resources["selections"], fn selection ->
        %{
          "pack" => selection["pack_index"],
          "file" => selection["instruction_file_index"],
          digest: selection["instruction_digest"],
          limit: @resource_instruction_bytes,
          size: nil
        }
      end)

    supporting =
      Enum.flat_map(resources["selections"], fn selection ->
        Enum.map(selection["supporting_files"], fn file ->
          %{
            "pack" => selection["pack_index"],
            "file" => file["file_index"],
            digest: file["digest"],
            limit: @resource_support_bytes,
            size: file["size"]
          }
        end)
      end)

    catalog ++ instructions ++ supporting
  end

  defp validate_evaluated_resource_rows([], [], staged), do: {:ok, Enum.reverse(staged)}

  defp validate_evaluated_resource_rows([row | rows], [identity | identities], staged)
       when is_map(row) do
    status = row["status"]

    with true <- Enum.sort(Map.keys(row)) == @resource_pack_row_keys,
         true <- row["pack"] == identity["pack"] and row["file"] == identity["file"],
         true <- valid_closed_resource_status?(identity, status) do
      staged = if status == "staged", do: [{identity, row} | staged], else: staged
      validate_evaluated_resource_rows(rows, identities, staged)
    else
      _invalid -> {:error, :invalid_context_receipt}
    end
  end

  defp validate_evaluated_resource_rows(_rows, _identities, _staged),
    do: {:error, :invalid_context_receipt}

  defp valid_closed_resource_status?(%{"pack" => 64, "file" => 64}, status),
    do:
      status in [
        "staged",
        "catalog_byte_limit",
        "context_tokens",
        "context_record_depth",
        "context_record_cardinality",
        "context_record_bytes"
      ]

  defp valid_closed_resource_status?(_identity, status),
    do:
      status in [
        "staged",
        "resource_byte_limit",
        "unsupported_text",
        "context_tokens",
        "context_record_depth",
        "context_record_cardinality",
        "context_record_bytes"
      ]

  defp resource_messages(request, state, run_id, applied_steer, project_count, staged_count)
       when is_integer(project_count) and project_count >= 0 and is_integer(staged_count) and
              staged_count >= 0 do
    with {:ok, entries} <-
           request_session_entries(state, run_id),
         steer_count = if(applied_steer, do: 1, else: 0),
         true <-
           length(request.messages) ==
             1 + project_count + staged_count + length(entries) + steer_count do
      {:ok, request.messages |> Enum.drop(1 + project_count) |> Enum.take(staged_count)}
    else
      _invalid -> {:error, :invalid_context_receipt}
    end
  end

  defp resource_messages(
         _request,
         _state,
         _run_id,
         _applied_steer,
         _project_count,
         _staged_count
       ),
       do: {:error, :invalid_context_receipt}

  defp resource_sources([], [], _resources, reversed), do: {:ok, Enum.reverse(reversed)}

  defp resource_sources([{identity, _row} | rows], [message | messages], resources, reversed)
       when is_map(message) do
    content = Map.get(message, "content")
    digest = if is_binary(content), do: Canonical.digest_bytes(content), else: nil
    expected_digest = identity[:digest]
    catalog? = expected_digest == :catalog
    expected_size = identity[:size]

    with true <- map_size(message) == 2,
         true <- message["role"] == "user",
         true <- is_binary(content) and String.valid?(content),
         true <- byte_size(content) <= identity[:limit],
         true <- is_nil(expected_size) or byte_size(content) == expected_size,
         true <- catalog? or digest == expected_digest do
      file_digest = if catalog?, do: digest, else: expected_digest

      source =
        context_source(
          %{
            "kind" => "resource_pack",
            "manifest_digest" => resources["manifest_digest"],
            "pack" => identity["pack"],
            "file" => identity["file"],
            "file_digest" => file_digest
          },
          "resource_pack"
        )

      resource_sources(rows, messages, resources, [source | reversed])
    else
      _invalid -> {:error, :invalid_context_receipt}
    end
  end

  defp resource_sources(_rows, _messages, _resources, _reversed),
    do: {:error, :invalid_context_receipt}

  defp validate_receipt_generation(
         %{"provider_revision" => 4, "continuation_cost" => cost},
         %{canonicalization_version: "loopex.model_request.v2"} = request
       ) do
    case Loopex.Model.Continuation.cost(request.continuation, request.model, request.messages) do
      {:ok, ^cost} -> :ok
      _ -> {:error, :invalid_context_receipt}
    end
  end

  defp validate_receipt_generation(_receipt, _request), do: {:error, :invalid_context_receipt}

  defp request_session_entries(state, run_id) do
    with {:ok, entries} <-
           Conversation.lineage_entries(
             uncompacted_elements(state, lineage_elements(state, run_id))
           ),
         {:ok, checkpoint} <- checkpoint_entries(state) do
      {:ok, checkpoint ++ entries}
    end
  end

  # Concept: every receipt describes exactly the committed lineage.
  # Technical depth: receipt digests cannot admit substituted or omitted history;
  # normalized messages and source bindings are independently reconstructed from
  # the reducer's committed elements before dispatch or replay.
  defp validate_lineage_projection(state, request, run_id, applied_steer, projection) do
    with {:ok, entries} <-
           projected_entries(state, run_id, projection),
         {:ok, steer} <- projected_steer(state, run_id, applied_steer),
         expected = Enum.map(entries, &elem(&1, 1)) ++ steer,
         true <- Enum.take(request.messages, -length(expected)) == expected do
      :ok
    else
      _invalid -> {:error, :invalid_context_receipt}
    end
  end

  defp projected_steer(_state, _run_id, nil), do: {:ok, []}

  defp projected_steer(state, run_id, command_id) do
    case Map.get(state.steer, run_id) do
      %{command_id: ^command_id, content: content} ->
        {:ok, [%{"role" => "user", "content" => content}]}

      _invalid ->
        {:error, :invalid_context_receipt}
    end
  end

  defp validate_receipt_shell(receipt) when is_map(receipt) do
    with true <- Enum.sort(Map.keys(receipt)) == @context_receipt_keys,
         true <- Map.get(receipt, "provider_identity") == "loopex.context.reference",
         true <- Map.get(receipt, "provider_revision") == 4,
         true <- Map.get(receipt, "transformer_identity") == nil,
         true <- Map.get(receipt, "transformer_revision") == nil,
         true <- Map.get(receipt, "selector_identity") == nil,
         true <- Map.get(receipt, "selector_revision") == nil,
         true <- Map.get(receipt, "token_estimator") == "loopex.context_bytes.v2",
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
  # list is still refused. `provider_estimated_tokens` adds the independently
  # verified continuation cost without changing the provenance totals.
  defp validate_receipt_totals(receipt, blocks) do
    totals = expected_context_totals(blocks)

    if Map.get(receipt, "totals") == totals and
         Map.get(receipt, "provider_estimated_tokens") ==
           totals["token_cost"] + continuation_tokens(receipt) and
         Map.get(receipt, "ordered_descriptor_digest") == ordered_descriptor_digest(blocks) do
      :ok
    else
      {:error, :invalid_context_receipt}
    end
  end

  defp continuation_tokens(%{"continuation_cost" => %{"token_cost" => tokens}}), do: tokens
  defp continuation_tokens(_receipt), do: 0

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

    with {:ok, entries} <- request_session_entries(state, run_id) do
      {:ok,
       [context_source(instruction_source(state, run_id), "system")] ++
         expected_project_sources(Map.get(receipt, "project_resource")) ++
         Enum.map(entries, fn {reference, _message} -> context_source(reference, "session") end) ++
         steer}
    end
  end

  defp expected_resource_context_sources(
         state,
         receipt,
         run_id,
         applied_steer,
         resource_sources
       ) do
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

        value when is_nil(value) ->
          []

        _mismatch ->
          :invalid
      end

    if steer == :invalid do
      {:error, :invalid_context_receipt}
    else
      with {:ok, entries} <- request_session_entries(state, run_id) do
        {:ok,
         [context_source(instruction_source(state, run_id), "system")] ++
           expected_project_sources(receipt["project_resource"]) ++
           resource_sources ++
           Enum.map(entries, fn {reference, _message} -> context_source(reference, "session") end) ++
           steer}
      end
    end
  end

  defp instruction_source(state, run_id),
    do: SessionConfiguration.instruction_source(run_configuration(state, run_id))

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
        "resource_pack" -> "untrusted_behavior_shaping_data"
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

  defp validate_resource_receipt_totals(receipt, blocks) do
    totals = expected_resource_context_totals(blocks)

    if receipt["totals"] == totals and
         receipt["provider_estimated_tokens"] ==
           totals["token_cost"] + continuation_tokens(receipt) and
         receipt["ordered_descriptor_digest"] == ordered_descriptor_digest(blocks) do
      :ok
    else
      {:error, :invalid_context_receipt}
    end
  end

  defp expected_resource_context_totals(blocks) do
    by_provenance =
      Map.new(~w(system session project_resource resource_pack), fn provenance ->
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

  @doc """
  ## Concept

  Check whether this run's captured renderer supports its retained terminal
  history before opening a provider attempt.

  ## Technical depth

  Uses complete lineage through the run and excludes the active run from the
  terminal-history capability requirement. Runs use only captured mapping facts
  and perform no catalog lookup, compaction or dispatch. A missing capture is
  invalid configuration.
  """
  @spec preflight_run_history(t(), binary()) :: :ok | {:error, atom()}
  def preflight_run_history(%__MODULE__{} = state, run_id) do
    case run_configuration(state, run_id) do
      nil ->
        {:error, :invalid_session_configuration}

      configuration ->
        with :ok <-
               SessionConfiguration.preflight_history(
                 configuration,
                 uncompacted_elements(state, lineage_elements(state, run_id)),
                 Enum.reject(state.run_order, &(&1 == run_id))
               ),
             {:ok, _, _} <- projected_lineage(state, run_id, 0),
             {:ok, _} <- preparation_sources(state, run_id),
             :ok <- preflight_continuation(state, run_id) do
          retained_preparation_failure(state, run_id)
        end
    end
  end

  defp retained_preparation_failure(state, run_id) do
    case preparation_identity(state, run_id) do
      {:ok, identity} ->
        case state.artifact_preparations[identity["episode_id"]] do
          %{"status" => "failed"} = episode ->
            {:ok, cause} = ArtifactPreparation.failure_cause(episode)
            {:error, cause}

          _ ->
            :ok
        end

      _ ->
        :ok
    end
  end

  # Concept: an unexpandable frozen exchange fails before request construction.
  # Technical depth: rebuild from retained sources only, so replay proves the
  # same unavailable projection without a provider, project file or catalog.
  # Numeric admission remains a separate measurement of a complete projection.
  defp preflight_continuation(state, run_id) do
    case get_in(state.pending_work, [run_id, :continuation_exchange]) do
      nil ->
        :ok

      %{base_request: request, base_receipt: receipt} ->
        prefix =
          request.messages
          |> Enum.zip(receipt["blocks"])
          |> Enum.take_while(fn {_message, block} -> block["provenance_class"] != "session" end)
          |> Enum.map(&elem(&1, 0))

        steer = pending_steer(state, run_id)
        applied = steer && steer.command_id

        with {:ok, entries, projection} <- projected_lineage(state, run_id, 2_048),
             {:ok, suffix} <- projected_steer(state, run_id, applied),
             {:ok, _} <-
               model_continuation(
                 state,
                 run_id,
                 prefix ++ Enum.map(entries, &elem(&1, 1)) ++ suffix,
                 applied,
                 projection
               ) do
          :ok
        else
          _ -> {:error, :context_projection_invalid}
        end
    end
  end

  @doc false
  @spec propose_context_preparation_failure(t(), binary(), atom()) ::
          {:ok, proposal()} | {:error, term()}
  # Concept: a condition found before request construction ends the run without
  # inventing a budget observation.
  # Technical depth: the unavailable v2 projection retains captured limits and
  # configuration, null measurements and the exact cause. The refusal and failed
  # terminal commit together; replay independently derives the same condition.
  def propose_context_preparation_failure(%__MODULE__{} = state, run_id, cause)
      when cause in [
             :canonical_history_rendering_unsupported,
             :context_projection_invalid,
             :artifact_metadata_unrepresentable,
             :artifact_preparation_count_exhausted,
             :artifact_preparation_bytes_exhausted,
             :artifact_preparation_deadline,
             :artifact_preparation_failed,
             :maintenance_summary_invalid,
             :maintenance_summary_incomplete,
             :maintenance_reply_reserve_unavailable,
             :maintenance_model_unconfigured,
             :maintenance_instructions_unconfigured,
             :maintenance_reasoning_unsupported,
             :maintenance_deadline_unrepresentable
           ] do
    case {run_configuration(state, run_id), Map.get(state.pending_work, run_id)} do
      {%{} = configuration, %{stage: stage, turn_number: _} = work}
      when stage in ["model_pending", "turn_settled"] ->
        turn = next_turn_number(work)

        refusal =
          unavailable_context_refusal(state, run_id, configuration, turn, Atom.to_string(cause))

        propose_context_refusal(state, run_id, refusal)

      _ ->
        {:error, :invalid_context_refusal}
    end
  end

  def propose_context_preparation_failure(_, _, _), do: {:error, :invalid_context_refusal}

  @doc false
  @spec propose_maintenance_preparation_expiry(t(), binary(), integer()) ::
          {:ok, proposal()} | {:error, atom()}
  # Concept: downtime cannot renew a maintenance preparation allowance.
  # Technical depth: the retained admission cutoff governs only pre-first-request
  # source preparation. An earlier or equal committed run cutoff wins with its
  # existing bound outcome. The leading terminal retains the exact unsigned
  # clock observation; replay proves expiry without reading a new clock.
  def propose_maintenance_preparation_expiry(state, run_id, now) do
    with true <- is_integer(now) and now >= 0 and now <= 18_446_744_073_709_551_615,
         nil <- state.aborting,
         %{"run_id" => ^run_id, "stage" => "source_preparation", "attempts" => 0} = episode <-
           Map.get(state.maintenance_episodes, state.active_maintenance),
         %{stage: stage} = work <- Map.get(state.pending_work, run_id),
         true <- stage in ["model_pending", "turn_settled"],
         %{} = configuration <- run_configuration(state, run_id) do
      deadline = retained_run_deadline(state, run_id)

      cond do
        is_integer(deadline) and deadline <= episode["preparation_deadline"] and now >= deadline ->
          {_bounds, charged} = accounting(state, run_id)

          terminal =
            run_terminal_record(state, run_id, "bound_reached", %{
              bound: "deadline",
              observed: now,
              declared_limit: deadline,
              accounting_source: charged.source && Atom.to_string(charged.source)
            })

          build_internal_proposal(state, episode["episode_id"] <> ":expiry", [terminal], now)

        now >= episode["preparation_deadline"] ->
          refusal =
            unavailable_context_refusal(
              state,
              run_id,
              configuration,
              next_turn_number(work),
              "compaction_preparation_deadline"
            )

          terminal =
            state
            |> run_terminal_record(run_id, "failed", %{})
            |> Map.put("failure", context_failure(refusal))

          build_internal_proposal(
            state,
            episode["episode_id"] <> ":expiry",
            [refusal, terminal],
            now
          )

        true ->
          {:error, :maintenance_preparation_not_elapsed}
      end
    else
      _ -> {:error, :invalid_maintenance_episode_transition}
    end
  end

  defp unavailable_context_refusal(state, run_id, configuration, turn, cause) do
    %{
      "run_id" => run_id,
      "turn_id" => stable_id("turn", run_id, turn),
      "failure" => %{
        "version" => 2,
        "category" => "context_preparation_failed",
        "retryable" => false,
        "measurement_scope" => nil,
        "cause" => cause
      },
      "token_estimator" => "loopex.context_bytes.v2",
      "descriptor_canonicalization_version" => @descriptor_canonicalization_version,
      "project_disposition" => "not_evaluated_required_failure",
      "system_message_count" => nil,
      "session_message_count" => nil,
      "steer_message_count" => nil,
      "tool_definition_count" => nil,
      "provider_estimated_tokens" => nil,
      "context_token_budget" => configuration["context_token_budget"],
      "record_byte_cost" => nil,
      "context_record_byte_ceiling" => Store.max_item_bytes(),
      "ordered_descriptor_digest" => nil,
      "configuration_version" => configuration["configuration_version"],
      "episode_id" => state.active_maintenance,
      "targets" => request_headroom_targets(state, run_id),
      "projection_state" => "unavailable",
      "measurement_scope" => nil,
      :kind => "context_admission_refused_v2"
    }
  end

  defp deadline_failure,
    do: %{"category" => "deadline_preflight_failed", "retryable" => false}

  # Concept: terminal failures retain the same observations as their refusal.
  # Technical depth: the current closed failure object is copied unchanged into
  # private terminal and public event, including its measurement scope.
  defp context_failure(%{"failure" => failure, kind: "context_admission_refused_v2"}), do: failure

  # Concept: a summary refusal is proved by the preceding canonical settlement.
  # Technical depth: its usage already settled once. The v2 refusal and episode
  # terminal reuse that retained verdict without another provider settlement.
  defp validate_preparation_failure_cause(state, run_id, expected)
       when expected in ["maintenance_summary_invalid", "maintenance_summary_incomplete"] do
    with %{
           "run_id" => ^run_id,
           "stage" => "checkpoint_pending",
           "summary_failure" => ^expected,
           "settlement" => record
         } <- state.maintenance_episodes[state.active_maintenance],
         true <- is_nil(state.aborting),
         {:error, cause} <- maintenance_summary(record),
         true <- Atom.to_string(cause) == expected do
      :ok
    else
      _ -> {:error, :invalid_context_refusal}
    end
  end

  # Concept: insufficient summary reservation retains the actual unspent balance.
  # Technical depth: derive both remaining capacity and turn precedence from the
  # committed run ledger. Only an undispatched run-owned episode can refuse;
  # a caller-supplied cause cannot end a different owner or an open attempt.
  defp validate_preparation_failure_cause(state, run_id, "maintenance_reply_reserve_unavailable") do
    {bounds, charged} = accounting(state, run_id)

    with true <- run_id == state.active_run_id,
         nil <- state.aborting,
         %{"run_id" => ^run_id, "stage" => stage, kind: "maintenance_episode_admitted_v1"} <-
           state.maintenance_episodes[state.active_maintenance],
         true <-
           stage in ~w(source_preparation checkpoint_committed model_retry_permitted),
         true <-
           stage != "checkpoint_committed" or
             match?(
               {:error, {:checkpoint_requires_more_progress, _}},
               maintenance_checkpoint_completion_record(
                 state,
                 state.checkpoints[state.active_checkpoint]["committed_at"],
                 fn -> :ok end
               )
             ),
         true <- is_map(bounds),
         remaining = bounds.token_budget - charged.tokens,
         true <- remaining > 0 and remaining < 1_024,
         true <- maintenance_parent_call_units(state, run_id) < bounds.max_turns do
      :ok
    else
      _ -> {:error, :invalid_context_refusal}
    end
  end

  defp validate_preparation_failure_cause(state, run_id, "compaction_preparation_deadline") do
    with %{observed_at: now} <- state.maintenance_terminal,
         true <- run_id == state.active_run_id,
         true <-
           valid_maintenance_ending_clock?(
             state,
             %{
               "outcome" => "failed",
               "failure" => %{"cause" => "compaction_preparation_deadline"}
             },
             now
           ) do
      :ok
    else
      _ -> {:error, :invalid_context_refusal}
    end
  end

  defp validate_preparation_failure_cause(state, run_id, "compaction_excerpt_budget_too_small") do
    with %{observed_at: now} <- state.maintenance_terminal,
         true <- run_id == state.active_run_id,
         {:error, :compaction_excerpt_budget_too_small} <-
           selected_maintenance_source_result(state, now, fn -> :ok end) do
      :ok
    else
      _ -> {:error, :invalid_context_refusal}
    end
  end

  defp validate_preparation_failure_cause(
         %{maintenance_terminal: %{observed_at: observed}} = state,
         run_id,
         "context_projection_invalid"
       )
       when is_integer(observed) do
    with {:ok, episode} <- maintenance_source_episode(state, observed, fn -> :ok end),
         true <- episode["run_id"] == run_id do
      :ok
    else
      _ -> {:error, :invalid_context_refusal}
    end
  end

  # Concept: host startup settings and the admission clock are observed before
  # an episode exists; the retained closed cause is the durable refusal fact.
  # Technical depth: replay can prove the run was still eligible for admission,
  # but cannot reread the predecessor host's settings or clock. The owner is the
  # only writer of this pre-intent record, and no provider dispatch can precede it.
  defp validate_preparation_failure_cause(state, run_id, expected)
       when expected in [
              "maintenance_model_unconfigured",
              "maintenance_instructions_unconfigured",
              "maintenance_reasoning_unsupported",
              "maintenance_deadline_unrepresentable"
            ] do
    case maintenance_admission_context(state, run_id) do
      {:ok, _, _} when is_nil(state.active_maintenance) -> :ok
      _ -> {:error, :invalid_context_refusal}
    end
  end

  defp validate_preparation_failure_cause(state, run_id, expected) do
    case preflight_run_history(state, run_id) do
      {:error, cause}
      when cause in [
             :canonical_history_rendering_unsupported,
             :context_projection_invalid,
             :artifact_metadata_unrepresentable,
             :artifact_preparation_count_exhausted,
             :artifact_preparation_bytes_exhausted,
             :artifact_preparation_deadline,
             :artifact_preparation_failed
           ] ->
        if expected == Atom.to_string(cause), do: :ok, else: {:error, :invalid_context_refusal}

      _ ->
        {:error, :invalid_context_refusal}
    end
  end

  defp validate_context_refusal(
         state,
         %{
           :kind => "context_admission_refused_v2",
           "failure" => %{"cause" => "compaction_no_progress"}
         } = refusal
       ) do
    with %{observed_at: now} <- state.maintenance_terminal,
         {:ok, expected} <- maintenance_nonprogress_refusal(state, now, fn -> :ok end),
         true <- refusal == expected do
      :ok
    else
      _ -> {:error, :invalid_context_refusal}
    end
  end

  defp validate_context_refusal(
         state,
         %{
           "failure" => %{"category" => "context_preparation_failed"} = failure,
           :kind => "context_admission_refused_v2"
         } = refusal
       ) do
    run_id = refusal["run_id"]
    configuration = run_configuration(state, run_id)

    with true <- Enum.sort(Map.keys(refusal)) == @context_refusal_v2_keys,
         true <-
           Enum.sort(Map.keys(failure)) ==
             Enum.sort(~w(version category retryable measurement_scope cause)),
         true <- failure["version"] == 2 and failure["retryable"] == false,
         true <- is_nil(failure["measurement_scope"]),
         true <- run_id == state.active_run_id,
         %{stage: stage} = work <- Map.get(state.pending_work, run_id),
         true <- stage in ["model_pending", "turn_settled"],
         true <- refusal["turn_id"] == stable_id("turn", run_id, next_turn_number(work)),
         true <- is_map(configuration),
         true <- refusal["configuration_version"] == configuration["configuration_version"],
         true <- refusal["context_token_budget"] == configuration["context_token_budget"],
         true <- refusal["context_record_byte_ceiling"] == Store.max_item_bytes(),
         true <- refusal["token_estimator"] == "loopex.context_bytes.v2",
         true <-
           refusal["descriptor_canonicalization_version"] == @descriptor_canonicalization_version,
         true <- refusal["project_disposition"] == "not_evaluated_required_failure",
         true <- refusal["projection_state"] == "unavailable",
         true <-
           Enum.all?(
             ~w(measurement_scope system_message_count
                   session_message_count steer_message_count tool_definition_count
                   provider_estimated_tokens record_byte_cost ordered_descriptor_digest),
             &is_nil(refusal[&1])
           ),
         true <- refusal["episode_id"] == state.active_maintenance,
         true <- refusal["targets"] == request_headroom_targets(state, run_id),
         :ok <- validate_preparation_failure_cause(state, run_id, failure["cause"]) do
      :ok
    else
      _invalid -> {:error, :invalid_context_refusal}
    end
  end

  defp validate_context_refusal(
         state,
         %{
           :kind => "context_admission_refused_v2",
           "episode_id" => episode,
           "failure" => %{"category" => category}
         } = refusal
       )
       when is_binary(episode) and
              category in ["context_budget_exceeded", "thinking_exchange_headroom"] do
    with %{observed_at: now} <- state.maintenance_terminal,
         %{"bounds" => %{} = bounds} = current <-
           state.maintenance_episodes[state.active_maintenance],
         {:ok, expected} <-
           if(current["attempts"] == bounds["max_attempts"],
             do: maintenance_exhaustion_refusal(state, now, fn -> :ok end),
             else: maintenance_source_numeric_refusal(state, now, fn -> :ok end)
           ),
         true <- refusal == expected do
      :ok
    else
      _ -> {:error, :invalid_context_refusal}
    end
  end

  defp validate_context_refusal(state, %{kind: "context_admission_refused_v2"} = refusal) do
    run_id = refusal["run_id"]
    configuration = run_configuration(state, run_id)
    failure = refusal["failure"]

    with true <-
           Enum.sort(Map.keys(refusal)) in [
             @context_refusal_v2_keys,
             @context_refusal_v2_frozen_keys
           ],
         true <- valid_v2_descriptor_counts?(refusal),
         true <- is_map(configuration),
         true <- refusal["configuration_version"] == configuration["configuration_version"],
         true <- is_nil(state.active_maintenance),
         true <- is_nil(refusal["episode_id"]),
         true <-
           refusal["projection_state"] == "measured" and
             refusal["measurement_scope"] == "ordinary",
         true <- refusal["token_estimator"] == "loopex.context_bytes.v2",
         true <-
           is_map(failure) and
             Enum.sort(Map.keys(failure)) ==
               Enum.sort(
                 ~w(version category retryable measurement_scope dimension observed limit hard_limit)
               ),
         true <-
           failure["version"] == 2 and failure["retryable"] == false and
             failure["measurement_scope"] == "ordinary",
         true <- failure["category"] in ["context_budget_exceeded", "thinking_exchange_headroom"],
         true <-
           is_integer(failure["observed"]) and failure["observed"] >= 0 and
             failure["observed"] <= @uint64_max,
         true <- positive_uint64?(failure["limit"]) and positive_uint64?(failure["hard_limit"]),
         :ok <- validate_ordinary_v2_relations(state, refusal, configuration, failure) do
      :ok
    else
      _invalid -> {:error, :invalid_context_refusal}
    end
  end

  defp validate_context_refusal(_state, _refusal), do: {:error, :invalid_context_refusal}

  defp validate_ordinary_v2_relations(state, refusal, configuration, failure) do
    common =
      refusal
      |> Map.drop(
        ~w(failure configuration_version episode_id targets projection_state measurement_scope) ++
          @context_refusal_optional_counts
      )
      |> Map.merge(Map.take(failure, ~w(category dimension observed limit)))
      |> Map.update!("project_disposition", fn
        "staged" -> "not_evaluated_required_failure"
        disposition -> disposition
      end)

    case failure["category"] do
      "context_budget_exceeded" ->
        if is_nil(refusal["targets"]) and failure["hard_limit"] == failure["limit"],
          do:
            validate_context_refusal_base(
              state,
              common,
              configuration["system_class_tokens"],
              "loopex.context_bytes.v2"
            ),
          else: {:error, :invalid_context_refusal}

      "thinking_exchange_headroom" ->
        targets = request_headroom_targets(state, refusal["run_id"])

        hard_limit =
          if failure["dimension"] == "context_tokens",
            do: configuration["context_token_budget"],
            else: Store.max_item_bytes()

        if is_map(targets) and refusal["targets"] == targets and
             failure["hard_limit"] == hard_limit,
           do:
             validate_context_refusal_base(
               state,
               common,
               configuration["system_class_tokens"],
               "loopex.context_bytes.v2",
               targets
             ),
           else: {:error, :invalid_context_refusal}
    end
  end

  # Concept: Frozen optional inputs stay visible in a compact measured refusal.
  # Technical depth: The pair is present together only when at least one optional
  # descriptor exists. Required-only and unavailable current shapes stay exact.
  # The Store protects committed observations; replay validates their bounds and
  # relations without inventing a missing descriptor preimage.
  defp valid_v2_descriptor_counts?(refusal) do
    required =
      ~w(system_message_count session_message_count steer_message_count tool_definition_count)

    counts = required ++ @context_refusal_optional_counts

    cond do
      Enum.all?(@context_refusal_optional_counts, &(not Map.has_key?(refusal, &1))) ->
        refusal["project_disposition"] != "staged"

      true ->
        staged? = refusal["project_disposition"] == "staged"
        project? = refusal["project_resource_count"] > 0

        Enum.all?(counts, &nonnegative_uint64?(refusal[&1])) and
          Enum.sum(Enum.map(counts, &refusal[&1])) <= @uint64_max and
          refusal["project_resource_count"] + refusal["resource_pack_count"] > 0 and
          staged? == project?
    end
  end

  defp nonnegative_uint64?(value),
    do: is_integer(value) and value >= 0 and value <= @uint64_max

  defp validate_context_refusal_base(state, refusal, system_limit, estimator, targets \\ nil) do
    run_id = Map.get(refusal, "run_id")
    work = Map.get(state.pending_work, run_id)

    with true <- Enum.sort(Map.keys(refusal)) == @context_refusal_keys,
         true <- run_id == state.active_run_id,
         %{stage: stage} <- work,
         true <- stage in ["model_pending", "turn_settled"],
         true <- Map.get(refusal, "turn_id") == stable_id("turn", run_id, next_turn_number(work)),
         true <-
           Map.get(refusal, "category") ==
             if(is_nil(targets),
               do: "context_budget_exceeded",
               else: "thinking_exchange_headroom"
             ),
         true <- Map.get(refusal, "token_estimator") == estimator,
         true <-
           Map.get(refusal, "descriptor_canonicalization_version") ==
             @descriptor_canonicalization_version,
         true <- Map.get(refusal, "context_record_byte_ceiling") == Store.max_item_bytes(),
         true <-
           Map.get(refusal, "context_token_budget") == Map.get(state.context_budgets, run_id),
         true <- Map.get(refusal, "project_disposition") in @context_project_dispositions,
         true <- valid_descriptor_counts?(refusal),
         true <- valid_context_relation?(refusal, system_limit, targets) do
      :ok
    else
      _invalid -> {:error, :invalid_context_refusal}
    end
  end

  defp valid_context_relation?(refusal, system_limit, nil),
    do: valid_context_dimension?(refusal, system_limit)

  defp valid_context_relation?(refusal, _system_limit, targets) do
    observed = refusal["observed"]
    limit = refusal["limit"]
    estimated = refusal["provider_estimated_tokens"]

    case refusal["dimension"] do
      "context_tokens" ->
        observed == estimated and limit == targets["input_target"] and
          observed > limit and observed <= refusal["context_token_budget"] and
          is_nil(refusal["record_byte_cost"])

      "context_record_bytes" ->
        observed == refusal["record_byte_cost"] and limit == targets["record_target"] and
          observed > limit and observed <= Store.max_item_bytes() and
          estimated <= targets["input_target"]

      _ ->
        false
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
  defp valid_context_dimension?(
         %{
           "dimension" => "context_tokens",
           "observed" => observed,
           "limit" => limit,
           "provider_estimated_tokens" => estimated,
           "context_token_budget" => budget,
           "record_byte_cost" => nil
         },
         _system_limit
       ),
       do: observed == estimated and limit == budget and observed > limit

  defp valid_context_dimension?(
         %{
           "dimension" => "context_record_bytes",
           "observed" => observed,
           "limit" => limit,
           "record_byte_cost" => cost
         },
         _system_limit
       ),
       do: observed == cost and limit == 65_536 and observed > limit

  defp valid_context_dimension?(
         %{
           "dimension" => "context_record_depth",
           "observed" => observed,
           "limit" => limit,
           "record_byte_cost" => nil
         },
         _system_limit
       ),
       do: observed == 13 and limit == 12

  defp valid_context_dimension?(
         %{
           "dimension" => "context_record_cardinality",
           "observed" => observed,
           "limit" => limit,
           "record_byte_cost" => nil
         },
         _system_limit
       ),
       do: observed == 1_025 and limit == 1_024

  defp valid_context_dimension?(
         %{
           "dimension" => "system_class_tokens",
           "observed" => observed,
           "limit" => limit,
           "provider_estimated_tokens" => estimated,
           "record_byte_cost" => nil
         },
         system_limit
       ),
       do: limit == system_limit and observed >= limit and observed <= estimated

  defp valid_context_dimension?(_refusal, _system_limit), do: false

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
    build_proposal(state, command.command_id, retain_authored_bounds(record, command), [], reply)
  end

  defp retain_tool_result_source(state, result, record, bytes, job) do
    source = %{
      "kind" => "session_tool_result",
      "run_id" => result.run_id,
      "turn" => result.turn_number,
      "call_id" => result.tool_call_id
    }

    original = %{
      source_reference: source,
      record_digest: Canonical.digest(record),
      record_byte_cost: bytes,
      journal_version: state.journal_version + 1,
      metadata: %{
        "session_id" => state.session_id,
        "run_id" => job.run_id,
        "operation_id" => job.operation_id,
        "attempt" => job.attempt,
        "tool_call_id" => job.tool_call_id
      }
    }

    %{state | tool_result_sources: Map.put(state.tool_result_sources, source, original)}
  end
end
