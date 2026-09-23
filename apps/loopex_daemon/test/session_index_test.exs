defmodule LoopexDaemon.SessionIndexTest do
  use ExUnit.Case, async: true

  alias LoopexDaemon.SessionIndex
  alias LoopexDaemon.SessionIndex.Storage

  test "a fresh root persists an empty image and a legacy root requires import" do
    fresh = temporary_root("fresh")
    legacy = temporary_root("legacy")
    File.mkdir!(Path.join(legacy, "sessions"))

    on_exit(fn ->
      File.rm_rf!(fresh)
      File.rm_rf!(legacy)
    end)

    assert {:ok, index} = start_index(fresh)
    assert %{entries: 0, full: false, poisoned: false} = SessionIndex.status(index)
    assert {:ok, []} = Storage.load(Path.join(fresh, "daemon"), File.stat!(fresh).uid)
    GenServer.stop(index)

    previous = Process.flag(:trap_exit, true)
    assert {:error, :session_index_upgrade_required} = start_index(legacy)
    Process.flag(:trap_exit, previous)
  end

  test "recording is durable, idempotent and placement-bound" do
    root = temporary_root("record")
    on_exit(fn -> File.rm_rf!(root) end)

    assert {:ok, index} = start_index(root)
    assert :ok = SessionIndex.record(index, "session", "placement")
    assert :ok = SessionIndex.record(index, "session", "placement")

    assert {:error, :composition_mismatch} =
             SessionIndex.record(index, "session", "other")

    GenServer.stop(index)
    assert {:ok, reopened} = start_index(root)

    assert {:ok, %{entries: [%{session_id: "session", placement_identity: "placement"}]}} =
             SessionIndex.page(reopened, nil, 256)

    GenServer.stop(reopened)
  end

  test "pages use raw-byte order and an exclusive continuation cursor" do
    root = temporary_root("pages")
    on_exit(fn -> File.rm_rf!(root) end)

    assert {:ok, index} = start_index(root)

    for session_id <- [<<255>>, <<0>>, <<2>>, <<1>>] do
      assert :ok = SessionIndex.record(index, session_id, "p")
    end

    assert {:ok,
            %{
              entries: [%{session_id: <<0>>}, %{session_id: <<1>>}],
              next_after_session_id: <<1>>,
              index_full: false
            }} = SessionIndex.page(index, nil, 2)

    assert {:ok,
            %{
              entries: [%{session_id: <<2>>}, %{session_id: <<255>>}],
              index_full: false
            }} = SessionIndex.page(index, <<1>>, 2)

    assert {:error, :invalid_page} = SessionIndex.page(index, nil, 0)
    assert {:error, :invalid_page} = SessionIndex.page(index, "", 1)
    GenServer.stop(index)
  end

  test "a full persisted index remains readable and omits a later row" do
    root = temporary_root("full")
    directory = Path.join(root, "daemon")
    uid = File.stat!(root).uid
    assert :ok = Storage.prepare(directory, uid)

    rows =
      for value <- 0..4_095 do
        %{session_id: <<value::unsigned-integer-size(16)>>, placement_identity: "p"}
      end

    assert :ok = Storage.publish(directory, uid, rows)
    on_exit(fn -> File.rm_rf!(root) end)

    assert {:ok, index} = start_index(root)
    assert %{entries: 4_096, full: true} = SessionIndex.status(index)
    assert {:ok, :index_full} = SessionIndex.record(index, <<255, 255, 255>>, "p")

    assert {:ok, %{entries: entries, index_full: true, next_after_session_id: cursor}} =
             SessionIndex.page(index, nil, 256)

    assert length(entries) == 256
    assert cursor == <<255::unsigned-integer-size(16)>>
    GenServer.stop(index)
  end

  test "an unverifiable publication poisons later writes without changing rows" do
    root = temporary_root("poison")
    directory = Path.join(root, "daemon")
    temporary = Path.join(directory, "session-index-v1.next")
    on_exit(fn -> File.rm_rf!(root) end)

    assert {:ok, index} = start_index(root)
    assert :ok = SessionIndex.record(index, "stable", "p")
    File.write!(temporary, "foreign")

    assert {:error, :index_write_failed} = SessionIndex.record(index, "one", "p")
    assert %{entries: 1, poisoned: true} = SessionIndex.status(index)
    assert :ok = SessionIndex.record(index, "stable", "p")
    assert {:error, :composition_mismatch} = SessionIndex.record(index, "stable", "other")
    assert {:error, :index_write_failed} = SessionIndex.record(index, "two", "p")
    assert File.read!(temporary) == "foreign"
    GenServer.stop(index)
  end

  defp start_index(root) do
    SessionIndex.start_link(state_root: root, daemon_uid: File.stat!(root).uid)
  end

  defp temporary_root(label) do
    path =
      Path.join(
        System.tmp_dir!(),
        "loopex-daemon-live-index-#{label}-#{Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)}"
      )

    File.mkdir!(path)
    path
  end
end
