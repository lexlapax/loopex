defmodule LoopexDaemon.ConnectionRegistryTest do
  use ExUnit.Case, async: true
  @moduletag capture_log: true

  alias LoopexDaemon.{ConnectionRegistry, ListenerSocket, SocketConnection}

  defmodule ImmediateExitConnection do
    def start_link(_options) do
      pid = spawn_link(fn -> exit(:forced_child_exit) end)
      {:ok, pid}
    end
  end

  defmodule SlowConnection do
    def start_link(options) do
      Process.sleep(30)
      SocketConnection.start_link(options)
    end
  end

  test "a transferred socket becomes live only after registry promotion" do
    fixture = socket_fixture()
    registry = start_registry(1_000)
    listener_incarnation = make_ref()
    accepted_at = now_ms()

    assert {:ok, %{rollback_token: token, initialize_deadline: deadline}} =
             ConnectionRegistry.reserve(registry, self(), listener_incarnation, accepted_at)

    assert deadline == accepted_at + 1_000
    assert {:ok, connection, incarnation} = ConnectionRegistry.start_connection(registry, token)
    assert :ok = ConnectionRegistry.begin_transfer(registry, token, incarnation)

    assert :ok =
             :socket.setopt(
               fixture.accepted,
               {:otp, :controlling_process},
               connection
             )

    assert :ok = ConnectionRegistry.transfer_result(registry, token, incarnation, :ok)
    assert :ok = SocketConnection.activate(connection, fixture.accepted)

    assert_receive {:promotion_complete, ^token, ^incarnation, ^connection}
    assert %{occupied: 1, provisional: 0, live: 1} = ConnectionRegistry.status(registry)

    assert :ok = SocketConnection.initialized(connection)
    Process.sleep(20)
    assert %{occupied: 1, live: 1} = ConnectionRegistry.status(registry)

    Process.exit(connection, :kill)
    eventually(fn -> ConnectionRegistry.status(registry).occupied == 0 end)
    close_fixture(fixture)
  end

  test "the unchanged accept-time deadline closes an uninitialized promoted connection" do
    fixture = socket_fixture()
    registry = start_registry(50)
    accepted_at = now_ms()

    assert {:ok, %{rollback_token: token}} =
             ConnectionRegistry.reserve(registry, self(), make_ref(), accepted_at)

    assert {:ok, connection, incarnation} = ConnectionRegistry.start_connection(registry, token)
    assert :ok = ConnectionRegistry.begin_transfer(registry, token, incarnation)

    assert :ok =
             :socket.setopt(
               fixture.accepted,
               {:otp, :controlling_process},
               connection
             )

    assert :ok = ConnectionRegistry.transfer_result(registry, token, incarnation, :ok)
    SocketConnection.activate(connection, fixture.accepted)
    assert_receive {:promotion_complete, ^token, ^incarnation, ^connection}

    monitor = Process.monitor(connection)
    assert_receive {:DOWN, ^monitor, :process, ^connection, :normal}, 500
    eventually(fn -> ConnectionRegistry.status(registry).occupied == 0 end)
    close_fixture(fixture)
  end

  test "expiry while listener-owned requires exact close acknowledgement and child reap" do
    registry = start_registry(30)
    accepted_at = now_ms()

    assert {:ok, %{rollback_token: token}} =
             ConnectionRegistry.reserve(registry, self(), make_ref(), accepted_at)

    assert {:ok, connection, _incarnation} =
             ConnectionRegistry.start_connection(registry, token)

    assert_receive {:close_accepted, ^token}, 500
    assert %{occupied: 1, provisional: 1} = ConnectionRegistry.status(registry)

    assert :ok = ConnectionRegistry.listener_closed(registry, token)
    monitor = Process.monitor(connection)
    assert_receive {:DOWN, ^monitor, :process, ^connection, _reason}, 500
    eventually(fn -> ConnectionRegistry.status(registry).occupied == 0 end)
  end

  test "a failed transfer returns ownership to the listener before cleanup" do
    registry = start_registry(1_000)
    accepted_at = now_ms()

    assert {:ok, %{rollback_token: token}} =
             ConnectionRegistry.reserve(registry, self(), make_ref(), accepted_at)

    assert {:ok, connection, incarnation} = ConnectionRegistry.start_connection(registry, token)
    assert :ok = ConnectionRegistry.begin_transfer(registry, token, incarnation)

    assert {:error, :transfer_failed} =
             ConnectionRegistry.transfer_result(
               registry,
               token,
               incarnation,
               {:error, :einval}
             )

    assert_receive {:close_accepted, ^token}
    assert :ok = ConnectionRegistry.listener_closed(registry, token)
    monitor = Process.monitor(connection)
    assert_receive {:DOWN, ^monitor, :process, ^connection, _reason}, 500
    eventually(fn -> ConnectionRegistry.status(registry).occupied == 0 end)
  end

  test "all 512 provisional slots remain charged until listener close evidence" do
    registry = start_registry(5_000)
    listener_incarnation = make_ref()

    tokens =
      for _index <- 1..512 do
        assert {:ok, %{rollback_token: token}} =
                 ConnectionRegistry.reserve(
                   registry,
                   self(),
                   listener_incarnation,
                   now_ms()
                 )

        token
      end

    assert {:error, :capacity_exceeded} =
             ConnectionRegistry.reserve(registry, self(), listener_incarnation, now_ms())

    assert %{occupied: 512, provisional: 512, limit: 512} =
             ConnectionRegistry.status(registry)

    assert :ok = ConnectionRegistry.abort_provisional_for(registry, listener_incarnation)

    for token <- tokens do
      assert_receive {:close_accepted, ^token}
      assert :ok = ConnectionRegistry.listener_closed(registry, token)
    end

    eventually(fn -> ConnectionRegistry.status(registry).occupied == 0 end)
  end

  test "an abort during transfer waits for the exact transfer result" do
    registry = start_registry(40)
    accepted_at = now_ms()

    assert {:ok, %{rollback_token: token}} =
             ConnectionRegistry.reserve(registry, self(), make_ref(), accepted_at)

    assert {:ok, connection, incarnation} = ConnectionRegistry.start_connection(registry, token)
    assert :ok = ConnectionRegistry.begin_transfer(registry, token, incarnation)
    monitor = Process.monitor(connection)

    Process.sleep(50)
    refute_receive {:close_accepted, ^token}, 20
    refute_receive {:DOWN, ^monitor, :process, ^connection, _reason}, 20
    assert %{occupied: 1, provisional: 1} = ConnectionRegistry.status(registry)

    assert {:error, :transfer_failed} =
             ConnectionRegistry.transfer_result(
               registry,
               token,
               incarnation,
               {:error, :einval}
             )

    assert_receive {:close_accepted, ^token}
    assert :ok = ConnectionRegistry.listener_closed(registry, token)
    assert_receive {:DOWN, ^monitor, :process, ^connection, :normal}, 500
    eventually(fn -> ConnectionRegistry.status(registry).occupied == 0 end)
  end

  test "an expired successful transfer reaps the connection-owned socket" do
    fixture = socket_fixture()
    registry = start_registry(60)

    assert {:ok, %{rollback_token: token}} =
             ConnectionRegistry.reserve(registry, self(), make_ref(), now_ms())

    assert {:ok, connection, incarnation} = ConnectionRegistry.start_connection(registry, token)
    assert :ok = ConnectionRegistry.begin_transfer(registry, token, incarnation)

    assert :ok =
             :socket.setopt(
               fixture.accepted,
               {:otp, :controlling_process},
               connection
             )

    monitor = Process.monitor(connection)
    Process.sleep(80)
    assert %{occupied: 1, provisional: 1} = ConnectionRegistry.status(registry)

    assert :ok = ConnectionRegistry.transfer_result(registry, token, incarnation, :ok)
    refute_receive {:close_accepted, ^token}, 20
    assert_receive {:DOWN, ^monitor, :process, ^connection, :normal}, 500
    eventually(fn -> ConnectionRegistry.status(registry).occupied == 0 end)
    close_fixture(fixture)
  end

  test "initialize completion queued before but consumed after the deadline loses" do
    fixture = socket_fixture()
    registry = start_registry(150)
    accepted_at = now_ms()

    assert {:ok, %{rollback_token: token}} =
             ConnectionRegistry.reserve(registry, self(), make_ref(), accepted_at)

    assert {:ok, connection, incarnation} = ConnectionRegistry.start_connection(registry, token)
    assert :ok = ConnectionRegistry.begin_transfer(registry, token, incarnation)

    assert :ok =
             :socket.setopt(
               fixture.accepted,
               {:otp, :controlling_process},
               connection
             )

    assert :ok = ConnectionRegistry.transfer_result(registry, token, incarnation, :ok)
    SocketConnection.activate(connection, fixture.accepted)
    assert_receive {:promotion_complete, ^token, ^incarnation, ^connection}

    :ok = :sys.suspend(registry)
    monitor = Process.monitor(connection)
    SocketConnection.initialized(connection)
    Process.sleep(170)
    :ok = :sys.resume(registry)

    assert_receive {:DOWN, ^monitor, :process, ^connection, :normal}, 500
    eventually(fn -> ConnectionRegistry.status(registry).occupied == 0 end)
    close_fixture(fixture)
  end

  test "listener death during transfer reaps the possible socket owner" do
    registry = start_registry(1_000)
    parent = self()

    listener =
      spawn(fn ->
        accepted_at = now_ms()
        incarnation = make_ref()

        {:ok, %{rollback_token: token}} =
          ConnectionRegistry.reserve(registry, self(), incarnation, accepted_at)

        {:ok, connection, connection_incarnation} =
          ConnectionRegistry.start_connection(registry, token)

        :ok = ConnectionRegistry.begin_transfer(registry, token, connection_incarnation)
        send(parent, {:transferring, self(), token, connection})

        receive do
          :stop -> :ok
        end
      end)

    assert_receive {:transferring, ^listener, _token, connection}
    monitor = Process.monitor(connection)
    Process.exit(listener, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^connection, :normal}, 500
    eventually(fn -> ConnectionRegistry.status(registry).occupied == 0 end)
  end

  test "only the reserving listener can continue or acknowledge a handoff" do
    registry = start_registry(1_000)

    listener =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    result =
      Task.async(fn ->
        ConnectionRegistry.reserve(registry, listener, make_ref(), now_ms())
      end)
      |> Task.await()

    assert {:error, :reservation_unavailable} = result
    Process.exit(listener, :kill)

    listener_incarnation = make_ref()

    assert {:ok, %{rollback_token: token}} =
             ConnectionRegistry.reserve(registry, self(), listener_incarnation, now_ms())

    assert {:error, :abort_unavailable} =
             Task.async(fn ->
               ConnectionRegistry.abort_provisional(registry, token, :handoff_failed)
             end)
             |> Task.await()

    assert {:error, :reservation_unavailable} =
             Task.async(fn -> ConnectionRegistry.start_connection(registry, token) end)
             |> Task.await()

    assert {:ok, connection, _incarnation} =
             ConnectionRegistry.start_connection(registry, token)

    assert {:error, :close_acknowledgement_unavailable} =
             ConnectionRegistry.listener_closed(registry, token)

    monitor = Process.monitor(connection)
    assert :ok = ConnectionRegistry.abort_provisional_for(registry, listener_incarnation)
    assert_receive {:close_accepted, ^token}
    assert :ok = ConnectionRegistry.listener_closed(registry, token)
    assert_receive {:DOWN, ^monitor, :process, ^connection, :normal}, 500
    eventually(fn -> ConnectionRegistry.status(registry).occupied == 0 end)
  end

  test "a child exit between linked start and unlink is reaped without losing the registry" do
    registry = start_registry(1_000, connection_module: ImmediateExitConnection)
    listener_incarnation = make_ref()

    assert {:ok, %{rollback_token: token}} =
             ConnectionRegistry.reserve(registry, self(), listener_incarnation, now_ms())

    assert {:ok, _connection, _incarnation} =
             ConnectionRegistry.start_connection(registry, token)

    assert_receive {:close_accepted, ^token}, 500
    assert :ok = ConnectionRegistry.listener_closed(registry, token)
    eventually(fn -> ConnectionRegistry.status(registry).occupied == 0 end)
    assert Process.alive?(registry)
  end

  test "a child start that crosses the accept deadline enters exact cleanup" do
    registry = start_registry(10, connection_module: SlowConnection)
    listener_incarnation = make_ref()

    assert {:ok, %{rollback_token: token}} =
             ConnectionRegistry.reserve(registry, self(), listener_incarnation, now_ms())

    assert {:error, :initialize_deadline_expired} =
             ConnectionRegistry.start_connection(registry, token)

    assert_receive {:close_accepted, ^token}, 500
    assert :ok = ConnectionRegistry.listener_closed(registry, token)
    eventually(fn -> ConnectionRegistry.status(registry).occupied == 0 end)
    assert Process.alive?(registry)
  end

  defp start_registry(deadline_ms, options \\ []) do
    {:ok, registry} =
      ConnectionRegistry.start_link(
        Keyword.merge(
          [owner: self(), initialize_deadline_ms: deadline_ms],
          options
        )
      )

    on_exit(fn ->
      try do
        if Process.alive?(registry), do: GenServer.stop(registry)
      catch
        :exit, _reason -> :ok
      end
    end)

    registry
  end

  defp socket_fixture do
    directory =
      Path.join(
        System.tmp_dir!(),
        "loopex-registry-socket-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir!(directory)
    path = Path.join(directory, "daemon.sock")
    uid = File.stat!(directory).uid
    {:ok, listener} = ListenerSocket.open_parked(path, uid)
    parent = self()

    client =
      Task.async(fn ->
        {:ok, socket} = :socket.open(:local, :stream, :default)
        :ok = :socket.connect(socket, %{family: :local, path: path})
        send(parent, {:client_ready, self()})

        receive do
          :close -> :ok
        end

        :socket.close(socket)
      end)

    assert_receive {:client_ready, client_pid} when client_pid == client.pid
    {:ok, accepted} = :socket.accept(listener, 1_000)

    %{directory: directory, path: path, listener: listener, accepted: accepted, client: client}
  end

  defp close_fixture(fixture) do
    send(fixture.client.pid, :close)
    assert :ok = Task.await(fixture.client)
    assert :ok = ListenerSocket.close(fixture.listener)
    File.rm!(fixture.path)
    File.rmdir!(fixture.directory)
  end

  defp eventually(predicate, attempts \\ 50)

  defp eventually(predicate, 0), do: assert(predicate.())

  defp eventually(predicate, attempts) do
    if predicate.() do
      :ok
    else
      Process.sleep(10)
      eventually(predicate, attempts - 1)
    end
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
