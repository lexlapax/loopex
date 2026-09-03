defmodule Loopex.BoundsTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Loopex.Bounds

  defp declared(overrides) do
    {:ok, declared} =
      Bounds.declare(
        Map.merge(%{max_turns: 10, token_budget: 1_000, deadline_ms: 10_000}, overrides)
      )

    Map.put(declared, :deadline, Map.get(overrides, :deadline, 10_000))
  end

  defp decide(declared, overrides) do
    Bounds.decide(
      declared,
      Keyword.merge(
        [tool_calls: [%{tool_call_id: "a"}], turn_number: 1, tokens: 0, now: 0],
        overrides
      )
    )
  end

  test "a malformed declaration is refused rather than quietly completed" do
    # `declare/1` never substitutes for a bound it was given. The runtime supplies
    # defaults for a host that said nothing; this is what happens to a host that
    # said something wrong.
    assert {:error, :invalid_declared_bounds} = Bounds.declare(nil)
    assert {:error, :invalid_declared_bounds} = Bounds.declare(%{max_turns: 1, token_budget: 1})

    assert {:error, :invalid_declared_bounds} =
             Bounds.declare(%{max_turns: 0, token_budget: 1, deadline_ms: 1})

    assert {:error, :invalid_declared_bounds} =
             Bounds.declare(%{max_turns: 1, token_budget: -1, deadline_ms: 1})

    assert {:ok, %{max_turns: 3}} =
             Bounds.declare(%{max_turns: 3, token_budget: 5, deadline_ms: 7})
  end

  test "a model that stops asking for tools completes before any bound is consulted" do
    # Every bound is simultaneously exhausted, and the run still completes,
    # because the no-tool check is first and unconditional. A bound evaluated
    # afterwards has nothing left to decide.
    exhausted = declared(%{max_turns: 1, token_budget: 1, deadline_ms: 1})

    assert :completed =
             decide(exhausted, tool_calls: [], turn_number: 99, tokens: 10_000, now: 99_999)
  end

  test "each bound ends the run before another provider call" do
    assert {:bound_reached, :max_turns, 3} =
             decide(declared(%{max_turns: 3}), turn_number: 3)

    assert {:bound_reached, :token_budget, 1_000} =
             decide(declared(%{token_budget: 1_000}), tokens: 1_000)

    assert {:bound_reached, :deadline, 10_000} =
             decide(declared(%{deadline_ms: 10_000}), now: 10_000)

    # One below each limit still continues.
    assert :continue = decide(declared(%{max_turns: 3}), turn_number: 2)
    assert :continue = decide(declared(%{token_budget: 1_000}), tokens: 999)
    assert :continue = decide(declared(%{deadline_ms: 10_000}), now: 9_999)
  end

  test "bounds are consulted in a fixed order when more than one is reached" do
    # Turns before tokens before deadline: the reported bound must be stable
    # rather than depending on which check happened to run first.
    all = declared(%{max_turns: 1, token_budget: 1, deadline_ms: 1})

    assert {:bound_reached, :max_turns, _observed} =
             decide(all, turn_number: 1, tokens: 5, now: 5)

    tokens_and_deadline = declared(%{max_turns: 100, token_budget: 1, deadline_ms: 1})

    assert {:bound_reached, :token_budget, _observed} =
             decide(tokens_and_deadline, turn_number: 1, tokens: 5, now: 5)
  end

  test "reported provider usage is preferred and recorded as reported" do
    reply = %{usage: %{"input_tokens" => 100, "output_tokens" => 20}, text: "hi"}
    assert {120, :reported} = Bounds.charge(reply, "request bytes", 500)
  end

  test "a reply without usage is estimated conservatively" do
    reply = %{usage: %{}, text: String.duplicate("a", 30)}
    {charge, source} = Bounds.charge(reply, String.duplicate("b", 30), 500)

    assert source == :estimated
    # 30 bytes of request and 30 of reply, at one token per three bytes.
    assert charge == 20
  end

  test "a turn that produced no complete reply is charged its full output allowance" do
    # This deliberately over-charges. The alternative makes aborting every turn
    # the cheapest way to stay inside a budget.
    {charge, source} = Bounds.charge(nil, String.duplicate("b", 30), 500)

    assert source == :estimated
    assert charge == 10 + 500

    # A reply that is present but malformed is charged the same way rather than
    # being treated as free.
    assert {510, :estimated} = Bounds.charge(%{unexpected: true}, String.duplicate("b", 30), 500)
  end

  test "the estimator never returns fewer tokens than three bytes per token" do
    for size <- [0, 1, 2, 3, 4, 100, 1_000] do
      bytes = String.duplicate("x", size)
      estimate = Bounds.estimate(bytes)

      assert estimate >= div(size, 4), "estimate for #{size} bytes must not undercount"
      assert estimate == div(size + 2, 3)
    end

    assert Bounds.estimator() =~ "loopex."
  end

  test "the bound and source vocabularies are closed" do
    assert Bounds.bounds() == [:max_turns, :token_budget, :deadline]
    assert Bounds.sources() == [:reported, :estimated]
  end
end
