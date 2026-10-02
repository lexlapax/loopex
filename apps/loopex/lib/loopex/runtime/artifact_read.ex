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
  @reference_keys [
    :digest,
    :size,
    :locator,
    :media_type,
    :role,
    :use_canonicalization_version,
    :use_digest,
    :use_locator
  ]

  @doc false
  @spec job_range(map()) :: {:ok, map()} | {:error, :invalid_tool_arguments}
  def job_range(
        %{tool_id: "loopex.read", tool_version: "1.1.0", validated_arguments: arguments} = job
      ) do
    with :ok <- Loopex.Executor.validate_job(job),
         %{"resolved_artifact" => %{"reference" => plain, "source" => source} = resolved} <-
           arguments,
         true <- map_size(resolved) == 2 and is_map(plain) and map_size(plain) == 8,
         reference = Map.new(@reference_keys, &{&1, Map.get(plain, Atom.to_string(&1))}),
         true <- Loopex.ArtifactStore.valid_reference?(reference),
         true <- valid_source?(source),
         model = Map.delete(arguments, "resolved_artifact"),
         {:ok, ^arguments} <- resolve_range(model, %{reference.use_locator => resolved}) do
      {:ok,
       %{reference: reference, source: source, offset: model["offset"], length: model["length"]}}
    else
      _ -> {:error, :invalid_tool_arguments}
    end
  end

  def job_range(_), do: {:error, :invalid_tool_arguments}

  defp valid_source?(
         %{
           "record_kind" => kind,
           "journal_version" => version,
           "record_digest" => digest,
           "run_id" => run,
           "operation_id" => operation,
           "attempt" => attempt,
           "tool_call_id" => call
         } = source
       ) do
    map_size(source) == 7 and
      kind in [
        "executor_receipt_committed",
        "executor_receipt_committed_v2",
        "tool_result_reference_prepared"
      ] and
      is_integer(version) and version > 0 and is_integer(attempt) and attempt > 0 and
      is_binary(digest) and byte_size(digest) == 64 and digest =~ ~r/\A[0-9a-f]{64}\z/ and
      Enum.all?([run, operation, call], &(is_binary(&1) and &1 != ""))
  end

  defp valid_source?(_), do: false

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
