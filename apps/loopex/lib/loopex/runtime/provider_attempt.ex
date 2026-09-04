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
  @usage_keys ["input_tokens", "output_tokens"]
  @tool_call_keys ["id", "name", "arguments"]

  @uint64_max 18_446_744_073_709_551_615
  @response_id_bytes 256

  # Technical depth: ADR 0017's per-collection ceiling, read at compile time so
  # the projection and the Store cannot disagree about how many members any
  # durable item may carry.
  @max_reply_members Loopex.Store.max_item_cardinality()

  # Technical depth: the other two ADR 0017 ceilings the raw admission below
  # charges against, read from the same core contract for the same reason. Both
  # are measured from the reply's own root, while the durable settlement that
  # carries the reply is measured from the record root, so admission here is
  # deliberately the more permissive of the two and the exact settlement
  # measurement still decides what is retained.
  @max_reply_bytes Loopex.Store.max_item_bytes()
  @max_reply_depth Loopex.Store.max_item_depth()

  @echoed_request_key "canonical_request_bytes"
  @usage_key "usage"

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

  Whether a value is exactly the six-member identity one provider permit may
  authorize: the attempt-open record's five members plus the session they
  belong to.

  ## Technical depth

  ADR 0018 makes Control spend the full
  `{session, run, turn, operation, attempt}` identity once per attempt, after
  verifying that "every identity equals its registered state". The binding is
  the map that identity is spelled in, so a member Control never looked at is a
  member the one-use key can vary in freely: an extra key, a missing key, or a
  changed attempt produces a different map and therefore a second unspent key
  for the same attempt. The key set is closed and every member is checked
  against the same domain `validate_opened/1` enforces, so the spelling cannot
  vary at all.
  """
  @spec validate_binding(term()) :: :ok | {:error, term()}
  def validate_binding(binding) when is_map(binding) and not is_struct(binding) do
    with :ok <- exact_keys(binding, ["session_id" | @opened_keys]),
         true <- bounded_binary?(binding["session_id"]),
         :ok <- validate_identity(binding) do
      :ok
    else
      _other -> {:error, :invalid_provider_attempt_binding}
    end
  end

  def validate_binding(_binding), do: {:error, :invalid_provider_attempt_binding}

  @doc """
  ## Concept

  The exact permit binding one committed attempt-open row authorizes, in the
  session that row was read from.

  ## Technical depth

  ADR 0018 requires that "every identity equals its registered state" before
  Control spends an attempt, and the registered state of a run, turn, operation,
  attempt and digest is the committed `model_attempt_opened_v1` row, never the
  argument of the process asking for the permit. So the binding is rebuilt here
  from that row's own five members plus the session it belongs to, and a caller's
  map is admitted only by equality with this one. The row is validated as the
  exact attempt-open record first, including its kind, so a row of any other
  kind standing at the same journal position names no binding at all rather than
  contributing whichever of these members it happens to carry. Every refusal is
  the binding refusal, because the only question asked here is which binding, if
  any, this row registers.
  """
  @spec binding_from_opened(term(), term()) :: {:ok, map()} | {:error, term()}
  def binding_from_opened(session_id, record)
      when is_binary(session_id) and is_map(record) and not is_struct(record) do
    with @opened_kind <- Map.get(record, :kind, Map.get(record, "kind")),
         :ok <- validate_opened(record),
         binding = Map.put(Map.take(record, @opened_keys), "session_id", session_id),
         :ok <- validate_binding(binding) do
      {:ok, binding}
    else
      _other -> {:error, :invalid_provider_attempt_binding}
    end
  end

  def binding_from_opened(_session_id, _record),
    do: {:error, :invalid_provider_attempt_binding}

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

  The raw answer is admitted against ADR 0017's plain-data, depth, cardinality
  and byte ceilings before anything is projected, and that admission stops at
  the first member that breaks one of them.

  The echoed `canonical_request_bytes` is compared byte-for-byte with the
  already committed request and then excluded from measurement, so a staged
  request and a durable reply that each fit their own record do not have to fit
  one item together. Every other member is retained exactly as supplied, after
  key normalisation only: atom and binary keys both reach the same closed set,
  and a collision between them refuses the reply.
  """
  @spec canonical_reply(term(), map()) :: {:ok, map()} | {:error, term()}
  def canonical_reply(reply, request) when is_map(reply) and not is_struct(reply) do
    with :ok <- admitted_raw_reply(reply),
         {:ok, encoded} <- stringify(reply),
         :ok <- callback_keys(encoded),
         {:ok, identity} <- reply_identity(Map.get(encoded, "identity")),
         {:ok, calls} <- reply_tool_calls(Map.get(encoded, "tool_calls")),
         {:ok, usage} <- reply_usage(Map.get(encoded, "usage")),
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
         "usage" => usage,
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
           validate_combination(
             record["attempt"],
             transport,
             termination,
             conversation,
             next,
             result,
             accounting
           ) do
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

  defp validate_combination(
         attempt,
         transport,
         termination,
         conversation,
         next,
         result,
         accounting
       ) do
    with {:ok, expected_conversation, expected_next, expected_sources} <-
           settlement_cell(attempt, transport, termination, result),
         true <- conversation == expected_conversation,
         true <- next == expected_next,
         true <- accounting["source"] in expected_sources,
         # Reported accounting is the reply's own usage, never a separate claim.
         true <- accounting["source"] != "reported" or reported_matches?(result, accounting) do
      :ok
    else
      _other -> {:error, :invalid_attempt_settlement}
    end
  end

  # Concept: one cell of ADR 0018's closed table -- given who was answering,
  # what the transport did, which termination won, and what came back, there is
  # exactly one conversation and one `next`, and at most two accounting sources.
  #
  # Technical depth: this was a list of refusals with `:ok` underneath, so every
  # member assignment nobody had thought to forbid validated by default. An
  # attempt-one settlement with exact `not_dispatched`, no termination, no
  # conversation and no accounting validated with `next: "terminal"`, although
  # combination 4 fixes `retry` for that exact cell: the record silently spent
  # the version-1 retry allowance the run still had. Stating the table instead
  # makes "all other combinations are invalid history" the default rather than
  # the part that has to be remembered, and it keeps every refusal the list held
  # -- a reply tagged not-dispatched, dispatched accounting `none`, attempt-two
  # or dispatched retry, a `continue` without continuable tool calls, and a
  # canonical or evidence-only conversation without the reply and termination
  # that name it -- because no cell produces any of them.
  #
  # A reply's accounting is `reported` exactly when the reply carries complete
  # reported usage, which combination 1 fixes and `reported_matches?/2` then
  # ties to the exact figures. Combination 5 is the one cell with a choice:
  # compaction removed the reply the numbers came from, so the record can no
  # longer say whether usage was available, and both sources stay admissible.
  defp settlement_cell(attempt, "not_dispatched", termination, %{
         "kind" => "error",
         "category" => "model_call_failed"
       })
       when termination in [nil, "abort", "deadline"] do
    # Combination 4: nothing was sent, so nothing is owed and nothing was said.
    # Attempt one retries only when no termination has won; the limit and every
    # termination select the terminal model-call failure, because version 1 has
    # no further allowance.
    next = if attempt < @attempt_limit and is_nil(termination), do: "retry", else: "terminal"
    {:ok, "none", next, ["none"]}
  end

  defp settlement_cell(_attempt, "dispatched_or_unknown", nil, %{
         "kind" => "reply",
         "reply" => reply
       }) do
    # Combination 1: the canonical answer. Tool calls select `continue`; a
    # no-tool reply selects the normal completed terminal.
    next = if reply["tool_calls"] == [], do: "terminal", else: "continue"
    {:ok, "canonical", next, [reply_accounting_source(reply)]}
  end

  defp settlement_cell(_attempt, "dispatched_or_unknown", termination, %{
         "kind" => "reply",
         "reply" => reply
       })
       when termination in ["abort", "deadline"] do
    # Combination 2: the ending was already chosen, so a late valid reply is
    # retained as evidence rather than as the conversation.
    {:ok, "evidence_only", "terminal", [reply_accounting_source(reply)]}
  end

  defp settlement_cell(_attempt, "dispatched_or_unknown", _termination, %{
         "kind" => "error",
         "category" => "model_call_failed"
       }),
       # Combination 3: a live ambiguous error or a recovered open attempt.
       do: {:ok, "none", "terminal", ["estimated"]}

  defp settlement_cell(_attempt, "dispatched_or_unknown", termination, %{
         "kind" => "error",
         "category" => "unreadable_model_answer"
       })
       when termination in [nil, "abort", "deadline"],
       # Combination 5: an answer this runtime could not read or could not fit.
       do: {:ok, "none", "terminal", ["reported", "estimated"]}

  defp settlement_cell(_attempt, _transport, _termination, _result),
    do: {:error, :invalid_attempt_settlement}

  defp reply_accounting_source(%{"usage" => %{"status" => "reported"}}), do: "reported"
  defp reply_accounting_source(_reply), do: "estimated"

  defp reported_matches?(%{"kind" => "reply", "reply" => reply}, accounting) do
    reply["usage"] ==
      %{
        "status" => "reported",
        "input_tokens" => accounting["input_tokens"],
        "output_tokens" => accounting["output_tokens"]
      }
  end

  # Concept: the compact unreadable answer is the one result that may carry
  # reported usage without a retained reply to show it against.
  #
  # Technical depth: ADR 0018 combination 5 says the compacted record
  # "preserves complete reported usage when available", and compaction is
  # exactly what removed the reply those numbers came from. Refusing the pair
  # here would make a record Core itself built self-invalid and cost the run its
  # verdict over an answer the provider did charge for. The licence is narrow on
  # purpose: `model_call_failed` names an attempt with no readable answer at
  # all, keeps combination 3's estimated remaining allowance, and still has no
  # way to claim a reported figure.
  defp reported_matches?(
         %{"kind" => "error", "category" => "unreadable_model_answer"},
         _accounting
       ),
       do: true

  defp reported_matches?(_result, _accounting), do: false

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

  # Concept: an answer no record could ever hold is refused before it is read,
  # at the first member that proves it, not after every member has been walked.
  #
  # Technical depth: the cardinality ceiling alone left the other three ADR 0017
  # dimensions applying only after projection. `canonical_reply/2` normalised
  # keys, projected identity, walked and rebuilt every tool call, and only then
  # did `attempt_result/3` measure the settlement -- so 1,024 tool calls each
  # carrying a megabyte of argument text, or an arguments map nested ten
  # thousand levels deep, were traversed and copied in full before the 65,536
  # byte and depth-12 refusals could apply. M2's row-one obligation is the
  # opposite order: "every raw model-reply candidate first satisfies the Store's
  # plain-data, depth, item, and byte ceilings, then refuses any undeclared
  # top-level key while projecting". This is that first pass. It carries a depth
  # counter, a per-collection member counter and a cumulative byte counter, and
  # returns at the first violation, so the walk costs what the admitted prefix
  # costs rather than what the answer claims to be.
  #
  # Bytes are counted, never built: `byte_size/1` for a binary, and
  # `:erlang.external_size/2` for the scalars whose encoded width is not their
  # own -- both read a term without allocating it, which `term_to_binary/2`
  # would not. Containers add nothing of their own, so the total is at or below
  # the eventual external size of the same term and can only be the more
  # permissive of the two; the exact settlement measurement in
  # `Loopex.Runtime.SessionState` still decides what is retained.
  #
  # Two root members are deliberately outside the walk, because neither one is
  # retained as supplied and each is already closed. `canonical_request_bytes`
  # is excluded from reply-size measurement by ADR 0018 -- the committed request
  # already fit its own record -- so it is charged against its own allowance
  # instead, which also keeps the byte-for-byte comparison further down from
  # being handed an unbounded binary. `usage` is replaced wholesale by
  # `normalize_usage/1`'s closed two- or three-key classification, and the path
  # that does it is bounded without this walk: the map is refused above
  # `max_item_cardinality/0` members, only `input_tokens` and `output_tokens`
  # may be named, and their values are read but never descended into. Walking it
  # here would also break ADR 0018 combination 1, which requires a present but
  # negative, non-integer, oversized, or wholly non-map usage to be classified
  # rather than to refuse an otherwise canonical reply.
  defp admitted_raw_reply(reply) do
    with :ok <- bounded_cardinality(map_size(reply)) do
      case admitted_members(reply, 0, 0) do
        {:ok, _charged} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp admitted_members(map, depth, charged) do
    Enum.reduce_while(map, {:ok, charged}, fn {key, value}, {:ok, charged} ->
      with {:ok, charged} <- admitted_key(key, charged),
           {:ok, charged} <- admitted_member(key, value, depth, charged) do
        {:cont, {:ok, charged}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp admitted_member(key, value, 0, charged)
       when key in [:canonical_request_bytes, @echoed_request_key] do
    if is_binary(value) and byte_size(value) <= @max_reply_bytes,
      do: {:ok, charged},
      else: {:error, :unreadable_model_answer}
  end

  defp admitted_member(key, _value, 0, charged) when key in [:usage, @usage_key],
    do: {:ok, charged}

  defp admitted_member(_key, value, depth, charged), do: admitted_term(value, depth + 1, charged)

  defp admitted_term(_value, depth, _charged) when depth > @max_reply_depth,
    do: {:error, :unreadable_model_answer}

  defp admitted_term(value, _depth, charged) when is_binary(value),
    do: charge(charged, byte_size(value))

  defp admitted_term(value, _depth, charged) when is_integer(value) or is_float(value),
    do: charge(charged, :erlang.external_size(value, [:deterministic]))

  defp admitted_term(value, _depth, charged) when value in [nil, true, false],
    do: {:ok, charged}

  defp admitted_term([], _depth, charged), do: {:ok, charged}

  defp admitted_term([_head | _tail] = list, depth, charged) do
    with :ok <- bounded_members(list, 0), do: admitted_list(list, depth, charged)
  end

  defp admitted_term(map, depth, charged) when is_map(map) and not is_struct(map) do
    with :ok <- bounded_cardinality(map_size(map)), do: admitted_members(map, depth, charged)
  end

  defp admitted_term(_other, _depth, _charged), do: {:error, :unreadable_model_answer}

  defp admitted_list([], _depth, charged), do: {:ok, charged}

  defp admitted_list([head | tail], depth, charged) do
    case admitted_term(head, depth + 1, charged) do
      {:ok, charged} -> admitted_list(tail, depth, charged)
      {:error, reason} -> {:error, reason}
    end
  end

  # Technical depth: a key is charged like the scalar it is. Only the two forms
  # the Store normalises are admitted, so a key that could never reach a durable
  # item stops the walk here rather than after its subtree has been visited.
  defp admitted_key(key, charged) when is_binary(key), do: charge(charged, byte_size(key))

  defp admitted_key(key, charged) when is_atom(key),
    do: charge(charged, :erlang.external_size(key, [:deterministic]))

  defp admitted_key(_key, _charged), do: {:error, :unreadable_model_answer}

  defp charge(charged, bytes) when charged + bytes > @max_reply_bytes,
    do: {:error, :unreadable_model_answer}

  defp charge(charged, bytes), do: {:ok, charged + bytes}

  defp bounded_cardinality(size) when size > @max_reply_members,
    do: {:error, :unreadable_model_answer}

  defp bounded_cardinality(_size), do: :ok

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
    with :ok <- bounded_members(calls, 0) do
      project_tool_calls(calls)
    end
  end

  defp reply_tool_calls(_calls), do: {:error, :unreadable_model_answer}

  # Concept: an answer carrying more members than any record could hold is
  # refused at the first member past the ceiling, not after all of them have
  # been read.
  #
  # Technical depth: an adapter is untrusted input, and this projection runs
  # before any Store bound applies to the settlement built from it. ADR 0017
  # fixes 1,024 members as the most any collection inside a durable item may
  # carry, so a longer one has no admissible outcome and the walk that would
  # discover that is the cost being avoided: a million-member tool-call list was
  # visited and projected into a million fresh maps before the settlement failed
  # to fit. Counting cons cells one at a time never calls `length/1` on the
  # untrusted tail and stops at the first rejected witness, and a tail that is
  # not `[]` inside the admitted range is an unreadable answer like any other
  # malformed member.
  defp bounded_members(_members, counted) when counted > @max_reply_members,
    do: {:error, :unreadable_model_answer}

  defp bounded_members([_head | tail], counted), do: bounded_members(tail, counted + 1)
  defp bounded_members([], _counted), do: :ok
  defp bounded_members(_improper_tail, _counted), do: {:error, :unreadable_model_answer}

  defp project_tool_calls(calls) do
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

  # Concept: a usage map is closed like every other level of the callback
  # reply, and only the values inside it are classified rather than refused.
  #
  # Technical depth: ADR 0018 admits no extra key at any level of
  # `bounded_adapter_reply_v2`, and its normalized usage is built from exactly
  # `input_tokens` and `output_tokens`. A member outside that pair is an
  # unreadable answer here rather than a value `normalize_usage/1` silently
  # drops, because dropping it retains a usage the provider did not state and
  # lets an arbitrary provider term reach the Store measurement in the members
  # around it. Absence stays legal -- the pair classifies to `missing` or
  # `partial` -- and a present but negative, non-integer, or oversized value
  # stays a classification rather than a refusal, since ADR 0018 combination 1
  # keeps such a reply canonical on the exact remaining allowance. A usage that
  # is not a map at all is classified `malformed` for the same reason; it names
  # no key to close.
  defp reply_usage(usage) when is_map(usage) and not is_struct(usage) do
    with {:ok, encoded} <- stringify(usage),
         :ok <- subset_keys(encoded, @usage_keys) do
      {:ok, normalize_usage(encoded)}
    else
      _other -> {:error, :unreadable_model_answer}
    end
  end

  defp reply_usage(usage), do: {:ok, normalize_usage(usage)}

  defp subset_keys(map, allowed) do
    if MapSet.subset?(MapSet.new(Map.keys(map)), MapSet.new(allowed)),
      do: :ok,
      else: {:error, :unreadable_model_answer}
  end

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
  # Technical depth: every map of an adapter answer -- the callback map itself,
  # the identity, each tool call, and the usage -- reaches key normalisation
  # here, and normalising keys visits every member. The closed key sets below
  # would refuse an over-wide map afterwards, which is one walk of untrusted
  # input too late, so `map_size/1` decides it first in constant time against
  # the same ceiling no durable item may exceed.
  defp stringify(map) when map_size(map) > @max_reply_members,
    do: {:error, :unreadable_model_answer}

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
