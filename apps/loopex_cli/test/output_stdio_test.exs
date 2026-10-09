defmodule LoopexCli.OutputStdioTest do
  use ExUnit.Case, async: false
  @moduletag timeout: 120_000

  @driver Path.expand("support/output_stdio_driver.exs", __DIR__)

  # Concept: the inherited-terminal target is proved on real descriptors.
  #
  # Technical depth: each case runs one command in its own VM whose fd 1 and
  # fd 2 are an actual pipe, file or PTY. The command writes through the fixed
  # Bash writer and reports its verdict and writer group outside those
  # descriptors. This test then reads the exact bytes each descriptor received
  # and proves through the process table that the writer's group is gone.
  setup do
    root = Path.join(System.tmp_dir!(), "los-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    %{root: root, report: Path.join(root, "report"), stderr: Path.join(root, "stderr")}
  end

  test "pipes receive exact raw bytes on separate descriptors and the writer joins", f do
    {stdout, 0} = shell("#{child("bytes", f.report)} 2>#{sh_quote(f.stderr)}")
    report = report(f.report)
    assert report.finish == :ok

    assert stdout ==
             "plain\n" <>
               <<0, 10, 255, 254, 13>> <> String.duplicate("b", 200_000) <> "end\n"

    assert File.read!(f.stderr) == <<"err", 0, "x\n">>
    assert group_absent?(report.leader)
  end

  test "a PTY receives the same records through terminal line discipline", f do
    {output, 0} = shell("script -qec #{sh_quote(child("pty", f.report))} /dev/null")
    report = report(f.report)
    assert report.finish == :ok
    assert output =~ "line1\r\nline2\r\n"
    assert output =~ "err\r\n"
    assert output =~ "line3\r\n"

    [before_err, after_err] = String.split(output, "err\r\n", parts: 2)
    assert before_err =~ "line2\r\n"
    assert after_err =~ "line3\r\n"
    assert group_absent?(report.leader)
  end

  test "the writer runs without inherited credentials or environment", f do
    {stdout, 0} =
      shell("#{child("environment", f.report)} 2>#{sh_quote(f.stderr)}",
        env: [{~c"LOOPEX_PROVIDER_API_KEY", ~c"provider-canary-7f3a"}]
      )

    report = report(f.report)
    assert report.finish == :ok
    assert stdout == "ok\n"
    refute report.environ =~ "provider-canary"

    assert report.environ |> String.split(<<0>>, trim: true) |> Enum.sort() ==
             ["LC_ALL=C", "PATH=/usr/bin:/bin"]

    assert group_absent?(report.leader)
  end

  test "a stopped reader fails the control cutoff and retires the writer group", f do
    port = start_shell("#{child("blocked", f.report)} 2>#{sh_quote(f.stderr)} | sleep 30")
    report = await_report(f.report)
    assert report.finish == {:error, :output_drain_timeout}
    assert report.elapsed >= 4_000 and report.elapsed < 6_500
    assert group_absent?(report.leader)
    close_shell(port)
  end

  test "a broken reader fails the write and retires the writer group", f do
    {_stdout, _status} = shell("#{child("broken", f.report)} 2>#{sh_quote(f.stderr)} | true")
    report = report(f.report)
    assert report.finish == {:error, :output_failed}
    assert group_absent?(report.leader)
  end

  test "command loss retires a blocked writer group within the owner's cutoff", f do
    port = start_shell("#{child("owner_loss", f.report)} 2>#{sh_quote(f.stderr)} | sleep 30")
    report = await_report(f.report)
    assert report.owner == :normal
    assert report.elapsed < 6_000
    assert group_absent?(report.leader)
    close_shell(port)
  end

  defp child(mode, report) do
    elixir = System.find_executable("elixir") || flunk("elixir executable unavailable")

    paths =
      :code.get_path()
      |> Enum.map(&List.to_string/1)
      |> Enum.filter(&String.contains?(&1, "_build"))
      |> Enum.flat_map(&["-pa", &1])

    Enum.map_join([elixir | paths] ++ [@driver, mode, report], " ", &sh_quote/1)
  end

  defp shell(script, options \\ []) do
    port = start_shell(script, options)
    collect(port, [], System.monotonic_time(:millisecond) + 60_000)
  end

  defp start_shell(script, options \\ []) do
    Port.open({:spawn_executable, ~c"/bin/sh"}, [
      :binary,
      :exit_status,
      {:args, [~c"-c", String.to_charlist(script)]},
      {:env, Keyword.get(options, :env, [])}
    ])
  end

  defp collect(port, acc, deadline) do
    receive do
      {^port, {:data, bytes}} -> collect(port, [acc, bytes], deadline)
      {^port, {:exit_status, status}} -> {IO.iodata_to_binary(acc), status}
    after
      max(deadline - System.monotonic_time(:millisecond), 0) -> flunk("the command did not end")
    end
  end

  defp close_shell(port) do
    {:os_pid, pid} = Port.info(port, :os_pid)
    System.cmd("/bin/sh", ["-c", "pkill -P #{pid}; kill #{pid}"], stderr_to_stdout: true)

    receive do
      {^port, {:exit_status, _}} -> :ok
    after
      10_000 -> flunk("the shell did not end")
    end
  end

  defp await_report(path, attempts \\ 600) do
    cond do
      File.exists?(path) and File.stat!(path).size > 0 ->
        Process.sleep(50)
        report(path)

      attempts > 0 ->
        Process.sleep(50)
        await_report(path, attempts - 1)

      true ->
        flunk("the command wrote no report")
    end
  end

  defp report(path), do: path |> File.read!() |> :erlang.binary_to_term()

  defp group_absent?(leader) do
    {table, 0} = System.cmd("ps", ["-e", "-o", "pgid="])
    groups = String.split(table, ~r/\s+/, trim: true)
    groups != [] and Integer.to_string(leader) not in groups
  end

  defp sh_quote(value), do: "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
end
