defmodule LoopexProtocol.Frame do
  @moduledoc """
  ## Concept

  One line of the wire: a single JSON object, and the rules that decide whether
  it is admissible at all. A frame that breaks any of them is refused before
  anything reads its contents, so a malformed or oversized frame can never
  become a request.

  ## Technical depth

  Accepted ADR 0023 fixes the framing, and this decoder implements it without a
  JSON library, because the protocol application carries no dependency. What it
  gives up in generality it spends on the properties the decision needs and a
  general decoder does not provide: object members are parsed in order so a
  duplicate key is refused rather than silently resolved, keys stay binaries so
  no input is ever interned, depth and member counts are bounded while parsing
  rather than after, and an integer outside the range both sides can round-trip
  is refused rather than truncated.

  Numbers with a fraction or an exponent are refused outright. Every quantity in
  this protocol that can reach the unsigned 64-bit domain travels as a decimal
  string precisely so that no float ever has to represent it, so admitting one
  would only create a value with no meaning here.
  """

  @max_depth 16
  @max_members 1_024
  @max_string_bytes 131_072
  @integer_max 9_007_199_254_740_991
  @integer_min -9_007_199_254_740_991
  @output_record_bytes 2_097_152

  @type reason ::
          :frame_too_large
          | :invalid_utf8
          | :not_an_object
          | :trailing_bytes
          | :truncated
          | :duplicate_member
          | :depth_exceeded
          | :too_many_members
          | :string_too_large
          | :integer_out_of_range
          | :number_not_an_integer
          | :malformed

  @doc """
  ## Concept

  Decodes one frame's payload, without its delimiting newline.

  ## Technical depth

  The caller supplies the ceiling in force, because it differs before and after
  initialization and the decoder has no connection state of its own. Size is
  checked before anything is parsed, so an oversized frame costs a length
  comparison rather than a traversal.
  """
  @spec decode(binary(), pos_integer()) :: {:ok, map()} | {:error, reason()}
  def decode(payload, limit) when is_binary(payload) and is_integer(limit) and limit > 0 do
    cond do
      byte_size(payload) > limit -> {:error, :frame_too_large}
      not String.valid?(payload) -> {:error, :invalid_utf8}
      true -> decode_object_frame(payload)
    end
  end

  @doc """
  ## Concept

  The maximum encoded size of one output record, newline included.
  """
  @spec output_record_bytes() :: pos_integer()
  def output_record_bytes, do: @output_record_bytes

  @doc """
  ## Concept

  Encodes one server record as a frame, newline included.

  ## Technical depth

  Refuses rather than truncates a record that would exceed the output ceiling: a
  client that received half a record would have no way to tell it apart from one
  the server meant to send. Only plain data reaches this function, and an atom
  is admitted solely as a map key or as `true`, `false` and `nil`, so nothing
  from a runtime's term space can be rendered by accident.
  """
  @spec encode(map()) :: {:ok, iodata()} | {:error, :output_record_too_large}
  def encode(record) when is_map(record) do
    encoded = [encode_value(record), ?\n]

    if IO.iodata_length(encoded) > @output_record_bytes,
      do: {:error, :output_record_too_large},
      else: {:ok, encoded}
  end

  # Concept: a frame is one object and nothing else.
  #
  # Technical depth: no leading or trailing bytes are admitted, not even
  # whitespace. A reader splits on the newline, so anything else on the line is
  # a sender doing something the contract does not describe, and guessing what
  # it meant is exactly what a strict framing exists to avoid.
  defp decode_object_frame(<<?{, _rest::binary>> = payload) do
    case parse_value(payload, 1) do
      {:ok, value, rest} when rest == "" -> {:ok, value}
      {:ok, _value, _rest} -> {:error, :trailing_bytes}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_object_frame(""), do: {:error, :truncated}
  defp decode_object_frame(_payload), do: {:error, :not_an_object}

  # Concept: only a container is a level of nesting.
  #
  # Technical depth: the bound is on nested arrays and objects, so a scalar at
  # the bottom of an admitted structure is not the level that breaks it. Checked
  # on entry to each container rather than on every value, which is also where
  # the recursion could actually run away.
  defp parse_value(<<?{, _rest::binary>>, depth) when depth > @max_depth,
    do: {:error, :depth_exceeded}

  defp parse_value(<<?[, _rest::binary>>, depth) when depth > @max_depth,
    do: {:error, :depth_exceeded}

  defp parse_value(<<?{, rest::binary>>, depth) do
    with {:ok, members, rest} <- parse_members(skip_space(rest), depth, []) do
      keys = Enum.map(members, &elem(&1, 0))

      if length(Enum.uniq(keys)) == length(keys),
        do: {:ok, Map.new(members), rest},
        else: {:error, :duplicate_member}
    end
  end

  defp parse_value(<<?[, rest::binary>>, depth) do
    parse_elements(skip_space(rest), depth, [])
  end

  defp parse_value(<<?", rest::binary>>, _depth) do
    parse_string(rest, [])
  end

  defp parse_value(<<"true", rest::binary>>, _depth), do: {:ok, true, rest}
  defp parse_value(<<"false", rest::binary>>, _depth), do: {:ok, false, rest}
  defp parse_value(<<"null", rest::binary>>, _depth), do: {:ok, nil, rest}

  defp parse_value(<<byte, _::binary>> = input, _depth) when byte in ~c"-0123456789" do
    parse_number(input)
  end

  defp parse_value("", _depth), do: {:error, :truncated}
  defp parse_value(_input, _depth), do: {:error, :malformed}

  defp parse_members(<<?}, rest::binary>>, _depth, []), do: {:ok, [], rest}

  defp parse_members(_input, _depth, acc) when length(acc) >= @max_members,
    do: {:error, :too_many_members}

  defp parse_members(<<?", rest::binary>>, depth, acc) do
    with {:ok, key, rest} <- parse_string(rest, []),
         <<?:, rest::binary>> <- skip_space(rest),
         {:ok, value, rest} <- parse_value(skip_space(rest), depth + 1) do
      case skip_space(rest) do
        <<?,, rest::binary>> -> parse_members(skip_space(rest), depth, [{key, value} | acc])
        <<?}, rest::binary>> -> {:ok, Enum.reverse([{key, value} | acc]), rest}
        "" -> {:error, :truncated}
        _other -> {:error, :malformed}
      end
    else
      {:error, reason} -> {:error, reason}
      "" -> {:error, :truncated}
      _other -> {:error, :malformed}
    end
  end

  defp parse_members("", _depth, _acc), do: {:error, :truncated}
  defp parse_members(_input, _depth, _acc), do: {:error, :malformed}

  defp parse_elements(<<?], rest::binary>>, _depth, []), do: {:ok, [], rest}

  defp parse_elements(_input, _depth, acc) when length(acc) >= @max_members,
    do: {:error, :too_many_members}

  defp parse_elements(input, depth, acc) do
    with {:ok, value, rest} <- parse_value(input, depth + 1) do
      case skip_space(rest) do
        <<?,, rest::binary>> -> parse_elements(skip_space(rest), depth, [value | acc])
        <<?], rest::binary>> -> {:ok, Enum.reverse([value | acc]), rest}
        "" -> {:error, :truncated}
        _other -> {:error, :malformed}
      end
    end
  end

  # Concept: a JSON string, bounded and never interned.
  #
  # Technical depth: the bound is on the decoded bytes rather than on the
  # encoded ones, because an escape sequence costs six wire characters and one
  # byte, and the limit that matters is what the server ends up holding.
  defp parse_string(_input, acc) when length(acc) > @max_string_bytes,
    do: {:error, :string_too_large}

  defp parse_string(<<?", rest::binary>>, acc) do
    decoded = acc |> Enum.reverse() |> IO.iodata_to_binary()

    cond do
      byte_size(decoded) > @max_string_bytes -> {:error, :string_too_large}
      not String.valid?(decoded) -> {:error, :invalid_utf8}
      true -> {:ok, decoded, rest}
    end
  end

  defp parse_string(<<?\\, ?u, a, b, c, d, rest::binary>>, acc) do
    case Integer.parse(<<a, b, c, d>>, 16) do
      {code, ""} when code in 0xD800..0xDBFF -> parse_surrogate(code, rest, acc)
      {code, ""} when code in 0xDC00..0xDFFF -> {:error, :malformed}
      {code, ""} -> parse_string(rest, [<<code::utf8>> | acc])
      _other -> {:error, :malformed}
    end
  end

  defp parse_string(<<?\\, escape, rest::binary>>, acc) do
    case escape do
      ?" -> parse_string(rest, [?" | acc])
      ?\\ -> parse_string(rest, [?\\ | acc])
      ?/ -> parse_string(rest, [?/ | acc])
      ?b -> parse_string(rest, [?\b | acc])
      ?f -> parse_string(rest, [?\f | acc])
      ?n -> parse_string(rest, [?\n | acc])
      ?r -> parse_string(rest, [?\r | acc])
      ?t -> parse_string(rest, [?\t | acc])
      _other -> {:error, :malformed}
    end
  end

  # A raw control character inside a string is malformed JSON, and admitting one
  # would let a sender put a newline inside a line-delimited frame.
  defp parse_string(<<byte, _rest::binary>>, _acc) when byte < 0x20, do: {:error, :malformed}

  defp parse_string(<<character::utf8, rest::binary>>, acc),
    do: parse_string(rest, [<<character::utf8>> | acc])

  defp parse_string("", _acc), do: {:error, :truncated}
  defp parse_string(_input, _acc), do: {:error, :invalid_utf8}

  defp parse_surrogate(high, <<?\\, ?u, a, b, c, d, rest::binary>>, acc) do
    case Integer.parse(<<a, b, c, d>>, 16) do
      {low, ""} when low in 0xDC00..0xDFFF ->
        code = 0x10000 + (high - 0xD800) * 0x400 + (low - 0xDC00)
        parse_string(rest, [<<code::utf8>> | acc])

      _other ->
        {:error, :malformed}
    end
  end

  defp parse_surrogate(_high, _input, _acc), do: {:error, :malformed}

  # Concept: an integer both sides can round-trip, and nothing else.
  #
  # Technical depth: a fraction or an exponent is refused rather than rounded.
  # Every quantity here that can reach the unsigned 64-bit domain travels as a
  # decimal string for exactly this reason, so a float on the wire names nothing
  # this protocol has.
  defp parse_number(input) do
    {digits, rest} = take_number(input, [])

    cond do
      digits == "" ->
        {:error, :malformed}

      String.contains?(digits, [".", "e", "E"]) ->
        {:error, :number_not_an_integer}

      true ->
        case Integer.parse(digits) do
          {value, ""} when value >= @integer_min and value <= @integer_max ->
            {:ok, value, rest}

          {_value, ""} ->
            {:error, :integer_out_of_range}

          _other ->
            {:error, :malformed}
        end
    end
  end

  defp take_number(<<byte, rest::binary>>, acc)
       when byte in ~c"-+.eE0123456789" do
    take_number(rest, [byte | acc])
  end

  defp take_number(rest, acc), do: {acc |> Enum.reverse() |> IO.iodata_to_binary(), rest}

  defp skip_space(<<byte, rest::binary>>) when byte in [?\s, ?\t, ?\n, ?\r], do: skip_space(rest)
  defp skip_space(input), do: input

  defp encode_value(value) when is_map(value) do
    members =
      value
      |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
      |> Enum.map(fn {key, member} ->
        [encode_string(to_string(key)), ?:, encode_value(member)]
      end)
      |> Enum.intersperse(?,)

    [?{, members, ?}]
  end

  defp encode_value(value) when is_list(value) do
    [?[, value |> Enum.map(&encode_value/1) |> Enum.intersperse(?,), ?]]
  end

  defp encode_value(value) when is_binary(value), do: encode_string(value)
  defp encode_value(value) when is_integer(value), do: Integer.to_string(value)
  defp encode_value(true), do: "true"
  defp encode_value(false), do: "false"
  defp encode_value(nil), do: "null"
  defp encode_value(value) when is_atom(value), do: encode_string(Atom.to_string(value))

  defp encode_string(value) do
    [?", escape(value, []), ?"]
  end

  defp escape(<<>>, acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  defp escape(<<character::utf8, rest::binary>>, acc) do
    escaped =
      case character do
        ?" ->
          "\\\""

        ?\\ ->
          "\\\\"

        ?\b ->
          "\\b"

        ?\f ->
          "\\f"

        ?\n ->
          "\\n"

        ?\r ->
          "\\r"

        ?\t ->
          "\\t"

        code when code < 0x20 ->
          "\\u" <>
            (code |> Integer.to_string(16) |> String.pad_leading(4, "0") |> String.downcase())

        code ->
          <<code::utf8>>
      end

    escape(rest, [escaped | acc])
  end
end
