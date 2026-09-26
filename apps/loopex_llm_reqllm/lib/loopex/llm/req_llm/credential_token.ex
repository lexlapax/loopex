defmodule Loopex.LLM.ReqLLM.CredentialToken do
  @moduledoc """
  ## Concept

  An opaque runtime-local name for the provider credential selected when a host
  composes a model adapter.

  ## Technical depth

  The token is exactly sixteen random bytes under a tagged struct. It contains
  no credential, route, module, provider identity, or ambient authority. Its
  closed shape is validated before child creation or routing.
  """

  @enforce_keys [:id]
  defstruct [:id]

  @opaque t :: %__MODULE__{id: <<_::128>>}

  @doc false
  @spec new() :: t()
  def new, do: %__MODULE__{id: :crypto.strong_rand_bytes(16)}

  @doc false
  @spec validate(term()) :: :ok | {:error, :invalid_token}
  def validate(%__MODULE__{} = token) do
    if map_size(token) == 2 and Map.keys(token) |> Enum.sort() == [:__struct__, :id] and
         is_binary(token.id) and byte_size(token.id) == 16 do
      :ok
    else
      {:error, :invalid_token}
    end
  end

  def validate(_token), do: {:error, :invalid_token}
end
