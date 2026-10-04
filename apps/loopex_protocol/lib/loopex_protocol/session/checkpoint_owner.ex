defmodule LoopexProtocol.Session.CheckpointOwner do
  @moduledoc """
  ## Concept

  Identify the actual run or compact command that owns a public checkpoint.
  Foreground and daemon event projections share this closed ownership contract.

  ## Technical depth

  The approved ADR 0043 amendment fixes exactly `kind` and `id`. Native IDs
  are opaque binaries; wire IDs use canonical unpadded base64url. Decoding
  authenticates neither ownership nor authority; the session reducer does that.
  No old owning `run_id` alias is admitted.
  """

  alias LoopexProtocol.Wire

  @doc """
  ## Concept

  Encode the actual checkpoint owner without interpreting its identity bytes.

  ## Technical depth

  Require a plain two-member map, kind `run` or `compact`, and 1–65,536 bytes.
  """
  @spec encode_wire(term()) :: {:ok, map()} | :error
  def encode_wire(%{"kind" => kind, "id" => id} = value)
      when not is_struct(value) and map_size(value) == 2 and kind in ["run", "compact"] and
             is_binary(id) and byte_size(id) in 1..65_536,
      do: {:ok, %{"kind" => kind, "id" => Wire.encode_identity(id)}}

  def encode_wire(_), do: :error

  @doc """
  ## Concept

  Recover the opaque owner identity from its current public shape.

  ## Technical depth

  Reject unknown members and kinds, padded or alternate identity spellings,
  and identifiers outside the existing Wire identity ceiling.
  """
  @spec decode_wire(term()) :: {:ok, map()} | :error
  def decode_wire(%{"kind" => kind, "id" => id} = value)
      when not is_struct(value) and map_size(value) == 2 and kind in ["run", "compact"] do
    with {:ok, native} <- Wire.identity(id),
         true <- Wire.encode_identity(native) == id do
      {:ok, %{"kind" => kind, "id" => native}}
    else
      _ -> :error
    end
  end

  def decode_wire(_), do: :error
end
