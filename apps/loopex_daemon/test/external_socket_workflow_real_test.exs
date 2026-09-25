Code.require_file("support/daemon_socket_fixture.exs", __DIR__)

defmodule LoopexDaemon.ExternalSocketWorkflowRealTest do
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

  # Concept: the release lane's proof that a daemon composed with the built
  # provider companion and a real credential serves one session to a
  # controller and an observer over its socket, each seeing the real answer.
  #
  # Technical depth: the credential comes only from the release check's
  # `LOOPEX_PROVIDER_API_KEY` into the daemon's custody; this case never
  # prints it. It is read and deleted from this VM's environment in one step,
  # as a host consumes it, so nothing started afterwards inherits it; the
  # release check runs each real-provider case in a VM of its own. Its
  # absence is evidence unavailable, never a pass.
  @tag :real_provider
  @tag timeout: 900_000
  test "a controller and observer complete the documented daemon workflow against a real provider" do
    credential = System.get_env("LOOPEX_PROVIDER_API_KEY")
    System.delete_env("LOOPEX_PROVIDER_API_KEY")
    if credential in [nil, ""], do: flunk("provider credential unavailable: evidence unavailable")

    root = Path.join(System.tmp_dir!(), "ldr-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "w")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(root) end)
    launch = build_companion(Path.join(physical(root), "build"))

    socket = Path.join([root, "s", "daemon", "d.sock"])

    options = [
      state_root: Path.join(root, "s"),
      socket_path: socket,
      workspace: workspace,
      policy: Policy,
      provider_launch: launch,
      credential: credential
    ]

    {:ok, output} = StringIO.open("")
    test = self()

    daemon =
      Task.async(fn ->
        Sentinel.run(options, output: output, install_signals: false, notify: test)
      end)

    assert_receive {:loopex_daemon_sentinel, sentinel, owner_ref, _owner}, 5_000
    await_ready(output, 3_000)

    controller = client(socket)
    observer = client(socket)

    :ok =
      send_frame(controller, %{
        "method" => "session.create",
        "request_id" => "create",
        "command_id" => Wire.encode_identity("real-create"),
        "session_options" => %{}
      })

    [%{"status" => "accepted", "session_id" => encoded}] = receive_records(controller, 1, 60_000)

    :ok =
      send_frame(controller, %{
        "method" => "session.acquire_control",
        "request_id" => "acquire",
        "session_id" => encoded
      })

    [%{"result" => %{"writer_epoch" => epoch}}] = receive_records(controller, 1, 60_000)

    for {client, id} <- [{controller, "attach"}, {observer, "observe"}] do
      :ok =
        send_frame(client, %{
          "method" => "session.attach",
          "request_id" => id,
          "session_id" => encoded,
          "after_event_sequence" => "0"
        })

      [%{"type" => "snapshot"}] = receive_records(client, 1, 60_000)
    end

    :ok =
      send_frame(controller, %{
        "method" => "session.prompt",
        "request_id" => "prompt",
        "command_id" => Wire.encode_identity("real-prompt"),
        "content_b64" => Wire.encode_bytes("Reply with the single word: pong"),
        "writer_epoch" => epoch
      })

    for client <- [controller, observer] do
      kinds = events_until_finished(client, [])
      assert "assistant.message_appended" in kinds
      assert List.last(kinds) == "run.finished"
    end

    send(sentinel, {:daemon_signal, owner_ref, :sigterm})
    assert Task.await(daemon, 120_000) == 0
  end

  # The documented companion build, into this case's own build root.
  defp build_companion(build) do
    adapter = Path.expand("../../loopex_llm_reqllm", __DIR__)
    mix = System.find_executable("mix") || flunk("Mix executable unavailable")

    {log, status} =
      System.cmd(mix, ["loopex.provider.build"],
        cd: adapter,
        env: [
          # The same isolated test-environment build the M4 real-provider lane
          # uses, so the release run needs no second dependency compilation.
          {"MIX_ENV", "test"},
          {"HEX_OFFLINE", "1"},
          {"MIX_BUILD_PATH", build},
          {"LOOPEX_PROVIDER_API_KEY", nil},
          {"ANTHROPIC_API_KEY", nil}
        ],
        stderr_to_stdout: true
      )

    assert status == 0, log

    {:ok, [launch]} =
      :file.consult(String.to_charlist(Path.join(build, "loopex_provider.launch")))

    launch
  end

  # Mix links `priv` by resolved paths, so a build root reached through a
  # symbolic link (`/var` on macOS) must be named by its physical path.
  defp physical(directory) do
    {path, 0} = System.cmd("sh", ["-c", "cd \"$1\" && pwd -P", "sh", directory])
    String.trim(path)
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

  defp events_until_finished(socket, kinds) do
    case receive_records(socket, 1, 300_000) do
      [%{"type" => "event", "event" => %{"kind" => "run.finished"}}] ->
        Enum.reverse(["run.finished" | kinds])

      [%{"type" => "event", "event" => %{"kind" => kind}}] ->
        events_until_finished(socket, [kind | kinds])

      [_other] ->
        events_until_finished(socket, kinds)
    end
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
