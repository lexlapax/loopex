defmodule Loopex.Runtime.LineageProjection do
  @moduledoc """
  ## Concept

  Project receipt-owned artifacts without changing committed conversation facts.
  Explicit range replies and messages already used in an open native exchange
  keep their exact bytes. Legacy selections retain their full inline results.

  ## Technical depth

  Revision 1 records one shared raw-prefix allowance and ordered source ranges.
  Artifact eligibility comes from the result's retained reference and the
  session's committed use index, never from a host registry or object read.
  The caller supplies previously validated frozen messages and their ranges.
  Inline sources without a reference stay fixed here; bounded preparation must
  establish references before they can participate in excerpt allocation.
  """

  alias Loopex.Conversation
  alias Loopex.Runtime.ToolResultExcerpt
  alias LoopexProtocol.Frame
  alias LoopexProtocol.ToolDefinition

  @question_generation ToolDefinition.generation(ToolDefinition.question_definition())

  @doc false
  @spec project(list(), map() | nil, map(), map(), non_neg_integer()) ::
          {:ok, list(), map() | nil} | {:error, atom()}
  def project(elements, nil, _sources, _frozen, _allowance) do
    with {:ok, entries} <- Conversation.lineage_entries(elements), do: {:ok, entries, nil}
  end

  def project(elements, binding, sources, frozen, allowance)
      when is_map(binding) and is_integer(allowance) and allowance in 0..2_048 do
    with {:ok, entries} <- Conversation.lineage_entries(elements) do
      {results, calls} = result_facts(elements)

      Enum.reduce_while(entries, {:ok, [], []}, fn {source, message}, {:ok, projected, ranges} ->
        case project_entry(source, message, results, calls, binding, sources, frozen, allowance) do
          {:ok, message, range} ->
            ranges = if range, do: [range | ranges], else: ranges
            {:cont, {:ok, [{source, message} | projected], ranges}}

          error ->
            {:halt, error}
        end
      end)
      |> case do
        {:ok, entries, ranges} ->
          {:ok, Enum.reverse(entries),
           %{"revision" => 1, "allowance" => allowance, "ranges" => Enum.reverse(ranges)}}

        error ->
          error
      end
    end
  end

  def project(_, _, _, _, _), do: {:error, :context_projection_invalid}

  @doc false
  @spec preparation_candidates(list(), map() | nil, map(), map()) ::
          {:ok, [map()]} | {:error, atom()}
  # Concept: only oversized, unfrozen executor results without a usable
  # reference need retention before ordinary excerpt allocation.
  # Technical depth: inspect the complete encoded tool message, including
  # escaping and identity. Selection precedes this call; excluded history never
  # enters its ordered result. No storage access or episode credit is consumed.
  def preparation_candidates(_elements, nil, _sources, _frozen), do: {:ok, []}

  def preparation_candidates(elements, binding, sources, frozen) when is_map(binding) do
    with {:ok, entries} <- Conversation.lineage_entries(elements) do
      {results, calls} = result_facts(elements)

      Enum.reduce_while(entries, {:ok, []}, fn
        {%{"kind" => "session_tool_result"} = source, message}, {:ok, candidates} ->
          identity = {source["run_id"], source["turn"], source["call_id"]}
          result = Map.fetch!(results, identity)
          call = Map.fetch!(calls, identity)

          with {:ok, encoded} <- Frame.encode(message) do
            fixed = Map.has_key?(frozen, source) or fixed_result?(call, binding)
            retained = match?({:ok, _}, reference(result, sources))

            if not fixed and not retained and IO.iodata_length(encoded) - 1 > 2_048 do
              {:cont, {:ok, [%{source_reference: source, message: message} | candidates]}}
            else
              {:cont, {:ok, candidates}}
            end
          else
            _ -> {:halt, {:error, :context_projection_invalid}}
          end

        _, acc ->
          {:cont, acc}
      end)
      |> case do
        {:ok, candidates} -> {:ok, Enum.reverse(candidates)}
        error -> error
      end
    end
  end

  def preparation_candidates(_, _, _, _), do: {:error, :context_projection_invalid}

  defp result_facts(elements) do
    results =
      elements
      |> Enum.filter(&(&1.kind == :tool_result))
      |> Map.new(&{{&1.run_id, &1.turn_number, &1.tool_call_id}, &1})

    calls =
      Enum.reduce(elements, %{}, fn
        %{kind: :assistant_message} = element, acc ->
          Enum.reduce(element.tool_calls, acc, fn call, acc ->
            Map.put(acc, {element.run_id, element.turn_number, call.tool_call_id}, call)
          end)

        _, acc ->
          acc
      end)

    {results, calls}
  end

  defp project_entry(source, message, results, calls, binding, sources, frozen, allowance) do
    case Map.fetch(frozen, source) do
      {:ok, %{message: retained, range: range}} ->
        {:ok, retained, range}

      :error ->
        project_new(source, message, results, calls, binding, sources, allowance)
    end
  end

  defp project_new(
         %{"kind" => "session_tool_result"} = source,
         message,
         results,
         calls,
         binding,
         sources,
         allowance
       ) do
    identity = {source["run_id"], source["turn"], source["call_id"]}
    result = Map.fetch!(results, identity)
    call = Map.fetch!(calls, identity)

    with false <- fixed_result?(call, binding),
         {:ok, reference} <- reference(result, sources),
         {:ok, projected} <- ToolResultExcerpt.encode(message, reference, allowance) do
      range =
        Map.merge(projected.source_range, %{
          "source_reference" => source,
          "artifact_use" => reference.use_locator
        })

      {:ok, projected.message, range}
    else
      true -> {:ok, message, nil}
      :none -> {:ok, message, nil}
      error -> error
    end
  end

  defp project_new(_source, message, _results, _calls, _binding, _sources, _allowance),
    do: {:ok, message, nil}

  defp fixed_result?(%{generation: @question_generation}, _binding), do: true

  defp fixed_result?(%{generation: generation, arguments: arguments}, binding) do
    generation == {binding["tool_id"], binding["tool_version"], binding["definition_digest"]} and
      Map.has_key?(arguments, "artifact_use")
  end

  defp reference(result, sources) do
    Enum.reduce_while(Map.get(result, :artifacts, []), :none, fn reference, _acc ->
      plain = Map.new(reference, fn {key, value} -> {Atom.to_string(key), value} end)

      case Map.get(sources, reference.use_locator) do
        %{"reference" => ^plain} -> {:halt, {:ok, reference}}
        _ -> {:cont, :none}
      end
    end)
  end
end
