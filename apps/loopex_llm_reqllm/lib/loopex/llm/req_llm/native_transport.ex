defmodule Loopex.LLM.ReqLLM.NativeTransport do
  @moduledoc """
  ## Concept

  Own one native Anthropic stream through the existing ReqLLM transport.

  ## Technical depth

  A private invocation process captures native bytes before dependency conversion.
  Only admitted progress enters the dependency queue. The caller monitors a
  separate drain and receives capture failures independently, cancelling the exact
  stream and joining that drain even when progress or enumeration is blocked.
  No provider registry, global hook or HTTP client is replaced.
  """
  use GenServer
  alias Loopex.LLM.ReqLLM.{Mapping, NativeRequest, NativeStream}
  alias Loopex.Model
  alias ReqLLM.Providers.Anthropic
  alias ReqLLM.StreamResponse.MetadataHandle

  @invalid {:error, :invalid_native_stream}
  @binding :loopex_native_invocation
  @options ~w(max_tokens tools total_timeout stream_idle_timeout receive_timeout max_retries base_url)a

  @doc """
  ## Concept

  Normalize a credential-free request before the transport handoff.

  ## Technical depth

  Preserve the pinned generation entry's model, provider-option, context and file
  validation. Resolve and retain the route once; the request builder and final
  hook must agree with it. Caller hooks, fixture capture and extra options refuse.
  """
  def prepare(request, context, options) do
    with :ok <- Model.validate_request(request),
         {:ok, profile} <- NativeRequest.profile(request),
         true <- Enum.all?(Keyword.keys(options), &(&1 in @options)),
         false <- Code.ensure_loaded?(ReqLLM.Test.Fixtures),
         "anthropic:" <> id <- request.model,
         {:ok, model} <- ReqLLM.model(%{provider: :anthropic, id: id}),
         {:ok, Anthropic} <- ReqLLM.provider(:anthropic),
         {:ok, options} <-
           ReqLLM.Provider.Options.normalize_namespaced_provider_options(
             Anthropic,
             :chat,
             model,
             options
           ),
         {:ok, context} <- ReqLLM.Context.normalize(context, options),
         :ok <- ReqLLM.ProviderFileReference.validate_context(context, :anthropic) do
      base = ReqLLM.Provider.Options.effective_base_url(Anthropic, model, options)
      endpoint = URI.parse(base <> "/v1/messages")
      options = Keyword.put(options, :base_url, base)

      {:ok,
       %{
         model: model,
         context: context,
         options: options,
         endpoint: endpoint,
         request: request,
         profile: profile
       }}
    else
      _ -> @invalid
    end
  end

  @doc """
  ## Concept

  Capture a complete native response while delivering validated transient progress.

  ## Technical depth

  Entering this function is the dispatch handoff. Every failure is a fixed error;
  callers must classify it as dispatched or unknown. The returned native content
  is invocation-private and still requires final reply/capsule admission. Timers
  and retries remain with the coordinator; dependency payload telemetry is off.
  """
  def complete(prepared, credential, progress) do
    owner = self()
    tag = make_ref()
    {:ok, capture} = GenServer.start_link(__MODULE__, {prepared, credential, owner, tag})

    options =
      Keyword.merge(prepared.options,
        max_retries: 0,
        total_timeout: :infinity,
        stream_idle_timeout: :infinity,
        receive_timeout: :infinity,
        metadata_timeout: :infinity,
        loopex_native_invocation: capture,
        telemetry: [payloads: :none],
        on_finch_request: fn request -> GenServer.call(capture, {:guard, request}, :infinity) end
      )

    try do
      case ReqLLM.Streaming.start_stream(__MODULE__, prepared.model, prepared.context, options) do
        {:ok, response} -> own_drain(response, capture, tag, progress)
        error -> failure("handoff", Mapping.returned_class(error))
      end
    rescue
      error -> failure("handoff", Mapping.raised_class(error))
    catch
      kind, reason -> failure("handoff", caught_class(kind, reason))
    after
      cleanup_stream(capture)
      if Process.alive?(capture), do: GenServer.stop(capture, :normal, :infinity)

      receive do
        {:native_failure, ^tag} -> :ok
      after
        0 -> :ok
      end
    end
  end

  # Concept: capture failure can stop a consumer blocked in enumeration or progress.
  # Technical depth: the owner receives a private invocation tag independently of
  # the drain. Cleanup monitors the exact drain before killing it and waits for
  # DOWN; observing the result message alone would not prove process cessation.
  defp own_drain(response, capture, tag, progress) do
    parent = self()

    {drain, monitor} =
      :erlang.spawn_opt(
        fn ->
          result =
            try do
              count =
                Enum.reduce(response.stream, 0, fn chunk, count ->
                  case chunk.metadata do
                    %{loopex_delta: delta} ->
                      progress.(delta)
                      count + 1

                    _ ->
                      count
                  end
                end)

              metadata =
                try do
                  {:ok, MetadataHandle.await(response.metadata_handle)}
                rescue
                  error -> failure("metadata", Mapping.raised_class(error))
                catch
                  kind, reason -> failure("metadata", caught_class(kind, reason))
                end

              case metadata do
                {:ok, metadata} -> {:ok, count, metadata}
                error -> error
              end
            rescue
              error -> failure("stream", Mapping.raised_class(error))
            catch
              kind, reason -> failure("stream", caught_class(kind, reason))
            end

          send(parent, {tag, self(), result})
        end,
        [:link, :monitor]
      )

    try do
      receive do
        {:native_failure, ^tag} ->
          failure("stream", "returned_error")

        {^tag, ^drain, {:ok, count, metadata}} ->
          case Mapping.completed(metadata) do
            :ok ->
              case GenServer.call(capture, :finish, :infinity) do
                {:ok, native} -> {:ok, %{native: native, metadata: metadata, delta_count: count}}
                _ -> failure("stream", "returned_error")
              end

            error ->
              failure("completion", Mapping.returned_class(error))
          end

        {^tag, ^drain, {:error, :invalid_native_stream, _} = error} ->
          error

        {:DOWN, ^monitor, :process, ^drain, _} ->
          failure("stream", "exited")
      end
    after
      cancel(response)
      joined = Process.monitor(drain)
      Process.unlink(drain)
      if Process.alive?(drain), do: Process.exit(drain, :kill)

      receive do
        {:DOWN, ^joined, :process, ^drain, _} -> :ok
      end

      Process.demonitor(monitor, [:flush])

      receive do
        {^tag, ^drain, _} -> :ok
      after
        0 -> :ok
      end
    end
  end

  defp failure(stage, class),
    do: {:error, :invalid_native_stream, Mapping.failure_pair(stage, class)}

  defp caught_class(:exit, {:timeout, {GenServer, :call, _}}), do: "genserver_timeout"
  defp caught_class(:exit, _), do: "exited"
  defp caught_class(:throw, _), do: "thrown"
  defp caught_class(_, _), do: "caught"

  defp cancel(response) do
    response.cancel.()
  catch
    _, _ -> :ok
  end

  defp cleanup_stream(capture) do
    case GenServer.call(capture, :server, :infinity) do
      nil ->
        :ok

      server ->
        monitor = Process.monitor(server)

        try do
          ReqLLM.StreamServer.cancel(server)
        catch
          _, _ -> :ok
        end

        receive do
          {:DOWN, ^monitor, :process, ^server, _} -> :ok
        end
    end
  end

  @doc false
  def stream_transport(_, _), do: :http
  @doc false
  def stream_protocol_parser(_model, options) do
    capture = Keyword.fetch!(options, @binding)
    fn bytes, parser -> GenServer.call(capture, {:parse, bytes, parser}, :infinity) end
  end

  @doc false
  def parse_stream_protocol(_, _), do: @invalid
  @doc false
  def init_stream_state(_model), do: nil
  @doc false
  def decode_stream_event(%{data: %{loopex_binding: capture}}, _, _), do: {[], capture}

  def decode_stream_event(%{data: %{loopex_delta: delta}}, _, capture),
    do: {[ReqLLM.StreamChunk.meta(%{loopex_delta: delta})], capture}

  def decode_stream_event(%{data: %{"type" => "message_stop"}}, _, capture),
    do: {[ReqLLM.StreamChunk.meta(%{finish_reason: :stop, terminal?: true})], capture}

  def decode_stream_event(_, _, capture) do
    if is_pid(capture), do: GenServer.call(capture, :fail, :infinity)
    {[], capture}
  end

  @doc false
  def flush_stream_state(_, capture) do
    if is_pid(capture), do: GenServer.call(capture, :flush, :infinity)
    {[], capture}
  end

  @doc false
  def attach_stream(model, context, options, finch) do
    capture = Keyword.fetch!(options, @binding)

    GenServer.call(
      capture,
      {:attach, model, context, Keyword.delete(options, @binding), finch},
      :infinity
    )
  end

  @impl true
  def init({prepared, credential, owner, tag}) do
    {:ok, profile} = NativeRequest.profile(prepared.request)
    prepared = %{prepared | profile: profile}

    {:ok,
     %{
       prepared: prepared,
       credential: credential,
       owner: owner,
       tag: tag,
       native: NativeStream.new(prepared.profile.response_model),
       parser: nil,
       guard: nil,
       body: nil,
       failed: false,
       flushed: false,
       tool_index: 0,
       current_call: nil,
       server: nil
     }}
  end

  @impl true
  def handle_call({:attach, model, context, options, finch}, {server, _}, state) do
    state = %{state | server: server}

    result =
      try do
        with nil <- state.guard,
             # Concept: provider validation sees only provider-supported options.
             # Technical depth: the pinned streaming layer consumes metadata_timeout,
             # but its Anthropic option schema does not accept that layer's timer.
             {:ok, built} <-
               Anthropic.attach_stream(
                 model,
                 context,
                 options
                 |> Keyword.delete(:metadata_timeout)
                 |> Keyword.put(:api_key, state.credential),
                 finch
               ),
             {:ok, expected, guard} <-
               NativeRequest.install(
                 state.prepared.request,
                 built,
                 state.prepared.endpoint,
                 state.credential
               ) do
          {:ok, expected, guard}
        else
          _ -> :invalid
        end
      rescue
        _ -> :invalid
      catch
        _, _ -> :invalid
      end

    case result do
      {:ok, expected, guard} -> {:reply, {:ok, expected}, %{state | guard: guard}}
      _ -> {:reply, {:error, :invalid_provider_request}, fail(state)}
    end
  end

  def handle_call(:server, _, state), do: {:reply, state.server, state}

  def handle_call({:guard, request}, _, %{guard: guard, failed: false} = state)
      when is_function(guard, 1) do
    case guard.(request) do
      %Finch.Request{} = accepted ->
        capture = self()
        tag = state.tag

        private =
          NativeRequest.private_body(
            accepted,
            fn -> GenServer.call(capture, {:body, tag}, :infinity) end
          )

        {:reply, private, %{state | body: accepted.body, guard: nil}}

      _ ->
        {:reply, {:error, :invalid_provider_request}, fail(state)}
    end
  end

  def handle_call({:guard, _}, _, state),
    do: {:reply, {:error, :invalid_provider_request}, fail(state)}

  def handle_call({:body, tag}, _, %{tag: tag, body: body, failed: false} = state)
      when is_binary(body), do: {:reply, body, %{state | body: nil}}

  def handle_call({:body, _}, _, state), do: {:reply, :invalid_native_body, fail(state)}

  def handle_call({:parse, bytes, parser}, _, %{failed: false} = state) do
    with true <- parser == state.parser,
         {:ok, native, events, next_parser} <- NativeStream.parse(state.native, bytes, parser),
         {:ok, projected, next} <- project(events, %{state | native: native, parser: next_parser}) do
      {:reply, {:ok, [%{data: %{loopex_binding: self()}} | projected], next_parser}, next}
    else
      _ -> {:reply, {:ok, [], ServerSentEvents.Parser.new()}, fail(state)}
    end
  end

  def handle_call({:parse, _, _}, _, state),
    do: {:reply, {:ok, [], ServerSentEvents.Parser.new()}, state}

  def handle_call(:flush, _, %{failed: false} = state) do
    case NativeStream.flush(state.native, state.parser) do
      {:ok, native} -> {:reply, :ok, %{state | native: native, flushed: true}}
      _ -> {:reply, @invalid, fail(state)}
    end
  end

  def handle_call(:finish, _, %{failed: false, flushed: true} = state),
    do: {:reply, NativeStream.finish(state.native), state}

  def handle_call(operation, _, state) when operation in [:fail, :finish, :flush],
    do: {:reply, @invalid, fail(state)}

  @impl true
  def format_status(status) do
    status
    |> Map.put(:state, :private_native_capture)
    |> Map.put(:message, :private_native_message)
    |> Map.put(:reason, :invalid_native_stream)
    |> Map.put(:log, [])
  end

  defp fail(%{failed: true} = state), do: state

  defp fail(state) do
    send(state.owner, {:native_failure, state.tag})
    %{state | failed: true, native: NativeStream.new(nil), parser: nil, guard: nil, body: nil}
  end

  # Concept: dependency queues receive only eligible bounded progress.
  # Technical depth: decoded native events exist only for this bounded HTTP batch;
  # signatures and private blocks never become dependency chunks or metadata.
  # The only terminal event is emitted after NativeStream accepts message_stop.
  defp project(events, state) do
    Enum.reduce_while(events, {:ok, [], state}, fn event, {:ok, output, state} ->
      {deltas, state} = deltas(event, state)

      if Enum.all?(deltas, &Model.valid_delta?/1) do
        projected = Enum.map(deltas, &%{data: %{loopex_delta: &1}})

        projected =
          if event["type"] == "message_stop",
            do: projected ++ [%{data: %{"type" => "message_stop"}}],
            else: projected

        {:cont, {:ok, Enum.reverse(projected) ++ output, state}}
      else
        {:halt, @invalid}
      end
    end)
    |> case do
      {:ok, output, state} -> {:ok, Enum.reverse(output), state}
      _ -> @invalid
    end
  end

  defp deltas(
         %{
           "type" => "content_block_start",
           "content_block" => %{"type" => "text", "text" => text}
         },
         state
       ),
       do: {text_deltas(:text_delta, text), state}

  defp deltas(
         %{
           "type" => "content_block_start",
           "content_block" => %{"type" => "tool_use", "id" => id, "name" => name}
         },
         state
       ) do
    delta = %{
      kind: :tool_call_delta,
      call_index: state.tool_index,
      tool_call_id: id,
      name: name,
      arguments_fragment: nil
    }

    {[delta], %{state | current_call: state.tool_index, tool_index: state.tool_index + 1}}
  end

  defp deltas(
         %{"type" => "content_block_delta", "delta" => %{"type" => "text_delta", "text" => text}},
         state
       ),
       do: {text_deltas(:text_delta, text), state}

  defp deltas(
         %{
           "type" => "content_block_delta",
           "delta" => %{"type" => "thinking_delta", "thinking" => text}
         },
         state
       ) do
    {if(state.prepared.profile.summary, do: text_deltas(:reasoning_delta, text), else: []), state}
  end

  defp deltas(
         %{
           "type" => "content_block_delta",
           "delta" => %{"type" => "input_json_delta", "partial_json" => text}
         },
         state
       ) do
    deltas =
      Enum.map(fragments(text), fn fragment ->
        %{
          kind: :tool_call_delta,
          call_index: state.current_call,
          tool_call_id: nil,
          name: nil,
          arguments_fragment: fragment
        }
      end)

    {deltas, state}
  end

  defp deltas(_, state), do: {[], state}

  defp text_deltas(kind, text),
    do: Enum.map(fragments(text), &%{kind: kind, content_index: 0, text: &1})

  defp fragments(""), do: []
  defp fragments(text) when byte_size(text) <= 60_000, do: [text]

  defp fragments(text) do
    size = utf8_prefix(text, 60_000)
    <<head::binary-size(^size), tail::binary>> = text
    [head | fragments(tail)]
  end

  defp utf8_prefix(text, size) do
    if String.valid?(binary_part(text, 0, size)), do: size, else: utf8_prefix(text, size - 1)
  end
end
