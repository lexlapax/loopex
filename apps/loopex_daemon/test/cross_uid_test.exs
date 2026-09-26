Code.require_file("support/daemon_socket_fixture.exs", __DIR__)

defmodule LoopexDaemon.CrossUidTest do
  use ExUnit.Case, async: false
  @moduletag capture_log: true

  alias LoopexDaemon.Sentinel

  defmodule Policy do
    @moduledoc false
    @behaviour Loopex.Policy

    @impl Loopex.Policy
    def decide(_request), do: {:deny, :policy_denied}
  end

  # A minimal independent client: connect, send one initialize frame, and
  # report every byte the daemon wrote before closing.
  @client ~S"""
  import socket, sys
  s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
  s.settimeout(10)
  try:
      s.connect(sys.argv[1])
  except OSError as error:
      print("connect-refused", error.errno)
      sys.exit(0)
  s.sendall(b'{"method":"initialize","request_id":"x","generations":["loopex.experimental/2"],"capabilities":[]}\n')
  data = b""
  try:
      while True:
          chunk = s.recv(65536)
          if not chunk:
              break
          data += chunk
          if b"\n" in data:
              break
  except OSError:
      pass
  print("received", len(data), "initialized" if b'"type":"initialized"' in data else "no-initialized-record")
  """

  # Concept: the peer-credential check admits only the daemon's own user. A
  # connection from another operating-system user is refused before it can
  # initialize; one from the daemon's user is served.
  #
  # Technical depth: these run only on the release check's Linux lane, which
  # names a second unprivileged user in `LOOPEX_CROSS_UID_USER` that the
  # current user may run a command as with `sudo -n`. The foreign user is first
  # refused by the kernel at the verified `0700`/`0600` modes; the modes are
  # then relaxed so a second connection reaches accept and the daemon's own
  # peer check is what refuses it, and cleanup restores both modes. A missing
  # second user is a failure, never a skip.
  @tag :cross_uid
  test "a connection from another user is refused before initialize", context do
    user = System.get_env("LOOPEX_CROSS_UID_USER")

    if user in [nil, ""],
      do: flunk("LOOPEX_CROSS_UID_USER names no second user: evidence unavailable")

    {socket, stop} = start_daemon(context)
    directory = Path.dirname(socket)
    assert File.stat!(directory).mode |> Bitwise.band(0o777) == 0o700
    assert File.stat!(socket).mode |> Bitwise.band(0o777) == 0o600

    # At the verified modes the kernel itself refuses the foreign user.
    assert foreign(user, socket) =~ "connect-refused"

    File.chmod!(directory, 0o711)
    File.chmod!(socket, 0o666)

    try do
      # With the modes relaxed the connection reaches accept, and the daemon's
      # peer-credential check closes it before initialize.
      output = foreign(user, socket)
      refute output =~ " initialized"
      assert output =~ "received 0", output
    after
      File.chmod!(socket, 0o600)
      File.chmod!(directory, 0o700)
    end

    stop.()
  end

  @tag :cross_uid
  test "a connection from the daemon's own user is served", context do
    {socket, stop} = start_daemon(context)

    {output, 0} = System.cmd("python3", ["-c", @client, socket], stderr_to_stdout: true)
    assert output =~ " initialized"
    stop.()
  end

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "lxu-#{Loopex.TestTmp.Daemon.token()}"
      )

    workspace = Path.join(root, "w")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(root) end)
    %{root: root, workspace: workspace}
  end

  defp foreign(user, socket) do
    {output, status} =
      System.cmd("sudo", ["-n", "-u", user, "python3", "-c", @client, socket],
        stderr_to_stdout: true
      )

    assert status == 0, output
    output
  end

  defp start_daemon(context) do
    socket = Path.join([context.root, "s", "daemon", "d.sock"])

    options = [
      state_root: Path.join(context.root, "s"),
      socket_path: socket,
      workspace: context.workspace,
      policy: Policy,
      credential: "cross-uid-placeholder"
    ]

    {:ok, output} = StringIO.open("")
    test = self()

    task =
      Task.async(fn ->
        Sentinel.run(options, output: output, install_signals: false, notify: test)
      end)

    assert_receive {:loopex_daemon_sentinel, sentinel, owner_ref, _owner}, 5_000
    await_ready(output, 3_000)

    stop = fn ->
      send(sentinel, {:daemon_signal, owner_ref, :sigterm})
      assert Task.await(task, 60_000) == 0
    end

    {socket, stop}
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
