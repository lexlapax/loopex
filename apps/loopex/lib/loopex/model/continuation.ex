defmodule Loopex.Model.Continuation do
  @moduledoc """
  ## Concept

  Validate an ordinary exchange's private continuation against the canonical
  messages it accompanies. Every reference names an assistant or tool result in
  that same request; no journal or provider lookup is part of expansion.

  ## Technical depth

  ADR 0044 fixes the closed envelope, ordered source/call mappings, at most 32
  entries and 128 native blocks, and 16,384-byte compact and expanded JSON limits.
  This module supplies the shared core/adapter expansion and the receipt's
  canonical expanded cost. The session owner separately proves each source
  against its committed settlement and captured configuration. Provider template
  interpretation belongs to the adapter.
  """

  alias Loopex.Bounds
  alias Loopex.Model.ContentReferences
  alias LoopexProtocol.Canonical

  @format "loopex.anthropic.content_refs.v1"
  @keys Enum.sort(
          ~w(format provider model configuration_version exchange_id base_request_digest entries)
        )
  @entry_keys Enum.sort(~w(source assistant_message_index calls capsule))
  @source_keys Enum.sort(~w(run_id turn_id operation_id attempt settlement_digest))
  @call_keys Enum.sort(~w(canonical_call_id native_id result_message_index))
  @invalid {:error, :invalid_continuation}
  @limit 16_384
  @uint64_max 18_446_744_073_709_551_615

  @doc """
  ## Concept

  Expand a complete continuation using only its declared canonical targets.

  ## Technical depth

  Nil has no private content. Non-nil envelopes require exact identity fields,
  increasing assistant/result positions, unique source and call identities, open
  capsules and matching ordered native IDs. Each bounded expanded entry spends
  the aggregate budget before it is appended. All non-content envelope members
  remain byte-for-byte equivalent in the returned accounting preimage.
  """
  @spec expand(term(), binary(), [map()]) :: {:ok, map() | nil} | {:error, :invalid_continuation}
  def expand(nil, _model, _messages), do: {:ok, nil}

  def expand(envelope, model, messages) when is_map(envelope) and is_list(messages) do
    with true <- closed?(envelope, @keys),
         true <- envelope["format"] == @format and envelope["provider"] == "anthropic",
         true <- envelope["model"] == model and text?(model),
         version when is_integer(version) and version in 1..@uint64_max <-
           envelope["configuration_version"],
         true <- text?(envelope["exchange_id"]) and digest?(envelope["base_request_digest"]),
         {:ok, _} <- ContentReferences.json_size(envelope),
         entries when is_list(entries) and length(entries) in 1..32 <- envelope["entries"],
         true <- length(messages) <= 1_024,
         {:ok, overhead} <- ContentReferences.json_size(%{envelope | "entries" => []}),
         {:ok, expanded} <-
           entries(
             entries,
             List.to_tuple(messages),
             envelope,
             -1,
             0,
             @limit - overhead,
             MapSet.new(),
             MapSet.new(),
             []
           ) do
      result = %{envelope | "entries" => expanded}

      with {:ok, _} <- ContentReferences.json_size(result),
           {:ok, ids} <- rendered_ids(envelope, messages),
           true <- length(ids) == MapSet.size(MapSet.new(ids)) do
        {:ok, result}
      else
        _ -> @invalid
      end
    else
      _ -> @invalid
    end
  end

  def expand(_, _, _), do: @invalid

  @doc """
  ## Concept

  Charge the full expanded private envelope in addition to ordinary messages.

  ## Technical depth

  The exact preimage is Canonical.encode(E(request)), including every unchanged
  envelope field and expanded capsule. Revision-four receipts retain its SHA-256,
  byte count and ceil(bytes/3) token estimate. Nil continuation has nil cost.
  """
  @spec cost(term(), binary(), [map()]) :: {:ok, map() | nil} | {:error, :invalid_continuation}
  def cost(envelope, model, messages) do
    with {:ok, expanded} <- expand(envelope, model, messages) do
      if is_nil(expanded) do
        {:ok, nil}
      else
        bytes = Canonical.encode(expanded)

        {:ok,
         %{
           "content_digest" => Canonical.digest_bytes(bytes),
           "byte_cost" => byte_size(bytes),
           "token_cost" => Bounds.estimate(bytes)
         }}
      end
    end
  end

  @doc """
  ## Concept

  Refuse native call identities that would require rewriting retained history.

  ## Technical depth

  Call after canonical reply admission. Unmapped assistants use their canonical
  IDs; envelope entries use their retained native IDs. New native IDs must be
  disjoint from that complete rendered history before any tool intent is made.
  Ordinary replies without a capsule keep their historical identity behavior.
  """
  @spec validate_reply_ids(map(), map()) :: :ok | {:error, :invalid_continuation}
  def validate_reply_ids(request, %{"continuation" => capsule, "tool_calls" => calls})
      when is_map(capsule) do
    with {:ok, ids} <- rendered_ids(request.continuation, request.messages) do
      existing = MapSet.new(ids)
      if Enum.any?(calls, &MapSet.member?(existing, &1["id"])), do: @invalid, else: :ok
    end
  end

  def validate_reply_ids(_request, _reply), do: :ok

  defp rendered_ids(envelope, messages) do
    replacements =
      Map.new((envelope && envelope["entries"]) || [], fn entry ->
        {entry["assistant_message_index"], Enum.map(entry["calls"], & &1["native_id"])}
      end)

    messages
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {message, index}, {:ok, ids} ->
      case Map.fetch(replacements, index) do
        {:ok, native} ->
          {:cont, {:ok, native ++ ids}}

        :error ->
          case canonical_ids(message) do
            {:ok, canonical} -> {:cont, {:ok, canonical ++ ids}}
            _ -> {:halt, @invalid}
          end
      end
    end)
  end

  defp canonical_ids(%{"role" => "assistant"} = message) do
    calls = Map.get(message, "tool_calls", [])

    if is_list(calls) and length(calls) <= 128 and
         Enum.all?(calls, &(is_map(&1) and text?(&1["tool_call_id"]))) do
      {:ok, Enum.map(calls, & &1["tool_call_id"])}
    else
      @invalid
    end
  end

  defp canonical_ids(message) when is_map(message), do: {:ok, []}
  defp canonical_ids(_), do: @invalid

  defp entries([], _messages, _envelope, _previous, _blocks, _budget, _sources, _ids, reversed),
    do: {:ok, Enum.reverse(reversed)}

  defp entries(
         [entry | rest],
         messages,
         envelope,
         previous,
         blocks,
         budget,
         sources,
         ids,
         reversed
       ) do
    with true <- closed?(entry, @entry_keys),
         source <- entry["source"],
         true <- valid_source?(source),
         true <- source["operation_id"] == envelope["exchange_id"] or reversed != [],
         true <- reversed == [] or source["run_id"] == hd(reversed)["source"]["run_id"],
         identity = Map.take(source, ~w(run_id turn_id operation_id attempt)),
         false <- MapSet.member?(sources, identity),
         index when is_integer(index) and index > previous <- entry["assistant_message_index"],
         %{"role" => "assistant", "content" => text, "tool_calls" => calls} <-
           at(
             messages,
             index
           ),
         true <- is_list(calls) and calls != [] and length(calls) <= 128,
         true <- Enum.all?(calls, &is_map/1),
         capsule when is_map(capsule) <- entry["capsule"],
         true <- capsule["model"] == envelope["model"] and capsule["status"] == "open",
         {:ok, native} <-
           ContentReferences.expand(capsule, text, Enum.map(calls, &Map.get(&1, "arguments"))),
         true <- blocks + length(native) <= 128,
         native_ids =
           for(%{"kind" => "tool_use_ref", "native_id" => id} <- capsule["content"], do: id),
         {:ok, last, ids} <- calls(entry["calls"], calls, native_ids, messages, index, ids),
         expanded = %{entry | "capsule" => %{capsule | "content" => native}},
         {:ok, size} <- ContentReferences.json_size(expanded),
         remaining = budget - size - if(reversed == [], do: 0, else: 1),
         true <- remaining >= 0 do
      entries(
        rest,
        messages,
        envelope,
        last,
        blocks + length(native),
        remaining,
        MapSet.put(sources, identity),
        ids,
        [expanded | reversed]
      )
    else
      _ -> @invalid
    end
  end

  defp calls([], [], [], _messages, previous, ids), do: {:ok, previous, ids}

  defp calls([binding | rest], [call | calls], [native | native_ids], messages, previous, ids) do
    with true <- closed?(binding, @call_keys),
         id when is_binary(id) <- call["tool_call_id"],
         true <- text?(id) and binding["canonical_call_id"] == id,
         true <- binding["native_id"] == native,
         false <- MapSet.member?(ids, {:canonical, id}),
         false <- MapSet.member?(ids, {:native, native}),
         index when is_integer(index) and index > previous <- binding["result_message_index"],
         %{"role" => "tool", "tool_call_id" => ^id} <- at(messages, index) do
      calls(
        rest,
        calls,
        native_ids,
        messages,
        index,
        ids |> MapSet.put({:canonical, id}) |> MapSet.put({:native, native})
      )
    else
      _ -> @invalid
    end
  end

  defp calls(_, _, _, _, _, _), do: @invalid

  defp valid_source?(source) do
    closed?(source, @source_keys) and
      Enum.all?(~w(run_id turn_id operation_id), &text?(source[&1])) and
      source["attempt"] in [1, 2] and digest?(source["settlement_digest"])
  end

  defp at(messages, index) when is_integer(index) and index >= 0 and index < tuple_size(messages),
    do: elem(messages, index)

  defp at(_, _), do: nil

  defp closed?(value, keys),
    do: is_map(value) and map_size(value) == length(keys) and Enum.sort(Map.keys(value)) == keys

  defp text?(value), do: is_binary(value) and byte_size(value) > 0 and String.valid?(value)

  defp digest?(value),
    do: is_binary(value) and byte_size(value) == 64 and Regex.match?(~r/\A[0-9a-f]{64}\z/, value)
end
