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
  environment and places it in a custody process beside a routing registry,
  as the version-2 single-credential bindings of ADR 0070; both are linked to
  the calling host process.
  `plane/1` starts one fresh trace capability for one composition, because a
  capability binds exactly one runtime, and returns the plane map that
  `LoopexComposition.start/1`, `with_runtime/2` and `start_edges/2` accept as
  `:credential_plane`. `release_plane/1` stops that capability once its
  runtime is gone and returns after it has exited, killing it after five
  seconds. No function returns or logs credential bytes.
  """

  alias Loopex.LLM.ReqLLM
  alias Loopex.Trace.Capability

  require Logger

  @enforce_keys [:registry, :provider_routes, :excluded_env_names]
  defstruct [:registry, :provider_routes, :excluded_env_names]

  @opaque t :: %__MODULE__{
            registry: term(),
            provider_routes: map(),
            excluded_env_names: [binary()]
          }

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
  def open, do: open(LoopexComposition.CredentialPlane.single_credential_bindings())

  @doc """
  ## Concept

  Load explicit durable provider references once for a borrowing host.

  ## Technical depth

  The shared loader validates the entire map before environment access,
  deduplicates credential slots and joins partial-start cleanup. Successful
  registry and custody processes remain linked to this host. Each later plane
  borrows these exact routes with a fresh runtime-specific trace capability.
  """
  @spec open(map()) :: {:ok, t()} | {:error, term()}
  def open(bindings) do
    with {:ok, loaded} <-
           LoopexComposition.CredentialPlane.load_bindings(bindings, &start_binding/2) do
      {:ok,
       %__MODULE__{
         registry: loaded.registry,
         provider_routes: loaded.provider_routes,
         excluded_env_names: loaded.excluded_env_names
       }}
    end
  end

  defp start_binding(module, options), do: module.start_link(options)

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

  Every host produces a version-2 plane, retaining the same routes, registry
  and exclusion set while creating a fresh capability. It never resolves
  credentials again. Composition binds the capability to the runtime it starts.
  """
  @spec plane(t()) :: {:ok, map()} | {:error, term()}
  def plane(%__MODULE__{} = host) do
    case Capability.start_link([]) do
      {:ok, capability_pid} ->
        try do
          case capability_handle(capability_pid) do
            {:ok, capability} ->
              Logger.debug("reference host composition capability started")

              plane =
                host
                |> LoopexComposition.CredentialPlane.binding_plane(capability)
                |> Map.put(:capability_pid, capability_pid)

              {:ok, plane}

            failure ->
              release_plane(%{capability_pid: capability_pid})
              failure
          end
        catch
          kind, reason ->
            release_plane(%{capability_pid: capability_pid})
            :erlang.raise(kind, reason, __STACKTRACE__)
        end

      failure ->
        failure
    end
  end

  if Mix.env() == :test do
    defp capability_handle(pid),
      do: Process.get({__MODULE__, :capability_handle}, &Capability.handle/1).(pid)
  else
    defp capability_handle(pid), do: Capability.handle(pid)
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
