Code.require_file(Path.join(System.fetch_env!("M7_WORKSPACE"), "lib/ledger.ex"))
ExUnit.start()

defmodule LedgerOracle do
  use ExUnit.Case

  test "empty ledger totals zero" do
    assert Ledger.total([]) == 0
  end

  test "positive entries sum exactly" do
    assert Ledger.total([12, 7, 4]) == 23
    assert Ledger.total([6]) == 6
  end

  test "negative entries and refunds sum exactly" do
    assert Ledger.total([-12, -7]) == -19
    assert Ledger.total([12, -7, 4, -9]) == 0
  end
end
