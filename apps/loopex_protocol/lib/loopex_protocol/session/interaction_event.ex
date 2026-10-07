defmodule LoopexProtocol.Session.InteractionEvent do
  @moduledoc """
  ## Concept

  Select the accepted model or policy interaction payload by its event kind.
  Requests, answer admission and terminal facts retain their distinct meanings;
  no shape or answer grants authority.

  ## Technical depth

  This pure selector composes ModelQuestionEvent, PolicyEvent and OpenInteraction
  for the foreground and daemon event builders. It is dormant until their complete
  coordinated generation change. It adds no event envelope, schema or byte bound.
  Enclosing frame limits and prior-cursor relations remain the caller's duties.
  Wire payloads require an explicit producer. Native policy requests and endings
  have no producer; only their complete dedicated codec validates that branch.
  Native policy reasons are validated and omitted by PolicyEvent.
  """

  alias LoopexProtocol.Session.{ModelQuestionEvent, OpenInteraction, PolicyEvent}

  @model_endings %{
    "interaction.answered" => "answered",
    "interaction.declined" => "declined",
    "interaction.expired" => "expired",
    "interaction.cancelled" => "cancelled"
  }
  @policy_endings ~w(interaction.resolved interaction.expired interaction.cancelled)

  @doc """
  ## Concept

  Encode one native interaction payload with its existing event kind.

  ## Technical depth

  Plain binary-key payloads cross their exact existing codec. Model disposition
  must match the enclosing kind; a missing native policy producer is sufficient
  only together with the complete closed policy payload. Unknown kinds refuse.
  No transport or generation is enabled here.
  """
  @spec encode(binary(), term()) :: {:ok, map()} | :error
  def encode(kind, value) when is_binary(kind) and is_map(value) and not is_struct(value) do
    case {kind, Map.get(value, "producer")} do
      {"interaction.answer_admitted", "policy_defer"} ->
        OpenInteraction.encode_answer_admitted(value)

      {"interaction.requested", "model_tool"} ->
        ModelQuestionEvent.encode_requested(value)

      {"interaction.requested", nil} ->
        PolicyEvent.encode_requested(value)

      {kind, "model_tool"} ->
        model_terminal(kind, value, &ModelQuestionEvent.encode_terminal/1)

      {kind, nil} when kind in @policy_endings ->
        PolicyEvent.encode_terminal(kind, value)

      _ ->
        :error
    end
  end

  def encode(_kind, _value), do: :error

  @doc """
  ## Concept

  Decode one wire interaction payload without changing its producer or ending.

  ## Technical depth

  Both producers must be explicit. Event kind selects admission versus terminal
  interpretation even when their nine wire members coincide. Decoded policy
  terminals omit their unavailable native reason. The serial owner separately
  authenticates the complete tuple and prior question at the committed cursor.
  """
  @spec decode(binary(), term()) :: {:ok, map()} | :error
  def decode(kind, value) when is_binary(kind) and is_map(value) and not is_struct(value) do
    case {kind, Map.get(value, "producer")} do
      {"interaction.answer_admitted", "policy_defer"} ->
        OpenInteraction.decode_answer_admitted(value)

      {"interaction.requested", "policy_defer"} ->
        PolicyEvent.decode_requested(value)

      {"interaction.requested", "model_tool"} ->
        ModelQuestionEvent.decode_requested(value)

      {kind, "model_tool"} ->
        model_terminal(kind, value, &ModelQuestionEvent.decode_terminal/1)

      {kind, "policy_defer"} when kind in @policy_endings ->
        PolicyEvent.decode_terminal(kind, value)

      _ ->
        :error
    end
  end

  def decode(_kind, _value), do: :error

  defp model_terminal(kind, value, codec) do
    with disposition when is_binary(disposition) <- Map.get(@model_endings, kind),
         true <- value["disposition"] == disposition do
      codec.(value)
    else
      _ -> :error
    end
  end
end
