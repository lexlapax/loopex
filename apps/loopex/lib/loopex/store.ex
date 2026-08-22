defmodule Loopex.Store do
  @moduledoc """
  ## Concept

  The private boundary through which runtime control and a session owner commit
  durable truth. A Store allocates a session together with its runtime command
  mapping and genesis, advances session ownership before command admission, and
  atomically appends private records and public outbox events for the current
  owner.

  The boundary has exactly three mutation outcomes. A confirmed commit is
  durable, a confirmed non-commit changes no journal or outbox truth, and an
  unknown commit fences its caller until the same transaction is resolved. A
  timeout is never converted into a non-commit.

  ## Technical depth

  `transact/2` is the one mutation callback. The closed transaction maps bind
  their exact deterministic canonical bytes and raw SHA-256 digest before the
  adapter call. An adapter resolves a known transaction before testing current
  ownership, compares every immutable binding including both bytes and digest,
  and performs lookup, ordered compare, mutation, sequence stamping, outbox
  insertion, and terminal-resolution retention at one linearization point.

  Store references are runtime-local handles and may contain a pid; they are
  never durable or public data. Durable records and events remain bounded plain
  maps. Read-only status and ownership-head observations intentionally expose no
  incarnation capability or transaction bytes and cannot authorize mutation.

  Record and event constructors normalize caller atom key spellings to bounded
  binaries and normalize `kind` to a binary. Arbitrary atom values are refused,
  so a cold VM can decode the private log with safe external-term decoding
  without creating atoms or depending on which host modules were previously
  loaded.
  """

  alias Loopex.Store.Transitions

  @max_identifier_bytes 256
  @max_item_bytes 65_536
  @max_mutation_bytes 1_048_576
  @max_items 1_024
  @max_depth 12
  @canonical_field_names [:canonical_record_bytes, :canonical_mutation_digest]
  @reserved_event_binary_fields ["event_sequence", "owner_epoch", "owner_incarnation_id"]
  @reserved_event_fields [
    :event_sequence,
    :owner_epoch,
    :owner_incarnation_id,
    "event_sequence",
    "owner_epoch",
    "owner_incarnation_id"
  ]

  @typedoc """
  ## Concept

  An explicit runtime-local handle for one Store implementation.

  ## Technical depth

  The adapter module implements this behaviour and the reference is interpreted
  only by that adapter. Neither value is written to durable state.
  """
  @opaque t :: %__MODULE__{adapter: module(), reference: term()}
  defstruct [:adapter, :reference]

  @typedoc """
  ## Concept

  A bounded identity used by Store transactions and durable rows.

  ## Technical depth

  Constructors accept a non-empty binary of at most 256 bytes. The Store does
  not interpret identity content as authority.
  """
  @type id :: binary()

  @typedoc """
  ## Concept

  The durable mutation namespace within one session.

  ## Technical depth

  Resolution identity is scoped by session, mutation domain, and transaction
  ID. A domain is a bounded non-empty binary.
  """
  @type mutation_domain :: binary()

  @typedoc """
  ## Concept

  The immutable digest bound to one canonical Store mutation.

  ## Technical depth

  It is the raw 32-byte SHA-256 of `canonical_record_bytes`.
  """
  @type digest :: <<_::256>>

  @typedoc """
  ## Concept

  One bounded private fact payload.

  ## Technical depth

  `:kind` is normalized to a binary; optional keys are bounded binaries and
  values are recursively bounded plain data with no runtime terms.
  """
  @type plain_record :: %{required(:kind) => binary(), optional(binary()) => term()}

  @typedoc """
  ## Concept

  One bounded public event before the Store assigns its sequence.

  ## Technical depth

  The event has a stable ID and binary kind. Reserved Store stamps and the
  owner-incarnation capability are rejected recursively.
  """
  @type plain_event :: %{
          required(:event_id) => id(),
          required(:kind) => binary(),
          optional(binary()) => term()
        }

  @typedoc """
  ## Concept

  The atomic runtime-control request that creates one durable session.

  ## Technical depth

  Runtime and command identity, genesis, canonical bytes, and digest form its
  immutable binding. The command ID is its transaction identity.
  """
  @type create_session_transaction :: %{
          required(:type) => :create_session,
          required(:runtime_id) => id(),
          required(:command_id) => id(),
          required(:genesis) => plain_record(),
          required(:canonical_record_bytes) => binary(),
          required(:canonical_mutation_digest) => digest()
        }

  @typedoc """
  ## Concept

  The compare-and-set request that installs a fresh session owner.

  ## Technical depth

  It binds the prior owner epoch and session-global journal version while
  proposing a new bounded incarnation capability.
  """
  @type advance_owner_transaction :: %{
          required(:type) => :advance_owner,
          required(:session_id) => id(),
          required(:mutation_domain) => mutation_domain(),
          required(:tx_id) => id(),
          required(:expected_owner_epoch) => non_neg_integer(),
          required(:expected_journal_version) => non_neg_integer(),
          required(:proposed_owner_incarnation_id) => binary(),
          required(:canonical_record_bytes) => binary(),
          required(:canonical_mutation_digest) => digest()
        }

  @typedoc """
  ## Concept

  One atomic private-record and public-outbox commit by the current owner.

  ## Technical depth

  The request binds the current owner pair, expected journal version, ordered
  payloads, exact canonical bytes, and digest.
  """
  @type session_transaction :: %{
          required(:type) => :session_commit,
          required(:session_id) => id(),
          required(:mutation_domain) => mutation_domain(),
          required(:tx_id) => id(),
          required(:expected_owner_epoch) => non_neg_integer(),
          required(:expected_owner_incarnation_id) => binary(),
          required(:expected_journal_version) => non_neg_integer(),
          required(:records) => nonempty_list(plain_record()),
          required(:outbox) => [plain_event()],
          required(:canonical_record_bytes) => binary(),
          required(:canonical_mutation_digest) => digest()
        }

  @typedoc """
  ## Concept

  Any mutation admitted by the Store boundary.

  ## Technical depth

  The union is closed to session creation, owner succession, and ordinary
  session commit; the transition catalogue derives from the same shapes.
  """
  @type transaction ::
          create_session_transaction() | advance_owner_transaction() | session_transaction()

  @typedoc """
  ## Concept

  Store-stamped evidence returned for a confirmed commit.

  ## Technical depth

  Its exact fields depend on the closed transaction kind and contain the
  allocated identity or Store-assigned versions needed by the caller.
  """
  @type committed_receipt :: %{
          required(:type) => :create_session | :advance_owner | :session_commit,
          optional(atom()) => term()
        }

  @typedoc """
  ## Concept

  The exhaustive result of a Store mutation call.

  ## Technical depth

  Confirmed commit and confirmed non-commit are terminal. `commit_unknown`
  carries the preallocated transaction ID and requires exact resolution before
  that mutation domain can proceed.
  """
  @type outcome ::
          {:committed, id(), committed_receipt()}
          | {:not_committed, atom()}
          | {:commit_unknown, id()}

  @typedoc """
  ## Concept

  A non-authorizing observation of one scoped transaction resolution.

  ## Technical depth

  Terminal observations omit receipts and bindings; absence is not proof of a
  future result, and unavailability requires the caller to remain fenced.
  """
  @type transaction_status ::
          {:terminal, :committed}
          | {:terminal, {:not_committed, atom()}}
          | :absent
          | :unavailable

  @typedoc """
  ## Concept

  The durable compare values from the current session head.

  ## Technical depth

  It intentionally omits the owner-incarnation capability and therefore cannot
  authorize an ordinary commit.
  """
  @type ownership_head :: %{
          required(:owner_epoch) => non_neg_integer(),
          required(:journal_version) => non_neg_integer()
        }

  @typedoc """
  ## Concept

  One Store-stamped private history row.

  ## Technical depth

  Journal version, owner pair, and payload are committed atomically. Only
  private recovery reads expose the incarnation ID.
  """
  @type private_record :: %{
          required(:journal_version) => pos_integer(),
          required(:owner_epoch) => non_neg_integer(),
          required(:owner_incarnation_id) => binary() | nil,
          required(:payload) => plain_record()
        }

  @typedoc """
  ## Concept

  One Store-stamped public outbox row.

  ## Technical depth

  The Store assigns a consecutive event sequence while preserving event ID and
  payload. Owner capabilities and private journal stamps are absent.
  """
  @type outbox_event :: %{
          required(:event_sequence) => pos_integer(),
          required(:event_id) => id(),
          required(:kind) => binary(),
          optional(binary()) => term()
        }

  @doc """
  ## Concept

  Atomically resolves one closed Store transaction.

  ## Technical depth

  Implementations retain the immutable binding and terminal resolution at the
  same linearization point as any records, mappings, or outbox rows.
  """
  @callback transact(reference :: term(), transaction()) :: outcome()

  @doc """
  ## Concept

  Observes one scoped transaction without granting mutation authority.

  ## Technical depth

  The callback returns only the four status classes and never returns a receipt,
  owner-incarnation ID, canonical bytes, digest, or expected version.
  """
  @callback transaction_status(
              reference :: term(),
              session_id :: id(),
              mutation_domain(),
              tx_id :: id()
            ) :: transaction_status()

  @doc """
  ## Concept

  Reads the current durable compare head for owner recovery.

  ## Technical depth

  The session-global epoch and journal version are observable; the current
  incarnation capability is deliberately not returned.
  """
  @callback ownership_head(
              reference :: term(),
              session_id :: id(),
              mutation_domain()
            ) :: {:ok, ownership_head()} | :absent | :unavailable

  @doc """
  ## Concept

  Reads a bounded page of private session history.

  ## Technical depth

  Rows begin strictly after the supplied journal version and remain in durable
  Store order.
  """
  @callback load_records(
              reference :: term(),
              session_id :: id(),
              after_version :: non_neg_integer(),
              limit :: pos_integer()
            ) :: {:ok, [private_record()]} | {:error, term()} | :unavailable

  @doc """
  ## Concept

  Reads a bounded page of committed public outbox history.

  ## Technical depth

  Rows begin strictly after the supplied event sequence and retain their stable
  Store-assigned identity without private owner capability data.
  """
  @callback load_events(
              reference :: term(),
              session_id :: id(),
              after_sequence :: non_neg_integer(),
              limit :: pos_integer()
            ) :: {:ok, [outbox_event()]} | {:error, term()} | :unavailable

  @doc """
  ## Concept

  Creates an explicit Store handle from an adapter and its private reference.

  ## Technical depth

  The module must declare this behaviour. The reference is deliberately not
  inspected by core and no default adapter or global lookup exists.
  """
  @spec new(module(), term()) :: {:ok, t()} | {:error, :not_a_store_adapter}
  def new(adapter, reference) when is_atom(adapter) do
    behaviours =
      if Code.ensure_loaded?(adapter) do
        adapter.module_info(:attributes)
        |> Keyword.get_values(:behaviour)
        |> List.flatten()
      else
        []
      end

    case __MODULE__ in behaviours do
      true -> {:ok, %__MODULE__{adapter: adapter, reference: reference}}
      false -> {:error, :not_a_store_adapter}
    end
  end

  @doc """
  ## Concept

  Builds the atomic runtime-control transaction that allocates one session and
  commits its command mapping and genesis together.

  ## Technical depth

  The command ID is also this transaction's scoped identity. Re-presenting the
  resulting map byte-for-byte returns the retained session ID; changing genesis
  under the same runtime and command conflicts.
  """
  @spec create_session(id(), id(), plain_record()) ::
          {:ok, create_session_transaction()} | {:error, term()}
  def create_session(runtime_id, command_id, genesis) do
    with {:ok, normalized_genesis} <- normalize_record(genesis) do
      fields = [
        type: :create_session,
        runtime_id: runtime_id,
        command_id: command_id,
        genesis: normalized_genesis
      ]

      build_transaction(fields)
    end
  end

  @doc """
  ## Concept

  Builds the transaction that installs a fresh session-owner incarnation before
  that coordinator may admit commands.

  ## Technical depth

  Succession binds the observed prior epoch and session-global journal version,
  but never requires the prior incarnation capability. The Store increments the
  epoch exactly once and stamps the succession record only if both comparisons
  hold at commit.
  """
  @spec advance_owner(
          id(),
          mutation_domain(),
          id(),
          non_neg_integer(),
          non_neg_integer(),
          binary()
        ) :: {:ok, advance_owner_transaction()} | {:error, term()}
  def advance_owner(
        session_id,
        mutation_domain,
        tx_id,
        expected_owner_epoch,
        expected_journal_version,
        proposed_owner_incarnation_id
      ) do
    fields = [
      type: :advance_owner,
      session_id: session_id,
      mutation_domain: mutation_domain,
      tx_id: tx_id,
      expected_owner_epoch: expected_owner_epoch,
      expected_journal_version: expected_journal_version,
      proposed_owner_incarnation_id: proposed_owner_incarnation_id
    ]

    build_transaction(fields)
  end

  @doc """
  ## Concept

  Builds one ordinary session transaction for the current owner.

  ## Technical depth

  The exact ordered private records and outbox events are canonicalized with the
  expected owner pair and journal version. The Store later stamps consecutive
  private and public sequences; callers cannot supply those stamps.
  """
  @spec session_commit(
          id(),
          mutation_domain(),
          id(),
          non_neg_integer(),
          binary(),
          non_neg_integer(),
          nonempty_list(plain_record()),
          [plain_event()]
        ) :: {:ok, session_transaction()} | {:error, term()}
  def session_commit(
        session_id,
        mutation_domain,
        tx_id,
        expected_owner_epoch,
        expected_owner_incarnation_id,
        expected_journal_version,
        records,
        outbox
      ) do
    with {:ok, normalized_records} <- normalize_records(records),
         {:ok, normalized_outbox} <- normalize_events(outbox),
         :ok <- reject_owner_capability(normalized_outbox, expected_owner_incarnation_id) do
      fields = [
        type: :session_commit,
        session_id: session_id,
        mutation_domain: mutation_domain,
        tx_id: tx_id,
        expected_owner_epoch: expected_owner_epoch,
        expected_owner_incarnation_id: expected_owner_incarnation_id,
        expected_journal_version: expected_journal_version,
        records: normalized_records,
        outbox: normalized_outbox
      ]

      build_transaction(fields)
    end
  end

  @doc """
  ## Concept

  Executes one closed Store transaction through its explicit adapter.

  ## Technical depth

  Transition identity is derived before dispatch. Adapter process loss or exit
  is reported as `commit_unknown` for the transaction's preallocated ID; it is
  never guessed to be a non-commit.
  """
  @spec transact(t(), transaction()) :: outcome()
  def transact(%__MODULE__{adapter: adapter, reference: reference}, transaction) do
    with {:ok, _transition} <- Transitions.id(transaction),
         {:ok, tx_id} <- transaction_id(transaction) do
      adapter_call(
        fn -> adapter.transact(reference, transaction) end,
        {:commit_unknown, tx_id}
      )
    else
      {:error, _reason} -> {:not_committed, :invalid_transaction}
    end
  end

  @doc """
  ## Concept

  Observes a scoped transaction's durable terminal state without conveying any
  mutation authority.

  ## Technical depth

  Adapter failure becomes `:unavailable`. The result carries no owner
  incarnation, expected version, canonical bytes, digest, or commit receipt.
  """
  @spec transaction_status(t(), id(), mutation_domain(), id()) ::
          transaction_status()
  def transaction_status(
        %__MODULE__{adapter: adapter, reference: reference},
        session_id,
        mutation_domain,
        tx_id
      ) do
    with {:ok, _session_id} <- validate_identifier(session_id),
         {:ok, _mutation_domain} <- validate_identifier(mutation_domain),
         {:ok, _tx_id} <- validate_identifier(tx_id) do
      adapter_call(
        fn -> adapter.transaction_status(reference, session_id, mutation_domain, tx_id) end,
        :unavailable
      )
    else
      _invalid -> :unavailable
    end
  end

  @doc """
  ## Concept

  Reads the durable owner epoch and session-global journal version needed for a
  fresh succession attempt.

  ## Technical depth

  The incumbent incarnation ID is intentionally absent. A dead-owner recovery
  can compare-and-set a fresh proposed ID but cannot obtain the old capability
  from this observation.
  """
  @spec ownership_head(t(), id(), mutation_domain()) ::
          {:ok, ownership_head()} | :absent | :unavailable
  def ownership_head(
        %__MODULE__{adapter: adapter, reference: reference},
        session_id,
        mutation_domain
      ) do
    with {:ok, _session_id} <- validate_identifier(session_id),
         {:ok, _mutation_domain} <- validate_identifier(mutation_domain) do
      adapter_call(
        fn -> adapter.ownership_head(reference, session_id, mutation_domain) end,
        :unavailable
      )
    else
      _invalid -> :unavailable
    end
  end

  @doc """
  ## Concept

  Loads a bounded page of committed private records after a journal version.

  ## Technical depth

  The adapter returns only store-stamped history. Invalid paging arguments are
  refused before dispatch, and adapter loss is explicit unavailability.
  """
  @spec load_records(t(), id(), non_neg_integer(), pos_integer()) ::
          {:ok, [private_record()]} | {:error, term()} | :unavailable
  def load_records(%__MODULE__{} = store, session_id, after_version, limit) do
    with {:ok, _session_id} <- validate_identifier(session_id),
         :ok <- validate_page(after_version, limit) do
      adapter_call(
        fn -> store.adapter.load_records(store.reference, session_id, after_version, limit) end,
        :unavailable
      )
    end
  end

  @doc """
  ## Concept

  Loads a bounded page of committed public outbox events after an event
  sequence.

  ## Technical depth

  Public event sequence is independent of private journal version, and returned
  events never carry an owner-incarnation capability.
  """
  @spec load_events(t(), id(), non_neg_integer(), pos_integer()) ::
          {:ok, [outbox_event()]} | {:error, term()} | :unavailable
  def load_events(%__MODULE__{} = store, session_id, after_sequence, limit) do
    with {:ok, _session_id} <- validate_identifier(session_id),
         :ok <- validate_page(after_sequence, limit) do
      adapter_call(
        fn -> store.adapter.load_events(store.reference, session_id, after_sequence, limit) end,
        :unavailable
      )
    end
  end

  @doc false
  @spec validate_transaction(map()) :: :ok | {:error, term()}
  def validate_transaction(transaction) when is_map(transaction) do
    with {:ok, fields} <- semantic_fields(transaction),
         :ok <- validate_exact_keys(transaction, fields),
         :ok <- validate_fields(fields),
         {:ok, canonical} <- canonical_bytes(fields),
         true <- Map.get(transaction, :canonical_record_bytes) == canonical,
         true <- Map.get(transaction, :canonical_mutation_digest) == digest(canonical) do
      :ok
    else
      false -> {:error, :canonical_binding_mismatch}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  @spec immutable_binding(map()) :: {:ok, map()} | {:error, term()}
  def immutable_binding(transaction) when is_map(transaction) do
    with {:ok, fields} <- semantic_fields(transaction),
         :ok <- validate_exact_keys(transaction, fields),
         :ok <- validate_fields(fields),
         {:ok, canonical} <- fetch_binary(transaction, :canonical_record_bytes),
         {:ok, mutation_digest} <- fetch_digest(transaction, :canonical_mutation_digest) do
      {:ok,
       fields
       |> Map.new()
       |> Map.put(:canonical_record_bytes, canonical)
       |> Map.put(:canonical_mutation_digest, mutation_digest)}
    end
  end

  @doc false
  @spec transaction_id(map()) :: {:ok, id()} | {:error, term()}
  def transaction_id(%{type: :create_session} = transaction),
    do: fetch_identifier(transaction, :command_id)

  def transaction_id(transaction), do: fetch_identifier(transaction, :tx_id)

  defp build_transaction(fields) do
    with :ok <- validate_fields(fields),
         {:ok, canonical} <- canonical_bytes(fields) do
      {:ok,
       fields
       |> Map.new()
       |> Map.put(:canonical_record_bytes, canonical)
       |> Map.put(:canonical_mutation_digest, digest(canonical))}
    end
  end

  defp semantic_fields(%{type: :create_session} = transaction) do
    fetch_fields(transaction, [:type, :runtime_id, :command_id, :genesis])
  end

  defp semantic_fields(%{type: :advance_owner} = transaction) do
    fetch_fields(transaction, [
      :type,
      :session_id,
      :mutation_domain,
      :tx_id,
      :expected_owner_epoch,
      :expected_journal_version,
      :proposed_owner_incarnation_id
    ])
  end

  defp semantic_fields(%{type: :session_commit} = transaction) do
    fetch_fields(transaction, [
      :type,
      :session_id,
      :mutation_domain,
      :tx_id,
      :expected_owner_epoch,
      :expected_owner_incarnation_id,
      :expected_journal_version,
      :records,
      :outbox
    ])
  end

  defp semantic_fields(_transaction), do: {:error, :unknown_transaction_type}

  defp fetch_fields(transaction, names) do
    Enum.reduce_while(names, {:ok, []}, fn name, {:ok, fields} ->
      case Map.fetch(transaction, name) do
        {:ok, value} -> {:cont, {:ok, fields ++ [{name, value}]}}
        :error -> {:halt, {:error, {:missing_field, name}}}
      end
    end)
  end

  defp validate_exact_keys(transaction, fields) do
    expected =
      fields
      |> Enum.map(&elem(&1, 0))
      |> Kernel.++(@canonical_field_names)
      |> MapSet.new()

    if Map.keys(transaction) |> MapSet.new() |> MapSet.equal?(expected) do
      :ok
    else
      {:error, :invalid_transaction_shape}
    end
  end

  defp validate_fields(fields) do
    transaction = Map.new(fields)

    with {:ok, transition} <- Transitions.id(transaction),
         :ok <- validate_common(transition, transaction),
         :ok <- validate_shape(transition, transaction),
         :ok <- validate_encoded_items(transaction) do
      :ok
    end
  end

  defp validate_common(:runtime_control_create_session, transaction) do
    with {:ok, _runtime_id} <- fetch_identifier(transaction, :runtime_id),
         {:ok, _command_id} <- fetch_identifier(transaction, :command_id) do
      :ok
    end
  end

  defp validate_common(_transition, transaction) do
    with {:ok, _session_id} <- fetch_identifier(transaction, :session_id),
         {:ok, _domain} <- fetch_identifier(transaction, :mutation_domain),
         {:ok, _tx_id} <- fetch_identifier(transaction, :tx_id) do
      :ok
    end
  end

  defp validate_shape(:runtime_control_create_session, transaction) do
    validate_record(Map.get(transaction, :genesis))
  end

  defp validate_shape(:session_journal_advance_owner, transaction) do
    with :ok <- non_negative(transaction, :expected_owner_epoch),
         :ok <- non_negative(transaction, :expected_journal_version),
         {:ok, _incarnation} <-
           fetch_identifier(transaction, :proposed_owner_incarnation_id) do
      :ok
    end
  end

  defp validate_shape(:session_journal_commit, transaction) do
    with :ok <- non_negative(transaction, :expected_owner_epoch),
         {:ok, _incarnation} <-
           fetch_identifier(transaction, :expected_owner_incarnation_id),
         :ok <- non_negative(transaction, :expected_journal_version),
         :ok <- validate_records(Map.get(transaction, :records)),
         :ok <- validate_events(Map.get(transaction, :outbox)),
         :ok <-
           reject_owner_capability(
             Map.get(transaction, :outbox),
             Map.get(transaction, :expected_owner_incarnation_id)
           ) do
      :ok
    end
  end

  defp normalize_records(records)
       when is_list(records) and records != [] and
              length(records) <= @max_items do
    normalize_list(records, &normalize_record/1, :invalid_records)
  end

  defp normalize_records(_records), do: {:error, :invalid_records}

  defp normalize_events(events) when is_list(events) and length(events) <= @max_items do
    with {:ok, normalized} <- normalize_list(events, &normalize_event/1, :invalid_events),
         ids = Enum.map(normalized, &Map.fetch!(&1, :event_id)),
         true <- length(ids) == MapSet.size(MapSet.new(ids)) do
      {:ok, normalized}
    else
      _other -> {:error, :invalid_events}
    end
  end

  defp normalize_events(_events), do: {:error, :invalid_events}

  defp normalize_list(values, fun, error) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, normalized} ->
      case fun.(value) do
        {:ok, item} -> {:cont, {:ok, [item | normalized]}}
        {:error, _reason} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_record(record) when is_map(record) and not is_struct(record) do
    with {:ok, kind, rest} <- take_required(record, :kind, "kind"),
         {:ok, normalized_kind} <- normalize_kind(kind),
         {:ok, normalized_rest} <- normalize_user_map(rest, 0) do
      {:ok, Map.put(normalized_rest, :kind, normalized_kind)}
    else
      _other -> {:error, :invalid_record}
    end
  end

  defp normalize_record(_record), do: {:error, :invalid_record}

  defp normalize_event(event) when is_map(event) and not is_struct(event) do
    with false <- Enum.any?(@reserved_event_fields, &Map.has_key?(event, &1)),
         {:ok, event_id, without_id} <- take_required(event, :event_id, "event_id"),
         {:ok, _event_id} <- validate_identifier(event_id),
         {:ok, kind, rest} <- take_required(without_id, :kind, "kind"),
         {:ok, normalized_kind} <- normalize_kind(kind),
         {:ok, normalized_rest} <- normalize_event_map(rest, 0) do
      {:ok,
       normalized_rest
       |> Map.put(:event_id, event_id)
       |> Map.put(:kind, normalized_kind)}
    else
      _other -> {:error, :invalid_event}
    end
  end

  defp normalize_event(_event), do: {:error, :invalid_event}

  defp normalize_event_map(map, depth)
       when is_map(map) and not is_struct(map) and map_size(map) <= @max_items and
              depth <= @max_depth do
    Enum.reduce_while(map, {:ok, %{}}, fn {key, value}, {:ok, normalized} ->
      with {:ok, normalized_key} <- normalize_user_key(key),
           false <- normalized_key in @reserved_event_binary_fields,
           false <- Map.has_key?(normalized, normalized_key),
           {:ok, normalized_value} <- normalize_event_value(value, depth + 1) do
        {:cont, {:ok, Map.put(normalized, normalized_key, normalized_value)}}
      else
        _other -> {:halt, {:error, :not_plain_event_data}}
      end
    end)
  end

  defp normalize_event_map(_map, _depth), do: {:error, :not_plain_event_data}

  defp normalize_event_value(value, _depth) when is_binary(value) or is_integer(value),
    do: {:ok, value}

  defp normalize_event_value(value, _depth) when value in [nil, true, false], do: {:ok, value}

  defp normalize_event_value(value, depth)
       when is_list(value) and length(value) <= @max_items and depth <= @max_depth do
    normalize_list(value, &normalize_event_value(&1, depth + 1), :not_plain_event_data)
  end

  defp normalize_event_value(value, depth) when is_map(value) and not is_struct(value),
    do: normalize_event_map(value, depth)

  defp normalize_event_value(_value, _depth), do: {:error, :not_plain_event_data}

  defp reject_owner_capability(events, owner_incarnation_id) do
    if Enum.any?(events, &contains_value?(&1, owner_incarnation_id)) do
      {:error, :owner_capability_in_public_event}
    else
      :ok
    end
  end

  defp contains_value?(value, expected) when is_binary(value) and is_binary(expected),
    do: :binary.match(value, expected) != :nomatch

  defp contains_value?(value, expected) when is_list(value),
    do: Enum.any?(value, &contains_value?(&1, expected))

  defp contains_value?(value, expected) when is_map(value) do
    Enum.any?(value, fn {key, item} ->
      contains_value?(key, expected) or contains_value?(item, expected)
    end)
  end

  defp contains_value?(_value, _expected), do: false

  defp take_required(map, atom_key, binary_key) do
    case {Map.fetch(map, atom_key), Map.fetch(map, binary_key)} do
      {{:ok, value}, :error} -> {:ok, value, Map.delete(map, atom_key)}
      {:error, {:ok, value}} -> {:ok, value, Map.delete(map, binary_key)}
      _other -> {:error, :invalid_required_field}
    end
  end

  defp normalize_kind(kind) when is_atom(kind), do: normalize_kind(Atom.to_string(kind))

  defp normalize_kind(kind)
       when is_binary(kind) and byte_size(kind) > 0 and byte_size(kind) <= @max_identifier_bytes,
       do: {:ok, kind}

  defp normalize_kind(_kind), do: {:error, :invalid_kind}

  defp normalize_user_map(map, depth)
       when is_map(map) and not is_struct(map) and map_size(map) <= @max_items and
              depth <= @max_depth do
    Enum.reduce_while(map, {:ok, %{}}, fn {key, value}, {:ok, normalized} ->
      with {:ok, normalized_key} <- normalize_user_key(key),
           false <- Map.has_key?(normalized, normalized_key),
           {:ok, normalized_value} <- normalize_user_value(value, depth + 1) do
        {:cont, {:ok, Map.put(normalized, normalized_key, normalized_value)}}
      else
        _other -> {:halt, {:error, :not_plain_data}}
      end
    end)
  end

  defp normalize_user_map(_map, _depth), do: {:error, :not_plain_data}

  defp normalize_user_key(key) when is_atom(key), do: normalize_user_key(Atom.to_string(key))

  defp normalize_user_key(key)
       when is_binary(key) and byte_size(key) > 0 and byte_size(key) <= @max_identifier_bytes,
       do: {:ok, key}

  defp normalize_user_key(_key), do: {:error, :not_plain_data}

  defp normalize_user_value(value, _depth) when is_binary(value) or is_integer(value),
    do: {:ok, value}

  defp normalize_user_value(value, _depth) when value in [nil, true, false], do: {:ok, value}

  defp normalize_user_value(value, depth)
       when is_list(value) and length(value) <= @max_items and depth <= @max_depth do
    normalize_list(value, &normalize_user_value(&1, depth + 1), :not_plain_data)
  end

  defp normalize_user_value(value, depth) when is_map(value) and not is_struct(value),
    do: normalize_user_map(value, depth)

  defp normalize_user_value(_value, _depth), do: {:error, :not_plain_data}

  defp validate_records(records) when is_list(records) and records != [] do
    case length(records) <= @max_items and Enum.all?(records, &(validate_record(&1) == :ok)) do
      true -> :ok
      false -> {:error, :invalid_records}
    end
  end

  defp validate_records(_records), do: {:error, :invalid_records}

  defp validate_events(events) when is_list(events) and length(events) <= @max_items do
    with true <- Enum.all?(events, &(validate_event(&1) == :ok)),
         ids = Enum.map(events, &Map.fetch!(&1, :event_id)),
         true <- length(ids) == MapSet.size(MapSet.new(ids)) do
      :ok
    else
      _other -> {:error, :invalid_events}
    end
  end

  defp validate_events(_events), do: {:error, :invalid_events}

  defp validate_record(%{kind: kind} = record) when is_binary(kind) do
    validate_plain_map(record)
  end

  defp validate_record(_record), do: {:error, :invalid_record}

  defp validate_event(%{event_id: event_id, kind: kind} = event) when is_binary(kind) do
    with {:ok, _event_id} <- validate_identifier(event_id),
         false <- contains_reserved_event_field?(event),
         :ok <- validate_plain_map(event) do
      :ok
    else
      true -> {:error, :reserved_event_field}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_event(_event), do: {:error, :invalid_event}

  defp contains_reserved_event_field?(value) when is_list(value),
    do: Enum.any?(value, &contains_reserved_event_field?/1)

  defp contains_reserved_event_field?(value) when is_map(value) do
    Enum.any?(value, fn {key, item} ->
      key in @reserved_event_fields or contains_reserved_event_field?(item)
    end)
  end

  defp contains_reserved_event_field?(_value), do: false

  defp validate_plain_map(map) when is_map(map) and not is_struct(map) do
    case plain?(map, 0) do
      true ->
        encoded = :erlang.term_to_binary(map, [:deterministic])

        if byte_size(encoded) <= @max_item_bytes,
          do: :ok,
          else: {:error, :item_too_large}

      false ->
        {:error, :not_plain_data}
    end
  end

  defp validate_plain_map(_map), do: {:error, :not_plain_data}

  defp validate_encoded_items(transaction) do
    fields =
      case transaction do
        %{type: :create_session, genesis: genesis} -> [genesis]
        %{type: :session_commit, records: records, outbox: outbox} -> records ++ outbox
        _other -> []
      end

    if length(fields) <= @max_items * 2,
      do: :ok,
      else: {:error, :too_many_items}
  end

  defp canonical_bytes(fields) do
    bytes = :erlang.term_to_binary(["loopex_store_transaction_v1" | fields], [:deterministic])

    if byte_size(bytes) <= @max_mutation_bytes,
      do: {:ok, bytes},
      else: {:error, :mutation_too_large}
  end

  defp digest(bytes), do: :crypto.hash(:sha256, bytes)

  defp fetch_identifier(map, field) do
    case Map.fetch(map, field) do
      {:ok, value} -> validate_identifier(value)
      :error -> {:error, {:missing_field, field}}
    end
  end

  defp validate_identifier(value)
       when is_binary(value) and byte_size(value) > 0 and
              byte_size(value) <= @max_identifier_bytes,
       do: {:ok, value}

  defp validate_identifier(_value), do: {:error, :invalid_identifier}

  defp fetch_binary(map, field) do
    case Map.fetch(map, field) do
      {:ok, value} when is_binary(value) and byte_size(value) <= @max_mutation_bytes ->
        {:ok, value}

      _other ->
        {:error, {:invalid_field, field}}
    end
  end

  defp fetch_digest(map, field) do
    case Map.fetch(map, field) do
      {:ok, <<_digest::binary-size(32)>> = digest} -> {:ok, digest}
      _other -> {:error, {:invalid_field, field}}
    end
  end

  defp non_negative(map, field) do
    case Map.fetch(map, field) do
      {:ok, value} when is_integer(value) and value >= 0 -> :ok
      _other -> {:error, {:invalid_field, field}}
    end
  end

  defp validate_page(after_position, limit)
       when is_integer(after_position) and after_position >= 0 and is_integer(limit) and
              limit > 0 and limit <= @max_items,
       do: :ok

  defp validate_page(_after_position, _limit), do: {:error, :invalid_page}

  defp adapter_call(fun, fallback) do
    fun.()
  rescue
    _error -> fallback
  catch
    _kind, _reason -> fallback
  end

  defp plain?(_value, depth) when depth > @max_depth, do: false
  defp plain?(value, _depth) when is_binary(value) or is_integer(value), do: true
  defp plain?(value, _depth) when value in [nil, true, false], do: true

  defp plain?(value, depth) when is_list(value) do
    length(value) <= @max_items and Enum.all?(value, &plain?(&1, depth + 1))
  end

  defp plain?(value, depth) when is_map(value) and not is_struct(value) do
    map_size(value) <= @max_items and
      Enum.all?(value, fn {key, item} ->
        (key in [:event_id, :kind] or is_binary(key)) and plain?(item, depth + 1)
      end)
  end

  defp plain?(_value, _depth), do: false
end
