defmodule LoopexCli.PlacementProbeTest do
  @moduledoc false

  use ExUnit.Case, async: false

  alias LoopexCli.Placement

  # Concept: the placement lock reads a helper that could not inspect the owner
  # as an owner it cannot examine, never as a dead one.
  #
  # Technical depth: `ps -p` exits 1 with no output when no process matches;
  # a diagnostic exit, or a status 1 that still printed, is reported as a
  # failed probe, and every reader of the owner record turns that into a
  # refusal that names the failure rather than a reclaimed lock.
  test "a probe that cannot inspect the owner is a failed probe, not absence" do
    assert {:error, {:process_probe_failed, {:exit_status, 2}}} =
             Placement.process_incarnation("1", probe_script("exit 2"))

    assert {:error, {:process_probe_failed, {:exit_status, 1}}} =
             Placement.process_incarnation("1", probe_script("echo diagnostic; exit 1"))

    assert {:error, :process_absent} = Placement.process_incarnation("1", probe_script("exit 1"))
    assert {:ok, identity} = Placement.process_incarnation(System.pid())
    assert is_binary(identity) and identity != ""
  end

  test "a lock whose owner cannot be probed is refused, not reclaimed" do
    root =
      Path.join(System.tmp_dir!(), "loopex-placement-probe-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)

    assert {:ok, handle} = Placement.acquire(root)
    assert :ok = Placement.release(handle)

    # Write an owner record for a process the failing probe cannot inspect.
    assert {:ok, handle} = Placement.acquire(root)
    bytes = File.read!(handle)

    failing = fn _pid -> {:error, {:process_probe_failed, {:exit_status, 2}}} end
    assert {:error, message} = Placement.acquire(root, failing)
    assert message =~ "could not be taken" and message =~ "process_probe_failed"
    assert File.read!(handle) == bytes, "a failed probe let the lock be rewritten"
    assert :ok = Placement.release(handle)
  end

  test "a probe that never answers is bounded and is not absence" do
    hanging = probe_script("sleep 30")
    started = System.monotonic_time(:millisecond)
    assert {:error, :process_probe_timeout} = Placement.process_incarnation("1", hanging)
    assert System.monotonic_time(:millisecond) - started < 15_000
  end

  defp probe_script(body) do
    file = Path.join(System.tmp_dir!(), "loopex-probe-#{System.unique_integer([:positive])}.sh")
    File.write!(file, "#!/bin/sh\n#{body}\n")
    File.chmod!(file, 0o755)
    on_exit(fn -> File.rm(file) end)
    file
  end
end
