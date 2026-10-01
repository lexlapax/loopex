defmodule LoopexComposition.DurableOptions do
  @moduledoc """
  ## Concept

  Validates optional durable profile choices shared by its three constructors.

  ## Technical depth

  Checks follow the released stages. Keyword lookup preserves first duplicate
  values. Empty active selections remove definitions for core inheritance.
  """
  @coding ~w(loopex.read loopex.write loopex.edit loopex.bash)
  @tools @coding ++ ~w(loopex.grep loopex.find loopex.ls)
  @uint64 18_446_744_073_709_551_615

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
         providers = if(routes == :legacy, do: [provider], else: routes),
         true <- provider in providers,
         {:ok, maintenance} <-
           LoopexComposition.ProviderBindings.resolve_maintenance_routes(
             Keyword.get(options, :maintenance_model),
             providers
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
    if Keyword.get(options, :active_tools, @coding) == [],
      do: [],
      else: Loopex.Executor.Local.CodingTools.definitions()
  end

  @doc false
  def runtime_options(options) do
    [active_tools: Keyword.get(options, :active_tools, @coding)] ++
      for key <- [:bounds, :sampling, :maintenance_instructions, :maintenance_model],
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
