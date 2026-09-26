defmodule LoopexCli.MultiClientWorkflowRealTest do
  use ExUnit.Case, async: false
  @moduletag capture_log: true

  # Concept: the operator's two-process workflow against a real provider, with
  # every participant its own operating-system process: `loopex daemon` holding
  # the credential, `loopex run --daemon` as controller, the Node client as
  # observer. The controller is killed, the observer waits out its lease, takes
  # control and has its own prompt answered by the real model.
  #
  # Technical depth: the credential comes only from the release check's
  # `LOOPEX_PROVIDER_API_KEY`, is handed to the daemon process alone and is
  # never printed; its absence is evidence unavailable, never a pass. The
  # companion is built into this case's own physical build root. `SIGKILL`
  # sends no release, so the observer's first acquisitions are refused until
  # the thirty-second term lapses. It then waits for the killed controller's
  # run to finish, prompts under its fresh epoch, and must see an assistant
  # message and `run.finished` after its admission. The daemon then stops
  # orderly with status `0`.
  # A controller prompt whose answer takes the model several seconds to write,
  # so the controller is still streaming when it is killed.
  @long_prompt "Write every integer from 1 to 400 in order, separated by single spaces, " <>
                 "and nothing else."

  @tag :real_provider
  @tag timeout: 900_000
  test "a Node observer takes over from a killed CLI controller and a real provider answers it" do
    # Consumed as a host consumes it: read and deleted in one step, so this
    # VM's environment names it no longer and only the daemon child is handed
    # it; the release check runs each real-provider case in a VM of its own.
    credential = System.get_env("LOOPEX_PROVIDER_API_KEY")
    System.delete_env("LOOPEX_PROVIDER_API_KEY")
    if credential in [nil, ""], do: flunk("provider credential unavailable: evidence unavailable")
    node = System.find_executable("node") || flunk("Node is unavailable on this host")

    root = physical_root("lmr-#{System.unique_integer([:positive])}")
    state_root = Path.join(root, "s")
    workspace = Path.join(root, "w")
    File.mkdir_p!(state_root)
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(root) end)

    launch = build_companion(Path.join(root, "build"))
    socket = Path.join([state_root, "daemon", "d.sock"])

    {daemon, daemon_pid} =
      start(
        [
          "daemon",
          "--state-root",
          state_root,
          "--workspace",
          workspace,
          "--provider-launch",
          launch,
          "--policy",
          "allow-all",
          "--socket",
          socket
        ],
        [:use_stdio],
        credential
      )

    assert %{"record" => "daemon_ready"} = daemon |> await_line(120_000) |> JSON.decode!()

    {controller, controller_pid} =
      start(
        ["run", "--daemon", socket, @long_prompt],
        [:stderr_to_stdout],
        nil
      )

    session_id = await_session(controller, 60_000)
    script = Path.expand("../../../clients/node/daemon-takeover.mjs", __DIR__)

    observer =
      Port.open({:spawn_executable, node}, [
        :binary,
        :exit_status,
        {:line, 65_536},
        env: [{~c"LOOPEX_PROVIDER_API_KEY", false}],
        args: [script, socket, session_id, "--prompt", "Reply with the single word: ping"]
      ])

    assert_receive {^observer, {:data, {:eol, ~s({"attached":true})}}}, 30_000

    # The controller must still be running when it is killed: a controller
    # that had already finished would have released its lease.
    refute_received {^controller, {:exit_status, _status}}
    {_output, 0} = System.cmd("/bin/kill", ["-KILL", Integer.to_string(controller_pid)])
    assert await_exit(controller, 10_000) != 0

    {status, lines} = collect(observer, [], 300_000)
    assert status == 0, lines
    summary = lines |> String.split("\n", trim: true) |> List.last()

    assert %{
             "granted" => true,
             "prompt" => "accepted",
             "answered" => true,
             "finished" => true,
             "attempts" => attempts
           } = JSON.decode!(summary)

    # The killed controller released nothing, so taking over had to wait.
    assert attempts > 1
    IO.puts("real-provider takeover: #{summary}")

    {_output, 0} = System.cmd("/bin/kill", ["-TERM", Integer.to_string(daemon_pid)])
    assert await_exit(daemon, 120_000) == 0
  end

  # The documented companion build, into this case's own build root, without
  # the credential in its environment.
  defp build_companion(build) do
    adapter = Path.expand("../../loopex_llm_reqllm", __DIR__)
    mix = System.find_executable("mix") || flunk("Mix executable unavailable")

    {log, status} =
      System.cmd(mix, ["loopex.provider.build"],
        cd: adapter,
        env: [
          {"MIX_ENV", "test"},
          {"HEX_OFFLINE", "1"},
          {"MIX_BUILD_PATH", build},
          {"LOOPEX_PROVIDER_API_KEY", nil},
          {"ANTHROPIC_API_KEY", nil}
        ],
        stderr_to_stdout: true
      )

    assert status == 0, log
    Path.join(build, "loopex_provider.launch")
  end

  # Mix links `priv` by resolved paths, so a root reached through a symbolic
  # link (`/var` or `/tmp` on macOS) must be named by its physical path.
  defp physical_root(name) do
    base = System.tmp_dir!()
    {path, 0} = System.cmd("sh", ["-c", "cd \"$1\" && pwd -P", "sh", base])
    Path.join(String.trim(path), name)
  end

  # Only the daemon receives the credential; the controller runs with the
  # variable removed, and so does the Node observer, started separately.
  defp start(argv, extra, credential) do
    executable = System.find_executable("elixir") || raise "elixir executable unavailable"

    environment =
      if credential,
        do: [{~c"LOOPEX_PROVIDER_API_KEY", String.to_charlist(credential)}],
        else: [{~c"LOOPEX_PROVIDER_API_KEY", false}]

    port =
      Port.open(
        {:spawn_executable, String.to_charlist(executable)},
        [:binary, :exit_status, :hide, {:line, 65_536}, env: environment] ++
          extra ++
          [
            args:
              Enum.flat_map(:code.get_path(), fn dir -> ["-pa", List.to_string(dir)] end) ++
                ["-e", "LoopexCli.main(#{inspect(argv)})"]
          ]
      )

    {:os_pid, os_pid} = Port.info(port, :os_pid)

    on_exit(fn ->
      System.cmd("/bin/kill", ["-KILL", Integer.to_string(os_pid)], stderr_to_stdout: true)
    end)

    {port, os_pid}
  end

  defp await_session(port, bound) do
    receive do
      {^port, {:data, {:eol, line}}} ->
        case Regex.run(~r/loopex: session (\S+)/, line) do
          [_, session_id] -> session_id
          nil -> await_session(port, bound)
        end

      {^port, {:exit_status, status}} ->
        flunk("the controller exited #{status} before naming its session")
    after
      bound -> flunk("the controller never named its session")
    end
  end

  defp collect(port, lines, bound) do
    receive do
      {^port, {:data, {_flag, line}}} -> collect(port, [line | lines], bound)
      {^port, {:exit_status, status}} -> {status, lines |> Enum.reverse() |> Enum.join("\n")}
    after
      bound -> flunk("a process did not exit: #{Enum.join(Enum.reverse(lines), "\n")}")
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
      {^port, {:data, _line}} -> await_exit(port, bound)
    after
      bound -> flunk("a process never exited")
    end
  end
end
