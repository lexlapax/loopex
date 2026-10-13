Code.require_file("support/provider_build_fixture.exs", __DIR__)

defmodule Loopex.LLM.ReqLLM.ProviderBuildDeadlineTest do
  use ExUnit.Case, async: true

  # Concept: the companion build's deadline is a hard bound on the build and
  # everything it starts.
  # Technical depth: real shells stand in for the build. An expired run kills
  # and joins its whole process group, including a backgrounded descendant,
  # and a result arriving after the deadline is refused.

  alias Loopex.LLM.ReqLLM.ProviderBuildFixture, as: Fixture

  @environment %{"PATH" => "/usr/bin:/bin"}

  test "a run within its deadline returns its output and status" do
    deadline = System.monotonic_time(:millisecond) + 10_000

    assert {output, 3} =
             Fixture.run_bounded(
               ["/bin/sh", "-c", "echo built; exit 3"],
               "/",
               @environment,
               deadline
             )

    assert output =~ "built\n"
  end

  test "an expired run kills and joins its whole process group" do
    deadline = System.monotonic_time(:millisecond) + 300

    error =
      assert_raise RuntimeError, fn ->
        Fixture.run_bounded(
          ["/bin/sh", "-c", "/bin/sleep 30 & echo child:$!; wait"],
          "/",
          @environment,
          deadline
        )
      end

    assert error.message =~ "exceeded"
    [_, child] = Regex.run(~r/child:([0-9]+)/, error.message)
    assert {_, 1} = System.cmd("/bin/ps", ["-p", child, "-o", "pid="])
  end

  test "a success arriving after the deadline is refused" do
    # The deadline has passed before the immediately successful run is
    # collected, so its queued exit status must not be accepted.
    deadline = System.monotonic_time(:millisecond) - 1

    assert_raise RuntimeError, ~r/exceeded/, fn ->
      Fixture.run_bounded(["/bin/sh", "-c", "exit 0"], "/", @environment, deadline)
    end
  end
end
