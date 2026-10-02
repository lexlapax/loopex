ExUnit.start()

defmodule LongConversationOracle do
  use ExUnit.Case

  test "the generated release retains the early prefix" do
    assert File.read!(Path.join(System.fetch_env!("M7_WORKSPACE"), "release.txt")) == "amber\n"
  end

  test "the batch retains the early prefix and exactly three entries" do
    assert File.read!(Path.join(System.fetch_env!("M7_WORKSPACE"), "batches.txt")) ==
             "amber-001\namber-002\namber-003\n"
  end
end
