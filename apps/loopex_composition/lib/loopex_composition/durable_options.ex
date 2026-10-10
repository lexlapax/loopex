defmodule LoopexComposition.DurableOptions do
  @moduledoc """
  ## Concept

  Validates and resolves durable profile inputs shared by its three constructors.

  ## Technical depth

  Checks follow the released stages. Keyword lookup preserves first duplicate
  values. Empty active selections remove definitions for core inheritance.
  Reference host genesis capture resolves compiled adapter facts and selected
  tool definitions before placement or credential custody. Command callers
  forward the captured data without importing concrete implementations.
  """
  alias Loopex.Runtime.SessionGenesis
  alias LoopexComposition.{ProviderBindings, SessionInstructions}
  alias LoopexProtocol.ToolDefinition

  @coding ~w(loopex.read loopex.write loopex.edit loopex.bash)
  @tools @coding ++ ~w(loopex.grep loopex.find loopex.ls loopex.ask)
  @uint64 18_446_744_073_709_551_615

  @required_options [:state_root, :workspace, :runtime_id]

  @doc false
  def prepare(options) do
    with {:ok, policy} <- policy(Keyword.get(options, :policy)),
         {:ok, [root, workspace, id]} <- required(options, @required_options),
         :ok <- boolean(options, :recover_stale_writer),
         :ok <- boolean(options, :artifact_transfers),
         :ok <- provider_launch(options),
         :ok <- LoopexComposition.ResourcePacks.validate_launch_option(options),
         :ok <- LoopexComposition.WorkspaceIdentity.validate_manifest(options, workspace),
         {:ok, options} <- resolve(options),
         {:ok, defaults} <- capture_defaults(options),
         options = Keyword.put(options, :session_creation_defaults, defaults),
         options = Keyword.put(options, :model, defaults["initial_configuration"]["model"]),
         do: {:ok, {options, root, workspace, id, policy}}
  end

  # Concept: the reference host captures current settings before owned effects.
  # Technical depth: adapter defaults and compiled definitions stay in composition;
  # the resulting plain genesis contains no credential reference or value.
  @doc false
  def capture_defaults(options) do
    case Keyword.fetch(options, :session_creation_defaults) do
      {:ok, defaults} -> retained_defaults(defaults, options)
      :error -> capture_new_defaults(options)
    end
  end

  defp capture_new_defaults(options) do
    with {:ok, genesis} <- capture_genesis(options, %{}) do
      {:ok, Map.drop(genesis, [:kind, "options"])}
    end
  end

  defp retained_defaults(defaults, options) when is_map(defaults) do
    with true <-
           Enum.sort(Map.keys(defaults)) ==
             ~w(initial_configuration policy_defer_mode runtime_configuration tool_selection),
         {:ok, genesis} <-
           SessionGenesis.normalize(
             Map.merge(defaults, %{:kind => "session_genesis_v3", "options" => %{}})
           ),
         true <-
           genesis["initial_configuration"]["model"] ==
             Keyword.get(options, :model, Loopex.LLM.ReqLLM.default_model()),
         admitted = definitions(options),
         true <- Enum.all?(genesis["tool_selection"]["definitions"], &(&1 in admitted)) do
      {:ok, Map.drop(genesis, [:kind, "options"])}
    else
      _ -> {:error, :invalid_session_genesis}
    end
  end

  defp retained_defaults(_, _), do: {:error, :invalid_session_genesis}

  @doc false
  def capture_genesis(options, session_options) do
    model = Keyword.get(options, :model) || Loopex.LLM.ReqLLM.default_model()
    [provider, _] = String.split(model, ":", parts: 2)
    ids = Keyword.get(options, :active_tools, @coding)

    definitions =
      Enum.filter(
        definitions(options),
        &(&1["tool_id"] in ids)
      )

    profile = Keyword.get(options, :tool_profile, instruction_profile(ids))

    bindings =
      Keyword.get(options, :provider_bindings, %{
        provider => %{"credential" => %{"env" => Loopex.LLM.ReqLLM.credential_variable()}}
      })

    with {:ok, instructions} <-
           SessionInstructions.capture(Keyword.fetch!(options, :workspace), profile),
         {:ok, configuration} <-
           ProviderBindings.resolve_configuration(
             Map.merge(
               %{
                 "model" => model,
                 "reasoning" => "default",
                 "configuration_version" => 1,
                 "instructions" => instructions,
                 "max_tokens" =>
                   Keyword.get(options, :sampling, %{"max_tokens" => 4096})["max_tokens"]
               },
               declared_context(options)
             ),
             bindings,
             definitions
           ),
         names <-
           Map.new(definitions, fn definition ->
             {id, version, digest} = ToolDefinition.generation(definition)

             {definition["name"],
              %{"tool_id" => id, "tool_version" => version, "definition_digest" => digest}}
           end),
         {:ok, genesis} <-
           SessionGenesis.resolve(session_options, %{
             genesis_version: "session_genesis_v3",
             runtime_configuration: %{
               "cleanup_grace_ms" =>
                 Keyword.get(options, :cleanup_grace_ms) ||
                   Loopex.Executor.default_cleanup_grace_ms()
             },
             initial_configuration: configuration,
             tool_selection: %{"definitions" => definitions, "names" => names},
             policy_defer_mode: "admit"
           }) do
      {:ok, genesis}
    else
      _ -> {:error, :invalid_session_genesis}
    end
  end

  # A host's explicit context and system ceilings shape its creation defaults;
  # omission keeps the model-window context and the 1,000-token system default.
  defp declared_context(options) do
    for {key, name} <- [
          context_token_budget: "context_token_budget",
          system_class_tokens: "system_class_tokens"
        ],
        {:ok, value} <- [Keyword.fetch(options, key)],
        into: %{},
        do: {name, value}
  end

  defp instruction_profile([]), do: "none"

  defp instruction_profile(ids) do
    if Enum.any?(ids, &(&1 in ~w(loopex.write loopex.edit loopex.bash))),
      do: "coding",
      else: "read-only"
  end

  # An assertion about the world is refused unless it was actually made, rather
  # than read as truthy: only `true` and `false` say anything here.
  defp boolean(options, key) do
    if is_boolean(Keyword.get(options, key, false)),
      do: :ok,
      else: {:error, {:invalid_composition_option, key}}
  end

  defp policy(module) when is_atom(module) and not is_nil(module), do: {:ok, module}

  # Core's contextual reference: its private context reaches only decide/2.
  defp policy(%{module: _, context: _} = adapter) do
    if Loopex.Policy.valid_adapter?(adapter),
      do: {:ok, adapter},
      else: {:error, :host_policy_required}
  end

  defp policy(_absent), do: {:error, :host_policy_required}

  defp provider_launch(options) do
    launch = Keyword.get(options, :provider_launch, [])

    reserved = [
      :credential_token,
      :credential_registry,
      :tracing_capability,
      :provider_routes,
      :excluded_env_names
    ]

    if Keyword.keyword?(launch) and
         Enum.all?(reserved, &(not Keyword.has_key?(launch, &1))) do
      :ok
    else
      {:error, {:invalid_composition_option, :provider_launch}}
    end
  end

  defp required(options, keys) do
    Enum.reduce_while(keys, {:ok, []}, fn key, {:ok, values} ->
      case Keyword.fetch(options, key) do
        {:ok, value} when is_binary(value) and byte_size(value) > 0 ->
          {:cont, {:ok, values ++ [value]}}

        _other ->
          {:halt, {:error, {:invalid_composition_option, key}}}
      end
    end)
  end

  @doc false
  def validate(options) do
    with :ok <- model(Keyword.get(options, :model, Loopex.LLM.ReqLLM.default_model())),
         :ok <- check(bounds?(Keyword.get(options, :bounds, %{})), :bounds),
         :ok <-
           check(sampling?(Keyword.get(options, :sampling, %{"max_tokens" => 4_096})), :sampling),
         :ok <- check(active?(Keyword.get(options, :active_tools, @coding)), :active_tools),
         {:ok, _capture} <-
           Loopex.Runtime.MaintenanceConfiguration.capture_instructions(
             Keyword.get(options, :maintenance_instructions)
           ),
         do: :ok
  end

  @doc false
  def resolve(options) do
    with :ok <- validate(options),
         {:ok, routes} <- LoopexComposition.Edges.admitted_routes(options),
         [provider, _] <-
           String.split(Keyword.get(options, :model, Loopex.LLM.ReqLLM.default_model()), ":",
             parts: 2
           ),
         true <- provider in routes,
         {:ok, maintenance} <-
           LoopexComposition.ProviderBindings.resolve_maintenance_routes(
             Keyword.get(options, :maintenance_model),
             routes
           ) do
      if Keyword.has_key?(options, :maintenance_model),
        do: {:ok, Keyword.put(options, :maintenance_model, maintenance)},
        else: {:ok, options}
    else
      false -> {:error, :provider_route_unavailable}
      {:error, _} = error -> error
    end
  end

  @doc false
  def definitions(options) do
    active = Keyword.get(options, :active_tools, @coding)

    if active == [] do
      []
    else
      questions =
        if "loopex.ask" in active,
          do: [LoopexProtocol.ToolDefinition.question_definition()],
          else: []

      Loopex.Executor.Local.CodingTools.definitions() ++ questions
    end
  end

  @doc false
  def runtime_options(options) do
    active = Keyword.get(options, :active_tools, @coding)

    [active_tools: active] ++
      for key <- [
            :bounds,
            :maintenance_instructions,
            :maintenance_model,
            :session_creation_defaults
          ],
          {:ok, value} <- [Keyword.fetch(options, key)],
          do: {key, value}
  end

  defp model(value) when is_binary(value) and byte_size(value) in 1..512 do
    if String.valid?(value) do
      case String.split(value, ":", parts: 2) do
        [provider, id] when provider != "" and id != "" -> provider(provider)
        _ -> check(false, :model)
      end
    else
      check(false, :model)
    end
  end

  defp model(_), do: check(false, :model)
  defp provider(value) when value in ["openai", "anthropic", "openrouter"], do: :ok
  defp provider("ollama"), do: {:error, {:composition, :durable_model_unsupported}}
  defp provider(_), do: {:error, {:composition, :unknown_provider}}

  defp bounds?(value) when is_map(value) do
    Enum.all?(value, fn {key, n} ->
      key in [:max_turns, :token_budget, :deadline_ms] and is_integer(n) and n > 0 and
        n <= @uint64
    end)
  end

  defp bounds?(_), do: false

  defp sampling?(%{"max_tokens" => n} = value),
    do: map_size(value) == 1 and is_integer(n) and n in 1..1_000_000

  defp sampling?(_), do: false
  defp active?(value), do: active?(value, [])
  defp active?([], _seen), do: true

  defp active?([id | rest], seen) when id in @tools do
    id not in seen and active?(rest, [id | seen])
  end

  defp active?(_, _), do: false
  defp check(true, _), do: :ok
  defp check(false, key), do: {:error, {:invalid_composition_option, key}}
end
