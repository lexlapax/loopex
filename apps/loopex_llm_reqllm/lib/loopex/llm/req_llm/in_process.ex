defmodule Loopex.LLM.ReqLLM.InProcess do
  @moduledoc """
  ## Concept

  Run one ephemeral model request without reading its provider credential in the
  callback process.

  ## Technical depth

  This is the credential-free half of the in-VM model edge. It validates the
  committed request, fixed provider, host configuration, address, context and
  tool definitions. The private callback protocol obtains session admission,
  transfers cleanup custody, and gives input directly to the sensitive caller.
  """

  alias Loopex.LLM.ReqLLM.InProcess.{Guards, Route}
  alias Loopex.LLM.ReqLLM.Mapping
  alias Loopex.Model

  @failed {:error, {:not_dispatched, "model_call_failed"}}

  @behaviour Model

  @doc """
  ## Concept

  Complete one committed ephemeral model call under session-owned cleanup.

  ## Technical depth

  This callback never resolves the selected credential. Its private orchestrator
  obtains the start and registration proofs before authorizing the cleanup
  owner to create the caller and tagged pool.
  """
  @impl Model
  def complete(request, options, progress)
      when is_map(request) and is_list(options) and is_function(progress, 1),
      do: __MODULE__.Callback.complete(request, options)

  def complete(_request, _options, _progress), do: @failed

  @doc false
  def preflight(request, base_url, bindings \\ nil) do
    with :ok <- Model.validate_request(request),
         {:ok, model} <- Guards.model(request.model),
         {:ok, variable} <- credential_reference(request.model, model, bindings),
         :ok <- Guards.call(model.provider),
         :ok <- native_preflight(request, model.provider),
         {:ok, address} <- Route.base_url(model.provider, base_url),
         {:ok, context} <- Mapping.context_of(request),
         {:ok, tools} <- Mapping.provider_tools(Model.model_facing_tools(request)),
         {:ok, inline_model} <-
           ReqLLM.model(%{provider: model.provider, id: model.model_id, base_url: address}),
         {:ok, surface} <- probe_surface(model.provider, inline_model, request, tools, address) do
      {:ok,
       %{
         request: request,
         context: context,
         tools: tools,
         provider: model.provider,
         model_id: model.model_id,
         credential_variable: variable,
         base_url: address,
         surface: surface,
         identity: %{
           provider: Atom.to_string(model.provider),
           model: model.model_id,
           endpoint: address
         }
       }}
    else
      _refused -> @failed
    end
  rescue
    _error -> @failed
  catch
    _class, _reason -> @failed
  end

  defp credential_reference(_model, selected, nil), do: {:ok, selected.credential_variable}

  defp credential_reference(model, _selected, bindings),
    do: Loopex.LLM.ReqLLM.HostBindings.select(model, bindings)

  defp native_preflight(request, :anthropic) do
    with false <- Code.ensure_loaded?(ReqLLM.Test.Fixtures),
         {:ok, _} <- Loopex.LLM.ReqLLM.NativeRequest.profile(request) do
      :ok
    else
      _ -> @failed
    end
  end

  defp native_preflight(request, :openai) do
    case Loopex.LLM.ReqLLM.ModelCapabilities.verify_captured(request) do
      :ok -> :ok
      _ -> @failed
    end
  end

  defp native_preflight(_, _), do: :ok

  defp probe_surface(:ollama, _model, _request, _tools, _address),
    do: {:ok, :ollama_chat_completions}

  defp probe_surface(:openrouter, _model, _request, _tools, _address),
    do: {:ok, :openrouter_chat_completions}

  defp probe_surface(_provider, model, request, tools, address) do
    options = [
      max_tokens: Model.max_tokens(request),
      tools: tools,
      total_timeout: :infinity,
      receive_timeout: :infinity,
      max_retries: 0,
      base_url: address
    ]

    case ReqLLM.plan(model, :chat, options) do
      {:ok, %{surface: surface}}
      when surface in [:anthropic_messages, :openai_chat_completions, :openai_responses] ->
        {:ok, surface}

      _other ->
        @failed
    end
  end
end

