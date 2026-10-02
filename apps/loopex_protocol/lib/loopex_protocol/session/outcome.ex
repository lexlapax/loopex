defmodule LoopexProtocol.Session.Outcome do
  @moduledoc """
  ## Concept

  Encode and decode the terminal run object shared by chat barriers and closing
  records. It reports a run ending, including uncertainty, without transcript
  content or a claim about host cleanup.

  ## Technical depth

  ADR 0049 fixes exactly `outcome` and `details`, with closed details for each
  ending. The native object has an atom outcome and binary-keyed details. Wire
  objects have binary keys, canonical decimal quantities and opaque base64url
  reconciliation references. Ordinary turn/token counts retain Core's arbitrary
  nonnegative integer domain; deadline and cleanup quantities retain u64.
  The enclosing presentation owns its byte cap. Existing ask and event codecs
  keep their contracts. No input creates an atom.
  """

  alias LoopexProtocol.Wire

  @u64_max 18_446_744_073_709_551_615
  @observed_max 55_340_232_221_128_654_844
  @outcomes [:completed, :cancelled, :failed, :bound_reached, :outcome_unknown]
  @dimensions ~w(system_class_tokens context_tokens context_record_bytes context_record_depth context_record_cardinality)

  @doc """
  ## Concept

  Project one terminal observation into the closed wire object.

  ## Technical depth

  Missing, extra or non-plain members refuse. The existing two-member deadline
  preflight failure is expanded with its three null fields; an already expanded
  failure must have exactly those five fields. Identities retain their bytes.
  This function neither observes a run nor proves the truth of supplied data.
  """
  @spec encode_wire(term()) :: {:ok, map()} | :error
  def encode_wire(%{outcome: outcome, details: details} = value)
      when map_size(value) == 2 and outcome in @outcomes do
    with {:ok, projected} <- project(outcome, details, :encode) do
      {:ok, %{"outcome" => Atom.to_string(outcome), "details" => projected}}
    end
  end

  def encode_wire(_), do: :error

  @doc """
  ## Concept

  Decode one terminal wire object into exact native quantities and identity bytes.

  ## Technical depth

  Only the five fixed outcome spellings match. Decimal JSON numbers, leading
  zeroes, padded/noncanonical identities and extra members refuse. A terminal
  object cannot represent no ending or host-only cleanup/admission uncertainty.
  """
  @spec decode_wire(term()) :: {:ok, map()} | :error
  def decode_wire(%{"outcome" => name, "details" => details} = value)
      when map_size(value) == 2 do
    with outcome when not is_nil(outcome) <- Enum.find(@outcomes, &(Atom.to_string(&1) == name)),
         {:ok, projected} <- project(outcome, details, :decode) do
      {:ok, %{outcome: outcome, details: projected}}
    else
      _ -> :error
    end
  end

  def decode_wire(_), do: :error

  defp project(outcome, details, mode) when outcome in [:completed, :cancelled] do
    with true <- closed?(details, ~w(cleanup_grace_ms)),
         {:ok, grace} <- quantity(details["cleanup_grace_ms"], mode, 1, @u64_max) do
      {:ok, %{"cleanup_grace_ms" => grace}}
    else
      _ -> :error
    end
  end

  defp project(:outcome_unknown, details, mode) do
    with true <- closed?(details, ~w(reconciliation_ref cleanup_grace_ms)),
         {:ok, grace} <- quantity(details["cleanup_grace_ms"], mode, 1, @u64_max),
         {:ok, ref} <- identity(details["reconciliation_ref"], mode) do
      {:ok, %{"reconciliation_ref" => ref, "cleanup_grace_ms" => grace}}
    else
      _ -> :error
    end
  end

  defp project(:bound_reached, details, mode) do
    with true <-
           closed?(details, ~w(bound observed declared_limit accounting_source cleanup_grace_ms)),
         bound when bound in ~w(max_turns token_budget deadline) <- details["bound"],
         true <- details["accounting_source"] in [nil, "reported", "estimated"],
         maximum = if(bound == "deadline", do: @u64_max, else: :unbounded),
         {:ok, observed} <- quantity(details["observed"], mode, 0, maximum),
         {:ok, limit} <- quantity(details["declared_limit"], mode, 0, maximum),
         {:ok, grace} <- quantity(details["cleanup_grace_ms"], mode, 1, @u64_max) do
      {:ok,
       %{details | "observed" => observed, "declared_limit" => limit, "cleanup_grace_ms" => grace}}
    else
      _ -> :error
    end
  end

  defp project(:failed, details, mode) do
    with true <- closed?(details, ~w(reason failure cleanup_grace_ms)),
         {:ok, grace} <- quantity(details["cleanup_grace_ms"], mode, 1, @u64_max),
         {:ok, failure} <- failure(details["reason"], details["failure"], mode) do
      {:ok, %{details | "failure" => failure, "cleanup_grace_ms" => grace}}
    else
      _ -> :error
    end
  end

  defp failure(reason, nil, _) when reason in ~w(model_call_failed unreadable_model_answer),
    do: {:ok, nil}

  defp failure(
         nil,
         %{"category" => "deadline_preflight_failed", "retryable" => false} = value,
         mode
       ) do
    keys = ~w(category retryable dimension observed limit)

    if (closed?(value, keys) or (mode == :encode and closed?(value, ~w(category retryable)))) and
         Enum.all?(~w(dimension observed limit), &is_nil(Map.get(value, &1))) do
      {:ok,
       %{
         "category" => "deadline_preflight_failed",
         "retryable" => false,
         "dimension" => nil,
         "observed" => nil,
         "limit" => nil
       }}
    else
      :error
    end
  end

  defp failure(
         nil,
         %{"category" => "context_budget_exceeded", "retryable" => false} = value,
         mode
       ) do
    with true <- closed?(value, ~w(category retryable dimension observed limit)),
         true <- value["dimension"] in @dimensions,
         {:ok, observed} <- quantity(value["observed"], mode, 0, @observed_max),
         {:ok, limit} <- quantity(value["limit"], mode, 1, @u64_max) do
      {:ok, %{value | "observed" => observed, "limit" => limit}}
    else
      _ -> :error
    end
  end

  defp failure(_, _, _), do: :error

  defp closed?(value, keys),
    do: is_map(value) and not is_struct(value) and Enum.sort(Map.keys(value)) == Enum.sort(keys)

  defp quantity(value, :encode, minimum, maximum)
       when is_integer(value) and value >= minimum do
    if maximum == :unbounded or value <= maximum,
      do: {:ok, Integer.to_string(value)},
      else: :error
  end

  defp quantity(value, :decode, minimum, maximum) when is_binary(value) do
    if Regex.match?(~r/\A(?:0|[1-9][0-9]*)\z/, value) do
      parsed = String.to_integer(value)

      if parsed >= minimum and (maximum == :unbounded or parsed <= maximum),
        do: {:ok, parsed},
        else: :error
    else
      :error
    end
  end

  defp quantity(_, _, _, _), do: :error

  defp identity(value, :encode) when is_binary(value) and byte_size(value) in 1..65_536,
    do: {:ok, Wire.encode_identity(value)}

  defp identity(value, :decode) when is_binary(value) and byte_size(value) <= 87_382 do
    with {:ok, bytes} <- Wire.identity(value),
         true <- Wire.encode_identity(bytes) == value do
      {:ok, bytes}
    else
      _ -> :error
    end
  end

  defp identity(_, _), do: :error
end
