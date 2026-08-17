defmodule Loopex.Checks.Json do
  @moduledoc """
  ## Concept

  A complete JSON reader for repository checks. Client configuration is JSON, and
  once the previous bridge is retired the checks must read it themselves rather
  than shelling out to an external processor — while keeping the property that
  processor gave: a malformed configuration is a failure, not a partially read
  document.

  Core carries no dependency, so this is stdlib and OTP only.

  ## Technical depth

  Recursive descent over the whole document with no tolerance: an unterminated
  string, a trailing comma, a duplicate object key, an unescaped control
  character, or trailing content after the top-level value all fail. Duplicate
  keys matter here specifically — a tolerant reader keeps one silently, and a
  configuration with two `hooks` keys would then be read differently by the check
  and by the client.

  Escapes include surrogate pairs, so a configuration containing an astral
  character round-trips instead of failing or producing a lone surrogate.
  """

  @doc """
  ## Concept

  Reads one JSON document into maps, lists, strings, numbers, booleans, and `nil`.

  ## Technical depth

  Returns `{:ok, value}` or `{:error, reason}`. Object keys become strings, never
  atoms: the input is untrusted configuration, and interning arbitrary text as
  atoms is unbounded growth in a table that is never reclaimed.
  """
  @spec decode(binary()) :: {:ok, term()} | {:error, String.t()}
  def decode(text) when is_binary(text) do
    case value(skip_space(text)) do
      {:ok, parsed, rest} ->
        case skip_space(rest) do
          "" -> {:ok, parsed}
          _trailing -> {:error, "trailing content after the JSON document"}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp skip_space(<<char, rest::binary>>) when char in [?\s, ?\t, ?\n, ?\r], do: skip_space(rest)
  defp skip_space(text), do: text

  defp value(<<"{", rest::binary>>), do: object(skip_space(rest), %{})
  defp value(<<"[", rest::binary>>), do: array(skip_space(rest), [])
  defp value(<<"\"", rest::binary>>), do: string(rest, [])
  defp value(<<"true", rest::binary>>), do: {:ok, true, rest}
  defp value(<<"false", rest::binary>>), do: {:ok, false, rest}
  defp value(<<"null", rest::binary>>), do: {:ok, nil, rest}
  defp value(<<char, _rest::binary>> = text) when char in ?0..?9 or char == ?-, do: number(text)
  defp value(""), do: {:error, "unexpected end of JSON input"}

  defp value(<<char, _rest::binary>>),
    do: {:error, "unexpected JSON character #{inspect(<<char>>)}"}

  defp object(<<"}", rest::binary>>, acc) when map_size(acc) == 0, do: {:ok, acc, rest}

  defp object(<<"\"", rest::binary>>, acc) do
    with {:ok, key, rest} <- string(rest, []),
         <<":", rest::binary>> <- skip_space(rest),
         {:ok, parsed, rest} <- value(skip_space(rest)),
         false <- Map.has_key?(acc, key) do
      case skip_space(rest) do
        <<",", rest::binary>> -> object(skip_space(rest), Map.put(acc, key, parsed))
        <<"}", rest::binary>> -> {:ok, Map.put(acc, key, parsed), rest}
        _other -> {:error, "expected , or } in a JSON object"}
      end
    else
      true -> {:error, "duplicate key in a JSON object"}
      {:error, reason} -> {:error, reason}
      _other -> {:error, "malformed JSON object member"}
    end
  end

  defp object(_text, _acc), do: {:error, "expected a quoted key in a JSON object"}

  defp array(<<"]", rest::binary>>, []), do: {:ok, [], rest}

  defp array(text, acc) do
    case value(text) do
      {:ok, parsed, rest} ->
        case skip_space(rest) do
          <<",", rest::binary>> -> array(skip_space(rest), [parsed | acc])
          <<"]", rest::binary>> -> {:ok, Enum.reverse([parsed | acc]), rest}
          _other -> {:error, "expected , or ] in a JSON array"}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp string(<<"\"", rest::binary>>, acc), do: {:ok, IO.iodata_to_binary(acc), rest}
  defp string(<<"\\", "\"", rest::binary>>, acc), do: string(rest, [acc, "\""])
  defp string(<<"\\", "\\", rest::binary>>, acc), do: string(rest, [acc, "\\"])
  defp string(<<"\\", "/", rest::binary>>, acc), do: string(rest, [acc, "/"])
  defp string(<<"\\", "b", rest::binary>>, acc), do: string(rest, [acc, "\b"])
  defp string(<<"\\", "f", rest::binary>>, acc), do: string(rest, [acc, "\f"])
  defp string(<<"\\", "n", rest::binary>>, acc), do: string(rest, [acc, "\n"])
  defp string(<<"\\", "r", rest::binary>>, acc), do: string(rest, [acc, "\r"])
  defp string(<<"\\", "t", rest::binary>>, acc), do: string(rest, [acc, "\t"])

  defp string(<<"\\", "u", hex::binary-size(4), rest::binary>>, acc) do
    with {code, ""} <- Integer.parse(hex, 16) do
      escaped(code, rest, acc)
    else
      _other -> {:error, "malformed JSON unicode escape"}
    end
  end

  defp string(<<"\\", _rest::binary>>, _acc), do: {:error, "unsupported JSON string escape"}

  defp string(<<char, _rest::binary>>, _acc) when char < 0x20,
    do: {:error, "unescaped control character in a JSON string"}

  defp string(<<char::utf8, rest::binary>>, acc), do: string(rest, [acc, <<char::utf8>>])
  defp string(<<>>, _acc), do: {:error, "unterminated JSON string"}
  defp string(_text, _acc), do: {:error, "invalid UTF-8 in a JSON string"}

  # Concept: a surrogate pair is one character written as two escapes.
  # Technical depth: a lone surrogate is rejected rather than emitted, because it
  # is not a valid codepoint and would make the decoded value unprintable.
  defp escaped(high, <<"\\", "u", hex::binary-size(4), rest::binary>>, acc)
       when high in 0xD800..0xDBFF do
    case Integer.parse(hex, 16) do
      {low, ""} when low in 0xDC00..0xDFFF ->
        code = 0x10000 + (high - 0xD800) * 0x400 + (low - 0xDC00)
        string(rest, [acc, <<code::utf8>>])

      _other ->
        {:error, "unpaired JSON surrogate escape"}
    end
  end

  defp escaped(code, _rest, _acc) when code in 0xD800..0xDFFF do
    {:error, "unpaired JSON surrogate escape"}
  end

  defp escaped(code, rest, acc), do: string(rest, [acc, <<code::utf8>>])

  defp number(text) do
    case Regex.run(~r/\A-?(?:0|[1-9][0-9]*)(\.[0-9]+)?([eE][-+]?[0-9]+)?/u, text) do
      [matched | groups] ->
        rest = binary_part(text, byte_size(matched), byte_size(text) - byte_size(matched))

        case Enum.all?(groups, &(&1 == "")) do
          true -> {:ok, String.to_integer(matched), rest}
          false -> {:ok, String.to_float(normalise_float(matched)), rest}
        end

      nil ->
        {:error, "malformed JSON number"}
    end
  end

  # Concept: Elixir's float reader needs a fractional part before an exponent.
  defp normalise_float(matched) do
    case String.contains?(matched, ".") do
      true -> matched
      false -> String.replace(matched, ~r/[eE]/u, ".0e", global: false)
    end
  end
end
