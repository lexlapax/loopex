defmodule Loopex.Runtime.ArtifactRead do
  @moduledoc """
  ## Concept

  A model may request an artifact range only from a use already committed in
  its session. The owner checks that membership before asking host policy.

  ## Technical depth

  Resolution is pure over a receipt-derived index. It performs no object lookup,
  registry lookup or retention. The exact read generation selects the two closed
  argument branches. Only an approved executor job receives the resolved source;
  policy and interaction identity retain the original model arguments.
  """

  alias Loopex.Runtime.ArtifactReadCapabilities
  alias LoopexProtocol.Canonical

  @uint64_max 18_446_744_073_709_551_615

  @doc false
  @spec resolve(map(), map(), map()) :: {:ok, map()} | {:error, :invalid_tool_arguments}
  def resolve(definition, arguments, sources) do
    case ArtifactReadCapabilities.resolve([definition]) do
      {:ok, nil} -> {:ok, arguments}
      {:ok, _capability} -> resolve_range(arguments, sources)
      _invalid -> {:error, :invalid_tool_arguments}
    end
  end

  defp resolve_range(%{"path" => path} = arguments, _sources) do
    if map_size(arguments) == 1 and is_binary(path) and byte_size(path) > 0 and
         String.valid?(path) do
      {:ok, arguments}
    else
      {:error, :invalid_tool_arguments}
    end
  end

  defp resolve_range(
         %{"artifact_use" => use, "offset" => offset, "length" => length} = arguments,
         sources
       )
       when map_size(arguments) == 3 and is_binary(use) and is_integer(offset) and
              offset >= 0 and offset <= @uint64_max and is_integer(length) and
              length > 0 and length <= 4_096 do
    case Map.get(sources, use) do
      %{"reference" => %{"use_locator" => ^use, "size" => size}} = resolved
      when offset <= size ->
        {:ok, Map.put(arguments, "resolved_artifact", resolved)}

      _unavailable ->
        {:error, :invalid_tool_arguments}
    end
  end

  defp resolve_range(_arguments, _sources), do: {:error, :invalid_tool_arguments}

  @doc false
  @spec retain(map(), [map()], map(), pos_integer(), map()) :: map()
  def retain(sources, [], _record, _version, _job), do: sources

  def retain(sources, references, record, version, job) do
    source = %{
      "record_kind" => record.kind,
      "journal_version" => version,
      "record_digest" => Canonical.digest(record),
      "run_id" => job.run_id,
      "operation_id" => job.operation_id,
      "attempt" => job.attempt,
      "tool_call_id" => job.tool_call_id
    }

    Enum.reduce(references, sources, fn reference, index ->
      plain = Map.new(reference, fn {key, value} -> {Atom.to_string(key), value} end)
      resolved = %{"reference" => plain, "source" => source}

      # Concept: repeated references keep their first committed source.
      # Technical depth: conflicting bytes under one use identity make that
      # identity unusable; no later receipt can repair it by replacing the index.
      Map.update(index, reference.use_locator, resolved, fn
        %{"reference" => ^plain} = original -> original
        _conflicting -> :ambiguous
      end)
    end)
  end
end
