defmodule Loopex.LLM.ReqLLM.NativeStream do
  @moduledoc """
  ## Concept

  Assemble one native Anthropic message before ordinary response conversion.
  Only a complete, ordered message can supply reusable native content.

  ## Technical depth

  This invocation-local reducer retains assembled blocks, one open block and
  cumulative usage, never an event log. Failure is permanent. Native content
  spends a 16,384-byte JSON budget before string append; incomplete tool JSON
  has the transport's 8,388,608-byte ceiling and is discarded after decoding.
  The transport separately counts all raw bytes, including SSE framing/pings.
  This module emits no public progress and grants no disclosure eligibility.
  """

  alias Loopex.Model.ContentReferences
  alias ReqLLM.Streaming.SSE
  alias ServerSentEvents.Parser

  @derive {Inspect, only: [:phase, :index]}
  defstruct phase: :new,
            expected_model: nil,
            response_model: nil,
            message_id: nil,
            index: 0,
            blocks: [],
            open: nil,
            json_bytes: 2,
            raw_bytes: 0,
            stop_reason: nil,
            usage: %{input_tokens: nil, output_tokens: nil}

  @content_limit 16_384
  @raw_limit 8_388_608
  @uint64_max 18_446_744_073_709_551_615

  @doc """
  ## Concept

  Start private capture with the registered row's literal response identity.

  ## Technical depth

  Nil is reserved for a generic mapping that makes no literal response-model
  claim. It does not authorize thinking reuse or public reasoning disclosure.
  """
  def new(expected_model) when is_binary(expected_model) or is_nil(expected_model),
    do: %__MODULE__{expected_model: expected_model}

  @doc """
  ## Concept

  Admit the next decoded native event, or permanently fail this invocation.

  ## Technical depth

  Identity is checked before the first content fragment. Block indices are
  consecutive, deltas match the open type, and only native message_stop completes
  capture. Invalid usage remains unknown instead of becoming a reported zero.
  The failure result carries only a cleared reducer, never the rejected event.
  """
  def feed(%__MODULE__{phase: :failed} = state, _event), do: {:error, state}

  def feed(%__MODULE__{} = state, event) do
    case step(state, event) do
      {:ok, next} -> {:ok, next}
      _ -> {:error, fail(state)}
    end
  end

  @doc """
  ## Concept

  Read complete native content and its supported usage evidence.

  ## Technical depth

  EOF, a converted finish reason or a stopped block is insufficient. Native
  capture/response mapping still validates the completed stop/content relation.
  """
  def finish(%__MODULE__{phase: :stopped} = state) do
    {:ok,
     %{
       content: Enum.reverse(state.blocks),
       stop_reason: state.stop_reason,
       model: state.response_model,
       usage: state.usage
     }}
  end

  def finish(%__MODULE__{}), do: {:error, :incomplete_native_stream}

  @doc """
  ## Concept

  Count transport bytes and validate native events before dependency conversion.

  ## Technical depth

  The parser remains the pinned ServerSentEvents.Parser state required by the
  dependency's final flush. Count the entire HTTP fragment before parsing or
  decoding, including comments and framing. Returned events remain private to
  the invocation bridge; the reducer retains none of their raw JSON strings.
  A malformed parser state, JSON value or event permanently clears capture.
  """
  def parse(%__MODULE__{phase: :failed} = state, _chunk, _parser), do: {:error, state}

  def parse(%__MODULE__{} = state, chunk, parser) when is_binary(chunk) do
    total = state.raw_bytes + byte_size(chunk)

    with true <- total <= @raw_limit,
         {:ok, parser} <- parser_state(parser, state.raw_bytes),
         {events, %Parser{} = next_parser} <- Parser.parse(parser, chunk),
         {:ok, next, decoded} <- decode_events(%{state | raw_bytes: total}, events, []) do
      {:ok, next, Enum.reverse(decoded), next_parser}
    else
      _ -> {:error, fail(state)}
    end
  end

  def parse(%__MODULE__{} = state, _chunk, _parser), do: {:error, fail(state)}

  @doc """
  ## Concept

  Require complete original framing and a complete native message at EOF.

  ## Technical depth

  ReqLLM's SSE.flush/1 appends synthetic newlines and silently accepts an unknown
  state. Neither behavior can establish completeness here. Only a consumed
  Parser state reaches that exact pinned flush, which must emit no more events.
  """
  def flush(
        %__MODULE__{phase: :stopped} = state,
        %Parser{phase: phase, key: nil, value: nil, event: nil} = parser
      )
      when phase in [:field, :cr] do
    case SSE.flush(parser) do
      {[], %Parser{}} -> {:ok, state}
      _ -> {:error, fail(state)}
    end
  end

  def flush(%__MODULE__{} = state, _parser), do: {:error, fail(state)}

  defp parser_state(nil, 0), do: {:ok, Parser.new()}

  defp parser_state(%Parser{phase: phase} = parser, _bytes)
       when phase in [:start, :field, :key, :value_start, :value, :skip_line, :cr],
       do: {:ok, parser}

  defp parser_state(_, _), do: :invalid

  defp decode_events(state, [], decoded), do: {:ok, state, decoded}

  defp decode_events(state, [%{event: kind, data: data} | rest], decoded)
       when is_binary(kind) and is_binary(data) do
    with {:ok, %{"type" => ^kind} = event} <- Jason.decode(data),
         {:ok, next} <- feed(state, event) do
      decode_events(next, rest, [event | decoded])
    end
  end

  defp decode_events(_, _, _), do: :invalid

  defp step(%{phase: phase} = state, %{"type" => "ping"} = event)
       when phase in [:new, :blocks, :ending] and map_size(event) == 1,
       do: {:ok, state}

  defp step(%{phase: :new} = state, %{"type" => "message_start", "message" => message} = event)
       when map_size(event) == 2 and is_map(message) do
    with true <-
           Enum.sort(Map.keys(message)) ==
             ~w(content id model role stop_reason stop_sequence type usage),
         true <- message["type"] == "message" and message["role"] == "assistant",
         true <- message["content"] == [] and is_nil(message["stop_reason"]),
         true <- is_nil(message["stop_sequence"]),
         true <- text?(message["id"]) and byte_size(message["id"]) <= 256,
         true <- text?(message["model"]) and byte_size(message["model"]) <= 512,
         true <- is_nil(state.expected_model) or message["model"] == state.expected_model,
         true <- is_map(message["usage"]) do
      {:ok,
       %{
         state
         | phase: :blocks,
           message_id: message["id"],
           response_model: message["model"],
           usage: usage(state.usage, message["usage"])
       }}
    end
  end

  defp step(
         %{phase: :blocks, open: nil, index: index} = state,
         %{"type" => "content_block_start", "index" => index, "content_block" => block} = event
       )
       when map_size(event) == 3 and index < 128 do
    with {:ok, open} <- open_block(block),
         {:ok, bytes} <- ContentReferences.json_size(block),
         total = state.json_bytes + bytes + if(index == 0, do: 0, else: 1),
         true <- total <= @content_limit do
      {:ok, %{state | open: open, json_bytes: total}}
    end
  end

  defp step(
         %{phase: :blocks, open: open, index: index} = state,
         %{"type" => "content_block_delta", "index" => index, "delta" => delta} = event
       )
       when map_size(event) == 3 and not is_nil(open) and is_map(delta),
       do: delta(state, delta)

  defp step(
         %{phase: :blocks, open: open, index: index} = state,
         %{"type" => "content_block_stop", "index" => index} = event
       )
       when map_size(event) == 2 and not is_nil(open) do
    with {:ok, block} <- close_block(open),
         {:ok, final_bytes} <- ContentReferences.json_size(block),
         {:ok, initial_bytes} <- ContentReferences.json_size(open.block),
         total = state.json_bytes + final_bytes - initial_bytes,
         true <- total <= @content_limit do
      {:ok,
       %{state | open: nil, index: index + 1, blocks: [block | state.blocks], json_bytes: total}}
    end
  end

  defp step(
         %{phase: phase, open: nil} = state,
         %{"type" => "message_delta", "delta" => delta, "usage" => counters} = event
       )
       when phase in [:blocks, :ending] and map_size(event) == 3 and is_map(delta) and
              is_map(counters) do
    with true <- Enum.sort(Map.keys(delta)) == ~w(stop_reason stop_sequence),
         true <-
           is_nil(delta["stop_reason"]) or
             (text?(delta["stop_reason"]) and byte_size(delta["stop_reason"]) <= 256),
         true <- is_nil(delta["stop_sequence"]) or is_binary(delta["stop_sequence"]),
         true <- phase == :blocks or state.stop_reason == delta["stop_reason"] do
      {:ok,
       %{
         state
         | phase: :ending,
           stop_reason: delta["stop_reason"],
           usage: usage(state.usage, counters)
       }}
    end
  end

  defp step(%{phase: :ending, open: nil} = state, %{"type" => "message_stop"} = event)
       when map_size(event) == 1,
       do: {:ok, %{state | phase: :stopped}}

  defp step(_, _), do: :invalid

  defp open_block(%{"type" => "text", "text" => value} = block)
       when map_size(block) == 2 and is_binary(value) do
    {:ok, %{block: block}}
  end

  defp open_block(%{"type" => "thinking", "thinking" => value, "signature" => signature} = block)
       when map_size(block) == 3 and is_binary(value) and is_binary(signature),
       do: {:ok, %{block: block, signing: signature != ""}}

  defp open_block(%{"type" => "redacted_thinking", "data" => value} = block)
       when map_size(block) == 2 and is_binary(value) and byte_size(value) > 0,
       do: {:ok, %{block: block}}

  defp open_block(%{"type" => "tool_use", "id" => id, "name" => name, "input" => input} = block)
       when map_size(block) == 4 and is_map(input) and map_size(input) == 0 do
    if text?(id) and text?(name),
      do: {:ok, %{block: block, json: [], json_bytes: 0}},
      else: :invalid
  end

  defp open_block(_), do: :invalid

  defp delta(
         %{open: %{block: %{"type" => "text"}}} = state,
         %{"type" => "text_delta", "text" => value} = delta
       )
       when map_size(delta) == 2,
       do: append(state, "text", value)

  defp delta(
         %{open: %{block: %{"type" => "thinking"}, signing: false}} = state,
         %{"type" => "thinking_delta", "thinking" => value} = delta
       )
       when map_size(delta) == 2,
       do: append(state, "thinking", value)

  defp delta(
         %{open: %{block: %{"type" => "thinking"}}} = state,
         %{"type" => "signature_delta", "signature" => value} = delta
       )
       when map_size(delta) == 2 do
    with {:ok, next} <- append(state, "signature", value),
         do: {:ok, put_in(next.open.signing, true)}
  end

  defp delta(
         %{open: %{block: %{"type" => "tool_use"}} = open} = state,
         %{"type" => "input_json_delta", "partial_json" => value} = delta
       )
       when map_size(delta) == 2 and is_binary(value) do
    total = open.json_bytes + byte_size(value)

    if total <= @raw_limit and String.valid?(value),
      do: {:ok, %{state | open: %{open | json: [value | open.json], json_bytes: total}}},
      else: :invalid
  end

  defp delta(_, _), do: :invalid

  defp append(state, field, fragment) when is_binary(fragment) do
    with {:ok, cost} <- ContentReferences.json_size(fragment),
         total = state.json_bytes + cost - 2,
         true <- total <= @content_limit do
      next = update_in(state.open.block[field], &(&1 <> fragment))
      {:ok, %{next | json_bytes: total}}
    end
  end

  defp append(_, _, _), do: :invalid

  defp close_block(%{block: %{"type" => "thinking", "signature" => ""}}), do: :invalid
  defp close_block(%{block: %{"type" => "tool_use"} = block, json: []}), do: {:ok, block}

  defp close_block(%{block: %{"type" => "tool_use"} = block, json: pieces}) do
    with {:ok, arguments} <- Jason.decode(pieces |> Enum.reverse() |> IO.iodata_to_binary()),
         true <- is_map(arguments) do
      {:ok, %{block | "input" => arguments}}
    end
  end

  defp close_block(%{block: block}), do: {:ok, block}

  defp usage(previous, counters) do
    Enum.reduce(
      [{:input_tokens, "input_tokens"}, {:output_tokens, "output_tokens"}],
      previous,
      fn {key, source}, acc ->
        case Map.fetch(counters, source) do
          :error ->
            acc

          {:ok, value} when is_integer(value) and value in 0..@uint64_max ->
            Map.put(acc, key, value)

          {:ok, _invalid} ->
            Map.put(acc, key, nil)
        end
      end
    )
  end

  defp text?(value), do: is_binary(value) and value != "" and String.valid?(value)
  defp fail(state), do: %__MODULE__{phase: :failed, expected_model: state.expected_model}
end
