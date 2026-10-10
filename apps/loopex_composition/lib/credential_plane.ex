defmodule LoopexComposition.CredentialPlane do
  @moduledoc """
  ## Concept

  The reference host consumes its provider credential once into private
  custody and composes the opaque routing and trace-exclusion capabilities the
  runtime model adapter needs. Successful composition leaves the credential
  name absent from the parent VM environment.

  ## Technical depth

  The caller supplies the same owned-edge starter used for every other
  reference edge, so registry, custody and tracing capability remain linked to
  the exact composition owner and participate in its reverse cleanup. This
  module returns only opaque token and handle values for model options; it
  never returns credential bytes. Custody's start arguments carry the
  credential through that starter, so an observer installed at the
  composition's process-dictionary edge seam can see them; production installs
  no observer there, only `LoopexComposition.Edges`' tracking starter, which
  passes custody's arguments through unchanged and keeps none of them.
  """

  alias Loopex.LLM.ReqLLM

  alias Loopex.LLM.ReqLLM.{
    CredentialCustody,
    CredentialRegistry,
    CredentialToken
  }

  alias Loopex.Trace.Capability

  require Logger

  @max_credential_bytes 65_536

  @doc false
  def open(bindings, start_edge) when is_function(start_edge, 2) do
    with {:ok, loaded} <- load_bindings(bindings, start_edge) do
      case start_binding_edge(Capability, [], start_edge) do
        {:ok, pid} ->
          case Capability.handle(pid) do
            {:ok, capability} ->
              {:ok, binding_plane(loaded, capability)}

            error ->
              stop_bindings(%{loaded | pids: [pid | loaded.pids]})
              error
          end

        error ->
          stop_bindings(loaded)
          error
      end
    end
  end

  # Concept: direct and borrowing hosts share reference validation and one load
  # per unique name, retaining only opaque routes after credential consumption.
  # Technical depth: validation precedes every environment operation. Only
  # returned linked children enter the reverse-order rollback list. Each error
  # joins their termination before returning; successful ownership stays with
  # the opener. An unused released provider variable is deleted unread.
  @doc false
  def load_bindings(bindings, start_edge) when is_function(start_edge, 2) do
    with {:ok, validated} <- LoopexComposition.ProviderBindings.validate(bindings),
         false <- Map.has_key?(bindings, "ollama") do
      names =
        bindings
        |> Map.values()
        |> Enum.map(&get_in(&1, ["credential", "env"]))
        |> Enum.uniq()
        |> Enum.sort()

      unless ReqLLM.credential_variable() in names,
        do: System.delete_env(ReqLLM.credential_variable())

      case start_binding_edge(CredentialRegistry, [], start_edge) do
        {:ok, pid} ->
          loaded = %{
            pids: [pid],
            registry: nil,
            provider_routes: %{},
            excluded_env_names: validated.excluded_env_names
          }

          with {:ok, registry} <- CredentialRegistry.handle(pid),
               {:ok, loaded, tokens} <-
                 load_names(names, %{loaded | registry: registry}, %{}, start_edge) do
            routes =
              Map.new(bindings, fn {provider, binding} ->
                {provider, Map.fetch!(tokens, binding["credential"]["env"])}
              end)

            {:ok, %{loaded | provider_routes: routes}}
          else
            {:error, reason, partial} ->
              stop_bindings(partial)
              {:error, reason}

            {:error, reason} ->
              stop_bindings(loaded)
              {:error, reason}
          end

        error ->
          error
      end
    else
      true -> {:error, {:composition, :durable_model_unsupported}}
      {:error, _} = error -> error
    end
  end

  defp load_names([], loaded, tokens, _start_edge), do: {:ok, loaded, tokens}

  defp load_names([name | rest], loaded, tokens, start_edge) do
    case load_name(name, loaded, start_edge) do
      {:ok, token, loaded} -> load_names(rest, loaded, Map.put(tokens, name, token), start_edge)
      {:error, _, _} = error -> error
    end
  end

  defp load_name(name, loaded, start_edge) do
    credential = System.get_env(name)
    System.delete_env(name)

    with :ok <- validate_credential(credential),
         {:ok, pid} <- start_binding_edge(CredentialCustody, [credential: credential], start_edge) do
      loaded = %{loaded | pids: [pid | loaded.pids]}

      with {:ok, custody} <- CredentialCustody.reference(pid),
           token = CredentialToken.new(),
           :ok <- CredentialRegistry.put(loaded.registry, token, custody) do
        {:ok, token, loaded}
      else
        {:error, reason} -> {:error, reason, loaded}
      end
    else
      {:error, reason} -> {:error, reason, loaded}
    end
  end

  @doc """
  ## Concept

  The bindings a host with one provider credential and no explicit bindings
  composes.

  ## Technical depth

  ADR 0070 replaces the unversioned single-token plane: every compiled hosted
  provider that requires a credential routes to the one released credential
  slot, so the host's single reference becomes an ordinary version-2 plane
  through the same loader, exclusions and route selection as explicit bindings.
  """
  @spec single_credential_bindings() :: map()
  def single_credential_bindings do
    for {provider, %{credential_required: true}} <-
          Loopex.LLM.ReqLLM.InProcess.Guards.binding_catalog(),
        into: %{},
        do: {provider, %{"credential" => %{"env" => ReqLLM.credential_variable()}}}
  end

  @doc false
  def binding_plane(loaded, capability) do
    %{
      version: 2,
      capability: capability,
      excluded_env_names: loaded.excluded_env_names,
      model_options: [
        provider_routes: loaded.provider_routes,
        credential_registry: loaded.registry,
        tracing_capability: capability
      ]
    }
  end

  @doc false
  def stop_bindings(%{pids: pids}) do
    Enum.each(pids, fn pid ->
      monitor = Process.monitor(pid)
      Process.unlink(pid)
      Process.exit(pid, :kill)

      receive do
        {:DOWN, ^monitor, :process, ^pid, _} -> :ok
      end
    end)

    :ok
  end

  defp start_binding_edge(module, options, start_edge) do
    case start_edge.(module, options) do
      {:ok, pid} when is_pid(pid) and node(pid) == node() -> {:ok, pid}
      _ -> {:error, :credential_binding_start_failed}
    end
  catch
    _, _ -> {:error, :credential_binding_start_failed}
  end

  defp validate_credential(credential)
       when is_binary(credential) and byte_size(credential) in 1..@max_credential_bytes do
    Logger.debug("reference composition provider credential consumed")
    :ok
  end

  defp validate_credential(_credential), do: {:error, :provider_credential_required}
end
