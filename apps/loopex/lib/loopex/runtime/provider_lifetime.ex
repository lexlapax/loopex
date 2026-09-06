defmodule Loopex.Runtime.ProviderLifetime do
  @moduledoc false

  @registrar_key {__MODULE__, :registrar}

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
  def register(resource, stop_reference)
      when is_pid(resource) and is_reference(stop_reference) do
    case Process.get(@registrar_key) do
      registrar when is_function(registrar, 2) -> registrar.(resource, stop_reference)
      _unmanaged -> :unmanaged
    end
  end

  defp restore_registrar(nil), do: Process.delete(@registrar_key)
  defp restore_registrar(previous), do: Process.put(@registrar_key, previous)
end
