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
  alias Loopex.Store
  alias Loopex.Store.OwnerLane

  @mutation_domain "session"
  @page_size 1_024
  @owner_retry_ms 25
  @max_historical_attempts 1_024

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
