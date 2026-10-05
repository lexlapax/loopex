defmodule LoopexProtocol.Session.ActiveBounds do
  @moduledoc """
  ## Concept

  Preserve an active run's committed bounds in one shared inspection object.
  This codec validates the object and supplies no defaults or clock values.

  ## Technical depth

  The accepted M7 inspection decision fixes four required binary-key members.
  Turns and tokens retain arbitrary positive integers; relative duration is
  positive uint64. The effective absolute deadline is nil until committed,
  then nonnegative uint64. Wire quantities are canonical decimal strings.
  The enclosing inspection handles a null active_bounds slot. This object
  codec refuses null, unknown members, malformed scalars and private values.
  """

  @u64 18_446_744_073_709_551_615
  @keys ~w(max_turns token_budget deadline_ms deadline)

  @doc """
  ## Concept

  Decode the exact four-member active bounds object.

  ## Technical depth

  Decimal strings decode to native integers without rounding or narrowing
  turns and tokens. Only deadline accepts nil or the canonical zero string.
  No clock, authored deadline_at_ms or missing member supplies a cutoff.
  """
  @spec decode_wire(term()) :: {:ok, map()} | :error
  def decode_wire(value), do: project(value, :decode)

  @doc """
  ## Concept

  Encode only the committed native bounds allowlist.

  ## Technical depth

  Native quantities must be integers in their exact domains. Deadline nil
  remains null; every integer becomes a canonical decimal string. Atom keys,
  structs, floats, extra members and missing members refuse.
  """
  @spec encode_wire(term()) :: {:ok, map()} | :error
  def encode_wire(value), do: project(value, :encode)

  defp project(value, mode) when is_map(value) and not is_struct(value) do
    if Enum.sort(Map.keys(value)) == Enum.sort(@keys) do
      Enum.reduce_while(@keys, {:ok, %{}}, fn key, {:ok, result} ->
        case quantity(value[key], key, mode) do
          {:ok, scalar} -> {:cont, {:ok, Map.put(result, key, scalar)}}
          :error -> {:halt, :error}
        end
      end)
    else
      :error
    end
  end

  defp project(_, _), do: :error

  defp quantity(nil, "deadline", _mode), do: {:ok, nil}

  defp quantity(value, key, :decode) when is_binary(value) do
    if Regex.match?(~r/\A(?:0|[1-9][0-9]*)\z/, value) do
      integer = String.to_integer(value)
      if in_domain?(integer, key), do: {:ok, integer}, else: :error
    else
      :error
    end
  end

  defp quantity(value, key, :encode) when is_integer(value) do
    if in_domain?(value, key), do: {:ok, Integer.to_string(value)}, else: :error
  end

  defp quantity(_, _, _), do: :error

  defp in_domain?(integer, "deadline"), do: integer >= 0 and integer <= @u64
  defp in_domain?(integer, "deadline_ms"), do: integer > 0 and integer <= @u64
  defp in_domain?(integer, key) when key in ["max_turns", "token_budget"], do: integer > 0
end
