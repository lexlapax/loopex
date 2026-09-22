Code.require_file("support/daemon_socket_fixture.exs", __DIR__)

defmodule LoopexDaemon.CollaborationTest do
  use ExUnit.Case, async: true
  @moduletag capture_log: true

  import LoopexDaemon.Test.DaemonSocketFixture

  alias LoopexDaemon.{AdmissionRelay, ConnectionRegistry, Owner}
  alias LoopexProtocol.Wire

  setup do
    root = temporary_directory("loopex-collaboration")
    runtime = start_runtime(root)

    {:ok, session_id} =
      Loopex.create_session(runtime, %{"purpose" => "collaboration"}, command_id: "create-1")

    %{runtime: runtime, session_id: session_id, daemon: start_daemon(runtime)}
  end

  test "an unknown session refuses before any owner or lease exists", %{daemon: daemon} do
    client = initialized_client(daemon)

    :ok = send_frame(client, acquire("unknown", "never-created"))

    assert [
             %{
               "type" => "error",
               "request_id" => "unknown",
               "code" => "session_unknown"
             }
           ] = receive_records(client, 1)

    assert %{owner_slots: 0, lease_operations: 0} = Owner.status(daemon.owner)
    assert %{permits: 0} = AdmissionRelay.status(daemon.relay)

    :ok = send_frame(client, acquire("unknown-again", "also-never-created"))
    assert [%{"code" => "session_unknown"}] = receive_records(client, 1)
  end

  test "one controller holds, renews and releases while another connection is refused",
       %{daemon: daemon, session_id: session_id} do
    controller = initialized_client(daemon)
    observer = initialized_client(daemon)

    :ok = send_frame(controller, acquire("acquire", session_id))

    assert [%{"type" => "result", "request_id" => "acquire", "result" => granted}] =
             receive_records(controller, 1)

    refute Map.has_key?(granted, "renewed")
    {:ok, epoch} = Wire.identity(granted["writer_epoch"])

    :ok = send_frame(controller, acquire("renew", session_id))

    assert [%{"request_id" => "renew", "result" => %{"renewed" => true} = renewed}] =
             receive_records(controller, 1)

    assert renewed["writer_epoch"] == granted["writer_epoch"]

    :ok = send_frame(observer, acquire("observer-acquire", session_id))

    assert [%{"request_id" => "observer-acquire", "code" => "control_held"} = held] =
             receive_records(observer, 1)

    refute Map.has_key?(held, "writer_epoch")

    :ok = send_frame(observer, release("observer-release", session_id, epoch))

    assert [%{"request_id" => "observer-release", "code" => "control_not_held"}] =
             receive_records(observer, 1)

    stale = :crypto.strong_rand_bytes(16)
    :ok = send_frame(controller, release("stale-release", session_id, stale))

    assert [%{"request_id" => "stale-release", "code" => "control_not_held"}] =
             receive_records(controller, 1)

    :ok = send_frame(controller, release("release", session_id, epoch))

    assert [
             %{
               "type" => "result",
               "request_id" => "release",
               "result" => %{"released" => true}
             }
           ] = receive_records(controller, 1)

    eventually(fn -> Owner.status(daemon.owner).owner_slots == 0 end)

    :ok = send_frame(observer, acquire("successor", session_id))

    assert [%{"request_id" => "successor", "result" => successor}] =
             receive_records(observer, 1)

    refute successor["writer_epoch"] == granted["writer_epoch"]
  end

  test "a connection serves one session", %{
    daemon: daemon,
    runtime: runtime,
    session_id: session_id
  } do
    {:ok, other_session} =
      Loopex.create_session(runtime, %{"purpose" => "other"}, command_id: "create-2")

    client = initialized_client(daemon)
    :ok = send_frame(client, acquire("first", session_id))
    assert [%{"request_id" => "first", "type" => "result"}] = receive_records(client, 1)

    :ok = send_frame(client, acquire("second", other_session))

    assert [
             %{
               "request_id" => "second",
               "code" => "invalid_request",
               "message" => "this connection serves another session"
             }
           ] = receive_records(client, 1)

    assert %{owner_slots: 1} = Owner.status(daemon.owner)
  end

  test "a lost session owner closes its holder once and admits a fresh successor",
       %{daemon: daemon, session_id: session_id} do
    holder = initialized_client(daemon)
    observer = initialized_client(daemon)

    :ok = send_frame(holder, acquire("acquire", session_id))
    assert [%{"request_id" => "acquire", "result" => granted}] = receive_records(holder, 1)

    [{_session, lease_owner}] = lease_owners(daemon)
    monitor = Process.monitor(lease_owner)
    Process.exit(lease_owner, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^lease_owner, :killed}, 500

    assert [
             %{
               "type" => "error",
               "code" => "control_owner_lost",
               "session_id" => encoded_session
             } = close
           ] = receive_records(holder, 1)

    assert encoded_session == Wire.encode_identity(session_id)
    refute Map.has_key?(close, "request_id")
    refute Map.has_key?(close, "event_cursor")
    assert closed?(holder)

    eventually(fn -> Owner.status(daemon.owner).owner_slots == 0 end)
    assert Process.alive?(daemon.owner)

    :ok = send_frame(observer, acquire("successor", session_id))
    assert [%{"request_id" => "successor", "result" => successor}] = receive_records(observer, 1)
    refute successor["writer_epoch"] == granted["writer_epoch"]

    eventually(fn -> ConnectionRegistry.status(daemon.registry).live == 1 end)
  end

  defp acquire(request_id, session_id) do
    %{
      "method" => "session.acquire_control",
      "request_id" => request_id,
      "session_id" => Wire.encode_identity(session_id)
    }
  end

  defp release(request_id, session_id, epoch) do
    %{
      "method" => "session.release_control",
      "request_id" => request_id,
      "session_id" => Wire.encode_identity(session_id),
      "writer_epoch" => Wire.encode_identity(epoch)
    }
  end

  defp lease_owners(daemon) do
    state = :sys.get_state(daemon.owner)
    Enum.map(state.owners, fn {session_id, row} -> {session_id, row.pid} end)
  end
end
