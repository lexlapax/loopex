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

  @doc false
  @spec session_entries([element()]) :: [{binary(), message()}]
  def session_entries(elements) when is_list(elements), do: project_entries(elements)

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
          |> Enum.filter(&(&1.kind == :tool_result and &1.turn_number == assistant.turn_number))
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
          |> Enum.filter(&(&1.kind == :tool_result and &1.turn_number == turn_number))
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
      %{kind: :user_message, run_id: run_id, command_id: command_id, content: content} ->
        [
          {"session:#{run_id}:command:#{command_id}", %{"role" => "user", "content" => content}}
        ]

      %{kind: :assistant_message, run_id: run_id, turn_number: turn_number} = assistant ->
        [
          {"session:#{run_id}:turn:#{turn_number}:assistant", assistant_message(assistant)}
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
      |> Enum.filter(&(&1.kind == :tool_result and &1.turn_number == assistant.turn_number))
      |> Map.new(&{&1.tool_call_id, &1})

    assistant.tool_calls
    |> Enum.map(& &1.tool_call_id)
    |> Enum.flat_map(fn tool_call_id ->
      case Map.fetch(by_call, tool_call_id) do
        {:ok, result} ->
          [
            {
              "session:#{result.run_id}:turn:#{result.turn_number}:tool:#{tool_call_id}",
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
end
