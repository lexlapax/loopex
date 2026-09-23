Code.require_file("support/daemon_proxy.exs", __DIR__)

defmodule LoopexCli.LiveQueryTest do
  use ExUnit.Case, async: false
  @moduletag capture_log: true

  import ExUnit.CaptureIO

  alias LoopexCli.DaemonClient
  alias LoopexCli.Test.DaemonProxy
  alias LoopexDaemon.Sentinel
  alias LoopexProtocol.Wire

  @status_keys ~w(placement_identity daemon_incarnation socket_path connections connection_limit
                  attachments attachment_limit active_sessions activation_limit activations_used
                  index_entries index_limit index_full uptime_ms)

  setup do
    base = Path.join("/tmp", "llq-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(base, "w"))
    on_exit(fn -> File.rm_rf(base) end)
    %{base: base, workspace: Path.join(base, "w")}
  end

  # Concept: a listing is paged by the continuation it prints, and following
  # it shows every session exactly once.
  test "two sessions page one at a time without repetition", context do
    state_root = Path.join(context.base, "s")
    socket = Path.join([state_root, "daemon", "d.sock"])
    daemon = start_daemon(context.workspace, state_root, socket)
    created = Enum.sort(for label <- ["page-a", "page-b"], do: create(socket, label))

    {first, _stderr} = query(["sessions", "--daemon", socket, "--limit", "1"])
    %{"sessions" => [one], "next_after_session_id" => after_id} = first
    assert is_binary(after_id)

    {second, _stderr} =
      query(["sessions", "--daemon", socket, "--limit", "1", "--after", after_id])

    %{"sessions" => [other]} = second
    assert Enum.sort([one["session_id"], other["session_id"]]) == created

    stop_daemon(daemon)
  end

  # Concept: `--status` asks the daemon for its status and nothing else, and
  # prints it as one line in a fixed key order even when the socket's path
  # needs escaping; a full index is a warning on standard error, never part of
  # the record.
  #
  # Technical depth: the state root's name carries a quote, a backslash, a
  # space and a newline. A proxy records every request the command sends, and
  # in the second query presents `index_full` as true in the daemon's answer.
  test "status sends only daemon.status and prints one ordered, escaped record", context do
    state_root = Path.join(context.base, "q \"b\\ n\nx")
    socket = Path.join([state_root, "daemon", "d.sock"])
    daemon = start_daemon(context.workspace, state_root, socket)

    proxy = DaemonProxy.start(socket, [])
    {stdout, stderr} = raw(["sessions", "--daemon", proxy.path, "--status"])

    assert [line] = String.split(stdout, "\n", trim: true)
    assert String.ends_with?(stdout, "}\n")
    status = JSON.decode!(line)
    assert status["socket_path"] == socket
    assert status["index_full"] == false
    assert ordered_keys(line) == @status_keys
    assert DaemonProxy.seen(proxy) == ["initialize", "daemon.status"]
    assert stderr == ""

    full =
      DaemonProxy.start(socket, [], fn bytes ->
        String.replace(bytes, ~s("index_full":false), ~s("index_full":true))
      end)

    {stdout, stderr} = raw(["sessions", "--daemon", full.path, "--status"])
    assert JSON.decode!(stdout)["index_full"] == true

    assert stderr ==
             "loopex: the daemon's index is full, so this listing may omit sessions this root contains\n"

    refute stdout =~ "loopex:"

    stop_daemon(daemon)
  end

  # Concept: each accepted live form speaks a fixed request sequence, so a
  # change to what a command sends is a visible change, not a silent one.
  test "accepted live forms send their exact request sequences", context do
    state_root = Path.join(context.base, "s")
    socket = Path.join([state_root, "daemon", "d.sock"])
    daemon = start_daemon(context.workspace, state_root, socket)
    session_id = create(socket, "sequence-session")

    sequences =
      for argv <- [
            ["sessions", "--daemon", :proxy, "--limit", "1"],
            ["sessions", "--daemon", :proxy, "--status"],
            ["attach", session_id, "--daemon", :proxy, "--observe"],
            ["run", "--daemon", :proxy, "go"],
            ["attach", session_id, "--daemon", :proxy, "--take-over", "--prompt", "more"]
          ] do
        proxy = DaemonProxy.start(socket, [])
        argv = Enum.map(argv, &if(&1 == :proxy, do: proxy.path, else: &1))
        {_stdout, _stderr} = raw(argv)
        DaemonProxy.seen(proxy)
      end

    assert sequences == [
             ["initialize", "session.list"],
             ["initialize", "daemon.status"],
             ["initialize", "session.attach", "session.inspect"],
             [
               "initialize",
               "session.create",
               "session.acquire_control",
               "session.attach",
               "session.inspect",
               "session.prompt",
               "session.release_control"
             ],
             [
               "initialize",
               "session.acquire_control",
               "session.attach",
               "session.inspect",
               "session.prompt",
               "session.release_control"
             ]
           ]

    stop_daemon(daemon)
  end

  # Concept: a controller whose command fails after it acquired the lease
  # still releases it while its transport is writable, so another client is
  # granted control at once rather than after the term.
  #
  # Technical depth: the proxy turns the daemon's `session.inspect` answer into
  # a `session_unavailable` refusal. The take-over command then fails with the
  # restart-then-resume remedy, its request sequence ends with
  # `session.release_control`, and a direct client is granted control
  # immediately.
  test "a controller that fails after acquiring releases its lease", context do
    state_root = Path.join(context.base, "s")
    socket = Path.join([state_root, "daemon", "d.sock"])
    daemon = start_daemon(context.workspace, state_root, socket)
    session_id = create(socket, "failing-controller")

    refuse_inspect = fn bytes ->
      bytes
      |> String.split("\n")
      |> Enum.map_join("\n", fn line ->
        if line =~ ~s("method":"session.inspect") and line =~ ~s("type":"result") do
          [_whole, request_id] = Regex.run(~r/"request_id":"([^"]+)"/, line)

          ~s({"code":"session_unavailable","message":"session unavailable","request_id":"#{request_id}","type":"error"})
        else
          line
        end
      end)
    end

    proxy = DaemonProxy.start(socket, [], refuse_inspect)

    _stderr =
      capture_io(:stderr, fn ->
        result =
          LoopexCli.dispatch([
            "attach",
            session_id,
            "--daemon",
            proxy.path,
            "--take-over",
            "--prompt",
            "more"
          ])

        send(self(), {:result, result})
      end)

    assert_received {:result, {:error, message}}
    assert message =~ "unavailable in this daemon"

    assert DaemonProxy.seen(proxy) == [
             "initialize",
             "session.acquire_control",
             "session.attach",
             "session.inspect",
             "session.release_control"
           ]

    {:ok, client} = DaemonClient.connect(socket)

    assert {:ok, %{"type" => "result"}, _client} =
             DaemonClient.request(client, "session.acquire_control", %{
               "session_id" => Wire.encode_identity(session_id)
             })

    DaemonClient.close(client)
    stop_daemon(daemon)
  end

  # Concept: a killed controller sends nothing, so its lease is not released
  # and waits out its term; ADR 0033 fixes that difference.
  #
  # Technical depth: the proxy withholds the daemon's `session.inspect` answer,
  # so the take-over command holds its lease while it waits. The command's
  # process is killed there; the proxy saw no `session.release_control`, and a
  # direct client is refused `control_held` rather than granted.
  test "a killed controller releases nothing and its lease stays held", context do
    state_root = Path.join(context.base, "s")
    socket = Path.join([state_root, "daemon", "d.sock"])
    daemon = start_daemon(context.workspace, state_root, socket)
    session_id = create(socket, "killed-controller")

    withhold_inspect = fn bytes ->
      bytes
      |> String.split("\n")
      |> Enum.reject(&(&1 =~ ~s("method":"session.inspect") and &1 =~ ~s("type":"result")))
      |> Enum.join("\n")
    end

    proxy = DaemonProxy.start(socket, [], withhold_inspect)
    argv = ["attach", session_id, "--daemon", proxy.path, "--take-over", "--prompt", "more"]

    {:ok, controller} =
      Task.start(fn -> capture_io(:stderr, fn -> LoopexCli.dispatch(argv) end) end)

    assert eventually(fn -> "session.inspect" in DaemonProxy.seen(proxy) end)
    Process.exit(controller, :kill)
    Process.sleep(200)
    refute "session.release_control" in DaemonProxy.seen(proxy)

    {:ok, client} = DaemonClient.connect(socket)

    assert {:ok, %{"type" => "error", "code" => "control_held"}, _client} =
             DaemonClient.request(client, "session.acquire_control", %{
               "session_id" => Wire.encode_identity(session_id)
             })

    DaemonClient.close(client)
    stop_daemon(daemon)
  end

  defp eventually(check, attempts \\ 300)
  defp eventually(_check, 0), do: false

  defp eventually(check, attempts) do
    if check.() do
      true
    else
      Process.sleep(10)
      eventually(check, attempts - 1)
    end
  end

  defp create(socket, label) do
    {:ok, client} = DaemonClient.connect(socket)

    try do
      {:ok, %{"status" => "accepted", "session_id" => encoded}, _client} =
        DaemonClient.request(client, "session.create", %{
          "command_id" => Wire.encode_identity(label),
          "session_options" => %{"label" => label}
        })

      {:ok, session_id} = Wire.identity(encoded)
      session_id
    after
      DaemonClient.close(client)
    end
  end

  defp query(argv) do
    {stdout, stderr} = raw(argv)
    {JSON.decode!(stdout), stderr}
  end

  defp raw(argv) do
    stderr =
      capture_io(:stderr, fn ->
        stdout = capture_io(fn -> assert :ok = LoopexCli.dispatch(argv) end)
        send(self(), {:stdout, stdout})
      end)

    {receive(do: ({:stdout, stdout} -> stdout)), stderr}
  end

  defp ordered_keys(line) do
    ~r/"([a-z_]+)":/
    |> Regex.scan(line, capture: :all_but_first)
    |> List.flatten()
  end

  defp start_daemon(workspace, state_root, socket) do
    {:ok, output} = StringIO.open("")
    test = self()

    options = [
      state_root: state_root,
      socket_path: socket,
      workspace: workspace,
      policy: LoopexCli.Policy.AllowAll,
      provider_launch: [],
      credential: "live-query-placeholder"
    ]

    task =
      Task.async(fn ->
        Sentinel.run(options, output: output, install_signals: false, notify: test)
      end)

    assert_receive {:loopex_daemon_sentinel, sentinel, owner_ref, _owner}, 5_000
    await_ready(output, 1_000)
    %{task: task, sentinel: sentinel, owner_ref: owner_ref}
  end

  defp stop_daemon(daemon) do
    send(daemon.sentinel, {:daemon_signal, daemon.owner_ref, :sigterm})
    assert Task.await(daemon.task, 30_000) == 0
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
