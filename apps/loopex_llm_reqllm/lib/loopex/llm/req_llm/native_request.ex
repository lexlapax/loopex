defmodule Loopex.LLM.ReqLLM.NativeRequest do
  @moduledoc """
  ## Concept

  Render captured Anthropic requests without rewriting private native content.

  ## Technical depth

  Both transport paths use the same post-normalization body boundary. The
  adapter verifies the captured ADR 0044 cell, committed output limit and closed
  control set before replacing canonical assistant views with expanded arrays.
  This module registers no model support and performs no transport or lookup.
  """

  alias Loopex.Model
  alias Loopex.Model.Continuation
  alias Loopex.LLM.ReqLLM.{Mapping, NativeContent}
  alias LoopexProtocol.ToolDefinition

  @invalid {:error, :invalid_provider_request}
  @haiku "anthropic:claude-haiku-4-5-20251001"
  @fable "anthropic:claude-fable-5-1"
  @generic %{
    "mapping_revision" => "loopex.unregistered.default.v1",
    "renderer_revision" => "loopex.reqllm.canonical.v1",
    "continuation_required" => false,
    "canonical_terminal_tool_history" => false,
    "thinking_disabled" => false,
    "thinking" => %{"mode" => "omitted"}
  }

  @doc """
  ## Concept

  Derive reply identity and disclosure rules from the exact captured cell.

  ## Technical depth

  Only literal model/revision/level combinations match. Manual budgets must fit
  strictly below the committed allowance. Summary eligibility is derived here,
  never accepted as an independently supplied disclosure flag. A legacy request
  without a captured mapping retains generic default behavior.
  """
  def profile(%{model: "anthropic:" <> model, sampling: sampling} = request) do
    captured = Map.get(sampling, "provider_mapping", @generic)
    level = Map.get(sampling, "reasoning", "default")

    cond do
      captured == @generic and level == "default" and is_nil(request.continuation) ->
        {:ok, %{mapping: captured, response_model: nil, summary: false}}

      request.model in [@haiku, @fable] ->
        with {:ok, thinking, required, summary} <- thinking(request.model, level),
             expected = %{
               "mapping_revision" =>
                 if(request.model == @haiku,
                   do: "loopex.anthropic.haiku45.v1",
                   else: "loopex.anthropic.fable51.v1"
                 ),
               "renderer_revision" => "loopex.anthropic.native.v1",
               "continuation_required" => required,
               "canonical_terminal_tool_history" => true,
               "thinking_disabled" => thinking == %{"mode" => "disabled"},
               "thinking" => thinking
             },
             true <- captured == expected,
             true <- required or is_nil(request.continuation),
             true <- Model.max_tokens(request) > Map.get(thinking, "budget_tokens", 0) do
          {:ok, %{mapping: expected, response_model: model, summary: summary}}
        else
          _ -> @invalid
        end

      true ->
        @invalid
    end
  end

  def profile(_), do: @invalid

  @doc """
  ## Concept

  Install exact native messages and controls after dependency normalization.

  ## Technical depth

  The dependency must preserve the selected model, reply limit and stream mode,
  with no unsolicited controls. Generic rendering remains dependency-owned.
  Registered native rendering resolves known call names by their complete tool
  generation, preserves unknown names, and maps each tool result to its retained
  native ID. A malformed argument is refused, never repaired into an object.
  """
  def render(request, body, streaming) when is_map(body) and is_boolean(streaming) do
    with :ok <- Model.validate_request(request),
         {:ok, profile} <- profile(request),
         true <-
           Enum.all?(Map.keys(body), &(&1 in ~w(model messages system tools max_tokens stream))),
         "anthropic:" <> model <- request.model,
         true <- body["model"] == model and body["max_tokens"] == Model.max_tokens(request),
         true <- Map.get(body, "stream", false) == streaming,
         tools = native_tools(request.tools),
         true <- Map.get(body, "tools", []) == tools do
      if profile.mapping == @generic do
        {:ok, body}
      else
        with {:ok, expanded} <-
               Continuation.expand(request.continuation, request.model, request.messages),
             {:ok, system, messages} <- messages(request, expanded) do
          native = %{
            "model" => model,
            "messages" => messages,
            "max_tokens" => Model.max_tokens(request)
          }

          native = if system == [], do: native, else: Map.put(native, "system", system)
          native = if streaming, do: Map.put(native, "stream", true), else: native

          native = if tools == [], do: native, else: Map.put(native, "tools", tools)
          {:ok, controls(native, profile.mapping["thinking"])}
        end
      end
    else
      _ -> @invalid
    end
  end

  def render(_, _, _), do: @invalid

  defp native_tools(tools) do
    Enum.map(tools, fn tool ->
      %{
        "name" => tool["name"],
        "description" => tool["description"],
        "input_schema" => tool["parameter_schema"]
      }
    end)
  end

  @doc """
  ## Concept

  Prepare the native body and its final hook from the dependency-built request.

  ## Technical depth

  Authentication and routing remain dependency-owned and must match the captured
  endpoint and selected credential. Recompute an existing, initially correct
  content-length only for this renderer's own body change. No caller hook or
  arbitrary header bag participates in constructing the sealed request.
  """
  def install(request, built, endpoint, credential),
    do: install_native(request, built, endpoint, credential, true)

  @doc """
  ## Concept

  Install the same captured native request at the one-shot buffered boundary.

  ## Technical depth

  The caller has already validated Req's final transport controls. Only the body
  and an existing correct content-length may change here. Authentication and the
  complete header set are checked against the independently captured endpoint
  and credential; only this path admits identity accept-encoding.
  """
  def install_buffered(request, %Req.Request{} = built, endpoint, credential) do
    headers = for {name, values} <- built.headers, value <- values, do: {name, value}
    body = IO.iodata_to_binary(built.body)
    finch = Finch.build(built.method, URI.to_string(built.url), headers, body)

    with {:ok, installed, _guard} <-
           install_native(request, finch, endpoint, credential, false) do
      headers =
        Map.new(installed.headers, fn {name, value} -> {String.downcase(name), [value]} end)

      {:ok, %{built | body: installed.body, headers: headers}}
    end
  rescue
    _ -> @invalid
  end

  def install_buffered(_, _, _, _), do: @invalid

  @doc """
  ## Concept

  Keep sealed native request bytes out of Finch's request telemetry.

  ## Technical depth

  Both transports retain the body in their invocation owner. The read callback
  captures only that owner's private handle and consumes the body once. Finch
  sees a body stream and the exact content-length, so the wire bytes and framing
  remain unchanged. This does not hide data from trusted host code executing in
  the transport process or confer authority on the callback.
  """
  def private_body(%Finch.Request{body: body} = request, read)
      when is_binary(body) and is_function(read, 0) do
    headers =
      Enum.reject(request.headers, fn {name, _} -> String.downcase(name) == "content-length" end)

    stream =
      Stream.resource(
        fn -> :ready end,
        fn
          :ready ->
            case read.() do
              bytes when is_binary(bytes) -> {[bytes], :done}
              _ -> raise "invalid native request body"
            end

          :done ->
            {:halt, :done}
        end,
        fn _ -> :ok end
      )

    %{
      request
      | headers: headers ++ [{"content-length", Integer.to_string(byte_size(body))}],
        body: {:stream, stream}
    }
  end

  defp install_native(
         request,
         %Finch.Request{body: body} = built,
         endpoint,
         credential,
         streaming
       )
       when is_binary(body) do
    with {:ok, decoded} <- Jason.decode(body),
         {:ok, native} <- render(request, decoded, streaming),
         encoded = Jason.encode!(native),
         {:ok, headers} <- resized_headers(built.headers, byte_size(body), byte_size(encoded)),
         expected = %{built | body: encoded, headers: headers},
         {:ok, guard} <- seal(expected, endpoint, credential, request.tools != [], streaming) do
      {:ok, expected, guard}
    else
      _ -> @invalid
    end
  end

  defp install_native(_, _, _, _, _), do: @invalid

  defp resized_headers(headers, before_size, after_size) when is_list(headers) do
    expected_length = Integer.to_string(before_size)

    Enum.reduce_while(headers, {:ok, []}, fn
      {name, value}, {:ok, acc} when is_binary(name) and is_binary(value) ->
        case String.downcase(name) do
          "content-length" when value == expected_length ->
            {:cont, {:ok, [{name, Integer.to_string(after_size)} | acc]}}

          "content-length" ->
            {:halt, @invalid}

          _ ->
            {:cont, {:ok, [{name, value} | acc]}}
        end

      _, _ ->
        {:halt, @invalid}
    end)
    |> case do
      {:ok, headers} -> {:ok, Enum.reverse(headers)}
      error -> error
    end
  end

  defp resized_headers(_, _, _), do: @invalid

  @doc """
  ## Concept

  Seal an authenticated request before the dependency's mutation hooks run.

  ## Technical depth

  The invocation installs the returned function as its final on_finch_request
  hook. It compares the complete Finch request, including transport/private
  controls, after the global hook. Refusal returns one literal instead of raising
  an exception whose inspected arguments could disclose headers or body. The
  endpoint is the independently captured route, not read back from this request.
  """
  def guard(expected, endpoint, credential, tools?),
    do: seal(expected, endpoint, credential, tools?, true)

  defp seal(%Finch.Request{} = expected, %URI{} = endpoint, credential, tools?, streaming)
       when is_binary(credential) and is_boolean(tools?) do
    with true <- expected.method == "POST" and is_binary(expected.body),
         true <- expected.scheme in [:http, :https],
         true <- Atom.to_string(expected.scheme) == endpoint.scheme,
         true <- expected.host == endpoint.host and expected.port == endpoint.port,
         true <- expected.path == endpoint.path and expected.query == endpoint.query,
         true <- is_nil(expected.unix_socket),
         :ok <- headers(expected, endpoint, credential, tools?, streaming) do
      {:ok, fn candidate -> if candidate == expected, do: candidate, else: @invalid end}
    else
      _ -> @invalid
    end
  end

  defp seal(_, _, _, _, _), do: @invalid

  defp headers(request, endpoint, credential, tools?, streaming) do
    allowed =
      ~w(accept content-type content-length host user-agent connection authorization x-api-key anthropic-version anthropic-beta) ++
        if(streaming, do: [], else: ["accept-encoding"])

    with true <- is_list(request.headers),
         true <-
           Enum.all?(request.headers, fn
             {name, value} when is_binary(name) and is_binary(value) ->
               String.downcase(name) in allowed and String.valid?(value) and
                 not String.contains?(value, ["\r", "\n", <<0>>])

             _ ->
               false
           end),
         pairs = Enum.map(request.headers, fn {name, value} -> {String.downcase(name), value} end),
         headers = Map.new(pairs),
         true <- map_size(headers) == length(pairs),
         true <-
           headers["accept"] == if(streaming, do: "text/event-stream", else: "application/json"),
         true <- headers["accept-encoding"] in [nil, "identity"],
         true <- headers["content-type"] == "application/json",
         true <- headers["anthropic-version"] == "2023-06-01",
         true <- headers["content-length"] in [nil, Integer.to_string(byte_size(request.body))],
         true <- headers["host"] in [nil, endpoint.authority],
         true <- headers["connection"] in [nil, "close", "keep-alive"],
         true <-
           is_nil(headers["anthropic-beta"]) or
             (tools? and headers["anthropic-beta"] == "tools-2024-05-16"),
         true <-
           (headers["x-api-key"] == credential and is_nil(headers["authorization"])) or
             (headers["authorization"] == "Bearer " <> credential and is_nil(headers["x-api-key"])) do
      :ok
    else
      _ -> @invalid
    end
  end

  defp thinking(@haiku, "default"), do: {:ok, %{"mode" => "omitted"}, false, false}
  defp thinking(@haiku, "none"), do: {:ok, %{"mode" => "disabled"}, false, false}

  defp thinking(@haiku, level) when level in ~w(low medium high),
    do:
      {:ok,
       %{
         "mode" => "manual",
         "budget_tokens" => %{"low" => 1_024, "medium" => 2_048, "high" => 4_096}[level]
       }, true, true}

  defp thinking(@fable, "default"), do: {:ok, %{"mode" => "omitted"}, true, false}

  defp thinking(@fable, level) when level in ~w(low medium high),
    do: {:ok, %{"mode" => "adaptive", "effort" => level, "display" => "summarized"}, true, true}

  defp thinking(_, _), do: @invalid

  defp controls(body, %{"mode" => "omitted"}), do: body

  defp controls(body, %{"mode" => "disabled"}),
    do: Map.put(body, "thinking", %{"type" => "disabled"})

  defp controls(body, %{"mode" => "manual", "budget_tokens" => budget}),
    do: Map.put(body, "thinking", %{"type" => "enabled", "budget_tokens" => budget})

  defp controls(body, %{"mode" => "adaptive", "effort" => effort, "display" => "summarized"}),
    do:
      body
      |> Map.put("thinking", %{"type" => "adaptive", "display" => "summarized"})
      |> Map.put("output_config", %{"effort" => effort})

  defp messages(request, expanded) do
    entries = (expanded && expanded["entries"]) || []
    replacements = Map.new(entries, &{&1["assistant_message_index"], &1})

    result_ids =
      Map.new(
        Enum.flat_map(entries, & &1["calls"]),
        &{&1["result_message_index"], &1["native_id"]}
      )

    names = Map.new(request.tools, &{ToolDefinition.generation(&1), &1["name"]})

    request.messages
    |> Enum.with_index()
    |> Enum.reduce_while(
      {:ok, [], [], MapSet.new(), MapSet.new()},
      fn {message, index}, {:ok, system, messages, calls, results} ->
        case message(message, replacements[index], result_ids[index], names, request.model) do
          {:system, text} when messages == [] ->
            {:cont, {:ok, [text | system], messages, calls, results}}

          {:message, native, new_calls, new_results} ->
            next_calls = MapSet.new(new_calls)
            next_results = MapSet.new(new_results)

            if MapSet.size(next_calls) == length(new_calls) and
                 MapSet.disjoint?(calls, next_calls) and
                 MapSet.subset?(next_results, calls) and MapSet.disjoint?(results, next_results) do
              {:cont,
               {:ok, system, [native | messages], MapSet.union(calls, next_calls),
                MapSet.union(results, next_results)}}
            else
              {:halt, @invalid}
            end

          _ ->
            {:halt, @invalid}
        end
      end
    )
    |> case do
      {:ok, system, messages, calls, calls} ->
        {:ok, Enum.reverse(system), group_results(Enum.reverse(messages))}

      _ ->
        @invalid
    end
  end

  defp group_results(messages) do
    messages
    |> Enum.reject(&(&1 == %{"role" => "assistant", "content" => []}))
    |> Enum.reduce([], fn
      %{"role" => "user", "content" => content} = message,
      [%{"role" => "user", "content" => previous} = prior | rest] = acc ->
        if Enum.any?(previous, &(&1["type"] == "tool_result")) do
          [%{prior | "content" => previous ++ content} | rest]
        else
          [message | acc]
        end

      message, acc ->
        [message | acc]
    end)
    |> Enum.reverse()
  end

  defp message(%{"role" => "system", "content" => text}, nil, nil, _, _) when is_binary(text),
    do: {:system, %{"type" => "text", "text" => text}}

  defp message(%{"role" => "user", "content" => text}, nil, nil, _, _) when is_binary(text),
    do:
      {:message, %{"role" => "user", "content" => [%{"type" => "text", "text" => text}]}, [], []}

  defp message(
         %{"role" => "tool", "content" => text, "tool_call_id" => canonical},
         nil,
         native_id,
         _,
         _
       )
       when is_binary(text) and is_binary(canonical) do
    id = native_id || canonical

    {:message,
     %{
       "role" => "user",
       "content" => [%{"type" => "tool_result", "tool_use_id" => id, "content" => text}]
     }, [], [id]}
  end

  defp message(
         %{"role" => "assistant", "content" => text} = message,
         replacement,
         nil,
         names,
         model
       )
       when is_binary(text) do
    with {:ok, calls} <- Mapping.canonical_calls(Map.get(message, "tool_calls", []), names),
         {:ok, content, ids} <- assistant(text, calls, replacement, model) do
      {:message, %{"role" => "assistant", "content" => content}, ids, []}
    end
  end

  defp message(_, _, _, _, _), do: @invalid

  defp assistant(text, calls, nil, _) do
    content = if text == "", do: [], else: [%{"type" => "text", "text" => text}]

    tools =
      Enum.map(
        calls,
        &%{"type" => "tool_use", "id" => &1.id, "name" => &1.name, "input" => &1.arguments}
      )

    {:ok, content ++ tools, Enum.map(calls, & &1.id)}
  end

  defp assistant(text, calls, entry, model) do
    native = entry["capsule"]["content"]
    expected = Enum.zip_with(calls, entry["calls"], &%{&1 | id: &2["native_id"]})

    with {:ok, captured} <- NativeContent.capture(model, "tool_use", native),
         true <- captured.text == text and captured.tool_calls == expected do
      {:ok, native, Enum.map(expected, & &1.id)}
    else
      _ -> @invalid
    end
  end
end
