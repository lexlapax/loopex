defmodule LoopexCli.ProgressConsumer do
  @moduledoc """
  ## Concept

  The terminal's transient view of model and tool progress. It renders an item
  immediately when that item continues its own stream domain, and remembers
  enough about each domain to decide whether the later durable assistant message
  would be a duplicate or is the required fallback.

  ## Technical depth

  Domains are independent state machines. Each begins at sequence zero, advances
  only by one, and becomes complete or abandoned only when its own content-free
  closure carries the number of items observed for that domain. A gap, duplicate,
  identity change, count mismatch, duplicate closure, or post-closure item makes
  only that domain invalid. A retry therefore cannot repair or poison its
  predecessor.

  Progress is never awaited. The caller drains whatever is already in its mailbox
  and then continues with durable events. A durable assistant message is
  suppressed only when a complete model domain anchored immediately before that
  event reconstructed exactly its text; an open, absent, abandoned, invalid,
  differently anchored, or text-mismatched domain falls back to the durable
  message.
  """

  @model_delta_kinds [:text_delta, :reasoning_delta, :tool_call_delta]
  @dispositions [:complete, :abandoned]

  alias Loopex.ProgressPayload

  @typedoc false
  @type action :: {:stdout | :stderr, binary()}

  @typedoc false
  @type domain_state :: %{
          required(:kind) => :model | :tool,
          required(:identity) => tuple(),
          required(:next_sequence) => non_neg_integer(),
          required(:status) => :open | :complete | :abandoned | :invalid,
          required(:text) => [binary()],
          required(:closure_order) => non_neg_integer() | nil,
          required(:consumed) => boolean()
        }

  @opaque t :: %__MODULE__{
            domains: %{optional(binary()) => domain_state()},
            next_closure_order: non_neg_integer()
          }

  defstruct domains: %{}, next_closure_order: 0

  @doc """
  ## Concept

  Starts an empty transient view.

  ## Technical depth

  No stream is presumed to exist until one of its items is actually delivered.
  """
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  ## Concept

  Consumes one delivered progress item and returns the bytes that are safe to
  show immediately.

  ## Technical depth

  Invalid and unknown items produce no output. A valid model text delta is
  written to standard output; reasoning, tool-call, and tool progress retain the
  command's standard-error presentation. Every valid model delta kind consumes
  its sequence because closure counts cover the whole domain, not only answer
  text.
  """
  @spec consume(t(), term()) :: {t(), [action()]}
  def consume(%__MODULE__{} = state, %{kind: kind} = item) when kind in @model_delta_kinds do
    consume_item(state, :model, item, Map.get(item, :model_sequence))
  end

  def consume(%__MODULE__{} = state, %{kind: :tool_progress} = item) do
    consume_item(state, :tool, item, Map.get(item, :progress_sequence))
  end

  def consume(%__MODULE__{} = state, %{kind: :model_stream_closed} = item) do
    consume_closure(state, :model, item, Map.get(item, :delta_count))
  end

  def consume(%__MODULE__{} = state, %{kind: :tool_stream_closed} = item) do
    consume_closure(state, :tool, item, Map.get(item, :progress_count))
  end

  def consume(%__MODULE__{} = state, _other), do: {state, []}

  @doc """
  ## Concept

  Decides whether a durable assistant message is fallback output or would repeat
  a fully observed transient answer.

  ## Technical depth

  A complete domain is eligible only when its base durable sequence immediately
  precedes this assistant event. Closure order breaks a tie defensively. The
  pairing is consumed even when text differs, because a non-streaming adapter
  legitimately closes a zero-item domain before returning a nonempty durable
  answer and must not be allowed to match an unrelated later turn.
  """
  @spec durable_assistant(t(), non_neg_integer(), term()) :: {t(), :render | :suppress}
  def durable_assistant(%__MODULE__{} = state, event_sequence, content)
      when is_integer(event_sequence) and event_sequence > 0 do
    case next_complete_model(state, event_sequence - 1) do
      nil ->
        {state, :render}

      {domain_id, domain} ->
        next = put_domain(state, domain_id, %{domain | consumed: true})
        reconstructed = domain.text |> Enum.reverse() |> IO.iodata_to_binary()

        if is_binary(content) and reconstructed == content,
          do: {next, :suppress},
          else: {next, :render}
    end
  end

  def durable_assistant(%__MODULE__{} = state, _event_sequence, _content),
    do: {state, :render}

  @doc false
  @spec status(t(), binary()) :: :open | :complete | :abandoned | :invalid | :unknown
  def status(%__MODULE__{domains: domains}, domain_id) when is_binary(domain_id) do
    case Map.get(domains, domain_id) do
      nil -> :unknown
      domain -> domain.status
    end
  end

  defp consume_item(state, kind, item, sequence) do
    with {:ok, domain_id, identity} <- identity(kind, item),
         true <- is_integer(sequence) and sequence >= 0,
         :ok <- valid_visible_payload(kind, item) do
      domain = Map.get(state.domains, domain_id, new_domain(kind, identity))

      if domain.kind == kind and domain.identity == identity and domain.status == :open and
           domain.next_sequence == sequence do
        next_domain = %{
          domain
          | next_sequence: sequence + 1,
            text: retain_text(kind, item, domain.text)
        }

        {put_domain(state, domain_id, next_domain), actions(kind, item)}
      else
        {invalidate(state, domain_id, domain, kind, identity), []}
      end
    else
      _invalid -> {invalidate_known_domain(state, item), []}
    end
  end

  defp consume_closure(state, kind, item, count) do
    disposition = Map.get(item, :disposition)

    with {:ok, domain_id, identity} <- identity(kind, item),
         true <- is_integer(count) and count >= 0,
         true <- disposition in @dispositions do
      domain = Map.get(state.domains, domain_id, new_domain(kind, identity))

      if domain.kind == kind and domain.identity == identity and domain.status == :open and
           domain.next_sequence == count do
        closed = %{
          domain
          | status: disposition,
            closure_order: state.next_closure_order
        }

        {%{
           put_domain(state, domain_id, closed)
           | next_closure_order: state.next_closure_order + 1
         }, []}
      else
        {invalidate(state, domain_id, domain, kind, identity), []}
      end
    else
      _invalid -> {invalidate_known_domain(state, item), []}
    end
  end

  defp identity(:model, item) do
    with domain when is_binary(domain) and domain != "" <- Map.get(item, :stream_domain_id),
         turn when is_binary(turn) <- Map.get(item, :turn_id),
         base when is_integer(base) and base >= 0 <- Map.get(item, :base_event_sequence) do
      {:ok, domain, {turn, base}}
    else
      _invalid -> :error
    end
  end

  defp identity(:tool, item) do
    with domain when is_binary(domain) and domain != "" <- Map.get(item, :stream_domain_id),
         turn when is_binary(turn) <- Map.get(item, :turn_id),
         call when is_binary(call) <- Map.get(item, :tool_call_id),
         base when is_integer(base) and base >= 0 <- Map.get(item, :base_event_sequence) do
      {:ok, domain, {turn, call, base}}
    else
      _invalid -> :error
    end
  end

  defp valid_visible_payload(:model, %{kind: kind, content_index: index, text: text})
       when kind in [:text_delta, :reasoning_delta] and is_integer(index) and index >= 0 and
              is_binary(text) do
    if ProgressPayload.terminal_safe?(text), do: :ok, else: :error
  end

  defp valid_visible_payload(:model, %{
         kind: :tool_call_delta,
         call_index: index,
         tool_call_id: call_id,
         name: name,
         arguments_fragment: fragment
       })
       when is_integer(index) and index >= 0 and (is_binary(call_id) or is_nil(call_id)) and
              (is_binary(name) or is_nil(name)) and (is_binary(fragment) or is_nil(fragment)) do
    if optional_terminal_text?(call_id) and optional_terminal_text?(name) and
         optional_terminal_text?(fragment),
       do: :ok,
       else: :error
  end

  defp valid_visible_payload(:tool, %{chunk: chunk}) when is_binary(chunk) do
    if ProgressPayload.terminal_safe?(chunk), do: :ok, else: :error
  end

  defp valid_visible_payload(_kind, _item), do: :error

  defp optional_terminal_text?(nil), do: true
  defp optional_terminal_text?(value), do: ProgressPayload.terminal_safe?(value)

  defp retain_text(:model, %{kind: :text_delta, text: text}, retained), do: [text | retained]
  defp retain_text(_kind, _item, retained), do: retained

  defp actions(:model, %{kind: :text_delta, text: text}), do: [{:stdout, text}]
  defp actions(:model, %{kind: :reasoning_delta, text: text}), do: [{:stderr, text}]

  defp actions(:model, %{
         kind: :tool_call_delta,
         tool_call_id: call_id,
         name: name,
         arguments_fragment: fragment
       }) do
    label = name || call_id || "tool call"
    identity = if name && call_id, do: "#{name} (#{call_id})", else: label
    [{:stderr, "  · #{identity}: #{fragment || ""}"}]
  end

  defp actions(:tool, %{chunk: chunk}), do: [{:stderr, chunk}]
  defp actions(_kind, _item), do: []

  defp new_domain(kind, identity) do
    %{
      kind: kind,
      identity: identity,
      next_sequence: 0,
      status: :open,
      text: [],
      closure_order: nil,
      consumed: false
    }
  end

  defp invalidate(state, domain_id, domain, kind, identity) do
    invalid =
      if is_map(domain),
        do: %{domain | status: :invalid},
        else: %{new_domain(kind, identity) | status: :invalid}

    put_domain(state, domain_id, invalid)
  end

  defp invalidate_known_domain(state, item) do
    case Map.get(item, :stream_domain_id) do
      domain_id when is_binary(domain_id) and domain_id != "" ->
        case Map.get(state.domains, domain_id) do
          nil -> state
          domain -> put_domain(state, domain_id, %{domain | status: :invalid})
        end

      _unknown ->
        state
    end
  end

  defp put_domain(state, domain_id, domain),
    do: %{state | domains: Map.put(state.domains, domain_id, domain)}

  defp next_complete_model(%__MODULE__{domains: domains}, base_event_sequence) do
    domains
    |> Enum.filter(fn {_domain_id, domain} ->
      domain.kind == :model and domain.status == :complete and not domain.consumed and
        elem(domain.identity, 1) == base_event_sequence
    end)
    |> Enum.min_by(fn {_domain_id, domain} -> domain.closure_order end, fn -> nil end)
  end
end
