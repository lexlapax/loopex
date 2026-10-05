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
  alias Loopex.Runtime.SessionState
  alias Loopex.Store
  alias Loopex.Store.Local.{Log, State}

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
