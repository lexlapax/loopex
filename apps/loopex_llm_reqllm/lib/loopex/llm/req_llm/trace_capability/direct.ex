defmodule Loopex.LLM.ReqLLM.TraceCapability.Direct do
  @moduledoc false

  @enforce_keys [:incarnation]
  defstruct [:incarnation]

  @opaque t :: %__MODULE__{incarnation: <<_::128>>}

  @doc false
  @spec new() :: t()
  def new, do: %__MODULE__{incarnation: :crypto.strong_rand_bytes(16)}

  @doc false
  @spec validate(term()) :: :ok | {:error, :invalid_direct_trace_capability}
  def validate(%__MODULE__{} = direct) do
    if map_size(direct) == 2 and
         Map.keys(direct) |> Enum.sort() == [:__struct__, :incarnation] and
         is_binary(direct.incarnation) and byte_size(direct.incarnation) == 16 do
      :ok
    else
      {:error, :invalid_direct_trace_capability}
    end
  end

  def validate(_direct), do: {:error, :invalid_direct_trace_capability}
end
