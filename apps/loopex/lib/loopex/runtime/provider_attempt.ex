defmodule Loopex.Runtime.ProviderAttempt do
  @moduledoc """
  ## Concept

  The exact durable vocabulary of one provider attempt: which request may be
  sent, what the transport is known to have done, and what the answer cost.

  A staged request says which bytes one model operation intended. It cannot say
  whether a transport was ever entered, so byte availability is never retry
  permission. This module owns the three records that carry that distinction —
  the attempt open, the attempt settlement, and an admitted termination — and
  the projection that turns an adapter's reply into the bounded values those
  records retain.

  Fixed by
  [ADR 0018](../../../../docs/adr/0018-provider-attempt-authority-and-recovery.md#concept).

  ## Technical depth

  Every record here is a closed key set. The reducer that applies them and the
  coordinator that proposes them both read the key sets from this module, so a
  member cannot be added on one side of the journal and missed on the other.

  Reply projection is retention, not reconstruction: the nine-key callback map
  is validated, its echoed request bytes are compared with the committed request
  and then excluded, and the remaining eight members are retained
  byte-for-byte. Nothing here canonicalises, truncates, or regenerates a value,
  because a member this module rebuilt would read back correct while the bytes
  the provider actually produced were gone.
  """

  @opened_kind "model_attempt_opened_v1"
  @settled_kind "model_attempt_settled_v1"
  @termination_kind "model_termination_admitted_v1"

  @opened_keys ["run_id", "turn_id", "operation_id", "attempt", "staged_request_digest"]
  @settled_keys [
    "run_id",
    "turn_id",
    "operation_id",
    "attempt",
    "staged_request_digest",
    "transport",
    "termination",
    "conversation",
    "next",
    "result",
    "accounting"
  ]
  @termination_keys [
    "run_id",
    "turn_id",
    "operation_id",
    "attempt",
    "staged_request_digest",
    "cause",
    "deadline",
    "observed"
  ]

  @reply_keys [
    "text",
    "identity",
    "usage",
    "tool_calls",
    "delta_count",
    "streamed",
    "provider_response_id",
    "staged_request_digest"
  ]

  @callback_keys ["canonical_request_bytes" | @reply_keys]

  @identity_keys ["provider", "model", "endpoint"]
  @tool_call_keys ["id", "name", "arguments"]

  @uint64_max 18_446_744_073_709_551_615
  @item_bytes 65_536
  @response_id_bytes 256

  @attempt_limit 2

  @doc """
  ## Concept

  The total number of provider attempts version one of the attempt-open record
  admits for one staged model operation.

  ## Technical depth

  Two: the first attempt plus exactly one retry, and the retry only after an
  exact durable `not_dispatched` settlement. The number is a property of the
  record kind rather than of a process attribute, because replay has to reach
  the same answer as the owner that wrote it.
  """
  @spec attempt_limit() :: pos_integer()
  def attempt_limit, do: @attempt_limit

  @doc """
  ## Concept

  The record kinds this module owns.

  ## Technical depth

  Read by the session reducer's replay filter so the admitted set and the
  applied set cannot drift apart.
  """
  @spec opened_kind() :: binary()
  def opened_kind, do: @opened_kind

  @doc """
  ## Concept

  The kind of the record that settles one attempt.

  ## Technical depth

  See `opened_kind/0`.
  """
  @spec settled_kind() :: binary()
  def settled_kind, do: @settled_kind

  @doc """
  ## Concept

  The kind of the record that admits a deadline against an open attempt.

  ## Technical depth

  See `opened_kind/0`.
  """
  @spec termination_kind() :: binary()
  def termination_kind, do: @termination_kind

  @doc """
  ## Concept

  The exact six-key attempt-open record, which is the only dispatch authority a
  provider attempt has.

  ## Technical depth

  Every member equals the current committed staged request. The caller supplies
  those values; this refuses anything that is not a bounded plain member of the
  declared domain rather than committing a record replay would later refuse.
  """
  @spec opened_record(map()) :: {:ok, map()} | {:error, term()}
  def opened_record(%{
        run_id: run_id,
        turn_id: turn_id,
        operation_id: operation_id,
        attempt: attempt,
        staged_request_digest: digest
      }) do
    record = %{
      "run_id" => run_id,
      "turn_id" => turn_id,
      "operation_id" => operation_id,
      "attempt" => attempt,
      "staged_request_digest" => digest,
      kind: @opened_kind
    }

    with :ok <- validate_identity(record) do
      {:ok, record}
    end
  end

  @doc """
  ## Concept

  Whether a replayed attempt-open row is the exact record this version admits.

  ## Technical depth

  The key set is closed, so an unknown member refuses the history instead of
  being ignored. The attempt position is checked here rather than at the caller
  because the version-one allowance is what this record kind means.
  """
  @spec validate_opened(map()) :: :ok | {:error, term()}
  def validate_opened(record) when is_map(record) do
    with :ok <- exact_keys(record, @opened_keys),
         :ok <- validate_identity(record) do
      :ok
    end
  end

  def validate_opened(_record), do: {:error, :invalid_attempt_open}

  @doc """
  ## Concept

  Whether a replayed settlement row is the exact twelve-key record with a
  closed, internally consistent verdict.

  ## Technical depth

  The verdict members are checked as one combination rather than one at a time,
  because the invalid histories ADR 0018 names — a reply tagged not-dispatched,
  dispatched accounting `none`, reported accounting without matching reply usage
  — are each legal in every member taken alone.
  """
  @spec validate_settled(map()) :: :ok | {:error, term()}
  def validate_settled(record) when is_map(record) do
    with :ok <- exact_keys(record, @settled_keys),
         :ok <- validate_identity(record),
         :ok <- validate_verdict(record) do
      :ok
    end
  end

  def validate_settled(_record), do: {:error, :invalid_attempt_settlement}

  @doc """
  ## Concept

  Whether a replayed termination row is the exact nine-key deadline admission.

  ## Technical depth

  `observed >= deadline` is part of the record's meaning: an admission naming an
  instant before its own bound describes a deadline that had not been reached.
  """
  @spec validate_termination(map()) :: :ok | {:error, term()}
  def validate_termination(record) when is_map(record) do
    with :ok <- exact_keys(record, @termination_keys),
         :ok <- validate_identity(record),
         true <- record["cause"] == "deadline",
         true <- uint64?(record["deadline"]),
         true <- uint64?(record["observed"]),
         true <- record["observed"] >= record["deadline"] do
      :ok
    else
      {:error, reason} -> {:error, reason}
      _other -> {:error, :invalid_model_termination}
    end
  end

  def validate_termination(_record), do: {:error, :invalid_model_termination}

  @doc """
  ## Concept

  The exact durable reply: the adapter's nine-key callback map with only its
  echoed request bytes removed.

  ## Technical depth

  The echoed `canonical_request_bytes` is compared byte-for-byte with the
  already committed request and then excluded from measurement, so a staged
  request and a durable reply that each fit their own record do not have to fit
  one item together. Every other member is retained exactly as supplied, after
  key normalisation only: atom and binary keys both reach the same closed set,
  and a collision between them refuses the reply.
  """
  @spec canonical_reply(term(), map()) :: {:ok, map()} | {:error, term()}
  def canonical_reply(reply, request) when is_map(reply) and not is_struct(reply) do
    with {:ok, encoded} <- stringify(reply),
         :ok <- callback_keys(encoded),
         {:ok, identity} <- reply_identity(Map.get(encoded, "identity")),
         {:ok, calls} <- reply_tool_calls(Map.get(encoded, "tool_calls")),
         {:ok, text} <- valid_text(Map.get(encoded, "text")),
         {:ok, delta_count} <- reply_delta_count(Map.get(encoded, "delta_count")),
         {:ok, streamed} <- reply_streamed(Map.get(encoded, "streamed"), delta_count),
         {:ok, response_id} <- reply_response_id(Map.get(encoded, "provider_response_id", nil)),
         true <- Map.get(encoded, "canonical_request_bytes") == request.canonical_request_bytes,
         true <- Map.get(encoded, "staged_request_digest") == request.staged_request_digest do
      {:ok,
       %{
         "text" => text,
         "identity" => identity,
         "usage" => normalize_usage(Map.get(encoded, "usage")),
         "tool_calls" => calls,
         "delta_count" => delta_count,
         "streamed" => streamed,
         "provider_response_id" => response_id,
         "staged_request_digest" => Map.get(encoded, "staged_request_digest")
       }}
    else
      {:error, reason} -> {:error, reason}
      _other -> {:error, :unreadable_model_answer}
    end
  end

  def canonical_reply(_reply, _request), do: {:error, :unreadable_model_answer}

  @doc """
  ## Concept

  The exact normalized usage of one reply: either a complete reported pair or a
  named reason it is unreported.

  ## Technical depth

  Classification order is overflow, both valid, exactly one present, both
  absent, then malformed. A negative, non-integer, oversized, or unknown raw
  field never reaches a retained or rendered value; only the category does.
  """
  @spec normalize_usage(term()) :: map()
  def normalize_usage(usage) when is_map(usage) and not is_struct(usage) do
    input = usage_member(usage, "input_tokens")
    output = usage_member(usage, "output_tokens")

    cond do
      overflowing?(input) or overflowing?(output) ->
        unreported("uint64_overflow")

      uint64?(input) and uint64?(output) ->
        %{"status" => "reported", "input_tokens" => input, "output_tokens" => output}

      present?(input) != present?(output) and readable_member?(input) and
          readable_member?(output) ->
        unreported("partial")

      not present?(input) and not present?(output) ->
        unreported("missing")

      true ->
        unreported("malformed")
    end
  end

  def normalize_usage(_usage), do: unreported("malformed")

  @doc """
  ## Concept

  The exact size the Store will retain a private record at.

  ## Technical depth

  Measured over the canonical string-keyed item, which is the form the journal
  holds, rather than over the in-memory proposal whose `kind` is still an atom.
  Measuring the proposal instead reports three bytes fewer than the Store keeps,
  which would admit an item one byte over the ceiling and then discover it at
  the transaction boundary — the surprise the pre-commit preflight exists to
  prevent.
  """
  @spec record_bytes(map()) :: non_neg_integer()
  def record_bytes(record) when is_map(record) do
    canonical =
      case Map.fetch(record, :kind) do
        {:ok, kind} -> record |> Map.delete(:kind) |> Map.put("kind", kind)
        :error -> record
      end

    byte_size(:erlang.term_to_binary(canonical, [:deterministic]))
  end

  @doc """
  ## Concept

  The Store's fixed ceiling for one retained item.

  ## Technical depth

  Named here so the preflight and the reducer compare against one number.
  """
  @spec item_bytes() :: pos_integer()
  def item_bytes, do: @item_bytes

  @doc """
  ## Concept

  Whether a durable reply projection fits inside its own settlement record.

  ## Technical depth

  Measured on the complete intended settlement, never on the reply alone: what
  the Store retains is the record, and a reply that fits by itself can still
  overflow the verdict that carries it.
  """
  @spec fits?(map()) :: boolean()
  def fits?(settlement), do: record_bytes(settlement) <= @item_bytes

  # Concept: a settlement is one indivisible verdict, so its members are
  # validated as a combination.
  #
  # Technical depth: the closed table of ADR 0018 is expressed as refusals of
  # the combinations it names invalid rather than as an enumeration of the valid
  # ones, because the record is also the migration boundary: a member added by a
  # later version must fail the exact key set above, not slip through a
  # permissive branch here.
  defp validate_verdict(record) do
    transport = record["transport"]
    termination = record["termination"]
    conversation = record["conversation"]
    next = record["next"]
    result = record["result"]
    accounting = record["accounting"]

    with true <- transport in ["not_dispatched", "dispatched_or_unknown"],
         true <- termination in [nil, "abort", "deadline", "owner_loss"],
         true <- conversation in ["canonical", "evidence_only", "none"],
         true <- next in ["retry", "continue", "terminal"],
         :ok <- validate_result(result),
         :ok <- validate_accounting(accounting),
         :ok <-
           validate_combination(transport, termination, conversation, next, result, accounting) do
      :ok
    else
      {:error, reason} -> {:error, reason}
      _other -> {:error, :invalid_attempt_settlement}
    end
  end

  defp validate_result(%{"kind" => "reply", "reply" => reply} = result)
       when map_size(result) == 2 do
    with :ok <- exact_keys(reply, @reply_keys),
         {:ok, _identity} <- reply_identity(Map.get(reply, "identity")),
         {:ok, _calls} <- reply_tool_calls(Map.get(reply, "tool_calls")),
         {:ok, _text} <- valid_text(Map.get(reply, "text")),
         {:ok, count} <- reply_delta_count(Map.get(reply, "delta_count")),
         {:ok, _streamed} <- reply_streamed(Map.get(reply, "streamed"), count),
         {:ok, _response_id} <- reply_response_id(Map.get(reply, "provider_response_id")),
         :ok <- validate_usage_shape(Map.get(reply, "usage")),
         true <- lowercase_sha256?(Map.get(reply, "staged_request_digest")) do
      :ok
    else
      {:error, reason} -> {:error, reason}
      _other -> {:error, :invalid_attempt_settlement}
    end
  end

  defp validate_result(%{"kind" => "error", "category" => category} = result)
       when map_size(result) == 2 and
              category in ["model_call_failed", "unreadable_model_answer"],
       do: :ok

  defp validate_result(_result), do: {:error, :invalid_attempt_settlement}

  defp validate_usage_shape(
         %{"status" => "reported", "input_tokens" => i, "output_tokens" => o} = u
       )
       when map_size(u) == 3 do
    if uint64?(i) and uint64?(o), do: :ok, else: {:error, :invalid_attempt_settlement}
  end

  defp validate_usage_shape(%{"status" => "unreported", "category" => category} = u)
       when map_size(u) == 2 and
              category in ["missing", "partial", "malformed", "uint64_overflow"],
       do: :ok

  defp validate_usage_shape(_usage), do: {:error, :invalid_attempt_settlement}

  defp validate_accounting(%{"source" => "none", "basis" => "not_dispatched"} = a)
       when map_size(a) == 2,
       do: :ok

  defp validate_accounting(%{"source" => "estimated", "basis" => "remaining_allowance"} = a)
       when map_size(a) == 2,
       do: :ok

  defp validate_accounting(
         %{"source" => "reported", "input_tokens" => input, "output_tokens" => output} = a
       )
       when map_size(a) == 3 do
    if uint64?(input) and uint64?(output), do: :ok, else: {:error, :invalid_attempt_settlement}
  end

  defp validate_accounting(_accounting), do: {:error, :invalid_attempt_settlement}

  defp validate_combination(transport, termination, conversation, next, result, accounting) do
    reply? = match?(%{"kind" => "reply"}, result)
    source = accounting["source"]

    cond do
      # A reply that arrived can never prove the transport was not entered.
      reply? and transport == "not_dispatched" ->
        {:error, :invalid_attempt_settlement}

      # Exactly the pre-permit refusal: nothing was sent, so nothing is owed and
      # nothing was said.
      transport == "not_dispatched" and (source != "none" or conversation != "none") ->
        {:error, :invalid_attempt_settlement}

      # A possibly billed attempt is always charged.
      transport == "dispatched_or_unknown" and source == "none" ->
        {:error, :invalid_attempt_settlement}

      # Reported accounting is the reply's own usage, never a separate claim.
      source == "reported" and not reported_matches?(result, accounting) ->
        {:error, :invalid_attempt_settlement}

      # Only an exact not-dispatched first attempt may retry.
      next == "retry" and
          (transport != "not_dispatched" or termination != nil) ->
        {:error, :invalid_attempt_settlement}

      # Continuing means the model asked for tools it can still be given.
      next == "continue" and not continuing_reply?(result, conversation, termination) ->
        {:error, :invalid_attempt_settlement}

      # An answer that entered no conversation cannot be the canonical one.
      conversation == "canonical" and (not reply? or termination != nil) ->
        {:error, :invalid_attempt_settlement}

      conversation == "evidence_only" and (not reply? or termination == nil) ->
        {:error, :invalid_attempt_settlement}

      true ->
        :ok
    end
  end

  defp reported_matches?(%{"kind" => "reply", "reply" => reply}, accounting) do
    reply["usage"] ==
      %{
        "status" => "reported",
        "input_tokens" => accounting["input_tokens"],
        "output_tokens" => accounting["output_tokens"]
      }
  end

  defp reported_matches?(_result, _accounting), do: false

  defp continuing_reply?(%{"kind" => "reply", "reply" => reply}, conversation, termination),
    do: reply["tool_calls"] != [] and conversation == "canonical" and termination == nil

  defp continuing_reply?(_result, _conversation, _termination), do: false

  defp validate_identity(record) do
    with true <- bounded_binary?(record["run_id"]),
         true <- bounded_binary?(record["turn_id"]),
         true <- bounded_binary?(record["operation_id"]),
         true <- record["attempt"] in 1..@attempt_limit,
         true <- lowercase_sha256?(record["staged_request_digest"]) do
      :ok
    else
      _other -> {:error, :invalid_attempt_identity}
    end
  end

  defp exact_keys(map, expected) when is_map(map) and not is_struct(map) do
    actual =
      map
      |> Map.keys()
      |> Enum.map(fn
        :kind -> "kind"
        key -> key
      end)

    named = if Map.has_key?(map, :kind) or Map.has_key?(map, "kind"), do: ["kind"], else: []

    if MapSet.new(actual) == MapSet.new(named ++ expected) and
         length(actual) == length(Enum.uniq(actual)) do
      :ok
    else
      {:error, :invalid_exact_record_schema}
    end
  end

  defp exact_keys(_map, _expected), do: {:error, :invalid_exact_record_schema}

  defp callback_keys(encoded) do
    keys = encoded |> Map.keys() |> MapSet.new()
    allowed = MapSet.new(@callback_keys)
    required = @callback_keys |> Enum.reject(&(&1 == "provider_response_id")) |> MapSet.new()

    if MapSet.subset?(keys, allowed) and MapSet.subset?(required, keys) do
      :ok
    else
      {:error, :unreadable_model_answer}
    end
  end

  defp reply_identity(identity) when is_map(identity) and not is_struct(identity) do
    with {:ok, encoded} <- stringify(identity),
         :ok <- exact_keys(encoded, @identity_keys),
         true <- Enum.all?(@identity_keys, &nonempty_utf8?(Map.get(encoded, &1))) do
      {:ok, encoded}
    else
      _other -> {:error, :unreadable_model_answer}
    end
  end

  defp reply_identity(_identity), do: {:error, :unreadable_model_answer}

  defp reply_tool_calls(calls) when is_list(calls) do
    Enum.reduce_while(calls, {:ok, []}, fn call, {:ok, acc} ->
      case reply_tool_call(call) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp reply_tool_calls(_calls), do: {:error, :unreadable_model_answer}

  defp reply_tool_call(call) when is_map(call) and not is_struct(call) do
    with {:ok, encoded} <- stringify(call),
         :ok <- exact_keys(encoded, @tool_call_keys),
         true <- nonempty_utf8?(Map.get(encoded, "id")),
         true <- nonempty_utf8?(Map.get(encoded, "name")),
         arguments = Map.get(encoded, "arguments"),
         true <- is_map(arguments) and not is_struct(arguments) do
      {:ok, encoded}
    else
      _other -> {:error, :unreadable_model_answer}
    end
  end

  defp reply_tool_call(_call), do: {:error, :unreadable_model_answer}

  defp valid_text(text) do
    if is_binary(text) and String.valid?(text),
      do: {:ok, text},
      else: {:error, :unreadable_model_answer}
  end

  defp reply_delta_count(count) do
    if uint64?(count), do: {:ok, count}, else: {:error, :unreadable_model_answer}
  end

  # Concept: stream evidence is retained, never repaired.
  #
  # Technical depth: `streamed` is true exactly when `delta_count` is positive.
  # Deriving one member from the other agrees with every consistent adapter and
  # silently rewrites the one case that matters, so a contradiction refuses the
  # reply instead.
  defp reply_streamed(streamed, delta_count) do
    if is_boolean(streamed) and streamed == delta_count > 0,
      do: {:ok, streamed},
      else: {:error, :unreadable_model_answer}
  end

  defp reply_response_id(nil), do: {:ok, nil}

  defp reply_response_id(id) do
    if nonempty_utf8?(id) and byte_size(id) <= @response_id_bytes,
      do: {:ok, id},
      else: {:error, :unreadable_model_answer}
  end

  # Concept: an atom-keyed and a binary-keyed member of one name are the same
  # member, and a map carrying both is not readable.
  #
  # Technical depth: the durable projection is string-keyed, so normalising
  # silently would let `%{text: "a", "text" => "b"}` retain whichever survived
  # the traversal. The collision refuses the reply instead.
  defp stringify(map) do
    Enum.reduce_while(map, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      normalized = if is_atom(key), do: Atom.to_string(key), else: key

      cond do
        not is_binary(normalized) -> {:halt, {:error, :unreadable_model_answer}}
        Map.has_key?(acc, normalized) -> {:halt, {:error, :unreadable_model_answer}}
        true -> {:cont, {:ok, Map.put(acc, normalized, value)}}
      end
    end)
  end

  defp usage_member(usage, name) do
    cond do
      Map.has_key?(usage, name) ->
        Map.fetch!(usage, name)

      Map.has_key?(usage, String.to_existing_atom(name)) ->
        Map.fetch!(usage, String.to_existing_atom(name))

      true ->
        :absent
    end
  rescue
    ArgumentError -> :absent
  end

  defp present?(:absent), do: false
  defp present?(_value), do: true

  defp readable_member?(:absent), do: true
  defp readable_member?(value), do: uint64?(value)

  defp overflowing?(value), do: is_integer(value) and value > @uint64_max

  defp unreported(category), do: %{"status" => "unreported", "category" => category}

  defp uint64?(value), do: is_integer(value) and value >= 0 and value <= @uint64_max

  defp bounded_binary?(value),
    do: is_binary(value) and byte_size(value) > 0 and byte_size(value) <= 512

  defp nonempty_utf8?(value),
    do: is_binary(value) and byte_size(value) > 0 and String.valid?(value)

  defp lowercase_sha256?(value) do
    is_binary(value) and byte_size(value) == 64 and
      value == String.downcase(value) and
      match?({:ok, _decoded}, Base.decode16(value, case: :lower))
  end
end
