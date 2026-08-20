defmodule Loopex.Coordinator do
  @moduledoc """
  ## Concept

  The sole serial writer of one session's durable truth.

  Every durable change passes through this one process, in order, and the
  ordering it enforces is the point: an effect's intent is durable before the
  effect is dispatched, and a fact is durable before it is published. A caller
  that receives `:ok` therefore knows the journal already has it, and a caller
  that receives nothing knows nothing was published.

  When the coordinator restarts it replays the journal, takes a new epoch, and
  fences every effect whose intent is durable but whose outcome is not. Such an
  effect may or may not have reached the executor — a crash between the journal
  write and the dispatch is indistinguishable from a crash after it — so the
  coordinator refuses to guess. The mutation domain is closed: no further
  dispatch, no publication, and no acknowledgement of that effect, until a
  solicited reconciliation resolves it. Nothing is retried.

  ## Technical depth

  A plain `GenServer` started with no registered name. The caller holds the pid,
  which is what keeps a runtime reference explicit; nothing here reads
  application environment, so two coordinators in one VM share nothing.

  A durable change is a two-step commit against a pure reducer. The record is
  offered to `Loopex.Session.apply_record/2` first, so a record the reducer would
  refuse never reaches the journal. Only when the append has returned `:ok` does
  the process adopt the new state, so a crash during the append leaves the
  in-memory state unadopted and recovery replays whatever bytes landed.

  Dispatch and publication use `send/2` to a target pid supplied at start. The
  target is transient runtime state, never a durable record: the payload that
  crosses the boundary is plain data built by `Loopex.Effect.dispatch/1`. The
  send is what makes "no second dispatch" observable — a collector counts
  messages, so the property is asserted rather than inspected.

  `handle_call/3` returns errors as replies rather than raising. A refused
  outcome is a normal, expected event in this design; crashing on it would turn
  every stale message into a restart, and a restart is exactly what must not be
  triggered by an untrusted late arrival.
  """

  use GenServer

  alias Loopex.Effect
  alias Loopex.Journal
  alias Loopex.Session

  @typedoc """
  ## Concept

  What a coordinator needs to start: which journal holds its truth, which
  session it is, where dispatches and publications go, and which executor it
  expects.

  ## Technical depth

  All four are required. There is no default journal path and no default
  dispatch target, because a coordinator that quietly invented either would be
  writing durable truth somewhere the caller did not choose.
  """
  @type option ::
          {:journal, Path.t()}
          | {:session_id, binary()}
          | {:dispatch_to, pid()}
          | {:executor, Effect.executor()}

  @doc """
  ## Concept

  Starts a coordinator, recovering from its journal if one exists.

  ## Technical depth

  Recovery happens in `init/1`, so `start_link/1` does not return until the new
  epoch and every fence are durable. A caller that gets a pid is talking to a
  coordinator that has already refused to retry anything.

  No name is registered. Callers hold the pid.
  """
  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(options) when is_list(options), do: GenServer.start_link(__MODULE__, options)

  @doc """
  ## Concept

  Journals an effect's intent and then dispatches it. Refuses, without
  dispatching, when the effect's mutation domain is fenced.

  ## Technical depth

  Returns `{:ok, tx_id}` with the preallocated transaction id, or
  `{:error, {:fenced, tx_id}}` naming the unresolved effect that closed the
  domain. The refusal happens before any record is written, so a fenced domain
  produces no journal growth and no message.
  """
  @spec dispatch(pid(), Effect.request()) :: {:ok, binary()} | {:error, term()}
  def dispatch(coordinator, request) when is_map(request) do
    GenServer.call(coordinator, {:dispatch, request})
  end

  @doc """
  ## Concept

  Records that an effect's outcome is unknown, which fences its mutation domain
  until the effect is reconciled.

  ## Technical depth

  This is the explicit form of what recovery does implicitly. It takes a
  transaction id rather than a domain because the fence is a property of the
  unresolved effect: the domain is closed by that transaction and reopens when
  that transaction resolves.

  The `:ok` reply acknowledges the fence, not the effect. Nothing about the
  effect's mutation is acknowledged, published, or dispatched afterwards.
  """
  @spec commit_unknown(pid(), binary()) :: :ok | {:error, term()}
  def commit_unknown(coordinator, tx_id) when is_binary(tx_id) do
    GenServer.call(coordinator, {:commit_unknown, tx_id})
  end

  @doc """
  ## Concept

  Offers a result for an effect that is still awaited. Accepted only when it
  matches the journaled intent and the current epoch; a fenced effect cannot be
  resolved this way at all.

  ## Technical depth

  On acceptance the resolution and any committed fact become durable in one
  record, and only then is the fact published. On refusal nothing is written and
  nothing is sent, and the reply names the field that failed.

  A result for a fenced effect is refused with `{:error, {:fenced, tx_id}}` even
  when every field matches. Once the outcome is unknown, an unsolicited answer
  is not admissible evidence about it; only a solicited receipt is.
  """
  @spec complete(pid(), map()) :: :ok | {:error, term()}
  def complete(coordinator, result) when is_map(result) do
    GenServer.call(coordinator, {:complete, result})
  end

  @doc """
  ## Concept

  Journals a fact and then publishes it. Refuses, without publishing, when the
  domain is fenced.

  ## Technical depth

  The fence covers publication as well as dispatch, so a session whose mutation
  domain is in an unknown state cannot emit public truth about that domain while
  the question is open.
  """
  @spec commit_fact(pid(), term(), binary()) :: :ok | {:error, term()}
  def commit_fact(coordinator, domain, fact) when is_binary(fact) do
    GenServer.call(coordinator, {:commit_fact, domain, fact})
  end

  @doc """
  ## Concept

  Opens a reconciliation query and returns its id together with the effects it
  asks about.

  ## Technical depth

  The id is fresh on every call, so a receipt answering an earlier query is no
  longer solicited and will be refused. Only the current query id is retained;
  it is transient process state, not durable truth, because a query is a question
  and not a fact.
  """
  @spec reconciliation_query(pid()) :: {:ok, binary(), [binary()]}
  def reconciliation_query(coordinator), do: GenServer.call(coordinator, :reconciliation_query)

  @doc """
  ## Concept

  Offers a receipt in answer to the current reconciliation query, resolving a
  fenced effect when it is admissible.

  ## Technical depth

  Refuses with `{:error, :unsolicited}` when no query is open. Otherwise applies
  `Loopex.Effect.admit_receipt/3` against the journaled intent and, on
  acceptance, commits the resolution and publishes any fact — which also lifts
  the fence, because the fence is derived from the durable state rather than
  held separately.
  """
  @spec reconcile(pid(), map()) :: :ok | {:error, term()}
  def reconcile(coordinator, receipt) when is_map(receipt) do
    GenServer.call(coordinator, {:reconcile, receipt})
  end

  @doc """
  ## Concept

  The session's durable state, for callers that need to observe what recovery
  reconstructed.

  ## Technical depth

  A read-only copy of the reducer's state. Nothing about it is authoritative
  outside the coordinator: the journal is the truth and this is what replaying it
  produced.
  """
  @spec durable_state(pid()) :: Session.t()
  def durable_state(coordinator), do: GenServer.call(coordinator, :durable_state)

  @impl GenServer
  def init(options) do
    journal = Keyword.fetch!(options, :journal)
    session_id = Keyword.fetch!(options, :session_id)

    # Technical depth: a torn tail is deliberately not a startup failure. The
    # records before the tear are the state that was acknowledged, so recovery
    # replays them and continues; refusing to start would turn every crash
    # mid-append into a session that can never be recovered.
    #
    # The tear must be discarded before anything else is written, and this is not
    # housekeeping. append/2 writes at the end of the file and read/1 stops at the
    # first bad frame, so a tear left in place makes every later record
    # unreachable: recovery would replay the prefix, then acknowledge and publish
    # facts that disappear on the next restart. The tail is therefore resolved
    # first, and a failure to resolve it stops the coordinator rather than letting
    # it run on a journal it cannot durably extend.
    # The journal is claimed before it is read, and held until this process stops.
    # A claim taken only around the repair made every append a check-then-write:
    # a repair could start between the check and the write, and the append it then
    # destroyed had already been acknowledged. Holding it for the session's whole
    # life makes a second owner impossible, so the only writer is this GenServer,
    # which serialises its own appends and its recovery by construction.
    #
    # Exits are trapped so terminate/2 runs and the claim is released; without it
    # a clean stop would strand the sentinel and the next owner would need a human.
    Process.flag(:trap_exit, true)

    # The claim is taken in its own step, before anything that can fail, because
    # what happens on failure differs by whether this process holds it. Inside a
    # single `with`, `else` cannot bind `claim` -- there is no way to tell "the
    # claim was refused" from "the claim was taken and the read then failed", and
    # the second case must release.
    case Journal.claim_session(journal) do
      {:error, {:repair_already_held, _lock, _who} = held} ->
        # Never released here: this process does not own it.
        {:stop, {:journal_claimed_by_another_owner, held}}

      {:error, reason} ->
        {:stop, {:recovery_failed, reason}}

      {:ok, claim} ->
        case start_claimed(journal, claim, session_id, options) do
          {:ok, state} ->
            {:ok, state}

          {:stop, reason} ->
            # gen_server does NOT call terminate/2 when init/1 returns {:stop, _},
            # so this is the only place the claim can be released on this path.
            # Leaving it stranded was survivable inside one VM -- the next start
            # proved the owner dead and took over -- and permanent across a VM
            # restart, where the recorded os_pid is no longer this process: the
            # session could not start until a human deleted a file in a temp
            # directory. Repairing the journal is the operator's expected next
            # move and has to be sufficient.
            Journal.release_session(journal, claim)
            {:stop, reason}
        end
    end
  end

  # Everything after the claim is taken. Returning {:stop, _} here is what tells
  # init/1 to release before it stops.
  defp start_claimed(journal, claim, session_id, options) do
    with {:ok, records, tail} <- Journal.read(journal),
         :ok <- resolve_tail(journal, tail, claim),
         {:ok, session} <- Session.replay(session_id, records) do
      state = %{
        journal: journal,
        claim: claim,
        session: session,
        dispatch_to: Keyword.fetch!(options, :dispatch_to),
        executor: Keyword.fetch!(options, :executor),
        query: nil
      }

      case recover(state) do
        {:ok, recovered} -> {:ok, recovered}
        {:error, reason} -> {:stop, {:recovery_failed, reason}}
      end
    else
      {:error, reason} -> {:stop, {:recovery_failed, reason}}
    end
  end

  @impl GenServer
  def terminate(_reason, %{journal: journal, claim: claim}) do
    Journal.release_session(journal, claim)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  # Concept: a journal must end where its durable truth ends.
  # Technical depth: nothing acknowledged is discarded — a torn frame was never a
  # complete record, so no caller was told it committed.
  defp resolve_tail(_journal, :complete, _claim), do: :ok

  defp resolve_tail(journal, {:torn, offset}, claim),
    do: Journal.discard_torn_tail(journal, offset, claim)

  # Corruption is not a torn append and is never repaired automatically. A complete
  # frame that fails its checksum means bytes changed under an acknowledged record,
  # and the records beyond it may be perfectly intact. Discarding from there would
  # destroy durable truth to make startup succeed, so the coordinator refuses and
  # leaves the journal for an operator.
  defp resolve_tail(journal, {:corrupt, offset}, _claim),
    do: {:error, {:journal_corrupt, journal, offset}}

  # Concept: a restart takes a new epoch, then fences every effect whose outcome
  # it cannot know.
  # Technical depth: the epoch is committed first so that a crash partway through
  # fencing still leaves the pending intents pending, and the next start fences
  # them again. Fencing is therefore idempotent across repeated crashes: an
  # effect already in the unknown set is not pending and is not re-fenced.
  defp recover(state) do
    opened = %{
      kind: :session_opened,
      session_id: state.session.session_id,
      epoch: state.session.epoch + 1
    }

    with {:ok, state} <- commit(state, opened) do
      fence_pending(state)
    end
  end

  defp fence_pending(state) do
    state.session
    |> Session.pending_txs()
    |> Enum.reduce_while({:ok, state}, fn tx_id, {:ok, current} ->
      case commit(current, %{kind: :effect_unknown, tx_id: tx_id}) do
        {:ok, next} -> {:cont, {:ok, next}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  @impl GenServer
  def handle_call({:dispatch, request}, _from, state) do
    case Session.fence(state.session, Map.fetch!(request, :domain)) do
      {:fenced, tx_id} ->
        {:reply, {:error, {:fenced, tx_id}}, state}

      :open ->
        intent = Effect.intent(request, state.session.epoch, state.executor)

        case commit(state, intent) do
          {:ok, committed} ->
            send(committed.dispatch_to, {:loopex_dispatch, Effect.dispatch(intent)})
            {:reply, {:ok, Map.fetch!(intent, :tx_id)}, committed}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  @impl GenServer
  def handle_call({:commit_unknown, tx_id}, _from, state) do
    case commit(state, %{kind: :effect_unknown, tx_id: tx_id}) do
      {:ok, committed} -> {:reply, :ok, committed}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl GenServer
  def handle_call({:complete, result}, _from, state) do
    tx_id = Map.get(result, :tx_id)

    case Session.status(state.session, tx_id) do
      :pending ->
        {:ok, intent} = Session.intent(state.session, tx_id)

        case Effect.admit_live_result(intent, result, state.session.epoch) do
          :ok -> resolve(state, intent, result)
          {:error, reason} -> {:reply, {:error, reason}, state}
        end

      :unknown ->
        {:reply, {:error, {:fenced, tx_id}}, state}

      {:resolved, resolution} ->
        {:reply, {:error, {:already_resolved, resolution}}, state}

      :no_such_tx ->
        {:reply, {:error, {:no_such_tx, tx_id}}, state}
    end
  end

  @impl GenServer
  def handle_call({:commit_fact, domain, fact}, _from, state) do
    case Session.fence(state.session, domain) do
      {:fenced, tx_id} ->
        {:reply, {:error, {:fenced, tx_id}}, state}

      :open ->
        case commit(state, %{kind: :fact_committed, fact: fact}) do
          {:ok, committed} ->
            send(committed.dispatch_to, {:loopex_published, fact})
            {:reply, :ok, committed}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  @impl GenServer
  def handle_call(:reconciliation_query, _from, state) do
    query_id =
      "reconcile-" <>
        Integer.to_string(state.session.epoch) <>
        "-" <> Integer.to_string(System.unique_integer([:positive, :monotonic]))

    {:reply, {:ok, query_id, Session.unknown_txs(state.session)}, %{state | query: query_id}}
  end

  @impl GenServer
  def handle_call({:reconcile, _receipt}, _from, %{query: nil} = state) do
    {:reply, {:error, :unsolicited}, state}
  end

  @impl GenServer
  def handle_call({:reconcile, receipt}, _from, state) do
    tx_id = Map.get(receipt, :tx_id)

    case Session.status(state.session, tx_id) do
      :unknown ->
        {:ok, intent} = Session.intent(state.session, tx_id)

        expected = %{
          reconciliation_query_id: state.query,
          session_epoch: state.session.epoch,
          executor_identity: Map.fetch!(state.executor, :identity)
        }

        case Effect.admit_receipt(intent, receipt, expected) do
          :ok -> resolve(state, intent, receipt)
          {:error, reason} -> {:reply, {:error, reason}, state}
        end

      other ->
        {:reply, {:error, {:not_fenced, tx_id, other}}, state}
    end
  end

  @impl GenServer
  def handle_call(:durable_state, _from, state), do: {:reply, state.session, state}

  # Concept: settle an effect durably, then publish its fact.
  # Technical depth: resolution and fact are one record, so there is no window in
  # which the effect is settled but the fact it committed is not durable. The
  # publication happens only after the append returned, which is the "facts
  # commit before publication" ordering.
  defp resolve(state, intent, answer) do
    record = %{
      kind: :effect_resolved,
      tx_id: Map.fetch!(intent, :tx_id),
      resolution: Map.get(answer, :resolution),
      fact: Map.get(answer, :fact)
    }

    case commit(state, record) do
      {:ok, committed} ->
        publish(committed, record)
        {:reply, :ok, committed}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp publish(state, %{resolution: :committed, fact: fact}) when is_binary(fact) do
    send(state.dispatch_to, {:loopex_published, fact})
  end

  defp publish(_state, _record), do: :ok

  # Concept: the reducer decides what may become durable; the journal makes it so.
  # Technical depth: the reducer runs first because it is pure, so a refused
  # record costs nothing and never reaches the file. The new state is adopted
  # only after the append returns, so an append that dies partway through leaves
  # this process's state exactly where recovery will find the journal.
  defp commit(state, record) do
    sequenced = Map.put(record, :seq, state.session.seq + 1)

    with {:ok, session} <- Session.apply_record(state.session, sequenced),
         :ok <- Journal.append(state.journal, sequenced, state.claim) do
      {:ok, %{state | session: session}}
    end
  end
end
