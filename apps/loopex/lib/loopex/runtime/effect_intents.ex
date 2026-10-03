defmodule Loopex.Runtime.EffectIntents do
  @moduledoc """
  ## Concept

  Reads a captured session-journal prefix as private recovery evidence. A page
  advances over ordinary records as well as intents and tool terminals; only
  its nil next cursor proves complete coverage.

  ## Technical depth

  Control authenticates the runtime capability and contains this whole read
  under its existing Store-read guardian. The query checks committed creation
  scope, captures the ownership head, and visits at most sixteen records.
  Resume verifies one retained boundary record before returning fresh coverage.
  Tokens are raw SHA-256 over deterministic ETF of the ordered tuple
  `{journal_version, owner_epoch, owner_incarnation_id, payload_etf}`. They are
  opaque observations, never owner capabilities. Supported non-effect record
  shapes advance the cursor without leaving this private boundary. Effect rows
  reuse the reducer's canonical job and receipt decoders; composition owns
  cross-page intent/terminal joins. No session owner is acquired or activated.
  """

  alias Loopex.Model
  alias Loopex.Bounds
  alias Loopex.Runtime.MaintenanceConfiguration
  alias Loopex.Runtime.ProviderAttempt
  alias Loopex.Runtime.SessionGenesis
  alias Loopex.Runtime.SessionState
  alias Loopex.Store
  alias LoopexProtocol.Session.CompactResult

  @uint64_max 18_446_744_073_709_551_615
  @page_bytes 1_114_112
  @effect_kinds ~w(effect_intent_committed effect_intent_committed_v2 executor_receipt_committed executor_receipt_committed_v2 tool_result_committed tool_result_committed_v2 outcome_unknown_committed outcome_unknown_committed_v2)
  @command_keys ~w(command_id command_digest command_type admission)
  @prompt_keys @command_keys ++
                 ~w(run_id content max_turns token_budget deadline_ms context_token_budget)
  @request_keys ~w(run_id turn_id operation_id staged_request_digest request applied_steer context_receipt)
  @request_fields ~w(canonicalization_version model messages tools sampling deadline continuation canonical_request_bytes staged_request_digest)a
  @refusal_keys ~w(run_id turn_id category dimension token_estimator descriptor_canonicalization_version project_disposition system_message_count session_message_count steer_message_count tool_definition_count provider_estimated_tokens context_token_budget record_byte_cost context_record_byte_ceiling ordered_descriptor_digest observed limit)
  @neutral_shapes %{
    "owner_advanced" =>
      {~w(prior_owner_epoch owner_epoch owner_incarnation_id owner_transaction_id), []},
    "prompt_admitted_v2" => {@prompt_keys, []},
    "prompt_admitted_v3" => {@prompt_keys ++ ~w(configuration_version), []},
    "session_configuration_admitted_v1" =>
      {@command_keys ++ ~w(changes prior_configuration_version configuration), []},
    "command_admission_refused_v1" =>
      {@command_keys ++ ~w(dimension candidate observed limit), []},
    "resource_command_v1" => {~w(command command_digest disposition resolved), []},
    "model_request_committed" => {@request_keys, ~w(lineage_projection)},
    "model_request_committed_resources_v1" => {@request_keys, []},
    "model_request_committed_v2" =>
      {@request_keys ++ ~w(configuration_version), ~w(lineage_projection)},
    "model_request_committed_resources_v2" =>
      {@request_keys ++ ~w(configuration_version), ~w(lineage_projection)},
    "context_admission_refused_v1" => {@refusal_keys, []},
    "context_admission_refused_v2" =>
      {(@refusal_keys -- ~w(category dimension observed limit)) ++
         ~w(failure configuration_version episode_id targets projection_state measurement_scope),
       ~w(project_resource_count resource_pack_count)},
    "maintenance_episode_admitted_v1" =>
      {~w(episode_id run_id staging_turn_id trigger targets origin configuration_version maintenance_configuration bounds admitted_at preparation_deadline attempts summary_ordinal checkpoint_id usage),
       []},
    "maintenance_request_committed_v1" =>
      {~w(episode_id summary_ordinal purpose operation_id configuration_version captured_session_version strategy_revision eligible_unit_count covered_range source_digest source_excerpted staged_at staged_request_digest request context_receipt),
       []},
    "maintenance_episode_terminal_v1" => {~w(episode_id observed_at result), []},
    "compaction_checkpoint_committed_v1" =>
      {~w(checkpoint_id episode_id run_id summary_ordinal committed_at lineage covered_range consumed_range prior_checkpoint_id summary strategy strategy_revision model reasoning configuration_version usage source_digest),
       []},
    "deadline_staging_failed_v1" => {~w(run_id turn_id category), []},
    "run_terminal_committed" =>
      {~w(run_id outcome bound observed declared_limit accounting_source reconciliation_ref cleanup_grace_ms command_id),
       ~w(reason failure)},
    "interaction_requested_v1" =>
      {~w(interaction_id run_id turn tool_call_id interaction_request interaction_request_digest policy_request_digest round created_at expires_at policy_identity),
       ~w(decision_ref)},
    "interaction_answer_admitted_v1" =>
      {~w(interaction_id command_id choice_id answer_digest), []},
    "interaction_resolved_v1" => {~w(interaction_id resolution), ~w(reason)},
    "model_question_requested_v1" =>
      {~w(producer interaction_id run_id turn tool_call_id argument_digest interaction_request interaction_request_digest created_at expires_at),
       []},
    "model_question_response_admitted_v2" =>
      {@command_keys ++ ~w(interaction_id answer disposition responded_at), []},
    "model_question_settled_v2" => {~w(interaction_id disposition answer settled_at), []}
  }

  @doc """
  ## Concept

  Returns one scoped page or an explicit refusal to establish its coverage.

  ## Technical depth

  A missing optional creation-provenance callback is unavailable history. Store
  absence, scope conflict, malformed records and unavailable reads stay distinct.
  This function runs inside Control's bounded reader, never directly in a host.
  All response fields and cursor forms are closed. The complete tagged response
  and each projected row are measured as uncompressed deterministic ETF.
  """
  @spec read(Store.t(), binary(), term(), term(), term()) ::
          {:ok, map()}
          | {:error, :invalid_query | :session_absent | :history_unavailable | :invalid_history}
  def read(store, runtime_id, session_id, cursor, limit) do
    with :ok <- validate_query(runtime_id, session_id, cursor, limit),
         :ok <- scope(store, runtime_id, session_id),
         {:ok, head} <- head(store, session_id),
         {:ok, through, after_version, boundary} <-
           cut(store, runtime_id, session_id, cursor, head),
         {:ok, records} <- records(store, session_id, after_version, through, limit, boundary) do
      scan(records, runtime_id, session_id, through, after_version, boundary, [])
    end
  end

  defp validate_query(runtime_id, session_id, cursor, limit) do
    if identifier?(runtime_id) and identifier?(session_id) and is_integer(limit) and
         limit in 1..16 and valid_cursor?(cursor, runtime_id, session_id),
       do: :ok,
       else: {:error, :invalid_query}
  end

  defp valid_cursor?(nil, _, _), do: true

  defp valid_cursor?(
         %{through_version: through, after_version: after_version} = cursor,
         runtime,
         session
       ) do
    closed?(cursor, [:version, :runtime_id, :session_id, :through_version, :after_version]) and
      cursor.version == 1 and cursor.runtime_id == runtime and cursor.session_id == session and
      positive_version?(through) and version?(after_version) and after_version <= through
  end

  defp valid_cursor?(
         %{resume_after_version: after_version, prefix_token: token} = cursor,
         runtime,
         session
       ) do
    closed?(cursor, [:version, :runtime_id, :session_id, :resume_after_version, :prefix_token]) and
      cursor.version == 1 and cursor.runtime_id == runtime and cursor.session_id == session and
      positive_version?(after_version) and is_binary(token) and byte_size(token) == 32
  end

  defp valid_cursor?(_, _, _), do: false

  defp scope(store, runtime, session) do
    case Store.creation_provenance(store, runtime, %{kind: :session, session_id: session}) do
      {:historical, _} -> :ok
      :absent -> {:error, :session_absent}
      :conflict -> {:error, :invalid_query}
      _ -> {:error, :history_unavailable}
    end
  end

  defp head(store, session) do
    case Store.ownership_head(store, session, "session") do
      {:ok, %{journal_version: version}} ->
        if positive_version?(version), do: {:ok, version}, else: {:error, :invalid_history}

      :absent ->
        {:error, :invalid_history}

      _ ->
        {:error, :history_unavailable}
    end
  end

  defp cut(_store, _runtime, _session, nil, head), do: {:ok, head, 0, nil}

  defp cut(
         store,
         _runtime,
         session,
         %{resume_after_version: after_version, prefix_token: expected},
         head
       ) do
    with true <- after_version <= head,
         {:ok, [record]} <- load(store, session, after_version - 1, 1),
         {:ok, actual} <- boundary_token(record),
         true <- actual == expected,
         {:ok, _} <- projection(session, record) do
      {:ok, head, after_version, expected}
    else
      false -> {:error, :invalid_query}
      {:ok, _} -> {:error, :invalid_history}
      error -> error
    end
  end

  defp cut(
         store,
         _runtime,
         session,
         %{through_version: through, after_version: after_version},
         head
       ) do
    cond do
      through > head ->
        {:error, :invalid_query}

      after_version < through ->
        {:ok, through, after_version, nil}

      true ->
        case load(store, session, after_version - 1, 1) do
          {:ok, [record]} ->
            with true <- bounded_stamp?(record),
                 {:ok, _} <- projection(session, record) do
              {:ok, through, after_version, prefix_token(record)}
            else
              _ -> {:error, :invalid_history}
            end

          {:ok, _} ->
            {:error, :invalid_history}

          error ->
            error
        end
    end
  end

  defp records(_store, _session, through, through, _limit, _boundary), do: {:ok, []}

  defp records(store, session, after_version, through, limit, _boundary) do
    case load(store, session, after_version, min(limit, through - after_version)) do
      {:ok, []} -> {:error, :invalid_history}
      result -> result
    end
  end

  defp load(store, session, after_version, limit) do
    case Store.load_records(store, session, after_version, limit) do
      {:ok, records} -> {:ok, records}
      {:error, :invalid_store_page} -> {:error, :invalid_history}
      _ -> {:error, :history_unavailable}
    end
  end

  defp scan([], runtime, session, through, scanned, token, reversed),
    do: {:ok, page(runtime, session, through, scanned, token, reversed)}

  defp scan([record | rest], runtime, session, through, scanned, token, reversed) do
    with true <- bounded_stamp?(record),
         true <- record.journal_version == scanned + 1 and record.journal_version <= through,
         {:ok, projection} <- projection(session, record) do
      next_rows =
        if projection,
          do: [Map.put(projection, :journal_version, record.journal_version) | reversed],
          else: reversed

      next_token = prefix_token(record)
      candidate = page(runtime, session, through, record.journal_version, next_token, next_rows)

      cond do
        projection && :erlang.external_size(hd(next_rows), [:deterministic]) > 65_536 ->
          {:error, :invalid_history}

        :erlang.external_size({:ok, candidate}, [:deterministic]) <= @page_bytes ->
          scan(rest, runtime, session, through, record.journal_version, next_token, next_rows)

        token != nil ->
          {:ok, page(runtime, session, through, scanned, token, reversed)}

        true ->
          {:error, :invalid_history}
      end
    else
      _ -> {:error, :invalid_history}
    end
  end

  defp page(runtime, session, through, scanned, token, reversed) do
    next =
      if scanned == through,
        do: nil,
        else: %{
          version: 1,
          runtime_id: runtime,
          session_id: session,
          through_version: through,
          after_version: scanned
        }

    %{
      version: 1,
      runtime_id: runtime,
      session_id: session,
      through_version: through,
      scanned_through: scanned,
      prefix_token: token,
      rows: Enum.reverse(reversed),
      next_cursor: next
    }
  end

  defp prefix_token(record) do
    payload = :erlang.term_to_binary(record.payload, [:deterministic])
    tuple = {record.journal_version, record.owner_epoch, record.owner_incarnation_id, payload}
    :crypto.hash(:sha256, :erlang.term_to_binary(tuple, [:deterministic]))
  end

  defp boundary_token(record) do
    if bounded_stamp?(record),
      do: {:ok, prefix_token(record)},
      else: {:error, :invalid_history}
  end

  defp projection(session, %{payload: %{kind: kind}} = record) when kind in @effect_kinds,
    do:
      owned_projection(record, fn ->
        SessionState.effect_history_projection(session, record.payload)
      end)

  defp projection(_session, %{payload: %{kind: kind} = payload} = record)
       when kind in ["session_genesis_v2", "session_genesis_v3"] do
    with true <-
           record.journal_version == 1 and record.owner_epoch == 0 and
             is_nil(record.owner_incarnation_id),
         {:ok, ^payload} <- SessionGenesis.normalize(payload),
         do: {:ok, nil},
         else: (_ -> {:error, :invalid_history})
  end

  defp projection(_session, record), do: owned_projection(record, fn -> neutral(record) end)

  defp owned_projection(record, project) do
    if positive_version?(record.owner_epoch) and identifier?(record.owner_incarnation_id),
      do: project.(),
      else: {:error, :invalid_history}
  end

  defp neutral(%{payload: %{kind: kind} = payload} = record) do
    valid =
      case kind do
        kind when kind in ["model_attempt_opened_v1", "maintenance_attempt_opened_v1"] ->
          ProviderAttempt.validate_opened(payload) == :ok

        kind when kind in ["model_attempt_settled_v3", "maintenance_attempt_settled_v3"] ->
          ProviderAttempt.validate_settled(payload) == :ok

        kind
        when kind in ["model_termination_admitted_v1", "maintenance_termination_admitted_v1"] ->
          ProviderAttempt.validate_termination(payload) == :ok

        kind when kind in ["command_admitted", "model_question_abort_admitted_v2"] ->
          command_shape?(payload) and
            (kind == "command_admitted" or
               (payload["command_type"] == "abort" and payload["admission"] == "accepted"))

        _ ->
          case Map.fetch(@neutral_shapes, kind) do
            {:ok, {required, optional}} ->
              closed?(payload, [:kind | required], optional) and neutral_values?(record)

            :error ->
              false
          end
      end

    if valid, do: {:ok, nil}, else: {:error, :invalid_history}
  end

  defp command_shape?(payload) do
    extras =
      case {payload["admission"], payload["command_type"]} do
        {"accepted", type} when type in ~w(steer follow_up) ->
          ~w(run_id content)

        {"accepted", "abort"} ->
          ~w(run_id)

        {"accepted", "interaction_answer"} ->
          ~w(interaction_id choice_id answer_digest)

        {"rejected_" <> _, type}
        when type in ~w(prompt steer follow_up abort interaction_answer) ->
          []

        _ ->
          nil
      end

    is_list(extras) and closed?(payload, [:kind | @command_keys ++ extras]) and
      identifier?(payload["command_id"]) and digest?(payload["command_digest"])
  end

  defp neutral_values?(%{payload: %{kind: "owner_advanced"} = payload} = record) do
    payload["owner_epoch"] == record.owner_epoch and
      payload["prior_owner_epoch"] == record.owner_epoch - 1 and
      payload["owner_incarnation_id"] == record.owner_incarnation_id and
      identifier?(payload["owner_transaction_id"])
  end

  defp neutral_values?(%{payload: %{kind: kind} = payload})
       when kind in ~w(model_request_committed model_request_committed_v2 model_request_committed_resources_v1 model_request_committed_resources_v2) do
    valid_request?(payload)
  end

  # Concept: private coverage passes maintenance without projecting effects.
  # Technical depth: this bounded reader validates each closed row locally.
  # Configuration and request constructors bind their own exact bytes; only
  # full SessionState replay proves adjacency, range ownership and parent limits.
  # A page never acquires an owner or reconstructs an unbounded session prefix.
  defp neutral_values?(%{payload: %{kind: "maintenance_episode_admitted_v1"} = payload}) do
    capture = payload["maintenance_configuration"]
    bounds = payload["bounds"]

    with %{"budget_origins" => %{"parent" => %{} = origins}} <- capture,
         parent =
           Map.take(capture, ~w(configuration_version context_token_budget system_class_tokens)),
         :ok <-
           MaintenanceConfiguration.validate_capture(
             capture,
             Map.put(parent, "budget_origins", origins)
           ),
         true <- capture["configuration_version"] == payload["configuration_version"],
         true <- closed?(bounds, ~w(max_turns token_budget deadline_ms max_attempts run_deadline)),
         {:ok, _} <-
           Bounds.declare(%{
             max_turns: bounds["max_turns"],
             token_budget: bounds["token_budget"],
             deadline_ms: bounds["deadline_ms"]
           }) do
      Enum.all?(~w(episode_id run_id staging_turn_id), &identifier?(payload[&1])) and
        payload["trigger"] in ~w(ordinary_limit thinking_headroom) and
        valid_episode_targets?(payload) and payload["origin"] == "automatic" and
        bounds["max_attempts"] == 4 and
        (is_nil(bounds["run_deadline"]) or version?(bounds["run_deadline"])) and
        version?(payload["admitted_at"]) and version?(payload["preparation_deadline"]) and
        payload["preparation_deadline"] == payload["admitted_at"] + 60_000 and
        payload["attempts"] == 0 and payload["summary_ordinal"] == 1 and
        is_nil(payload["checkpoint_id"]) and
        payload["usage"] == %{
          "attempts" => 0,
          "reported_tokens" => 0,
          "estimated_tokens" => 0,
          "total_tokens" => 0
        }
    else
      _ -> false
    end
  end

  defp neutral_values?(%{payload: %{kind: "maintenance_request_committed_v1"} = payload}) do
    with true <- valid_request?(payload),
         request = payload["request"],
         [%{"role" => "system"}, %{"role" => "user", "content" => source}] <- request["messages"],
         true <- is_binary(source) and byte_size(source) in 1..16_384,
         true <- payload["source_digest"] == LoopexProtocol.Canonical.digest_bytes(source),
         range = payload["covered_range"],
         true <-
           closed?(range, ~w(unit_count record_count source_count first last first_kept digest)) do
      Enum.all?(~w(episode_id operation_id), &identifier?(payload[&1])) and
        positive_version?(payload["summary_ordinal"]) and payload["purpose"] == "compaction" and
        positive_version?(payload["configuration_version"]) and
        positive_version?(payload["captured_session_version"]) and
        payload["strategy_revision"] == 3 and positive_version?(payload["eligible_unit_count"]) and
        positive_version?(range["unit_count"]) and
        range["unit_count"] <= payload["eligible_unit_count"] and
        positive_version?(range["record_count"]) and positive_version?(range["source_count"]) and
        range["record_count"] <= range["source_count"] and digest?(range["digest"]) and
        Enum.all?(~w(first last first_kept), &is_map(range[&1])) and
        is_boolean(payload["source_excerpted"]) and version?(payload["staged_at"]) and
        request["tools"] == [] and is_nil(request["continuation"]) and
        request["sampling"]["max_tokens"] == 1_024 and request["sampling"]["reasoning"] == "none"
    else
      _ -> false
    end
  end

  defp neutral_values?(%{payload: %{kind: "compaction_checkpoint_committed_v1"} = payload}) do
    range = payload["covered_range"]
    lineage = payload["lineage"]

    Enum.all?(~w(checkpoint_id episode_id run_id), &identifier?(payload[&1])) and
      positive_version?(payload["summary_ordinal"]) and version?(payload["committed_at"]) and
      closed?(lineage, ~w(session_id through_run_id)) and identifier?(lineage["session_id"]) and
      lineage["through_run_id"] == payload["run_id"] and
      closed?(range, ~w(unit_count record_count source_count first last first_kept digest)) and
      Enum.all?(~w(unit_count record_count source_count), &positive_version?(range[&1])) and
      range["record_count"] <= range["source_count"] and digest?(range["digest"]) and
      Enum.all?(~w(first last first_kept), &is_map(range[&1])) and
      valid_consumed_checkpoint_range?(payload, range) and
      Loopex.Runtime.CompactionSummary.validate_prior(payload["summary"]) == :ok and
      payload["summary"]["covered_range_digest"] == range["digest"] and
      payload["strategy"] == "loopex.compaction.reference" and payload["strategy_revision"] == 3 and
      identifier?(payload["model"]) and payload["reasoning"] == "none" and
      positive_version?(payload["configuration_version"]) and digest?(payload["source_digest"]) and
      closed?(payload["usage"], ~w(attempts reported_tokens estimated_tokens total_tokens)) and
      Enum.all?(Map.values(payload["usage"]), &version?/1) and
      payload["usage"]["total_tokens"] ==
        payload["usage"]["reported_tokens"] + payload["usage"]["estimated_tokens"]
  end

  defp neutral_values?(%{payload: %{kind: "maintenance_episode_terminal_v1"} = payload}) do
    identifier?(payload["episode_id"]) and
      (is_nil(payload["observed_at"]) or version?(payload["observed_at"])) and
      (match?({:ok, _}, CompactResult.encode_wire(payload["result"])) or
         parent_turn_bound_result?(payload["result"]))
  end

  defp neutral_values?(%{payload: %{kind: "context_admission_refused_v2"} = payload}) do
    case {Map.fetch(payload, "project_resource_count"), Map.fetch(payload, "resource_pack_count")} do
      {:error, :error} -> true
      {{:ok, project}, {:ok, resources}} -> version?(project) and version?(resources)
      _ -> false
    end
  end

  defp neutral_values?(_record), do: true

  # Concept: captured headroom remains private evidence on each bounded page.
  # Technical depth: this reader checks the closed target generation and numeric
  # domains. Full reducer replay derives the values from the ordinary run's
  # configuration; the summarizer capture may have a smaller input ceiling.
  defp valid_episode_targets?(%{"targets" => nil, "trigger" => "ordinary_limit"}), do: true

  defp valid_episode_targets?(%{"targets" => targets}) do
    closed?(targets, ~w(revision record_target input_target)) and
      targets["revision"] == "loopex.thinking_headroom.v1" and
      targets["record_target"] == 32_768 and positive_version?(targets["input_target"])
  end

  # Concept: cumulative checkpoints preserve a strictly smaller new raw cut.
  # Technical depth: this neutral reader checks closed ranges, identities,
  # advancing counts and a shared last/first-kept boundary. Full State replay
  # independently authenticates the prior chain and hashes original records.
  defp valid_consumed_checkpoint_range?(payload, range) do
    consumed = payload["consumed_range"]
    prior = payload["prior_checkpoint_id"]

    if is_nil(prior) do
      consumed == range
    else
      identifier?(prior) and prior != payload["checkpoint_id"] and
        closed?(consumed, ~w(unit_count record_count source_count first last first_kept digest)) and
        Enum.all?(~w(unit_count record_count source_count), &positive_version?(consumed[&1])) and
        consumed["record_count"] <= consumed["source_count"] and digest?(consumed["digest"]) and
        Enum.all?(~w(first last first_kept), &is_map(consumed[&1])) and
        consumed["unit_count"] < range["unit_count"] and
        consumed["record_count"] <= range["record_count"] and
        consumed["source_count"] < range["source_count"] and
        consumed["last"] == range["last"] and consumed["first_kept"] == range["first_kept"]
    end
  end

  # Concept: a run-owned episode retains the parent's turn-bound vocabulary.
  # Technical depth: standalone compact has max_attempts instead. This private
  # reader validates the existing parent result without changing the standalone
  # wire codec; full reducer replay authenticates the observed ledger and limit.
  defp parent_turn_bound_result?(result) do
    with true <- closed?(result, ~w(disposition checkpoint_id failure usage cleanup)),
         true <- result["disposition"] == "failed",
         true <- is_nil(result["checkpoint_id"]) or identifier?(result["checkpoint_id"]),
         true <- result["cleanup"] == "confirmed",
         failure = result["failure"],
         true <-
           closed?(
             failure,
             ~w(category retryable bound observed declared_limit accounting_source)
           ),
         true <- failure["category"] == "bound_reached" and failure["retryable"] == false,
         true <- failure["bound"] == "max_turns",
         true <- version?(failure["observed"]) and positive_version?(failure["declared_limit"]),
         true <- failure["observed"] >= failure["declared_limit"],
         true <- failure["accounting_source"] in [nil, "reported", "estimated"],
         usage = result["usage"],
         true <- closed?(usage, ~w(attempts reported_tokens estimated_tokens total_tokens)),
         true <- Enum.all?(Map.values(usage), &version?/1) do
      usage["total_tokens"] == usage["reported_tokens"] + usage["estimated_tokens"]
    else
      _ -> false
    end
  end

  defp valid_request?(payload) do
    encoded = payload["request"]

    if closed?(encoded, Enum.map(@request_fields, &Atom.to_string/1)) do
      decoded = Map.new(@request_fields, &{&1, Map.fetch!(encoded, Atom.to_string(&1))})

      Model.validate_request(decoded) == :ok and
        decoded.staged_request_digest == payload["staged_request_digest"]
    else
      false
    end
  end

  defp closed?(map, required, optional \\ []),
    do:
      is_map(map) and not is_struct(map) and Enum.all?(required, &Map.has_key?(map, &1)) and
        Map.keys(map) -- (required ++ optional) == []

  defp identifier?(value), do: is_binary(value) and byte_size(value) in 1..256

  defp bounded_stamp?(record),
    do:
      positive_version?(record.journal_version) and version?(record.owner_epoch) and
        (is_nil(record.owner_incarnation_id) or identifier?(record.owner_incarnation_id))

  defp version?(value), do: is_integer(value) and value >= 0 and value <= @uint64_max
  defp positive_version?(value), do: version?(value) and value > 0

  defp digest?(value),
    do: is_binary(value) and byte_size(value) == 64 and Regex.match?(~r/\A[0-9a-f]{64}\z/, value)
end
