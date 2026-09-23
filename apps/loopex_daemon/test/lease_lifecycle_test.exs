Code.require_file("support/daemon_socket_fixture.exs", __DIR__)

defmodule LoopexDaemon.LeaseLifecycleTest do
  use ExUnit.Case, async: true
  @moduletag capture_log: true

  import LoopexDaemon.Test.DaemonSocketFixture

  alias LoopexProtocol.Wire

  @lease_term_ms 1_000

  setup do
    root = temporary_directory("loopex-lease-lifecycle")
    runtime = start_runtime(root)
    %{runtime: runtime, daemon: start_daemon(runtime, lease_term_ms: @lease_term_ms)}
  end

  # Concept: a controller that goes away without releasing keeps its lease
  # until the term lapses. Nothing forces it off early, and nothing keeps it
  # longer.
  #
  # Technical depth: the holder closes its socket without sending
  # `session.release_control`. A second client asking inside the term is
  # refused `control_held`; asking after it is granted a different writer
  # epoch. The term here is one second.
  test "a holder that closes without releasing is replaced only after its term",
       %{daemon: daemon} do
    holder = initialized_client(daemon)
    session_id = create_session(holder, "eof-create")
    {first_epoch, granted_at} = acquire!(holder, session_id)
    :ok = :socket.close(holder)

    successor = initialized_client(daemon)
    :ok = send_frame(successor, acquire("early", session_id))
    assert [%{"request_id" => "early", "code" => "control_held"}] = receive_records(successor, 1)
    assert System.monotonic_time(:millisecond) - granted_at < @lease_term_ms

    {second_epoch, _at} = acquire_after_expiry!(successor, session_id)
    assert System.monotonic_time(:millisecond) - granted_at >= @lease_term_ms
    refute second_epoch == first_epoch
  end

  # Concept: once another client holds control, a command carrying the lapsed
  # holder's epoch is refused before it reaches the session, and the session's
  # journal is unchanged by it.
  #
  # Technical depth: the first holder stays connected but stops renewing; the
  # successor is granted after expiry. The first holder's prompt under its old
  # epoch is refused `control_not_held`, the session's durable event sequence
  # does not move, and the successor's prompt under its own epoch is admitted.
  test "a lapsed holder's epoch is refused without touching the session",
       %{daemon: daemon, runtime: runtime} do
    lapsed = initialized_client(daemon)
    session_id = create_session(lapsed, "lapse-create")
    {old_epoch, _at} = acquire!(lapsed, session_id)
    :ok = send_frame(lapsed, attach("watch", session_id))
    assert [%{"request_id" => "watch", "type" => "snapshot"}] = receive_records(lapsed, 1)

    successor = initialized_client(daemon)
    {new_epoch, _at} = acquire_after_expiry!(successor, session_id)
    :ok = send_frame(successor, attach("follow", session_id))
    assert [%{"request_id" => "follow", "type" => "snapshot"}] = receive_records(successor, 1)
    before = event_sequence(runtime, session_id)

    :ok = send_frame(lapsed, prompt("stale", "stale-prompt", old_epoch))
    assert [%{"request_id" => "stale", "code" => "control_not_held"}] = receive_records(lapsed, 1)
    assert event_sequence(runtime, session_id) == before

    :ok = send_frame(successor, prompt("fresh", "fresh-prompt", new_epoch))

    assert [%{"request_id" => "fresh", "status" => "accepted"}] =
             receive_until(successor, &(&1["request_id"] == "fresh"))
  end

  # Concept: controller authority is a daemon-lifetime fact, never durable
  # truth, so a restarted daemon starts with every session uncontrolled and no
  # epoch from the earlier lifetime means anything to it.
  #
  # Technical depth: the first daemon's holder never releases; that daemon's
  # collaboration processes stop and a fresh daemon is started over the same
  # runtime. A prompt under the old epoch is refused `control_not_held`
  # without an acquisition, and a fresh acquisition is granted at once rather
  # than waiting for the old term.
  test "a restarted daemon holds no lease and refuses an earlier lifetime's epoch",
       %{runtime: runtime, daemon: first} do
    holder = initialized_client(first)
    session_id = create_session(holder, "restart-create")
    {old_epoch, _at} = acquire!(holder, session_id)
    :ok = GenServer.stop(first.owner, :normal)

    second = start_daemon(runtime, lease_term_ms: 60_000)
    client = initialized_client(second)

    :ok = send_frame(client, prompt("stale", "restart-stale", old_epoch))
    assert [%{"request_id" => "stale", "code" => "control_not_held"}] = receive_records(client, 1)

    # No lease survived: control is granted at once, not after the old term.
    started = System.monotonic_time(:millisecond)
    {new_epoch, _at} = acquire!(client, session_id)
    assert System.monotonic_time(:millisecond) - started < 5_000
    refute new_epoch == old_epoch

    :ok = send_frame(client, resume("resume", session_id, "restart-resume", new_epoch))

    assert [%{"request_id" => "resume", "status" => "accepted"}] =
             receive_until(client, &(&1["request_id"] == "resume"))
  end

  defp acquire!(client, session_id) do
    :ok = send_frame(client, acquire("acquire", session_id))

    assert [
             %{
               "request_id" => "acquire",
               "type" => "result",
               "result" => %{"writer_epoch" => epoch}
             }
           ] =
             receive_records(client, 1)

    {epoch, System.monotonic_time(:millisecond)}
  end

  defp acquire_after_expiry!(client, session_id, attempts \\ 100) do
    :ok = send_frame(client, acquire("retry", session_id))

    case receive_records(client, 1) do
      [%{"request_id" => "retry", "type" => "result", "result" => %{"writer_epoch" => epoch}}] ->
        {epoch, System.monotonic_time(:millisecond)}

      [%{"request_id" => "retry", "code" => code}]
      when code in ["control_held", "control_pending"] and attempts > 0 ->
        Process.sleep(100)
        acquire_after_expiry!(client, session_id, attempts - 1)
    end
  end

  defp receive_until(socket, predicate) do
    [record] = receive_records(socket, 1)
    if predicate.(record), do: [record], else: receive_until(socket, predicate)
  end

  defp event_sequence(runtime, session_id) do
    {:ok, attachment} = Loopex.attach(runtime, session_id)
    Loopex.snapshot(attachment).event_sequence
  end

  defp create_session(client, command_id) do
    :ok =
      send_frame(client, %{
        "method" => "session.create",
        "request_id" => command_id,
        "command_id" => Wire.encode_identity(command_id),
        "session_options" => %{"purpose" => command_id}
      })

    assert [%{"status" => "accepted", "session_id" => encoded}] = receive_records(client, 1)
    {:ok, session_id} = Wire.identity(encoded)
    session_id
  end

  defp acquire(request_id, session_id) do
    %{
      "method" => "session.acquire_control",
      "request_id" => request_id,
      "session_id" => Wire.encode_identity(session_id)
    }
  end

  defp attach(request_id, session_id) do
    %{
      "method" => "session.attach",
      "request_id" => request_id,
      "session_id" => Wire.encode_identity(session_id),
      "after_event_sequence" => "0"
    }
  end

  defp prompt(request_id, command_id, epoch) do
    %{
      "method" => "session.prompt",
      "request_id" => request_id,
      "command_id" => Wire.encode_identity(command_id),
      "content_b64" => Wire.encode_bytes("hello"),
      "writer_epoch" => epoch
    }
  end

  defp resume(request_id, session_id, command_id, epoch) do
    %{
      "method" => "session.resume",
      "request_id" => request_id,
      "session_id" => Wire.encode_identity(session_id),
      "command_id" => Wire.encode_identity(command_id),
      "writer_epoch" => epoch
    }
  end
end
