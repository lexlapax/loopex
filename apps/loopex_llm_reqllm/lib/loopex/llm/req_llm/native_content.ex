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
    with {:ok, _} <- ContentReferences.json_size(content),
         {:ok, nodes, pieces, calls} <- blocks(content, 0, [], [], [], MapSet.new()),
         {:ok, status} <- status(stop, calls),
         text <- pieces |> Enum.reverse() |> IO.iodata_to_binary(),
         calls <- Enum.reverse(calls),
         capsule = %{
           "format" => "loopex.anthropic.content_refs.v1",
           "provider" => "anthropic",
           "model" => model,
           "status" => status,
           "content" => Enum.reverse(nodes)
         },
         {:ok, ^content} <-
           ContentReferences.expand(capsule, text, Enum.map(calls, & &1.arguments)) do
      {:ok, %{text: text, tool_calls: calls, completion: "natural", continuation: capsule}}
    else
      _ -> @invalid
    end
  end

  def capture(_, _, _), do: @invalid

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
