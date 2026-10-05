defmodule LoopexProtocol.Session.OpenInteraction do
  @moduledoc """
  ## Concept

  An open question retains its producer, kind and original call identity.
  Policy answers remain open while resolution is owed. Reading grants no authority.

  ## Technical depth

  ADR 0045 admits model-tool choice/text questions and policy-defer choices.
  The closed ten-member projection uses opaque identities, exact positive turn
  quantities and uint64 expiry. Prompts are nonempty UTF-8 up to 2,048 bytes;
  choices have one to eight distinct opaque identifiers up to 64 bytes and
  nonempty UTF-8 labels up to 256 bytes. Model choices retain their original
  choice-N order and distinct labels. Text questions retain an empty list.
  Pending views have ten members. Answered policy choice views add only the
  offered answer_choice_id and admitted answer_command_id. Model answers close
  atomically and have no open answered branch. No private policy handle enters
  this public cursor projection.
  """

  alias LoopexProtocol.Wire
  @keys ~w(interaction_id run_id turn tool_call_id status prompt choices expires_at producer kind)
  @answered_keys @keys ++ ~w(answer_choice_id answer_command_id)
  @event_keys ~w(interaction_id run_id turn tool_call_id producer interaction_kind status answer_choice_id answer_command_id)
  @u64 18_446_744_073_709_551_615

  @doc """
  ## Concept

  Encode the closed pending or answered policy question at its public cursor.

  ## Technical depth

  Preserve exact identity bytes and turn/expiry quantities. Extra members,
  model terminal responses and private policy facts refuse.
  """
  @spec encode_wire(term()) :: {:ok, map()} | :error
  def encode_wire(value), do: project(value, :encode)

  @doc """
  ## Concept

  Decode an open question without inventing its producer, kind or answer.

  ## Technical depth

  Refuse noncanonical identities/decimals and inconsistent producer, kind or
  choices. Enclosing frames retain their total size and structural bounds.
  """
  @spec decode_wire(term()) :: {:ok, map()} | :error
  def decode_wire(value), do: project(value, :decode)

  @doc """
  ## Concept

  Encode a committed policy answer admission without granting an effect.

  ## Technical depth

  Require exactly the nine approved event-data members. Raw identities retain
  their own byte ceilings and turn remains an arbitrary positive integer.
  The serial reducer separately verifies the offered choice and question tuple.
  No event envelope, prompt, expiry, policy reference or resolution is added.
  """
  @spec encode_answer_admitted(term()) :: {:ok, map()} | :error
  def encode_answer_admitted(value), do: answer_admitted(value, :encode)

  @doc """
  ## Concept

  Decode the closed public policy answer admission data.

  ## Technical depth

  Producer, interaction kind and status are fixed literal strings. Noncanonical
  identities, quantities, missing members and private payloads refuse.
  """
  @spec decode_answer_admitted(term()) :: {:ok, map()} | :error
  def decode_answer_admitted(value), do: answer_admitted(value, :decode)

  defp answer_admitted(value, mode) do
    with true <- closed?(value, @event_keys),
         "policy_defer" <- value["producer"],
         "choice" <- value["interaction_kind"],
         "answered" <- value["status"],
         {:ok, turn} <- quantity(value["turn"], mode, 1, nil) do
      Enum.reduce_while(
        ~w(interaction_id run_id tool_call_id answer_choice_id answer_command_id),
        {:ok, Map.put(value, "turn", turn)},
        fn key, {:ok, result} ->
          maximum = if key == "answer_choice_id", do: 64, else: 65_536

          case identity(value[key], mode, maximum) do
            {:ok, scalar} -> {:cont, {:ok, Map.put(result, key, scalar)}}
            :error -> {:halt, :error}
          end
        end
      )
    else
      _ -> :error
    end
  end

  defp open_shape?(%{"status" => "pending"} = value), do: closed?(value, @keys)

  defp open_shape?(
         %{"status" => "answered", "producer" => "policy_defer", "kind" => "choice"} = value
       ),
       do: closed?(value, @answered_keys)

  defp open_shape?(_), do: false

  defp answer(%{"status" => "pending"}, _choices, _mode), do: {:ok, %{}}

  defp answer(value, choices, mode) do
    with {:ok, choice} <- identity(value["answer_choice_id"], mode, 64),
         true <- Enum.any?(choices, &(&1["id"] == choice)),
         {:ok, command} <- identity(value["answer_command_id"], mode, 65_536) do
      {:ok, %{"answer_choice_id" => choice, "answer_command_id" => command}}
    else
      _ -> :error
    end
  end

  defp project(value, mode) do
    with true <- open_shape?(value),
         true <- value["producer"] in ~w(model_tool policy_defer),
         true <- value["kind"] in ~w(choice text),
         true <- text?(value["prompt"], 2_048),
         {:ok, interaction} <- identity(value["interaction_id"], mode, 65_536),
         {:ok, run} <- identity(value["run_id"], mode, 65_536),
         {:ok, call} <- identity(value["tool_call_id"], mode, 65_536),
         {:ok, turn} <- quantity(value["turn"], mode, 1, nil),
         {:ok, expiry} <- quantity(value["expires_at"], mode, 0, @u64),
         {:ok, choices} <- choices(value["choices"], mode),
         true <- valid_choices?(value["producer"], value["kind"], choices, mode),
         {:ok, answer} <- answer(value, choices, mode) do
      {:ok,
       value
       |> Map.merge(%{
         "interaction_id" => interaction,
         "run_id" => run,
         "tool_call_id" => call,
         "turn" => turn,
         "expires_at" => expiry,
         "choices" => choices
       })
       |> Map.merge(answer)}
    else
      _ -> :error
    end
  end

  defp choices(values, mode) when is_list(values) and length(values) <= 8 do
    Enum.reduce_while(values, {:ok, []}, fn choice, {:ok, acc} ->
      with true <- closed?(choice, ~w(id label)),
           true <- text?(choice["label"], 256),
           {:ok, id} <- identity(choice["id"], mode, 64) do
        {:cont, {:ok, [%{"id" => id, "label" => choice["label"]} | acc]}}
      else
        _ -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      :error -> :error
    end
  end

  defp choices(_, _), do: :error

  defp valid_choices?("model_tool", "text", choices, _mode), do: choices == []

  defp valid_choices?(producer, "choice", choices, mode) when choices != [] do
    distinct = length(Enum.uniq_by(choices, & &1["id"])) == length(choices)

    if producer == "model_tool" do
      ordered =
        Enum.with_index(choices, 1)
        |> Enum.all?(fn {choice, index} ->
          id = "choice-#{index}"
          choice["id"] == if(mode == :encode, do: Wire.encode_identity(id), else: id)
        end)

      distinct and length(Enum.uniq_by(choices, & &1["label"])) == length(choices) and ordered
    else
      distinct
    end
  end

  defp valid_choices?(_, _, _, _), do: false

  defp identity(value, :encode, maximum)
       when is_binary(value) and byte_size(value) > 0 and byte_size(value) <= maximum,
       do: {:ok, Wire.encode_identity(value)}

  defp identity(value, :decode, maximum) do
    with {:ok, bytes} <- Wire.identity(value),
         true <- byte_size(bytes) <= maximum and Wire.encode_identity(bytes) == value,
         do: {:ok, bytes},
         else: (_ -> :error)
  end

  defp identity(_, _, _), do: :error

  defp quantity(value, :encode, minimum, maximum) when is_integer(value) do
    if value >= minimum and (is_nil(maximum) or value <= maximum),
      do: {:ok, Integer.to_string(value)},
      else: :error
  end

  defp quantity(value, :decode, minimum, maximum) when is_binary(value) do
    if Regex.match?(~r/\A(?:0|[1-9][0-9]*)\z/, value) do
      integer = String.to_integer(value)

      if integer >= minimum and (is_nil(maximum) or integer <= maximum),
        do: {:ok, integer},
        else: :error
    else
      :error
    end
  end

  defp quantity(_, _, _, _), do: :error

  defp text?(value, maximum),
    do: is_binary(value) and byte_size(value) in 1..maximum and String.valid?(value)

  defp closed?(value, keys),
    do: is_map(value) and not is_struct(value) and Enum.sort(Map.keys(value)) == Enum.sort(keys)
end
