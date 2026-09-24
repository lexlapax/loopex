Code.require_file("support/daemon_socket_fixture.exs", __DIR__)

defmodule LoopexDaemon.SocketConnectionTest do
  use ExUnit.Case, async: false
  @moduletag capture_log: true

  import LoopexDaemon.Test.DaemonSocketFixture

  alias LoopexProtocol.Wire

  setup do
    root = temporary_directory("loopex-socket-connection")
    runtime = start_runtime(root)

    {:ok, session_id} =
      Loopex.create_session(runtime, %{"purpose" => "stalled-registry"}, command_id: "create-1")

    %{session_id: session_id, daemon: start_daemon(runtime)}
  end

  # Concept: a connection never waits on the registry inside a handler, so a
  # holder whose registry is stalled with its output in flight still
  # processes its lost owner's close within its own flush bound: it closes
  # cleanly and acknowledges, is not killed at the owner's holder-close step,
  # and the daemon names nothing lost. Once the registry resumes, output
  # sent to it while it was stalled is written in the order it was produced.
  #
  # Technical depth: the holder is suspended while a correlated frame and
  # then the owner's close reach its mailbox, in that order; the registry is
  # suspended only after the owner has popped the routing mirror and entered
  # its holder-close step, so no mirror work waits on it. Resuming the holder
  # makes it enqueue the frame's refusal to the suspended registry before it
  # consumes the close. Its exit must be `:normal` within three seconds with
  # the registry still suspended — the owner's step would kill it at five —
  # and the owner must have consumed its acknowledgement. An observer sends
  # three pipelined frames while the registry is suspended and receives
  # their refusals in wire order after it resumes; whatever the holder's
  # client received is an in-order prefix of its refusal and its close.
  @tag timeout: 60_000
  test "a holder with output in flight to a stalled registry still closes for its lost owner",
       %{daemon: daemon, session_id: session_id} do
    holder = initialized_client(daemon)
    [holder_pid] = initialized_connections(daemon)
    observer = initialized_client(daemon)

    :ok = send_frame(holder, acquire("acquire", session_id))
    assert [%{"request_id" => "acquire", "type" => "result"}] = receive_records(holder, 1)

    [lease_owner] = Enum.map(:sys.get_state(daemon.owner).owners, fn {_s, row} -> row.pid end)
    holder_monitor = Process.monitor(holder_pid)

    :ok = :sys.suspend(holder_pid)
    :ok = send_frame(holder, unsupported("in-flight"))
    eventually(fn -> message_queue_len(holder_pid) >= 1 end)

    Process.exit(lease_owner, :kill)
    eventually(fn -> holder_close_pending?(daemon.owner) end, 500)

    :ok = :sys.suspend(daemon.registry)

    try do
      for id <- ["o1", "o2", "o3"], do: :ok = send_frame(observer, unsupported(id))
      :ok = :sys.resume(holder_pid)

      assert_receive {:DOWN, ^holder_monitor, :process, ^holder_pid, :normal}, 3_000
      eventually(fn -> not holder_close_pending?(daemon.owner) end)
    after
      :sys.resume(daemon.registry)
    end

    assert ["o1", "o2", "o3"] ==
             observer |> receive_records(3) |> Enum.map(& &1["request_id"])

    received = drain_records(holder)
    expected = [{"error", "in-flight"}, {"error", nil}]
    assert Enum.take(expected, length(received)) == received
    assert Process.alive?(daemon.owner)
    refute_received {:daemon_component_fatal, _component, _class}

    :ok = send_frame(observer, acquire("successor", session_id))
    assert [%{"request_id" => "successor", "type" => "result"}] = receive_records(observer, 1)
    refute_received {:daemon_component_fatal, _component, _class}
  end

  defp initialized_connections(daemon) do
    for {_token, %{initialized: true, connection_pid: pid}} <-
          :sys.get_state(daemon.registry).rows,
        do: pid
  end

  defp holder_close_pending?(owner) do
    owner
    |> :sys.get_state()
    |> Map.fetch!(:mirror_operations)
    |> Enum.any?(fn {_ref, operation} -> Map.get(operation, :step) == :await_holder_close end)
  end

  defp message_queue_len(pid) do
    {:message_queue_len, length} = Process.info(pid, :message_queue_len)
    length
  end

  # The records a closed client received, as `{type, request_id}` in order.
  defp drain_records(socket, acc \\ []) do
    case :socket.recv(socket, 0, 1_000) do
      {:ok, bytes} ->
        drain_records(socket, [bytes | acc])

      {:error, _closed} ->
        buffered = Process.get({LoopexDaemon.Test.DaemonSocketFixture, socket}, "")

        (buffered <> IO.iodata_to_binary(Enum.reverse(acc)))
        |> String.split("\n", trim: true)
        |> Enum.map(&JSON.decode!/1)
        |> Enum.map(&{&1["type"], &1["request_id"]})
    end
  end

  defp unsupported(request_id), do: %{"method" => "no.such_method", "request_id" => request_id}

  defp acquire(request_id, session_id) do
    %{
      "method" => "session.acquire_control",
      "request_id" => request_id,
      "session_id" => Wire.encode_identity(session_id)
    }
  end
end
