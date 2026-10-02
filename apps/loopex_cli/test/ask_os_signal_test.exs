defmodule LoopexCli.AskOSSignalTest do
  @moduledoc """
  ## Concept

  An operating-system signal reaches ask mode in its own VM after installation
  and before the command chooses its final output.

  ## Technical depth

  A test-only control socket gates startup or mandatory stop. The child uses
  the real signal manager and, for orderly cases, a real ephemeral session.
  The launcher receives INT; the exact child receives TERM, HUP and QUIT.
  """

  use ExUnit.Case, async: false

  @moduletag timeout: 120_000
  @launcher Path.expand("../bin/loopex", __DIR__)

  setup_all do
    root =
      Path.join(System.tmp_dir!(), "loopex-ask-os-signal-#{System.unique_integer([:positive])}")

    File.mkdir!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    driver = Path.join(root, "driver")
    File.mkdir!(driver)

    for {module, binary} <-
          Code.compile_file(Path.join(__DIR__, "support/ask_os_signal_driver.txt")) do
      File.write!(Path.join(driver, Atom.to_string(module) <> ".beam"), binary)
    end

    elixir = System.find_executable("elixir") || flunk("elixir executable unavailable")

    paths =
      [driver | Enum.map(:code.get_path(), &List.to_string/1)]
      |> Enum.map_join(" ", fn path -> "-pa " <> shell_quote(path) end)

    stand_in = Path.join(root, "stand-in")

    File.write!(stand_in, """
    #!/bin/sh
    exec #{shell_quote(elixir)} #{paths} -e 'LoopexCli.AskOSSignalDriver.main()' -- "$@" 2>"$LOOPEX_SIGNAL_STDERR"
    """)

    File.chmod!(stand_in, 0o755)
    {:ok, %{root: root, stand_in: stand_in}}
  end

  test "all four OS signals stop startup after the handler is installed", fixture do
    for {signal, target} <- [
          {"TERM", :child},
          {"HUP", :child},
          {"QUIT", :child},
          {"INT", :launcher}
        ] do
      state = start_case(fixture, "startup")
      assert_control(state.socket, :startup_enter)
      signal(state, signal, target)
      assert_control(state.socket, {:phase, :stopping})
      release(state.socket)
      assert_control(state.socket, :stop_enter)
      assert_control(state.socket, {:stop_returned, :ok})
      assert_restored_handlers(state.socket)
      assert {:result, %{status: 130, stdout: ""}} = receive_control(state.socket)
      assert {130, output} = await_exit(state.port, 10_000)
      refute output =~ "signal answer"
    end
  end

  test "a real signal during mandatory stop wins after a provisional answer", fixture do
    state = start_case(fixture, "stop")
    assert_control(state.socket, :ask_enter)
    assert_control(state.socket, :stop_enter)
    signal(state, "TERM", :child)
    assert_control(state.socket, {:phase, :stopping})
    release(state.socket)
    assert_control(state.socket, {:stop_returned, :ok})
    assert_restored_handlers(state.socket)

    assert {:result, %{status: 130, stdout: "", stderr: "ending completed\n"}} =
             receive_control(state.socket)

    assert {130, output} = await_exit(state.port, 10_000)
    refute output =~ "signal answer"
  end

  test "a signal before the worker enters the API stops without a prompt", fixture do
    state = start_case(fixture, "pre_worker")
    assert_control(state.socket, :worker_enter)
    signal(state, "TERM", :child)

    assert MapSet.new([receive_control(state.socket), receive_control(state.socket)]) ==
             MapSet.new([{:phase, :stopping}, :stop_enter])

    release(state.socket)
    assert_control(state.socket, {:stop_returned, :ok})
    assert_restored_handlers(state.socket)
    assert {:result, %{status: 130, stdout: "", stderr: ""}} = receive_control(state.socket)
    assert {130, output} = await_exit(state.port, 10_000)
    refute output =~ "signal answer"
  end

  test "an OS signal joins the startup-enabled trace and diagnostic actors", fixture do
    state = start_case(fixture, "stop", true)
    assert_control(state.socket, :ask_enter)
    assert_control(state.socket, :stop_enter)
    signal(state, "TERM", :child)
    assert_control(state.socket, {:phase, :stopping})
    release(state.socket)
    assert_control(state.socket, {:stop_returned, :ok})
    assert_control(state.socket, {:trace_joined, true})
    assert_restored_handlers(state.socket)
    assert {:result, %{status: 130, stdout: ""}} = receive_control(state.socket)
    assert {130, output} = await_exit(state.port, 10_000)
    refute output =~ "signal answer"
  end

  test "a real signal after owner registration but before grant starts no prompt", fixture do
    state = start_case(fixture, "pregrant")
    assert_control(state.socket, :ask_enter)
    assert_control(state.socket, :pregrant_reserved)
    signal(state, "TERM", :child)

    assert MapSet.new(for _ <- 1..3, do: receive_control(state.socket)) ==
             MapSet.new([{:phase, :stopping}, :stop_enter, :pregrant_cancelling])

    assert_control(state.socket, {:stop_returned, :ok})
    assert_restored_handlers(state.socket)
    assert {:result, %{status: 130, stdout: "", stderr: ""}} = receive_control(state.socket)
    assert {130, output} = await_exit(state.port, 10_000)
    assert output == ""
    assert File.read!(state.stderr_path) == ""
  end

  test "a real signal after dispatch grant stops the possibly admitted prompt", fixture do
    state = start_case(fixture, "postgrant")
    assert_control(state.socket, :ask_enter)
    assert_control(state.socket, :postgrant_pregrant_seen)
    assert_control(state.socket, :postgrant_owner_suspended)
    assert_control(state.socket, :postgrant_actor_resumed)
    assert_control(state.socket, :postgrant_ready_trace)
    assert_control(state.socket, :postgrant_actor_await_grant)
    assert_control(state.socket, :postgrant_granted)
    signal(state, "TERM", :child)

    assert MapSet.new(for _ <- 1..3, do: receive_control(state.socket)) ==
             MapSet.new([{:phase, :stopping}, :stop_enter, :postgrant_stopping])

    assert_control(state.socket, {:stop_returned, :ok})
    assert_restored_handlers(state.socket)

    assert {:result, %{status: 130, stdout: "", stderr: "ending cancelled\n"}} =
             receive_control(state.socket)

    assert {130, output} = await_exit(state.port, 10_000)
    assert output == ""
    assert File.read!(state.stderr_path) == "ending cancelled\n"
  end

  test "a second signal hard-halts a stop that has not returned", fixture do
    state = start_case(fixture, "double")
    assert_control(state.socket, :ask_enter)
    assert_control(state.socket, :stop_enter)
    signal(state, "TERM", :child)
    assert_control(state.socket, {:phase, :stopping})
    signal(state, "HUP", :child)
    assert {130, output} = await_exit(state.port, 10_000)
    assert output == ""
    assert File.read!(state.stderr_path) =~ "stopping did not finish in time"
    assert {:error, :closed} = :gen_tcp.recv(state.socket, 0, 1_000)
  end

  test "the first signal's 10-second backstop hard-halts a stalled stop", fixture do
    state = start_case(fixture, "backstop")
    assert_control(state.socket, :ask_enter)
    assert_control(state.socket, :stop_enter)
    started = System.monotonic_time(:millisecond)
    signal(state, "TERM", :child)
    assert_control(state.socket, {:phase, :stopping})
    assert {130, output} = await_exit(state.port, 15_000)
    elapsed = System.monotonic_time(:millisecond) - started
    assert elapsed >= 9_500
    assert elapsed < 14_000
    assert output == ""
    assert File.read!(state.stderr_path) =~ "stopping did not finish in time"
    assert {:error, :closed} = :gen_tcp.recv(state.socket, 0, 1_000)
  end

  defp start_case(fixture, scenario, trace? \\ false) do
    workspace = Path.join(fixture.root, "workspace-#{System.unique_integer([:positive])}")
    File.mkdir!(workspace)
    stderr_path = Path.join(workspace, "stderr")

    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, packet: 4, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, {_, control_port}} = :inet.sockname(listener)

    port =
      Port.open({:spawn_executable, @launcher}, [
        :binary,
        :exit_status,
        :hide,
        :use_stdio,
        args: ["ask"],
        env: [
          {~c"LOOPEX_ESCRIPT", String.to_charlist(fixture.stand_in)},
          {~c"LOOPEX_SIGNAL_SCENARIO", String.to_charlist(scenario)},
          {~c"LOOPEX_SIGNAL_TRACE", if(trace?, do: ~c"1", else: ~c"0")},
          {~c"LOOPEX_SIGNAL_PORT", Integer.to_charlist(control_port)},
          {~c"LOOPEX_SIGNAL_WORKSPACE", String.to_charlist(workspace)},
          {~c"LOOPEX_SIGNAL_STDERR", String.to_charlist(stderr_path)},
          {~c"OPENAI_API_KEY", ~c""},
          {~c"ANTHROPIC_API_KEY", ~c""},
          {~c"OPENROUTER_API_KEY", ~c""},
          {~c"LOOPEX_PROVIDER_API_KEY", ~c""}
        ]
      ])

    on_exit(fn ->
      case Port.info(port, :os_pid) do
        {:os_pid, pid} ->
          _ = System.cmd("/bin/kill", ["-TERM", Integer.to_string(pid)], stderr_to_stdout: true)

        _ ->
          :ok
      end

      if Port.info(port), do: Port.close(port)
      :gen_tcp.close(listener)
    end)

    assert {:os_pid, launcher_pid} = Port.info(port, :os_pid)
    assert {:ok, socket} = :gen_tcp.accept(listener, 10_000)
    on_exit(fn -> :gen_tcp.close(socket) end)
    assert {:pid, child_pid} = receive_control(socket)
    assert Regex.match?(~r/^\d+$/, child_pid)
    assert_control(socket, {:manager_before, true})
    assert {:handlers_before, handlers} = receive_control(socket)

    assert Enum.sort(handlers) in [
             [:erl_signal_handler],
             [:erl_signal_handler, :prim_tty_sighandler]
           ]

    assert_control(socket, {:install, :ok})

    %{
      port: port,
      socket: socket,
      launcher_pid: launcher_pid,
      child_pid: child_pid,
      stderr_path: stderr_path
    }
  end

  defp signal(state, name, target) do
    pid = if target == :child, do: state.child_pid, else: Integer.to_string(state.launcher_pid)
    assert {_, 0} = System.cmd("/bin/kill", ["-#{name}", pid], stderr_to_stdout: true)
  end

  defp release(socket), do: :gen_tcp.send(socket, :erlang.term_to_binary(:release))

  defp assert_control(socket, expected), do: assert(receive_control(socket) == expected)

  defp assert_restored_handlers(socket) do
    assert {:handlers_after, handlers} = receive_control(socket)

    assert Enum.sort(handlers) in [
             [:erl_signal_handler],
             [:erl_signal_handler, :prim_tty_sighandler]
           ]
  end

  defp receive_control(socket) do
    assert {:ok, bytes} = :gen_tcp.recv(socket, 0, 15_000)
    :erlang.binary_to_term(bytes, [:safe])
  end

  defp await_exit(port, timeout) do
    await_exit(port, "", System.monotonic_time(:millisecond) + timeout)
  end

  defp await_exit(port, output, deadline) do
    remaining = max(0, deadline - System.monotonic_time(:millisecond))

    receive do
      {^port, {:data, bytes}} -> await_exit(port, output <> bytes, deadline)
      {^port, {:exit_status, status}} -> {status, output}
    after
      remaining -> flunk("ask child did not exit after OS signal")
    end
  end

  defp shell_quote(text), do: "'" <> String.replace(text, "'", "'\\''") <> "'"
end
