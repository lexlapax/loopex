defmodule Loopex.LLM.ReqLLM do
  @moduledoc """
  ## Concept

  The reference model adapter. It maps one canonical model request onto ReqLLM
  and maps the provider's answer back to plain data, which is the whole of
  outcome 7: proving a real model call completes *from the adapter application*
  rather than from core.

  Two directions are kept clean. Nothing about Loopex sessions, operations,
  durability, or policy appears here — the caller passes a model identity and a
  prompt and receives text, identity, and usage. Nothing about ReqLLM, Req,
  Finch, or a provider's wire format leaves this module: `ReqLLM` structs are
  read here and never returned, so a host or a later core boundary sees only
  bounded serializable maps and strings.

  The credential arrives only from the `LOOPEX_PROVIDER_API_KEY` environment
  variable, is handed to ReqLLM as a per-request option, and is never returned,
  logged, or written anywhere. No other provider variable is consulted, so a key
  that happens to sit in the operator's environment cannot be spent by this lane
  by accident.

  ## Technical depth

  `ReqLLM` here is the top-level library module `Elixir.ReqLLM`; Elixir resolves
  aliases from the root, so the trailing segment of this module's own name does
  not shadow it.

  The credential is passed as `api_key:` on the call rather than through
  `ReqLLM.put_key/2` or ReqLLM's own environment lookup. A per-request option is
  scoped to the one request, leaves no value in application environment for
  another process to read, and — because ReqLLM's key resolution prefers the
  explicit option — removes any path by which a differently named provider
  variable already present in the environment could satisfy the call instead.

  Model identity is resolved through `ReqLLM.model/1`, which reads the bundled
  LLMDB catalog with no network access and no credential. That resolution is
  therefore usable as an ordinary untagged test: it proves the pinned reference
  model spec still names a real catalog entry without spending a token. The
  endpoint recorded is the catalog's base URL when it carries one and the
  provider module's default otherwise, which is an endpoint *class* — a
  non-secret host, never a credentialed URL.

  Provider failures are reduced to a bounded, scrubbed string rather than passed
  through as a term. A provider error can carry request context, so the raw term
  is inspected with hard limits and the credential value is substituted out
  before it can reach a caller, a report, or an operator's terminal. The gate
  runner redacts its captured output as well; these are two independent planes
  and each needs its own containment.

  `complete/2` returns before any dispatch when the credential is absent, so a
  missing credential is a reported absence rather than a provider call with an
  empty key.
  """

  @behaviour Loopex.Model

  alias Loopex.Model

  @credential_variable "LOOPEX_PROVIDER_API_KEY"

  # Concept: the pinned reference model. A provider-neutral credential name
  # cannot say which provider it belongs to, so the lane names the model it
  # calls and the operator points the credential at that provider.
  #
  # Technical depth: an operator whose credential belongs elsewhere overrides
  # the spec at the call site rather than editing this constant, because
  # `complete/2` takes the spec as an argument.
  @default_model "anthropic:claude-haiku-4-5"

  # Concept: one short answer is all the outcome needs; a ceiling keeps the
  # evidence run cheap and bounded.
  @max_tokens 64

  @unknown_endpoint "unknown"
  @redacted "[redacted credential]"

  @typedoc """
  ## Concept

  The non-secret identity of a model call, retained so a reviewer can judge what
  was actually called.

  ## Technical depth

  Plain strings only. `endpoint` is an endpoint class — a host, never a URL
  carrying a credential or a tenant identifier.
  """
  @type identity :: %{provider: String.t(), model: String.t(), endpoint: String.t()}

  @typedoc """
  ## Concept

  What one completed model call yields: the assistant text, the identity that
  produced it, and the provider's reported token usage.

  ## Technical depth

  Bounded serializable data. Usage is reduced to two integer counts, or `nil`
  where the provider reported none, so no provider struct crosses the boundary.

  `provider_response_id` is the provider's own identifier for the response, taken
  from the `request-id` header the provider returns per call. It is the one field
  in a reply that a deterministic adapter cannot invent, because it exists in the
  provider's account and can be looked up there. That is what makes it the anchor
  of the milestone's real-call evidence, and it is `nil` wherever the provider
  supplied none rather than being filled in with a plausible value.

  A streamed call cannot carry the provider's assembled *message* identifier: the
  library keeps only usage from the provider's opening event and discards the
  rest. The per-call request identifier survives streaming and is the identifier
  the provider's own account and support surface use, so it is the one retained.
  """
  @type reply :: %{
          text: String.t(),
          identity: identity(),
          provider_response_id: String.t() | nil,
          usage: %{input_tokens: non_neg_integer() | nil, output_tokens: non_neg_integer() | nil},
          tool_calls: [map()],
          canonical_request_bytes: binary(),
          canonical_request_digest: binary()
        }

  @doc """
  ## Concept

  The environment variable this adapter reads the provider credential from, and
  the only one it will read.

  ## Technical depth

  Exposed so the real-provider lane can name it in its own failure message
  without restating the string and drifting from the value actually read.
  """
  @spec credential_variable() :: String.t()
  def credential_variable, do: @credential_variable

  @doc """
  ## Concept

  The pinned reference model specification the real-provider lane calls.

  ## Technical depth

  A `provider:model` specification ReqLLM resolves through its bundled catalog.
  """
  @spec default_model() :: String.t()
  def default_model, do: @default_model

  @doc """
  ## Concept

  Resolves a model specification to the non-secret identity a call against it
  would carry.

  ## Technical depth

  Needs no credential and makes no network request, so the lane can record what
  it is about to call — and an ordinary test can prove the pinned spec still
  resolves — without spending a token. An unresolvable specification is an
  error, never a guessed identity.
  """
  @spec identity(String.t()) ::
          {:ok, identity()} | {:error, {:unresolved_model, String.t(), term()}}
  def identity(model_spec) when is_binary(model_spec) do
    case ReqLLM.model(model_spec) do
      {:ok, model} ->
        {:ok,
         %{
           provider: to_string(model.provider),
           model: to_string(model.id),
           endpoint: endpoint(model)
         }}

      {:error, reason} ->
        {:error, {:unresolved_model, model_spec, reason}}
    end
  end

  @doc """
  ## Concept

  Builds and dispatches one request from a bare model name and prompt.

  ## Technical depth

  A convenience for callers that hold no committed request, used by the
  credential-free adapter lane. It declares its own sampling bound explicitly,
  because there is no default anywhere and a request without one is refused.
  """
  @spec complete(String.t(), String.t()) ::
          {:ok, reply()}
          | {:error, {:credential_unset, String.t()}}
          | {:error, {:unresolved_model, String.t(), term()}}
          | {:error, {:provider_call_failed, String.t()}}
  def complete(model_spec, prompt) when is_binary(model_spec) and is_binary(prompt) do
    with {:ok, request} <-
           Model.request(model_spec, [%{"role" => "user", "content" => prompt}],
             sampling: %{"max_tokens" => @max_tokens},
             deadline: System.system_time(:millisecond) + 60_000
           ) do
      complete(request, [], Model.discard_progress())
    end
  end

  @doc """
  ## Concept

  Dispatches exactly the committed request and returns one complete reply.

  ## Technical depth

  This adapter streams. Every chunk the provider sends is emitted through
  `progress` as it arrives and accumulated at the same time, so the reply this
  returns is assembled from exactly the chunks the deltas carried and replays
  them byte for byte. `delta_count` is what was emitted and `streamed` is true,
  so the coordinator closes that attempt's domain with a truthful count.

  The stream is consumed once. Usage and the per-call request identifier come
  from the metadata the provider sends after the content, so they are read once
  the stream is drained rather than beside it.
  """
  @impl Loopex.Model
  @spec complete(Model.request(), keyword(), Model.progress_fun()) ::
          {:ok, reply()} | {:error, term()}
  def complete(request, options, progress)
      when is_map(request) and is_list(options) and is_function(progress, 1) do
    with :ok <- Model.validate_request(request),
         {:ok, context} <- context_of(request),
         {:ok, credential} <- credential(),
         {:ok, identity} <- identity(request.model),
         {:ok, tools} <- provider_tools(Model.model_facing_tools(request)) do
      dispatch(request, context, credential, identity, tools, progress)
    end
  end

  # Concept: the credential is read here and nowhere else, and an absent or
  # empty value is an absence rather than a call with a blank key.
  defp credential do
    case System.get_env(@credential_variable) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _absent -> {:error, {:credential_unset, @credential_variable}}
    end
  end

  # Concept: the answer reaches the operator as the provider produces it.
  #
  # Technical depth: this adapter used to call the non-streaming form and declare
  # `streamed: false` with no deltas, which the port admits as conformant. It was
  # conformant and it was also the reason nothing an operator ran ever streamed,
  # while the runtime, the stream domains, their closure items and the terminal
  # all carried the path.
  #
  # The stream is consumed exactly once. Every chunk is emitted through the
  # progress function the coordinator supplied — closed over that attempt's
  # stream domain — and accumulated at the same time, so the reply this returns
  # is assembled from the same chunks the deltas carried and replays them byte
  # for byte. Usage and the provider's response identifier come from the metadata
  # the provider sends after the content, which is why they are read once the
  # stream is drained rather than beside it.
  defp dispatch(request, context, credential, identity, tools, progress) do
    options = [
      api_key: credential,
      max_tokens: Model.max_tokens(request),
      tools: tools
    ]

    case ReqLLM.stream_text(request.model, context, options) do
      {:ok, response} ->
        {:ok, drain(response, request, identity, progress)}

      {:error, error} ->
        {:error, {:provider_call_failed, scrub(error, credential)}}
    end
  end

  defp drain(response, request, identity, progress) do
    {chunks, text, deltas} =
      Enum.reduce(response.stream, {[], [], 0}, fn chunk, {chunks, text, deltas} ->
        case emit(chunk, deltas, progress) do
          {:text, fragment} -> {[chunk | chunks], [fragment | text], deltas + 1}
          {:counted, _kind} -> {[chunk | chunks], text, deltas + 1}
          :ignored -> {[chunk | chunks], text, deltas}
        end
      end)

    chunks = Enum.reverse(chunks)
    metadata = ReqLLM.StreamResponse.MetadataHandle.await(response.metadata_handle)
    reported = Map.get(metadata, :usage) || %{}
    streamed_text = text |> Enum.reverse() |> IO.iodata_to_binary()
    assembled = assemble(response, chunks, metadata)

    %{
      text: if(streamed_text == "", do: assembled_text(assembled), else: streamed_text),
      identity: identity,
      provider_response_id: provider_request_id(metadata),
      usage: %{
        input_tokens: Map.get(reported, :input_tokens),
        output_tokens: Map.get(reported, :output_tokens)
      },
      tool_calls: assembled_calls(assembled),
      delta_count: deltas,
      streamed: deltas > 0,
      canonical_request_bytes: request.canonical_request_bytes,
      staged_request_digest: request.staged_request_digest
    }
  end

  # Concept: the turn's tool calls come from the provider, assembled.
  #
  # Technical depth: a streaming `tool_call` chunk carries the name and an empty
  # argument map, because the provider sends the arguments as incremental JSON
  # after it and the chunk is emitted before they arrive. Reading the chunk alone
  # gives a call with no arguments, which the runtime refuses and which made a
  # coding agent that could name a tool and never use one.
  #
  # The provider's own response builder assembles the same chunks into a complete
  # response -- with the provider's tool-call identifiers and its arguments -- so
  # the chunks are collected as they stream and handed to it afterwards. This is
  # what `StreamResponse.to_response/1` does, minus re-consuming a stream that
  # has already been drained once and cannot be drained twice.
  defp assemble(response, chunks, metadata) do
    builder = ReqLLM.Provider.ResponseBuilder.for_model(response.model)

    case builder.build_response(chunks, metadata,
           context: response.context,
           model: response.model
         ) do
      {:ok, assembled} -> assembled
      _other -> nil
    end
  rescue
    _unavailable -> nil
  end

  defp assembled_text(nil), do: ""
  defp assembled_text(assembled), do: ReqLLM.Response.text(assembled) || ""

  defp assembled_calls(nil), do: []

  defp assembled_calls(assembled) do
    assembled
    |> ReqLLM.Response.tool_calls()
    |> Enum.map(&ReqLLM.ToolCall.to_map/1)
  end

  # Concept: one provider chunk becomes at most one delta of a declared kind.
  #
  # Technical depth: the port names three kinds and an item of any other shape is
  # not a delta, so a metadata chunk is counted by nothing and emitted as
  # nothing. `content_index` is zero because this adapter produces one content
  # part per attempt; a provider that interleaved several would need it to say
  # which, and this one does not.
  defp emit(%{type: :content, text: fragment}, index, progress)
       when is_binary(fragment) and fragment != "" do
    progress.(%{kind: :text_delta, content_index: 0, sequence: index, text: fragment})
    {:text, fragment}
  end

  defp emit(%{type: :thinking, text: fragment}, index, progress)
       when is_binary(fragment) and fragment != "" do
    progress.(%{kind: :reasoning_delta, content_index: 0, sequence: index, text: fragment})
    {:counted, :reasoning_delta}
  end

  defp emit(%{type: :tool_call, name: name}, index, progress) when is_binary(name) do
    progress.(%{
      kind: :tool_call_delta,
      content_index: 0,
      sequence: index,
      arguments_fragment: ""
    })

    {:counted, :tool_call_delta}
  end

  defp emit(_chunk, _index, _progress), do: :ignored

  # Concept: the identifier this call is known by in the provider's account.
  #
  # Technical depth: a streamed call cannot carry the assembled message
  # identifier, because the library keeps only usage from the provider's
  # `message_start` event and discards the rest. What survives is the response's
  # own `request-id` header, which the provider issues per call and which is the
  # identifier its account and its support surface use -- so it is the one an
  # auditor looks a retained claim up by, and the attestation declares its form.
  #
  # A provider that returns no such header yields `nil` rather than a
  # manufactured substitute, and an evidence claim built from replies carrying
  # none is refused rather than recorded.
  defp provider_request_id(metadata) do
    metadata
    |> Map.get(:headers, [])
    |> header("request-id")
  end

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

  # Concept: render the whole committed conversation, not the last thing said.
  #
  # Technical depth: core stages the full history — the operator's prompt, the
  # model's own prior assistant messages with their tool calls, and the real
  # result of each call — and this adapter must carry all of it to the provider.
  # An earlier version sent only the most recent user message. Every test passed,
  # because fixtures read `request.messages` directly, and the real path was
  # nonetheless broken: the model saw its original instruction again on every
  # turn, never learned it had already done the work, and called the same tool
  # until the run hit its turn bound. A history the kernel commits and the edge
  # discards is not a history.
  #
  # Roles map onto the provider's own shapes rather than being flattened into
  # prose. A tool result rendered as text would read to the model as something
  # the operator said, which is exactly the confusion the role exists to prevent.
  defp context_of(%{messages: messages}) when is_list(messages) do
    case Enum.reduce_while(messages, {:ok, []}, &render_message/2) do
      {:ok, rendered} -> {:ok, ReqLLM.Context.new(Enum.reverse(rendered))}
      {:error, reason} -> {:error, reason}
    end
  end

  defp context_of(_request), do: {:error, :unsupported_model_request}

  defp render_message(%{"role" => "system", "content" => content}, {:ok, acc})
       when is_binary(content),
       do: {:cont, {:ok, [ReqLLM.Context.system(content) | acc]}}

  defp render_message(%{"role" => "user", "content" => content}, {:ok, acc})
       when is_binary(content),
       do: {:cont, {:ok, [ReqLLM.Context.user(content) | acc]}}

  defp render_message(%{"role" => "assistant"} = message, {:ok, acc}) do
    text = Map.get(message, "content", "")

    case Map.get(message, "tool_calls", []) do
      [] ->
        {:cont, {:ok, [ReqLLM.Context.assistant(text) | acc]}}

      calls ->
        # The provider's encoder accepts a plain map with the arguments already
        # decoded, so nothing here has to encode JSON. That matters: the ADR 0002
        # floor has neither `:json` nor `JSON`, and adding an encoder to reach a
        # provider would be an external dependency this edge is not permitted.
        rendered =
          Enum.map(calls, fn call ->
            %{
              id: call["tool_call_id"],
              name: provider_name(call),
              arguments: call["arguments"] || %{}
            }
          end)

        parts = if text in [nil, ""], do: [], else: [ReqLLM.Message.ContentPart.text(text)]

        {:cont,
         {:ok, [%ReqLLM.Message{role: :assistant, content: parts, tool_calls: rendered} | acc]}}
    end
  end

  defp render_message(%{"role" => "tool"} = message, {:ok, acc}) do
    content = Map.get(message, "content", "")
    id = Map.get(message, "tool_call_id")
    {:cont, {:ok, [ReqLLM.Context.tool_result(id, content) | acc]}}
  end

  defp render_message(_unknown, {:ok, acc}), do: {:cont, {:ok, acc}}

  # Concept: the name the provider knows a call by.
  #
  # Technical depth: a committed call carries its generation triple, and the
  # provider knows the tool by its model-visible name. The staged request carries
  # the definitions, so the name is recovered from the call's own tool_id rather
  # than guessed; a blank name is what made a second call render as `· ()` in the
  # operator's terminal.
  defp provider_name(call) do
    case call do
      %{"name" => name} when is_binary(name) and name != "" ->
        name

      %{"tool_id" => tool_id} when is_binary(tool_id) ->
        tool_id |> String.split(".") |> List.last()

      _absent ->
        "unknown"
    end
  end

  defp provider_tools(tools) when is_list(tools) do
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

  # Concept: a provider error is bounded and stripped of the credential before
  # any caller, report, or terminal can see it.
  #
  # Technical depth: the limits cap an arbitrarily large error term, and the
  # substitution is unconditional rather than dependent on recognising which
  # field a provider chose to echo the key into.
  defp scrub(error, credential) do
    error
    |> inspect(limit: 8, printable_limit: 512)
    |> String.replace(credential, @redacted)
  end

  defp endpoint(%{base_url: url}) when is_binary(url) and url != "", do: url
  defp endpoint(%{provider: provider}), do: provider_default_endpoint(provider)

  defp provider_default_endpoint(provider) do
    case ReqLLM.provider(provider) do
      {:ok, module} -> default_base_url(module)
      _other -> @unknown_endpoint
    end
  end

  defp default_base_url(module) do
    case Code.ensure_loaded?(module) and function_exported?(module, :default_base_url, 0) do
      true -> module.default_base_url()
      false -> @unknown_endpoint
    end
  end
end
