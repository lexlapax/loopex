defmodule LoopexComposition.Delegation.LedgerCodec do
  @moduledoc """
  ## Concept

  Retain exact helper-object bytes and identify private binding/run ledger
  headers without creating sessions, authorizing work or recovering a writer.

  ## Technical depth

  Accepted ADR 0056 fixes canonical JSON, the two closed header identities and
  checksummed binary framing. This private composition boundary reuses the wire
  encoder for validated maps, but parses exact private integers independently.
  JSON syntax and raw framing confer no object or transaction validity. Only
  header decoding validates its own complete schema and expected identity.
  No operation performs IO, admits a mutation or treats a torn header as a log.
  """

  alias LoopexProtocol.Frame

  @object_bytes 1_048_576
  @payload_bytes 65_536
  @depth 16
  @members 32
  @elements 16
  @identifier_bytes 256
  @magic "LXPHELP1"

  @doc false
  @spec encode_json(term(), :object | :frame) :: {:ok, binary()} | {:error, :invalid_ledger_bytes}
  def encode_json(value, class) when is_map(value) and class in [:object, :frame] do
    limit = limit(class)

    with remaining when is_integer(remaining) <- measure(value, 0, limit),
         {:ok, encoded} <- Frame.encode(value),
         true <- IO.iodata_length(encoded) - 1 <= limit do
      # Concept: remove the one wire delimiter, preserving every payload byte.
      # Technical depth: Frame.encode returns its payload and one literal LF;
      # premeasurement and iodata measurement precede flattening.
      bytes = IO.iodata_to_binary(encoded)
      {:ok, binary_part(bytes, 0, byte_size(bytes) - 1)}
    else
      _invalid -> error()
    end
  end

  def encode_json(_value, _class), do: error()

  @doc false
  @spec decode_json(term(), :object | :frame) :: {:ok, map()} | {:error, :invalid_ledger_bytes}
  def decode_json(bytes, class) when is_binary(bytes) and class in [:object, :frame] do
    if byte_size(bytes) in 1..limit(class) and String.valid?(bytes) do
      parse_json(bytes, class)
    else
      error()
    end
  end

  def decode_json(_bytes, _class), do: error()

  @doc false
  @spec encode_header(:binding | :run, [binary()]) ::
          {:ok, binary()} | {:error, :invalid_ledger_header}
  def encode_header(kind, identifiers) do
    with {:ok, header} <- header(kind, identifiers),
         {:ok, payload} <- encode_json(header, :frame),
         {:ok, frame} <- encode_frame(payload) do
      {:ok, frame}
    else
      _invalid -> {:error, :invalid_ledger_header}
    end
  end

  @doc false
  @spec decode_header(term(), :binding | :run, [binary()], term()) ::
          {:ok, map()} | {:error, :invalid_ledger_header | :incomplete_frame}
  def decode_header(bytes, kind, identifiers, expected_key) do
    with {:ok, expected} <- header(kind, identifiers),
         true <- expected_key == expected["identity_sha256"],
         {:ok, payload, ""} <- decode_frame(bytes),
         {:ok, decoded} <- decode_json(payload, :frame),
         true <- decoded == expected do
      {:ok, decoded}
    else
      {:error, :incomplete_frame} -> {:error, :incomplete_frame}
      _invalid -> {:error, :invalid_ledger_header}
    end
  end

  @doc false
  @spec header_key(:binding | :run, [binary()]) ::
          {:ok, binary()} | {:error, :invalid_ledger_header}
  def header_key(kind, identifiers) do
    case header(kind, identifiers) do
      {:ok, header} -> {:ok, header["identity_sha256"]}
      _invalid -> {:error, :invalid_ledger_header}
    end
  end

  @doc false
  @spec encode_frame(term()) :: {:ok, binary()} | {:error, :invalid_frame}
  def encode_frame(payload)
      when is_binary(payload) and byte_size(payload) in 1..@payload_bytes do
    prefix = <<@magic, 1::unsigned-16-big, byte_size(payload)::unsigned-32-big>>
    {:ok, prefix <> raw_hash(prefix) <> payload <> raw_hash(payload)}
  end

  def encode_frame(_payload), do: {:error, :invalid_frame}

  @doc false
  @spec decode_frame(term()) ::
          {:ok, binary(), binary()} | {:error, :invalid_frame | :incomplete_frame}
  def decode_frame(bytes) when is_binary(bytes) and byte_size(bytes) < 46,
    do: {:error, :incomplete_frame}

  def decode_frame(<<prefix::binary-14, checksum::binary-32, rest::binary>>) do
    # Concept: an authenticated length is required before payload interpretation.
    # Technical depth: verify the entire 46-byte header before extracting length;
    # complete bad/over-cap headers refuse even when the file ends there.
    if raw_hash(prefix) == checksum do
      case prefix do
        <<@magic, 1::unsigned-16-big, size::unsigned-32-big>>
        when size in 1..@payload_bytes ->
          payload(rest, size)

        _invalid ->
          {:error, :invalid_frame}
      end
    else
      {:error, :invalid_frame}
    end
  end

  def decode_frame(_bytes), do: {:error, :invalid_frame}

  defp payload(bytes, size) when byte_size(bytes) < size + 32,
    do: {:error, :incomplete_frame}

  defp payload(bytes, size) do
    <<payload::binary-size(^size), checksum::binary-32, rest::binary>> = bytes

    if raw_hash(payload) == checksum,
      do: {:ok, payload, rest},
      else: {:error, :invalid_frame}
  end

  defp header(:binding, [runtime, command]), do: make_header(:binding, [runtime, command])

  defp header(:run, [runtime, session, run]),
    do: make_header(:run, [runtime, session, run])

  defp header(_kind, _identifiers), do: {:error, :invalid_ledger_header}

  defp make_header(kind, identifiers) do
    if Enum.all?(identifiers, &identifier?/1) do
      identity = Enum.map(identifiers, &Base.encode64/1)
      ledger_kind = Atom.to_string(kind)
      label = "loopex:helper-" <> ledger_kind <> ":v1"

      # Concept: preimages retain original opaque IDs and their exact order.
      # Technical depth: these declared arrays contain only padded Base64 ASCII;
      # direct quoting is therefore the complete canonical J array recipe.
      preimage = ["[", Enum.intersperse(Enum.map(identity, &[?", &1, ?"]), ","), "]"]
      digest = :crypto.hash(:sha256, [label, <<0>>, preimage]) |> Base.encode16(case: :lower)

      {:ok,
       %{
         "version" => 1,
         "kind" => "header",
         "ledger_kind" => ledger_kind,
         "identity" => identity,
         "identity_sha256" => digest
       }}
    else
      {:error, :invalid_ledger_header}
    end
  end

  defp identifier?(value),
    do: is_binary(value) and byte_size(value) in 1..@identifier_bytes

  defp parse_json(bytes, class) do
    with {{:object, _pairs} = parsed, _state, ""} <-
           :json.decode(bytes, {0, 0, []}, decoders()),
         {:ok, value} <- normalize(parsed),
         {:ok, canonical} <- encode_json(value, class),
         true <- canonical == bytes do
      {:ok, value}
    else
      _invalid -> error()
    end
  rescue
    _exception -> error()
  catch
    :throw, :invalid_ledger_json -> error()
  end

  defp decoders do
    %{
      object_start: &start_container/1,
      object_push: &push_member/3,
      object_finish: fn {_, _, pairs}, outer -> {{:object, Enum.reverse(pairs)}, outer} end,
      array_start: &start_container/1,
      array_push: &push_element/2,
      array_finish: fn {_, _, values}, outer -> {Enum.reverse(values), outer} end,
      float: fn _token -> throw(:invalid_ledger_json) end,
      null: nil
    }
  end

  defp start_container({depth, _, _}) when depth < @depth, do: {depth + 1, 0, []}
  defp start_container(_), do: throw(:invalid_ledger_json)

  defp push_member(key, value, {depth, count, pairs}) when count < @members,
    do: {depth, count + 1, [{key, value} | pairs]}

  defp push_member(_, _, _), do: throw(:invalid_ledger_json)

  defp push_element(value, {depth, count, values}) when count < @elements,
    do: {depth, count + 1, [value | values]}

  defp push_element(_, _), do: throw(:invalid_ledger_json)

  defp normalize({:object, pairs}) do
    Enum.reduce_while(pairs, {:ok, %{}}, fn {key, value}, {:ok, result} ->
      with false <- Map.has_key?(result, key),
           {:ok, normalized} <- normalize(value) do
        {:cont, {:ok, Map.put(result, key, normalized)}}
      else
        _invalid -> {:halt, error()}
      end
    end)
  end

  defp normalize(values) when is_list(values) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, result} ->
      case normalize(value) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | result]}}
        _invalid -> {:halt, error()}
      end
    end)
    |> case do
      {:ok, result} -> {:ok, Enum.reverse(result)}
      other -> other
    end
  end

  defp normalize(value) when is_binary(value) or is_boolean(value) or is_nil(value),
    do: {:ok, value}

  defp normalize(value) when is_integer(value) and value >= 0, do: {:ok, value}
  defp normalize(_value), do: error()

  # Concept: native callers also spend the fixed byte and structural budgets.
  # Technical depth: validate before the shared encoder; count exact punctuation
  # and escaped string lengths. Integer ETF size bounds temporary decimal work.
  defp measure(_value, _depth, remaining) when remaining < 0, do: :invalid

  defp measure(value, depth, remaining)
       when is_map(value) and depth < @depth and map_size(value) <= @members do
    Enum.reduce_while(value, remaining - 2 - max(map_size(value) - 1, 0), fn
      {key, member}, budget when is_binary(key) ->
        with next when is_integer(next) <- measure(key, depth + 1, budget - 1),
             next when is_integer(next) <- measure(member, depth + 1, next) do
          {:cont, next}
        else
          _invalid -> {:halt, :invalid}
        end

      _, _budget ->
        {:halt, :invalid}
    end)
    |> nonnegative()
  end

  defp measure(value, depth, remaining) when is_list(value) and depth < @depth do
    measure_list(value, depth, remaining - 2, 0) |> nonnegative()
  end

  defp measure(value, _depth, remaining) when is_binary(value) do
    if byte_size(value) <= remaining and String.valid?(value),
      do: string_budget(value, remaining - 2),
      else: :invalid
  end

  defp measure(value, _depth, remaining) when is_integer(value) and value >= 0 do
    if :erlang.external_size(value) <= remaining + 16,
      do: nonnegative(remaining - byte_size(Integer.to_string(value))),
      else: :invalid
  end

  defp measure(true, _depth, remaining), do: nonnegative(remaining - 4)
  defp measure(false, _depth, remaining), do: nonnegative(remaining - 5)
  defp measure(nil, _depth, remaining), do: nonnegative(remaining - 4)
  defp measure(_value, _depth, _remaining), do: :invalid

  defp measure_list([], _depth, remaining, _count), do: remaining

  defp measure_list([value | rest], depth, remaining, count) when count < @elements do
    punctuation = if count == 0, do: 0, else: 1

    case measure(value, depth + 1, remaining - punctuation) do
      next when is_integer(next) -> measure_list(rest, depth, next, count + 1)
      _invalid -> :invalid
    end
  end

  defp measure_list(_, _, _, _), do: :invalid

  defp string_budget(_bytes, remaining) when remaining < 0, do: :invalid
  defp string_budget("", remaining), do: remaining

  defp string_budget(<<character::utf8, rest::binary>>, remaining) do
    size =
      cond do
        character in [34, 92, 8, 12, 10, 13, 9] -> 2
        character < 32 -> 6
        character <= 127 -> 1
        character <= 2_047 -> 2
        character <= 65_535 -> 3
        true -> 4
      end

    string_budget(rest, remaining - size)
  end

  defp nonnegative(value) when is_integer(value) and value >= 0, do: value
  defp nonnegative(_value), do: :invalid
  defp limit(:object), do: @object_bytes
  defp limit(:frame), do: @payload_bytes
  defp raw_hash(bytes), do: :crypto.hash(:sha256, bytes)
  defp error, do: {:error, :invalid_ledger_bytes}
end
