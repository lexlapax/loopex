defmodule LoopexComposition.CredentialHost do
  @moduledoc """
  ## Concept

  A host that composes more than one runtime in one process lifetime consumes
  its provider credential once and lends each composition the same custody.
  The reference CLI is such a host: recovering a session inspects it under one
  temporary runtime and then resumes it under another, and a credential the
  first composition consumed must still reach the second without ever
  returning to the environment.

  ## Technical depth

  `open/0` reads `LOOPEX_PROVIDER_API_KEY` once, deletes it from the VM
  environment and places it in a custody process beside a routing registry
  holding one opaque token; both are linked to the calling host process.
  `plane/1` starts one fresh trace capability for one composition, because a
  capability binds exactly one runtime, and returns the plane map that
  `LoopexComposition.start/1`, `with_runtime/2` and `start_edges/2` accept as
  `:credential_plane`. `release_plane/1` stops that capability once its
  runtime is gone and returns after it has exited, killing it after five
  seconds. No function returns or logs credential bytes.
  """

  alias Loopex.LLM.ReqLLM
  alias Loopex.LLM.ReqLLM.{CredentialCustody, CredentialRegistry, CredentialToken}
  alias Loopex.Trace.Capability

  require Logger

  @enforce_keys [:registry, :token]
  defstruct [:registry, :token]

  @opaque t :: %__MODULE__{registry: term(), token: term()}

  @max_credential_bytes 65_536
  @release_wait_ms 5_000

  @doc """
  ## Concept

  Takes the operator's credential into this host's custody.

  ## Technical depth

  The variable is deleted whether or not its value is usable; an absent,
  empty or oversized value is `{:error, :provider_credential_required}` and
  starts nothing.
  """
  @spec open() :: {:ok, t()} | {:error, :provider_credential_required | term()}
  def open do
    variable = ReqLLM.credential_variable()
    credential = System.get_env(variable)
    System.delete_env(variable)

    if is_binary(credential) and byte_size(credential) in 1..@max_credential_bytes do
      open_custody(credential)
    else
      Logger.debug("reference host provider credential absent")
      {:error, :provider_credential_required}
    end
  end

  # A partial start stops what it started, so no orphaned custody keeps the
  # credential for the rest of the host's life.
  defp open_custody(credential) do
    with {:ok, registry_pid} <- CredentialRegistry.start_link([]),
         {:ok, custody_pid} <- start_custody(registry_pid, credential),
         result = register(registry_pid, custody_pid) do
      result
    end
  end

  defp start_custody(registry_pid, credential) do
    case CredentialCustody.start_link(credential: credential) do
      {:ok, custody_pid} ->
        {:ok, custody_pid}

      failure ->
        stop_quietly(registry_pid)
        failure
    end
  end

  defp register(registry_pid, custody_pid) do
    with {:ok, registry} <- CredentialRegistry.handle(registry_pid),
         {:ok, custody} <- CredentialCustody.reference(custody_pid),
         token = CredentialToken.new(),
         :ok <- CredentialRegistry.put(registry, token, custody) do
      Logger.debug("reference host provider credential consumed")
      {:ok, %__MODULE__{registry: registry, token: token}}
    else
      failure ->
        stop_quietly(custody_pid)
        stop_quietly(registry_pid)
        Logger.debug("reference host credential custody start failed")
        failure
    end
  end

  defp stop_quietly(pid) do
    Process.unlink(pid)
    Process.exit(pid, :kill)
  end

  @doc """
  ## Concept

  Removes the credential from a host process that will compose no runtime, so
  no child it starts can inherit it.

  ## Technical depth

  Deletes `LOOPEX_PROVIDER_API_KEY` without reading it.
  """
  @spec discard() :: :ok
  def discard, do: System.delete_env(ReqLLM.credential_variable())

  @doc """
  ## Concept

  One composition's view of the host's credential.

  ## Technical depth

  The returned map carries `:capability`, `:capability_pid` and the three
  opaque `:model_options`; the composition binds the capability to the
  runtime it starts.
  """
  @spec plane(t()) :: {:ok, map()} | {:error, term()}
  def plane(%__MODULE__{registry: registry, token: token}) do
    with {:ok, capability_pid} <- Capability.start_link([]),
         {:ok, capability} <- Capability.handle(capability_pid) do
      Logger.debug("reference host composition capability started")

      {:ok,
       %{
         capability: capability,
         capability_pid: capability_pid,
         model_options: [
           credential_token: token,
           credential_registry: registry,
           tracing_capability: capability
         ]
       }}
    end
  end

  @doc false
  @spec release_plane(map()) :: :ok
  def release_plane(%{capability_pid: pid}) when is_pid(pid) do
    monitor = Process.monitor(pid)
    Process.unlink(pid)
    Process.exit(pid, :shutdown)

    receive do
      {:DOWN, ^monitor, :process, ^pid, _reason} -> :ok
    after
      @release_wait_ms ->
        Process.exit(pid, :kill)

        receive do
          {:DOWN, ^monitor, :process, ^pid, _reason} -> :ok
        end
    end

    Logger.debug("reference host composition capability released")
    :ok
  end

  def release_plane(_plane), do: :ok
end
