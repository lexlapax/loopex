defmodule Checkout do
  @moduledoc false

  def quote(amount, fee), do: Invoice.total(amount, fee)
end
