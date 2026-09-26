defmodule Loopex.Runtime.ProviderLifetime do
  @moduledoc false

  @registrar_key {__MODULE__, :registrar}
  @starter_key {__MODULE__, :starter}

  alias Loopex.Runtime.ProviderLifetime.Starter

  @doc false
  def scoped(registrar, call) when is_function(registrar, 2) and is_function(call, 0) do
    previous = Process.put(@registrar_key, registrar)

    try do
      call.()
    after
      restore_registrar(previous)
    end
  end

  @doc false
  def scoped(registrar, %Starter{} = starter, call)
      when is_function(registrar, 2) and is_function(call, 0) do
    previous_registrar = Process.put(@registrar_key, registrar)
    previous_starter = Process.put(@starter_key, starter)

    try do
      call.()
    after
      restore(@registrar_key, previous_registrar)
      restore(@starter_key, previous_starter)
    end
  end

  @doc false
  @spec starter() :: {:managed, Starter.t()} | :unmanaged
  def starter do
    case Process.get(@starter_key) do
      %Starter{} = starter -> {:managed, starter}
      _unmanaged -> :unmanaged
    end
  end

  @doc false
  @spec start_child(Starter.t(), (-> term())) :: {:ok, pid()} | {:error, :unavailable}
  def start_child(starter, child), do: Starter.invoke(starter, child)

  @doc false
  def register(resource, stop_reference)
      when is_pid(resource) and is_reference(stop_reference) do
    case Process.get(@registrar_key) do
      registrar when is_function(registrar, 2) -> registrar.(resource, stop_reference)
      _unmanaged -> :unmanaged
    end
  end

  defp restore_registrar(nil), do: Process.delete(@registrar_key)
  defp restore_registrar(previous), do: Process.put(@registrar_key, previous)

  defp restore(key, nil), do: Process.delete(key)
  defp restore(key, previous), do: Process.put(key, previous)
end
