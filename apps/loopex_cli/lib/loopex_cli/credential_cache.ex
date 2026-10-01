defmodule LoopexCli.CredentialCache do
  @moduledoc """
  ## Concept

  Keeps the reference command's provider credential in one host-owned custody
  for repeated compositions in the same command process.

  ## Technical depth

  The cache is process-local. Opening it consumes the environment variable
  once; each plane starts a fresh runtime-bound trace capability. Explicit binding
  maps are immutable for the command lifetime; repeated opens borrow the same
  routes, while a changed map or replacement of a legacy host refuses without
  reading or deleting another credential. The host
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

      {:bindings, _bindings, host} ->
        {:ok, host}

      host ->
        {:ok, host}
    end
  end

  @doc false
  @spec host(map()) :: {:ok, LoopexComposition.CredentialHost.t()} | {:error, term()}
  def host(bindings) do
    with {:ok, _validated} <- LoopexComposition.ProviderBindings.validate(bindings) do
      case Process.get(@key) do
        nil ->
          with {:ok, host} <- LoopexComposition.CredentialHost.open(bindings) do
            Process.put(@key, {:bindings, bindings, host})
            {:ok, host}
          end

        {:bindings, ^bindings, host} ->
          {:ok, host}

        _existing ->
          {:error, :provider_bindings_conflict}
      end
    end
  end

  @doc false
  @spec plane() :: {:ok, map()} | {:error, term()}
  def plane do
    with {:ok, host} <- host(),
         do: LoopexComposition.CredentialHost.plane(host)
  end
end
