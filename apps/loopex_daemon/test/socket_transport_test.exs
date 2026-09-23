Code.require_file("support/daemon_socket_fixture.exs", __DIR__)

defmodule LoopexDaemon.SocketTransportTest do
  use ExUnit.Case, async: true
  @moduletag capture_log: true

  import LoopexDaemon.Test.DaemonSocketFixture

  alias LoopexDaemon.{AdmissionRelay, ConnectionRegistry, LeaseOwner}
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

    :ok =
      send_frame(controller, %{
        "method" => "session.follow_up",
        "request_id" => "after-succession",
        "command_id" => Wire.encode_identity("after-succession"),
        "content_b64" => Wire.encode_bytes("still in control"),
        "writer_epoch" => epoch
      })

    assert [%{"request_id" => "after-succession", "type" => "admission"} = admission | _rest] =
             receive_until(controller, &(&1["request_id"] == "after-succession"))

    assert admission["status"] in ["accepted", "refused"]
  end

  defp receive_until(socket, predicate, acc \\ []) do
    [record] = receive_records(socket, 1)
    if predicate.(record), do: [record | acc], else: receive_until(socket, predicate, acc)
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
end
