defmodule Loopex.Interaction do
  @moduledoc """
  ## Concept

  The question a host policy may ask before it decides, and the answer that
  comes back. An interaction is bounded plain data: one prompt, a short list of
  offered choices, and an expiry. It is durable session state owned by the
  serial session owner, and it authorizes nothing by itself: only a committed
  host-policy allow, evaluated again after the answer, can lead to a grant.

  ## Technical depth

  Accepted ADR 0024 fixes the admitted question family exactly, and this module
  is where that shape is enforced. `kind` is exactly `choice`; the prompt is
  non-empty UTF-8 of at most 2 KiB; there are one to eight choices, each with a
  unique 1-64 byte identifier and a non-empty UTF-8 label of at most 256 bytes;
  and the requested duration is 1 to 600,000 milliseconds. A host may attach its
  own bounded opaque reference, which is retained privately and never projected.
  Anything else is malformed, and a malformed defer resolves the tool decision
  as `policy_unavailable` without creating an interaction at all.

  The three digests this module computes stay distinct from one another and from
  any executor request digest: the policy request the host was asked, the
  validated question it asked back, and the answer that was admitted. They are
  computed over canonical encodings of bounded plain data, so a later reader
  recomputes them from the retained record rather than trusting a stored claim.
  """

  @kind :choice
  @max_prompt_bytes 2_048
  @max_choices 8
  @max_choice_id_bytes 64
  @max_choice_label_bytes 256
  @max_decision_ref_bytes 256
  @max_expires_in_ms 600_000

  @statuses ~w(pending answered denied expired cancelled)

  @typedoc """
  ## Concept

  The validated question, as the runtime retains it.
  """
  @type request :: %{
          required(:kind) => :choice,
          required(:prompt) => binary(),
          required(:choices) => [%{id: binary(), label: binary()}],
          required(:expires_in_ms) => pos_integer(),
          optional(:decision_ref) => binary()
        }

  @doc """
  ## Concept

  The statuses an interaction may hold.

  ## Technical depth

  `answered` means answer evidence is committed and policy resolution is still
  owed; it never means allowed. The sibling policy-decision record holds that,
  and only an allow can lead to a grant.
  """
  @spec statuses() :: [binary()]
  def statuses, do: @statuses

  @doc """
  ## Concept

  The ceilings this question family is bounded by.
  """
  @spec bounds() :: map()
  def bounds do
    %{
      prompt_bytes: @max_prompt_bytes,
      choices: @max_choices,
      choice_id_bytes: @max_choice_id_bytes,
      choice_label_bytes: @max_choice_label_bytes,
      decision_ref_bytes: @max_decision_ref_bytes,
      expires_in_ms: @max_expires_in_ms
    }
  end

  @doc """
  ## Concept

  Validates a host's deferred question, or refuses it.

  ## Technical depth

  Every bound is checked here rather than at the boundary that stores it, so a
  question that reaches the journal has already been proved to be inside the
  admitted family. Keys are the fixed atoms the accepted policy behaviour
  already uses; nothing here converts input to an atom. Duplicate choice
  identifiers are refused, because an answer names a choice by identifier and
  two identical identifiers make an admitted answer ambiguous.
  """
  @spec validate_request(term()) :: {:ok, request()} | {:error, :invalid_interaction_request}
  def validate_request(request) when is_map(request) and not is_struct(request) do
    with :ok <- validate_keys(request),
         :ok <- validate_kind(Map.get(request, :kind)),
         :ok <- validate_prompt(Map.get(request, :prompt)),
         {:ok, choices} <- validate_choices(Map.get(request, :choices)),
         :ok <- validate_expiry(Map.get(request, :expires_in_ms)),
         :ok <- validate_decision_ref(Map.get(request, :decision_ref)) do
      validated = %{
        kind: @kind,
        prompt: Map.fetch!(request, :prompt),
        choices: choices,
        expires_in_ms: Map.fetch!(request, :expires_in_ms)
      }

      case Map.get(request, :decision_ref) do
        nil -> {:ok, validated}
        reference -> {:ok, Map.put(validated, :decision_ref, reference)}
      end
    end
  end

  def validate_request(_request), do: {:error, :invalid_interaction_request}

  @doc """
  ## Concept

  The durable form of a validated question.

  ## Technical depth

  Durable rows carry string-keyed bounded plain data, so the atoms this module
  uses in memory stop at the journal boundary. The host's opaque reference is
  not part of this map: it is retained as a sibling field of the record, which
  is what keeps it out of every projection built from the question itself.
  """
  @spec to_record(request()) :: map()
  def to_record(%{kind: @kind} = request) do
    %{
      "kind" => "choice",
      "prompt" => request.prompt,
      "choices" => Enum.map(request.choices, &%{"id" => &1.id, "label" => &1.label}),
      "expires_in_ms" => request.expires_in_ms
    }
  end

  @doc """
  ## Concept

  Reads a retained question back, refusing anything the family does not admit.

  ## Technical depth

  A recovered owner acts on this, so the same bounds are enforced coming out of
  the journal as going in. A row written by another version, or edited by hand,
  is refused rather than carried: the alternative is an owner asking a question
  it cannot bound or answering one it cannot check.
  """
  @spec from_record(term()) :: {:ok, request()} | {:error, :invalid_interaction_request}
  def from_record(record) when is_map(record) and not is_struct(record) do
    with %{"kind" => "choice", "prompt" => prompt, "choices" => choices} <- record,
         expires_in_ms when is_integer(expires_in_ms) <- Map.get(record, "expires_in_ms"),
         true <- is_list(choices),
         true <- Enum.all?(choices, &is_map/1),
         restored = Enum.map(choices, &%{id: Map.get(&1, "id"), label: Map.get(&1, "label")}),
         true <- Enum.all?(restored, &(is_binary(&1.id) and is_binary(&1.label))) do
      validate_request(%{
        kind: @kind,
        prompt: prompt,
        choices: restored,
        expires_in_ms: expires_in_ms
      })
    else
      _refused -> {:error, :invalid_interaction_request}
    end
  end

  def from_record(_record), do: {:error, :invalid_interaction_request}

  @doc """
  ## Concept

  Whether an answer names one of the choices that were offered.
  """
  @spec offered?(request(), term()) :: boolean()
  def offered?(%{choices: choices}, choice_id) when is_binary(choice_id),
    do: Enum.any?(choices, &(&1.id == choice_id))

  def offered?(_request, _choice_id), do: false

  @doc """
  ## Concept

  The response member core creates for a resumed policy evaluation.

  ## Technical depth

  The host receives its original request byte-identically plus exactly this one
  member: the interaction identity the runtime retained, the exact validated
  question, the admitted answer, and that answer's digest. The runtime has
  already proved the choice was offered; the host may interpret it, and the
  runtime never maps a choice to a grant.
  """
  @spec response_member(binary(), request(), binary()) :: map()
  def response_member(interaction_id, request, choice_id)
      when is_binary(interaction_id) and is_binary(choice_id) do
    answer = %{choice_id: choice_id}

    %{
      interaction_id: interaction_id,
      interaction_request: request,
      answer: answer,
      answer_digest: digest(answer)
    }
  end

  @doc """
  ## Concept

  The public view of an open interaction.

  ## Technical depth

  The host's opaque reference never appears here: it is retained privately, as
  ADR 0024 requires, and a projection that carried it would publish something no
  reader is entitled to. The selected choice appears only after an answer was
  admitted.
  """
  @spec view(map()) :: map()
  def view(record) when is_map(record) do
    %{
      "interaction_id" => record.interaction_id,
      "run_id" => record.run_id,
      "turn" => record.turn,
      "tool_call_id" => record.tool_call_id,
      "status" => record.status,
      "prompt" => record.request.prompt,
      "choices" => Enum.map(record.request.choices, &%{"id" => &1.id, "label" => &1.label}),
      "expires_at" => record.expires_at
    }
    |> then(fn projected ->
      case Map.get(record, :choice_id) do
        nil -> projected
        choice_id -> Map.put(projected, "choice_id", choice_id)
      end
    end)
  end

  @doc """
  ## Concept

  When a question stops being answerable.

  ## Technical depth

  The effective expiry is the earlier of the requested duration from the
  committed creation instant and the run's own deadline, and it is chosen once,
  before the transaction that creates the interaction is attempted. Resolving an
  uncertain commit reuses that same instant rather than recomputing it from a
  later clock, which is what keeps two owners recovering the same creation from
  giving the question two different lifetimes.
  """
  @spec effective_expiry(integer(), pos_integer(), integer() | nil) :: integer()
  def effective_expiry(created_at, expires_in_ms, run_deadline)
      when is_integer(created_at) and is_integer(expires_in_ms) do
    requested = created_at + expires_in_ms
    if is_integer(run_deadline), do: min(requested, run_deadline), else: requested
  end

  @doc """
  ## Concept

  The lowercase hexadecimal SHA-256 of one bounded plain term.

  ## Technical depth

  The encoding is deterministic, so the same term digests the same way in any
  process and after any restart. These digests stay distinct from an executor's
  `canonical_request_digest`: nothing here is ever a dispatch identity.
  """
  @spec digest(term()) :: binary()
  def digest(term) do
    :sha256
    |> :crypto.hash(:erlang.term_to_binary(term, [:deterministic]))
    |> Base.encode16(case: :lower)
  end

  defp validate_keys(request) do
    case Map.keys(request) -- [:kind, :prompt, :choices, :expires_in_ms, :decision_ref] do
      [] -> :ok
      _unknown -> {:error, :invalid_interaction_request}
    end
  end

  defp validate_kind(@kind), do: :ok
  defp validate_kind(_kind), do: {:error, :invalid_interaction_request}

  defp validate_prompt(prompt)
       when is_binary(prompt) and byte_size(prompt) > 0 and byte_size(prompt) <= @max_prompt_bytes do
    if String.valid?(prompt), do: :ok, else: {:error, :invalid_interaction_request}
  end

  defp validate_prompt(_prompt), do: {:error, :invalid_interaction_request}

  defp validate_choices(choices)
       when is_list(choices) and length(choices) >= 1 and length(choices) <= @max_choices do
    with true <- Enum.all?(choices, &valid_choice?/1),
         identifiers = Enum.map(choices, & &1.id),
         true <- identifiers == Enum.uniq(identifiers) do
      {:ok, Enum.map(choices, &%{id: &1.id, label: &1.label})}
    else
      _refused -> {:error, :invalid_interaction_request}
    end
  end

  defp validate_choices(_choices), do: {:error, :invalid_interaction_request}

  defp valid_choice?(choice) when is_map(choice) and not is_struct(choice) do
    id = Map.get(choice, :id)
    label = Map.get(choice, :label)

    Map.keys(choice) -- [:id, :label] == [] and
      is_binary(id) and byte_size(id) >= 1 and byte_size(id) <= @max_choice_id_bytes and
      String.valid?(id) and
      is_binary(label) and byte_size(label) >= 1 and
      byte_size(label) <= @max_choice_label_bytes and String.valid?(label)
  end

  defp valid_choice?(_choice), do: false

  defp validate_expiry(expires_in_ms)
       when is_integer(expires_in_ms) and expires_in_ms >= 1 and
              expires_in_ms <= @max_expires_in_ms,
       do: :ok

  defp validate_expiry(_expires_in_ms), do: {:error, :invalid_interaction_request}

  defp validate_decision_ref(nil), do: :ok

  defp validate_decision_ref(reference)
       when is_binary(reference) and byte_size(reference) <= @max_decision_ref_bytes,
       do: :ok

  defp validate_decision_ref(_reference), do: {:error, :invalid_interaction_request}
end
