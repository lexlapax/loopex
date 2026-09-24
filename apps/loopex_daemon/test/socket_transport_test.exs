Code.require_file("support/daemon_socket_fixture.exs", __DIR__)

defmodule LoopexDaemon.SocketTransportTest do
  use ExUnit.Case, async: true
  @moduletag capture_log: true

  import LoopexDaemon.Test.DaemonSocketFixture

  alias LoopexDaemon.{AdmissionRelay, ConnectionRegistry, LeaseOwner, WireRecords}
  alias LoopexProtocol.Wire

  setup do
    root = temporary_directory("loopex-socket-transport")
    runtime = start_runtime(root)
    %{runtime: runtime, daemon: start_daemon(runtime)}
  end

  test "create spends one activation and an exact replay returns the same session",
       %{daemon: daemon, runtime: runtime} do
    client = initialized_client(daemon)

    :ok = send_frame(client, create("c1", "create-a", %{"purpose" => "socket"}))

    assert [
             %{
               "type" => "admission",
               "request_id" => "c1",
               "method" => "session.create",
               "status" => "accepted",
               "reason" => nil,
               "session_id" => encoded
             } = admission
           ] = receive_records(client, 1)

    assert admission["command_id"] == Wire.encode_identity("create-a")
    {:ok, session_id} = Wire.identity(encoded)
    assert {:ok, :present} = Loopex.Runtime.session_existence(runtime, session_id)
    assert %{activations_used: 1, active_sessions: 1} = ConnectionRegistry.status(daemon.registry)

    :ok = send_frame(client, create("c2", "create-a", %{"purpose" => "socket"}))

    assert [%{"request_id" => "c2", "status" => "accepted", "session_id" => ^encoded}] =
             receive_records(client, 1)

    assert %{activations_used: 1} = ConnectionRegistry.status(daemon.registry)

    :ok = send_frame(client, create("c3", "create-a", %{"purpose" => "changed"}))

    assert [
             %{
               "request_id" => "c3",
               "status" => "refused",
               "reason" => "runtime_command_conflict"
             } = refused
           ] = receive_records(client, 1)

    refute Map.has_key?(refused, "session_id")
    assert %{activations_used: 1} = ConnectionRegistry.status(daemon.registry)
    eventually(fn -> AdmissionRelay.status(daemon.relay).tickets == 0 end)
  end

  @tag timeout: 120_000
  test "the sixty-fifth fresh create refuses while a historical replay still answers",
       %{daemon: daemon} do
    client = initialized_client(daemon)

    first =
      for index <- 1..64 do
        :ok = send_frame(client, create("c#{index}", "create-#{index}", %{"n" => index}))

        assert [%{"request_id" => request_id, "status" => "accepted", "session_id" => encoded}] =
                 receive_records(client, 1, 5_000)

        assert request_id == "c#{index}"
        encoded
      end
      |> hd()

    assert %{activations_used: 64} = ConnectionRegistry.status(daemon.registry)

    :ok = send_frame(client, create("c65", "create-65", %{"n" => 65}))

    assert [
             %{
               "type" => "error",
               "request_id" => "c65",
               "code" => "activation_ceiling_reached"
             }
           ] = receive_records(client, 1)

    :ok = send_frame(client, create("replay", "create-1", %{"n" => 1}))

    assert [%{"request_id" => "replay", "status" => "accepted", "session_id" => ^first}] =
             receive_records(client, 1)

    assert %{activations_used: 64} = ConnectionRegistry.status(daemon.registry)
  end

  # Concept: the activation ceiling holds under concurrency: at 63 activations,
  # a create and a resume arriving at once on two connections activate exactly
  # one session, and the other is refused `activation_ceiling_reached`.
  @tag timeout: 120_000
  test "at 63 activations two concurrent activations admit exactly one" do
    root = temporary_directory("loopex-socket-race")
    {runtime, [dormant]} = start_runtime_with_dormant(root, 1)
    daemon = start_daemon(runtime)
    filler = initialized_client(daemon)

    for index <- 1..63 do
      :ok = send_frame(filler, create("f#{index}", "race-fill-#{index}", %{"n" => index}))
      assert [%{"status" => "accepted"}] = receive_records(filler, 1, 5_000)
    end

    creator = initialized_client(daemon)
    resumer = initialized_client(daemon)
    :ok = send_frame(resumer, acquire("acquire", dormant))
    assert [%{"result" => %{"writer_epoch" => encoded_epoch}}] = receive_records(resumer, 1)
    {:ok, epoch} = Wire.identity(encoded_epoch)

    :ok = send_frame(creator, create("race-create", "race-create", %{"n" => 64}))
    :ok = send_frame(resumer, resume("race-resume", dormant, "race-resume", epoch))
    [created] = receive_records(creator, 1, 10_000)
    [resumed] = receive_records(resumer, 1, 10_000)

    outcomes =
      Enum.map([created, resumed], fn record ->
        cond do
          record["status"] == "accepted" -> :activated
          record["code"] == "activation_ceiling_reached" -> :refused
          true -> {:unexpected, record}
        end
      end)

    assert Enum.sort(outcomes) == [:activated, :refused]
    assert %{activations_used: 64} = ConnectionRegistry.status(daemon.registry)
  end

  test "attach delivers the snapshot and then every later durable event in order",
       %{daemon: daemon, runtime: runtime} do
    client = initialized_client(daemon)
    session_id = create_session(client, "attach-create")

    :ok = send_frame(client, attach("a1", session_id, after: 0))

    assert [
             %{
               "type" => "snapshot",
               "request_id" => "a1",
               "event_cursor" => "0",
               "snapshot" => %{"event_sequence" => "0"}
             }
           ] = receive_records(client, 1)

    {:ok, embedded} = Loopex.attach(runtime, session_id)

    assert {:accepted, "p1"} =
             Loopex.command(embedded, %{type: :prompt, command_id: "p1", content: "hello"})

    assert [
             %{
               "type" => "event",
               "session_id" => encoded,
               "event" => %{"event_sequence" => "1", "kind" => "user.message_appended"}
             }
           ] = receive_records(client, 1)

    assert encoded == Wire.encode_identity(session_id)
    assert %{succession_reservations: 1} = ConnectionRegistry.status(daemon.registry)
  end

  test "attach refuses a session this daemon lifetime has not activated",
       %{daemon: daemon, runtime: runtime} do
    {:ok, dormant} =
      Loopex.create_session(runtime, %{"purpose" => "embedded"}, command_id: "embedded")

    client = initialized_client(daemon)
    :ok = send_frame(client, attach("dormant", dormant))

    assert [%{"request_id" => "dormant", "code" => "session_dormant"}] =
             receive_records(client, 1)

    assert %{succession_reservations: 0} = ConnectionRegistry.status(daemon.registry)

    active = create_session(client, "after-dormant")
    :ok = send_frame(client, attach("active", active))
    assert [%{"request_id" => "active", "type" => "snapshot"}] = receive_records(client, 1)
  end

  test "a connection holds one attachment and replaces it only when asked",
       %{daemon: daemon} do
    client = initialized_client(daemon)
    session_id = create_session(client, "replace-create")

    :ok = send_frame(client, attach("first", session_id))
    assert [%{"request_id" => "first", "type" => "snapshot"}] = receive_records(client, 1)

    :ok = send_frame(client, attach("second", session_id))

    assert [
             %{
               "request_id" => "second",
               "code" => "attachment_conflict",
               "message" => "another attachment holds this session"
             }
           ] = receive_records(client, 1)

    :ok = send_frame(client, attach("replace", session_id, replace: true))
    assert [%{"request_id" => "replace", "type" => "snapshot"}] = receive_records(client, 1)
    assert %{succession_reservations: 1} = ConnectionRegistry.status(daemon.registry)
  end

  # Concept: the connection marks a requested replacement as pending when it
  # dispatches it, so the replaced attachment's pump ending before the new one
  # is installed keeps the connection.
  #
  # Technical depth: Control is suspended so the replacement's core attach
  # cannot complete; once the connection shows the mark, the old pump is ended
  # as core's removal ends it, and Control is resumed.
  test "a pending replacement is marked at dispatch and survives its old pump ending",
       %{daemon: daemon, runtime: runtime} do
    client = initialized_client(daemon)
    session_id = create_session(client, "replace-marked-create")
    :ok = send_frame(client, attach("first", session_id))
    assert [%{"request_id" => "first", "type" => "snapshot"}] = receive_records(client, 1)
    connection = initialized_connection(daemon)
    %{attachment: %{pump: pump}} = :sys.get_state(connection)

    {:ok, children} = Loopex.Runtime.children(runtime)
    :ok = :sys.suspend(children.control)
    :ok = send_frame(client, attach("replace", session_id, replace: true))
    eventually(fn -> match?(%{attachment: %{replacing: _origin}}, :sys.get_state(connection)) end)

    Process.exit(pump, :kill)
    eventually(fn -> match?(%{attachment: %{pump_ended: true}}, :sys.get_state(connection)) end)
    :ok = :sys.resume(children.control)

    assert [%{"request_id" => "replace", "type" => "snapshot"}] = receive_records(client, 1)
    assert Process.alive?(connection)
  end

  # Concept: the pending-replacement mark belongs to the request that set it,
  # so a second replacement the client sends meanwhile, which the registry
  # refuses as already pending, can neither take it over nor end it, and the
  # first replacement still completes.
  #
  # Technical depth: Control is suspended so the replacement stays pending; a
  # second replacement then passes the connection's own checks and is refused
  # by the registry because this connection's attachment is pending; then the
  # old pump ends as core's removal ends it, and Control is resumed.
  test "an attach refused while a replacement is pending leaves the replacement marked",
       %{daemon: daemon, runtime: runtime} do
    client = initialized_client(daemon)
    session_id = create_session(client, "replace-pipelined-create")
    :ok = send_frame(client, attach("first", session_id))
    assert [%{"request_id" => "first", "type" => "snapshot"}] = receive_records(client, 1)
    connection = initialized_connection(daemon)
    %{attachment: %{pump: pump}} = :sys.get_state(connection)

    {:ok, children} = Loopex.Runtime.children(runtime)
    :ok = :sys.suspend(children.control)
    :ok = send_frame(client, attach("replace", session_id, replace: true))
    eventually(fn -> match?(%{attachment: %{replacing: _origin}}, :sys.get_state(connection)) end)

    :ok = send_frame(client, attach("second", session_id, replace: true))
    assert [%{"request_id" => "second", "type" => "error"}] = receive_records(client, 1)

    assert match?(%{attachment: %{replacing: _origin}}, :sys.get_state(connection))

    Process.exit(pump, :kill)
    eventually(fn -> match?(%{attachment: %{pump_ended: true}}, :sys.get_state(connection)) end)
    :ok = :sys.resume(children.control)

    assert [%{"request_id" => "replace", "type" => "snapshot"}] = receive_records(client, 1)
    assert Process.alive?(connection)
  end

  # Concept: a replacement that fails after its old attachment's pump ended leaves
  # the client no attachment, so it is told `detached` after the refusal and
  # the connection closes, which releases its delivery reserve.
  test "a replacement refused after its old pump ended reports detached and closes",
       %{daemon: daemon, runtime: runtime} do
    client = initialized_client(daemon)
    session_id = create_session(client, "replace-lost-create")
    :ok = send_frame(client, attach("first", session_id))
    assert [%{"request_id" => "first", "type" => "snapshot"}] = receive_records(client, 1)
    connection = initialized_connection(daemon)
    %{attachment: %{pump: pump}} = :sys.get_state(connection)
    connection_monitor = Process.monitor(connection)

    {:ok, children} = Loopex.Runtime.children(runtime)
    :ok = :sys.suspend(children.control)
    :ok = send_frame(client, attach("replace", session_id, replace: true))
    eventually(fn -> match?(%{attachment: %{replacing: _origin}}, :sys.get_state(connection)) end)

    Process.exit(pump, :kill)
    eventually(fn -> match?(%{attachment: %{pump_ended: true}}, :sys.get_state(connection)) end)

    # The replacement's core attach is blocked on Control; ending Control makes
    # it fail after dispatch, so it is refused with the old pump already gone.
    Process.exit(children.control, :kill)

    assert [%{"request_id" => "replace", "type" => "error"}] = receive_records(client, 1)
    assert [%{"type" => "error", "code" => "detached"}] = receive_records(client, 1)
    assert_receive {:DOWN, ^connection_monitor, :process, ^connection, _reason}, 5_000
  end

  test "the session's mutation gate sees an attachment before its snapshot and forgets it on close",
       %{daemon: daemon} do
    client = initialized_client(daemon)
    session_id = create_session(client, "gate-create")

    :ok = send_frame(client, acquire("acquire", session_id))
    assert [%{"request_id" => "acquire", "type" => "result"}] = receive_records(client, 1)
    [lease_owner] = lease_owner_pids(daemon)
    assert %{attachments: 0} = LeaseOwner.status(lease_owner)

    :ok = send_frame(client, attach("attach", session_id))
    assert [%{"request_id" => "attach", "type" => "snapshot"}] = receive_records(client, 1)
    assert %{attachments: 1} = LeaseOwner.status(lease_owner)

    :ok = :socket.close(client)
    eventually(fn -> LeaseOwner.status(lease_owner).attachments == 0 end)
    eventually(fn -> ConnectionRegistry.status(daemon.registry).succession_reservations == 0 end)
  end

  test "a recorded session this composition cannot serve refuses at resume by name" do
    root = temporary_directory("loopex-socket-mismatch")
    [recorded] = seed_dormant(root, 1, "recorded-placement")
    mismatched = start_runtime(root, "another-placement")
    daemon = start_daemon(mismatched)
    client = initialized_client(daemon)

    :ok = send_frame(client, acquire("acquire", recorded))
    assert [%{"request_id" => "acquire", "result" => granted}] = receive_records(client, 1)
    {:ok, epoch} = Wire.identity(granted["writer_epoch"])

    :ok =
      send_frame(client, %{
        "method" => "session.resume",
        "request_id" => "resume",
        "session_id" => Wire.encode_identity(recorded),
        "command_id" => Wire.encode_identity("resume-mismatch"),
        "writer_epoch" => Wire.encode_identity(epoch)
      })

    assert [
             %{
               "type" => "error",
               "request_id" => "resume",
               "code" => "composition_mismatch",
               "message" => "session cannot be activated by this daemon composition"
             }
           ] = receive_records(client, 1)

    assert %{activations_used: 0, active_sessions: 0} = ConnectionRegistry.status(daemon.registry)
  end

  test "inspect answers an active session's public status and refuses an inactive one" do
    root = temporary_directory("loopex-socket-inspect")
    [dormant] = seed_dormant(root, 1, "inspect-placement")
    daemon = start_daemon(start_runtime(root, "inspect-placement"))
    client = initialized_client(daemon)
    session_id = create_session(client, "inspect-create")

    :ok = send_frame(client, inspect_request("inspect", session_id))

    assert [
             %{
               "type" => "result",
               "request_id" => "inspect",
               "method" => "session.inspect",
               "result" => %{"event_sequence" => "0", "pending_work_ids" => []} = status
             }
           ] = receive_records(client, 1)

    refute Map.has_key?(status, "owner_epoch")

    other_client = initialized_client(daemon)
    :ok = send_frame(other_client, inspect_request("dormant", dormant))

    assert [%{"request_id" => "dormant", "code" => "session_unavailable"}] =
             receive_records(other_client, 1)
  end

  # Concept: a session whose coordinator died is still this daemon's active
  # session, but reading its state says it is unavailable and nothing can
  # change it; restarting the daemon and resuming the session repairs it.
  test "a killed coordinator is unavailable until a restart and resume repair it" do
    root = temporary_directory("loopex-killed-coordinator")
    {runtime, adapter} = runtime_with_adapter(root)
    daemon = start_daemon(runtime)
    client = initialized_client(daemon)
    session_id = create_session(client, "killed-create")

    # Other cases run concurrently, so only this runtime's coordinator counts.
    [coordinator] =
      for pid <- Process.list(),
          {:dictionary, dictionary} <- [Process.info(pid, :dictionary)],
          match?({Loopex.Runtime.SessionCoordinator, _, _}, dictionary[:"$initial_call"]),
          runtime.supervisor in Keyword.get(dictionary, :"$ancestors", []),
          do: pid

    Process.exit(coordinator, :kill)

    # Attaching reads durable history, so it may still succeed until core has
    # processed the coordinator's death; an attach the death cuts is superseded,
    # which the daemon answers `attachment_conflict`; after that it is refused
    # `session_unavailable`.
    :ok = send_frame(client, attach("attach", session_id))
    assert [attached] = receive_records(client, 1)

    assert attached["type"] == "snapshot" or
             attached["code"] in ["session_unavailable", "attachment_conflict"],
           inspect(attached)

    :ok = send_frame(client, inspect_request("inspect", session_id))

    assert [%{"request_id" => "inspect", "code" => "session_unavailable"}] =
             receive_records(client, 1)

    :ok = GenServer.stop(daemon.owner, :normal)
    :ok = Loopex.stop(runtime)
    :ok = GenServer.stop(adapter)

    {runtime, _adapter} = runtime_with_adapter(root)
    restarted = start_daemon(runtime)
    repair = initialized_client(restarted)
    :ok = send_frame(repair, acquire("acquire", session_id))
    assert [%{"result" => %{"writer_epoch" => encoded_epoch}}] = receive_records(repair, 1)
    {:ok, epoch} = Wire.identity(encoded_epoch)
    :ok = send_frame(repair, resume("resume", session_id, "killed-resume", epoch))
    assert [%{"request_id" => "resume", "status" => "accepted"}] = receive_records(repair, 1)
    :ok = send_frame(repair, inspect_request("again", session_id))
    assert [%{"request_id" => "again", "type" => "result"}] = receive_records(repair, 1)
  end

  defp runtime_with_adapter(root) do
    {:ok, adapter} = Loopex.Store.Local.start_link(path: Path.join(root, "store.log"))
    Process.unlink(adapter)
    {:ok, store} = Loopex.Store.new(Loopex.Store.Local, adapter)

    {:ok, runtime} =
      Loopex.start_link(runtime_id: "killed-placement", store: store, context_token_budget: 8_192)

    {runtime, adapter}
  end

  # Concept: a session the daemon activated but could not record in its index
  # is still created; the creating client is told so with `daemon.notice`
  # `index_write_failed`, and the session is fully usable.
  #
  # Technical depth: a temporary the index did not create is planted in its
  # private directory, which poisons the next publication on the real
  # filesystem. A `session.create` is then accepted, the notice follows naming
  # that session, and the session can still be attached.
  test "a session the index cannot record is created with an index_write_failed notice" do
    root = temporary_directory("loopex-socket-notice")
    runtime = start_runtime(root, "notice-placement")
    state = Path.join(root, "state")
    daemon = start_daemon(runtime, index_root: state, placement_identity: "notice-placement")
    File.write!(Path.join([state, "daemon", "session-index-v1.next"]), "planted")
    client = initialized_client(daemon)

    :ok = send_frame(client, create("create", "notice-create", %{}))

    # The notice is written while the session activates, so it may precede the
    # admission; both name the same session.
    records = receive_records(client, 2)
    assert %{"session_id" => encoded} = Enum.find(records, &(&1["status"] == "accepted"))

    assert %{"session_id" => ^encoded} =
             Enum.find(
               records,
               &(&1["type"] == "daemon.notice" and &1["code"] == "index_write_failed")
             )

    {:ok, session_id} = Wire.identity(encoded)
    :ok = send_frame(client, attach("attach", session_id))
    assert [%{"request_id" => "attach", "type" => "snapshot"}] = receive_records(client, 1)
  end

  test "session.list pages recorded sessions with residency and control" do
    root = temporary_directory("loopex-socket-list")
    [dormant] = seed_dormant(root, 1, "list-placement")
    runtime = start_runtime(root, "list-placement")
    state = Path.join(root, "state")
    daemon = start_daemon(runtime, index_root: state, placement_identity: "list-placement")
    client = initialized_client(daemon)

    :ok = send_frame(client, list("empty", 10))

    assert [%{"request_id" => "empty", "result" => %{"entries" => []} = empty}] =
             receive_records(client, 1)

    refute Map.has_key?(empty, "next_after_session_id")
    refute Map.has_key?(empty, "index_full")

    first = create_session(client, "list-a")
    second = create_session(client, "list-b")
    [low, high] = Enum.sort([first, second])

    :ok = send_frame(client, acquire("acquire", high))
    assert [%{"request_id" => "acquire", "type" => "result"}] = receive_records(client, 1)

    :ok = send_frame(client, list("page-1", 1))

    assert [
             %{
               "request_id" => "page-1",
               "method" => "session.list",
               "result" => %{
                 "entries" => [
                   %{
                     "session_id" => low_encoded,
                     "placement_identity" => placement,
                     "residency" => "active",
                     "controlled" => false
                   }
                 ],
                 "next_after_session_id" => next
               }
             }
           ] = receive_records(client, 1)

    assert low_encoded == Wire.encode_identity(low)
    assert placement == Wire.encode_identity("list-placement")
    {:ok, after_id} = Wire.identity(next)

    :ok =
      send_frame(client, %{
        "method" => "session.list",
        "request_id" => "page-2",
        "limit" => 1,
        "after_session_id" => Wire.encode_identity(after_id)
      })

    assert [
             %{
               "request_id" => "page-2",
               "result" => %{
                 "entries" => [%{"residency" => "active", "controlled" => true} = entry]
               }
             }
           ] = receive_records(client, 1)

    assert entry["session_id"] == Wire.encode_identity(high)
    refute Enum.member?([low, high], dormant)
  end

  @tag timeout: 120_000
  test "only a resume that activates publishes; a completed replay records nothing" do
    root = temporary_directory("loopex-socket-publish")
    [session_id] = seed_dormant(root, 1, "publish-placement")

    # A previous lifetime completed resume command `resume-seen`.
    {:ok, adapter} = Loopex.Store.Local.start_link(path: Path.join([root, "state", "store.log"]))
    {:ok, store} = Loopex.Store.new(Loopex.Store.Local, adapter)

    {:ok, previous} =
      Loopex.start_link(
        runtime_id: "publish-placement",
        store: store,
        context_token_budget: 8_192
      )

    {:ok, ^session_id} = Loopex.resume_session(previous, session_id, command_id: "resume-seen")
    :ok = Loopex.stop(previous)
    :ok = GenServer.stop(adapter)

    runtime = start_runtime(root, "publish-placement")
    state = Path.join(root, "state")
    daemon = start_daemon(runtime, index_root: state, placement_identity: "publish-placement")
    client = initialized_client(daemon)

    :ok = send_frame(client, acquire("acquire", session_id))
    assert [%{"request_id" => "acquire", "result" => granted}] = receive_records(client, 1)
    {:ok, epoch} = Wire.identity(granted["writer_epoch"])

    :ok = send_frame(client, resume("replayed", session_id, "resume-seen", epoch))

    assert [%{"request_id" => "replayed", "status" => "accepted"}] =
             receive_records(client, 1)

    assert %{activations_used: 0} = ConnectionRegistry.status(daemon.registry)
    :ok = send_frame(client, list("after-replay", 10))

    assert [%{"request_id" => "after-replay", "result" => %{"entries" => []}}] =
             receive_records(client, 1)

    assert {:ok, []} = Loopex.list_sessions(state)

    :ok = send_frame(client, resume("fresh", session_id, "resume-fresh", epoch))
    assert [%{"request_id" => "fresh", "status" => "accepted"}] = receive_records(client, 1)
    assert %{activations_used: 1} = ConnectionRegistry.status(daemon.registry)
    :ok = send_frame(client, list("after-fresh", 10))

    assert [%{"request_id" => "after-fresh", "result" => %{"entries" => [entry]}}] =
             receive_records(client, 1)

    assert entry["session_id"] == Wire.encode_identity(session_id)
    assert {:ok, [_directory_entry]} = Loopex.list_sessions(state)
  end

  test "a closed connection's slot frees only after the relay retires it and core releases its holder",
       %{daemon: daemon, runtime: runtime} do
    client = initialized_client(daemon)
    session_id = create_session(client, "retire-create")
    :ok = send_frame(client, attach("attach", session_id))
    assert [%{"type" => "snapshot"}] = receive_records(client, 1)

    [connection] = connection_pids(daemon)
    {:ok, %{dispatcher: dispatcher}} = Loopex.Runtime.children(runtime)
    assert Map.has_key?(:sys.get_state(dispatcher).holders, connection)

    :ok = :socket.close(client)

    eventually(fn -> ConnectionRegistry.status(daemon.registry).occupied == 0 end, 1_000)
    refute Map.has_key?(:sys.get_state(dispatcher).holders, connection)
    assert %{attachments: 0} = ConnectionRegistry.status(daemon.registry)
    refute_received {:daemon_component_fatal, _registry, :runtime_lost}
  end

  test "a holder cleanup core cannot acknowledge is runtime_lost and never frees the slot",
       %{daemon: daemon, runtime: runtime} do
    client = initialized_client(daemon)
    registry = daemon.registry
    :ok = Loopex.stop(runtime)
    :ok = :socket.close(client)

    assert_receive {:daemon_component_fatal, ^registry, :runtime_lost}, 5_000
    assert ConnectionRegistry.status(registry).occupied == 1
    assert ConnectionRegistry.status(registry).closing == 1
  end

  test "an owner succession detaches every attached client but keeps each connection open",
       %{daemon: daemon, runtime: runtime} do
    controller = initialized_client(daemon)
    session_id = create_session(controller, "succession-create")

    :ok = send_frame(controller, acquire("acquire", session_id))
    assert [%{"request_id" => "acquire", "result" => granted}] = receive_records(controller, 1)
    epoch = granted["writer_epoch"]

    :ok = send_frame(controller, attach("attach", session_id))
    assert [%{"type" => "snapshot"}] = receive_records(controller, 1)

    observer = initialized_client(daemon)
    :ok = send_frame(observer, attach("observe", session_id))
    assert [%{"type" => "snapshot"}] = receive_records(observer, 1)
    assert %{attachments: 2} = ConnectionRegistry.status(daemon.registry)

    # An ordinary resume of an active session starts a successor owner, which
    # cuts every attachment of that session.
    assert {:ok, ^session_id} =
             Loopex.resume_session(runtime, session_id, command_id: "succession-owner")

    for client <- [controller, observer] do
      assert [%{"type" => "error", "code" => "detached", "event_cursor" => _cursor} = record] =
               receive_records(client, 1)

      assert record["session_id"] == Wire.encode_identity(session_id)
      refute closed?(client, 100)
    end

    eventually(fn -> ConnectionRegistry.status(daemon.registry).attachments == 0 end)

    # Both reattach on the same connections; the controller keeps its lease and
    # epoch and may mutate again once reattached.
    :ok = send_frame(observer, attach("reobserve", session_id))
    assert [%{"request_id" => "reobserve", "type" => "snapshot"}] = receive_records(observer, 1)

    :ok = send_frame(controller, attach("reattach", session_id))
    assert [%{"request_id" => "reattach", "type" => "snapshot"}] = receive_records(controller, 1)

    # A follow-up on the idle session gets past the control check only with
    # the live lease: a client without it and the holder with a wrong epoch
    # are refused for control, while the holder's own epoch reaches the run
    # check and is refused only because no run is active.
    follow_up = fn socket, request_id, writer_epoch ->
      :ok =
        send_frame(socket, %{
          "method" => "session.follow_up",
          "request_id" => request_id,
          "command_id" => Wire.encode_identity(request_id),
          "content_b64" => Wire.encode_bytes("still in control"),
          "writer_epoch" => writer_epoch
        })

      assert [%{"request_id" => ^request_id} = record | _rest] =
               receive_until(socket, &(&1["request_id"] == request_id))

      record
    end

    unleased = follow_up.(observer, "observer-follow-up", epoch)
    stale = follow_up.(controller, "stale-follow-up", Wire.encode_identity("not-the-epoch"))
    held = follow_up.(controller, "after-succession", epoch)

    assert %{"type" => "error", "code" => "control_not_held"} = unleased
    assert %{"type" => "error", "code" => "control_not_held"} = stale
    assert %{"type" => "admission", "status" => "refused", "reason" => "no_active_run"} = held

    :ok =
      send_frame(controller, %{
        "method" => "session.release_control",
        "request_id" => "release",
        "session_id" => Wire.encode_identity(session_id),
        "writer_epoch" => epoch
      })

    assert [%{"request_id" => "release", "type" => "result"} | _rest] =
             receive_until(controller, &(&1["request_id"] == "release"))
  end

  # Reads event records through the next appended prompt and returns their
  # sequences in arrival order.
  defp read_through_prompt(socket, sequences) do
    [%{"type" => "event", "event" => event}] = receive_records(socket, 1, 10_000)
    sequences = [String.to_integer(event["event_sequence"]) | sequences]

    if event["kind"] == "user.message_appended",
      do: Enum.reverse(sequences),
      else: read_through_prompt(socket, sequences)
  end

  # Attaches after `cursor` on fresh connections until event `last` arrives,
  # returning every sequence received; a closed connection resumes from its
  # newest complete event, and each attempt must add at least one event.
  defp resume_through(_daemon, _session_id, cursor, last, _attempts) when cursor >= last, do: []

  defp resume_through(daemon, session_id, cursor, last, attempts) when attempts > 0 do
    client = initialized_client(daemon)
    :ok = send_frame(client, attach("return-#{cursor}", session_id, after: cursor))
    assert [%{"type" => "snapshot"}] = receive_records(client, 1)
    received = read_until_closed(client, last, [])
    :socket.close(client)
    assert received != [], "a reconnection made no progress"
    received ++ resume_through(daemon, session_id, List.last(received), last, attempts - 1)
  end

  # Reads event sequences until `last` or the daemon closes the connection.
  defp read_until_closed(socket, last, sequences) do
    case drain_records(socket, 1) do
      [%{"type" => "event", "event" => event}] ->
        sequence = String.to_integer(event["event_sequence"])

        if sequence >= last,
          do: Enum.reverse([sequence | sequences]),
          else: read_until_closed(socket, last, [sequence | sequences])

      _closed_or_detached ->
        Enum.reverse(sequences)
    end
  end

  # Reads every complete record until the daemon closes the connection, or
  # at most `limit` records when given an integer.
  defp drain_records(socket, limit) when is_integer(limit) do
    receive_records(socket, limit, 5_000)
  catch
    _kind, _reason -> []
  end

  defp drain_records(socket, records) do
    case receive_records(socket, 1, 5_000) do
      [record] -> drain_records(socket, [record | records])
    end
  catch
    _kind, _reason -> Enum.reverse(records)
  end

  defp receive_until(socket, predicate, acc \\ []) do
    [record] = receive_records(socket, 1)
    if predicate.(record), do: [record | acc], else: receive_until(socket, predicate, acc)
  end

  test "an idle observer is evicted with a record while a lease holder stays until it releases" do
    root = temporary_directory("loopex-socket-idle")
    daemon = start_daemon(start_runtime(root), idle_eviction_ms: 300)

    controller = initialized_client(daemon)
    session_id = create_session(controller, "idle-create")
    :ok = send_frame(controller, acquire("acquire", session_id))
    assert [%{"request_id" => "acquire", "result" => granted}] = receive_records(controller, 1)
    :ok = send_frame(controller, attach("attach", session_id))
    assert [%{"type" => "snapshot"}] = receive_records(controller, 1)

    observer = initialized_client(daemon)
    :ok = send_frame(observer, attach("observe", session_id))
    assert [%{"type" => "snapshot"}] = receive_records(observer, 1)

    # The observer is told where it stopped and its connection is closed.
    assert [%{"code" => "detached", "event_cursor" => cursor}] = receive_records(observer, 1)
    assert closed?(observer, 2_000)

    # The quiet controller holds its lease, so it outlives several idle limits.
    Process.sleep(1_000)
    refute closed?(controller, 50)

    :ok =
      send_frame(controller, %{
        "method" => "session.release_control",
        "request_id" => "release",
        "session_id" => Wire.encode_identity(session_id),
        "writer_epoch" => granted["writer_epoch"]
      })

    assert [%{"request_id" => "release", "type" => "result"}] = receive_records(controller, 1)
    assert [%{"code" => "detached"}] = receive_records(controller, 1)
    assert closed?(controller, 2_000)

    # The evicted observer reconnects at its retained cursor.
    returning = initialized_client(daemon)
    :ok = send_frame(returning, attach("return", session_id, after: String.to_integer(cursor)))
    assert [%{"request_id" => "return", "type" => "snapshot"}] = receive_records(returning, 1)
  end

  # Concept: aggregate-pressure reclamation evicts like overflow and idleness:
  # an attached client is told `detached` with its session and last emitted
  # cursor before the close, and an unattached one is simply closed.
  #
  # Technical depth: the registry's reclamation message is delivered to each
  # live connection exactly as `reclaim/3` sends it; the registry-side victim
  # order is proved in `connection_registry_test.exs`.
  test "a connection reclaimed under aggregate pressure is detached before it closes",
       %{daemon: daemon} do
    client = initialized_client(daemon)
    session_id = create_session(client, "reclaim-create")
    :ok = send_frame(client, attach("attach", session_id))
    assert [%{"type" => "snapshot", "event_cursor" => emitted}] = receive_records(client, 1)
    {token, pid} = live_connection(daemon)

    send(pid, {:connection_abort, token, :output_reclaimed})

    assert [%{"code" => "detached", "session_id" => encoded, "event_cursor" => cursor}] =
             receive_records(client, 1)

    assert encoded == Wire.encode_identity(session_id)
    assert cursor == emitted
    assert closed?(client, 2_000)

    bare = initialized_client(daemon)
    {token, pid} = live_connection(daemon)
    send(pid, {:connection_abort, token, :output_reclaimed})
    assert closed?(bare, 2_000)
  end

  defp live_connection(daemon) do
    eventually(fn ->
      match?([_], live_rows(daemon))
    end)

    [{token, %{connection_pid: pid}}] = live_rows(daemon)
    {token, pid}
  end

  defp live_rows(daemon) do
    daemon.registry
    |> :sys.get_state()
    |> Map.fetch!(:rows)
    |> Enum.filter(fn {_token, row} -> row.phase == :live and row.initialized end)
  end

  # Concept: one session holds at most 64 attachments; the 65th is refused
  # without touching the others, and another session still accepts one.
  @tag timeout: 120_000
  # Concept: an observer that stops reading is detached at the last cursor
  # the daemon completely emitted to it, while another attachment to the same
  # session keeps receiving every event, and the observer reconnects there
  # with no gap.
  #
  # Technical depth: two socket clients attach to one session; one reads each
  # prompt before the next is written, the other reads nothing. Eighty
  # embedded prompt-and-abort cycles, each prompt carrying 60,000 bytes, far
  # exceed the connection's 4 MiB output allowance, and every event frame is
  # larger than the kernel socket buffer, so each one needs resumed partial
  # writes. The reader sees one contiguous run of sequences and stays attached
  # while the silent observer is detached. Draining the observer yields only
  # a contiguous prefix and at most a `detached` record at its end, and a new
  # connection attached after that prefix receives the rest of the run.
  @tag timeout: 120_000
  test "an observer that stops reading is detached while another attachment continues",
       %{daemon: daemon, runtime: runtime} do
    reader = initialized_client(daemon)
    session_id = create_session(reader, "slow-create")
    :ok = send_frame(reader, attach("read", session_id, after: 0))
    assert [%{"type" => "snapshot"}] = receive_records(reader, 1)

    silent = initialized_client(daemon)
    :ok = send_frame(silent, attach("silent", session_id, after: 0))
    assert [%{"type" => "snapshot"}] = receive_records(silent, 1)

    {:ok, embedded} = Loopex.attach(runtime, session_id)
    content = String.duplicate("x", 60_000)

    # The reader is read up to each prompt before the next cycle, so only the
    # silent observer falls behind.
    read =
      Enum.flat_map(1..80, fn index ->
        prompt = %{type: :prompt, command_id: "slow-p#{index}", content: content}
        assert {:accepted, _command} = Loopex.command(embedded, prompt)

        assert {:accepted, _command} =
                 Loopex.command(embedded, %{type: :abort, command_id: "slow-a#{index}"})

        read_through_prompt(reader, [])
      end)

    assert read == Enum.to_list(1..List.last(read))
    eventually(fn -> ConnectionRegistry.status(daemon.registry).attachments == 1 end)
    refute closed?(reader, 50)

    # The silent observer holds only what the daemon completely emitted, a
    # contiguous prefix, then at most the best-effort `detached` record at
    # that cursor before the close; a frame cut off by the close is not a
    # record.
    records = drain_records(silent, [])
    {events, rest} = Enum.split_with(records, &(&1["type"] == "event"))
    assert records == events ++ rest
    sequences = Enum.map(events, &String.to_integer(&1["event"]["event_sequence"]))
    assert sequences == Enum.to_list(1..length(sequences)//1)
    held = length(sequences)
    assert held < List.last(read)

    for detached <- rest do
      assert %{"type" => "error", "code" => "detached"} = detached
      assert detached["event_cursor"] == Integer.to_string(held)
    end

    # Reconnecting after its last complete event, it receives the rest of the
    # run with no gap. A reconnection that itself falls behind the replay is
    # detached too, so the client reconnects again from its newest complete
    # event; each connection must make progress.
    resumed = resume_through(daemon, session_id, held, List.last(read), 20)
    assert resumed == Enum.to_list((held + 1)..List.last(read))
  end

  test "the sixty-fifth attachment to one session is refused while another session attaches",
       %{daemon: daemon} do
    creator = initialized_client(daemon)
    full = create_session(creator, "full-create")
    other = create_session(creator, "other-create")

    attached =
      for index <- 1..64 do
        client = initialized_client(daemon)
        :ok = send_frame(client, attach("a#{index}", full))
        assert [%{"type" => "snapshot"}] = receive_records(client, 1)
        client
      end

    extra = initialized_client(daemon)
    :ok = send_frame(extra, attach("sixty-fifth", full))

    assert [%{"request_id" => "sixty-fifth", "code" => "capacity_exceeded"}] =
             receive_records(extra, 1)

    :ok = send_frame(extra, attach("elsewhere", other))
    assert [%{"request_id" => "elsewhere", "type" => "snapshot"}] = receive_records(extra, 1)
    assert %{attachments: 65} = ConnectionRegistry.status(daemon.registry)
    refute Enum.any?(attached, &closed?(&1, 10))
  end

  # Concept: a client that offers only an older generation — the released
  # `0.1.0` name or generation one — is refused at initialize, and nothing it
  # sends afterwards creates anything.
  test "an older generation is refused and creates nothing", %{daemon: daemon} do
    for {offer, index} <-
          Enum.with_index(["loopex.session.v1-experimental", "loopex.experimental/1"]) do
      client = connect(daemon)

      :ok =
        send_frame(client, %{
          "method" => "initialize",
          "request_id" => "old-#{index}",
          "generations" => [offer],
          "capabilities" => []
        })

      assert [%{"code" => "unsupported_generation"}] = receive_records(client, 1)
      :ok = send_frame(client, create("late-#{index}", "late-create-#{index}", %{}))
      assert [%{"request_id" => "late-" <> _}] = receive_records(client, 1)
    end

    assert %{activations_used: 0, active_sessions: 0} = ConnectionRegistry.status(daemon.registry)
  end

  test "resource queries and artifact transfers answer or refuse over the socket",
       %{daemon: daemon} do
    client = initialized_client(daemon)
    session_id = create_session(client, "resource-create")
    encoded = Wire.encode_identity(session_id)

    :ok =
      send_frame(client, %{
        "method" => "resources.catalog",
        "request_id" => "catalog",
        "session_id" => encoded
      })

    assert [%{"request_id" => "catalog", "type" => "result", "method" => "resources.catalog"}] =
             receive_records(client, 1)

    :ok =
      send_frame(client, %{
        "method" => "resources.read",
        "request_id" => "read",
        "session_id" => encoded,
        "manifest_digest" => String.duplicate("0", 64),
        "source_id" => "no-source",
        "name" => "no-skill",
        "label" => "SKILL.md"
      })

    assert [%{"request_id" => "read", "type" => "error"}] = receive_records(client, 1)

    reference =
      Wire.encode_reference(%{
        digest: String.duplicate("a", 64),
        size: 9,
        locator: "no-such-artifact",
        use_locator: "use:" <> String.duplicate("a", 64)
      })

    open = %{
      "method" => "artifact.open_transfer",
      "request_id" => "open-unattached",
      "use_ref" => reference,
      "start_offset" => "0"
    }

    :ok = send_frame(client, open)

    assert [%{"request_id" => "open-unattached", "code" => "not_attached"}] =
             receive_records(client, 1)

    :ok = send_frame(client, attach("attach", session_id))
    assert [%{"type" => "snapshot"}] = receive_records(client, 1)

    :ok = send_frame(client, Map.put(open, "request_id", "open-bogus"))

    assert [%{"request_id" => "open-bogus", "code" => "transfer_refused", "reason" => _reason}] =
             receive_records(client, 1)

    :ok =
      send_frame(client, %{
        "method" => "artifact.read_chunk",
        "request_id" => "chunk-unknown",
        "transfer_ref" => Wire.encode_identity("no-such-transfer"),
        "length" => 1
      })

    assert [%{"request_id" => "chunk-unknown", "code" => "transfer_refused"}] =
             receive_records(client, 1)

    # The connection still serves after every refusal.
    :ok = send_frame(client, inspect_request("inspect", session_id))
    assert [%{"request_id" => "inspect", "type" => "result"}] = receive_records(client, 1)
  end

  test "daemon.status reports bounded counts with reservations counted", %{daemon: daemon} do
    client = initialized_client(daemon)
    _session_id = create_session(client, "status-create")

    :ok = send_frame(client, %{"method" => "daemon.status", "request_id" => "status"})

    assert [
             %{
               "type" => "result",
               "request_id" => "status",
               "method" => "daemon.status",
               "result" =>
                 %{
                   "connections" => 1,
                   "connection_limit" => 512,
                   "attachments" => 0,
                   "attachment_limit" => 512,
                   "active_sessions" => 1,
                   "activation_limit" => 64,
                   "activations_used" => 1,
                   "index_limit" => 4096,
                   "index_full" => false,
                   "uptime_ms" => uptime
                 } = status
             }
           ] = receive_records(client, 1)

    assert {:ok, _uptime} = Wire.u64(uptime)
    assert is_binary(status["daemon_incarnation"])
  end

  # Concept (E9, T26): a connection whose relay open is parked keeps serving
  # its client: told its session owner was lost, it writes the one
  # `control_owner_lost` record and closes while the open is still pending.
  test "a connection with a parked relay open still answers a holder close",
       %{daemon: daemon} do
    client = initialized_client(daemon)
    connection = initialized_connection(daemon)
    incarnation = :sys.get_state(connection).incarnation
    monitor = Process.monitor(connection)
    park_relay_on(daemon.relay, &match?({:"$gen_call", _from, {:open_permit, _, _, _}}, &1))

    :ok = send_frame(client, %{"method" => "daemon.status", "request_id" => "status"})
    assert_receive :relay_parked, 1_000

    close_ref = make_ref()

    send(
      connection,
      {:daemon_control_owner_lost, daemon.owner, close_ref, :crypto.strong_rand_bytes(16),
       incarnation}
    )

    assert [%{"type" => "error", "code" => "control_owner_lost"}] =
             receive_records(client, 1, 2_000)

    assert_receive {:DOWN, ^monitor, :process, ^connection, :normal}, 2_000
    send(daemon.relay, :continue_relay)
  end

  # Concept (E9, T26): a relay open left unanswered for five seconds is
  # reported by the connection; the daemon owner names the relay lost once,
  # and the request is answered exactly once when the relay exits.
  @tag timeout: 30_000
  test "an unanswered relay open is reported and the owner names relay_lost",
       %{daemon: daemon} do
    client = initialized_client(daemon)
    connection = initialized_connection(daemon)
    :ok = :sys.suspend(daemon.relay)

    started = System.monotonic_time(:millisecond)
    :ok = send_frame(client, %{"method" => "daemon.status", "request_id" => "status"})

    assert_receive {:daemon_component_fatal, owner, :relay_lost}, 7_000
    assert owner == daemon.owner
    assert System.monotonic_time(:millisecond) - started >= 4_900

    assert [%{"type" => "error", "request_id" => "status", "code" => "internal_failure"}] =
             receive_records(client, 1, 2_000)

    refute_receive {:daemon_component_fatal, _reporter, _class}, 300
    assert Process.alive?(connection)
  end

  # Concept (E9): a ticket's worker stays monitored until the relay answers
  # its bind, and a result it reports before that answer is held: nothing is
  # promoted until the ticket is bound.
  test "a create's worker result waits for its ticket bind before promotion",
       %{daemon: daemon} do
    client = initialized_client(daemon)
    connection = initialized_connection(daemon)

    park_relay_on(
      daemon.relay,
      &match?({:"$gen_call", _from, {:bind_ticket_worker, _, _, _}}, &1)
    )

    :ok = send_frame(client, create("held", "held-create", %{"purpose" => "held"}))
    assert_receive :relay_parked, 1_000

    eventually(fn ->
      Enum.any?(:sys.get_state(connection).ledger.requests, fn {_origin, entry} ->
        entry.phase == :binding and match?({:held, _result}, entry.prepared)
      end)
    end)

    assert %{relay_flow: nil, activation_promotions: promotions} =
             :sys.get_state(daemon.registry)

    assert promotions == %{}
    send(daemon.relay, :continue_relay)

    assert [%{"request_id" => "held", "status" => "accepted"}] = receive_records(client, 1)
  end

  # Concept (E7, F5): a create whose own promotion waits longer than any
  # fixed call bound is still admitted, never refused after it may have
  # committed.
  #
  # Technical depth: the registry is suspended while both clients' creates
  # reach `:promoting`, so both promotions are pending before the stamp. Each
  # relay promotion then takes 3.5 s, inside every component's own
  # five-second instant, and the second waits behind the first in the
  # registry's flow queue: its own wait from the stamp exceeds five seconds.
  @tag timeout: 60_000
  test "a create promoted after more than five seconds is admitted", %{daemon: daemon} do
    first = initialized_client(daemon)
    second = initialized_client(daemon)
    connections = connection_pids(daemon)

    delay_relay_on(
      daemon.relay,
      &match?({:"$gen_call", _from, {:promote_ticket, _, _, _, _}}, &1),
      3_500
    )

    :ok = :sys.suspend(daemon.registry)
    :ok = send_frame(first, create("first", "slow-first", %{"purpose" => "first"}))
    :ok = send_frame(second, create("second", "slow-second", %{"purpose" => "second"}))

    eventually(fn ->
      Enum.all?(connections, fn connection -> ledger_phase?(connection, :promoting) end)
    end)

    stamped = System.monotonic_time(:millisecond)
    :ok = :sys.resume(daemon.registry)

    assert [%{"request_id" => "first", "status" => "accepted"}] =
             receive_records(first, 1, 15_000)

    assert [%{"request_id" => "second", "status" => "accepted"}] =
             receive_records(second, 1, 15_000)

    assert System.monotonic_time(:millisecond) - stamped >= 5_000
    refute_received {:daemon_component_fatal, _reporter, _class}
  end

  # Concept (F1): once the connection is closing, a relay answer to a request
  # it opened is cleanup-only: no correlated record follows the close, no
  # worker is started and nothing is left behind.
  #
  # Technical depth: the relay is parked on the permit open, the connection
  # is suspended, the close is delivered, and then the open's answer — the
  # relay's exit, or its acceptance — lands behind it in the connection's
  # mailbox before the connection resumes.
  for close <- [:owner_loss, :final], outcome <- [:refusal, :acceptance] do
    test "an open answered during the #{close} close writes nothing (#{outcome})",
         %{daemon: daemon} do
      client = initialized_client(daemon)
      connection = initialized_connection(daemon)
      incarnation = :sys.get_state(connection).incarnation
      monitor = Process.monitor(connection)
      relay = daemon.relay

      park_then_watch(
        relay,
        &match?({:"$gen_call", _from, {:open_permit, _, _, _}}, &1),
        &match?({:"$gen_call", _from, {:bind_worker, _, _, _}}, &1)
      )

      :ok = send_frame(client, %{"method" => "daemon.status", "request_id" => "status"})
      assert_receive :relay_parked, 1_000
      :ok = :sys.suspend(connection)
      send(connection, close_message(unquote(close), daemon, incarnation))

      case unquote(outcome) do
        :refusal ->
          Process.exit(relay, :kill)

          eventually(fn ->
            mailbox_has?(connection, &match?({:DOWN, _, :process, ^relay, _}, &1))
          end)

        :acceptance ->
          send(relay, :continue_relay)
          eventually(fn -> mailbox_has?(connection, &match?({[:alias | _], {:ok, _}}, &1)) end)
      end

      :ok = :sys.resume(connection)

      assert [record] = records_until_closed(client)
      assert record["type"] == close_record_type(unquote(close))
      refute Map.has_key?(record, "request_id")
      assert_receive {:DOWN, ^monitor, :process, ^connection, _reason}, 2_000
      refute_receive {:relay_watched, _message}, 200

      if unquote(outcome) == :acceptance,
        do: eventually(fn -> AdmissionRelay.status(relay).permits == 0 end)
    end
  end

  # Concept (F2): a create whose relay is lost after core committed it is
  # never refused: its outcome is unknown, so the connection writes nothing
  # for it and leaves it to the uncorrelated close, and the committed session
  # is what a retry of the same command finds.
  test "a create whose relay is lost after its task committed writes no refusal",
       %{daemon: daemon, runtime: runtime} do
    client = initialized_client(daemon)
    park_after_promotion(daemon.relay)
    options = %{"purpose" => "lost"}

    :ok = send_frame(client, create("lost", "lost-create", options))
    assert_receive :promotion_parked, 2_000

    eventually(fn ->
      match?(
        {:ok, {:historical, _session}},
        Loopex.Runtime.lookup_create_result(runtime, "lost-create", options)
      )
    end)

    Process.exit(daemon.relay, :kill)
    assert_receive {:daemon_component_fatal, _owner, :relay_lost}, 2_000

    assert Process.get({LoopexDaemon.Test.DaemonSocketFixture, client}, "") == ""
    assert {:error, :timeout} = :socket.recv(client, 0, 1_000)

    assert {:ok, {:historical, _session}} =
             Loopex.Runtime.lookup_create_result(runtime, "lost-create", options)
  end

  # Concept (F3): a relay cancel that ends a request while its ticket is
  # still binding kills the worker the relay never took over.
  test "a relay cancel while a ticket binds kills its worker", %{daemon: daemon} do
    client = initialized_client(daemon)
    connection = initialized_connection(daemon)

    park_relay_on(
      daemon.relay,
      &match?({:"$gen_call", _from, {:bind_ticket_worker, _, _, _}}, &1)
    )

    :ok = send_frame(client, create("cancelled", "cancel-create", %{"purpose" => "cancel"}))
    assert_receive :relay_parked, 1_000
    {origin, entry} = ledger_entry(connection, :binding)

    send(connection, {:relay_ticket_cancelled, origin, :daemon_stopping})

    assert [%{"request_id" => "cancelled", "code" => "daemon_stopping"}] =
             receive_records(client, 1)

    eventually(fn -> not Process.alive?(entry.worker) end)
    send(daemon.relay, :continue_relay)
  end

  # Concept (F4): a permit worker's normal exit that overtakes the relay's
  # bind answer is not the request's failure: the permit's result still
  # answers it.
  #
  # Technical depth: the relay is parked on the bind, and the worker's normal
  # `DOWN` is delivered first, forcing the cross-sender order.
  test "a permit worker's exit before its bind answer still yields the result",
       %{daemon: daemon} do
    client = initialized_client(daemon)
    connection = initialized_connection(daemon)
    park_relay_on(daemon.relay, &match?({:"$gen_call", _from, {:bind_worker, _, _, _}}, &1))

    :ok = send_frame(client, %{"method" => "daemon.status", "request_id" => "status"})
    assert_receive :relay_parked, 1_000
    {_origin, entry} = ledger_entry(connection, :binding)

    send(connection, {:DOWN, entry.worker_monitor, :process, entry.worker, :normal})
    send(daemon.relay, :continue_relay)

    assert [%{"request_id" => "status", "type" => "result"}] = receive_records(client, 1)
  end

  # Concept (F7): a refused attach releases exactly the succession reserve it
  # took at dispatch, even when the connection's attachment changed while it
  # was promoting.
  #
  # Technical depth: an unattached attach takes the reserve and is parked at
  # its relay promotion; the connection's attachment is then set, as a
  # concurrent change would, and a relay cancel refuses the attach.
  #
  # The state forced here cannot occur today. On the real interleaving —
  # succession invalidating the attachment while a replacement is promoting —
  # the notice is enqueued before the attachment clears, so the reserve is
  # already out of `:reserved` and the registry refuses to release it: the
  # old release-by-current-attachment code is correct there too. The fix and
  # this witness defend the invariant "release exactly the reserve this
  # attach took" against future change.
  test "a refused attach releases the succession reserve it took", %{daemon: daemon} do
    client = initialized_client(daemon)
    session_id = create_session(client, "reserve-create")
    connection = initialized_connection(daemon)

    park_relay_on(
      daemon.relay,
      &match?({:"$gen_call", _from, {:promote_ticket, _, _, _, _}}, &1)
    )

    :ok = send_frame(client, attach("taken", session_id))
    assert_receive :relay_parked, 1_000
    {origin, _entry} = ledger_entry(connection, :promoting)
    assert %{succession_reservations: 1} = ConnectionRegistry.status(daemon.registry)

    :sys.replace_state(connection, fn state ->
      %{state | attachment: %{session_id: session_id, attachment_id: "concurrent"}}
    end)

    send(connection, {:relay_ticket_cancelled, origin, :daemon_stopping})
    assert [%{"request_id" => "taken", "code" => "daemon_stopping"}] = receive_records(client, 1)
    assert %{succession_reservations: 0} = ConnectionRegistry.status(daemon.registry)

    :sys.replace_state(connection, &%{&1 | attachment: nil})
    send(daemon.relay, :continue_relay)
  end

  # Concept (round 2): nothing new starts while the connection is closing: a
  # create's worker result that arrives during the close starts no
  # promotion, commits no session, leaves no reservation and writes nothing.
  #
  # Technical depth: Control is suspended so the create's worker is parked in
  # its lookup after its ticket is bound; the connection is suspended while
  # the owner-loss close is delivered and Control resumed, so the worker's
  # result lands behind the close in the connection's mailbox.
  test "a worker result arriving during the close starts no promotion",
       %{daemon: daemon, runtime: runtime} do
    client = initialized_client(daemon)
    connection = initialized_connection(daemon)
    incarnation = :sys.get_state(connection).incarnation
    monitor = Process.monitor(connection)
    options = %{"purpose" => "closing"}
    {:ok, children} = Loopex.Runtime.children(runtime)
    watch_relay(daemon.relay, &match?({:"$gen_call", _from, {:promote_ticket, _, _, _, _}}, &1))

    :ok = :sys.suspend(children.control)
    :ok = send_frame(client, create("closing", "closing-create", options))
    {_origin, entry} = ledger_entry(connection, :ready)

    :ok = :sys.suspend(connection)
    send(connection, close_message(:owner_loss, daemon, incarnation))
    :ok = :sys.resume(children.control)
    eventually(fn -> mailbox_has?(connection, &match?({:request_worker_result, _, _, _}, &1)) end)
    :ok = :sys.resume(connection)

    assert [record] = records_until_closed(client)
    assert record["code"] == "control_owner_lost"
    refute Map.has_key?(record, "request_id")
    assert_receive {:DOWN, ^monitor, :process, ^connection, _reason}, 2_000

    refute_receive {:relay_watched, _promotion}, 300
    refute Process.alive?(entry.worker)

    assert {:ok, :absent} =
             Loopex.Runtime.lookup_create_result(runtime, "closing-create", options)

    eventually(fn -> AdmissionRelay.status(daemon.relay).tickets == 0 end)
    assert %{activation_reservations: 0} = ConnectionRegistry.status(daemon.registry)
  end

  # Reports every message the relay handles that matches.
  # Concept (E1, F8): the returned holder of a lost session owner hears only
  # its one uncorrelated `control_owner_lost` close: a renewal it sent, held
  # by the daemon owner until the loss finishes, is never answered with a
  # correlated refusal, and its connection is never blocked while held.
  #
  # Technical depth: the daemon owner is suspended with the renewal queued,
  # the lease owner is killed, and the owner resumes once the relay has seen
  # the loss, so the renewal's open is refused `actor_lost` and held. The
  # loss's holder close needs this very connection to answer.
  @tag timeout: 30_000
  test "a held renewal of a lost owner's holder gets only the owner-lost close",
       %{daemon: daemon} do
    client = initialized_client(daemon)
    session_id = create_session(client, "lost-holder")
    :ok = send_frame(client, acquire("acquire", session_id))
    assert [%{"request_id" => "acquire", "type" => "result"}] = receive_records(client, 1)
    [lease_owner] = lease_owner_pids(daemon)
    :ok = :sys.suspend(daemon.owner)
    :ok = send_frame(client, acquire("renewal", session_id))

    eventually(fn ->
      mailbox_has?(
        daemon.owner,
        &match?(
          {:"$gen_call", _from, request}
          when elem(request, 0) in [:acquire_control, :connection_acquire_control],
          &1
        )
      )
    end)

    Process.exit(lease_owner, :kill)
    eventually(fn -> AdmissionRelay.status(daemon.relay).owner_losses == 1 end)
    :ok = :sys.resume(daemon.owner)

    assert [%{"type" => "error", "code" => "control_owner_lost"} = close] =
             records_until_closed(client, 8_000)

    refute Map.has_key?(close, "request_id")
    refute_receive {:daemon_component_fatal, _reporter, _class}, 200
  end

  # Concept (E1, F8, P2): an acquire racing its lease owner's retirement is
  # held; a lease owner that never sends its retirement intent is killed at
  # the hold's five-second step, and the held acquire is then granted by a
  # fresh owner. The connection waits without a deadline of its own, so it
  # never answers `control_pending` meanwhile.
  #
  # Technical depth: a relay debug hook suspends the lease owner as its
  # retirement preparation arrives, so the relay refuses the later acquire
  # `actor_retiring` while no intent follows.
  @tag timeout: 30_000
  test "an acquire held past a silent retirement is granted, not refused",
       %{daemon: daemon} do
    holder = initialized_client(daemon)
    session_id = create_session(holder, "silent-retirement")
    :ok = send_frame(holder, acquire("acquire", session_id))

    assert [%{"request_id" => "acquire", "result" => %{"writer_epoch" => epoch}}] =
             receive_records(holder, 1)

    [lease_owner] = lease_owner_pids(daemon)
    test_pid = self()

    :ok =
      :sys.install(
        daemon.relay,
        {fn
           :waiting, {:in, {:"$gen_call", {^lease_owner, _tag}, request}}, _state
           when elem(request, 0) == :prepare_lease_owner_retirement ->
             :sys.suspend(lease_owner)
             send(test_pid, :retirement_prepared)
             :done

           hook_state, _event, _state ->
             hook_state
         end, :waiting}
      )

    :ok =
      send_frame(holder, %{
        "method" => "session.release_control",
        "request_id" => "release",
        "session_id" => Wire.encode_identity(session_id),
        "writer_epoch" => epoch
      })

    assert [%{"request_id" => "release", "type" => "result"}] = receive_records(holder, 1)
    assert_receive :retirement_prepared, 2_000
    monitor = Process.monitor(lease_owner)
    successor = initialized_client(daemon)
    started = System.monotonic_time(:millisecond)
    :ok = send_frame(successor, acquire("late", session_id))

    assert [%{"request_id" => "late", "type" => "result", "result" => %{"writer_epoch" => _}}] =
             receive_records(successor, 1, 10_000)

    assert System.monotonic_time(:millisecond) - started >= 4_900
    assert_received {:DOWN, ^monitor, :process, ^lease_owner, :killed}
    refute_receive {:daemon_component_fatal, _reporter, _class}, 200
  end

  # Concept (E1, F8, round 2 item 1): during the stop, the returned holder of
  # a lost session owner still hears only an uncorrelated close: the cut
  # answers its held renewal `holder_closed`, which writes nothing, and its
  # connection ends with `daemon.stopping`.
  #
  # Technical depth: the loss is held at its classification (the relay is
  # parked on it) or before it, at the registry's mirror pop (the registry is
  # suspended), so the renewal is held (`actor_lost`) and the cut is
  # consumed before the classification. The holder is then named by
  # `lost_holders` in the first case and by its granted route in the second.
  # No owner-lost close is emitted after the cut, so the test delivers the
  # final close itself.
  for stage <- [:classification, :pop] do
    @tag timeout: 30_000
    test "a held renewal of a lost owner's holder during the stop writes no refusal (#{stage})",
         %{daemon: daemon} do
      client = initialized_client(daemon)
      session_id = create_session(client, "lost-holder-stop")
      :ok = send_frame(client, acquire("acquire", session_id))
      assert [%{"request_id" => "acquire", "type" => "result"}] = receive_records(client, 1)
      [lease_owner] = lease_owner_pids(daemon)
      connection = initialized_connection(daemon)
      :ok = :sys.suspend(daemon.owner)
      :ok = send_frame(client, acquire("renewal", session_id))

      eventually(fn ->
        mailbox_has?(
          daemon.owner,
          &match?({:"$gen_call", _from, request} when elem(request, 0) == :acquire_control, &1)
        )
      end)

      if unquote(stage) == :classification do
        park_relay_on(
          daemon.relay,
          &match?({:relay_owner_loss_classification, _, _, _, _, _, _, _}, &1)
        )
      else
        :ok = :sys.suspend(daemon.registry)
      end

      Process.exit(lease_owner, :kill)
      eventually(fn -> AdmissionRelay.status(daemon.relay).owner_losses == 1 end)
      :ok = :sys.resume(daemon.owner)
      if unquote(stage) == :classification, do: assert_receive(:relay_parked, 2_000)

      eventually(fn ->
        match?(%{held: [_]}, :sys.get_state(daemon.owner).owners[session_id])
      end)

      cut = Task.async(fn -> LoopexDaemon.Owner.cut_admission(daemon.owner, 5_000) end)
      eventually(fn -> not is_nil(:sys.get_state(daemon.owner).stop) end)

      if unquote(stage) == :classification,
        do: send(daemon.relay, :continue_relay),
        else: :ok = :sys.resume(daemon.registry)

      assert {:ok, _cut_ref} = Task.await(cut, 6_000)
      eventually(fn -> :sys.get_state(connection).ledger.requests == %{} end)
      send(connection, close_message(:final, daemon, nil))

      assert [%{"type" => "daemon.stopping"}] = records_until_closed(client, 8_000)
    end
  end

  # Concept (E1, round 2 item 4): a relay record that reaches the connection
  # before the daemon owner's answer is the request's one answer; the
  # owner's later acceptance is cleanup only.
  #
  # Technical depth: a relay debug hook suspends the daemon owner as its
  # open reaches the relay, so the open's answer waits in the suspended
  # owner's mailbox; the pending permit's worker is then killed, so
  # the relay sends `relay_permit_failed` first; the owner then resumes.
  test "a relay record before the owner's answer is the request's only answer",
       %{daemon: daemon} do
    holder = initialized_client(daemon)
    session_id = create_session(holder, "record-first")
    :ok = send_frame(holder, acquire("acquire", session_id))
    assert [%{"request_id" => "acquire", "type" => "result"}] = receive_records(holder, 1)
    holder_connection = initialized_connection(daemon)
    observer = initialized_client(daemon)
    owner = daemon.owner
    test_pid = self()

    :ok =
      :sys.install(
        daemon.relay,
        {fn
           :waiting, {:in, {:"$gen_call", {^owner, _tag}, request}}, _proc_state
           when elem(request, 0) == :open_lease_permit ->
             :sys.suspend(owner)
             send(test_pid, :open_answered)
             :done

           hook_state, _event, _proc_state ->
             hook_state
         end, :waiting}
      )

    :ok = send_frame(observer, acquire("late", session_id))
    assert_receive :open_answered, 2_000

    [{_origin, %{worker_pid: worker, connection_pid: observer_connection}}] =
      Enum.filter(:sys.get_state(daemon.relay).permits, fn {_origin, permit} ->
        permit.connection_pid != holder_connection
      end)

    Process.exit(worker, :kill)

    assert [%{"request_id" => "late", "type" => "error", "code" => "internal_failure"}] =
             receive_records(observer, 1)

    :ok = :sys.resume(owner)
    eventually(fn -> :sys.get_state(observer_connection).ledger.requests == %{} end)
    eventually(fn -> LoopexDaemon.Owner.status(owner).lease_operations == 0 end)
    assert {:error, :timeout} = :socket.recv(observer, 0, 300)
  end

  # Concept (E1, round 2 item 5): a hand-off the daemon owner accepted
  # leaves its worker to the relay even when the connection is closing; the
  # relay then settles the permit as the connection's loss.
  #
  # Technical depth: the lease owner and the daemon owner are suspended, so
  # the renewal's permit stays pending; the connection is suspended, handed
  # an owner-loss close, and then receives the owner's acceptance behind it.
  test "a close during an accepted hand-off leaves the worker to the relay",
       %{daemon: daemon} do
    client = initialized_client(daemon)
    session_id = create_session(client, "close-handoff")
    :ok = send_frame(client, acquire("acquire", session_id))
    assert [%{"request_id" => "acquire", "type" => "result"}] = receive_records(client, 1)
    [lease_owner] = lease_owner_pids(daemon)
    connection = initialized_connection(daemon)
    incarnation = :sys.get_state(connection).incarnation
    :ok = :sys.suspend(lease_owner)
    :ok = :sys.suspend(daemon.owner)
    :ok = send_frame(client, acquire("renewal", session_id))
    {origin, _entry} = ledger_entry(connection, :handoff)
    :ok = :sys.suspend(connection)
    send(connection, close_message(:owner_loss, daemon, incarnation))
    :ok = :sys.resume(daemon.owner)

    eventually(fn ->
      mailbox_has?(connection, &match?({[:alias | _], {:ok, :accepted, _, _}}, &1))
    end)

    monitor = Process.monitor(connection)
    :ok = :sys.resume(connection)
    assert_receive {:DOWN, ^monitor, :process, ^connection, _reason}, 2_000

    eventually(fn ->
      match?(%{disposition: :connection_lost}, :sys.get_state(daemon.relay).permits[origin])
    end)

    :ok = :sys.resume(lease_owner)
  end

  # Concept (round 3 item 1): a request the returned holder of a lost session
  # owner sends after the owner's exit but before its close — a release, or
  # a renewal while a successor acquire is already waiting — is answered
  # `holder_closed`, so the holder hears only its uncorrelated close.
  #
  # Technical depth: a registry debug hook parks the loss's mirror pop, so
  # the row is `:lost` and the granted route still names the holder while
  # the holder's request is dispatched; an owner debug hook reports that the
  # request arrived, and the pop is then released so the loss classifies and
  # closes the holder.
  for variant <- [:release, :renewal_behind_successor] do
    @tag timeout: 30_000
    test "a returned holder's #{variant} before its close gets only the owner-lost close",
         %{daemon: daemon} do
      client = initialized_client(daemon)
      session_id = create_session(client, "returned-#{unquote(variant)}")
      :ok = send_frame(client, acquire("acquire", session_id))

      assert [%{"request_id" => "acquire", "result" => %{"writer_epoch" => epoch}}] =
               receive_records(client, 1)

      [lease_owner] = lease_owner_pids(daemon)
      connection = initialized_connection(daemon)
      other = if unquote(variant) == :renewal_behind_successor, do: initialized_client(daemon)
      test_pid = self()

      :ok =
        :sys.install(
          daemon.registry,
          {fn
             :waiting, {:in, {:apply_mirror, _, _, _, :pop_owner_mirror, _}}, _state ->
               send(test_pid, :pop_parked)

               receive do
                 :continue_pop -> :done
               end

             hook_state, _event, _state ->
               hook_state
           end, :waiting}
        )

      :ok =
        :sys.install(
          daemon.owner,
          {fn
             reporting, {:in, {:"$gen_call", {^connection, _tag}, request}}, _state
             when elem(request, 0) in [:acquire_control, :release_control] ->
               send(test_pid, :holder_request_arrived)
               reporting

             reporting, _event, _state ->
               reporting
           end, :reporting}
        )

      Process.exit(lease_owner, :kill)
      assert_receive :pop_parked, 2_000

      if unquote(variant) == :renewal_behind_successor do
        :ok = send_frame(other, acquire("successor", session_id))

        eventually(fn ->
          match?(%{successor: {_, _, _}}, :sys.get_state(daemon.owner).owners[session_id])
        end)

        :ok = send_frame(client, acquire("renewal", session_id))
      else
        :ok =
          send_frame(client, %{
            "method" => "session.release_control",
            "request_id" => "release",
            "session_id" => Wire.encode_identity(session_id),
            "writer_epoch" => epoch
          })
      end

      assert_receive :holder_request_arrived, 2_000
      _ = :sys.get_state(daemon.owner)
      eventually(fn -> :sys.get_state(connection).ledger.requests == %{} end)
      send(daemon.registry, :continue_pop)

      assert [%{"type" => "error", "code" => "control_owner_lost"} = close] =
               records_until_closed(client, 8_000)

      refute Map.has_key?(close, "request_id")
    end
  end

  defp watch_relay(relay, matcher) do
    test = self()

    :ok =
      :sys.install(
        relay,
        {fn
           :watching, {:in, message}, _state ->
             if matcher.(message), do: send(test, {:relay_watched, message})
             :watching

           phase, _event, _state ->
             phase
         end, :watching}
      )
  end

  defp close_message(:owner_loss, daemon, incarnation),
    do:
      {:daemon_control_owner_lost, daemon.owner, make_ref(), :crypto.strong_rand_bytes(16),
       incarnation}

  defp close_message(:final, _daemon, _incarnation),
    do: {:daemon_stopping, WireRecords.daemon_stopping("operator_stop")}

  defp close_record_type(:owner_loss), do: "error"
  defp close_record_type(:final), do: "daemon.stopping"

  defp mailbox_has?(pid, matcher) do
    {:messages, messages} = Process.info(pid, :messages)
    Enum.any?(messages, matcher)
  end

  # Every record the client receives until its socket closes.
  defp records_until_closed(socket, timeout \\ 2_000) do
    buffered = Process.get({LoopexDaemon.Test.DaemonSocketFixture, socket}, "")
    Process.put({LoopexDaemon.Test.DaemonSocketFixture, socket}, "")
    collect_until_closed(socket, buffered, timeout)
  end

  defp collect_until_closed(socket, bytes, timeout) do
    case :socket.recv(socket, 0, timeout) do
      {:ok, more} ->
        collect_until_closed(socket, bytes <> more, timeout)

      {:error, :closed} ->
        bytes
        |> String.split("\n", trim: true)
        |> Enum.map(fn payload ->
          {:ok, record} =
            LoopexProtocol.Frame.decode(payload, LoopexProtocol.Frame.output_record_bytes())

          record
        end)
    end
  end

  defp ledger_phase?(connection, phase) do
    Enum.any?(:sys.get_state(connection).ledger.requests, fn {_origin, entry} ->
      entry.phase == phase
    end)
  end

  defp ledger_entry(connection, phase) do
    eventually(fn -> ledger_phase?(connection, phase) end)

    Enum.find(:sys.get_state(connection).ledger.requests, fn {_origin, entry} ->
      entry.phase == phase
    end)
  end

  # Parks the relay on the first matching message until `:continue_relay`,
  # then reports every later message that matches `watch`.
  defp park_then_watch(relay, park, watch) do
    test = self()

    :ok =
      :sys.install(
        relay,
        {fn
           :waiting, {:in, message}, _state ->
             if park.(message) do
               send(test, :relay_parked)

               receive do
                 :continue_relay -> :watching
               end
             else
               :waiting
             end

           :watching, {:in, message}, _state ->
             if watch.(message), do: send(test, {:relay_watched, message})
             :watching

           phase, _event, _state ->
             phase
         end, :waiting}
      )
  end

  # Parks the relay for good once it has started a ticket promotion's task
  # and is handling the killed waiting worker's exit, before it answers the
  # registry.
  defp park_after_promotion(relay) do
    test = self()

    :ok =
      :sys.install(
        relay,
        {fn
           :waiting, {:in, {:"$gen_call", _from, {:promote_ticket, _, _, _, _}}}, _state ->
             :promoted

           :promoted, {:in, {:DOWN, _monitor, :process, _worker, :killed}}, _state ->
             send(test, :promotion_parked)

             receive do
               :never_released -> :done
             end

           phase, _event, _state ->
             phase
         end, :waiting}
      )
  end

  # Parks the relay just before it handles the first matching message, until
  # the test sends it `:continue_relay`.
  defp park_relay_on(relay, matcher) do
    test = self()

    :ok =
      :sys.install(
        relay,
        {fn
           :waiting, {:in, message}, _state ->
             if matcher.(message) do
               send(test, :relay_parked)

               receive do
                 :continue_relay -> :done
               end
             else
               :waiting
             end

           :waiting, _event, _state ->
             :waiting
         end, :waiting}
      )
  end

  # Delays the relay by `delay_ms` before each matching message it handles.
  defp delay_relay_on(relay, matcher, delay_ms) do
    :ok =
      :sys.install(
        relay,
        {fn
           :waiting, {:in, message}, _state ->
             if matcher.(message), do: Process.sleep(delay_ms)
             :waiting

           :waiting, _event, _state ->
             :waiting
         end, :waiting}
      )
  end

  # This daemon's connection processes, found by initial call and registry.
  defp connection_pids(daemon) do
    for pid <- Process.list(),
        {:dictionary, dictionary} <- [Process.info(pid, :dictionary)],
        dictionary[:"$initial_call"] == {LoopexDaemon.SocketConnection, :init, 1},
        connection_registry(pid) == daemon.registry,
        do: pid
  end

  # A connection of a concurrent case may exit between listing and reading.
  defp connection_registry(pid) do
    :sys.get_state(pid, 1_000).registry
  catch
    :exit, _gone -> nil
  end

  defp inspect_request(request_id, session_id) do
    %{
      "method" => "session.inspect",
      "request_id" => request_id,
      "session_id" => Wire.encode_identity(session_id)
    }
  end

  defp list(request_id, limit),
    do: %{"method" => "session.list", "request_id" => request_id, "limit" => limit}

  defp create_session(client, command_id) do
    :ok = send_frame(client, create(command_id, command_id, %{"purpose" => command_id}))
    assert [%{"status" => "accepted", "session_id" => encoded}] = receive_records(client, 1)
    {:ok, session_id} = Wire.identity(encoded)
    session_id
  end

  defp attach(request_id, session_id, options \\ []) do
    %{
      "method" => "session.attach",
      "request_id" => request_id,
      "session_id" => Wire.encode_identity(session_id)
    }
    |> maybe_put("after_event_sequence", options[:after] && Integer.to_string(options[:after]))
    |> maybe_put("replace", options[:replace])
  end

  defp resume(request_id, session_id, command_id, epoch) do
    %{
      "method" => "session.resume",
      "request_id" => request_id,
      "session_id" => Wire.encode_identity(session_id),
      "command_id" => Wire.encode_identity(command_id),
      "writer_epoch" => Wire.encode_identity(epoch)
    }
  end

  defp acquire(request_id, session_id) do
    %{
      "method" => "session.acquire_control",
      "request_id" => request_id,
      "session_id" => Wire.encode_identity(session_id)
    }
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp lease_owner_pids(daemon) do
    daemon.owner
    |> :sys.get_state()
    |> Map.fetch!(:owners)
    |> Enum.map(fn {_id, row} -> row.pid end)
  end

  defp create(request_id, command_id, options) do
    %{
      "method" => "session.create",
      "request_id" => request_id,
      "command_id" => Wire.encode_identity(command_id),
      "session_options" => options
    }
  end

  defp initialized_connection(daemon) do
    [connection] =
      for {_token, %{initialized: true, connection_pid: pid}} <-
            :sys.get_state(daemon.registry).rows,
          do: pid

    connection
  end
end
