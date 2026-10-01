defmodule Loopex.LLM.ReqLLM.NativeContent do
  @moduledoc """
  ## Concept

  Capture complete native Anthropic content for a continuation-required mapping
  while preserving its decoded values and block order.

  ## Technical depth

  ADR 0044's exact text/tool templates and literal thinking/redacted-thinking
  forms become compact references to simultaneously produced canonical text and
  arguments. The shared core expander reconstructs and compares the entire native
  array before returning. This pure adapter boundary grants no tool authority,
  registers no reasoning support and performs no provider call or publication.
  Streaming assembly and the owning mapping must establish completeness first.
  """

  alias Loopex.Model.ContentReferences

  @invalid {:error, :invalid_native_content}

  @doc """
  ## Concept

  Capture one complete buffered native response before SDK conversion.

  ## Technical depth

  The one-shot caller supplies the requirement and literal response-model binding
  derived from its captured request. The raw body shares the transport's 8 MiB
  ceiling; content then passes the same compact and expanded bounds as streaming.
  Only supported usage counters survive, with malformed values left unreported.
  When supplied, the selected key is screened against decoded content and raw
  usage before that reduction; it is never retained in the result.
  Nothing here publishes progress or returns the raw response envelope.
  """
  def response(model, required, expected_model, body, credential \\ nil)

  def response(model, required, expected_model, body, credential)
      when is_boolean(required) and is_binary(body) and byte_size(body) <= 8_388_608 and
             (is_nil(credential) or (is_binary(credential) and byte_size(credential) in 1..65_536)) do
    with {:ok, native} when is_map(native) <- Jason.decode(body),
         true <-
           Enum.sort(Map.keys(native)) ==
             ~w(content id model role stop_reason stop_sequence type usage),
         true <- native["type"] == "message" and native["role"] == "assistant",
         true <- bounded_text?(native["id"], 256),
         true <- bounded_text?(native["model"], 512),
         true <- is_nil(expected_model) or native["model"] == expected_model,
         true <- is_nil(native["stop_sequence"]) or bounded_text?(native["stop_sequence"], 256),
         counters when is_map(counters) <- native["usage"],
         {:ok, captured} <- project(model, required, native["stop_reason"], native["content"]),
         false <- contains_key?([native["content"], counters], credential) do
      usage =
        for {key, source} <- [{:input_tokens, "input_tokens"}, {:output_tokens, "output_tokens"}],
            Map.has_key?(counters, source),
            into: %{} do
          value = counters[source]
          {key, if(is_integer(value) and value in 0..18_446_744_073_709_551_615, do: value)}
        end

      {:ok, Map.put(captured, :usage, usage)}
    else
      _ -> @invalid
    end
  end

  def response(_, _, _, _, _), do: @invalid

  # Concept: malformed usage cannot erase a selected-key echo by becoming unknown.
  # Technical depth: screen decoded provider content and raw usage before reducing
  # counters. Host-bound identity and envelope protocol literals are not echoes.
  defp contains_key?(_, nil), do: false
  defp contains_key?(value, key) when is_binary(value), do: :binary.match(value, key) != :nomatch

  defp contains_key?(value, key) when is_list(value),
    do: Enum.any?(value, &contains_key?(&1, key))

  defp contains_key?(value, key) when is_map(value),
    do:
      Enum.any?(value, fn {name, member} ->
        contains_key?(name, key) or contains_key?(member, key)
      end)

  defp contains_key?(_, _), do: false

  defp bounded_text?(value, limit),
    do: is_binary(value) and byte_size(value) in 1..limit and String.valid?(value)

  @doc """
  ## Concept

  Produce canonical content and one bounded private capsule from a complete reply.

  ## Technical depth

  Only tool_use with calls and end_turn without calls are successful under a
  continuation-required mapping. Unknown fields, blocks, duplicate native IDs,
  missing signatures and malformed arguments refuse the whole reply. The selected
  model must already be exact; host alias resolution happens before dispatch.
  No native stop reason or opaque thinking text enters canonical answer text.
  """
  @spec capture(term(), term(), term()) :: {:ok, map()} | {:error, :invalid_native_content}
  def capture("anthropic:" <> id = model, stop, content)
      when byte_size(id) > 0 and byte_size(model) <= 512 do
    with {:ok, captured} <- decode(model, content),
         {:ok, status} <- status(stop, captured.tool_calls),
         true <- captured.continuation["status"] == status do
      {:ok, captured}
    else
      _ -> @invalid
    end
  end

  def capture(_, _, _), do: @invalid

  @doc """
  ## Concept

  Admit the completed reply under its captured continuation requirement.

  ## Technical depth

  Generic and thinking-off rows reject private thinking blocks instead of dropping
  them. They retain the exact native stop classification and return no capsule.
  Required rows admit only the natural open/closed relations proved by capture/3.
  Both paths validate the same complete bounded content before returning calls.
  """
  def project(model, true, stop, content), do: capture(model, stop, content)

  def project("anthropic:" <> id = model, false, stop, content)
      when byte_size(id) > 0 and byte_size(model) <= 512 and is_list(content) do
    with true <- Enum.all?(content, &is_map/1),
         false <- Enum.any?(content, &(&1["type"] in ["thinking", "redacted_thinking"])),
         {:ok, completion} <- completion(stop),
         {:ok, captured} <- decode(model, content) do
      {:ok, %{captured | completion: completion, continuation: nil}}
    else
      _ -> @invalid
    end
  end

  def project(_, _, _, _), do: @invalid

  defp completion(stop) when stop in ["end_turn", "tool_use", "stop_sequence"],
    do: {:ok, "natural"}

  defp completion("max_tokens"), do: {:ok, "limit"}
  defp completion(nil), do: {:ok, "unknown"}

  defp completion(stop) when is_binary(stop) and byte_size(stop) <= 256 do
    if String.valid?(stop), do: {:ok, "unknown"}, else: @invalid
  end

  defp completion(_), do: @invalid

  defp decode(model, content) do
    with {:ok, _} <- ContentReferences.json_size(content),
         {:ok, nodes, pieces, calls} <- blocks(content, 0, [], [], [], MapSet.new()),
         text <- pieces |> Enum.reverse() |> IO.iodata_to_binary(),
         calls <- Enum.reverse(calls),
         capsule = %{
           "format" => "loopex.anthropic.content_refs.v1",
           "provider" => "anthropic",
           "model" => model,
           "status" => if(calls == [], do: "closed", else: "open"),
           "content" => Enum.reverse(nodes)
         },
         {:ok, ^content} <-
           ContentReferences.expand(capsule, text, Enum.map(calls, & &1.arguments)) do
      {:ok, %{text: text, tool_calls: calls, completion: "natural", continuation: capsule}}
    else
      _ -> @invalid
    end
  end

  defp status("tool_use", [_ | _]), do: {:ok, "open"}
  defp status("end_turn", []), do: {:ok, "closed"}
  defp status(_, _), do: @invalid

  defp blocks([], _count, nodes, text, calls, _ids), do: {:ok, nodes, text, calls}

  defp blocks([block | rest], count, nodes, text, calls, ids) when count < 128 do
    case block(block, length(calls), ids) do
      {:text, node, piece} ->
        blocks(rest, count + 1, [node | nodes], [piece | text], calls, ids)

      {:tool, node, call} ->
        blocks(rest, count + 1, [node | nodes], text, [call | calls], MapSet.put(ids, call.id))

      {:literal, node} ->
        blocks(rest, count + 1, [node | nodes], text, calls, ids)

      _ ->
        @invalid
    end
  end

  defp blocks(_, _, _, _, _, _), do: @invalid

  defp block(%{"type" => "text", "text" => text} = block, _, _)
       when map_size(block) == 2 and is_binary(text) do
    {:text,
     %{
       "kind" => "text_ref",
       "byte_length" => byte_size(text),
       "template" => %{"type" => "text"},
       "field" => "text"
     }, text}
  end

  defp block(
         %{"type" => "tool_use", "id" => id, "name" => name, "input" => arguments} = block,
         index,
         ids
       )
       when map_size(block) == 4 and is_binary(id) and byte_size(id) > 0 and
              is_binary(name) and byte_size(name) > 0 and is_map(arguments) do
    if MapSet.member?(ids, id) do
      @invalid
    else
      {:tool,
       %{
         "kind" => "tool_use_ref",
         "call_index" => index,
         "native_id" => id,
         "template" => Map.take(block, ~w(type id name)),
         "field" => "input"
       }, %{id: id, name: name, arguments: arguments}}
    end
  end

  defp block(%{"type" => "thinking", "thinking" => text, "signature" => signature} = block, _, _)
       when map_size(block) == 3 and is_binary(text) and is_binary(signature) and
              byte_size(signature) > 0,
       do: {:literal, %{"kind" => "literal", "value" => block}}

  defp block(%{"type" => "redacted_thinking", "data" => data} = block, _, _)
       when map_size(block) == 2 and is_binary(data) and byte_size(data) > 0,
       do: {:literal, %{"kind" => "literal", "value" => block}}

  defp block(_, _, _), do: @invalid
end
