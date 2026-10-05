defmodule LoopexProtocol.Session.CommandBounds do
  @moduledoc """
  ## Concept

  Preserve the authored bounds of prompt, follow-up and compact commands across
  the shared session boundary. This codec validates data; it admits no command.

  ## Technical depth

  The accepted M7 command-bounds decision fixes closed binary-key objects.
  Prompt allows optional max_turns, token_budget, deadline_ms and deadline_at_ms;
  follow-up allows only optional deadline_at_ms. Compact requires max_attempts,
  deadline_ms and token_budget. Decimal quantities decode to native integers;
  absolute deadlines remain JSON-safe integers. Unknown and null values refuse.
  An enclosing request preserves an omitted bounds member without calling this
  object codec. Empty and partial optional objects remain exactly authored.
  No defaults, clock reads, dispatch or atom creation occur here.
  """

  @u64 18_446_744_073_709_551_615
  @json_integer_max 9_007_199_254_740_991
  @fields %{
    prompt: %{
      "max_turns" => nil,
      "token_budget" => nil,
      "deadline_ms" => @u64,
      "deadline_at_ms" => :json_integer
    },
    follow_up: %{"deadline_at_ms" => :json_integer},
    compact: %{"max_attempts" => 4, "deadline_ms" => 60_000, "token_budget" => 32_768}
  }

  @typedoc """
  ## Concept

  The existing command kinds that select the bounds grammar.

  ## Technical depth

  These fixed atoms match native command names. Unrecognized kinds refuse;
  wire input never becomes an atom.
  """
  @type kind :: :prompt | :follow_up | :compact

  @doc """
  ## Concept

  Decode one authored bounds object without changing its supplied members.

  ## Technical depth

  Positive canonical decimal strings retain arbitrary precision for prompt
  turns and tokens. Prompt duration is positive uint64. Absolute deadlines are
  positive JSON integers at most 9007199254740991. Compact quantities retain the
  accepted 4-attempt, 60000-ms and 32768-token maxima. Missing compact members,
  atom keys, extra members and malformed scalar values refuse.
  """
  @spec decode_wire(term(), kind()) :: {:ok, map()} | :error
  def decode_wire(bounds, kind), do: project(bounds, kind, :decode)

  @doc """
  ## Concept

  Encode native bounds while retaining the exact authored key set.

  ## Technical depth

  Native quantities must be positive integers in their declared domains.
  Decimal fields become strings and absolute deadlines remain integers. Empty
  prompt/follow-up objects survive; absence belongs to the enclosing request.
  Encoding supplies no defaults and reads no clock.
  """
  @spec encode_wire(term(), kind()) :: {:ok, map()} | :error
  def encode_wire(bounds, kind), do: project(bounds, kind, :encode)

  defp project(bounds, kind, mode)
       when is_map(bounds) and not is_struct(bounds) and kind in [:prompt, :follow_up, :compact] do
    fields = Map.fetch!(@fields, kind)

    if Enum.all?(Map.keys(bounds), &Map.has_key?(fields, &1)) and
         (kind != :compact or map_size(bounds) == map_size(fields)) do
      Enum.reduce_while(bounds, {:ok, %{}}, fn {key, value}, {:ok, converted} ->
        case quantity(value, Map.fetch!(fields, key), mode) do
          {:ok, result} -> {:cont, {:ok, Map.put(converted, key, result)}}
          :error -> {:halt, :error}
        end
      end)
    else
      :error
    end
  end

  defp project(_, _, _), do: :error

  defp quantity(value, :json_integer, _mode)
       when is_integer(value) and value > 0 and value <= @json_integer_max,
       do: {:ok, value}

  defp quantity(_, :json_integer, _mode), do: :error

  defp quantity(value, maximum, :decode) when is_binary(value) do
    if Regex.match?(~r/\A[1-9][0-9]*\z/, value) do
      integer = String.to_integer(value)
      if maximum == nil or integer <= maximum, do: {:ok, integer}, else: :error
    else
      :error
    end
  end

  defp quantity(value, maximum, :encode) when is_integer(value) and value > 0 do
    if maximum == nil or value <= maximum, do: {:ok, Integer.to_string(value)}, else: :error
  end

  defp quantity(_, _, _), do: :error
end
