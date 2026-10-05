defmodule LoopexComposition.RestoreIOTest do
  use ExUnit.Case, async: false

  alias LoopexComposition.Restore.IO, as: RestoreIO

  setup do
    root = Path.join(System.tmp_dir!(), "loopex-restore-io-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "real publish synchronizes closes renames and reads back before exact actor joins", context do
    path = Path.join(context.root, "record")
    bytes = :erlang.term_to_binary(%{"record" => "value"}, [:deterministic])
    owned = launch({:publish, path, path <> ".tmp", bytes, 0o600, :absent}, :stat)
    {result, events} = drive(owned)
    assert {:joined, {:ok, digest}, evidence} = result
    assert digest == hash(bytes)
    assert evidence.opens == evidence.closes
    assert evidence.opens == 3
    assert evidence.stop == :complete
    kinds = issued_kinds(events)
    assert Enum.count(kinds, &(&1 == :file_sync)) == 1
    assert Enum.count(kinds, &(&1 == :directory_sync)) == 1
    assert index(kinds, :write) < index(kinds, :file_sync)
    assert index(kinds, :file_sync) < index(kinds, :rename)
    assert index(kinds, :rename) < index(kinds, :directory_sync)
    assert index(kinds, :directory_sync) < index(kinds, :read)
    assert File.read!(path) == bytes
    assert Bitwise.band(File.stat!(path).mode, 0o7777) == 0o600
    refute File.exists?(path <> ".tmp")
    joined(owned)
  end

  test "exact existing bytes are resynced without a new file or rename", context do
    path = Path.join(context.root, "record")
    File.write!(path, "retained")
    inode = File.stat!(path).inode
    owned = launch({:publish, path, path <> ".tmp", "retained", 0o640, :absent}, :stat)
    {result, events} = drive(owned)
    assert {:joined, {:ok, _}, %{opens: opens, closes: opens}} = result
    refute :write in issued_kinds(events)
    refute :rename in issued_kinds(events)
    assert :file_sync in issued_kinds(events)
    assert :directory_sync in issued_kinds(events)
    assert File.stat!(path).inode == inode
    refute File.exists?(path <> ".tmp")
    joined(owned)
  end

  test "generation replacement compares exact original bytes and preserves the selected mode", context do
    path = Path.join(context.root, "generation")
    File.write!(path, "original")
    owned = launch({:publish, path, path <> ".tmp", "candidate", 0o400, "original"}, :stat)
    assert {{:joined, {:ok, _}, %{opens: opens, closes: opens}}, _} = drive(owned)
    assert File.read!(path) == "candidate"
    assert Bitwise.band(File.stat!(path).mode, 0o7777) == 0o400
    joined(owned)
    conflicting = launch({:publish, path, path <> ".tmp", "another", 0o400, "original"}, :stat)
    assert {{:joined, {:error, :io_error}, _}, events} = drive(conflicting)
    refute :write in issued_kinds(events)
    refute :rename in issued_kinds(events)
    assert File.read!(path) == "candidate"
    joined(conflicting)
  end

  test "bounded read refuses excess and symlinks with no descriptor left open", context do
    path = Path.join(context.root, "record")
    File.write!(path, "bounded")
    owned = launch({:read, path, 7}, :stat)
    assert {{:joined, {:ok, "bounded"}, %{opens: 1, closes: 1}}, _} = drive(owned)
    joined(owned)
    excess = launch({:read, path, 6}, :stat)
    assert {{:joined, {:error, :io_error}, %{opens: 0, closes: 0}}, _} = drive(excess)
    joined(excess)
    link = Path.join(context.root, "link")
    File.ln_s!(path, link)
    symlink = launch({:read, link, 7}, :stat)
    assert {{:joined, {:error, :io_error}, %{opens: 0, closes: 0}}, _} = drive(symlink)
    joined(symlink)
  end

  test "actual rename failure retains uncertain payload bytes but proves all descriptor closes", context do
    directory = Path.join(context.root, "parent")
    moved = Path.join(context.root, "moved")
    File.mkdir!(directory)
    path = Path.join(directory, "record")
    owned = launch({:publish, path, path <> ".tmp", "value", 0o600, :absent}, :rename)
    assert_receive {:restore_io, guardian, worker, reference, {:issued, id, :rename}}, 1_000
    assert {guardian, worker, reference} == {owned.guardian, owned.worker, owned.reference}
    File.rename!(directory, moved)
    send(guardian, {:proceed, reference, id})
    assert {{:joined, {:error, :io_error}, %{opens: 1, closes: 1}}, events} = drive(owned)
    refute :directory_sync in issued_kinds(events)
    assert File.read!(Path.join(moved, "record.tmp")) == "value"
    refute File.exists?(Path.join(moved, "record"))
    joined(owned)
  end

  test "readback mismatch uses actual changed file data rather than an injected reply", context do
    path = Path.join(context.root, "record")
    owned = launch({:publish, path, path <> ".tmp", "value", 0o600, :absent}, :read)
    assert_receive {:restore_io, guardian, worker, reference, {:issued, id, :read}}, 1_000
    assert {guardian, worker, reference} == {owned.guardian, owned.worker, owned.reference}
    File.write!(path, "other")
    send(guardian, {:proceed, reference, id})
    assert {{:joined, {:error, :io_error}, %{opens: opens, closes: opens}}, _} = drive(owned)
    assert File.read!(path) == "other"
    joined(owned)
  end

  test "deadline before the first raw call stops payload and captures the original cleanup cutoff", context do
    path = Path.join(context.root, "record")
    File.write!(path, "retained")
    owned = launch({:read, path, 8}, :stat, 100, 5)
    assert_receive {:restore_io, _, _, _, {:issued, _, :stat}}, 1_000
    {result, events} = drive(owned, false)
    assert {:joined, {:error, :deadline}, %{opens: 0, closes: 0, operations: 0}} = result
    assert {:stopping, :deadline, stop, cleanup} = Enum.find(events, &match?({:stopping, _, _, _}, &1))
    assert stop == owned.work_cutoff
    assert cleanup == stop + 10_000
    joined(owned)
  end

  test "caller death cooperatively closes an actually opened descriptor and joins the worker", context do
    path = Path.join(context.root, "record")
    File.write!(path, "retained")
    owned = launch({:read, path, 8}, :read)
    assert_receive {:restore_io, _, _, _, {:issued, _, :read}}, 1_000
    Process.exit(owned.caller, :kill)
    assert_receive {:DOWN, monitor, :process, caller, :killed}, 1_000
    assert {monitor, caller} == {owned.caller_monitor, owned.caller}
    assert_receive {:restore_io, _, _, _, {:terminal, {:joined, {:error, :caller_lost}, %{opens: 1, closes: 1}}}}, 1_000
    joined(owned, false)
    assert File.read!(path) == "retained"
  end

  test "guardian loss signals its linked descriptor owner and never reports a joined result", context do
    path = Path.join(context.root, "record")
    File.write!(path, "retained")
    owned = launch({:read, path, 8}, :read)
    assert_receive {:restore_io, _, _, _, {:issued, _, :read}}, 1_000
    assert {:links, links} = Process.info(owned.worker, :links)
    assert owned.guardian in links
    Process.exit(owned.guardian, :kill)
    assert {result, _events} = drive(owned, false)
    assert result == {:unconfirmed, :guardian_lost}
    guardian = owned.guardian
    gm = owned.guardian_monitor
    worker = owned.worker
    wm = owned.worker_monitor
    caller = owned.caller
    cm = owned.caller_monitor
    assert_receive {:DOWN, ^gm, :process, ^guardian, :killed}, 1_000
    assert_receive {:DOWN, ^wm, :process, ^worker, :killed}, 1_000
    assert_receive {:DOWN, ^cm, :process, ^caller, :normal}, 1_000
    assert File.read!(path) == "retained"
  end

  test "guardian death during an actual blocking raw open remains unconfirmed after later worker DOWN", context do
    path = Path.join(context.root, "record")
    File.write!(path, "retained")
    owned = launch({:read, path, 8}, :open)
    assert_receive {:restore_io, guardian, worker, reference, {:issued, id, {:open, _token}}}, 1_000
    assert {guardian, worker, reference} == {owned.guardian, owned.worker, owned.reference}
    # The fault replaces the already-statted regular path with an actual FIFO.
    # No IO result is substituted: the pinned raw open must really be blocked.
    File.rm!(path)
    assert {_, 0} = System.cmd("mkfifo", [path])
    send(guardian, {:proceed, reference, id})
    try do
      await_raw_open(worker, System.monotonic_time(:millisecond) + 1_000)
      Process.exit(guardian, :kill)
      assert {result, _events} = drive(owned, false)
      assert result == {:unconfirmed, :guardian_lost}
    after
      release_fifo(path)
    end
    gm = owned.guardian_monitor
    wm = owned.worker_monitor
    caller = owned.caller
    cm = owned.caller_monitor
    assert_receive {:DOWN, ^gm, :process, ^guardian, :killed}, 1_000
    assert_receive {:DOWN, ^wm, :process, ^worker, :killed}, 1_000
    assert_receive {:DOWN, ^cm, :process, ^caller, :normal}, 1_000
  end

  @tag :long_bound
  test "a killed suspended raw-descriptor owner remains unconfirmed after its exact DOWN", context do
    path = Path.join(context.root, "record")
    File.write!(path, "retained")
    owned = launch({:read, path, 8}, :read, 1_000, 5)
    assert_receive {:restore_io, _, _, _, {:issued, _, :read}}, 1_000
    :erlang.suspend_process(owned.worker)
    Process.exit(owned.worker, :kill)
    assert_receive {:DOWN, monitor, :process, worker, :killed}, 1_000
    assert {monitor, worker} == {owned.worker_monitor, owned.worker}
    {result, events} = drive(owned, false)
    assert {:unconfirmed, :descriptor_unclosed} = result
    assert {:stopping, :worker_unjoined, stop, cleanup} = Enum.find(events, &match?({:stopping, _, _, _}, &1))
    assert cleanup - stop == 10_000
    assert System.monotonic_time(:millisecond) >= cleanup
    guardian = owned.guardian
    gm = owned.guardian_monitor
    caller = owned.caller
    cm = owned.caller_monitor
    assert_receive {:DOWN, ^gm, :process, ^guardian, :normal}, 1_000
    assert_receive {:DOWN, ^cm, :process, ^caller, :normal}, 1_000
    assert File.read!(path) == "retained"
  end

  test "invalid work or operation requests launch no IO actors", context do
    assert {:error, :invalid_io_request} = RestoreIO.run({:read, Path.join(context.root, "record"), 1}, %{"work_ms" => 0, "cleanup_grace_ms" => 5}, probe: self())
    assert {:error, :invalid_io_request} = RestoreIO.run({:read, "relative", 1}, limits(1_000, 5), probe: self())
    refute_receive {:restore_io, _, _, _, _}
  end

  defp launch(operation, pause, work_ms \\ 1_000, grace \\ 100) do
    parent = self()
    tag = make_ref()
    {caller, caller_monitor} = spawn_monitor(fn -> send(parent, {tag, RestoreIO.run(operation, limits(work_ms, grace), probe: parent, pause_at: pause)}) end)
    assert_receive {:restore_io, guardian, worker, reference, {:installed, admitted, work_cutoff}}, 1_000
    guardian_monitor = Process.monitor(guardian)
    worker_monitor = Process.monitor(worker)
    on_exit(fn ->
      for actor <- [caller, guardian, worker] do
        monitor = Process.monitor(actor)
        Process.exit(actor, :kill)
        assert_receive {:DOWN, ^monitor, :process, ^actor, _}, 1_000
      end
    end)
    assert work_cutoff == admitted + work_ms
    %{caller: caller, caller_monitor: caller_monitor, guardian: guardian, guardian_monitor: guardian_monitor, worker: worker, worker_monitor: worker_monitor, reference: reference, tag: tag, pause: pause}
    |> Map.put(:work_cutoff, work_cutoff)
  end
  defp drive(owned, proceed \\ true, events \\ []) do
    guardian = owned.guardian
    worker = owned.worker
    reference = owned.reference
    tag = owned.tag
    receive do
      {:restore_io, ^guardian, ^worker, ^reference, event} ->
        case event do
          {:issued, id, kind} when proceed ->
            name = if is_tuple(kind), do: elem(kind, 0), else: kind
            if name == owned.pause, do: send(guardian, {:proceed, reference, id})
          _ -> :ok
        end
        drive(owned, proceed, [event | events])
      {^tag, result} -> {result, Enum.reverse(events)}
    after
      11_000 -> flunk("owned raw IO did not finish inside the captured work/cleanup bound")
    end
  end
  defp joined(owned, caller? \\ true) do
    worker = owned.worker
    wm = owned.worker_monitor
    guardian = owned.guardian
    gm = owned.guardian_monitor
    assert_receive {:DOWN, ^wm, :process, ^worker, :normal}, 1_000
    assert_receive {:DOWN, ^gm, :process, ^guardian, :normal}, 1_000
    if caller? do
      caller = owned.caller
      cm = owned.caller_monitor
      assert_receive {:DOWN, ^cm, :process, ^caller, :normal}, 1_000
    end
  end
  defp issued_kinds(events), do: for({:issued, _, kind} <- events, do: if(is_tuple(kind), do: elem(kind, 0), else: kind))
  defp index(values, value), do: Enum.find_index(values, &(&1 == value))
  defp hash(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
  defp limits(work, grace), do: %{"work_ms" => work, "cleanup_grace_ms" => grace}
  defp await_raw_open(worker, cutoff) do
    parent = self()
    reference = make_ref()
    {inspector, monitor} = spawn_monitor(fn -> send(parent, {reference, observe_raw_open(worker, cutoff)}) end)
    try do
      receive do
        {^reference, :observed} -> :ok
        {^reference, {:unavailable, observation}} -> flunk("actual raw FIFO open was not observed in open_nif: #{inspect(observation)}")
      after
        max(0, cutoff - System.monotonic_time(:millisecond)) -> flunk("raw-open inspection did not return before its captured cutoff")
      end
    after
      Process.exit(inspector, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^inspector, _}, 1_000
    end
  end
  defp observe_raw_open(worker, cutoff) do
    case Process.info(worker, :current_function) do
      {:current_function, {:prim_file, :open_nif, 2}} -> :observed
      observation ->
        if System.monotonic_time(:millisecond) >= cutoff do
          {:unavailable, observation}
        else
          receive do
          after
            1 -> observe_raw_open(worker, cutoff)
          end
        end
    end
  end
  defp release_fifo(path) do
    # Python is an existing development prerequisite. O_NONBLOCK guarantees
    # that this exact joined release subprocess cannot hang if the reader died.
    assert {_, 0} = System.cmd("python3", ["-c", "import os,sys; fd=os.open(sys.argv[1],os.O_RDWR|os.O_NONBLOCK); os.close(fd)", path])
  end
end
