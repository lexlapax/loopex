defmodule LoopexDaemon.Test.DaemonSocketFixture do
  @moduledoc false

  import ExUnit.Assertions
  import ExUnit.Callbacks

  alias LoopexDaemon.{Listener, ListenerSocket, Owner}
  alias LoopexProtocol.{Frame, Session.V2}

  @doc false
  def temporary_directory(prefix) do
    directory =
      Path.join(System.tmp_dir!(), "#{prefix}-#{System.unique_integer([:positive, :monotonic])}")

    File.mkdir!(directory)
    on_exit(fn -> File.rm_rf(directory) end)
    directory
  end

  @doc false
  def start_runtime(root) do
    state = Path.join(root, "state")
    File.mkdir_p!(state)

    {:ok, adapter} =
      Loopex.Store.Local.start_link(path: Path.join(state, "store.log"))

    {:ok, store} = Loopex.Store.new(Loopex.Store.Local, adapter)

    {:ok, runtime} =
      Loopex.start_link(
        runtime_id: "daemon-test-#{System.unique_integer([:positive])}",
        store: store,
        context_token_budget: 8_192
      )

    runtime
  end

  @doc false
  def start_daemon(runtime, options \\ []) do
    directory = temporary_directory("loopex-daemon-socket")
    path = Path.join(directory, "d.sock")
    uid = File.stat!(directory).uid

    owner =
      start_supervised!(
        {Owner,
         Keyword.merge(
           [admission_wait_ms: 1_000, runtime: runtime, fatal_recipient: self()],
           options
         )},
        restart: :temporary
      )

    components = Owner.components(owner)
    {:ok, socket} = ListenerSocket.open_parked(path, uid)
    startup_ref = make_ref()

    {:ok, listener} =
      Listener.start_link(
        owner: self(),
        registry: components.registry,
        socket: socket,
        daemon_uid: uid,
        startup_ref: startup_ref
      )

    assert_receive {:listener_parked, ^startup_ref, ^listener}
    assert :ok = Listener.begin_accept(listener, startup_ref)
    Map.merge(components, %{owner: owner, listener: listener, path: path})
  end

  @doc false
  def connect(daemon) do
    {:ok, socket} = :socket.open(:local, :stream, :default)
    :ok = :socket.connect(socket, %{family: :local, path: daemon.path})
    Process.put({__MODULE__, socket}, "")
    socket
  end

  @doc false
  def initialized_client(daemon) do
    socket = connect(daemon)

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

  @doc false
  def send_frame(socket, record) do
    {:ok, encoded} = Frame.encode(record)
    :socket.send(socket, IO.iodata_to_binary(encoded))
  end

  @doc false
  def receive_records(socket, count, timeout \\ 1_000)

  def receive_records(_socket, 0, _timeout), do: []

  def receive_records(socket, count, timeout) do
    buffered = Process.get({__MODULE__, socket}, "")

    case :binary.split(buffered, "\n") do
      [payload, rest] ->
        Process.put({__MODULE__, socket}, rest)
        {:ok, record} = Frame.decode(payload, Frame.output_record_bytes())
        [record | receive_records(socket, count - 1, timeout)]

      [_partial] ->
        case :socket.recv(socket, 0, timeout) do
          {:ok, bytes} ->
            Process.put({__MODULE__, socket}, buffered <> bytes)
            receive_records(socket, count, timeout)

          {:error, reason} ->
            flunk("socket closed before #{count} more records: #{inspect(reason)}")
        end
    end
  end

  @doc false
  def closed?(socket, timeout \\ 1_000) do
    case :socket.recv(socket, 0, timeout) do
      {:error, :closed} -> true
      {:ok, _bytes} -> false
      {:error, :timeout} -> false
    end
  end

  @doc false
  def eventually(predicate, attempts \\ 100)
  def eventually(predicate, 0), do: assert(predicate.())

  def eventually(predicate, attempts) do
    if predicate.() do
      :ok
    else
      Process.sleep(10)
      eventually(predicate, attempts - 1)
    end
  end
end
