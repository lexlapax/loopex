defmodule LoopexComposition.RestoreRetainedPublicationTest do
  use ExUnit.Case, async: false

  alias Loopex.Executor.Local.RestoreCodec
  alias LoopexComposition.Restore.IO, as: RestoreIO

  setup do
    assert {:ok, temp} = LoopexComposition.WorkspaceIdentity.resolve_path(System.tmp_dir!())
    assert File.lstat!(temp).type == :directory
    suffix = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
    root = Path.join(temp, "restore-retained-publication-" <> suffix)
    assert File.lstat(root) == {:error, :enoent}
    File.mkdir!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "fresh canonical ledger intent closes and synchronizes before native rename and readback", context do
    path = Path.join(context.root, "intent")
    bytes = record_bytes()
    owned = launch(operation(:record, path, bytes, 0o600, :absent))
    assert {{:joined, {:ok, digest}, evidence}, events} = drive(owned)
    assert digest == hash(bytes)
    assert evidence.opens == evidence.closes and evidence.opens > 0
    kinds = kinds(events)
    assert index(kinds, :write) < index(kinds, :file_sync)
    assert index(kinds, :file_sync) < index(kinds, :rename)
    assert index(kinds, :rename) < index(kinds, :directory_sync)
    assert :close in Enum.take(kinds, index(kinds, :rename))
    assert File.read!(path) == bytes
    assert mode(path) == 0o600
    refute File.exists?(path <> ".tmp")
    joined(owned)
  end

  test "exact retained temp is resynced and promoted without allocation or rewriting", context do
    path = Path.join(context.root, "intent")
    bytes = record_bytes()
    put(path <> ".tmp", bytes, 0o600)
    inode = File.lstat!(path <> ".tmp").inode
    owned = launch(operation(:record, path, bytes, 0o600, :absent))
    assert {{:joined, {:ok, _}, %{opens: opens, closes: opens}}, events} = drive(owned)
    refute :write in kinds(events)
    assert index(kinds(events), :file_sync) < index(kinds(events), :rename)
    assert File.lstat!(path).inode == inode
    assert File.read!(path) == bytes
    refute File.exists?(path <> ".tmp")
    joined(owned)
  end

  test "original imported generation admits fresh or exact retained candidate with its original mode", context do
    original = generation_bytes(1)
    candidate = generation_bytes(2)

    for retained <- [false, true] do
      directory = Path.join(context.root, to_string(retained))
      File.mkdir!(directory)
      path = Path.join(directory, "generation")
      put(path, original, 0o400)
      if retained, do: put(path <> ".tmp", candidate, 0o400)
      owned = launch(operation(:generation, path, candidate, 0o400, original))
      assert {{:joined, {:ok, _}, %{opens: opens, closes: opens}}, events} = drive(owned)
      assert File.read!(path) == candidate
      assert mode(path) == 0o400
      refute File.exists?(path <> ".tmp")
      assert :rename in kinds(events)
      if retained, do: refute(:write in kinds(events))
      joined(owned)
    end
  end

  test "equal final is resynced in place and only the exact equal retained sibling may be removed", context do
    bytes = record_bytes()

    for retained <- [false, true] do
      directory = Path.join(context.root, to_string(retained))
      File.mkdir!(directory)
      path = Path.join(directory, "intent")
      put(path, bytes, 0o600)
      inode = File.lstat!(path).inode
      if retained, do: put(path <> ".tmp", bytes, 0o600)
      other = Path.join(directory, "other-ordinal.tmp")
      put(other, "foreign retained bytes", 0o600)
      owned = launch(operation(:record, path, bytes, 0o600, :absent))
      assert {{:joined, {:ok, _}, %{opens: opens, closes: opens}}, events} = drive(owned)
      refute :write in kinds(events)
      refute :rename in kinds(events)
      assert :file_sync in kinds(events)
      assert (:delete in kinds(events)) == retained
      assert File.lstat!(path).inode == inode
      assert File.read!(path) == bytes and mode(path) == 0o600
      assert File.read!(other) == "foreign retained bytes"
      refute File.exists?(path <> ".tmp")
      joined(owned)
    end
  end

  test "canonical baseline uses its existing manifest role and keeps exact encoded bytes", context do
    path = Path.join(context.root, "baseline")
    entry = %{"path" => ".", "kind" => "directory", "mode" => 0o700, "size" => 0, "sha256" => nil}
    assert {:ok, bytes} = RestoreCodec.encode(:manifest, ["loopex:current-state-manifest:v1", [entry]])
    put(path <> ".tmp", bytes, 0o600)
    owned = launch(operation(:baseline, path, bytes, 0o600, :absent))
    assert {{:joined, {:ok, _}, %{opens: opens, closes: opens}}, _} = drive(owned)
    assert File.read!(path) == bytes and mode(path) == 0o600
    joined(owned)
  end

  test "third preimages and wrong existing modes refuse without mutation or temp removal", context do
    bytes = record_bytes()

    for {final, temporary, file_mode} <- [
          {"foreign-final", :absent, 0o600},
          {:absent, "foreign-temp", 0o600},
          {bytes, "foreign-temp", 0o600},
          {:absent, bytes, 0o640},
          {bytes, bytes, 0o640}
        ] do
      directory = Path.join(context.root, Integer.to_string(System.unique_integer([:positive])))
      File.mkdir!(directory)
      path = Path.join(directory, "intent")
      if final != :absent, do: put(path, final, file_mode)
      if temporary != :absent, do: put(path <> ".tmp", temporary, file_mode)
      before = image(directory)
      owned = launch(operation(:record, path, bytes, 0o600, :absent))
      assert {{:joined, {:error, :io_error}, %{opens: opens, closes: opens}}, events} = drive(owned)
      refute Enum.any?(kinds(events), &(&1 in [:write, :mode, :rename, :delete]))
      assert image(directory) == before
      joined(owned)
    end
  end

  test "missing original generation cannot be replaced merely because a candidate temp exists", context do
    path = Path.join(context.root, "generation")
    candidate = generation_bytes(2)
    put(path <> ".tmp", candidate, 0o640)
    owned = launch(operation(:generation, path, candidate, 0o640, generation_bytes(1)))
    assert {{:joined, {:error, :io_error}, %{opens: opens, closes: opens}}, events} = drive(owned)
    refute :rename in kinds(events)
    assert File.read!(path <> ".tmp") == candidate
    assert File.lstat(path) == {:error, :enoent}
    joined(owned)
  end

  test "each role rejects an oversized existing file before raw open", context do
    for {role, cap, file_mode} <- [{:baseline, 4_194_304, 0o600}, {:record, 65_536, 0o600}, {:generation, 2_048, 0o640}],
        location <- [:final, :temp] do
      path = Path.join(context.root, Atom.to_string(role) <> "-" <> Atom.to_string(location))
      observed = if location == :final, do: path, else: path <> ".tmp"
      put(observed, :binary.copy("x", cap + 1), file_mode)
      before = image(context.root)
      owned = launch(operation(role, path, "candidate", file_mode, :absent))
      assert {{:joined, {:error, :io_error}, %{opens: 0, closes: 0}}, events} = drive(owned)
      refute :open in kinds(events)
      assert image(context.root) == before
      joined(owned)
    end
  end

  test "role byte and mode admission refuses before actors and leaves native state intact", context do
    path = Path.join(context.root, "intent")
    put(path, record_bytes(), 0o600)
    before = image(context.root)

    for request <- [
          operation(:record, path, record_bytes(), 0o640, :absent),
          operation(:record, path, :binary.copy("x", 65_537), 0o600, :absent),
          operation(:generation, path, "candidate", 0o640, :binary.copy("x", 2_049)),
          operation(:other, path, "candidate", 0o600, :absent)
        ] do
      assert RestoreIO.run(request, limits()) == {:error, :invalid_io_request}
      assert image(context.root) == before
    end
  end

  test "real symlink hardlink and FIFO inputs refuse before raw open", context do
    for kind <- [:symlink, :hardlink, :fifo], location <- [:final, :temp] do
      directory = Path.join(context.root, Atom.to_string(kind) <> "-" <> Atom.to_string(location))
      File.mkdir!(directory)
      path = Path.join(directory, "intent")
      observed = if location == :final, do: path, else: path <> ".tmp"
      other = Path.join(directory, "other")
      put(other, record_bytes(), 0o600)

      case kind do
        :symlink -> File.ln_s!(other, observed)
        :hardlink -> File.ln!(other, observed)
        :fifo -> assert {_, 0} = System.cmd("mkfifo", [observed])
      end

      owned = launch(operation(:record, path, record_bytes(), 0o600, :absent))
      assert {{:joined, {:error, :io_error}, %{opens: 0, closes: 0}}, events} = drive(owned)
      refute :open in kinds(events)
      assert File.lstat!(observed).type == node_type(kind)
      assert File.read!(other) == record_bytes()
      joined(owned)
    end
  end

  test "replacement after native open refuses the coupled original descriptor and path", context do
    path = Path.join(context.root, "intent")
    bytes = record_bytes()
    put(path, bytes, 0o600)
    owned = launch(operation(:record, path, bytes, 0o600, :absent), :descriptor_stat)
    {id, kind} = held(owned, :descriptor_stat)
    File.rename!(path, path <> ".old")
    put(path, bytes, 0o600)
    send(owned.guardian, {:proceed, owned.reference, id})
    assert {{:joined, {:error, :io_error}, %{opens: 1, closes: 1}}, events} = drive(owned, [{:issued, id, kind}])
    refute :delete in kinds(events)
    assert File.read!(path) == bytes and File.read!(path <> ".old") == bytes
    joined(owned)
  end

  test "same-size temp overwrite before final validation refuses rather than deleting foreign bytes", context do
    path = Path.join(context.root, "intent")
    bytes = record_bytes()
    put(path, bytes, 0o600)
    put(path <> ".tmp", bytes, 0o600)
    owned = launch(operation(:record, path, bytes, 0o600, :absent), :retained_publication_recheck)
    {id, kind} = held(owned, :retained_publication_recheck)
    foreign = :binary.copy("x", byte_size(bytes))
    File.write!(path <> ".tmp", foreign)
    send(owned.guardian, {:proceed, owned.reference, id})
    assert {{:joined, {:error, :io_error}, %{opens: opens, closes: opens}}, events} = drive(owned, [{:issued, id, kind}])
    refute :delete in kinds(events)
    assert File.read!(path) == bytes and File.read!(path <> ".tmp") == foreign
    joined(owned)
  end

  test "persistent ancestor replacement before final validation refuses and retains the real temp", context do
    directory = Path.join(context.root, "parent")
    moved = Path.join(context.root, "moved")
    File.mkdir!(directory)
    path = Path.join(directory, "intent")
    bytes = record_bytes()
    put(path <> ".tmp", bytes, 0o600)
    owned = launch(operation(:record, path, bytes, 0o600, :absent), :retained_publication_recheck)
    {id, kind} = held(owned, :retained_publication_recheck)
    File.rename!(directory, moved)
    File.mkdir!(directory)
    send(owned.guardian, {:proceed, owned.reference, id})
    assert {{:joined, {:error, :io_error}, %{opens: opens, closes: opens}}, events} = drive(owned, [{:issued, id, kind}])
    refute :rename in kinds(events)
    assert File.read!(Path.join(moved, "intent.tmp")) == bytes
    assert File.lstat(path) == {:error, :enoent}
    joined(owned)
  end

  test "native final readback observes changed bytes and refuses after the real rename", context do
    path = Path.join(context.root, "intent")
    bytes = record_bytes()
    owned = launch(operation(:record, path, bytes, 0o600, :absent), :read)
    {id, events} = held_readback(owned, path, [])
    foreign = :binary.copy("x", byte_size(bytes))
    File.write!(path, foreign)
    send(owned.guardian, {:proceed, owned.reference, id})
    assert {{:joined, {:error, :io_error}, %{opens: opens, closes: opens}}, events} = drive(owned, events)
    assert :rename in kinds(events) and :directory_sync in kinds(events)
    assert File.read!(path) == foreign
    refute File.exists?(path <> ".tmp")
    joined(owned)
  end

  test "guardian death with an actual temp descriptor remains unconfirmed after exact actor joins", context do
    path = Path.join(context.root, "intent")
    bytes = record_bytes()
    owned = launch(operation(:record, path, bytes, 0o600, :absent), :file_sync)
    {_id, _kind} = held(owned, :file_sync)
    Process.exit(owned.guardian, :kill)
    assert {{:unconfirmed, :guardian_lost}, _} = drive(owned)
    guardian = owned.guardian
    gm = owned.guardian_monitor
    worker = owned.worker
    wm = owned.worker_monitor
    caller = owned.caller
    cm = owned.caller_monitor
    assert_receive {:DOWN, ^gm, :process, ^guardian, :killed}, 1_000
    assert_receive {:DOWN, ^wm, :process, ^worker, :killed}, 1_000
    assert_receive {:DOWN, ^cm, :process, ^caller, :normal}, 1_000
    assert File.lstat(path) == {:error, :enoent}
    assert File.read!(path <> ".tmp") == bytes
  end

  test "caller loss before actual temp sync closes its descriptor and leaves payload unpromoted", context do
    path = Path.join(context.root, "intent")
    bytes = record_bytes()
    owned = launch(operation(:record, path, bytes, 0o600, :absent), :file_sync)
    {_id, _kind} = held(owned, :file_sync)
    Process.exit(owned.caller, :kill)
    caller = owned.caller
    cm = owned.caller_monitor
    assert_receive {:DOWN, ^cm, :process, ^caller, :killed}, 1_000
    guardian = owned.guardian
    worker = owned.worker
    reference = owned.reference
    assert_receive {:restore_io, ^guardian, ^worker, ^reference,
                    {:terminal, {:joined, {:error, :caller_lost}, %{opens: 1, closes: 1}}}}, 1_000
    assert File.lstat(path) == {:error, :enoent}
    assert File.read!(path <> ".tmp") == bytes
    joined(owned, false)
  end

  defp record_bytes do
    hash = hash("current retained publication vector")
    assert {:ok, bytes} = RestoreCodec.encode(:ledger_intent, %{
      "kind" => "loopex_current_restore_ledger_intent_v1", "ordinal" => 1,
      "tx_id" => hash, "intent_sha256" => hash, "relative_root" => "receipts",
      "source_state_binding" => hash, "destination_state_binding" => hash,
      "source_generation_sha256" => hash, "destination_generation_sha256" => hash,
      "source_ledger_binding" => hash, "destination_ledger_binding" => hash
    })
    bytes
  end

  defp generation_bytes(epoch) do
    assert {:ok, bytes} = RestoreCodec.encode(:generation, %{
      :ledger_kind => "local_executor_generation_v1", "executor_identity" => "retained-executor",
      "executor_epoch" => epoch, "generation_id" => Base.encode16(<<epoch::unsigned-256>>, case: :lower),
      "root_binding" => hash("retained physical generation binding")
    })
    bytes
  end

  defp put(path, bytes, file_mode) do
    File.write!(path, bytes, [:binary, :exclusive])
    File.chmod!(path, file_mode)
  end

  defp image(root) do
    File.ls!(root)
    |> Enum.sort()
    |> Enum.map(fn name ->
      path = Path.join(root, name)
      info = File.lstat!(path)
      {name, info.type, Bitwise.band(info.mode, 0o7777), info.size, info.links, info.inode, File.read!(path)}
    end)
  end

  defp node_type(:symlink), do: :symlink
  defp node_type(:hardlink), do: :regular
  defp node_type(:fifo), do: :other

  defp operation(role, path, bytes, file_mode, expected),
    do: {:restore_publish, role, path, bytes, file_mode, expected}

  defp limits, do: %{"work_ms" => 10_000, "cleanup_grace_ms" => 1_000}
  defp mode(path), do: Bitwise.band(File.lstat!(path).mode, 0o7777)
  defp hash(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  # Concept: native actors belong to one original invocation and exact monitors.
  # Technical depth: install the existing real primitive pause before observing
  # their monitors. All drives share its captured work plus cleanup bound.
  defp launch(operation, pause \\ :retained_publication_stat) do
    parent = self()
    tag = make_ref()
    {caller, caller_monitor} = spawn_monitor(fn ->
      send(parent, {tag, RestoreIO.run(operation, limits(), probe: parent, pause_at: pause)})
    end)
    assert_receive {:restore_io, guardian, worker, reference, {:installed, admitted, cutoff}}, 1_000
    guardian_monitor = Process.monitor(guardian)
    worker_monitor = Process.monitor(worker)
    on_exit(fn ->
      for actor <- [caller, guardian, worker], Process.alive?(actor) do
        monitor = Process.monitor(actor)
        Process.exit(actor, :kill)
        assert_receive {:DOWN, ^monitor, :process, ^actor, _}, 1_000
      end
    end)
    assert cutoff == admitted + 10_000
    %{caller: caller, caller_monitor: caller_monitor, guardian: guardian,
      guardian_monitor: guardian_monitor, worker: worker, worker_monitor: worker_monitor,
      reference: reference, tag: tag, pause: pause, observation_cutoff: admitted + 20_000}
  end

  defp held(owned, expected) do
    guardian = owned.guardian
    worker = owned.worker
    reference = owned.reference
    receive do
      {:restore_io, ^guardian, ^worker, ^reference, {:issued, id, kind}} ->
        if name(kind) == expected, do: {id, kind}, else: held(owned, expected)
      {:restore_io, ^guardian, ^worker, ^reference, _} -> held(owned, expected)
    after
      left(owned.observation_cutoff) -> flunk("the exact original primitive was not held")
    end
  end

  # Concept: the fault is held at an actual final read after native publication.
  # Technical depth: earlier real reads proceed under the same original cutoff;
  # no fixture or invocation restarts, synthetic reply or favorable retry exists.
  defp held_readback(owned, path, events) do
    guardian = owned.guardian
    worker = owned.worker
    reference = owned.reference
    tag = owned.tag
    receive do
      {:restore_io, ^guardian, ^worker, ^reference, {:issued, id, :read} = event} ->
        events = [event | events]
        if File.exists?(path) and not File.exists?(path <> ".tmp") do
          {id, events}
        else
          send(guardian, {:proceed, reference, id})
          held_readback(owned, path, events)
        end
      {:restore_io, ^guardian, ^worker, ^reference, event} ->
        held_readback(owned, path, [event | events])
      {^tag, result} ->
        flunk("publication ended before its actual final read: #{inspect(result)}")
    after
      left(owned.observation_cutoff) -> flunk("original final read was not held")
    end
  end

  defp drive(owned, events \\ []) do
    guardian = owned.guardian
    worker = owned.worker
    reference = owned.reference
    tag = owned.tag
    receive do
      {:restore_io, ^guardian, ^worker, ^reference, event} ->
        case event do
          {:issued, id, kind} ->
            if name(kind) == owned.pause, do: send(guardian, {:proceed, reference, id})
          _ -> :ok
        end
        drive(owned, [event | events])
      {^tag, result} -> {result, Enum.reverse(events)}
    after
      left(owned.observation_cutoff) -> flunk("original publication invocation did not join")
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

  defp kinds(events), do: for({:issued, _, kind} <- events, do: name(kind))
  defp name(kind), do: if(is_tuple(kind), do: elem(kind, 0), else: kind)
  defp index(values, value), do: Enum.find_index(values, &(&1 == value))
  defp left(cutoff), do: max(cutoff - System.monotonic_time(:millisecond), 0)
end
