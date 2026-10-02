defmodule Ledger do
  @moduledoc false

  def total(entries), do: Enum.reduce(entries, &+/2)
end
