defmodule LoopexCli.ProviderLaunch do
  @moduledoc false

  # Concept: the command carries the opaque launch configuration of the pair
  # built for it; runtime never searches a workspace for provider code.
  # Technical depth: the file is generated build input, parsed as data once at
  # compilation. Ordinary unpaired source compilation carries no configuration
  # and provider dispatch refuses. No credential belongs in this file.
  @configuration (case System.get_env("LOOPEX_BUILD_PROVIDER_CONFIG") do
                    nil ->
                      []

                    path ->
                      {:ok, [configuration]} = :file.consult(String.to_charlist(path))
                      configuration
                  end)

  @doc false
  def options, do: @configuration
end
