Code.require_file("support/daemon_socket_fixture.exs", __DIR__)

defmodule LoopexDaemon.SocketConnectionTest do
  use ExUnit.Case, async: false
  @moduletag capture_log: true

  import LoopexDaemon.Test.DaemonSocketFixture

  alias LoopexProtocol.Wire
  alias LoopexDaemon.{ConnectionRegistry, Owner, WireRecords}

  setup do
    root = temporary_directory("loopex-socket-connection")
    runtime = start_runtime(root)
    await_creation_startup(runtime)

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

  test "the current negotiated socket delivers compaction activity through credited ingress",
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
      result =
        Loopex.ProgressSink.try_offer(:sys.get_state(connection).progress_sink, session_id, item)

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

    # Concept: current serving emits the exact activity and releases its credit.
    # Technical depth: private/oversized variants refuse before admission. Both
    # valid rows must arrive within the original single five-second read window.
    :ok =
      Loopex.ProgressSink.try_offer(
        :sys.get_state(connection).progress_sink,
        session_id,
        ordinary
      )

    read_cutoff = System.monotonic_time(:millisecond) + 5_000

    [activity_record] =
      receive_records(client, 1, max(read_cutoff - System.monotonic_time(:millisecond), 0))

    assert System.monotonic_time(:millisecond) <= read_cutoff

    assert activity_record == %{
             "type" => "progress",
             "session_id" => encoded_session,
             "progress" => %{
               "kind" => "context.compaction_progress",
               "episode_id" => "AP8",
               "owner" => %{"kind" => "compact", "id" => "_wA"},
               "stream_domain_id" => "MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY",
               "progress_sequence" => "0",
               "base_event_sequence" => Integer.to_string(cursor)
             }
           }

    assert [%{"type" => "progress", "progress" => progress}] =
             receive_records(
               client,
               1,
               max(read_cutoff - System.monotonic_time(:millisecond), 0)
             )

    assert System.monotonic_time(:millisecond) <= read_cutoff

    eventually(fn ->
      state = :sys.get_state(connection)

      map_size(state.progress_leases) == 0 and map_size(state.progress_frames) == 0 and
        state.progress_bytes == 0
    end)

    assert progress["kind"] == "text_delta"
    assert progress["text"] == "ordinary-barrier"
    assert progress["base_event_sequence"] == Integer.to_string(cursor)
    assert Process.alive?(connection)
    state = :sys.get_state(connection)
    assert state.attachment.session_id == session_id
    assert {:ok, %{event_sequence: ^cursor}} = Loopex.session_status(runtime, session_id)
  end

  test "drained Socket close joins its own arena while guardian DOWN awaits the terminal result",
       %{daemon: daemon, runtime: runtime} do
    {client, socket, _session, sink} = progress_client(daemon, runtime)
    {guardian, native_incarnation, arena} = sink
    registry = daemon.registry
    registry_sink = :sys.get_state(registry).progress_sink
    {registry_guardian, registry_incarnation, registry_arena} = registry_sink
    socket_monitor = Process.monitor(socket)
    guardian_monitor = Process.monitor(guardian)
    registry_guardian_monitor = Process.monitor(registry_guardian)
    1 = :erlang.trace(guardian, true, [:receive])
    1 = :erlang.trace(registry_guardian, true, [:receive])
    1 = :erlang.trace(registry, true, [:receive])
    gate = park_socket_terminal(socket, registry)
    {caller, caller_monitor} = close_connections(daemon)
    assert_receive {:socket_terminal_parked, ^gate, close_ref}, 1_000
    {token, row} = socket_row(registry, socket)
    intent = row.native_retirement
    assert intent.close_ref == close_ref and intent.ready
    assert row.progress_fenced
    assert row.output.bytes == 0 and row.output.claim == nil
    assert intent.sink == sink
    assert now_ms() < intent.cutoff
    control = intent.control
    control_monitor = Process.monitor(control)

    assert_receive {:trace, ^guardian, :receive,
                    {:"$gen_call", {^socket, _}, {:close, ^native_incarnation}}},
                   1_000

    assert_receive {:DOWN, ^guardian_monitor, :process, ^guardian, :normal}, 1_000
    assert :ets.info(arena) == :undefined
    eventually(fn -> elem(socket_row(registry, socket), 1).native_retirement.guardian_joined end)

    assert %{native_retirement: %{result: nil, outcome: :pending}, connection_down: false} =
             elem(socket_row(registry, socket), 1)

    assert ConnectionRegistry.status(registry).live == 0
    refute_receive {:socket_close_answer, ^caller, :ok}, 0
    assert [%{"type" => "daemon.stopping"}] = receive_records(client, 1)
    assert closed?(client)
    send(socket, {:continue_socket_terminal, gate})

    assert_receive {:trace, ^registry, :receive,
                    {:"$gen_call", {^socket, _},
                     {:socket_native_retirement_result, incarnation, ^sink, ^close_ref, cutoff,
                      :ok}}},
                   1_000

    assert incarnation == row.connection_incarnation and cutoff == intent.cutoff
    assert_receive {:DOWN, ^socket_monitor, :process, ^socket, :normal}, 1_000
    assert_receive {:DOWN, ^control_monitor, :process, ^control, :normal}, 1_000
    assert now_ms() < intent.cutoff
    assert_receive {:trace, ^registry, :receive, {:holder_cleanup_result, _, ^token, :ok}}, 1_000

    assert_receive {:trace, ^registry, :receive,
                    {:relay_connection_retired, relay, ^incarnation}},
                   1_000

    assert relay == daemon.relay

    assert_receive {:trace, ^registry_guardian, :receive,
                    {:"$gen_call", {^registry, _}, {:close, ^registry_incarnation}}},
                   1_000

    assert_receive {:DOWN, ^registry_guardian_monitor, :process, ^registry_guardian, :normal},
                   1_000

    assert :ets.info(registry_arena) == :undefined
    assert_receive {:socket_close_answer, ^caller, :ok}, 1_000
    assert_receive {:DOWN, ^caller_monitor, :process, ^caller, :normal}, 1_000

    assert %{
             rows: rows,
             socket_retirement_controls: controls,
             progress_phase: :closed,
             close_all_failed: false
           } = :sys.get_state(registry)

    assert rows == %{} and controls == %{}
    refute_received {:daemon_component_fatal, _component, _class}
  end

  test "a blocked Socket native close is contained by its original cutoff without cleanup success",
       %{daemon: daemon, runtime: runtime} do
    {client, socket, _session, sink} = progress_client(daemon, runtime)
    {guardian, native_incarnation, arena} = sink
    socket_monitor = Process.monitor(socket)
    guardian_monitor = Process.monitor(guardian)
    :ok = :sys.suspend(guardian)
    on_exit(fn -> resume_actor(guardian) end)
    {caller, caller_monitor} = close_connections(daemon)

    eventually(fn ->
      case socket_row(daemon.registry, socket) do
        {_token, %{native_retirement: %{ready: true}}} -> true
        _ -> false
      end
    end)

    {_token, row} = socket_row(daemon.registry, socket)
    intent = row.native_retirement
    control_monitor = Process.monitor(intent.control)

    eventually(fn ->
      Enum.any?(elem(Process.info(guardian, :messages), 1), fn
        {:"$gen_call", {^socket, _}, {:close, ^native_incarnation}} -> true
        _ -> false
      end)
    end)

    assert :ets.info(arena) != :undefined
    assert intent.result == nil and intent.outcome == :pending
    assert [%{"type" => "daemon.stopping"}] = receive_records(client, 1)
    assert closed?(client)
    assert is_map(ConnectionRegistry.status(daemon.registry))
    assert_receive {:DOWN, ^socket_monitor, :process, ^socket, :killed}, 2_000
    assert now_ms() >= intent.cutoff
    assert_receive {:DOWN, ^control_monitor, :process, control, :normal}, 1_000
    assert control == intent.control
    assert Process.alive?(guardian) and :ets.info(arena) != :undefined
    assert_receive {:socket_close_answer, ^caller, {:error, :connections_lost}}, 1_000
    assert_receive {:DOWN, ^caller_monitor, :process, ^caller, :normal}, 1_000
    assert :sys.get_state(daemon.registry).close_all_failed
    resume_actor(guardian)
    assert_receive {:DOWN, ^guardian_monitor, :process, ^guardian, :normal}, 1_000
    assert :ets.info(arena) == :undefined
    refute_receive {:socket_close_answer, ^caller, :ok}, 0
  end

  test "Registry loss contains the actual Socket blocked in native close before its original cutoff",
       %{daemon: daemon, runtime: runtime} do
    {_client, socket, _session, sink} = progress_client(daemon, runtime)
    {guardian, native_incarnation, arena} = sink
    registry = daemon.registry
    socket_monitor = Process.monitor(socket)
    registry_monitor = Process.monitor(registry)
    guardian_monitor = Process.monitor(guardian)
    :ok = :sys.suspend(guardian)
    on_exit(fn -> resume_actor(guardian) end)
    {caller, caller_monitor} = close_connections(daemon)

    eventually(fn ->
      case socket_row(registry, socket) do
        {_token, %{native_retirement: %{ready: true}}} -> true
        _ -> false
      end
    end)

    {_token, row} = socket_row(registry, socket)
    intent = row.native_retirement
    control = intent.control
    control_monitor = Process.monitor(control)

    eventually(fn ->
      Enum.any?(elem(Process.info(guardian, :messages), 1), fn
        {:"$gen_call", {^socket, _}, {:close, ^native_incarnation}} -> true
        _ -> false
      end)
    end)

    assert intent.result == nil and intent.outcome == :pending
    assert Process.alive?(guardian) and :ets.info(arena) != :undefined

    # Concept: the retirement control contains Registry loss independently.
    # Technical depth: holding the actual Owner excludes its broader fail-stop
    # from this Socket kill; only the retained control can spend this interval.
    refute registry in elem(Process.info(socket, :links), 1)
    :ok = :sys.suspend(daemon.owner)
    on_exit(fn -> resume_actor(daemon.owner) end)
    remaining = intent.cutoff - now_ms()
    assert remaining > 0
    Process.exit(registry, :kill)
    assert_receive {:DOWN, ^registry_monitor, :process, ^registry, :killed}, remaining

    assert_receive {:DOWN, ^socket_monitor, :process, ^socket, :killed},
                   max(intent.cutoff - now_ms(), 0)

    assert now_ms() < intent.cutoff

    assert_receive {:DOWN, ^control_monitor, :process, ^control, :normal},
                   max(intent.cutoff - now_ms(), 0)

    assert now_ms() < intent.cutoff
    refute Process.alive?(socket)
    assert Process.alive?(guardian) and :ets.info(arena) != :undefined
    refute_receive {:socket_close_answer, ^caller, :ok}, 0
    resume_actor(daemon.owner)
    assert_receive {:socket_close_answer, ^caller, {:error, :connections_lost}}, 1_000
    assert_receive {:DOWN, ^caller_monitor, :process, ^caller, :normal}, 1_000
    resume_actor(guardian)
    assert_receive {:DOWN, ^guardian_monitor, :process, ^guardian, :normal}, 1_000
    assert :ets.info(arena) == :undefined
    refute_receive {:socket_close_answer, ^caller, :ok}, 0
  end

  test "control loss contains the actual Socket blocked in native close before its original cutoff",
       %{daemon: daemon, runtime: runtime} do
    {_client, socket, _session, sink} = progress_client(daemon, runtime)
    {guardian, native_incarnation, arena} = sink
    registry = daemon.registry
    socket_monitor = Process.monitor(socket)
    guardian_monitor = Process.monitor(guardian)
    :ok = :sys.suspend(guardian)
    on_exit(fn -> resume_actor(guardian) end)
    {caller, caller_monitor} = close_connections(daemon)

    eventually(fn ->
      case socket_row(registry, socket) do
        {_token, %{native_retirement: %{ready: true}}} -> true
        _ -> false
      end
    end)

    {_token, row} = socket_row(registry, socket)
    intent = row.native_retirement
    control = intent.control
    control_monitor = Process.monitor(control)

    eventually(fn ->
      Enum.any?(elem(Process.info(guardian, :messages), 1), fn
        {:"$gen_call", {^socket, _}, {:close, ^native_incarnation}} -> true
        _ -> false
      end)
    end)

    assert intent.result == nil and intent.outcome == :pending
    assert Process.alive?(guardian) and :ets.info(arena) != :undefined
    remaining = intent.cutoff - now_ms()
    assert remaining > 0
    Process.exit(control, :kill)
    assert_receive {:DOWN, ^control_monitor, :process, ^control, :killed}, remaining

    assert_receive {:DOWN, ^socket_monitor, :process, ^socket, :killed},
                   max(intent.cutoff - now_ms(), 0)

    assert now_ms() < intent.cutoff
    refute Process.alive?(socket)
    assert Process.alive?(guardian) and :ets.info(arena) != :undefined
    assert Process.alive?(registry)
    assert_receive {:socket_close_answer, ^caller, {:error, :connections_lost}}, 1_000
    assert_receive {:DOWN, ^caller_monitor, :process, ^caller, :normal}, 1_000
    assert :sys.get_state(registry).close_all_failed
    assert :sys.get_state(registry).rows == %{}
    assert :sys.get_state(registry).socket_retirement_controls == %{}
    resume_actor(guardian)
    assert_receive {:DOWN, ^guardian_monitor, :process, ^guardian, :normal}, 1_000
    assert :ets.info(arena) == :undefined
    refute_receive {:socket_close_answer, ^caller, :ok}, 0
  end

  test "a genuine Socket native reply without its guardian join stays unproved at the original cutoff",
       %{daemon: daemon, runtime: runtime} do
    {_client, socket, _session, sink} = progress_client(daemon, runtime)
    {guardian, incarnation, arena} = sink
    gate = make_ref()
    observer = self()
    socket_monitor = Process.monitor(socket)
    guardian_monitor = Process.monitor(guardian)

    :ok =
      :sys.install(
        guardian,
        {gate,
         fn
           :waiting, {:out, :ok, {^socket, _}, %{incarnation: ^incarnation}}, _extra ->
             send(observer, {:socket_native_reply_parked, gate})

             receive do
               {:continue_socket_native_reply, ^gate} -> :done
             end

           debug, _event, _extra ->
             debug
         end, :waiting}
      )

    on_exit(fn -> send(guardian, {:continue_socket_native_reply, gate}) end)
    {caller, caller_monitor} = close_connections(daemon)
    assert_receive {:socket_native_reply_parked, ^gate}, 1_000
    {_token, row} = socket_row(daemon.registry, socket)
    control = row.native_retirement.control
    control_monitor = Process.monitor(control)
    assert row.native_retirement.result == nil
    assert Process.alive?(guardian) and :ets.info(arena) != :undefined
    assert_receive {:DOWN, ^socket_monitor, :process, ^socket, :killed}, 2_000
    assert now_ms() >= row.native_retirement.cutoff
    assert_receive {:DOWN, ^control_monitor, :process, ^control, :normal}, 1_000
    assert_receive {:socket_close_answer, ^caller, {:error, :connections_lost}}, 1_000
    assert_receive {:DOWN, ^caller_monitor, :process, ^caller, :normal}, 1_000
    send(guardian, {:continue_socket_native_reply, gate})
    assert_receive {:DOWN, ^guardian_monitor, :process, ^guardian, :normal}, 1_000
    assert :ets.info(arena) == :undefined
    assert :sys.get_state(daemon.registry).close_all_failed
  end

  test "private Socket retirement rejects missing intent and stale exact correlations",
       %{daemon: daemon, runtime: runtime} do
    {_client, socket, _session, sink} = progress_client(daemon, runtime)
    registry = daemon.registry
    incarnation = :sys.get_state(socket).incarnation

    missing =
      {:socket_native_retirement_result, incarnation, sink, make_ref(), now_ms() + 1_000, :ok}

    assert {:error, :output_unavailable} = probe_socket_request(socket, registry, missing)
    gate = park_socket_terminal(socket, registry)
    socket_monitor = Process.monitor(socket)
    {caller, caller_monitor} = close_connections(daemon)
    assert_receive {:socket_terminal_parked, ^gate, close_ref}, 1_000
    {_token, row} = socket_row(registry, socket)
    cutoff = row.native_retirement.cutoff
    control = row.native_retirement.control
    control_monitor = Process.monitor(control)
    {guardian, _sink_incarnation, arena} = sink

    requests = [
      {:socket_native_retirement_result, incarnation, sink, make_ref(), cutoff, :ok},
      {:socket_native_retirement_result, "wrong", sink, close_ref, cutoff, :ok},
      {:socket_native_retirement_result, incarnation, {guardian, make_ref(), arena}, close_ref,
       cutoff, :ok},
      {:socket_native_retirement_result, incarnation, sink, close_ref, cutoff + 1, :ok}
    ]

    send(socket, {:probe_socket_terminal, gate, requests, self()})
    assert_receive {:socket_terminal_probe, ^gate, results}, 1_000
    assert Enum.all?(results, &(&1 == {:error, :output_unavailable}))
    exact = {:socket_native_retirement_result, incarnation, sink, close_ref, cutoff, :ok}
    assert {:error, :output_unavailable} = GenServer.call(registry, exact)

    assert %{native_retirement: %{result: nil, outcome: :pending}} =
             elem(socket_row(registry, socket), 1)

    send(socket, {:continue_socket_terminal, gate})
    assert_receive {:DOWN, ^socket_monitor, :process, ^socket, :normal}, 1_000
    assert_receive {:DOWN, ^control_monitor, :process, ^control, :normal}, 1_000
    assert_receive {:socket_close_answer, ^caller, :ok}, 1_000
    assert_receive {:DOWN, ^caller_monitor, :process, ^caller, :normal}, 1_000
    assert {:error, :output_unavailable} = GenServer.call(registry, exact)
    assert :sys.get_state(registry).rows == %{}
    refute_receive {:socket_close_answer, ^caller, _duplicate}, 0
  end

  test "a real terminal Socket result observed after its retained cutoff cannot repair cleanup",
       %{daemon: daemon, runtime: runtime} do
    {_client, socket, _session, sink} = progress_client(daemon, runtime)
    registry = daemon.registry
    socket_monitor = Process.monitor(socket)
    socket_gate = park_socket_terminal(socket, registry)
    gate = make_ref()
    observer = self()

    :ok =
      :sys.install(
        registry,
        {gate,
         fn
           :waiting,
           {:in,
            {:"$gen_call", {^socket, _},
             {:socket_native_retirement_result, _, ^sink, ref, cutoff, :ok}}},
           _extra ->
             send(observer, {:late_socket_result_parked, gate, ref, cutoff})

             receive do
               {:continue_late_socket_result, ^gate} -> :done
             end

           debug, _event, _extra ->
             debug
         end, :waiting}
      )

    on_exit(fn -> send(registry, {:continue_late_socket_result, gate}) end)
    {caller, caller_monitor} = close_connections(daemon)
    assert_receive {:socket_terminal_parked, ^socket_gate, _close_ref}, 1_000
    {_token, row} = socket_row(registry, socket)
    control = row.native_retirement.control
    control_monitor = Process.monitor(control)
    send(socket, {:continue_socket_terminal, socket_gate})
    assert_receive {:late_socket_result_parked, ^gate, _ref, cutoff}, 1_000
    assert_receive {:DOWN, ^socket_monitor, :process, ^socket, :normal}, 1_000
    assert_receive {:DOWN, ^control_monitor, :process, ^control, :normal}, 1_000
    wait_until(cutoff + 1)
    send(registry, {:continue_late_socket_result, gate})
    assert_receive {:socket_close_answer, ^caller, {:error, :connections_lost}}, 1_000
    assert_receive {:DOWN, ^caller_monitor, :process, ^caller, :normal}, 1_000
    assert :sys.get_state(registry).close_all_failed
    assert :sys.get_state(registry).rows == %{}
    {again, again_monitor} = close_connections(daemon)
    assert_receive {:socket_close_answer, ^again, {:error, :connections_lost}}, 1_000
    assert_receive {:DOWN, ^again_monitor, :process, ^again, :normal}, 1_000
  end

  # Concept: native evidence can arrive before the Registry consumes its original joins.
  # Technical depth: the real result is parked before its handler while the
  # original Socket and control exit normally. Their exact DOWNs remain queued
  # in the Registry; releasing before the same cutoff must retain the result
  # until those original joins prove retirement, without consulting a new monitor.
  test "a timely real Socket result survives its normally exited control's queued original DOWN",
       %{daemon: daemon, runtime: runtime} do
    {_client, socket, _session, sink} = progress_client(daemon, runtime)
    {guardian, _native_incarnation, arena} = sink
    registry = daemon.registry
    socket_monitor = Process.monitor(socket)
    guardian_monitor = Process.monitor(guardian)
    socket_gate = park_socket_terminal(socket, registry)
    gate = make_ref()
    observer = self()
    on_exit(fn -> send(registry, {:continue_timely_socket_result, gate}) end)

    :ok =
      :sys.install(
        registry,
        {gate,
         fn
           :waiting,
           {:in,
            {:"$gen_call", {^socket, _},
             {:socket_native_retirement_result, incarnation, ^sink, ref, cutoff, :ok}}},
           _extra ->
             send(observer, {:timely_socket_result_parked, gate, incarnation, ref, cutoff})

             receive do
               {:continue_timely_socket_result, ^gate} -> :done
             end

           debug, _event, _extra ->
             debug
         end, :waiting}
      )

    {caller, caller_monitor} = close_connections(daemon)
    assert_receive {:socket_terminal_parked, ^socket_gate, close_ref}, 1_000
    {_token, row} = socket_row(registry, socket)
    intent = row.native_retirement
    control = intent.control
    control_monitor = Process.monitor(control)
    original_control_monitor = intent.control_monitor
    original_socket_monitor = row.connection_monitor
    incarnation = row.connection_incarnation
    cutoff = intent.cutoff
    assert intent.ready and intent.result == nil and not intent.control_joined
    assert now_ms() < cutoff
    send(socket, {:continue_socket_terminal, socket_gate})

    assert_receive {:timely_socket_result_parked, ^gate, ^incarnation, ^close_ref, ^cutoff}, 1_000
    assert_receive {:DOWN, ^socket_monitor, :process, ^socket, :normal}, 1_000
    assert_receive {:DOWN, ^control_monitor, :process, ^control, :normal}, 1_000
    assert_receive {:DOWN, ^guardian_monitor, :process, ^guardian, :normal}, 1_000
    assert now_ms() < cutoff
    refute Process.alive?(control)

    eventually(fn ->
      assert now_ms() < cutoff
      assert {:messages, queued} = Process.info(registry, :messages)

      joined =
        {:DOWN, original_control_monitor, :process, control, :normal} in queued and
          {:DOWN, original_socket_monitor, :process, socket, :normal} in queued

      assert now_ms() < cutoff
      joined
    end)

    assert now_ms() < cutoff
    assert {:messages, messages} = Process.info(registry, :messages)
    assert {:DOWN, original_control_monitor, :process, control, :normal} in messages
    assert {:DOWN, original_socket_monitor, :process, socket, :normal} in messages
    assert now_ms() < cutoff
    send(registry, {:continue_timely_socket_result, gate})

    assert_receive {:socket_close_answer, ^caller, :ok}, 1_000
    assert_receive {:DOWN, ^caller_monitor, :process, ^caller, :normal}, 1_000
    assert :ets.info(arena) == :undefined

    assert %{
             rows: rows,
             socket_retirement_controls: controls,
             progress_phase: :closed,
             close_all_failed: false
           } = :sys.get_state(registry)

    assert rows == %{} and controls == %{}
    refute_received {:daemon_component_fatal, _component, _class}
    assert now_ms() < cutoff
  end

  test "actual cutoff-control loss supplies no native success from guardian and Socket normal DOWN",
       %{daemon: daemon, runtime: runtime} do
    {_client, socket, _session, sink} = progress_client(daemon, runtime)
    {guardian, _native_incarnation, arena} = sink
    registry = daemon.registry
    gate = park_socket_terminal(socket, registry)
    socket_monitor = Process.monitor(socket)
    guardian_monitor = Process.monitor(guardian)
    {caller, caller_monitor} = close_connections(daemon)
    assert_receive {:socket_terminal_parked, ^gate, _close_ref}, 1_000
    assert_receive {:DOWN, ^guardian_monitor, :process, ^guardian, :normal}, 1_000
    assert :ets.info(arena) == :undefined
    eventually(fn -> elem(socket_row(registry, socket), 1).native_retirement.guardian_joined end)
    {_token, row} = socket_row(registry, socket)
    control = row.native_retirement.control
    control_registry_monitor = row.native_retirement.control_monitor
    cutoff = row.native_retirement.cutoff
    assert row.native_retirement.result == nil
    registry_gate = make_ref()
    observer = self()

    :ok =
      :sys.install(
        registry,
        {registry_gate,
         fn
           :waiting,
           {:in, {:DOWN, ^control_registry_monitor, :process, ^control, :killed}},
           _extra ->
             send(observer, {:socket_control_down_parked, registry_gate})

             receive do
               {:continue_socket_control_down, ^registry_gate} -> :done
             end

           debug, _event, _extra ->
             debug
         end, :waiting}
      )

    on_exit(fn -> send(registry, {:continue_socket_control_down, registry_gate}) end)
    monitor = Process.monitor(control)
    Process.exit(control, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^control, :killed}, 1_000
    assert_receive {:socket_control_down_parked, ^registry_gate}, max(cutoff - now_ms(), 0)
    send(socket, {:continue_socket_terminal, gate})
    assert_receive {:DOWN, ^socket_monitor, :process, ^socket, :normal}, max(cutoff - now_ms(), 0)
    assert now_ms() < cutoff
    send(registry, {:continue_socket_control_down, registry_gate})
    assert_receive {:socket_close_answer, ^caller, {:error, :connections_lost}}, 1_000
    assert_receive {:DOWN, ^caller_monitor, :process, ^caller, :normal}, 1_000
    assert :sys.get_state(registry).close_all_failed
  end

  test "an actual progress emission ACK pending cannot qualify by clearing native custody",
       %{daemon: daemon, runtime: runtime} do
    {client, socket, session, sink} = progress_client(daemon, runtime)
    registry = daemon.registry
    incarnation = :sys.get_state(socket).incarnation
    {guardian, _, _arena} = sink
    gate = make_ref()
    observer = self()
    1 = :erlang.trace(guardian, true, [:receive])
    socket_monitor = Process.monitor(socket)

    :ok =
      :sys.install(
        registry,
        {gate,
         fn
           :waiting,
           {:in, {:"$gen_call", {^socket, _}, {:output_emitted, ^incarnation, frame_ref}}},
           _extra ->
             send(observer, {:socket_emission_held, gate, frame_ref})

             receive do
               {:continue_socket_emission, ^gate} -> :done
             end

           debug, _event, _extra ->
             debug
         end, :waiting}
      )

    on_exit(fn -> send(registry, {:continue_socket_emission, gate}) end)
    :ok = Loopex.ProgressSink.try_offer(sink, session, progress_item(1))
    assert [%{"type" => "progress"}] = receive_records(client, 1)
    assert_receive {:socket_emission_held, ^gate, frame_ref}, 1_000
    before_close = :sys.get_state(socket)
    assert Map.has_key?(before_close.progress_frames, frame_ref)
    assert map_size(before_close.progress_leases) == 1
    assert before_close.progress_bytes > 0
    {caller, caller_monitor} = close_connections(daemon)
    owner = daemon.owner

    eventually(fn ->
      Enum.any?(elem(Process.info(registry, :messages), 1), fn
        {:owner_request, ^owner, _, {:close_all, _, _}} -> true
        _ -> false
      end)
    end)

    send(socket, {:daemon_stopping, WireRecords.daemon_stopping("operator_stop")})
    eventually(fn -> :sys.get_state(socket).closing != nil end)
    closing = :sys.get_state(socket)
    assert closing.closing.owner == nil and closing.closing.retirement == nil
    assert closing.progress_frames == before_close.progress_frames
    assert closing.progress_leases == before_close.progress_leases
    assert closing.progress_bytes == before_close.progress_bytes
    cutoff = closing.closing.cutoff
    assert_receive {:DOWN, ^socket_monitor, :process, ^socket, :normal}, 2_000
    assert now_ms() >= cutoff
    refute_received {:trace, ^guardian, :receive, {:"$gen_call", {^socket, _}, {:close, _}}}
    send(registry, {:continue_socket_emission, gate})
    assert_receive {:socket_close_answer, ^caller, {:error, :connections_lost}}, 1_000
    assert_receive {:DOWN, ^caller_monitor, :process, ^caller, :normal}, 1_000
    assert :sys.get_state(registry).close_all_failed
    assert :sys.get_state(registry).socket_retirement_controls == %{}
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

          assert {:noreply, next} =
                   LoopexDaemon.SocketConnection.handle_info(
                     {:loopex_progress_ready, sink},
                     state
                   )

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

    for {lease, _} <- :queue.to_list(queued.progress),
        do: assert(:ok == Loopex.ProgressSink.release(sink, lease))

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
      kind: :tool_progress,
      turn_id: bytes,
      tool_call_id: bytes,
      stream_domain_id: "0123456789abcdef0123456789abcdef",
      progress_sequence: 0,
      base_event_sequence: 0,
      stream: "stdout",
      byte_offset: 0,
      chunk: String.duplicate("x", 65_536)
    }

    assert :dropped = Loopex.ProgressSink.try_offer(sink, "session", byte_pressure)
    fitting = %{large | text: String.duplicate("x", 30_000)}
    assert :ok = Loopex.ProgressSink.try_offer(sink, "session", fitting)
    assert_receive {:loopex_progress_ready, ^sink}, 1_000

    assert {:noreply, one} =
             LoopexDaemon.SocketConnection.handle_info({:loopex_progress_ready, sink}, state)

    assert :queue.len(one.progress) == 1
    assert map_size(one.progress_leases) == 1
    [{lease, encoded}] = :queue.to_list(one.progress)
    assert byte_size(encoded) == one.progress_bytes
    assert one.progress_bytes > 30_000 and one.progress_bytes <= 524_288
    {_guardian, native_incarnation, arena} = sink

    [{:state, ^native_incarnation, owner, _status, native_bytes, slots, _ready}] =
      :ets.lookup(arena, :state)

    assert owner == self()
    {^native_incarnation, slot, token} = lease
    assert {^token, :leased, ^owner, charge} = elem(slots, slot)
    assert native_bytes == charge and native_bytes <= 524_288
    assert native_bytes + charge > 524_288

    assert :dropped =
             Loopex.ProgressSink.try_offer(sink, "session", %{fitting | model_sequence: 1})

    assert {:ok, record} =
             LoopexProtocol.Frame.decode(
               String.trim_trailing(encoded, "\n"),
               LoopexProtocol.Frame.output_record_bytes()
             )

    assert record["progress"]["text"] == fitting.text
    assert :ok = Loopex.ProgressSink.release(sink, lease)
    assert :ok = Loopex.ProgressSink.close(sink)
  end

  # Concept: a fixture observes creation startup before its single native create.
  # Technical depth: the public snapshot retains the literal original startup
  # identity and deadline under one finite observation cutoff; no create is probed.
  defp await_creation_startup(runtime) do
    cutoff = now_ms() + 1_000
    assert {:ok, snapshot} = Loopex.creation_startup_status(runtime, 1_000)
    await_creation_startup(runtime, snapshot, min(cutoff, snapshot.startup_deadline_ms))
  end

  defp await_creation_startup(runtime, snapshot, cutoff) do
    remaining = cutoff - now_ms()
    assert remaining > 0

    case snapshot.state do
      :ready ->
        :ok

      :starting ->
        receive do
        after
          min(10, remaining) -> :ok
        end

        remaining = cutoff - now_ms()
        assert remaining > 0
        assert {:ok, next} = Loopex.creation_startup_status(runtime, min(1_000, remaining))
        assert next.startup_id == snapshot.startup_id
        assert next.startup_deadline_ms == snapshot.startup_deadline_ms
        await_creation_startup(runtime, next, cutoff)

      unavailable ->
        flunk("original creation startup unavailable: #{inspect(unavailable)}")
    end
  end

  # Concept: retirement proofs begin with public creation/attachment and real credit.
  # Technical depth: the accepted emission reply, not physical send alone, ends
  # external custody. No constructed Socket state or fake native close is used.
  defp progress_client(daemon, runtime) do
    client = initialized_client(daemon)
    [socket] = initialized_connections(daemon)

    :ok =
      send_frame(client, %{
        "method" => "session.create",
        "request_id" => "close-create",
        "command_id" => Wire.encode_identity("close-create"),
        "session_options" => %{"version" => 1}
      })

    assert [%{"type" => "admission", "status" => "accepted", "session_id" => encoded}] =
             receive_records(client, 1)

    assert {:ok, session} = Wire.identity(encoded)
    assert {:ok, %{event_sequence: cursor}} = Loopex.session_status(runtime, session)

    :ok =
      send_frame(client, %{
        "method" => "session.attach",
        "request_id" => "close-attach",
        "session_id" => encoded,
        "after_event_sequence" => Wire.encode_u64(cursor)
      })

    assert [%{"type" => "snapshot"}] = receive_records(client, 1)
    sink = :sys.get_state(socket).progress_sink

    :ok =
      Loopex.ProgressSink.try_offer(sink, session, %{
        progress_item(0)
        | base_event_sequence: cursor
      })

    assert [%{"type" => "progress", "progress" => %{"text" => "retirement-proof"}}] =
             receive_records(client, 1)

    eventually(fn ->
      state = :sys.get_state(socket)

      map_size(state.progress_leases) == 0 and map_size(state.progress_frames) == 0 and
        state.progress_bytes == 0 and :queue.is_empty(state.progress) and
        state.enqueues_pending == 0 and :queue.is_empty(state.output_cursors) and
        state.output_claim == nil and state.send_select == nil and
        not Enum.any?(state.exchanges, fn {_id, exchange} ->
          elem(exchange.label, 0) in [:enqueue, :enqueue_progress, :claim, :emitted]
        end)
    end)

    {client, socket, session, sink}
  end

  defp progress_item(sequence) do
    %{
      kind: :text_delta,
      turn_id: "turn",
      text: "retirement-proof",
      stream_domain_id: "0123456789abcdef0123456789abcdef",
      model_sequence: sequence,
      content_index: 0,
      base_event_sequence: 0
    }
  end

  defp close_connections(daemon) do
    observer = self()

    {caller, monitor} =
      spawn_monitor(fn ->
        result =
          Owner.close_connections(
            daemon.owner,
            WireRecords.daemon_stopping("operator_stop"),
            now_ms() + 5_000
          )

        send(observer, {:socket_close_answer, self(), result})
      end)

    on_exit(fn -> if Process.alive?(caller), do: Process.exit(caller, :kill) end)
    {caller, monitor}
  end

  defp socket_row(registry, socket),
    do:
      Enum.find(:sys.get_state(registry).rows, fn {_token, row} ->
        row.connection_pid == socket
      end)

  defp park_socket_terminal(socket, registry) do
    gate = make_ref()
    observer = self()

    :ok =
      :sys.install(
        socket,
        {gate,
         fn
           :waiting, {:in, {:socket_native_retirement, close_ref}}, _extra ->
             send(observer, {:socket_terminal_parked, gate, close_ref})
             await_socket_terminal(gate, registry)

           debug, _event, _extra ->
             debug
         end, :waiting}
      )

    on_exit(fn -> send(socket, {:continue_socket_terminal, gate}) end)
    gate
  end

  defp await_socket_terminal(gate, registry) do
    receive do
      {:continue_socket_terminal, ^gate} ->
        :done

      {:probe_socket_terminal, ^gate, requests, observer} ->
        results = Enum.map(requests, &GenServer.call(registry, &1, 100))
        send(observer, {:socket_terminal_probe, gate, results})
        await_socket_terminal(gate, registry)
    end
  end

  defp probe_socket_request(socket, registry, request) do
    gate = make_ref()
    observer = self()

    :ok =
      :sys.install(
        socket,
        {gate,
         fn
           :waiting, {:in, {:probe_socket_request, ^gate}}, _extra ->
             result = GenServer.call(registry, request, 100)
             send(observer, {:socket_request_probe, gate, result})
             :done

           debug, _event, _extra ->
             debug
         end, :waiting}
      )

    send(socket, {:probe_socket_request, gate})
    assert_receive {:socket_request_probe, ^gate, result}, 1_000
    result
  end

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp wait_until(cutoff) do
    remaining = cutoff - now_ms()

    if remaining > 0 do
      receive do
      after
        remaining -> :ok
      end

      wait_until(cutoff)
    end
  end

  defp resume_actor(actor) do
    try do
      :sys.resume(actor)
    catch
      :exit, _ -> :ok
    end
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
