workspace = System.fetch_env!("M7_WORKSPACE")

for file <- ["fees.ex", "invoice.ex", "checkout.ex"],
    do: Code.require_file(Path.join([workspace, "lib", file]))

ExUnit.start()

defmodule ReviewOracle do
  use ExUnit.Case

  test "the pinned defect remains present in the read-only workspace" do
    assert Checkout.quote(1200, 75) == 1350
  end

  test "the structured finding names the exact defect and call chain" do
    finding = File.read!(System.fetch_env!("M7_FINDING"))
    assert byte_size(finding) <= 1024

    assert finding ==
             "file\tfunction\tdefect_code\tcall_chain\nlib/fees.ex\ttotal/2\tduplicate_fee\tCheckout.quote/2>Invoice.total/2>Fees.total/2\n"
  end
end
