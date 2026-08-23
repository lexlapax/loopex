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

  alias Loopex.Runtime.Control
  alias Loopex.Runtime.SessionState
  alias Loopex.Executor
  alias Loopex.Model
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
       grant_decision: Keyword.fetch!(options, :grant_decision),
       fault_to: Keyword.fetch!(options, :fault_to),
       in_flight: %{},
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

      {{:model, run_id}, remaining} ->
        Process.demonitor(reference, [:flush])
        accept_model_result(%{state | in_flight: remaining}, run_id, result)

      {{:executor, run_id}, remaining} ->
        Process.demonitor(reference, [:flush])
        accept_executor_result(%{state | in_flight: remaining}, run_id, result)
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
    case SessionState.propose(state.durable, command) do
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
      end
    else
      {:noreply, %{state | superseded: true}}
    end
  end

  defp advance_work(state), do: {:noreply, state}

  defp prepare_model_request(state, work) do
    {tools, tool_choice} =
      if work.turn_number == 1 do
        provider_tool =
          Map.take(state.tool, ["name", "description", "input_schema"])

        {[provider_tool], %{"type" => "tool", "name" => state.tool["name"]}}
      else
        {[], "none"}
      end

    max_tokens = Keyword.get(state.model.options, :max_tokens, 128)

    with {:ok, request} <-
           Model.request(
             state.model.model,
             [%{"role" => "user", "content" => work.content}],
             tools: tools,
             tool_choice: tool_choice,
             max_tokens: max_tokens
           ),
         {:ok, proposal} <-
           SessionState.propose_model_request(state.durable, work.run_id, request),
         {:ok, next} <- commit_internal(state, proposal) do
      send(self(), :advance_work)
      {:noreply, next}
    else
      {:error, reason} -> {:stop, {:model_request_failed, reason}, state}
    end
  end

  defp start_model_work(state, work) do
    if in_flight?(state, :model, work.run_id) do
      {:noreply, state}
    else
      module = state.model.module
      request = work.request
      options = state.model.options

      task =
        Task.Supervisor.async_nolink(state.workers, fn ->
          module.complete(request, options)
        end)

      {:noreply, put_in_flight(state, task.ref, {:model, work.run_id})}
    end
  end

  defp prepare_effect(state, work) do
    call = work.tool_call

    with true <- call.name == state.tool["name"],
         {:ok, job} <- build_job(state, work, call),
         {:ok, grant} <-
           Executor.issue_grant(
             state.grant_decision,
             job,
             System.system_time(:millisecond) + 60_000
           ),
         {:ok, proposal} <-
           SessionState.propose_effect_intent(state.durable, work.run_id, job, grant),
         {:ok, next} <- commit_internal(state, proposal) do
      start_executor_work(next, Map.fetch!(next.durable.pending_work, work.run_id))
    else
      false -> {:stop, :model_selected_unknown_tool, state}
      {:error, reason} -> {:stop, {:effect_preparation_failed, reason}, state}
    end
  end

  defp start_executor_work(state, work) do
    if in_flight?(state, :executor, work.run_id) do
      {:noreply, state}
    else
      executor = state.executor

      task =
        Task.Supervisor.async_nolink(state.workers, fn ->
          executor.module.execute(executor.reference, work.job, work.grant, [])
        end)

      {:noreply, put_in_flight(state, task.ref, {:executor, work.run_id})}
    end
  end

  defp build_job(state, work, call) do
    now = System.system_time(:millisecond)
    executor = state.executor
    tool = state.tool

    Executor.job(%{
      protocol_version: 1,
      job_id: stable_id("job", work.run_id, call.id),
      operation_id: stable_id("operation", work.run_id, call.id),
      attempt: 1,
      session_id: state.session_id,
      run_id: work.run_id,
      turn_id: work.turn_id,
      tool_call_id: call.id,
      origin_session_epoch: state.owner.owner_epoch,
      origin_executor_epoch: executor.epoch,
      executor_identity: executor.identity,
      required_capabilities: [tool["effect_class"]],
      tool_id: tool["tool_id"],
      tool_version: tool["tool_version"],
      effect_class: tool["effect_class"],
      validated_arguments: call.arguments,
      workspace_ref: executor.workspace_ref,
      workspace_lease: executor.workspace_lease,
      deadline: now + 60_000,
      resource_budgets: %{"max_output_bytes" => 1_048_576},
      idempotency_class: "effectful",
      fencing_token: executor.fencing_token,
      artifact_policy: %{"retain" => true},
      output_policy: %{"capture" => true}
    })
  end

  defp accept_model_result(state, run_id, {:ok, reply}) when is_map(reply) do
    with {:ok, proposal} <- SessionState.propose_model_result(state.durable, run_id, reply),
         {:ok, next} <- commit_internal(state, proposal) do
      send(self(), :advance_work)
      {:noreply, next}
    else
      {:error, reason} -> {:stop, {:model_result_failed, reason}, state}
    end
  end

  defp accept_model_result(state, _run_id, result), do: {:stop, {:model_failed, result}, state}

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

  defp accept_executor_result(state, _run_id, result),
    do: {:stop, {:executor_failed, result}, state}

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

  defp in_flight?(state, kind, run_id),
    do: Enum.any?(state.in_flight, fn {_reference, value} -> value == {kind, run_id} end)

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
