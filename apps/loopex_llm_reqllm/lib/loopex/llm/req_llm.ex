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
  """
  @type reply :: %{
          text: String.t(),
          identity: identity(),
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

  Completes one model call from either the canonical request boundary or the
  retained M0 prompt convenience form, returning normalized text and identity.

  ## Technical depth

  Canonical bytes and digest are validated before the credential is read or a
  provider is contacted. M1 supports one non-streaming user message. The M0
  convenience clause first constructs that same canonical request. Provider
  failures are returned as bounded strings with the credential substituted out.
  """
  @impl Loopex.Model
  @spec complete(String.t(), String.t()) ::
          {:ok, reply()}
          | {:error, {:credential_unset, String.t()}}
          | {:error, {:unresolved_model, String.t(), term()}}
          | {:error, {:provider_call_failed, String.t()}}
  def complete(model_spec, prompt) when is_binary(model_spec) and is_binary(prompt) do
    with {:ok, request} <-
           Model.request(model_spec, [%{"role" => "user", "content" => prompt}],
             max_tokens: @max_tokens
           ) do
      complete(request, [])
    end
  end

  @spec complete(Model.request(), keyword()) :: {:ok, reply()} | {:error, term()}
  def complete(request, options) when is_map(request) and is_list(options) do
    with :ok <- Model.validate_request(request),
         {:ok, prompt} <- user_text(request),
         {:ok, credential} <- credential(),
         {:ok, identity} <- identity(request.model),
         {:ok, tools} <- provider_tools(request.tools),
         {:ok, tool_choice} <- provider_tool_choice(request.tool_choice) do
      dispatch(request, prompt, credential, identity, tools, tool_choice)
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

  defp dispatch(request, prompt, credential, identity, tools, tool_choice) do
    options = [
      api_key: credential,
      max_tokens: request.max_tokens,
      tools: tools,
      tool_choice: tool_choice
    ]

    case ReqLLM.generate_text(request.model, prompt, options) do
      {:ok, response} ->
        {:ok,
         %{
           text: ReqLLM.Response.text(response),
           identity: identity,
           usage: usage(response),
           tool_calls: Enum.map(ReqLLM.Response.tool_calls(response), &ReqLLM.ToolCall.to_map/1),
           canonical_request_bytes: request.canonical_request_bytes,
           canonical_request_digest: request.canonical_request_digest
         }}

      {:error, error} ->
        {:error, {:provider_call_failed, scrub(error, credential)}}
    end
  end

  defp user_text(%{messages: [%{"role" => "user", "content" => content}]})
       when is_binary(content) and byte_size(content) > 0,
       do: {:ok, content}

  defp user_text(_request), do: {:error, :unsupported_model_request}

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
         "input_schema" => input_schema
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

  defp provider_tool_choice("auto"), do: {:ok, :auto}
  defp provider_tool_choice("none"), do: {:ok, :none}
  defp provider_tool_choice("required"), do: {:ok, :required}

  defp provider_tool_choice(%{"type" => "tool", "name" => name}) when is_binary(name),
    do: {:ok, %{type: "tool", name: name}}

  defp provider_tool_choice(_choice), do: {:error, :invalid_model_tool_choice}

  # Concept: usage crosses the boundary as two counts, not as a provider type.
  defp usage(response) do
    reported = ReqLLM.Response.usage(response) || %{}

    %{
      input_tokens: Map.get(reported, :input_tokens),
      output_tokens: Map.get(reported, :output_tokens)
    }
  end

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
