defmodule Loopex.Executor.Local.ArtifactRange do
  @moduledoc """
  ## Concept

  An explicit artifact read returns an exact text range and the offset at which
  the caller can continue. JSON escaping and metadata consume the same result
  allowance as the text.

  ## Technical depth

  This pure encoder receives a verified window from an admitted job. It neither
  reads storage nor proves artifact ownership or integrity. The window contains
  exactly the requested bytes, shortened only at object EOF. A partial trailing
  codepoint may be omitted before EOF; malformed UTF-8, including a start inside
  a codepoint, refuses. The largest complete prefix fitting the entire encoded
  result is selected, with positive progress except at EOF. No artifact is made
  from the returned excerpt.

  Measurement includes the ordinary conversation tool-message envelope and its
  second JSON escaping of the range content. Projection revision 1's normalized
  call IDs always contain `lx_` plus 48 hexadecimal characters. A same-length
  measurement ID accounts for those bytes without inventing a call identity in
  the executor output. The real projector supplies the actual identity later.
  """

  alias LoopexProtocol.Frame

  @ceiling 8_192
  @measurement_id "lx_" <> String.duplicate("0", 48)

  @doc false
  @spec encode(map(), non_neg_integer(), pos_integer(), binary(), pos_integer()) ::
          {:ok, binary()} | {:error, atom()}
  def encode(reference, offset, length, bytes, limit \\ @ceiling)

  def encode(%{"size" => size} = reference, offset, length, bytes, limit)
      when is_integer(size) and is_integer(offset) and
             offset >= 0 and offset <= size and is_integer(length) and length in 1..4_096 and
             is_binary(bytes) and byte_size(bytes) == min(length, size - offset) and
             is_integer(limit) and limit in 1..@ceiling do
    with {:ok, text} <- text(bytes, offset + byte_size(bytes) == size) do
      boundaries =
        text
        |> String.codepoints()
        |> Enum.scan(0, fn point, count -> count + byte_size(point) end)
        |> List.to_tuple()

      record = %{
        "artifact" => reference,
        "offset" => offset
      }

      if offset == size do
        fit(record, text, 0, size, limit)
      else
        largest(record, text, boundaries, size, limit, 0, tuple_size(boundaries) - 1, nil)
      end
    end
  end

  def encode(_, _, _, _, _), do: {:error, :invalid_artifact_range}

  defp text(bytes, eof) do
    case :unicode.characters_to_binary(bytes, :utf8, :utf8) do
      text when is_binary(text) -> {:ok, text}
      {:incomplete, prefix, _partial} when not eof -> {:ok, prefix}
      _invalid -> {:error, :artifact_range_unsupported_content}
    end
  end

  # Concept: escaping can shorten a range even when its raw bytes fit.
  # Technical depth: encoded sizes are nondecreasing at codepoint boundaries.
  # At EOF, true saves one byte over false, but the added codepoint costs at
  # least one. Binary search therefore finds the largest fitting prefix without
  # encoding every possible prefix of a maximally escaped 4-KiB window.
  defp largest(_record, _text, _boundaries, _size, _limit, low, high, best) when low > high do
    if best, do: {:ok, best}, else: {:error, :artifact_range_unrepresentable}
  end

  defp largest(record, text, boundaries, size, limit, low, high, best) do
    middle = div(low + high, 2)

    case fit(record, text, elem(boundaries, middle), size, limit) do
      {:ok, encoded} ->
        largest(record, text, boundaries, size, limit, middle + 1, high, encoded)

      {:error, :artifact_range_unrepresentable} ->
        largest(record, text, boundaries, size, limit, low, middle - 1, best)
    end
  end

  defp fit(record, text, count, size, limit) do
    result =
      Map.merge(record, %{
        "content" => binary_part(text, 0, count),
        "byte_count" => count,
        "next_offset" => record["offset"] + count,
        "eof" => record["offset"] + count == size
      })

    with {:ok, frame} <- Frame.encode(result),
         encoded = IO.iodata_to_binary(frame),
         json = binary_part(encoded, 0, byte_size(encoded) - 1),
         {:ok, message} <-
           Frame.encode(%{
             "role" => "tool",
             "tool_call_id" => @measurement_id,
             "outcome" => "completed",
             "content" => json
           }),
         true <- IO.iodata_length(message) - 1 <= limit do
      {:ok, json}
    else
      _too_large -> {:error, :artifact_range_unrepresentable}
    end
  end
end
