defmodule Invoice do
  @moduledoc false

  def total(amount, fee), do: Fees.total(amount, fee)
end
