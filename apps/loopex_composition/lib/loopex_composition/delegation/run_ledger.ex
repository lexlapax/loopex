defmodule LoopexComposition.Delegation.RunLedger do
  @moduledoc """
  ## Concept

  Fold the accepted prelaunch helper initialize, reserve and first-stop prefix
  without creating a child or exposing helpers.

  ## Technical depth

  ParentBinding revalidates captured parent bytes and the bound prefix;
  RunMutation owns closed transactions and original JobRequest projections;
  ChildCreation owns the selected retained child object. State and results are
  prospective stored projections. They authenticate no historical or source
  producer, cross-run slot, grant, object sync, cleanup or accounting producer.
  The serial physical owner must establish those joins before effects or an
  acknowledgement. This internal fold admits no later lifecycle mutations.
  """

  alias LoopexComposition.Delegation.{ChildCreation, LedgerCodec, ParentBinding, RunMutation}

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

  @doc false
  def first_stop(%{stop: nil}), do: :absent
  def first_stop(%{stop: {tx, result}}), do: {:ok, tx, result}

  @doc false
  def replay(identifiers, capture, binding_transactions, history, entries) when is_list(entries) do
    with {:ok, state} <- new(identifiers, capture, binding_transactions, history) do
      Enum.reduce_while(entries, {:ok, state}, fn entry, {:ok, current} ->
        case entry do
          {tx, inputs} when is_map(tx) and not is_struct(tx) and is_map(inputs) and not is_struct(inputs) ->
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

  defp parent(%{runtime: runtime, command: command, object_bytes: [catalog, declaration, creation]}),
    do: ParentBinding.capture(runtime, command, catalog, declaration, creation)

  defp parent(_), do: :error

  defp advance(state, tx, size, inputs) do
    if tx["expected_version"] == state.version do
      transition(state, tx, size, inputs)
    else
      {:error, :stale_run_version}
    end
  end

  defp transition(%{phase: :empty} = state, %{"mutation" => %{"kind" => "initialize"}} = tx, size, _) do
    if tx["mutation"] == initialize_mutation(state),
      do: install(state, tx, size, %{state | phase: :initialized}),
      else: {:error, :run_binding_mismatch}
  end

  defp transition(state, %{"mutation" => %{"kind" => "reserve"}} = tx, size, inputs)
       when state.phase in [:initialized, :reserved] do
    reserve(state, tx, size, inputs)
  end

  defp transition(%{phase: :reserved} = state, %{"mutation" => %{"kind" => "stop"}} = tx, size, inputs) do
    mutation = tx["mutation"]

    with %{original_job: original} <- inputs,
         :ok <- RunMutation.match_job(state.identifiers, mutation, original),
         true <- mutation["operation_identity"] == state.operation.logical["operation_identity"],
         {:ok, attempt} <- Map.fetch(state.operation.attempts, mutation["job"]["job_id"]),
         true <- attempt.job == mutation["job"] do
      # Concept: stopping excludes new work but retains every other obligation.
      # Technical depth: consume only S; create/prompt/settle and all original
      # attempts' receipt slots remain until a later conclusive owning release.
      next = %{state | phase: :stopped, credit: state.credit - @frame}
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
            attempts: %{mutation["job"]["job_id"] => attempt(mutation)}
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

  defp child_matches?(child, mutation, [runtime, _parent, _run]) do
    child.runtime_id == runtime and child.operation_identity == mutation["operation_identity"] and
      child.role == mutation["role"] and child.creation_sha256 == mutation["child_creation_sha256"] and
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
