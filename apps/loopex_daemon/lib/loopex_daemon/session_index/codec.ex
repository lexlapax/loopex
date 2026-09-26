defmodule LoopexDaemon.SessionIndex.Codec do
  @moduledoc """
  ## Concept

  The daemon's session list is a bounded discoverability index. It records only
  session identity and runtime placement identity; it never substitutes for
  Store truth or proves that a session exists.

  ## Technical depth

  The image is the exact canonical JSON Lines format fixed by ADR 0032: one
  literal header, up to 4,096 rows sorted by decoded session-id bytes, and one
  lowercase SHA-256 trailer. Identities are canonical unpadded base64url forms
  of 1 through 256 bytes. The digest covers the header and rows including their
  line feeds and excludes the trailer. No general JSON normalization is used,
  so whitespace, escapes, reordered keys and unknown keys cannot be accepted as
  alternate spellings of the same image.
  """

  alias LoopexProtocol.Wire

  @header ~s({"format":"loopex-session-index","version":1})
  @row_prefix ~s({"session_id":")
  @row_middle ~s(","placement_identity":")
  @row_suffix ~s("})
  @trailer_prefix ~s({"sha256":")
  @trailer_suffix ~s("})

  @max_entries 4_096
  @max_lines @max_entries + 2
  @max_file_bytes 4 * 1_024 * 1_024
  @max_row_bytes_including_lf 726

  @typedoc false
  @type row :: %{session_id: binary(), placement_identity: binary()}

  @doc false
  @spec encode([row()]) ::
          {:ok, binary()} | {:error, :session_index_full | :invalid_index_entry}
  def encode(rows) when is_list(rows) do
    cond do
      length(rows) > @max_entries ->
        {:error, :session_index_full}

      true ->
        with {:ok, normalized} <- normalize_rows(rows),
             :ok <- unique_session_ids(normalized) do
          domain = encode_domain(normalized)
          digest = sha256(domain)
          {:ok, domain <> @trailer_prefix <> digest <> @trailer_suffix <> "\n"}
        end
    end
  end

  def encode(_rows), do: {:error, :invalid_index_entry}

  @doc false
  @spec decode(binary()) ::
          {:ok, [row()]}
          | {:error, :session_index_too_large | :session_index_corrupt}
  def decode(image) when is_binary(image) do
    if byte_size(image) > @max_file_bytes do
      {:error, :session_index_too_large}
    else
      decode_bounded(image)
    end
  end

  def decode(_image), do: {:error, :session_index_corrupt}

  @doc false
  @spec max_entries() :: 4_096
  def max_entries, do: @max_entries

  @doc false
  @spec max_file_bytes() :: 4_194_304
  def max_file_bytes, do: @max_file_bytes

  defp decode_bounded(image) do
    with true <- String.valid?(image),
         {:ok, lines} <- complete_lines(image),
         {:ok, row_lines, trailer} <- image_lines(lines),
         true <- length(row_lines) <= @max_entries,
         {:ok, rows} <- decode_rows(row_lines),
         :ok <- verify_trailer(trailer, row_lines) do
      {:ok, rows}
    else
      _other -> {:error, :session_index_corrupt}
    end
  end

  defp complete_lines(image) do
    split_complete_lines(image, [], @max_lines)
  end

  defp split_complete_lines(_image, _lines, 0), do: :error

  defp split_complete_lines(image, lines, remaining) do
    case :binary.match(image, "\n") do
      {index, 1} ->
        line = binary_part(image, 0, index)
        rest = binary_part(image, index + 1, byte_size(image) - index - 1)

        if rest == "" do
          {:ok, Enum.reverse([line | lines])}
        else
          split_complete_lines(rest, [line | lines], remaining - 1)
        end

      :nomatch ->
        :error
    end
  end

  defp image_lines([@header | rest]) when rest != [] do
    {:ok, Enum.drop(rest, -1), List.last(rest)}
  end

  defp image_lines(_lines), do: :error

  defp decode_rows(lines) do
    Enum.reduce_while(lines, {:ok, [], nil}, fn line, {:ok, rows, previous_id} ->
      with true <- byte_size(line) + 1 <= @max_row_bytes_including_lf,
           {:ok, row} <- decode_row(line),
           true <- is_nil(previous_id) or previous_id < row.session_id do
        {:cont, {:ok, [row | rows], row.session_id}}
      else
        _other -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, rows, _previous_id} -> {:ok, Enum.reverse(rows)}
      :error -> :error
    end
  end

  defp decode_row(line) do
    with true <- String.starts_with?(line, @row_prefix),
         true <- String.ends_with?(line, @row_suffix),
         body <-
           binary_part(
             line,
             byte_size(@row_prefix),
             byte_size(line) - byte_size(@row_prefix) - byte_size(@row_suffix)
           ),
         [encoded_session_id, encoded_placement] <- :binary.split(body, @row_middle),
         {:ok, session_id} <- Wire.session_identity(encoded_session_id),
         {:ok, placement_identity} <- Wire.session_identity(encoded_placement) do
      {:ok, %{session_id: session_id, placement_identity: placement_identity}}
    else
      _other -> :error
    end
  end

  defp verify_trailer(trailer, row_lines) do
    with true <- String.starts_with?(trailer, @trailer_prefix),
         true <- String.ends_with?(trailer, @trailer_suffix),
         digest <-
           binary_part(
             trailer,
             byte_size(@trailer_prefix),
             byte_size(trailer) - byte_size(@trailer_prefix) - byte_size(@trailer_suffix)
           ),
         true <- lowercase_sha256?(digest),
         true <- digest == sha256(domain_from_lines(row_lines)) do
      :ok
    else
      _other -> :error
    end
  end

  defp normalize_rows(rows) do
    Enum.reduce_while(rows, {:ok, []}, fn
      %{session_id: session_id, placement_identity: placement_identity}, {:ok, normalized}
      when is_binary(session_id) and is_binary(placement_identity) ->
        if identity?(session_id) and identity?(placement_identity) do
          row = %{session_id: session_id, placement_identity: placement_identity}
          {:cont, {:ok, [row | normalized]}}
        else
          {:halt, {:error, :invalid_index_entry}}
        end

      _row, _acc ->
        {:halt, {:error, :invalid_index_entry}}
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.sort_by(normalized, & &1.session_id)}
      error -> error
    end
  end

  defp unique_session_ids(rows) do
    rows
    |> Enum.reduce_while(nil, fn row, previous_id ->
      if row.session_id == previous_id,
        do: {:halt, :duplicate},
        else: {:cont, row.session_id}
    end)
    |> case do
      :duplicate -> {:error, :invalid_index_entry}
      _last_id -> :ok
    end
  end

  defp encode_domain(rows) do
    encoded_rows =
      Enum.map(rows, fn row ->
        @row_prefix <>
          Wire.encode_identity(row.session_id) <>
          @row_middle <>
          Wire.encode_identity(row.placement_identity) <>
          @row_suffix <>
          "\n"
      end)

    IO.iodata_to_binary([@header, "\n", encoded_rows])
  end

  defp domain_from_lines(row_lines),
    do: IO.iodata_to_binary([@header, "\n", Enum.map(row_lines, &[&1, "\n"])])

  defp identity?(identity), do: byte_size(identity) in 1..256

  defp lowercase_sha256?(digest) when byte_size(digest) == 64 do
    Enum.all?(:binary.bin_to_list(digest), fn byte -> byte in ?0..?9 or byte in ?a..?f end)
  end

  defp lowercase_sha256?(_digest), do: false

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
