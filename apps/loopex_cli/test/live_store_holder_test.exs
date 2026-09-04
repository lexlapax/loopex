defmodule LoopexCli.LiveStoreHolderTest do
  @moduledoc false

  use ExUnit.Case, async: false

  # Concept: a command asked to work on a state root another live runtime is
  # writing is refused, and told so in words.
  #
  # Technical depth: the placement lock is taken only by `loopex` processes. An
  # embedded runtime on the same state root takes none, so a fresh `loopex
  # resume` against that root proved nothing whatever about the embedder and
  # still asserted `recover_stale_writer: true` -- which deleted the live
  # writer's marker and opened a second Store on one transaction log. The
  # observable symptom was this command reaching `session_unknown`, having
  # evicted a runtime that was serving. The store now decides on the marker's
  # own recorded holder, so the command is refused while that holder lives and
  # gets past the marker once it does not. Both are proved here against a real
  # second operating-system process, because an in-VM stand-in does not have the
  # shape the defect had.

  test "a state root held by a live embedder refuses the command instead of evicting it" do
    {root, workspace} = roots()
    {port, os_pid} = hold_root(root, workspace)
    marker = Path.join(root, "store.log.writer")
    bytes = File.read!(marker)

    assert {:error, message} = resume(root, workspace)
    assert :ok = LoopexCli.release_placement()

    assert message =~ "another process is already writing this state root's store"
    assert message =~ "--state-root"
    assert File.read!(marker) == bytes, "the command evicted a live embedder's writer marker"

    # The refusal is not a refusal of the root: once that holder is gone the
    # same command gets past the marker it left and reaches the truthful
    # unknown-session answer, which is what the defect reported while the
    # embedder was still running.
    kill(port, os_pid)

    assert {:error, :session_unknown} = resume(root, workspace)
    assert :ok = LoopexCli.release_placement()
    refute File.read!(marker) == bytes, "the command reused the dead holder's marker"
  end

  defp resume(root, workspace) do
    LoopexCli.dispatch([
      "resume",
      "s_missing",
      "--policy",
      "allow-all",
      "--state-root",
      root,
      "--workspace",
      workspace
    ])
  end

  # Concept: a real embedded runtime, in its own operating-system process,
  # holding the durable store of this state root.
  defp hold_root(root, workspace) do
    executable = System.find_executable("elixir") || raise "elixir executable unavailable"

    code = """
    defmodule Holder do
      @behaviour Loopex.Policy
      @impl Loopex.Policy
      def decide(_request), do: {:allow, nil}
    end

    {:ok, _runtime} =
      LoopexComposition.start(
        runtime_id: "embedder",
        state_root: #{inspect(root)},
        workspace: #{inspect(workspace)},
        policy: Holder
      )

    IO.puts("HOLDING")
    Process.sleep(:infinity)
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

  defp kill(port, os_pid) do
    {_output, 0} = System.cmd("/bin/kill", ["-KILL", Integer.to_string(os_pid)])

    receive do
      {^port, {:exit_status, _status}} -> :ok
    after
      20_000 -> flunk("the embedder never exited")
    end
  end

  defp await(port, prefix, bound) do
    receive do
      {^port, {:data, {_flag, line}}} ->
        if String.starts_with?(line, prefix), do: :ok, else: await(port, prefix, bound)

      {^port, {:exit_status, status}} ->
        flunk("the embedder exited (#{status}) before saying #{prefix}")
    after
      bound -> flunk("the embedder never said #{prefix}")
    end
  end

  defp roots do
    unique = System.unique_integer([:positive])
    root = Path.join(System.tmp_dir!(), "loopex-live-holder-#{unique}")
    workspace = Path.join(System.tmp_dir!(), "loopex-live-holder-ws-#{unique}")
    File.mkdir_p!(root)
    File.mkdir_p!(workspace)

    on_exit(fn ->
      File.rm_rf(root)
      File.rm_rf(workspace)
    end)

    {root, workspace}
  end
end
