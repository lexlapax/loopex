defmodule LoopexProtocol.Session.Answer do
  @moduledoc """
  ## Concept

  The closed response branches shared by session command admission and the
  coordinated M7 foreground and daemon contracts. An answer names a choice,
  supplies text, or explicitly declines. Its shape grants no authority and
  does not decide whether the retained question offers that branch.

  ## Technical depth

  ADR 0045 admits nonempty UTF-8 text up to 8,192 bytes and the literal decline
  disposition. Choice identities remain opaque bytes within the existing
  65,536-byte input-command ceiling. Wire choices use ADR 0023's unpadded
  base64url representation. Core callers may use fixed atom or binary keys;
  wire callers must use binary keys. Mixed or extra members refuse.

  This module unifies the response-shape checks needed by core admission,
  foreground mapping and daemon request parsing. Retained-question validation
  stays with its owner. No server enables these additions before the complete
  M7 generation and schema switch.
  """

  alias LoopexProtocol.Wire

  @typedoc """
  ## Concept

  A normalized response with exactly one branch.

  ## Technical depth

  Binary-key maps contain opaque choice bytes, bounded UTF-8 text, or the
  separate declined disposition. A question's offered choices and producer
  still determine whether the owner may admit it.
  """
  @type t ::
          %{required(binary()) => binary()}

  @doc """
  ## Concept

  Normalize one core response while retaining its exact content.

  ## Technical depth

  Only the six fixed key spellings match; no input creates an atom. The
  choice ceiling preserves historical nested choice-command admission.
  """
  @spec normalize(term()) :: {:ok, t()} | :error
  def normalize(answer) when is_map(answer) and not is_struct(answer) and map_size(answer) == 1 do
    case Map.to_list(answer) do
      [{key, id}]
      when key in [:choice_id, "choice_id"] and is_binary(id) and byte_size(id) in 1..65_536 ->
        {:ok, %{"choice_id" => id}}

      [{key, text}]
      when key in [:text, "text"] and is_binary(text) and byte_size(text) in 1..8_192 ->
        if String.valid?(text), do: {:ok, %{"text" => text}}, else: :error

      [{key, "declined"}] when key in [:disposition, "disposition"] ->
        {:ok, %{"disposition" => "declined"}}

      _ ->
        :error
    end
  end

  def normalize(_), do: :error

  @doc """
  ## Concept

  Decode one wire response into the owner's plain response shape.

  ## Technical depth

  Choice bytes are decoded exactly once. Text and decline retain their bytes;
  atom keys, padding, empty identities and extra members refuse before owner
  admission. Correlation and controller authority belong to the enclosing
  request, not to this decoder.
  """
  @spec decode_wire(term()) :: {:ok, t()} | :error
  def decode_wire(%{"choice_id" => id} = answer)
      when map_size(answer) == 1 and is_binary(id) and byte_size(id) <= 87_382 do
    case Wire.identity(id) do
      {:ok, bytes} -> {:ok, %{"choice_id" => bytes}}
      :error -> :error
    end
  end

  def decode_wire(%{"text" => _} = answer), do: normalize(answer)
  def decode_wire(%{"disposition" => _} = answer), do: normalize(answer)
  def decode_wire(_), do: :error
end
