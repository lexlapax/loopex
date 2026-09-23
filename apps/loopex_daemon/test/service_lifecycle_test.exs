Code.require_file("support/daemon_socket_fixture.exs", __DIR__)

defmodule LoopexDaemon.ServiceLifecycleTest do
  use ExUnit.Case, async: false
  @moduletag capture_log: true

  import LoopexDaemon.Test.DaemonSocketFixture, only: [send_frame: 2, receive_records: 2]

  alias LoopexComposition.Placement
  alias LoopexDaemon.Sentinel
  alias LoopexProtocol.{Session.V2, Wire}

  defmodule DenyPolicy do
    @moduledoc false
    @behaviour Loopex.Policy

    @impl Loopex.Policy
    def decide(_request), do: {:deny, :policy_denied}
  end

  setup do
    root = Path.join(System.tmp_dir!(), "ldl-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "w")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(root) end)
    state_root = Path.join(root, "s")

    options = [
      state_root: state_root,
      socket_path: Path.join([state_root, "daemon", "d.sock"]),
      workspace: workspace,
      policy: DenyPolicy,
      credential: "service-lifecycle-placeholder",
      admission_wait_ms: 200
    ]

    %{options: options, state_root: state_root}
  end

  # Concept: every Store refusal at open reaches the operator as its own exit
  # class, whatever arity the Store's refusal carries.
  test "each Store open refusal shape names its exit class" do
    for {reason, class} <- [
          {{:store_writer_active, "/r/store.log.writer"}, :store_writer_active},
          {{:store_writer_unverifiable, "/r/store.log.writer", :malformed},
           :store_writer_unverifiable},
          {{:store_log_too_large, 300, 200}, :store_log_too_large},
          {{:store_writer_lock_failed, :eacces}, :store_writer_acquisition_failed},
          {{:store_writer_lock_close_failed, :eio}, :store_writer_acquisition_failed},
          {{:store_writer_recovery_failed, :eperm}, :store_writer_acquisition_failed},
          {{:store_writer_identity_unavailable, :timeout}, :store_writer_acquisition_failed},
          {:store_writer_active, :store_writer_active},
          {{:store_corrupt, 12}, nil},
          {:unexpected, nil}
        ] do
      assert LoopexDaemon.ExitStatus.store_open_class(reason) == class, inspect(reason)
    end
  end

  test "a ready daemon serves a client and an orderly stop releases every exclusion",
       %{options: options, state_root: state_root} do
    daemon = start_daemon(options)
    ready = await_ready(daemon.output)

    assert ready["record"] == "daemon_ready"
    assert ready["root"] == state_root
    assert ready["socket"] == options[:socket_path]
    assert ready["version"] == "0.2.0"

    # Custody holds the one copy of the credential; the owner keeps none.
    refute Keyword.has_key?(:sys.get_state(daemon.owner).options, :credential)

    client = initialized(options[:socket_path])

    :ok =
      send_frame(client, %{
        "method" => "session.create",
        "request_id" => "create",
        "command_id" => Wire.encode_identity("lifecycle-create"),
        "session_options" => %{"purpose" => "lifecycle"}
      })

    assert [%{"status" => "accepted", "session_id" => encoded}] = receive_records(client, 1)
    {:ok, session_id} = Wire.identity(encoded)

    send(daemon.sentinel, {:daemon_signal, daemon.owner_ref, :sigterm})

    assert [%{"type" => "daemon.stopping", "reason" => "operator_stop"}] =
             receive_records(client, 1)

    assert Task.await(daemon.task, 30_000) == 0
    assert {:ok, %File.Stat{type: :other}} = File.lstat(options[:socket_path])
    assert Placement.live_owner(state_root) == :none

    {:ok, adapter} = Loopex.Store.Local.start_link(path: Path.join(state_root, "store.log"))
    {:ok, store} = Loopex.Store.new(Loopex.Store.Local, adapter)
    {:ok, placement} = Loopex.runtime_placement_id(state_root)

    {:ok, runtime} =
      Loopex.start_link(runtime_id: placement, store: store, context_token_budget: 8_192)

    assert {:ok, :present} = Loopex.Runtime.session_existence(runtime, session_id)
    :ok = Loopex.stop(runtime)
    :ok = GenServer.stop(adapter)
  end

  # Concept: losing the listener after readiness is a daemon failure: the
  # daemon tells every connected client why it is stopping and ends with the
  # listener's own exit class.
  #
  # Technical depth: the listener the service started is killed while an
  # initialized client is connected. The client receives `daemon.stopping`
  # with `fatal:listener_lost` and the sentinel exits `listener_lost` (107).
  # Concept: a Store that stops because its journal reached capacity ends the
  # daemon with that class, telling every client why, distinct from any other
  # Store loss.
  #
  # Technical depth: the Store stops with `{:store_capacity_exceeded, max}`,
  # the reason its append-failure branch stops with when the log refuses an
  # append past its ceiling, which `log_capacity_test.exs` proves. A connected
  # client receives `daemon.stopping` with `store_capacity_exceeded` and the
  # sentinel exits `store_capacity_exceeded`.
  test "a Store stopped at capacity fail-stops with store_capacity_exceeded",
       %{options: options} do
    daemon = start_daemon(options)
    _ready = await_ready(daemon.output)
    client = initialized(options[:socket_path])

    store = :sys.get_state(daemon.owner).pids.store
    # The Store traps exits, so it is stopped with the reason itself, as its
    # append path's `{:stop, reason, ...}` does.
    spawn(fn -> GenServer.stop(store, {:store_capacity_exceeded, 268_435_456}, 5_000) end)

    assert [%{"type" => "daemon.stopping", "reason" => "store_capacity_exceeded"}] =
             receive_records(client, 1)

    {:ok, capacity} = LoopexDaemon.ExitStatus.fetch(:store_capacity_exceeded)
    assert Task.await(daemon.task, 40_000) == capacity
  end

  test "losing the listener after readiness fail-stops with listener_lost",
       %{options: options, state_root: state_root} do
    daemon = start_daemon(options)
    _ready = await_ready(daemon.output)
    client = initialized(options[:socket_path])

    listener = :sys.get_state(daemon.owner).pids.listener
    Process.exit(listener, :kill)

    assert [%{"type" => "daemon.stopping", "reason" => "fatal:listener_lost"}] =
             receive_records(client, 1)

    {:ok, listener_lost} = LoopexDaemon.ExitStatus.fetch(:listener_lost)
    assert Task.await(daemon.task, 60_000) == listener_lost

    # A fail-stop leaves the host placement lock to the daemon process's own
    # exit; here that process is this test's VM, which still holds it.
    assert {:ok, _holder} = Placement.live_owner(state_root)
  end

  # Concept: the socket's privacy is verified, never repaired: a daemon
  # directory that others can read refuses the start by its class and binds
  # nothing, while an ordinary `0755` state root is accepted because the daemon
  # owns only its own `0700` subdirectory.
  test "a permissive daemon directory refuses the start and a 0755 root is accepted",
       %{options: options, state_root: state_root} do
    File.mkdir_p!(Path.join(state_root, "daemon"))
    File.chmod!(state_root, 0o755)
    File.chmod!(Path.join(state_root, "daemon"), 0o755)

    {:ok, unverified} = LoopexDaemon.ExitStatus.fetch(:socket_permission_unverified)
    {:ok, output} = StringIO.open("")
    assert Sentinel.run(options, output: output, install_signals: false) == unverified
    assert StringIO.contents(output) == {"", ""}
    refute File.exists?(options[:socket_path])
    assert File.stat!(Path.join(state_root, "daemon")).mode |> Bitwise.band(0o777) == 0o755
    assert Placement.live_owner(state_root) == :none
    refute File.exists?(Path.join(state_root, "store.log.writer"))

    File.chmod!(Path.join(state_root, "daemon"), 0o700)
    daemon = start_daemon(options)
    ready = await_ready(daemon.output)
    assert ready["socket"] == options[:socket_path]
    assert File.stat!(state_root).mode |> Bitwise.band(0o777) == 0o755
    send(daemon.sentinel, {:daemon_signal, daemon.owner_ref, :sigterm})
    assert Task.await(daemon.task, 30_000) == 0
  end

  # Concept: the listener must still be alive when the daemon is released to
  # accept; one that dies while readiness is being written ends the start as
  # `listener_start_failed`, and no client is ever accepted.
  #
  # Technical depth: the sentinel's output device holds the readiness write
  # until the test has killed the parked listener, then lets it complete. The
  # owner's recheck after the write finds the listener gone, so the gate never
  # opens: the sentinel exits `listener_start_failed` and nothing accepts on the
  # socket path.
  test "a listener lost while readiness is written ends the start listener_start_failed",
       %{options: options} do
    test = self()
    device = spawn_link(fn -> holding_device(test) end)
    sentinel_test = self()

    task =
      Task.async(fn ->
        Sentinel.run(options, output: device, install_signals: false, notify: sentinel_test)
      end)

    assert_receive {:readiness_held, writer}, 30_000

    # This daemon's own listener, started by its owner: another case's
    # listener may still be alive in the same VM, and the owner is busy in
    # startup, so the listener is found by its ancestry.
    assert_receive {:loopex_daemon_sentinel, _sentinel, _owner_ref, owner}, 5_000

    [listener] =
      for pid <- Process.list(),
          {:dictionary, dictionary} <- [Process.info(pid, :dictionary)],
          dictionary[:"$initial_call"] == {LoopexDaemon.Listener, :init, 1},
          owner in Keyword.get(dictionary, :"$ancestors", []),
          do: pid

    Process.exit(listener, :kill)
    send(writer, :release_write)

    {:ok, failed} = LoopexDaemon.ExitStatus.fetch(:listener_start_failed)
    assert Task.await(task, 60_000) == failed

    assert {:error, _refused} =
             :gen_tcp.connect({:local, options[:socket_path]}, 0, [:binary], 500)
  end

  defp holding_device(test) do
    receive do
      {:io_request, from, reply_as, {:put_chars, _encoding, _chars}} ->
        send(test, {:readiness_held, self()})

        receive do
          :release_write -> :ok
        end

        send(from, {:io_reply, reply_as, :ok})
        holding_device(test)

      {:io_request, from, reply_as, _request} ->
        send(from, {:io_reply, reply_as, {:error, :request}})
        holding_device(test)
    end
  end

  # Concept: a state root that cannot even be created refuses at the first
  # acquisition, the placement lock, and leaves nothing behind.
  test "a root that cannot be created refuses placement_lock_failed", %{options: options} do
    blocker = Path.join(Path.dirname(options[:state_root]), "a-file")
    File.write!(blocker, "not a directory")
    root = Path.join(blocker, "s")

    options =
      Keyword.merge(options,
        state_root: root,
        socket_path: Path.join([root, "daemon", "d.sock"])
      )

    {:ok, failed} = LoopexDaemon.ExitStatus.fetch(:placement_lock_failed)
    {:ok, output} = StringIO.open("")
    assert Sentinel.run(options, output: output, install_signals: false) == failed
    assert StringIO.contents(output) == {"", ""}
    assert File.read!(blocker) == "not a directory"
  end

  # Concept: two daemons started at the same moment on one root produce one
  # daemon: exactly one reaches readiness and the other loses at the
  # placement lock without disturbing it.
  test "simultaneous starts on one root yield exactly one daemon", %{options: options} do
    parent = self()

    starts =
      for index <- 1..2 do
        Task.async(fn ->
          {:ok, output} = StringIO.open("")

          status =
            Sentinel.run(options, output: output, install_signals: false, notify: parent)

          {index, status, StringIO.contents(output)}
        end)
      end

    {:ok, active} = LoopexDaemon.ExitStatus.fetch(:placement_active)

    # The loser ends on its own; the winner is stopped once the loser has.
    {loser, [winner]} =
      case Task.yield_many(starts, 30_000) |> Enum.split_with(fn {_task, result} -> result end) do
        {[{_task, {:ok, result}}], [{task, nil}]} -> {result, [task]}
      end

    assert {_index, ^active, {"", ""}} = loser

    # Both sentinels announced themselves; the stop reaches whichever is live.
    for _announced <- 1..2 do
      assert_receive {:loopex_daemon_sentinel, sentinel, owner_ref, _owner}, 1_000
      send(sentinel, {:daemon_signal, owner_ref, :sigterm})
    end

    assert {_index, 0, {"", readiness}} = Task.await(winner, 30_000)
    assert readiness =~ ~s("record":"daemon_ready")
  end

  test "a second daemon on a held root loses at the placement lock",
       %{options: options} do
    first = start_daemon(options)
    _ready = await_ready(first.output)
    {:ok, before} = File.lstat(options[:socket_path])

    {:ok, placement_active} = LoopexDaemon.ExitStatus.fetch(:placement_active)
    {:ok, output} = StringIO.open("")
    assert Sentinel.run(options, output: output, install_signals: false) == placement_active
    assert StringIO.contents(output) == {"", ""}
    assert {:ok, ^before} = File.lstat(options[:socket_path])

    send(first.sentinel, {:daemon_signal, first.owner_ref, :sigterm})
    assert Task.await(first.task, 30_000) == 0
  end

  test "a stop before readiness exits zero holding nothing", %{
    options: options,
    state_root: state_root
  } do
    {:ok, output} = StringIO.open("")
    test = self()

    task =
      Task.async(fn ->
        Sentinel.run(options,
          output: output,
          install_signals: false,
          notify: test
        )
      end)

    assert_receive {:loopex_daemon_sentinel, sentinel, owner_ref, _owner}, 1_000
    send(sentinel, {:daemon_signal, owner_ref, :sigterm})

    status = Task.await(task, 30_000)
    assert status == 0
    assert Placement.live_owner(state_root) == :none
  end

  @tag timeout: 90_000
  test "a relay that stops answering stop barriers ends the stop as relay_lost",
       %{options: options} do
    daemon = start_daemon(options)
    _ready = await_ready(daemon.output)
    client = initialized(options[:socket_path])

    collaboration = :sys.get_state(daemon.owner).pids.collaboration
    relay = LoopexDaemon.Owner.components(collaboration).relay
    :ok = :sys.suspend(relay)

    started = System.monotonic_time(:millisecond)
    send(daemon.sentinel, {:daemon_signal, daemon.owner_ref, :sigterm})

    {:ok, relay_lost} = LoopexDaemon.ExitStatus.fetch(:relay_lost)
    assert Task.await(daemon.task, 60_000) == relay_lost
    assert System.monotonic_time(:millisecond) - started < 45_000

    # The relay is killed as fatal teardown, so the registry survives it and
    # the client learns why.
    assert [%{"type" => "daemon.stopping", "reason" => "fatal:relay_lost"}] =
             receive_records(client, 1)

    on_exit(fn -> Process.exit(collaboration, :kill) end)
  end

  # Concept: the transport cut is one five-second deadline begun before the
  # relay cut. A registry that never answers its gate ends the stop as
  # `connections_lost` at that deadline, not as `relay_lost` and not after a
  # fresh clock.
  #
  # Technical depth: the registry is suspended before `SIGTERM`, so the relay
  # acknowledges the cut and the gate request waits out the shared instant.
  # The exit class separates this from a relay that missed the cut; the
  # shared-deadline case below proves the gate waits on the cut's own clock.
  @tag timeout: 90_000
  test "a registry that misses the transport gate ends the stop as connections_lost",
       %{options: options} do
    daemon = start_daemon(options)
    _ready = await_ready(daemon.output)
    _client = initialized(options[:socket_path])

    collaboration = :sys.get_state(daemon.owner).pids.collaboration
    registry = LoopexDaemon.Owner.components(collaboration).registry
    :ok = :sys.suspend(registry)

    started = System.monotonic_time(:millisecond)
    send(daemon.sentinel, {:daemon_signal, daemon.owner_ref, :sigterm})

    {:ok, connections_lost} = LoopexDaemon.ExitStatus.fetch(:connections_lost)
    assert Task.await(daemon.task, 60_000) == connections_lost
    elapsed = System.monotonic_time(:millisecond) - started
    assert elapsed >= 4_900
    assert elapsed < 15_000
  end

  # Concept: the relay acknowledgement and the registry gate share one clock.
  # A relay that answers late leaves the registry only what remains of the
  # five seconds, never a fresh five.
  #
  # Technical depth: the relay is held for about three seconds and the
  # registry throughout. The collaboration owner kills the registry when the
  # shared deadline passes, which closes every client socket, so the socket's
  # close time is the owner's decision time: about five seconds after
  # `SIGTERM`, where a gate given its own five seconds would close at about
  # eight.
  @tag timeout: 90_000
  test "a late relay leaves the registry gate only the rest of the shared deadline",
       %{options: options} do
    daemon = start_daemon(options)
    _ready = await_ready(daemon.output)
    client = initialized(options[:socket_path])

    collaboration = :sys.get_state(daemon.owner).pids.collaboration
    components = LoopexDaemon.Owner.components(collaboration)
    :ok = :sys.suspend(components.relay)
    :ok = :sys.suspend(components.registry)

    started = System.monotonic_time(:millisecond)
    send(daemon.sentinel, {:daemon_signal, daemon.owner_ref, :sigterm})
    Process.sleep(3_000)
    :ok = :sys.resume(components.relay)

    assert :closed = await_socket_closed(client, 15_000)
    closed = System.monotonic_time(:millisecond) - started
    assert closed >= 4_900
    assert closed < 6_500

    {:ok, connections_lost} = LoopexDaemon.ExitStatus.fetch(:connections_lost)
    assert Task.await(daemon.task, 60_000) == connections_lost
  end

  # Concept: the uninitialized-peer sweep is part of the transport cut. A peer
  # the registry cannot close by the cut deadline ends the stop as
  # `connections_lost`; the stop never reaches core quiesce with the sweep
  # unproved.
  #
  # Technical depth: a raw peer connects and never initializes; its connection
  # process is suspended, so the sweep's abort is never acted on and the
  # registry never acknowledges an empty set. The gate and listener reap
  # succeed, which leaves the sweep as the only missing acknowledgement.
  @tag timeout: 90_000
  test "an uninitialized peer the sweep cannot close ends the stop as connections_lost",
       %{options: options} do
    daemon = start_daemon(options)
    _ready = await_ready(daemon.output)
    _client = initialized(options[:socket_path])

    {:ok, peer} = :socket.open(:local, :stream, :default)
    :ok = await_connect(peer, options[:socket_path], 100)

    collaboration = :sys.get_state(daemon.owner).pids.collaboration
    registry = LoopexDaemon.Owner.components(collaboration).registry
    connection = await_uninitialized_connection(registry)
    :ok = :sys.suspend(connection)

    started = System.monotonic_time(:millisecond)
    send(daemon.sentinel, {:daemon_signal, daemon.owner_ref, :sigterm})

    {:ok, connections_lost} = LoopexDaemon.ExitStatus.fetch(:connections_lost)
    assert Task.await(daemon.task, 60_000) == connections_lost
    elapsed = System.monotonic_time(:millisecond) - started
    assert elapsed >= 4_900
    assert elapsed < 15_000
    :socket.close(peer)
  end

  # Concept: only the listener's exact linked exit proves no later accept, and
  # it must arrive inside the transport cut; a missing exit is
  # `listener_lost`.
  #
  # Technical depth: the owner's listener entry is swapped for an unlinked
  # decoy, so the kill the stop sends produces no linked exit and the wait
  # reaches the shared deadline. The real listener is left running until the
  # fail-stop teardown, as it would be if its exit were lost.
  @tag timeout: 90_000
  test "a listener exit missing at the transport cut ends the stop as listener_lost",
       %{options: options} do
    daemon = start_daemon(options)
    _ready = await_ready(daemon.output)
    _client = initialized(options[:socket_path])

    decoy = spawn(fn -> Process.sleep(:infinity) end)
    listener = :sys.get_state(daemon.owner).pids.listener

    :sys.replace_state(daemon.owner, fn state ->
      listener = state.pids.listener

      %{
        state
        | pids: Map.put(state.pids, :listener, decoy),
          components:
            state.components
            |> Map.delete({:pid, listener})
            |> Map.put({:pid, decoy}, :listener)
      }
    end)

    started = System.monotonic_time(:millisecond)
    send(daemon.sentinel, {:daemon_signal, daemon.owner_ref, :sigterm})

    {:ok, listener_lost} = LoopexDaemon.ExitStatus.fetch(:listener_lost)
    assert Task.await(daemon.task, 60_000) == listener_lost
    elapsed = System.monotonic_time(:millisecond) - started
    assert elapsed >= 4_900
    assert elapsed < 15_000
    refute Process.alive?(decoy)

    # The untracked real listener is not stopped by the fail-stop teardown.
    Process.exit(listener, :kill)
  end

  # Concept: a lease freeze left with unfinished registry work ends the stop
  # as `connections_lost`, not `relay_lost`, and core quiesce never starts.
  #
  # Technical depth: a client holds a session's lease. The collaboration
  # owner is parked by a debug hook as the freeze call reaches it; while
  # parked the registry is suspended and the lease owner killed, so after the
  # freeze is acknowledged the lost owner's mirror pop waits on the registry
  # through the five-second freeze deadline.
  @tag timeout: 90_000
  test "a freeze left with unfinished registry work ends the stop as connections_lost",
       %{options: options} do
    daemon = start_daemon(options)
    _ready = await_ready(daemon.output)
    client = initialized(options[:socket_path])

    :ok =
      send_frame(client, %{
        "method" => "session.create",
        "request_id" => "create",
        "command_id" => Wire.encode_identity("freeze-create"),
        "session_options" => %{"purpose" => "freeze"}
      })

    assert [%{"status" => "accepted", "session_id" => encoded}] = receive_records(client, 1)

    :ok =
      send_frame(client, %{
        "method" => "session.acquire_control",
        "request_id" => "acquire",
        "session_id" => encoded
      })

    assert [%{"request_id" => "acquire", "type" => "result"}] = receive_records(client, 1)
    collaboration = :sys.get_state(daemon.owner).pids.collaboration
    registry = LoopexDaemon.Owner.components(collaboration).registry
    [lease_owner] = for {_session_id, row} <- :sys.get_state(collaboration).owners, do: row.pid
    test_pid = self()

    :ok =
      :sys.install(
        collaboration,
        {fn
           :waiting,
           {:in, {:"$gen_call", _from, {:relay_barrier, {:freeze_lease_ops, _}, _}}},
           _state ->
             send(test_pid, :freeze_parked)

             receive do
               :continue_freeze -> :done
             end

           :waiting, _event, _state ->
             :waiting
         end, :waiting}
      )

    send(daemon.sentinel, {:daemon_signal, daemon.owner_ref, :sigterm})
    assert_receive :freeze_parked, 10_000
    :ok = :sys.suspend(registry)
    lease_owner_monitor = Process.monitor(lease_owner)
    Process.exit(lease_owner, :kill)
    assert_receive {:DOWN, ^lease_owner_monitor, :process, ^lease_owner, :killed}, 500
    # The owner's exit must already be queued behind the parked freeze call.
    assert :ok = await_queued_exit(collaboration, lease_owner)
    send(collaboration, :continue_freeze)

    {:ok, connections_lost} = LoopexDaemon.ExitStatus.fetch(:connections_lost)
    assert Task.await(daemon.task, 60_000) == connections_lost
  end

  # Concept: a fail-stop cannot be held open by a silent registry: the
  # executor and a live Store are still stopped, each inside its bound, well
  # before the sentinel's 35-second halt.
  #
  # Technical depth: the registry is suspended, then the session index is
  # killed. The owner only messages the registry, so it goes straight on to
  # stop the live executor and the healthy Store; both end with an ordinary
  # stop rather than a kill, and the daemon reports `session_index_lost`
  # within seconds.
  @tag timeout: 90_000
  test "a silent registry cannot keep a fail-stop from stopping the executor and Store",
       %{options: options} do
    daemon = start_daemon(options)
    _ready = await_ready(daemon.output)
    _client = initialized(options[:socket_path])

    owner_state = :sys.get_state(daemon.owner)
    executor = owner_state.pids.executor
    store = owner_state.pids.store
    executor_monitor = Process.monitor(executor)
    store_monitor = Process.monitor(store)
    :ok = :sys.suspend(owner_state.registry)

    # A fail-stop leaves the collaboration owner for the VM halt, which a test
    # VM never performs.
    on_exit(fn ->
      Process.exit(owner_state.registry, :kill)
      Process.exit(owner_state.pids.collaboration, :kill)
    end)

    started = System.monotonic_time(:millisecond)
    Process.exit(owner_state.pids.index, :kill)

    assert_receive {:DOWN, ^executor_monitor, :process, ^executor, executor_reason}, 10_000
    assert_receive {:DOWN, ^store_monitor, :process, ^store, store_reason}, 10_000
    refute executor_reason == :killed
    refute store_reason == :killed

    {:ok, session_index_lost} = LoopexDaemon.ExitStatus.fetch(:session_index_lost)
    assert Task.await(daemon.task, 60_000) == session_index_lost
    assert System.monotonic_time(:millisecond) - started < 10_000
    refute Process.alive?(owner_state.relay)
  end

  # Concept: the session index is a linked running component, so losing it is
  # a daemon failure with its own class rather than a daemon that stays ready
  # while every create, list and status request fails.
  #
  # Technical depth: the index the service started is killed while an
  # initialized client is connected. The client receives `daemon.stopping`
  # with `fatal:session_index_lost` and the sentinel exits
  # `session_index_lost` (111).
  test "losing the session index fail-stops with session_index_lost",
       %{options: options} do
    daemon = start_daemon(options)
    _ready = await_ready(daemon.output)
    client = initialized(options[:socket_path])

    index = :sys.get_state(daemon.owner).pids.index
    Process.exit(index, :kill)

    assert [%{"type" => "daemon.stopping", "reason" => "fatal:session_index_lost"}] =
             receive_records(client, 1)

    {:ok, session_index_lost} = LoopexDaemon.ExitStatus.fetch(:session_index_lost)
    assert session_index_lost == 111
    assert Task.await(daemon.task, 60_000) == session_index_lost
  end

  test "losing the Store fail-stops with its class and tells the client",
       %{options: options} do
    daemon = start_daemon(options)
    _ready = await_ready(daemon.output)
    client = initialized(options[:socket_path])

    store = :sys.get_state(daemon.owner).pids.store
    Process.exit(store, :kill)

    assert [%{"type" => "daemon.stopping", "reason" => "store_lost"}] =
             receive_records(client, 1)

    {:ok, store_lost} = LoopexDaemon.ExitStatus.fetch(:store_lost)
    assert Task.await(daemon.task, 40_000) == store_lost
  end

  # Concept: the daemon's routes are bound to the runtime's exact Control and
  # EventDispatcher, so losing either while serving fail-stops `runtime_lost`
  # and tells the client.
  #
  # Technical depth: each case kills one exact runtime child. The runtime's own
  # supervisor would restart it, so only the daemon's monitor can notice; the
  # client receives `daemon.stopping` naming `fatal:runtime_lost` and the
  # daemon exits with that class. A fail-stop keeps host placement until the
  # process halts, so a successor is proved by a separate operating-system
  # process in `apps/loopex_cli/test/daemon_command_test.exs`, not here.
  for child <- [:control, :dispatcher] do
    test "losing the runtime's #{child} fail-stops runtime_lost",
         %{options: options} do
      daemon = start_daemon(options)
      _ready = await_ready(daemon.output)
      client = initialized(options[:socket_path])

      {:ok, children} = Loopex.Runtime.children(:sys.get_state(daemon.owner).edges.runtime)
      Process.exit(Map.fetch!(children, unquote(child)), :kill)

      assert [%{"type" => "daemon.stopping", "reason" => "fatal:runtime_lost"}] =
               receive_records(client, 1)

      {:ok, runtime_lost} = LoopexDaemon.ExitStatus.fetch(:runtime_lost)
      assert Task.await(daemon.task, 40_000) == runtime_lost
    end
  end

  # Concept: a component lost while an orderly stop drains ends the stop with
  # that component's class; the stop never reports success.
  #
  # Technical depth: the runtime's Control is suspended so core quiesce blocks
  # inside the owner's unlinked helper; once the owner is waiting on that
  # helper, the Store or the EventDispatcher is killed. The owner consumes the
  # exit or monitor at once, kills the helper and exits with `store_lost` or
  # `runtime_lost`, and the client hears that class rather than
  # `operator_stop`.
  for {target, class, reason} <- [
        {:store, :store_lost, "store_lost"},
        {:dispatcher, :runtime_lost, "fatal:runtime_lost"}
      ] do
    test "losing the #{target} while quiesce drains ends the stop as #{class}",
         %{options: options} do
      daemon = start_daemon(options)
      _ready = await_ready(daemon.output)
      client = initialized(options[:socket_path])
      owner_state = :sys.get_state(daemon.owner)
      {:ok, children} = Loopex.Runtime.children(owner_state.edges.runtime)
      :ok = :sys.suspend(children.control)

      send(daemon.sentinel, {:daemon_signal, daemon.owner_ref, :sigterm})
      assert await_quiesce_wait(daemon.owner)

      victim =
        case unquote(target) do
          :store -> owner_state.pids.store
          :dispatcher -> children.dispatcher
        end

      Process.exit(victim, :kill)

      {:ok, status} = LoopexDaemon.ExitStatus.fetch(unquote(class))
      assert Task.await(daemon.task, 40_000) == status

      assert [%{"type" => "daemon.stopping", "reason" => unquote(reason)}] =
               receive_records(client, 1)
    end
  end

  # The owner is waiting on core quiesce: it is inside the shared stop wait,
  # called from the quiesce step rather than from a transport-cut step.
  defp await_quiesce_wait(pid, attempts \\ 500)

  defp await_quiesce_wait(pid, attempts) when attempts > 0 do
    {:current_function, current} = Process.info(pid, :current_function)
    {:current_stacktrace, stack} = Process.info(pid, :current_stacktrace)

    quiescing =
      Enum.any?(stack, &match?({LoopexDaemon.Service, :quiesce_responsive, 1, _}, &1))

    if current == {LoopexDaemon.Service, :await_responsive, 4} and quiescing do
      true
    else
      Process.sleep(10)
      await_quiesce_wait(pid, attempts - 1)
    end
  end

  defp await_quiesce_wait(_pid, 0), do: false

  defp await_queued_exit(pid, exited, attempts \\ 100)

  defp await_queued_exit(pid, exited, attempts) when attempts > 0 do
    {:messages, messages} = Process.info(pid, :messages)

    if Enum.any?(messages, &match?({:EXIT, ^exited, _reason}, &1)) do
      :ok
    else
      Process.sleep(5)
      await_queued_exit(pid, exited, attempts - 1)
    end
  end

  defp await_queued_exit(_pid, _exited, 0), do: {:error, :not_queued}

  defp await_uninitialized_connection(registry, attempts \\ 500)

  defp await_uninitialized_connection(registry, attempts) when attempts > 0 do
    uninitialized =
      for {_token, %{initialized: false, connection_pid: pid}} <- :sys.get_state(registry).rows,
          is_pid(pid),
          do: pid

    case uninitialized do
      [connection] ->
        connection

      _none ->
        Process.sleep(10)
        await_uninitialized_connection(registry, attempts - 1)
    end
  end

  defp await_uninitialized_connection(_registry, 0),
    do: flunk("no uninitialized connection appeared")

  defp await_socket_closed(socket, timeout) do
    case :socket.recv(socket, 0, timeout) do
      {:ok, _bytes} -> await_socket_closed(socket, timeout)
      {:error, :closed} -> :closed
      {:error, :econnreset} -> :closed
      {:error, reason} -> {:error, reason}
    end
  end

  defp receive_records_or_closed(socket) do
    receive_records(socket, 1)
  rescue
    _closed -> :closed
  catch
    _kind, _closed -> :closed
  end

  defp start_daemon(options) do
    {:ok, output} = StringIO.open("")
    test = self()

    task =
      Task.async(fn ->
        Sentinel.run(options, output: output, install_signals: false, notify: test)
      end)

    assert_receive {:loopex_daemon_sentinel, sentinel, owner_ref, owner}, 1_000
    %{task: task, sentinel: sentinel, owner_ref: owner_ref, owner: owner, output: output}
  end

  defp await_ready(output, attempts \\ 500)

  defp await_ready(output, attempts) when attempts > 0 do
    case StringIO.contents(output) do
      {"", line} when byte_size(line) > 0 ->
        assert String.ends_with?(line, "\n")
        JSON.decode!(line)

      _empty ->
        Process.sleep(10)
        await_ready(output, attempts - 1)
    end
  end

  defp await_ready(_output, 0), do: flunk("daemon never announced readiness")

  defp initialized(path) do
    {:ok, socket} = :socket.open(:local, :stream, :default)
    :ok = await_connect(socket, path, 100)

    :ok =
      send_frame(socket, %{
        "method" => "initialize",
        "request_id" => "init",
        "generations" => [V2.generation()],
        "capabilities" => []
      })

    assert [%{"type" => "initialized"}] = receive_records(socket, 1)
    socket
  end

  defp await_connect(socket, path, attempts) do
    case :socket.connect(socket, %{family: :local, path: path}) do
      :ok ->
        :ok

      {:error, _reason} when attempts > 0 ->
        Process.sleep(10)
        await_connect(socket, path, attempts - 1)

      {:error, reason} ->
        flunk("could not connect: #{inspect(reason)}")
    end
  end
end
