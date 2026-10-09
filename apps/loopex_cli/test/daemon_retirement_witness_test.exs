defmodule LoopexCli.DaemonRetirementWitnessTest do
  @moduledoc false
  use ExUnit.Case, async: false
  @moduletag capture_log: true

  alias LoopexProtocol.{Frame, Session.V2}

  @modules [
    LoopexCli.Daemon,
    LoopexDaemon.Sentinel,
    LoopexDaemon.Service,
    LoopexDaemon.Owner,
    LoopexDaemon.ConnectionRegistry,
    LoopexDaemon.SocketConnection,
    Loopex.ProgressSink
  ]

  test "one initialized client retains native retirement decisions across real SIGTERM" do
    root = Path.join(System.tmp_dir!(), "ldr-#{System.unique_integer([:positive])}")
    cleanup = make_ref()
    # Concept: every unowned setup path releases its fixture root.
    # Technical depth: register before the first directory acquisition; the
    # same callback identity transfers deletion to exact child-custody cleanup.
    on_exit(cleanup, fn -> File.rm_rf!(root) end)
    workspace = Path.join(root, "w")
    state_root = Path.join(root, "s")
    socket = Path.join([state_root, "daemon", "d.sock"])
    File.mkdir_p!(workspace)
    launch = Path.join(root, "launch.config")
    File.write!(launch, "[].\n")

    evidence_root = System.get_env("M7_DAEMON_RETIREMENT_EVIDENCE_DIR") || System.tmp_dir!()
    File.mkdir_p!(evidence_root)

    evidence =
      Path.join(evidence_root, "daemon-retirement-#{System.unique_integer([:positive])}.json")

    refute File.exists?(evidence)

    driver = Path.join(__DIR__, "support/daemon_retirement_witness_driver.txt")

    arguments = [
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
    ]

    expected_modules =
      Map.new(@modules, fn module ->
        {^module, beam, _path} = :code.get_object_code(module)
        {Atom.to_string(module), Base.encode16(:crypto.hash(:sha256, beam), case: :lower)}
      end)

    code =
      "Code.require_file(#{inspect(driver)}); " <>
        "LoopexCli.DaemonRetirementWitnessDriver.run(#{inspect(arguments)}, #{inspect(evidence)})"

    executable = System.find_executable("elixir") || flunk("elixir executable unavailable")

    child =
      start_command(
        executable,
        [
          :binary,
          :exit_status,
          :use_stdio,
          :hide,
          {:line, 65_536},
          env: [{~c"LOOPEX_PROVIDER_API_KEY", ~c"daemon-command-placeholder"}],
          args:
            Enum.flat_map(:code.get_path(), fn path -> ["-pa", List.to_string(path)] end) ++
              ["-e", code]
        ],
        root,
        evidence,
        cleanup
      )

    port = child.port
    line = await_line(child, 60_000)
    expected_version = LoopexDaemon.version()

    assert %{
             "record" => "daemon_ready",
             "root" => ^state_root,
             "socket" => ^socket,
             "version" => ^expected_version
           } = JSON.decode!(line)

    {:ok, client} = :socket.open(:local, :stream, :default)
    :ok = :socket.connect(client, %{family: :local, path: socket})
    on_exit(fn -> :socket.close(client) end)

    :ok =
      send_frame(client, %{
        "method" => "initialize",
        "request_id" => "init",
        "generations" => [V2.generation()],
        "capabilities" => []
      })

    assert [%{"type" => "initialized"}] = receive_records(client, 1)
    :ok = signal_term(child)

    assert [%{"type" => "daemon.stopping", "reason" => "operator_stop"}] =
             receive_records(client, 1)

    status = await_exit(child, 60_000)
    metadata = evidence |> File.read!() |> JSON.decode!()

    assert metadata["trace_complete"] == true, "incomplete trace at #{evidence}"
    assert metadata["overflow"] == 0, "trace overflow at #{evidence}"
    assert metadata["status"] == status

    assert MapSet.new(Enum.map(metadata["modules"], & &1["module"])) ==
             MapSet.new(Map.keys(expected_modules))

    for identity <- metadata["modules"] do
      assert identity["beam_sha256"] == expected_modules[identity["module"]],
             "loaded beam differs at #{evidence}: #{identity["module"]}"
    end

    assert Enum.any?(metadata["events"], fn event ->
             event["kind"] == "return" and
               event["mfa"] == ["Elixir.LoopexDaemon.Owner", "close_connections", 3]
           end),
           "missing Owner.close_connections result at #{evidence}"

    # Concept: diagnostic completion cannot replace the original stop obligation.
    # Technical depth: retain status zero, the live client, exact original waits,
    # one readiness record and the final socket-path assertion.
    assert status == 0, "native retirement witness #{evidence}: #{JSON.encode!(metadata)}"
    refute_received {^port, {:data, _more}}
    assert {:ok, %File.Stat{type: :other}} = File.lstat(socket)
  end

  # Concept: cleanup retains the original child across the ExUnit actor boundary.
  # Technical depth: this unlinked custodian owns the Port, its original monitor
  # and actual exit_status. Cleanup registration precedes its only launch grant.
  defp start_command(executable, options, root, evidence, cleanup) do
    test = self()
    {owner, owner_down} = spawn_monitor(fn -> await_launch(test) end)

    # Concept: the acquired custodian becomes the sole root-deletion owner.
    # Technical depth: replace the original named callback before granting any
    # Port launch. Missing original exit/status or custodian join preserves root.
    on_exit(cleanup, fn ->
      retired = retire_command(owner)
      File.write!(evidence <> ".parent.json", JSON.encode!(retired) <> "\n", [:exclusive])
      File.rm_rf!(root)
    end)

    cutoff = System.monotonic_time(:millisecond) + 5_000
    send(owner, {:launch, test, executable, options, cutoff})

    receive do
      {:command_opened, ^owner, port, monitor, os_pid} ->
        remaining(cutoff)
        %{owner: owner, owner_down: owner_down, port: port, monitor: monitor, os_pid: os_pid}

      {:DOWN, ^owner_down, :process, ^owner, reason} ->
        flunk("daemon custody failed before launch: #{inspect(reason)}")
    after
      remaining(cutoff) -> flunk("daemon custody did not acquire its original child")
    end
  end

  defp await_launch(test) do
    Process.flag(:trap_exit, true)
    test_down = Process.monitor(test)

    receive do
      {:launch, ^test, executable, options, cutoff} ->
        if Process.alive?(test) and System.monotonic_time(:millisecond) < cutoff do
          port = Port.open({:spawn_executable, String.to_charlist(executable)}, options)
          monitor = :erlang.monitor(:port, port)
          {:os_pid, os_pid} = Port.info(port, :os_pid)
          send(test, {:command_opened, self(), port, monitor, os_pid})

          command_loop(%{
            test: test,
            test_down: test_down,
            port: port,
            monitor: monitor,
            os_pid: os_pid,
            status: nil,
            down: nil,
            joined_at: nil,
            cancel_cutoff: nil,
            stdout_records: 0
          })
        else
          retire_idle(System.monotonic_time(:millisecond) + 5_000)
        end

      {:DOWN, ^test_down, :process, ^test, _} ->
        retire_idle(System.monotonic_time(:millisecond) + 5_000)

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

    send(caller, {:command_retired, reference, :not_launched})
  end

  defp command_loop(state) do
    state = record_join(state)

    if state.joined_at do
      send(state.test, {:command_complete, self(), completion(state)})
      retain_command(state)
    else
      receive do
        {port, {:data, _}} = data when port == state.port ->
          send(state.test, data)
          state = %{state | stdout_records: state.stdout_records + 1}

          if state.stdout_records <= 2 do
            command_loop(state)
          else
            send(state.test, {:command_failed, self(), :stdout_population})
            retain_command(cancel_original(state))
          end

        {port, {:exit_status, status}} when port == state.port ->
          command_loop(%{state | status: status})

        {:DOWN, monitor, :port, port, _} = down
        when monitor == state.monitor and port == state.port ->
          command_loop(%{state | down: down})

        {:EXIT, port, _} when port == state.port ->
          command_loop(state)

        {:term, caller, reference, cutoff} ->
          state = drain_exit_evidence(state)
          result = signal_original(state, "-TERM", cutoff)
          send(caller, {:command_signaled, reference, result})
          command_loop(state)

        {:DOWN, monitor, :process, test, _}
        when monitor == state.test_down and test == state.test ->
          retain_command(cancel_original(state))

        {:retire, caller, reference, cutoff} ->
          dispose_command(state, caller, reference, cutoff)
      end
    end
  end

  defp record_join(%{status: status, down: down, joined_at: nil} = state)
       when not is_nil(status) and not is_nil(down),
       do: %{state | joined_at: System.monotonic_time(:millisecond)}

  defp record_join(state), do: state

  defp completion(state),
    do: Map.take(state, [:port, :monitor, :os_pid, :status, :down, :joined_at, :stdout_records])

  # Concept: observing original exit retires the numeric signal route permanently.
  # Technical depth: queued original status/DOWN is consumed before a signal;
  # a known exit or matching Port loss prevents every subsequent cached-PID kill.
  defp drain_exit_evidence(state) do
    receive do
      {port, {:exit_status, status}} when port == state.port ->
        drain_exit_evidence(%{state | status: status})

      {:DOWN, monitor, :port, port, _} = down
      when monitor == state.monitor and port == state.port ->
        drain_exit_evidence(%{state | down: down})

      {:EXIT, port, _} when port == state.port ->
        drain_exit_evidence(state)
    after
      0 -> record_join(state)
    end
  end

  defp signal_original(%{status: status, down: down}, _signal, _cutoff)
       when not is_nil(status) or not is_nil(down),
       do: {:error, :original_already_exited}

  defp signal_original(state, signal, cutoff) do
    if System.monotonic_time(:millisecond) >= cutoff do
      {:error, :signal_observation_expired}
    else
      case Port.info(state.port, :os_pid) do
        {:os_pid, pid} when pid == state.os_pid ->
          {_output, status} =
            System.cmd("/bin/kill", [signal, Integer.to_string(pid)], stderr_to_stdout: true)

          if System.monotonic_time(:millisecond) < cutoff,
            do: {:ok, status},
            else: {:error, :signal_observation_expired}

        nil ->
          {:error, :original_port_unavailable}

        _other ->
          {:error, :original_port_identity_mismatch}
      end
    end
  end

  defp retain_command(state) do
    receive do
      {:retire, caller, reference, cutoff} ->
        dispose_command(state, caller, reference, cutoff)

      {:EXIT, port, _} when port == state.port ->
        retain_command(state)

      {:DOWN, monitor, :process, test, _}
      when monitor == state.test_down and test == state.test ->
        retain_command(state)

      {:term, caller, reference, _} ->
        send(caller, {:command_signaled, reference, {:error, :original_already_exited}})
        retain_command(state)
    end
  end

  defp dispose_command(state, caller, reference, cutoff) do
    joined = cancel_original(state, cutoff)
    if System.monotonic_time(:millisecond) >= cutoff, do: exit(:retirement_observation_expired)
    send(caller, {:command_retired, reference, completion(joined)})
  end

  defp cancel_original(state, requested \\ nil)

  defp cancel_original(%{joined_at: observed} = state, _requested) when not is_nil(observed),
    do: state

  defp cancel_original(state, requested) do
    cutoff = state.cancel_cutoff || System.monotonic_time(:millisecond) + 5_000
    cutoff = if requested, do: min(cutoff, requested), else: cutoff
    state = drain_exit_evidence(%{state | cancel_cutoff: cutoff})

    if state.joined_at do
      if state.joined_at >= cutoff, do: exit(:original_command_join_unproved)
      state
    else
      _ = signal_original(state, "-KILL", cutoff)
      join_original(state, cutoff)
    end
  end

  defp join_original(%{down: down, status: status} = state, cutoff)
       when not is_nil(down) and not is_nil(status) do
    if System.monotonic_time(:millisecond) >= cutoff, do: exit(:original_command_join_unproved)
    record_join(state)
  end

  defp join_original(state, cutoff) do
    if System.monotonic_time(:millisecond) >= cutoff, do: exit(:original_command_join_unproved)

    receive do
      {:DOWN, monitor, :port, port, _} = down
      when monitor == state.monitor and port == state.port ->
        join_original(%{state | down: down}, cutoff)

      {port, {:exit_status, status}} when port == state.port ->
        join_original(%{state | status: status}, cutoff)

      {port, {:data, _}} when port == state.port ->
        join_original(%{state | stdout_records: state.stdout_records + 1}, cutoff)

      {:EXIT, port, _} when port == state.port ->
        join_original(state, cutoff)
    after
      wait_delay(cutoff) -> exit(:original_command_join_unproved)
    end
  end

  defp retire_command(owner) do
    monitor = Process.monitor(owner)
    reference = make_ref()
    cutoff = System.monotonic_time(:millisecond) + 5_000
    send(owner, {:retire, self(), reference, cutoff})

    receive do
      {:command_retired, ^reference, completed} when is_map(completed) ->
        remaining(cutoff)
        assert is_integer(completed.status) and is_integer(completed.os_pid)
        assert {:DOWN, original, :port, port, reason} = completed.down
        assert original == completed.monitor and port == completed.port
        assert_receive {:DOWN, ^monitor, :process, ^owner, :normal}, remaining(cutoff)
        remaining(cutoff)

        %{
          "format" => "m7-daemon-parent-custody/2",
          "custodian" => inspect(owner),
          "custodian_monitor" => inspect(monitor),
          "custodian_down" => "normal",
          "port" => inspect(port),
          "port_monitor" => inspect(original),
          "port_down_reason" =>
            if(is_atom(reason), do: Atom.to_string(reason), else: "unavailable_reason_shape"),
          "os_pid" => completed.os_pid,
          "exit_status" => completed.status,
          "joined_at_ms" => completed.joined_at,
          "retirement_cutoff_ms" => cutoff,
          "stdout_records" => completed.stdout_records
        }

      {:command_retired, ^reference, :not_launched} ->
        remaining(cutoff)
        assert_receive {:DOWN, ^monitor, :process, ^owner, :normal}, remaining(cutoff)
        remaining(cutoff)
        %{"format" => "m7-daemon-parent-custody/2", "disposition" => "not_launched"}

      {:DOWN, ^monitor, :process, ^owner, reason} ->
        flunk("original daemon cleanup evidence unavailable: #{inspect(reason)}")
    after
      remaining(cutoff) -> flunk("original daemon cleanup did not acknowledge its join")
    end
  end

  defp signal_term(child) do
    reference = make_ref()
    cutoff = System.monotonic_time(:millisecond) + 5_000
    send(child.owner, {:term, self(), reference, cutoff})

    receive do
      {:command_signaled, ^reference, {:ok, 0}} ->
        remaining(cutoff)
        :ok

      {:command_signaled, ^reference, refused} ->
        flunk("original daemon signal refused: #{inspect(refused)}")

      {:DOWN, monitor, :process, owner, reason}
      when monitor == child.owner_down and owner == child.owner ->
        flunk("daemon custody lost before SIGTERM: #{inspect(reason)}")
    after
      remaining(cutoff) -> flunk("original daemon signal did not complete")
    end
  end

  defp await_line(child, bound) do
    cutoff = System.monotonic_time(:millisecond) + bound
    port = child.port

    receive do
      {^port, {:data, {:eol, line}}} ->
        remaining(cutoff)
        line

      {:command_complete, owner, completed} when owner == child.owner ->
        flunk("daemon exited #{completed.status} before readiness")

      {:command_failed, owner, reason} when owner == child.owner ->
        flunk("daemon custody failed before readiness: #{inspect(reason)}")

      {:DOWN, monitor, :process, owner, reason}
      when monitor == child.owner_down and owner == child.owner ->
        flunk("daemon custody lost before readiness: #{inspect(reason)}")
    after
      remaining(cutoff) -> flunk("daemon never announced readiness")
    end
  end

  defp await_exit(child, bound) do
    cutoff = System.monotonic_time(:millisecond) + bound
    port = child.port

    receive do
      {^port, {:data, _line}} ->
        flunk("daemon wrote a second stdout line")

      {:command_complete, owner, completed} when owner == child.owner ->
        remaining(cutoff)
        assert completed.port == child.port and completed.monitor == child.monitor
        assert completed.os_pid == child.os_pid and completed.joined_at < cutoff
        assert completed.down == {:DOWN, child.monitor, :port, child.port, :normal}
        completed.status

      {:command_failed, owner, reason} when owner == child.owner ->
        flunk("daemon custody failed before exit: #{inspect(reason)}")

      {:DOWN, monitor, :process, owner, reason}
      when monitor == child.owner_down and owner == child.owner ->
        flunk("daemon custody lost before exit: #{inspect(reason)}")
    after
      remaining(cutoff) -> flunk("daemon never exited")
    end
  end

  defp remaining(cutoff) do
    value = cutoff - System.monotonic_time(:millisecond)
    assert value > 0, "original fixture observation cutoff exhausted"
    value
  end

  defp wait_delay(cutoff), do: max(0, cutoff - System.monotonic_time(:millisecond))

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
