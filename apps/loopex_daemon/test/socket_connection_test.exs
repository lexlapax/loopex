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

    %{session_id: session_id, runtime: runtime, daemon: start_daemon(runtime)}
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

  # Concept: a registry that leaves a connection's request unanswered for its
  # five-second step while serving is named `connections_lost`, once, and
  # the daemon fail-stops on that class rather than blaming the connection.
  #
  # Technical depth: the registry is suspended and a client frame makes its
  # connection send an output enqueue to it. The connection's instant reports
  # the registry to the collaboration owner, which reports `connections_lost`
  # to the fatal recipient, here the test, and kills the registry; its exit
  # is not reported again.
  @tag timeout: 60_000
  test "a registry request unanswered for its step while serving is connections_lost once",
       %{daemon: daemon} do
    client = initialized_client(daemon)
    owner = daemon.owner
    :ok = :sys.suspend(daemon.registry)
    started = System.monotonic_time(:millisecond)
    :ok = send_frame(client, unsupported("stalled"))

    assert_receive {:daemon_component_fatal, ^owner, :connections_lost}, 8_000
    assert System.monotonic_time(:millisecond) - started >= 4_900
    refute_receive {:daemon_component_fatal, _component, _class}, 1_000
  end

  # Concept: after the admission cut the stop's own deadlines govern, so the
  # same unanswered registry request is reported and names nothing.
  #
  # Technical depth: the cut completes before the registry is suspended. The
  # report is observed arriving at the collaboration owner, so the refusal
  # to latch is not the absence of a report.
  @tag timeout: 60_000
  test "a registry request unanswered after the cut is reported and names nothing",
       %{daemon: daemon} do
    client = initialized_client(daemon)
    owner = daemon.owner
    registry = daemon.registry
    assert {:ok, _cut_ref} = LoopexDaemon.Owner.cut_admission(owner, 2_000)
    1 = :erlang.trace(owner, true, [:receive])
    :ok = :sys.suspend(registry)

    try do
      :ok = send_frame(client, unsupported("after-cut"))

      assert_receive {:trace, ^owner, :receive,
                      {:connection_registry_unanswered, _connection, _incarnation, ^registry}},
                     8_000

      refute_receive {:daemon_component_fatal, _component, _class}, 500
      assert Process.alive?(registry)
      assert %{fatal_teardown: false} = :sys.get_state(owner)
    after
      :erlang.trace(owner, false, [:receive])
      :sys.resume(registry)
    end
  end

  test "the current socket consumes only credited closed activity and ordinary progress",
       %{daemon: daemon, runtime: runtime} do
    client = initialized_client(daemon)
    [connection] = initialized_connections(daemon)

    # Concept: an attachment observes a session activated in this daemon lifetime.
    # Technical depth: native facade creation in setup does not establish daemon
    # residency; this existing public create request does so before attachment.
    :ok =
      send_frame(client, %{
        "method" => "session.create",
        "request_id" => "create-progress",
        "command_id" => Wire.encode_identity("create-progress"),
        "session_options" => %{"version" => 1}
      })

    assert [
             %{
               "type" => "admission",
               "request_id" => "create-progress",
               "method" => "session.create",
               "status" => "accepted",
               "session_id" => encoded_session
             }
           ] = receive_records(client, 1)

    assert {:ok, session_id} = Wire.identity(encoded_session)

    assert %{active_sessions: 1, activations_used: 1} =
             LoopexDaemon.ConnectionRegistry.status(daemon.registry)

    assert {:ok, %{event_sequence: cursor}} = Loopex.session_status(runtime, session_id)

    :ok =
      send_frame(client, %{
        "method" => "session.attach",
        "request_id" => "attach-progress",
        "session_id" => Wire.encode_identity(session_id),
        "after_event_sequence" => Wire.encode_u64(cursor)
      })

    assert [%{"type" => "snapshot"}] = receive_records(client, 1)

    activity = %{
      kind: "context.compaction_progress",
      episode_id: <<0, 255>>,
      owner: %{"kind" => "compact", "id" => <<255, 0>>},
      stream_domain_id: "0123456789abcdef0123456789abcdef",
      progress_sequence: 0,
      base_event_sequence: cursor
    }

    for item <- [
          activity,
          Map.put(activity, :summary, "PRIVATE_CANARY"),
          Map.put(activity, :permit, fn -> :private end),
          Map.put(activity, :episode_id, :binary.copy(<<255>>, 65_537)),
          %{"kind" => "context.compaction_progress", "summary" => fn -> :private end}
        ] do
      result = Loopex.ProgressSink.try_offer(:sys.get_state(connection).progress_sink, session_id, item)
      assert result == if(item == activity, do: :ok, else: :dropped)
    end

    ordinary = %{
      kind: :text_delta,
      turn_id: "turn",
      text: "ordinary-barrier",
      stream_domain_id: "0123456789abcdef0123456789abcdef",
      model_sequence: 0,
      content_index: 0,
      base_event_sequence: cursor
    }

    # Concept: only closed native items become socket decoration.
    # Technical depth: the actual native arena refuses private/oversized inputs;
    # accepted activity and ordinary items retain their offer order.
    :ok = Loopex.ProgressSink.try_offer(:sys.get_state(connection).progress_sink, session_id, ordinary)
    assert [%{"type" => "progress", "progress" => observed_activity},
            %{"type" => "progress", "progress" => progress}] = receive_records(client, 2)
    assert {:ok, expected_activity} = LoopexProtocol.Session.CompactionProgress.encode_wire(activity)
    assert observed_activity == expected_activity
    assert progress["kind"] == "text_delta"
    assert progress["text"] == "ordinary-barrier"
    assert progress["base_event_sequence"] == Integer.to_string(cursor)
    assert Process.alive?(connection)
    state = :sys.get_state(connection)
    assert state.attachment.session_id == session_id
    assert {:ok, %{event_sequence: ^cursor}} = Loopex.session_status(runtime, session_id)
  end

  test "credited ordinary Socket progress retains32 leases and refuses native byte pressure" do
    {:ok, sink} = Loopex.ProgressSink.open()
    state = %{
      progress_sink: sink,
      progress_leases: %{},
      progress_frames: %{},
      closing: nil,
      succession: nil,
      attachment: %{session_id: "session"},
      progress: :queue.new(),
      progress_bytes: 0,
      output_claim: :busy,
      output_cursors: :queue.new(),
      enqueues_pending: 1
    }

    queued =
      Enum.reduce(1..33, state, fn index, state ->
        item = %{
          kind: :text_delta,
          turn_id: "turn",
          text: "item-#{index}",
          stream_domain_id: "0123456789abcdef0123456789abcdef",
          model_sequence: index - 1,
          base_event_sequence: 0,
          content_index: 0
        }

        if index <= 32 do
          assert :ok = Loopex.ProgressSink.try_offer(sink, "session", item)
          assert_receive {:loopex_progress_ready, ^sink}, 1_000
          assert {:noreply, next} = LoopexDaemon.SocketConnection.handle_info({:loopex_progress_ready, sink}, state)
          next
        else
          assert :dropped = Loopex.ProgressSink.try_offer(sink, "session", item)
          state
        end
      end)

    assert :queue.len(queued.progress) == 32
    assert queued.progress_bytes <= 524_288
    [{_lease, first} | _] = :queue.to_list(queued.progress)

    assert {:ok, first_record} =
             LoopexProtocol.Frame.decode(
               String.trim_trailing(first, "\n"),
               LoopexProtocol.Frame.output_record_bytes()
             )

    assert first_record["progress"]["text"] == "item-1"

    assert map_size(queued.progress_leases) == 32
    for {lease, _} <- :queue.to_list(queued.progress), do: assert(:ok == Loopex.ProgressSink.release(sink, lease))

    large = %{
      kind: :text_delta,
      turn_id: "turn",
      text: String.duplicate("x", 300_000),
      stream_domain_id: "0123456789abcdef0123456789abcdef",
      model_sequence: 0,
      base_event_sequence: 0,
      content_index: 0
    }

    for _ <- 1..2 do
      assert :dropped = Loopex.ProgressSink.try_offer(sink, "session", large)
    end

    # Concept: native credit refuses oversized backing before encoded copies.
    # Technical depth: the accepted native charge is stricter than the encoded
    # ceiling; real byte pressure cannot be manufactured by bypassing admission.
    bytes = :binary.copy(<<255>>, 65_536)
    byte_pressure = %{
      kind: :tool_progress, turn_id: bytes, tool_call_id: bytes,
      stream_domain_id: "0123456789abcdef0123456789abcdef",
      progress_sequence: 0, base_event_sequence: 0, stream: "stdout",
      byte_offset: 0, chunk: String.duplicate("x", 65_536)
    }
    assert :dropped = Loopex.ProgressSink.try_offer(sink, "session", byte_pressure)
    fitting = %{large | text: String.duplicate("x", 30_000)}
    assert :ok = Loopex.ProgressSink.try_offer(sink, "session", fitting)
    assert_receive {:loopex_progress_ready, ^sink}, 1_000
    assert {:noreply, one} = LoopexDaemon.SocketConnection.handle_info({:loopex_progress_ready, sink}, state)
    assert :queue.len(one.progress) == 1
    assert map_size(one.progress_leases) == 1
    [{lease, encoded}] = :queue.to_list(one.progress)
    assert byte_size(encoded) == one.progress_bytes
    assert one.progress_bytes > 30_000 and one.progress_bytes <= 524_288
    {_guardian, native_incarnation, arena} = sink
    [{:state, ^native_incarnation, owner, _status, native_bytes, slots, _ready}] = :ets.lookup(arena, :state)
    assert owner == self()
    {^native_incarnation, slot, token} = lease
    assert {^token, :leased, ^owner, charge} = elem(slots, slot)
    assert native_bytes == charge and native_bytes <= 524_288
    assert native_bytes + charge > 524_288
    assert :dropped = Loopex.ProgressSink.try_offer(sink, "session", %{fitting | model_sequence: 1})
    assert {:ok, record} = LoopexProtocol.Frame.decode(String.trim_trailing(encoded, "\n"), LoopexProtocol.Frame.output_record_bytes())
    assert record["progress"]["text"] == fitting.text
    assert :ok = Loopex.ProgressSink.release(sink, lease)
    assert :ok = Loopex.ProgressSink.close(sink)
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
