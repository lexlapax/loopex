defmodule Mix.Tasks.Loopex.M7Evidence.AttemptFrames do
  @moduledoc """
  ## Concept

  Preserve the exact hash-chained record bytes required by M7's attempts index.
  This private evidence helper verifies framing and chain continuity only.
  Ownership, event schemas, case transitions and dispatch authority require
  their separate admission checks; a valid frame grants none of them.

  ## Technical depth

  The accepted envelope has exactly six members: version, campaign_id, sequence,
  previous_digest, body and digest. Each compact sorted-key JSON object is at
  most 65,536 bytes before its LF. SHA-256 covers the other five members without
  LF. Duplicate members, noncanonical bytes and non-plain bodies refuse. The
  existing protocol JSON encoder and duplicate-aware configuration decoder
  supply canonical encoding, integer precision and bounded nesting.

  Chain verification starts at sequence one with a null predecessor and checks
  every subsequent campaign, sequence and digest. An incomplete trailing line
  returns its verified preceding head and exact unresolved bytes. It never
  presents that prefix as a complete index. No file is opened or written.
  """

  alias LoopexCli.ConfigJson
  alias LoopexProtocol.Frame

  @keys ~w(body campaign_id digest previous_digest sequence version)
  @limit 65_536

  @doc false
  def encode(campaign, sequence, previous, body) do
    unsigned = %{
      "version" => 1,
      "campaign_id" => campaign,
      "sequence" => sequence,
      "previous_digest" => previous,
      "body" => body
    }

    with true <- shape?(Map.put(unsigned, "digest", String.duplicate("0", 64))),
         {:ok, covered} <- canonical(unsigned),
         record = Map.put(unsigned, "digest", digest(covered)),
         {:ok, bytes} <- canonical(record),
         true <- byte_size(bytes) <= @limit do
      {:ok, bytes <> "\n", record}
    else
      _ -> {:error, :invalid_attempt_frame}
    end
  end

  @doc false
  def decode(bytes) when is_binary(bytes) and byte_size(bytes) in 1..@limit do
    with {:ok, record} <- ConfigJson.decode(bytes),
         true <- shape?(record),
         {:ok, ^bytes} <- canonical(record),
         {:ok, covered} <- canonical(Map.delete(record, "digest")),
         true <- record["digest"] == digest(covered) do
      {:ok, record}
    else
      _ -> {:error, :invalid_attempt_frame}
    end
  end

  def decode(_), do: {:error, :invalid_attempt_frame}

  @doc false
  def verify(bytes) when is_binary(bytes), do: verify_lines(bytes, nil)
  def verify(_), do: {:error, :invalid_attempt_chain}

  defp verify_lines(<<>>, nil), do: {:error, :empty_attempt_chain}
  defp verify_lines(<<>>, head), do: {:ok, head}

  defp verify_lines(bytes, head) do
    case :binary.match(bytes, "\n") do
      {length, 1} when length <= @limit ->
        <<line::binary-size(^length), "\n", remaining::binary>> = bytes

        with {:ok, record} <- decode(line),
             true <- follows?(record, head) do
          verify_lines(remaining, Map.take(record, ~w(campaign_id sequence digest)))
        else
          _ -> {:error, :invalid_attempt_chain}
        end

      :nomatch when byte_size(bytes) <= @limit ->
        {:error, {:incomplete_attempt_append, head, bytes}}

      _ ->
        {:error, :invalid_attempt_chain}
    end
  end

  defp follows?(record, nil),
    do: record["sequence"] == 1 and is_nil(record["previous_digest"])

  defp follows?(record, head),
    do:
      record["campaign_id"] == head["campaign_id"] and
        record["sequence"] == head["sequence"] + 1 and
        record["previous_digest"] == head["digest"]

  defp shape?(record) do
    is_map(record) and not is_struct(record) and Enum.sort(Map.keys(record)) == @keys and
      record["version"] == 1 and is_binary(record["campaign_id"]) and
      byte_size(record["campaign_id"]) > 0 and is_integer(record["sequence"]) and
      record["sequence"] > 0 and
      ((record["sequence"] == 1 and is_nil(record["previous_digest"])) or
         (record["sequence"] > 1 and digest?(record["previous_digest"]))) and
      is_map(record["body"]) and not is_struct(record["body"]) and digest?(record["digest"])
  end

  defp canonical(value) do
    {:ok, encoded} = Frame.encode(value)
    line = IO.iodata_to_binary(encoded)
    bytes = binary_part(line, 0, byte_size(line) - 1)

    case ConfigJson.decode(bytes) do
      {:ok, ^value} -> {:ok, bytes}
      _ -> :error
    end
  rescue
    _ -> :error
  end

  defp digest(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
  defp digest?(value), do: is_binary(value) and Regex.match?(~r/\A[0-9a-f]{64}\z/, value)
end
