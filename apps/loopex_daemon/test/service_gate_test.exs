defmodule LoopexDaemon.ServiceGateTest do
  use ExUnit.Case, async: true
  @moduletag capture_log: true

  alias LoopexComposition.Placement
  alias LoopexDaemon.Service

  # Concept: the daemon's owner acquires nothing until its command process
  # opens the gate; if that command dies first, the owner ends on its own
  # within five seconds, holding no lock, marker or socket.
  #
  # Technical depth: the owner is started with a complete option set and the
  # gate is never opened, as if the command process were killed between
  # starting it and sending `:go`. The owner exits normally at its five-second
  # gate deadline, and the root has no placement owner, Store marker or daemon
  # directory.
  #
  # The five seconds are the owner's own: `init/1` fixes `gate_deadline` five
  # seconds out and `handle_continue(:start, _)` waits for `:go` only until
  # then. With no `:go` sent, that expiry is the owner's only `:normal` exit,
  # so a `:normal` exit no earlier than five seconds after start proves it
  # waited the gate out and ended on it. How late a starved host then wakes the
  # owner is the scheduler's, not the product's: a floor-pair run with ten
  # suites at once saw 7.3 s. The 30 s wait only catches an owner that never
  # ends.
  test "an owner whose gate never opens ends within five seconds holding nothing" do
    root =
      Path.join(
        System.tmp_dir!(),
        "lsg-#{Loopex.TestTmp.Daemon.token()}"
      )

    workspace = Path.join(root, "w")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(root) end)
    state_root = Path.join(root, "s")

    started = System.monotonic_time(:millisecond)

    {:ok, owner} =
      Service.start(
        state_root: state_root,
        socket_path: Path.join([state_root, "daemon", "d.sock"]),
        workspace: workspace,
        policy: __MODULE__,
        credential: "service-gate-placeholder"
      )

    monitor = Process.monitor(owner)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :normal}, 30_000
    assert System.monotonic_time(:millisecond) - started >= 5_000

    assert Placement.live_owner(state_root) == :none
    refute File.exists?(Path.join(state_root, "store.log.writer"))
    refute File.exists?(Path.join(state_root, "daemon"))
  end
end
