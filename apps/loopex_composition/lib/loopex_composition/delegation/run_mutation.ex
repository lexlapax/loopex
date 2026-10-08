defmodule LoopexComposition.Delegation.RunMutation do
  @moduledoc """
  ## Concept

  Validate the closed private helper run transaction recipe without admitting
  a transition, creating a child or treating a digest as authority.

  ## Technical depth

  ADR 0056 owns these stored maps, scope joins and deterministic preimages.
  LedgerCodec owns canonical JSON and complete payload bounds. Executor owns
  original JobRequest validation; match_job/3 compares that validated original
  with the stored helper projection and, for reserve, its task digest.
  This internal boundary does not establish history, grants, object durability,
  accounting provenance, reservation arithmetic, cleanup or writer custody.
  A result is a prospective byte projection, never a commit acknowledgement.
  """

  alias Loopex.Executor
  alias LoopexComposition.Delegation.{LedgerCodec, Tool}
  alias LoopexProtocol.Canonical

  @uint64 18_446_744_073_709_551_615
  @cutoff 9_007_199_254_740_991
  @zero String.duplicate("0", 64)
  @role ~r/\A[a-z][a-z0-9_-]{0,63}\z/
  @operation ~w(parent_session_id parent_run_id operation_id)
  @job ~w(job_id route operation_id attempt session_id run_id canonical_request_digest origin_session_epoch origin_executor_epoch executor_identity fencing_token cleanup_grace_ms)
  @terminal ~w(state child_session_id child_run_id journal_version terminal_record_sha256 cleanup)
  @accounting ~w(reported_input_tokens reported_output_tokens estimated_tokens unresolved_usage charged_tokens through_version prefix_token evidence_sha256)

  @doc false
  def transaction(identifiers, expected_version, mutation) do
    # Concept: native inputs spend the complete transaction budget before digest work.
    # Technical depth: fixed-width placeholder hashes have the final encoded size.
    with {:ok, key} <- LedgerCodec.header_key(:run, identifiers),
         true <- nonnegative?(expected_version),
         placeholder = %{
           "version" => 1,
           "tx_id" => @zero,
           "expected_version" => expected_version,
           "mutation_digest" => @zero,
           "mutation" => mutation
         },
         {:ok, _} <- LedgerCodec.encode_json(placeholder, :frame),
         true <- mutation?(mutation, identifiers),
         {:ok, id} <- domain("loopex:helper-tx:v1", [key, mutation["kind"], target(mutation)]),
         true <- mutation["kind"] != "stop" or mutation["stop_tx_id"] == id,
         {:ok, digest} <-
           domain("loopex:helper-mutation:v1", [key, expected_version, mutation]) do
      {:ok, %{placeholder | "tx_id" => id, "mutation_digest" => digest}}
    else
      _ -> error()
    end
  end

  @doc false
  def validate(identifiers, tx) do
    with true <- closed?(tx, ~w(version tx_id expected_version mutation_digest mutation)),
         true <- tx["version"] === 1 and hash?(tx["tx_id"]) and hash?(tx["mutation_digest"]),
         {:ok, expected} <- transaction(identifiers, tx["expected_version"], tx["mutation"]),
         true <- tx == expected do
      {:ok, tx}
    else
      _ -> error()
    end
  end

  @doc false
  def decode(identifiers, bytes) do
    with {:ok, tx} <- LedgerCodec.decode_json(bytes, :frame),
         {:ok, ^tx} <- validate(identifiers, tx) do
      {:ok, tx}
    else
      _ -> error()
    end
  end

  @doc false
  def result(identifiers, tx) do
    with {:ok, ^tx} <- validate(identifiers, tx) do
      {:ok,
       %{
         "version" => 1,
         "tx_id" => tx["tx_id"],
         "ledger_version" => tx["expected_version"] + 1,
         "mutation_digest" => tx["mutation_digest"]
       }}
    end
  end

  @doc false
  def match_job(identifiers, mutation, original) do
    with {:ok, _} <- transaction(identifiers, 0, mutation),
         true <- mutation["kind"] in ~w(reserve stop bind_receipt),
         :ok <- Executor.validate_job(original),
         definition = Tool.definition(),
         true <-
           original.tool_id == definition["tool_id"] and
             original.tool_version == definition["tool_version"] and
             original.effect_class == definition["effect_class"] and
             original.idempotency_class == definition["idempotency_class"],
         :ok <- Tool.validate_arguments(original.validated_arguments),
         true <- mutation["job"] == project_job(original),
         true <-
           mutation["kind"] != "reserve" or
             (mutation["role"] == original.validated_arguments["role"] and
                mutation["task_digest"] == Canonical.digest(original.validated_arguments)) do
      :ok
    else
      _ -> {:error, :original_job_mismatch}
    end
  end

  defp mutation?(%{"kind" => "initialize"} = value, _ids) do
    closed?(value, ~w(kind binding_key catalog_sha256 declaration_sha256 limits)) and
      hashes?(value, ~w(binding_key catalog_sha256 declaration_sha256)) and
      declaration?(value["limits"])
  end

  defp mutation?(%{"kind" => "reserve"} = value, ids) do
    closed?(
      value,
      ~w(kind operation_identity source_intent job role task_digest child_creation_sha256 create_command_id prompt_command_id absolute_cutoff_ms reserved_tokens closing_credit_bytes)
    ) and operation?(value["operation_identity"], ids) and
      source?(value["source_intent"], ids) and
      job?(value["job"], value["operation_identity"], ids) and
      value["job"]["canonical_request_digest"] ==
        value["source_intent"]["canonical_request_digest"] and
      role?(value["role"]) and hashes?(value, ~w(task_digest child_creation_sha256)) and
      commands?(value, ids) and positive?(value["absolute_cutoff_ms"]) and
      value["absolute_cutoff_ms"] <= @cutoff and positive?(value["reserved_tokens"]) and
      nonnegative?(value["closing_credit_bytes"])
  end

  defp mutation?(%{"kind" => "recover_uncreated"} = value, ids) do
    closed?(
      value,
      ~w(kind operation_identity source_intent create_command_id prompt_command_id reservation_state reason child_session_id child_run_id reported_child_usage count_charge closing_credit_bytes)
    ) and operation?(value["operation_identity"], ids) and
      source?(value["source_intent"], ids) and commands?(value, ids) and
      value["reservation_state"] == "unknown" and value["reason"] == "adapter_recovery" and
      is_nil(value["child_session_id"]) and is_nil(value["child_run_id"]) and
      value["reported_child_usage"] === 0 and value["count_charge"] === 1 and
      nonnegative?(value["closing_credit_bytes"])
  end

  defp mutation?(%{"kind" => "child_created"} = value, ids) do
    closed?(
      value,
      ~w(kind operation_identity child_session_id child_creation_sha256 configuration_digest tool_selection_sha256 policy_defer_mode)
    ) and operation?(value["operation_identity"], ids) and
      binary?(value["child_session_id"], 256) and
      hashes?(value, ~w(child_creation_sha256 configuration_digest tool_selection_sha256)) and
      value["policy_defer_mode"] == "refuse"
  end

  defp mutation?(%{"kind" => "child_prompted"} = value, ids) do
    closed?(
      value,
      ~w(kind operation_identity child_session_id child_run_id prompt_command_id prompt_digest)
    ) and operation?(value["operation_identity"], ids) and
      binary?(value["child_session_id"], 256) and binary?(value["child_run_id"], 8_192) and
      command?(value, ids, "prompt") and hash?(value["prompt_digest"])
  end

  defp mutation?(%{"kind" => "stop"} = value, ids) do
    closed?(value, ~w(kind operation_identity job stop_tx_id reason)) and
      operation?(value["operation_identity"], ids) and
      job?(value["job"], value["operation_identity"], ids) and hash?(value["stop_tx_id"]) and
      value["reason"] in ~w(cancel cutoff adapter_recovery)
  end

  defp mutation?(%{"kind" => "settle"} = value, ids) do
    closed?(value, ~w(kind operation_identity terminal accounting charge_tokens refund_tokens)) and
      operation?(value["operation_identity"], ids) and terminal?(value["terminal"]) and
      accounting?(value["accounting"], value["terminal"], value["operation_identity"]) and
      nonnegative?(value["charge_tokens"]) and nonnegative?(value["refund_tokens"]) and
      value["charge_tokens"] == value["accounting"]["charged_tokens"] and
      settlement_projection?(value)
  end

  defp mutation?(%{"kind" => "bind_receipt"} = value, ids) do
    closed?(value, ~w(kind operation_identity job receipt_sha256)) and
      operation?(value["operation_identity"], ids) and
      job?(value["job"], value["operation_identity"], ids) and hash?(value["receipt_sha256"])
  end

  defp mutation?(_, _ids), do: false

  defp declaration?(value) do
    closed?(
      value,
      ~w(version kind enabled roles max_children token_budget child_bounds max_tokens role_budgets)
    ) and value["version"] === 1 and value["kind"] == "declaration" and
      value["enabled"] === true and roles?(value["roles"]) and
      positive?(value["max_children"]) and value["max_children"] <= 128 and
      positive?(value["token_budget"]) and positive?(value["max_tokens"]) and
      child_bounds?(value["child_bounds"]) and
      budgets?(value["role_budgets"], value["roles"])
  end

  defp child_bounds?(value) do
    closed?(value, ~w(max_turns deadline_ms token_budget)) and
      Enum.all?(Map.values(value), &positive?/1) and value["deadline_ms"] <= 600_000
  end

  defp roles?(values) do
    is_list(values) and length(values) in 1..16 and
      Enum.all?(values, &role?/1) and values == Enum.uniq(values)
  end

  defp budgets?(values, roles) do
    is_list(values) and length(values) == length(roles) and
      Enum.all?(Enum.zip(roles, values), fn {role, budget} ->
        closed?(budget, ~w(role context_token_budget system_class_tokens)) and
          budget["role"] == role and uint64_positive?(budget["context_token_budget"]) and
          uint64_positive?(budget["system_class_tokens"]) and
          budget["system_class_tokens"] <= budget["context_token_budget"]
      end)
  end

  defp operation?(value, [_runtime, session, run]) do
    closed?(value, @operation) and value["parent_session_id"] == Base.encode64(session) and
      value["parent_run_id"] == Base.encode64(run) and binary?(value["operation_id"], 8_192)
  end

  defp source?(value, [_runtime, session, _run]) do
    closed?(value, ~w(session_id journal_version canonical_request_digest)) and
      value["session_id"] == Base.encode64(session) and positive?(value["journal_version"]) and
      hash?(value["canonical_request_digest"])
  end

  defp job?(value, operation, [_runtime, session, run]) do
    closed?(value, @job) and value["route"] == "helper" and
      value["session_id"] == Base.encode64(session) and value["run_id"] == Base.encode64(run) and
      value["operation_id"] == operation["operation_id"] and
      binary?(value["job_id"], 8_192) and binary?(value["executor_identity"], 8_192) and
      positive?(value["attempt"]) and hash?(value["canonical_request_digest"]) and
      Enum.all?(~w(origin_session_epoch origin_executor_epoch fencing_token), fn key ->
        nonnegative?(value[key])
      end) and match?({:ok, _}, Executor.cancellation_bounds(value["cleanup_grace_ms"]))
  end

  defp commands?(value, ids), do: command?(value, ids, "create") and command?(value, ids, "prompt")

  defp command?(value, [runtime, _session, _run], kind) do
    case domain("loopex:helper-" <> kind <> ":v1", [Base.encode64(runtime), value["operation_identity"]]) do
      {:ok, id} -> value[kind <> "_command_id"] == Base.encode64(id)
      _ -> false
    end
  end

  defp terminal?(value) do
    closed?(value, @terminal) and positive?(value["journal_version"]) and
      hash?(value["terminal_record_sha256"]) and value["cleanup"] == "confirmed" and
      case value["state"] do
        "uncreated" -> is_nil(value["child_session_id"]) and is_nil(value["child_run_id"])
        state when state in ~w(completed failed cancelled bound_reached) ->
          binary?(value["child_session_id"], 256) and
            (binary?(value["child_run_id"], 8_192) or
               (state == "failed" and is_nil(value["child_run_id"])))
        _ -> false
      end
  end

  defp accounting?(value, terminal, operation) do
    closed?(value, @accounting) and
      Enum.all?(~w(reported_input_tokens reported_output_tokens estimated_tokens charged_tokens through_version), fn key ->
        nonnegative?(value[key])
      end) and is_boolean(value["unresolved_usage"]) and
      (value["estimated_tokens"] == 0 or value["unresolved_usage"]) and
      hash?(value["evidence_sha256"]) and
      accounting_endpoint?(value, terminal) and
      case domain("loopex:helper-accounting-evidence:v1", [operation, terminal, Map.delete(value, "evidence_sha256")]) do
        {:ok, hash} -> hash == value["evidence_sha256"]
        _ -> false
      end
  end

  defp accounting_endpoint?(value, %{"state" => "uncreated"}) do
    Enum.all?(~w(reported_input_tokens reported_output_tokens estimated_tokens charged_tokens through_version), &(value[&1] == 0)) and
      value["unresolved_usage"] === false and is_nil(value["prefix_token"])
  end

  defp accounting_endpoint?(value, _terminal) do
    positive?(value["through_version"]) and binary?(value["prefix_token"], 32, 32)
  end

  # Concept: a stored charge must be locally consistent without claiming a refund proof.
  # Technical depth: the reservation R and owning history remain outside this
  # validator, so exact max(R, Q) and refund admission belong to the reducer.
  defp settlement_projection?(value) do
    accounting = value["accounting"]
    usage = accounting["reported_input_tokens"] + accounting["reported_output_tokens"] + accounting["estimated_tokens"]

    cond do
      value["terminal"]["state"] == "uncreated" ->
        value["charge_tokens"] == 0 and value["refund_tokens"] == 0
      is_nil(value["terminal"]["child_run_id"]) ->
        usage == 0 and accounting["unresolved_usage"] === false and value["charge_tokens"] == 0
      accounting["unresolved_usage"] ->
        value["charge_tokens"] >= usage and value["refund_tokens"] == 0
      true ->
        value["charge_tokens"] == usage
    end
  end

  # Concept: original job validation remains at the executor boundary.
  # Technical depth: this projection is compared only after validate_job/1;
  # neither its stored hash nor these fields validate grants or source history.
  defp project_job(job) do
    %{
      "job_id" => Base.encode64(job.job_id),
      "route" => "helper",
      "operation_id" => Base.encode64(job.operation_id),
      "attempt" => job.attempt,
      "session_id" => Base.encode64(job.session_id),
      "run_id" => Base.encode64(job.run_id),
      "canonical_request_digest" => job.canonical_request_digest,
      "origin_session_epoch" => job.origin_session_epoch,
      "origin_executor_epoch" => job.origin_executor_epoch,
      "executor_identity" => Base.encode64(job.executor_identity),
      "fencing_token" => job.fencing_token,
      "cleanup_grace_ms" => job.cleanup_grace_ms
    }
  end

  defp target(%{"kind" => "initialize"}), do: []
  defp target(%{"kind" => kind, "operation_identity" => operation, "job" => job})
       when kind in ~w(reserve bind_receipt), do: [operation, job["job_id"]]
  defp target(%{"operation_identity" => operation}), do: operation

  defp domain(label, value) do
    with {:ok, wrapped} <- LedgerCodec.encode_json(%{"v" => value}, :object) do
      bytes = binary_part(wrapped, 5, byte_size(wrapped) - 6)
      {:ok, Canonical.digest_bytes(label <> <<0>> <> bytes)}
    end
  end

  defp binary?(value, maximum, minimum \\ 1)
  defp binary?(value, maximum, minimum) when is_binary(value) do
    byte_size(value) <= div(maximum + 2, 3) * 4 and
      case Base.decode64(value) do
        {:ok, bytes} -> byte_size(bytes) in minimum..maximum and Base.encode64(bytes) == value
        _ -> false
      end
  end
  defp binary?(_, _, _), do: false

  defp hashes?(value, keys), do: Enum.all?(keys, &hash?(value[&1]))
  defp hash?(value) when is_binary(value) and byte_size(value) == 64,
    do: Enum.all?(:binary.bin_to_list(value), &(&1 in ?0..?9 or &1 in ?a..?f))
  defp hash?(_), do: false
  defp nonnegative?(value), do: is_integer(value) and value >= 0
  defp positive?(value), do: is_integer(value) and value > 0
  defp uint64_positive?(value), do: positive?(value) and value <= @uint64
  defp role?(value), do: is_binary(value) and Regex.match?(@role, value)
  defp closed?(value, keys),
    do: is_map(value) and not is_struct(value) and Enum.sort(Map.keys(value)) == Enum.sort(keys)
  defp error, do: {:error, :invalid_run_transaction}
end
