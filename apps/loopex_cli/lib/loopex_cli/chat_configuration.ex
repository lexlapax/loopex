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
  Resume and enabled delegation require their own retained-state preparation;
  until those paths are joined they refuse here rather than changing meaning.
  """

  alias LoopexCli.{ConfigFile, ConfigOptions, ConfigSelection, SessionInstructions}
  alias LoopexComposition.DurableOptions
  alias Loopex.Runtime.SessionGenesis
  alias Loopex.Runtime.SessionConfiguration
  alias LoopexComposition.ProviderBindings
  alias LoopexProtocol.ToolDefinition

  @profiles %{
    "coding" => ~w(loopex.read loopex.write loopex.edit loopex.bash loopex.ask),
    "read-only" => ~w(loopex.read loopex.grep loopex.find loopex.ls loopex.ask),
    "none" => []
  }
  @session_options %{"surface" => "chat"}

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
         {:ok, genesis} <- genesis(selection, definitions) do
      {:ok,
       %{
         selection: selection,
         active_tools: active,
         session_options: @session_options,
         genesis: genesis
       }}
    else
      {:ok, _other_command} -> {:error, :invalid_chat_invocation}
      {:error, _} = error -> error
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
        %{
          selection: %{configuration: current, profile: %{"providers" => bindings}},
          genesis: %{"tool_selection" => %{"definitions" => definitions}}
        },
        changes
      ) do
    with :ok <- SessionConfiguration.validate_update(changes),
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

  defp selected_definitions(active) do
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

  defp genesis(selection, definitions) do
    names =
      Map.new(definitions, fn definition ->
        {id, version, digest} = ToolDefinition.generation(definition)

        {definition["name"],
         %{"tool_id" => id, "tool_version" => version, "definition_digest" => digest}}
      end)

    SessionGenesis.resolve(@session_options, %{
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
