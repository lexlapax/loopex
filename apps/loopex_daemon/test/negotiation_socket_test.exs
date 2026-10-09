Code.require_file("support/daemon_socket_fixture.exs", __DIR__)

defmodule LoopexDaemon.NegotiationSocketTest do
  @moduledoc """
  ## Concept

  The daemon's one negotiation attempt behaves the same on a real socket as
  the plan's offer table: it selects only its own current generation from any
  mixed offer, refuses everything else once, and a refused or malformed
  connection can never create, attach, resume, take control or mutate.

  ## Technical depth

  ADR 0044 and the M7 negotiation table over served `loopex.experimental/4`.
  Each case uses a fresh connection to one real daemon and asserts the exact
  error code and that no activation was spent.
  """

  use ExUnit.Case, async: true
  @moduletag capture_log: true

  import LoopexDaemon.Test.DaemonSocketFixture

  alias LoopexDaemon.ConnectionRegistry
  alias LoopexProtocol.Session.V2
  alias LoopexProtocol.Wire

  setup do
    root = temporary_directory("loopex-negotiation-socket")
    runtime = start_runtime(root)
    %{daemon: start_daemon(runtime)}
  end

  test "mixed offers select the daemon generation in either order", %{daemon: daemon} do
    for offer <- [
          ["loopex.experimental/2", "loopex.experimental/3", V2.generation()],
          [V2.generation(), "loopex.session.v1-experimental", "loopex.experimental/3"]
        ] do
      client = connect(daemon)
      :ok = send_frame(client, initialize("mixed", offer))

      assert [
               %{
                 "type" => "initialized",
                 "request_id" => "mixed",
                 "selected_generation" => "loopex.experimental/4",
                 "exact_schema_sha256" => digest
               }
             ] = receive_records(client, 1)

      assert digest == V2.schema_digest()
      :socket.close(client)
    end
  end

  test "a refused offer fences every later session request", %{daemon: daemon} do
    client = connect(daemon)
    :ok = send_frame(client, initialize("old", ["loopex.experimental/2"]))
    assert [%{"code" => "unsupported_generation"}] = receive_records(client, 1)
    :ok = send_frame(client, initialize("again", [V2.generation()]))

    assert [%{"request_id" => "again", "code" => "already_initialized"}] =
             receive_records(client, 1)

    for request <- session_requests() do
      :ok = send_frame(client, request)

      assert [%{"type" => "error", "request_id" => id, "code" => "not_initialized"}] =
               receive_records(client, 1)

      assert id == request["request_id"]
    end

    assert %{activations_used: 0, active_sessions: 0} = ConnectionRegistry.status(daemon.registry)
  end

  test "a malformed initialize spends no attempt and a later valid one succeeds once",
       %{daemon: daemon} do
    client = connect(daemon)

    for bad <- [
          Map.put(initialize("extra", [V2.generation()]), "extra", true),
          Map.delete(initialize("missing", [V2.generation()]), "capabilities"),
          initialize("numbers", [1])
        ] do
      :ok = send_frame(client, bad)
      assert [%{"type" => "error", "code" => "invalid_request"}] = receive_records(client, 1)
    end

    :ok = send_frame(client, initialize("valid", [V2.generation()]))
    assert [%{"type" => "initialized", "request_id" => "valid"}] = receive_records(client, 1)
    :ok = send_frame(client, initialize("repeat", [V2.generation()]))

    assert [%{"request_id" => "repeat", "code" => "already_initialized"}] =
             receive_records(client, 1)

    assert %{activations_used: 0} = ConnectionRegistry.status(daemon.registry)
  end

  defp initialize(id, generations),
    do: %{
      "method" => "initialize",
      "request_id" => id,
      "generations" => generations,
      "capabilities" => []
    }

  defp session_requests do
    session = Wire.encode_identity("s_test_1")
    epoch = Wire.encode_identity("epoch")
    command = Wire.encode_identity("command")

    [
      %{
        "method" => "session.create",
        "request_id" => "create",
        "command_id" => command,
        "session_options" => %{"version" => 1}
      },
      %{"method" => "session.attach", "request_id" => "attach", "session_id" => session},
      %{
        "method" => "session.resume",
        "request_id" => "resume",
        "session_id" => session,
        "command_id" => command
      },
      %{
        "method" => "session.acquire_control",
        "request_id" => "acquire",
        "session_id" => session
      },
      %{
        "method" => "session.prompt",
        "request_id" => "prompt",
        "command_id" => command,
        "content_b64" => Wire.encode_bytes("go"),
        "writer_epoch" => epoch
      },
      %{
        "method" => "session.configure",
        "request_id" => "configure",
        "command_id" => command,
        "changes" => %{"max_tokens" => "512"},
        "writer_epoch" => epoch
      },
      %{
        "method" => "session.compact",
        "request_id" => "compact",
        "command_id" => command,
        "writer_epoch" => epoch
      },
      %{
        "method" => "session.respond_interaction",
        "request_id" => "answer",
        "command_id" => command,
        "interaction_id" => Wire.encode_identity("interaction"),
        "answer" => %{"disposition" => "declined"},
        "writer_epoch" => epoch
      }
    ]
  end
end
