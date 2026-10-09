defmodule LoopexComposition.Delegation.RunLedger do
  @moduledoc """
  ## Concept

  Fold one parent run's helper ledger: its allowance, the operation that may
  hold the parent's helper slot, stop records, known child creation and
  conservative recovery charges, without creating a child or exposing helpers.

  ## Technical depth

  ParentBinding revalidates captured parent bytes and the bound prefix;
  RunMutation owns closed transactions and original JobRequest projections;
  ChildCreation owns the selected retained child object. State and results are
  prospective stored projections. They authenticate no historical or source
  producer, grant, object sync, cleanup or accounting producer. The serial
  physical owner must establish those joins before effects or an
  acknowledgement.

  `operation` is the run's reserved operation; `recovered` holds ADR 0046's
  already-stopped no-child operations, each charged one count slot and no
  tokens. Every retained operation occupies the parent's helper slot until its
  release (settled, cleanup conclusive, every attempt receipt retained). ADR
  0056 keeps three transitions closed until their owners exist:
  `child_prompted` (the Core owning prompt-digest join), a real child's
  `settle` (the whole-child-run accounting producer) and `bind_receipt` (the
  Core receipt fact validator). They refuse with named reasons rather than
  accepting host assertions, so no operation is released yet.
  """

  alias LoopexComposition.Delegation.{
    ChildCreation,
    GenesisCodec,
    LedgerCodec,
    ParentBinding,
    RunMutation
  }

  alias LoopexProtocol.Canonical

  @cap 16_777_216
  @frame 65_614
  @logical ~w(operation_identity role task_digest child_creation_sha256 create_command_id prompt_command_id absolute_cutoff_ms reserved_tokens)

  @doc false
  def new(identifiers, capture, binding_transactions, history) do
    with {:ok, parent} <- parent(capture),
         {:ok, binding} <- ParentBinding.replay(parent, binding_transactions, history),
         true <- binding.phase == :bound,
         [runtime, session, _run] <- identifiers,
         true <- runtime == parent.runtime and session == binding.parent,
         {:ok, header} <- LedgerCodec.encode_header(:run, identifiers) do
      {:ok,
       %{
         identifiers: identifiers,
         capture: parent,
         binding_key: parent.key,
         header: header,
         version: 0,
         bytes: byte_size(header),
         credit: 0,
         phase: :empty,
         count: 0,
         reserved_tokens: 0,
         charged_tokens: 0,
         operation: nil,
         recovered: %{},
         stop: nil,
         transactions: []
       }}
    else
      _ -> {:error, :invalid_run_capture}
    end
  end

  @doc false
  def initialize_mutation(state) do
    %{
      "kind" => "initialize",
      "binding_key" => state.binding_key,
      "catalog_sha256" => state.capture.creation["catalog_sha256"],
      "declaration_sha256" => state.capture.creation["declaration_sha256"],
      "limits" => state.capture.declaration
    }
  end

  @doc false
  def admit_bytes(state, bytes, inputs \\ %{}) do
    with {:ok, tx} <- RunMutation.decode(state.identifiers, bytes),
         do: admit(state, tx, inputs)
  end

  @doc false
  def admit(state, tx, inputs \\ %{}) do
    with {:ok, ^tx} <- RunMutation.validate(state.identifiers, tx),
         {:ok, bytes} <- LedgerCodec.encode_json(tx, :frame),
         {:ok, frame} <- LedgerCodec.encode_frame(bytes) do
      # Concept: an exact repeat retains its original result at a newer head.
      # Technical depth: validate bytes, then consult the original transaction
      # index before expected-version or transition checks; never append twice.
      case Enum.find(state.transactions, fn {old, _} -> old["tx_id"] == tx["tx_id"] end) do
        {^tx, result} -> {:ok, state, result}
        {_changed, _} -> {:error, :run_transaction_conflict}
        nil -> advance(state, tx, byte_size(frame), inputs)
      end
    else
      _ -> {:error, :invalid_run_transaction}
    end
  end

  @doc """
  ## Concept

  Whether this run holds its parent's single helper slot.

  ## Technical depth

  Any retained operation occupies the slot until release, and no transition
  can release one yet. The parent's slot is occupied when any of its run
  states answers true, including runs other than the current one.
  """
  @spec occupied?(map()) :: boolean()
  def occupied?(state), do: state.operation != nil or state.recovered != %{}

  @doc false
  def first_stop(%{stop: nil}), do: :absent
  def first_stop(%{stop: {tx, result}}), do: {:ok, tx, result}

  @doc false
  def replay(identifiers, capture, binding_transactions, history, entries)
      when is_list(entries) do
    with {:ok, state} <- new(identifiers, capture, binding_transactions, history) do
      Enum.reduce_while(entries, {:ok, state}, fn entry, {:ok, current} ->
        case entry do
          {tx, inputs}
          when is_map(tx) and not is_struct(tx) and is_map(inputs) and not is_struct(inputs) ->
            if Enum.any?(current.transactions, fn {old, _} -> old["tx_id"] == tx["tx_id"] end) do
              {:halt, {:error, :duplicate_appended_transaction}}
            else
              case admit(current, tx, inputs) do
                {:ok, next, _result} -> {:cont, {:ok, next}}
                refusal -> {:halt, refusal}
              end
            end

          _ ->
            {:halt, {:error, :invalid_run_prefix}}
        end
      end)
    end
  end

  def replay(_, _, _, _, _), do: {:error, :invalid_run_prefix}

  defp parent(%{
         runtime: runtime,
         command: command,
         object_bytes: [catalog, declaration, creation]
       }),
       do: ParentBinding.capture(runtime, command, catalog, declaration, creation)

  defp parent(_), do: :error

  defp advance(state, tx, size, inputs) do
    if tx["expected_version"] == state.version do
      transition(state, tx, size, inputs)
    else
      {:error, :stale_run_version}
    end
  end

  defp transition(
         %{phase: :empty} = state,
         %{"mutation" => %{"kind" => "initialize"}} = tx,
         size,
         _
       ) do
    if tx["mutation"] == initialize_mutation(state),
      do: install(state, tx, size, %{state | phase: :initialized}),
      else: {:error, :run_binding_mismatch}
  end

  defp transition(state, %{"mutation" => %{"kind" => "reserve"} = mutation} = tx, size, inputs)
       when state.phase != :empty do
    identity = mutation["operation_identity"]

    cond do
      Map.has_key?(state.recovered, identity) ->
        {:error, :invalid_run_transition}

      state.recovered != %{} or
          (state.operation != nil and state.operation.logical["operation_identity"] != identity) ->
        {:error, :helper_slot_occupied}

      state.phase == :stopped ->
        {:error, :invalid_run_transition}

      true ->
        reserve(state, tx, size, inputs)
    end
  end

  defp transition(state, %{"mutation" => %{"kind" => "recover_uncreated"}} = tx, size, inputs)
       when state.phase != :empty do
    recover(state, tx, size, inputs)
  end

  defp transition(
         %{operation: %{child: nil}} = state,
         %{"mutation" => %{"kind" => "child_created"}} = tx,
         size,
         _inputs
       ) do
    created(state, tx, size)
  end

  defp transition(state, %{"mutation" => %{"kind" => "settle"}} = tx, size, inputs)
       when state.phase != :empty do
    settle(state, tx, size, inputs)
  end

  # Concept: these accepted transitions stay closed until their owners exist.
  # Technical depth: ADR 0056 forbids a host substitute for the Core prompt
  # digest and receipt validators, so no caller-supplied claim admits them.
  defp transition(_state, %{"mutation" => %{"kind" => "child_prompted"}}, _size, _inputs),
    do: {:error, :helper_prompt_owner_unavailable}

  defp transition(_state, %{"mutation" => %{"kind" => "bind_receipt"}}, _size, _inputs),
    do: {:error, :helper_receipt_validator_unavailable}

  defp transition(
         %{phase: :reserved} = state,
         %{"mutation" => %{"kind" => "stop"}} = tx,
         size,
         inputs
       ) do
    mutation = tx["mutation"]

    with %{original_job: original} <- inputs,
         :ok <- RunMutation.match_job(state.identifiers, mutation, original),
         true <- mutation["operation_identity"] == state.operation.logical["operation_identity"],
         {:ok, attempt} <- Map.fetch(state.operation.attempts, mutation["job"]["job_id"]),
         true <- attempt.job == mutation["job"] do
      # Concept: stopping excludes new work but retains every other obligation.
      # Technical depth: consume only S; create/prompt/settle and all original
      # attempts' receipt slots remain until a later conclusive owning release.
      next = %{
        state
        | phase: :stopped,
          credit: state.credit - @frame,
          operation: %{state.operation | stop: tx}
      }

      install(state, tx, size, next)
    else
      _ -> {:error, :original_stop_mismatch}
    end
  end

  defp transition(_, _, _, _), do: {:error, :invalid_run_transition}

  defp reserve(state, tx, size, inputs) do
    mutation = tx["mutation"]

    with %{original_job: original, child_creation: bytes} <- inputs,
         :ok <- RunMutation.match_job(state.identifiers, mutation, original) do
      case state.operation do
        nil -> first_reserve(state, tx, size, bytes, original)
        operation -> later_reserve(state, tx, size, bytes, operation, original)
      end
    else
      _ -> {:error, :original_job_mismatch}
    end
  end

  defp first_reserve(state, tx, size, bytes, original) do
    mutation = tx["mutation"]
    limits = state.capture.declaration
    available = max(0, limits["token_budget"] - state.charged_tokens - state.reserved_tokens)
    reserved = min(limits["child_bounds"]["token_budget"], available)
    credit = 5 * @frame

    # Concept: a stored child cutoff cannot outlive its original parent job.
    # Technical depth: match_job already validates this captured effective wall
    # deadline. Compare that original value; replay never reconstructs its clock.
    cond do
      mutation["absolute_cutoff_ms"] > original.effective_job_deadline ->
        {:error, :parent_cutoff_exceeded}

      state.count >= limits["max_children"] ->
        {:error, :delegation_count_exhausted}

      reserved == 0 ->
        {:error, :delegation_tokens_exhausted}

      mutation["reserved_tokens"] != reserved or mutation["closing_credit_bytes"] != credit ->
        {:error, :reservation_mismatch}

      true ->
        with {:ok, child} <- ChildCreation.validate(bytes, state.capture, reserved),
             true <- child_matches?(child, mutation, state.identifiers) do
          operation = %{
            logical: Map.take(mutation, @logical),
            child_creation: bytes,
            attempts: %{mutation["job"]["job_id"] => attempt(mutation)},
            child: nil,
            stop: nil
          }

          next = %{
            state
            | phase: :reserved,
              count: state.count + 1,
              reserved_tokens: state.reserved_tokens + reserved,
              credit: state.credit + credit,
              operation: operation
          }

          install(state, tx, size, next)
        else
          _ -> {:error, :child_creation_mismatch}
        end
    end
  end

  defp later_reserve(state, tx, size, bytes, operation, original) do
    mutation = tx["mutation"]
    credit = state.credit + @frame

    cond do
      mutation["absolute_cutoff_ms"] > original.effective_job_deadline ->
        {:error, :parent_cutoff_exceeded}

      Map.take(mutation, @logical) != operation.logical ->
        {:error, :operation_binding_conflict}

      bytes != operation.child_creation ->
        {:error, :child_creation_mismatch}

      mutation["closing_credit_bytes"] != credit ->
        {:error, :reservation_mismatch}

      true ->
        next_operation = %{
          operation
          | attempts: Map.put(operation.attempts, mutation["job"]["job_id"], attempt(mutation))
        }

        install(state, tx, size, %{state | credit: credit, operation: next_operation})
    end
  end

  # Concept: a missing reservation is charged one count slot, never zero.
  # Technical depth: the owner proves complete coverage, the predecessor's
  # absence and conclusive original-create absence before this append. The
  # operation is born stopped and holds settlement plus one receipt credit. An
  # excess beyond the retained count or byte cap refuses rather than clamping.
  defp recover(state, tx, size, inputs) do
    mutation = tx["mutation"]
    identity = mutation["operation_identity"]
    credit = 2 * @frame

    with %{original_job: original} <- inputs,
         {:ok, job} <- RunMutation.match_source(state.identifiers, mutation, original) do
      cond do
        state.operation != nil and state.operation.logical["operation_identity"] == identity ->
          {:error, :invalid_run_transition}

        mutation["closing_credit_bytes"] != credit ->
          {:error, :reservation_mismatch}

        state.count >= state.capture.declaration["max_children"] ->
          {:error, :delegation_count_exhausted}

        true ->
          operation = %{
            logical:
              Map.take(mutation, ~w(operation_identity create_command_id prompt_command_id)),
            source_intent: mutation["source_intent"],
            attempts: %{job["job_id"] => %{job: job, source_intent: mutation["source_intent"]}},
            settled: nil
          }

          next = %{
            state
            | count: state.count + 1,
              credit: state.credit + credit,
              recovered: Map.put(state.recovered, identity, operation)
          }

          install(state, tx, size, next)
      end
    else
      _ -> {:error, :original_source_mismatch}
    end
  end

  # Concept: record the known creation of the reserved operation's child.
  # Technical depth: both digests are Core Canonical digests of the retained
  # child genesis. A create sent before a stop may still be recorded after it;
  # recording spends only its own create credit and authorizes no prompt.
  defp created(state, tx, size) do
    mutation = tx["mutation"]
    operation = state.operation

    with true <- mutation["operation_identity"] == operation.logical["operation_identity"],
         true <- mutation["child_creation_sha256"] == operation.logical["child_creation_sha256"],
         {:ok, object} <- LedgerCodec.decode_json(operation.child_creation, :object),
         {:ok, genesis} <- GenesisCodec.decode(object["genesis"]),
         true <-
           mutation["configuration_digest"] == Canonical.digest(genesis["initial_configuration"]),
         true <- mutation["tool_selection_sha256"] == Canonical.digest(genesis["tool_selection"]) do
      next = %{
        state
        | credit: state.credit - @frame,
          operation: %{operation | child: mutation["child_session_id"]}
      }

      install(state, tx, size, next)
    else
      _ -> {:error, :child_created_mismatch}
    end
  end

  # Concept: only a conclusive recovered no-child settlement is admitted today.
  # Technical depth: its terminal binds the source intent's journal version and
  # the Core digest of that validated intent payload, which the owner supplies
  # from the read-only intent query. Usage, charge and refund are zero and the
  # count charge stands. A real child needs the pending accounting producer.
  defp settle(state, tx, size, inputs) do
    mutation = tx["mutation"]
    identity = mutation["operation_identity"]
    terminal = mutation["terminal"]

    case state.recovered do
      %{^identity => %{settled: nil} = operation} ->
        with %{source_intent_sha256: digest} <- inputs,
             "uncreated" <- terminal["state"],
             true <- terminal["journal_version"] == operation.source_intent["journal_version"],
             true <- terminal["terminal_record_sha256"] == digest do
          next = %{
            state
            | credit: state.credit - @frame,
              recovered: Map.put(state.recovered, identity, %{operation | settled: tx})
          }

          install(state, tx, size, next)
        else
          _ -> {:error, :settlement_mismatch}
        end

      %{^identity => _settled} ->
        {:error, :invalid_run_transition}

      _ ->
        if state.operation != nil and state.operation.logical["operation_identity"] == identity,
          do: {:error, :helper_accounting_unavailable},
          else: {:error, :invalid_run_transition}
    end
  end

  defp child_matches?(child, mutation, [runtime, _parent, _run]) do
    child.runtime_id == runtime and child.operation_identity == mutation["operation_identity"] and
      child.role == mutation["role"] and
      child.creation_sha256 == mutation["child_creation_sha256"] and
      Base.encode64(child.command_id) == mutation["create_command_id"] and
      Base.encode64(child.prompt_command_id) == mutation["prompt_command_id"] and
      child.reserved_tokens == mutation["reserved_tokens"]
  end

  defp attempt(mutation), do: %{job: mutation["job"], source_intent: mutation["source_intent"]}

  defp install(state, tx, size, next) do
    if state.bytes + size + next.credit <= @cap do
      {:ok, result} = RunMutation.result(state.identifiers, tx)

      next = %{
        next
        | version: state.version + 1,
          bytes: state.bytes + size,
          transactions: state.transactions ++ [{tx, result}]
      }

      next = if tx["mutation"]["kind"] == "stop", do: %{next | stop: {tx, result}}, else: next
      {:ok, next, result}
    else
      {:error, :run_byte_limit}
    end
  end
end
