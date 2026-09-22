defmodule LoopexDaemon.ListenerTest do
  use ExUnit.Case, async: true
  @moduletag capture_log: true

  alias LoopexDaemon.{ConnectionRegistry, Listener, ListenerSocket}

  defmodule RejectPeer do
    def authorize(_socket, _daemon_uid), do: {:error, :peer_credential_unverified}
  end

  test "the parked gate creates no daemon connection before exact release" do
    fixture = start_fixture()
    client = connect(fixture.path)

    assert Listener.phase(fixture.listener) == :parked
    assert ConnectionRegistry.status(fixture.registry).occupied == 0

    assert :ok = Listener.begin_accept(fixture.listener, make_ref())
    Process.sleep(20)
    assert ConnectionRegistry.status(fixture.registry).occupied == 0

    assert :ok = Listener.begin_accept(fixture.listener, fixture.startup_ref)

    eventually(fn ->
      case ConnectionRegistry.status(fixture.registry) do
        %{occupied: 1, provisional: 0, live: 1} -> true
        _other -> false
      end
    end)

    assert Listener.phase(fixture.listener) == :accepting

    second_client = connect(fixture.path)

    eventually(fn ->
      case ConnectionRegistry.status(fixture.registry) do
        %{occupied: 2, provisional: 0, live: 2} -> true
        _other -> false
      end
    end)

    refute inspect(:sys.get_status(fixture.listener)) =~ fixture.path
    assert :ok = :socket.close(client)
    assert :ok = :socket.close(second_client)
  end

  test "a refused peer closes through the charged registry rollback" do
    fixture = start_fixture(peer_module: RejectPeer)
    assert :ok = Listener.begin_accept(fixture.listener, fixture.startup_ref)
    client = connect(fixture.path)

    eventually(fn -> ConnectionRegistry.status(fixture.registry).occupied == 0 end)
    assert {:error, :closed} = :socket.recv(client, 1, 500)
    assert Listener.phase(fixture.listener) == :accepting
    assert Process.alive?(fixture.listener)
    assert :ok = :socket.close(client)
  end

  test "owner loss stops the listener and retains the socket pathname" do
    directory = temporary_directory()
    path = Path.join(directory, "daemon.sock")
    uid = File.stat!(directory).uid
    registry = start_registry()
    parent = self()

    owner =
      spawn(fn ->
        {:ok, socket} = ListenerSocket.open_parked(path, uid)
        startup_ref = make_ref()

        {:ok, listener} =
          Listener.start_link(
            owner: self(),
            registry: registry,
            socket: socket,
            daemon_uid: uid,
            startup_ref: startup_ref
          )

        receive do
          {:listener_parked, ^startup_ref, ^listener} ->
            send(parent, {:owner_listener, self(), listener})
        end

        receive do
          :hold -> :ok
        end
      end)

    assert_receive {:owner_listener, ^owner, listener}
    monitor = Process.monitor(listener)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^listener, _reason}, 500
    assert {:ok, %File.Stat{type: :other}} = File.lstat(path)

    on_exit(fn ->
      File.rm(path)
      File.rmdir(directory)
    end)
  end

  defp start_fixture(options \\ []) do
    directory = temporary_directory()
    path = Path.join(directory, "daemon.sock")
    uid = File.stat!(directory).uid
    {:ok, socket} = ListenerSocket.open_parked(path, uid)
    registry = start_registry()
    startup_ref = make_ref()

    {:ok, listener} =
      Listener.start_link(
        Keyword.merge(
          [
            owner: self(),
            registry: registry,
            socket: socket,
            daemon_uid: uid,
            startup_ref: startup_ref
          ],
          options
        )
      )

    assert_receive {:listener_parked, ^startup_ref, ^listener}

    on_exit(fn ->
      stop(listener)
      File.rm(path)
      File.rmdir(directory)
    end)

    %{
      directory: directory,
      path: path,
      uid: uid,
      registry: registry,
      startup_ref: startup_ref,
      listener: listener
    }
  end

  defp start_registry do
    {:ok, registry} = ConnectionRegistry.start_link(owner: self())

    on_exit(fn ->
      stop(registry)
    end)

    registry
  end

  defp connect(path) do
    {:ok, socket} = :socket.open(:local, :stream, :default)
    :ok = :socket.connect(socket, %{family: :local, path: path})
    socket
  end

  defp temporary_directory do
    directory =
      Path.join(
        System.tmp_dir!(),
        "loopex-listener-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir!(directory)
    directory
  end

  defp stop(pid) do
    try do
      if Process.alive?(pid), do: GenServer.stop(pid)
    catch
      :exit, _reason -> :ok
    end
  end

  defp eventually(predicate, attempts \\ 100)

  defp eventually(predicate, 0), do: assert(predicate.())

  defp eventually(predicate, attempts) do
    if predicate.() do
      :ok
    else
      Process.sleep(10)
      eventually(predicate, attempts - 1)
    end
  end
end
