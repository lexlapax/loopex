defmodule LoopexComposition.TraceConfiguration do
  @moduledoc """
  ## Concept

  Resolve the same explicit trace selection for owning commands and embedded
  sessions. Host input names trusted compiled modules without supplying a
  runtime, callback or diagnostic sink.

  ## Technical depth

  ADR 0049's closed binary-keyed map uses Boolean enabled, string level and
  module selectors, and three optional positive limits. Missing enabled means
  disabled; omitted level, modules and limits use ADR 0030's existing defaults.
  Validation applies even when disabled. The normalized runtime configuration
  always uses the diagnostics sink and only selectors from the compiled host
  inventory. This function starts no application, trace, consumer or runtime.
  """

  alias Loopex.Trace.Config
  alias LoopexComposition.TraceSelectors

  @keys ~w(enabled level modules max_entry_bytes max_entries_per_second max_queue_entries)
  @levels %{"calls" => :calls, "returns" => :returns, "arguments" => :arguments}
  @limits %{
    "max_entry_bytes" => :entry_bytes,
    "max_entries_per_second" => :entries_per_second,
    "max_queue_entries" => :queued
  }

  @doc """
  ## Concept

  Validate a host trace map before composition can perform startup effects.

  ## Technical depth

  Exact field names and value types are required; invalid input returns the
  fixed invalid_trace_configuration code without echoing a supplied selector
  or value. Resolved module atoms come only from existing application metadata.
  The enabled decision is separate from the closed runtime trace configuration.
  """
  @spec validate(term()) ::
          {:ok, %{enabled: boolean(), configuration: Config.t()}}
          | {:error, :invalid_trace_configuration}
  def validate(value) when is_map(value) and not is_struct(value) do
    with true <- Map.keys(value) -- @keys == [],
         enabled when is_boolean(enabled) <- Map.get(value, "enabled", false),
         level when not is_nil(level) <- Map.get(@levels, Map.get(value, "level", "calls")),
         {:ok, modules} <- modules(value),
         {:ok, configuration} <-
           Config.validate(%{
             modules: modules,
             level: level,
             limits: limits(value),
             sink: :diagnostics
           }) do
      {:ok, %{enabled: enabled, configuration: configuration}}
    else
      _ -> {:error, :invalid_trace_configuration}
    end
  end

  def validate(_), do: {:error, :invalid_trace_configuration}

  defp modules(value) do
    case Map.fetch(value, "modules") do
      :error -> {:ok, Config.namespaces()}
      {:ok, selectors} -> TraceSelectors.resolve(selectors)
    end
  end

  defp limits(value) do
    for {key, runtime_key} <- @limits,
        {:ok, selected} <- [Map.fetch(value, key)],
        into: %{},
        do: {runtime_key, selected}
  end
end
