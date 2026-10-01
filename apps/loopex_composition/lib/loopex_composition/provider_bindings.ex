defmodule LoopexComposition.ProviderBindings do
  @moduledoc """
  ## Concept

  Validate explicit provider credential references before any environment read,
  deletion, custody or runtime startup. A valid reference says nothing about
  credential availability and grants no provider call.

  Resolve a declared session against those routes and the adapter's verified
  model mappings before any runtime starts. The returned core configuration
  retains instructions and limits, never credential references.

  ## Technical depth

  ADR 0048 admits one to sixteen binary-key routes from the adapter's compiled
  catalog. Each closed binding selects an environment name or an existing
  credential-free route. Operational names and prefixes refuse. This pure
  boundary preserves the authored bindings and derives sorted unique launch
  exclusions, including the legacy provider key. Shared environment slots are
  deduplicated for later custody loading; no name or value enters core data.
  """

  alias Loopex.LLM.ReqLLM.InProcess.Guards
  alias Loopex.LLM.ReqLLM.ModelCapabilities
  alias Loopex.Runtime.{MaintenanceConfiguration, SessionConfiguration}

  @doc """
  ## Concept

  Check a host-selected model against the composed adapter's model syntax.

  ## Technical depth

  This credential-free check admits only the compiled provider names and bounded
  literal model identifiers. It performs no catalog lookup or provider call and
  exposes no adapter implementation data to command parsers.
  """
  @spec valid_model?(term()) :: boolean()
  def valid_model?(model), do: match?({:ok, _}, Guards.model(model))

  @doc """
  ## Concept

  Resolve a host's declared session configuration against its explicit provider
  routes and the exact selected tool definitions, without acquiring credentials.

  ## Technical depth

  The declaration has SessionConfiguration.resolve/4's closed shape and already
  captured instructions. Validate every binding before catalog access, resolve
  the sole literal model alias, require its named route, and validate the exact
  reasoning mapping against the selected reply allowance. Core then admits the
  complete metadata, instruction/tool system cost and context/output ceilings.
  Only the plain resolved configuration is returned; credential references and
  route implementation state never enter it. History, genesis size and settled
  configuration admission remain the owning session's obligations.
  """
  @spec resolve_configuration(term(), term(), term()) ::
          {:ok, map()} | {:error, atom() | {atom(), binary()}}
  def resolve_configuration(declaration, bindings, definitions)
      when is_map(declaration) and not is_struct(declaration) do
    with {:ok, capabilities, mapping} <-
           resolve_selection(
             declaration["model"],
             declaration["reasoning"],
             declaration["max_tokens"],
             bindings
           ) do
      SessionConfiguration.resolve(
        Map.put(declaration, "model", capabilities["model"]),
        capabilities,
        mapping,
        definitions
      )
    end
  end

  def resolve_configuration(_, _, _), do: {:error, :invalid_session_configuration}

  @doc """
  ## Concept

  Resolve an explicitly selected summarizer without inheriting the conversation
  model or reading a credential. Nil remains unconfigured.

  ## Technical depth

  The selected route must exist in the validated binding map. Its registered
  none mapping must disable thinking, require no continuation and preserve the
  fixed 1,024-token reply allowance. Core validates the closed four-member map
  and capacity floors. Registered mappings have deterministic native completion
  conformance; unknown or default-only mappings cannot become summarizers.
  """
  @spec resolve_maintenance_model(term(), term()) :: {:ok, map() | nil} | {:error, term()}
  def resolve_maintenance_model(nil, bindings) do
    with {:ok, _} <- validate(bindings), do: {:ok, nil}
  end

  def resolve_maintenance_model(model, bindings) do
    with {:ok, capabilities, mapping} <- resolve_selection(model, "none", 1024, bindings),
         {:ok, resolved} <-
           MaintenanceConfiguration.validate_model(%{
             "model" => capabilities["model"],
             "reasoning" => "none",
             "model_capabilities" => capabilities,
             "provider_mapping" => mapping
           }),
         :ok <- MaintenanceConfiguration.eligible_model(resolved) do
      {:ok, resolved}
    else
      {:error, :invalid_model_mapping} -> {:error, :maintenance_reasoning_unsupported}
      {:error, _} = error -> error
    end
  end

  defp resolve_selection(model, level, max_tokens, bindings) do
    with {:ok, _validated} <- validate(bindings),
         {:ok, capabilities} <- ModelCapabilities.capture(model),
         [provider, _] <- String.split(capabilities["model"], ":", parts: 2),
         true <- Map.has_key?(bindings, provider),
         {:ok, mapping} <- ModelCapabilities.mapping(capabilities["model"], level, max_tokens) do
      {:ok, capabilities, mapping}
    else
      false -> {:error, :provider_route_unavailable}
      {:error, _} = error -> error
    end
  end

  @doc """
  ## Concept

  Validate every provider reference before host effects.

  ## Technical depth

  The adapter owns the shared closed grammar used at startup and dispatch.
  This host facade returns its validated bindings and sorted launch exclusions.
  """
  @spec validate(term()) :: {:ok, map()} | {:error, {atom(), binary()}}
  defdelegate validate(bindings), to: Loopex.LLM.ReqLLM.HostBindings

  @doc """
  ## Concept

  Check a credential slot without resolving its value.

  ## Technical depth

  Delegate to the same bounded syntax and operational exclusions as dispatch.
  """
  @spec valid_env_name?(term()) :: boolean()
  defdelegate valid_env_name?(name), to: Loopex.LLM.ReqLLM.HostBindings
end
