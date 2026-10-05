Code.require_file("../../loopex/test/support/m1_runtime_helper.exs", __DIR__)
Code.require_file("../../loopex/test/support/agent_loop_helper.exs", __DIR__)

defmodule LoopexCli.ChatOSSignalTest do
  use ExUnit.Case, async: false
  @moduletag timeout: 120_000
  @launcher Path.expand("../bin/loopex", __DIR__)

  setup_all do
    root = Path.join(System.tmp_dir!(), "chat-os-signal-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    fixture_beams = Path.join(root, "beams")
    File.mkdir!(fixture_beams)

    for {module, bytes} <-
          Code.compile_file(Path.join(__DIR__, "support/chat_os_signal_driver.txt")) do
      File.write!(Path.join(fixture_beams, Atom.to_string(module) <> ".beam"), bytes)
    end

    paths =
      [fixture_beams | Enum.map(:code.get_path(), &List.to_string/1)]
      |> Enum.map_join(" ", &("-pa " <> shell_quote(&1)))

    stand_in = Path.join(root, "stand-in")
    elixir = System.find_executable("elixir") || flunk("elixir executable unavailable")
    store_fixture = Path.expand("../../loopex/test/support/m1_runtime_helper.exs", __DIR__)
    loop_fixture = Path.expand("../../loopex/test/support/agent_loop_helper.exs", __DIR__)

    File.write!(stand_in, """
    #!/bin/sh
    exec #{shell_quote(elixir)} #{paths} -r #{shell_quote(store_fixture)} -r #{shell_quote(loop_fixture)} -e 'LoopexCli.ChatOSSignalDriver.main()' -- "$@"
    """)

    File.chmod!(stand_in, 0o755)
    %{root: root, stand_in: stand_in}
  end

  test "actual TERM HUP QUIT and launcher INT reach the chat driver while stdin is blocked",
       fixture do
    for {signal, target} <- [
          {"TERM", :child},
          {"HUP", :child},
          {"QUIT", :child},
          {"INT", :launcher}
        ] do
      state = start_case(fixture, "input")
      assert receive_control(state.socket) == :input_blocked
      signal(state, signal, target)
      assert receive_control(state.socket) == :stopping

      assert(
        {:result, %{exit_code: 1, cleanup: :confirmed}, 1, {:ok, :interrupted}, transcript, true,
         true} = receive_control(state.socket)
      )

      assert transcript =~ "\"cleanup\":\"confirmed\""
      assert {1, ""} == await_exit(state.port, "", System.monotonic_time(:millisecond) + 10_000)
    end
  end

  test "two actual signals return unknown admission and a closing record through the same driver",
       fixture do
    state = start_case(fixture, "double")
    assert receive_control(state.socket) == :admission_blocked
    signal(state, "TERM", :child)
    assert receive_control(state.socket) == :stopping
    signal(state, "TERM", :child)

    assert {:result, %{exit_code: 1, cleanup: :unknown}, 1, {:ok, :interrupted}, transcript, true,
            true} =
             receive_control(state.socket)

    assert transcript =~ "\"outcome\":\"commit_unknown\""
    assert transcript =~ "\"cleanup\":\"unknown\""
    assert {1, ""} == await_exit(state.port, "", System.monotonic_time(:millisecond) + 10_000)
  end

  defp start_case(fixture, scenario) do
    home = Path.join(fixture.root, "home-#{System.unique_integer([:positive])}")
    File.mkdir!(home)

    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, packet: 4, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, {_, control_port}} = :inet.sockname(listener)

    port =
      Port.open({:spawn_executable, @launcher}, [
        :binary,
        :exit_status,
        :hide,
        :use_stdio,
        args: ["chat"],
        env: [
          {~c"LOOPEX_ESCRIPT", String.to_charlist(fixture.stand_in)},
          {~c"LOOPEX_HOME", String.to_charlist(home)},
          {~c"LOOPEX_CHAT_SIGNAL_PORT", Integer.to_charlist(control_port)},
          {~c"LOOPEX_CHAT_SIGNAL_SCENARIO", String.to_charlist(scenario)},
          {~c"ERL_CRASH_DUMP", ~c"/dev/null"},
          {~c"ERL_CRASH_DUMP_SECONDS", ~c"0"}
        ]
      ])

    on_exit(fn ->
      case Port.info(port, :os_pid) do
        {:os_pid, pid} ->
          System.cmd("/bin/kill", ["-TERM", Integer.to_string(pid)], stderr_to_stdout: true)

        _ ->
          :ok
      end

      if Port.info(port), do: Port.close(port)
      :gen_tcp.close(listener)
    end)

    assert {:os_pid, launcher_pid} = Port.info(port, :os_pid)
    assert {:ok, socket} = :gen_tcp.accept(listener, 15_000)
    on_exit(fn -> :gen_tcp.close(socket) end)
    assert {:pid, child_pid} = receive_control(socket)
    assert Regex.match?(~r/^\d+$/, child_pid)
    assert receive_control(socket) == :ready
    %{port: port, socket: socket, child_pid: child_pid, launcher_pid: launcher_pid}
  end

  defp signal(state, name, target) do
    pid = if target == :child, do: state.child_pid, else: Integer.to_string(state.launcher_pid)
    assert {_, 0} = System.cmd("/bin/kill", ["-#{name}", pid], stderr_to_stdout: true)
  end

  defp receive_control(socket) do
    assert {:ok, bytes} = :gen_tcp.recv(socket, 0, 15_000)
    :erlang.binary_to_term(bytes, [:safe])
  end

  defp await_exit(port, output, cutoff) do
    receive do
      {^port, {:data, bytes}} -> await_exit(port, output <> bytes, cutoff)
      {^port, {:exit_status, code}} -> {code, output}
    after
      max(0, cutoff - System.monotonic_time(:millisecond)) -> flunk("chat child did not exit")
    end
  end

  defp shell_quote(text), do: "'" <> String.replace(text, "'", "'\\''") <> "'"
end
