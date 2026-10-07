defmodule Loopex.Runtime.CreationOptions do
  @moduledoc """
  ## Concept

  Capture authored creation input before host resolution and reconstruct its
  exact identity from initial genesis. This internal pure boundary grants no
  creation or model authority.

  ## Technical depth

  ADR 0055 admits native version 1, optional configuration and ordered tools.
  Instructions, SessionConfiguration and SessionGenesis own the existing
  closed domains, candidate algebra and budgets. Options retain instruction
  version/digest while full sections occur once in genesis configuration.
  Equality of capture values compares every section, even when renderings
  collide. No callback, adapter, registry, catalog, clock or environment is read.
  """

  alias Loopex.Runtime.Instructions
  alias Loopex.Runtime.SessionConfiguration
  alias Loopex.Runtime.SessionGenesis
  alias Loopex.Store

  @option_keys ~w(version configuration tools)
  @instruction_keys ~w(version base environment appendix)
  @default_keys Enum.sort(
                  ~w(initial_configuration runtime_configuration tool_selection policy_defer_mode)
                )
  @max_tools 1_024

  @typedoc """
  ## Concept

  Internal authored identity with its complete instruction capture.

  ## Technical depth

  Options preserve supplied-member presence, native quantities, aliases and
  tool order. Instructions are nil when omitted, otherwise the five captured
  fields. Options retain only their two-field descriptor. No host selection
  or preparation authority is represented.
  """
  @type capture :: %{options: map(), instructions: Instructions.captured() | nil}

  # Concept: normalize authored data without supplying host facts.
  # Technical depth: transports decode decimal quantities to native integers;
  # exact binary keys and raw four-field instructions are required here.
  @doc false
  @spec normalize(term()) :: {:ok, capture()} | {:error, :invalid_session_creation}
  def normalize(options)
      when is_map(options) and not is_struct(options) and map_size(options) in 1..3 do
    with true <- options["version"] === 1,
         true <- Map.keys(options) -- @option_keys == [],
         {:ok, _bytes} <- Store.admit_bounded(options),
         :ok <- validate_tools(options),
         {:ok, normalized, instructions} <- normalize_configuration(options) do
      {:ok, %{options: normalized, instructions: instructions}}
    else
      _invalid -> {:error, :invalid_session_creation}
    end
  end

  def normalize(_options), do: {:error, :invalid_session_creation}

  # Concept: preparation receives the complete authored configuration changes.
  # Technical depth: authenticating the capture refuses orphan instruction
  # content or changed descriptors. Omitted configuration returns nil.
  @doc false
  @spec changes(term()) :: {:ok, map() | nil} | {:error, :invalid_session_creation}
  def changes(capture) do
    with {:ok, input} <- authored_input(capture),
         {:ok, ^capture} <- normalize(input) do
      configuration = capture.options["configuration"]

      if capture.instructions,
        do: {:ok, Map.put(configuration, "instructions", capture.instructions)},
        else: {:ok, configuration}
    else
      _invalid -> {:error, :invalid_session_creation}
    end
  end

  # Concept: selection is limited to the host's captured default definitions.
  # Technical depth: this private version-1 baseline has empty options and is
  # not a creation proposal. Omission preserves order; explicit names select
  # exact definitions in authored order. The original configuration must fit.
  @doc false
  @spec baseline(term(), term()) ::
          {:ok, SessionGenesis.genesis()}
          | {:error, :invalid_session_creation | :session_configuration_too_large}
  def baseline(capture, defaults)
      when is_map(defaults) and not is_struct(defaults) and map_size(defaults) == 4 do
    with {:ok, _changes} <- changes(capture),
         true <- Enum.sort(Map.keys(defaults)) == @default_keys,
         {:ok, retained} <-
           SessionGenesis.normalize(
             Map.merge(defaults, %{:kind => "session_genesis_v3", "options" => %{}})
           ),
         true <- retained["initial_configuration"]["configuration_version"] == 1,
         {:ok, definitions} <- select_definitions(capture.options, retained["tool_selection"]),
         selection <- %{
           "definitions" => definitions,
           "names" =>
             Map.take(retained["tool_selection"]["names"], Enum.map(definitions, & &1["name"]))
         } do
      SessionGenesis.resolve(%{}, %{
        genesis_version: "session_genesis_v3",
        runtime_configuration: retained["runtime_configuration"],
        initial_configuration: retained["initial_configuration"],
        tool_selection: selection,
        policy_defer_mode: retained["policy_defer_mode"]
      })
      |> creation_result()
    else
      {:error, :session_configuration_too_large} = error -> error
      _invalid -> {:error, :invalid_session_creation}
    end
  end

  def baseline(_capture, _defaults), do: {:error, :invalid_session_creation}

  # Concept: bind the verified initial configuration and exact authored input.
  # Technical depth: explicit changes require the version-2 candidate verified
  # by the existing alias algebra; only its version becomes 1. No configure
  # fact is emitted, and the complete shared genesis ceiling still applies.
  @doc false
  @spec initial_genesis(term(), term(), term()) ::
          {:ok, SessionGenesis.genesis()}
          | {:error, :invalid_session_creation | :session_configuration_too_large}
  def initial_genesis(capture, baseline, candidate) do
    with {:ok, changes} <- changes(capture),
         {:ok, retained} <- SessionGenesis.normalize(baseline),
         true <- retained["options"] == %{},
         current = retained["initial_configuration"],
         true <- current["configuration_version"] == 1,
         definitions = retained["tool_selection"]["definitions"],
         true <- selected_names_match?(capture.options, definitions),
         {:ok, configuration} <- initial_configuration(current, changes, candidate, definitions) do
      retained
      |> Map.put("options", capture.options)
      |> Map.put("initial_configuration", configuration)
      |> SessionGenesis.normalize()
      |> creation_result()
    else
      {:error, :session_configuration_too_large} = error -> error
      _invalid -> {:error, :invalid_session_creation}
    end
  end

  # Concept: replay compares original authored sections without current defaults.
  # Technical depth: the authenticated initial configuration supplies complete
  # content. Recomputed capture must reproduce the retained descriptor, every
  # supplied member and the explicit tool order.
  @doc false
  @spec reconstruct(term()) ::
          {:ok, capture()}
          | {:error, :invalid_session_creation | :session_configuration_too_large}
  def reconstruct(genesis) do
    with {:ok, retained} <- SessionGenesis.normalize(genesis),
         options = retained["options"],
         true <- retained["initial_configuration"]["configuration_version"] == 1,
         instructions <- retained_instructions(options, retained["initial_configuration"]),
         {:ok, input} <- authored_input(%{options: options, instructions: instructions}),
         {:ok, capture} <- normalize(input),
         true <- capture.options == options,
         true <- retained_changes_match?(capture, retained["initial_configuration"]),
         true <- selected_names_match?(options, retained["tool_selection"]["definitions"]) do
      {:ok, capture}
    else
      {:error, :session_configuration_too_large} = error -> error
      _invalid -> {:error, :invalid_session_creation}
    end
  end

  defp normalize_configuration(options) do
    case Map.fetch(options, "configuration") do
      :error ->
        {:ok, options, nil}

      {:ok, configuration} when is_map(configuration) and not is_struct(configuration) ->
        case Map.fetch(configuration, "instructions") do
          :error ->
            with :ok <- SessionConfiguration.validate_update(configuration),
                 do: {:ok, options, nil}

          {:ok, raw} ->
            with {:ok, instructions} <- Instructions.capture(raw),
                 changes = Map.put(configuration, "instructions", instructions),
                 :ok <- SessionConfiguration.validate_update(changes) do
              descriptor = Map.take(instructions, ~w(version digest))
              normalized = Map.put(configuration, "instructions", descriptor)
              {:ok, Map.put(options, "configuration", normalized), instructions}
            end
        end

      _invalid ->
        {:error, :invalid_session_creation}
    end
  end

  defp validate_tools(options) do
    case Map.fetch(options, "tools") do
      :error ->
        :ok

      {:ok, tools} when is_list(tools) ->
        if length(tools) <= @max_tools and Enum.all?(tools, &tool_name?/1) and
             length(Enum.uniq(tools)) == length(tools),
           do: :ok,
           else: {:error, :invalid_session_creation}

      _invalid ->
        {:error, :invalid_session_creation}
    end
  end

  defp tool_name?(name),
    do:
      is_binary(name) and byte_size(name) in 1..64 and
        Regex.match?(~r/\A[a-z][a-z0-9_]{0,63}\z/, name)

  defp authored_input(%{options: options, instructions: instructions} = capture)
       when map_size(capture) == 2 and is_map(options) and not is_struct(options) do
    configuration = options["configuration"]

    cond do
      is_map(configuration) and Map.has_key?(configuration, "instructions") ->
        with :ok <- Instructions.validate(instructions),
             true <- configuration["instructions"] == Map.take(instructions, ~w(version digest)) do
          raw = Map.take(instructions, @instruction_keys)
          {:ok, Map.put(options, "configuration", Map.put(configuration, "instructions", raw))}
        else
          _invalid -> {:error, :invalid_session_creation}
        end

      is_nil(instructions) ->
        {:ok, options}

      true ->
        {:error, :invalid_session_creation}
    end
  end

  defp authored_input(_capture), do: {:error, :invalid_session_creation}

  defp select_definitions(options, selection) do
    case Map.fetch(options, "tools") do
      :error ->
        {:ok, selection["definitions"]}

      {:ok, names} ->
        by_name = Map.new(selection["definitions"], &{&1["name"], &1})

        if Enum.all?(names, &Map.has_key?(by_name, &1)),
          do: {:ok, Enum.map(names, &Map.fetch!(by_name, &1))},
          else: {:error, :invalid_session_creation}
    end
  end

  defp selected_names_match?(options, definitions) do
    case Map.fetch(options, "tools") do
      :error -> true
      {:ok, names} -> names == Enum.map(definitions, & &1["name"])
    end
  end

  defp initial_configuration(current, nil, :captured, _definitions), do: {:ok, current}

  defp initial_configuration(current, changes, candidate, definitions)
       when is_map(changes) and is_map(candidate) do
    with :ok <- SessionConfiguration.validate_candidate(current, changes, candidate, definitions),
         true <- candidate["configuration_version"] == 2,
         initial = Map.put(candidate, "configuration_version", 1),
         :ok <- SessionConfiguration.validate(initial, definitions),
         do: {:ok, initial}
  end

  defp initial_configuration(_current, _changes, _candidate, _definitions),
    do: {:error, :invalid_session_creation}

  defp retained_instructions(options, configuration) do
    if is_map(options["configuration"]) and Map.has_key?(options["configuration"], "instructions") do
      configuration["instructions"]
    else
      nil
    end
  end

  # Concept: retained authored settings must agree with their committed values.
  # Technical depth: aliases retain authored spelling without fresh resolution;
  # every other supplied value remains exact, including explicit ceiling origins.
  defp retained_changes_match?(capture, configuration) do
    case changes(capture) do
      {:ok, nil} ->
        true

      {:ok, changes} ->
        Enum.all?(changes, fn
          {"model", _authored} ->
            true

          {key, value} when key in ["context_token_budget", "system_class_tokens"] ->
            configuration[key] == value and configuration["budget_origins"][key] == "explicit"

          {key, value} ->
            configuration[key] == value
        end)

      _invalid ->
        false
    end
  end

  defp creation_result({:ok, _genesis} = result), do: result
  defp creation_result({:error, :session_configuration_too_large} = error), do: error
  defp creation_result(_invalid), do: {:error, :invalid_session_creation}
end
