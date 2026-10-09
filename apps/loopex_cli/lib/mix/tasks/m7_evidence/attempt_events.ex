defmodule Mix.Tasks.Loopex.M7Evidence.AttemptEvents do
  @moduledoc """
  ## Concept

  Validate the current six-variant attempts event grammar before a private
  evidence producer relies on a framed body. A valid event grants no ownership,
  evidence completeness, reviewed verdict, retry or dispatch authority.

  ## Technical depth

  ADR 0057 fixes closed members, bounded UTF-8 identities and references, exact
  ownership epochs, local preceding-head joins and case-state relations. This
  codec reuses AttemptFrames for canonical JSON, nested duplicate refusal,
  SHA-256 coverage and the 65,536-byte envelope cap. Encode returns the existing
  LF-terminated record; decode accepts its complete canonical bytes before LF.
  Ownership verification first authenticates the complete chain with optional
  committed-head anchoring, then folds the same decoded bodies. It projects
  genesis/designation, succession, pending relinquishment and exact acceptance,
  checking each case's current writer tuple. Incomplete tails remain unresolved.
  Case-history verification reuses that ordered ownership result, retaining
  original case records through the consumed linear transitions. Repeated
  pre-dispatch observations, additional reviews and changed review evidence
  return an explicit unresolved projection with every original record retained.
  Case-evidence composition checks caller-supplied complete reference bytes,
  preserving that projection and reporting unavailable evidence without
  returning the supplied bytes or granting a reviewed verdict.
  Lane-history verification selects the greatest committed anchor and joins
  consumed-case and post-head barriers before proposing a single-lane
  continuation. Its trusted in-memory selection retains original pass histories
  and only recorded pre-dispatch rows; missing invocation, grouped-subcase,
  head-recording or authority joins remain unresolved. Fresh full invocations
  cannot bypass consumed matrix histories. This performs no IO, tail recovery,
  evidence dereferencing or manifest admission. Matching handoff references do
  not prove actual
  quiescence, custody or authority; no projection grants dispatch permission.
  """

  alias Mix.Tasks.Loopex.M7Evidence.AttemptFrames
  alias Mix.Tasks.Loopex.M7Evidence.AttemptHeads

  @epoch_max 18_446_744_073_709_551_615
  @genesis Enum.sort(~w(kind version campaign_id codec_version))
  @designated Enum.sort(~w(kind version writer_id host_id ownership_epoch))
  @relinquished Enum.sort(
                  ~w(kind version writer_id host_id ownership_epoch destination_writer_id destination_host_id handoff_id preceding_head quiescence)
                )
  @accepted Enum.sort(
              ~w(kind version writer_id host_id ownership_epoch source_writer_id source_host_id source_ownership_epoch handoff_id relinquishment_head quiescence source_revocation transfer)
            )
  @succession Enum.sort(
                ~w(kind version writer_id host_id ownership_epoch predecessor_head prior_rows unavailable_interval disposition)
              )
  @case_keys Enum.sort(
               ~w(kind version writer_id host_id ownership_epoch manifest_digest candidate_sha lane_id logical_matrix_id case_key subcase_key specification_digest attempt_id state mechanical_result verdict evidence diagnosis disposition reviewer_id authorized_candidate_sha authorization_evidence)
             )
  @mechanical ~w(pass required_action_absent assertion_failed evidence_incomplete_pre_dispatch evidence_incomplete_post_dispatch provider_environment_failure)
  @verdicts ~w(pass product_failure model_nonconformance evidence_unavailable environment_failure)

  @doc false
  def encode(campaign, sequence, previous, body) do
    with true <- event?(campaign, sequence, previous, body),
         {:ok, bytes, record} <- AttemptFrames.encode(campaign, sequence, previous, body) do
      {:ok, bytes, record}
    else
      _ -> {:error, :invalid_attempt_event}
    end
  end

  @doc false
  def decode(bytes) do
    with {:ok, record} <- AttemptFrames.decode(bytes),
         true <-
           event?(
             record["campaign_id"],
             record["sequence"],
             record["previous_digest"],
             record["body"]
           ) do
      {:ok, record}
    else
      _ -> {:error, :invalid_attempt_event}
    end
  end

  @doc false
  def verify_ownership(bytes) do
    with {:ok, _head} <- AttemptFrames.verify(bytes) do
      ownership_projection(bytes)
    end
  end

  @doc false
  def verify_ownership(bytes, committed_head) do
    with {:ok, _head} <- AttemptFrames.verify(bytes, committed_head) do
      ownership_projection(bytes)
    end
  end

  @doc false
  def verify_case_history(bytes) do
    with {:ok, ownership} <- verify_ownership(bytes) do
      case_projection(bytes, ownership)
    end
  end

  @doc false
  def verify_case_history(bytes, committed_head) do
    with {:ok, ownership} <- verify_ownership(bytes, committed_head) do
      case_projection(bytes, ownership)
    end
  end

  @doc false
  def verify_case_evidence(bytes, reference_bytes) do
    with {:ok, projection} <- verify_case_history(bytes) do
      case_evidence(projection, reference_bytes)
    end
  end

  @doc false
  def verify_case_evidence(bytes, committed_head, reference_bytes) do
    with {:ok, projection} <- verify_case_history(bytes, committed_head) do
      case_evidence(projection, reference_bytes)
    end
  end

  # Concept: matching complete bytes adds no execution or review authority.
  # Technical depth: check every original case record, including consumed
  # predecessors, against its own digest. The caller retains byte custody.
  # Report only the first bounded reference failure beside the original history;
  # null post-dispatch evidence never inherits an earlier execution-path proof.
  defp case_evidence(projection, reference_bytes)
       when is_map(reference_bytes) and not is_struct(reference_bytes) do
    Enum.reduce_while(projection.records, {:ok, projection}, fn record, result ->
      body = record["body"]

      if is_nil(body["evidence"]) do
        {:halt, evidence_unavailable(projection, record, "evidence", nil, :absent_evidence)}
      else
        references =
          Enum.map(body["evidence"], &{"evidence", &1}) ++
            Enum.flat_map(~w(diagnosis disposition authorization_evidence), fn member ->
              if is_nil(body[member]), do: [], else: [{member, body[member]}]
            end)

        unavailable =
          Enum.find_value(references, fn {member, reference} ->
            case reference_bytes_status(reference, reference_bytes) do
              :ok -> nil
              reason -> {member, reference, reason}
            end
          end)

        case unavailable do
          nil ->
            {:cont, result}

          {member, reference, reason} ->
            {:halt, evidence_unavailable(projection, record, member, reference, reason)}
        end
      end
    end)
  end

  defp case_evidence(projection, _reference_bytes),
    do: evidence_unavailable(projection, nil, nil, nil, :invalid_reference_bytes)

  defp reference_bytes_status(reference, reference_bytes) do
    case Map.fetch(reference_bytes, reference["reference"]) do
      {:ok, bytes} when is_binary(bytes) ->
        digest = Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
        if digest == reference["sha256"], do: :ok, else: :digest_mismatch

      {:ok, _nonbinary} ->
        :nonbinary_reference_bytes

      :error ->
        :missing_reference_bytes
    end
  end

  defp evidence_unavailable(projection, record, member, reference, reason) do
    {:unavailable,
     %{
       case_history: projection,
       head: if(is_nil(record), do: nil, else: Map.take(record, ~w(campaign_id sequence digest))),
       member: member,
       reference: reference,
       reason: reason
     }}
  end

  @doc false
  def verify_lane_history(bytes, concept, campaign, selection, mode) do
    with {:ok, head} <- AttemptHeads.select(concept, campaign),
         {:ok, projection} <- verify_case_history(bytes, head),
         true <- mode in [:new, :continue] and lane_selection?(selection) do
      lane_projection(projection, head, selection, mode)
    else
      false -> {:error, :invalid_attempt_lane_selection}
      other -> other
    end
  end

  # Concept: Continuation preserves consumed work instead of proposing a retry.
  # Technical depth: The private selection is trusted composition input, not a
  # persisted manifest or permission. Complete framing/ownership/case replay
  # precedes these negative barriers. Original records and references remain in
  # every result; missing invocation, subcase or authority joins stay unresolved.
  defp lane_projection(projection, head, selection, mode) do
    scope = Map.take(selection, ~w(candidate_sha lane_id logical_matrix_id))

    scoped =
      Enum.filter(projection.histories, fn {locator, _} -> lane_scope(locator) == scope end)

    selected =
      Enum.map(selection["cases"], fn pin ->
        locator = Map.merge(scope, Map.take(pin, ~w(case_key subcase_key)))
        %{pin: pin, history: Map.get(projection.histories, locator)}
      end)

    result = %{
      case_history: projection,
      committed_head: head,
      selection: selection,
      reused: [],
      remaining: [],
      reason: nil
    }

    cond do
      mode == :new and not is_nil(selection["logical_matrix_id"]) and
          Enum.any?(projection.records, fn record ->
            body = record["body"]

            body["candidate_sha"] == selection["candidate_sha"] and
              not is_nil(body["logical_matrix_id"]) and consumed_record?(record)
          end) ->
        lane_stopped(result, :blocked, :fresh_matrix_already_consumed)

      mode == :new and Enum.any?(projection.records, &post_head_consumed?(&1, head)) ->
        lane_stopped(result, :blocked, :post_head_consumed_case)

      Enum.any?(selected, &selection_pin_changed?(&1, selection)) ->
        lane_stopped(result, :blocked, :attempt_selection_pin_mismatch)

      length(scoped) != Enum.count(selected, &(not is_nil(&1.history))) ->
        lane_stopped(result, :unresolved, :unselected_lane_history)

      Enum.any?(scoped, fn {_, history} -> consumed_failure?(history) end) ->
        lane_stopped(result, :blocked, :consumed_lane_failure)

      not is_nil(selection["logical_matrix_id"]) and
          Enum.any?(projection.histories, fn {locator, history} ->
            locator["candidate_sha"] == selection["candidate_sha"] and
              locator["logical_matrix_id"] == selection["logical_matrix_id"] and
                consumed_failure?(history)
          end) ->
        lane_stopped(result, :blocked, :consumed_matrix_failure)

      not is_nil(projection.ownership.pending) ->
        lane_stopped(result, :unresolved, :pending_writer_handoff)

      is_nil(projection.ownership.owner) ->
        lane_stopped(result, :unresolved, :writer_designation_unavailable)

      prior_lane_failure?(projection, scope) ->
        lane_stopped(result, :unresolved, :prior_failure_authority_join_required)

      not is_nil(selection["logical_matrix_id"]) ->
        lane_stopped(result, :unresolved, :matrix_invocation_join_required)

      mode == :new and scoped != [] ->
        lane_stopped(result, :blocked, :lane_continuation_required)

      mode == :new ->
        {:ok, %{result | remaining: selected}}

      scoped == [] ->
        lane_stopped(result, :unresolved, :lane_history_unavailable)

      Enum.any?(projection.records, fn record ->
        body = record["body"]

        body["candidate_sha"] == selection["candidate_sha"] and
          lane_scope(body) != scope and
            post_head_consumed?(record, head)
      end) ->
        lane_stopped(result, :unresolved, :multi_lane_invocation_join_required)

      Enum.any?(selected, &is_nil(&1.history)) ->
        lane_stopped(result, :unresolved, :not_dispatched_evidence_unavailable)

      Enum.any?(selected, fn row ->
        row.history.state == "not_dispatched" and
            List.last(row.history.records)["sequence"] <= head["sequence"]
      end) ->
        lane_stopped(result, :unresolved, :head_recorded_lane_join_required)

      true ->
        suspended_lane(result, selected)
    end
  end

  defp suspended_lane(result, selected) do
    {reused, remaining} = Enum.split_while(selected, &completed_pass?(&1.history))

    cond do
      remaining == [] ->
        lane_stopped(result, :blocked, :lane_already_ended)

      Enum.any?(remaining, &completed_pass?(&1.history)) ->
        lane_stopped(result, :unresolved, :noncontiguous_case_order)

      Enum.any?(remaining, fn pending ->
        Enum.any?(reused, &(&1.pin["case_key"] == pending.pin["case_key"]))
      end) ->
        lane_stopped(result, :unresolved, :grouped_subcase_join_required)

      true ->
        {:ok, %{result | reused: reused, remaining: remaining}}
    end
  end

  defp selection_pin_changed?(%{history: nil}, _selection), do: false

  defp selection_pin_changed?(%{pin: pin, history: history}, selection) do
    first = hd(history.records)["body"]

    first["manifest_digest"] != selection["manifest_digest"] or
      first["specification_digest"] != pin["specification_digest"]
  end

  defp consumed_failure?(history) do
    consumed = Enum.any?(history.records, &consumed_record?/1)
    consumed and not completed_pass?(history)
  end

  defp completed_pass?(history) do
    completed = Enum.find(history.records, &(&1["body"]["state"] == "completed"))
    latest = List.last(history.records)["body"]

    not is_nil(completed) and completed["body"]["mechanical_result"] == "pass" and
      latest["verdict"] in [nil, "pass"]
  end

  defp prior_lane_failure?(projection, scope) do
    Enum.any?(projection.histories, fn {locator, history} ->
      locator["lane_id"] == scope["lane_id"] and
        lane_scope(locator) != scope and consumed_failure?(history)
    end)
  end

  defp post_head_consumed?(record, head),
    do: record["sequence"] > head["sequence"] and consumed_record?(record)

  defp consumed_record?(record), do: record["body"]["state"] != "not_dispatched"
  defp lane_scope(body), do: Map.take(body, ~w(candidate_sha lane_id logical_matrix_id))
  defp lane_stopped(result, tag, reason), do: {tag, %{result | reason: reason}}

  defp lane_selection?(selection) do
    closed?(selection, ~w(candidate_sha cases lane_id logical_matrix_id manifest_digest)) and
      git?(selection["candidate_sha"]) and identity?(selection["lane_id"]) and
      nullable?(selection["logical_matrix_id"], &identity?/1) and
      digest?(selection["manifest_digest"]) and selection["cases"] != [] and
      lane_cases?(selection["cases"], MapSet.new())
  end

  defp lane_cases?([], _seen), do: true

  defp lane_cases?([pin | rest], seen) do
    if closed?(pin, ~w(case_key specification_digest subcase_key)) and
         identity?(pin["case_key"]) and nullable?(pin["subcase_key"], &identity?/1) and
         digest?(pin["specification_digest"]) do
      key = Map.take(pin, ~w(case_key subcase_key))
      not MapSet.member?(seen, key) and lane_cases?(rest, MapSet.put(seen, key))
    else
      false
    end
  end

  defp lane_cases?(_, _seen), do: false

  # Concept: A consumed attempt retains its original result and all authors.
  # Technical depth: The locator separates independent candidate/lane/matrix/
  # case/subcase rows; manifest and specification remain immutable within it.
  # Every original record retains its envelope and body. Unspecified repeated
  # observations or reviews stop semantic projection, never replace prior facts.
  defp case_projection(bytes, ownership) do
    case_lines(bytes, %{ownership: ownership, histories: %{}, records: [], unresolved: []})
  end

  defp case_lines(<<>>, projection) do
    tag = if projection.unresolved == [], do: :ok, else: :unresolved
    {tag, projection}
  end

  defp case_lines(bytes, projection) do
    {length, 1} = :binary.match(bytes, "\n")
    <<line::binary-size(^length), "\n", remaining::binary>> = bytes

    with {:ok, record} <- decode(line),
         {:ok, projection} <- case_record(record, projection) do
      case_lines(remaining, projection)
    end
  end

  defp case_record(%{"body" => %{"kind" => "case"} = body} = record, projection) do
    locator = Map.take(body, ~w(candidate_sha lane_id logical_matrix_id case_key subcase_key))
    history = Map.get(projection.histories, locator)

    with {:ok, history, reason} <- case_transition(history, record) do
      unresolved =
        if is_nil(reason),
          do: projection.unresolved,
          else:
            projection.unresolved ++
              [%{head: Map.take(record, ~w(campaign_id sequence digest)), reason: reason}]

      {:ok,
       %{
         projection
         | histories: Map.put(projection.histories, locator, history),
           records: projection.records ++ [record],
           unresolved: unresolved
       }}
    end
  end

  defp case_record(_, projection), do: {:ok, projection}

  defp case_transition(nil, %{"body" => %{"state" => state}} = record)
       when state in ["not_dispatched", "started"] do
    {:ok, %{state: state, records: [record], unresolved: false}, nil}
  end

  defp case_transition(nil, _), do: {:error, :invalid_attempt_case_history}

  defp case_transition(history, %{"body" => body} = record) do
    first = hd(history.records)["body"]
    consumed = Enum.find(history.records, &(&1["body"]["state"] == "started"))
    completed = Enum.find(history.records, &(&1["body"]["state"] == "completed"))

    if Map.take(body, ~w(manifest_digest specification_digest)) ==
         Map.take(first, ~w(manifest_digest specification_digest)) and
         (is_nil(consumed) or body["attempt_id"] == consumed["body"]["attempt_id"]) and
         (is_nil(completed) or body["mechanical_result"] == completed["body"]["mechanical_result"]) do
      case_step(history, record)
    else
      {:error, :invalid_attempt_case_history}
    end
  end

  defp case_step(%{unresolved: true} = history, record),
    do: retain_case(history, record, :unresolved_case_history)

  defp case_step(
         %{state: "not_dispatched"} = history,
         %{"body" => %{"state" => "not_dispatched"}} = record
       ),
       do: retain_case(history, record, :repeated_not_dispatched)

  defp case_step(
         %{state: "not_dispatched"} = history,
         %{"body" => %{"state" => "started"}} = record
       ),
       do: retain_case(history, record, nil)

  defp case_step(%{state: "started"} = history, %{"body" => %{"state" => "completed"}} = record),
    do: retain_case(history, record, nil)

  defp case_step(
         %{state: "completed"} = history,
         %{"body" => %{"state" => "reviewed"} = body} = record
       ) do
    original = List.last(history.records)["body"]
    reason = if body["evidence"] == original["evidence"], do: nil, else: :changed_review_evidence
    retain_case(history, record, reason)
  end

  defp case_step(%{state: "reviewed"} = history, %{"body" => %{"state" => "reviewed"}} = record),
    do: retain_case(history, record, :additional_review)

  defp case_step(
         %{state: "reviewed"} = history,
         %{"body" => %{"state" => "authorized_next_candidate"} = body} = record
       ) do
    original = List.last(history.records)["body"]
    retained = ~w(attempt_id mechanical_result verdict reviewer_id evidence)

    if original["verdict"] != "pass" and Map.take(body, retained) == Map.take(original, retained) do
      reason =
        if body["diagnosis"] == original["diagnosis"] and
             (is_nil(original["disposition"]) or body["disposition"] == original["disposition"]),
           do: nil,
           else: :changed_authorization_boundary_references

      retain_case(history, record, reason)
    else
      {:error, :invalid_attempt_case_history}
    end
  end

  defp case_step(_, _), do: {:error, :invalid_attempt_case_history}

  defp retain_case(history, %{"body" => body} = record, reason) do
    {:ok,
     %{
       history
       | state: if(is_nil(reason), do: body["state"], else: history.state),
         records: history.records ++ [record],
         unresolved: history.unresolved or not is_nil(reason)
     }, reason}
  end

  # Concept: This projection checks record ownership, not execution admission.
  # Technical depth: Complete framing precedes body replay. A pending handoff
  # retains the old owner and original relinquishment; acceptance alone advances
  # the tuple. Cases are checked only for that tuple, never their transitions.
  defp ownership_projection(bytes) do
    state = %{head: nil, owner: nil, pending: nil, succession: nil, handoff_ids: MapSet.new()}
    ownership_lines(bytes, state)
  end

  defp ownership_lines(<<>>, state),
    do: {:ok, Map.take(state, [:head, :owner, :pending, :succession])}

  defp ownership_lines(bytes, state) do
    {length, 1} = :binary.match(bytes, "\n")
    <<line::binary-size(^length), "\n", remaining::binary>> = bytes

    with {:ok, record} <- decode(line),
         {:ok, state} <- ownership_record(record, state) do
      ownership_lines(remaining, %{
        state
        | head: Map.take(record, ~w(campaign_id sequence digest))
      })
    end
  end

  defp ownership_record(%{"body" => %{"kind" => "genesis"}}, %{head: nil} = state),
    do: {:ok, state}

  defp ownership_record(_, %{head: nil}), do: {:error, :invalid_attempt_ownership}

  defp ownership_record(
         %{"body" => %{"kind" => "writer_designated"} = body},
         %{head: %{"sequence" => 1}} = state
       ),
       do: {:ok, %{state | owner: owner_tuple(body)}}

  defp ownership_record(_, %{head: %{"sequence" => 1}}),
    do: {:error, :invalid_attempt_ownership}

  defp ownership_record(
         %{"body" => %{"kind" => "writer_accepted"} = body},
         %{pending: %{"head" => relinquishment_head, "body" => original}} = state
       ) do
    if body["writer_id"] == original["destination_writer_id"] and
         body["host_id"] == original["destination_host_id"] and
         body["source_writer_id"] == original["writer_id"] and
         body["source_host_id"] == original["host_id"] and
         body["source_ownership_epoch"] == original["ownership_epoch"] and
         body["ownership_epoch"] == original["ownership_epoch"] + 1 and
         body["handoff_id"] == original["handoff_id"] and
         body["quiescence"] == original["quiescence"] and
         body["relinquishment_head"] == relinquishment_head do
      {:ok, %{state | owner: owner_tuple(body), pending: nil}}
    else
      {:error, :invalid_attempt_ownership}
    end
  end

  defp ownership_record(_, %{pending: pending}) when not is_nil(pending),
    do: {:error, :invalid_attempt_ownership}

  defp ownership_record(
         %{"sequence" => 3, "body" => %{"kind" => "campaign_succession"} = body},
         %{succession: nil} = state
       ) do
    if owner_tuple(body) == state.owner,
      do: {:ok, %{state | succession: body}},
      else: {:error, :invalid_attempt_ownership}
  end

  defp ownership_record(%{"body" => %{"kind" => "case"} = body}, state) do
    if owner_tuple(body) == state.owner,
      do: {:ok, state},
      else: {:error, :invalid_attempt_ownership}
  end

  defp ownership_record(%{"body" => %{"kind" => "writer_relinquished"} = body} = record, state) do
    if owner_tuple(body) == state.owner and
         not MapSet.member?(state.handoff_ids, body["handoff_id"]) do
      pending = %{
        "head" => Map.take(record, ~w(campaign_id sequence digest)),
        "body" => body
      }

      {:ok,
       %{state | pending: pending, handoff_ids: MapSet.put(state.handoff_ids, body["handoff_id"])}}
    else
      {:error, :invalid_attempt_ownership}
    end
  end

  defp ownership_record(_, _), do: {:error, :invalid_attempt_ownership}

  defp owner_tuple(body), do: Map.take(body, ~w(writer_id host_id ownership_epoch))

  defp event?(campaign, sequence, previous, body) do
    identity?(campaign) and positive?(sequence) and is_map(body) and not is_struct(body) and
      body["version"] === 1 and variant?(campaign, sequence, previous, body)
  end

  defp variant?(campaign, sequence, previous, %{"kind" => "genesis"} = body) do
    closed?(body, @genesis) and body["codec_version"] === 1 and
      body["campaign_id"] == campaign and sequence == 1 and is_nil(previous)
  end

  defp variant?(_campaign, sequence, _previous, %{"kind" => "writer_designated"} = body) do
    closed?(body, @designated) and writer?(body) and body["ownership_epoch"] === 1 and
      sequence == 2
  end

  defp variant?(campaign, sequence, previous, %{"kind" => "writer_relinquished"} = body) do
    closed?(body, @relinquished) and writer?(body) and
      identity?(body["destination_writer_id"]) and identity?(body["destination_host_id"]) and
      identity?(body["handoff_id"]) and body["writer_id"] != body["destination_writer_id"] and
      preceding?(body["preceding_head"], campaign, sequence, previous) and
      reference?(body["quiescence"])
  end

  defp variant?(campaign, sequence, previous, %{"kind" => "writer_accepted"} = body) do
    closed?(body, @accepted) and writer?(body) and identity?(body["source_writer_id"]) and
      identity?(body["source_host_id"]) and epoch?(body["source_ownership_epoch"]) and
      body["writer_id"] != body["source_writer_id"] and
      body["ownership_epoch"] == body["source_ownership_epoch"] + 1 and
      identity?(body["handoff_id"]) and
      preceding?(body["relinquishment_head"], campaign, sequence, previous) and
      Enum.all?(~w(quiescence source_revocation transfer), &reference?(body[&1]))
  end

  # Concept: Succession names another campaign without proving its history.
  # Technical depth: The accepted standalone vector is sequence two; first
  # after designation is an ordered replay obligation, not a body shape.
  defp variant?(campaign, _sequence, _previous, %{"kind" => "campaign_succession"} = body) do
    closed?(body, @succession) and writer?(body) and body["ownership_epoch"] === 1 and
      head?(body["predecessor_head"]) and
      body["predecessor_head"]["campaign_id"] != campaign and
      Enum.all?(~w(prior_rows unavailable_interval disposition), &reference?(body[&1]))
  end

  defp variant?(_campaign, _sequence, _previous, %{"kind" => "case"} = body) do
    closed?(body, @case_keys) and writer?(body) and digest?(body["manifest_digest"]) and
      git?(body["candidate_sha"]) and identity?(body["lane_id"]) and
      nullable?(body["logical_matrix_id"], &identity?/1) and identity?(body["case_key"]) and
      nullable?(body["subcase_key"], &identity?/1) and digest?(body["specification_digest"]) and
      nullable?(body["attempt_id"], &identity?/1) and
      nullable?(body["mechanical_result"], &(&1 in @mechanical)) and
      nullable?(body["verdict"], &(&1 in @verdicts)) and
      nullable?(body["evidence"], &evidence?/1) and
      Enum.all?(
        ~w(diagnosis disposition authorization_evidence),
        &nullable?(body[&1], fn value -> reference?(value) end)
      ) and
      nullable?(body["reviewer_id"], &identity?/1) and
      nullable?(body["authorized_candidate_sha"], &git?/1) and case_state?(body)
  end

  defp variant?(_, _, _, _), do: false

  defp case_state?(%{"state" => "not_dispatched"} = body) do
    is_nil(body["attempt_id"]) and
      body["mechanical_result"] in [nil, "evidence_incomplete_pre_dispatch"] and
      not is_nil(body["evidence"]) and body["verdict"] in [nil, "evidence_unavailable"] and
      (is_nil(body["verdict"]) or
         (not is_nil(body["reviewer_id"]) and not is_nil(body["diagnosis"]))) and
      no_authorization?(body)
  end

  defp case_state?(%{"state" => "started"} = body) do
    not is_nil(body["attempt_id"]) and not is_nil(body["evidence"]) and
      Enum.all?(
        ~w(mechanical_result verdict diagnosis disposition reviewer_id authorized_candidate_sha authorization_evidence),
        &is_nil(body[&1])
      )
  end

  defp case_state?(%{"state" => "completed"} = body) do
    post_dispatch?(body) and is_nil(body["verdict"]) and is_nil(body["reviewer_id"]) and
      no_authorization?(body)
  end

  defp case_state?(%{"state" => "reviewed"} = body) do
    post_dispatch?(body) and not is_nil(body["verdict"]) and not is_nil(body["reviewer_id"]) and
      reviewed_result?(body) and no_authorization?(body)
  end

  defp case_state?(%{"state" => "authorized_next_candidate"} = body) do
    post_dispatch?(body) and not is_nil(body["verdict"]) and body["verdict"] != "pass" and
      not is_nil(body["reviewer_id"]) and not is_nil(body["diagnosis"]) and
      not is_nil(body["disposition"]) and not is_nil(body["authorization_evidence"]) and
      not is_nil(body["authorized_candidate_sha"]) and
      body["authorized_candidate_sha"] != body["candidate_sha"]
  end

  defp case_state?(_), do: false

  defp post_dispatch?(body) do
    not is_nil(body["attempt_id"]) and not is_nil(body["mechanical_result"]) and
      body["mechanical_result"] != "evidence_incomplete_pre_dispatch" and
      (not is_nil(body["evidence"]) or
         body["mechanical_result"] == "evidence_incomplete_post_dispatch")
  end

  defp reviewed_result?(%{"verdict" => "pass"} = body),
    do: body["mechanical_result"] == "pass" and not is_nil(body["evidence"])

  defp reviewed_result?(body), do: not is_nil(body["diagnosis"])

  defp no_authorization?(body),
    do: is_nil(body["authorized_candidate_sha"]) and is_nil(body["authorization_evidence"])

  defp writer?(body),
    do:
      identity?(body["writer_id"]) and identity?(body["host_id"]) and
        epoch?(body["ownership_epoch"])

  defp preceding?(head, campaign, sequence, previous) do
    head?(head) and head["campaign_id"] == campaign and head["sequence"] == sequence - 1 and
      head["digest"] == previous
  end

  defp head?(head) do
    closed?(head, ~w(campaign_id digest sequence)) and identity?(head["campaign_id"]) and
      positive?(head["sequence"]) and digest?(head["digest"])
  end

  defp reference?(reference) do
    closed?(reference, ~w(reference sha256)) and digest?(reference["sha256"]) and
      reference_path?(reference["reference"])
  end

  defp reference_path?(value) do
    is_binary(value) and byte_size(value) in 1..4096 and String.valid?(value) and
      not controls?(value) and (absolute_reference?(value) or git_reference?(value))
  end

  defp absolute_reference?("/" <> path),
    do: Enum.all?(String.split(path, "/"), &(&1 not in ["", ".", ".."]))

  defp absolute_reference?(_), do: false

  defp git_reference?(value) do
    path =
      value |> String.split(":", parts: 3) |> List.last() |> String.split("#", parts: 2) |> hd()

    Regex.match?(
      ~r/\Agit:[0-9a-f]{40}:docs\/(?:[A-Za-z0-9._-]+\/)*[A-Za-z0-9._-]+\.md(?:#[a-z0-9-]+)?\z/,
      value
    ) and
      Enum.all?(String.split(path, "/"), &(&1 not in [".", ".."]))
  end

  defp evidence?(value), do: evidence?(value, 0)
  defp evidence?([], count), do: count in 1..64

  defp evidence?([reference | rest], count) when count < 64,
    do: reference?(reference) and evidence?(rest, count + 1)

  defp evidence?(_, _), do: false
  defp nullable?(nil, _predicate), do: true
  defp nullable?(value, predicate), do: predicate.(value)

  defp closed?(value, keys),
    do: is_map(value) and not is_struct(value) and Enum.sort(Map.keys(value)) == keys

  defp positive?(value), do: is_integer(value) and value > 0
  defp epoch?(value), do: is_integer(value) and value in 1..@epoch_max

  defp identity?(value),
    do:
      is_binary(value) and byte_size(value) in 1..256 and String.valid?(value) and
        not controls?(value)

  defp controls?(value), do: Regex.match?(~r/[\x00-\x1f\x7f]/, value)
  defp digest?(value), do: is_binary(value) and Regex.match?(~r/\A[0-9a-f]{64}\z/, value)
  defp git?(value), do: is_binary(value) and Regex.match?(~r/\A[0-9a-f]{40}\z/, value)
end
