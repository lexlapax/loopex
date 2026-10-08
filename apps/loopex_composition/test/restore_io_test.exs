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
    File.mkdir_p!(Path.join(root, ".loopex-restore/0001"))
    File.write!(Path.join(root, ".loopex-restore/0001/intent"), "prior immutable bytes")
    File.write!(Path.join(root, ".hidden"), "")
    File.chmod!(Path.join(root, ".hidden"), 0o640)
    content = :binary.copy(<<1, 2, 3, 4>>, 40_000)
    File.write!(Path.join(root, "stream"), content)

    # Concept: the manifest proves physically established special permission bits.
    # Technical depth: the joined Python setter precedes independent native lstat checks.
    assert {"", 0} =
             System.cmd("python3", [
               "-c",
               "import os,sys; os.chmod(sys.argv[1],0o1750); os.chmod(sys.argv[2],0o4750)",
               Path.join(root, "empty"),
               Path.join(root, "stream")
             ])

    assert Bitwise.band(File.lstat!(Path.join(root, "empty")).mode, 0o7777) == 0o1750
    assert Bitwise.band(File.lstat!(Path.join(root, "stream")).mode, 0o7777) == 0o4750

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
    assert {:ok, entries} = RestoreCodec.manifest(bytes, byte_size(content) + 21)
    index = Map.new(entries, &{&1["path"], &1})
    assert index["empty"]["mode"] == 0o1750
    assert index["stream"]["mode"] == 0o4750
    assert evidence.opens == 3
    assert evidence.closes == 3
    assert Enum.count(issued_kinds(events), &(&1 == :hash_read)) >= 6
    assert File.read!(Path.join(root, "stream")) == content
    joined(owned)
  end

  test "real streamed copy preserves the physically established full regular-file mode and complete manifest",
       context do
    root = physical_root(context.root)
    source = Path.join(root, "mode-source")
    backup = Path.join(root, "mode-backup")
    destination = Path.join(root, "mode-destination")
    workspace = Path.join(root, "mode-workspace")

    for path <- [source, backup, destination, workspace] do
      File.mkdir!(path)
      File.chmod!(path, 0o700)
    end

    content = :binary.copy(<<1, 2, 3, 4>>, 40_000)

    for path <- [source, backup] do
      file = Path.join(path, "stream")
      File.write!(file, content)

      assert {"", 0} =
               System.cmd("python3", [
                 "-c",
                 "import os,sys; os.chmod(sys.argv[1],0o4750)",
                 file
               ])

      assert Bitwise.band(File.lstat!(file).mode, 0o7777) == 0o4750
    end

    source_file = Path.join(source, "stream")
    backup_file = Path.join(backup, "stream")
    destination_file = Path.join(destination, "stream")
    source_inode = File.lstat!(source_file).inode
    backup_inode = File.lstat!(backup_file).inode
    baseline = expected_manifest(backup, [".", "stream"])
    assert expected_manifest(source, [".", "stream"]) == baseline
    assert {:ok, entries} = RestoreCodec.manifest(baseline, byte_size(content))
    assert Enum.find(entries, &(&1["path"] == "stream"))["mode"] == 0o4750
    {:ok, lineage} = RestoreCodec.lineage_digest([])

    placement = fn path ->
      stat = File.lstat!(path)
      %{"expanded_root" => path, "major_device" => stat.major_device, "inode" => stat.inode}
    end

    observed_workspace = placement.(workspace)

    workspace_ref =
      LoopexComposition.WorkspaceIdentity.from_verified_root(
        workspace,
        {observed_workspace["major_device"], observed_workspace["inode"]}
      )

    plan = %{
      "version" => 1,
      "tx_id" => hash("regular-mode-original-restore"),
      "source_state_root" => source,
      "source_state_placement" => placement.(source),
      "source_status" => "available",
      "backup_state_root" => backup,
      "destination_state_root" => destination,
      "manifest_sha256" => hash(baseline),
      "cut_id" => hash("joined-regular-mode-cut"),
      "prior_restore_count" => 0,
      "prior_lineage_sha256" => lineage,
      "runtime_ids" => [],
      "stores" => [],
      "ledgers" => [],
      "workspace" => %{"root" => workspace, "workspace_ref" => workspace_ref},
      "host_attestation" => %{
        "latest_cut" => true,
        "no_post_cut_activity" => true,
        "all_other_copies_excluded" => true,
        "old_authority_termination" => "joined",
        "host_ledgers_validated" => true,
        "evidence_sha256" => hash("native-fixture-writers-returned")
      }
    }

    invocation = %{
      "work_ms" => 1_000,
      "cleanup_grace_ms" => 100,
      "max_total_file_bytes" => 1_048_576,
      "prior_admin_authority" => "none",
      "prior_admin_evidence_sha256" => nil
    }

    assert {:ok, _} = RestoreCodec.encode(:plan, plan)
    assert {:ok, _} = RestoreCodec.encode(:invocation, invocation)
    assert File.ls!(destination) == []

    # Concept: exercise copy only through the admitted original restore owner.
    # Technical depth: an existing manifest-stat gate holds the first destination
    # administrative allocation after its phase marker, preserving the complete
    # copied baseline for observation under the same captured work cutoff.
    owned = launch({:restore_first, plan, invocation}, :manifest_stat)
    fixture = %{destination: destination, baseline: baseline, content: content}

    {result, events, release} =
      drive_mode_restore(owned, fixture, owned.work_cutoff + 10_000)

    assert {:joined, {:ok, %{restore_result: {:committed, receipt}, release_claims: []}},
            evidence} = result

    assert evidence.opens == evidence.closes and evidence.opens > 0
    assert evidence.work_cutoff == owned.work_cutoff
    assert evidence.stop == :complete
    assert receipt["tx_id"] == plan["tx_id"]
    assert receipt["baseline_manifest_sha256"] == hash(baseline)
    assert receipt["ledger_count"] == 0
    assert {:ok, _} = RestoreCodec.encode(:receipt, receipt)
    joined(owned)

    assert %{worker: release_worker, monitor: release_monitor, cleanup_cutoff: release_cutoff} =
             release

    assert evidence.cleanup_cutoff == release_cutoff
    assert_receive {:DOWN, ^release_monitor, :process, ^release_worker, :normal}, 1_000

    payload_events = for {worker, event} <- events, worker == owned.worker, do: event

    copy_events =
      payload_events
      |> Enum.drop_while(&(not match?({:issued, _, {:restore_phase, "baseline_copy"}}, &1)))
      |> tl()
      |> Enum.take_while(&(not match?({:issued, _, {:restore_phase, "destination_intent"}}, &1)))

    kinds = issued_kinds(copy_events)

    assert [initial_mode, final_mode, directory_mode] =
             for({:mode, at} <- Enum.with_index(kinds), do: at)

    writes = for {:write, at} <- Enum.with_index(kinds), do: at
    assert length(writes) >= 3
    assert initial_mode < hd(writes)
    assert List.last(writes) < final_mode
    assert final_mode < index(kinds, :file_sync)
    assert index(kinds, :file_sync) < directory_mode
    closes = for {:close, at} <- Enum.with_index(kinds), do: at
    assert length(closes) >= 3
    copied = Enum.take(kinds, Enum.at(closes, 2) + 1)
    assert Enum.count(copied, &(&1 == :open)) == 3
    assert Enum.count(copied, &(&1 == :close)) == 3
    assert File.read!(destination_file) == content
    assert Bitwise.band(File.lstat!(destination_file).mode, 0o7777) == 0o4750
    assert File.lstat!(source_file).inode == source_inode
    assert File.lstat!(backup_file).inode == backup_inode

    for file <- [source_file, backup_file] do
      assert Bitwise.band(File.lstat!(file).mode, 0o7777) == 0o4750
      assert File.read!(file) == content
      refute File.lstat!(destination_file).inode == File.lstat!(file).inode
    end

    assert expected_manifest(backup, [".", "stream"]) == baseline

    for state_root <- [source, destination] do
      {:ok, digest} = RestoreCodec.claim_digest(state_root)
      assert File.lstat(Path.join(root, ".loopex-restore-claim-" <> digest)) == {:error, :enoent}
    end
  end

  for control <- [:preserve, :normalize] do
    test "real special-mode restore #{control} compares root directories and remaining regular bits before publication",
         context do
      control = unquote(control)
      root = physical_root(context.root)
      source = Path.join(root, "special-source")
      backup = Path.join(root, "special-backup")
      destination = Path.join(root, "special-destination")
      workspace = Path.join(root, "special-workspace")

      for path <- [source, backup, destination, workspace] do
        File.mkdir!(path)
        File.chmod!(path, 0o700)
      end

      # Concept: special-mode fixtures select an eligible temporary directory group.
      # Technical depth: group identity is outside the mode manifest; verify the
      # fresh destination group before its native restore copies any entries.
      assert {destination_group, 0} =
               System.cmd("python3", [
                 "-c",
                 "import os,sys; p=sys.argv[1]; g=os.getegid(); os.chown(p,-1,g); print(g)",
                 destination
               ])

      assert File.lstat!(destination).gid ==
               String.to_integer(String.trim(destination_group))

      modes = %{
        "." => 0o3750,
        "empty" => 0o1750,
        "nested" => 0o2750,
        "nested/inner" => 0o4750,
        "nested/inner/all" => 0o7750,
        "setgid" => 0o2750,
        "sticky" => 0o1750
      }

      contents = %{
        "nested/inner/all" => :binary.copy(<<0, 255, 1, 2>>, 40_000),
        "setgid" => "retained setgid bytes",
        "sticky" => ""
      }

      for state_root <- [source, backup] do
        File.mkdir!(Path.join(state_root, "empty"))
        File.mkdir_p!(Path.join(state_root, "nested/inner"))
        for {relative, bytes} <- contents, do: File.write!(Path.join(state_root, relative), bytes)

        for {relative, mode} <- modes do
          path = if relative == ".", do: state_root, else: Path.join(state_root, relative)

          assert {"", 0} =
                   System.cmd("python3", [
                     "-c",
                     "import os,sys; p=sys.argv[1]; g=os.getegid(); os.chown(p,-1,g); os.lstat(p).st_gid==g or sys.exit(1); os.chmod(p,int(sys.argv[2]))",
                     path,
                     Integer.to_string(mode)
                   ])

          assert Bitwise.band(File.lstat!(path).mode, 0o7777) == mode
        end
      end

      paths = Enum.sort(Map.keys(modes))
      baseline = special_mode_manifest(backup, paths)
      assert special_mode_manifest(source, paths) == baseline
      {:ok, lineage} = RestoreCodec.lineage_digest([])

      placement = fn path ->
        info = File.lstat!(path)
        %{"expanded_root" => path, "major_device" => info.major_device, "inode" => info.inode}
      end

      original =
        Map.new([source, backup], fn state_root ->
          {state_root,
           Map.new(paths, fn relative ->
             path = if relative == ".", do: state_root, else: Path.join(state_root, relative)
             {relative, placement.(path)}
           end)}
        end)

      workspace_identity = placement.(workspace)

      workspace_ref =
        LoopexComposition.WorkspaceIdentity.from_verified_root(
          workspace,
          {workspace_identity["major_device"], workspace_identity["inode"]}
        )

      plan = %{
        "version" => 1,
        "tx_id" => hash("special-mode-original-restore-#{control}"),
        "source_state_root" => source,
        "source_state_placement" => placement.(source),
        "source_status" => "available",
        "backup_state_root" => backup,
        "destination_state_root" => destination,
        "manifest_sha256" => hash(baseline),
        "cut_id" => hash("joined-special-mode-cut"),
        "prior_restore_count" => 0,
        "prior_lineage_sha256" => lineage,
        "runtime_ids" => [],
        "stores" => [],
        "ledgers" => [],
        "workspace" => %{"root" => workspace, "workspace_ref" => workspace_ref},
        "host_attestation" => %{
          "latest_cut" => true,
          "no_post_cut_activity" => true,
          "all_other_copies_excluded" => true,
          "old_authority_termination" => "joined",
          "host_ledgers_validated" => true,
          "evidence_sha256" => hash("exact-mode-fixture-writers-returned")
        }
      }

      invocation = %{
        "work_ms" => 1_000,
        "cleanup_grace_ms" => 100,
        "max_total_file_bytes" => 1_048_576,
        "prior_admin_authority" => "none",
        "prior_admin_evidence_sha256" => nil
      }

      assert {:ok, _} = RestoreCodec.encode(:plan, plan)
      assert {:ok, _} = RestoreCodec.encode(:invocation, invocation)
      owned = launch({:restore_first, plan, invocation}, :manifest_stat)

      fixture = %{
        destination: destination,
        baseline: baseline,
        paths: paths,
        modes: modes,
        contents: contents,
        control: control,
        # Concept: observe the complete copied baseline before the audit.
        # Technical depth: each regular file has two mode acknowledgements;
        # each directory has its final mode plus initial 0700, except the root.
        mode_count:
          2 * map_size(contents) +
            2 * (map_size(modes) - map_size(contents)) - 1
      }

      {result, events, release, copied} =
        drive_special_mode_restore(owned, fixture, owned.work_cutoff + 10_000)

      assert {:joined, {:ok, %{restore_result: outcome, release_claims: []}}, evidence} = result
      assert evidence.opens == evidence.closes and evidence.opens > 0
      assert evidence.work_cutoff == owned.work_cutoff and evidence.stop == :complete

      [{_actor, {:stopping, :complete, stopped, cleanup_cutoff}}] =
        Enum.filter(events, fn {_actor, event} -> match?({:stopping, :complete, _, _}, event) end)

      assert cleanup_cutoff == stopped + 10_000 and cleanup_cutoff == evidence.cleanup_cutoff
      assert System.monotonic_time(:millisecond) < evidence.cleanup_cutoff
      joined(owned)
      assert System.monotonic_time(:millisecond) < evidence.cleanup_cutoff

      if copied == baseline do
        assert {:committed, receipt} = outcome
        assert receipt["tx_id"] == plan["tx_id"]
        assert receipt["baseline_manifest_sha256"] == hash(baseline)
        assert receipt["cut_id"] == plan["cut_id"]
        assert receipt["ledger_count"] == 0
        assert {:ok, _} = RestoreCodec.encode(:receipt, receipt)
        assert %{worker: actor, monitor: monitor, cleanup_cutoff: cutoff} = release
        assert cutoff == evidence.cleanup_cutoff
        assert_receive {:DOWN, ^monitor, :process, ^actor, :normal}, 1_000
        assert System.monotonic_time(:millisecond) < cutoff

        for state_root <- [source, destination] do
          {:ok, digest} = RestoreCodec.claim_digest(state_root)

          assert File.lstat(Path.join(root, ".loopex-restore-claim-" <> digest)) ==
                   {:error, :enoent}
        end
      else
        assert {:not_committed, "inventory_mismatch"} = outcome
        assert is_nil(release)
        assert evidence.restore.intent == false and evidence.claim_count == 2
        assert File.lstat(Path.join(destination, ".loopex-restore")) == {:error, :enoent}

        assert {:error, :restore_incomplete} =
                 Loopex.Executor.Local.RestoreGuard.state(destination)

        refute Enum.any?(events, fn {_actor, event} ->
                 match?({:issued, _, {:restore_phase, "destination_intent"}}, event)
               end)
      end

      for state_root <- [source, backup] do
        assert expected_manifest(state_root, paths) == baseline

        for relative <- paths do
          path = if relative == ".", do: state_root, else: Path.join(state_root, relative)
          assert placement.(path) == original[state_root][relative]

          destination_path =
            if relative == ".", do: destination, else: Path.join(destination, relative)

          refute placement.(destination_path) == original[state_root][relative]
        end
      end

      assert special_mode_manifest(backup, paths) == baseline
      acknowledged = for {_actor, {:acknowledged, _, kind, status}} <- events, do: {kind, status}

      assert Enum.count(acknowledged, fn {kind, status} ->
               match?({:close, _}, kind) and status == :closed
             end) == evidence.closes

      assert Enum.count(acknowledged, &(&1 == {:file_sync, :completed})) >= map_size(contents)
      assert Enum.count(acknowledged, &(&1 == {:directory_sync, :completed})) >= 4

      if copied == baseline do
        administrative =
          ~w(.loopex-restore .loopex-restore/lineage .loopex-restore/lineage/00000001)

        source_additions =
          administrative ++
            Enum.map(
              ~w(intent source-retirement),
              &Path.join(".loopex-restore/lineage/00000001", &1)
            )

        destination_additions =
          administrative ++
            Enum.map(
              ~w(baseline intent source-retirement committed),
              &Path.join(".loopex-restore/lineage/00000001", &1)
            )

        for {state_root, additions} <- [
              {source, source_additions},
              {destination, destination_additions}
            ] do
          full = special_mode_manifest(state_root, Enum.sort(paths ++ additions))
          assert {:ok, full_entries} = RestoreCodec.manifest(full, 1_048_576)

          for entry <- full_entries, entry["path"] in additions do
            assert entry["mode"] == if(entry["kind"] == "directory", do: 0o700, else: 0o600)
          end
        end

        assert expected_manifest(destination, paths) == baseline
      else
        assert special_mode_manifest(source, paths) == baseline
        assert special_mode_manifest(destination, paths) == copied
      end
    end
  end

  test "both regular-file publication paths reapply the full mode after the final payload write",
       context do
    root = physical_root(context.root)
    original = "retained original bytes"
    candidate = :binary.copy("candidate-", 100)

    for kind <- [:publish, :restore_publish] do
      path = Path.join(root, Atom.to_string(kind))
      File.write!(path, original)

      assert {"", 0} =
               System.cmd("python3", [
                 "-c",
                 "import os,sys; os.chmod(sys.argv[1],0o4750)",
                 path
               ])

      assert Bitwise.band(File.lstat!(path).mode, 0o7777) == 0o4750

      operation =
        case kind do
          :publish -> {:publish, path, path <> ".tmp", candidate, 0o4750, original}
          :restore_publish -> {:restore_publish, :generation, path, candidate, 0o4750, original}
        end

      owned = launch(operation, :mode)
      assert {{:joined, {:ok, digest}, %{opens: opens, closes: opens}}, events} = drive(owned)
      joined(owned)
      assert digest == hash(candidate)
      kinds = issued_kinds(events)
      assert [initial_mode, final_mode] = for({:mode, at} <- Enum.with_index(kinds), do: at)
      writes = for {:write, at} <- Enum.with_index(kinds), do: at
      assert initial_mode < hd(writes)
      assert List.last(writes) < final_mode
      assert final_mode < index(kinds, :file_sync)
      assert index(kinds, :file_sync) < index(kinds, :rename)
      assert File.read!(path) == candidate
      assert Bitwise.band(File.lstat!(path).mode, 0o7777) == 0o4750
      assert opens > 0
      refute File.exists?(path <> ".tmp")
    end
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
    fixture = store_fixture(context.root, 2)
    [first, second] = fixture.ids
    assert first < second
    head = fixture.state.sessions[second]

    {:ok, owner} =
      Store.advance_owner(second, "owner", "invalid-history-owner", 0,
        head.journal_version, "invalid-history-owner")

    assert {:new, _, _, {:committed, _, _}} = State.prepare(fixture.state, owner)
    fixture = append_transaction(fixture, owner)
    head = fixture.state.sessions[second]

    # Concept: Store validity does not establish session-history validity.
    # Technical depth: a current genesis record is invalid after the real
    # genesis and owner succession; the correctly fenced Store still commits it.
    {:ok, transaction} =
      Store.session_commit(second, "session", "invalid-history", head.owner_epoch,
        head.owner_incarnation_id, head.journal_version,
        [%{kind: "session_genesis_v3"}], [])

    assert {:new, _, _, {:committed, _, _}} = State.prepare(fixture.state, transaction)
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

  test "selected receipt capture preserves actual Local writer bytes after source loss",
       context do
    for job_id <- [<<255, 0, 128>> <> "capture", :binary.copy(<<255>>, 8_192)] do
      fixture = receipt_fixture(context.root, job_id)
      owned = launch(receipt_operation(fixture), :receipt_decode)
      assert {{:joined, {:ok, receipt}, evidence}, events} = drive(owned)
      assert receipt == fixture.receipt and receipt.job_id == job_id
      assert evidence.opens == 1 and evidence.closes == 1
      assert evidence.work_cutoff == owned.work_cutoff
      kinds = issued_kinds(events)
      assert index(kinds, :close) < index(kinds, :receipt_decode)
      assert Enum.count(kinds, &(&1 == :receipt_decode)) == 1
      assert File.read!(fixture.path) == fixture.bytes
      refute File.exists?(fixture.original)
      joined(owned)
    end
  end

  test "selected receipt requires exact current manifest membership and bounded raw identity",
       context do
    fixture = receipt_fixture(context.root)
    {:audit_selected_receipt, root, job_id, manifest} = receipt_operation(fixture)

    for invalid <- [nil, "", :binary.copy("x", 8_193)] do
      operation = {:audit_selected_receipt, root, invalid, manifest}
      result = RestoreIO.run(operation, limits(1_000, 100), probe: self())
      assert {:error, :invalid_io_request} = result
    end

    refute_receive {:restore_io, _, _, _, _}, 0
    [domain, entries] = :erlang.binary_to_term(manifest, [:safe])
    relative = Path.relative_to(fixture.path, root)

    for changed <- [
          Enum.reject(entries, &(&1["path"] == relative)),
          Enum.map(entries, fn entry ->
            if entry["path"] == "receipts",
              do: %{entry | "mode" => Bitwise.bxor(entry["mode"], 0o100)},
              else: entry
          end)
        ] do
      operation =
        {:audit_selected_receipt, root, job_id,
         :erlang.term_to_binary([domain, changed], [:deterministic])}

      owned = launch(operation, :receipt_manifest)
      assert {{:joined, {:error, :io_error}, %{opens: 0, closes: 0}}, events} = drive(owned)
      refute :receipt_decode in issued_kinds(events)
      joined(owned)
    end

    owned = launch({:audit_selected_receipt, root, job_id, <<131>>}, :receipt_manifest)
    assert {{:joined, {:error, :history_invalid}, %{opens: 0, closes: 0}}, _} = drive(owned)
    joined(owned)
  end

  test "selected receipt filename binds the exact raw job without authority inference", context do
    fixture = receipt_fixture(context.root, <<255, 0>> <> "original")
    wrong = fixture.job_id <> <<0>>
    path = receipt_path(fixture.root, wrong)
    File.cp!(fixture.path, path)
    selected = %{fixture | job_id: wrong, path: path}
    owned = launch(receipt_operation(selected), :receipt_decode)
    assert {{:joined, {:error, :history_invalid}, %{opens: 1, closes: 1}}, _} = drive(owned)
    assert File.read!(path) == fixture.bytes
    joined(owned)
  end

  test "selected receipt exact cap is a decoder control and over-cap refuses before open",
       context do
    fixture = receipt_fixture(context.root)
    assert Loopex.Store.max_item_bytes() == 65_536

    control = %{
      fixture.receipt
      | tool_id: "loopex.demo.write",
        tool_version: "1.0.0",
        child_environment_names: ["PATH"],
        artifacts: [],
        output: <<>>
    }

    width = 65_536 - byte_size(:erlang.term_to_binary(control, [:deterministic]))
    receipt = %{control | output: :binary.copy("x", width)}
    bytes = :erlang.term_to_binary(receipt, [:deterministic])
    assert byte_size(bytes) == 65_536
    assert {:ok, ^receipt} = Loopex.Executor.Local.decode_receipt_bytes(bytes)
    # Concept: rewritten demonstration receipt is a physical decoder control.
    # Technical depth: the executor did not publish this changed tool/output. Both
    # capture and manifest use its actual bytes; no selected filename grants finality.
    File.write!(fixture.path, bytes)
    owned = launch(receipt_operation(fixture), :receipt_decode)
    assert {{:joined, {:ok, ^receipt}, %{opens: 1, closes: 1}}, _} = drive(owned)
    joined(owned)
    File.write!(fixture.path, bytes <> <<0>>)
    owned = launch(receipt_operation(fixture), :receipt_manifest)
    assert {{:joined, {:error, :io_error}, %{opens: 0, closes: 0}}, events} = drive(owned)
    refute :read in issued_kinds(events)
    refute :receipt_decode in issued_kinds(events)
    assert File.stat!(fixture.path).size == 65_537
    joined(owned)
  end

  test "selected receipt size mode content and manifest hash guard actual raw bytes", context do
    fixture = receipt_fixture(context.root)
    mode = Bitwise.band(File.lstat!(fixture.path).mode, 0o7777)

    for change <- [:size, :mode, :content, :digest] do
      File.write!(fixture.path, fixture.bytes)
      File.chmod!(fixture.path, mode)
      operation = receipt_operation(fixture)

      altered =
        case change do
          :size ->
            File.write!(fixture.path, fixture.bytes <> <<0>>)
            operation

          :mode ->
            File.chmod!(fixture.path, Bitwise.bxor(mode, 0o100))
            operation

          :content ->
            File.write!(fixture.path, :binary.copy(<<0>>, byte_size(fixture.bytes)))
            operation

          :digest ->
            {:audit_selected_receipt, root, job_id, manifest} = operation
            [domain, entries] = :erlang.binary_to_term(manifest, [:safe])
            relative = Path.relative_to(fixture.path, root)

            changed =
              Enum.map(entries, fn entry ->
                if entry["path"] == relative,
                  do: %{entry | "sha256" => String.duplicate("0", 64)},
                  else: entry
              end)

            {:audit_selected_receipt, root, job_id,
             :erlang.term_to_binary([domain, changed], [:deterministic])}
        end

      owned = launch(altered, :receipt_manifest)
      assert {{:joined, {:error, :io_error}, evidence}, events} = drive(owned)
      assert evidence.opens == evidence.closes
      refute :receipt_decode in issued_kinds(events)
      joined(owned)
    end
  end

  test "selected receipt hardlinks symlinks FIFO and symlink parents refuse before open",
       context do
    fixture = receipt_fixture(context.root)
    operation = receipt_operation(fixture)
    path = fixture.path
    other = Path.join(fixture.root, "other")
    File.ln!(path, other)
    owned = launch(operation, :receipt_manifest)
    assert {{:joined, {:error, :io_error}, %{opens: 0, closes: 0}}, _} = drive(owned)
    joined(owned)
    File.rm!(other)
    File.rename!(path, other)
    File.ln_s!(other, path)
    owned = launch(operation, :receipt_manifest)
    assert {{:joined, {:error, :io_error}, %{opens: 0, closes: 0}}, _} = drive(owned)
    joined(owned)
    File.rm!(path)
    assert {_, 0} = System.cmd("mkfifo", [path])
    owned = launch(operation, :receipt_manifest)
    assert {{:joined, {:error, :io_error}, %{opens: 0, closes: 0}}, _} = drive(owned)
    joined(owned)
    File.rm!(path)
    File.rename!(other, path)
    File.rename!(Path.dirname(path), Path.dirname(path) <> "-moved")
    File.ln_s!(Path.dirname(path) <> "-moved", Path.dirname(path))
    owned = launch(operation, :receipt_manifest)
    assert {{:joined, {:error, :io_error}, %{opens: 0, closes: 0}}, _} = drive(owned)
    joined(owned)
  end

  test "selected receipt descriptor and post-decode rechecks refuse replacements", context do
    for change <- [:descriptor, :file, :parent, :external_ancestor] do
      fixture = receipt_fixture(context.root)
      pause = if change == :descriptor, do: :descriptor_stat, else: :receipt_decode
      owned = launch(receipt_operation(fixture), pause)
      {id, _} = paused_operation(owned, pause)

      case change do
        :parent ->
          directory = Path.dirname(fixture.path)
          File.rename!(directory, directory <> "-moved")
          File.mkdir!(directory)

          File.rename!(
            Path.join(directory <> "-moved", Path.basename(fixture.path)),
            fixture.path
          )

        :external_ancestor ->
          parent = Path.dirname(fixture.root)
          moved = parent <> "-moved-#{System.unique_integer([:positive])}"
          File.rename!(parent, moved)
          File.mkdir!(parent)
          File.rename!(Path.join(moved, Path.basename(fixture.root)), fixture.root)
          on_exit(fn -> File.rm_rf!(moved) end)

        _ ->
          replacement = fixture.path <> ".replacement"
          File.write!(replacement, fixture.bytes)
          File.chmod!(replacement, Bitwise.band(File.lstat!(fixture.path).mode, 0o7777))
          File.rename!(replacement, fixture.path)
      end

      send(owned.guardian, {:proceed, owned.reference, id})
      assert {{:joined, {:error, :io_error}, %{opens: 1, closes: 1}}, events} = drive(owned)
      if change == :descriptor, do: refute(:receipt_decode in issued_kinds(events))
      joined(owned)
    end
  end

  test "selected physical receipt equality still refuses canonical and semantic corruption",
       context do
    fixture = receipt_fixture(context.root)
    malformed = %{fixture.receipt | cleanup_confirmation: :unconfirmed, outcome: :completed}

    # These representative rewritten controls exercise the capture-to-decoder
    # boundary; the complete current receipt grammar remains Local's own suite.
    for bytes <- [
          :erlang.term_to_binary(fixture.receipt, [:deterministic, :compressed]),
          fixture.bytes <> <<0>>,
          <<131>>,
          :erlang.term_to_binary(malformed, [:deterministic])
        ] do
      File.write!(fixture.path, bytes)
      owned = launch(receipt_operation(fixture), :receipt_decode)

      assert {{:joined, {:error, :history_invalid}, %{opens: 1, closes: 1}}, events} =
               drive(owned)

      assert :receipt_decode in issued_kinds(events)
      assert File.read!(fixture.path) == bytes
      joined(owned)
    end
  end

  test "selected receipt semantics spend only the original work and cleanup cutoffs", context do
    fixture = receipt_fixture(context.root)
    owned = launch(receipt_operation(fixture), :receipt_decode, 500)
    paused_operation(owned, :receipt_decode)
    assert {{:joined, {:error, :deadline}, evidence}, events} = drive(owned, false)
    assert evidence.opens == 1 and evidence.closes == 1
    assert evidence.work_cutoff == owned.work_cutoff

    assert {:stopping, :deadline, stop, cleanup} =
             Enum.find(events, &match?({:stopping, :deadline, _, _}, &1))

    assert cleanup == stop + 10_000 and evidence.cleanup_cutoff == cleanup
    joined(owned)
  end

  test "artifact use capture preserves actual writer bytes after original root deletion",
       context do
    for bytes <- [<<>>, "retained text", <<0, 255, 128>>] do
      metadata = artifact_metadata()
      fixture = artifact_fixture(context.root, bytes, [metadata, %{metadata | "attempt" => 2}])
      [first, second] = fixture.references
      assert first.digest == second.digest
      refute first.use_digest == second.use_digest
      File.write!(Path.join(fixture.root, "orphan-object"), "unreferenced")
      File.write!(Path.join(fixture.root, "staging.tmp"), "unfinished")
      File.mkdir!(Path.join(fixture.root, "empty-directory"))

      for {reference, use} <- Enum.zip(fixture.references, fixture.uses) do
        selected = %{
          fixture
          | reference: reference,
            use: use,
            path: artifact_use_path(fixture.root, reference)
        }

        owned = launch(artifact_operation(selected), :artifact_describe)
        assert {{:joined, {:ok, ^use}, %{opens: 1, closes: 1}}, events} = drive(owned)
        kinds = issued_kinds(events)
        assert index(kinds, :close) < index(kinds, :artifact_describe)

        assert use.metadata ==
                 Map.drop(
                   if(reference == first, do: metadata, else: %{metadata | "attempt" => 2}),
                   ["role", "media_type"]
                 )

        assert File.read!(selected.path) ==
                 LoopexProtocol.Canonical.encode(["artifact-use-v2", use])

        joined(owned)
      end

      assert File.read!(Path.join(fixture.root, "orphan-object")) == "unreferenced"
      assert File.read!(Path.join(fixture.root, "staging.tmp")) == "unfinished"
      assert File.dir?(Path.join(fixture.root, "empty-directory"))
      refute File.exists?(fixture.original)
    end
  end

  test "selected artifact use does not certify objects or narrow the uint64 use size grammar",
       context do
    fixture = artifact_fixture(context.root)

    object =
      Path.join([
        fixture.root,
        "artifacts",
        binary_part(fixture.reference.digest, 0, 2),
        fixture.reference.digest
      ])

    File.rm!(object)

    for size <- [67_108_865, 18_446_744_073_709_551_615] do
      # These writer-derived semantic controls change the retained use, not an
      # actual oversized Local publication. Object proof remains a separate step.
      use = %{fixture.use | object_size: size}
      reference = %{fixture.reference | size: size}
      selected = artifact_use_control(fixture, use, reference)
      owned = launch(artifact_operation(selected), :artifact_describe)
      assert {{:joined, {:ok, ^use}, %{opens: 1, closes: 1}}, _} = drive(owned)
      joined(owned)
    end

    refute File.exists?(object)
  end

  test "artifact reference closure precedes path selection and opens no file", context do
    fixture = artifact_fixture(context.root)
    {:audit_artifact_use, root, reference, manifest} = artifact_operation(fixture)

    for changed <- [
          Map.put(reference, :extra, true),
          Map.delete(reference, :digest),
          %{reference | use_digest: String.duplicate("A", 64)},
          %{reference | use_digest: "../unsafe"},
          %{reference | use_locator: "use:" <> String.duplicate("0", 64)},
          %{reference | use_canonicalization_version: "loopex.canonical.future"},
          %{reference | role: "input"},
          %{reference | size: -1},
          %{reference | size: 18_446_744_073_709_551_616}
        ] do
      owned = launch({:audit_artifact_use, root, changed, manifest}, :artifact_reference)

      assert {{:joined, {:error, :history_invalid}, %{opens: 0, closes: 0}}, events} =
               drive(owned)

      refute :artifact_manifest in issued_kinds(events)
      refute :artifact_describe in issued_kinds(events)
      joined(owned)
    end

    assert {:error, :invalid_io_request} =
             RestoreIO.run({:audit_artifact_use, root, nil, manifest}, limits(1_000, 100),
               probe: self()
             )

    refute_receive {:restore_io, _, _, _, _}
  end

  test "artifact selection requires canonical file membership and all parent modes", context do
    fixture = artifact_fixture(context.root)
    {:audit_artifact_use, root, reference, manifest} = artifact_operation(fixture)
    [domain, entries] = :erlang.binary_to_term(manifest, [:safe])
    relative = Path.relative_to(fixture.path, root)
    parent = Path.dirname(relative)

    for changed <- [
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
        ] do
      altered = :erlang.term_to_binary([domain, changed], [:deterministic])
      owned = launch({:audit_artifact_use, root, reference, altered}, :artifact_manifest)
      assert {{:joined, {:error, reason}, %{opens: 0, closes: 0}}, events} = drive(owned)
      assert reason in [:io_error, :history_invalid]
      refute :artifact_describe in issued_kinds(events)
      joined(owned)
    end

    File.rename!(fixture.path, fixture.path <> ".etf")
    owned = launch(artifact_operation(fixture), :artifact_manifest)
    assert {{:joined, {:error, :io_error}, %{opens: 0, closes: 0}}, _} = drive(owned)
    joined(owned)
  end

  test "artifact selected digest must authenticate the actual canonical filename bytes",
       context do
    fixture = artifact_fixture(context.root)
    wrong = String.duplicate("0", 64)
    reference = %{fixture.reference | use_digest: wrong, use_locator: "use:" <> wrong}
    path = artifact_use_path(fixture.root, reference)
    File.mkdir_p!(Path.dirname(path))
    File.cp!(fixture.path, path)
    selected = %{fixture | reference: reference, path: path}
    owned = launch(artifact_operation(selected), :artifact_describe)
    assert {{:joined, {:error, :history_invalid}, %{opens: 1, closes: 1}}, _} = drive(owned)
    assert File.read!(path) == fixture.bytes
    joined(owned)
  end

  test "artifact use actual writer cap succeeds and first over-cap refuses before open",
       context do
    seed = artifact_fixture(context.root)
    assert Loopex.ArtifactStore.max_use_bytes() == 131_072
    metadata = artifact_metadata()
    width = 131_072 - byte_size(seed.bytes) + byte_size(metadata["session_id"])
    metadata = %{metadata | "session_id" => :binary.copy("s", width)}
    fixture = artifact_fixture(context.root, "captured object", [metadata])
    assert byte_size(fixture.bytes) == 131_072
    owned = launch(artifact_operation(fixture), :artifact_describe)
    assert {{:joined, {:ok, use}, %{opens: 1, closes: 1}}, _} = drive(owned)
    assert use == fixture.use
    joined(owned)

    # The negative file and checked physical manifest agree on all 131073 bytes;
    # admission must refuse its role ceiling before any raw descriptor is opened.
    File.write!(fixture.path, fixture.bytes <> <<0>>)
    owned = launch(artifact_operation(fixture), :artifact_manifest)
    assert {{:joined, {:error, :io_error}, %{opens: 0, closes: 0}}, events} = drive(owned)
    refute :read in issued_kinds(events)
    refute :artifact_describe in issued_kinds(events)
    assert File.stat!(fixture.path).size == 131_073
    joined(owned)
  end

  test "artifact use capture checks physical size mode contents and manifest hash", context do
    fixture = artifact_fixture(context.root)
    mode = Bitwise.band(File.stat!(fixture.path).mode, 0o7777)

    for change <- [:size, :mode, :content, :digest] do
      File.write!(fixture.path, fixture.bytes)
      File.chmod!(fixture.path, mode)
      operation = artifact_operation(fixture)

      altered =
        case change do
          :size ->
            File.write!(fixture.path, fixture.bytes <> <<0>>)
            operation

          :mode ->
            File.chmod!(fixture.path, Bitwise.bxor(mode, 0o100))
            operation

          :content ->
            File.write!(fixture.path, :binary.copy(<<0>>, byte_size(fixture.bytes)))
            operation

          :digest ->
            {:audit_artifact_use, root, reference, manifest} = operation
            [domain, entries] = :erlang.binary_to_term(manifest, [:safe])
            relative = Path.relative_to(fixture.path, root)

            changed =
              Enum.map(entries, fn entry ->
                if entry["path"] == relative,
                  do: %{entry | "sha256" => String.duplicate("0", 64)},
                  else: entry
              end)

            {:audit_artifact_use, root, reference,
             :erlang.term_to_binary([domain, changed], [:deterministic])}
        end

      owned = launch(altered, :artifact_manifest)
      assert {{:joined, {:error, :io_error}, evidence}, events} = drive(owned)
      assert evidence.opens == evidence.closes
      refute :artifact_describe in issued_kinds(events)
      joined(owned)
    end
  end

  test "artifact hardlink symlink FIFO and symlink parent substitutions refuse before open",
       context do
    fixture = artifact_fixture(context.root)
    operation = artifact_operation(fixture)
    path = fixture.path
    other = Path.join(fixture.root, "other")
    File.ln!(path, other)
    owned = launch(operation, :artifact_manifest)
    assert {{:joined, {:error, :io_error}, %{opens: 0, closes: 0}}, _} = drive(owned)
    joined(owned)
    File.rm!(other)
    File.rename!(path, other)
    File.ln_s!(other, path)
    owned = launch(operation, :artifact_manifest)
    assert {{:joined, {:error, :io_error}, %{opens: 0, closes: 0}}, _} = drive(owned)
    joined(owned)
    File.rm!(path)
    assert {_, 0} = System.cmd("mkfifo", [path])
    owned = launch(operation, :artifact_manifest)
    assert {{:joined, {:error, :io_error}, %{opens: 0, closes: 0}}, _} = drive(owned)
    joined(owned)
    File.rm!(path)
    File.rename!(other, path)
    directory = Path.dirname(path)
    File.rename!(directory, directory <> "-moved")
    File.ln_s!(directory <> "-moved", directory)
    owned = launch(operation, :artifact_manifest)
    assert {{:joined, {:error, :io_error}, %{opens: 0, closes: 0}}, _} = drive(owned)
    joined(owned)
  end

  test "artifact opened descriptor and post-describe identities prevent replacement", context do
    for change <- [:descriptor, :file, :parent, :external_ancestor] do
      fixture = artifact_fixture(context.root)
      pause = if change == :descriptor, do: :descriptor_stat, else: :artifact_describe
      owned = launch(artifact_operation(fixture), pause)
      {id, _} = paused_operation(owned, pause)

      case change do
        :parent ->
          directory = Path.dirname(fixture.path)
          File.rename!(directory, directory <> "-moved")
          File.mkdir!(directory)

          File.rename!(
            Path.join(directory <> "-moved", Path.basename(fixture.path)),
            fixture.path
          )

        :external_ancestor ->
          parent = Path.dirname(fixture.root)
          moved = parent <> "-moved-#{System.unique_integer([:positive])}"
          File.rename!(parent, moved)
          File.mkdir!(parent)
          File.rename!(Path.join(moved, Path.basename(fixture.root)), fixture.root)
          on_exit(fn -> File.rm_rf!(moved) end)

        _ ->
          replacement = fixture.path <> ".replacement"
          File.write!(replacement, fixture.bytes)
          File.chmod!(replacement, Bitwise.band(File.stat!(fixture.path).mode, 0o7777))
          File.rename!(replacement, fixture.path)
      end

      send(owned.guardian, {:proceed, owned.reference, id})
      assert {{:joined, {:error, :io_error}, %{opens: 1, closes: 1}}, events} = drive(owned)
      if change == :descriptor, do: refute(:artifact_describe in issued_kinds(events))
      joined(owned)
    end
  end

  test "artifact physical equality cannot admit hostile or alternate current transport",
       context do
    fixture = artifact_fixture(context.root)
    ordered = :erlang.binary_to_term(fixture.bytes, [:safe])
    compressed = :erlang.term_to_binary(ordered, [:deterministic, :compressed])
    assert <<131, 80, _::binary>> = compressed

    for bytes <- [
          compressed,
          fixture.bytes <> <<0>>,
          <<131>>,
          :erlang.term_to_binary(fixture.use, [:deterministic])
        ] do
      File.write!(fixture.path, bytes)
      owned = launch(artifact_operation(fixture), :artifact_describe)

      assert {{:joined, {:error, :history_invalid}, %{opens: 1, closes: 1}}, events} =
               drive(owned)

      assert index(issued_kinds(events), :close) < index(issued_kinds(events), :artifact_describe)
      assert File.read!(fixture.path) == bytes
      joined(owned)
    end
  end

  test "artifact captured transport alone cannot substitute for real Core use closure", context do
    fixture = artifact_fixture(context.root)
    use = fixture.use

    changed_uses =
      [
        Map.put(use, :extra, true),
        Map.delete(use, :metadata),
        %{use | canonicalization_version: "loopex.canonical.future"},
        %{use | object_digest: String.duplicate("a", 64)},
        %{use | object_size: use.object_size + 1},
        %{use | object_locator: "different-object"},
        %{use | media_type: "text/plain"},
        %{use | role: "input"},
        %{use | media_type: :invalid_media_type},
        %{use | metadata: Map.put(use.metadata, "extra", true)},
        %{use | metadata: Map.delete(use.metadata, "attempt")},
        %{use | metadata: %{use.metadata | "attempt" => 0}},
        %{use | metadata: %{use.metadata | "run_id" => :existing_atom}}
      ] ++
        Enum.map(~w(session_id run_id operation_id tool_call_id), fn field ->
          %{use | metadata: Map.put(use.metadata, field, "")}
        end)

    for changed <- changed_uses do
      selected = artifact_use_control(fixture, changed, fixture.reference)

      assert {:ok, ^changed} =
               Loopex.Store.Local.Artifacts.decode_use_bytes(
                 selected.bytes,
                 selected.reference.use_digest
               )

      owned = launch(artifact_operation(selected), :artifact_describe)
      assert {{:joined, {:error, :history_invalid}, %{opens: 1, closes: 1}}, _} = drive(owned)
      joined(owned)
    end
  end

  test "artifact compact object facts must agree with the selected unchanged use", context do
    fixture = artifact_fixture(context.root)

    for reference <- [
          %{fixture.reference | digest: String.duplicate("a", 64)},
          %{fixture.reference | size: fixture.reference.size + 1},
          %{fixture.reference | locator: "different-object"},
          %{fixture.reference | media_type: "text/plain"}
        ] do
      assert Loopex.ArtifactStore.valid_reference?(reference)
      owned = launch(artifact_operation(%{fixture | reference: reference}), :artifact_describe)
      assert {{:joined, {:error, :history_invalid}, %{opens: 1, closes: 1}}, _} = drive(owned)
      joined(owned)
    end
  end

  test "artifact semantic permit retains the original work cutoff after explicit close",
       context do
    fixture = artifact_fixture(context.root)
    owned = launch(artifact_operation(fixture), :artifact_describe, 500)
    paused_operation(owned, :artifact_describe)
    assert {{:joined, {:error, :deadline}, %{opens: 1, closes: 1}}, _} = drive(owned, false)
    joined(owned)
  end

  test "real artifact describe synchronous telemetry remains within the original semantic lifetime",
       context do
    fixture = artifact_fixture(context.root)
    parent = self()
    handler = "restore-artifact-describe-#{System.unique_integer([:positive])}"

    assert :ok =
             :telemetry.attach(
               handler,
               [:loopex, :artifact, :describe, :start],
               &__MODULE__.pause_artifact_describe/4,
               parent
             )

    on_exit(fn -> :telemetry.detach(handler) end)
    owned = launch(artifact_operation(fixture), :artifact_describe, 500)
    {id, _} = paused_operation(owned, :artifact_describe)
    send(owned.guardian, {:proceed, owned.reference, id})
    assert_receive {:artifact_describe_entered, worker, metadata}, 1_000
    assert worker == owned.worker
    assert metadata == %{use_locator: fixture.reference.use_locator}
    guardian = owned.guardian
    reference = owned.reference

    assert_receive {:restore_io, ^guardian, ^worker, ^reference,
                    {:stopping, :deadline, stop, cleanup}},
                   1_000

    assert stop >= owned.work_cutoff
    assert cleanup == stop + 10_000
    send(worker, :continue_artifact_describe)
    assert {{:joined, {:error, :deadline}, %{opens: 1, closes: 1}}, _} = drive(owned, false)
    joined(owned)
    assert :ok = :telemetry.detach(handler)
  end

  test "artifact object streaming binds actual Local writer bytes after source deletion",
       context do
    for bytes <- [
          <<>>,
          "retained text",
          :binary.copy(<<0, 255>>, 32_768),
          :binary.copy("x", 65_537)
        ] do
      metadata = artifact_metadata()
      fixture = artifact_fixture(context.root, bytes, [metadata, %{metadata | "attempt" => 2}])
      File.write!(Path.join(fixture.root, "orphan-object"), "unreferenced")
      File.write!(Path.join(fixture.root, "staging.tmp"), "unfinished")
      File.mkdir!(Path.join(fixture.root, "empty-directory"))
      operation = artifact_object_operation(fixture)
      {:audit_artifact_object, _, _, baseline, _} = operation
      object = Map.take(fixture.reference, [:digest, :size, :locator])
      owned = launch(operation, :artifact_object_digest)
      assert {{:joined, {:ok, ^object}, %{opens: 1, closes: 1}}, events} = drive(owned)
      kinds = issued_kinds(events)
      assert Enum.count(kinds, &(&1 == :hash_read)) == div(byte_size(bytes) + 65_535, 65_536) + 1
      refute :read in kinds
      refute :artifact_describe in kinds
      assert index(kinds, :close) < index(kinds, :artifact_object_digest)
      assert File.read!(artifact_object_path(fixture.root, fixture.reference)) == bytes
      assert File.read!(Path.join(fixture.root, "orphan-object")) == "unreferenced"
      assert File.read!(Path.join(fixture.root, "staging.tmp")) == "unfinished"
      assert File.dir?(Path.join(fixture.root, "empty-directory"))

      assert {:joined, {:ok, ^baseline}, _} =
               RestoreIO.run({:manifest, fixture.root, 1_048_576}, limits(1_000, 100))

      refute File.exists?(fixture.original)
      joined(owned)
    end
  end

  test "artifact object above the Local writer cap remains an actual streaming reader control",
       context do
    fixture = artifact_fixture(context.root, "seed")
    size = 67_108_865
    locator = hash("large-reader:" <> fixture.reference.digest)
    reference = %{fixture.reference | locator: locator, size: size}
    path = artifact_object_path(fixture.root, reference)
    File.mkdir_p!(Path.dirname(path))
    {:ok, descriptor} = :file.open(path, [:raw, :binary, :write])

    # This actual physical reader-domain control derives a use from the writer
    # seed. Local put did not publish an object exceeding its unchanged cap.
    context =
      try do
        chunk = :binary.copy("r", 65_536)

        context =
          Enum.reduce(1..1_024, :crypto.hash_init(:sha256), fn _, context ->
            assert :ok = :file.write(descriptor, chunk)
            :crypto.hash_update(context, chunk)
          end)

        assert :ok = :file.write(descriptor, "r")
        :crypto.hash_update(context, "r")
      after
        assert :ok = :file.close(descriptor)
      end

    digest = :crypto.hash_final(context) |> Base.encode16(case: :lower)
    reference = %{reference | digest: digest}
    use = %{fixture.use | object_locator: locator, object_digest: digest, object_size: size}
    selected = artifact_use_control(fixture, use, reference)
    assert File.stat!(path).size == size
    assert size == Loopex.Store.Local.Artifacts.max_bytes() + 1
    operation = artifact_object_operation(selected, size + 1_048_576)
    object = Map.take(selected.reference, [:digest, :size, :locator])
    owned = launch(operation, :artifact_object_digest)
    assert {{:joined, {:ok, ^object}, %{opens: 1, closes: 1}}, events} = drive(owned)
    kinds = issued_kinds(events)
    assert Enum.count(kinds, &(&1 == :hash_read)) == 1_026
    refute :read in kinds
    joined(owned)
  end

  test "artifact object locator-selected audit preserves current direct-fetch alias semantics",
       context do
    bytes = "actual writer bytes at an alternate admitted reader locator"
    fixture = artifact_fixture(context.root, bytes)
    locator = hash("reader-locator:" <> fixture.reference.digest)
    refute locator == fixture.reference.digest
    reference = %{fixture.reference | locator: locator}
    path = artifact_object_path(fixture.root, reference)
    File.mkdir_p!(Path.dirname(path))
    File.rename!(artifact_object_path(fixture.root, fixture.reference), path)

    # Concept: this is a reader-admission vector derived from real writer bytes.
    # Technical depth: Local put still issued digest==locator; only the selected
    # baseline path and current use/reference are deliberately retargeted here.
    selected = artifact_use_control(fixture, %{fixture.use | object_locator: locator}, reference)
    assert {:ok, handle} = Loopex.Store.Local.Artifacts.open(Path.join(fixture.root, "artifacts"))
    store = %{module: Loopex.Store.Local.Artifacts, handle: handle}
    assert {:ok, ^bytes} = Loopex.ArtifactStore.fetch(store, selected.reference)
    assert {:error, :artifact_integrity_failed} = Loopex.ArtifactStore.stat(store, locator)
    assert {:ok, use} = Loopex.ArtifactStore.describe(store, selected.reference)
    assert use == selected.use
    object = Map.take(selected.reference, [:digest, :size, :locator])
    owned = launch(artifact_object_operation(selected), :artifact_object_digest)
    assert {{:joined, {:ok, ^object}, %{opens: 1, closes: 1}}, _} = drive(owned)
    assert File.read!(path) == bytes
    joined(owned)
  end

  test "artifact object reference and Local locator admission precede manifest and path access",
       context do
    fixture = artifact_fixture(context.root)
    {:audit_artifact_object, root, reference, manifest, cap} = artifact_object_operation(fixture)

    for changed <- [
          Map.put(reference, :extra, true),
          Map.delete(reference, :digest),
          %{reference | digest: String.duplicate("A", 64)},
          %{reference | size: -1},
          %{reference | size: 18_446_744_073_709_551_616},
          %{reference | locator: "../unsafe"},
          %{reference | locator: "x"},
          %{reference | locator: String.duplicate("z", 64)},
          %{reference | locator: "line\nbreak"}
        ] do
      owned = launch({:audit_artifact_object, root, changed, manifest, cap}, :artifact_reference)

      assert {{:joined, {:error, :history_invalid}, %{opens: 0, closes: 0}}, events} =
               drive(owned)

      refute :artifact_manifest in issued_kinds(events)
      refute :hash_read in issued_kinds(events)
      joined(owned)
    end

    for invalid <- [-1, 18_446_744_073_709_551_616, "1048576"] do
      invalid_operation = {:audit_artifact_object, root, reference, manifest, invalid}

      assert {:error, :invalid_io_request} =
               RestoreIO.run(invalid_operation, limits(1_000, 100), probe: self())

      refute_receive {:restore_io, _, _, _, _}
    end
  end

  test "artifact object manifest membership and original total cap refuse before open", context do
    fixture = artifact_fixture(context.root)
    operation = artifact_object_operation(fixture)
    {:audit_artifact_object, root, reference, manifest, cap} = operation
    [domain, entries] = :erlang.binary_to_term(manifest, [:safe])
    relative = Path.relative_to(artifact_object_path(root, reference), root)
    parent = Path.dirname(relative)
    total = Enum.reduce(entries, 0, &(&1["size"] + &2))
    assert total > 0

    for changed <- [
          Enum.reject(entries, &(&1["path"] == relative)),
          Enum.reject(entries, &(&1["path"] == parent)),
          Enum.map(entries, fn entry ->
            if entry["path"] == relative,
              do: %{entry | "sha256" => String.duplicate("0", 64)},
              else: entry
          end),
          Enum.map(entries, fn entry ->
            if entry["path"] == parent,
              do: %{entry | "mode" => Bitwise.bxor(entry["mode"], 0o100)},
              else: entry
          end)
        ] do
      altered = :erlang.term_to_binary([domain, changed], [:deterministic])
      owned = launch({:audit_artifact_object, root, reference, altered, cap}, :artifact_manifest)
      assert {{:joined, {:error, reason}, %{opens: 0, closes: 0}}, events} = drive(owned)
      assert reason in [:io_error, :history_invalid]
      refute :hash_read in issued_kinds(events)
      joined(owned)
    end

    owned =
      launch({:audit_artifact_object, root, reference, manifest, total - 1}, :artifact_manifest)

    assert {{:joined, {:error, :history_invalid}, %{opens: 0, closes: 0}}, events} = drive(owned)
    refute :hash_read in issued_kinds(events)
    joined(owned)

    # Current reader sizes stay uint64; these fail physical inventory equality,
    # not an inferred writer cap. They do not claim an oversized Local put.
    for size <- [67_108_865, 18_446_744_073_709_551_615] do
      changed = %{reference | size: size}
      assert Loopex.ArtifactStore.valid_reference?(changed)
      owned = launch({:audit_artifact_object, root, changed, manifest, cap}, :artifact_manifest)
      assert {{:joined, {:error, :io_error}, %{opens: 0, closes: 0}}, events} = drive(owned)
      refute :hash_read in issued_kinds(events)
      joined(owned)
    end
  end

  test "artifact object streaming rejects same-size forged manifest content and physical disagreement",
       context do
    bytes = "payload"
    fixture = artifact_fixture(context.root, bytes)
    path = artifact_object_path(fixture.root, fixture.reference)
    mode = Bitwise.band(File.stat!(path).mode, 0o7777)

    for change <- [:content, :size, :mode] do
      File.write!(path, bytes)
      File.chmod!(path, mode)
      operation = artifact_object_operation(fixture)

      case change do
        :content -> File.write!(path, "damage!")
        :size -> File.write!(path, bytes <> "x")
        :mode -> File.chmod!(path, Bitwise.bxor(mode, 0o100))
      end

      owned = launch(operation, :artifact_manifest)
      assert {{:joined, {:error, :io_error}, evidence}, events} = drive(owned)
      assert evidence.opens == evidence.closes

      if change == :content do
        assert evidence.opens == 1
        assert :artifact_object_digest in issued_kinds(events)
      else
        assert evidence.opens == 0
      end

      joined(owned)
    end
  end

  test "artifact object exact EOF rejects growth and early EOF after descriptor admission",
       context do
    bytes = "payload"

    for change <- [:grow, :shrink] do
      fixture = artifact_fixture(context.root, bytes)
      owned = launch(artifact_object_operation(fixture), :hash_read)
      {id, :hash_read} = paused_operation(owned, :hash_read)
      path = artifact_object_path(fixture.root, fixture.reference)
      File.write!(path, if(change == :grow, do: bytes <> "x", else: "payloa"))
      send(owned.guardian, {:proceed, owned.reference, id})
      assert {{:joined, {:error, :io_error}, %{opens: 1, closes: 1}}, events} = drive(owned)
      refute :artifact_object_digest in issued_kinds(events)
      joined(owned)
    end
  end

  test "artifact object native links FIFO and symlink parent refuse before open", context do
    fixture = artifact_fixture(context.root)
    operation = artifact_object_operation(fixture)
    path = artifact_object_path(fixture.root, fixture.reference)
    other = Path.join(fixture.root, "other-object")
    File.ln!(path, other)
    owned = launch(operation, :artifact_manifest)
    assert {{:joined, {:error, :io_error}, %{opens: 0, closes: 0}}, _} = drive(owned)
    joined(owned)
    File.rm!(other)
    File.rename!(path, other)
    File.ln_s!(other, path)
    owned = launch(operation, :artifact_manifest)
    assert {{:joined, {:error, :io_error}, %{opens: 0, closes: 0}}, _} = drive(owned)
    joined(owned)
    File.rm!(path)
    assert {_, 0} = System.cmd("mkfifo", [path])
    owned = launch(operation, :artifact_manifest)
    assert {{:joined, {:error, :io_error}, %{opens: 0, closes: 0}}, _} = drive(owned)
    joined(owned)
    File.rm!(path)
    File.rename!(other, path)
    directory = Path.dirname(path)
    File.rename!(directory, directory <> "-moved")
    File.ln_s!(directory <> "-moved", directory)
    owned = launch(operation, :artifact_manifest)
    assert {{:joined, {:error, :io_error}, %{opens: 0, closes: 0}}, _} = drive(owned)
    joined(owned)
  end

  test "artifact object descriptor and post-close identities reject file parent and ancestor replacement",
       context do
    for change <- [:descriptor, :file, :parent, :external_ancestor] do
      fixture = artifact_fixture(context.root)
      path = artifact_object_path(fixture.root, fixture.reference)
      bytes = File.read!(path)
      pause = if change == :descriptor, do: :descriptor_stat, else: :artifact_object_digest
      owned = launch(artifact_object_operation(fixture), pause)
      {id, _} = paused_operation(owned, pause)

      case change do
        :parent ->
          directory = Path.dirname(path)
          File.rename!(directory, directory <> "-moved")
          File.mkdir!(directory)
          File.rename!(Path.join(directory <> "-moved", Path.basename(path)), path)

        :external_ancestor ->
          parent = Path.dirname(fixture.root)
          moved = parent <> "-moved-#{System.unique_integer([:positive])}"
          File.rename!(parent, moved)
          File.mkdir!(parent)
          File.rename!(Path.join(moved, Path.basename(fixture.root)), fixture.root)
          on_exit(fn -> File.rm_rf!(moved) end)

        _ ->
          replacement = path <> ".replacement"
          File.write!(replacement, bytes)
          File.chmod!(replacement, Bitwise.band(File.stat!(path).mode, 0o7777))
          File.rename!(replacement, path)
      end

      send(owned.guardian, {:proceed, owned.reference, id})
      assert {{:joined, {:error, :io_error}, %{opens: 1, closes: 1}}, _} = drive(owned)
      joined(owned)
    end
  end

  test "artifact object post-close comparison retains the original work cutoff", context do
    fixture = artifact_fixture(context.root)
    owned = launch(artifact_object_operation(fixture), :artifact_object_digest, 500)
    paused_operation(owned, :artifact_object_digest)
    assert {{:joined, {:error, :deadline}, %{opens: 1, closes: 1}}, _} = drive(owned, false)
    joined(owned)
  end

  test "artifact object caller loss closes and joins its exact descriptor owner", context do
    fixture = artifact_fixture(context.root)
    owned = launch(artifact_object_operation(fixture), :hash_read)
    paused_operation(owned, :hash_read)
    Process.exit(owned.caller, :kill)
    caller = owned.caller
    monitor = owned.caller_monitor
    guardian = owned.guardian
    worker = owned.worker
    reference = owned.reference
    assert_receive {:DOWN, ^monitor, :process, ^caller, :killed}, 1_000

    assert_receive {:restore_io, ^guardian, ^worker, ^reference,
                    {:terminal, {:joined, {:error, :caller_lost}, %{opens: 1, closes: 1}}}},
                   1_000

    joined(owned, false)
  end

  test "artifact object guardian loss cannot certify descriptor close or object facts", context do
    fixture = artifact_fixture(context.root)
    owned = launch(artifact_object_operation(fixture), :hash_read)
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
  end

  test "ledger index captures every actual marker and open record under one guardian", context do
    fixture = ledger_fixture(context.root)
    owned = launch(ledger_index_operation(fixture), :ledger_snapshot)
    assert {{:joined, {:ok, result}, %{opens: 4, closes: 4}}, events} = drive(owned)
    assert result.generation == fixture.records.generation

    assert result.markers ==
             Enum.sort([
               {hash(fixture.jobs.admission), fixture.records.admission},
               {hash(fixture.jobs.refusal), fixture.records.refusal}
             ])

    assert result.open == [fixture.records.open]
    refute result.claim_present
    assert Enum.count(issued_kinds(events), &(&1 == :ledger_decode)) == 4
    assert Enum.count(issued_kinds(events), &(&1 == :ledger_snapshot)) == 1

    assert index(issued_kinds(events), :ledger_decode) <
             index(issued_kinds(events), :ledger_snapshot)

    joined(owned)
  end

  test "ledger index preserves actual close restore and open-before-marker writer cuts",
       context do
    fixture = ledger_fixture(context.root)

    assert :ok =
             Ledger.with_claim(fixture.prepared, fn claimed ->
               Ledger.close_open(claimed, fixture.jobs.open)
             end)

    assert {:joined, {:ok, %{open: []}}, _} =
             RestoreIO.run(ledger_index_operation(fixture), limits(1_000, 100))

    assert :ok =
             Ledger.with_claim(fixture.prepared, fn claimed ->
               Ledger.restore_open(claimed, fixture.records.open)
             end)

    request = %{fixture.request | job_id: "partial-publication"}
    marker = Ledger.marker(request)
    open = Ledger.open_entry(request, fixture.declaration["executor_identity"])
    blocked = Path.join([fixture.prepared.root, "markers", hash(request.job_id)])
    File.mkdir!(blocked)

    assert {:error, _} =
             Ledger.with_claim(fixture.prepared, fn claimed ->
               Ledger.admit(claimed, marker, open)
             end)

    File.rmdir!(blocked)

    assert {:joined, {:ok, result}, _} =
             RestoreIO.run(ledger_index_operation(fixture), limits(1_000, 100))

    assert Enum.sort(result.open) == Enum.sort([fixture.records.open, open])
    refute List.keymember?(result.markers, hash(request.job_id), 0)

    assert File.read!(fixture.paths.admission) ==
             :erlang.term_to_binary(fixture.records.admission, [:deterministic])
  end

  test "ledger index retains a refusal alongside an unresolved open warning", context do
    fixture = ledger_fixture(context.root)
    record = %{fixture.records.open | "job_id" => fixture.jobs.refusal}

    assert :ok =
             Ledger.with_claim(fixture.prepared, fn claimed ->
               Ledger.restore_open(claimed, record)
             end)

    assert {:joined, {:ok, result}, _} =
             RestoreIO.run(ledger_index_operation(fixture), limits(1_000, 100))

    assert record in result.open
    assert {hash(fixture.jobs.refusal), fixture.records.refusal} in result.markers
  end

  test "ledger index records a current held claim without reclaiming or granting it", context do
    fixture = ledger_fixture(context.root)

    assert :ok =
             Ledger.with_claim(fixture.prepared, fn _claimed ->
               operation = ledger_index_operation(fixture)

               assert {:joined, {:ok, %{claim_present: true}}, _} =
                        RestoreIO.run(operation, limits(1_000, 100))

               assert File.dir?(Path.join(fixture.prepared.root, "claim"))
               :ok
             end)

    refute File.exists?(Path.join(fixture.prepared.root, "claim"))
  end

  test "ledger index copies retain original source binding and reject relocated descriptors",
       context do
    fixture = ledger_fixture(context.root)
    backup = fixture.root <> "-index-backup"
    File.cp_r!(fixture.root, backup)
    on_exit(fn -> File.rm_rf!(backup) end)
    copied = %{fixture | root: backup}

    assert {:joined, {:ok, %{generation: generation}}, _} =
             RestoreIO.run(ledger_index_operation(copied), limits(1_000, 100))

    assert generation == fixture.records.generation
    info = File.stat!(Path.join(backup, "ledger"))

    moved = %{
      "expanded_root" => Path.join(backup, "ledger"),
      "major_device" => info.major_device,
      "inode" => info.inode
    }

    changed = %{copied | declaration: %{copied.declaration | "source_placement" => moved}}

    assert {:joined, {:error, :history_invalid}, _} =
             RestoreIO.run(ledger_index_operation(changed), limits(1_000, 100))
  end

  test "ledger index refuses omitted inventory members and actual extra names", context do
    for change <- [:omitted, :extra] do
      fixture = ledger_fixture(context.root)
      {:audit_ledger_index, root, declaration, manifest} = ledger_index_operation(fixture)
      assert {:ok, entries} = RestoreCodec.manifest(manifest, 1_048_576)

      manifest =
        if change == :omitted do
          path = "ledger/open/" <> hash(fixture.jobs.open)
          changed = Enum.reject(entries, &(&1["path"] == path))

          assert {:ok, bytes} =
                   RestoreCodec.encode(
                     :manifest,
                     ["loopex:current-state-manifest:v1", changed]
                   )

          bytes
        else
          File.write!(Path.join([fixture.prepared.root, "open", hash("unlisted")]), "extra")
          manifest
        end

      owned = launch({:audit_ledger_index, root, declaration, manifest}, :ledger_names)
      assert {{:joined, {:error, :io_error}, %{opens: 0, closes: 0}}, events} = drive(owned)
      refute :ledger_decode in issued_kinds(events)
      joined(owned)
    end
  end

  test "ledger index requires generation and both physical directories without initialization",
       context do
    for role <- [:generation, :markers, :open] do
      fixture = ledger_fixture(context.root)
      path = Path.join(fixture.prepared.root, Atom.to_string(role))
      File.rm_rf!(path)
      owned = launch(ledger_index_operation(fixture), :ledger_names)
      assert {{:joined, {:error, :io_error}, %{opens: 0, closes: 0}}, _} = drive(owned)
      refute File.exists?(path)
      joined(owned)
    end
  end

  test "ledger index rejects nested staging and noncanonical committed names before opening",
       context do
    for {plane, name, directory?} <- [
          {"markers", hash("nested"), true},
          {"markers", hash("staged") <> ".tmp-1", false},
          {"open", String.duplicate("A", 64), false},
          {"open", "unknown", false}
        ] do
      fixture = ledger_fixture(context.root)
      path = Path.join([fixture.prepared.root, plane, name])
      if directory?, do: File.mkdir!(path), else: File.write!(path, "record")
      owned = launch(ledger_index_operation(fixture), :ledger_names)
      assert {{:joined, {:error, :io_error}, %{opens: 0, closes: 0}}, _} = drive(owned)
      joined(owned)
    end
  end

  test "ledger index preflights every role byte ceiling before opening any member", context do
    for {role, cap} <- [{:generation, 2_048}, {:admission, 65_536}, {:open, 65_536}] do
      fixture = ledger_fixture(context.root)
      File.write!(fixture.paths[role], :binary.copy(<<0>>, cap + 1))
      owned = launch(ledger_index_operation(fixture), :ledger_capacity)
      assert {{:joined, {:error, :io_error}, %{opens: 0, closes: 0}}, events} = drive(owned)
      refute :ledger_decode in issued_kinds(events)
      joined(owned)
    end
  end

  test "ledger index refuses 1025 actual open writer entries before record opening", context do
    fixture = ledger_fixture(context.root)

    assert :ok =
             Ledger.with_claim(fixture.prepared, fn claimed ->
               for number <- 1..1_024 do
                 record = %{fixture.records.open | "job_id" => "open-#{number}"}
                 assert :ok = Ledger.restore_open(claimed, record)
               end

               :ok
             end)

    owned = launch(ledger_index_operation(fixture), :ledger_capacity)
    assert {{:joined, {:error, :io_error}, %{opens: 0, closes: 0}}, events} = drive(owned)
    assert :ledger_capacity in issued_kinds(events)
    refute :ledger_decode in issued_kinds(events)
    joined(owned)
  end

  test "ledger marker retention does not borrow the open index cardinality limit", context do
    fixture = ledger_fixture(context.root)

    assert :ok =
             Ledger.with_claim(fixture.prepared, fn claimed ->
               for number <- 1..1_023 do
                 request = %{fixture.request | job_id: "refusal-#{number}"}
                 assert {:ok, refusal} = Ledger.refusal(request, :workspace_lease_lost)
                 assert :ok = Ledger.refuse(claimed, refusal)
               end

               :ok
             end)

    owned = launch(ledger_index_operation(fixture, 5_000), :ledger_snapshot, 5_000)
    assert {{:joined, {:ok, result}, %{opens: 1_027, closes: 1_027}}, _} = drive(owned)
    assert length(result.markers) == 1_025
    assert result.open == [fixture.records.open]
    joined(owned)
  end

  test "ledger index uses the live whole-snapshot exact byte ceiling", context do
    fixture = ledger_fixture(context.root)

    assert :ok =
             Ledger.with_claim(fixture.prepared, fn claimed ->
               Ledger.close_open(claimed, fixture.jobs.open)
             end)

    entries =
      Ledger.with_claim(fixture.prepared, fn claimed ->
        entries = ledger_ceiling_entries(claimed, fixture.records.open)
        assert byte_size(ledger_snapshot_bytes(claimed, entries)) == 4_194_304
        for {_name, record} <- entries, do: assert(:ok == Ledger.restore_open(claimed, record))
        entries
      end)

    owned = launch(ledger_index_operation(fixture, 5_000), :ledger_snapshot, 5_000)
    expected = Enum.map(entries, &elem(&1, 1))
    assert {{:joined, {:ok, %{open: ^expected}}, %{opens: 515, closes: 515}}, _} = drive(owned)
    joined(owned)
    [{_name, first} | rest] = entries
    # Remove then publish the next writer-admitted record. Every selected file
    # remains canonical and below its role cap; only the whole observation grows.
    assert byte_size(first["job_id"]) < 8_192
    larger = %{first | "job_id" => first["job_id"] <> "x"}

    assert :ok =
             Ledger.with_claim(fixture.prepared, fn claimed ->
               assert :ok = Ledger.close_open(claimed, first["job_id"])
               Ledger.restore_open(claimed, larger)
             end)

    Ledger.with_claim(fixture.prepared, fn claimed ->
      larger_entries = Enum.sort([{hash(larger["job_id"]), larger} | rest])
      assert byte_size(ledger_snapshot_bytes(claimed, larger_entries)) == 4_194_305
    end)

    owned = launch(ledger_index_operation(fixture, 5_000), :ledger_snapshot, 5_000)
    assert {{:joined, {:error, :history_invalid}, %{opens: 515, closes: 515}}, _} = drive(owned)
    joined(owned)
  end

  test "ledger index refuses linked or replaced later records without decoding their bytes",
       context do
    for change <- [:symlink, :hardlink, :changed_after_generation] do
      fixture = ledger_fixture(context.root)
      operation = ledger_index_operation(fixture)
      owned = launch(operation, :ledger_decode)
      {id, :ledger_decode} = paused_operation(owned, :ledger_decode)
      path = fixture.paths.open

      case change do
        :symlink ->
          external = Path.join(fixture.root, "external-open")
          File.rename!(path, external)
          File.ln_s!(external, path)

        :hardlink ->
          File.ln!(path, Path.join(fixture.root, "linked-open"))

        :changed_after_generation ->
          changed = %{fixture.records.open | "origin_executor_epoch" => 8}
          File.write!(path, :erlang.term_to_binary(changed, [:deterministic]))
      end

      send(owned.guardian, {:proceed, owned.reference, id})
      assert {{:joined, {:error, :io_error}, _}, events} = drive(owned)
      # Generation was decoded; the changed later open record must not be.
      assert Enum.count(issued_kinds(events), &(&1 == :ledger_decode)) <= 3
      joined(owned)
    end
  end

  test "ledger index rejects marker basenames open identity and admission-pair disagreements",
       context do
    for change <- [:basename, :executor, :request, :cleanup, :wrong_plane] do
      fixture = ledger_fixture(context.root)
      path = if change == :basename, do: fixture.paths.admission, else: fixture.paths.open

      case change do
        :basename ->
          File.rename!(path, Path.join(Path.dirname(path), hash("other-job")))

        _ ->
          record =
            case change do
              :executor ->
                %{fixture.records.open | "executor_identity" => "other"}

              :request ->
                %{fixture.records.open | "canonical_request_digest" => String.duplicate("b", 64)}

              :cleanup ->
                %{fixture.records.open | "cleanup_grace_ms" => 101}

              :wrong_plane ->
                fixture.records.admission
            end

          File.write!(path, :erlang.term_to_binary(record, [:deterministic]))
      end

      owned = launch(ledger_index_operation(fixture), :ledger_snapshot)
      assert {{:joined, {:error, :history_invalid}, _}, _} = drive(owned)
      joined(owned)
    end
  end

  test "ledger index rechecks namespaces earlier records and ancestors after the final decode",
       context do
    for change <- [:addition, :earlier_record, :ancestor] do
      fixture = ledger_fixture(context.root)
      owned = launch(ledger_index_operation(fixture), :ledger_snapshot)
      {id, :ledger_snapshot} = paused_operation(owned, :ledger_snapshot)

      case change do
        :addition ->
          File.write!(Path.join([fixture.prepared.root, "markers", hash("late")]), "late")

        :earlier_record ->
          replacement = fixture.paths.generation <> ".replacement"
          File.write!(replacement, File.read!(fixture.paths.generation))

          File.chmod!(
            replacement,
            Bitwise.band(File.stat!(fixture.paths.generation).mode, 0o7777)
          )

          File.rename!(replacement, fixture.paths.generation)

        :ancestor ->
          directory = Path.join(fixture.prepared.root, "markers")
          moved = directory <> "-moved"
          File.rename!(directory, moved)
          File.mkdir!(directory)

          for name <- File.ls!(moved),
              do: File.rename!(Path.join(moved, name), Path.join(directory, name))

          File.rmdir!(moved)
      end

      send(owned.guardian, {:proceed, owned.reference, id})
      assert {{:joined, {:error, :io_error}, %{opens: 4, closes: 4}}, _} = drive(owned)
      joined(owned)
    end
  end

  test "ledger index captures the original cutoff across all members and snapshot reduction",
       context do
    fixture = ledger_fixture(context.root)
    owned = launch(ledger_index_operation(fixture), :ledger_snapshot, 500)
    paused_operation(owned, :ledger_snapshot)
    assert {{:joined, {:error, :deadline}, %{opens: 4, closes: 4}}, _} = drive(owned, false)
    joined(owned)
  end

  test "Ledger audit preserves all actual current writer records and raw job identities",
       context do
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

  test "captured Ledger copies authenticate the original source placement without activation",
       context do
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
          {:generation, "job"},
          {:open, nil},
          {:open, <<>>},
          {:open, :job},
          {:open, :binary.copy(<<0>>, 8_193)},
          {:other, nil}
        ] do
      assert RestoreIO.run(
               {:audit_ledger, root, declaration, role, job_id, manifest},
               limits(1_000, 100)
             ) == {:error, :invalid_io_request}
    end

    for changed <- [
          Map.put(declaration, "extra", true),
          Map.delete(declaration, "executor_identity"),
          %{declaration | "relative_root" => "../ledger"},
          %{declaration | "relative_root" => "/ledger"},
          %{declaration | "relative_root" => "ledger/./nested"},
          %{declaration | "source_generation_sha256" => String.duplicate("A", 64)}
        ] do
      owned =
        launch({:audit_ledger, root, changed, :generation, nil, manifest}, :ledger_declaration)

      assert {{:joined, {:error, :history_invalid}, %{opens: 0, closes: 0}}, events} =
               drive(owned)

      refute :ledger_decode in issued_kinds(events)
      joined(owned)
    end
  end

  test "Ledger capture requires canonical file and every parent in the physical manifest",
       context do
    fixture = ledger_fixture(context.root)

    for role <- [:generation, :admission, :refusal, :open] do
      {:audit_ledger, root, declaration, ^role, job_id, manifest} =
        ledger_operation(fixture, role)

      [domain, entries] = :erlang.binary_to_term(manifest, [:safe])
      relative = Path.relative_to(fixture.paths[role], root)
      parent = Path.dirname(relative)

      for changed <- [
            Enum.reject(entries, &(&1["path"] == relative)),
            Enum.reject(entries, &(&1["path"] == parent)),
            Enum.reject(entries, &(&1["path"] == ".")),
            Enum.map(entries, fn entry ->
              if entry["path"] == relative,
                do: %{entry | "kind" => "directory", "size" => 0, "sha256" => nil},
                else: entry
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

      File.write!(
        fixture.paths[role],
        :erlang.term_to_binary(fixture.records[role], [:deterministic])
      )
    end
  end

  test "Ledger generation hash identity and original binding are independent required relations",
       context do
    fixture = ledger_fixture(context.root)
    declaration = fixture.declaration
    placement = declaration["source_placement"]

    for changed <- [
          %{declaration | "source_generation_sha256" => String.duplicate("0", 64)},
          %{declaration | "executor_identity" => "other-executor"},
          %{declaration | "source_placement" => %{placement | "inode" => placement["inode"] + 1}},
          %{declaration | "source_placement" => %{placement | "expanded_root" => fixture.root}}
        ] do
      owned =
        launch(ledger_operation(%{fixture | declaration: changed}, :generation), :ledger_decode)

      assert {{:joined, {:error, :history_invalid}, %{opens: 1, closes: 1}}, _} = drive(owned)
      joined(owned)
    end

    changed = %{fixture | declaration: %{declaration | "executor_identity" => "other-executor"}}
    owned = launch(ledger_operation(changed, :open), :ledger_decode)
    assert {{:joined, {:error, :history_invalid}, %{opens: 1, closes: 1}}, _} = drive(owned)
    joined(owned)
  end

  test "Ledger basename job identity and expected kind cannot substitute for each other",
       context do
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

  test "all Ledger roles refuse their actual first over-cap file before open or decode",
       context do
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

  test "Ledger descriptor and post-decode file or ancestor replacement cannot publish a record",
       context do
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

  test "physical Ledger equality cannot admit compressed trailing alternate or malformed records",
       context do
    for role <- [:generation, :admission, :refusal, :open] do
      fixture = ledger_fixture(context.root)
      record = fixture.records[role]
      canonical = File.read!(fixture.paths[role])
      compressed = :erlang.term_to_binary(record, [:deterministic, :compressed])
      assert <<131, 80, _::binary>> = compressed

      for bytes <- [
            compressed,
            canonical <> <<0>>,
            :erlang.term_to_binary([record], [:deterministic]),
            :erlang.term_to_binary(Map.put(record, "extra", true), [:deterministic]),
            :erlang.term_to_binary(Map.delete(record, :ledger_kind), [:deterministic])
          ] do
        File.write!(fixture.paths[role], bytes)

        changed =
          if role == :generation,
            do: %{
              fixture
              | declaration: %{fixture.declaration | "source_generation_sha256" => hash(bytes)}
            },
            else: fixture

        owned = launch(ledger_operation(changed, role), :ledger_decode)

        assert {{:joined, {:error, :history_invalid}, %{opens: 1, closes: 1}}, events} =
                 drive(owned)

        assert index(issued_kinds(events), :close) < index(issued_kinds(events), :ledger_decode)
        assert File.read!(fixture.paths[role]) == bytes
        joined(owned)
      end
    end
  end

  test "Ledger semantic work retains the original cutoff after explicit descriptor close",
       context do
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
    {:ok, claim} = Store.claim_creation_domain("audit-runtime", 0, String.duplicate("a", 64))
    initial = append_transaction(initial, claim)

    Enum.reduce(1..count, initial, fn number, fixture ->
      {:ok, transaction} =
        Store.create_session(
          "audit-runtime",
          "create-#{number}",
          ConfiguredGenesisFixture.genesis([])
        )

      head = fixture.state.creation_heads[transaction.runtime_id]

      {:ok, reserve} =
        Store.reserve_creation(transaction.runtime_id, transaction.command_id,
          head.owner_generation, head.owner_selection, head.domain_version, transaction.genesis)

      fixture = append_transaction(fixture, reserve)
      fixture = append_transaction(fixture, transaction)
      assert map_size(fixture.state.sessions) == number
      fixture
    end)
  end

  defp append_transaction(fixture, transaction) do
    {:new, state, frame, outcome} = State.prepare(fixture.state, transaction)

    # Concept: fixture sessions use the current original creation custody.
    # Technical depth: a refused final creation must not masquerade as a
    # populated Store. Preserve ordinary orphan refusals outside these families.
    if transaction.type in [:claim_creation_domain, :reserve_creation, :create_session],
      do: assert(match?({:committed, _, _}, outcome))
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

    assert :ok =
             Ledger.with_claim(prepared, fn claimed ->
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
        "expanded_root" => ledger,
        "major_device" => info.major_device,
        "inode" => info.inode
      }
    }

    assert {:ok, _} = RestoreCodec.encode(:ledger_descriptor, declaration)

    %{
      root: state,
      declaration: declaration,
      paths: paths,
      prepared: prepared,
      request: job,
      jobs: %{generation: nil, admission: job.job_id, refusal: refused.job_id, open: job.job_id},
      records: %{generation: generation, admission: marker, refusal: refusal, open: open}
    }
  end

  defp ledger_ceiling_entries(claimed, base) do
    build = fn width ->
      for number <- 1..512 do
        id = String.pad_leading(Integer.to_string(number), 4, "0") <> String.duplicate("j", width)
        record = %{base | "job_id" => id}
        {hash(id), record}
      end
      |> Enum.sort()
    end

    width = ledger_fitting_width(claimed, build, 0, 8_188)
    entries = build.(width)
    remaining = 4_194_304 - byte_size(ledger_snapshot_bytes(claimed, entries))
    # Distribute the final bytes within actual identifier domains. Leave one
    # byte in the first entry for the exact first-over control.
    {entries, 0} =
      Enum.map_reduce(entries, remaining, fn {_name, record}, left ->
        added = min(left, 8_191 - byte_size(record["job_id"]))
        record = %{record | "job_id" => record["job_id"] <> String.duplicate("j", added)}
        {{hash(record["job_id"]), record}, left - added}
      end)

    Enum.sort(entries)
  end

  defp ledger_fitting_width(_claimed, _build, low, high) when low == high, do: low

  defp ledger_fitting_width(claimed, build, low, high) do
    middle = div(low + high + 1, 2)

    if byte_size(ledger_snapshot_bytes(claimed, build.(middle))) <= 4_194_304,
      do: ledger_fitting_width(claimed, build, middle, high),
      else: ledger_fitting_width(claimed, build, low, middle - 1)
  end

  defp ledger_snapshot_bytes(claimed, entries) do
    :erlang.term_to_binary(
      [
        "loopex:local-root-snapshot:v1",
        claimed.generation_digest,
        claimed.root_binding,
        claimed.root_claim_nonce,
        length(entries),
        Enum.map(entries, fn {name, record} ->
          [name, hash(:erlang.term_to_binary(record, [:deterministic])), record]
        end)
      ],
      [:deterministic]
    )
  end

  defp ledger_index_operation(fixture, work_ms \\ 1_000) do
    assert {:joined, {:ok, manifest}, _} =
             RestoreIO.run({:manifest, fixture.root, 16_777_216}, limits(work_ms, 100))

    {:audit_ledger_index, fixture.root, fixture.declaration, manifest}
  end

  defp ledger_operation(fixture, role) do
    assert {:joined, {:ok, manifest}, _} =
             RestoreIO.run({:manifest, fixture.root, 1_048_576}, limits(1_000, 100))

    {:audit_ledger, fixture.root, fixture.declaration, role, fixture.jobs[role], manifest}
  end

  # Concept: the test observes the real synchronous Core facade, without a fake
  # adapter or retained payload. Technical depth: its finite wait covers a single
  # original 500-ms invocation cutoff and receives an explicit release after stop.
  @doc false
  def pause_artifact_describe(_event, _measurements, metadata, parent) do
    send(parent, {:artifact_describe_entered, self(), metadata})

    receive do
      :continue_artifact_describe -> :ok
    after
      1_000 -> raise "artifact describe observation was not released"
    end
  end

  defp artifact_metadata do
    %{
      "session_id" => <<255, 0, 128>>,
      "run_id" => "run" <> <<0, 254>>,
      "operation_id" => <<128, 255, 0>>,
      "tool_call_id" => <<0, 255>>,
      "attempt" => Integer.pow(2, 128),
      "media_type" => "application/octet-stream",
      "role" => "tool_output"
    }
  end

  # Concept: actual Local publication supplies the receipt's complete current bytes.
  # Technical depth: the physical capture is independent of Local after both original
  # authorities join under one cutoff and the writer root is removed. Rewritten
  # boundary controls are labelled separately; no copied ledger grants live authority.
  defp receipt_fixture(root, job_id \\ <<255, 0, 128>> <> "selected-receipt") do
    root = physical_root(root)
    unique = System.unique_integer([:positive])
    parent = Path.join(root, "receipt-capture-#{unique}")
    original = Path.join(parent, "original")
    backup = Path.join(parent, "backup")
    workspace = Path.join(root, "receipt-workspace-#{unique}")
    ledger = Path.join(original, "receipts")
    File.mkdir_p!(workspace)
    identity = "receipt-capture"
    epoch = 3
    fence = 19
    lease_id = "receipt-capture-#{unique}"

    {:ok, lease} =
      Loopex.Executor.Local.WorkspaceLease.start_link(
        id: lease_id,
        path: workspace,
        fencing_token: fence
      )

    {:ok, local} =
      Loopex.Executor.Local.start_link(
        identity: identity,
        epoch: epoch,
        fencing_token: fence,
        workspace_leases: %{lease_id => lease},
        ledger_root: ledger,
        cleanup_grace_ms: 100
      )

    actors = [{local, Process.monitor(local)}, {lease, Process.monitor(lease)}]

    on_exit(fn ->
      for {actor, _original} <- actors, Process.alive?(actor) do
        monitor = Process.monitor(actor)
        Process.unlink(actor)
        Process.exit(actor, :kill)
        assert_receive {:DOWN, ^monitor, :process, ^actor, _}, 1_000
      end
    end)

    definition =
      Enum.find(
        Loopex.Executor.Local.CodingTools.definitions(),
        &(&1["tool_id"] == "loopex.write")
      )

    assert {:ok, request} =
             Loopex.Executor.job(%{
               protocol_version: 1,
               job_id: job_id,
               operation_id: "receipt-operation",
               attempt: 1,
               session_id: "receipt-session",
               run_id: "receipt-run",
               turn_id: "receipt-turn",
               tool_call_id: "receipt-call",
               origin_session_epoch: 1,
               origin_executor_epoch: epoch,
               executor_identity: identity,
               required_capabilities: [definition["effect_class"]],
               tool_id: "loopex.write",
               tool_version: definition["tool_version"],
               effect_class: definition["effect_class"],
               validated_arguments: %{"path" => "written.txt", "content" => "captured"},
               workspace_ref: "receipt-workspace",
               workspace_lease: lease_id,
               run_deadline: System.system_time(:millisecond) + 60_000,
               resource_budgets: %{"max_output_bytes" => 65_536},
               idempotency_class: definition["idempotency_class"],
               fencing_token: fence,
               artifact_policy: %{"retain" => true},
               output_policy: %{"capture" => true},
               cleanup_grace_ms: 100
             })

    assert {:ok, grant} =
             Loopex.Executor.issue_grant({:host_policy, :allow}, request, request.run_deadline)

    assert {:ok, receipt} = Loopex.Executor.Local.execute(local, request, grant, [], nil)
    assert receipt.outcome == :completed and receipt.cleanup_confirmation == :confirmed
    assert receipt.job_id == job_id
    assert File.read!(Path.join(workspace, "written.txt")) == "captured"
    assert {:ok, ^receipt} = Loopex.Executor.Local.receipt(local, job_id)
    original_path = receipt_path(original, job_id)
    bytes = File.read!(original_path)
    assert bytes == :erlang.term_to_binary(receipt, [:deterministic])
    cutoff = System.monotonic_time(:millisecond) + 5_000

    for {actor, monitor} <- actors do
      remaining = max(cutoff - System.monotonic_time(:millisecond), 0)
      assert remaining > 0
      assert :ok = GenServer.stop(actor, :normal, remaining)

      assert_receive {:DOWN, ^monitor, :process, ^actor, :normal},
                     max(cutoff - System.monotonic_time(:millisecond), 0)
    end

    assert System.monotonic_time(:millisecond) < cutoff
    File.cp_r!(original, backup)
    File.rm_rf!(original)
    refute File.exists?(original)
    path = receipt_path(backup, job_id)
    assert File.read!(path) == bytes
    assert {:ok, ^receipt} = Loopex.Executor.Local.decode_receipt_bytes(bytes)

    %{
      root: backup,
      original: original,
      path: path,
      bytes: bytes,
      receipt: receipt,
      job_id: job_id
    }
  end

  defp receipt_path(root, job_id),
    do: Path.join([root, "receipts", hash(job_id) <> ".receipt"])

  defp receipt_operation(fixture) do
    assert {:joined, {:ok, manifest}, _} =
             RestoreIO.run({:manifest, fixture.root, 1_048_576}, limits(1_000, 100))

    {:audit_selected_receipt, fixture.root, fixture.job_id, manifest}
  end

  defp artifact_fixture(root, bytes \\ "captured object", metadata \\ [artifact_metadata()]) do
    root = physical_root(root)
    unique = System.unique_integer([:positive])
    original = Path.join(root, "artifact-writer-#{unique}")
    backup = Path.join(root, "artifact-backup-#{unique}")
    assert {:ok, handle} = Loopex.Store.Local.Artifacts.open(Path.join(original, "artifacts"))
    store = %{module: Loopex.Store.Local.Artifacts, handle: handle}

    records =
      Enum.map(metadata, fn labels ->
        assert {:ok, reference} = Loopex.ArtifactStore.put(store, bytes, labels)
        assert {:ok, use} = Loopex.ArtifactStore.describe(store, reference)
        {reference, use}
      end)

    File.cp_r!(original, backup)
    File.rm_rf!(original)
    refute File.exists?(original)
    [{reference, use} | _] = records
    path = artifact_use_path(backup, reference)
    captured = File.read!(path)
    assert captured == LoopexProtocol.Canonical.encode(["artifact-use-v2", use])

    %{
      root: backup,
      original: original,
      path: path,
      bytes: captured,
      reference: reference,
      use: use,
      references: Enum.map(records, &elem(&1, 0)),
      uses: Enum.map(records, &elem(&1, 1))
    }
  end

  defp artifact_use_path(root, reference),
    do:
      Path.join([
        root,
        "artifacts",
        "uses",
        binary_part(reference.use_digest, 0, 2),
        reference.use_digest
      ])

  defp artifact_use_control(fixture, use, reference) do
    bytes = LoopexProtocol.Canonical.encode(["artifact-use-v2", use])
    digest = hash(bytes)
    reference = %{reference | use_digest: digest, use_locator: "use:" <> digest}
    assert Loopex.ArtifactStore.valid_reference?(reference)
    path = artifact_use_path(fixture.root, reference)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, bytes)
    %{fixture | reference: reference, use: use, path: path, bytes: bytes}
  end

  defp artifact_operation(fixture) do
    assert {:joined, {:ok, manifest}, _} =
             RestoreIO.run({:manifest, fixture.root, 1_048_576}, limits(1_000, 100))

    {:audit_artifact_use, fixture.root, fixture.reference, manifest}
  end

  defp artifact_object_path(root, reference),
    do: Path.join([root, "artifacts", binary_part(reference.locator, 0, 2), reference.locator])

  defp artifact_object_operation(fixture, max_total \\ 1_048_576) do
    assert {:joined, {:ok, manifest}, _} =
             RestoreIO.run({:manifest, fixture.root, max_total}, limits(1_000, 100))

    {:audit_artifact_object, fixture.root, fixture.reference, manifest, max_total}
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

  @tag :long_bound
  test "late final guardian observation refuses join despite the real worker's timely normal termination",
       context do
    sink = final_observation_sink()
    path = Path.join(context.root, "observation-record")
    File.write!(path, "retained")

    for mode <- [:timely, :late] do
      owned = launch({:read, path, 8}, :stat)
      guardian = owned.guardian
      worker = owned.worker
      reference = owned.reference
      tag = owned.tag
      assert_receive {:restore_io, ^guardian, ^worker, ^reference, {:issued, id, :stat}}, 1_000
      send(guardian, {:proceed_final_observation, reference, id})
      {guardian_worker_monitor, paused_at, facts, events} = final_observation_ready(owned, [])
      cutoff = facts.cleanup_cutoff
      caller_cutoff = owned.work_cutoff + 10_000

      assert facts == %{
               finished: true,
               down: false,
               pending: false,
               open_count: 0,
               worker_exit_seen: true,
               opens: 1,
               closes: 1,
               stop: :complete,
               stop_at: facts.stop_at,
               work_cutoff: owned.work_cutoff,
               cleanup_cutoff: cutoff
             }

      assert [{:stopping, :complete, stop_at, ^cutoff}] =
               for({:stopping, :complete, _, _} = event <- events, do: event)

      assert stop_at == facts.stop_at
      assert cutoff == facts.stop_at + 10_000
      assert facts.stop_at <= owned.work_cutoff
      assert paused_at < cutoff and cutoff < caller_cutoff

      assert [{:acknowledged, _, {:open, token}, :opened}] =
               for({:acknowledged, _, {:open, _}, :opened} = event <- events, do: event)

      assert [{:acknowledged, _, {:close, ^token}, :closed}] =
               for({:acknowledged, _, {:close, _}, :closed} = event <- events, do: event)

      suspension_key = {:restore_observation_suspended, guardian}

      try do
        suspended_at =
          if mode == :late do
            assert :erlang.suspend_process(guardian)
            Process.put(suspension_key, true)
            at = System.monotonic_time(:millisecond)
            assert at < cutoff
            at
          end

        worker_monitor = owned.worker_monitor

        receive do
          {:DOWN, ^worker_monitor, :process, ^worker, :normal} -> :ok
        after
          max(0, cutoff - System.monotonic_time(:millisecond)) ->
            flunk("actual worker normal DOWN was not observed before original cleanup cutoff")
        end

        worker_down_at = System.monotonic_time(:millisecond)
        assert paused_at <= worker_down_at and worker_down_at < cutoff
        refute Process.alive?(worker)
        refute_received {:restore_io, ^guardian, ^worker, ^reference, {:terminal, _}}
        refute_received {^tag, _}

        if mode == :late do
          receive do
          after
            max(0, cutoff - System.monotonic_time(:millisecond)) -> :ok
          end

          crossed_at = System.monotonic_time(:millisecond)
          assert crossed_at >= cutoff and crossed_at < caller_cutoff
        end

        continued_at = System.monotonic_time(:millisecond)
        send(guardian, {:continue_final_observation, reference})

        resumed_at =
          if mode == :late do
            assert Process.delete(suspension_key)
            assert :erlang.resume_process(guardian)
            System.monotonic_time(:millisecond)
          end

        {result, events, result_received_at} =
          final_observation_result(owned, caller_cutoff, events)

        assert [{:worker_down_observed, ^guardian_worker_monitor, true, observed_at}] =
                 for({:worker_down_observed, _, _, _} = event <- events, do: event)

        assert [{:final_observation_continued, continuation, barrier_continued_at}] =
                 for({:final_observation_continued, _, _} = event <- events, do: event)

        assert continuation in [:continued, :expired]
        assert continued_at <= barrier_continued_at and barrier_continued_at <= observed_at
        assert worker_down_at <= observed_at
        assert observed_at < caller_cutoff

        if mode == :timely do
          assert observed_at < cutoff
        else
          assert suspended_at < cutoff
          assert continued_at >= cutoff
          assert resumed_at >= cutoff and resumed_at < caller_cutoff
          assert observed_at >= cutoff
        end

        guardian_joined_at =
          final_observation_join(guardian, owned.guardian_monitor, caller_cutoff)

        caller_joined_at =
          final_observation_join(owned.caller, owned.caller_monitor, caller_cutoff)

        assert File.read!(path) == "retained"

        {result_tag, result_reason} =
          case result do
            {:joined, {:ok, "retained"}, _} -> {"joined", nil}
            {:unconfirmed, :worker_unjoined} -> {"unconfirmed", "worker_unjoined"}
            _ -> {"unexpected", nil}
          end

        final_observation_retain(sink, mode, %{
          "kind" => "restore_io_observation_witness_v1",
          "mode" => Atom.to_string(mode),
          "caller" => inspect(owned.caller),
          "guardian" => inspect(guardian),
          "worker" => inspect(worker),
          "caller_monitor" => inspect(owned.caller_monitor),
          "guardian_monitor" => inspect(owned.guardian_monitor),
          "fixture_worker_monitor" => inspect(worker_monitor),
          "guardian_worker_monitor" => inspect(guardian_worker_monitor),
          "work_ms" => 1_000,
          "cleanup_grace_ms" => 100,
          "cleanup_window_ms" => 10_000,
          "admitted_at" => owned.work_cutoff - 1_000,
          "stop_at" => facts.stop_at,
          "work_cutoff" => owned.work_cutoff,
          "cleanup_cutoff" => cutoff,
          "caller_cutoff" => caller_cutoff,
          "barrier_paused_at" => paused_at,
          "guardian_suspended_at" => suspended_at,
          "fixture_worker_down_observed_at" => worker_down_at,
          "fixture_worker_down_normal" => true,
          "continuation_sent_at" => continued_at,
          "guardian_resumed_at" => resumed_at,
          "barrier_continued_at" => barrier_continued_at,
          "barrier_continuation" => Atom.to_string(continuation),
          "worker_down_consumed_by_guardian_at" => observed_at,
          "result_received_at" => result_received_at,
          "guardian_join_observed_at" => guardian_joined_at,
          "caller_join_observed_at" => caller_joined_at,
          "opens" => 1,
          "closes" => 1,
          "finished" => true,
          "pending" => false,
          "worker_exit_seen_before_barrier" => true,
          "open_count_at_barrier" => 0,
          "complete_original_actor_joins" => true,
          "result" => result_tag,
          "reason" => result_reason
        })

        if mode == :timely do
          assert {:joined, {:ok, "retained"},
                  %{
                    opens: 1,
                    closes: 1,
                    stop: :complete,
                    work_cutoff: work_cutoff,
                    cleanup_cutoff: ^cutoff
                  }} = result

          assert work_cutoff == owned.work_cutoff
        else
          assert result == {:unconfirmed, :worker_unjoined}
        end
      after
        if Process.delete(suspension_key) == true and Process.alive?(guardian),
          do: :erlang.resume_process(guardian)
      end
    end
  end

  # Concept: the fixture holds observation, never the actual raw IO resource.
  # Technical depth: first-stat pause installs original monitors; the exact held
  # continuation arms a single finished/closed/normal-EXIT barrier. Its wait and
  # all subsequent observations spend captured W/C/O, without a relative retry.
  defp final_observation_ready(owned, events) do
    guardian = owned.guardian
    worker = owned.worker
    reference = owned.reference
    tag = owned.tag

    receive do
      {:restore_io, ^guardian, ^worker, ^reference,
       {:final_observation_paused, monitor, at, facts} = event} ->
        {monitor, at, facts, Enum.reverse([event | events])}

      {:restore_io, ^guardian, ^worker, ^reference, {:issued, id, :stat} = event} ->
        send(guardian, {:proceed, reference, id})
        final_observation_ready(owned, [event | events])

      {:restore_io, ^guardian, ^worker, ^reference, event} ->
        final_observation_ready(owned, [event | events])

      {^tag, result} ->
        flunk(
          "real IO finished without establishing the fixed final observation barrier: #{inspect(result)}"
        )
    after
      max(0, owned.work_cutoff - System.monotonic_time(:millisecond)) ->
        flunk("fixed final observation barrier was not established by original work cutoff")
    end
  end

  defp final_observation_result(owned, cutoff, events) do
    guardian = owned.guardian
    worker = owned.worker
    reference = owned.reference
    tag = owned.tag

    receive do
      {:restore_io, ^guardian, ^worker, ^reference, event} ->
        final_observation_result(owned, cutoff, events ++ [event])

      {^tag, result} ->
        at = System.monotonic_time(:millisecond)
        assert at < cutoff
        {result, events, at}
    after
      max(0, cutoff - System.monotonic_time(:millisecond)) ->
        flunk("late observation result exceeded original caller cutoff")
    end
  end

  defp final_observation_join(actor, monitor, cutoff) do
    receive do
      {:DOWN, ^monitor, :process, ^actor, :normal} ->
        at = System.monotonic_time(:millisecond)
        assert at < cutoff
        at
    after
      max(0, cutoff - System.monotonic_time(:millisecond)) ->
        flunk("original observation actor did not join inside original caller cutoff")
    end
  end

  # Concept: a runner may retain only this fixture's bounded scheduling proof.
  # Technical depth: require an empty mode-0700 physical child of this stage's
  # mode-0700 System.tmp_dir, before any evidence write. Recheck both identities;
  # publish exactly two exclusive mode-0600 JSON files, each at most 4,096 bytes.
  # Nil sink adds no filesystem operation. No payload, path or crash reason is
  # retained, and monitor strings describe the actual original local actors.
  defp final_observation_sink() do
    case System.get_env("LOOPEX_RESTORE_OBSERVATION_EVIDENCE_DIR") do
      nil ->
        nil

      directory ->
        assert {:ok, temp} = LoopexComposition.WorkspaceIdentity.resolve_path(System.tmp_dir!())
        assert {:ok, physical} = LoopexComposition.WorkspaceIdentity.resolve_path(directory)
        assert physical == Path.expand(directory)
        assert Path.dirname(physical) == temp
        temp_stat = File.lstat!(temp)
        directory_stat = File.lstat!(physical)
        assert temp_stat.type == :directory and Bitwise.band(temp_stat.mode, 0o7777) == 0o700

        assert directory_stat.type == :directory and
                 Bitwise.band(directory_stat.mode, 0o7777) == 0o700

        assert File.ls!(physical) == []

        %{
          directory: physical,
          temp: temp,
          temp_identity: {temp_stat.major_device, temp_stat.inode},
          directory_identity: {directory_stat.major_device, directory_stat.inode}
        }
    end
  end

  defp final_observation_retain(nil, _mode, _record), do: :ok

  defp final_observation_retain(sink, mode, record) do
    temp_stat = File.lstat!(sink.temp)
    directory_stat = File.lstat!(sink.directory)
    assert temp_stat.type == :directory and Bitwise.band(temp_stat.mode, 0o7777) == 0o700

    assert directory_stat.type == :directory and
             Bitwise.band(directory_stat.mode, 0o7777) == 0o700

    assert {temp_stat.major_device, temp_stat.inode} == sink.temp_identity
    assert {directory_stat.major_device, directory_stat.inode} == sink.directory_identity
    expected = if mode == :timely, do: [], else: ["timely.json"]
    assert File.ls!(sink.directory) == expected
    bytes = JSON.encode!(record)
    assert byte_size(bytes) <= 4_096
    path = Path.join(sink.directory, Atom.to_string(mode) <> ".json")
    assert File.lstat(path) == {:error, :enoent}
    File.write!(path, bytes, [:binary, :exclusive])
    File.chmod!(path, 0o600)
    assert {:ok, %File.Stat{type: :regular, links: 1, size: size} = info} = File.lstat(path)
    assert size == byte_size(bytes) and Bitwise.band(info.mode, 0o7777) == 0o600
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

  # Concept: observe the complete copied baseline before administrative allocation.
  # Technical depth: all observations and proceeds are tied to the installed
  # guardian/reference and original payload or captured terminal worker. A single
  # original caller cutoff bounds this gate; no second IO owner or renewed work.
  defp drive_mode_restore(
         owned,
         fixture,
         cutoff,
         events \\ [],
         phase \\ nil,
         copied \\ false,
         release \\ nil
       ) do
    guardian = owned.guardian
    reference = owned.reference
    tag = owned.tag

    receive do
      {:restore_io, ^guardian, worker, ^reference, event} ->
        release =
          case event do
            {:terminal_release_installed, cleanup_cutoff} ->
              assert is_nil(release) and worker != owned.worker
              assert Process.alive?(worker)
              monitor = Process.monitor(worker)

              on_exit(fn ->
                cleanup_monitor = Process.monitor(worker)
                Process.exit(worker, :kill)
                assert_receive {:DOWN, ^cleanup_monitor, :process, ^worker, _}, 1_000
              end)

              %{worker: worker, monitor: monitor, cleanup_cutoff: cleanup_cutoff}

            _ ->
              release
          end

        assert worker == owned.worker or (release && worker == release.worker)

        phase =
          case event do
            {:issued, _, {:restore_phase, selected}} -> selected
            _ -> phase
          end

        copied =
          case event do
            {:issued, id, :manifest_stat} ->
              if worker == owned.worker and phase == "destination_intent" and not copied do
                assert System.monotonic_time(:millisecond) < owned.work_cutoff
                assert File.ls!(fixture.destination) == ["stream"]
                assert expected_manifest(fixture.destination, [".", "stream"]) == fixture.baseline

                assert {:ok, _} =
                         RestoreCodec.manifest(fixture.baseline, byte_size(fixture.content))

                file = Path.join(fixture.destination, "stream")
                assert File.read!(file) == fixture.content
                assert Bitwise.band(File.lstat!(file).mode, 0o7777) == 0o4750
                assert System.monotonic_time(:millisecond) < owned.work_cutoff
              end

              send(guardian, {:proceed, reference, id})
              copied or (worker == owned.worker and phase == "destination_intent")

            _ ->
              copied
          end

        drive_mode_restore(
          owned,
          fixture,
          cutoff,
          [{worker, event} | events],
          phase,
          copied,
          release
        )

      {^tag, result} ->
        assert copied and not is_nil(release)
        {result, Enum.reverse(events), release}
    after
      max(cutoff - System.monotonic_time(:millisecond), 0) ->
        flunk("original restore did not finish within its captured work/cleanup cutoff")
    end
  end

  # Concept: the mode gate observes actual complete staging before its audit.
  # Technical depth: final directory-mode acknowledgements precede this held
  # manifest primitive. Only measured mode inequality admits inventory_mismatch;
  # all observations and original actor joins spend the original captured cutoff.
  defp drive_special_mode_restore(
         owned,
         fixture,
         cutoff,
         events \\ [],
         phase \\ nil,
         modes \\ 0,
         copied \\ nil,
         release \\ nil
       ) do
    guardian = owned.guardian
    reference = owned.reference
    tag = owned.tag

    receive do
      {:restore_io, ^guardian, worker, ^reference, event} ->
        release =
          case event do
            {:terminal_release_installed, cleanup_cutoff} ->
              assert is_nil(release) and worker != owned.worker
              assert Process.alive?(worker)
              monitor = Process.monitor(worker)

              on_exit(fn ->
                if Process.alive?(worker) do
                  cleanup_monitor = Process.monitor(worker)
                  Process.exit(worker, :kill)
                  assert_receive {:DOWN, ^cleanup_monitor, :process, ^worker, _}, 1_000
                end
              end)

              %{worker: worker, monitor: monitor, cleanup_cutoff: cleanup_cutoff}

            _ ->
              release
          end

        assert worker == owned.worker or (release && worker == release.worker)

        phase =
          if match?({:issued, _, {:restore_phase, _}}, event),
            do: elem(elem(event, 2), 1),
            else: phase

        modes =
          if phase == "baseline_copy" and match?({:acknowledged, _, :mode, :completed}, event),
            do: modes + 1,
            else: modes

        copied =
          case event do
            {:issued, id, :manifest_stat} ->
              observed =
                if worker == owned.worker and phase == "baseline_copy" and
                     modes == fixture.mode_count and is_nil(copied) do
                  assert System.monotonic_time(:millisecond) < owned.work_cutoff
                  before = special_mode_manifest(fixture.destination, fixture.paths)

                  if fixture.control == :normalize do
                    assert before == fixture.baseline
                    path = Path.join(fixture.destination, "nested/inner/all")

                    assert {"", 0} =
                             System.cmd("python3", [
                               "-c",
                               "import os,sys; p=sys.argv[1]; g=os.getegid(); os.chown(p,-1,g); os.lstat(p).st_gid==g or sys.exit(1); os.chmod(p,0o6750)",
                               path
                             ])

                    assert Bitwise.band(File.lstat!(path).mode, 0o7777) == 0o6750
                  end

                  actual = special_mode_manifest(fixture.destination, fixture.paths)
                  {:ok, expected_entries} = RestoreCodec.manifest(fixture.baseline, 1_048_576)
                  {:ok, actual_entries} = RestoreCodec.manifest(actual, 1_048_576)

                  assert Enum.map(actual_entries, &Map.delete(&1, "mode")) ==
                           Enum.map(expected_entries, &Map.delete(&1, "mode"))

                  for {relative, bytes} <- fixture.contents,
                      do: assert(File.read!(Path.join(fixture.destination, relative)) == bytes)

                  assert System.monotonic_time(:millisecond) < owned.work_cutoff
                  actual
                else
                  copied
                end

              if worker == owned.worker and phase == "destination_intent" do
                assert observed == fixture.baseline

                assert special_mode_manifest(fixture.destination, fixture.paths) ==
                         fixture.baseline
              end

              send(guardian, {:proceed, reference, id})
              observed

            _ ->
              copied
          end

        drive_special_mode_restore(
          owned,
          fixture,
          cutoff,
          [{worker, event} | events],
          phase,
          modes,
          copied,
          release
        )

      {^tag, result} ->
        assert not is_nil(copied)
        assert System.monotonic_time(:millisecond) < cutoff
        {result, Enum.reverse(events), release, copied}
    after
      max(cutoff - System.monotonic_time(:millisecond), 0) ->
        flunk("special-mode restore exceeded its original work/cleanup cutoff")
    end
  end

  defp special_mode_manifest(root, paths) do
    for relative <- paths do
      path = if relative == ".", do: root, else: Path.join(root, relative)
      info = File.lstat!(path)
      assert info.type in [:directory, :regular]

      if info.type == :directory do
        children =
          for candidate <- paths,
              candidate != ".",
              Path.dirname(candidate) == relative,
              do: Path.basename(candidate)

        assert Enum.sort(File.ls!(path)) == Enum.sort(children)
      end
    end

    expected_manifest(root, paths)
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
