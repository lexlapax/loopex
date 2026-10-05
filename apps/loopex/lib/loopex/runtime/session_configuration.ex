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
  alias Loopex.Conversation
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
  @mutable ~w(model reasoning instructions max_tokens context_token_budget system_class_tokens)
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

  Validate the nonempty configuration changes an operator may request.

  ## Technical depth

  ADR 0044 permits exactly model, reasoning, captured instructions and the
  reply, context and system ceilings. Version, capability metadata, provider
  mapping, immutable tools and maintenance settings cannot be authored here.
  This validates every provided member without resolving host facts or defaults.
  """
  @spec validate_update(term()) :: :ok | {:error, :invalid_configuration_update}
  def validate_update(changes) when is_map(changes) and not is_struct(changes) do
    if match?({:ok, _}, Store.admit_bounded(changes)) and map_size(changes) > 0 and
         Map.keys(changes) -- @mutable == [] and
         Enum.all?(changes, fn
           {"model", model} -> text?(model)
           {"reasoning", level} -> level in @levels
           {"instructions", instructions} -> Instructions.validate(instructions) == :ok
           {_ceiling, value} -> positive?(value)
         end),
       do: :ok,
       else: {:error, :invalid_configuration_update}
  end

  def validate_update(_), do: {:error, :invalid_configuration_update}

  @doc """
  ## Concept

  Prepare one complete next configuration from the committed settings and
  explicit operator changes. A refused candidate changes no retained setting.

  ## Technical depth

  The host supplies resolved model capabilities and mapping separately from
  authored changes. The configuration version advances exactly once. Existing
  explicit context and system ceilings stay explicit unless replaced; derived
  context ceilings are recomputed from the captured window and reply reserve,
  and the omitted system ceiling remains the legacy 1,000. The same complete
  validator used at genesis checks the result against the immutable tools.

  This pure preparation performs no model call, catalog lookup or compaction.
  The session owner must separately prove settled admission and exact history
  and request-record preflight before committing the prepared candidate.
  """
  @spec update(term(), term(), term(), term(), term()) ::
          {:ok, map()}
          | {:error, :invalid_configuration_update | :invalid_session_configuration}
  def update(current, changes, capabilities, mapping, definitions) do
    with :ok <- validate_update(changes),
         :ok <- validate(current, definitions),
         declaration <-
           current
           |> Map.take(@declaration_required)
           |> retain_explicit_ceiling(current, "context_token_budget")
           |> retain_explicit_ceiling(current, "system_class_tokens")
           |> Map.merge(changes)
           |> Map.put("configuration_version", current["configuration_version"] + 1) do
      resolve(declaration, capabilities, mapping, definitions)
    end
  end

  @doc """
  ## Concept

  Verify the exact canonical candidate captured for an authored configuration
  change, including a host-resolved model alias.

  ## Technical depth

  ADR 0050 binds the original authored model name to the candidate's canonical
  model. Only an explicitly authored model member may be substituted when
  reconstructing the pure update. Omission cannot retarget the model, and every
  other setting and origin must equal the existing update result. This validator
  uses retained facts only; it performs no catalog lookup or host callback.
  """
  @spec validate_candidate(term(), term(), term(), term()) ::
          :ok | {:error, :invalid_configuration_transition}
  def validate_candidate(current, authored, candidate, definitions)
      when is_map(current) and is_map(authored) and is_map(candidate) do
    with :ok <- validate_update(authored),
         true <- Map.has_key?(authored, "model") or candidate["model"] == current["model"],
         effective <-
           if(Map.has_key?(authored, "model"),
             do: Map.put(authored, "model", candidate["model"]),
             else: authored
           ),
         {:ok, ^candidate} <-
           update(
             current,
             effective,
             candidate["model_capabilities"],
             candidate["provider_mapping"],
             definitions
           ) do
      :ok
    else
      _ -> {:error, :invalid_configuration_transition}
    end
  end

  def validate_candidate(_, _, _, _), do: {:error, :invalid_configuration_transition}

  @doc """
  ## Concept

  Project only the committed configuration settings an operator may inspect.

  ## Technical depth

  The allowlist contains version, model, reasoning, effective reply/context/
  system ceilings and instruction version/digest. Raw instructions, capability
  provenance and provider mapping stay private. Nil explicitly means legacy
  configuration has not been resolved; no current default is substituted.
  """
  @spec public_view(map() | nil) :: map() | nil
  def public_view(nil), do: nil

  def public_view(configuration) do
    configuration
    |> Map.take(
      ~w(configuration_version model reasoning max_tokens context_token_budget system_class_tokens)
    )
    |> Map.put("instructions", Map.take(configuration["instructions"], ~w(version digest)))
  end

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
         :ok <-
           validate_model_metadata(
             configuration["model"],
             configuration["model_capabilities"],
             configuration["provider_mapping"]
           ),
         true <- valid_reasoning?(configuration),
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

  Validate the captured model facts shared by ordinary and maintenance settings.

  ## Technical depth

  The exact model is nonempty UTF-8. Capabilities and mapping use their closed
  plain-data shapes and together fit 2,048 canonical bytes. This
  checks declared facts only, without a catalog or provider lookup. Each caller
  separately applies its reasoning eligibility and purpose-specific ceilings.
  """
  @spec validate_model_metadata(term(), term(), term()) :: :ok | {:error, :invalid_model_metadata}
  def validate_model_metadata(model, capabilities, mapping) do
    configuration = %{
      "model" => model,
      "model_capabilities" => capabilities,
      "provider_mapping" => mapping
    }

    with {:ok, _} <- Store.admit_bounded(configuration),
         true <- text?(model),
         true <- valid_capabilities?(configuration),
         true <- valid_mapping?(mapping),
         true <- byte_size(Canonical.encode(metadata(configuration))) <= 2_048 do
      :ok
    else
      _ -> {:error, :invalid_model_metadata}
    end
  end

  @doc """
  ## Concept

  Refuse a configuration whose renderer cannot preserve terminal tool history.

  ## Technical depth

  The caller supplies complete retained lineage and exact terminal-run identities.
  The captured mapping must explicitly declare canonical_terminal_tool_history
  when any terminal tool turn lacks a nonempty assistant completion. Malformed
  lineage refuses even when the capability is declared. This check performs no
  dispatch or compaction; token and complete request-record preflight remain
  separate obligations of the owner.
  """
  @spec preflight_history(map(), [Conversation.element()], [binary()]) ::
          :ok | {:error, :canonical_history_rendering_unsupported | :context_projection_invalid}
  def preflight_history(configuration, elements, terminal_runs) do
    with {:ok, required} <- Conversation.terminal_tool_history(elements, terminal_runs) do
      if not required or
           get_in(configuration, ["provider_mapping", "canonical_terminal_tool_history"]) == true,
         do: :ok,
         else: {:error, :canonical_history_rendering_unsupported}
    end
  end

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

  defp retain_explicit_ceiling(declaration, current, key) do
    if current["budget_origins"][key] == "explicit",
      do: Map.put(declaration, key, current[key]),
      else: declaration
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
