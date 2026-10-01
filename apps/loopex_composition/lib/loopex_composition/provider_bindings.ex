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

  @reserved ~w(PATH HOME TMPDIR TMP TEMP SHELL USER LOGNAME PWD OLDPWD SHLVL IFS CDPATH ENV BASH_ENV ZDOTDIR)
  @prefixes ~w(LD_ DYLD_ ERL_ ELIXIR_ MIX_ RELEASE_ BASH_ LOOPEX_)
  @legacy "LOOPEX_PROVIDER_API_KEY"
  @name ~r/\A[A-Za-z_][A-Za-z0-9_]{0,127}\z/

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

  Admit the complete route map without resolving any credential.

  ## Technical depth

  The returned host-only map contains original binary-key bindings and the
  exclusion set. Errors expose only a stable class and the provider field's
  JSON pointer, never a selected environment name or credential value.
  Credential-free bindings are valid only where the compiled adapter admits
  that profile; durable constructors must separately refuse them.
  """
  @spec validate(term()) :: {:ok, map()} | {:error, {atom(), binary()}}
  def validate(bindings) when is_map(bindings) and map_size(bindings) in 1..16 do
    catalog = Guards.binding_catalog()

    result =
      bindings
      |> Enum.sort_by(fn {key, _} -> key end)
      |> Enum.reduce_while({:ok, [@legacy]}, fn {provider, binding}, {:ok, names} ->
        case validate_route(provider, binding, catalog) do
          {:ok, nil} -> {:cont, {:ok, names}}
          {:ok, name} -> {:cont, {:ok, [name | names]}}
          {:error, _} = error -> {:halt, error}
        end
      end)

    case result do
      {:ok, names} ->
        {:ok, %{bindings: bindings, excluded_env_names: names |> Enum.uniq() |> Enum.sort()}}

      {:error, _} = error ->
        error
    end
  end

  def validate(_), do: {:error, {:invalid_provider_bindings, "/providers"}}

  @doc """
  ## Concept

  Check a credential slot's syntax and operational exclusions without reading it.

  ## Technical depth

  Names use at most 128 ASCII bytes. The sole operational-prefix exception is
  the released legacy provider key; validation is case-sensitive like the host
  environment. No case conversion or substitution occurs.
  """
  @spec valid_env_name?(term()) :: boolean()
  def valid_env_name?(name) when is_binary(name) and byte_size(name) in 1..128 do
    String.valid?(name) and Regex.match?(@name, name) and name not in @reserved and
      (name == @legacy or not Enum.any?(@prefixes, &String.starts_with?(name, &1)))
  end

  def valid_env_name?(_), do: false

  defp validate_route(provider, binding, catalog) when is_binary(provider) do
    case Map.fetch(catalog, provider) do
      {:ok, profile} -> validate_binding(binding, profile, "/providers/" <> provider)
      :error -> {:error, {:unsupported_provider, "/providers"}}
    end
  end

  defp validate_route(_, _, _), do: {:error, {:invalid_provider_bindings, "/providers"}}

  defp validate_binding(%{"credential" => credential} = binding, profile, pointer)
       when map_size(binding) == 1 do
    case credential do
      %{"env" => name} when map_size(credential) == 1 ->
        if valid_env_name?(name),
          do: {:ok, name},
          else: {:error, {:invalid_credential_reference, pointer <> "/credential/env"}}

      %{"none" => true} when map_size(credential) == 1 ->
        if profile.credential_required,
          do: {:error, {:credential_required, pointer <> "/credential"}},
          else: {:ok, nil}

      _ ->
        {:error, {:invalid_credential_binding, pointer <> "/credential"}}
    end
  end

  defp validate_binding(_, _, pointer),
    do: {:error, {:invalid_credential_binding, pointer}}
end
