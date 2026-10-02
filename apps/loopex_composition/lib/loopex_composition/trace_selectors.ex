defmodule LoopexComposition.TraceSelectors do
  @moduledoc """
  ## Concept

  Resolve host trace names only within the compiled trusted Loopex inventory.
  A supplied string cannot create a module atom or widen a namespace wildcard.

  ## Technical depth

  ADRs 0030 and 0049 admit exact compiled modules and the two named application
  selectors. The inventory comes from the fixed shipped applications' module
  manifests, not a name-prefix scan or all existing VM atoms. Loading application
  metadata starts no application. Wildcards remain application selectors, so
  tracing resolves them through their own module lists later. Unknown values
  produce a stable class and array index, without echoing the selected name.
  """

  @applications ~w(loopex loopex_protocol loopex_composition loopex_llm_reqllm
                    loopex_executor_local loopex_cli loopex_app_server loopex_daemon
                    loopex_reference_client loopex_store_local loopex_telemetry)a
  @wildcards %{"Loopex.*" => :loopex, "LoopexProtocol.*" => :loopex_protocol}

  @doc """
  ## Concept

  Resolve an explicit bounded selector list for inspection or owning startup.

  ## Technical depth

  Accept one to sixty-four UTF-8 names of at most 128 bytes. Exact Elixir module
  names use their printed form, with the explicit `Elixir.` form also admitted.
  Only manifest-owned atoms are returned. Duplicated resolved selectors collapse
  in first-authored order, matching the runtime trace configuration.
  """
  @spec resolve(term()) :: {:ok, [atom()]} | {:error, {atom(), non_neg_integer() | nil}}
  def resolve([]), do: {:error, {:invalid_trace_selectors, nil}}
  def resolve(values) when is_list(values), do: resolve(values, inventory(), 0, [])
  def resolve(_), do: {:error, {:invalid_trace_selectors, nil}}

  defp resolve([], _, _, result), do: {:ok, result |> Enum.reverse() |> Enum.uniq()}
  defp resolve([_ | _], _, 64, _), do: {:error, {:too_many_trace_selectors, nil}}

  defp resolve([name | rest], inventory, index, result) do
    if is_binary(name) and byte_size(name) in 1..128 and String.valid?(name) do
      case Map.fetch(inventory, name) do
        {:ok, module} -> resolve(rest, inventory, index + 1, [module | result])
        :error -> {:error, {:unsupported_trace_selector, index}}
      end
    else
      {:error, {:invalid_trace_selector, index}}
    end
  end

  defp resolve(_, _, _, _), do: {:error, {:invalid_trace_selectors, nil}}

  defp inventory do
    Enum.reduce(@applications, @wildcards, fn application, inventory ->
      _ = :application.load(application)

      case :application.get_key(application, :modules) do
        {:ok, modules} ->
          Enum.reduce(modules, inventory, fn module, inventory ->
            name = Atom.to_string(module)

            inventory
            |> Map.put(name, module)
            |> Map.put(String.replace_prefix(name, "Elixir.", ""), module)
          end)

        _ ->
          inventory
      end
    end)
  end
end
