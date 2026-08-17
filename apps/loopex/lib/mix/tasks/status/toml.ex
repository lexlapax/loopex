defmodule Loopex.Checks.Toml do
  @moduledoc """
  ## Concept

  Reads the deliberately small TOML subset the repository's client adapter
  configuration is written in: table headers, quoted strings, multi-line strings,
  and booleans. Nothing else is accepted.

  Rejecting the rest is the design, not a limitation. The adapter check asserts
  things like "this profile declares exactly these keys", and a reader that
  quietly skipped a construct it did not understand would let a key the check
  never saw sit in the file.

  ## Technical depth

  Line oriented, with no dependency. A line is a table header, a key assignment,
  a full-line comment, or blank; anything else fails. Trailing comments after a
  value are not supported, because supporting them means deciding whether a `#`
  inside a quoted string opens one — and the configuration this reads has no need
  for either.

  Duplicate keys and duplicate table headers fail, since both make the effective
  configuration depend on the reader rather than on the file.
  """

  @header ~r/\A\[([A-Za-z0-9_.-]+)\]\z/u
  @assignment ~r/\A([A-Za-z0-9_-]+)[ \t]*=[ \t]*(.*)\z/u

  @doc """
  ## Concept

  Reads one TOML document into nested maps with string keys.

  ## Technical depth

  Returns `{:ok, map}` or `{:error, reason}`. Tables are created as they are
  named, so a table header establishes the path every following assignment lands
  in until the next header.
  """
  @spec decode(binary()) :: {:ok, map()} | {:error, String.t()}
  def decode(text) when is_binary(text) do
    text
    |> String.split("\n")
    |> parse([], %{}, MapSet.new())
  end

  defp parse([], _path, document, _seen), do: {:ok, document}

  defp parse([line | rest], path, document, seen) do
    trimmed = String.trim(line)

    cond do
      trimmed == "" or String.starts_with?(trimmed, "#") ->
        parse(rest, path, document, seen)

      header = Regex.run(@header, trimmed) ->
        [_all, name] = header
        new_path = String.split(name, ".")

        case MapSet.member?(seen, new_path) do
          true ->
            {:error, "duplicate TOML table [#{name}]"}

          false ->
            parse(rest, new_path, put_table(document, new_path), MapSet.put(seen, new_path))
        end

      assignment = Regex.run(@assignment, trimmed) ->
        [_all, key, raw] = assignment
        assign(rest, path, document, seen, key, raw)

      true ->
        {:error, "unsupported TOML line #{inspect(trimmed)}"}
    end
  end

  defp assign(rest, path, document, seen, key, raw) do
    with {:ok, value, remaining} <- read_value(raw, rest),
         false <- has_key?(document, path ++ [key]) do
      parse(remaining, path, put_in_path(document, path ++ [key], value), seen)
    else
      true -> {:error, "duplicate TOML key #{inspect(key)}"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp read_value("true", rest), do: {:ok, true, rest}
  defp read_value("false", rest), do: {:ok, false, rest}

  defp read_value("\"\"\"", rest), do: multiline(rest, [])

  defp read_value(<<"\"", _remainder::binary>> = raw, rest) do
    case basic_string(binary_part(raw, 1, byte_size(raw) - 1), []) do
      {:ok, value} -> {:ok, value, rest}
      {:error, reason} -> {:error, reason}
    end
  end

  defp read_value(raw, _rest), do: {:error, "unsupported TOML value #{inspect(raw)}"}

  defp multiline([], _acc), do: {:error, "unterminated multi-line TOML string"}

  defp multiline([line | rest], acc) do
    case String.trim(line) == "\"\"\"" do
      true -> {:ok, Enum.join(Enum.reverse(acc), "\n") <> "\n", rest}
      false -> multiline(rest, [line | acc])
    end
  end

  defp basic_string(<<"\"">>, acc), do: {:ok, IO.iodata_to_binary(acc)}
  defp basic_string(<<"\\", "\"", rest::binary>>, acc), do: basic_string(rest, [acc, "\""])
  defp basic_string(<<"\\", "\\", rest::binary>>, acc), do: basic_string(rest, [acc, "\\"])
  defp basic_string(<<"\\", "n", rest::binary>>, acc), do: basic_string(rest, [acc, "\n"])
  defp basic_string(<<"\\", "t", rest::binary>>, acc), do: basic_string(rest, [acc, "\t"])
  defp basic_string(<<"\\", _rest::binary>>, _acc), do: {:error, "unsupported TOML escape"}

  defp basic_string(<<char::utf8, rest::binary>>, acc),
    do: basic_string(rest, [acc, <<char::utf8>>])

  defp basic_string(<<>>, _acc), do: {:error, "unterminated TOML string"}
  defp basic_string(_text, _acc), do: {:error, "invalid UTF-8 in a TOML string"}

  defp put_table(document, path) do
    case get_in_path(document, path) do
      nil -> put_in_path(document, path, %{})
      _existing -> document
    end
  end

  defp has_key?(document, path) do
    case get_in_path(document, path) do
      nil -> false
      _value -> true
    end
  end

  defp get_in_path(document, []), do: document

  defp get_in_path(document, [key | rest]) when is_map(document) do
    case Map.fetch(document, key) do
      {:ok, value} -> get_in_path(value, rest)
      :error -> nil
    end
  end

  defp get_in_path(_document, _path), do: nil

  defp put_in_path(_document, [], value), do: value

  defp put_in_path(document, [key | rest], value) when is_map(document) do
    Map.put(document, key, put_in_path(Map.get(document, key) || %{}, rest, value))
  end
end
