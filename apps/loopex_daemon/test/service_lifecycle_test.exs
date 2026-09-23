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

    [listener] =
      for pid <- Process.list(),
          {:dictionary, dictionary} <- [Process.info(pid, :dictionary)],
          dictionary[:"$initial_call"] == {LoopexDaemon.Listener, :init, 1},
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

    # The client learns why, or at least sees its socket close.
    case receive_records_or_closed(client) do
      :closed -> :ok
      [%{"type" => "daemon.stopping", "reason" => reason}] -> assert reason =~ "relay_lost"
    end
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
