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
  It performs no IO, ordered replay, tail recovery or evidence dereferencing.
  Cross-record ownership and transition facts remain the later reducer's work.
  """

  alias Mix.Tasks.Loopex.M7Evidence.AttemptFrames

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
