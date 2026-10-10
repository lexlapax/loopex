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
  release: settled from conclusive evidence and every admitted attempt's
  receipt bound. ADR 0069 supplies the owning joins: `child_prompted` takes
  Core's admitted prompt digest, a real `settle` takes Core's run evidence and
  `bind_receipt` takes Core's executor-receipt validator. The owner passes
  those as inputs; the fold never accepts a host-computed substitute.
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
  @encoding "loopex.ledger.plain_etf.v1.base64"
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
         released: MapSet.new(),
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
      Map.has_key?(state.recovered, identity) or MapSet.member?(state.released, identity) ->
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

  defp transition(
         %{operation: %{child: child, child_run: nil}} = state,
         %{"mutation" => %{"kind" => "child_prompted"}} = tx,
         size,
         inputs
       )
       when is_binary(child) do
    prompted(state, tx, size, inputs)
  end

  defp transition(state, %{"mutation" => %{"kind" => "bind_receipt"}} = tx, size, inputs)
       when state.phase != :empty do
    receipt(state, tx, size, inputs)
  end

  defp transition(
         %{phase: :reserved} = state,
         %{"mutation" => %{"kind" => "stop"}} = tx,
         size,
         inputs
       ) do
    mutation = tx["mutation"]

    with {:ok, _original} <- joined_job(state.identifiers, mutation, inputs),
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

    with %{child_creation: bytes} <- inputs,
         {:ok, original} <- joined_job(state.identifiers, mutation, inputs) do
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
      exceeds_cutoff?(mutation, original) ->
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
            child_run: nil,
            stop: nil,
            settled: nil,
            receipts: MapSet.new()
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
      exceeds_cutoff?(mutation, original) ->
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

    with {:ok, job} <- joined_source(state.identifiers, mutation, inputs) do
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
            settled: nil,
            receipts: MapSet.new()
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

  # Concept: the original live prompt's admission is recorded once.
  # Technical depth: the owner supplies Core's own admitted command digest from
  # ADR 0069 run evidence for the child run; the host never computes it.
  defp prompted(state, tx, size, inputs) do
    mutation = tx["mutation"]
    operation = state.operation

    with %{prompt_digest: digest} <- inputs,
         true <- mutation["operation_identity"] == operation.logical["operation_identity"],
         true <- mutation["child_session_id"] == operation.child,
         true <- mutation["prompt_command_id"] == operation.logical["prompt_command_id"],
         true <- mutation["prompt_digest"] == digest do
      next = %{
        state
        | credit: state.credit - @frame,
          operation: %{operation | child_run: mutation["child_run_id"]}
      }

      install(state, tx, size, next)
    else
      _ -> {:error, :child_prompted_mismatch}
    end
  end

  # Concept: settle once from conclusive terminal, cleanup and Core accounting.
  # Technical depth: a real child settles only against ADR 0069 run evidence
  # for its exact run plus the captured history token; a prompted child's charge
  # is Q, or max(R, Q) when any usage is unresolved, never clamped. A created
  # but unprompted child settles a failed terminal at zero usage. A recovered
  # operation settles its uncreated terminal at zero. The reservation leaves and
  # the charge enters the allowance exactly once.
  defp settle(state, tx, size, inputs) do
    mutation = tx["mutation"]
    identity = mutation["operation_identity"]

    case operation(state, identity) do
      {:recovered, %{settled: nil} = operation} ->
        with %{source_intent_sha256: digest} <- inputs,
             %{"state" => "uncreated"} = terminal <- mutation["terminal"],
             true <- terminal["journal_version"] == operation.source_intent["journal_version"],
             true <- terminal["terminal_record_sha256"] == digest do
          settled(state, tx, size, :recovered, %{operation | settled: tx}, 0, 0)
        else
          _ -> {:error, :settlement_mismatch}
        end

      {:reserved, %{settled: nil, child: child} = operation} when is_binary(child) ->
        reserved = operation.logical["reserved_tokens"]

        case settlement(mutation, operation, inputs, reserved) do
          :ok ->
            settled(
              state,
              tx,
              size,
              :reserved,
              %{operation | settled: tx},
              reserved,
              mutation["charge_tokens"]
            )

          :error ->
            {:error, :settlement_mismatch}
        end

      _ ->
        {:error, :invalid_run_transition}
    end
  end

  defp settlement(mutation, operation, inputs, reserved) do
    terminal = mutation["terminal"]
    accounting = mutation["accounting"]

    joined =
      case {operation.child_run, inputs} do
        # ADR 0056: a missing acknowledgement alone cannot prove an unprompted
        # child, so the captured prefix must hold no admission of its prompt.
        {nil, %{through_version: through, prefix_token: token, admitted_prompts: admitted}} ->
          prompt = Base.decode64!(operation.logical["prompt_command_id"])

          terminal["state"] == "failed" and is_nil(terminal["child_run_id"]) and
            not MapSet.member?(admitted, prompt) and
            accounting["through_version"] == through and
            accounting["prefix_token"] == Base.encode64(token)

        {run, %{evidence: %{terminal: %{} = ended, usage: usage} = evidence, prefix_token: token}} ->
          terminal["child_run_id"] == run and terminal["state"] == ended.state and
            terminal["journal_version"] == ended.journal_version and
            terminal["terminal_record_sha256"] == ended.record_digest and
            accounting["reported_input_tokens"] == usage.reported_input and
            accounting["reported_output_tokens"] == usage.reported_output and
            accounting["estimated_tokens"] == usage.estimated and
            accounting["unresolved_usage"] == usage.unresolved and
            accounting["through_version"] == evidence.through_version and
            accounting["prefix_token"] == Base.encode64(token)

        _ ->
          false
      end

    usage =
      accounting["reported_input_tokens"] + accounting["reported_output_tokens"] +
        accounting["estimated_tokens"]

    charge = if accounting["unresolved_usage"], do: max(reserved, usage), else: usage

    if joined and terminal["child_session_id"] == operation.child and
         mutation["charge_tokens"] == charge and
         mutation["refund_tokens"] == max(0, reserved - charge),
       do: :ok,
       else: :error
  end

  defp settled(state, tx, size, kind, operation, reserved, charge) do
    state = %{
      state
      | credit: state.credit - @frame,
        reserved_tokens: state.reserved_tokens - reserved,
        charged_tokens: state.charged_tokens + charge
    }

    install(state, tx, size, release(put_operation(state, kind, operation), kind, operation))
  end

  # Concept: each admitted attempt binds at most one exact retained receipt.
  # Technical depth: the receipt object must name this runtime, operation and
  # stored job, and its envelope must pass Core's own executor-receipt validator
  # for the original JobRequest. Binding is admitted only after settlement.
  defp receipt(state, tx, size, inputs) do
    mutation = tx["mutation"]
    job_id = mutation["job"]["job_id"]

    with {kind, %{settled: settled} = operation} when not is_nil(settled) <-
           operation(state, mutation["operation_identity"]),
         %{job: job} <- Map.get(operation.attempts, job_id),
         true <- job == mutation["job"] and not MapSet.member?(operation.receipts, job_id),
         %{receipt: bytes} <- inputs,
         {:ok, original} <- joined_job(state.identifiers, mutation, inputs),
         true <- hash(bytes) == mutation["receipt_sha256"],
         {:ok, _receipt} <- receipt_object(bytes, state.identifiers, mutation, original) do
      operation = %{operation | receipts: MapSet.put(operation.receipts, job_id)}
      state = %{state | credit: state.credit - @frame}
      install(state, tx, size, release(put_operation(state, kind, operation), kind, operation))
    else
      _ -> {:error, :receipt_mismatch}
    end
  end

  # Concept: a frame joins its attempt by the original job or, on replay below a
  # validated coverage watermark, by its retained job-index entry.
  # Technical depth: live admission always validates the complete original
  # JobRequest. A replayed frame whose original intent lies below the watermark
  # of a coverage entry that validated this start is joined to the job index
  # entry's exact projection instead; that frame was fully validated when it was
  # first admitted and its bytes are checksummed. No new frame is ever admitted
  # this way, and the cutoff and Core receipt checks it skips were proved then.
  defp joined_job(_identifiers, mutation, %{indexed_job: projection}) do
    if mutation["job"] == projection, do: {:ok, :indexed}, else: :error
  end

  defp joined_job(identifiers, mutation, %{original_job: original}) do
    case RunMutation.match_job(identifiers, mutation, original) do
      :ok -> {:ok, original}
      _ -> :error
    end
  end

  defp joined_job(_identifiers, _mutation, _inputs), do: :error

  defp joined_source(_identifiers, mutation, %{indexed_job: job}) do
    source = mutation["source_intent"]
    operation = mutation["operation_identity"]

    if job["session_id"] == source["session_id"] and
         job["canonical_request_digest"] == source["canonical_request_digest"] and
         job["operation_id"] == operation["operation_id"] and
         job["run_id"] == operation["parent_run_id"],
       do: {:ok, job},
       else: :error
  end

  defp joined_source(identifiers, mutation, %{original_job: original}),
    do: RunMutation.match_source(identifiers, mutation, original)

  defp joined_source(_identifiers, _mutation, _inputs), do: :error

  defp exceeds_cutoff?(_mutation, :indexed), do: false

  defp exceeds_cutoff?(mutation, original),
    do: mutation["absolute_cutoff_ms"] > original.effective_job_deadline

  @doc false
  def receipt_object(bytes, [runtime | _], mutation, :indexed) do
    with {:ok, object} <- LedgerCodec.decode_json(bytes, :object),
         true <- closed?(object, ~w(version kind runtime_id operation_identity job receipt)),
         true <- object["version"] === 1 and object["kind"] == "receipt",
         true <- object["runtime_id"] == Base.encode64(runtime),
         true <- object["operation_identity"] == mutation["operation_identity"],
         true <- object["job"] == mutation["job"],
         {:ok, plain} <- plain_receipt(object["receipt"]) do
      {:ok, plain}
    else
      _ -> {:error, :invalid_receipt_object}
    end
  end

  def receipt_object(bytes, [runtime | _] = identifiers, mutation, original) do
    with {:ok, object} <- LedgerCodec.decode_json(bytes, :object),
         true <- closed?(object, ~w(version kind runtime_id operation_identity job receipt)),
         true <- object["version"] === 1 and object["kind"] == "receipt",
         true <- object["runtime_id"] == Base.encode64(runtime),
         true <- object["operation_identity"] == mutation["operation_identity"],
         true <- object["job"] == mutation["job"],
         :ok <-
           RunMutation.match_job(identifiers, Map.put(mutation, "kind", "bind_receipt"), original),
         {:ok, plain} <- plain_receipt(object["receipt"]) do
      Loopex.Runtime.SessionState.validate_executor_receipt(plain, original)
    else
      _ -> {:error, :invalid_receipt_object}
    end
  end

  defp plain_receipt(
         %{"encoding" => @encoding, "bytes" => encoded, "sha256" => digest} = envelope
       )
       when map_size(envelope) == 3 and is_binary(encoded) and byte_size(encoded) <= 87_384 do
    with {:ok, bytes} <- Base.decode64(encoded),
         true <- byte_size(bytes) <= 65_536 and Base.encode64(bytes) == encoded,
         true <- hash(bytes) == digest,
         <<131, tag, _::binary>> when tag != 80 <- bytes,
         {value, used} <- :erlang.binary_to_term(bytes, [:safe, :used]),
         true <- used == byte_size(bytes) and is_map(value) and not is_struct(value) do
      {:ok, value}
    else
      _ -> :error
    end
  rescue
    ArgumentError -> :error
  end

  defp plain_receipt(_), do: :error

  # Concept: release frees the parent's slot and unused closing credit.
  # Technical depth: only a settled operation whose every admitted attempt has
  # its receipt is released; its unspent create, prompt and stop slots return.
  defp release(state, kind, operation) do
    if operation.settled != nil and
         MapSet.size(operation.receipts) == map_size(operation.attempts) do
      identity = operation.logical["operation_identity"]

      unspent =
        if kind == :reserved,
          do:
            Enum.count([operation.child, operation.child_run, operation.stop], &is_nil/1) *
              @frame,
          else: 0

      state = %{
        state
        | credit: state.credit - unspent,
          released: MapSet.put(state.released, identity)
      }

      case kind do
        :reserved -> %{state | operation: nil, phase: :initialized, stop: nil}
        :recovered -> %{state | recovered: Map.delete(state.recovered, identity)}
      end
    else
      state
    end
  end

  defp operation(state, identity) do
    cond do
      Map.has_key?(state.recovered, identity) ->
        {:recovered, state.recovered[identity]}

      state.operation != nil and state.operation.logical["operation_identity"] == identity ->
        {:reserved, state.operation}

      true ->
        :none
    end
  end

  defp put_operation(state, :reserved, operation), do: %{state | operation: operation}

  defp put_operation(state, :recovered, operation),
    do: %{
      state
      | recovered: Map.put(state.recovered, operation.logical["operation_identity"], operation)
    }

  defp hash(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp closed?(value, keys),
    do: is_map(value) and not is_struct(value) and Enum.sort(Map.keys(value)) == Enum.sort(keys)

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
