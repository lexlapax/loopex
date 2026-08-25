defmodule Loopex.Runtime.SessionCoordinator do
  @moduledoc """
  ## Concept

  The sole serial Store-backed owner of one live M1 session. It recovers durable
  state, commits a fresh owner succession before admission opens, reduces one
  command at a time, and retains the session's mutation-ambiguity lane.

  ## Technical depth

  A coordinator is an unnamed temporary DynamicSupervisor child. Startup uses
  transaction status, the non-authorizing ownership head, and one fresh
  compare-and-set succession. Each command is proposed by the pure
  `Loopex.Runtime.SessionState`, committed through `Store.OwnerLane`, and then
  offered to runtime control. Only runtime control may install the current
  cache or expose pending work. Public delivery independently scans the Store
  outbox and never depends on the mutation reply.

  A delayed reply may truthfully report that the old Store transaction
  committed. The coordinator does not adopt proposed state until runtime
  control's central post-commit fence admits its exact generation and owner
  pair. Store handles, owner-incarnation capabilities, command content, and
  reducer state are redacted from OTP status reports.
  """

  use GenServer

  alias Loopex.Bounds
  alias Loopex.Conversation
  alias Loopex.Runtime.Control
  alias Loopex.Runtime.SessionState
  alias Loopex.Executor
  alias Loopex.Model
  alias Loopex.Policy
  alias Loopex.ProjectResource
  alias Loopex.StreamDomain
  alias LoopexProtocol.ToolDefinition
  alias Loopex.Store
  alias Loopex.Store.OwnerLane

  @mutation_domain "session"
  @page_size 1_024
  @owner_retry_ms 25
  @max_historical_attempts 1_024
  @recovery_contract "loopex-executor-recovery-v1"
  @reconciliation_fields [
    :reconciliation_query_id,
    :current_session_epoch,
    :expected_executor_identity,
    :current_recovery_contract,
    :journaled_operation_id,
    :original_attempt,
    :journaled_canonical_request_digest,
    :original_session_epoch,
    :original_executor_epoch,
    :origin_executor_identity,
    :origin_fencing_token
  ]

  @typedoc """
  ## Concept

  The current owner identity runtime control uses for routing and consequences.

  ## Technical depth

  The generation is runtime-local. Epoch and incarnation are Store-bound; the
  incarnation remains private and never enters public events, snapshots,
  progress, or diagnostics.
  """
  @type owner :: %{
          required(:generation) => binary(),
          required(:owner_epoch) => non_neg_integer(),
          required(:owner_incarnation_id) => binary(),
          required(:transaction_id) => binary()
        }

  @doc """
  ## Concept

  Starts one candidate session owner and completes durable succession before
  returning a pid.

  ## Technical depth

  Options are supplied only by explicit runtime control. The child is
  temporary: a crashed or superseded coordinator is never restarted with its
  old owner incarnation; recovery creates a fresh candidate instead.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options) when is_list(options), do: GenServer.start_link(__MODULE__, options)

  @doc false
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(options) do
    %{
      id: {__MODULE__, Keyword.fetch!(options, :generation)},
      start: {__MODULE__, :start_link, [options]},
      restart: :temporary,
      shutdown: 5_000,
      type: :worker
    }
  end

  @doc false
  @spec describe(pid()) :: {:ok, owner(), SessionState.t()} | {:error, term()}
  def describe(coordinator) when is_pid(coordinator) do
    safe_call(coordinator, :describe)
  end

  @doc false
  @spec command(pid(), owner(), map()) :: {:accepted, binary()} | {:error, term()}
  def command(coordinator, owner, command)
      when is_pid(coordinator) and is_map(owner) and is_map(command) do
    safe_call(coordinator, {:command, owner, command}, :infinity)
  end

  @doc false
  @spec session_status(pid(), owner()) :: {:ok, map()} | {:error, term()}
  def session_status(coordinator, owner) when is_pid(coordinator) and is_map(owner) do
    safe_call(coordinator, {:session_status, owner})
  end

  @doc false
  @spec reconciliation_fields() :: [atom()]
  def reconciliation_fields, do: @reconciliation_fields

  @doc false
  @spec reconciliation_query(pid(), owner()) :: {:ok, map()} | {:error, term()}
  def reconciliation_query(coordinator, owner) when is_pid(coordinator) and is_map(owner),
    do: safe_call(coordinator, {:reconciliation_query, owner})

  @doc false
  @spec reconcile(pid(), owner(), map()) :: :ok | {:error, term()}
  def reconcile(coordinator, owner, response)
      when is_pid(coordinator) and is_map(owner) and is_map(response),
      do: safe_call(coordinator, {:reconcile, owner, response}, :infinity)

  @impl GenServer
  def init(options) do
    {:ok,
     %{
       phase: :discovering,
       control: Keyword.fetch!(options, :control),
       store: Keyword.fetch!(options, :store),
       session_id: Keyword.fetch!(options, :session_id),
       generation: Keyword.fetch!(options, :generation),
       succession_id: Keyword.fetch!(options, :succession_id),
       prior_tx_id: Keyword.get(options, :prior_tx_id),
       attempt: 1,
       transaction: nil,
       incarnation: nil,
       lane: OwnerLane.new(Keyword.fetch!(options, :store)),
       workers: Keyword.fetch!(options, :workers),
       model: Keyword.fetch!(options, :model),
       executor: Keyword.fetch!(options, :executor),
       tool: Keyword.fetch!(options, :tool),
       active_tools: Keyword.get(options, :active_tools, []),
       progress_to: Keyword.get(options, :progress_to),
       diagnostics_to: Keyword.get(options, :diagnostics_to),
       bounds: Keyword.get(options, :bounds),
       policy: Keyword.get(options, :policy),
       project_manifest: Keyword.get(options, :project_manifest),
       project_decision: Keyword.get(options, :project_decision),
       sampling: Keyword.get(options, :sampling),
       grant_decision: Keyword.fetch!(options, :grant_decision),
       fault_to: Keyword.fetch!(options, :fault_to),
       in_flight: %{},
       streams: %{},
       cleanup: %{},
       pending_fault: nil,
       query: nil,
       owner: nil,
       durable: nil,
       superseded: false
     }, {:continue, :acquire_owner}}
  end

  @impl GenServer
  def handle_continue(:acquire_owner, state), do: advance_acquisition(state)

  @impl GenServer
  def handle_call(:describe, _from, state) do
    case state.phase do
      :ready -> {:reply, {:ok, state.owner, state.durable}, state}
      _other -> {:reply, {:error, :owner_acquiring}, state}
    end
  end

  def handle_call({:command, supplied_owner, command}, _from, state) do
    cond do
      state.phase != :ready ->
        {:reply, {:error, :owner_acquiring}, state}

      supplied_owner != state.owner ->
        {:reply, {:error, :superseded_owner}, state}

      state.superseded ->
        {:reply, {:error, :superseded_owner}, state}

      not Control.current_owner?(state.control, state.session_id, state.owner) ->
        {:reply, {:error, :superseded_owner}, %{state | superseded: true}}

      true ->
        commit_command(state, command)
    end
  end

  def handle_call({:session_status, supplied_owner}, _from, state) do
    if state.phase == :ready and supplied_owner == state.owner and not state.superseded do
      status = %{
        status: :active,
        owner_epoch: state.owner.owner_epoch,
        journal_version: state.durable.journal_version,
        event_sequence: state.durable.event_sequence,
        active_run_id: state.durable.active_run_id,
        pending_work_ids:
          Enum.map(SessionState.pending_work(state.durable), &Map.fetch!(&1, :run_id))
      }

      {:reply, {:ok, status}, state}
    else
      {:reply, {:error, :session_unavailable}, state}
    end
  end

  def handle_call({:reconciliation_query, supplied_owner}, _from, state) do
    with :ok <- ready_current?(state, supplied_owner),
         {:ok, work} <- pending_effect(state),
         true <- map_size(state.in_flight) == 0 do
      query_id =
        stable_id(
          "reconciliation-query",
          state.owner.generation,
          System.unique_integer([:positive])
        )

      query = reconciliation_query_data(query_id, state.owner, work.job)
      {:reply, {:ok, query}, %{state | query: %{data: query, run_id: work.run_id, job: work.job}}}
    else
      false -> {:reply, {:error, :effect_in_flight}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:reconcile, supplied_owner, response}, _from, state) do
    with :ok <- ready_current?(state, supplied_owner),
         %{data: query, run_id: run_id, job: job} <- state.query,
         :ok <- validate_reconciliation_response(response, query, job),
         {:ok, proposal} <- reconciliation_proposal(state.durable, run_id, response, query),
         {:ok, next} <- commit_internal(state, proposal) do
      send(self(), :advance_work)
      {:reply, :ok, %{next | query: nil}}
    else
      nil -> {:reply, {:error, :reconciliation_not_solicited}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl GenServer
  def handle_cast({:superseded, generation}, state) do
    superseded = is_map(state.owner) and generation != state.owner.generation
    {:noreply, %{state | superseded: superseded or state.superseded}}
  end

  @impl GenServer
  def handle_info(:retry_owner, %{phase: phase} = state)
      when phase in [:discovering, :acquiring, :recovering] do
    advance_acquisition(state)
  end

  def handle_info(:advance_work, state), do: advance_work(state)

  def handle_info({reference, result}, state) when is_reference(reference) do
    case Map.pop(state.in_flight, reference) do
      {nil, _remaining} ->
        {:noreply, state}

      {{:model, run_id, _pid}, remaining} ->
        Process.demonitor(reference, [:flush])
        dispatch_result(%{state | in_flight: remaining}, :model, run_id, result)

      {{:executor, run_id, _pid}, remaining} ->
        Process.demonitor(reference, [:flush])
        dispatch_result(%{state | in_flight: remaining}, :executor, run_id, result)
    end
  end

  def handle_info({:DOWN, reference, :process, _pid, reason}, state) do
    case Map.pop(state.in_flight, reference) do
      {nil, _remaining} -> {:noreply, state}
      {_work, remaining} -> {:stop, {:worker_failed, reason}, %{state | in_flight: remaining}}
    end
  end

  def handle_info(
        {:continue_fault, reference},
        %{pending_fault: %{reference: reference} = fault} = state
      ) do
    commit_executor_fact(%{state | pending_fault: nil}, fault.run_id, fault.receipt)
  end

  def handle_info({:continue_fault, _stale_reference}, state), do: {:noreply, state}

  @impl GenServer
  def format_status(status) do
    status
    |> Map.put(:state, :redacted_session_coordinator_state)
    |> Map.put(:message, :redacted_session_coordinator_message)
    |> Map.put(:reason, :redacted_session_coordinator_reason)
    |> Map.put(:log, [])
  end

  defp advance_acquisition(%{phase: :recovering} = state), do: recover_committed_owner(state)

  defp advance_acquisition(%{phase: :discovering} = state), do: discover_and_advance(state)
  defp advance_acquisition(%{phase: :acquiring} = state), do: transact_owner(state)

  defp discover_and_advance(%{attempt: attempt} = state)
       when attempt <= @max_historical_attempts do
    with {:ok, prior_tx_id} <- discover_prior_tx_id(state),
         :ok <- prior_transaction_resolved(state, prior_tx_id),
         {:ok, head} <- ownership_head(state),
         {:ok, transaction, incarnation} <- build_owner_candidate(state, head) do
      transact_owner(%{
        state
        | phase: :acquiring,
          prior_tx_id: prior_tx_id,
          transaction: transaction,
          incarnation: incarnation
      })
    else
      :retry -> retry_owner(state)
      {:error, reason} -> {:stop, reason, state}
    end
  end

  defp discover_and_advance(state), do: {:stop, :owner_attempt_limit, state}

  defp discover_prior_tx_id(%{prior_tx_id: prior_tx_id}) when is_binary(prior_tx_id),
    do: {:ok, prior_tx_id}

  defp discover_prior_tx_id(state) do
    case load_all_records(state.store, state.session_id) do
      {:ok, records} -> {:ok, last_owner_transaction_id(records)}
      {:error, :store_unavailable} -> :retry
      :unavailable -> :retry
      {:error, reason} -> {:error, reason}
    end
  end

  defp last_owner_transaction_id(records) do
    Enum.find_value(Enum.reverse(records), fn
      %{payload: %{"owner_transaction_id" => tx_id, kind: "owner_advanced"}}
      when is_binary(tx_id) ->
        tx_id

      _other ->
        nil
    end)
  end

  defp prior_transaction_resolved(_state, nil), do: :ok

  defp prior_transaction_resolved(state, prior_tx_id) do
    case Store.transaction_status(
           state.store,
           state.session_id,
           @mutation_domain,
           prior_tx_id
         ) do
      {:terminal, _resolution} -> :ok
      :absent -> :ok
      :unavailable -> :retry
    end
  end

  defp ownership_head(state) do
    case Store.ownership_head(state.store, state.session_id, @mutation_domain) do
      {:ok, head} -> {:ok, head}
      :unavailable -> :retry
      :absent -> {:error, :session_not_found}
    end
  end

  defp build_owner_candidate(state, head) do
    tx_id = owner_identity("owner_tx", {state.succession_id, state.generation}, state.attempt)
    incarnation = fresh_incarnation(state.succession_id, state.attempt)

    case Store.advance_owner(
           state.session_id,
           @mutation_domain,
           tx_id,
           head.owner_epoch,
           head.journal_version,
           incarnation
         ) do
      {:ok, transaction} -> {:ok, transaction, incarnation}
      {:error, reason} -> {:error, reason}
    end
  end

  defp transact_owner(state) do
    {outcome, lane} = OwnerLane.transact(state.lane, state.transaction)
    state = %{state | lane: lane}
    expected_tx_id = state.transaction.tx_id

    case outcome do
      {:committed, ^expected_tx_id, receipt} ->
        if valid_owner_receipt?(receipt, state.incarnation) do
          recover_committed_owner(%{state | phase: :recovering, owner: owner(state, receipt)})
        else
          {:stop, :invalid_owner_receipt, state}
        end

      {:not_committed, reason}
      when reason in [:stale_owner_epoch, :stale_journal_version] ->
        advance_acquisition(%{
          state
          | phase: :discovering,
            prior_tx_id: expected_tx_id,
            transaction: nil,
            incarnation: nil,
            attempt: state.attempt + 1
        })

      {:not_committed, reason} ->
        {:stop, reason, state}

      {:commit_unknown, _tx_id} ->
        retry_owner(state)

      {:fenced, :commit_unknown} ->
        retry_owner(state)
    end
  end

  defp recover_committed_owner(state) do
    with {:ok, records} <- load_all_records(state.store, state.session_id),
         {:ok, events} <- load_all_events(state.store, state.session_id),
         {:ok, durable} <- SessionState.recover(state.session_id, records, events),
         true <- durable.owner_epoch == state.owner.owner_epoch,
         true <- durable.owner_incarnation_id == state.owner.owner_incarnation_id,
         true <- durable.owner_transaction_id == state.owner.transaction_id do
      ready = %{state | phase: :ready, durable: durable, transaction: nil, incarnation: nil}
      GenServer.cast(state.control, {:owner_ready, self(), state.owner, durable})
      send(self(), :advance_work)
      {:noreply, ready}
    else
      {:error, :store_unavailable} -> retry_owner(state)
      :unavailable -> retry_owner(state)
      false -> {:stop, :owner_recovery_superseded, state}
      {:error, reason} -> {:stop, reason, state}
      _other -> {:stop, :owner_recovery_failed, state}
    end
  end

  defp retry_owner(state) do
    Process.send_after(self(), :retry_owner, @owner_retry_ms)
    {:noreply, state}
  end

  defp valid_owner_receipt?(
         %{
           type: :advance_owner,
           owner_incarnation_id: incarnation,
           owner_epoch: owner_epoch,
           journal_version: journal_version
         },
         incarnation
       )
       when is_integer(owner_epoch) and owner_epoch > 0 and is_integer(journal_version) and
              journal_version > 1,
       do: true

  defp valid_owner_receipt?(_receipt, _incarnation), do: false

  defp owner(state, receipt) do
    %{
      generation: state.generation,
      owner_epoch: receipt.owner_epoch,
      owner_incarnation_id: receipt.owner_incarnation_id,
      transaction_id: state.transaction.tx_id
    }
  end

  defp owner_identity(namespace, succession_id, attempt) do
    bytes =
      :erlang.term_to_binary(["loopex_owner_identity_v1", namespace, succession_id, attempt], [
        :deterministic
      ])

    encoded = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
    namespace <> "_" <> binary_part(encoded, 0, 40)
  end

  defp fresh_incarnation(succession_id, attempt) do
    bytes =
      :erlang.term_to_binary(
        ["loopex_owner_incarnation_v1", succession_id, attempt, make_ref()],
        [:deterministic]
      )

    encoded = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
    "owner_" <> binary_part(encoded, 0, 40)
  end

  defp commit_command(state, command) do
    state = cancel_in_flight(state, command)

    case SessionState.propose(state.durable, command, resolved_for(state, command)) do
      {:replayed, reply} ->
        {:reply, reply, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}

      {:ok, proposal} ->
        with {:ok, transaction} <-
               Store.session_commit(
                 state.session_id,
                 @mutation_domain,
                 proposal.tx_id,
                 state.owner.owner_epoch,
                 state.owner.owner_incarnation_id,
                 state.durable.journal_version,
                 proposal.records,
                 proposal.events
               ) do
          apply_transaction(state, transaction, proposal)
        else
          {:error, reason} -> {:reply, {:error, reason}, state}
        end
    end
  end

  defp apply_transaction(state, transaction, proposal) do
    {outcome, lane} = resolve_transaction(state.lane, transaction)
    state = %{state | lane: lane}
    expected_tx_id = proposal.tx_id

    case outcome do
      {:committed, ^expected_tx_id, receipt} ->
        with {:ok, next} <- SessionState.commit_proposal(proposal, receipt),
             :ok <-
               Control.post_commit(
                 state.control,
                 state.session_id,
                 state.owner,
                 %{
                   journal_version: next.journal_version,
                   event_sequence: next.event_sequence
                 },
                 receipt
               ) do
          send(self(), :advance_work)
          {:reply, proposal.reply, %{state | durable: next}}
        else
          {:error, :superseded_owner} ->
            {:reply, {:error, {:superseded_after_commit, proposal.reply}},
             %{state | superseded: true}}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      {:not_committed, reason} when reason in [:stale_owner_epoch, :stale_owner_incarnation_id] ->
        {:reply, {:error, :superseded_owner}, %{state | superseded: true}}

      {:not_committed, reason} ->
        {:reply, {:error, reason}, state}

      {:commit_unknown, _tx_id} ->
        {:reply, {:error, :commit_unknown}, state}

      {:fenced, :commit_unknown} ->
        {:reply, {:error, :commit_unknown}, state}
    end
  end

  defp resolve_transaction(lane, transaction) do
    case OwnerLane.transact(lane, transaction) do
      {{:commit_unknown, _tx_id}, next_lane} -> OwnerLane.transact(next_lane, transaction)
      result -> result
    end
  end

  defp advance_work(%{phase: :ready, superseded: false, model: model} = state)
       when is_map(model) do
    if Control.current_owner?(state.control, state.session_id, state.owner) do
      case SessionState.pending_work(state.durable) do
        [] ->
          {:noreply, state}

        [%{stage: "model_pending"} = work | _rest] ->
          prepare_model_request(state, work)

        [%{stage: "model_dispatched"} = work | _rest] ->
          start_model_work(state, work)

        [%{stage: "effect_pending"} = work | _rest] ->
          prepare_effect(state, work)

        [%{stage: "effect_dispatched"} | _rest] ->
          {:noreply, state}

        [%{stage: "turn_settled"} = work | _rest] ->
          settle_turn(state, work)
      end
    else
      {:noreply, %{state | superseded: true}}
    end
  end

  defp advance_work(state), do: {:noreply, state}

  # Concept: build the next request from what the run has actually committed.
  #
  # Technical depth: the message list is projected from committed elements, so
  # every request after the first carries the operator's prompt, the model's own
  # prior assistant messages, and the real output of every tool it ran. The
  # bytes are canonicalized and committed *before* dispatch, and the adapter is
  # then handed exactly those bytes. There is no sampling default: a run whose
  # model configuration declares no `max_tokens` is refused here rather than
  # truncated at dispatch by a number no record names.
  defp prepare_model_request(state, work) do
    run_id = work.run_id
    {declared, _charged} = SessionState.accounting(state.durable, run_id)
    elements = SessionState.elements(state.durable, run_id)

    # Concept: a steer joins here, and only here.
    #
    # Technical depth: this is after every tool result of the current turn has
    # committed and after the bound checks decided another request will actually
    # be staged. Reading it any earlier would let a steer be recorded applied
    # against a request the run never sent.
    steer = SessionState.pending_steer(state.durable, run_id)

    with {:ok, max_tokens} <- declared_max_tokens(state),
         {blocks, receipt} = project_blocks(state),
         messages =
           Conversation.project(elements, system: system_block(state), project_blocks: blocks),
         messages = messages ++ steer_message(steer),
         deadline = run_deadline(declared),
         {:ok, request} <-
           Model.request(state.model.model, messages,
             tools: state.active_tools,
             sampling: %{"max_tokens" => max_tokens},
             deadline: deadline
           ),
         {:ok, proposal} <-
           SessionState.propose_model_request(state.durable, run_id, request,
             applied_steer: steer && steer.command_id,
             context_receipt: receipt
           ),
         {:ok, next} <- commit_internal(state, proposal) do
      send(self(), :advance_work)
      {:noreply, next}
    else
      {:error, reason} -> {:stop, {:model_request_failed, reason}, state}
    end
  end

  # Concept: the run stops when the model stops asking, or when a declared bound
  # says so.
  #
  # Technical depth: the no-tool check runs first and unconditionally, so a run
  # whose model finished on its own is `completed` and stays `completed`. Only
  # then are bounds consulted, in their fixed order. The decision is committed as
  # a durable fact rather than re-derived later, because it reads the wall clock
  # and a clock-reading decision cannot be replayed.
  defp settle_turn(state, work) do
    run_id = work.run_id
    {declared, charged} = SessionState.accounting(state.durable, run_id)
    elements = SessionState.elements(state.durable, run_id)
    assistant = Conversation.last_assistant(elements)

    decision =
      Bounds.decide(declared,
        tool_calls: assistant.tool_calls,
        turn_number: work.turn_number,
        tokens: charged.tokens,
        now: System.system_time(:millisecond)
      )

    case decision do
      :continue ->
        prepare_model_request(state, work)

      :completed ->
        commit_terminal(state, run_id, "completed", %{})

      {:bound_reached, bound, observed} when bound == :deadline ->
        # Concept: a deadline is not a guaranteed clean stop.
        #
        # Technical depth: `bound_reached(:deadline)` may commit only once every
        # owned operation has reached a validated terminal fact. A committed
        # `outcome_unknown` effect is precisely the case where one has not, so
        # the run ends `outcome_unknown` carrying its reconciliation reference
        # instead. That precedence is why no document here calls reaching a
        # deadline a clean stop.
        if SessionState.unproven_effect?(state.durable, run_id) do
          commit_terminal(state, run_id, "outcome_unknown", %{
            bound: "deadline",
            observed: observed,
            declared_limit: declared_limit(declared, :deadline),
            accounting_source: charged.source && Atom.to_string(charged.source),
            reconciliation_ref: reconciliation_ref(state, run_id)
          })
        else
          commit_terminal(state, run_id, "bound_reached", %{
            bound: "deadline",
            observed: observed,
            declared_limit: declared_limit(declared, :deadline),
            accounting_source: charged.source && Atom.to_string(charged.source)
          })
        end

      {:bound_reached, bound, observed} ->
        commit_terminal(state, run_id, "bound_reached", %{
          bound: Atom.to_string(bound),
          observed: observed,
          declared_limit: declared_limit(declared, bound),
          accounting_source: charged.source && Atom.to_string(charged.source)
        })
    end
  end

  # Concept: the limit an observed value was measured against.
  #
  # Technical depth: the deadline's declared limit is the instant the run was
  # actually bound by, not the duration it was configured with, because that is
  # what the observed clock reading is comparable to.
  defp reconciliation_ref(state, run_id),
    do: stable_id("reconciliation", state.session_id, run_id)

  defp declared_limit(declared, :deadline), do: run_deadline(declared)
  defp declared_limit(declared, bound), do: Map.fetch!(declared, bound)

  # Concept: project context is admitted, never assumed.
  #
  # Technical depth: resolved per turn from the same manifest and decision, so a
  # changed workspace or edited resource stops being admitted at the next turn
  # rather than only at the next run. A declined class stages nothing and
  # journals why; the coding task runs either way.
  defp project_blocks(state) do
    case ProjectResource.resolve(state.project_manifest, state.project_decision) do
      {:staged, blocks, detail} -> {blocks, ProjectResource.receipt(:staged, detail)}
      {:declined, reason, detail} -> {[], ProjectResource.receipt(reason, detail)}
    end
  end

  defp steer_message(nil), do: []
  defp steer_message(%{content: content}), do: [%{"role" => "user", "content" => content}]

  defp commit_terminal(state, run_id, outcome, detail) do
    with {:ok, proposal} <-
           SessionState.propose_run_terminal(state.durable, run_id, outcome, detail),
         {:ok, next} <- commit_internal(state, proposal) do
      {:noreply, next}
    else
      {:error, reason} -> {:stop, {:run_terminal_failed, reason}, state}
    end
  end

  # Concept: the output allowance every request declares.
  #
  # Technical depth: read from the runtime's declared sampling configuration, or
  # from the model options where a host set one there. There is no fallback
  # invented here: if neither declares a bound the request is refused rather than
  # truncated at dispatch by a number no record names.
  # Concept: the run's absolute deadline, fixed by its first turn.
  #
  # Technical depth: once committed history carries one, that value is used
  # unchanged for every later turn. Only turn one converts the declared duration
  # into an instant, which is why a recovering owner resumes the deadline the run
  # actually had rather than granting it the downtime it slept through.
  defp run_deadline(%{deadline: deadline}) when is_integer(deadline), do: deadline

  defp run_deadline(%{deadline_ms: deadline_ms}),
    do: System.system_time(:millisecond) + deadline_ms

  defp declared_max_tokens(state) do
    configured =
      Keyword.get(state.model.options, :max_tokens) ||
        get_in(state.sampling, ["max_tokens"])

    case configured do
      max_tokens when is_integer(max_tokens) and max_tokens > 0 -> {:ok, max_tokens}
      _absent -> {:error, :undeclared_sampling_bound}
    end
  end

  # Concept: a run's bounds become absolute when the run is admitted.
  #
  # Technical depth: the configured deadline is a duration; this is the one place
  # it becomes an instant, and it is committed with the admitting record. A
  # command may name its own bounds and they win, which is how a host with a
  # per-run policy overrides the runtime default without either of them being
  # implicit.
  defp resolve_bounds(state, command) do
    case Map.get(command, :bounds) do
      %{} = supplied -> Map.merge(state.bounds, supplied)
      _absent -> state.bounds
    end
  end

  # Concept: the versioned block that opens every conversation.
  #
  # Technical depth: carried inside the staged bytes and therefore covered by
  # `staged_request_digest`, so a change to it is a visible change of what was
  # dispatched rather than an invisible drift in how the model was instructed.
  defp system_block(_state) do
    "loopex.system.v1: You are a coding agent working in a real workspace. " <>
      "Use the tools you are given to inspect and change files, and run commands " <>
      "when you need to. Continue until the task is done, then stop."
  end

  defp start_model_work(state, work) do
    if in_flight?(state, :model, work.run_id) do
      {:noreply, state}
    else
      module = state.model.module
      request = work.request
      options = state.model.options
      {stream, progress} = model_progress_fun(state, work)

      task =
        Task.Supervisor.async_nolink(state.workers, fn ->
          module.complete(request, options, progress)
        end)

      state = %{state | streams: Map.put(state.streams, {:model, work.run_id}, stream)}
      {:noreply, put_in_flight(state, task.ref, {:model, work.run_id, task.pid})}
    end
  end

  # Concept: the coordinator names the stream, not the adapter.
  #
  # Technical depth: the function closes over the domain derived from the
  # attempt this coordinator is about to dispatch, so an adapter cannot
  # misattribute a delta to another attempt even by accident — it never supplies
  # a domain at all. Malformed items are dropped rather than projected, because
  # a bad item must not be able to break the sequence a consumer uses to detect
  # loss.
  defp model_progress_fun(state, work) do
    domain =
      StreamDomain.derive(
        :model,
        state.session_id,
        model_operation_id(work),
        Map.get(work, :model_attempt, 1)
      )

    turn_id = work.turn_id
    sink = state.progress_to
    counter = :counters.new(1, [:atomics])
    stream = %{domain: domain, turn_id: turn_id, counter: counter}

    {stream,
     fn delta ->
       if Model.valid_delta?(delta) do
         :counters.add(counter, 1, 1)

         emit_progress(
           sink,
           Map.merge(delta, %{
             turn_id: turn_id,
             stream_domain_id: domain,
             model_sequence: :counters.get(counter, 1)
           })
         )
       end

       :ok
     end}
  end

  defp model_operation_id(work), do: stable_id("model-operation", work.run_id, work.turn_number)

  # Concept: every domain the coordinator opens is owed exactly one closure.
  #
  # Technical depth: a complete attempt closes with the producer's own count; an
  # abandoned one closes with the count the coordinator itself observed, which is
  # exact because it stops accepting items for a domain once it has closed it.
  # Emission is the obligation — delivery is not guaranteed, because the closure
  # rides the transient plane like any other item and may be coalesced away or
  # lost with the plane when its owner changes.
  defp close_model_stream(state, run_id, disposition, reported_count) do
    case Map.fetch(state.streams, {:model, run_id}) do
      {:ok, stream} ->
        count =
          case disposition do
            :complete -> reported_count
            :abandoned -> :counters.get(stream.counter, 1)
          end

        emit_progress(
          state.progress_to,
          StreamDomain.model_closed(stream.turn_id, stream.domain, 0, disposition, count)
        )

        %{state | streams: Map.delete(state.streams, {:model, run_id})}

      :error ->
        state
    end
  end

  defp close_tool_stream(state, run_id, disposition, reported_count) do
    case Map.fetch(state.streams, {:executor, run_id}) do
      {:ok, stream} ->
        count =
          case disposition do
            :complete -> reported_count
            :abandoned -> :counters.get(stream.counter, 1)
          end

        emit_progress(
          state.progress_to,
          StreamDomain.tool_closed(
            stream.turn_id,
            stream.domain,
            stream.tool_call_id,
            0,
            disposition,
            count
          )
        )

        %{state | streams: Map.delete(state.streams, {:executor, run_id})}

      :error ->
        state
    end
  end

  defp emit_progress(nil, _item), do: :ok

  defp emit_progress(sink, item) when is_pid(sink) do
    send(sink, {:loopex_progress, item})
    :ok
  end

  defp prepare_effect(state, work) do
    [call | _rest] = work.pending_calls
    {declared, _charged} = SessionState.accounting(state.durable, work.run_id)

    # Concept: a call is dispatched only while the run's deadline is still ahead.
    #
    # Technical depth: checked once, here, at intent commit. Past the deadline no
    # intent commits, no grant is minted and no process starts, so the call takes
    # a terminal `cancelled` fact whose cleanup is confirmed trivially — there is
    # nothing to clean up because nothing ran. There is deliberately no minimum
    # remaining time: a call with one millisecond left is dispatched, because
    # inventing a threshold would refuse work the operator's declared bound
    # actually permits.
    if System.system_time(:millisecond) >= run_deadline(declared) do
      commit_tool_terminal(
        state,
        work,
        call,
        :cancelled,
        "the run deadline passed before dispatch"
      )
    else
      dispatch_effect(state, work, call)
    end
  end

  defp dispatch_effect(state, work, call) do
    with {:ok, definition} <- resolve_active_tool(state, call.name),
         {:ok, job} <- build_job(state, work, call, definition),
         {:allow, context} <- consult_policy(state, work, call, definition),
         {:ok, grant} <-
           Executor.issue_grant(
             grant_decision(state),
             job,
             System.system_time(:millisecond) + 60_000,
             policy_context(context)
           ),
         {:ok, proposal} <-
           SessionState.propose_effect_intent(state.durable, work.run_id, job, grant),
         {:ok, next} <- commit_internal(state, proposal) do
      start_executor_work(next, Map.fetch!(next.durable.pending_work, work.run_id))
    else
      # Concept: a host refusal is an answer, not an error.
      #
      # Technical depth: no grant is issued and no operating-system process
      # starts. The denial commits as a terminal fact the operator can read, and
      # the run carries on or ends truthfully. It is never retried, because the
      # host already answered.
      {:deny, category} ->
        commit_tool_terminal(state, work, call, :denied, Atom.to_string(category))

      # Concept: a call that cannot be dispatched still gets an answer.
      #
      # Technical depth: the name is never guessed and the call is never
      # dispatched; it takes a terminal `failed` fact naming what went wrong, and
      # the loop carries on from there. Exiting here instead would lose the run's
      # place in its own conversation over a problem with one tool.
      {:error, reason} ->
        commit_tool_failure(state, work, call, reason)
    end
  end

  # Concept: an abort stops the work before it records that the work stopped.
  #
  # Technical depth: M1 recorded an abort and removed the run, which left an
  # operating-system process running with nobody's name on it and an operator
  # told the task had ended. The order here is the point: scheduling stops, the
  # in-flight model attempt and executor job are actually cancelled, cleanup is
  # confirmed, and only then does a terminal fact commit — and it commits
  # `cancelled` only where that confirmation succeeded.
  #
  # A validated terminal fact that committed before the abort is untouched. The
  # abort ends what is still running; it does not rewrite what already finished.
  defp cancel_in_flight(state, command) do
    if Map.get(command, :type) in [:abort, "abort"] do
      state
      |> cancel_model_attempt()
      |> cancel_executor_job()
    else
      state
    end
  end

  # Concept: the abort carries what cleanup actually achieved.
  #
  # Technical depth: the disposition is attached after cancellation ran and
  # before the record is proposed, so the committed outcome describes the world
  # rather than the intent. It is not part of the command's canonical digest,
  # which covers what the caller asked for; re-presenting the same abort returns
  # the retained result rather than re-cancelling.
  # Concept: what a command needs that its caller did not supply.
  #
  # Technical depth: a prompt needs its run's resolved bounds; an abort needs
  # what cancellation actually achieved. Both travel alongside the command rather
  # than inside it, because the command's digest covers what the caller asked for
  # and must stay the same however the world turned out — otherwise re-presenting
  # one abort would conflict with itself because cleanup went differently the
  # second time.
  defp resolved_for(state, command) do
    if Map.get(command, :type) in [:abort, "abort"] do
      disposition =
        if Enum.any?(state.cleanup, fn {_run_id, value} -> value == :unconfirmed end),
          do: :unconfirmed,
          else: :cleaned

      %{cleanup: disposition}
    else
      resolve_bounds(state, command)
    end
  end

  defp cancel_model_attempt(state) do
    Enum.reduce(state.in_flight, state, fn
      {reference, {:model, run_id, pid}}, acc ->
        # A provider call has no effect to leave behind, so shutting the task
        # down is the whole of its cleanup. Its domain still owes a closure.
        _ = Task.Supervisor.terminate_child(acc.workers, pid)
        acc = close_model_stream(acc, run_id, :abandoned, 0)
        %{acc | in_flight: Map.delete(acc.in_flight, reference)}

      {_reference, _other}, acc ->
        acc
    end)
  end

  defp cancel_executor_job(state) do
    Enum.reduce(state.in_flight, state, fn
      {reference, {:executor, run_id, pid}}, acc ->
        cleanup = cancel_executor_work(acc, run_id)
        _ = Task.Supervisor.terminate_child(acc.workers, pid)
        acc = close_tool_stream(acc, run_id, :abandoned, 0)

        %{
          acc
          | in_flight: Map.delete(acc.in_flight, reference),
            cleanup: Map.put(acc.cleanup, run_id, cleanup)
        }

      {_reference, _other}, acc ->
        acc
    end)
  end

  # Concept: ask the hand to stop its own job, and believe only what it confirms.
  #
  # Technical depth: the executor owns the process tree, so it is the one that
  # can end it and the one that can look for survivors. An executor that cannot
  # tell us leaves the run unable to claim a clean stop, which is why the
  # unconfirmed answer propagates all the way to `outcome_unknown` rather than
  # being smoothed into a success.
  defp cancel_executor_work(state, run_id) do
    case Map.get(state.durable.pending_work, run_id) do
      %{job: job} ->
        {:ok, disposition} =
          Executor.cancel(state.executor.module, state.executor.reference, job.job_id)

        disposition

      _absent ->
        :cleaned
    end
  end

  # Concept: every executor-backed call asks the host, including a read-only one.
  #
  # Technical depth: there is no effect class and no argument shape that skips
  # this. An exemption would be a dispatch branch nothing policed. Where no
  # policy is configured the runtime refused to start, so reaching here without
  # one means tools were composed after start, and that is refused rather than
  # allowed.
  defp consult_policy(%{policy: nil}, _work, _call, _definition),
    do: {:deny, :policy_unavailable}

  defp consult_policy(state, work, call, definition) do
    Policy.decide(state.policy, %{
      session_id: state.session_id,
      run_id: work.run_id,
      tool_call_id: call.tool_call_id,
      generation: ToolDefinition.generation(definition),
      arguments: call.arguments,
      effect_class: Map.fetch!(definition, "effect_class"),
      idempotency_class: Map.fetch!(definition, "idempotency_class"),
      workspace_lease: state.executor.workspace_lease
    })
  end

  # Concept: the grant is minted because the host allowed, not because a literal
  # said so.
  #
  # Technical depth: a runtime with any tool active refuses to start without a
  # policy, so reaching a dispatch means a host answered allow for this exact
  # call. The reference issuance function still takes M1's marker term; what
  # changed is that nothing reaches it unless a policy said yes first.
  defp grant_decision(_state), do: {:host_policy, :allow}

  defp policy_context(nil), do: nil
  defp policy_context(context) when is_map(context), do: context

  defp commit_tool_failure(state, work, call, reason),
    do: commit_tool_terminal(state, work, call, :failed, failure_reason(reason))

  defp commit_tool_terminal(state, work, call, outcome, reason) do
    with {:ok, proposal} <-
           SessionState.propose_tool_result(
             state.durable,
             work.run_id,
             call.tool_call_id,
             outcome,
             reason
           ),
         {:ok, next} <- commit_internal(state, proposal) do
      send(self(), :advance_work)
      {:noreply, next}
    else
      {:error, commit_reason} -> {:stop, {:tool_result_failed, commit_reason}, state}
    end
  end

  # Concept: a bounded reason the model can read.
  #
  # Technical depth: bounded and plain, because it becomes model-facing content
  # and crosses the durable boundary. An unrecognised term is summarised rather
  # than inspected in full, so a large internal structure cannot reach either.
  defp failure_reason({:unknown_tool, name}) when is_binary(name),
    do: "unknown_tool: no active tool is named #{name}"

  defp failure_reason(reason) when is_atom(reason), do: Atom.to_string(reason)

  defp failure_reason({reason, _detail}) when is_atom(reason), do: Atom.to_string(reason)

  defp failure_reason(_reason), do: "the tool could not be run"

  # Concept: a name the model used must be one this session offered.
  #
  # Technical depth: resolved against the active set composed at session start,
  # never against the registry directly, so a tool registered mid-run cannot
  # become callable in a conversation that was never shown it.
  # Concept: the session's model-visible names, each bound to one generation.
  #
  # Technical depth: committed with the reply that used them, so the assistant
  # message records the exact bytes each call resolved through rather than a
  # bare name a later registry edit could repoint.
  defp active_generations(state) do
    Map.new(state.active_tools, fn definition ->
      {Map.fetch!(definition, "name"), Tuple.to_list(ToolDefinition.generation(definition))}
    end)
  end

  defp resolve_active_tool(state, name) do
    case Enum.find(state.active_tools, &(Map.fetch!(&1, "name") == name)) do
      nil -> {:error, {:unknown_tool, name}}
      definition -> {:ok, definition}
    end
  end

  defp start_executor_work(state, work) do
    if in_flight?(state, :executor, work.run_id) do
      {:noreply, state}
    else
      executor = state.executor
      {stream, progress} = executor_progress_fun(state, work)

      task =
        Task.Supervisor.async_nolink(state.workers, fn ->
          executor.module.execute(executor.reference, work.job, work.grant, [], progress)
        end)

      state = %{state | streams: Map.put(state.streams, {:executor, work.run_id}, stream)}
      {:noreply, put_in_flight(state, task.ref, {:executor, work.run_id, task.pid})}
    end
  end

  # Concept: an executor's progress is stamped with a domain it never supplied.
  #
  # Technical depth: the domain is derived from the `(operation_id, attempt)`
  # this coordinator dispatched and journaled. An event whose `tool_call_id`
  # does not match the dispatched call is refused rather than relabelled, which
  # is why validation happens before the domain is stamped and not after.
  defp executor_progress_fun(state, work) do
    job = work.job
    domain = StreamDomain.derive(:executor, state.session_id, job.operation_id, job.attempt)
    turn_id = work.turn_id
    tool_call_id = job.tool_call_id
    sink = state.progress_to
    counter = :counters.new(1, [:atomics])

    stream = %{domain: domain, turn_id: turn_id, counter: counter, tool_call_id: tool_call_id}

    {stream,
     fn event ->
       if is_map(event) and Map.get(event, :tool_call_id) == tool_call_id do
         :counters.add(counter, 1, 1)

         emit_progress(
           sink,
           Map.merge(event, %{
             kind: :tool_progress,
             turn_id: turn_id,
             stream_domain_id: domain,
             progress_sequence: :counters.get(counter, 1)
           })
         )
       end

       :ok
     end}
  end

  defp build_job(state, work, call, definition) do
    {declared, _charged} = SessionState.accounting(state.durable, work.run_id)
    executor = state.executor
    budgets = Map.fetch!(definition, "budgets")

    Executor.job(%{
      protocol_version: 1,
      job_id: stable_id("job", work.run_id, call.tool_call_id),
      operation_id: stable_id("operation", work.run_id, call.tool_call_id),
      attempt: 1,
      session_id: state.session_id,
      run_id: work.run_id,
      turn_id: work.turn_id,
      tool_call_id: call.tool_call_id,
      origin_session_epoch: state.owner.owner_epoch,
      origin_executor_epoch: executor.epoch,
      executor_identity: executor.identity,
      required_capabilities: [Map.fetch!(definition, "effect_class")],
      tool_id: Map.fetch!(definition, "tool_id"),
      tool_version: Map.fetch!(definition, "tool_version"),
      effect_class: Map.fetch!(definition, "effect_class"),
      validated_arguments: call.arguments,
      workspace_ref: executor.workspace_ref,
      workspace_lease: executor.workspace_lease,
      run_deadline: declared.deadline,
      resource_budgets: %{"max_output_bytes" => Map.fetch!(budgets, "output_bytes")},
      idempotency_class: Map.fetch!(definition, "idempotency_class"),
      fencing_token: executor.fencing_token,
      artifact_policy: %{"retain" => true},
      output_policy: %{"capture" => true}
    })
  end

  # Concept: a result belongs to a run only while that run is still owed one.
  #
  # Technical depth: the pending-work map is the authority. If the run is gone —
  # aborted, or already terminal — the result is late and takes the evidence
  # path; otherwise it is applied normally.
  defp dispatch_result(state, kind, run_id, result) do
    if Map.has_key?(state.durable.pending_work, run_id) do
      case kind do
        :model -> accept_model_result(state, run_id, result)
        :executor -> accept_executor_result(state, run_id, result)
      end
    else
      accept_late_result(state, run_id, kind, result)
    end
  end

  defp accept_model_result(state, run_id, {:ok, reply}) when is_map(reply) do
    state = close_model_stream(state, run_id, :complete, Map.get(reply, :delta_count, 0))

    with {:ok, proposal} <-
           SessionState.propose_model_result(
             state.durable,
             run_id,
             reply,
             active_generations(state)
           ),
         {:ok, next} <- commit_internal(state, proposal) do
      send(self(), :advance_work)
      {:noreply, next}
    else
      {:error, reason} -> {:stop, {:model_result_failed, reason}, state}
    end
  end

  defp accept_model_result(state, run_id, result) do
    # An attempt that returned no reply still owes its closure, so a consumer can
    # tell an abandoned stream from one that merely went quiet, and still owes
    # its charge, so giving up is not cheaper than finishing.
    state = close_model_stream(state, run_id, :abandoned, 0)
    state = %{state | durable: SessionState.charge_incomplete_turn(state.durable, run_id)}

    # Concept: a provider retry redispatches the bytes that were already
    # committed.
    #
    # Technical depth: nothing is recomputed. The same staged bytes and the same
    # staged_request_digest go out again under a newly recorded attempt, because
    # the model request has no operation or attempt member for a digest to cover.
    # That is the opposite of the executor rule, where each attempt canonicalizes
    # its own attempt identity and therefore computes its own digest — which is
    # exactly why the two digests no longer share one name.
    case retry_model_attempt(state, run_id) do
      {:ok, next} ->
        send(self(), :advance_work)
        {:noreply, next}

      :exhausted ->
        {:stop, {:model_failed, result}, state}
    end
  end

  @model_attempt_limit 2

  defp retry_model_attempt(state, run_id) do
    case Map.get(state.durable.pending_work, run_id) do
      %{stage: "model_dispatched"} = work ->
        attempt = Map.get(work, :model_attempt, 1)

        if attempt < @model_attempt_limit do
          next_work = Map.put(work, :model_attempt, attempt + 1)

          durable = %{
            state.durable
            | pending_work: Map.put(state.durable.pending_work, run_id, next_work)
          }

          {:ok, %{state | durable: durable}}
        else
          :exhausted
        end

      _absent ->
        :exhausted
    end
  end

  defp accept_executor_result(state, run_id, {:ok, receipt}) when is_map(receipt) do
    state = close_tool_stream(state, run_id, :complete, Map.get(receipt, :progress_count, 0))

    case state.fault_to do
      pid when is_pid(pid) ->
        reference = make_ref()

        send(
          pid,
          {:loopex_fault, :after_executor_receipt_before_fact, self(), reference, receipt}
        )

        {:noreply,
         %{state | pending_fault: %{reference: reference, run_id: run_id, receipt: receipt}}}

      nil ->
        commit_executor_fact(state, run_id, receipt)
    end
  end

  defp accept_executor_result(state, run_id, result) do
    state = close_tool_stream(state, run_id, :abandoned, 0)

    # An executor that answered with an error produced no receipt, so the call
    # has no validated terminal fact of its own. It becomes a terminal `failed`
    # rather than ending the session: the effect did not start, so there is
    # nothing indeterminate to reconcile.
    case Map.get(state.durable.pending_work, run_id) do
      %{pending_calls: [call | _rest]} = work ->
        commit_tool_failure(state, work, call, failure_of(result))

      _other ->
        {:stop, {:executor_failed, result}, state}
    end
  end

  # Concept: a reply that arrives after its run ended is evidence, not history.
  #
  # Technical depth: an abort admitted before the reply committed leaves no work
  # for it to belong to. The attempt is retained truthfully on the diagnostics
  # plane and never becomes a canonical assistant message, because the run it
  # would have continued is already terminal. Treating it as a fault instead
  # would kill an owner over a message that arrived a moment too late.
  defp accept_late_result(state, run_id, kind, result) do
    emit_diagnostic(state, %{
      "kind" => "late_result_discarded",
      "run_id" => run_id,
      "operation" => Atom.to_string(kind),
      "outcome" => if(match?({:ok, _}, result), do: "reply", else: "error")
    })

    {:noreply, state}
  end

  defp emit_diagnostic(%{diagnostics_to: sink}, item) when is_pid(sink) do
    send(sink, {:loopex_diagnostic, item})
    :ok
  end

  defp emit_diagnostic(_state, _item), do: :ok

  defp failure_of({:error, reason}), do: reason
  defp failure_of(other), do: other

  defp commit_executor_fact(state, run_id, receipt) do
    with {:ok, proposal} <- SessionState.propose_executor_fact(state.durable, run_id, receipt),
         {:ok, next} <- commit_internal(state, proposal) do
      send(self(), :advance_work)
      {:noreply, next}
    else
      {:error, reason} -> {:stop, {:executor_fact_failed, reason}, state}
    end
  end

  defp commit_internal(state, proposal) do
    with {:ok, transaction} <-
           Store.session_commit(
             state.session_id,
             @mutation_domain,
             proposal.tx_id,
             state.owner.owner_epoch,
             state.owner.owner_incarnation_id,
             state.durable.journal_version,
             proposal.records,
             proposal.events
           ) do
      {outcome, lane} = resolve_transaction(state.lane, transaction)
      state = %{state | lane: lane}

      case outcome do
        {:committed, tx_id, receipt} when tx_id == proposal.tx_id ->
          with {:ok, next} <- SessionState.commit_proposal(proposal, receipt),
               :ok <-
                 Control.post_commit(
                   state.control,
                   state.session_id,
                   state.owner,
                   %{
                     journal_version: next.journal_version,
                     event_sequence: next.event_sequence
                   },
                   receipt
                 ) do
            {:ok, %{state | durable: next}}
          end

        {:not_committed, reason} ->
          {:error, reason}

        {:commit_unknown, _tx_id} ->
          {:error, :commit_unknown}

        {:fenced, :commit_unknown} ->
          {:error, :commit_unknown}
      end
    end
  end

  defp ready_current?(state, supplied_owner) do
    cond do
      state.phase != :ready -> {:error, :owner_acquiring}
      state.superseded -> {:error, :superseded_owner}
      supplied_owner != state.owner -> {:error, :superseded_owner}
      Control.current_owner?(state.control, state.session_id, state.owner) -> :ok
      true -> {:error, :superseded_owner}
    end
  end

  defp pending_effect(state) do
    case SessionState.pending_work(state.durable) do
      [%{stage: "effect_dispatched"} = work] -> {:ok, work}
      _other -> {:error, :no_effect_recovery_pending}
    end
  end

  defp reconciliation_query_data(query_id, owner, job) do
    %{
      reconciliation_query_id: query_id,
      current_session_epoch: owner.owner_epoch,
      expected_executor_identity: job.executor_identity,
      current_recovery_contract: @recovery_contract,
      journaled_operation_id: job.operation_id,
      original_attempt: job.attempt,
      journaled_canonical_request_digest: job.canonical_request_digest,
      original_session_epoch: job.origin_session_epoch,
      original_executor_epoch: job.origin_executor_epoch,
      origin_executor_identity: job.executor_identity,
      origin_fencing_token: job.fencing_token
    }
  end

  defp validate_reconciliation_response(response, query, job) do
    expected =
      reconciliation_query_data(
        query.reconciliation_query_id,
        %{owner_epoch: query.current_session_epoch},
        job
      )

    with :ok <- compare_reconciliation_fields(response, expected),
         :ok <- validate_reconciliation_evidence(response, job) do
      :ok
    end
  end

  defp compare_reconciliation_fields(response, expected) do
    Enum.reduce_while(@reconciliation_fields, :ok, fn field, :ok ->
      if Map.get(response, field) == Map.fetch!(expected, field),
        do: {:cont, :ok},
        else: {:halt, {:error, {:mismatch, field}}}
    end)
  end

  defp validate_reconciliation_evidence(%{evidence: "receipt", retained_receipt: receipt}, job)
       when is_map(receipt) do
    receipt_fields = [
      job_id: job.job_id,
      operation_id: job.operation_id,
      attempt: job.attempt,
      canonical_request_digest: job.canonical_request_digest,
      session_epoch_at_dispatch: job.origin_session_epoch,
      executor_epoch: job.origin_executor_epoch,
      executor_identity: job.executor_identity,
      fencing_token: job.fencing_token
    ]

    Enum.reduce_while(receipt_fields, :ok, fn {field, expected}, :ok ->
      if Map.get(receipt, field) == expected,
        do: {:cont, :ok},
        else: {:halt, {:error, {:mismatch, field}}}
    end)
  end

  defp validate_reconciliation_evidence(%{evidence: "outcome_unknown"}, _job), do: :ok

  defp validate_reconciliation_evidence(_response, _job),
    do: {:error, :invalid_reconciliation_evidence}

  defp reconciliation_proposal(
         state,
         run_id,
         %{evidence: "receipt", retained_receipt: receipt},
         _query
       ),
       do: SessionState.propose_executor_fact(state, run_id, receipt)

  defp reconciliation_proposal(state, run_id, %{evidence: "outcome_unknown"}, query),
    do: SessionState.propose_outcome_unknown(state, run_id, query.reconciliation_query_id)

  defp in_flight?(state, kind, run_id) do
    Enum.any?(state.in_flight, fn
      {_reference, {^kind, ^run_id, _pid}} -> true
      {_reference, _other} -> false
    end)
  end

  defp put_in_flight(state, reference, value),
    do: %{state | in_flight: Map.put(state.in_flight, reference, value)}

  defp stable_id(namespace, left, right) do
    bytes =
      :erlang.term_to_binary(["loopex_runtime_v1", namespace, left, right], [:deterministic])

    encoded = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
    namespace <> "_" <> binary_part(encoded, 0, 40)
  end

  defp safe_call(server, message, timeout \\ 5_000) do
    try do
      GenServer.call(server, message, timeout)
    catch
      :exit, _reason -> {:error, :session_unavailable}
    end
  end

  defp load_all_records(store, session_id),
    do:
      load_pages(&Store.load_records(store, session_id, &1, @page_size), :journal_version, 0, [])

  defp load_all_events(store, session_id),
    do: load_pages(&Store.load_events(store, session_id, &1, @page_size), :event_sequence, 0, [])

  defp load_pages(loader, position_key, position, accumulated) do
    case loader.(position) do
      {:ok, []} ->
        {:ok, Enum.reverse(accumulated)}

      {:ok, rows} when is_list(rows) ->
        case List.last(rows) do
          %{^position_key => next_position}
          when is_integer(next_position) and next_position > position ->
            load_pages(loader, position_key, next_position, Enum.reverse(rows, accumulated))

          _other ->
            {:error, :invalid_store_page}
        end

      :unavailable ->
        {:error, :store_unavailable}

      {:error, reason} ->
        {:error, reason}

      _other ->
        {:error, :invalid_store_page}
    end
  end
end
