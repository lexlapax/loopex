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
              stream_file(input, output, keys, width, marker, <<>>)

            :other ->
              port = Port.open({:fd, 4, 5}, [:binary, :eof])
              stream_pipe(port, keys, width, marker, <<>>)

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

  defp stream_file(input, output, keys, width, replacement, pending) do
    case :file.read(input, 65_536) do
      :eof ->
        {redacted, <<>>} = redact(pending, keys, width, replacement, true)
        publish(output, redacted)
        :ok = :file.close(input)
        Port.close(output)

      {:ok, data} ->
        {redacted, remaining} = redact(pending <> data, keys, width, replacement, false)
        publish(output, redacted)
        stream_file(input, output, keys, width, replacement, remaining)

      _ ->
        fail("redaction_failed")
    end
  end

  defp stream_pipe(port, keys, width, replacement, pending) do
    receive do
      {^port, {:data, data}} when is_binary(data) ->
        {redacted, remaining} = redact(pending <> data, keys, width, replacement, false)
        publish(port, redacted)
        stream_pipe(port, keys, width, replacement, remaining)

      {^port, :eof} ->
        {redacted, <<>>} = redact(pending, keys, width, replacement, true)
        publish(port, redacted)
        Port.close(port)

      _ ->
        fail("redaction_failed")
    end
  end

  defp redact(content, keys, width, replacement, final?) do
    # Credential values exclude CR and LF, so no key can cross a completed
    # line. Release that line even when it is shorter than the longest key.
    line_end =
      case :binary.matches(content, ["\r", "\n"]) do
        [] -> 0
        positions -> positions |> List.last() |> elem(0) |> Kernel.+(1)
      end

    safe =
      if final?,
        do: byte_size(content),
        else: max(line_end, max(0, byte_size(content) - width + 1))

    scan(content, keys, safe, replacement, 0, [])
  end

  defp scan(content, _keys, safe, _replacement, cursor, reversed) when cursor >= safe do
    {IO.iodata_to_binary(Enum.reverse(reversed)),
     binary_part(content, cursor, byte_size(content) - cursor)}
  end

  defp scan(content, keys, safe, replacement, cursor, reversed) do
    case earliest(content, keys, cursor) do
      {position, key} when position < safe ->
        prefix = binary_part(content, cursor, position - cursor)

        scan(content, keys, safe, replacement, position + byte_size(key), [
          replacement,
          prefix | reversed
        ])

      _ ->
        prefix = binary_part(content, cursor, safe - cursor)

        {IO.iodata_to_binary(Enum.reverse([prefix | reversed])),
         binary_part(content, safe, byte_size(content) - safe)}
    end
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
