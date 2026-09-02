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
  alias Loopex.Runtime.ExecutorStream
  alias Loopex.Runtime.SessionState
  alias Loopex.Runtime.StreamRelay
  alias Loopex.Executor
  alias Loopex.Model
  alias Loopex.Policy
  alias Loopex.ProjectResource
  alias Loopex.StreamDomain
  alias LoopexProtocol.Canonical
  alias LoopexProtocol.ToolDefinition
  alias Loopex.Store
  alias Loopex.Store.OwnerLane

  @mutation_domain "session"
  @page_size 1_024

  # Concept: an owner that cannot reach the Store waits a while, then says so.
  # It does not wait forever, because the caller that asked for this session is
  # blocked behind it with no bound of its own.
  #
  # Technical depth: every retry re-reads the Store, so a flat delay against a
  # Store that stays down is a hot loop that never ends -- roughly forty reads a
  # second, indefinitely, while `create_session/3` and `resume_session/3` wait on
  # `:infinity`. Three declared numbers end that. The first delay stays at 25 ms
  # because the case this loop exists for is a Store momentarily behind its own
  # writes, which clears in a retry or two and should cost nothing. The delay
  # then doubles, so a longer outage is not paid for at that rate; the 400 ms
  # ceiling holds a sustained outage at about two reads a second, which is
  # observation rather than load. Twelve retries spend 25 + 50 + 100 + 200 ms and
  # then eight ceilings, so acquisition gives up after roughly 3.6 s: long enough
  # to ride out a Store that is restarting, short enough that a blocked caller
  # gets a real answer instead of a hang. `@max_historical_attempts` does not
  # cover this; it bounds succession contention, and `state.attempt` advances
  # only on the stale-epoch branch, so an unavailable Store never reaches it.
  @owner_retry_ms 25
  @owner_retry_ceiling_ms 400
  @max_owner_retries 12
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
  @spec command(pid(), owner(), map()) :: {:accepted, binary()} | {:error, term()}
  def command(coordinator, owner, command)
      when is_pid(coordinator) and is_map(owner) and is_map(command) do
    safe_call(coordinator, {:command, owner, command}, :infinity)
  end

  # Concept: status is the one session question that may give up on an owner
  # that is not answering, because asking it changes nothing.
  #
  # Technical depth: `command/3`, `reconciliation_query/2`, and `reconcile/3`
  # keep `:infinity` deliberately, and must keep it: a timeout is not an
  # ownership verdict, and bounding a call whose mutation may already be
  # committing abandons a caller whose work becomes durable anyway. None of that
  # reasoning reaches this call. A status read proposes nothing, commits nothing,
  # and installs nothing, so its deadline cannot become a durable fact or fence
  # anyone out of a session; the worst it can produce is
  # `{:error, :session_unavailable}` for a caller free to ask again. That is why
  # this one call carries a bound and why making the other three match it would
  # reintroduce the defect those two commits removed.
  @session_status_timeout_ms 5_000

  # Concept: the version of the encoding a retained descriptor was measured and
  # digested under, carried so a later encoder cannot be assumed.
  #
  # Technical depth: an unknown canonicalization version is unavailable history
  # rather than something to decode with the current encoder and hope.
  @descriptor_canonicalization_version "loopex.canonical.v1"
  @descriptor_digest_domain "loopex.context.descriptors.v1"

  @doc false
  @spec session_status(pid(), owner()) :: {:ok, map()} | {:error, term()}
  def session_status(coordinator, owner) when is_pid(coordinator) and is_map(owner) do
    safe_call(coordinator, {:session_status, owner}, @session_status_timeout_ms)
  end

  @doc false
  @spec reconciliation_fields() :: [atom()]
  def reconciliation_fields, do: @reconciliation_fields

  @doc false
  @spec reconciliation_query(pid(), owner()) :: {:ok, map()} | {:error, term()}
  def reconciliation_query(coordinator, owner) when is_pid(coordinator) and is_map(owner),
    do: safe_call(coordinator, {:reconciliation_query, owner}, :infinity)

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
       owner_command: Keyword.get(options, :owner_command),
       prior_tx_id: Keyword.get(options, :prior_tx_id),
       attempt: 1,
       # Technical depth: one counter for the whole acquisition, never reset. A
       # counter reset by succession contention would multiply the budget by
       # `@max_historical_attempts` and put the unbounded wait back.
       acquisition_retries: 0,
       transaction: nil,
       incarnation: nil,
       lane: OwnerLane.new(Keyword.fetch!(options, :store)),
       workers: Keyword.fetch!(options, :workers),
       owner_workers: Keyword.fetch!(options, :owner_workers),
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
       cleanup_grace_ms: Keyword.fetch!(options, :cleanup_grace_ms),
       context_token_budget: Keyword.fetch!(options, :context_token_budget),
       # The runs whose model dispatch this owner staged itself. A run at
       # `model_dispatched` that is not in here was dispatched by a predecessor,
       # and its attempt is abandoned rather than re-run under the same identity.
       adopted: MapSet.new(),
       in_flight: %{},
       pending_cleanup: %{},
       streams: %{},
       deadline_timers: %{},
       policy_timers: %{},
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
  def handle_call({:command, supplied_owner, command}, _from, state) do
    cond do
      state.phase != :ready ->
        {:reply, {:error, :owner_acquiring}, state}

      supplied_owner != state.owner ->
        {:reply, {:error, :superseded_owner}, state}

      state.superseded ->
        {:reply, {:error, :superseded_owner}, state}

      true ->
        case Control.current_owner(state.control, state.session_id, state.owner) do
          :ok ->
            commit_command(state, command)

          {:error, :superseded_owner} ->
            {:reply, {:error, :superseded_owner}, %{state | superseded: true}}

          {:error, :runtime_unavailable} = error ->
            {:reply, error, state}
        end
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
        active_context_token_budget:
          SessionState.context_token_budget(state.durable, state.durable.active_run_id),
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

    state =
      if superseded do
        # An earlier Control or Store fence may already have marked this owner
        # stale without ending its effect-free model work. The actual handoff
        # notification is still the event that terminates and drains that worker
        # and states the model domain abandoned; the boolean must not suppress
        # those idempotent local actions.
        state
        |> terminate_superseded_effect_free_work()
        |> abandon_open_streams()
      else
        state
      end

    continue_after_owner_loss(%{state | superseded: superseded or state.superseded})
  end

  @impl GenServer
  def handle_info(:retry_owner, %{phase: phase} = state)
      when phase in [:discovering, :acquiring, :recovering] do
    advance_acquisition(state)
  end

  def handle_info(:advance_work, state), do: advance_work(state)

  def handle_info({:executor_progress_owner_lost, run_id, relay}, state) do
    next =
      case Map.fetch(state.streams, {:executor, run_id}) do
        {:ok, stream} ->
          if ExecutorStream.relay(stream) == relay do
            state
            |> discard_tool_stream(run_id)
            |> Map.put(:superseded, true)
          else
            state
          end

        :error ->
          state
      end

    continue_after_owner_loss(next)
  end

  # Concept: the deadline fires against the run that committed it, and only
  # while this owner still speaks for that run.
  #
  # Technical depth: the clock is read again rather than trusted from the timer,
  # because a timer that fired early would otherwise end a run inside its own
  # bound. A superseded or acquiring owner does nothing: the successor owns the
  # decision, and two owners committing one terminal is exactly what the
  # succession fence exists to prevent.
  def handle_info({:run_deadline, run_id, deadline}, state) do
    state = %{state | deadline_timers: Map.delete(state.deadline_timers, run_id)}

    cond do
      state.phase != :ready or state.superseded ->
        {:noreply, state}

      not Map.has_key?(state.durable.pending_work, run_id) ->
        {:noreply, state}

      committed_deadline(state, run_id) != deadline ->
        {:noreply, state}

      not deadline_reached?(state, run_id) ->
        {:noreply, arm_deadline(state, run_id)}

      true ->
        case Control.current_owner(state.control, state.session_id, state.owner) do
          :ok ->
            finish_at_deadline(state, run_id)

          {:error, :superseded_owner} ->
            {:noreply, %{state | superseded: true}}

          # Control is gone, so there is nothing left to commit a terminal
          # against. The successor rebuilds this decision from the journal.
          {:error, :runtime_unavailable} ->
            {:noreply, state}
        end
    end
  end

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

      {{:cleanup, run_id, _pid}, remaining} ->
        Process.demonitor(reference, [:flush])
        complete_cleanup(%{state | in_flight: remaining}, run_id, admitted_cleanup(result))

      {{:policy, run_id, _pid}, remaining} ->
        Process.demonitor(reference, [:flush])

        state
        |> Map.put(:in_flight, remaining)
        |> cancel_policy_timeout(reference)
        |> disarm_deadline(run_id)
        |> complete_policy_consultation(run_id, result)
    end
  end

  def handle_info({:cleanup_settled, run_id, disposition}, state),
    do: complete_cleanup(state, run_id, disposition)

  def handle_info({:DOWN, reference, :process, _pid, reason}, state) do
    case Map.pop(state.in_flight, reference) do
      {nil, _remaining} ->
        {:noreply, state}

      # A cleanup worker that died told this coordinator nothing, which is
      # unproved cleanup rather than a reason to stop the session: the run still
      # owes a truthful ending and stopping here would leave it without one.
      {{:cleanup, run_id, _pid}, remaining} ->
        complete_cleanup(%{state | in_flight: remaining}, run_id, :unconfirmed)

      {{:policy, run_id, _pid}, remaining} ->
        state
        |> Map.put(:in_flight, remaining)
        |> cancel_policy_timeout(reference)
        |> disarm_deadline(run_id)
        |> complete_policy_consultation(run_id, {:deny, :policy_unavailable})

      {_work, remaining} ->
        {:stop, {:worker_failed, reason}, %{state | in_flight: remaining}}
    end
  end

  def handle_info({:policy_timeout, reference, run_id}, state) do
    case Map.pop(state.in_flight, reference) do
      {{:policy, ^run_id, pid}, remaining} ->
        _ = Task.Supervisor.terminate_child(state.owner_workers, pid)
        _ = take_worker_result(reference)

        state =
          state
          |> Map.put(:in_flight, remaining)
          |> cancel_policy_timeout(reference)
          |> disarm_deadline(run_id)

        if deadline_reached?(state, run_id) do
          finish_at_deadline(state, run_id)
        else
          complete_policy_consultation(state, run_id, {:deny, :policy_unavailable})
        end

      {_other, remaining} ->
        {:noreply, cancel_policy_timeout(%{state | in_flight: remaining}, reference)}
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

  # The executor port answers `{:ok, :cleaned}` or `{:ok, :unconfirmed}` and
  # nothing else. Anything else arriving here is a cleanup that did not say what
  # it achieved, which is unproved.
  defp admitted_cleanup({:ok, :cleaned}), do: :cleaned
  defp admitted_cleanup(_other), do: :unconfirmed

  defp advance_acquisition(%{phase: :recovering} = state), do: recover_committed_owner(state)

  defp advance_acquisition(%{phase: :discovering} = state), do: discover_and_advance(state)
  defp advance_acquisition(%{phase: :acquiring} = state), do: transact_owner(state)

  defp discover_and_advance(%{attempt: attempt} = state)
       when attempt <= @max_historical_attempts do
    discover_and_advance_owner(state)
  end

  defp discover_and_advance(state), do: {:stop, :owner_attempt_limit, state}

  defp discover_and_advance_owner(%{owner_command: owner_command} = state)
       when is_map(owner_command) do
    with {:ok, prior_tx_id} <- discover_prior_tx_id(state),
         :ok <- prior_transaction_resolved(state, prior_tx_id),
         {:ok, head} <- ownership_head(state),
         {:ok, attempt_generation, expected_generation} <- owner_attempt_generation(state),
         {:ok, transaction, incarnation} <-
           build_command_owner_candidate(state, head, attempt_generation),
         {:ok, stage} <-
           Store.stage_owner_attempt(
             Map.put(owner_command, :attempt_generation, attempt_generation),
             expected_generation,
             owner_identity("owner_stage_tx", state.succession_id, attempt_generation),
             transaction
           ) do
      transact_owner_stage(
        %{
          state
          | phase: :acquiring,
            prior_tx_id: prior_tx_id,
            transaction: transaction,
            incarnation: incarnation
        },
        stage
      )
    else
      :retry -> retry_owner(state, :store_unavailable)
      {:error, reason} -> {:stop, reason, state}
    end
  end

  defp discover_and_advance_owner(state) do
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
      :retry -> retry_owner(state, :store_unavailable)
      {:error, reason} -> {:stop, reason, state}
    end
  end

  defp owner_attempt_generation(%{owner_command: %{open: nil}}), do: {:ok, 1, 0}

  defp owner_attempt_generation(%{
         store: store,
         session_id: session_id,
         owner_command: %{
           open: %{attempt_generation: generation, candidate_tx_id: candidate_tx_id}
         }
       }) do
    case Store.transaction_status(store, session_id, @mutation_domain, candidate_tx_id) do
      :absent -> {:ok, generation + 1, generation}
      {:terminal, {:not_committed, _reason}} -> {:ok, generation + 1, generation}
      {:terminal, :committed} -> {:error, :runtime_command_inconsistent}
      :unavailable -> :retry
    end
  end

  defp build_command_owner_candidate(state, head, attempt_generation) do
    tx_id = owner_identity("owner_tx", state.succession_id, attempt_generation)
    incarnation = owner_identity("owner_incarnation", state.succession_id, attempt_generation)
    owner_command = Map.put(state.owner_command, :attempt_generation, attempt_generation)

    case Store.advance_owner(
           state.session_id,
           @mutation_domain,
           tx_id,
           head.owner_epoch,
           head.journal_version,
           incarnation,
           owner_command
         ) do
      {:ok, transaction} -> {:ok, transaction, incarnation}
      {:error, reason} -> {:error, reason}
    end
  end

  defp transact_owner_stage(state, stage) do
    {outcome, lane} = OwnerLane.transact(state.lane, stage)
    state = %{state | lane: lane}

    case outcome do
      {:committed, tx_id, %{type: :stage_owner_attempt}} when tx_id == stage.tx_id ->
        transact_owner(state)

      {:not_committed, reason}
      when reason in [:stale_attempt_generation, :command_completed] ->
        retry_command_owner(state)

      {:not_committed, reason} ->
        {:stop, reason, state}

      {:commit_unknown, _tx_id} ->
        retry_owner(%{state | phase: :discovering}, :commit_unknown)

      {:fenced, :commit_unknown} ->
        retry_owner(%{state | phase: :discovering}, :commit_unknown)
    end
  end

  defp retry_command_owner(state) do
    case Store.runtime_command(state.store, Map.delete(state.owner_command, :open)) do
      {:completed, %{result: session_id}} when session_id == state.session_id ->
        GenServer.cast(state.control, {:owner_replayed, self(), state.session_id})
        {:stop, :normal, state}

      {:open, open} ->
        advance_acquisition(%{
          state
          | phase: :discovering,
            owner_command: Map.put(state.owner_command, :open, open),
            transaction: nil,
            incarnation: nil,
            attempt: state.attempt + 1
        })

      :unavailable ->
        retry_owner(%{state | phase: :discovering}, :store_unavailable)

      _other ->
        {:stop, :runtime_command_conflict, state}
    end
  end

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
        retry_owner(state, :commit_unknown)

      {:fenced, :commit_unknown} ->
        retry_owner(state, :commit_unknown)
    end
  end

  defp recover_committed_owner(state) do
    with {:ok, records} <- load_all_records(state.store, state.session_id),
         {:ok, events} <- load_all_events(state.store, state.session_id),
         {:ok, durable} <- SessionState.recover(state.session_id, records, events),
         durable = SessionState.declare_cleanup_grace(durable, state.cleanup_grace_ms),
         true <- durable.owner_epoch == state.owner.owner_epoch,
         true <- durable.owner_incarnation_id == state.owner.owner_incarnation_id,
         true <- durable.owner_transaction_id == state.owner.transaction_id do
      ready = %{state | phase: :ready, durable: durable, transaction: nil, incarnation: nil}
      GenServer.cast(state.control, {:owner_ready, self(), state.owner, durable})
      send(self(), :advance_work)
      {:noreply, ready}
    else
      {:error, :store_unavailable} -> retry_owner(state, :store_unavailable)
      :unavailable -> retry_owner(state, :store_unavailable)
      false -> {:stop, :owner_recovery_superseded, state}
      {:error, reason} -> {:stop, reason, state}
      _other -> {:stop, :owner_recovery_failed, state}
    end
  end

  # Concept: retrying is bounded, and running out of retries is an answer the
  # caller receives rather than a silence it waits through.
  #
  # Technical depth: control holds the caller's `from`, so the coordinator cannot
  # reply itself; it casts the reason it actually failed for and then stops. The
  # cast is a cast: control still makes no synchronous call into a coordinator,
  # and this direction was never half of that cycle. Order matters for the reply
  # being exactly one. Signals from this process to control are delivered in the
  # order they were sent, and the monitor's `:DOWN` is one of them, so control
  # handles the cast first, answers with the true reason, and clears the waiter
  # the `:DOWN` behind it would otherwise answer a second time with
  # `:owner_recovery_failed`. Stopping with `:normal` is deliberate: this
  # coordinator did its job -- it reported a Store it could not reach -- and a
  # temporary child that reports and exits is not a crash to log.
  defp retry_owner(state, reason) do
    retries = state.acquisition_retries + 1

    if retries > @max_owner_retries do
      GenServer.cast(state.control, {:owner_unavailable, self(), state.session_id, reason})
      {:stop, :normal, state}
    else
      Process.send_after(self(), :retry_owner, retry_delay(retries))
      {:noreply, %{state | acquisition_retries: retries}}
    end
  end

  # Technical depth: doubling from the first delay, clamped at the ceiling.
  defp retry_delay(retries),
    do: min(@owner_retry_ms * Integer.pow(2, retries - 1), @owner_retry_ceiling_ms)

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
    {state, resolved} = resolve_command(state, command)

    case SessionState.propose(state.durable, command, resolved) do
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
          state
          |> apply_transaction(transaction, proposal)
          |> begin_admitted_cleanup()
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
    case Control.current_owner(state.control, state.session_id, state.owner) do
      :ok ->
        # Concept: a run an operator aborted schedules nothing further.
        #
        # Technical depth: ADR 0009's second step, and what makes the first one
        # safe. The admission now leaves the run active and its work pending --
        # because neither is over until the cleanup's result is committed -- so
        # without this the very next `:advance_work` would dispatch the run's
        # next turn instead of ending it. It is checked here, at the single
        # entry to scheduling, rather than inside a stage.
        case SessionState.aborting_run(state.durable) do
          nil ->
            case SessionState.pending_work(state.durable) do
              [] -> {:noreply, state}
              [work | _rest] -> advance_run(state, work)
            end

          run_id ->
            resume_aborting_run(state, run_id)
        end

      {:error, :superseded_owner} ->
        {:noreply, %{state | superseded: true}}

      # Control is gone. Pending work stays pending rather than being abandoned
      # under a supersession that no successor ever claimed.
      {:error, :runtime_unavailable} ->
        {:noreply, state}
    end
  end

  defp advance_work(state), do: {:noreply, state}

  # Concept: an abort is on disk and this owner is not cleaning it up. Either it
  # already is, or it never will.
  #
  # Technical depth: the first case is ordinary -- the cleanup is in flight and
  # its result will commit the ending. The second is recovery: a previous owner
  # admitted the abort and died before committing what the cleanup achieved, so
  # this owner finds the marker with nothing in flight. It cannot prove the
  # cleanup ran, half ran, or never started, and re-running it would be blindly
  # retrying work whose effect is exactly what is unknown. `outcome_unknown`
  # carrying a reconciliation reference is the only honest ending.
  #
  # The operation is settled before the run, because ADR 0009 derives the run
  # outcome from the owned operation outcomes rather than from the fact that an
  # abort was admitted. A recovering owner that committed only the run terminal
  # left the dispatched call with no ending of its own: an operator saw
  # `tool.started` and nothing after it, and the run's outcome was a second,
  # independent statement of the same unknown rather than a consequence of it.
  defp resume_aborting_run(state, run_id) do
    if Map.has_key?(state.pending_cleanup, run_id) do
      {:noreply, state}
    else
      case commit_owned_operation_unknown(state, run_id) do
        {:ok, settled} ->
          commit_terminal(
            settled,
            run_id,
            "outcome_unknown",
            %{reconciliation_ref: reconciliation_ref(state, run_id)}
          )

        {:error, reason} ->
          {:stop, {:tool_result_failed, reason}, state}
      end
    end
  end

  # Concept: a run holding an effect nobody could prove does nothing further.
  #
  # Technical depth: this is the one place the coordinator asks whether the run
  # may still act, and it is asked before the stage is read rather than inside
  # any stage's branch. Asking it only at settlement stopped the next model call
  # and nothing else: the remaining calls of the same assistant batch sit at
  # `effect_pending`, which is dispatched directly, so an unprovable first call
  # still ran every effect queued behind it. `outcome_unknown` is terminal for
  # the affected run, and terminal has to mean no further effects, not merely no
  # further requests.
  #
  # An effect already in flight is the one thing this does not stop. It is
  # dispatched, its process tree is owned, and ending the run over it here would
  # abandon that tree without cancelling it. Its own receipt brings the run back
  # through this check a moment later, which is where it ends.
  defp advance_run(state, %{stage: "effect_dispatched"}), do: {:noreply, state}

  defp advance_run(state, work) do
    if SessionState.unproven_effect?(state.durable, work.run_id) do
      finish_unknown(state, work.run_id)
    else
      dispatch_stage(state, work)
    end
  end

  defp dispatch_stage(state, %{stage: "model_pending"} = work),
    do: before_deadline(state, work, &prepare_model_request/2)

  defp dispatch_stage(state, %{stage: "model_dispatched"} = work),
    do: before_deadline(state, work, &start_model_work/2)

  defp dispatch_stage(state, %{stage: "effect_pending"} = work), do: prepare_effect(state, work)

  defp dispatch_stage(state, %{stage: "turn_settled"} = work), do: settle_turn(state, work)

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

    {blocks, project_receipt} = project_blocks(state)

    staging = %{
      run_id: run_id,
      elements: elements,
      steer: steer,
      deadline: run_deadline(declared)
    }

    with {:ok, max_tokens} <- declared_max_tokens(state),
         staging = Map.put(staging, :max_tokens, max_tokens),
         {:ok, proposal} <- stage_candidate(state, staging, blocks, project_receipt),
         {:ok, next} <- commit_internal(state, proposal) do
      send(self(), :advance_work)
      {:noreply, adopt_run(next, run_id)}
    else
      # Concept: a request that cannot be admitted ends its run, and calls
      # nobody.
      #
      # Technical depth: ADR 0017 commits the compact refusal, the failed
      # terminal, and its public event in one transaction, and dispatches
      # nothing. The run is over: a retained terminal is final and the same run
      # never re-enters staging, so changing context, configuration, or policy
      # requires a newly admitted run.
      {:refused, refusal} -> commit_context_refusal(state, run_id, refusal)
      {:error, reason} -> {:stop, {:model_request_failed, reason}, state}
    end
  end

  # Concept: optional project content is withheld whole, and only after the
  # required request has been proved admissible without it.
  #
  # Technical depth: ADR 0017 permits withholding exactly one class and never
  # trimming. If the optional-inclusive candidate exceeds the committed token
  # total or the Store record ceiling, the whole project class is removed, the
  # request is canonicalized again, and the record cost is resolved to its own
  # fixed point. The declined receipt names the dimension, the optional-inclusive
  # observation, and the limit, so an operator can see what was withheld and
  # why, and the task continues. A required-only candidate that still fails has
  # nothing optional left to remove and becomes the compact refusal.
  defp stage_candidate(state, staging, [], project_receipt),
    do: staged_proposal(state, staging, [], project_receipt)

  defp stage_candidate(state, staging, blocks, project_receipt) do
    case staged_proposal(state, staging, blocks, project_receipt) do
      {:refused, %{"dimension" => dimension} = refusal}
      when dimension in ["context_tokens", "context_record_bytes"] ->
        staged_proposal(state, staging, [], withheld_project_receipt(dimension, refusal))

      other ->
        other
    end
  end

  defp withheld_project_receipt(dimension, refusal) do
    disposition =
      case dimension do
        "context_tokens" -> :context_token_budget
        "context_record_bytes" -> :context_record_bytes
      end

    ProjectResource.receipt(disposition, %{
      "dimension" => dimension,
      "observed" => Map.fetch!(refusal, "observed"),
      "limit" => Map.fetch!(refusal, "limit")
    })
  end

  defp staged_proposal(state, staging, blocks, project_receipt) do
    messages =
      Conversation.project(staging.elements, system: system_block(state), project_blocks: blocks)

    with {:ok, request} <-
           Model.request(state.model.model, messages ++ steer_message(staging.steer),
             tools: state.active_tools,
             sampling: %{"max_tokens" => staging.max_tokens},
             deadline: staging.deadline
           ),
         {:ok, receipt} <-
           context_receipt(
             request,
             context_sources(
               project_receipt,
               Conversation.session_entries(staging.elements),
               staging.steer,
               staging.run_id
             ),
             project_receipt,
             state.context_token_budget
           ) do
      SessionState.propose_model_request(state.durable, staging.run_id, request,
        applied_steer: staging.steer && staging.steer.command_id,
        context_receipt: receipt
      )
    end
  end

  defp commit_context_refusal(state, run_id, refusal) do
    state = disarm_deadline(state, run_id)

    with {:ok, proposal} <- SessionState.propose_context_refusal(state.durable, run_id, refusal),
         {:ok, next} <- commit_internal(state, proposal) do
      send(self(), :advance_work)
      {:noreply, %{next | adopted: MapSet.delete(next.adopted, run_id)}}
    else
      {:error, reason} -> {:stop, {:context_refusal_failed, reason}, state}
    end
  end

  # Concept: a run holding an effect nobody could prove ends saying so.
  #
  # Technical depth: no bound is named, because no bound ended this run — the
  # unknown effect did, whatever else the run had also reached. The reference is
  # the same stable session-and-run reconciliation reference the deadline and
  # abort paths emit, so an operator reconciling this run names one identity
  # however the run was stopped. It is required to be a non-empty binary: the
  # projection refuses an `outcome_unknown` that carries no reference, because a
  # run that says the effect's truth is unknown and offers nothing to reconcile
  # against is an ending an operator cannot act on.
  defp finish_unknown(state, run_id) do
    {_declared, charged} = SessionState.accounting(state.durable, run_id)

    commit_terminal(state, run_id, "outcome_unknown", %{
      accounting_source: charged.source && Atom.to_string(charged.source),
      reconciliation_ref: reconciliation_ref(state, run_id)
    })
  end

  # Concept: a settled turn either continues the loop or ends the run at a
  # declared bound.
  #
  # Technical depth: an unprovable effect never reaches here — `advance_run`
  # answers that before any stage is dispatched, which is why this reads bounds
  # alone and why `bound_reached(:deadline)` is not called a clean stop
  # anywhere in this file. The decision is committed as a durable fact rather
  # than re-derived later, because it reads the wall clock and a clock-reading
  # decision cannot be replayed.
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

  # Concept: every byte class staged for a model call says where it came from,
  # what trust it carries, and what it cost before the provider sees it.
  #
  # Technical depth: this is one final ordered receipt over the three provenance
  # classes ADR 0010 fixes for M2. The provider identity is the fixed local
  # context stage, not the model provider; a future pluggable pipeline can change
  # that identity without migrating the descriptor algebra. Project-resource
  # admission remains nested so a declined class keeps its exact reason even
  # though it contributes no block.
  defp context_receipt(request, message_sources, project_receipt, context_token_budget) do
    # Technical depth: `Enum.zip/2` truncates silently. A projection/source
    # disagreement is therefore refused before commit instead of producing a
    # receipt that simply omits the tail of the request it claims to describe.
    if length(request.messages) == length(message_sources) do
      message_blocks =
        request.messages
        |> Enum.zip(message_sources)
        |> Enum.map(fn {message, source} ->
          context_descriptor(source, Canonical.encode(message))
        end)

      blocks = message_blocks ++ Enum.map(request.tools, &tool_descriptor/1)
      totals = context_totals(blocks)

      {:ok,
       %{
         "provider_identity" => "loopex.context.reference",
         "provider_revision" => 2,
         "transformer_identity" => nil,
         "transformer_revision" => nil,
         "selector_identity" => nil,
         "selector_revision" => nil,
         "token_estimator" => Bounds.estimator(),
         "descriptor_canonicalization_version" => @descriptor_canonicalization_version,
         "blocks" => blocks,
         "totals" => totals,
         "project_resource" => project_receipt,
         "context_token_budget" => context_token_budget,
         "provider_estimated_tokens" => totals["token_cost"],
         "context_record_byte_ceiling" => Store.max_item_bytes(),
         "record_byte_cost" => 0,
         "ordered_descriptor_digest" => ordered_descriptor_digest(blocks)
       }}
    else
      {:error, :context_receipt_source_mismatch}
    end
  end

  # Concept: the ordered descriptor list is bound by one digest rather than
  # re-listed anywhere it has to be referred to.
  #
  # Technical depth: the preimage is the exact ASCII domain, one zero byte, and
  # then each descriptor's eight-byte unsigned big-endian canonical length
  # followed by its canonical bytes. Length framing is what stops two different
  # descriptor sequences sharing a preimage. Hashing incrementally means no
  # aggregate encoding of the whole list is ever allocated, which matters because
  # the compact refusal has to carry this digest without carrying the list.
  defp ordered_descriptor_digest(blocks) do
    blocks
    |> Enum.reduce(
      :crypto.hash_update(
        :crypto.hash_init(:sha256),
        @descriptor_digest_domain <> <<0>>
      ),
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

  defp context_sources(project_receipt, session_entries, steer, run_id) do
    [source(%{"kind" => "system", "identity" => "loopex.system.v1"}, "system")] ++
      project_sources(project_receipt) ++
      Enum.map(session_entries, fn {source_reference, _message} ->
        source(source_reference, "session")
      end) ++ steer_sources(steer, run_id)
  end

  # Concept: a tool is charged for what the model is actually shown.
  #
  # Technical depth: ADR 0017 charges the model-facing projection for content
  # digest, byte cost, and token cost, while the source reference keeps the whole
  # generation triple and the full definition digest. Changing storage-only tool
  # metadata therefore changes retained source identity and record bytes without
  # misreporting a provider-context cost that did not change.
  defp tool_descriptor(tool) do
    source_reference = %{
      "kind" => "tool_definition",
      "tool_id" => Map.fetch!(tool, "tool_id"),
      "tool_version" => Map.fetch!(tool, "tool_version"),
      "definition_digest" => ToolDefinition.definition_digest(tool)
    }

    context_descriptor(
      source(source_reference, "system"),
      Canonical.encode(ToolDefinition.model_facing(tool))
    )
  end

  defp project_sources(%{
         "disposition" => "staged",
         "detail" => %{
           "workspace_ref" => workspace_ref,
           "manifest_digest" => manifest_digest,
           "entries" => entries
         }
       }) do
    Enum.map(entries, fn entry ->
      source(
        %{
          "kind" => "project_resource",
          "workspace_ref" => workspace_ref,
          "manifest_digest" => manifest_digest,
          "relative_label" => entry["relative_label"]
        },
        "project_resource"
      )
    end)
  end

  defp project_sources(_declined), do: []

  defp steer_sources(nil, _run_id), do: []

  defp steer_sources(%{command_id: command_id}, run_id),
    do: [
      source(
        %{"kind" => "session_steer", "run_id" => run_id, "command_id" => command_id},
        "session"
      )
    ]

  # Concept: a source reference is structured data, not a delimiter-joined
  # string.
  #
  # Technical depth: ADR 0017 fixes seven exact key sets. Identifiers keep the
  # bound of the durable record that supplied them and no formatter has to
  # reparse one string to recover a member, so an identifier containing a
  # delimiter stays distinguishable instead of colliding with a different
  # reference that happens to concatenate the same way.
  defp source(source_reference, provenance_class) do
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

  defp context_descriptor(source, bytes) do
    Map.merge(source, %{
      "content_digest" => Canonical.digest_bytes(bytes),
      "byte_cost" => byte_size(bytes),
      "token_cost" => Bounds.estimate(bytes)
    })
  end

  # Technical depth: all three provenance buckets are always present, using zero
  # costs for a class with no block, so a consumer reads the same shape whether
  # or not a class contributed and the three buckets always sum back to both
  # outer totals.
  defp context_totals(blocks) do
    by_provenance =
      Map.new(~w(system session project_resource), fn provenance ->
        {provenance, sum_costs(Enum.filter(blocks, &(&1["provenance_class"] == provenance)))}
      end)

    Map.put(sum_costs(blocks), "by_provenance", by_provenance)
  end

  defp sum_costs(blocks) do
    Enum.reduce(blocks, %{"byte_cost" => 0, "token_cost" => 0}, fn block, totals ->
      %{
        "byte_cost" => totals["byte_cost"] + block["byte_cost"],
        "token_cost" => totals["token_cost"] + block["token_cost"]
      }
    end)
  end

  defp steer_message(nil), do: []
  defp steer_message(%{content: content}), do: [%{"role" => "user", "content" => content}]

  defp commit_terminal(state, run_id, outcome, detail) do
    state = disarm_deadline(state, run_id)

    with {:ok, proposal} <-
           SessionState.propose_run_terminal(state.durable, run_id, outcome, detail),
         {:ok, next} <- commit_internal(state, proposal) do
      # A run that has ended is no longer this owner's to adopt, and a session
      # that runs for a long time should not accumulate one identifier per run
      # it has finished.
      {:noreply, %{next | adopted: MapSet.delete(next.adopted, run_id)}}
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

  # Concept: a command chooses the declared bounds its run will use.
  #
  # Technical depth: the configured deadline stays a duration here and in the
  # admitting record. `run_deadline/1` converts it to an instant only while the
  # first model request is staged, and that request commits the instant. A
  # command may name its own bounds and they win, which is how a host with a
  # per-run policy overrides the runtime default without either being implicit.
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

  # Concept: the operator's deadline is checked before a provider is called, not
  # only in the gaps between turns.
  #
  # Technical depth: a recovering owner arrives holding a request its predecessor
  # committed before it died. Dispatching that request because it is still staged
  # spends a provider call the operator's declared bound had already refused, and
  # a bound that only ever holds while its owner is alive is not a bound. The
  # expiry is therefore decided here, ahead of the call, and the run terminates
  # instead of redispatching.
  defp before_deadline(state, work, dispatch) do
    if deadline_reached?(state, work.run_id) do
      finish_at_deadline(state, work.run_id)
    else
      dispatch.(state, work)
    end
  end

  defp committed_deadline(state, run_id) do
    case SessionState.accounting(state.durable, run_id) do
      {%{deadline: deadline}, _charged} -> deadline
      _undeclared -> nil
    end
  end

  # A run has no deadline instant until its first request commits one, so a run
  # that has staged nothing cannot have expired.
  defp deadline_reached?(state, run_id) do
    case committed_deadline(state, run_id) do
      deadline when is_integer(deadline) -> System.system_time(:millisecond) >= deadline
      _undeclared -> false
    end
  end

  # Concept: a provider that stalls past the deadline is stopped, not waited for.
  #
  # Technical depth: the timer is armed against the instant the run committed, so
  # what bounds the call is the run's own declared deadline rather than a
  # per-call timeout that could outlast it — the two can never disagree because
  # there is only one value. It is armed at dispatch and disarmed the moment the
  # run stops owning a live provider call, so a finished run leaves nothing
  # scheduled behind it and a run whose turn moved on to a tool is bounded by the
  # deadline the job itself carries rather than by a second clock here.
  defp arm_deadline(state, run_id) do
    state = disarm_deadline(state, run_id)

    case committed_deadline(state, run_id) do
      deadline when is_integer(deadline) ->
        remaining = max(deadline - System.system_time(:millisecond), 0)
        timer = Process.send_after(self(), {:run_deadline, run_id, deadline}, remaining)
        %{state | deadline_timers: Map.put(state.deadline_timers, run_id, timer)}

      _undeclared ->
        state
    end
  end

  defp disarm_deadline(state, run_id) do
    case Map.pop(state.deadline_timers, run_id) do
      {nil, _remaining} ->
        state

      {timer, remaining} ->
        _ = Process.cancel_timer(timer)
        %{state | deadline_timers: remaining}
    end
  end

  # Concept: reaching the deadline is an ending that has to be earned.
  #
  # Technical depth: the same cancellation an abort runs, for the same reason —
  # `bound_reached(:deadline)` may claim the run stopped cleanly only where every
  # owned operation reached a validated terminal fact and every owned process
  # tree was confirmed cleaned. A committed `outcome_unknown` effect, or a
  # cancellation that could not prove either, outranks it and ends the run
  # carrying the reference the operator reconciles against.
  defp finish_at_deadline(state, run_id) do
    {declared, charged} = SessionState.accounting(state.durable, run_id)

    detail = %{
      bound: "deadline",
      observed: System.system_time(:millisecond),
      declared_limit: run_deadline(declared),
      accounting_source: charged.source && Atom.to_string(charged.source)
    }

    # The same cleanup an abort runs, through the same path, for the same reason
    # -- and off this process for the same reason too. A deadline reached while a
    # host-supplied `cancel/2` blocks would otherwise leave this coordinator
    # unable to answer an operator's interrupt for as long as it blocked, which
    # is the defect an abort had and this shares by construction.
    {:noreply, begin_cleanup(state, run_id, {:deadline, detail})}
  end

  defp start_model_work(state, work) do
    cond do
      in_flight?(state, :model, work.run_id) ->
        {:noreply, state}

      not MapSet.member?(state.adopted, work.run_id) ->
        adopt_inherited_attempt(state, work)

      true ->
        module = state.model.module
        request = work.request
        options = state.model.options
        {stream, progress} = model_progress_fun(state, work)

        task =
          Task.Supervisor.async_nolink(state.owner_workers, fn ->
            module.complete(request, options, progress)
          end)

        state = %{state | streams: Map.put(state.streams, {:model, work.run_id}, stream)}
        state = arm_deadline(state, work.run_id)
        {:noreply, put_in_flight(state, task.ref, {:model, work.run_id, task.pid})}
    end
  end

  # Concept: a provider call this owner did not make is not this owner's
  # attempt, and dispatching those bytes again is a second call.
  #
  # Technical depth: a predecessor that died with a model call in flight leaves
  # the run at `model_dispatched`, and a successor used to dispatch the same
  # staged bytes under the same attempt. ADR 0011 makes a stream domain one
  # *attempt's* progress stream, so reusing the attempt reuses the domain and two
  # owners produce into one label. A review drove it end to end: the successor
  # emitted sequence zero and a complete closure, and the predecessor's producer
  # then emitted sequences zero, one and two under the identical domain, so the
  # closure was no longer last and sequence zero appeared twice.
  #
  # Abandoning the inherited attempt is what the abandonment record already
  # exists to do, and its own reducer says so: the increment is what makes a
  # redispatch open a new domain rather than reuse the abandoned one, and what
  # bounds retries across succession. It also charges the call the predecessor
  # actually made, which a successor silently reusing the attempt did not.
  #
  # A run this owner staged itself is adopted at that commit, so the ordinary
  # first dispatch is never mistaken for an inherited one, and the abandonment
  # adopts the run so the retry that follows is this owner's own.
  #
  # A live predecessor closes its relay when Control supersedes it. If it dies
  # first, its linked transient plane ends without fabricating a disposition;
  # absence is the incomplete view ADR 0011 defines. This successor never
  # fabricates that closure or its count; it advances the durable attempt and
  # opens a different domain for the replacement dispatch.
  defp adopt_inherited_attempt(state, work) do
    state = adopt_run(state, work.run_id)

    if retry_available?(state, work.run_id) do
      case commit_abandoned_attempt(state, work.run_id) do
        {:ok, next} ->
          if retry_available?(next, work.run_id) do
            send(self(), :advance_work)
            {:noreply, next}
          else
            {:stop, {:model_failed, :retry_exhausted}, next}
          end

        {:error, :no_attempt_pending} ->
          send(self(), :advance_work)
          {:noreply, state}

        {:error, reason} ->
          {:stop, {:model_attempt_failed, reason}, state}
      end
    else
      # The durable attempt is already the first one the declared allowance does
      # not permit. It was never dispatched, so abandoning it would both charge
      # work that did not happen and advance to another identity a later owner
      # could mistake for permission to call again.
      {:stop, {:model_failed, :retry_exhausted}, state}
    end
  end

  defp accept_counted_model_result(state, run_id, reply, count) do
    state = disarm_deadline(state, run_id)

    case SessionState.propose_model_result(
           state.durable,
           run_id,
           reply,
           active_generations(state)
         ) do
      {:ok, proposal} ->
        case retain_terminal_operation_fact(state, proposal) do
          {:ok, next} ->
            next = close_model_stream(next, run_id, {:complete, count})
            send(self(), :advance_work)
            {:noreply, next}

          {:retained, next} ->
            # The Store already fixed the reply and its producer count before
            # Control moved to the successor. That retained fact, rather than
            # this stale coordinator's authority, is what makes `complete`
            # truthful. The successor never closes or reuses this relay.
            next
            |> close_model_stream(run_id, {:complete, count})
            |> continue_after_owner_loss()

          {:error, reason}
          when reason in [:stale_owner_epoch, :stale_owner_incarnation_id, :superseded_owner] ->
            # No model result committed under this transaction, so the stale
            # owner has no retained fact and no authority for a closure. Ending
            # the relay without one leaves the successor to own abandonment and
            # retry under the durable attempt transition.
            state
            |> discard_model_stream(run_id)
            |> Map.put(:superseded, true)
            |> continue_after_owner_loss()

          {:error, reason} ->
            {:stop, {:model_result_failed, reason}, state}
        end

      {:error, reason} ->
        case reason do
          :invalid_model_reply -> accept_model_result(state, run_id, {:error, reason})
          _other -> {:stop, {:model_result_failed, reason}, state}
        end
    end
  end

  defp adopt_run(state, run_id),
    do: %{state | adopted: MapSet.put(state.adopted, run_id)}

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
    base_event_sequence = state.durable.event_sequence

    # Concept: the first delta of a domain is sequence zero.
    #
    # Technical depth: ADR 0011 fixes the algebra as zero-based, so a closing
    # count of `n` and a last sequence of `n - 1` describe the same stream.
    # Incrementing before reading made the first item one, which left every
    # consumer's gap check off by one against the count it is compared with. The
    # relay hands out the value it holds and then advances, in one process, so
    # two emissions can never claim one number and nothing has to be reconciled
    # afterwards.
    {:ok, relay} =
      StreamRelay.open(
        state.workers,
        state.progress_to,
        fn delta, sequence ->
          Map.merge(delta, %{
            turn_id: turn_id,
            stream_domain_id: domain,
            model_sequence: sequence,
            base_event_sequence: base_event_sequence
          })
        end,
        fn disposition, count ->
          StreamDomain.model_closed(
            turn_id,
            domain,
            base_event_sequence,
            disposition,
            count
          )
        end
      )

    stream = %{domain: domain, turn_id: turn_id, relay: relay}

    {stream,
     fn delta ->
       # A malformed delta is dropped here rather than handed on, so it never
       # consumes a sequence and never appears in any total.
       if Model.valid_delta?(delta) do
         _admitted =
           Control.project_progress(
             state.control,
             state.session_id,
             state.owner,
             relay,
             delta
           )
       end

       :ok
     end}
  end

  defp model_operation_id(work), do: stable_id("model-operation", work.run_id, work.turn_number)

  # Concept: an authoritative coordinator closes every ordinary terminal domain
  # exactly once.
  #
  # Technical depth: ADR 0011 fixes what each disposition states. A complete
  # attempt produced the durable artifact of its kind, so its closure carries
  # that producer's own figure -- the reply's `delta_count` -- and the difference
  # between that figure and what a consumer received is the signal the closure
  # exists to give: something did not arrive, whether the plane coalesced it away
  # or this coordinator refused it. An abandoned attempt produced no such figure,
  # so its closure carries the count the relay actually emitted.
  #
  # The relay emits the closure itself, as the last thing it does before it ends,
  # which is what makes ADR 0011's "the closure is the last item of its domain"
  # true rather than nearly true: one process emits every item of a domain, in
  # its own mailbox order, and a producer handing an item to a closed domain is
  # sending to a process that no longer exists.
  #
  # A complete close follows the durable result that makes it truthful. An
  # abandoned close with no retained fact uses `close_current_model_stream/3`
  # below, whose Control admission prevents a handoff from beginning between
  # its ownership check and its closing send.
  defp close_model_stream(state, run_id, disposition) do
    case Map.fetch(state.streams, {:model, run_id}) do
      {:ok, stream} ->
        _stated = StreamRelay.close(stream.relay, disposition)
        %{state | streams: Map.delete(state.streams, {:model, run_id})}

      :error ->
        state
    end
  end

  defp close_current_model_stream(state, run_id, disposition) do
    case Map.fetch(state.streams, {:model, run_id}) do
      {:ok, stream} ->
        case Control.close_progress(
               state.control,
               state.session_id,
               state.owner,
               stream.relay,
               disposition
             ) do
          {:ok, _stated} ->
            %{state | streams: Map.delete(state.streams, {:model, run_id})}

          {:error, :superseded_owner} ->
            state
            |> discard_model_stream(run_id)
            |> Map.put(:superseded, true)

          {:error, _reason} ->
            discard_model_stream(state, run_id)
        end

      :error ->
        state
    end
  end

  defp discard_model_stream(state, run_id) do
    case Map.fetch(state.streams, {:model, run_id}) do
      {:ok, stream} ->
        _ended = StreamRelay.discard(stream.relay)
        %{state | streams: Map.delete(state.streams, {:model, run_id})}

      :error ->
        state
    end
  end

  # Concept: the closing item says how many items this coordinator put on the
  # stream, which is the only count it can vouch for.
  #
  # Technical depth: ADR 0011 fixes what each disposition states. A completed
  # attempt returned a terminal receipt, so its closure carries that receipt's
  # own `progress_count`; an abandoned one returned none, so its closure carries
  # the count the relay emitted, which is exact because the relay emitted all of
  # it and then ended.
  #
  # The two numbers differ whenever `project_progress/2` refuses an event, and
  # that difference is a signal rather than a defect: a consumer comparing the
  # stated total against what reached it learns that something did not arrive.
  # Substituting this runtime's own count would erase the only live evidence a
  # refusal leaves; its accounting is relay-private and diagnostic-only.
  # Concept: only a validated receipt may state a completed stream's count.
  #
  # Technical depth: every call is after `put_executor_fact/3` accepted and
  # durably committed the receipt, whose reducer requires this field to be a
  # non-negative integer. Keeping this clause strict prevents a malformed
  # receipt from being projected as a truthful complete closure before the
  # durable boundary refuses it.
  defp progress_count(%{progress_count: count}) when is_integer(count) and count >= 0,
    do: count

  defp close_tool_stream(state, run_id, disposition) do
    case Map.fetch(state.streams, {:executor, run_id}) do
      {:ok, stream} ->
        _stated = ExecutorStream.close(stream, disposition)

        # A retained receipt may authorize this complete closure after Control
        # has moved ownership. It does not authorize a second stale-owner
        # transaction or diagnostic for refusal accounting; the successor owns
        # every later durable and diagnostic consequence.
        state = maybe_report_refused_progress(state, run_id, stream)

        %{state | streams: Map.delete(state.streams, {:executor, run_id})}

      :error ->
        state
    end
  end

  # Concept: refusal accounting belongs to the owner that still has authority
  # after the receipt's closure is fixed.
  #
  # Technical depth: a retained receipt can authorize its direct closure after
  # handoff, including the ordering where `post_commit` updated Control before
  # the handoff but its reply was delayed until afterwards. The cached
  # `superseded` flag is false in that ordering. Rechecking the serialized owner
  # boundary prevents the stale coordinator from starting the separate refusal
  # transaction merely because its terminal fact remains true. A handoff that
  # races after an `:ok` answer is still fenced atomically by the Store commit.
  defp maybe_report_refused_progress(%{superseded: true} = state, _run_id, _stream),
    do: state

  defp maybe_report_refused_progress(state, run_id, stream) do
    case Control.current_owner(state.control, state.session_id, state.owner) do
      :ok ->
        report_refused_progress(state, run_id, stream)

      {:error, :superseded_owner} ->
        %{state | superseded: true}

      {:error, :runtime_unavailable} ->
        # A diagnostic is transient projection too. Without a successful owner
        # check this coordinator cannot say it is still the process entitled to
        # emit one, and unavailability is not evidence that ownership stayed or
        # moved.
        state
    end
  end

  defp close_current_tool_stream(state, run_id, disposition) do
    case Map.fetch(state.streams, {:executor, run_id}) do
      {:ok, stream} ->
        case Control.close_progress(
               state.control,
               state.session_id,
               state.owner,
               ExecutorStream.relay(stream),
               disposition
             ) do
          {:ok, _stated} ->
            state = report_refused_progress(state, run_id, stream)
            %{state | streams: Map.delete(state.streams, {:executor, run_id})}

          {:error, :superseded_owner} ->
            state
            |> discard_tool_stream(run_id)
            |> Map.put(:superseded, true)

          {:error, _reason} ->
            discard_tool_stream(state, run_id)
        end

      :error ->
        state
    end
  end

  defp discard_tool_stream(state, run_id) do
    case Map.fetch(state.streams, {:executor, run_id}) do
      {:ok, stream} ->
        _ended = ExecutorStream.discard(stream)
        %{state | streams: Map.delete(state.streams, {:executor, run_id})}

      :error ->
        state
    end
  end

  # Concept: supersession ends every transient domain the prior owner opened,
  # but only a model domain can truthfully call that ending abandoned merely
  # because authority moved.
  #
  # Technical depth: owner death is only one succession shape. Control can
  # install a successor over a live coordinator, and in that shape the linked
  # relay does not end with its still-live owner. Model work has no host effect,
  # so the terminated and drained model worker earns an abandoned closure. An
  # executor effect may already have happened and may still produce evidence;
  # its old plane ends without a closure while the worker is left for durable
  # reconciliation. In both cases the ended relay drops later producer items.
  defp abandon_open_streams(state) do
    state.streams
    |> Map.keys()
    |> Enum.reduce(state, fn
      {:model, run_id}, next -> close_model_stream(next, run_id, :abandoned)
      {:executor, run_id}, next -> discard_tool_stream(next, run_id)
    end)
  end

  # Concept: a superseded owner cannot keep spending an operator's model budget
  # or waiting on a host policy after its successor has taken the run.
  #
  # Technical depth: deadline messages deliberately no-op after supersession,
  # because the old owner cannot commit their decision. A model call has no host
  # effect to reconcile, so every in-flight model worker is terminated here,
  # its monitor/result is drained, and its timer is disarmed before the domain is
  # closed abandoned. A policy callback has admitted no effect, so it is likewise
  # terminated and drained rather than left consuming the predecessor's run
  # deadline. Executor and cleanup workers are left alone: killing an effectful
  # operation is evidence-destroying and its own deadline/lease path must settle
  # it truthfully.
  defp terminate_superseded_effect_free_work(state) do
    Enum.reduce(state.in_flight, state, fn
      {reference, {:model, run_id, pid}}, next ->
        _ = Task.Supervisor.terminate_child(next.owner_workers, pid)
        _ = take_worker_result(reference)

        next
        |> Map.update!(:in_flight, &Map.delete(&1, reference))
        |> disarm_deadline(run_id)

      {reference, {:policy, run_id, pid}}, next ->
        _ = Task.Supervisor.terminate_child(next.owner_workers, pid)
        _ = take_worker_result(reference)

        next
        |> Map.update!(:in_flight, &Map.delete(&1, reference))
        |> cancel_policy_timeout(reference)
        |> disarm_deadline(run_id)

      {_reference, _work}, next ->
        next
    end)
  end

  # Concept: a superseded coordinator stays only while it still carries live
  # evidence-producing work; once settled, it leaves no stale session owner
  # process behind.
  #
  # Technical depth: an executor or cleanup worker may still return the receipt
  # reconciliation needs, and a pending fault hook may already hold such a
  # receipt, so none of those is killed for lifecycle tidiness. Every stream is
  # ended first. When those maps are empty, the successor has all durable truth
  # and stopping normally lets Control remove its obsolete monitor without
  # changing the active successor entry.
  defp continue_after_owner_loss(state) do
    settled =
      map_size(state.in_flight) == 0 and
        map_size(state.pending_cleanup) == 0 and
        map_size(state.streams) == 0 and
        is_nil(state.pending_fault)

    if state.superseded and settled,
      do: {:stop, :normal, state},
      else: {:noreply, state}
  end

  # Concept: an executor whose progress was refused should not be refused in
  # silence.
  #
  # Technical depth: the count and first failed binding only. Nothing else about
  # a refused event is projected or published, and this evidence never reaches
  # the operator's progress plane, so it can neither be mistaken for progress
  # nor affect an outcome, a bound, or a receipt. A refused event is still an
  # executor emitting something it had no standing to emit, and an operator or
  # reviewer needs to know which contract it failed.
  #
  # It reaches only the diagnostic plane. ADR 0011 makes the count relay-private
  # and explicitly forbids journaling a refused event or its accounting. Stream
  # close is when the count is stable and when this one bounded diagnostic is
  # emitted; owner loss discards the counter with the relay.
  defp report_refused_progress(state, run_id, stream) do
    case ExecutorStream.refused_count(stream) do
      0 ->
        state

      refused ->
        bindings = ExecutorStream.refused_bindings(stream)

        emit_diagnostic(state, %{
          "kind" => "executor_progress_refused",
          "run_id" => run_id,
          "tool_call_id" => stream.tool_call_id,
          "refused_count" => refused,
          "refused_bindings" => bindings
        })

        state
    end
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
    cond do
      in_flight?(state, :policy, work.run_id) ->
        {:noreply, state}

      System.system_time(:millisecond) >= run_deadline(declared) ->
        commit_tool_terminal(
          state,
          work,
          call,
          :cancelled,
          "the run deadline passed before dispatch"
        )

      true ->
        dispatch_effect(state, work, call)
    end
  end

  defp dispatch_effect(state, work, call) do
    with {:ok, definition} <- resolve_active_tool(state, call.name),
         :ok <- validate_tool_arguments(definition, call.arguments) do
      start_policy_consultation(state, work, call, definition)
    else
      {:error, reason} ->
        commit_tool_failure(state, work, call, reason)
    end
  end

  defp dispatch_authorized_effect(state, work, call, definition, context) do
    with {:ok, job} <- build_job(state, work, call, definition),
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
      # Concept: committing intent does not buy permission to start after the
      # operator's deadline.
      #
      # Technical depth: the Store call above is synchronous and may linearize
      # the intent while the deadline is still open, then return after it has
      # passed. The coordinator cannot process its queued deadline timer while
      # it waits. Rechecking at the dispatch boundary prevents that scheduling
      # delay from starting an executor after the bound. The intent is already
      # durable, so the call receives its own truthful pre-effect terminal fact;
      # no cancellation query is sent for a job that never crossed the port.
      if deadline_reached?(next, work.run_id) do
        commit_tool_terminal(
          next,
          work,
          call,
          :cancelled,
          "the run deadline passed before dispatch"
        )
      else
        start_executor_work(next, Map.fetch!(next.durable.pending_work, work.run_id))
      end
    else
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

  # Concept: an abort stops the work before it records that the work stopped —
  # but only once the reducer has said this abort is real.
  #
  # Technical depth: M1 recorded an abort and removed the run, which left an
  # operating-system process running with nobody's name on it and an operator
  # told the task had ended. The order here is the point: the command is first
  # classified, then scheduling stops, then the in-flight model attempt and
  # executor job are actually cancelled, cleanup is confirmed, and only then does
  # a terminal fact commit — and it commits `cancelled` only where that
  # confirmation succeeded.
  #
  # Cancelling before that classification was a defect rather than an ordering
  # preference: an abort id that was replayed, that conflicted with different
  # bytes, or that was malformed still killed whatever happened to be in flight —
  # which is a later run's work once the aborted run is gone — and then answered
  # with the earlier run's retained acceptance while the later run committed no
  # terminal fact at all.
  #
  # A validated terminal fact that committed before the abort is untouched. The
  # abort ends what is still running; it does not rewrite what already finished.
  #
  # Concept: what a command needs that its caller did not supply.
  #
  # Technical depth: a prompt needs its run's resolved bounds; an abort needs
  # what cancellation actually achieved. Both travel alongside the command rather
  # than inside it, because the command's digest covers what the caller asked for
  # and must stay the same however the world turned out — otherwise re-presenting
  # one abort would conflict with itself because cleanup went differently the
  # second time.
  # Concept: what a command needs that its caller did not supply.
  #
  # Technical depth: an abort used to need what its cleanup achieved, which meant
  # cleaning up before the abort could be committed at all. ADR 0009 orders the
  # admission first, so an abort now needs nothing resolved: it is admitted, and
  # what it achieved is a separate fact committed after the cleanup that produced
  # it.
  # Technical depth: ADR 0017's context ceiling is resolved here beside the three
  # declared bounds and committed into the same admission record, but it is never
  # merged into `:bounds`: it can produce no `bound_reached`, and folding it in
  # would make it visible to `Bounds.declare/1`.
  defp resolve_command(state, command) do
    resolved =
      state
      |> resolve_bounds(command)
      |> Map.put(:context_token_budget, state.context_token_budget)

    {state, resolved}
  end

  # Concept: end what one run still owns, and say what that actually achieved.
  #
  # Technical depth: scoped to a single run because an abort names a single run,
  # and because a coordinator that later holds work for more than one run must
  # not answer one operator's interrupt by killing another's task. The
  # disposition is the weakest of what each owned operation proved, because a
  # terminal outcome may claim only what all of them establish together.
  # Concept: cleanup begins once the reason for it is on disk, and the part of it
  # that is host-supplied code runs where it cannot block this process.
  #
  # Technical depth: reached from the reply path of a committed command, and only
  # where the reducer marked a run aborting -- so a replayed abort, a refused
  # one, and one naming no active run all start nothing. A second interrupt
  # naming a run already being cleaned up is answered and starts no second
  # cleanup, which is what Outcome 8 requires of it.
  defp begin_admitted_cleanup({:reply, reply, state}) do
    case SessionState.aborting_run(state.durable) do
      nil -> {:reply, reply, state}
      run_id -> {:reply, reply, begin_cleanup(state, run_id, :abort)}
    end
  end

  # Concept: end what the run owns, then ask the executor to end what it owns,
  # and commit the result of both once it is known.
  #
  # Technical depth: everything this coordinator owns is settled here and now --
  # the deadline timer, the in-flight model attempt, the in-flight executor
  # worker and its stream and fact -- because all of it is local state only this
  # process may touch. What is left is one call into a host-supplied executor,
  # and that runs in a task: `cancel/2` is somebody else's code, and this process
  # must stay able to answer a second interrupt, arm a deadline, and admit
  # anything at all while it runs. Bounding the call was not enough on its own,
  # because a bounded call still blocks its caller for the length of the bound.
  #
  # The host call moved after the local settling rather than before it. Stopping
  # our own wait and then asking the executor to stop is the same cancellation in
  # the other order: if the worker already answered, the job is finished and the
  # ask is a no-op; if it did not, the ask is what ends the job, and nothing is
  # committed until it answers.
  defp begin_cleanup(state, run_id, purpose) do
    if Map.has_key?(state.pending_cleanup, run_id) do
      state
    else
      state = disarm_deadline(state, run_id)
      state = cancel_policy_consultation(state, run_id)
      {state, model} = cancel_model_attempt(state, run_id, purpose)
      job_id = dispatched_job_id(state, run_id)

      state = %{
        state
        | pending_cleanup:
            Map.put(state.pending_cleanup, run_id, %{purpose: purpose, model: model})
      }

      dispatch_host_cancel(state, run_id, job_id)
    end
  end

  defp dispatched_job_id(state, run_id) do
    case Map.get(state.durable.pending_work, run_id) do
      %{job: job} -> job.job_id
      _absent -> nil
    end
  end

  # Nothing was dispatched to the executor, so there is nothing for it to end and
  # the local settling above is the whole cleanup. It still completes through the
  # same message the host call would, so one path commits the ending.
  defp dispatch_host_cancel(state, run_id, nil) do
    send(self(), {:cleanup_settled, run_id, :cleaned})
    state
  end

  defp dispatch_host_cancel(state, run_id, job_id) do
    module = state.executor.module
    reference = state.executor.reference

    task =
      Task.Supervisor.async_nolink(state.workers, fn ->
        Executor.cancel(module, reference, job_id)
      end)

    put_in_flight(state, task.ref, {:cleanup, run_id, task.pid})
  end

  # Concept: the cleanup answered; this is what the run ended as.
  #
  # Technical depth: the weakest of what every owned operation proved. `cancelled`
  # and `bound_reached` are claims that the stopping was clean, and only a
  # cleanup that confirmed every owned tree supports either; anything weaker is
  # `outcome_unknown` carrying the reference an operator reconciles against.
  # `propose_run_terminal/4` then applies the rule that one committed unprovable
  # effect outranks whatever asked the run to stop, so that rule is not copied
  # here.
  defp complete_cleanup(state, run_id, host) do
    {pending, remaining} = Map.pop(state.pending_cleanup, run_id)
    state = %{state | pending_cleanup: remaining}

    case pending do
      nil ->
        {:noreply, state}

      %{purpose: purpose, model: model} ->
        # Settled only now, after the executor has answered. Asking it to cancel
        # is what makes an in-flight job finish, so a job that answers during
        # cleanup still has its receipt taken, its stream closed on the count
        # this runtime published, and its fact committed -- which is what keeps a
        # validated terminal fact that landed before the abort from being thrown
        # away by the abort.
        {state, effect} = settle_executor_work(state, run_id)
        disposition = weakest(model, weakest(host, effect))

        case settle_owned_operation(state, run_id, disposition) do
          {:ok, settled} ->
            finish_cleanup(settled, run_id, purpose, disposition)

          {:error, reason} ->
            {:stop, {:tool_result_failed, reason}, state}
        end
    end
  end

  defp finish_cleanup(state, run_id, :abort, :cleaned),
    do: commit_terminal(state, run_id, "cancelled", %{})

  defp finish_cleanup(state, run_id, :abort, :unconfirmed) do
    commit_terminal(state, run_id, "outcome_unknown", %{
      reconciliation_ref: reconciliation_ref(state, run_id)
    })
  end

  defp finish_cleanup(state, run_id, {:deadline, detail}, :cleaned),
    do: commit_terminal(state, run_id, "bound_reached", detail)

  defp finish_cleanup(state, run_id, {:deadline, detail}, :unconfirmed) do
    commit_terminal(
      state,
      run_id,
      "outcome_unknown",
      Map.put(detail, :reconciliation_ref, reconciliation_ref(state, run_id))
    )
  end

  defp weakest(:unconfirmed, _other), do: :unconfirmed
  defp weakest(_left, :unconfirmed), do: :unconfirmed
  defp weakest(_left, _right), do: :cleaned

  # Concept: a provider call is stopped, and the turn it abandoned is still
  # charged.
  #
  # Technical depth: a provider call has no effect to leave behind, so shutting
  # the task down is the whole of its cleanup, and its domain still owes a
  # closure. The charge and the attempt increment are committed rather than kept
  # in memory, so a run cannot escape its own token budget by being aborted and a
  # successor owner cannot rebuild the abandoned attempt and spend the nominal
  # retry allowance a second time.
  defp cancel_model_attempt(state, run_id, purpose) do
    {state, retained} =
      case in_flight_of(state, :model, run_id) do
        nil ->
          {state, :cleaned}

        {reference, pid} ->
          _ = Task.Supervisor.terminate_child(state.owner_workers, pid)
          answer = take_worker_result(reference)

          {state, retained} =
            state
            |> Map.put(:in_flight, Map.delete(state.in_flight, reference))
            |> retain_cancelled_model_answer(run_id, purpose, answer)

          {close_current_model_stream(state, run_id, :abandoned), retained}
      end

    # The charge follows the dispatched turn rather than the live task: a
    # successor that inherits a request its predecessor dispatched still owes the
    # allowance that turn spent, and it holds no task to find.
    case commit_abandoned_attempt(state, run_id) do
      {:ok, next} -> {next, retained}
      {:error, :no_attempt_pending} -> {state, retained}
      {:error, _reason} -> {state, :unconfirmed}
    end
  end

  # Concept: waiting for permission is effect-free work, so stopping it proves
  # there is no host effect to reconcile.
  #
  # Technical depth: the callback itself runs in the supervised task. Ending
  # that task therefore ends the whole consultation; unlike nesting
  # `Policy.decide/2`, it cannot leave an unlinked callback alive past the run's
  # deadline. Its pending timeout and result are drained with it, and no denial
  # is fabricated for a deadline or abort that won the coordinator's order.
  defp cancel_policy_consultation(state, run_id) do
    case in_flight_of(state, :policy, run_id) do
      nil ->
        state

      {reference, pid} ->
        _ = Task.Supervisor.terminate_child(state.owner_workers, pid)
        _ = take_worker_result(reference)

        state
        |> Map.update!(:in_flight, &Map.delete(&1, reference))
        |> cancel_policy_timeout(reference)
    end
  end

  # Concept: a receipt that was already produced is truth, not noise.
  #
  # Technical depth: the executor task can finish between the operator pressing
  # the key and this coordinator reducing the abort, which leaves a validated
  # terminal fact sitting undelivered in the mailbox while the process group it
  # named is already gone. Discarding it produced the worst available pair: an
  # effect that happened, and a run committing `cancelled` with no terminal fact
  # for it. The result is therefore drained after the task is dead — at which
  # point nothing further can arrive — and committed wherever it validates. An
  # attempt that produced no answer, or one that cannot be validated as terminal,
  # leaves its operation unproved, and unproved is `outcome_unknown` and never
  # `cancelled`, however confidently the executor reports the process tree gone:
  # a confirmed cleanup bounds the tree, it does not establish what the effect
  # did.
  # Concept: take a worker's answer out of the mailbox instead of leaving it to
  # be dropped in silence.
  #
  # Technical depth: `terminate_child/2` answers from the supervisor, while the
  # result is sent by the task. Those senders have no ordering relationship, so
  # the supervisor's answer cannot make a zero-timeout mailbox read exact. The
  # task's own result signal and its monitor signal do have one order: if a
  # result was sent it precedes `DOWN` from that task to this coordinator. Wait
  # for either, and only read no answer when `DOWN` itself proves none can still
  # arrive. A result branch demonitor-flushes the following signal.
  defp take_worker_result(reference) do
    receive do
      {^reference, {:ok, value}} ->
        Process.demonitor(reference, [:flush])
        {:ok, value}

      {^reference, other} ->
        Process.demonitor(reference, [:flush])
        {:answered, other}

      {:DOWN, ^reference, :process, _pid, _reason} ->
        :none
    end
  end

  defp retain_cancelled_model_answer(state, _run_id, _purpose, :none),
    do: {state, :cleaned}

  defp retain_cancelled_model_answer(state, run_id, purpose, {:ok, reply}),
    do: retain_model_attempt_evidence(state, run_id, purpose, {:ok, reply})

  defp retain_cancelled_model_answer(state, run_id, purpose, {:answered, answer}),
    do: retain_model_attempt_evidence(state, run_id, purpose, answer)

  defp retain_model_attempt_evidence(state, run_id, purpose, result) do
    termination = if match?({:deadline, _detail}, purpose), do: :deadline, else: :abort

    with {:ok, proposal} <-
           SessionState.propose_model_attempt_evidence(
             state.durable,
             run_id,
             termination,
             result
           ),
         {:ok, next} <- commit_internal(state, proposal) do
      {report_late_result(next, run_id, :model, result), :cleaned}
    else
      {:error, _reason} -> {state, :unconfirmed}
    end
  end

  defp in_flight_of(state, kind, run_id) do
    Enum.find_value(state.in_flight, fn
      {reference, {^kind, ^run_id, pid}} -> {reference, pid}
      {_reference, _other} -> nil
    end)
  end

  # Concept: settle everything this coordinator owns for the run, and name the
  # job the executor still owns.
  #
  # Technical depth: the worker is stopped, its result taken, its stream closed
  # and its fact committed -- all local state only this process may touch. The job id is read before any of that, because
  # committing the fact may advance the work past the point where it is still
  # there to read.
  #
  defp settle_executor_work(state, run_id) do
    case in_flight_of(state, :executor, run_id) do
      nil ->
        # A successor owns no local Task for an effect its predecessor
        # dispatched. That absence proves only who owns the worker, never what
        # the effect did. Treating it as a clean cancellation let a fresh abort
        # commit `cancelled` with a durable `effect_dispatched` operation and no
        # terminal fact. The stream may likewise belong to the predecessor, so
        # closing the local entry is deliberately best-effort; the durable
        # operation fact below is the authoritative ending.
        case Map.get(state.durable.pending_work, run_id) do
          %{stage: "effect_dispatched"} ->
            {close_current_tool_stream(state, run_id, :abandoned), :unconfirmed}

          _nothing_dispatched ->
            {state, :cleaned}
        end

      {reference, pid} ->
        _ = Task.Supervisor.terminate_child(state.workers, pid)
        state = %{state | in_flight: Map.delete(state.in_flight, reference)}

        case take_worker_result(reference) do
          {:ok, receipt} when is_map(receipt) ->
            case retain_executor_fact(state, run_id, receipt) do
              {:ok, next} -> {next, :cleaned}
              {:invalid, next, _reason} -> {next, :unconfirmed}
              {:error, next, _reason} -> {next, :unconfirmed}
              {:superseded, next} -> {next, :unconfirmed}
            end

          _unproved ->
            {close_current_tool_stream(state, run_id, :abandoned), :unconfirmed}
        end
    end
  end

  # Concept: a cleanup that could not prove what it stopped still owes the
  # operation it was stopping a fact of its own.
  #
  # Technical depth: this covers every way the disposition reaches
  # `:unconfirmed` with a call still dispatched -- an executor that produced no
  # readable receipt, one whose receipt could not be committed, a host
  # cancellation that answered nothing intelligible -- rather than only the
  # branch the defect was found in. A run whose executor answered and whose fact
  # committed has already left `effect_dispatched`, so this is a no-op there, and
  # a `:cleaned` cleanup has nothing unproved to record.
  defp settle_owned_operation(state, run_id, :unconfirmed),
    do: commit_owned_operation_unknown(state, run_id)

  defp settle_owned_operation(state, _run_id, :cleaned), do: {:ok, state}

  # Concept: an operation this coordinator dispatched ends with a fact of its
  # own, and the run does not end until it has.
  #
  # Technical depth: ADR 0009's ordering is operation first, run second, and its
  # run-outcome table is a function of the owned operation outcomes. Committing
  # the call's `outcome_unknown` here is what makes the run's own
  # `outcome_unknown` derived rather than decided a second time: `run_outcome/3`
  # reads the committed element and outranks whatever the caller proposed, so the
  # two can no longer disagree and the run terminal cannot claim a clean stop
  # over an operation nobody could prove.
  #
  # A run with no dispatched call owes nothing and is left alone.
  #
  # A refused commit is fatal here, and swallowing it was a durability hole
  # rather than a tidy fallback: a Store that refused this one transaction left
  # the run committing its terminal anyway, so an operator got `tool.started`,
  # then `run.finished`, and nothing about the call in between -- the exact shape
  # this function exists to prevent, reachable whenever a Store answers no. It
  # also made the run's outcome an independent decision again, because nothing
  # was committed for `run_outcome/3` to read. Stopping is what every sibling
  # commit here already does: the abort's admission is durable, so a successor
  # finds the marker and settles the operation before it settles the run.
  defp commit_owned_operation_unknown(state, run_id) do
    case Map.get(state.durable.pending_work, run_id) do
      %{stage: "effect_dispatched", tool_call: call} ->
        with {:ok, proposal} <-
               SessionState.propose_tool_result(
                 state.durable,
                 run_id,
                 call.tool_call_id,
                 :outcome_unknown,
                 reconciliation_ref(state, run_id)
               ),
             {:ok, next} <- commit_internal(state, proposal) do
          {:ok, next}
        end

      _no_dispatched_call ->
        {:ok, state}
    end
  end

  # Concept: every executor-backed call asks the host, including a read-only one,
  # without making the serial session owner wait inside host code.
  #
  # Technical depth: the callback runs in this coordinator's supervised task,
  # not inside the coordinator and not behind `Policy.decide/2`'s own unlinked
  # child. That makes both bounds real: the policy's fixed timeout resolves fail
  # closed, while the run timer can terminate the callback at the earlier
  # committed deadline without leaving an orphan host operation behind. No
  # effect intent or grant exists until the supervised answer is admitted.
  defp start_policy_consultation(%{policy: nil} = state, work, call, _definition),
    do: commit_tool_terminal(state, work, call, :denied, "policy_unavailable")

  defp start_policy_consultation(state, work, call, definition) do
    request = policy_request(state, work, call, definition)

    task =
      Task.Supervisor.async_nolink(state.owner_workers, fn ->
        Policy.evaluate_callback(state.policy, request)
      end)

    state = put_in_flight(state, task.ref, {:policy, work.run_id, task.pid})
    state = arm_policy_timeout(state, task.ref, work.run_id)
    {:noreply, arm_deadline(state, work.run_id)}
  end

  defp complete_policy_consultation(state, run_id, decision) do
    cond do
      state.phase != :ready or state.superseded ->
        continue_after_owner_loss(state)

      deadline_reached?(state, run_id) ->
        finish_at_deadline(state, run_id)

      true ->
        case Map.get(state.durable.pending_work, run_id) do
          %{stage: "effect_pending", pending_calls: [call | _rest]} = work ->
            with {:ok, definition} <- resolve_active_tool(state, call.name),
                 :ok <- validate_tool_arguments(definition, call.arguments) do
              case decision do
                {:allow, context} ->
                  dispatch_authorized_effect(state, work, call, definition, context)

                {:deny, category} when is_atom(category) ->
                  if category in Policy.reason_categories() do
                    commit_tool_terminal(state, work, call, :denied, Atom.to_string(category))
                  else
                    commit_tool_terminal(state, work, call, :denied, "policy_unavailable")
                  end

                _unavailable ->
                  commit_tool_terminal(state, work, call, :denied, "policy_unavailable")
              end
            else
              {:error, reason} -> commit_tool_failure(state, work, call, reason)
            end

          _no_pending_call ->
            {:noreply, state}
        end
    end
  end

  defp policy_request(state, work, call, definition) do
    %{
      session_id: state.session_id,
      run_id: work.run_id,
      tool_call_id: call.tool_call_id,
      generation: ToolDefinition.generation(definition),
      arguments: call.arguments,
      effect_class: Map.fetch!(definition, "effect_class"),
      idempotency_class: Map.fetch!(definition, "idempotency_class"),
      workspace_lease: state.executor.workspace_lease
    }
  end

  defp arm_policy_timeout(state, reference, run_id) do
    timer =
      Process.send_after(
        self(),
        {:policy_timeout, reference, run_id},
        Policy.decision_timeout_ms()
      )

    %{state | policy_timers: Map.put(state.policy_timers, reference, timer)}
  end

  defp cancel_policy_timeout(state, reference) do
    case Map.pop(state.policy_timers, reference) do
      {nil, _remaining} ->
        state

      {timer, remaining} ->
        _ = Process.cancel_timer(timer)
        %{state | policy_timers: remaining}
    end
  end

  defp validate_tool_arguments(definition, arguments) do
    case ToolDefinition.validate_arguments(definition, arguments) do
      :ok -> :ok
      {:error, _reason} -> {:error, :invalid_tool_arguments}
    end
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
      coordinator = self()
      run_id = work.run_id

      publish = fn relay, item ->
        case Control.project_progress(
               state.control,
               state.session_id,
               state.owner,
               relay,
               item
             ) do
          {:error, :superseded_owner} = error ->
            # The callback runs in the executor worker, so Control's refusal
            # must be reflected back into the coordinator that owns the relay.
            # It ends only the transient executor plane; the effectful worker
            # stays alive to produce the receipt reconciliation still needs.
            send(coordinator, {:executor_progress_owner_lost, run_id, relay})
            error

          other ->
            other
        end
      end

      {:ok, stream, progress} =
        ExecutorStream.open(
          state.workers,
          state.progress_to,
          work.job,
          state.durable.event_sequence,
          publish
        )

      task =
        Task.Supervisor.async_nolink(state.workers, fn ->
          executor.module.execute(executor.reference, work.job, work.grant, [], progress)
        end)

      state = %{state | streams: Map.put(state.streams, {:executor, work.run_id}, stream)}
      {:noreply, put_in_flight(state, task.ref, {:executor, work.run_id, task.pid})}
    end
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
      # Concept: the bounds this job runs under are declared where they are
      # journaled, not invented by the hand that runs it.
      #
      # Technical depth: both ceilings come from the definition this call
      # resolved through, so the effect intent that commits records the exact
      # numbers the job was dispatched under. The wall-time ceiling used to be
      # read only from the executor's own copy of the definition, which made the
      # bound a fact about the hand rather than about the dispatch, and left
      # nothing durable naming it.
      resource_budgets: %{
        "max_output_bytes" => Map.fetch!(budgets, "output_bytes"),
        "max_wall_time_ms" => Map.fetch!(budgets, "wall_time_ms")
      },
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
  # Model replies and executor receipts both reach their final Store/Control
  # fence. That boundary can retain a fact that raced the handoff, name a stale
  # owner exactly, or refuse an unproved closure in the same serialized Control
  # operation that would emit it. A generic precheck here creates a
  # check-then-action interval and also makes those final branches impossible to
  # exercise: the precheck answers first and the claimed close never runs.
  defp dispatch_result(state, kind, run_id, result) when kind in [:model, :executor],
    do: dispatch_current_result(state, kind, run_id, result)

  defp dispatch_current_result(state, kind, run_id, result) do
    if Map.has_key?(state.durable.pending_work, run_id) do
      case kind do
        :model -> accept_model_result(state, run_id, result)
        :executor -> accept_executor_result(state, run_id, result)
      end
    else
      accept_late_result(state, run_id, kind, result)
    end
  end

  # Concept: a reply whose stream statistic is not a count is an answer this
  # runtime cannot use, not an answer it publishes anyway.
  #
  # Technical depth: `delta_count` reached the closing item and the durable
  # assistant message unchecked, so an adapter returning minus one published a
  # closure a consumer can compare nothing against and committed the same value.
  # It takes the abandoned path rather than killing the owner, because that is
  # what a provider answer this runtime cannot read already means: the domain
  # closes on what the relay actually emitted, the attempt is charged, and the
  # turn is retried under a new attempt.
  defp accept_model_result(state, run_id, {:ok, reply}) when is_map(reply) do
    case Map.get(reply, :delta_count, 0) do
      count when is_integer(count) and count >= 0 ->
        accept_counted_model_result(state, run_id, reply, count)

      _not_a_count ->
        accept_model_result(state, run_id, {:error, :invalid_delta_count})
    end
  end

  defp accept_model_result(state, run_id, result) do
    # An attempt that returned no reply still owes its closure, so a consumer can
    # tell an abandoned stream from one that merely went quiet, and still owes
    # its charge, so giving up is not cheaper than finishing.
    state = close_current_model_stream(state, run_id, :abandoned)

    if state.superseded do
      # The successor owns the abandonment once Control's closing fence says
      # this coordinator no longer owns the plane. Attempting the same
      # deterministic abandonment transaction here lets the Store retain a
      # stale-owner non-commit under the identity the successor must use, so the
      # successor sees a binding conflict instead of advancing the attempt.
      continue_after_owner_loss(state)
    else
      # Concept: a provider retry redispatches the bytes that were already
      # committed.
      #
      # Technical depth: nothing is recomputed. The same staged bytes and the same
      # staged_request_digest go out again under a newly recorded attempt, because
      # the model request has no operation or attempt member for a digest to cover.
      # That is the opposite of the executor rule, where each attempt canonicalizes
      # its own attempt identity and therefore computes its own digest — which is
      # exactly why the two digests no longer share one name.
      case commit_abandoned_attempt(state, run_id) do
        {:ok, next} ->
          if retry_available?(next, run_id) do
            send(self(), :advance_work)
            {:noreply, next}
          else
            {:stop, {:model_failed, result}, next}
          end

        {:error, :no_attempt_pending} ->
          {:stop, {:model_failed, result}, state}

        {:error, reason} ->
          {:stop, {:model_attempt_failed, reason}, state}
      end
    end
  end

  @model_attempt_limit 2

  # Concept: the attempt an owner is on, and the tokens the abandoned one spent,
  # are facts about the run rather than notes in one process's memory.
  #
  # Technical depth: both used to live only in the coordinator's own state. A
  # successor rebuilt the run from the journal, found attempt one and no charge,
  # and could therefore spend the nominal retry allowance again after every
  # succession while reopening the stream domain the abandoned attempt had
  # already used. Committing the transition is what makes the retry allowance and
  # the token budget survive the owner that was counting them. The deadline timer
  # is disarmed here because this attempt no longer owns a live provider call;
  # the next dispatch arms the same instant again.
  defp commit_abandoned_attempt(state, run_id) do
    state = disarm_deadline(state, run_id)

    case SessionState.propose_model_attempt_abandoned(state.durable, run_id) do
      {:ok, proposal} -> commit_internal(state, proposal)
      {:error, reason} -> {:error, reason}
    end
  end

  defp retry_available?(state, run_id) do
    case Map.get(state.durable.pending_work, run_id) do
      %{stage: "model_dispatched"} = work ->
        Map.get(work, :model_attempt, 1) <= @model_attempt_limit

      _absent ->
        false
    end
  end

  defp accept_executor_result(state, run_id, {:ok, receipt}) when is_map(receipt) do
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

  # Concept: an executor that did not answer with a receipt still says something
  # about its call, and what it says depends on whether the effect had already
  # happened when it stopped being able to prove anything.
  #
  # Technical depth: this used to read every executor error as a refusal and
  # commit a terminal `failed`, on the stated reasoning that "the effect did not
  # start, so there is nothing indeterminate to reconcile". That is true of a
  # pre-start refusal and false of `{:receipt_not_retained, reason}`, which the
  # executor returns after the tool has run and its effect has landed in the
  # workspace. Reading that as `failed` told the model the tool never ran,
  # dispatched it again, and finished the run `completed` -- the silent resume
  # past an indeterminate effect that `docs/vision-technical.md` forbids.
  #
  # Neither branch decides the run. The unproven branch commits the call's own
  # terminal fact and `advance_run/2` remains the single place a run ends,
  # which is why one unknown effect ends the run whatever else was true of it.
  defp accept_executor_result(state, run_id, result) do
    state = close_current_tool_stream(state, run_id, :abandoned)

    if state.superseded do
      # The result supplied no retained receipt, so ownership loss leaves this
      # coordinator with no terminal fact it may commit. The successor recovers
      # the dispatched operation and reconciles it; turning the local error into
      # a stale-epoch failure or unknown record would be later run work.
      continue_after_owner_loss(state)
    else
      case Map.get(state.durable.pending_work, run_id) do
        %{pending_calls: [call | _rest]} = work ->
          case effect_disposition(result) do
            :refused_before_effect -> commit_tool_failure(state, work, call, failure_of(result))
            :unproven -> commit_tool_unproven(state, work, call, result)
          end

        _other ->
          {:stop, {:executor_failed, result}, state}
      end
    end
  end

  # Concept: whether an effect started is a fact about the executor, so the
  # executor is asked rather than guessed at.
  #
  # Technical depth: this used to be a list of error names held here, copied from
  # the shipped local executor's behaviour and applied to every implementation of
  # a port that is deliberately open. `:workspace_lease_lost` shows what that
  # costs. The local executor raises it only from the validation that runs before
  # a start, so listing it here was true of that executor -- and a conforming
  # third-party executor that lost its lease halfway through a write and returned
  # the same name had its effect committed as an ordinary `failed`, with the loop
  # carrying on past an effect nobody could account for. That is the defect this
  # runtime had just repaired, reachable again through the port.
  #
  # The executor now says it in the answer. A tagged refusal is the only thing
  # read as one; anything else -- including an executor that never adopts the
  # tag -- is unproven.
  # An executor that declares nothing is unproven, which is also the answer for
  # anything this runtime cannot read as an error at all: `failed` is a positive
  # claim that the effect did not happen, and nothing here can support it.
  # `Loopex.Executor.cancel/3` reads an unadmitted answer the same way, for the
  # same reason.
  # It is a pattern match and not a call. The shape this replaced asked the
  # executor module a question from inside this process while a run was in
  # flight, so an implementation that blocked in the callback blocked this
  # coordinator's deadline and its operator's abort with it. A term that has
  # already arrived cannot do that.
  defp effect_disposition({:error, {:refused_before_effect, _reason}}), do: :refused_before_effect

  defp effect_disposition(_answer), do: :unproven

  # Concept: an effect that ran and cannot be accounted for is committed as
  # unknown, naming what an operator reconciles it against.
  #
  # Technical depth: the committed reason is that reference rather than the
  # executor's error, because it is what the model is shown and what the run's
  # terminal carries. The error is not durable truth about the effect -- it is
  # one executor's account of why it could produce none -- so it goes to the
  # diagnostics plane, where an operator can still read which failure this was
  # without it being mistaken for a fact about the workspace.
  defp commit_tool_unproven(state, work, call, result) do
    emit_diagnostic(state, %{
      "kind" => "executor_effect_unproven",
      "run_id" => work.run_id,
      "tool_call_id" => call.tool_call_id,
      "reason" => unproven_reason(result)
    })

    commit_tool_terminal(
      state,
      work,
      call,
      :outcome_unknown,
      reconciliation_ref(state, work.run_id)
    )
  end

  # An answer that was not an error at all is one this runtime could not read as
  # a receipt, which is a different diagnosis from any error the executor named.
  defp unproven_reason({:error, reason}), do: failure_reason(reason)
  defp unproven_reason(_answer), do: "unreadable_executor_answer"

  # Concept: a reply that arrives after its run ended is evidence, not history.
  #
  # Technical depth: an abort admitted before the reply committed leaves no work
  # for it to belong to. The attempt is retained truthfully on the diagnostics
  # plane and never becomes a canonical assistant message, because the run it
  # would have continued is already terminal. Treating it as a fault instead
  # would kill an owner over a message that arrived a moment too late.
  defp accept_late_result(state, run_id, kind, result) do
    {:noreply, report_late_result(state, run_id, kind, result)}
  end

  defp report_late_result(state, run_id, kind, result) do
    emit_diagnostic(state, %{
      "kind" => "late_result_discarded",
      "run_id" => run_id,
      "operation" => Atom.to_string(kind),
      "outcome" => if(match?({:ok, _}, result), do: "reply", else: "error")
    })

    state
  end

  defp emit_diagnostic(%{diagnostics_to: sink}, item) when is_pid(sink) do
    send(sink, {:loopex_diagnostic, item})
    :ok
  end

  defp emit_diagnostic(_state, _item), do: :ok

  # Only a refusal reaches this, and a refusal is always the tagged shape: every
  # other answer took the unproven path before this was called. A wider clause
  # would be a second place deciding what an untagged error means.
  defp failure_of({:error, {:refused_before_effect, reason}}), do: reason

  defp commit_executor_fact(state, run_id, receipt) do
    case retain_executor_fact(state, run_id, receipt) do
      {:ok, next} ->
        send(self(), :advance_work)
        {:noreply, next}

      {:superseded, next} ->
        continue_after_owner_loss(next)

      {:invalid, state, reason} ->
        if state.superseded do
          # Receipt validation produced no fact. Once the closing fence also
          # reports owner loss, only the successor may turn that uncertainty
          # into a reconciliation decision.
          continue_after_owner_loss(state)
        else
          case Map.get(state.durable.pending_work, run_id) do
            %{pending_calls: [call | _rest]} = work ->
              commit_tool_unproven(
                state,
                work,
                call,
                {:error, {:invalid_executor_receipt, reason}}
              )

            _other ->
              {:stop, {:executor_fact_failed, reason}, state}
          end
        end

      {:error, state, reason} ->
        {:stop, {:executor_fact_failed, reason}, state}
    end
  end

  # Concept: a tool stream earns `complete` only with the durable receipt that
  # states its count.
  #
  # Technical depth: both ordinary result handling and cancellation cleanup use
  # this one boundary. Validation and retention happen first; only their success
  # selects the receipt's count and the complete disposition. An invalid or
  # current-owner unretained receipt closes the relay abandoned on the number it
  # actually emitted, so neither caller can publish a fact the journal refused.
  # A retained receipt whose later Control projection loses ownership remains a
  # truthful complete fact and closes directly. A stale-owner Store refusal is
  # different: no receipt committed under that transaction, so this plane has
  # no standing to state a disposition; it discards the relay and leaves the
  # successor to reconcile the already-dispatched effect.
  defp retain_executor_fact(state, run_id, receipt) do
    case put_executor_fact(state, run_id, receipt) do
      {:ok, next} ->
        {:ok, close_tool_stream(next, run_id, {:complete, progress_count(receipt)})}

      {:retained, next} ->
        {:superseded, close_tool_stream(next, run_id, {:complete, progress_count(receipt)})}

      {:invalid, reason} ->
        {:invalid, close_current_tool_stream(state, run_id, :abandoned), reason}

      {:error, reason}
      when reason in [:stale_owner_epoch, :stale_owner_incarnation_id, :superseded_owner] ->
        next =
          state
          |> discard_tool_stream(run_id)
          |> Map.put(:superseded, true)

        {:superseded, next}

      {:error, reason} ->
        {:error, close_current_tool_stream(state, run_id, :abandoned), reason}
    end
  end

  # Concept: committing the fact, separated from deciding what to do next.
  #
  # Technical depth: cancellation commits the same fact from inside a command
  # reduction, where a `:noreply` tuple would be the wrong shape and scheduling
  # more work would be exactly wrong.
  defp put_executor_fact(state, run_id, receipt) do
    case SessionState.propose_executor_fact(state.durable, run_id, receipt) do
      {:ok, proposal} -> retain_terminal_operation_fact(state, proposal)
      {:error, reason} -> {:invalid, reason}
    end
  end

  defp commit_internal(state, proposal) do
    case commit_internal_result(state, proposal) do
      {:ok, next, :current_owner} -> {:ok, next}
      {:ok, _next, {:owner_lost, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  # Concept: a durable terminal operation fact remains true when runtime-local
  # ownership moves before the committing owner receives its Store result.
  #
  # Technical depth: ordinary internal commits still treat a refused
  # post-commit projection as an ownership error. A model reply or executor
  # receipt is different: once the Store retained it, it fixes the originating
  # stream's disposition and producer count. The caller may therefore emit that
  # one truthful closure, but the returned state is marked superseded so it can
  # perform no later run work.
  defp retain_terminal_operation_fact(state, proposal) do
    case commit_internal_result(state, proposal) do
      {:ok, next, :current_owner} -> {:ok, next}
      {:ok, next, {:owner_lost, _reason}} -> {:retained, %{next | superseded: true}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp commit_internal_result(state, proposal) do
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
          with {:ok, durable} <- SessionState.commit_proposal(proposal, receipt) do
            next = %{state | durable: durable}

            case Control.post_commit(
                   state.control,
                   state.session_id,
                   state.owner,
                   %{
                     journal_version: durable.journal_version,
                     event_sequence: durable.event_sequence
                   },
                   receipt
                 ) do
              :ok -> {:ok, next, :current_owner}
              {:error, :superseded_owner} -> {:ok, next, {:owner_lost, :superseded_owner}}
              {:error, reason} -> {:error, reason}
            end
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
      true -> Control.current_owner(state.control, state.session_id, state.owner)
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
      protocol_version: job.protocol_version,
      job_id: job.job_id,
      operation_id: job.operation_id,
      attempt: job.attempt,
      session_id: job.session_id,
      run_id: job.run_id,
      turn_id: job.turn_id,
      tool_call_id: job.tool_call_id,
      canonical_request_digest: job.canonical_request_digest,
      session_epoch_at_dispatch: job.origin_session_epoch,
      executor_epoch: job.origin_executor_epoch,
      executor_identity: job.executor_identity,
      fencing_token: job.fencing_token,
      tool_id: job.tool_id,
      tool_version: job.tool_version
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
         query
       ),
       do:
         SessionState.propose_reconciled_executor_fact(
           state,
           run_id,
           receipt,
           query.reconciliation_query_id
         )

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

  # Concept: every caller states how long it will wait; none inherits a bound it
  # never chose.
  #
  # Technical depth: the default was five seconds, and a call that reached it
  # returned `:session_unavailable` -- a claim about the session, made because a
  # process was busy. Two of these ran from control while it held its own
  # `handle_call`, which is how a scheduling delay became a verdict. The
  # coordinator is the serial authority on its own state, so its callers wait for
  # it; a caller that genuinely must give up bounds itself here, visibly, rather
  # than inheriting a number from this line.
  defp safe_call(server, message, timeout) do
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
