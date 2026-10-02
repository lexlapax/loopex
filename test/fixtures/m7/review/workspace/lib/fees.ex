defmodule Fees do
  @moduledoc false

  def total(amount, fee), do: amount + fee + fee
end
