defmodule LoopexProtocol.Session.ModelQuestionEvent do
  @moduledoc """
  ## Concept

  Preserve committed model-question requests and their terminal evidence.
  Text and choice questions reuse the current open-interaction contract.

  ## Technical depth

  Requested data retains fifteen members and five null evidence captures.
  Terminal data retains those members and adds choice_id only for an answered
  choice. Status and disposition agree; exact answer, command identity/digest
  and positive uint64 settlement evidence are checked together. OpenInteraction
  validates the original question; terminal status does not create another open
  question. Envelopes and policy questions stay outside this codec. The existing
  disposition fixes the enclosing event kind; decoding establishes no authority.
  """

  alias LoopexProtocol.Session.OpenInteraction
  alias LoopexProtocol.Wire

  @captures ~w(answer command_digest command_id disposition settlement_sequence)
  @keys ~w(interaction_id run_id turn tool_call_id status prompt choices expires_at producer interaction_kind) ++
          @captures

  @doc """
  ## Concept

  Encode committed native requested-model-question data.

  ## Technical depth

  Require the closed model-only payload and every null capture before delegating
  exact identity, turn, expiry and question validation. No defaults are added.
  """
  @spec encode_requested(term()) :: {:ok, map()} | :error
  def encode_requested(value), do: project(value, &OpenInteraction.encode_wire/1)

  @doc """
  ## Concept

  Decode requested-model-question data without losing numeric or identity bytes.

  ## Technical depth

  Unknown fields, noncanonical quantities, policy branches and nonnull evidence
  refuse. The enclosing event retains its existing envelope and byte ceilings.
  """
  @spec decode_requested(term()) :: {:ok, map()} | :error
  def decode_requested(value), do: project(value, &OpenInteraction.decode_wire/1)

  defp project(value, codec) do
    with true <-
           is_map(value) and not is_struct(value) and
             Enum.sort(Map.keys(value)) == Enum.sort(@keys),
         "model_tool" <- value["producer"],
         "pending" <- value["status"],
         true <- Enum.all?(@captures, &is_nil(value[&1])),
         question <-
           value
           |> Map.drop(@captures ++ ["interaction_kind"])
           |> Map.put("kind", value["interaction_kind"]),
         {:ok, projected} <- codec.(question) do
      {:ok,
       projected
       |> Map.delete("kind")
       |> Map.put("interaction_kind", projected["kind"])
       |> Map.merge(Map.new(@captures, &{&1, nil}))}
    else
      _ -> :error
    end
  end

  @doc """
  ## Concept

  Encode committed terminal model-question data without changing its answer.

  ## Technical depth

  The closed existing answered, declined, expired and cancelled branches retain
  their original question and settlement. Only an answered choice has a top-level
  choice_id; its answer must match that identity and the offered label. The event
  envelope and its kind remain outside this payload.
  """
  @spec encode_terminal(term()) :: {:ok, map()} | :error
  def encode_terminal(value), do: terminal(value, :encode)

  @doc """
  ## Concept

  Decode terminal evidence while retaining exact identities and quantities.

  ## Technical depth

  Refuse inconsistent status, disposition, answer, choice or command captures.
  Expiry has null answer and command evidence. Cancellation has a null answer
  and either two null command captures or the admitted abort identity and digest.
  Every branch has one positive uint64 settlement sequence; no authority is granted.
  """
  @spec decode_terminal(term()) :: {:ok, map()} | :error
  def decode_terminal(value), do: terminal(value, :decode)

  defp terminal(value, mode) do
    with true <- is_map(value) and not is_struct(value),
         disposition when disposition in ~w(answered declined expired cancelled) <-
           value["disposition"],
         true <- value["status"] == disposition,
         choice? <- disposition == "answered" and value["interaction_kind"] == "choice",
         true <- closed?(value, if(choice?, do: @keys ++ ["choice_id"], else: @keys)),
         "model_tool" <- value["producer"],
         {:ok, question} <- terminal_question(value, mode),
         {:ok, sequence} <- settlement(value["settlement_sequence"], mode),
         {:ok, captures} <- terminal_captures(value, question["choices"], mode) do
      {:ok,
       question
       |> Map.delete("kind")
       |> Map.put("interaction_kind", question["kind"])
       |> Map.put("status", disposition)
       |> Map.put("disposition", disposition)
       |> Map.put("settlement_sequence", sequence)
       |> Map.merge(captures)}
    else
      _ -> :error
    end
  end

  # Concept: terminal evidence carries the same captured question as its request.
  # Technical depth: a temporary pending projection reuses the closed question
  # validator; the returned terminal never exposes that temporary status.
  defp terminal_question(value, mode) do
    question =
      value
      |> Map.drop(@captures ++ ["interaction_kind", "choice_id"])
      |> Map.put("kind", value["interaction_kind"])
      |> Map.put("status", "pending")

    if mode == :encode,
      do: OpenInteraction.encode_wire(question),
      else: OpenInteraction.decode_wire(question)
  end

  defp terminal_captures(%{"disposition" => "expired"} = value, _choices, _mode) do
    if Enum.all?(~w(answer command_id command_digest), &is_nil(value[&1])),
      do: {:ok, Map.take(value, ~w(answer command_id command_digest))},
      else: :error
  end

  defp terminal_captures(
         %{
           "disposition" => "cancelled",
           "answer" => nil,
           "command_id" => nil,
           "command_digest" => nil
         } = value,
         _choices,
         _mode
       ),
       do: {:ok, Map.take(value, ~w(answer command_id command_digest))}

  defp terminal_captures(%{"disposition" => "cancelled", "answer" => nil} = value, _choices, mode) do
    with {:ok, command} <- identity(value["command_id"], mode, 65_536),
         {:ok, digest} <- Wire.digest(value["command_digest"]) do
      {:ok, %{"answer" => nil, "command_id" => command, "command_digest" => digest}}
    else
      _ -> :error
    end
  end

  defp terminal_captures(value, choices, mode) do
    with {:ok, command} <- identity(value["command_id"], mode, 65_536),
         {:ok, digest} <- Wire.digest(value["command_digest"]),
         {:ok, answer} <- terminal_answer(value, choices, mode) do
      {:ok, Map.merge(answer, %{"command_id" => command, "command_digest" => digest})}
    else
      _ -> :error
    end
  end

  defp terminal_answer(%{"disposition" => "declined", "answer" => answer}, _choices, _mode) do
    if answer == %{"disposition" => "declined"}, do: {:ok, %{"answer" => answer}}, else: :error
  end

  defp terminal_answer(
         %{"disposition" => "answered", "interaction_kind" => "text", "answer" => answer},
         _choices,
         _mode
       ) do
    if closed?(answer, ["text"]) and text?(answer["text"], 8_192),
      do: {:ok, %{"answer" => answer}},
      else: :error
  end

  defp terminal_answer(
         %{"disposition" => "answered", "interaction_kind" => "choice", "answer" => answer} =
           value,
         choices,
         mode
       ) do
    with true <- closed?(answer, ~w(choice_id label)),
         {:ok, id} <- identity(value["choice_id"], mode, 64),
         {:ok, ^id} <- identity(answer["choice_id"], mode, 64),
         %{"label" => label} <- Enum.find(choices, &(&1["id"] == id)),
         true <- answer["label"] == label do
      {:ok, %{"choice_id" => id, "answer" => %{"choice_id" => id, "label" => label}}}
    else
      _ -> :error
    end
  end

  defp terminal_answer(_, _, _), do: :error

  defp identity(value, :encode, maximum)
       when is_binary(value) and byte_size(value) >= 1 and byte_size(value) <= maximum,
       do: {:ok, Wire.encode_identity(value)}

  defp identity(value, :decode, maximum) when is_binary(value) and byte_size(value) <= 87_382 do
    with {:ok, bytes} <- Wire.identity(value, maximum),
         true <- Wire.encode_identity(bytes) == value,
         do: {:ok, bytes},
         else: (_ -> :error)
  end

  defp identity(_, _, _), do: :error

  defp settlement(value, :encode)
       when is_integer(value) and value in 1..18_446_744_073_709_551_615,
       do: {:ok, Wire.encode_u64(value)}

  defp settlement(value, :decode) when is_binary(value) and byte_size(value) <= 20 do
    with {:ok, sequence} <- Wire.u64(value),
         true <- sequence > 0,
         do: {:ok, sequence},
         else: (_ -> :error)
  end

  defp settlement(_, _), do: :error

  defp text?(value, maximum),
    do: is_binary(value) and byte_size(value) in 1..maximum and String.valid?(value)

  defp closed?(value, keys),
    do: is_map(value) and not is_struct(value) and Enum.sort(Map.keys(value)) == Enum.sort(keys)
end
