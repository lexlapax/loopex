defmodule LoopexComposition.Model do
  @moduledoc """
  ## Concept

  The reference host resolves settled configuration changes centrally while
  retaining its selected model adapter's ordinary completion contract.

  ## Technical depth

  ADR 0050 extends the inward Model port. Private wrapper options keep host route
  inputs separate from the selected adapter's exact original keyword options.
  Completion delegates only those original options. Preparation checks explicit
  admitted routes before catalog resolution, acquires no credential, and returns
  only a complete plain canonical candidate. The serial runtime owner validates
  authored identity, history and lifetime before committing it.
  """

  @behaviour Loopex.Model
  alias Loopex.Runtime.SessionConfiguration
  alias LoopexComposition.{Edges, ProviderBindings}

  @doc false
  def reference(%{module: module, model: model, options: original}, host_options) do
    %{
      module: __MODULE__,
      model: model,
      options: [
        adapter: module,
        adapter_options: original,
        host_options: Keyword.take(host_options, [:provider_bindings, :credential_plane])
      ]
    }
  end

  @impl Loopex.Model
  def complete(request, options, progress) do
    module = Keyword.fetch!(options, :adapter)
    module.complete(request, Keyword.fetch!(options, :adapter_options), progress)
  end

  @impl Loopex.Model
  def prepare_configuration(current, authored, definitions, context, options) do
    with true <- System.monotonic_time(:millisecond) < context.deadline_monotonic_ms,
         {:ok, providers} when is_list(providers) <-
           Edges.admitted_routes(Keyword.fetch!(options, :host_options)),
         :ok <- SessionConfiguration.validate_update(authored),
         :ok <- SessionConfiguration.validate(current, definitions),
         declaration <-
           current
           |> Map.take(~w(model reasoning configuration_version instructions max_tokens))
           |> explicit_ceiling(current, "context_token_budget")
           |> explicit_ceiling(current, "system_class_tokens")
           |> Map.merge(authored),
         {:ok, resolved} <-
           ProviderBindings.resolve_configuration_routes(
             declaration,
             providers,
             definitions
           ),
         effective <-
           if(Map.has_key?(authored, "model"),
             do: Map.put(authored, "model", resolved["model"]),
             else: authored
           ),
         {:ok, candidate} <-
           SessionConfiguration.update(
             current,
             effective,
             resolved["model_capabilities"],
             resolved["provider_mapping"],
             definitions
           ),
         true <- System.monotonic_time(:millisecond) < context.deadline_monotonic_ms do
      {:ok, candidate}
    else
      _ -> {:error, :configuration_not_prepared}
    end
  end

  defp explicit_ceiling(declaration, current, key) do
    if current["budget_origins"][key] == "explicit",
      do: Map.put(declaration, key, current[key]),
      else: declaration
  end
end
