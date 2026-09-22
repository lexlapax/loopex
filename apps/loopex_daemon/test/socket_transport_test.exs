Code.require_file("support/daemon_socket_fixture.exs", __DIR__)

defmodule LoopexDaemon.SocketTransportTest do
  use ExUnit.Case, async: true
  @moduletag capture_log: true

  import LoopexDaemon.Test.DaemonSocketFixture

  alias LoopexDaemon.{AdmissionRelay, ConnectionRegistry}
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

  defp create(request_id, command_id, options) do
    %{
      "method" => "session.create",
      "request_id" => request_id,
      "command_id" => Wire.encode_identity(command_id),
      "session_options" => options
    }
  end
end
