defmodule LoopexDaemon.ListenerTest do
  use ExUnit.Case, async: true
  @moduletag capture_log: true

  alias LoopexDaemon.{ConnectionRegistry, Listener, ListenerSocket, OutputBuffer}
  alias LoopexProtocol.{Frame, Session.V2}

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

  # Concept: the listener's real peer check closes a connection whose
  # credential names another user before any frame is read.
  #
  # Technical depth: the listener runs the production `PeerCredential` module
  # with a daemon uid one above the socket owner's, so the kernel-supplied
  # credential is readable and well formed but mismatched. The client's
  # initialize frame gets no reply, the connection closes, the registry
  # returns to empty and the listener keeps accepting.
  test "the real peer check closes a valid but mismatched credential before initialize" do
    probe = Path.join(System.tmp_dir!(), "lpc-#{System.unique_integer([:positive])}")
    File.write!(probe, "")
    uid = File.stat!(probe).uid
    File.rm!(probe)
    fixture = start_fixture(daemon_uid: uid + 1)
    assert :ok = Listener.begin_accept(fixture.listener, fixture.startup_ref)
    client = connect(fixture.path)
    _ = send_frame(client, initialize())

    eventually(fn -> ConnectionRegistry.status(fixture.registry).occupied == 0 end)
    assert {:error, :closed} = :socket.recv(client, 0, 1_000)
    assert Listener.phase(fixture.listener) == :accepting
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

  test "generation two initializes before the accept-time deadline and cancels it" do
    fixture = start_fixture(initialize_deadline_ms: 300)
    assert :ok = Listener.begin_accept(fixture.listener, fixture.startup_ref)
    client = connect(fixture.path)

    assert :ok = send_frame(client, initialize())
    [initialized] = receive_records(client, 1)
    assert initialized["type"] == "initialized"
    assert initialized["request_id"] == "r1"
    assert initialized["selected_generation"] == V2.generation()
    assert initialized["exact_schema_sha256"] == V2.schema_digest()

    Process.sleep(330)
    assert %{occupied: 1, live: 1} = ConnectionRegistry.status(fixture.registry)

    assert :ok =
             send_frame(client, %{
               "method" => "session.list",
               "request_id" => "r2",
               "limit" => 1
             })

    [inert] = receive_records(client, 1)
    assert inert["code"] == "unsupported_method"
    assert inert["request_id"] == "r2"

    assert :ok =
             send_frame(client, %{
               "method" => "session.list",
               "request_id" => "r3",
               "limit" => nil
             })

    [malformed] = receive_records(client, 1)

    assert malformed == %{
             "type" => "error",
             "code" => "invalid_request",
             "message" => "request does not match the generation-two contract",
             "request_id" => "r3"
           }

    assert :ok = :socket.close(client)
  end

  test "a generation-one offer is refused once and then expires" do
    fixture = start_fixture(initialize_deadline_ms: 250)
    assert :ok = Listener.begin_accept(fixture.listener, fixture.startup_ref)
    client = connect(fixture.path)

    assert :ok = send_frame(client, initialize("r1", ["loopex.experimental/1"]))
    [unsupported] = receive_records(client, 1)
    assert unsupported["code"] == "unsupported_generation"

    assert :ok = send_frame(client, initialize("r2", [V2.generation()]))
    [spent] = receive_records(client, 1)
    assert spent["code"] == "already_initialized"
    assert spent["request_id"] == "r2"

    eventually(fn -> ConnectionRegistry.status(fixture.registry).occupied == 0 end)
    assert {:error, :closed} = :socket.recv(client, 1, 500)
    assert :ok = :socket.close(client)
  end

  test "fragmented and multiple frames preserve order across initialization" do
    fixture = start_fixture(initialize_deadline_ms: 1_000)
    assert :ok = Listener.begin_accept(fixture.listener, fixture.startup_ref)
    client = connect(fixture.path)
    {:ok, encoded_initialize} = Frame.encode(initialize())
    initialize_bytes = IO.iodata_to_binary(encoded_initialize)
    split = div(byte_size(initialize_bytes), 2)
    <<first::binary-size(^split), second::binary>> = initialize_bytes

    before =
      frame_bytes(%{"method" => "session.list", "request_id" => "before"})

    assert :ok = :socket.send(client, [before, first])
    [not_initialized] = receive_records(client, 1)
    assert not_initialized["code"] == "not_initialized"
    assert not_initialized["request_id"] == "before"

    assert :ok = :socket.send(client, second)
    [initialized] = receive_records(client, 1)
    assert initialized["type"] == "initialized"

    assert :ok = :socket.send(client, ["{}\r\n", frame_bytes(%{"request_id" => "missing"})])
    [crlf, missing_method] = receive_records(client, 2)
    assert crlf["code"] == "invalid_frame"
    assert missing_method["code"] == "invalid_request"
    assert missing_method["request_id"] == "missing"
    assert :ok = :socket.close(client)
  end

  test "registry-owned output uses nonblocking socket progress under peer backpressure" do
    fixture = start_fixture(initialize_deadline_ms: 1_000)
    assert :ok = Listener.begin_accept(fixture.listener, fixture.startup_ref)
    client = connect(fixture.path)

    assert :ok = send_frame(client, initialize())
    assert [%{"type" => "initialized"}] = receive_records(client, 1)
    eventually(fn -> ConnectionRegistry.status(fixture.registry).output_bytes == 0 end)

    registry_state = :sys.get_state(fixture.registry)
    [{token, row}] = Map.to_list(registry_state.rows)
    connection = row.connection_pid
    incarnation = row.connection_incarnation
    :ok = :sys.suspend(connection)

    {:ok, encoded} =
      Frame.encode(%{
        "type" => "error",
        "code" => "internal_failure",
        "message" => String.duplicate("m", 120_000)
      })

    encoded = IO.iodata_to_binary(encoded)

    :sys.replace_state(fixture.registry, fn state ->
      row = Map.fetch!(state.rows, token)

      output =
        Enum.reduce(1..34, row.output, fn _index, output ->
          {:ok, output} = OutputBuffer.enqueue(output, encoded)
          output
        end)

      commitment = OutputBuffer.commitment(output)

      state
      |> put_in([:rows, token, :output], output)
      |> Map.put(:output_commitment, commitment)
    end)

    send(connection, {:output_ready, incarnation})
    :ok = :sys.resume(connection)

    eventually(fn ->
      state = :sys.get_state(connection)
      not is_nil(state.send_select) and not is_nil(state.output_claim)
    end)

    assert %{occupied: 1, output_bytes: queued, output_commitment: queued} =
             ConnectionRegistry.status(fixture.registry)

    assert queued > 0
    assert Process.alive?(fixture.registry)
    assert Process.alive?(connection)

    # Once the peer reads, the writer resumes each partial send and every
    # queued frame arrives whole, releasing the whole charge.
    records = read_frames(client, 34, [], 0)
    assert length(records) == 34
    assert Enum.all?(records, &(&1["message"] == String.duplicate("m", 120_000)))
    eventually(fn -> ConnectionRegistry.status(fixture.registry).output_bytes == 0 end)

    assert :ok = :socket.close(client)
    eventually(fn -> ConnectionRegistry.status(fixture.registry).occupied == 0 end)
    assert %{output_bytes: 0, output_commitment: 0} = ConnectionRegistry.status(fixture.registry)
  end

  test "an oversized partial frame is discarded only through its newline" do
    fixture = start_fixture(initialize_deadline_ms: 1_000)
    assert :ok = Listener.begin_accept(fixture.listener, fixture.startup_ref)
    client = connect(fixture.path)
    ceiling = V2.limits()["frame_bytes_before_initialization"]

    assert :ok = :socket.send(client, String.duplicate("x", ceiling + 1))
    [oversized] = receive_records(client, 1)
    assert oversized["code"] == "invalid_frame"
    assert oversized["message"] == "the frame exceeds the ceiling in force"

    assert :ok = :socket.send(client, ["\n", frame_bytes(initialize())])
    [initialized] = receive_records(client, 1)
    assert initialized["type"] == "initialized"
    assert :ok = :socket.close(client)
  end

  test "the transport cut closes real uninitialized sockets and keeps initialized sockets" do
    fixture = start_fixture(initialize_deadline_ms: 1_000)
    assert :ok = Listener.begin_accept(fixture.listener, fixture.startup_ref)

    initialized_client = connect(fixture.path)
    assert :ok = send_frame(initialized_client, initialize())
    assert [%{"type" => "initialized"}] = receive_records(initialized_client, 1)

    uninitialized_client = connect(fixture.path)
    eventually(fn -> ConnectionRegistry.status(fixture.registry).occupied == 2 end)

    cut_ref = make_ref()

    assert {:reply, {:ok, ^cut_ref}} =
             fixture.registry
             |> ConnectionRegistry.transport_closing(cut_ref)
             |> :gen_server.receive_response(500)

    late_client = connect(fixture.path)
    assert {:error, :closed} = :socket.recv(late_client, 1, 500)

    Process.unlink(fixture.listener)
    listener_monitor = Process.monitor(fixture.listener)
    Process.exit(fixture.listener, :kill)
    assert_receive {:DOWN, ^listener_monitor, :process, _listener, :killed}, 500

    assert {:reply, :ok} =
             fixture.registry
             |> ConnectionRegistry.reap_uninitialized(cut_ref)
             |> :gen_server.receive_response(500)

    assert_receive {:transport_uninitialized_empty, registry, ^cut_ref}, 500
    assert registry == fixture.registry
    assert {:error, :closed} = :socket.recv(uninitialized_client, 1, 500)

    assert :ok =
             send_frame(initialized_client, %{
               "method" => "session.list",
               "request_id" => "after-cut",
               "limit" => 1
             })

    assert [%{"code" => "unsupported_method", "request_id" => "after-cut"}] =
             receive_records(initialized_client, 1)

    assert %{occupied: 1, live: 1, transport_marked: 0} =
             ConnectionRegistry.status(fixture.registry)

    assert :ok = :socket.close(initialized_client)
    assert :ok = :socket.close(uninitialized_client)
    assert :ok = :socket.close(late_client)
  end

  defp start_fixture(options \\ []) do
    {initialize_deadline_ms, listener_options} =
      Keyword.pop(options, :initialize_deadline_ms, V2.limits()["initialize_deadline_ms"])

    directory = temporary_directory()
    path = Path.join(directory, "daemon.sock")
    uid = File.stat!(directory).uid
    {:ok, socket} = ListenerSocket.open_parked(path, uid)
    registry = start_registry(initialize_deadline_ms)
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
          listener_options
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

  defp start_registry(initialize_deadline_ms \\ V2.limits()["initialize_deadline_ms"]) do
    {:ok, registry} =
      ConnectionRegistry.start_link(
        owner: self(),
        initialize_deadline_ms: initialize_deadline_ms
      )

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

  defp initialize(request_id \\ "r1", generations \\ [V2.generation()]) do
    %{
      "method" => "initialize",
      "request_id" => request_id,
      "generations" => generations,
      "capabilities" => []
    }
  end

  defp send_frame(socket, record), do: :socket.send(socket, frame_bytes(record))

  defp frame_bytes(record) do
    {:ok, encoded} = Frame.encode(record)
    IO.iodata_to_binary(encoded)
  end

  defp receive_records(socket, count), do: receive_records(socket, count, "")

  defp receive_records(socket, count, buffered) do
    parts = :binary.split(buffered, "\n", [:global])

    if length(parts) > count do
      {payloads, _rest} = Enum.split(parts, count)

      Enum.map(payloads, fn payload ->
        {:ok, record} = Frame.decode(payload, Frame.output_record_bytes())
        record
      end)
    else
      {:ok, bytes} = :socket.recv(socket, 0, 1_000)
      receive_records(socket, count, buffered <> bytes)
    end
  end

  # Reads until `count` complete frames have arrived, counting newlines per
  # chunk so a large backlog is scanned once.
  defp read_frames(_socket, count, chunks, seen) when seen >= count do
    chunks
    |> Enum.reverse()
    |> IO.iodata_to_binary()
    |> :binary.split("\n", [:global])
    |> Enum.take(count)
    |> Enum.map(fn payload ->
      {:ok, record} = Frame.decode(payload, Frame.output_record_bytes())
      record
    end)
  end

  defp read_frames(socket, count, chunks, seen) do
    {:ok, bytes} = :socket.recv(socket, 0, 5_000)
    newlines = length(:binary.matches(bytes, "\n"))
    read_frames(socket, count, [bytes | chunks], seen + newlines)
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
