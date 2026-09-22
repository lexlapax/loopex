defmodule LoopexDaemon.Readiness do
  @moduledoc """
  ## Concept

  A daemon announces that its exclusive resources and parked listener are
  ready with one machine-readable line. The line is stable even when a state
  root or socket path contains whitespace or control characters.

  ## Technical depth

  The five fields are emitted in the contract's fixed order rather than by a
  map encoder whose key ordering is independent of the readiness protocol.
  Every value must be nonempty UTF-8, and JSON escaping ensures that the final
  line contains exactly one literal line-feed byte: its terminator.
  """

  @typedoc false
  @type reason :: :invalid_readiness_value

  @doc """
  ## Concept

  Encodes the daemon readiness record, including its one terminating newline.

  ## Technical depth

  The caller supplies already-resolved paths and the daemon-lifetime
  incarnation. The supplied version is retained literally so the process
  entrypoint can bind the record to the application version it actually runs.
  """
  @spec encode(binary(), binary(), binary(), binary()) ::
          {:ok, binary()} | {:error, reason()}
  def encode(root, socket, incarnation, version) do
    values = [root, socket, incarnation, version]

    if Enum.all?(values, &valid_value?/1) do
      {:ok,
       IO.iodata_to_binary([
         ~s({"record":"daemon_ready","root":),
         encode_string(root),
         ~s(,"socket":),
         encode_string(socket),
         ~s(,"incarnation":),
         encode_string(incarnation),
         ~s(,"version":),
         encode_string(version),
         "}\n"
       ])}
    else
      {:error, :invalid_readiness_value}
    end
  end

  defp valid_value?(value),
    do: is_binary(value) and byte_size(value) > 0 and String.valid?(value)

  defp encode_string(value), do: [?", escape(value, []), ?"]

  defp escape(<<>>, acc), do: Enum.reverse(acc)

  defp escape(<<character::utf8, rest::binary>>, acc) do
    encoded =
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
          [
            "\\u",
            code |> Integer.to_string(16) |> String.pad_leading(4, "0") |> String.downcase()
          ]

        code ->
          <<code::utf8>>
      end

    escape(rest, [encoded | acc])
  end
end
