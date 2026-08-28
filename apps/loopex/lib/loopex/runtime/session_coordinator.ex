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
       pending_cleanup: %{},
       streams: %{},
       deadline_timers: %{},
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

      {_work, remaining} ->
        {:stop, {:worker_failed, reason}, %{state | in_flight: remaining}}
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
        retry_owner(state, :commit_unknown)

      {:fenced, :commit_unknown} ->
        retry_owner(state, :commit_unknown)
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
  defp resume_aborting_run(state, run_id) do
    if Map.has_key?(state.pending_cleanup, run_id) do
      {:noreply, state}
    else
      commit_terminal(
        state,
        run_id,
        "outcome_unknown",
        %{reconciliation_ref: reconciliation_ref(state, run_id)}
      )
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

  defp steer_message(nil), do: []
  defp steer_message(%{content: content}), do: [%{"role" => "user", "content" => content}]

  defp commit_terminal(state, run_id, outcome, detail) do
    state = disarm_deadline(state, run_id)

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
      state = arm_deadline(state, work.run_id)
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
    counter = new_stream_counter()
    stream = %{domain: domain, turn_id: turn_id, counter: counter}

    {stream,
     fn delta ->
       if Model.valid_delta?(delta) do
         # Concept: the first delta of a domain is sequence zero.
         #
         # Technical depth: ADR 0011 fixes the algebra as zero-based, so a
         # closing count of `n` and a last sequence of `n - 1` describe the same
         # stream. Incrementing before reading made the first item one, which
         # left every consumer's gap check off by one against the count it is
         # compared with. The counter still holds the count; the sequence is the
         # value it had before this item was added, taken atomically so two
         # emissions can never claim one number.
         case reserve_sequence(counter) do
           :sealed ->
             # The domain is closed and its total is published. A late delta is
             # dropped rather than emitted past that total, and it is not
             # counted, because the count belongs to what crossed the plane.
             :ok

           {:ok, sequence} ->
             emit_model_delta(sink, delta, turn_id, domain, sequence)
         end
       end

       :ok
     end}
  end

  defp emit_model_delta(sink, delta, turn_id, domain, sequence) do
    emit_progress(
      sink,
      Map.merge(delta, %{
        turn_id: turn_id,
        stream_domain_id: domain,
        model_sequence: sequence
      })
    )
  end

  defp model_operation_id(work), do: stable_id("model-operation", work.run_id, work.turn_number)

  # Concept: taking a sequence and sealing a stream are one operation, or they
  # are a race.
  #
  # Technical depth: a separate closed flag beside the counter is check-then-act.
  # A producer reads the flag, is preempted, a closer publishes the closure with
  # the count it can see, and the producer then increments and emits an item past
  # a total already on the plane -- which is exactly the loss a consumer uses
  # that total to detect, reported for an item that was not lost. The window is
  # small and it is real: the callback runs in the producer's process and the
  # closer runs in this one.
  #
  # The seal is therefore a bit inside the counter itself, and both operations
  # are compare-and-exchange loops over that single word. A producer either
  # reserves a sequence before the seal or sees the seal; a closer either seals
  # before a reservation or counts it. There is no interleaving in which an item
  # is emitted that the closing total does not include.
  #
  # Model and executor streams share this because they have the same algebra:
  # ADR 0011 gives each domain one gapless zero-based sequence closed by one
  # total. The model side previously had no seal at all, so a retained callback
  # could emit into a closed domain with nothing to stop it.
  @stream_sealed_bit 0x8000_0000_0000_0000

  defp new_stream_counter, do: :atomics.new(1, signed: false)

  defp reserve_sequence(counter) do
    current = :atomics.get(counter, 1)

    if Bitwise.band(current, @stream_sealed_bit) != 0 do
      :sealed
    else
      case :atomics.compare_exchange(counter, 1, current, current + 1) do
        :ok -> {:ok, current}
        _lost_the_race -> reserve_sequence(counter)
      end
    end
  end

  # Returns the exact final count. Sealing an already-sealed stream returns the
  # same count again rather than a second, different one, so a duplicate closure
  # is impossible to derive from here.
  defp seal_stream(counter) do
    current = :atomics.get(counter, 1)

    if Bitwise.band(current, @stream_sealed_bit) != 0 do
      Bitwise.band(current, Bitwise.bnot(@stream_sealed_bit))
    else
      case :atomics.compare_exchange(
             counter,
             1,
             current,
             Bitwise.bor(current, @stream_sealed_bit)
           ) do
        :ok -> current
        _lost_the_race -> seal_stream(counter)
      end
    end
  end

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
        # Sealing first is what makes the abandoned count exact rather than
        # merely current: no delta can be reserved after this line, so the value
        # it returns is the total that crossed the plane and not a sample of a
        # counter still moving.
        observed = seal_stream(stream.counter)

        count =
          case disposition do
            :complete -> reported_count
            :abandoned -> observed
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

  # Concept: the closing item says how many items this coordinator put on the
  # stream, which is the only count it can vouch for.
  #
  # Technical depth: a completed stream closed with the executor's own
  # `progress_count` -- the executor's claim about what it emitted, taken as this
  # runtime's statement about what it published. Those are different numbers
  # whenever `project_progress/2` refuses an event: an executor that emitted
  # three, two of them with a wrong binding, had one item reach the operator
  # under a closure declaring three, so a consumer using the closure to detect
  # loss on the transient plane concluded that two items had been coalesced away.
  # The refusals are not loss and are already reported as refusals.
  #
  # The port declares no relationship between that field and what a coordinator
  # accepted -- it could not, because refusal is the coordinator's decision and
  # the executor has not heard of it. So the number is counted here, from what
  # was emitted, and the executor's own figure stays where it belongs: in the
  # receipt, as that executor's record of what it sent.
  defp close_tool_stream(state, run_id, disposition) do
    case Map.fetch(state.streams, {:executor, run_id}) do
      {:ok, stream} ->
        # Sealing returns the exact total: no event can reserve a sequence after
        # this line, so nothing is emitted that this count does not include.
        count = seal_stream(stream.counter)

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

        state = report_refused_progress(state, run_id, stream)
        %{state | streams: Map.delete(state.streams, {:executor, run_id})}

      :error ->
        state
    end
  end

  # Concept: an executor whose progress was refused should not be refused in
  # silence.
  #
  # Technical depth: the count only. Nothing about a refused event is projected
  # or published, and the count never reaches the operator's progress plane, so
  # it can neither be mistaken for progress nor affect an outcome, a bound, or a
  # receipt. A refused event is still an executor emitting something it had no
  # standing to emit, and an operator or a reviewer needs some way to see that
  # it happened.
  #
  # It goes two places for two different readers. The diagnostic reaches whoever
  # is watching the run now. The private record reaches whoever reads the
  # journal afterwards, which is what the count in memory could never do -- it
  # died with the coordinator, so a reviewer could not tell a well-behaved
  # attempt from one refused a thousand times. The record is committed here,
  # at stream close, because no further event can arrive by then and the count
  # is therefore stable across any recomputation of this proposal.
  defp report_refused_progress(state, run_id, stream) do
    case :atomics.get(stream.refused, 1) do
      0 ->
        state

      refused ->
        emit_diagnostic(state, %{
          "kind" => "executor_progress_refused",
          "run_id" => run_id,
          "tool_call_id" => stream.tool_call_id,
          "refused_count" => refused
        })

        case SessionState.propose_progress_refusals(
               state.durable,
               run_id,
               stream.tool_call_id,
               refused
             ) do
          {:ok, proposal} ->
            case commit_internal(state, proposal) do
              {:ok, next} -> next
              # Technical depth: a refusal count that cannot be retained is not
              # worth failing a run over. The diagnostic above already went out.
              {:error, _reason} -> state
            end

          {:error, _reason} ->
            state
        end
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
  defp resolve_command(state, command), do: {state, resolve_bounds(state, command)}

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
      {state, model} = cancel_model_attempt(state, run_id)
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

        finish_cleanup(state, run_id, purpose, weakest(model, weakest(host, effect)))
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
  defp cancel_model_attempt(state, run_id) do
    state =
      case in_flight_of(state, :model, run_id) do
        nil ->
          state

        {reference, pid} ->
          _ = Task.Supervisor.terminate_child(state.workers, pid)
          _ = take_worker_result(reference)
          state = %{state | in_flight: Map.delete(state.in_flight, reference)}
          close_model_stream(state, run_id, :abandoned, 0)
      end

    # The charge follows the dispatched turn rather than the live task: a
    # successor that inherits a request its predecessor dispatched still owes the
    # allowance that turn spent, and it holds no task to find.
    case commit_abandoned_attempt(state, run_id) do
      {:ok, next} -> {next, :cleaned}
      {:error, :no_attempt_pending} -> {state, :cleaned}
      {:error, _reason} -> {state, :unconfirmed}
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
  # Technical depth: called only after the task is dead, so a message that has
  # not arrived by now never will and a zero timeout is exact rather than
  # optimistic. The monitor is flushed in every branch, so a terminated worker's
  # `DOWN` can never later be read as a live worker failing.
  defp take_worker_result(reference) do
    result =
      receive do
        {^reference, {:ok, value}} -> {:ok, value}
        {^reference, other} -> {:answered, other}
      after
        0 -> :none
      end

    Process.demonitor(reference, [:flush])
    result
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
  # and its fact committed -- all local state only this process may touch. The
  # job id is read before any of that, because committing the fact may advance
  # the work past the point where it is still there to read.
  defp settle_executor_work(state, run_id) do
    case in_flight_of(state, :executor, run_id) do
      nil ->
        {state, :cleaned}

      {reference, pid} ->
        _ = Task.Supervisor.terminate_child(state.workers, pid)
        state = %{state | in_flight: Map.delete(state.in_flight, reference)}

        case take_worker_result(reference) do
          {:ok, receipt} when is_map(receipt) ->
            state = close_tool_stream(state, run_id, :complete)

            case put_executor_fact(state, run_id, receipt) do
              {:ok, next} -> {next, :cleaned}
              {:error, _reason} -> {state, :unconfirmed}
            end

          _unproved ->
            {close_tool_stream(state, run_id, :abandoned), :unconfirmed}
        end
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

  # Concept: an executor's progress must prove which attempt it belongs to
  # before any of it is shown to an operator.
  #
  # Technical depth: the domain is derived from the `(operation_id, attempt)`
  # this coordinator dispatched and journaled, and every binding the dispatched
  # job carries — operation and attempt, session, run and turn, the attempt-bound
  # canonical request digest, both origin epochs, the executor's identity, and
  # its fencing token — is compared against the job rather than read off the
  # event. Matching a `tool_call_id` alone was not a check: a stale or faulty
  # executor that echoed the live call id could carry any other binding it liked,
  # and the whole map it supplied was then merged into the item the operator
  # sees, so an unbounded chunk, a pid, or a credential reached the progress
  # plane on the strength of one field.
  #
  # A missing binding and a present-but-wrong binding are refused identically,
  # because `Map.fetch/2` distinguishes them and equality does not. What survives
  # is projected as a named bounded subset that this coordinator builds; the
  # executor's map is never forwarded. A refused event is dropped and counted on
  # the attempt's stream state, and never projected, journaled, published, or
  # allowed to affect an outcome, a bound, or a receipt.
  defp executor_progress_fun(state, work) do
    job = work.job
    domain = StreamDomain.derive(:executor, state.session_id, job.operation_id, job.attempt)
    turn_id = work.turn_id
    tool_call_id = job.tool_call_id
    sink = state.progress_to
    counter = new_stream_counter()
    refused = :atomics.new(1, signed: false)
    bindings = progress_bindings(job)

    stream = %{
      domain: domain,
      turn_id: turn_id,
      counter: counter,
      refused: refused,
      tool_call_id: tool_call_id
    }

    {stream,
     fn event ->
       case project_progress(event, bindings) do
         {:ok, projected} ->
           # The identity is judged first and the sequence reserved second, so a
           # refused event never consumes a number. Reserving is what tests the
           # seal: an event arriving after closure is dropped rather than emitted
           # past a total already published, and it is not counted as a refusal
           # either, because a refusal is this coordinator's judgement about an
           # event's identity and this event's identity is correct -- it is only
           # late.
           case reserve_sequence(counter) do
             :sealed ->
               :ok

             {:ok, sequence} ->
               emit_tool_progress(sink, projected, sequence, %{
                 turn_id: turn_id,
                 tool_call_id: tool_call_id,
                 domain: domain
               })
           end

         :refused ->
           :atomics.add(refused, 1, 1)
       end

       :ok
     end}
  end

  defp emit_tool_progress(sink, projected, sequence, %{
         turn_id: turn_id,
         tool_call_id: tool_call_id,
         domain: domain
       }) do
    emit_progress(
      sink,
      Map.merge(projected, %{
        kind: :tool_progress,
        turn_id: turn_id,
        tool_call_id: tool_call_id,
        stream_domain_id: domain,
        progress_sequence: sequence
      })
    )
  end

  # Concept: the identity an event has to reproduce is the identity the job was
  # dispatched under.
  #
  # Technical depth: taken from the journaled job, so the comparison is against
  # state this coordinator already holds. Nothing here is derived from the event,
  # which is what makes the check fail closed rather than merely self-consistent.
  defp progress_bindings(job) do
    %{
      tool_call_id: job.tool_call_id,
      operation_id: job.operation_id,
      attempt: job.attempt,
      session_id: job.session_id,
      run_id: job.run_id,
      turn_id: job.turn_id,
      canonical_request_digest: job.canonical_request_digest,
      session_epoch_at_dispatch: job.origin_session_epoch,
      executor_epoch: job.origin_executor_epoch,
      executor_identity: job.executor_identity,
      fencing_token: job.fencing_token
    }
  end

  @max_progress_chunk_bytes 65_536
  @progress_streams ["stdout", "stderr"]

  defp project_progress(event, bindings) when is_map(event) do
    bound? =
      Enum.all?(bindings, fn {field, expected} -> Map.fetch(event, field) == {:ok, expected} end)

    if bound? do
      bounded_progress(event)
    else
      :refused
    end
  end

  defp project_progress(_event, _bindings), do: :refused

  # Concept: what an operator is shown is a small, named, plain shape.
  #
  # Technical depth: three fields, each bounded and each checked. A chunk past
  # the declared ceiling, an offset that is not a byte position, or a stream name
  # this boundary does not define is refused rather than truncated, because
  # silently repairing an event would hide the producer that emitted it. Nothing
  # else the executor supplied is carried, so no pid, function, or arbitrary term
  # can cross by riding along in an unexamined key.
  defp bounded_progress(%{stream: stream, byte_offset: offset, chunk: chunk})
       when stream in @progress_streams and is_integer(offset) and offset >= 0 and
              is_binary(chunk) and byte_size(chunk) <= @max_progress_chunk_bytes,
       do: {:ok, %{stream: stream, byte_offset: offset, chunk: chunk}}

  defp bounded_progress(_event), do: :refused

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
    state = disarm_deadline(state, run_id)

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
    state = close_tool_stream(state, run_id, :complete)

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
    state = close_tool_stream(state, run_id, :abandoned)

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

  # Only a refusal reaches this, and a refusal is always the tagged shape: every
  # other answer took the unproven path before this was called. A wider clause
  # would be a second place deciding what an untagged error means.
  defp failure_of({:error, {:refused_before_effect, reason}}), do: reason

  defp commit_executor_fact(state, run_id, receipt) do
    case put_executor_fact(state, run_id, receipt) do
      {:ok, next} ->
        send(self(), :advance_work)
        {:noreply, next}

      {:error, reason} ->
        {:stop, {:executor_fact_failed, reason}, state}
    end
  end

  # Concept: committing the fact, separated from deciding what to do next.
  #
  # Technical depth: cancellation commits the same fact from inside a command
  # reduction, where a `:noreply` tuple would be the wrong shape and scheduling
  # more work would be exactly wrong.
  defp put_executor_fact(state, run_id, receipt) do
    with {:ok, proposal} <- SessionState.propose_executor_fact(state.durable, run_id, receipt) do
      commit_internal(state, proposal)
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
