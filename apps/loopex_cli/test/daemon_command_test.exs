defmodule LoopexCli.DaemonCommandTest do
  use ExUnit.Case, async: false
  @moduletag capture_log: true

  alias LoopexDaemon.ExitStatus
  alias LoopexProtocol.{Frame, Session.V2}

  setup do
    root = Path.join(System.tmp_dir!(), "lcd-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "w")
    File.mkdir_p!(workspace)
    launch = Path.join(root, "launch.config")
    File.write!(launch, "[].\n")
    on_exit(fn -> File.rm_rf(root) end)

    %{
      root: root,
      state_root: Path.join(root, "s"),
      workspace: workspace,
      launch: launch
    }
  end

  test "grammar refusals are status one and touch nothing", %{state_root: state_root} do
    for arguments <- [
          ["--unknown", "x"],
          ["--state-root"],
          ["--state-root", ""],
          ["--state-root", state_root, "--state-root", state_root],
          ["positional"],
          ["--", "word"]
        ] do
      assert LoopexCli.Daemon.run(arguments, env: fn _ -> nil end, credential: "c") == 1
    end

    refute File.exists?(state_root)
  end

  test "prepare-index refuses every other input and imports a legacy root", context do
    for arguments <- [
          ["prepare-index", "--socket", "x"],
          ["prepare-index", "--workspace", "x"],
          ["prepare-index", "extra"],
          ["prepare-index", "--state-root"],
          ["prepare-index", "--state-root", ""],
          [
            "prepare-index",
            "--state-root",
            context.state_root,
            "--state-root",
            context.state_root
          ],
          ["prepare-index", "--", "word"],
          ["--state-root", context.state_root, "prepare-index"]
        ] do
      assert LoopexCli.Daemon.run(arguments, env: fn _ -> nil end, install_signals: false) == 1,
             inspect(arguments)
    end

    refute File.exists?(context.state_root)

    {:ok, required} = ExitStatus.fetch(:state_root_required)

    assert LoopexCli.Daemon.run(["prepare-index"], env: fn _ -> nil end, install_signals: false) ==
             required

    File.mkdir_p!(context.state_root)
    :ok = Loopex.track_session(context.state_root, "s-legacy", "legacy-placement")

    assert LoopexCli.Daemon.run(["prepare-index"],
             env: &%{"LOOPEX_HOME" => context.state_root}[&1],
             install_signals: false
           ) == 0

    assert File.regular?(Path.join([context.state_root, "daemon", "session-index-v1"]))
  end

  test "each missing or invalid input refuses with its own class before any effect", context do
    base = %{
      "LOOPEX_HOME" => context.state_root,
      "LOOPEX_WORKSPACE" => context.workspace,
      "LOOPEX_PROVIDER_LAUNCH" => context.launch,
      "LOOPEX_POLICY" => "allow-all"
    }

    cases = [
      {:state_root_required, Map.delete(base, "LOOPEX_HOME"), [], "c"},
      {:state_root_required, Map.put(base, "LOOPEX_HOME", ""), [], "c"},
      {:workspace_required, Map.delete(base, "LOOPEX_WORKSPACE"), [], "c"},
      {:workspace_unusable, Map.put(base, "LOOPEX_WORKSPACE", Path.join(context.root, "none")),
       [], "c"},
      {:provider_launch_required, Map.delete(base, "LOOPEX_PROVIDER_LAUNCH"), [], "c"},
      {:provider_launch_invalid,
       Map.put(base, "LOOPEX_PROVIDER_LAUNCH", Path.join(context.root, "missing")), [], "c"},
      {:policy_required, Map.delete(base, "LOOPEX_POLICY"), [], "c"},
      {:policy_unknown, Map.put(base, "LOOPEX_POLICY", "ask"), [], "c"},
      {:provider_credential_required, base, [], ""},
      {:cleanup_grace_invalid, base, ["--cleanup-grace-ms", "0"], "c"},
      {:invalid_socket_path, base, ["--socket", Path.join(context.root, "outside.sock")], "c"}
    ]

    for {class, env, arguments, credential} <- cases do
      {:ok, expected} = ExitStatus.fetch(class)

      assert LoopexCli.Daemon.run(arguments,
               env: &Map.get(env, &1),
               credential: credential
             ) == expected,
             "expected #{class}"
    end

    refute File.exists?(Path.join(context.state_root, "daemon"))
  end

  test "a real daemon process announces readiness once and stops orderly on SIGTERM", context do
    socket = Path.join([context.state_root, "daemon", "d.sock"])

    arguments = [
      "--state-root",
      context.state_root,
      "--workspace",
      context.workspace,
      "--provider-launch",
      context.launch,
      "--policy",
      "allow-all",
      "--socket",
      socket
    ]

    {port, os_pid} = start_daemon_process(arguments)
    line = await_line(port, 60_000)

    assert %{
             "record" => "daemon_ready",
             "root" => root,
             "socket" => ^socket,
             "version" => "0.2.0"
           } = JSON.decode!(line)

    assert root == context.state_root

    client = connect(socket)
    :ok = send_frame(client, initialize())
    assert [%{"type" => "initialized"}] = receive_records(client, 1)

    {_output, 0} = System.cmd("/bin/kill", ["-TERM", Integer.to_string(os_pid)])

    assert [%{"type" => "daemon.stopping", "reason" => "operator_stop"}] =
             receive_records(client, 1)

    assert await_exit(port, 60_000) == 0
    refute_received {^port, {:data, _more}}
    assert {:ok, %File.Stat{type: :other}} = File.lstat(socket)
  end

  defp start_daemon_process(arguments), do: start_cli_process(["daemon" | arguments])

  defp start_cli_process(argv, extra \\ []) do
    executable = System.find_executable("elixir") || raise "elixir executable unavailable"
    code = "LoopexCli.main(#{inspect(argv)})"

    port =
      Port.open(
        {:spawn_executable, String.to_charlist(executable)},
        [
          :binary,
          :exit_status,
          :use_stdio,
          :hide,
          {:line, 65_536},
          env: [{~c"LOOPEX_PROVIDER_API_KEY", ~c"daemon-command-placeholder"}]
        ] ++
          extra ++
          [
            args:
              Enum.flat_map(:code.get_path(), fn dir -> ["-pa", List.to_string(dir)] end) ++
                ["-e", code]
          ]
      )

    {:os_pid, os_pid} = Port.info(port, :os_pid)

    on_exit(fn ->
      System.cmd("/bin/kill", ["-KILL", Integer.to_string(os_pid)], stderr_to_stdout: true)
    end)

    {port, os_pid}
  end

  test "a real SIGTERM detaches a waiting live take-over with status zero", context do
    socket = Path.join([context.state_root, "daemon", "d.sock"])

    {daemon, daemon_pid} =
      start_daemon_process([
        "--state-root",
        context.state_root,
        "--workspace",
        context.workspace,
        "--provider-launch",
        context.launch,
        "--policy",
        "allow-all",
        "--socket",
        socket
      ])

    _ready = await_line(daemon, 60_000)

    # This test's own client creates the session and holds its lease, so the
    # take-over below waits for it without bound.
    holder = connect(socket)
    :ok = send_frame(holder, initialize())
    assert [%{"type" => "initialized"}] = receive_records(holder, 1)

    :ok =
      send_frame(holder, %{
        "method" => "session.create",
        "request_id" => "create",
        "command_id" => LoopexProtocol.Wire.encode_identity("signal-create"),
        "session_options" => %{}
      })

    assert [%{"status" => "accepted", "session_id" => encoded}] = receive_records(holder, 1)
    {:ok, session_id} = LoopexProtocol.Wire.identity(encoded)

    :ok =
      send_frame(holder, %{
        "method" => "session.acquire_control",
        "request_id" => "hold",
        "session_id" => encoded
      })

    assert [%{"request_id" => "hold", "type" => "result"}] = receive_records(holder, 1)

    {client, client_pid} =
      start_cli_process(
        ["attach", session_id, "--daemon", socket, "--take-over"],
        [:stderr_to_stdout]
      )

    # The command installs its handler before it dials, so once the daemon
    # counts the client's connection the signal can only reach that handler.
    wait_for_connections(holder, 2)
    {_output, 0} = System.cmd("/bin/kill", ["-TERM", Integer.to_string(client_pid)])

    {status, lines} = await_exit_lines(client, 30_000, [])
    assert status == 0
    assert Enum.any?(lines, &(&1 =~ "detached; the session continues in the daemon"))
    {_output, 0} = System.cmd("/bin/kill", ["-TERM", Integer.to_string(daemon_pid)])
    assert await_exit(daemon, 60_000) == 0
  end

  defp wait_for_connections(holder, count, attempts \\ 500) do
    :ok =
      send_frame(holder, %{"method" => "daemon.status", "request_id" => "status-#{attempts}"})

    [%{"result" => %{"connections" => connections}}] = receive_records(holder, 1)

    cond do
      connections >= count ->
        :ok

      attempts > 0 ->
        Process.sleep(20)
        wait_for_connections(holder, count, attempts - 1)

      true ->
        flunk("the live client never connected")
    end
  end

  defp await_exit_lines(port, bound, lines) do
    receive do
      {^port, {:data, {_flag, line}}} -> await_exit_lines(port, bound, [line | lines])
      {^port, {:exit_status, status}} -> {status, Enum.reverse(lines)}
    after
      bound -> flunk("the client never exited")
    end
  end

  defp await_line(port, bound) do
    receive do
      {^port, {:data, {:eol, line}}} -> line
      {^port, {:exit_status, status}} -> flunk("the daemon exited #{status} before readiness")
    after
      bound -> flunk("the daemon never announced readiness")
    end
  end

  defp await_exit(port, bound) do
    receive do
      {^port, {:exit_status, status}} -> status
    after
      bound -> flunk("the daemon never exited")
    end
  end

  defp connect(path) do
    {:ok, socket} = :socket.open(:local, :stream, :default)
    :ok = :socket.connect(socket, %{family: :local, path: path})
    socket
  end

  defp initialize do
    %{
      "method" => "initialize",
      "request_id" => "init",
      "generations" => [V2.generation()],
      "capabilities" => []
    }
  end

  defp send_frame(socket, record) do
    {:ok, encoded} = Frame.encode(record)
    :socket.send(socket, IO.iodata_to_binary(encoded))
  end

  defp receive_records(socket, count, buffered \\ "") do
    parts = :binary.split(buffered, "\n", [:global])

    if length(parts) > count do
      parts
      |> Enum.take(count)
      |> Enum.map(fn payload ->
        {:ok, record} = Frame.decode(payload, Frame.output_record_bytes())
        record
      end)
    else
      {:ok, bytes} = :socket.recv(socket, 0, 30_000)
      receive_records(socket, count, buffered <> bytes)
    end
  end
end
