defmodule LoopexDaemon.PrepareIndexTest do
  use ExUnit.Case, async: false
  @moduletag capture_log: true

  alias LoopexComposition.Placement
  alias LoopexDaemon.{LegacyImport, PrepareIndex, SessionIndex}
  alias LoopexDaemon.SessionIndex.Storage

  setup do
    root = Path.join(System.tmp_dir!(), "lpi-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    %{root: root, uid: File.stat!(root).uid, daemon: Path.join(root, "daemon")}
  end

  # Concept: an import whose publication fails exits with the index write
  # class and leaves the root to the next attempt.
  test "a failed publication ends the import session_index_write_failed", context do
    :ok = Loopex.track_session(context.root, "s-one", "placement-a")

    assert PrepareIndex.run(context.root,
             install_signals: false,
             storage: [sync_directory: fn _path -> {:error, :eio} end]
           ) == {:error, :session_index_write_failed}

    assert Placement.live_owner(context.root) == :none
    assert PrepareIndex.run(context.root, install_signals: false) == {:ok, 1}
  end

  test "a legacy root imports every recorded session and then starts", context do
    :ok = Loopex.track_session(context.root, "s-one", "placement-a")
    :ok = Loopex.track_session(context.root, "s-two", "placement-a")
    File.write!(Path.join([context.root, "sessions", "s-three.tmp-123"]), "partial")

    assert {:error, :session_index_upgrade_required} = start_index(context)
    assert PrepareIndex.run(context.root, install_signals: false) == {:ok, 2}

    assert {:ok,
            [
              %{session_id: "s-one", placement_identity: "placement-a"},
              %{session_id: "s-two", placement_identity: "placement-a"}
            ]} = Storage.load(context.daemon, context.uid)

    assert {:ok, index} = start_index(context)
    assert %{entries: 2} = SessionIndex.status(index)
    GenServer.stop(index)

    # Importing again is idempotent and releases the root every time.
    assert PrepareIndex.run(context.root, install_signals: false) == {:ok, 2}
    assert Placement.live_owner(context.root) == :none
  end

  test "a root with no sessions publishes an empty index", context do
    assert PrepareIndex.run(context.root, install_signals: false) == {:ok, 0}
    assert {:ok, []} = Storage.load(context.daemon, context.uid)
  end

  test "one unreadable entry refuses the whole import and keeps the prior index", context do
    :ok = Loopex.track_session(context.root, "s-good", "placement-a")
    assert {:ok, 1} = PrepareIndex.run(context.root, install_signals: false)
    prior = File.read!(Path.join(context.daemon, "session-index-v1"))

    for {name, bytes} <- [
          {"s-garbage", "not a term"},
          {"s-renamed",
           :erlang.term_to_binary(%{session_id: "other", runtime_id: "p", commands: %{}})},
          {"s-extra",
           :erlang.term_to_binary(%{session_id: "s-extra", runtime_id: "p", commands: %{}, x: 1})},
          {"s-bad-command",
           :erlang.term_to_binary(%{
             session_id: "s-bad-command",
             runtime_id: "p",
             commands: %{"c" => "someone-else"}
           })},
          {"s-compressed", compressed_entry("s-compressed")}
        ] do
      path = Path.join([context.root, "sessions", name])
      File.write!(path, bytes)

      assert PrepareIndex.run(context.root, install_signals: false) ==
               {:error, :session_index_corrupt},
             name

      assert File.read!(Path.join(context.daemon, "session-index-v1")) == prior
      File.rm!(path)
    end

    assert Placement.live_owner(context.root) == :none
  end

  test "a legacy entry that rebinds an indexed session refuses", context do
    :ok = Loopex.track_session(context.root, "s-bound", "placement-a")
    assert {:ok, 1} = PrepareIndex.run(context.root, install_signals: false)

    :ok =
      Storage.publish(context.daemon, context.uid, [
        %{session_id: "s-bound", placement_identity: "placement-b"}
      ])

    assert PrepareIndex.run(context.root, install_signals: false) ==
             {:error, :session_index_corrupt}
  end

  test "a live store writer refuses the import", context do
    {:ok, store} = Loopex.Store.Local.start_link(path: Path.join(context.root, "store.log"))

    assert PrepareIndex.run(context.root, install_signals: false) ==
             {:error, :store_writer_active}

    GenServer.stop(store)
    assert Placement.live_owner(context.root) == :none
  end

  test "a stop during the scan interrupts it, releases the root and keeps the index",
       context do
    test = self()

    blocking_scan = fn _root, _uid ->
      send(test, {:scanning, self()})
      Process.sleep(:infinity)
    end

    task =
      Task.async(fn ->
        PrepareIndex.run(context.root,
          install_signals: false,
          notify: test,
          scan: blocking_scan
        )
      end)

    assert_receive {:loopex_prepare_index, sentinel, ref}, 5_000
    assert_receive {:scanning, worker}, 5_000
    send(sentinel, {:daemon_signal, ref, :sigterm})

    assert Task.await(task, 45_000) == {:error, :prepare_index_interrupted}
    refute Process.alive?(worker)
    assert Placement.live_owner(context.root) == :none
    assert {:ok, :missing} = Storage.load(context.daemon, context.uid)
  end

  test "the strict reader refuses an unowned or replaced sessions directory", context do
    :ok = Loopex.track_session(context.root, "s-one", "placement-a")
    uid = context.uid

    foreign = fn path ->
      {:ok, stat} = File.lstat(path)
      {:ok, %{stat | uid: uid + 1}}
    end

    assert LegacyImport.scan(context.root, uid, foreign) == {:error, :state_root_unusable}

    counter = :counters.new(1, [])

    replaced = fn path ->
      :counters.add(counter, 1, 1)
      {:ok, stat} = File.lstat(path)

      if :counters.get(counter, 1) > 1,
        do: {:ok, %{stat | inode: stat.inode + 1}},
        else: {:ok, stat}
    end

    assert LegacyImport.scan(context.root, uid, replaced) == {:error, :state_root_unusable}

    assert {:ok, [%{session_id: "s-one", placement_identity: "placement-a"}]} =
             LegacyImport.scan(context.root, uid)
  end

  # A repetitive, otherwise valid entry, so the compressed tag is really present.
  defp compressed_entry(session_id) do
    commands = Map.new(1..200, &{"command-#{&1}", session_id})

    bytes =
      :erlang.term_to_binary(%{session_id: session_id, runtime_id: "p", commands: commands},
        compressed: 9
      )

    <<131, 80, _rest::binary>> = bytes
    bytes
  end

  defp start_index(context) do
    Process.flag(:trap_exit, true)

    result =
      SessionIndex.start_link(state_root: context.root, daemon_uid: context.uid)

    Process.flag(:trap_exit, false)
    result
  end
end
