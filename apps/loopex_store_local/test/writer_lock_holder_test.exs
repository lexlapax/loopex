defmodule Loopex.Store.Local.WriterLockHolderTest do
  @moduledoc false

  use ExUnit.Case, async: false

  alias Loopex.Store.Local

  # A refused open exits with the reason it refused for, and this process is
  # linked to it by `start_link/1`. Trapping is what lets the case read the
  # refusal rather than inherit it.
  setup do
    previous = Process.flag(:trap_exit, true)
    on_exit(fn -> Process.flag(:trap_exit, previous) end)
    :ok
  end

  # Concept: a store's writer marker is broken for a holder that is gone, and
  # for no other reason. Who is asking, and what else that caller holds, decides
  # nothing.
  #
  # Technical depth: `:recover_stale_writer` used to be the caller's assertion,
  # and the shipped command made it after taking a lock only `loopex` processes
  # take. An embedded runtime on the same state root takes no such lock, so the
  # assertion was true about nothing it was asserting, and a live writer's marker
  # was deleted -- two Stores appending to one transaction log. These cases fix
  # the decision to the marker's own recorded holder: an operating-system process
  # the operating system no longer has, or a Store process that died inside this
  # still-running VM. Everything else refuses, including a marker carrying no
  # identity to check and an identifier the operating system has since reused.

  test "a live holder in this VM refuses a recovering opener and keeps its marker" do
    path = store_path()
    {:ok, holder} = Local.start_link(path: path)
    marker = path <> ".writer"
    bytes = File.read!(marker)

    assert {:error, {:store_writer_active, ^marker}} =
             Local.start_link(path: path, recover_stale_writer: true)

    assert File.read!(marker) == bytes, "recovery removed a live writer's marker"
    assert Process.alive?(holder)
    stop(holder)
  end

  test "a live holder in another operating-system process refuses a recovering opener" do
    path = store_path()
    {port, _os_pid} = hold_store(path)
    marker = path <> ".writer"
    bytes = File.read!(marker)

    assert {:error, {:store_writer_active, ^marker}} =
             Local.start_link(path: path, recover_stale_writer: true)

    assert File.read!(marker) == bytes, "recovery evicted a live embedder"

    # The refusal was issued while that holder was still writing, not merely
    # while its VM was still running: it answers a Store call afterwards.
    assert :answered = ping(port)
    close(port)
  end

  test "a holder killed with SIGKILL leaves a marker its successor recovers" do
    path = store_path()
    {port, os_pid} = hold_store(path)
    marker = path <> ".writer"
    dead = File.read!(marker)
    kill(port, os_pid)

    assert File.regular?(marker), "the killed holder left no marker to recover"
    assert {:error, {:store_writer_active, ^marker}} = Local.start_link(path: path)

    assert {:ok, successor} = Local.start_link(path: path, recover_stale_writer: true)
    refute File.read!(marker) == dead, "the successor reused the dead holder's marker"
    stop(successor)
  end

  test "a Store killed inside this VM leaves a marker this VM recovers" do
    path = store_path()
    {:ok, holder} = Local.start_link(path: path)
    marker = path <> ".writer"
    down = Process.monitor(holder)
    Process.exit(holder, :kill)
    assert_receive {:DOWN, ^down, :process, ^holder, :killed}, 5_000

    assert File.regular?(marker)
    assert {:error, {:store_writer_active, ^marker}} = Local.start_link(path: path)

    assert {:ok, successor} = Local.start_link(path: path, recover_stale_writer: true)
    stop(successor)
  end

  test "a v1 marker carrying no identity is never recovered automatically" do
    path = store_path()
    marker = path <> ".writer"
    bytes = "loopex_store_writer_v1\n" <> String.duplicate("0", 64) <> "\n"
    File.write!(marker, bytes)

    assert {:error, {:store_writer_active, ^marker}} = Local.start_link(path: path)

    assert {:error, {:store_writer_active, ^marker}} =
             Local.start_link(path: path, recover_stale_writer: true)

    assert File.read!(marker) == bytes, "a marker with no identity was recovered anyway"
  end

  test "a marker whose recorded identifier was reused is recovered despite a live process" do
    path = store_path()
    marker = path <> ".writer"
    {:ok, holder} = Local.start_link(path: path)
    [version, os_pid, _incarnation, _process, nonce, ""] = String.split(File.read!(marker), "\n")
    assert os_pid == System.pid()
    stop(holder)

    # This process is alive and its identifier is ours, so only the recorded
    # start identity can say the holder is gone -- which is exactly what an
    # operating system that reissued an identifier leaves behind.
    reused = Base.url_encode64("Thu Jan  1 00:00:00 1970", padding: false)
    alive = List.to_string(:erlang.pid_to_list(self()))
    File.write!(marker, Enum.join([version, os_pid, reused, alive, nonce], "\n") <> "\n")

    assert {:ok, successor} = Local.start_link(path: path, recover_stale_writer: true)
    stop(successor)
  end

  defp stop(pid) do
    down = Process.monitor(pid)
    Process.exit(pid, :shutdown)
    assert_receive {:DOWN, ^down, :process, ^pid, _reason}, 5_000
  end

  defp store_path do
    root = System.fetch_env!("LOOPEX_HOME")
    directory = Path.join(root, "writer-lock-holder-#{System.unique_integer([:positive])}")
    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf(directory) end)
    Path.join(directory, "store.log")
  end

  # Concept: a real second operating-system process holding the store, because
  # that is the shape the defect had and no in-VM stand-in has it.
  #
  # Technical depth: the child opens the same Store this VM would and then
  # answers a Store call for every line it is sent, so a refusal here can be
  # shown to have been issued against a holder that was still serving.
  defp hold_store(path) do
    executable = System.find_executable("elixir") || raise "elixir executable unavailable"

    code = """
    {:ok, store} = Loopex.Store.Local.start_link(path: #{inspect(path)})
    IO.puts("HOLDING")

    Enum.each(IO.stream(:stdio, :line), fn _line ->
      _answered = Loopex.Store.Local.load_events(store, "session", 0, 1)
      IO.puts("ALIVE")
    end)
    """

    arguments =
      Enum.flat_map(:code.get_path(), fn dir -> ["-pa", List.to_string(dir)] end) ++ ["-e", code]

    port =
      Port.open(
        {:spawn_executable, String.to_charlist(executable)},
        [
          :binary,
          :exit_status,
          :use_stdio,
          :stderr_to_stdout,
          :hide,
          :line,
          args: Enum.map(arguments, &String.to_charlist/1)
        ]
      )

    {:os_pid, os_pid} = Port.info(port, :os_pid)

    on_exit(fn ->
      System.cmd("/bin/kill", ["-KILL", Integer.to_string(os_pid)],
        stderr_to_stdout: true,
        into: ""
      )
    end)

    await(port, "HOLDING", 60_000)
    {port, os_pid}
  end

  defp ping(port) do
    true = Port.command(port, "ping\n")
    await(port, "ALIVE", 20_000)
    :answered
  end

  defp kill(port, os_pid) do
    {_output, 0} = System.cmd("/bin/kill", ["-KILL", Integer.to_string(os_pid)])

    receive do
      {^port, {:exit_status, _status}} -> :ok
    after
      20_000 -> flunk("the killed holder never exited")
    end
  end

  defp close(port) do
    Port.close(port)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp await(port, prefix, bound) do
    receive do
      {^port, {:data, {_flag, line}}} ->
        if String.starts_with?(line, prefix), do: :ok, else: await(port, prefix, bound)

      {^port, {:exit_status, status}} ->
        flunk("the store holder exited (#{status}) before saying #{prefix}")
    after
      bound -> flunk("the store holder never said #{prefix}")
    end
  end
end
