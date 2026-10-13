# Redact the four supported provider credentials from a human-attended release
# transcript without requiring Python. Bytes are held across reads until no
# longer key can begin there, so a credential split by PTY reads is still one
# exact match. This process writes only redacted bytes.
defmodule LoopexAttendedRedact do
  @markers ["[REDACTED]", "<REDACTED>", "{REDACTED}", "~REDACTED~"]

  def main do
    try do
      case credentials() do
        {:ok, keys} ->
          # The shell gives these raw inherited descriptors. Standard IO
          # transcodes bytes under a UTF-8 locale, even with IO.binread/write.
          # A bidirectional port reports pipe data promptly, but does not
          # reliably report EOF for a regular input file.
          width = max_key_width(keys)
          marker = replacement(keys)

          case File.stat!("/dev/fd/4").type do
            :regular ->
              {:ok, input} = :file.open(~c"/dev/fd/4", [:read, :binary, :raw])
              output = Port.open({:fd, 4, 5}, [:binary, :out])
              stream_file(input, output, keys, width, marker, {<<>>, 0})

            :other ->
              port = Port.open({:fd, 4, 5}, [:binary, :eof])
              stream_pipe(port, keys, width, marker, {<<>>, 0})

            _ ->
              fail("redaction_failed")
          end

        {:error, reason} ->
          fail(reason)
      end
    rescue
      _ -> fail("redaction_failed")
    catch
      _, _ -> fail("redaction_failed")
    end
  end

  defp credentials do
    # Bash supplies four raw values on an inherited private pipe. OTP decodes
    # environment strings, which can change an invalid UTF-8 credential byte.
    case File.read("/dev/fd/3") do
      {:ok, frame} ->
        case :binary.split(frame, <<0>>, [:global]) do
          [first, second, third, fourth, <<>>] ->
            keys = [first, second, third, fourth]

            if Enum.any?(keys, &(:binary.match(&1, ["\r", "\n"]) != :nomatch)),
              do: {:error, "credential_value_unredactable"},
              else: {:ok, keys |> Enum.reject(&(&1 == <<>>)) |> Enum.uniq()}

          _ ->
            {:error, "redaction_failed"}
        end

      _ ->
        {:error, "redaction_failed"}
    end
  end

  # A replacement must not contain a key, and no key may contain either edge
  # byte: otherwise surrounding transcript bytes could synthesize a key after
  # replacement. NUL is the final separator because environment values cannot
  # contain it.
  defp replacement(keys) do
    Enum.find(@markers, &safe_replacement?(&1, keys)) ||
      Enum.find_value(33..126, fn byte ->
        marker = <<byte>>
        if safe_replacement?(marker, keys), do: marker
      end) || <<0>>
  end

  defp safe_replacement?(marker, keys) do
    first = binary_part(marker, 0, 1)
    last = binary_part(marker, byte_size(marker) - 1, 1)

    Enum.all?(keys, fn key ->
      :binary.match(marker, key) == :nomatch and
        :binary.match(key, first) == :nomatch and
        :binary.match(key, last) == :nomatch
    end)
  end

  defp max_key_width([]), do: 1
  defp max_key_width(keys), do: keys |> Enum.map(&byte_size/1) |> Enum.max()

  defp stream_file(input, output, keys, width, replacement, {pending, covered}) do
    case :file.read(input, 65_536) do
      :eof ->
        {redacted, {<<>>, 0}} = redact(pending, covered, keys, width, replacement, true)
        publish(output, redacted)
        :ok = :file.close(input)
        Port.close(output)

      {:ok, data} ->
        {redacted, held} = redact(pending <> data, covered, keys, width, replacement, false)
        publish(output, redacted)
        stream_file(input, output, keys, width, replacement, held)

      _ ->
        fail("redaction_failed")
    end
  end

  defp stream_pipe(port, keys, width, replacement, {pending, covered}) do
    receive do
      {^port, {:data, data}} when is_binary(data) ->
        {redacted, held} = redact(pending <> data, covered, keys, width, replacement, false)
        publish(port, redacted)
        stream_pipe(port, keys, width, replacement, held)

      {^port, :eof} ->
        {redacted, {<<>>, 0}} = redact(pending, covered, keys, width, replacement, true)
        publish(port, redacted)
        Port.close(port)

      _ ->
        fail("redaction_failed")
    end
  end

  # Concept: `covered` leading bytes of the held content belong to a span
  # already published as one replacement; a key continuing from them extends
  # that span, and retention stays bounded by the longest key.
  # Technical depth: a span reaching the held tail is published at once; only
  # its last width - 1 bytes, where a longer key could still begin, are kept
  # as covered. Unpublished bytes after it stay held as they are.
  defp redact(content, covered, keys, width, replacement, final?) do
    # Credential values exclude CR and LF, so no key can cross a completed
    # line. Release that line even when it is shorter than the longest key.
    line_end =
      case :binary.matches(content, ["\r", "\n"]) do
        [] -> 0
        positions -> positions |> List.last() |> elem(0) |> Kernel.+(1)
      end

    # Hold only a tail that can still begin a key, so a prompt without a
    # newline reaches the operator while its process waits for an answer.
    safe =
      if final?,
        do: byte_size(content),
        else: hold_start(content, keys, max(line_end, byte_size(content) - width + 1))

    {cursor, span} =
      if covered > 0, do: {span_end(content, keys, 0, covered), 0}, else: {0, nil}

    {reversed, cursor, span} = scan(content, keys, safe, replacement, cursor, span, [])

    keep =
      if span == nil or final?,
        do: cursor,
        else: min(cursor, max(span, byte_size(content) - width + 1))

    {IO.iodata_to_binary(Enum.reverse(reversed)),
     {binary_part(content, keep, byte_size(content) - keep), cursor - keep}}
  end

  defp hold_start(content, keys, from) do
    size = byte_size(content)

    Enum.find(max(from, 0)..(size - 1)//1, size, fn position ->
      tail = binary_part(content, position, size - position)

      Enum.any?(keys, fn key ->
        byte_size(key) > byte_size(tail) and binary_part(key, 0, byte_size(tail)) == tail
      end)
    end)
  end

  defp scan(content, keys, safe, replacement, cursor, span, reversed) do
    case earliest(content, keys, cursor) do
      {position, key} when position < safe ->
        prefix = binary_part(content, cursor, position - cursor)
        stop = span_end(content, keys, position, position + byte_size(key))
        scan(content, keys, safe, replacement, stop, position, [replacement, prefix | reversed])

      _ when safe > cursor ->
        {[binary_part(content, cursor, safe - cursor) | reversed], safe, nil}

      _ ->
        {reversed, cursor, span}
    end
  end

  # Overlapping keys redact as one span, so no key's suffix survives.
  defp span_end(_content, _keys, position, stop) when position >= stop, do: stop

  defp span_end(content, keys, position, stop) do
    stop =
      Enum.reduce(keys, stop, fn key, stop ->
        size = byte_size(key)

        if position + size <= byte_size(content) and binary_part(content, position, size) == key,
          do: max(stop, position + size),
          else: stop
      end)

    span_end(content, keys, position + 1, stop)
  end

  defp earliest(content, keys, cursor) do
    Enum.reduce(keys, nil, fn key, best ->
      case :binary.match(content, key, scope: {cursor, byte_size(content) - cursor}) do
        :nomatch ->
          best

        {position, _length} ->
          if best == nil or position < elem(best, 0) or
               (position == elem(best, 0) and byte_size(key) > byte_size(elem(best, 1))),
             do: {position, key},
             else: best
      end
    end)
  end

  defp publish(_port, <<>>), do: :ok

  defp publish(port, bytes) do
    true = Port.command(port, bytes)
    :ok
  end

  defp fail(code) do
    IO.write(:stderr, "attended-redact: #{code}\n")
    System.halt(1)
  end
end

LoopexAttendedRedact.main()
