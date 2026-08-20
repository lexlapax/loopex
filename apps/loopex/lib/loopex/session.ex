defmodule Loopex.Session do
  @moduledoc """
  ## Concept

  One session's durable state, and the reducer that rebuilds it from a journal.
  Replaying the same records in the same order always produces the same state,
  which is what makes a restart a recovery rather than a guess.

  The reducer also decides what may be journaled at all. A record it refuses is
  a record the coordinator never writes, so the journal cannot contain a history
  that no session could have had — a duplicate effect identity, a record out of
  sequence, or a resolution for an effect that was never begun.

  ## Technical depth

  Pure and process-free: every function here is a function of its arguments, so
  the properties can be exercised without a journal, a process, or a restart.
  `Loopex.Coordinator` is the only serial writer that drives it.

  Every record carries a `:seq` that must be exactly one past the current state.
  That single rule turns three separate failures into one check: a record
  applied twice, a record applied out of order, and a journal whose prefix was
  replayed against the wrong starting state.

  State separates three things a single "in flight" set would conflate.
  `pending` holds an effect whose intent is durable and whose outcome is still
  expected. `unknown` holds an effect whose outcome can no longer be expected
  and whose mutation domain is therefore fenced. `resolved` holds the settled
  verdict. An effect moves pending to unknown to resolved, never backwards.
  """

  alias Loopex.Journal

  defstruct session_id: nil,
            epoch: 0,
            seq: 0,
            facts: [],
            pending: %{},
            unknown: %{},
            resolved: %{},
            operations: %{}

  @typedoc """
  ## Concept

  The durable state of one session: its recovery epoch, its committed facts, and
  the effects that are in flight, fenced, or settled.

  ## Technical depth

  `facts` is held newest-first so a commit is a prepend rather than a traversal;
  `facts/1` returns them in commit order. `operations` maps an
  `{operation_id, attempt}` pair to its transaction id, which is how a
  preallocated id stays recoverable from the owning operation identity after a
  restart. `epoch` increases once per coordinator start and never repeats, which
  is what makes a result carrying an older epoch recognisably stale.
  """
  @type t :: %__MODULE__{
          session_id: binary() | nil,
          epoch: non_neg_integer(),
          seq: non_neg_integer(),
          facts: [binary()],
          pending: %{optional(binary()) => Journal.entry()},
          unknown: %{optional(binary()) => Journal.entry()},
          resolved: %{optional(binary()) => resolution()},
          operations: %{optional({binary(), pos_integer()}) => binary()}
        }

  @typedoc """
  ## Concept

  How an effect settled: its mutation either took place or did not.

  ## Technical depth

  There is deliberately no third value for "unknown". An unknown outcome is a
  fence, not a resolution: it is a state the session sits in until a solicited
  reconciliation turns it into one of these two.
  """
  @type resolution :: :committed | :failed

  @typedoc """
  ## Concept

  Whether a mutation domain is open for work, or fenced by an unresolved effect.

  ## Technical depth

  `{:fenced, tx_id}` names the transaction responsible, so a refusal says which
  effect must be reconciled rather than only that something is wrong.
  """
  @type fence :: :open | {:fenced, binary()}

  # Concept: an intent is admissible only if it carries what later comparisons need.
  #
  # Technical depth: an intent must carry every field the admission rules later
  # compare against. Checked as a set at apply time so a partially built intent
  # is refused at the write, not discovered during a reconciliation months later
  # when the comparison silently has nothing to compare.
  @intent_fields [
    :tx_id,
    :operation_id,
    :attempt,
    :canonical_request_digest,
    :domain,
    :domain_version,
    :epoch,
    :executor_identity,
    :executor_epoch,
    :fencing_token
  ]

  @doc """
  ## Concept

  The state of a session that has no journal yet.

  ## Technical depth

  Epoch and sequence start at zero, so the first `:session_opened` record a
  coordinator writes carries epoch 1 and sequence 1. A replayed session reaches
  the same state as a fresh one applied to the same records, which is the
  property `replay/2` rests on.
  """
  @spec initial(binary()) :: t()
  def initial(session_id) when is_binary(session_id), do: %__MODULE__{session_id: session_id}

  @doc """
  ## Concept

  Applies one journal record, or explains why the record cannot belong to this
  session's history.

  ## Technical depth

  Total over any map: an unrecognised `:kind` or a malformed record returns an
  error rather than raising, because this function is the gate every durable
  write passes through and a crash there would leave the journal ahead of the
  reducer.
  """
  @spec apply_record(t(), Journal.entry()) :: {:ok, t()} | {:error, term()}
  def apply_record(%__MODULE__{} = state, record) when is_map(record) do
    with :ok <- check_sequence(state, record) do
      step(state, record)
    end
  end

  @doc """
  ## Concept

  Rebuilds a session from a journal's records.

  ## Technical depth

  A left fold, which is the whole reason a restart can resume from a truncated
  journal: replaying a prefix yields exactly the state the session had when that
  prefix was the whole journal. An error carries the index of the offending
  record so a rejected journal can be located rather than merely reported.
  """
  @spec replay(binary(), [Journal.entry()]) ::
          {:ok, t()} | {:error, {term(), non_neg_integer()}}
  def replay(session_id, records) when is_binary(session_id) and is_list(records) do
    records
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, initial(session_id)}, fn {record, index}, {:ok, state} ->
      case apply_record(state, record) do
        {:ok, next} -> {:cont, {:ok, next}}
        {:error, reason} -> {:halt, {:error, {reason, index}}}
      end
    end)
  end

  @doc """
  ## Concept

  The session's committed facts, in the order they were committed.

  ## Technical depth

  Facts are durable public truth. Progress and notifications are neither, and
  never enter this list.
  """
  @spec facts(t()) :: [binary()]
  def facts(%__MODULE__{facts: facts}), do: Enum.reverse(facts)

  @doc """
  ## Concept

  Whether a mutation domain may be acted on, or is fenced by an effect whose
  outcome is unknown.

  ## Technical depth

  The fence is a property of the durable state, not a flag some caller sets, so
  it survives a restart by construction: replay puts the unresolved effect back
  into `unknown` and the domain is fenced again without anyone remembering to
  re-fence it.

  Where several effects in one domain are unknown, the lowest transaction id is
  named, so the refusal is deterministic and two callers see the same answer.
  """
  @spec fence(t(), term()) :: fence()
  def fence(%__MODULE__{unknown: unknown}, domain) do
    unknown
    |> Enum.filter(fn {_tx_id, intent} -> Map.get(intent, :domain) == domain end)
    |> Enum.map(fn {tx_id, _intent} -> tx_id end)
    |> Enum.sort()
    |> case do
      [] -> :open
      [tx_id | _rest] -> {:fenced, tx_id}
    end
  end

  @doc """
  ## Concept

  The journaled intent of an effect that is still pending or fenced.

  ## Technical depth

  The intent is the only admissible basis for comparison when a result or a
  receipt arrives: it is what was durable before dispatch, so it cannot have
  been influenced by whatever came back.
  """
  @spec intent(t(), binary()) :: {:ok, Journal.entry()} | :error
  def intent(%__MODULE__{pending: pending, unknown: unknown}, tx_id) do
    case Map.fetch(pending, tx_id) do
      {:ok, intent} -> {:ok, intent}
      :error -> Map.fetch(unknown, tx_id)
    end
  end

  @doc """
  ## Concept

  Where an effect stands: awaited, fenced, settled, or never begun.

  ## Technical depth

  `:no_such_tx` is distinct from `:pending` on purpose. A result for a
  transaction this session never journaled is not a late result; it belongs to
  another session or another attempt, and admitting it would be the exact
  confusion the fencing rules exist to prevent.
  """
  @spec status(t(), term()) :: :pending | :unknown | {:resolved, resolution()} | :no_such_tx
  def status(%__MODULE__{} = state, tx_id) do
    cond do
      Map.has_key?(state.pending, tx_id) -> :pending
      Map.has_key?(state.unknown, tx_id) -> :unknown
      Map.has_key?(state.resolved, tx_id) -> {:resolved, Map.fetch!(state.resolved, tx_id)}
      true -> :no_such_tx
    end
  end

  @doc """
  ## Concept

  Effects whose intent is durable and whose outcome is still expected.

  ## Technical depth

  Sorted, because a restart iterates this list to fence each entry and map key
  order is not a guarantee. An unsorted recovery would write the same records in
  a different order on different runs, which would make two recoveries from one
  journal produce two different journals.
  """
  @spec pending_txs(t()) :: [binary()]
  def pending_txs(%__MODULE__{pending: pending}), do: pending |> Map.keys() |> Enum.sort()

  @doc """
  ## Concept

  Effects that are fenced awaiting reconciliation.

  ## Technical depth

  Sorted for the same determinism reason as `pending_txs/1`. This is the list a
  reconciliation query asks the executor about.
  """
  @spec unknown_txs(t()) :: [binary()]
  def unknown_txs(%__MODULE__{unknown: unknown}), do: unknown |> Map.keys() |> Enum.sort()

  @doc """
  ## Concept

  The transaction id a given operation attempt preallocated.

  ## Technical depth

  This is what "recoverable from the owning operation identity" means in
  practice. After a restart the coordinator knows the operation it was asked to
  perform; this maps that back to the preallocated id whose intent, digest, and
  domain version are on disk, so reconciliation asks about the right
  transaction rather than starting a new one.
  """
  @spec tx_for_operation(t(), binary(), pos_integer()) :: {:ok, binary()} | :error
  def tx_for_operation(%__MODULE__{operations: operations}, operation_id, attempt) do
    Map.fetch(operations, {operation_id, attempt})
  end

  # Concept: every record must be the next one, exactly.
  defp check_sequence(state, record) do
    case Map.get(record, :seq) do
      seq when seq == state.seq + 1 -> :ok
      other -> {:error, {:out_of_sequence, expected: state.seq + 1, got: other}}
    end
  end

  defp step(state, %{kind: :session_opened, session_id: session_id, epoch: epoch} = record) do
    cond do
      session_id != state.session_id ->
        {:error, {:session_mismatch, session_id, state.session_id}}

      not (is_integer(epoch) and epoch > state.epoch) ->
        {:error, {:epoch_not_monotonic, epoch, state.epoch}}

      true ->
        {:ok, advance(%{state | epoch: epoch}, record)}
    end
  end

  defp step(state, %{kind: :fact_committed, fact: fact} = record) when is_binary(fact) do
    {:ok, advance(%{state | facts: [fact | state.facts]}, record)}
  end

  defp step(state, %{kind: :effect_intent, tx_id: tx_id} = record) do
    operation = {Map.get(record, :operation_id), Map.get(record, :attempt)}

    cond do
      status(state, tx_id) != :no_such_tx ->
        {:error, {:duplicate_tx, tx_id}}

      Map.has_key?(state.operations, operation) ->
        {:error, {:duplicate_operation, operation}}

      missing_intent_fields(record) != [] ->
        {:error, {:incomplete_intent, missing_intent_fields(record)}}

      true ->
        {:ok,
         advance(
           %{
             state
             | pending: Map.put(state.pending, tx_id, record),
               operations: Map.put(state.operations, operation, tx_id)
           },
           record
         )}
    end
  end

  defp step(state, %{kind: :effect_unknown, tx_id: tx_id} = record) do
    case Map.fetch(state.pending, tx_id) do
      {:ok, intent} ->
        {:ok,
         advance(
           %{
             state
             | pending: Map.delete(state.pending, tx_id),
               unknown: Map.put(state.unknown, tx_id, intent)
           },
           record
         )}

      :error ->
        {:error, {:not_pending, tx_id, status(state, tx_id)}}
    end
  end

  defp step(state, %{kind: :effect_resolved, tx_id: tx_id, resolution: resolution} = record) do
    cond do
      resolution not in [:committed, :failed] ->
        {:error, {:invalid_resolution, resolution}}

      status(state, tx_id) not in [:pending, :unknown] ->
        {:error, {:not_open, tx_id, status(state, tx_id)}}

      true ->
        {:ok,
         advance(
           %{
             state
             | pending: Map.delete(state.pending, tx_id),
               unknown: Map.delete(state.unknown, tx_id),
               resolved: Map.put(state.resolved, tx_id, resolution),
               facts: resolved_facts(state.facts, resolution, Map.get(record, :fact))
           },
           record
         )}
    end
  end

  defp step(_state, record), do: {:error, {:unrecognised_record, Map.get(record, :kind)}}

  # Concept: a committed effect's fact becomes durable in the same record as its
  # resolution.
  # Technical depth: one record, so there is no window in which an effect is
  # settled but its fact is not yet durable. A failed effect publishes nothing.
  defp resolved_facts(facts, :committed, fact) when is_binary(fact), do: [fact | facts]
  defp resolved_facts(facts, _resolution, _fact), do: facts

  defp missing_intent_fields(record) do
    Enum.reject(@intent_fields, &is_map_key(record, &1))
  end

  defp advance(state, record), do: %{state | seq: Map.fetch!(record, :seq)}
end
