# Concept: one command in its own VM writing through the inherited-terminal target.
# Technical depth: the parent test supplies the mode and a report path. The
# report is an external term written outside stdout/stderr, so the parent can
# compare the exact bytes the descriptors received with what the owner reported.
alias LoopexCli.Output

[mode, report] = System.argv()

leader = fn {:loopex_cli_output, owner, _} -> :sys.get_state(owner).target.leader end
write_report = fn map -> File.write!(report, :erlang.term_to_binary(map)) end

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
    environ = File.read!("/proc/#{group}/environ")
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
