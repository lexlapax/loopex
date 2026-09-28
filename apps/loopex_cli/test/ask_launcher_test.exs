defmodule LoopexCli.AskLauncherTest do
  use ExUnit.Case, async: true

  @launcher Path.expand("../bin/loopex", __DIR__)

  test "ask modes retain each signal received before the child PID is assigned" do
    for command <- ["ask", "-p"], signal <- ["INT", "TERM", "HUP", "QUIT"] do
      root = temporary_directory()
      gate_ready = Path.join(root, "gate-ready")
      gate_release = Path.join(root, "gate-release")
      launcher = Path.join(root, "loopex")
      stand_in = Path.join(root, "stand-in")

      source = File.read!(@launcher)
      anchor = "child=$!\n"
      assert length(:binary.matches(source, anchor)) == 1

      File.write!(
        launcher,
        String.replace(
          source,
          anchor,
          ": > \"$LOOPEX_GATE_READY\"\nwhile [ ! -e \"$LOOPEX_GATE_RELEASE\" ]; do :; done\n" <>
            anchor,
          global: false
        )
      )

      File.chmod!(launcher, 0o755)

      File.write!(stand_in, """
      #!/bin/sh
      trap 'printf "term-received\\n"; exit 42' TERM
      printf 'child-ready\\n'
      while IFS= read -r _; do :; done
      exit 99
      """)

      File.chmod!(stand_in, 0o755)

      port =
        Port.open({:spawn_executable, launcher}, [
          :binary,
          :exit_status,
          :hide,
          args: [command],
          env: [
            {~c"LOOPEX_ESCRIPT", String.to_charlist(stand_in)},
            {~c"LOOPEX_GATE_READY", String.to_charlist(gate_ready)},
            {~c"LOOPEX_GATE_RELEASE", String.to_charlist(gate_release)}
          ]
        ])

      try do
        assert {:os_pid, launcher_pid} = Port.info(port, :os_pid)
        assert_output(port, "child-ready\n")
        assert_file(gate_ready)
        assert {_, 0} = System.cmd("/bin/kill", ["-#{signal}", Integer.to_string(launcher_pid)])
        File.touch!(gate_release)
        assert_output(port, "term-received\n")
        assert_receive {^port, {:exit_status, 42}}, 5_000
      after
        File.touch!(gate_release)
        if Port.info(port), do: Port.close(port)
        File.rm_rf!(root)
      end
    end
  end

  test "crash dumps are disabled only for ask and its alias" do
    root = temporary_directory()
    stand_in = Path.join(root, "stand-in")

    try do
      File.write!(stand_in, """
      #!/bin/sh
      printf '%s|%s\\n' "$ERL_CRASH_DUMP" "$ERL_CRASH_DUMP_SECONDS"
      """)

      File.chmod!(stand_in, 0o755)

      for {command, expected} <- [
            {"ask", "/dev/null|0\n"},
            {"-p", "/dev/null|0\n"},
            {"sessions", "original.dump|7\n"}
          ] do
        assert {^expected, 0} =
                 System.cmd(@launcher, [command],
                   env: [
                     {"LOOPEX_ESCRIPT", stand_in},
                     {"ERL_CRASH_DUMP", "original.dump"},
                     {"ERL_CRASH_DUMP_SECONDS", "7"}
                   ]
                 )
      end
    after
      File.rm_rf!(root)
    end
  end

  defp temporary_directory do
    root = Path.join(System.tmp_dir!(), "loopex-ask-launcher-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    root
  end

  defp assert_file(path) do
    deadline = System.monotonic_time(:millisecond) + 5_000
    assert_file(path, deadline)
  end

  defp assert_file(path, deadline) do
    if File.exists?(path) do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        flunk("launcher did not reach the pre-PID gate")
      else
        Process.sleep(10)
        assert_file(path, deadline)
      end
    end
  end

  defp assert_output(port, expected) do
    receive do
      {^port, {:data, ^expected}} -> :ok
      {^port, {:data, other}} -> flunk("unexpected launcher output: #{inspect(other)}")
      {^port, {:exit_status, status}} -> flunk("launcher exited early with #{status}")
    after
      5_000 -> flunk("launcher did not emit #{inspect(expected)}")
    end
  end
end
