defmodule Loopex.Runtime.ToolResultExcerpt do
  @moduledoc """
  ## Concept

  A model-facing excerpt points back to an already retained artifact while
  preserving the tool's outcome. Its offsets describe committed receipt text,
  which may contain notices and need not equal the artifact's bytes.

  ## Technical depth

  This pure formatter implements ADR 0041's 2,048-byte complete JSON message
  ceiling and one caller-supplied raw prefix allowance in 0..2048. It measures
  the real call identity and the second escaping of JSON inside message content.
  The caller establishes committed membership, chooses eligible results and
  freezes prior projections. This module neither acquires a reference nor
  changes explicit range reads, legacy inline results or question answers.

  Invalid UTF-8 receives a fixed description and zero excerpt bytes. The source
  digest and size still bind the original bytes. No byte replacement, base64
  expansion or storage access occurs. Returned source-range data supports the
  staging record's independent replay check; it grants no retrieval authority.
  """

  alias LoopexProtocol.Frame

  @ceiling 2_048
  @outcomes ~w(completed failed denied cancelled outcome_unknown)

  @doc false
  @spec encode(map(), map(), non_neg_integer()) :: {:ok, map()} | {:error, atom()}
  def encode(message, reference, allowance \\ @ceiling)

  def encode(
        %{"role" => "tool", "tool_call_id" => call, "outcome" => outcome, "content" => source} =
          message,
        reference,
        allowance
      )
      when map_size(message) == 4 and is_binary(call) and is_binary(source) and
             outcome in @outcomes and is_integer(allowance) and allowance in 0..@ceiling do
    with true <- String.valid?(call) and call != "",
         true <- Loopex.ArtifactStore.valid_reference?(reference) do
      metadata = %{
        "use_locator" => reference.use_locator,
        "object_digest" => reference.digest,
        "object_size" => reference.size,
        "excerpt_source" => "receipt_content",
        "source_byte_count" => byte_size(source),
        "excerpt_offset" => 0
      }

      result =
        if String.valid?(source) do
          prefix = utf8_prefix(source, allowance)
          boundaries = [0 | Enum.scan(String.codepoints(prefix), 0, &(byte_size(&1) + &2))]
          offsets = List.to_tuple(boundaries)
          largest(message, metadata, prefix, offsets, 0, tuple_size(offsets) - 1, nil)
        else
          project(message, Map.put(metadata, "description", "Binary receipt content."), "", 0)
        end

      with {:ok, projection} <- result do
        digest = :crypto.hash(:sha256, source) |> Base.encode16(case: :lower)
        {:ok, put_in(projection, [:source_range, "source_digest"], digest)}
      end
    else
      _invalid -> {:error, :context_projection_invalid}
    end
  end

  def encode(_, _, _), do: {:error, :context_projection_invalid}

  defp utf8_prefix(source, allowance) do
    prefix = binary_part(source, 0, min(byte_size(source), allowance))

    case :unicode.characters_to_binary(prefix, :utf8, :utf8) do
      text when is_binary(text) -> text
      {:incomplete, text, _tail} -> text
    end
  end

  # Concept: every result keeps its metadata even when its excerpt must be empty.
  # Technical depth: candidate sizes are nondecreasing over UTF-8 boundaries.
  # The final omitted=false marker is one byte longer, so reaching source EOF
  # cannot make a larger prefix cheaper. Binary search includes the zero prefix.
  defp largest(_message, _metadata, _prefix, _offsets, low, high, best) when low > high,
    do: best || {:error, :artifact_metadata_unrepresentable}

  defp largest(message, metadata, prefix, offsets, low, high, best) do
    middle = div(low + high, 2)
    count = elem(offsets, middle)

    case project(message, metadata, binary_part(prefix, 0, count), count) do
      {:ok, _} = candidate ->
        largest(message, metadata, prefix, offsets, middle + 1, high, candidate)

      {:error, :artifact_metadata_unrepresentable} ->
        largest(message, metadata, prefix, offsets, low, middle - 1, best)
    end
  end

  defp project(message, metadata, excerpt, count) do
    notice =
      Map.merge(metadata, %{
        "excerpt" => excerpt,
        "excerpt_byte_count" => count,
        "omitted" => count < metadata["source_byte_count"]
      })

    with {:ok, inner} <- json(notice),
         projected = %{message | "content" => inner},
         {:ok, outer} <- json(projected),
         true <- byte_size(outer) <= @ceiling do
      {:ok,
       %{
         message: projected,
         source_range: %{
           "source_byte_count" => metadata["source_byte_count"],
           "offset" => 0,
           "byte_count" => count
         }
       }}
    else
      _too_large -> {:error, :artifact_metadata_unrepresentable}
    end
  end

  defp json(value) do
    with {:ok, frame} <- Frame.encode(value) do
      bytes = IO.iodata_to_binary(frame)
      {:ok, binary_part(bytes, 0, byte_size(bytes) - 1)}
    end
  end
end
