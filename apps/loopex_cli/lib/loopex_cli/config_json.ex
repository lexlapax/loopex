defmodule LoopexCli.ConfigJson do
  @moduledoc """
  ## Concept

  Decode authored host configuration without losing duplicate members, integer
  precision or the location of a refusal. Errors expose a class and JSON pointer,
  never an input value or parser exception.

  ## Technical depth

  OTP 27's standard-library decoder supplies JSON syntax and Unicode handling.
  Object callbacks retain ordered pairs until a separate traversal checks
  duplicates, including escaped spellings of the same key. Integer decoding
  retains the BEAM integer domain. Fraction/exponent numbers become a fixed
  marker for subsequent integer-only schema checks, including numbers outside
  the floating-point range. Input is UTF-8, at most 256 KiB, and an object;
  nesting stops at sixteen containers, beyond every admitted configuration
  shape. Trailing bytes must be JSON whitespace. No input creates atoms.
  """

  @bytes 262_144
  @depth 16

  @doc """
  ## Concept

  Parse a complete bounded configuration object before schema validation.

  ## Technical depth

  Successful maps retain binary keys, lists, strings, integers, booleans and nil.
  The internal `{:non_integer_number}` marker retains the distinction between
  an authored integer and fraction/exponent syntax without rounding or retaining
  that token. Schema validation must refuse it at the owning field's pointer.
  Duplicate pointers follow RFC 6901, including array indices and escaped keys.
  """
  @spec decode(term()) :: {:ok, map()} | {:error, {atom(), binary()}}
  def decode(bytes) when is_binary(bytes) do
    cond do
      byte_size(bytes) > @bytes -> error(:configuration_too_large)
      not String.valid?(bytes) -> error(:invalid_utf8)
      true -> parse(bytes)
    end
  end

  def decode(_), do: error(:invalid_configuration)

  defp parse(bytes) do
    case :json.decode(bytes, {0, []}, decoders()) do
      {{:object, pairs}, _, rest} ->
        if whitespace?(rest), do: object(pairs, "", %{}), else: error(:trailing_bytes)

      _other ->
        error(:not_an_object)
    end
  rescue
    _exception -> error(:malformed_json)
  catch
    :throw, :configuration_nesting_too_deep -> error(:configuration_nesting_too_deep)
  end

  defp decoders do
    %{
      object_start: &start_container/1,
      object_push: fn key, value, {depth, pairs} -> {depth, [{key, value} | pairs]} end,
      object_finish: fn {_, pairs}, outer -> {{:object, Enum.reverse(pairs)}, outer} end,
      array_start: &start_container/1,
      array_push: fn value, {depth, values} -> {depth, [value | values]} end,
      array_finish: fn {_, values}, outer -> {Enum.reverse(values), outer} end,
      float: fn _token -> {:non_integer_number} end,
      null: nil
    }
  end

  defp start_container({depth, _}) when depth < @depth, do: {depth + 1, []}
  defp start_container(_), do: throw(:configuration_nesting_too_deep)

  defp object([], _pointer, result), do: {:ok, result}

  defp object([{key, value} | rest], pointer, result) do
    child_pointer = pointer <> "/" <> escape_pointer(key)

    if Map.has_key?(result, key) do
      {:error, {:duplicate_member, child_pointer}}
    else
      with {:ok, normalized} <- normalize(value, child_pointer) do
        object(rest, pointer, Map.put(result, key, normalized))
      end
    end
  end

  defp normalize({:object, pairs}, pointer), do: object(pairs, pointer, %{})
  defp normalize(values, pointer) when is_list(values), do: array(values, pointer, 0, [])
  defp normalize(value, _pointer), do: {:ok, value}

  defp array([], _pointer, _index, result), do: {:ok, Enum.reverse(result)}

  defp array([value | rest], pointer, index, result) do
    with {:ok, normalized} <- normalize(value, pointer <> "/" <> Integer.to_string(index)) do
      array(rest, pointer, index + 1, [normalized | result])
    end
  end

  defp escape_pointer(key), do: key |> String.replace("~", "~0") |> String.replace("/", "~1")

  defp whitespace?(<<>>), do: true
  defp whitespace?(<<byte, rest::binary>>) when byte in [9, 10, 13, 32], do: whitespace?(rest)
  defp whitespace?(_), do: false

  defp error(class), do: {:error, {class, ""}}
end
