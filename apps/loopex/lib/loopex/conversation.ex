defmodule Loopex.Conversation do
  @moduledoc """
  ## Concept

  The conversation the model sees, derived from what the session has actually
  committed. It is a projection, never a second store: a turn is not part of the
  conversation until its record commits, so there is no window in which the
  model has been told something the session cannot prove it said.

  That is what makes turn two a continuation. The provider is not handed a
  retained handle or a session token; it is handed the whole conversation again,
  built from committed records — the operator's prompt, the model's own prior
  assistant messages, and the real output of every tool it ran.

  Fixed by
  [ADR 0010](../../../../docs/adr/0010-provider-continuation-and-context-staging.md#concept).

  ## Technical depth

  Three committed element kinds project into the message list:

  | Element | Carries |
  | --- | --- |
  | `user_message` | `run_id`, `command_id`, the exact prompt bytes |
  | `assistant_message` | `run_id`, `turn_number`, ordered content blocks, ordered tool calls, stop reason, usage |
  | `tool_result` | `run_id`, `turn_number`, `tool_call_id`, terminal outcome, bounded model-facing content, optional artifact references |

  The projected order is fixed: the system block, then any admitted
  project-resource blocks, then the run's prompt, then each turn's assistant
  message followed by that turn's tool results *in the assistant's own call
  order* regardless of the order they completed in.

  `project/2` reads no process state, performs no retrieval, and derives no
  content. Given the same committed elements it produces byte-identical output.
  That is not a stylistic preference: under ADR 0008 the coordinator can be lost
  at any point, so anything held only in its memory is unrecoverable rather than
  merely stale, and a projection that consulted process state could not be
  rebuilt by a successor.

  Projection never consults the tool registry either. A staged request carries
  the complete definition bytes it used, so a request stays reconstructible and
  independently verifiable from the journal alone after the tool has been
  edited, version-bumped, or removed entirely.
  """

  @outcomes [:completed, :failed, :denied, :cancelled, :outcome_unknown]

  alias LoopexProtocol.Canonical

  @typedoc """
  ## Concept

  One committed conversation element.

  ## Technical depth

  Bounded plain data with atom keys, as committed to the journal. The `:kind`
  member discriminates the three shapes.
  """
  @type element :: %{required(:kind) => atom(), optional(atom()) => term()}

  @typedoc """
  ## Concept

  One message in the canonical list handed to a model.

  ## Technical depth

  Binary-keyed plain data, because these bytes are canonicalized into the staged
  request and an atom key would encode differently than the binary key an
  adapter renders.
  """
  @type message :: %{binary() => term()}

  @doc """
  ## Concept

  The terminal outcomes a tool result may carry.

  ## Technical depth

  Closed set. Every member has a defined bounded model-facing content form
  below, so no outcome leaves a hole the model must guess at.
  """
  @spec outcomes() :: [atom()]
  def outcomes, do: @outcomes

  @doc """
  ## Concept

  Projects committed elements into the canonical message list.

  ## Technical depth

  Elements arrive in commit order. The projection groups by turn, emits each
  assistant message followed by its own results in call order, and ignores
  nothing: an element that cannot be placed is a defect in what was committed,
  not something to skip, so `project/2` raises rather than silently producing a
  shorter conversation than the journal describes.

  `:system` supplies the versioned system block and the active tool definitions;
  `:project_blocks` supplies any admitted project-resource blocks, which are
  ordinary input structure and carry no authority.
  """
  @spec project([element()], keyword()) :: [message()]
  def project(elements, options \\ []) when is_list(elements) and is_list(options) do
    system = Keyword.fetch!(options, :system)
    project_blocks = Keyword.get(options, :project_blocks, [])

    [%{"role" => "system", "content" => system}] ++
      Enum.map(project_blocks, &%{"role" => "user", "content" => &1}) ++
      project_elements(elements)
  end

  @doc """
  ## Concept

  Projects complete committed session lineage with unambiguous model-facing
  tool identities, retaining the canonical source identity beside each message.

  ## Technical depth

  Projection revision 1 joins calls and results by run, turn and call identity.
  Each provider-facing ID is `lx_` plus the first 48 lowercase SHA-256 hex
  characters of `Canonical.encode([run_id, turn_number, tool_call_id])`.
  Missing, duplicate or orphan facts and normalized-ID collisions return
  `context_projection_invalid`. Every current request binds this committed
  lineage projection; no older per-run projection is admitted.
  """
  @spec lineage_entries([element()]) ::
          {:ok, [{map(), message()}]} | {:error, :context_projection_invalid}
  def lineage_entries(elements) when is_list(elements) do
    with {:ok, calls, results} <- lineage_identities(elements),
         true <- MapSet.new(Map.keys(calls)) == results,
         true <- MapSet.size(MapSet.new(Map.values(calls))) == map_size(calls) do
      {:ok,
       Enum.map(project_entries(elements), fn {source, message} ->
         {source, normalize_call_ids(source, message, calls)}
       end)}
    else
      _invalid -> {:error, :context_projection_invalid}
    end
  end

  def lineage_entries(_invalid), do: {:error, :context_projection_invalid}

  # Concept: a projected message and its original fact share one source identity.
  # Technical depth: this identity labels conversation data, never provider or
  # executor authority. Replay uses it to bind complete original-record digests
  # independently of the bytes a renderer exposes to the model.
  @doc false
  @spec source_reference(element()) :: map()
  def source_reference(%{kind: :user_message, run_id: run, command_id: command}),
    do: %{"kind" => "session_command", "run_id" => run, "command_id" => command}

  def source_reference(%{kind: :assistant_message, run_id: run, turn_number: turn}),
    do: %{"kind" => "session_assistant", "run_id" => run, "turn" => turn}

  def source_reference(%{
        kind: :tool_result,
        run_id: run,
        turn_number: turn,
        tool_call_id: call
      }),
      do: %{"kind" => "session_tool_result", "run_id" => run, "turn" => turn, "call_id" => call}

  # Concept: compaction preserves complete exchanges and their preceding inputs.
  # Technical depth: these transient units contain no maintenance records. A
  # selector may cover only a contiguous prefix before its first protected unit.
  # Request sizing, tail release and checkpoint coverage are applied separately.
  @doc false
  @spec compaction_units([element()], binary() | nil, [binary()], [map()]) ::
          {:ok, [map()]} | {:error, :context_projection_invalid}
  def compaction_units(elements, current_run, terminal_runs, frozen_sources)
      when is_list(elements) and (is_binary(current_run) or is_nil(current_run)) and
             is_list(terminal_runs) and
             is_list(frozen_sources) do
    with {:ok, calls, _results} <- lineage_identities(elements),
         true <- MapSet.size(MapSet.new(Map.values(calls))) == map_size(calls),
         runs = Enum.chunk_by(elements, & &1.run_id),
         run_ids = Enum.map(runs, &hd(&1).run_id),
         true <- length(run_ids) == MapSet.size(MapSet.new(run_ids)) do
      terminal = MapSet.new(terminal_runs)
      frozen = MapSet.new(frozen_sources)

      {:ok,
       Enum.flat_map(runs, fn run_elements ->
         run_units(run_elements)
         |> Enum.map(fn unit ->
           frozen? =
             Enum.any?(project_entries(unit.elements), &MapSet.member?(frozen, elem(&1, 0)))

           Map.put(
             unit,
             :protected?,
             unit.run_id == current_run or not MapSet.member?(terminal, unit.run_id) or
               not unit.complete? or frozen?
           )
         end)
       end)}
    else
      _invalid -> {:error, :context_projection_invalid}
    end
  end

  def compaction_units(_, _, _, _), do: {:error, :context_projection_invalid}

  defp run_units(elements) do
    results =
      elements
      |> Enum.filter(&(&1.kind == :tool_result))
      |> Map.new(&{{&1.turn_number, &1.tool_call_id}, &1})

    {units, pending} =
      Enum.reduce(elements, {[], []}, fn
        %{kind: :user_message} = input, {units, pending} ->
          {units, [input | pending]}

        %{kind: :assistant_message} = assistant, {units, pending} ->
          ordered_results =
            Enum.flat_map(assistant.tool_calls, fn call ->
              case Map.fetch(results, {assistant.turn_number, call.tool_call_id}) do
                {:ok, result} -> [result]
                :error -> []
              end
            end)

          unit = %{
            kind: :assistant_group,
            run_id: assistant.run_id,
            elements: Enum.reverse(pending) ++ [assistant | ordered_results],
            complete?: length(ordered_results) == length(assistant.tool_calls)
          }

          {[unit | units], []}

        %{kind: :tool_result}, acc ->
          acc
      end)

    units =
      case pending do
        [] ->
          units

        [input | _] ->
          [
            %{
              kind: :inputs,
              run_id: input.run_id,
              elements: Enum.reverse(pending),
              complete?: true
            }
            | units
          ]
      end

    Enum.reverse(units)
  end

  @doc """
  ## Concept

  Whether retained terminal runs contain tool results without a following
  assistant completion, requiring an explicitly compatible provider renderer.

  ## Technical depth

  Validates the complete lineage before inspecting each named terminal run's
  last nonempty assistant message. An empty message with no calls is absent
  for this check. A later run's completion cannot complete an earlier run's
  tool turn. Current nonterminal exchanges are excluded by the caller's exact
  terminal-run identities. No content or call identity is rewritten.
  """
  @spec terminal_tool_history([element()], [binary()]) ::
          {:ok, boolean()} | {:error, :context_projection_invalid}
  def terminal_tool_history(elements, terminal_runs) when is_list(terminal_runs) do
    with {:ok, entries} <- lineage_entries(elements) do
      last_assistants =
        Enum.reduce(entries, %{}, fn
          {%{"kind" => "session_assistant", "run_id" => run}, message}, acc ->
            if message["content"] != "" or message["tool_calls"] != [],
              do: Map.put(acc, run, message),
              else: acc

          _entry, acc ->
            acc
        end)

      {:ok,
       Enum.any?(terminal_runs, fn run ->
         case Map.get(last_assistants, run) do
           nil -> false
           message -> message["tool_calls"] != []
         end
       end)}
    end
  end

  def terminal_tool_history(_, _), do: {:error, :context_projection_invalid}

  @doc """
  ## Concept

  Whether every tool call of the latest assistant message has a committed
  terminal result.

  ## Technical depth

  The next request may not be staged while this is false. A partially resolved
  turn would project an assistant message whose calls have no answers, which is
  a conversation no provider is owed and no journal can justify.
  """
  @spec turn_settled?([element()]) :: boolean()
  def turn_settled?(elements) do
    case last_assistant(elements) do
      nil ->
        true

      assistant ->
        answered =
          elements
          |> Enum.filter(&same_turn_result?(&1, assistant.run_id, assistant.turn_number))
          |> MapSet.new(& &1.tool_call_id)

        Enum.all?(assistant.tool_calls, &MapSet.member?(answered, &1.tool_call_id))
    end
  end

  @doc """
  ## Concept

  The most recently committed assistant message, if any.

  ## Technical depth

  The turn machine asks this whether the model stopped requesting tools, which
  is the first thing checked and the only thing that ends a run `completed`.
  """
  @spec last_assistant([element()]) :: element() | nil
  def last_assistant(elements) do
    elements
    |> Enum.filter(&(&1.kind == :assistant_message))
    |> List.last()
  end

  @doc """
  ## Concept

  Whether a tool result may be committed for this call right now.

  ## Technical depth

  A result is admitted only when its `tool_call_id` names a call in the
  *immediately preceding* committed assistant message of the same run, and only
  when every earlier call in that message's order already has one. Both rules
  are enforced here rather than at the call site, so a coordinator cannot commit
  results out of order by taking a different path to the store.
  """
  @spec admits_result?([element()], binary(), binary()) :: boolean()
  def admits_result?(elements, run_id, tool_call_id) do
    case last_assistant(elements) do
      %{run_id: ^run_id, turn_number: turn_number, tool_calls: calls} ->
        answered =
          elements
          |> Enum.filter(&same_turn_result?(&1, run_id, turn_number))
          |> MapSet.new(& &1.tool_call_id)

        expected =
          calls
          |> Enum.map(& &1.tool_call_id)
          |> Enum.find(&(not MapSet.member?(answered, &1)))

        expected == tool_call_id

      _other ->
        false
    end
  end

  @doc """
  ## Concept

  The bounded content a model is shown for one terminal outcome.

  ## Technical depth

  Every outcome has a form, including the ones a model cannot act on. An
  `outcome_unknown` in particular must say so plainly rather than read as a
  failure the model might retry, because the whole point of that outcome is that
  nobody knows whether the effect happened.
  """
  @spec result_content(atom(), binary() | nil) :: binary()
  def result_content(:completed, content) when is_binary(content) and content != "",
    do: content

  # Concept: a tool that completed and said nothing still completed.
  #
  # Technical depth: an empty result is indistinguishable to a model from a call
  # that failed silently, and the reasonable response to that is to try again --
  # which is what a tool with no output actually produced here, repeatedly, in a
  # real trace. An empty content block is also refused outright by some
  # providers. The result says what is true rather than saying nothing.
  def result_content(:completed, _absent), do: "The tool completed and produced no output."
  def result_content(:failed, reason), do: "The tool failed: #{reason || "no reason recorded"}."

  def result_content(:denied, category),
    do: "The host refused this call: #{category || "policy_denied"}. Do not retry it."

  def result_content(:cancelled, _reason),
    do: "This call was cancelled before it produced a result."

  def result_content(:outcome_unknown, reference),
    do:
      "Whether this call took effect is unknown and is being reconciled" <>
        if(is_binary(reference), do: " under #{reference}", else: "") <>
        ". Do not assume it succeeded and do not retry it."

  defp project_elements(elements) do
    Enum.map(project_entries(elements), &elem(&1, 1))
  end

  defp project_entries(elements) do
    Enum.flat_map(elements, fn
      %{kind: :user_message, content: content} = input ->
        [
          {source_reference(input), %{"role" => "user", "content" => content}}
        ]

      %{kind: :assistant_message} = assistant ->
        [
          {source_reference(assistant), assistant_message(assistant)}
          | turn_result_entries(elements, assistant)
        ]

      %{kind: :tool_result} ->
        # Concept: results are emitted with their assistant message, not here.
        #
        # Technical depth: emitting them in commit order would put a fast
        # tool's answer ahead of a slow one that the model asked for first,
        # which changes the bytes the provider sees for the same committed
        # journal. `turn_results/2` re-orders them into the assistant's own
        # call order instead.
        []

      other ->
        raise ArgumentError, "cannot project an unknown conversation element: #{inspect(other)}"
    end)
  end

  defp assistant_message(assistant) do
    %{
      "role" => "assistant",
      "content" => assistant.content,
      "tool_calls" =>
        Enum.map(assistant.tool_calls, fn call ->
          # Concept: a call names the exact generation it resolved through.
          #
          # Technical depth: a call whose name resolved to nothing carries no
          # generation and is never dispatched; it is projected with its name
          # alone so the conversation still shows what the model asked for.
          case call.generation do
            {tool_id, tool_version, definition_digest} ->
              %{
                "tool_call_id" => call.tool_call_id,
                "tool_id" => tool_id,
                "tool_version" => tool_version,
                "definition_digest" => definition_digest,
                "arguments" => call.arguments
              }

            nil ->
              %{
                "tool_call_id" => call.tool_call_id,
                "name" => call.name,
                "arguments" => call.arguments
              }
          end
        end)
    }
  end

  defp turn_result_entries(elements, assistant) do
    by_call =
      elements
      |> Enum.filter(&same_turn_result?(&1, assistant.run_id, assistant.turn_number))
      |> Map.new(&{&1.tool_call_id, &1})

    assistant.tool_calls
    |> Enum.map(& &1.tool_call_id)
    |> Enum.flat_map(fn tool_call_id ->
      case Map.fetch(by_call, tool_call_id) do
        {:ok, result} ->
          [
            {
              source_reference(result),
              %{
                "role" => "tool",
                "tool_call_id" => tool_call_id,
                "outcome" => Atom.to_string(result.outcome),
                "content" => result.content
              }
            }
          ]

        :error ->
          []
      end
    end)
  end

  defp same_turn_result?(element, run_id, turn_number),
    do:
      element.kind == :tool_result and element.run_id == run_id and
        element.turn_number == turn_number

  defp lineage_identities(elements) do
    Enum.reduce_while(elements, {:ok, %{}, MapSet.new(), MapSet.new()}, fn
      %{kind: :user_message, run_id: run, command_id: command, content: content}, acc
      when is_binary(run) and run != "" and is_binary(command) and command != "" and
             is_binary(content) ->
        {:cont, acc}

      %{
        kind: :assistant_message,
        run_id: run,
        turn_number: turn,
        content: content,
        tool_calls: calls
      },
      {:ok, identities, results, turns}
      when is_binary(run) and run != "" and is_integer(turn) and turn > 0 and
             is_binary(content) and is_list(calls) ->
        with false <- MapSet.member?(turns, {run, turn}),
             {:ok, identities} <- lineage_calls(calls, run, turn, identities) do
          {:cont, {:ok, identities, results, MapSet.put(turns, {run, turn})}}
        else
          _invalid -> {:halt, :invalid}
        end

      %{
        kind: :tool_result,
        run_id: run,
        turn_number: turn,
        tool_call_id: call,
        content: content,
        outcome: outcome
      },
      {:ok, identities, results, turns}
      when is_binary(content) and outcome in @outcomes ->
        identity = {run, turn, call}

        if Map.has_key?(identities, identity) and not MapSet.member?(results, identity) do
          {:cont, {:ok, identities, MapSet.put(results, identity), turns}}
        else
          {:halt, :invalid}
        end

      _element, _acc ->
        {:halt, :invalid}
    end)
    |> case do
      {:ok, identities, results, _turns} -> {:ok, identities, results}
      _invalid -> {:error, :context_projection_invalid}
    end
  end

  defp lineage_calls(calls, run, turn, identities) do
    Enum.reduce_while(calls, {:ok, identities}, fn
      %{tool_call_id: id, arguments: arguments, generation: generation} = call, {:ok, identities}
      when is_binary(id) and id != "" and is_map(arguments) ->
        valid_generation =
          case generation do
            {tool, version, digest}
            when is_binary(tool) and is_binary(version) and
                   is_binary(digest) ->
              true

            nil ->
              is_binary(Map.get(call, :name))

            _invalid ->
              false
          end

        identity = {run, turn, id}

        if valid_generation and not Map.has_key?(identities, identity) do
          normalized = normalized_call_id(run, turn, id)
          {:cont, {:ok, Map.put(identities, identity, normalized)}}
        else
          {:halt, {:error, :context_projection_invalid}}
        end

      _call, _acc ->
        {:halt, {:error, :context_projection_invalid}}
    end)
  end

  @doc false
  @spec normalized_call_id(binary(), pos_integer(), binary()) :: binary()
  def normalized_call_id(run, turn_number, raw_call_id),
    do: "lx_" <> binary_part(Canonical.digest([run, turn_number, raw_call_id]), 0, 48)

  defp normalize_call_ids(
         %{"kind" => "session_assistant", "run_id" => run, "turn" => turn},
         message,
         calls
       ) do
    Map.update!(message, "tool_calls", fn tool_calls ->
      Enum.map(tool_calls, fn call ->
        Map.put(call, "tool_call_id", Map.fetch!(calls, {run, turn, call["tool_call_id"]}))
      end)
    end)
  end

  defp normalize_call_ids(
         %{"kind" => "session_tool_result", "run_id" => run, "turn" => turn, "call_id" => call},
         message,
         calls
       ),
       do: Map.put(message, "tool_call_id", Map.fetch!(calls, {run, turn, call}))

  defp normalize_call_ids(_source, message, _calls), do: message
end
