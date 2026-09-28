defmodule LoopexCli.CredentialCache do
  @moduledoc """
  ## Concept

  Keeps the reference command's provider credential in one host-owned custody
  for repeated compositions in the same command process.

  ## Technical depth

  The cache is process-local. Opening it consumes the environment variable
  once; each plane starts a fresh runtime-bound trace capability. The host
  process owns the linked custody and registry until that process ends.
  """

  @key :"$loopex_cli_credential_host"

  @doc false
  @spec host() :: {:ok, LoopexComposition.CredentialHost.t()} | {:error, term()}
  def host do
    case Process.get(@key) do
      nil ->
        with {:ok, host} <- LoopexComposition.CredentialHost.open() do
          Process.put(@key, host)
          {:ok, host}
        end

      host ->
        {:ok, host}
    end
  end

  @doc false
  @spec plane() :: {:ok, map()} | {:error, term()}
  def plane do
    with {:ok, host} <- host(),
         do: LoopexComposition.CredentialHost.plane(host)
  end
end
