Code.require_file("support/daemon_socket_fixture.exs", __DIR__)

defmodule LoopexDaemon.MaximumPopulationTest do
  use ExUnit.Case, async: false
  @moduletag capture_log: true

  import LoopexDaemon.Test.DaemonSocketFixture, only: [send_frame: 2, receive_records: 3]

  alias LoopexDaemon.Sentinel
  alias LoopexProtocol.{Session.V2, Wire}

  defmodule Policy do
    @moduledoc false
    @behaviour Loopex.Policy

    @impl Loopex.Policy
    def decide(_request), do: {:deny, :policy_denied}
  end

  @connections 512
  @sessions 8

  # Concept: the measurement behind `teardown_ms`: an orderly stop of a
  # daemon at its full population of 512 initialized, attached connections —
  # 64 attachments on each of 8 sessions — completes and reports its duration.
  #
  # Technical depth: every connection receives its `daemon.stopping` record or
  # sees its socket close, and the stop's wall time from the signal to the
  # sentinel's exit status is printed with the toolchain for the closure
  # evidence. The case asserts only that the stop succeeds inside the
  # provisional `teardown_ms` plus the fixed pre-teardown phases.
  @tag :long_bound
  @tag timeout: 900_000
  test "an orderly stop at the full connection and attachment population" do
    root = Path.join(System.tmp_dir!(), "lmp-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "w")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(root) end)
    socket = Path.join([root, "s", "daemon", "d.sock"])

    options = [
      state_root: Path.join(root, "s"),
      socket_path: socket,
      workspace: workspace,
      policy: Policy,
      credential: "maximum-population-placeholder"
    ]

    {:ok, output} = StringIO.open("")
    test = self()

    daemon =
      Task.async(fn ->
        Sentinel.run(options, output: output, install_signals: false, notify: test)
      end)

    assert_receive {:loopex_daemon_sentinel, sentinel, owner_ref, _owner}, 5_000
    await_ready(output, 3_000)

    creator = client(socket)

    sessions =
      for index <- 1..@sessions do
        :ok =
          send_frame(creator, %{
            "method" => "session.create",
            "request_id" => "create-#{index}",
            "command_id" => Wire.encode_identity("population-#{index}"),
            "session_options" => %{}
          })

        [%{"status" => "accepted", "session_id" => encoded}] = receive_records(creator, 1, 30_000)
        encoded
      end

    :socket.close(creator)

    clients =
      for index <- 0..(@connections - 1) do
        client = client(socket)
        encoded = Enum.at(sessions, rem(index, @sessions))

        :ok =
          send_frame(client, %{
            "method" => "session.attach",
            "request_id" => "attach",
            "session_id" => encoded,
            "after_event_sequence" => "0"
          })

        [%{"type" => "snapshot"}] = receive_records(client, 1, 30_000)
        client
      end

    # Status is asked over an attached connection: at the full population a
    # further connection would be accepted and closed unread.
    probe = List.last(clients)
    :ok = send_frame(probe, %{"method" => "daemon.status", "request_id" => "status"})
    [%{"request_id" => "status", "result" => status}] = receive_records(probe, 1, 30_000)
    assert status["connections"] == @connections
    assert status["attachments"] == @connections

    started = System.monotonic_time(:millisecond)
    send(sentinel, {:daemon_signal, owner_ref, :sigterm})
    assert Task.await(daemon, 600_000) == 0
    elapsed = System.monotonic_time(:millisecond) - started

    IO.puts(
      "maximum-population orderly stop: connections=#{@connections} attachments=#{@connections} " <>
        "elapsed_ms=#{elapsed} elixir=#{System.version()} otp=#{System.otp_release()}"
    )

    assert elapsed < 5_000 + 5_000 + 5_000 + 5_000 + 30_000
    Enum.each(clients, &:socket.close/1)
  end

  defp client(path) do
    {:ok, socket} = :socket.open(:local, :stream, :default)
    :ok = :socket.connect(socket, %{family: :local, path: path})

    :ok =
      send_frame(socket, %{
        "method" => "initialize",
        "request_id" => "init",
        "generations" => [V2.generation()],
        "capabilities" => []
      })

    [%{"type" => "initialized"}] = receive_records(socket, 1, 30_000)
    socket
  end

  defp await_ready(output, attempts) when attempts > 0 do
    case StringIO.contents(output) do
      {"", line} when byte_size(line) > 0 ->
        :ok

      _empty ->
        Process.sleep(10)
        await_ready(output, attempts - 1)
    end
  end

  defp await_ready(_output, 0), do: flunk("daemon never announced readiness")
end
