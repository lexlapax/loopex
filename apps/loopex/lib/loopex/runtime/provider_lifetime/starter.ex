defmodule Loopex.Runtime.ProviderLifetime.Starter do
  @moduledoc """
  ## Concept

  An opaque invocation-local route for starting provider bridge children under
  the current session owner's worker supervisor.

  ## Technical depth

  The starter is transient process-local authority. It never enters durable or
  public data and reveals neither the supervisor pid nor its child specification.
  Core constructs the only valid value and fixes every child as temporary with
  brutal-kill shutdown.
  """

  @enforce_keys [:start]
  defstruct [:start]

  @opaque t :: %__MODULE__{start: (function() -> {:ok, pid()} | {:error, term()})}

  @doc false
  @spec new((function() -> {:ok, pid()} | {:error, term()})) :: t()
  def new(start) when is_function(start, 1), do: %__MODULE__{start: start}

  @doc false
  @spec invoke(t(), (-> term())) :: {:ok, pid()} | {:error, :unavailable}
  def invoke(%__MODULE__{start: start}, child) when is_function(child, 0) do
    case start.(child) do
      {:ok, pid} when is_pid(pid) -> {:ok, pid}
      _refused -> {:error, :unavailable}
    end
  catch
    _kind, _reason -> {:error, :unavailable}
  end

  def invoke(_starter, _child), do: {:error, :unavailable}
end
