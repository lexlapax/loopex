defmodule LoopexCli.ChatConfiguration do
  @moduledoc """
  ## Concept

  Prepare a new conversation from its explicit configuration file before the
  host consumes credentials or opens a runtime. Capture instructions and the
  selected tool generation together, so creation retains what was validated.

  ## Technical depth

  The existing file, flag, precedence and model resolvers own their respective
  validation. Core's shared genesis resolver measures the complete v3 payload.
  Credential references stay in the private selection and never enter genesis.
  Configured file reads are limited to the selected configuration and prompts;
  model resolution may load trusted packaged catalog metadata. This stage does
  no environment lookup, resource discovery, credential resolution or startup.
  Resume has a separate configuration preparation path using the capability
  holder's retained reads. New chat captures the physical workspace identity;
  resume requires that binding and checks every retained pending effect against
  it. The selected registry policy must match a retained policy question, and
  admitted model identities must have configured provider routes. These checks
  resolve no credential or catalog entry. Activation and enabled delegation
  remain outer-host integration obligations.
  """

  alias LoopexCli.{ConfigFile, ConfigOptions, ConfigSelection, SessionInstructions}
  alias LoopexComposition.DurableOptions
  alias Loopex.Runtime.SessionGenesis
  alias Loopex.Runtime.SessionConfiguration
  alias LoopexComposition.ProviderBindings
  alias LoopexComposition.WorkspaceIdentity
  alias LoopexProtocol.ToolDefinition

  @profiles %{
    "coding" => ~w(loopex.read loopex.write loopex.edit loopex.bash loopex.ask),
    "read-only" => ~w(loopex.read loopex.grep loopex.find loopex.ls loopex.ask),
    "none" => []
  }

  @doc """
  ## Concept

  Resolve one new chat invocation into its exact session creation input.

  ## Technical depth

  Cwd and the permitted LOOPEX_HOME value are supplied explicitly. Authored
  bounds remain mandatory even when flags override them. Both paths must be
  selected before instruction capture; neither directory is created here.
  Nonempty profiles opt into the fixed question definition. The exact selected
  definitions, including that question, contribute to instruction/system costs.
  Returned genesis is ready for the accepted exact-genesis creation operation;
  subsequent startup may not reconstruct it from changed files or defaults.
  """
  @spec load(term(), term(), term()) :: {:ok, map()} | {:error, term()}
  def load(argv, cwd, home) do
    with {:ok, %{command: :chat} = parsed} <- ConfigOptions.parse(argv),
         {:ok, file} <- ConfigFile.load(parsed.config, cwd),
         {:ok, selection} <- ConfigSelection.compose(file, parsed, cwd, home),
         :ok <- required_paths(selection.profile),
         :ok <- delegation(selection.profile),
         {:ok, workspace_ref} <-
           WorkspaceIdentity.reference(selection.profile["paths"]["workspace"]),
         session_options <- session_options(workspace_ref),
         active <- Map.fetch!(@profiles, selection.profile["session"]["tools"]),
         definitions <- selected_definitions(active),
         {:ok, instructions} <- capture_instructions(selection.profile),
         {:ok, selection} <- ConfigSelection.resolve_session(selection, instructions, definitions),
         {:ok, _} <-
           DurableOptions.resolve(
             model: selection.configuration["model"],
             provider_bindings: selection.profile["providers"],
             active_tools: active
           ),
         :ok <- workspace_binding(session_options, selection.profile["paths"]["workspace"], []),
         {:ok, genesis} <- genesis(selection, definitions, session_options) do
      {:ok,
       %{
         selection: selection,
         active_tools: active,
         session_options: session_options,
         genesis: genesis
       }}
    else
      {:ok, _other_command} -> {:error, :invalid_chat_invocation}
      {:error, _} = error -> error
    end
  end

  @doc """
  ## Concept

  Validate a resume invocation before acquiring credentials or a session owner.

  ## Technical depth

  The selected file must retain its required authored bounds. Composition here
  supplies paths, routes, new-run bounds and host-local options only; file
  session defaults are not a recovered configuration. This stage reads no
  instruction file, model catalog or credential. The caller subsequently
  acquires a prepared owner and presents this result to resume/2.
  """
  @spec load_resume(term(), term(), term()) :: {:ok, map()} | {:error, term()}
  def load_resume(argv, cwd, home) do
    with {:ok, %{command: :chat, resume: session} = parsed} when is_binary(session) <-
           ConfigOptions.parse(argv),
         {:ok, file} <- ConfigFile.load(parsed.config, cwd),
         {:ok, selection} <- ConfigSelection.compose(file, %{parsed | resume: nil}, cwd, home),
         :ok <- required_paths(selection.profile),
         {:ok, _} <- ProviderBindings.validate(selection.profile["providers"]) do
      {:ok, %{selection: selection, flags: parsed.overrides, resume_session_id: session}}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_chat_resume_invocation}
    end
  end

  @doc """
  ## Concept

  Prepare chat settings from an ordinary session's exact retained configuration.
  Refusal gives up the prepared owner before returning to the operator.

  ## Technical depth

  The calling process must hold the unspent activation. File defaults never
  replace retained model metadata, instructions, tools or cleanup grace. Only
  explicit flags are compared, and a matching model alias is resolved without
  replacing captured capabilities. Absent model flags consult no current model
  catalog. Explicit prompt flags read only those bounded selected sections;
  omitted prompt files are never reopened. New-run bounds and separately
  resolved maintenance selection stay invocation settings. The result spends
  no activation and dispatches no work. Retained policy questions must match
  the selected registry identity and revision. Every already-admitted model must
  retain its provider route, without re-resolving its captured model metadata.
  Outer startup rechecks physical placement, installs cancellation, then activates.
  Missing workspace binding refuses; no older-root migration or host-selected
  identity fallback is offered. Helper bindings remain separate integration work.
  Failed abandonment reports the original refusal and cleanup uncertainty.
  """
  @spec resume(term(), Loopex.ResumeActivation.t()) :: {:ok, map()} | {:error, term()}
  def resume(invocation, activation) do
    case resume_configuration(invocation, activation) do
      {:ok, _} = result ->
        result

      {:error, reason} ->
        case Loopex.abandon_resume(activation) do
          :ok ->
            {:error, reason}

          {:error, cleanup} ->
            {:error, {:resume_configuration_owner_unconfirmed, reason, cleanup}}
        end
    end
  end

  defp resume_configuration(
         %{selection: selection, flags: flags, resume_session_id: session},
         activation
       )
       when is_map(flags) and is_binary(session) do
    with {:ok, retained} <- Loopex.prepared_session_configuration(activation),
         {:ok, startup} <- Loopex.prepared_session_startup(activation),
         :ok <-
           workspace_binding(
             startup.session_options,
             selection.profile["paths"]["workspace"],
             startup.admitted_workspace_refs
           ),
         :ok <-
           pending_policy_binding(startup.pending_policy_identity, selection.profile["policy"]),
         :ok <- admitted_model_routes(startup.admitted_models, selection.profile["providers"]),
         %{"definitions" => definitions} <- retained.tool_selection,
         configuration when is_map(configuration) <- retained.configuration,
         :ok <- SessionConfiguration.validate(configuration, definitions),
         :ok <- resume_grace(flags, retained.cleanup_grace_ms),
         :ok <- resume_limits(flags, configuration),
         :ok <- resume_tools(flags, definitions),
         :ok <- resume_model(flags, configuration, definitions, selection.profile["providers"]),
         :ok <- resume_instructions(flags, selection.profile, configuration["instructions"]),
         {:ok, _} <-
           DurableOptions.resolve(
             model: configuration["model"],
             provider_bindings: selection.profile["providers"],
             active_tools: []
           ),
         {:ok, maintenance} <-
           ProviderBindings.resolve_maintenance_model(
             get_in(selection.profile, ["maintenance", "model"]),
             selection.profile["providers"]
           ) do
      origins =
        Enum.reduce(~w(model reasoning max_tokens context_token_budget system_class_tokens
                               instructions tools cleanup_grace_ms), selection.origins, fn key,
                                                                                           origins ->
          pointer = "/session/" <> key

          origins =
            Map.reject(origins, fn {name, _} ->
              name == pointer or String.starts_with?(name, pointer <> "/")
            end)

          Map.put(origins, pointer, "committed")
        end)

      ids = Enum.sort(Enum.map(definitions, & &1["tool_id"]))

      profile_name =
        Enum.find_value(@profiles, "retained", fn {name, tools} ->
          if Enum.sort(tools) == ids, do: name
        end)

      session_profile =
        selection.profile["session"]
        |> Map.drop(~w(instructions skill_dirs))
        |> Map.merge(
          Map.take(
            configuration,
            ~w(model reasoning max_tokens context_token_budget system_class_tokens)
          )
        )
        |> Map.put("cleanup_grace_ms", retained.cleanup_grace_ms)
        |> Map.put("tools", profile_name)

      profile =
        selection.profile
        |> Map.put("session", session_profile)
        |> Map.put("roles", %{})
        |> Map.put("delegation", %{"enabled" => false, "roles" => []})

      origins =
        origins
        |> Map.reject(fn {pointer, _} ->
          pointer in ["/roles", "/delegation"] or String.starts_with?(pointer, "/roles/") or
            String.starts_with?(pointer, "/delegation/") or
            pointer == "/session/skill_dirs" or
            String.starts_with?(pointer, "/session/skill_dirs/")
        end)
        |> Map.put("/roles", "committed")
        |> Map.put("/delegation/enabled", "committed")
        |> Map.put("/delegation/roles", "committed")

      {:ok,
       %{
         selection:
           selection
           |> Map.put(:profile, profile)
           |> Map.put(:configuration, configuration)
           |> Map.put(:maintenance_model, maintenance)
           |> Map.put(:origins, origins),
         retained: retained,
         startup: startup,
         resume_session_id: session,
         active_tools: Enum.map(definitions, & &1["tool_id"])
       }}
    else
      {:error, _} = error -> error
      _ -> {:error, :chat_resume_configuration_unavailable}
    end
  end

  defp resume_configuration(_, _), do: {:error, :invalid_chat_resume_invocation}

  # Concept: a pending policy question continues under the same host identity.
  # Technical depth: names select fixed trusted registry modules; they do not
  # invent identities or adopt a retained policy. With no policy interaction,
  # a newly selected policy remains the host's choice for subsequent work.
  defp pending_policy_binding(nil, _policy), do: :ok

  defp pending_policy_binding(retained, policy) do
    case Map.fetch(LoopexCli.AskOptions.policy_profiles(), policy) do
      {:ok, module} ->
        if retained == %{"id" => inspect(module), "revision" => "0.2.0"},
          do: :ok,
          else: {:error, :chat_pending_policy_binding_conflict}

      :error ->
        {:error, :chat_pending_policy_binding_conflict}
    end
  end

  # Concept: recovery cannot lose a route needed by work already admitted.
  # Technical depth: compare only the provider prefix of each retained exact
  # model identity. No catalog, current alias, capability or credential lookup
  # may replace the captured model or grant permission to dispatch it.
  defp admitted_model_routes(models, bindings) do
    with {:ok, _} <- ProviderBindings.validate(bindings),
         true <- Enum.all?(models, &admitted_model_route?(&1, bindings)) do
      :ok
    else
      _ -> {:error, :provider_route_unavailable}
    end
  end

  defp admitted_model_route?(model, bindings) when is_binary(model) do
    case String.split(model, ":", parts: 2) do
      [provider, name] when byte_size(provider) > 0 and byte_size(name) > 0 ->
        Map.has_key?(bindings, provider)

      _ ->
        false
    end
  end

  defp admitted_model_route?(_, _), do: false

  # Concept: the host continues work only in the physical workspace retained at creation.
  # Technical depth: paths and explicit flags cannot adopt an unbound older root.
  # Compare the existing canonical-root/device/inode digest and every pending
  # intent before returning prepared settings; the caller still checks placement
  # again immediately before activation. Refusal abandons through resume/2.
  defp workspace_binding(
         %{
           "surface" => "chat",
           "workspace_binding" => %{"revision" => 1, "workspace_ref" => retained} = binding
         } = options,
         workspace,
         pending
       )
       when map_size(options) == 2 and map_size(binding) == 2 and is_binary(retained) and
              is_list(pending) do
    with {:ok, reference} <- WorkspaceIdentity.reference(workspace),
         true <- retained == reference,
         true <- Enum.all?(pending, &(&1 == reference)) do
      :ok
    else
      false -> {:error, :chat_workspace_binding_conflict}
      {:error, _} = error -> error
    end
  end

  defp workspace_binding(_options, _workspace, _pending),
    do: {:error, :chat_workspace_binding_unavailable}

  defp resume_grace(flags, grace), do: agrees(flags, "cleanup-grace-ms", grace)

  defp resume_limits(flags, configuration) do
    Enum.reduce_while(
      [
        {"reasoning", "reasoning"},
        {"max-tokens", "max_tokens"},
        {"context-token-budget", "context_token_budget"},
        {"system-class-tokens", "system_class_tokens"}
      ],
      :ok,
      fn {flag, key}, :ok ->
        case agrees(flags, flag, configuration[key]) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end
      end
    )
  end

  defp resume_tools(flags, definitions) do
    ids = Enum.sort(Enum.map(definitions, & &1["tool_id"]))

    cond do
      "loopex.task" in ids ->
        {:error, :chat_delegation_unavailable}

      Map.has_key?(flags, "skill-dir") ->
        {:error, {:chat_resume_immutable_catalog, "/flags/skill-dir"}}

      Map.has_key?(flags, "tools") and Enum.sort(Map.fetch!(@profiles, flags["tools"])) != ids ->
        {:error, {:chat_resume_configuration_conflict, "/flags/tools"}}

      true ->
        :ok
    end
  end

  defp resume_model(flags, %{"model" => retained_model} = configuration, definitions, bindings) do
    case Map.fetch(flags, "model") do
      :error ->
        :ok

      {:ok, ^retained_model} ->
        :ok

      {:ok, model} ->
        declaration =
          configuration
          |> Map.take(
            ~w(reasoning max_tokens context_token_budget system_class_tokens instructions configuration_version)
          )
          |> Map.put("model", model)

        with {:ok, resolved} <-
               ProviderBindings.resolve_configuration(declaration, bindings, definitions),
             do: agrees(%{"model" => resolved["model"]}, "model", configuration["model"])
    end
  end

  defp resume_instructions(flags, profile, instructions) do
    Enum.reduce_while(
      [
        {"system-prompt-file", "system_file", "base"},
        {"append-system-prompt-file", "append_file", "appendix"}
      ],
      :ok,
      fn {flag, option, section}, :ok ->
        if Map.has_key?(flags, flag) do
          path = profile["session"]["instructions"][option]

          case SessionInstructions.capture(
                 profile["paths"]["workspace"],
                 profile["session"]["tools"],
                 %{option => path}
               ) do
            {:ok, captured} ->
              case agrees(%{flag => captured[section]}, flag, instructions[section]) do
                :ok -> {:cont, :ok}
                error -> {:halt, error}
              end

            error ->
              {:halt, error}
          end
        else
          {:cont, :ok}
        end
      end
    )
  end

  defp agrees(flags, flag, retained) do
    case Map.fetch(flags, flag) do
      :error -> :ok
      {:ok, ^retained} -> :ok
      {:ok, _} -> {:error, {:chat_resume_configuration_conflict, "/flags/" <> flag}}
    end
  end

  @doc """
  ## Concept

  Prepare an explicit conversation configuration change against the host's
  last confirmed settings, using its admitted routes and immutable tools.

  ## Technical depth

  Validate the closed authored update before catalog resolution. Resolve model
  aliases into the same canonical identity used at creation, then delegate
  budget derivation and version advancement to Core's shared update validator.
  The returned changes and candidate remain separate admission inputs. This
  preparation reads no instruction file or credential and dispatches no work.
  The caller retains the candidate only after confirmed admission; Core checks
  it against committed settings and history before accepting it.
  """
  @spec update(term(), term()) :: {:ok, map(), map()} | {:error, term()}
  def update(
        %{selection: %{configuration: current, profile: %{"providers" => bindings}}} = prepared,
        changes
      ) do
    with {:ok, definitions} <- configuration_definitions(prepared),
         :ok <- SessionConfiguration.validate_update(changes),
         :ok <- SessionConfiguration.validate(current, definitions),
         declaration <-
           current
           |> Map.take(~w(model reasoning configuration_version instructions max_tokens))
           |> explicit_ceiling(current, "context_token_budget")
           |> explicit_ceiling(current, "system_class_tokens")
           |> Map.merge(changes),
         {:ok, resolved} <-
           ProviderBindings.resolve_configuration(declaration, bindings, definitions),
         changes <- canonical_model(changes, resolved),
         {:ok, candidate} <-
           SessionConfiguration.update(
             current,
             changes,
             resolved["model_capabilities"],
             resolved["provider_mapping"],
             definitions
           ) do
      {:ok, changes, candidate}
    end
  end

  def update(_, _), do: {:error, :invalid_session_configuration}

  defp configuration_definitions(%{
         genesis: %{"tool_selection" => %{"definitions" => definitions}}
       }),
       do: {:ok, definitions}

  defp configuration_definitions(%{retained: %{tool_selection: %{"definitions" => definitions}}}),
    do: {:ok, definitions}

  defp configuration_definitions(_), do: {:error, :invalid_session_configuration}

  defp explicit_ceiling(declaration, current, key) do
    if current["budget_origins"][key] == "explicit",
      do: Map.put(declaration, key, current[key]),
      else: declaration
  end

  defp canonical_model(changes, resolved) do
    if Map.has_key?(changes, "model"),
      do: Map.put(changes, "model", resolved["model"]),
      else: changes
  end

  defp required_paths(profile) do
    Enum.reduce_while(~w(workspace state_root), :ok, fn key, :ok ->
      if is_binary(get_in(profile, ["paths", key])),
        do: {:cont, :ok},
        else: {:halt, {:error, {:missing_configuration_path, "/paths/" <> key}}}
    end)
  end

  defp delegation(%{"delegation" => %{"enabled" => true}}),
    do: {:error, :chat_delegation_unavailable}

  defp delegation(_), do: :ok

  @doc false
  def active_tools(profile), do: Map.fetch!(@profiles, profile)

  @doc false
  def selected_definitions(active) do
    # Concept: new configured sessions capture the artifact-capable read generation.
    # Technical depth: select the literal version before genesis derives its
    # capability; retained sessions keep their captured definitions on resume.
    DurableOptions.definitions(active_tools: active)
    |> Enum.filter(fn definition ->
      definition["tool_id"] in active and
        (definition["tool_id"] not in ~w(loopex.read loopex.grep loopex.find loopex.ls) or
           definition["tool_version"] == "1.1.0")
    end)
  end

  defp capture_instructions(profile) do
    SessionInstructions.capture(
      profile["paths"]["workspace"],
      profile["session"]["tools"],
      Map.get(profile["session"], "instructions", %{})
    )
  end

  @doc false
  def session_options(workspace_ref) do
    %{
      "surface" => "chat",
      "workspace_binding" => %{"revision" => 1, "workspace_ref" => workspace_ref}
    }
  end

  @doc false
  def genesis(selection, definitions, session_options) do
    names =
      Map.new(definitions, fn definition ->
        {id, version, digest} = ToolDefinition.generation(definition)

        {definition["name"],
         %{"tool_id" => id, "tool_version" => version, "definition_digest" => digest}}
      end)

    SessionGenesis.resolve(session_options, %{
      genesis_version: "session_genesis_v3",
      runtime_configuration: %{
        "cleanup_grace_ms" => selection.profile["session"]["cleanup_grace_ms"]
      },
      initial_configuration: selection.configuration,
      tool_selection: %{"definitions" => definitions, "names" => names},
      policy_defer_mode: "admit"
    })
  end
end
