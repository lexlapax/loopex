defmodule LoopexCli.ChatCompositionStartupTest do
  use ExUnit.Case, async: false

  @driver Path.join(__DIR__, "support/chat_composition_startup_driver.txt")
  @proof "@m7_chat_startup "
  @output_limit 65_536
  @command_ms 60_000
  @failure_ms 5_000

  test "fresh chat waits for actual Local creation startup before creating or consuming input" do
    root =
      Path.join(
        System.tmp_dir!(),
        "chat-composition-startup-#{System.unique_integer([:positive])}"
      )

    File.mkdir!(root)
    cleanup = make_ref()
    on_exit(cleanup, fn -> File.rm_rf!(root) end)
    beams = Path.join(root, "beams")
    File.mkdir!(beams)

    {compiled, diagnostics} = Code.with_diagnostics(fn -> Code.compile_file(@driver) end)
    assert diagnostics == [], "standalone fixture emitted diagnostics: #{inspect(diagnostics)}"
    assert length(compiled) == 2

    for {module, bytes} <- compiled do
      File.write!(Path.join(beams, Atom.to_string(module) <> ".beam"), bytes)
    end

    elixir = System.find_executable("elixir") || flunk("elixir executable unavailable")
    paths = [beams | Enum.map(:code.get_path(), &List.to_string/1)]
    token = Base.encode16(:crypto.strong_rand_bytes(16))

    args =
      ["--erl", "+B -kernel standard_io_encoding latin1"] ++
        Enum.flat_map(paths, &["-pa", &1]) ++
        ["-e", "LoopexCli.ChatCompositionStartupDriver.main()", "--", root, token]

    home = Path.join(root, "home")

    environment = [
      {~c"LOOPEX_HOME", String.to_charlist(home)},
      {~c"LOOPEX_WORKSPACE", String.to_charlist(Path.join(root, "workspace"))},
      {~c"LOOPEX_PROVIDER_API_KEY", false},
      {~c"ANTHROPIC_API_KEY", false},
      {~c"OPENAI_API_KEY", false},
      {~c"OPENROUTER_API_KEY", false},
      {~c"OPEN_ROUTER_API_KEY", false},
      {~c"ERL_CRASH_DUMP", ~c"/dev/null"},
      {~c"ERL_CRASH_DUMP_SECONDS", ~c"0"}
    ]

    test = self()
    cutoff = System.monotonic_time(:millisecond) + @command_ms
    {owner, owner_down} = spawn_monitor(fn -> await_launch(test) end)

    # Concept: command custody survives the test's exit into its callback.
    # Technical depth: on_exit runs in another process after the test dies.
    # The unlinked owner retains the original port monitor until this callback
    # obtains its exact join and retires that same owner before root removal.
    on_exit(cleanup, fn ->
      retire_command(owner)
      File.rm_rf!(root)
    end)

    send(owner, {:launch, test, elixir, args, environment, root, cutoff})

    receive do
      {:command_opened, ^owner, port, port_down, os_pid} ->
        remaining(cutoff)
        assert is_port(port) and is_reference(port_down) and is_integer(os_pid)
        completed = await_command(owner, owner_down, cutoff)
        remaining(cutoff)
        assert completed.joined_at < cutoff
        assert completed.port == port and completed.monitor == port_down
        assert completed.os_pid == os_pid
        assert completed.down == {:DOWN, port_down, :port, port, :normal}

        assert completed.status == 0,
               "standalone witness exited #{completed.status}: #{completed.output}"

        assert Port.info(port) == nil
        lines = String.split(completed.output, "\n", trim: true)
        assert [@proof <> encoded] = lines
        evidence = JSON.decode!(encoded)
        assert evidence["proof_token"] == token
        assert evidence["state_root"] == home
        assert evidence["create_calls"] == 1 and evidence["genesis"] == 1
        assert evidence["model_calls"] == 0 and evidence["actors_joined"] > 0
        assert byte_size(Base.decode16!(evidence["startup_id"])) == 32
        assert is_integer(evidence["startup_deadline_ms"])
        assert {:ok, [%{session_id: session}]} = Loopex.list_sessions(home)
        assert LoopexProtocol.Wire.encode_identity(session) == evidence["session_id"]

      {:DOWN, ^owner_down, :process, ^owner, reason} ->
        flunk("command custody failed before launch: #{inspect(reason)}")
    after
      remaining(cutoff) -> flunk("standalone command did not open within its original cutoff")
    end
  end

  defp await_command(owner, monitor, cutoff) do
    receive do
      {:command_complete, ^owner, completed} ->
        remaining(cutoff)
        completed

      {:command_failed, ^owner, reason, output} ->
        flunk("standalone command #{inspect(reason)}: #{output}")

      {:DOWN, ^monitor, :process, ^owner, reason} ->
        flunk("command custody exited before original port join: #{inspect(reason)}")
    after
      remaining(cutoff) -> flunk("standalone command did not finish within its original cutoff")
    end
  end

  # Concept: the original child can launch only after safe cleanup registration.
  # Technical depth: this unlinked actor starts idle. The test sends its one
  # launch grant after installing on_exit; original test death retires an idle
  # actor without opening a command or leaving an unbounded custodian behind.
  defp await_launch(test) do
    Process.flag(:trap_exit, true)
    test_down = Process.monitor(test)

    receive do
      {:launch, ^test, executable, args, environment, root, cutoff} ->
        if Process.alive?(test) and System.monotonic_time(:millisecond) < cutoff do
          own_command(test, test_down, executable, args, environment, root, cutoff)
        else
          retire_idle(System.monotonic_time(:millisecond) + @failure_ms)
        end

      {:DOWN, ^test_down, :process, ^test, _} ->
        retire_idle(System.monotonic_time(:millisecond) + @failure_ms)

      {:retire, caller, reference, cutoff} ->
        acknowledge_idle(caller, reference, cutoff)
    end
  end

  defp retire_idle(cutoff) do
    receive do
      {:retire, caller, reference, requested} ->
        acknowledge_idle(caller, reference, min(cutoff, requested))
    after
      wait_delay(cutoff) -> :ok
    end
  end

  defp acknowledge_idle(caller, reference, cutoff) do
    if System.monotonic_time(:millisecond) >= cutoff,
      do: exit(:idle_retirement_observation_expired)

    send(caller, {:command_retired, reference, :not_launched, nil})
  end

  defp own_command(test, test_down, executable, args, environment, root, cutoff) do
    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        :use_stdio,
        :stderr_to_stdout,
        args: args,
        env: environment,
        cd: root
      ])

    {:os_pid, os_pid} = Port.info(port, :os_pid)
    monitor = :erlang.monitor(:port, port)
    send(test, {:command_opened, self(), port, monitor, os_pid})

    command_loop(%{
      test: test,
      test_down: test_down,
      port: port,
      monitor: monitor,
      os_pid: os_pid,
      cutoff: cutoff,
      status: nil,
      down: nil,
      output: "",
      cancel_cutoff: nil,
      joined_at: nil
    })
  end

  defp command_loop(state) do
    if System.monotonic_time(:millisecond) >= state.cutoff do
      send(state.test, {:command_failed, self(), :command_cutoff, state.output})
      retain_command(cancel_original(state))
    else
      state = record_join(state, state.cutoff)

      if state.joined_at do
        if System.monotonic_time(:millisecond) >= state.cutoff do
          send(state.test, {:command_failed, self(), :command_cutoff, state.output})
        else
          send(
            state.test,
            {:command_complete, self(),
             Map.take(state, [:port, :monitor, :os_pid, :status, :down, :output, :joined_at])}
          )
        end

        retain_command(state)
      else
        receive_command(state)
      end
    end
  end

  defp receive_command(state) do
    receive do
      {port, {:data, bytes}} when port == state.port ->
        if byte_size(state.output) + byte_size(bytes) <= @output_limit do
          command_loop(%{state | output: state.output <> bytes})
        else
          send(state.test, {:command_failed, self(), :output_limit, state.output})
          retain_command(cancel_original(state))
        end

      {port, {:exit_status, status}} when port == state.port ->
        command_loop(%{state | status: status})

      {:DOWN, monitor, :port, port, _} = down
      when monitor == state.monitor and port == state.port ->
        command_loop(%{state | down: down})

      {:EXIT, port, _} when port == state.port ->
        command_loop(state)

      {:DOWN, monitor, :process, test, _}
      when monitor == state.test_down and test == state.test ->
        retain_command(cancel_original(state))

      {:retire, caller, reference, cutoff} ->
        dispose_command(state, caller, reference, cutoff)
    after
      wait_delay(state.cutoff) ->
        send(state.test, {:command_failed, self(), :command_cutoff, state.output})
        retain_command(cancel_original(state))
    end
  end

  # Concept: timely original evidence remains available after its command ends.
  # Technical depth: both exit_status and exact original DOWN must be observed
  # before the active cutoff. The retained joined_at distinguishes proved
  # earlier observation from queued evidence consumed after observer delay.
  defp record_join(%{down: down, status: status, joined_at: nil} = state, cutoff)
       when not is_nil(down) and not is_nil(status) do
    observed = System.monotonic_time(:millisecond)
    if observed >= cutoff, do: exit({:original_command_join_unproved, state.os_pid})
    %{state | joined_at: observed}
  end

  defp record_join(state, _cutoff), do: state

  # Concept: a retained result remains available to the different on_exit actor.
  # Technical depth: no original monitor is moved or recaptured. The custodian
  # remains alive until it acknowledges retirement after its exact port join.
  defp retain_command(state) do
    receive do
      {:retire, caller, reference, cutoff} -> dispose_command(state, caller, reference, cutoff)
      {:EXIT, port, _} when port == state.port -> retain_command(state)
    end
  end

  defp dispose_command(state, caller, reference, cutoff) do
    joined = cancel_original(state, cutoff)

    if System.monotonic_time(:millisecond) >= cutoff,
      do: exit(:retirement_observation_expired)

    send(caller, {:command_retired, reference, joined.down, joined.status})
  end

  defp cancel_original(state, cutoff \\ nil)

  defp cancel_original(%{joined_at: observed} = state, _cutoff)
       when not is_nil(observed) do
    state
  end

  defp cancel_original(state, requested_cutoff) do
    cutoff = state.cancel_cutoff || System.monotonic_time(:millisecond) + @failure_ms
    cutoff = if requested_cutoff, do: min(cutoff, requested_cutoff), else: cutoff
    state = %{state | cancel_cutoff: cutoff}

    case Port.info(state.port, :os_pid) do
      {:os_pid, pid} when pid == state.os_pid ->
        {_output, _status} =
          System.cmd("/bin/kill", ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true)

      nil ->
        :ok
    end

    join_original(state, cutoff)
  end

  defp join_original(%{down: down, status: status} = state, cutoff)
       when not is_nil(down) and not is_nil(status) do
    record_join(state, cutoff)
  end

  defp join_original(state, cutoff) do
    if System.monotonic_time(:millisecond) >= cutoff,
      do: exit({:original_command_join_unproved, state.os_pid})

    receive do
      {:DOWN, monitor, :port, port, _} = down
      when monitor == state.monitor and port == state.port ->
        join_original(%{state | down: down}, cutoff)

      {port, {:exit_status, status}} when port == state.port ->
        join_original(%{state | status: status}, cutoff)

      {port, {:data, bytes}} when port == state.port ->
        left = max(0, @output_limit - byte_size(state.output))
        bounded = binary_part(bytes, 0, min(left, byte_size(bytes)))
        join_original(%{state | output: state.output <> bounded}, cutoff)

      {:EXIT, port, _} when port == state.port ->
        join_original(state, cutoff)
    after
      wait_delay(cutoff) -> exit({:original_command_join_unproved, state.os_pid})
    end
  end

  defp retire_command(owner) do
    monitor = Process.monitor(owner)
    reference = make_ref()
    cutoff = System.monotonic_time(:millisecond) + @failure_ms
    send(owner, {:retire, self(), reference, cutoff})

    receive do
      {:command_retired, ^reference, {:DOWN, original, :port, port, _}, status} ->
        remaining(cutoff)
        assert is_reference(original) and is_port(port) and is_integer(status)
        assert_receive {:DOWN, ^monitor, :process, ^owner, :normal}, remaining(cutoff)
        remaining(cutoff)

      {:command_retired, ^reference, :not_launched, nil} ->
        remaining(cutoff)
        assert_receive {:DOWN, ^monitor, :process, ^owner, :normal}, remaining(cutoff)
        remaining(cutoff)

      {:DOWN, ^monitor, :process, ^owner, reason} ->
        flunk("original command cleanup evidence unavailable: #{inspect(reason)}")
    after
      remaining(cutoff) -> flunk("original command cleanup did not acknowledge its join")
    end
  end

  defp remaining(cutoff) do
    remaining = cutoff - System.monotonic_time(:millisecond)
    assert remaining > 0, "original fixture observation cutoff exhausted"
    remaining
  end

  defp wait_delay(cutoff), do: max(0, cutoff - System.monotonic_time(:millisecond))
end
