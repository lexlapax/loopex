# Concept: one command in its own VM writing through the inherited-terminal target.
# Technical depth: the parent test supplies the mode and a report path. The
# report is an external term written outside stdout/stderr, so the parent can
# compare the exact bytes the descriptors received with what the owner reported.
alias LoopexCli.Output

[mode, report] = System.argv()

leader = fn {:loopex_cli_output, owner, _} -> :sys.get_state(owner).target.leader end
write_report = fn map -> File.write!(report, :erlang.term_to_binary(map)) end

# Concept: read the exec-time environment from the kernel, not from the process.
# Technical depth: Linux exposes the writer's block NUL-separated in /proc.
# Darwin has no /proc and SIP hides a platform binary's (`/bin/bash`, `/bin/dd`)
# environment from `ps -E`, so there the writer's exact port environment list is
# exec'd as the non-platform ERTS `inet_gethost`, which blocks on its stdin, and
# `ps -E` reads the block back after its argv once the exec has landed. Only the
# Linux lane proves the block on the writer itself.
visible_environ = fn ->
  [probe] = Path.wildcard(Path.join([:code.root_dir(), "erts-*", "bin", "inet_gethost"]))

  port =
    Port.open({:spawn_executable, String.to_charlist(probe)}, [
      :binary,
      {:env, LoopexCli.Output.Stdio.environment()}
    ])

  {:os_pid, pid} = Port.info(port, :os_pid)

  line =
    Enum.find_value(1..500, fn _ ->
      {line, 0} = System.cmd("/bin/ps", ["-E", "-ww", "-o", "command=", "-p", "#{pid}"])
      line = String.trim_trailing(line, "\n")
      (line == probe or String.starts_with?(line, probe <> " ")) && line
    end) || raise "the probe never exec'd"

  Port.close(port)
  line |> String.replace_prefix(probe, "") |> String.split(" ", trim: true) |> Enum.join(<<0>>)
end

environ = fn output ->
  case :os.type() do
    {:unix, :darwin} -> visible_environ.()
    _ -> File.read!("/proc/#{leader.(output)}/environ")
  end
end

case mode do
  "bytes" ->
    {:ok, output, _sink} = Output.open(:stdio, Output.acquisition())
    group = leader.(output)
    :ok = Output.write(output, :text, :stdout, "plain\n")
    :ok = Output.write(output, :text, :stderr, <<"err", 0, "x\n">>)
    :ok = Output.write(output, :control, :stdout, <<0, 10, 255, 254, 13>>)
    :ok = Output.write(output, :text, :stdout, String.duplicate("b", 200_000))
    :ok = Output.write(output, :text, :stdout, "")
    :ok = Output.write(output, :text, :stdout, "end\n")
    write_report.(%{finish: Output.finish(output), leader: group})

  "pty" ->
    {:ok, output, _sink} = Output.open(:stdio, Output.acquisition())
    group = leader.(output)
    :ok = Output.write(output, :text, :stdout, "line1\nline2\n")
    :ok = Output.write(output, :text, :stderr, "err\n")
    :ok = Output.write(output, :text, :stdout, "line3\n")
    write_report.(%{finish: Output.finish(output), leader: group})

  "environment" ->
    {:ok, output, _sink} = Output.open(:stdio, Output.acquisition())
    group = leader.(output)
    environ = environ.(output)
    :ok = Output.write(output, :text, :stdout, "ok\n")
    write_report.(%{finish: Output.finish(output), leader: group, environ: environ})

  "blocked" ->
    {:ok, output, _sink} = Output.open(:stdio, Output.acquisition())
    group = leader.(output)
    :ok = Output.write(output, :text, :stdout, String.duplicate("x", 200_000))
    started = System.monotonic_time(:millisecond)
    :ok = Output.write(output, :control, :stdout, "after\n")
    Process.sleep(2_000)
    finish = Output.finish(output)
    elapsed = System.monotonic_time(:millisecond) - started
    write_report.(%{finish: finish, leader: group, elapsed: elapsed})

  "broken" ->
    {:ok, output, _sink} = Output.open(:stdio, Output.acquisition())
    group = leader.(output)
    Process.sleep(500)
    first = Output.write(output, :text, :stdout, String.duplicate("y", 100_000))
    Process.sleep(500)
    write_report.(%{first: first, finish: Output.finish(output), leader: group})

  "owner_loss" ->
    parent = self()

    command =
      spawn(fn ->
        {:ok, output, _sink} = Output.open(:stdio, Output.acquisition())
        :ok = Output.write(output, :text, :stdout, String.duplicate("z", 200_000))
        send(parent, {:opened, output, leader.(output)})
        Process.sleep(:infinity)
      end)

    {output, group} =
      receive do
        {:opened, output, group} -> {output, group}
      after
        5_000 -> raise "no output"
      end

    {:loopex_cli_output, owner, _} = output
    monitor = Process.monitor(owner)
    Process.sleep(200)
    started = System.monotonic_time(:millisecond)
    Process.exit(command, :kill)

    reason =
      receive do
        {:DOWN, ^monitor, :process, ^owner, reason} -> reason
      after
        10_000 -> :owner_alive
      end

    write_report.(%{
      owner: reason,
      leader: group,
      elapsed: System.monotonic_time(:millisecond) - started
    })
end
