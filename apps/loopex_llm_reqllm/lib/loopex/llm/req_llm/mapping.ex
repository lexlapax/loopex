defmodule Loopex.LLM.ReqLLM.Mapping do
  @moduledoc """
  ## Concept

  Shared request and reply mapping for the companion and in-process model edges.
  Application tool calls cross as decoded data for core to resolve and authorize.

  ## Technical depth

  This internal module has no process state or transport effects. It preserves
  conversation rendering, reply identities and finite failure classes. Buffered
  ToolCall arguments must decode without JSON repair into an object. Visible
  builtin, provider-native and error markers refuse the whole ordered call list.
  Defects erased earlier by ReqLLM cannot be reconstructed here.
  """

  @response_id_bytes 256

  @doc """
  ## Concept

  Build the finite diagnostic pair for a failed private boundary.

  ## Technical depth

  Shared by both model edges. It introduces no dispatch or session authority.
  """
  def failure_pair(stage, class), do: %{"stage" => stage, "class" => class}

  @doc """
  ## Concept

  Classify a returned dependency failure without exposing its raw cause.

  ## Technical depth

  Shared by both model edges. It introduces no dispatch or session authority.
  """
  def returned_class({:error, %ReqLLM.Error.API.Stream{} = exception}),
    do: raised_class(exception)

  # Concept: library return wrappers do not erase an observed typed cause.
  # Technical depth: ReqLLM's request-build boundary returns these fixed wrappers;
  # unwrap only their API.Stream value and keep all raw fields inside the worker.
  def returned_class({:error, {tag, %ReqLLM.Error.API.Stream{} = exception}})
      when tag in [:build_request_failed, :provider_build_failed],
      do: raised_class(exception)

  def returned_class(
        {:error, {:http_streaming_failed, {tag, %ReqLLM.Error.API.Stream{} = exception}}}
      )
      when tag in [:build_request_failed, :provider_build_failed],
      do: raised_class(exception)

  def returned_class({:error, {:stream_failed, {:provider_status, status}}})
      when is_integer(status) and status >= 400 do
    "provider_status"
  end

  def returned_class({:error, {:stream_failed, _}}), do: "stream_failed"
  def returned_class({:error, {:stream_incomplete, _}}), do: "stream_incomplete"
  def returned_class({:error, {:reply_not_assembled, _}}), do: "assembly_failed"
  def returned_class(_), do: "returned_error"

  @doc """
  ## Concept

  Classify a raised dependency failure without exposing its raw cause.

  ## Technical depth

  Shared by both model edges. It introduces no dispatch or session authority.
  """
  def raised_class(%ReqLLM.Error.API.Stream{cause: cause}) do
    case cause do
      %ReqLLM.Error.API.Request{status: status} when status in [401, 403] ->
        "stream_http_auth"

      %ReqLLM.Error.API.Request{status: 429} ->
        "stream_http_rate_limit"

      %ReqLLM.Error.API.Request{status: status} when is_integer(status) and status in 500..599 ->
        "stream_http_server"

      %ReqLLM.Error.API.Request{status: status} when is_integer(status) and status >= 400 ->
        "stream_http_status"

      %Finch.TransportError{reason: :timeout} ->
        "stream_transport_timeout"

      %Finch.TransportError{reason: {:tls_alert, _}} ->
        "stream_transport_tls"

      %Finch.TransportError{} ->
        "stream_transport_error"

      %Mint.TransportError{reason: :timeout} ->
        "stream_transport_timeout"

      %Mint.TransportError{reason: {:tls_alert, _}} ->
        "stream_transport_tls"

      %Mint.TransportError{} ->
        "stream_transport_error"

      %Finch.HTTPError{} ->
        "stream_http_protocol_error"

      %Finch.Error{} ->
        "stream_finch_error"

      {:http_task_failed, _} ->
        "stream_http_task_failed"

      :timeout ->
        "stream_wait_timeout"

      {:exit, {:timeout, {GenServer, :call, _}}} ->
        "stream_task_call_timeout"

      %Jason.DecodeError{} ->
        "stream_decode_error"

      {:error, %Jason.DecodeError{}} ->
        "stream_decode_error"

      _ ->
        "stream_other_error"
    end
  end

  def raised_class(_), do: "raised"

  @doc """
  ## Concept

  Build the bounded model reply with the committed request identity.

  ## Technical depth

  Shared by both model edges. It introduces no dispatch or session authority.
  """
  def reply(request, identity, metadata, text, calls, deltas) do
    reported = Map.get(metadata, :usage) || %{}

    %{
      text: text,
      identity: identity,
      provider_response_id: provider_request_id(metadata, identity),
      usage: %{
        input_tokens: Map.get(reported, :input_tokens),
        output_tokens: Map.get(reported, :output_tokens)
      },
      tool_calls: calls,
      delta_count: deltas,
      streamed: deltas > 0,
      canonical_request_bytes: request.canonical_request_bytes,
      staged_request_digest: request.staged_request_digest
    }
  end

  # Concept: a completion the provider finished, distinguished from one that was
  # cut off — including the completion that finished with nothing to say.
  #
  # Technical depth: failure is decided on positive evidence and never on
  # emptiness. A model that answers with no text at all still finishes `stop` and
  # is a success; what fails is a metadata error, a provider status of 400 or
  # above, or a finish reason that names an ending rather than a stop. The
  # library guarantees one of the first two whenever the stream did not terminate
  # cleanly, and substitutes `incomplete` for a missing finish reason on that
  # path, so an unfamiliar provider-specific reason is not read as a fault: a
  # reason this adapter has never seen is not evidence that anything went wrong.
  # `length` is a stop, not a cut: the provider ended the turn at the output
  # allowance core committed, and the tool-call check below is what catches a
  # call that allowance truncated.
  @doc """
  ## Concept

  Require positive completion evidence before exposing a reply.

  ## Technical depth

  Shared by both model edges. It introduces no dispatch or session authority.
  """
  def completed(metadata) do
    cond do
      is_map(metadata) and is_map_key(metadata, :error) ->
        {:error, {:stream_failed, Map.get(metadata, :error)}}

      error_status?(Map.get(metadata, :status)) ->
        {:error, {:stream_failed, {:provider_status, Map.get(metadata, :status)}}}

      Map.get(metadata, :finish_reason) in [:incomplete, :cancelled, :error] ->
        {:error, {:stream_incomplete, Map.get(metadata, :finish_reason)}}

      true ->
        :ok
    end
  end

  defp error_status?(status) when is_integer(status) and status >= 400, do: true
  defp error_status?(_status), do: false

  @doc """
  ## Concept

  Admit the whole ordered list of replayable application calls.

  ## Technical depth

  Shared by both model edges. It introduces no dispatch or session authority.
  """
  def bounded_calls(assembled) do
    assembled
    |> ReqLLM.Response.tool_calls()
    |> Enum.reduce_while({:ok, []}, fn call, {:ok, built} ->
      case application_call(call) do
        {:ok, mapped} -> {:cont, {:ok, [mapped | built]}}
        :invalid -> {:halt, {:error, {:tool_call_not_reconstructible, :invalid_application_call}}}
      end
    end)
    |> case do
      {:ok, built} -> {:ok, Enum.reverse(built)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp application_call(%ReqLLM.ToolCall{type: "function", id: id, function: function} = call)
       when is_binary(id) and id != "" and is_map(function) do
    metadata = ReqLLM.ToolCall.metadata(call)

    with false <- ReqLLM.ToolCall.builtin?(call),
         false <- ReqLLM.ToolCall.provider_native?(call),
         false <- Map.has_key?(metadata, :error) or Map.has_key?(metadata, "error"),
         %{name: name, arguments: raw} when is_binary(name) and name != "" and is_binary(raw) <-
           function,
         {:ok, arguments} when is_map(arguments) <- ReqLLM.JSON.decode(raw, json_repair: false) do
      {:ok, %{id: id, name: name, arguments: arguments}}
    else
      _invalid -> :invalid
    end
  end

  defp application_call(_call), do: :invalid

  defp provider_request_id(metadata, identity) do
    headers = Map.get(metadata, :headers, [])

    case Map.get(identity, :provider) do
      "anthropic" -> headers |> header("request-id") |> bounded_response_id()
      "openai" -> headers |> header("x-request-id") |> bounded_response_id()
      _unknown -> nil
    end
  end

  # Concept: a header that cannot be the provider's identifier is an absence
  # rather than a value.
  #
  # Technical depth: a reply may carry `nil` or a nonempty UTF-8 binary of at
  # most `@response_id_bytes` bytes, so anything longer or not valid UTF-8 fails
  # the reply shape rather than the header. Truncating it would produce an
  # identifier no auditor could look up in the provider's account, which is the
  # one thing this field exists not to do.
  defp bounded_response_id(value)
       when is_binary(value) and value != "" and byte_size(value) <= @response_id_bytes do
    if String.valid?(value), do: value, else: nil
  end

  defp bounded_response_id(_absent), do: nil

  defp header(headers, name) when is_list(headers) do
    Enum.find_value(headers, fn
      {key, value} when is_binary(key) -> if String.downcase(key) == name, do: present(value)
      _other -> nil
    end)
  end

  defp header(headers, name) when is_map(headers), do: headers |> Map.to_list() |> header(name)
  defp header(_headers, _name), do: nil

  defp present(value) when is_binary(value) and value != "", do: value
  defp present([value | _rest]), do: present(value)
  defp present(_absent), do: nil

  @doc """
  ## Concept

  Render every committed conversation role for the provider.

  ## Technical depth

  Shared by both model edges. It introduces no dispatch or session authority.
  """
  def context_of(%{messages: messages} = request) when is_list(messages) do
    names =
      Map.new(
        Map.get(request, :tools, []),
        &{LoopexProtocol.ToolDefinition.generation(&1), &1["name"]}
      )

    case Enum.reduce_while(messages, {:ok, []}, &render_message(&1, &2, names)) do
      {:ok, rendered} -> {:ok, ReqLLM.Context.new(Enum.reverse(rendered))}
      {:error, reason} -> {:error, reason}
    end
  end

  def context_of(_request), do: {:error, :unsupported_model_request}

  defp render_message(%{"role" => "system", "content" => content}, {:ok, acc}, _names)
       when is_binary(content),
       do: {:cont, {:ok, [ReqLLM.Context.system(content) | acc]}}

  defp render_message(%{"role" => "user", "content" => content}, {:ok, acc}, _names)
       when is_binary(content),
       do: {:cont, {:ok, [ReqLLM.Context.user(content) | acc]}}

  defp render_message(%{"role" => "assistant"} = message, {:ok, acc}, names) do
    text = Map.get(message, "content", "")

    with true <- is_binary(text),
         {:ok, calls} <- canonical_calls(Map.get(message, "tool_calls", []), names) do
      parts = if text == "", do: [], else: [ReqLLM.Message.ContentPart.text(text)]
      {:cont, {:ok, [ReqLLM.Context.assistant(parts, tool_calls: calls) | acc]}}
    else
      _ -> {:halt, {:error, :unsupported_model_request}}
    end
  end

  defp render_message(%{"role" => "tool"} = message, {:ok, acc}, _names) do
    content = Map.get(message, "content", "")
    id = Map.get(message, "tool_call_id")
    {:cont, {:ok, [ReqLLM.Context.tool_result(id, content) | acc]}}
  end

  defp render_message(_unknown, _acc, _names), do: {:halt, {:error, :unsupported_model_request}}

  @doc """
  ## Concept

  Resolve canonical calls without guessing names or repairing malformed arguments.

  ## Technical depth

  Both ordinary context conversion and native rendering use the complete retained
  generation to find known model-visible names. Unknown calls retain their literal
  name. A missing generation binding, empty identity or non-object arguments refuse.
  """
  def canonical_calls(calls, names) when is_list(calls) and is_map(names) do
    Enum.reduce_while(calls, {:ok, []}, fn
      %{"tool_call_id" => id, "arguments" => arguments} = call, {:ok, acc}
      when is_binary(id) and id != "" and is_map(arguments) ->
        name =
          case call do
            %{"tool_id" => tool, "tool_version" => version, "definition_digest" => digest} ->
              names[{tool, version, digest}]

            %{"name" => name} ->
              name

            _ ->
              nil
          end

        if is_binary(name) and name != "",
          do: {:cont, {:ok, [%{id: id, name: name, arguments: arguments} | acc]}},
          else: {:halt, {:error, :unsupported_model_request}}

      _, _ ->
        {:halt, {:error, :unsupported_model_request}}
    end)
    |> case do
      {:ok, calls} -> {:ok, Enum.reverse(calls)}
      error -> error
    end
  end

  def canonical_calls(_, _), do: {:error, :unsupported_model_request}

  @doc """
  ## Concept

  Build model-visible definitions whose callbacks require the executor boundary.

  ## Technical depth

  Shared by both model edges. It introduces no dispatch or session authority.
  """
  def provider_tools(tools) when is_list(tools) do
    Enum.reduce_while(tools, {:ok, []}, fn definition, {:ok, built} ->
      case provider_tool(definition) do
        {:ok, tool} -> {:cont, {:ok, [tool | built]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, built} -> {:ok, Enum.reverse(built)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp provider_tool(%{
         "name" => name,
         "description" => description,
         "parameter_schema" => input_schema
       })
       when is_binary(name) and is_binary(description) and is_map(input_schema) do
    case ReqLLM.Tool.new(
           name: name,
           description: description,
           parameter_schema: input_schema,
           callback: fn _arguments -> {:error, :executor_boundary_required} end
         ) do
      {:ok, tool} -> {:ok, tool}
      {:error, _reason} -> {:error, :invalid_model_tool}
    end
  end

  defp provider_tool(_definition), do: {:error, :invalid_model_tool}
end
