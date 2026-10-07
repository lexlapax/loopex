defmodule LoopexProtocol.Session.CreationOptions do
  @moduledoc """
  ## Concept

  Decode authored creation settings without filling omissions or supplying host
  authority. Model aliases, instruction sections and explicit tool order retain
  their exact authored bytes.

  ## Technical depth

  Accepted ADR 0055 requires integer version 1 and permits only optional
  configuration and tools. ConfigureRequest owns the six mutable value domains;
  its Wire quantities become positive native uint64 integers. Tool names are
  ordered, unique ASCII names, with at most 1,024 entries. This standalone codec
  performs no selection, capture, preparation, runtime call or generation
  activation. The enclosing duplicate-aware Frame admits JSON and applies its
  existing byte, string, depth and member limits before map conversion. Host
  default membership and complete genesis budgets remain later checks.
  """

  alias LoopexProtocol.Session.ConfigureRequest

  @keys ~w(version configuration tools)
  @max_tools 1_024

  @doc """
  ## Concept

  Preserve the supplied creation-options members in their native value domains.

  ## Technical depth

  Version must be the integer 1. Omitted configuration and tools stay omitted;
  an explicit empty tool list stays present. Configuration must be nonempty and
  raw instruction sections remain digest-free. Unknown or malformed input
  returns error without consulting host defaults or a registry.
  """
  @spec decode_wire(term()) :: {:ok, map()} | :error
  def decode_wire(options)
      when is_map(options) and not is_struct(options) and map_size(options) in 1..3 do
    with true <- options["version"] === 1,
         true <- Map.keys(options) -- @keys == [],
         {:ok, decoded} <- configuration(options),
         true <- tools?(options) do
      {:ok, decoded}
    else
      _invalid -> :error
    end
  end

  def decode_wire(_options), do: :error

  defp configuration(options) do
    case Map.fetch(options, "configuration") do
      :error ->
        {:ok, options}

      {:ok, supplied} ->
        case ConfigureRequest.decode_changes(supplied) do
          {:ok, changes} -> {:ok, Map.put(options, "configuration", changes)}
          :error -> :error
        end
    end
  end

  defp tools?(options) do
    case Map.fetch(options, "tools") do
      :error -> true
      {:ok, tools} -> unique_tools?(tools, 0, MapSet.new())
    end
  end

  defp unique_tools?([], _count, _seen), do: true

  defp unique_tools?([name | rest], count, seen) when count < @max_tools do
    tool_name?(name) and not MapSet.member?(seen, name) and
      unique_tools?(rest, count + 1, MapSet.put(seen, name))
  end

  defp unique_tools?(_tools, _count, _seen), do: false

  defp tool_name?(name),
    do:
      is_binary(name) and byte_size(name) in 1..64 and
        Regex.match?(~r/\A[a-z][a-z0-9_]{0,63}\z/, name)
end
