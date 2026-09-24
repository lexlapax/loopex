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
  @spec open((module(), keyword() -> {:ok, pid()} | {:error, term()})) ::
          {:ok, %{capability: Capability.Handle.t(), model_options: keyword()}} | {:error, term()}
  def open(start_edge) when is_function(start_edge, 2) do
    variable = ReqLLM.credential_variable()
    credential = System.get_env(variable)
    System.delete_env(variable)

    with :ok <- validate_credential(credential),
         {:ok, registry_pid} <- start_edge.(CredentialRegistry, []),
         {:ok, registry} <- CredentialRegistry.handle(registry_pid),
         {:ok, custody_pid} <- start_edge.(CredentialCustody, credential: credential),
         {:ok, custody} <- CredentialCustody.reference(custody_pid),
         token = CredentialToken.new(),
         :ok <- CredentialRegistry.put(registry, token, custody),
         {:ok, capability_pid} <- start_edge.(Capability, []),
         {:ok, capability} <- Capability.handle(capability_pid) do
      Logger.debug("reference composition credential plane started")

      {:ok,
       %{
         capability: capability,
         model_options: [
           credential_token: token,
           credential_registry: registry,
           tracing_capability: capability
         ]
       }}
    end
  end

  defp validate_credential(credential)
       when is_binary(credential) and byte_size(credential) in 1..@max_credential_bytes do
    Logger.debug("reference composition provider credential consumed")
    :ok
  end

  defp validate_credential(_credential), do: {:error, :provider_credential_required}
end
