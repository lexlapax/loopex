defmodule Loopex.LLM.ReqLLM.ProviderLauncherTest do
  use ExUnit.Case, async: false

  alias Loopex.LLM.ReqLLM.ProviderLauncher

  setup_all do
    {:ok, _apps} = Application.ensure_all_started(:crypto)
    :ok
  end

  setup do
    root =
      Path.join(System.tmp_dir!(), "loopex-provider-launch-#{System.unique_integer([:positive])}")

    File.mkdir!(root)
    previous = Process.flag(:trap_exit, true)
    on_exit(fn -> File.rm_rf!(root) end)
    on_exit(fn -> Process.flag(:trap_exit, previous) end)
    {:ok, root: root}
  end

  test "private socket is single-use and only its owned namespace is removed" do
    assert {:ok, namespace} = ProviderLauncher.prepare()
    assert {:ok, directory} = File.stat(namespace.namespace)
    assert Bitwise.band(directory.mode, 0o777) == 0o700
    assert {:ok, socket} = File.stat(namespace.socket_path)
    assert Bitwise.band(socket.mode, 0o777) == 0o600
    :gen_tcp.close(namespace.listener)
    assert :ok = ProviderLauncher.abandon(namespace.namespace)
    refute File.exists?(namespace.namespace)
  end

  test "guard alone owns descriptors and proves cooperative child cessation", %{root: root} do
    {owned, nonce, namespace, pid_path} = launch(root, false)
    assert eventually(fn -> File.regular?(pid_path) end)
    child = pid_path |> File.read!() |> String.trim() |> String.to_integer()
    assert File.read!(Path.join(root, "descriptors")) == "closed\n"
    :gen_tcp.close(namespace.listener)
    stop = String.duplicate("b", 32)
    assert Port.command(owned.port, "stop:#{nonce}:#{stop}:2000\n")
    expected = "cleanup_complete:#{nonce}:#{stop}"
    assert_receive {port, {:data, {:eol, ^expected}}}, 2_000
    assert port == owned.port
    assert_receive {^port, {:exit_status, 0}}, 500
    refute process_alive?(child)
    refute File.exists?(namespace.namespace)
  end

  test "Port owner death leaves the independent guard to stop its child", %{root: root} do
    parent = self()

    owner =
      spawn(fn ->
        Process.flag(:trap_exit, true)
        {owned, _nonce, namespace, pid_path} = launch(root, false)
        send(parent, {:owned, owned, namespace, pid_path})

        receive do
          :hold -> :ok
        end
      end)

    assert_receive {:owned, _owned, namespace, pid_path}, 2_000
    assert eventually(fn -> File.regular?(pid_path) end)
    child = pid_path |> File.read!() |> String.trim() |> String.to_integer()
    assert process_alive?(child)
    Process.exit(owner, :kill)
    assert eventually(fn -> not process_alive?(child) end, 3_000)
    assert eventually(fn -> not File.exists?(namespace.namespace) end)
  end

  test "a TERM-resistant child is killed without a false cleanup acknowledgement", %{root: root} do
    {owned, nonce, namespace, pid_path} = launch(root, true)
    assert eventually(fn -> File.regular?(pid_path) end)
    child = pid_path |> File.read!() |> String.trim() |> String.to_integer()
    :gen_tcp.close(namespace.listener)
    stop = String.duplicate("c", 32)
    assert Port.command(owned.port, "stop:#{nonce}:#{stop}:200\n")
    expected = "cleanup_complete:#{nonce}:#{stop}"
    port = owned.port
    refute_receive {^port, {:data, {:eol, ^expected}}}, 400
    assert eventually(fn -> not process_alive?(child) end)
    refute File.exists?(namespace.namespace)
  end

  test "repeated termination during cleanup cannot disarm the owned watchdog", %{root: root} do
    {owned, nonce, namespace, pid_path} = launch(root, true)
    assert eventually(fn -> File.regular?(pid_path) end)
    child = pid_path |> File.read!() |> String.trim() |> String.to_integer()
    port = owned.port
    monitor = :erlang.monitor(:port, port)
    :gen_tcp.close(namespace.listener)
    stop = String.duplicate("e", 32)
    deadline = System.monotonic_time(:millisecond) + 2_000 + 100

    try do
      assert Port.command(port, "stop:#{nonce}:#{stop}:2000\n")

      assert eventually(fn ->
               cleanup_sleeper_present?(owned, child) and not File.exists?(namespace.namespace)
             end)

      refute File.exists?(namespace.namespace)
      assert process_alive?(child)
      assert {_, 0} = System.cmd("/bin/kill", ["-TERM", "--", "-#{owned.carrier}"])
      observed = terminal_observation(port, monitor, deadline)
      members = live_group(owned.carrier)
      IO.inspect(%{repeated_cleanup_term: observed, live_group: members}, limit: :infinity)
      assert is_integer(observed.exit_status)
      assert observed.down
      refute observed.exit_status == 0
      refute Enum.any?(observed.lines, &String.starts_with?(&1, "cleanup_complete:"))
      assert members == []
      refute process_alive?(child)
      refute File.exists?(namespace.namespace)
    after
      dispose_owned_group(owned)
      :erlang.demonitor(monitor, [:flush])
    end
  end

  test "namespace cleanup failure cannot acknowledge after an interrupted wait", %{root: root} do
    {owned, nonce, namespace, pid_path} = launch(root, false)
    assert eventually(fn -> File.regular?(pid_path) end)
    child = pid_path |> File.read!() |> String.trim() |> String.to_integer()
    obstacle = Path.join(namespace.namespace, "owned-test-obstacle")
    File.write!(obstacle, "namespace removal must fail\n")
    port = owned.port
    monitor = :erlang.monitor(:port, port)
    :gen_tcp.close(namespace.listener)
    stop = String.duplicate("f", 32)
    deadline = System.monotonic_time(:millisecond) + 2_000 + 100

    try do
      assert Port.command(port, "stop:#{nonce}:#{stop}:2000\n")

      assert eventually(fn ->
               cleanup_sleeper_present?(owned, child) and
                 not File.exists?(namespace.socket_path)
             end)

      # The obstacle makes rmdir fail, independently of signal timing. Repeated
      # guard-only TERM interrupts its failure wait without cancelling the timer.
      signals = interrupt_owned_guard(owned, 5)
      observed = terminal_observation(port, monitor, deadline)
      members = live_group(owned.carrier)

      IO.inspect(
        %{namespace_failure: observed, guard_signals: signals, live_group: members},
        limit: :infinity
      )

      assert 0 in signals
      assert is_integer(observed.exit_status)
      assert observed.down
      refute Enum.any?(observed.lines, &String.starts_with?(&1, "cleanup_complete:"))
      refute observed.exit_status == 0
      assert members == []
      refute process_alive?(child)
      assert File.read!(obstacle) == "namespace removal must fail\n"
      refute File.exists?(namespace.socket_path)
    after
      dispose_owned_group(owned)
      :erlang.demonitor(monitor, [:flush])
      File.rm!(obstacle)
      File.rmdir!(namespace.namespace)
    end
  end

  defp launch(root, stubborn) do
    script = Path.join(root, "worker.sh")
    pid_path = Path.join(root, "pid")
    descriptors = Path.join(root, "descriptors")
    trap = if stubborn, do: "trap '' TERM", else: "trap - TERM"

    File.write!(script, """
    #{trap}
    if (printf forbidden >&4) 2>/dev/null || (: <&3) 2>/dev/null; then
      printf 'open\\n' > '#{descriptors}'
    else
      printf 'closed\\n' > '#{descriptors}'
    fi
    printf '%s\\n' "$$" > '#{pid_path}'
    while :; do /bin/sleep 1; done
    """)

    assert {:ok, namespace} = ProviderLauncher.prepare()
    nonce = String.duplicate("a", 64)

    configuration = %{
      interpreter_path: "/bin/sh",
      worker_path: script,
      build_manifest_sha256: String.duplicate("d", 64)
    }

    assert {:ok, owned} =
             ProviderLauncher.start(namespace, configuration, nonce, 2_000, 9_999_999_999_999)

    port = owned.port
    assert_receive {^port, {:data, {:eol, ready}}}, 2_000
    assert String.starts_with?(ready, "ready:#{nonce}:#{owned.carrier}:")
    ["ready", ^nonce, _carrier, guard, _namespace] = String.split(ready, ":", parts: 5)
    assert Port.command(port, "run:#{nonce}\n")
    {Map.put(owned, :guard, String.to_integer(guard)), nonce, namespace, pid_path}
  end

  # The fault is delivered only after a real timer and its sleeping child exist.
  # Process inspection synchronizes the schedule; it never supplies a cleanup verdict.
  defp cleanup_sleeper_present?(owned, child) do
    members = live_group(owned.carrier)

    Enum.any?(members, fn timer ->
      timer.ppid == owned.guard and timer.pid != child and
        Enum.any?(members, &(&1.ppid == timer.pid))
    end)
  end

  defp live_group(group) do
    {table, 0} =
      System.cmd("/bin/ps", ["-ax", "-o", "pid=", "-o", "ppid=", "-o", "pgid=", "-o", "stat="])

    for line <- String.split(table, "\n", trim: true),
        [pid, parent, pgid, state] = String.split(String.trim(line)),
        String.to_integer(pgid) == group,
        not String.starts_with?(state, "Z"),
        do: %{pid: String.to_integer(pid), ppid: String.to_integer(parent), state: state}
  end

  defp terminal_observation(
         port,
         monitor,
         deadline,
         observed \\ %{exit_status: nil, down: false, lines: []}
       ) do
    if is_integer(observed.exit_status) and observed.down do
      observed
    else
      receive do
        {^port, {:data, {:eol, line}}} ->
          terminal_observation(port, monitor, deadline, %{
            observed
            | lines: observed.lines ++ [line]
          })

        {^port, {:exit_status, status}} ->
          terminal_observation(port, monitor, deadline, %{observed | exit_status: status})

        {:DOWN, ^monitor, :port, ^port, _reason} ->
          terminal_observation(port, monitor, deadline, %{observed | down: true})
      after
        max(deadline - System.monotonic_time(:millisecond), 0) -> observed
      end
    end
  end

  defp interrupt_owned_guard(_owned, 0), do: []

  defp interrupt_owned_guard(owned, remaining) do
    if Port.info(owned.port, :os_pid) == {:os_pid, owned.carrier} and
         Enum.any?(
           live_group(owned.carrier),
           &(&1.pid == owned.guard and &1.ppid == owned.carrier)
         ) do
      {_output, status} = System.cmd("/bin/kill", ["-s", "TERM", Integer.to_string(owned.guard)])
      Process.sleep(10)
      [status | interrupt_owned_guard(owned, remaining - 1)]
    else
      []
    end
  end

  # Recovery is fixture disposal, never evidence that the guard met its bound.
  # A still-open direct Port correlates the group with this exact launch.
  # External procps kill needs its short signal form for a negative group;
  # that parser differs from the production shell builtin's explicit -s form.
  defp dispose_owned_group(owned) do
    if Port.info(owned.port, :os_pid) == {:os_pid, owned.carrier} do
      _ = System.cmd("/bin/kill", ["-KILL", "--", "-#{owned.carrier}"])
      assert eventually(fn -> live_group(owned.carrier) == [] end)
    end

    if Port.info(owned.port) != nil, do: Port.close(owned.port)
  end

  defp process_alive?(pid) do
    case System.cmd("/bin/ps", ["-p", Integer.to_string(pid), "-o", "stat="]) do
      {state, 0} -> not String.starts_with?(String.trim(state), "Z")
      {_output, 1} -> false
      other -> flunk("process observation unavailable: #{inspect(other)}")
    end
  end

  defp eventually(fun, timeout \\ 1_000) do
    until = System.monotonic_time(:millisecond) + timeout
    await(fun, until)
  end

  defp await(fun, until) do
    cond do
      fun.() ->
        true

      System.monotonic_time(:millisecond) >= until ->
        false

      true ->
        receive do
        after
          10 -> await(fun, until)
        end
    end
  end
end
