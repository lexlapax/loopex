# Concept: the shared session fixture loads under an explicit temporary home.
# Technical depth: its guard runs during require, before case setup. Restore the
# host environment immediately; the fixture starts no actors while loading.
fixture_home =
  Path.join(System.tmp_dir!(), "restore-store-load-#{System.unique_integer([:positive])}")

File.mkdir_p!(fixture_home)
prior_home = System.get_env("LOOPEX_HOME")
System.put_env("LOOPEX_HOME", fixture_home)

try do
  Code.require_file("../../loopex/test/support/m1_runtime_helper.exs", __DIR__)
  Code.require_file("../../loopex/test/support/agent_loop_helper.exs", __DIR__)
after
  if prior_home,
    do: System.put_env("LOOPEX_HOME", prior_home),
    else: System.delete_env("LOOPEX_HOME")

  File.rm_rf!(fixture_home)
end

defmodule LoopexComposition.RestoreIOTest do
  use ExUnit.Case, async: false

  alias LoopexComposition.Restore.IO, as: RestoreIO
  alias Loopex.ConfiguredGenesisFixture
  alias Loopex.Executor.Local.{Ledger, RestoreCodec}
  alias Loopex.Runtime.SessionState
  alias Loopex.Store
  alias Loopex.Store.Local.{Log, State}
  alias LoopexComposition.ResourcePacks

  setup do
    root = Path.join(System.tmp_dir!(), "loopex-restore-io-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "accepted long work and cleanup limits retain their captured cutoffs", context do
    path = Path.join(context.root, "record")
    File.write!(path, "retained")
    long = 1_099_511_627_776

    for {work, grace} <- [{long, 5}, {500, long}, {long, long}] do
      owned = launch({:read, path, 8}, :stat, work, grace)
      assert {{:joined, {:ok, "retained"}, evidence}, events} = drive(owned)
      assert evidence.work_cutoff == owned.work_cutoff

      assert {:stopping, :complete, stop, cleanup} =
               Enum.find(events, &match?({:stopping, :complete, _, _}, &1))

      assert cleanup == stop + max(10_000, grace + 2_000)
      assert evidence.cleanup_cutoff == cleanup
      assert evidence.opens == 1
      assert evidence.closes == 1
      joined(owned)
    end
  end

  test "real publish synchronizes closes renames and reads back before exact actor joins",
       context do
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

  test "generation replacement compares exact original bytes and preserves the selected mode",
       context do
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

  test "actual rename failure retains uncertain payload bytes but proves all descriptor closes",
       context do
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

  test "deadline before the first raw call stops payload and captures the original cleanup cutoff",
       context do
    path = Path.join(context.root, "record")
    File.write!(path, "retained")
    owned = launch({:read, path, 8}, :stat, 100, 5)
    assert_receive {:restore_io, _, _, _, {:issued, _, :stat}}, 1_000
    {result, events} = drive(owned, false)
    assert {:joined, {:error, :deadline}, %{opens: 0, closes: 0, operations: 0}} = result

    assert {:stopping, :deadline, stop, cleanup} =
             Enum.find(events, &match?({:stopping, _, _, _}, &1))

    assert stop == owned.work_cutoff
    assert cleanup == stop + 10_000
    joined(owned)
  end

  test "caller death cooperatively closes an actually opened descriptor and joins the worker",
       context do
    path = Path.join(context.root, "record")
    File.write!(path, "retained")
    owned = launch({:read, path, 8}, :read)
    assert_receive {:restore_io, _, _, _, {:issued, _, :read}}, 1_000
    Process.exit(owned.caller, :kill)
    assert_receive {:DOWN, monitor, :process, caller, :killed}, 1_000
    assert {monitor, caller} == {owned.caller_monitor, owned.caller}

    assert_receive {:restore_io, _, _, _,
                    {:terminal, {:joined, {:error, :caller_lost}, %{opens: 1, closes: 1}}}},
                   1_000

    joined(owned, false)
    assert File.read!(path) == "retained"
  end

  test "guardian loss signals its linked descriptor owner and never reports a joined result",
       context do
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

  test "guardian death during an actual blocking raw open remains unconfirmed after later worker DOWN",
       context do
    path = Path.join(context.root, "record")
    File.write!(path, "retained")
    owned = launch({:read, path, 8}, :open)

    assert_receive {:restore_io, guardian, worker, reference, {:issued, id, {:open, _token}}},
                   1_000

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
  test "a killed suspended raw-descriptor owner remains unconfirmed after its exact DOWN",
       context do
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

    assert {:stopping, :worker_unjoined, stop, cleanup} =
             Enum.find(events, &match?({:stopping, _, _, _}, &1))

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

  test "manifest includes root hidden empty and prior metadata with exact modes and hashes",
       context do
    root = physical_root(context.root)
    File.chmod!(root, 0o750)
    File.mkdir!(Path.join(root, "empty"))
    File.chmod!(Path.join(root, "empty"), 0o1750)
    File.mkdir_p!(Path.join(root, ".loopex-restore/0001"))
    File.write!(Path.join(root, ".loopex-restore/0001/intent"), "prior immutable bytes")
    File.write!(Path.join(root, ".hidden"), "")
    File.chmod!(Path.join(root, ".hidden"), 0o640)
    content = :binary.copy(<<1, 2, 3, 4>>, 40_000)
    File.write!(Path.join(root, "stream"), content)
    File.chmod!(Path.join(root, "stream"), 0o4750)

    paths = [
      ".",
      ".hidden",
      ".loopex-restore",
      ".loopex-restore/0001",
      ".loopex-restore/0001/intent",
      "empty",
      "stream"
    ]

    expected = expected_manifest(root, paths)
    owned = launch({:manifest, root, byte_size(content) + 21}, :list)
    assert {{:joined, {:ok, bytes}, evidence}, events} = drive(owned)
    assert bytes == expected
    assert evidence.opens == 3
    assert evidence.closes == 3
    assert Enum.count(issued_kinds(events), &(&1 == :hash_read)) >= 6
    assert File.read!(Path.join(root, "stream")) == content
    joined(owned)
  end

  test "manifest accepts zero total for an empty root and refuses a smaller regular-byte cap",
       context do
    root = physical_root(context.root)

    for cap <- [0, 18_446_744_073_709_551_615] do
      empty = launch({:manifest, root, cap}, :list)
      assert {{:joined, {:ok, bytes}, %{opens: 0, closes: 0}}, _} = drive(empty)
      assert bytes == expected_manifest(root, ["."])
      joined(empty)
    end

    File.write!(Path.join(root, "data"), "12345")
    bounded = launch({:manifest, root, 5}, :list)
    assert {{:joined, {:ok, bytes}, %{opens: 1, closes: 1}}, _} = drive(bounded)
    assert bytes == expected_manifest(root, [".", "data"])
    joined(bounded)
    excess = launch({:manifest, root, 4}, :list)
    assert {{:joined, {:error, :io_error}, %{opens: 0, closes: 0}}, _} = drive(excess)
    joined(excess)
  end

  test "manifest preserves distinct UTF-8 filename bytes and sums every regular file",
       context do
    root = physical_root(context.root)
    names = ["λ", "😀", "z", ".hidden"]
    for name <- names, do: File.write!(Path.join(root, name), "12")
    owned = launch({:manifest, root, 8}, :list)
    assert {{:joined, {:ok, bytes}, %{opens: 4, closes: 4}}, _} = drive(owned)
    assert bytes == expected_manifest(root, ["." | names])
    joined(owned)
    excess = launch({:manifest, root, 7}, :list)
    assert {{:joined, {:error, :io_error}, %{opens: 3, closes: 3}}, _} = drive(excess)
    joined(excess)
  end

  test "manifest rejects symlink entries and symlink ancestors without opening data",
       context do
    root = physical_root(context.root)
    File.ln_s!(root, Path.join(root, "alias"))
    entry = launch({:manifest, root, 0}, :list)
    assert {{:joined, {:error, :io_error}, %{opens: 0, closes: 0}}, _} = drive(entry)
    joined(entry)
    File.rm!(Path.join(root, "alias"))
    File.mkdir!(Path.join(root, "directory"))
    File.ln_s!(Path.join(root, "directory"), Path.join(root, "alias"))
    ancestor = launch({:manifest, Path.join(root, "alias"), 0}, :manifest_stat)
    assert {{:joined, {:error, :io_error}, %{opens: 0, closes: 0}}, _} = drive(ancestor)
    joined(ancestor)
  end

  test "manifest refuses actual FIFOs and regular hardlinks",
       context do
    root = physical_root(context.root)
    path = Path.join(root, "node")
    assert {_, 0} = System.cmd("mkfifo", [path])
    special = launch({:manifest, root, 0}, :list)
    assert {{:joined, {:error, :io_error}, %{opens: 0, closes: 0}}, _} = drive(special)
    joined(special)
    File.rm!(path)
    File.write!(path, "retained")
    File.ln!(path, Path.join(root, "owner.lock"))
    linked = launch({:manifest, root, 16}, :list)
    assert {{:joined, {:error, :io_error}, %{opens: 0, closes: 0}}, _} = drive(linked)
    joined(linked)
    File.rm!(Path.join(root, "owner.lock"))
    File.rm!(path)
  end

  test "manifest refuses same-size namespace substitution against the opened descriptor",
       context do
    root = physical_root(context.root)
    path = Path.join(root, "data")
    File.write!(path, "original")
    owned = launch({:manifest, root, 8}, :descriptor_stat)
    {id, _} = paused_operation(owned, :descriptor_stat)
    File.rename!(path, Path.join(root, "previous"))
    File.write!(path, "replaced")
    send(owned.guardian, {:proceed, owned.reference, id})
    assert {{:joined, {:error, :io_error}, %{opens: 1, closes: 1}}, _} = drive(owned)
    joined(owned)
  end

  test "manifest refuses physical size mode and type changes during hashing", context do
    root = physical_root(context.root)
    path = Path.join(root, "data")

    for change <- [:shorter, :longer, :mode, :symlink] do
      File.write!(path, "original")
      File.chmod!(path, 0o600)
      owned = launch({:manifest, root, 8}, :hash_read)
      {id, _} = paused_operation(owned, :hash_read)

      case change do
        :shorter ->
          File.write!(path, "short")

        :longer ->
          File.write!(path, "original plus")

        :mode ->
          File.chmod!(path, 0o640)

        :symlink ->
          File.rename!(path, Path.join(root, "previous"))
          File.ln_s!(Path.join(root, "previous"), path)
      end

      send(owned.guardian, {:proceed, owned.reference, id})
      assert {{:joined, {:error, :io_error}, %{opens: 1, closes: 1}}, _} = drive(owned)
      joined(owned)
      File.rm!(path)
      if change == :symlink, do: File.rm!(Path.join(root, "previous"))
    end
  end

  test "manifest detects a changed directory even after its original child was hashed",
       context do
    root = physical_root(context.root)
    File.write!(Path.join(root, "data"), "retained")
    owned = launch({:manifest, root, 8}, :close)
    {id, _} = paused_operation(owned, :close)
    File.write!(Path.join(root, ".new"), "")
    send(owned.guardian, {:proceed, owned.reference, id})
    assert {{:joined, {:error, :io_error}, %{opens: 1, closes: 1}}, _} = drive(owned)
    joined(owned)
  end

  test "manifest raw open failure joins without inventing a descriptor acknowledgement",
       context do
    root = physical_root(context.root)
    path = Path.join(root, "data")
    File.write!(path, "retained")
    owned = launch({:manifest, root, 8}, :open)
    {id, _} = paused_operation(owned, :open)
    File.rm!(path)
    send(owned.guardian, {:proceed, owned.reference, id})
    assert {{:joined, {:error, :io_error}, %{opens: 0, closes: 0}}, events} = drive(owned)

    assert {:acknowledged, ^id, {:open, _}, :error} =
             Enum.find(events, &match?({:acknowledged, ^id, {:open, _}, :error}, &1))

    joined(owned)
  end

  test "manifest caller loss closes its exact opened file without a successful manifest",
       context do
    root = physical_root(context.root)
    File.write!(Path.join(root, "data"), "retained")
    owned = launch({:manifest, root, 8}, :hash_read)
    paused_operation(owned, :hash_read)
    Process.exit(owned.caller, :kill)
    assert_receive {:DOWN, monitor, :process, caller, :killed}, 1_000
    assert {monitor, caller} == {owned.caller_monitor, owned.caller}

    assert_receive {:restore_io, _, _, _,
                    {:terminal, {:joined, {:error, :caller_lost}, %{opens: 1, closes: 1}}}},
                   1_000

    joined(owned, false)
  end

  test "manifest guardian loss preserves uncertainty and joins the exact linked descriptor owner",
       context do
    root = physical_root(context.root)
    File.write!(Path.join(root, "data"), "retained")
    owned = launch({:manifest, root, 8}, :hash_read)
    paused_operation(owned, :hash_read)
    Process.exit(owned.guardian, :kill)
    assert {{:unconfirmed, :guardian_lost}, _} = drive(owned, false)
    guardian = owned.guardian
    gm = owned.guardian_monitor
    worker = owned.worker
    wm = owned.worker_monitor
    caller = owned.caller
    cm = owned.caller_monitor
    assert_receive {:DOWN, ^gm, :process, ^guardian, :killed}, 1_000
    assert_receive {:DOWN, ^wm, :process, ^worker, :killed}, 1_000
    assert_receive {:DOWN, ^cm, :process, ^caller, :normal}, 1_000
    assert File.read!(Path.join(root, "data")) == "retained"
  end

  @tag :long_bound
  test "manifest worker DOWN cannot substitute for its unacknowledged descriptor close",
       context do
    root = physical_root(context.root)
    File.write!(Path.join(root, "data"), "retained")
    owned = launch({:manifest, root, 8}, :hash_read, 1_000, 5)
    paused_operation(owned, :hash_read)
    :erlang.suspend_process(owned.worker)
    Process.exit(owned.worker, :kill)
    assert_receive {:DOWN, monitor, :process, worker, :killed}, 1_000
    assert {monitor, worker} == {owned.worker_monitor, owned.worker}
    assert {{:unconfirmed, :descriptor_unclosed}, events} = drive(owned, false)

    assert {:stopping, :worker_unjoined, stop, cleanup} =
             Enum.find(events, &match?({:stopping, _, _, _}, &1))

    assert cleanup == stop + 10_000
    assert System.monotonic_time(:millisecond) >= cleanup
    guardian = owned.guardian
    gm = owned.guardian_monitor
    caller = owned.caller
    cm = owned.caller_monitor
    assert_receive {:DOWN, ^gm, :process, ^guardian, :normal}, 1_000
    assert_receive {:DOWN, ^cm, :process, ^caller, :normal}, 1_000
  end

  test "manifest native entry-count refusal precedes child traversal on an actual excessive list",
       context do
    root = physical_root(context.root)
    create_listing(root, 65_536, 5)
    assert length(File.ls!(root)) == 65_536
    owned = launch({:manifest, root, 0}, :list)
    assert {{:joined, {:error, :io_error}, %{opens: 0, closes: 0}}, events} = drive(owned)
    assert Enum.count(issued_kinds(events), &(&1 == :list)) == 1
    joined(owned)
  end

  test "manifest exact encoded-byte ceiling refuses an actual sub-count listing before hashing",
       context do
    root = physical_root(context.root)
    create_listing(root, 20_000, 200)
    names = File.ls!(root)
    assert length(names) == 20_000
    # Independently measure the actual deterministic ETF directory lower bound.
    # If even this smaller representation exceeds 4 MiB, regular fields cannot fit.
    mode = Bitwise.band(File.stat!(root).mode, 0o7777)

    entries = [
      %{"path" => ".", "kind" => "directory", "mode" => mode, "size" => 0, "sha256" => nil}
      | Enum.map(names, fn name ->
          %{"path" => name, "kind" => "directory", "mode" => 0, "size" => 0, "sha256" => nil}
        end)
    ]

    assert byte_size(
             :erlang.term_to_binary(
               ["loopex:current-state-manifest:v1", entries],
               [:deterministic]
             )
           ) > 4_194_304

    owned = launch({:manifest, root, 0}, :list)
    assert {{:joined, {:error, :io_error}, %{opens: 0, closes: 0}}, events} = drive(owned)
    assert Enum.count(issued_kinds(events), &(&1 == :list)) == 1
    joined(owned)
  end

  test "invalid work or operation requests launch no IO actors", context do
    assert {:error, :invalid_io_request} =
             RestoreIO.run(
               {:read, Path.join(context.root, "record"), 1},
               %{"work_ms" => 0, "cleanup_grace_ms" => 5},
               probe: self()
             )

    assert {:error, :invalid_io_request} =
             RestoreIO.run({:read, "relative", 1}, limits(1_000, 5), probe: self())

    for path <- [
          context.root <> "/invalid-" <> <<255>>,
          context.root <> "/nul-" <> <<0>>,
          "relative",
          "/" <> String.duplicate("x", 8_192)
        ] do
      assert {:error, :invalid_io_request} =
               RestoreIO.run({:manifest, path, 0}, limits(1_000, 5), probe: self())
    end

    for cap <- [-1, 18_446_744_073_709_551_616, "0"] do
      assert {:error, :invalid_io_request} =
               RestoreIO.run({:manifest, context.root, cap}, limits(1_000, 5), probe: self())
    end

    refute_receive {:restore_io, _, _, _, _}
  end

  test "Store audit recovers every session and retains the complete private replay map",
       context do
    fixture = store_fixture(context.root, 3)
    [first | _] = fixture.ids
    fixture = append_pending(fixture, first)

    {:ok, orphan} =
      Store.advance_owner("absent-session", "owner", "orphan-tx", 0, 0, "orphan-owner")

    fixture = append_transaction(fixture, orphan)
    operation = store_operation(fixture)
    owned = launch(operation, :store_decode)
    assert {{:joined, {:ok, result}, evidence}, events} = drive(owned)
    assert result.store == fixture.state
    assert map_size(result.sessions) == 3
    assert evidence.opens == 1
    assert evidence.closes == 1
    assert map_size(result.store.runtime_commands) > 0
    assert map_size(result.store.creation_rows) > 0
    assert map_size(result.store.orphan_resolutions) > 0
    assert [_pending] = SessionState.pending_work(result.sessions[first])
    assert Enum.count(issued_kinds(events), &(&1 == :session_recover)) == 3

    for {id, session} <- fixture.state.sessions do
      assert {:ok, expected} = SessionState.recover(id, session.records, session.events)
      assert result.sessions[id] == expected
    end

    assert File.read!(fixture.path) == fixture.bytes
    joined(owned)
  end

  test "an existing empty Store file audits as an empty complete history", context do
    fixture = store_fixture(context.root, 1)
    File.write!(fixture.path, <<>>)
    owned = launch(store_operation(%{fixture | bytes: <<>>}), :store_decode)

    assert {{:joined, {:ok, %{store: store, sessions: sessions}}, %{opens: 1, closes: 1}}, _} =
             drive(owned)

    assert sessions == %{}
    assert store == State.new()
    assert File.read!(fixture.path) == <<>>
    joined(owned)
  end

  test "the physical whole-log ceiling refuses a real oversized file before open or decode",
       context do
    fixture = store_fixture(context.root, 1)
    size = 268_435_457

    assert {digest, 0} =
             System.cmd("python3", [
               "-c",
               "import os,sys,hashlib; p=sys.argv[1]; n=int(sys.argv[2]); f=open(p,'wb'); f.truncate(n); f.close(); h=hashlib.sha256(); f=open(p,'rb'); [h.update(b) for b in iter(lambda:f.read(65536),b'')]; f.close(); print(h.hexdigest())",
               fixture.path,
               Integer.to_string(size)
             ])

    digest = String.trim_trailing(digest, "\n")
    root_info = File.lstat!(fixture.root)
    directory_info = File.lstat!(Path.dirname(fixture.path))
    info = File.lstat!(fixture.path)
    assert info.size == size

    entries = [
      %{
        "path" => ".",
        "kind" => "directory",
        "mode" => Bitwise.band(root_info.mode, 0o7777),
        "size" => 0,
        "sha256" => nil
      },
      %{
        "path" => "store",
        "kind" => "directory",
        "mode" => Bitwise.band(directory_info.mode, 0o7777),
        "size" => 0,
        "sha256" => nil
      },
      %{
        "path" => "store/history.log",
        "kind" => "regular",
        "mode" => Bitwise.band(info.mode, 0o7777),
        "size" => size,
        "sha256" => digest
      }
    ]

    {:ok, manifest} =
      Loopex.Executor.Local.RestoreCodec.encode(:manifest, [
        "loopex:current-state-manifest:v1",
        entries
      ])

    declaration = %{"relative_path" => "store/history.log", "sha256" => digest}
    owned = launch({:audit_store, fixture.root, declaration, manifest}, :store_manifest)
    assert {{:joined, {:error, :io_error}, %{opens: 0, closes: 0}}, events} = drive(owned)
    refute :store_decode in issued_kinds(events)
    assert File.stat!(fixture.path).size == size
    joined(owned)
  end

  test "Store-valid invalid second-session history refuses after the first session recovers",
       context do
    fixture = store_fixture(context.root, 1)
    bad = Map.put(ConfiguredGenesisFixture.genesis([]), :kind, "session_genesis_v2")
    [first] = fixture.ids

    transaction =
      Enum.find_value(1..100, fn number ->
        {:ok, transaction} = Store.create_session("audit-runtime", "create-bad-#{number}", bad)
        {:new, next, _frame, _outcome} = State.prepare(fixture.state, transaction)
        [second] = Map.keys(next.sessions) -- [first]
        if second > first, do: transaction
      end)

    assert transaction
    fixture = append_transaction(fixture, transaction)
    assert {:ok, replayed} = State.replay(fixture.frames)
    assert replayed == fixture.state
    assert map_size(replayed.sessions) == 2
    [first, second] = Enum.sort(Map.keys(replayed.sessions))
    assert {:ok, _} = SessionState.recover(first, replayed.sessions[first].records, [])
    assert {:error, _} = SessionState.recover(second, replayed.sessions[second].records, [])
    owned = launch(store_operation(fixture), :session_recover)
    assert {{:joined, {:error, :history_invalid}, %{opens: 1, closes: 1}}, events} = drive(owned)
    assert Enum.count(issued_kinds(events), &(&1 == :session_recover)) == 2
    assert File.read!(fixture.path) == fixture.bytes
    joined(owned)
  end

  test "complete frames with an invalid transaction order refuse before session recovery",
       context do
    fixture = store_fixture(context.root, 2)
    bytes = Enum.map_join(Enum.reverse(fixture.frames), &encoded_frame/1)
    File.write!(fixture.path, bytes)
    fixture = %{fixture | bytes: bytes}
    assert {:ok, _, :complete} = Log.decode_bytes(bytes)
    assert {:error, _} = State.replay(Enum.reverse(fixture.frames))
    owned = launch(store_operation(fixture), :store_replay)
    assert {{:joined, {:error, :history_invalid}, %{opens: 1, closes: 1}}, events} = drive(owned)
    refute :session_recover in issued_kinds(events)
    assert File.read!(fixture.path) == bytes
    joined(owned)
  end

  test "torn and corrupt actual Store files refuse without repairing any byte", context do
    fixture = store_fixture(context.root, 1)

    for bytes <- [fixture.bytes <> binary_part(fixture.bytes, 0, 7), fixture.bytes <> "corrupt"] do
      File.write!(fixture.path, bytes)
      owned = launch(store_operation(%{fixture | bytes: bytes}), :store_decode)

      assert {{:joined, {:error, :history_invalid}, %{opens: 1, closes: 1}}, events} =
               drive(owned)

      refute :store_replay in issued_kinds(events)
      assert File.read!(fixture.path) == bytes
      joined(owned)
    end
  end

  test "missing Store files do not become empty logs", context do
    fixture = store_fixture(context.root, 1)
    operation = store_operation(fixture)
    File.rm!(fixture.path)
    owned = launch(operation, :store_manifest)
    assert {{:joined, {:error, :io_error}, %{opens: 0, closes: 0}}, events} = drive(owned)
    refute :store_decode in issued_kinds(events)
    refute File.exists?(fixture.path)
    joined(owned)
  end

  test "declarations require manifest membership and the exact retained digest", context do
    fixture = store_fixture(context.root, 1)
    {:audit_store, root, declaration, manifest} = store_operation(fixture)

    for changed <- [
          %{declaration | "sha256" => String.duplicate("0", 64)},
          %{declaration | "relative_path" => "store/absent.log"},
          Map.put(declaration, "extra", "undeclared")
        ] do
      owned = launch({:audit_store, root, changed, manifest}, :store_declaration)
      assert {{:joined, {:error, reason}, %{opens: 0, closes: 0}}, events} = drive(owned)
      assert reason in [:io_error, :history_invalid]
      refute :store_decode in issued_kinds(events)
      joined(owned)
    end
  end

  test "Store size mode and same-size content disagreement refuse against the captured manifest",
       context do
    fixture = store_fixture(context.root, 1)
    operation = store_operation(fixture)
    mode = Bitwise.band(File.stat!(fixture.path).mode, 0o7777)

    for change <- [:size, :mode, :content] do
      File.write!(fixture.path, fixture.bytes)
      File.chmod!(fixture.path, mode)

      case change do
        :size -> File.write!(fixture.path, fixture.bytes <> <<0>>)
        :mode -> File.chmod!(fixture.path, Bitwise.bxor(mode, 0o100))
        :content -> File.write!(fixture.path, :binary.copy(<<0>>, byte_size(fixture.bytes)))
      end

      owned = launch(operation, :store_manifest)
      assert {{:joined, {:error, :io_error}, evidence}, events} = drive(owned)
      assert evidence.opens == evidence.closes
      refute :store_decode in issued_kinds(events)
      joined(owned)
    end
  end

  test "Store hardlinks symlinks and symlink ancestors refuse before opening", context do
    fixture = store_fixture(context.root, 1)
    operation = store_operation(fixture)
    other = Path.join(context.root, "other")
    File.ln!(fixture.path, other)
    owned = launch(operation, :store_manifest)
    assert {{:joined, {:error, :io_error}, %{opens: 0, closes: 0}}, _} = drive(owned)
    joined(owned)
    File.rm!(other)
    File.rename!(fixture.path, other)
    File.ln_s!(other, fixture.path)
    owned = launch(operation, :store_manifest)
    assert {{:joined, {:error, :io_error}, %{opens: 0, closes: 0}}, _} = drive(owned)
    joined(owned)
    File.rm!(fixture.path)
    File.rename!(other, fixture.path)
    directory = Path.dirname(fixture.path)
    moved = directory <> "-moved"
    File.rename!(directory, moved)
    File.ln_s!(moved, directory)
    owned = launch(operation, :store_manifest)
    assert {{:joined, {:error, :io_error}, %{opens: 0, closes: 0}}, _} = drive(owned)
    joined(owned)
  end

  test "an opened Store replaced with identical bytes refuses and closes the old descriptor",
       context do
    fixture = store_fixture(context.root, 1)
    owned = launch(store_operation(fixture), :descriptor_stat)
    {id, _} = paused_operation(owned, :descriptor_stat)
    replacement = fixture.path <> ".replacement"
    File.write!(replacement, fixture.bytes)
    File.chmod!(replacement, Bitwise.band(File.stat!(fixture.path).mode, 0o7777))
    File.rename!(replacement, fixture.path)
    send(owned.guardian, {:proceed, owned.reference, id})
    assert {{:joined, {:error, :io_error}, %{opens: 1, closes: 1}}, events} = drive(owned)
    refute :store_decode in issued_kinds(events)
    joined(owned)
  end

  test "ancestor replacement after reading cannot publish recovered Store facts", context do
    fixture = store_fixture(context.root, 1)
    owned = launch(store_operation(fixture), :store_replay)
    {id, _} = paused_operation(owned, :store_replay)
    directory = Path.dirname(fixture.path)
    moved = directory <> "-moved"
    File.rename!(directory, moved)
    File.mkdir!(directory)
    File.rename!(Path.join(moved, "history.log"), fixture.path)
    send(owned.guardian, {:proceed, owned.reference, id})
    assert {{:joined, {:error, :io_error}, %{opens: 1, closes: 1}}, _} = drive(owned)
    joined(owned)
  end

  test "Store semantic work stops at the original deadline with descriptors already closed",
       context do
    fixture = store_fixture(context.root, 1)
    owned = launch(store_operation(fixture), :store_decode, 500)
    paused_operation(owned, :store_decode)
    assert {{:joined, {:error, :deadline}, %{opens: 1, closes: 1}}, events} = drive(owned, false)
    refute :store_replay in issued_kinds(events)
    joined(owned)
  end

  test "caller loss during Store descriptor validation closes and joins the owned worker",
       context do
    fixture = store_fixture(context.root, 1)
    owned = launch(store_operation(fixture), :descriptor_stat)
    {id, _} = paused_operation(owned, :descriptor_stat)
    Process.exit(owned.caller, :kill)
    assert_receive {:DOWN, monitor, :process, caller, :killed}, 1_000
    assert monitor == owned.caller_monitor
    assert caller == owned.caller

    assert_receive {:restore_io, guardian, worker, reference, {:stopping, :caller_lost, _, _}},
                   1_000

    assert {guardian, worker, reference} == {owned.guardian, owned.worker, owned.reference}
    send(owned.guardian, {:proceed, owned.reference, id})
    # The guardian publishes only to the lost caller; its probe retains the join.
    assert_receive {:restore_io, guardian, worker, reference,
                    {:terminal, {:joined, {:error, :caller_lost}, %{opens: 1, closes: 1}}}},
                   1_000

    assert {guardian, worker, reference} == {owned.guardian, owned.worker, owned.reference}
    joined(owned, false)
  end

  test "guardian loss during Store semantic recovery never publishes private facts", context do
    fixture = store_fixture(context.root, 1)
    owned = launch(store_operation(fixture), :session_recover)
    paused_operation(owned, :session_recover)
    Process.exit(owned.guardian, :kill)
    assert_receive {tag, {:unconfirmed, :guardian_lost}}, 1_000
    assert tag == owned.tag
    assert_receive {:DOWN, guardian_monitor, :process, guardian, :killed}, 1_000
    assert {guardian_monitor, guardian} == {owned.guardian_monitor, owned.guardian}
    assert_receive {:DOWN, worker_monitor, :process, worker, :killed}, 1_000
    assert {worker_monitor, worker} == {owned.worker_monitor, owned.worker}
    assert_receive {:DOWN, caller_monitor, :process, caller, :normal}, 1_000
    assert {caller_monitor, caller} == {owned.caller_monitor, owned.caller}
    assert File.read!(fixture.path) == fixture.bytes
  end

  test "Resource audit preserves actual current writer records for both Git widths", context do
    for width <- [40, 64] do
      fixture = resource_fixture(context.root, width)

      for kind <- [:manifest, :provenance] do
        record = fixture.records[kind]
        bytes = File.read!(fixture.paths[kind])
        mode = File.stat!(fixture.paths[kind]).mode
        owned = launch(resource_operation(fixture, kind), :resource_decode)
        assert {{:joined, {:ok, ^record}, %{opens: 1, closes: 1}}, events} = drive(owned)
        kinds = issued_kinds(events)
        assert Enum.count(kinds, &(&1 == :read)) >= 3
        assert index(kinds, :close) < index(kinds, :resource_decode)
        assert index(kinds, :resource_digest) < index(kinds, :resource_decode)
        assert File.read!(fixture.paths[kind]) == bytes
        assert File.stat!(fixture.paths[kind]).mode == mode
        assert byte_size(fixture.records.provenance["commit"]) == width
        joined(owned)
      end
    end
  end

  test "actual local Resource manifests retain nil provenance without a fallback", context do
    root = physical_root(context.root)
    directory = Path.join([root, ".agents", "skills", "review"])
    File.mkdir_p!(directory)

    File.write!(
      Path.join(directory, "SKILL.md"),
      "---\nname: review\ndescription: Review.\n---\nbody\n"
    )

    File.write!(Path.join(directory, "opaque.bin"), <<0, 255, 128>>)

    assert {:ok, %{manifest: manifest}} =
             ResourcePacks.read_directories([directory], workspace: root)

    [pack] = manifest["packs"]
    assert pack["origin"] == nil
    assert pack["commit"] == nil
    assert pack["tree_digest"] == nil
    state = Path.join(root, "state")
    assert {:ok, digest} = ResourcePacks.retain(manifest, state)

    {:joined, {:ok, inventory}, _} =
      RestoreIO.run({:manifest, state, 1_048_576}, limits(1_000, 100))

    path = Path.join([state, "resource-packs", "manifests", digest <> ".etf"])
    bytes = File.read!(path)
    owned = launch({:audit_resource, state, :manifest, digest, inventory}, :resource_decode)
    assert {{:joined, {:ok, ^manifest}, %{opens: 1, closes: 1}}, _} = drive(owned)
    joined(owned)
    refute File.exists?(Path.join([state, "resource-packs", "provenance"]))
    identity = resource_content_identity(pack)

    missing =
      launch({:audit_resource, state, :provenance, identity, inventory}, :resource_manifest)

    assert {{:joined, {:error, :io_error}, %{opens: 0, closes: 0}}, events} = drive(missing)
    refute :resource_decode in issued_kinds(events)
    assert File.read!(path) == bytes
    joined(missing)
  end

  test "Resource selection requires canonical membership and every parent directory", context do
    fixture = resource_fixture(context.root)

    for kind <- [:manifest, :provenance] do
      {:audit_resource, root, ^kind, identity, manifest} = resource_operation(fixture, kind)
      [domain, entries] = :erlang.binary_to_term(manifest, [:safe])
      relative = Path.relative_to(fixture.paths[kind], root)
      parent = Path.dirname(relative)

      alternatives = [
        Enum.reject(entries, &(&1["path"] == relative)),
        Enum.reject(entries, &(&1["path"] == parent)),
        Enum.map(entries, fn entry ->
          if entry["path"] == relative,
            do: %{entry | "kind" => "directory", "size" => 0, "sha256" => nil},
            else: entry
        end),
        Enum.map(entries, fn entry ->
          if entry["path"] == parent,
            do: %{entry | "mode" => Bitwise.bxor(entry["mode"], 0o100)},
            else: entry
        end)
      ]

      for changed <- alternatives do
        bytes = :erlang.term_to_binary([domain, changed], [:deterministic])
        owned = launch({:audit_resource, root, kind, identity, bytes}, :resource_manifest)
        assert {{:joined, {:error, reason}, %{opens: 0, closes: 0}}, events} = drive(owned)
        assert reason in [:io_error, :history_invalid]
        refute :resource_decode in issued_kinds(events)
        joined(owned)
      end
    end
  end

  test "Resource canonical filenames must bind the actual decoded identity", context do
    fixture = resource_fixture(context.root)
    wrong = String.duplicate("0", 64)

    for kind <- [:manifest, :provenance] do
      path = Path.join(Path.dirname(fixture.paths[kind]), wrong <> ".etf")
      File.cp!(fixture.paths[kind], path)

      {:joined, {:ok, inventory}, _} =
        RestoreIO.run({:manifest, fixture.root, 1_048_576}, limits(1_000, 100))

      owned = launch({:audit_resource, fixture.root, kind, wrong, inventory}, :resource_decode)
      assert {{:joined, {:error, :history_invalid}, %{opens: 1, closes: 1}}, _} = drive(owned)
      assert File.read!(path) == File.read!(fixture.paths[kind])
      joined(owned)
      File.rm!(path)

      for identity <- [String.duplicate("A", 64), "../" <> wrong, nil] do
        assert RestoreIO.run(
                 {:audit_resource, fixture.root, kind, identity, inventory},
                 limits(1_000, 100)
               ) ==
                 {:error, :invalid_io_request}
      end
    end

    assert RestoreIO.run({:audit_resource, fixture.root, :other, wrong, <<>>}, limits(1_000, 100)) ==
             {:error, :invalid_io_request}
  end

  test "each Resource role refuses its real first over-cap file before opening", context do
    for {kind, ceiling} <- [manifest: 72_081_510, provenance: 1_126_241] do
      fixture = resource_fixture(context.root)
      {:audit_resource, root, ^kind, identity, manifest} = resource_operation(fixture, kind)
      path = fixture.paths[kind]
      size = ceiling + 1

      assert {digest, 0} =
               System.cmd("python3", [
                 "-c",
                 "import sys,hashlib; p=sys.argv[1]; n=int(sys.argv[2]); f=open(p,'wb'); f.truncate(n); f.close(); h=hashlib.sha256(); f=open(p,'rb'); [h.update(b) for b in iter(lambda:f.read(65536),b'')]; f.close(); print(h.hexdigest())",
                 path,
                 Integer.to_string(size)
               ])

      digest = String.trim_trailing(digest, "\n")
      assert File.stat!(path).size == size
      [domain, entries] = :erlang.binary_to_term(manifest, [:safe])
      relative = Path.relative_to(path, root)

      entries =
        Enum.map(entries, fn entry ->
          if entry["path"] == relative,
            do: %{entry | "size" => size, "sha256" => digest},
            else: entry
        end)

      manifest = :erlang.term_to_binary([domain, entries], [:deterministic])
      owned = launch({:audit_resource, root, kind, identity, manifest}, :resource_manifest)
      assert {{:joined, {:error, :io_error}, %{opens: 0, closes: 0}}, events} = drive(owned)
      refute :read in issued_kinds(events)
      refute :resource_decode in issued_kinds(events)
      assert File.stat!(path).size == size
      joined(owned)
    end
  end

  test "Resource size mode and same-size content must match the physical inventory", context do
    fixture = resource_fixture(context.root)

    for kind <- [:manifest, :provenance] do
      operation = resource_operation(fixture, kind)
      path = fixture.paths[kind]
      bytes = File.read!(path)
      mode = Bitwise.band(File.stat!(path).mode, 0o7777)

      for change <- [:size, :mode, :content, :digest] do
        File.write!(path, bytes)
        File.chmod!(path, mode)

        altered =
          case change do
            :size ->
              File.write!(path, bytes <> <<0>>)
              operation

            :mode ->
              File.chmod!(path, Bitwise.bxor(mode, 0o100))
              operation

            :content ->
              File.write!(path, :binary.copy(<<0>>, byte_size(bytes)))
              operation

            :digest ->
              {:audit_resource, root, ^kind, identity, manifest} = operation
              [domain, entries] = :erlang.binary_to_term(manifest, [:safe])
              relative = Path.relative_to(path, root)

              entries =
                Enum.map(entries, fn entry ->
                  if entry["path"] == relative,
                    do: %{entry | "sha256" => String.duplicate("0", 64)},
                    else: entry
                end)

              {:audit_resource, root, kind, identity,
               :erlang.term_to_binary([domain, entries], [:deterministic])}
          end

        owned = launch(altered, :resource_manifest)
        assert {{:joined, {:error, :io_error}, evidence}, events} = drive(owned)
        assert evidence.opens == evidence.closes
        refute :resource_decode in issued_kinds(events)
        joined(owned)
      end

      File.write!(path, bytes)
      File.chmod!(path, mode)
    end
  end

  test "Resource hardlinks symlinks and symlink ancestors refuse before opening", context do
    for kind <- [:manifest, :provenance] do
      fixture = resource_fixture(context.root)
      operation = resource_operation(fixture, kind)
      path = fixture.paths[kind]
      other = Path.join(fixture.root, "other")
      File.ln!(path, other)
      owned = launch(operation, :resource_manifest)
      assert {{:joined, {:error, :io_error}, %{opens: 0, closes: 0}}, _} = drive(owned)
      joined(owned)
      File.rm!(other)
      File.rename!(path, other)
      File.ln_s!(other, path)
      owned = launch(operation, :resource_manifest)
      assert {{:joined, {:error, :io_error}, %{opens: 0, closes: 0}}, _} = drive(owned)
      joined(owned)
      File.rm!(path)
      File.rename!(other, path)
      directory = Path.dirname(path)
      moved = directory <> "-moved"
      File.rename!(directory, moved)
      File.ln_s!(moved, directory)
      owned = launch(operation, :resource_manifest)
      assert {{:joined, {:error, :io_error}, %{opens: 0, closes: 0}}, _} = drive(owned)
      joined(owned)
    end
  end

  test "Resource descriptor identity refuses replacement with identical writer bytes", context do
    fixture = resource_fixture(context.root)

    for kind <- [:manifest, :provenance] do
      path = fixture.paths[kind]
      owned = launch(resource_operation(fixture, kind), :descriptor_stat)
      {id, _} = paused_operation(owned, :descriptor_stat)
      replacement = path <> ".replacement"
      File.write!(replacement, File.read!(path))
      File.chmod!(replacement, Bitwise.band(File.stat!(path).mode, 0o7777))
      File.rename!(replacement, path)
      send(owned.guardian, {:proceed, owned.reference, id})
      assert {{:joined, {:error, :io_error}, %{opens: 1, closes: 1}}, events} = drive(owned)
      refute :resource_decode in issued_kinds(events)
      joined(owned)
    end
  end

  test "Resource semantic completion revalidates both file and ancestor identities", context do
    for kind <- [:manifest, :provenance], change <- [:file, :ancestor] do
      fixture = resource_fixture(context.root)
      path = fixture.paths[kind]
      owned = launch(resource_operation(fixture, kind), :resource_decode)
      {id, _} = paused_operation(owned, :resource_decode)

      case change do
        :file ->
          replacement = path <> ".replacement"
          File.write!(replacement, File.read!(path))
          File.chmod!(replacement, Bitwise.band(File.stat!(path).mode, 0o7777))
          File.rename!(replacement, path)

        :ancestor ->
          directory = Path.dirname(path)
          moved = directory <> "-moved"
          File.rename!(directory, moved)
          File.mkdir!(directory)
          File.rename!(Path.join(moved, Path.basename(path)), path)
      end

      send(owned.guardian, {:proceed, owned.reference, id})
      assert {{:joined, {:error, :io_error}, %{opens: 1, closes: 1}}, _} = drive(owned)
      joined(owned)
    end
  end

  test "physical Resource equality does not admit malformed or alternate retained formats",
       context do
    fixture = resource_fixture(context.root)

    for kind <- [:manifest, :provenance] do
      record = fixture.records[kind]
      path = fixture.paths[kind]
      bytes = File.read!(path)
      required = if kind == :manifest, do: "revision", else: "commit"

      for candidate <- [
            :erlang.term_to_binary(record, [:deterministic, :compressed]),
            bytes <> <<0>>,
            :erlang.term_to_binary(Map.delete(record, required), [:deterministic]),
            :erlang.term_to_binary(Map.put(record, "extra", "closed"), [:deterministic])
          ] do
        File.write!(path, candidate)
        owned = launch(resource_operation(fixture, kind), :resource_decode)
        assert {{:joined, {:error, :history_invalid}, %{opens: 1, closes: 1}}, _} = drive(owned)
        assert File.read!(path) == candidate
        joined(owned)
      end

      File.write!(path, bytes)
    end
  end

  test "Resource decoding obeys the original work cutoff after explicit descriptor close",
       context do
    fixture = resource_fixture(context.root)

    for kind <- [:manifest, :provenance] do
      owned = launch(resource_operation(fixture, kind), :resource_decode, 500)
      paused_operation(owned, :resource_decode)
      assert {{:joined, {:error, :deadline}, %{opens: 1, closes: 1}}, _} = drive(owned, false)
      joined(owned)
    end
  end

  test "Ledger audit preserves all actual current writer records and raw job identities", context do
    fixture = ledger_fixture(context.root)
    assert not String.valid?(fixture.jobs.admission)
    assert fixture.records.open["origin_executor_epoch"] == 7

    for role <- [:generation, :admission, :refusal, :open] do
      record = fixture.records[role]
      path = fixture.paths[role]
      bytes = File.read!(path)
      mode = File.stat!(path).mode
      owned = launch(ledger_operation(fixture, role), :ledger_decode)
      assert {{:joined, {:ok, ^record}, %{opens: 1, closes: 1}}, events} = drive(owned)
      kinds = issued_kinds(events)
      assert index(kinds, :close) < index(kinds, :ledger_decode)
      assert index(kinds, :ledger_digest) < index(kinds, :ledger_decode)
      assert File.read!(path) == bytes
      assert File.stat!(path).mode == mode
      joined(owned)
    end
  end

  test "captured Ledger copies authenticate the original source placement without activation", context do
    fixture = ledger_fixture(context.root)
    backup = fixture.root <> "-backup"
    File.cp_r!(fixture.root, backup)
    original = fixture.declaration["source_placement"]
    copied = %{fixture | root: backup}

    for role <- [:generation, :admission, :refusal, :open] do
      record = fixture.records[role]
      owned = launch(ledger_operation(copied, role), :ledger_decode)
      assert {{:joined, {:ok, ^record}, %{opens: 1, closes: 1}}, _} = drive(owned)
      joined(owned)
    end

    info = File.stat!(Path.join(backup, "ledger"))
    assert info.inode != original["inode"]
    assert Path.join(backup, "ledger") != original["expanded_root"]

    moved = %{
      "expanded_root" => Path.join(backup, "ledger"),
      "major_device" => info.major_device,
      "inode" => info.inode
    }

    changed = %{copied | declaration: %{fixture.declaration | "source_placement" => moved}}
    owned = launch(ledger_operation(changed, :generation), :ledger_decode)
    assert {{:joined, {:error, :history_invalid}, %{opens: 1, closes: 1}}, _} = drive(owned)
    joined(owned)
    assert File.read!(Path.join(backup, "ledger/generation")) ==
             File.read!(fixture.paths.generation)
    refute File.exists?(Path.join(backup, "ledger/claim"))
  end

  test "Ledger selection and descriptor admission refuse unsafe or alternate requests", context do
    fixture = ledger_fixture(context.root)
    {:audit_ledger, root, declaration, _, _, manifest} = ledger_operation(fixture, :generation)

    for {role, job_id} <- [
          {:generation, "job"}, {:open, nil}, {:open, <<>>},
          {:open, :job}, {:open, :binary.copy(<<0>>, 8_193)}, {:other, nil}
        ] do
      assert RestoreIO.run(
               {:audit_ledger, root, declaration, role, job_id, manifest}, limits(1_000, 100)
             ) == {:error, :invalid_io_request}
    end

    for changed <- [
          Map.put(declaration, "extra", true), Map.delete(declaration, "executor_identity"),
          %{declaration | "relative_root" => "../ledger"},
          %{declaration | "relative_root" => "/ledger"},
          %{declaration | "relative_root" => "ledger/./nested"},
          %{declaration | "source_generation_sha256" => String.duplicate("A", 64)}
        ] do
      owned = launch({:audit_ledger, root, changed, :generation, nil, manifest}, :ledger_declaration)
      assert {{:joined, {:error, :history_invalid}, %{opens: 0, closes: 0}}, events} = drive(owned)
      refute :ledger_decode in issued_kinds(events)
      joined(owned)
    end
  end

  test "Ledger capture requires canonical file and every parent in the physical manifest", context do
    fixture = ledger_fixture(context.root)

    for role <- [:generation, :admission, :refusal, :open] do
      {:audit_ledger, root, declaration, ^role, job_id, manifest} = ledger_operation(fixture, role)
      [domain, entries] = :erlang.binary_to_term(manifest, [:safe])
      relative = Path.relative_to(fixture.paths[role], root)
      parent = Path.dirname(relative)

      for changed <- [
            Enum.reject(entries, &(&1["path"] == relative)),
            Enum.reject(entries, &(&1["path"] == parent)),
            Enum.reject(entries, &(&1["path"] == ".")),
            Enum.map(entries, fn entry ->
              if entry["path"] == relative,
                do: %{entry | "kind" => "directory", "size" => 0, "sha256" => nil}, else: entry
            end)
          ] do
        bytes = :erlang.term_to_binary([domain, changed], [:deterministic])
        owned = launch({:audit_ledger, root, declaration, role, job_id, bytes}, :ledger_manifest)
        assert {{:joined, {:error, reason}, %{opens: 0, closes: 0}}, events} = drive(owned)
        assert reason in [:io_error, :history_invalid]
        refute :ledger_decode in issued_kinds(events)
        joined(owned)
      end

      File.rm!(fixture.paths[role])
      owned = launch({:audit_ledger, root, declaration, role, job_id, manifest}, :ledger_manifest)
      assert {{:joined, {:error, :io_error}, %{opens: 0, closes: 0}}, _} = drive(owned)
      refute File.exists?(fixture.paths[role])
      joined(owned)
      File.write!(fixture.paths[role], :erlang.term_to_binary(fixture.records[role], [:deterministic]))
    end
  end

  test "Ledger generation hash identity and original binding are independent required relations", context do
    fixture = ledger_fixture(context.root)
    declaration = fixture.declaration
    placement = declaration["source_placement"]

    for changed <- [
          %{declaration | "source_generation_sha256" => String.duplicate("0", 64)},
          %{declaration | "executor_identity" => "other-executor"},
          %{declaration | "source_placement" => %{placement | "inode" => placement["inode"] + 1}},
          %{declaration | "source_placement" => %{placement | "expanded_root" => fixture.root}}
        ] do
      owned = launch(ledger_operation(%{fixture | declaration: changed}, :generation), :ledger_decode)
      assert {{:joined, {:error, :history_invalid}, %{opens: 1, closes: 1}}, _} = drive(owned)
      joined(owned)
    end

    changed = %{fixture | declaration: %{declaration | "executor_identity" => "other-executor"}}
    owned = launch(ledger_operation(changed, :open), :ledger_decode)
    assert {{:joined, {:error, :history_invalid}, %{opens: 1, closes: 1}}, _} = drive(owned)
    joined(owned)
  end

  test "Ledger basename job identity and expected kind cannot substitute for each other", context do
    fixture = ledger_fixture(context.root)
    wrong = <<255, 0, "another-job">>

    for role <- [:admission, :refusal, :open] do
      path = Path.join(Path.dirname(fixture.paths[role]), hash(wrong))
      File.cp!(fixture.paths[role], path)
      changed = %{fixture | jobs: Map.put(fixture.jobs, role, wrong)}
      owned = launch(ledger_operation(changed, role), :ledger_decode)
      assert {{:joined, {:error, :history_invalid}, %{opens: 1, closes: 1}}, _} = drive(owned)
      assert File.read!(path) == File.read!(fixture.paths[role])
      joined(owned)
      File.rm!(path)
    end

    for {selected, actual} <- [{:admission, :refusal}, {:refusal, :admission}] do
      changed = %{fixture | jobs: Map.put(fixture.jobs, selected, fixture.jobs[actual])}
      owned = launch(ledger_operation(changed, selected), :ledger_decode)
      assert {{:joined, {:error, :history_invalid}, %{opens: 1, closes: 1}}, _} = drive(owned)
      joined(owned)
    end
  end

  test "all Ledger roles refuse their actual first over-cap file before open or decode", context do
    for {role, ceiling} <- [generation: 2_048, admission: 65_536, refusal: 65_536, open: 65_536] do
      fixture = ledger_fixture(context.root)
      File.write!(fixture.paths[role], :binary.copy(<<0>>, ceiling + 1))
      owned = launch(ledger_operation(fixture, role), :ledger_manifest)
      assert {{:joined, {:error, :io_error}, %{opens: 0, closes: 0}}, events} = drive(owned)
      refute :read in issued_kinds(events)
      refute :ledger_decode in issued_kinds(events)
      assert File.stat!(fixture.paths[role]).size == ceiling + 1
      joined(owned)
    end
  end

  test "Ledger size mode and same-size content must match the captured inventory", context do
    for role <- [:generation, :admission, :refusal, :open] do
      fixture = ledger_fixture(context.root)
      operation = ledger_operation(fixture, role)
      path = fixture.paths[role]
      bytes = File.read!(path)
      mode = Bitwise.band(File.stat!(path).mode, 0o7777)

      for change <- [:size, :mode, :content] do
        File.write!(path, bytes)
        File.chmod!(path, mode)

        case change do
          :size -> File.write!(path, bytes <> <<0>>)
          :mode -> File.chmod!(path, Bitwise.bxor(mode, 0o100))
          :content -> File.write!(path, :binary.copy(<<0>>, byte_size(bytes)))
        end

        owned = launch(operation, :ledger_manifest)
        assert {{:joined, {:error, :io_error}, evidence}, events} = drive(owned)
        assert evidence.opens == evidence.closes
        refute :ledger_decode in issued_kinds(events)
        joined(owned)
      end
    end
  end

  test "Ledger hardlinks symlinks ancestors and FIFO substitutions refuse before open", context do
    for role <- [:generation, :admission, :refusal, :open] do
      fixture = ledger_fixture(context.root)
      operation = ledger_operation(fixture, role)
      path = fixture.paths[role]
      other = Path.join(fixture.root, "other")
      File.ln!(path, other)
      owned = launch(operation, :ledger_manifest)
      assert {{:joined, {:error, :io_error}, %{opens: 0, closes: 0}}, _} = drive(owned)
      joined(owned)
      File.rm!(other)
      File.rename!(path, other)
      File.ln_s!(other, path)
      owned = launch(operation, :ledger_manifest)
      assert {{:joined, {:error, :io_error}, %{opens: 0, closes: 0}}, _} = drive(owned)
      joined(owned)
      File.rm!(path)
      assert {_, 0} = System.cmd("mkfifo", [path])
      owned = launch(operation, :ledger_manifest)
      assert {{:joined, {:error, :io_error}, %{opens: 0, closes: 0}}, _} = drive(owned)
      joined(owned)
      File.rm!(path)
      File.rename!(other, path)
      directory = Path.dirname(path)
      moved = directory <> "-moved"
      File.rename!(directory, moved)
      File.ln_s!(moved, directory)
      owned = launch(operation, :ledger_manifest)
      assert {{:joined, {:error, :io_error}, %{opens: 0, closes: 0}}, _} = drive(owned)
      joined(owned)
    end
  end

  test "Ledger descriptor and post-decode file or ancestor replacement cannot publish a record", context do
    for role <- [:generation, :admission, :refusal, :open],
        change <- [:descriptor, :file, :ancestor] do
      fixture = ledger_fixture(context.root)
      path = fixture.paths[role]
      pause = if change == :descriptor, do: :descriptor_stat, else: :ledger_decode
      owned = launch(ledger_operation(fixture, role), pause)
      {id, _} = paused_operation(owned, pause)

      if change == :ancestor do
        directory = Path.dirname(path)
        moved = directory <> "-moved"
        File.rename!(directory, moved)
        File.mkdir!(directory)
        File.rename!(Path.join(moved, Path.basename(path)), path)
      else
        replacement = path <> ".replacement"
        File.write!(replacement, File.read!(path))
        File.chmod!(replacement, Bitwise.band(File.stat!(path).mode, 0o7777))
        File.rename!(replacement, path)
      end

      send(owned.guardian, {:proceed, owned.reference, id})
      assert {{:joined, {:error, :io_error}, %{opens: 1, closes: 1}}, events} = drive(owned)
      if change == :descriptor, do: refute(:ledger_decode in issued_kinds(events))
      joined(owned)
    end
  end

  test "physical Ledger equality cannot admit compressed trailing alternate or malformed records", context do
    for role <- [:generation, :admission, :refusal, :open] do
      fixture = ledger_fixture(context.root)
      record = fixture.records[role]
      canonical = File.read!(fixture.paths[role])
      compressed = :erlang.term_to_binary(record, [:deterministic, :compressed])
      assert <<131, 80, _::binary>> = compressed

      for bytes <- [compressed, canonical <> <<0>>,
            :erlang.term_to_binary([record], [:deterministic]),
            :erlang.term_to_binary(Map.put(record, "extra", true), [:deterministic]),
            :erlang.term_to_binary(Map.delete(record, :ledger_kind), [:deterministic])] do
        File.write!(fixture.paths[role], bytes)
        changed = if role == :generation,
          do: %{fixture | declaration: %{fixture.declaration | "source_generation_sha256" => hash(bytes)}},
          else: fixture
        owned = launch(ledger_operation(changed, role), :ledger_decode)
        assert {{:joined, {:error, :history_invalid}, %{opens: 1, closes: 1}}, events} = drive(owned)
        assert index(issued_kinds(events), :close) < index(issued_kinds(events), :ledger_decode)
        assert File.read!(fixture.paths[role]) == bytes
        joined(owned)
      end
    end
  end

  test "Ledger semantic work retains the original cutoff after explicit descriptor close", context do
    for role <- [:generation, :admission, :refusal, :open] do
      fixture = ledger_fixture(context.root)
      owned = launch(ledger_operation(fixture, role), :ledger_decode, 500)
      paused_operation(owned, :ledger_decode)
      assert {{:joined, {:error, :deadline}, %{opens: 1, closes: 1}}, _} = drive(owned, false)
      joined(owned)
    end
  end

  test "an actual Local Store retains unknown effect truth through offline semantic audit",
       context do
    previous = System.get_env("LOOPEX_HOME")
    System.put_env("LOOPEX_HOME", context.root)

    on_exit(fn ->
      if previous,
        do: System.put_env("LOOPEX_HOME", previous),
        else: System.delete_env("LOOPEX_HOME")
    end)

    root = physical_root(context.root)
    directory = Path.join(root, "store")
    File.mkdir!(directory)
    path = Path.join(directory, "history.log")
    {:ok, store} = Loopex.Store.Local.start_link(path: path)

    on_exit(fn ->
      monitor = Process.monitor(store)
      Process.exit(store, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^store, _}, 1_000
    end)

    fixture =
      Loopex.AgentLoopFixture.start(
        store: store,
        store_module: Loopex.Store.Local,
        script: [
          %{text: "write", calls: [%{id: "call-1", name: "write", arguments: %{"path" => "a"}}]}
        ],
        outcomes: %{"call-1" => "outcome_unknown"}
      )

    actors = [fixture.runtime.supervisor, store, fixture.model, fixture.executor]
    monitors = Enum.map(actors, &{&1, Process.monitor(&1)})

    on_exit(fn ->
      for actor <- actors do
        monitor = Process.monitor(actor)
        Process.exit(actor, :kill)
        assert_receive {:DOWN, ^monitor, :process, ^actor, _}, 1_000
      end
    end)

    {session, attachment, {:accepted, "prompt-1"}} = Loopex.AgentLoopFixture.run(fixture, "write")
    cutoff = System.monotonic_time(:millisecond) + 5_000
    await_unknown(attachment, cutoff)
    :ok = Loopex.stop(fixture.runtime)
    :ok = GenServer.stop(store, :normal, 1_000)
    :ok = Agent.stop(fixture.model, :normal, 1_000)
    :ok = Agent.stop(fixture.executor, :normal, 1_000)

    for {actor, monitor} <- monitors do
      assert_receive {:DOWN, ^monitor, :process, ^actor, :normal}, 1_000
    end

    bytes = File.read!(path)
    {:ok, frames, :complete} = Log.decode_bytes(bytes)
    {:ok, replayed} = State.replay(frames)
    owned = launch(store_operation(%{root: root, path: path, bytes: bytes}), :store_decode)
    assert {{:joined, {:ok, result}, %{opens: 1, closes: 1}}, _} = drive(owned)
    assert result.store == replayed

    assert {:ok, expected} =
             SessionState.recover(
               session,
               replayed.sessions[session].records,
               replayed.sessions[session].events
             )

    assert result.sessions[session] == expected

    assert expected.conversation
           |> Map.values()
           |> List.flatten()
           |> Enum.any?(&(&1.kind == :tool_result and &1.outcome == :outcome_unknown))

    assert File.read!(path) == bytes
    joined(owned)
  end

  defp await_unknown(attachment, cutoff) do
    assert System.monotonic_time(:millisecond) < cutoff

    case Loopex.next_event(attachment) do
      {:ok, %{:kind => "run.finished", "outcome" => "outcome_unknown"}} ->
        :ok

      {:ok, _event} ->
        await_unknown(attachment, cutoff)

      {:error, :empty} ->
        assert System.monotonic_time(:millisecond) < cutoff

        receive do
        after
          1 -> await_unknown(attachment, cutoff)
        end

      other ->
        flunk("unknown-effect fixture did not finish: #{inspect(other)}")
    end
  end

  defp store_fixture(root, count) do
    root = physical_root(root)
    directory = Path.join(root, "store")
    File.mkdir!(directory)
    path = Path.join(directory, "history.log")
    File.write!(path, <<>>)
    initial = %{root: root, path: path, state: State.new(), frames: [], bytes: <<>>, ids: []}

    Enum.reduce(1..count, initial, fn number, fixture ->
      {:ok, transaction} =
        Store.create_session(
          "audit-runtime",
          "create-#{number}",
          ConfiguredGenesisFixture.genesis([])
        )

      append_transaction(fixture, transaction)
    end)
  end

  defp append_transaction(fixture, transaction) do
    {:new, state, frame, _outcome} = State.prepare(fixture.state, transaction)
    frames = fixture.frames ++ [frame]
    bytes = fixture.bytes <> encoded_frame(frame)
    File.write!(fixture.path, bytes)

    %{
      fixture
      | state: state,
        frames: frames,
        bytes: bytes,
        ids: Enum.sort(Map.keys(state.sessions))
    }
  end

  defp append_pending(fixture, id) do
    head = fixture.state.sessions[id]

    {:ok, owner} =
      Store.advance_owner(id, "owner", "owner-tx", 0, head.journal_version, "audit-owner")

    fixture = append_transaction(fixture, owner)
    head = fixture.state.sessions[id]
    {:ok, state} = SessionState.recover(id, head.records, head.events)

    {:ok, prompt} =
      SessionState.propose(state, %{type: :prompt, command_id: "prompt", content: "continue"}, %{
        max_turns: 8,
        token_budget: 10_000,
        deadline_ms: 60_000,
        context_token_budget: 8_192
      })

    {:ok, transaction} =
      Store.session_commit(
        id,
        "session",
        prompt.tx_id,
        head.owner_epoch,
        head.owner_incarnation_id,
        head.journal_version,
        prompt.records,
        prompt.events
      )

    append_transaction(fixture, transaction)
  end

  defp encoded_frame(frame) do
    {:ok, bytes} = Log.encode(frame)
    bytes
  end

  defp store_operation(fixture) do
    assert {:joined, {:ok, manifest}, _} =
             RestoreIO.run(
               {:manifest, fixture.root, byte_size(fixture.bytes)},
               limits(1_000, 100)
             )

    declaration = %{"relative_path" => "store/history.log", "sha256" => hash(fixture.bytes)}
    {:audit_store, fixture.root, declaration, manifest}
  end

  defp ledger_fixture(root) do
    state = Path.join(physical_root(root), "ledger-state-#{System.unique_integer([:positive])}")
    File.mkdir!(state)
    ledger = Path.join(state, "ledger")
    identity = "ledger-audit"
    assert {:ok, prepared} = Ledger.prepare(ledger, identity, 100)

    job = %{
      job_id: <<0, 255, 128, "admitted">>,
      operation_id: "ledger-operation",
      attempt: 1,
      canonical_request_digest: String.duplicate("a", 64),
      cleanup_grace_ms: 100,
      origin_executor_epoch: 7
    }

    refused = %{job | job_id: "refused", operation_id: "refused-operation"}
    marker = Ledger.marker(job)
    open = Ledger.open_entry(job, identity)
    assert {:ok, refusal} = Ledger.refusal(refused, :workspace_lease_lost)

    assert :ok = Ledger.with_claim(prepared, fn claimed ->
      assert :ok = Ledger.admit(claimed, marker, open)
      Ledger.refuse(claimed, refusal)
    end)

    paths = %{
      generation: Path.join(ledger, "generation"),
      admission: Path.join([ledger, "markers", hash(job.job_id)]),
      refusal: Path.join([ledger, "markers", hash(refused.job_id)]),
      open: Path.join([ledger, "open", hash(job.job_id)])
    }

    bytes = File.read!(paths.generation)
    generation = :erlang.binary_to_term(bytes, [:safe])
    info = File.stat!(ledger)
    declaration = %{
      "relative_root" => "ledger",
      "executor_identity" => identity,
      "source_generation_sha256" => hash(bytes),
      "source_placement" => %{
        "expanded_root" => ledger, "major_device" => info.major_device, "inode" => info.inode
      }
    }

    assert {:ok, _} = RestoreCodec.encode(:ledger_descriptor, declaration)
    %{
      root: state, declaration: declaration, paths: paths,
      jobs: %{generation: nil, admission: job.job_id, refusal: refused.job_id, open: job.job_id},
      records: %{generation: generation, admission: marker, refusal: refusal, open: open}
    }
  end

  defp ledger_operation(fixture, role) do
    assert {:joined, {:ok, manifest}, _} =
      RestoreIO.run({:manifest, fixture.root, 1_048_576}, limits(1_000, 100))

    {:audit_ledger, fixture.root, fixture.declaration, role, fixture.jobs[role], manifest}
  end

  defp resource_fixture(root, width \\ 40) do
    root = physical_root(root)
    state = Path.join(root, "resource-state-#{System.unique_integer([:positive])}")
    File.mkdir!(state)

    files =
      for {label, content} <- [
            {"SKILL.md", "summary\n"},
            {"opaque.bin", :binary.copy(<<0, 255, 128>>, 50_000)}
          ] do
        %{
          "label" => label,
          "size" => byte_size(content),
          "digest" => LoopexProtocol.Canonical.digest_bytes(content),
          "content" => content,
          "contained" => true
        }
      end

    pack = %{
      "source_id" => "git:restore-audit",
      "origin" => "https://example.invalid/skills",
      "commit" => String.duplicate("a", width),
      "tree_digest" => String.duplicate("b", width),
      "name" => "review",
      "description" => "Review retained bytes.",
      "manual_only" => false,
      "files" => files
    }

    manifest = %{
      "version" => "loopex.resource_pack/1",
      "workspace_ref" => "workspace:restore-audit",
      "revision" => nil,
      "packs" => [pack]
    }

    assert {:ok, digest, manifest} = Loopex.ResourcePack.digest(manifest)
    [pack] = manifest["packs"]
    identity = resource_content_identity(pack)
    assert {:ok, ^digest} = ResourcePacks.retain(manifest, state)

    %{
      root: state,
      identities: %{manifest: digest, provenance: identity},
      records: %{manifest: manifest, provenance: pack},
      paths: %{
        manifest: Path.join([state, "resource-packs", "manifests", digest <> ".etf"]),
        provenance: Path.join([state, "resource-packs", "provenance", identity <> ".etf"])
      }
    }
  end

  defp resource_content_identity(pack) do
    LoopexProtocol.Canonical.digest(%{
      "encoding" => LoopexProtocol.Canonical.version(),
      "kind" => "loopex.retained_resource_content/1",
      "value" => pack["files"] |> Enum.map(&[&1["label"], &1["digest"]]) |> Enum.sort_by(&hd/1)
    })
  end

  defp resource_operation(fixture, kind) do
    assert {:joined, {:ok, manifest}, _} =
             RestoreIO.run({:manifest, fixture.root, 1_048_576}, limits(1_000, 100))

    {:audit_resource, fixture.root, kind, fixture.identities[kind], manifest}
  end

  defp physical_root(root) do
    assert {physical, 0} =
             System.cmd("python3", [
               "-c",
               "import os,sys; print(os.path.realpath(sys.argv[1]))",
               root
             ])

    String.trim_trailing(physical, "\n")
  end

  defp expected_manifest(root, paths) do
    entries =
      paths
      |> Enum.sort()
      |> Enum.map(fn relative ->
        path = if relative == ".", do: root, else: Path.join(root, relative)
        info = File.lstat!(path)

        %{
          "path" => relative,
          "kind" => if(info.type == :directory, do: "directory", else: "regular"),
          "mode" => Bitwise.band(info.mode, 0o7777),
          "size" => if(info.type == :directory, do: 0, else: info.size),
          "sha256" => if(info.type == :directory, do: nil, else: hash(File.read!(path)))
        }
      end)

    :erlang.term_to_binary(["loopex:current-state-manifest:v1", entries], [:deterministic])
  end

  defp paused_operation(owned, expected),
    do: paused_operation(owned, expected, System.monotonic_time(:millisecond) + 1_000)

  defp paused_operation(owned, expected, cutoff) do
    guardian = owned.guardian
    worker = owned.worker
    reference = owned.reference

    receive do
      {:restore_io, ^guardian, ^worker, ^reference, {:issued, id, kind}} ->
        name = if is_tuple(kind), do: elem(kind, 0), else: kind
        if name == expected, do: {id, kind}, else: paused_operation(owned, expected, cutoff)

      {:restore_io, ^guardian, ^worker, ^reference, _} ->
        paused_operation(owned, expected, cutoff)
    after
      max(0, cutoff - System.monotonic_time(:millisecond)) ->
        flunk("expected owned operation was not issued")
    end
  end

  defp create_listing(root, count, width) do
    assert {_, 0} =
             System.cmd("python3", [
               "-c",
               "import os,sys; root=sys.argv[1]; count=int(sys.argv[2]); width=int(sys.argv[3]); [os.close(os.open(os.path.join(root, str(i).zfill(width)), os.O_CREAT|os.O_EXCL|os.O_WRONLY,0o600)) for i in range(count)]",
               root,
               Integer.to_string(count),
               Integer.to_string(width)
             ])
  end

  defp launch(operation, pause, work_ms \\ 1_000, grace \\ 100) do
    parent = self()
    tag = make_ref()

    {caller, caller_monitor} =
      spawn_monitor(fn ->
        send(
          parent,
          {tag, RestoreIO.run(operation, limits(work_ms, grace), probe: parent, pause_at: pause)}
        )
      end)

    assert_receive {:restore_io, guardian, worker, reference,
                    {:installed, admitted, work_cutoff}},
                   1_000

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

    %{
      caller: caller,
      caller_monitor: caller_monitor,
      guardian: guardian,
      guardian_monitor: guardian_monitor,
      worker: worker,
      worker_monitor: worker_monitor,
      reference: reference,
      tag: tag,
      pause: pause
    }
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

          _ ->
            :ok
        end

        drive(owned, proceed, [event | events])

      {^tag, result} ->
        {result, Enum.reverse(events)}
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

  defp issued_kinds(events),
    do: for({:issued, _, kind} <- events, do: if(is_tuple(kind), do: elem(kind, 0), else: kind))

  defp index(values, value), do: Enum.find_index(values, &(&1 == value))
  defp hash(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
  defp limits(work, grace), do: %{"work_ms" => work, "cleanup_grace_ms" => grace}

  defp await_raw_open(worker, cutoff) do
    parent = self()
    reference = make_ref()

    {inspector, monitor} =
      spawn_monitor(fn -> send(parent, {reference, observe_raw_open(worker, cutoff)}) end)

    try do
      receive do
        {^reference, :observed} ->
          :ok

        {^reference, {:unavailable, observation}} ->
          flunk("actual raw FIFO open was not observed in open_nif: #{inspect(observation)}")
      after
        max(0, cutoff - System.monotonic_time(:millisecond)) ->
          flunk("raw-open inspection did not return before its captured cutoff")
      end
    after
      Process.exit(inspector, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^inspector, _}, 1_000
    end
  end

  defp observe_raw_open(worker, cutoff) do
    case Process.info(worker, :current_function) do
      {:current_function, {:prim_file, :open_nif, 2}} ->
        :observed

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
    assert {_, 0} =
             System.cmd("python3", [
               "-c",
               "import os,sys; fd=os.open(sys.argv[1],os.O_RDWR|os.O_NONBLOCK); os.close(fd)",
               path
             ])
  end
end
