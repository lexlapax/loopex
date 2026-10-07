defmodule LoopexProtocol.Session.PolicyEvent do
  @moduledoc """
  ## Concept

  Project accepted ADR 0052 policy requests and endings without granting authority.
  The explicit terminal event kind preserves allowed, denied, expired and cancelled
  answer history. Native reasons are validated and omitted from the wire.

  ## Technical depth

  Native requests have seven members; wire requests add only policy producer,
  choice kind and pending status. Native endings have six required members and
  exactly the conditional choice/reason captures; wire endings have nine members.
  Decoding reconstructs the native projection without an omitted reason. Shared
  OpenInteraction and Wire preserve scalar bytes. Frame enforces its existing
  2,097,152-byte output ceiling including newline; enclosing event and negotiated
  frame bounds remain the transport's duty. Input JSON first crosses the existing
  duplicate-aware Frame. No journal, lifecycle or generation is activated here.
  """

  alias LoopexProtocol.{Frame, Wire}
  alias LoopexProtocol.Session.OpenInteraction

  @request ~w(interaction_id run_id turn tool_call_id prompt choices expires_at)
  @wire_request @request ++ ~w(producer interaction_kind status)
  @terminal ~w(interaction_id run_id turn tool_call_id resolution answer_command_id)
  @wire_terminal ~w(interaction_id run_id turn tool_call_id producer interaction_kind status answer_choice_id answer_command_id)
  @statuses %{
    "interaction.resolved" => %{"allowed" => "answered", "denied" => "denied"},
    "interaction.expired" => %{"expired" => "expired"},
    "interaction.cancelled" => %{"cancelled" => "cancelled"}
  }

  @doc """
  ## Concept

  Encode the exact native policy request into the closed ten-member payload.

  ## Technical depth

  The dedicated branch adds fixed literals, preserving original identities,
  numbered turn, offered choices and expiry. Extra captures refuse.
  """
  @spec encode_requested(term()) :: {:ok, map()} | :error
  def encode_requested(value) do
    with true <- closed?(value, @request),
         question <-
           Map.merge(value, %{
             "producer" => "policy_defer",
             "kind" => "choice",
             "status" => "pending"
           }),
         {:ok, projected} <- OpenInteraction.encode_wire(question),
         wire <- projected |> Map.delete("kind") |> Map.put("interaction_kind", "choice"),
         true <- bounded?(wire) do
      {:ok, wire}
    else
      _ -> :error
    end
  end

  @doc """
  ## Concept

  Decode a policy request to its seven native members without adding authority.

  ## Technical depth

  Closed policy/choice/pending literals and a complete bounded JSON projection
  precede shared canonical scalar decoding. No null correlation is admitted.
  """
  @spec decode_requested(term()) :: {:ok, map()} | :error
  def decode_requested(value) do
    with true <- closed?(value, @wire_request),
         "policy_defer" <- value["producer"],
         "choice" <- value["interaction_kind"],
         "pending" <- value["status"],
         true <- request_json?(value),
         true <- bounded?(value),
         question <- value |> Map.delete("interaction_kind") |> Map.put("kind", "choice"),
         {:ok, projected} <- OpenInteraction.decode_wire(question) do
      {:ok, Map.take(projected, @request)}
    else
      _ -> :error
    end
  end

  @doc """
  ## Concept

  Encode a kind-correlated native policy ending with its actual answer pair.

  ## Technical depth

  Allowed and denied require the selected choice and admitted command. Expiry
  and cancellation admit either both captures or neither. A present native
  reason remains an opaque binary of at most 65,536 bytes and is omitted.
  """
  @spec encode_terminal(binary(), term()) :: {:ok, map()} | :error
  def encode_terminal(kind, value) do
    with true <- native_terminal?(value),
         status when is_binary(status) <- get_in(@statuses, [kind, value["resolution"]]),
         choice <- Map.get(value, "choice_id"),
         true <- pair?(status, choice, value["answer_command_id"]),
         {:ok, scalars} <- terminal_scalars(value, choice, :encode),
         wire <-
           Map.merge(scalars, %{
             "producer" => "policy_defer",
             "interaction_kind" => "choice",
             "status" => status
           }),
         true <- bounded?(wire) do
      {:ok, wire}
    else
      _ -> :error
    end
  end

  @doc """
  ## Concept

  Decode a closed policy ending into the native projection without a reason.

  ## Technical depth

  The explicit event kind constrains status; a payload alone is not an answer
  admission or lifecycle proof. Canonical identities and exact answer pairs are
  preserved, while the enclosing reducer verifies the prior question tuple.
  """
  @spec decode_terminal(binary(), term()) :: {:ok, map()} | :error
  def decode_terminal(kind, value) do
    with true <- closed?(value, @wire_terminal),
         "policy_defer" <- value["producer"],
         "choice" <- value["interaction_kind"],
         table when is_map(table) <- @statuses[kind],
         {resolution, _} <-
           Enum.find(table, fn {_resolution, status} -> status == value["status"] end),
         true <- pair?(value["status"], value["answer_choice_id"], value["answer_command_id"]),
         true <-
           Enum.all?(
             @wire_terminal -- ~w(answer_choice_id answer_command_id),
             &text_scalar?(value[&1])
           ),
         true <-
           Enum.all?(
             ~w(answer_choice_id answer_command_id),
             &(is_nil(value[&1]) or text_scalar?(value[&1]))
           ),
         true <- bounded?(value),
         {:ok, scalars} <- terminal_scalars(value, value["answer_choice_id"], :decode) do
      native = scalars |> Map.delete("answer_choice_id") |> Map.put("resolution", resolution)

      {:ok,
       if(is_nil(scalars["answer_choice_id"]),
         do: native,
         else: Map.put(native, "choice_id", scalars["answer_choice_id"])
       )}
    else
      _ -> :error
    end
  end

  defp terminal_scalars(value, choice, mode) do
    with {:ok, turn} <- turn(value["turn"], mode) do
      identities =
        Map.take(value, ~w(interaction_id run_id tool_call_id answer_command_id))
        |> Map.put("answer_choice_id", choice)

      Enum.reduce_while(identities, {:ok, %{"turn" => turn}}, fn {key, scalar}, {:ok, result} ->
        maximum = if key == "answer_choice_id", do: 64, else: 65_536
        optional = key in ~w(answer_choice_id answer_command_id)

        case identity(scalar, mode, maximum, optional) do
          {:ok, projected} -> {:cont, {:ok, Map.put(result, key, projected)}}
          :error -> {:halt, :error}
        end
      end)
    end
  end

  defp native_terminal?(value) when is_map(value) and not is_struct(value) do
    keys =
      @terminal ++
        if(Map.has_key?(value, "choice_id"), do: ["choice_id"], else: []) ++
        if(Map.has_key?(value, "reason"), do: ["reason"], else: [])

    closed?(value, keys) and
      (not Map.has_key?(value, "reason") or
         (is_binary(value["reason"]) and byte_size(value["reason"]) <= 65_536)) and
      if is_nil(value["answer_command_id"]),
        do: not Map.has_key?(value, "choice_id"),
        else: Map.has_key?(value, "choice_id") and not is_nil(value["choice_id"])
  end

  defp native_terminal?(_), do: false

  defp pair?(status, choice, command) when status in ~w(answered denied),
    do: not is_nil(choice) and not is_nil(command)

  defp pair?(status, choice, command) when status in ~w(expired cancelled),
    do: is_nil(choice) == is_nil(command)

  defp pair?(_, _, _), do: false

  defp identity(nil, _mode, _maximum, true), do: {:ok, nil}

  defp identity(value, :encode, maximum, _)
       when is_binary(value) and byte_size(value) in 1..maximum//1,
       do: {:ok, Wire.encode_identity(value)}

  defp identity(value, :decode, maximum, _) do
    with {:ok, bytes} <- Wire.identity(value, maximum),
         true <- Wire.encode_identity(bytes) == value,
         do: {:ok, bytes},
         else: (_ -> :error)
  end

  defp identity(_, _, _, _), do: :error

  defp turn(value, :encode) when is_integer(value) and value > 0,
    do: {:ok, Integer.to_string(value)}

  defp turn(value, :decode) when is_binary(value) do
    if Regex.match?(~r/\A[1-9][0-9]*\z/, value), do: {:ok, String.to_integer(value)}, else: :error
  end

  defp turn(_, _), do: :error

  # Concept: aggregate refusal precedes expensive arbitrary-turn decoding.
  # Technical depth: only the finite closed JSON request tree reaches Frame;
  # these type checks add no scalar limit and cannot invoke private term encoders.
  defp request_json?(value) do
    Enum.all?(@wire_request -- ["choices"], &text_scalar?(value[&1])) and
      request_choices_json?(value["choices"])
  end

  defp request_choices_json?(values) when is_list(values) and length(values) in 1..8 do
    Enum.all?(values, fn choice ->
      closed?(choice, ~w(id label)) and Enum.all?(~w(id label), &text_scalar?(choice[&1]))
    end)
  end

  defp request_choices_json?(_), do: false
  defp text_scalar?(value), do: is_binary(value) and String.valid?(value)
  defp bounded?(value), do: match?({:ok, _}, Frame.encode(value))

  defp closed?(value, keys),
    do: is_map(value) and not is_struct(value) and Enum.sort(Map.keys(value)) == Enum.sort(keys)
end
