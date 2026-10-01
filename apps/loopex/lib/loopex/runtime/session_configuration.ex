defmodule Loopex.Runtime.SessionConfiguration do
  @moduledoc """
  ## Concept

  A session retains the settings its host admitted, including exact instruction
  bytes and resolved model facts. Recovery validates those captured settings
  without consulting a newer catalog or treating metadata as an authority grant.

  ## Technical depth

  The closed configuration contains model, reasoning, configuration_version,
  instructions, max_tokens, context_token_budget, system_class_tokens,
  budget_origins, model_capabilities and provider_mapping. Capability metadata
  has model, context_window, output_limit, reasoning_levels, source_revision and
  source_digest; unknown limits are explicit nil values. Context origins are
  model_window, unknown_window or explicit; system origins are legacy_default
  or explicit. The two resolved metadata maps together cost at most 2,048
  canonical bytes. Validation counts the rendered system message and complete
  model-facing selected tools against the strict system ceiling. Whole history
  and complete request-record admission remain the session owner's obligation.
  """

  alias Loopex.Bounds
  alias Loopex.Runtime.Instructions
  alias Loopex.Store
  alias LoopexProtocol.Canonical
  alias LoopexProtocol.ToolDefinition

  @uint64_max 18_446_744_073_709_551_615
  @keys Enum.sort(~w(model reasoning configuration_version instructions max_tokens
                    context_token_budget system_class_tokens budget_origins
                    model_capabilities provider_mapping))
  @capability_keys Enum.sort(
                     ~w(model context_window output_limit reasoning_levels source_revision source_digest)
                   )
  @mapping_keys Enum.sort(~w(mapping_revision renderer_revision continuation_required
                            canonical_terminal_tool_history thinking_disabled thinking))
  @levels ~w(default none low medium high)
  @declaration_required ~w(model reasoning configuration_version instructions max_tokens)
  @declaration_optional ~w(context_token_budget system_class_tokens)
  @generic %{
    "mapping_revision" => "loopex.unregistered.default.v1",
    "renderer_revision" => "loopex.reqllm.canonical.v1",
    "continuation_required" => false,
    "canonical_terminal_tool_history" => false,
    "thinking_disabled" => false,
    "thinking" => %{"mode" => "omitted"}
  }

  @doc """
  ## Concept

  Resolve an initial configuration from explicit host selections and captured
  model facts, retaining how each context and system ceiling was selected.

  ## Technical depth

  The closed declaration requires model, reasoning, configuration_version,
  captured instructions and max_tokens. Only context_token_budget and
  system_class_tokens may be omitted. A known window derives input as window
  minus the reply reserve; an unknown window derives 8,192 input tokens without
  subtracting the reserve. Omitted system ceiling is 1,000. Explicit ceilings
  remain explicit, including a value equal to the default. The host supplies
  already resolved capability and mapping records and the complete selected
  definitions. The shared validator checks the whole candidate before return;
  this function does no catalog lookup, instruction capture or effect.
  """
  @spec resolve(term(), term(), term(), term()) ::
          {:ok, map()} | {:error, :invalid_session_configuration}
  def resolve(declaration, capabilities, mapping, definitions)
      when is_map(declaration) and not is_struct(declaration) do
    with true <- declaration_shape?(declaration),
         true <- positive?(declaration["max_tokens"]),
         candidate <-
           declaration
           |> Map.put("model_capabilities", capabilities)
           |> Map.put("provider_mapping", mapping),
         true <- valid_capabilities?(candidate),
         candidate <- resolve_budgets(candidate),
         :ok <- validate(candidate, definitions) do
      {:ok, candidate}
    else
      _invalid -> {:error, :invalid_session_configuration}
    end
  end

  def resolve(_, _, _, _), do: {:error, :invalid_session_configuration}

  @doc """
  ## Concept

  Validate one complete resolved configuration against its immutable tools.

  ## Technical depth

  Input is bounded plain data with binary keys. Known model windows must exceed
  the reply reserve and bound input; unknown windows use 8,192 only for the
  unknown_window origin. Explicit values retain their origin and still obey
  known limits. A captured reasoning subset permits only its listed levels;
  unknown capability permits default only with the literal generic mapping.
  No provider, catalog, registry, clock or Store adapter is invoked.
  """
  @spec validate(term(), term()) :: :ok | {:error, :invalid_session_configuration}
  def validate(configuration, definitions) when is_map(configuration) and is_list(definitions) do
    with {:ok, _} <- Store.admit_bounded([configuration, definitions]),
         true <- closed?(configuration, @keys),
         true <- text?(configuration["model"]),
         true <- configuration["reasoning"] in @levels,
         true <- positive?(configuration["configuration_version"]),
         true <- positive?(configuration["max_tokens"]),
         true <- positive?(configuration["context_token_budget"]),
         true <- positive?(configuration["system_class_tokens"]),
         true <- configuration["system_class_tokens"] <= configuration["context_token_budget"],
         :ok <- Instructions.validate(configuration["instructions"]),
         true <- valid_capabilities?(configuration),
         true <- valid_mapping?(configuration["provider_mapping"]),
         true <- valid_reasoning?(configuration),
         true <- byte_size(Canonical.encode(metadata(configuration))) <= 2_048,
         true <- valid_budgets?(configuration),
         true <- Enum.all?(definitions, &ToolDefinition.valid?/1),
         {:ok, text} <- Instructions.render(configuration["instructions"]),
         true <- system_cost(text, definitions) < configuration["system_class_tokens"] do
      :ok
    else
      _invalid -> {:error, :invalid_session_configuration}
    end
  end

  def validate(_configuration, _definitions), do: {:error, :invalid_session_configuration}

  @doc """
  ## Concept

  The sampling settings bound by an admitted configuration.

  ## Technical depth

  Includes the exact resolved mapping in canonical request bytes. Default
  reasoning omits its override; other admitted levels carry their literal value.
  The caller supplies an already validated configuration.
  """
  @spec sampling(map()) :: map()
  def sampling(configuration) do
    sampling = Map.take(configuration, ~w(max_tokens provider_mapping))

    if configuration["reasoning"] == "default",
      do: sampling,
      else: Map.put(sampling, "reasoning", configuration["reasoning"])
  end

  @doc """
  ## Concept

  The instruction identity used by a configured request's context receipt.

  ## Technical depth

  The closed host_instructions reference retains exactly captured version and
  rendered-content digest. The descriptor separately measures the full message.
  The caller supplies an already validated configuration.
  """
  @spec instruction_source(map()) :: map()
  def instruction_source(configuration) do
    configuration["instructions"]
    |> Map.take(~w(version digest))
    |> Map.put("kind", "host_instructions")
  end

  defp declaration_shape?(declaration) do
    keys = Map.keys(declaration)

    @declaration_required -- keys == [] and
      keys -- (@declaration_required ++ @declaration_optional) == []
  end

  defp resolve_budgets(candidate) do
    {context, origin} =
      cond do
        Map.has_key?(candidate, "context_token_budget") ->
          {candidate["context_token_budget"], "explicit"}

        is_nil(candidate["model_capabilities"]["context_window"]) ->
          {8_192, "unknown_window"}

        true ->
          {candidate["model_capabilities"]["context_window"] - candidate["max_tokens"],
           "model_window"}
      end

    system_origin =
      if Map.has_key?(candidate, "system_class_tokens"), do: "explicit", else: "legacy_default"

    candidate
    |> Map.put("context_token_budget", context)
    |> Map.put_new("system_class_tokens", 1_000)
    |> Map.put("budget_origins", %{
      "context_token_budget" => origin,
      "system_class_tokens" => system_origin
    })
  end

  defp valid_capabilities?(configuration) do
    capabilities = configuration["model_capabilities"]

    closed?(capabilities, @capability_keys) and
      capabilities["model"] == configuration["model"] and
      optional_limit?(capabilities["context_window"]) and
      optional_limit?(capabilities["output_limit"]) and
      levels?(capabilities["reasoning_levels"]) and
      revision?(capabilities["source_revision"]) and
      digest?(capabilities["source_digest"])
  end

  defp valid_mapping?(mapping) do
    closed?(mapping, @mapping_keys) and revision?(mapping["mapping_revision"]) and
      revision?(mapping["renderer_revision"]) and
      is_boolean(mapping["continuation_required"]) and
      is_boolean(mapping["canonical_terminal_tool_history"]) and
      is_boolean(mapping["thinking_disabled"]) and valid_thinking?(mapping["thinking"])
  end

  defp valid_thinking?(%{"mode" => mode} = value) when mode in ~w(omitted disabled),
    do: map_size(value) == 1

  defp valid_thinking?(%{"mode" => "manual", "budget_tokens" => tokens} = value),
    do: map_size(value) == 2 and positive?(tokens)

  defp valid_thinking?(
         %{"mode" => "adaptive", "effort" => effort, "display" => "summarized"} = value
       ),
       do: map_size(value) == 3 and effort in ~w(low medium high)

  defp valid_thinking?(_value), do: false

  defp valid_reasoning?(configuration) do
    levels = configuration["model_capabilities"]["reasoning_levels"]
    reasoning = configuration["reasoning"]
    mapping = configuration["provider_mapping"]

    cond do
      levels == [] ->
        reasoning == "default" and mapping == @generic

      mapping["mapping_revision"] == @generic["mapping_revision"] ->
        reasoning == "default" and reasoning in levels and mapping == @generic

      true ->
        reasoning in levels
    end
  end

  defp valid_budgets?(configuration) do
    capabilities = configuration["model_capabilities"]
    origins = configuration["budget_origins"]
    window = capabilities["context_window"]
    output = capabilities["output_limit"]
    reserve = configuration["max_tokens"]
    input = configuration["context_token_budget"]

    closed?(origins, ~w(context_token_budget system_class_tokens)) and
      origins["system_class_tokens"] in ~w(legacy_default explicit) and
      (origins["system_class_tokens"] != "legacy_default" or
         configuration["system_class_tokens"] == 1_000) and
      (is_nil(output) or reserve <= output) and
      (is_nil(window) or (window > reserve and input <= window - reserve)) and
      valid_context_origin?(origins["context_token_budget"], window, reserve, input)
  end

  defp valid_context_origin?("explicit", _window, _reserve, _input), do: true
  defp valid_context_origin?("unknown_window", nil, _reserve, input), do: input == 8_192

  defp valid_context_origin?("model_window", window, reserve, input) when is_integer(window),
    do: input == window - reserve

  defp valid_context_origin?(_origin, _window, _reserve, _input), do: false

  defp metadata(configuration),
    do: Map.take(configuration, ~w(model_capabilities provider_mapping))

  defp system_cost(text, definitions) do
    Bounds.estimate(Canonical.encode(%{"role" => "system", "content" => text})) +
      Enum.reduce(definitions, 0, fn definition, cost ->
        cost + Bounds.estimate(Canonical.encode(ToolDefinition.model_facing(definition)))
      end)
  end

  defp closed?(value, keys), do: is_map(value) and Enum.sort(Map.keys(value)) == Enum.sort(keys)
  defp positive?(value), do: is_integer(value) and value >= 1 and value <= @uint64_max
  defp optional_limit?(nil), do: true
  defp optional_limit?(value), do: positive?(value)
  defp text?(value), do: is_binary(value) and byte_size(value) > 0 and String.valid?(value)
  defp revision?(value), do: text?(value) and byte_size(value) <= 128

  defp digest?(value),
    do: is_binary(value) and byte_size(value) == 64 and Regex.match?(~r/\A[0-9a-f]{64}\z/, value)

  defp levels?(value) when is_list(value),
    do: length(value) <= 5 and Enum.uniq(value) == value and Enum.all?(value, &(&1 in @levels))

  defp levels?(_value), do: false
end
