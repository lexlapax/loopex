defmodule LoopexComposition.PlacementProbeTest do
  @moduledoc false

  use ExUnit.Case, async: false

  alias LoopexComposition.Placement

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

    assert {:error, {:placement_lock_failed, {:guard_failed, reason}}} =
             Placement.acquire(root, failing)

    assert inspect(reason) =~ "process_probe_failed"
    assert File.read!(handle) == bytes, "a failed probe let the lock be rewritten"
    assert :ok = Placement.release(handle)
  end

  test "a probe that never answers is bounded and is not absence" do
    hanging = probe_script("sleep 30")
    started = System.monotonic_time(:millisecond)
    assert {:error, :process_probe_timeout} = Placement.process_incarnation("1", hanging)
    assert System.monotonic_time(:millisecond) - started < 15_000
  end

  test "acquisition, inspection and release probes remove the captured credential names" do
    names = Enum.sort(["LOOPEX_PROVIDER_API_KEY", "M7_PLACEMENT_A", "M7_PLACEMENT_B"])
    prior = Map.new(names, &{&1, System.get_env(&1)})

    on_exit(fn ->
      for {name, value} <- prior do
        if value, do: System.put_env(name, value), else: System.delete_env(name)
      end
    end)

    checks = Enum.map_join(names, "\n", &"[ \"${#{&1}+x}\" != x ] || exit 42")

    script =
      probe_script(checks <> "\n[ \"$LC_ALL\" = C ] || exit 43\nprintf fixture-incarnation\n")

    probe = fn pid -> Placement.process_incarnation(pid, script, names) end

    root =
      Path.join(
        System.tmp_dir!(),
        "loopex-placement-exclusions-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf(root) end)
    Enum.each(names, &System.put_env(&1, "synthetic-placement-secret"))

    assert {:ok, handle} = Placement.acquire(root, probe)
    assert {:ok, pid} = Placement.live_owner(root, probe)
    assert pid == System.pid()
    assert :ok = Placement.release(handle, probe)
    assert :none = Placement.live_owner(root, probe)
    assert Enum.all?(names, &(System.get_env(&1) == "synthetic-placement-secret"))

    assert {:error, :invalid_credential_exclusions} =
             Placement.process_incarnation(System.pid(), script, [
               "HOME",
               "LOOPEX_PROVIDER_API_KEY"
             ])
  end

  defp probe_script(body) do
    file = Path.join(System.tmp_dir!(), "loopex-probe-#{System.unique_integer([:positive])}.sh")
    File.write!(file, "#!/bin/sh\n#{body}\n")
    File.chmod!(file, 0o755)
    on_exit(fn -> File.rm(file) end)
    file
  end
end
