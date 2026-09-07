defmodule LoopexCli.ProviderLaunch do
  @moduledoc false

  # Concept: the command carries the opaque launch configuration of the pair
  # built for it; runtime never searches a workspace for provider code.
  # Technical depth: the file is generated build input, parsed as data once at
  # compilation. Ordinary unpaired source compilation carries no configuration
  # and provider dispatch refuses. No credential belongs in this file.
  @configuration_path System.get_env("LOOPEX_BUILD_PROVIDER_CONFIG")
  if @configuration_path do
    @external_resource @configuration_path
  end

  @configuration (case @configuration_path do
                    nil ->
                      []

                    path ->
                      {:ok, [configuration]} = :file.consult(String.to_charlist(path))
                      configuration
                  end)

  @doc false
  def options, do: @configuration

  # Concept: an ordinary source compile cannot retain a previous paired build.
  # Technical depth: Mix calls this hook before incremental compilation. A
  # changed or removed explicit input, including same-path/same-size changes,
  # invalidates the embedded bytes. Runtime options/0 performs no file lookup.
  if @configuration_path do
    @configuration_bytes File.read!(@configuration_path)
    @doc false
    def __mix_recompile__? do
      System.get_env("LOOPEX_BUILD_PROVIDER_CONFIG") != @configuration_path or
        File.read(@configuration_path) != {:ok, @configuration_bytes}
    end
  else
    @doc false
    def __mix_recompile__?, do: System.get_env("LOOPEX_BUILD_PROVIDER_CONFIG") != nil
  end
end
