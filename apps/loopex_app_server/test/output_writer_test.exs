defmodule Loopex.AppServer.OutputWriterTest do
  @moduledoc """
  ## Concept

  The fixed foreground proxy writes actual inherited stdout in a separate VM.
  A blocked pipe remains blocked while the host services retirement and joins.
  Control failures and actor deaths never become successful frame delivery.

  ## Technical depth

  The child uses a loopback fixture channel independent of stdout. The output
  is a regular file or a real FIFO held open by the case; neither a BEAM IO
  device nor a fabricated process-table answer replaces the physical write.
  Each case retains one 30,000-ms request cutoff, the writer's captured
  5,000+5,000-ms cutoffs and separate 1,000-ms fixture join grace. Control-record
  faults exercise the private decoder with a real active proxy; they do not
  pretend to originate from the fixed Bash program.
  """

  use ExUnit.Case, async: false

  alias Loopex.AppServer.OutputWriter
  alias Loopex.Executor.Local

  @moduletag timeout: 60_000
  @frame_bytes 2_097_152
  @fixture_grace 1_000

  test "literal frame bytes and LF are written once before exact joins release them" do
    with_fixture(:file, fn fixture ->
      startup = Path.join(Path.dirname(fixture.output), "unwanted-startup.bash")
      File.write!(startup, "printf '%s' 'UNWANTED-STARTUP'\n")

      assert request(fixture, {"environment", startup}, &(&1 == :environment_ready)) ==
               :environment_ready

      frame = "{\"text\":\"$HOME `touch ignored` \\\" café\"}\n"
      {:reply, {:ok, reference}} = request(fixture, {"write", frame}, &match?({:reply, _}, &1))
      {:result, ^reference, {:ok, first}, at} = next(fixture, &match?({:result, _, _, _}, &1))
      assert_joined(first, at)
      assert File.read!(fixture.output) == frame

      {:reply, {:ok, next_reference}} =
        request(fixture, {"write", "{}\n"}, &match?({:reply, _}, &1))

      {:result, ^next_reference, {:ok, second}, at} =
        next(fixture, &match?({:result, _, _, _}, &1))

      assert_joined(second, at)
      refute first.leader == second.leader
      assert File.read!(fixture.output) == frame <> "{}\n"
      assert File.read!(fixture.stderr) == <<>>
    end)
  end

  test "invalid frames never launch a proxy or write stdout" do
    {:ok, writer} = OutputWriter.start()
    monitor = Process.monitor(writer)

    try do
      for frame <- [
            nil,
            <<>>,
            "\n",
            "{}",
            "{}\r\n",
            "{}\n{}\n",
            <<0, 10>>,
            <<255, 10>>,
            :binary.copy("x", @frame_bytes) <> "\n"
          ] do
        assert OutputWriter.write(writer, frame) == {:error, :invalid_frame}
        assert :sys.get_state(writer).active == nil
      end
    after
      assert OutputWriter.stop(writer) == {:ok, :idle}
      assert_receive {:DOWN, ^monitor, :process, ^writer, :normal}, @fixture_grace
    end
  end

  test "a full-cap blocked stdout spends its original cutoff and rejects a second frame" do
    with_fixture(:fifo, fn fixture ->
      startup = Path.join(Path.dirname(fixture.output), "unwanted-startup.bash")
      File.write!(startup, "printf '%s' 'UNWANTED-STARTUP'\n")

      assert request(fixture, {"environment", startup}, &(&1 == :environment_ready)) ==
               :environment_ready

      frame = :binary.copy("x", @frame_bytes - 1) <> "\n"
      {:reply, {:ok, reference}} = request(fixture, {"write", frame}, &match?({:reply, _}, &1))
      active = blocked_worker(fixture)
      assert_live_group(active)

      assert {environment, 0} =
               Local.answer_within(
                 "/bin/ps",
                 ["eww", "-p", Integer.to_string(active.leader), "-o", "command="],
                 500
               )

      refute environment == <<>>
      assert :binary.match(environment, "writer-environment-fixture") == :nomatch
      assert :binary.match(environment, "BASH_ENV=") == :nomatch
      {:reply, {:error, :busy}} = request(fixture, {"write", "{}\n"}, &match?({:reply, _}, &1))
      {:retired, ^reference, :write_expired} = next(fixture, &match?({:retired, _, _}, &1))

      {:result, ^reference, {:error, :write_expired, facts}, at} =
        next(fixture, &match?({:result, _, _, _}, &1))

      assert facts.cleanup == :joined
      assert facts.worker_waited == false
      assert_physical_join(facts, at)
      assert facts.write_cutoff == active.write_cutoff
      assert facts.cleanup_cutoff == active.cleanup_cutoff
      {:reply, {:error, :retired}} = request(fixture, {"write", "{}\n"}, &match?({:reply, _}, &1))
    end)
  end

  test "stop joins a real partial stdout worker without appending an error record" do
    with_fixture(:fifo, fn fixture ->
      frame = :binary.copy("p", @frame_bytes - 1) <> "\n"
      {:reply, {:ok, reference}} = request(fixture, {"write", frame}, &match?({:reply, _}, &1))
      active = blocked_worker(fixture)
      assert_live_group(active)
      assert {:ok, prefix} = :file.read(fixture.fifo, 4096)
      assert prefix == :binary.copy("p", 4096)
      assert :binary.match(prefix, "\n") == :nomatch
      send_command(fixture, "stop")
      {:retired, ^reference, :stopped} = next(fixture, &match?({:retired, _, _}, &1))
      {:stopped, {:ok, facts}} = next(fixture, &match?({:stopped, _}, &1))
      assert facts.cleanup == :joined
      refute facts.worker_waited
      assert facts.worker == active.worker
      assert facts.group_absent
      assert facts.port_down
      assert is_integer(facts.port_exit_status)
      {:writer_down, :normal, at} = next(fixture, &match?({:writer_down, _, _}, &1))
      assert at < facts.cleanup_cutoff + @fixture_grace
    end)
  end

  test "a broken stdout cannot acknowledge the worker or prevent physical cleanup" do
    with_fixture(:fifo, fn fixture ->
      :ok = :file.close(fixture.fifo)
      {:reply, {:ok, reference}} = request(fixture, {"write", "{}\n"}, &match?({:reply, _}, &1))
      {:retired, ^reference, reason} = next(fixture, &match?({:retired, _, _}, &1))
      assert reason in [:write_expired, :control_eof]

      {:result, ^reference, {:error, ^reason, facts}, at} =
        next(fixture, &match?({:result, _, _, _}, &1))

      refute facts.worker_waited
      assert_physical_join(facts, at)
    end)
  end

  for fault <- ["nonce", "order", "repeat", "trailing"] do
    @fault fault
    test "private #{@fault} control retires a real blocked writer and joins its group" do
      with_fixture(:fifo, fn fixture ->
        {:reply, {:ok, reference}} =
          request(
            fixture,
            {"write", :binary.copy("q", @frame_bytes - 1) <> "\n"},
            &match?({:reply, _}, &1)
          )

        active = blocked_worker(fixture)
        assert_live_group(active)
        assert request(fixture, {"inject", @fault}, &(&1 == :injected)) == :injected
        {:retired, ^reference, :invalid_control} = next(fixture, &match?({:retired, _, _}, &1))

        {:result, ^reference, {:error, :invalid_control, facts}, at} =
          next(fixture, &match?({:result, _, _, _}, &1))

        refute facts.worker_waited
        assert facts.worker == active.worker
        assert_physical_join(facts, at)
      end)
    end
  end

  test "a repeated actually observed WRITTEN cannot release a fully exposed frame" do
    with_fixture(:fifo, fn fixture ->
      frame = :binary.copy("r", @frame_bytes - 1) <> "\n"
      {:reply, {:ok, reference}} = request(fixture, {"write", frame}, &match?({:reply, _}, &1))
      active = blocked_worker(fixture)
      assert_live_group(active)
      assert request(fixture, "suspend", &(&1 == :suspended)) == :suspended
      captured = Path.join(Path.dirname(fixture.output), "actually-written")
      drain = "IFS= read -r -t 5 payload < \"$1\" || exit 1; printf '%s\\n' \"$payload\" > \"$2\""

      assert {<<>>, 0} =
               Local.answer_within(
                 "/bin/bash",
                 [
                   "--noprofile",
                   "--norc",
                   "-c",
                   drain,
                   "fixture-drain",
                   fixture.output,
                   captured
                 ],
                 5_000
               )

      assert File.read!(captured) == frame
      assert request(fixture, "repeat_written", &(&1 == :repeated_written)) == :repeated_written
      {:retired, ^reference, :invalid_control} = next(fixture, &match?({:retired, _, _}, &1))

      {:result, ^reference, {:error, :invalid_control, facts}, at} =
        next(fixture, &match?({:result, _, _, _}, &1))

      refute facts.worker_waited
      assert facts.worker == active.worker
      assert_physical_join(facts, at)
    end)
  end

  test "port close alone returns unproved cleanup and cannot reopen the output" do
    with_fixture(:fifo, fn fixture ->
      {:reply, {:ok, reference}} =
        request(
          fixture,
          {"write", :binary.copy("c", @frame_bytes - 1) <> "\n"},
          &match?({:reply, _}, &1)
        )

      active = blocked_worker(fixture)
      assert request(fixture, "close_proxy", &(&1 == :closed_proxy)) == :closed_proxy
      {:retired, ^reference, :control_eof} = next(fixture, &match?({:retired, _, _}, &1))

      {:result, ^reference, {:error, :cleanup_unproved, facts}, _at} =
        next(fixture, &match?({:result, _, _, _}, &1))

      assert facts.cleanup == :unproved
      refute facts.worker_waited
      assert facts.port_exit_status == nil
      assert facts.cleanup_cutoff == active.cleanup_cutoff
      {:reply, {:error, :retired}} = request(fixture, {"write", "{}\n"}, &match?({:reply, _}, &1))

      {:stopped, {:error, :cleanup_unproved, ^facts}} =
        request(fixture, "stop", &match?({:stopped, _}, &1))

      assert_absent(active.leader, fixture.cutoff)
    end)
  end

  for loss <- ["kill_owner", "kill_writer"] do
    @loss loss
    test "#{@loss} closes control while an actual stdout worker is blocked" do
      with_fixture(:fifo, fn fixture ->
        {:reply, {:ok, _reference}} =
          request(
            fixture,
            {"write", :binary.copy("d", @frame_bytes - 1) <> "\n"},
            &match?({:reply, _}, &1)
          )

        active = blocked_worker(fixture)
        assert_live_group(active)
        cutoff = System.monotonic_time(:millisecond) + 5_000
        send_command(fixture, @loss)
        acknowledgement = if(@loss == "kill_owner", do: :killed_owner, else: :killed_writer)
        assert next(fixture, &(&1 == acknowledgement)) == acknowledgement

        if @loss == "kill_owner" do
          {:owner_down, :killed, owner_at} = next(fixture, &match?({:owner_down, _, _}, &1))
          assert owner_at < active.cleanup_cutoff + @fixture_grace
        end

        {:writer_down, reason, at} = next(fixture, &match?({:writer_down, _, _}, &1))
        assert reason == if(@loss == "kill_writer", do: :killed, else: :normal)
        assert at < active.cleanup_cutoff + @fixture_grace
        assert_absent(active.leader, cutoff)
        # Manager loss supplies no successful frame/cleanup acknowledgment.
        # Actual physical absence is this fixture's separate witness.
      end)
    end
  end

  test "control-channel EOF performs orderly writer shutdown without a delivered frame" do
    with_fixture(:fifo, fn fixture ->
      {:reply, {:ok, _reference}} =
        request(
          fixture,
          {"write", :binary.copy("e", @frame_bytes - 1) <> "\n"},
          &match?({:reply, _}, &1)
        )

      active = blocked_worker(fixture)
      assert_live_group(active)
      cutoff = System.monotonic_time(:millisecond) + 5_000
      :ok = :gen_tcp.close(fixture.socket)
      assert_launcher_exit(fixture, cutoff)
      assert_absent(active.leader, cutoff)
    end)
  end

  defp assert_joined(facts, at) do
    assert facts.worker_waited
    assert is_integer(facts.worker) and facts.worker != facts.leader
    assert facts.write_cutoff - facts.admitted_at == 5_000
    assert facts.cleanup_cutoff - facts.write_cutoff == 5_000
    assert facts.written_at < facts.write_cutoff
    assert facts.joined_at < facts.write_cutoff
    assert facts.written_at <= facts.joined_at
    assert_physical_join(facts, at)
  end

  defp assert_physical_join(facts, at) do
    assert facts.cleanup == :joined
    assert facts.port_down
    assert is_integer(facts.port_exit_status)
    assert facts.group_absent
    assert facts.group == facts.leader
    assert facts.cleanup_observed_at < facts.cleanup_cutoff
    assert at < facts.cleanup_cutoff + @fixture_grace
  end

  defp blocked_worker(fixture),
    do: blocked_worker(fixture, System.monotonic_time(:millisecond) + 5_000)

  defp blocked_worker(fixture, cutoff) do
    assert System.monotonic_time(:millisecond) < cutoff

    case request(fixture, "state", &match?({:state, _, _}, &1)) do
      {:state, %{phase: :writing, worker: worker} = active, false} when is_integer(worker) ->
        active

      {:state, _active, _sealed} ->
        Process.sleep(10)
        blocked_worker(fixture, cutoff)
    end
  end

  defp assert_live_group(active) do
    pairs = process_pairs(500)
    assert {active.leader, active.leader} in pairs
    assert {active.worker, active.leader} in pairs
  end

  defp assert_absent(group, cutoff) do
    remaining = cutoff - System.monotonic_time(:millisecond)
    assert remaining > 0
    pairs = process_pairs(min(500, remaining))

    if Enum.any?(pairs, fn {_pid, pgid} -> pgid == group end) do
      Process.sleep(min(10, remaining))
      assert_absent(group, cutoff)
    else
      assert System.monotonic_time(:millisecond) < cutoff
    end
  end

  defp process_pairs(bound) do
    assert {bytes, 0} = Local.answer_within("/bin/ps", ["-e", "-o", "pid=", "-o", "pgid="], bound)
    lines = String.split(bytes, "\n", trim: true)
    assert lines != []

    Enum.map(lines, fn line ->
      [pid, group] = String.split(line)
      {String.to_integer(pid), String.to_integer(group)}
    end)
  end

  defp with_fixture(mode, body) do
    cutoff = System.monotonic_time(:millisecond) + 30_000

    root =
      Path.join(System.tmp_dir!(), "loopex-output-writer-#{System.unique_integer([:positive])}")

    File.mkdir!(root)

    try do
      File.chmod!(root, 0o700)
      output = Path.join(root, "stdout")
      stderr = Path.join(root, "stderr")

      {:ok, listener} =
        :gen_tcp.listen(0, [:binary, packet: 4, active: false, ip: {127, 0, 0, 1}])

      try do
        {:ok, {_address, number}} = :inet.sockname(listener)

        fifo =
          if mode == :fifo do
            {<<>>, 0} = System.cmd("/usr/bin/mkfifo", [output])
            File.chmod!(output, 0o600)
            {:ok, device} = :file.open(String.to_charlist(output), [:read, :write, :raw, :binary])
            device
          else
            nil
          end

        try do
          fixture_source = Path.join(__DIR__, "support/output_writer_fixture.txt")
          shell = Path.join(root, "launch.bash")

          File.write!(
            shell,
            "exec \"$1\" \"${@:5}\" \"$2\" \"$3\" >\"$4\" 2>\"$LOOPEX_WRITER_STDERR\"\n"
          )

          ebin =
            for path <- :code.get_path(), File.dir?(List.to_string(path)), do: [~c"-pa", path]

          cleared = for {name, _value} <- System.get_env(), do: {String.to_charlist(name), false}

          environment =
            cleared ++
              [
                {~c"PATH", String.to_charlist(System.get_env("PATH"))},
                {~c"HOME", String.to_charlist(root)},
                {~c"ERL_CRASH_DUMP", String.to_charlist(Path.join(root, "crash.dump"))},
                {~c"ELIXIR_ERL_OPTIONS", ~c"+S 2:2 -noinput"},
                {~c"LOOPEX_HOME", String.to_charlist(root)},
                {~c"LOOPEX_WRITER_STDERR", String.to_charlist(stderr)}
              ]

          launcher =
            Port.open({:spawn_executable, ~c"/bin/bash"}, [
              :binary,
              :exit_status,
              {:args,
               [
                 ~c"--noprofile",
                 ~c"--norc",
                 String.to_charlist(shell),
                 String.to_charlist(
                   System.find_executable("elixir") || flunk("Elixir unavailable")
                 ),
                 String.to_charlist(fixture_source),
                 String.to_charlist(Integer.to_string(number)),
                 String.to_charlist(output)
               ] ++ Enum.concat(ebin)},
              {:env, environment}
            ])

          try do
            monitor = :erlang.monitor(:port, launcher)

            try do
              {:ok, socket} =
                :gen_tcp.accept(
                  listener,
                  max(0, cutoff - System.monotonic_time(:millisecond))
                )

              fixture = %{
                socket: socket,
                launcher: launcher,
                monitor: monitor,
                output: output,
                stderr: stderr,
                fifo: fifo,
                cutoff: cutoff
              }

              try do
                assert {:ready, _os_pid} = next(fixture, &match?({:ready, _}, &1))
                body.(fixture)
              after
                cleanup([
                  fn -> :gen_tcp.send(socket, :erlang.term_to_binary("close")) end,
                  fn -> :gen_tcp.close(socket) end,
                  fn -> assert_launcher_exit(fixture, cutoff + @fixture_grace) end
                ])
              end
            after
              :erlang.demonitor(monitor, [:flush])
            end
          after
            close_launcher(launcher)
          end
        after
          if fifo != nil, do: :file.close(fifo)
        end
      after
        :gen_tcp.close(listener)
      end
    after
      File.rm_rf!(root)
    end
  end

  # Concept: fixture retention and every acquired resource have independent
  # cleanup attempts; an earlier failed assertion cannot bypass later joins.
  # Technical depth: after all actions, re-raise the first actual failure with
  # its original stack. This supplies no successful join for a failed action.
  defp cleanup(actions) do
    failure =
      Enum.reduce(actions, nil, fn action, first ->
        try do
          action.()
          first
        catch
          kind, reason -> first || {kind, reason, __STACKTRACE__}
        end
      end)

    case failure do
      nil -> :ok
      {kind, reason, stack} -> :erlang.raise(kind, reason, stack)
    end
  end

  defp request(fixture, command, accepts) do
    send_command(fixture, command)
    next(fixture, accepts)
  end

  defp send_command(fixture, command) do
    assert :gen_tcp.send(fixture.socket, :erlang.term_to_binary(command)) == :ok
  end

  defp next(fixture, accepts) do
    key = {__MODULE__, fixture.launcher, :records}
    records = Process.get(key, [])

    case Enum.find_index(records, accepts) do
      index when is_integer(index) ->
        {record, rest} = List.pop_at(records, index)
        Process.put(key, rest)
        record

      nil ->
        remaining = fixture.cutoff - System.monotonic_time(:millisecond)
        assert remaining > 0
        assert {:ok, bytes} = :gen_tcp.recv(fixture.socket, 0, remaining)
        record = :erlang.binary_to_term(bytes, [:safe])
        assert length(records) < 32
        Process.put(key, records ++ [record])
        next(fixture, accepts)
    end
  end

  defp assert_launcher_exit(fixture, cutoff) do
    # Remember observed terminal facts because a case may explicitly join
    # before its unconditional fixture cleanup executes.
    key = {__MODULE__, fixture.launcher}
    observed = Process.get(key, %{exit: false, down: false})
    joined = join_launcher(fixture, cutoff, observed)
    Process.put(key, joined)
    assert joined.exit and joined.down
  end

  defp join_launcher(_fixture, _cutoff, %{exit: true, down: true} = observed), do: observed

  defp join_launcher(fixture, cutoff, observed) do
    remaining = max(0, cutoff - System.monotonic_time(:millisecond))

    receive do
      {port, {:exit_status, status}} when port == fixture.launcher ->
        assert status == 0
        join_launcher(fixture, cutoff, %{observed | exit: true})

      {:DOWN, monitor, :port, port, _reason}
      when monitor == fixture.monitor and port == fixture.launcher ->
        join_launcher(fixture, cutoff, %{observed | down: true})

      {port, {:data, _bytes}} when port == fixture.launcher ->
        join_launcher(fixture, cutoff, observed)
    after
      remaining -> flunk("fixture launcher did not physically join")
    end
  end

  defp close_launcher(port) do
    if Port.info(port) != nil, do: Port.close(port)
    Process.delete({__MODULE__, port})
    Process.delete({__MODULE__, port, :records})
  rescue
    ArgumentError -> Process.delete({__MODULE__, port})
  end
end