defmodule Loopex.LLM.ReqLLM.InProcess.Caller do
  @moduledoc """
  ## Concept

  Keep a provider credential inside one sensitive, owner-controlled call process.

  ## Technical depth

  This is the sole sensitive MFA for the in-VM adapter. The owner must already
  have started and recorded the tagged pool before it sends the matching begin
  message. The caller reports a fixed result and native completion instant,
  then remains alive for owner-controlled teardown.
  """

  alias Loopex.LLM.ReqLLM.InProcess.{Guards, Route}
  alias Loopex.LLM.ReqLLM.Mapping
  alias Loopex.Model

  @not_dispatched {:error, {:not_dispatched, "model_call_failed"}}
  @unknown {:error, {:dispatched_or_unknown, "model_call_failed"}}
  @header_namespace Loopex.LLM.ReqLLM.InProcess

  @doc false
  def run(%{
        owner: owner,
        callback: callback,
        ref: ref,
        input_ref: input_ref,
        tag: tag,
        cell: cell,
        trace_capability: capability,
        pool_timeout: pool_timeout
      })
      when is_pid(owner) and is_pid(callback) and is_reference(ref) and
             is_reference(input_ref) and is_reference(tag) and
             is_integer(pool_timeout) and pool_timeout in 1..1_000 do
    Process.flag(:sensitive, true)
    Logger.put_process_level(self(), :none)
    owner_monitor = Process.monitor(owner)
    callback_monitor = Process.monitor(callback)
    send(owner, {:in_process_caller_ready, self(), ref})

    case await_input(owner, callback, ref, input_ref, owner_monitor, callback_monitor) do
      {:ok, prepared} ->
        result =
          try do
            with true <- :atomics.get(cell, 1) == 0,
                 :ok <- Guards.call(prepared.provider),
                 :ok <-
                   Loopex.Trace.exclude_self(capability,
                     functions: [{__MODULE__, :run, 1}]
                   ),
                 {:ok, fingerprint} <-
                   Route.fingerprint(
                     prepared.provider,
                     prepared.surface,
                     prepared.base_url
                   ),
                 {:ok, inline_model} <-
                   ReqLLM.model(%{
                     provider: prepared.provider,
                     id: prepared.model_id,
                     base_url: prepared.base_url
                   }) do
              http_options = [
                adapter: Loopex.LLM.ReqLLM.OneShotHTTP1,
                redirect: false,
                finch: [name: Req.Finch, pool_tag: tag, pool_timeout: pool_timeout],
                finch_private: %{loopex_one_shot: {owner, tag, fingerprint}}
              ]

              planning_options = [
                max_tokens: Model.max_tokens(prepared.request),
                tools: prepared.tools,
                total_timeout: :infinity,
                receive_timeout: :infinity,
                max_retries: 0,
                base_url: prepared.base_url,
                req_http_options: http_options
              ]

              planning_options =
                if prepared.provider == :anthropic,
                  do: Keyword.put(planning_options, :telemetry, payloads: :none),
                  else: planning_options

              planned =
                case prepared.provider do
                  :ollama ->
                    prepared.surface == :ollama_chat_completions

                  :openrouter ->
                    prepared.surface == :openrouter_chat_completions

                  _hosted ->
                    case ReqLLM.plan(inline_model, :chat, planning_options) do
                      {:ok, %{surface: surface}} -> surface == prepared.surface
                      _other -> false
                    end
                end

              if planned and :atomics.get(cell, 1) == 0 and
                   Guards.call(prepared.provider) == :ok do
                variable = prepared.credential_variable
                credential = if is_binary(variable), do: System.get_env(variable), else: nil

                if is_nil(variable) or
                     (is_binary(credential) and byte_size(credential) in 1..65_536) do
                  options =
                    if is_nil(variable),
                      do: planning_options,
                      else: [{:api_key, credential} | planning_options]

                  header_key = {@header_namespace, :response_headers, tag}
                  native_request_key = {@header_namespace, :native_request, tag}
                  native_response_key = {@header_namespace, :native_response, tag}
                  Process.delete(header_key)
                  Process.delete(native_response_key)

                  if prepared.provider == :anthropic do
                    Process.put(native_request_key, %{
                      request: prepared.request,
                      credential: credential
                    })
                  end

                  try do
                    case ReqLLM.generate_text(inline_model, prepared.context, options) do
                      {:ok, %ReqLLM.Response{} = response} ->
                        metadata = %{
                          usage: response.usage || %{},
                          finish_reason: response.finish_reason,
                          headers: Process.get(header_key, [])
                        }

                        metadata =
                          if is_nil(response.error),
                            do: metadata,
                            else: Map.put(metadata, :error, response.error)

                        with :ok <- Mapping.completed(metadata),
                             {:ok, reply} <- mapped_reply(prepared, response, metadata, tag) do
                          # Concept: a selected key echoed in provider-controlled
                          # reply data cannot be published. Host-supplied request
                          # identity and canonical bytes are not a provider echo.
                          # Technical depth: usage also needs scanning: the locked
                          # provider path can map a malformed string token count.
                          has_key = fn scan, value ->
                            cond do
                              is_nil(credential) ->
                                false

                              is_binary(value) ->
                                :binary.match(value, credential) != :nomatch

                              is_map(value) ->
                                Enum.any?(value, fn {key, member} ->
                                  scan.(scan, key) or scan.(scan, member)
                                end)

                              is_list(value) ->
                                Enum.any?(value, &scan.(scan, &1))

                              is_tuple(value) ->
                                value |> Tuple.to_list() |> Enum.any?(&scan.(scan, &1))

                              true ->
                                false
                            end
                          end

                          provider_fields =
                            Map.take(reply, [
                              :text,
                              :tool_calls,
                              :provider_response_id,
                              :usage,
                              :completion,
                              :continuation
                            ])

                          if has_key.(has_key, provider_fields),
                            do: @unknown,
                            else: {:ok, reply}
                        else
                          _invalid -> @unknown
                        end

                      _other ->
                        @unknown
                    end
                  rescue
                    _error -> @unknown
                  catch
                    _class, _reason -> @unknown
                  after
                    Process.delete(header_key)
                    Process.delete(native_request_key)
                    Process.delete(native_response_key)
                  end
                else
                  @not_dispatched
                end
              else
                @not_dispatched
              end
            else
              _refused -> @not_dispatched
            end
          rescue
            _error -> @not_dispatched
          catch
            _class, _reason -> @not_dispatched
          end

        send(owner, {self(), ref, result, System.monotonic_time(:native)})

        receive do
          {:DOWN, ^owner_monitor, :process, ^owner, _reason} -> :ok
        end

      :down ->
        :ok
    end
  end

  defp mapped_reply(%{provider: :anthropic} = prepared, _response, metadata, tag) do
    case Process.get({@header_namespace, :native_response, tag}) do
      %{
        text: text,
        tool_calls: calls,
        completion: completion,
        continuation: continuation,
        usage: usage
      } ->
        reply =
          Mapping.reply(
            prepared.request,
            prepared.identity,
            %{metadata | usage: usage},
            text,
            calls,
            0
          )

        {:ok, Map.merge(reply, %{completion: completion, continuation: continuation})}

      _ ->
        @unknown
    end
  end

  defp mapped_reply(prepared, response, metadata, _tag) do
    with {:ok, calls} <- Mapping.bounded_calls(response),
         text when is_binary(text) <- ReqLLM.Response.text(response) || "" do
      {:ok, Mapping.reply(prepared.request, prepared.identity, metadata, text, calls, 0)}
    end
  end

  defp await_input(owner, callback, ref, input_ref, owner_monitor, callback_monitor) do
    await_input(owner, callback, ref, input_ref, owner_monitor, callback_monitor, nil, false)
  end

  defp await_input(
         _owner,
         _callback,
         _ref,
         _input_ref,
         _owner_monitor,
         _callback_monitor,
         prepared,
         true
       )
       when is_map(prepared),
       do: {:ok, prepared}

  defp await_input(
         owner,
         callback,
         ref,
         input_ref,
         owner_monitor,
         callback_monitor,
         prepared,
         begun
       ) do
    receive do
      {:in_process_caller_input, ^callback, ^ref, ^input_ref, input}
      when is_map(input) and is_nil(prepared) ->
        await_input(
          owner,
          callback,
          ref,
          input_ref,
          owner_monitor,
          callback_monitor,
          input,
          begun
        )

      {:in_process_caller_begin, ^owner, ^ref, ^input_ref} when not begun ->
        await_input(
          owner,
          callback,
          ref,
          input_ref,
          owner_monitor,
          callback_monitor,
          prepared,
          true
        )

      {:DOWN, ^owner_monitor, :process, ^owner, _reason} ->
        :down

      {:DOWN, ^callback_monitor, :process, ^callback, _reason} ->
        :down
    end
  end
end
