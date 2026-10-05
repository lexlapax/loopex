defmodule LoopexProtocol.Session.ModelQuestionEvent do
  @moduledoc """
  ## Concept

  Preserve the committed requested-model-question data without answer evidence.
  Text and choice questions reuse the current open-interaction contract.

  ## Technical depth

  Only the fifteen-member data payload of model `interaction.requested` is
  supported. The five answer/command/settlement captures are required and null.
  Native opaque identities and integer quantities retain their exact wire
  encodings through OpenInteraction. Envelopes, policy questions and terminal
  events are outside this codec; successful decoding establishes no authority.
  """

  alias LoopexProtocol.Session.OpenInteraction

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
end
