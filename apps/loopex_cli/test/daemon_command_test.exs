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

  # Concept: the daemon command consumes the operator's variable once, at
  # entry; a later start in the same VM finds nothing and refuses before any
  # effect rather than finding a restored copy.
  test "the credential is consumed once per VM and a second start refuses", context do
    System.put_env("LOOPEX_PROVIDER_API_KEY", "consumed-once-placeholder")
    File.mkdir_p!(context.state_root)

    assert LoopexCli.Daemon.run(["prepare-index", "--state-root", context.state_root],
             install_signals: false
           ) == 0

    assert System.get_env("LOOPEX_PROVIDER_API_KEY") == nil
    {:ok, required} = ExitStatus.fetch(:provider_credential_required)

    env = %{
      "LOOPEX_HOME" => context.state_root,
      "LOOPEX_WORKSPACE" => context.workspace,
      "LOOPEX_PROVIDER_LAUNCH" => context.launch,
      "LOOPEX_POLICY" => "allow-all"
    }

    assert LoopexCli.Daemon.run([], env: &Map.get(env, &1), install_signals: false) == required
    refute File.exists?(Path.join([context.state_root, "daemon", "daemon.sock"]))
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

  # Concept: an operator's supervisor reads exactly one line from the daemon's
  # standard output, so that line is compared byte for byte, and nothing else
  # may ever appear there, even for a state root whose name needs escaping.
  #
  # Technical depth: the root's final component carries a quote, a backslash, a
  # space, a tab and a newline. Standard output is read raw from start to exit,
  # so a second record, a missing or doubled LF, or any stray byte fails. The
  # incarnation is the one value the test cannot know in advance; it is pinned
  # to its lowercase-hex shape and every other byte is literal.
  test "a real daemon writes exactly one escaped readiness line and nothing else", context do
    base = Path.join("/tmp", "lcr-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(base) end)
    state_root = Path.join(base, "r \"q\\b\tt\nn")
    socket = Path.join([state_root, "daemon", "daemon.sock"])

    {port, os_pid} =
      start_cli_process(
        [
          "daemon",
          "--state-root",
          state_root,
          "--workspace",
          context.workspace,
          "--provider-launch",
          context.launch,
          "--policy",
          "allow-all"
        ],
        [:stream]
      )

    output = await_raw(port, "", 60_000)
    escaped_root = base <> "/r \\\"q\\\\b\\tt\\nn"

    assert [_, incarnation] =
             Regex.run(~r/"incarnation":"([0-9a-f]+)"/, output),
           "no incarnation in #{inspect(output)}"

    assert output ==
             ~s({"record":"daemon_ready","root":"#{escaped_root}","socket":"#{escaped_root}/daemon/daemon.sock","incarnation":"#{incarnation}","version":"0.2.0"}\n)

    assert JSON.decode!(output)["socket"] == socket

    {_output, 0} = System.cmd("/bin/kill", ["-TERM", Integer.to_string(os_pid)])
    assert {rest, 0} = drain_raw(port, "", 60_000)
    assert rest == "", "the daemon wrote more to standard output: #{inspect(rest)}"
  end

  # Concept: the root's Store marker decides whether a daemon may start. A live
  # writer refuses the daemon with its own class and an unverifiable marker
  # with another, each before any socket exists and with the marker untouched;
  # a daemon killed outright leaves a marker its successor recovers.
  #
  # Technical depth: every start is a real `loopex daemon` process. The live
  # writer is a Store opened on the root's log by this test VM; the
  # unverifiable marker is bytes no Store wrote. After `SIGKILL` the dead
  # holder's marker remains and the next daemon reaches readiness.
  test "a real daemon refuses a live or unverifiable Store marker and recovers a killed one",
       context do
    File.mkdir_p!(context.state_root)
    log = Path.join(context.state_root, "store.log")
    marker = log <> ".writer"
    socket = Path.join([context.state_root, "daemon", "daemon.sock"])

    arguments = [
      "daemon",
      "--state-root",
      context.state_root,
      "--workspace",
      context.workspace,
      "--provider-launch",
      context.launch,
      "--policy",
      "allow-all"
    ]

    {:ok, holder} = Loopex.Store.Local.start_link(path: log)
    held = File.read!(marker)
    {:ok, active} = ExitStatus.fetch(:store_writer_active)
    assert {"", ^active} = run_raw(arguments)
    assert File.read!(marker) == held
    refute File.exists?(socket)
    :ok = GenServer.stop(holder)

    File.write!(marker, "not a marker any Store wrote\n")
    {:ok, unverifiable} = ExitStatus.fetch(:store_writer_unverifiable)
    assert {"", ^unverifiable} = run_raw(arguments)
    assert File.read!(marker) == "not a marker any Store wrote\n"
    refute File.exists?(socket)
    File.rm!(marker)

    {first, first_pid} = start_cli_process(arguments, [:stream])
    assert await_raw(first, "", 60_000) =~ ~s("record":"daemon_ready")
    {_output, 0} = System.cmd("/bin/kill", ["-KILL", Integer.to_string(first_pid)])
    assert {_rest, status} = drain_raw(first, "", 30_000)
    assert status != 0
    assert File.regular?(marker), "the killed daemon left no marker to recover"

    {second, second_pid} = start_cli_process(arguments, [:stream])
    assert await_raw(second, "", 60_000) =~ ~s("record":"daemon_ready")
    {_output, 0} = System.cmd("/bin/kill", ["-TERM", Integer.to_string(second_pid)])
    assert {"", 0} = drain_raw(second, "", 60_000)
    refute File.exists?(marker)
  end

  # Concept: once the daemon's handler is installed, only `SIGTERM` is an
  # orderly stop. `SIGQUIT` is ignored while the daemon keeps serving, and
  # `SIGHUP` is the operating system's own termination: status 129, no orderly
  # record, and residue the next daemon recovers.
  #
  # Technical depth: both are real signals to a real daemon process. After
  # `SIGQUIT` a new client still initializes and a later `SIGTERM` still ends
  # with `daemon.stopping` and status 0. After `SIGHUP` the connected client
  # sees its socket close with no `daemon.stopping`, the Store marker stays, and
  # a successor reaches readiness.
  test "after installation SIGQUIT is ignored and SIGHUP ends the daemon with status 129",
       context do
    arguments = [
      "daemon",
      "--state-root",
      context.state_root,
      "--workspace",
      context.workspace,
      "--provider-launch",
      context.launch,
      "--policy",
      "allow-all"
    ]

    socket = Path.join([context.state_root, "daemon", "daemon.sock"])
    marker = Path.join(context.state_root, "store.log.writer")

    {quitting, quitting_pid} = start_cli_process(arguments, [:stream])
    assert await_raw(quitting, "", 60_000) =~ ~s("record":"daemon_ready")
    {_output, 0} = System.cmd("/bin/kill", ["-QUIT", Integer.to_string(quitting_pid)])
    Process.sleep(500)

    client = connect(socket)
    :ok = send_frame(client, initialize())
    assert [%{"type" => "initialized"}] = receive_records(client, 1)

    {_output, 0} = System.cmd("/bin/kill", ["-TERM", Integer.to_string(quitting_pid)])

    assert [%{"type" => "daemon.stopping", "reason" => "operator_stop"}] =
             receive_records(client, 1)

    assert {"", 0} = drain_raw(quitting, "", 60_000)

    {hanging, hanging_pid} = start_cli_process(arguments, [:stream])
    assert await_raw(hanging, "", 60_000) =~ ~s("record":"daemon_ready")
    watcher = connect(socket)
    :ok = send_frame(watcher, initialize())
    assert [%{"type" => "initialized"}] = receive_records(watcher, 1)

    {_output, 0} = System.cmd("/bin/kill", ["-HUP", Integer.to_string(hanging_pid)])
    assert {"", 129} = drain_raw(hanging, "", 30_000)
    assert {:error, _closed} = :socket.recv(watcher, 0, 5_000)
    assert File.regular?(marker), "an abrupt stop left no marker for its successor"

    {successor, successor_pid} = start_cli_process(arguments, [:stream])
    assert await_raw(successor, "", 60_000) =~ ~s("record":"daemon_ready")
    {_output, 0} = System.cmd("/bin/kill", ["-TERM", Integer.to_string(successor_pid)])
    assert {"", 0} = drain_raw(successor, "", 60_000)
  end

  # Concept: a Store log larger than the Store will read refuses the daemon
  # with its own class before any socket exists, and leaves the log alone.
  #
  # Technical depth: the log is a sparse file one byte over the 256 MiB read
  # ceiling, so the refusal is decided from its size, as the Store decides it.
  test "a real daemon refuses an oversized Store log as store_log_too_large", context do
    File.mkdir_p!(context.state_root)
    log = Path.join(context.state_root, "store.log")
    {:ok, file} = :file.open(log, [:write, :raw, :binary])
    {:ok, _position} = :file.position(file, 256 * 1_048_576)
    :ok = :file.write(file, "x")
    :ok = :file.close(file)

    {:ok, too_large} = ExitStatus.fetch(:store_log_too_large)

    assert {"", ^too_large} =
             run_raw([
               "daemon",
               "--state-root",
               context.state_root,
               "--workspace",
               context.workspace,
               "--provider-launch",
               context.launch,
               "--policy",
               "allow-all"
             ])

    assert File.stat!(log).size == 256 * 1_048_576 + 1
    refute File.exists?(Path.join([context.state_root, "daemon", "daemon.sock"]))
    refute File.exists?(log <> ".writer")
  end

  defp run_raw(arguments) do
    {port, _os_pid} = start_cli_process(arguments, [:stream])
    drain_raw(port, "", 60_000)
  end

  defp await_raw(port, acc, bound) do
    receive do
      {^port, {:data, bytes}} ->
        acc = acc <> bytes
        if String.ends_with?(acc, "\n"), do: acc, else: await_raw(port, acc, bound)

      {^port, {:exit_status, status}} ->
        flunk("the daemon exited #{status} before readiness: #{inspect(acc)}")
    after
      bound -> flunk("the daemon never announced readiness")
    end
  end

  defp drain_raw(port, acc, bound) do
    receive do
      {^port, {:data, bytes}} -> drain_raw(port, acc <> bytes, bound)
      {^port, {:exit_status, status}} -> {acc, status}
    after
      bound -> flunk("the daemon never exited")
    end
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
          env: [{~c"LOOPEX_PROVIDER_API_KEY", ~c"daemon-command-placeholder"}]
        ] ++
          if(:stream in extra, do: [], else: [{:line, 65_536}]) ++
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
