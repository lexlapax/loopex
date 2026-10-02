defmodule RowEncoder do
  @moduledoc false

  def encode(values, _options \\ []) do
    Enum.map_join(values, ",", &value/1)
  end

  defp value(nil), do: raise(ArgumentError, "nil behavior must be chosen")
  defp value(value), do: to_string(value)
end
