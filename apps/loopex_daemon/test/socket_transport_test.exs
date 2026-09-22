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
