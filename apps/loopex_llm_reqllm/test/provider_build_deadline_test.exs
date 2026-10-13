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

  test "an expired deadline starts nothing" do
    marker = Path.join(System.tmp_dir!(), "loopex-build-#{System.unique_integer([:positive])}")
    deadline = System.monotonic_time(:millisecond) - 1

    assert_raise RuntimeError, ~r/before it started/, fn ->
      Fixture.run_bounded(
        ["/bin/sh", "-c", "echo $$ > #{marker}; /bin/sleep 30 & wait"],
        "/",
        @environment,
        deadline
      )
    end

    refute File.exists?(marker)
  end

  test "a success arriving after the deadline is refused" do
    # The exit status is already queued when collection starts after the
    # deadline, so it must not be accepted.
    port = Fixture.open_group(["/bin/sh", "-c", "exit 0"], "/", @environment)
    Process.sleep(200)
    deadline = System.monotonic_time(:millisecond) - 1

    assert_raise RuntimeError, ~r/exceeded/, fn -> Fixture.collect(port, deadline, []) end
  end

  test "a group join succeeds only after its complete empty window" do
    # The group is already empty: a spent bound still fails the join, while
    # a live bound proves the 100 ms empty window first.
    {pid, 0} = System.cmd("/bin/sh", ["-c", "echo $$"])
    group = String.trim(pid)

    refute Fixture.kill_group(group, System.monotonic_time(:millisecond), nil)

    started = System.monotonic_time(:millisecond)
    assert Fixture.kill_group(group, started + 5_000, nil)
    assert System.monotonic_time(:millisecond) - started >= 100
  end

  test "expiry at any point after spawning leaves no owned process alive" do
    # Deadlines a few milliseconds ahead expire while the shell is starting,
    # forking or waiting. Each owned process records its own pid, and none of
    # the command's group may stay alive.
    for ahead <- 1..20 do
      pids = Path.join(System.tmp_dir!(), "loopex-build-#{System.unique_integer([:positive])}")
      deadline = System.monotonic_time(:millisecond) + ahead
      child = "echo $$ >> #{pids}; exec /bin/sleep 30"

      assert_raise RuntimeError, ~r/exceeded/, fn ->
        Fixture.run_bounded(
          ["/bin/sh", "-c", "echo $$ > #{pids}; /bin/sh -c '#{child}' & wait"],
          "/",
          @environment,
          deadline
        )
      end

      owned = if File.exists?(pids), do: String.split(File.read!(pids)), else: []
      File.rm(pids)
      {table, 0} = System.cmd("/bin/ps", ["-axo", "pid=,pgid=,stat="])

      live =
        for row <- String.split(table, "\n", trim: true),
            [pid, pgid, state] = String.split(row),
            not String.starts_with?(state, "Z"),
            pid in owned or pgid in Enum.take(owned, 1),
            do: row

      assert live == []
    end
  end
end
