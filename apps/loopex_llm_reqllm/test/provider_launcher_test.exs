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
    assert Port.command(port, "run:#{nonce}\n")
    {owned, nonce, namespace, pid_path}
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
