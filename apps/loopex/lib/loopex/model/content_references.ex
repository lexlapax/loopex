defmodule Loopex.Model.ContentReferences do
  @moduledoc """
  ## Concept

  Expand a private content capsule against its owning canonical text and tool
  arguments. References reuse those values without retaining a second copy.

  ## Technical depth

  ADR 0044 fixes the closed literal/text/tool node union and the 16,384-byte
  compact and expanded JSON ceilings. Core and adapter rendering share this
  pure rule. Text consumes successive UTF-8 byte slices; tools consume ordered
  argument indices exactly once. Templates receive one absent top-level field.
  Opaque objects are measured as plain JSON data, never interpreted as nodes.
  Provider block schemas, source settlement identity and renderer correspondence
  remain the owning adapter and session owner's separate checks.
  """

  @limit 16_384
  @format "loopex.anthropic.content_refs.v1"
  @capsule_keys Enum.sort(~w(format provider model status content))
  @invalid {:error, :invalid_continuation}

  @doc """
  ## Concept

  Reconstruct the exact ordered content objects from one owned capsule.

  ## Technical depth

  Arguments are the canonical call arguments in call order, with no provider
  structs or resolver. Both capsule representations fit compact UTF-8 JSON;
  at most 128 nodes are admitted. Open requires calls; closed requires none.
  No callback, artifact lookup or recursive reference substitution occurs.
  """
  @spec expand(term(), term(), term()) :: {:ok, [map()]} | {:error, :invalid_continuation}
  def expand(capsule, text, arguments)
      when is_map(capsule) and map_size(capsule) == 5 and is_binary(text) do
    with true <- Map.keys(capsule) |> Enum.sort() == @capsule_keys,
         true <- capsule["format"] == @format and capsule["provider"] == "anthropic",
         model when is_binary(model) and byte_size(model) in 1..512 <- capsule["model"],
         true <- String.valid?(model),
         {:ok, _} <- json_size(capsule),
         {:ok, call_count} <- argument_count(arguments, 0),
         true <- valid_status?(capsule["status"], call_count),
         true <- byte_size(text) <= @limit and String.valid?(text),
         {:ok, overhead} <- json_size(%{capsule | "content" => []}),
         {:ok, blocks, offset, used} <-
           nodes(capsule["content"], text, arguments, 0, 0, 0, @limit - overhead, []),
         true <- offset == byte_size(text) and used == call_count do
      {:ok, blocks}
    else
      _ -> @invalid
    end
  end

  def expand(_, _, _), do: @invalid

  @doc """
  ## Concept

  Measure private JSON data before allocating an encoded or expanded value.

  ## Technical depth

  Uses ADR 0042's compact UTF-8 recipe without a newline: standard short escapes,
  six-byte other control escapes and unescaped Unicode. Binary keys only, plain
  objects, depth twelve and cardinality 1,024 preserve existing structural limits.
  Floats use the shortest round-trip decimal spelling. The walk stops at the
  fixed continuation ceiling; it does not build a JSON string. This same bound
  serves compact capsules and future aggregate request envelopes.
  """
  @spec json_size(term()) :: {:ok, non_neg_integer()} | {:error, :invalid_continuation}
  def json_size(value) do
    case measure(value, @limit, 0) do
      {:ok, remaining} -> {:ok, @limit - remaining}
      _ -> @invalid
    end
  end

  defp valid_status?("open", count), do: count > 0
  defp valid_status?("closed", 0), do: true
  defp valid_status?(_, _), do: false

  defp argument_count([], count), do: {:ok, count}

  defp argument_count([head | tail], count) when is_map(head) and count < 128 do
    if is_struct(head), do: @invalid, else: argument_count(tail, count + 1)
  end

  defp argument_count(_, _), do: @invalid

  defp nodes([], _text, _arguments, offset, used, _count, _budget, blocks),
    do: {:ok, Enum.reverse(blocks), offset, used}

  defp nodes([node | rest], text, arguments, offset, used, count, budget, blocks)
       when count < 128 do
    with {:ok, block, next_offset, next_used} <- node(node, text, arguments, offset, used),
         {:ok, budget} <- spend(budget, if(count > 0, do: 1, else: 0)),
         {:ok, budget} <- measure(block, budget, 2) do
      nodes(rest, text, arguments, next_offset, next_used, count + 1, budget, [block | blocks])
    end
  end

  defp nodes(_, _, _, _, _, _, _, _), do: @invalid

  defp node(%{"kind" => "literal", "value" => value} = node, _, _, offset, used)
       when map_size(node) == 2 and is_map(value),
       do: {:ok, value, offset, used}

  defp node(
         %{
           "kind" => "text_ref",
           "byte_length" => length,
           "template" => template,
           "field" => field
         } = node,
         text,
         _,
         offset,
         used
       )
       when map_size(node) == 4 and is_integer(length) and length >= 0 do
    with true <- length <= byte_size(text) - offset,
         slice <- binary_part(text, offset, length),
         true <- String.valid?(slice),
         {:ok, block} <- insert(template, field, slice) do
      {:ok, block, offset + length, used}
    else
      _ -> @invalid
    end
  end

  defp node(
         %{
           "kind" => "tool_use_ref",
           "call_index" => index,
           "native_id" => id,
           "template" => template,
           "field" => field
         } = node,
         _,
         arguments,
         offset,
         used
       )
       when map_size(node) == 5 and is_integer(index) and index == used and is_binary(id) and
              byte_size(id) > 0 do
    with true <- String.valid?(id),
         argument when is_map(argument) <- Enum.at(arguments, index),
         {:ok, block} <- insert(template, field, argument) do
      {:ok, block, offset, used + 1}
    else
      _ -> @invalid
    end
  end

  defp node(_, _, _, _, _), do: @invalid

  # Concept: a reference inserts data, never executes a reference-shaped value.
  # Technical depth: field names are single ASCII keys, not paths; only the
  # selected node is interpreted. A nested object keeps its exact original keys.
  defp insert(template, field, value) when is_map(template) and is_binary(field) do
    if byte_size(field) in 1..128 and ascii?(field) and not Map.has_key?(template, field),
      do: {:ok, Map.put(template, field, value)},
      else: @invalid
  end

  defp insert(_, _, _), do: @invalid
  defp ascii?(<<>>), do: true
  defp ascii?(<<byte, rest::binary>>) when byte in 0..127, do: ascii?(rest)
  defp ascii?(_), do: false

  defp measure(_, remaining, depth) when remaining < 0 or depth > 12, do: @invalid
  defp measure(nil, remaining, _), do: spend(remaining, 4)
  defp measure(true, remaining, _), do: spend(remaining, 4)
  defp measure(false, remaining, _), do: spend(remaining, 5)

  defp measure(value, remaining, _) when is_binary(value) do
    if byte_size(value) + 2 <= remaining,
      do: string_size(value, remaining - 2),
      else: @invalid
  end

  defp measure(value, remaining, _) when is_integer(value) do
    digits = remaining - if(value < 0, do: 1, else: 0)

    if digits > 0 do
      bound = Integer.pow(10, digits)

      if value > -bound and value < bound,
        do: spend(remaining, byte_size(Integer.to_string(value))),
        else: @invalid
    else
      @invalid
    end
  end

  defp measure(value, remaining, _) when is_float(value),
    do: spend(remaining, byte_size(:erlang.float_to_binary(value, [:short])))

  defp measure(value, remaining, depth) when is_map(value) and not is_struct(value) do
    if map_size(value) <= 1_024 do
      Enum.reduce_while(value, spend(remaining, 2 + max(map_size(value) - 1, 0)), fn {key, member},
                                                                                     result ->
        with true <- is_binary(key),
             {:ok, budget} <- result,
             {:ok, budget} <- measure(key, budget, depth + 1),
             {:ok, budget} <- spend(budget, 1),
             {:ok, budget} <- measure(member, budget, depth + 1) do
          {:cont, {:ok, budget}}
        else
          _ -> {:halt, @invalid}
        end
      end)
    else
      @invalid
    end
  end

  defp measure(value, remaining, depth) when is_list(value),
    do: measure_list(value, remaining - 2, depth, 0)

  defp measure(_, _, _), do: @invalid

  defp measure_list([], remaining, _, _count), do: spend(remaining, 0)

  defp measure_list([head | tail], remaining, depth, count) when count < 1_024 do
    with {:ok, remaining} <- spend(remaining, if(count > 0, do: 1, else: 0)),
         {:ok, remaining} <- measure(head, remaining, depth + 1),
         do: measure_list(tail, remaining, depth, count + 1)
  end

  defp measure_list(_, _, _, _), do: @invalid

  defp spend(remaining, bytes) when remaining >= bytes, do: {:ok, remaining - bytes}
  defp spend(_, _), do: @invalid

  defp string_size(_, remaining) when remaining < 0, do: @invalid
  defp string_size(<<>>, remaining), do: {:ok, remaining}

  defp string_size(<<code::utf8, rest::binary>>, remaining) do
    bytes =
      cond do
        code in [?", ?\\, ?\b, ?\f, ?\n, ?\r, ?\t] -> 2
        code < 32 -> 6
        true -> byte_size(<<code::utf8>>)
      end

    string_size(rest, remaining - bytes)
  end

  defp string_size(_, _), do: @invalid
end
