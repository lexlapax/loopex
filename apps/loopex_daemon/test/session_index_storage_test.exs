defmodule LoopexDaemon.SessionIndex.StorageTest do
  use ExUnit.Case, async: true

  alias LoopexDaemon.SessionIndex.Storage

  test "a fresh private directory publishes and reloads complete snapshots" do
    root = temporary_root()
    directory = Path.join(root, "daemon")
    daemon_uid = File.stat!(root).uid
    rows = [%{session_id: "session", placement_identity: "placement"}]

    on_exit(fn -> File.rm_rf!(root) end)

    assert :ok = Storage.prepare(directory, daemon_uid)
    assert_mode(directory, :directory, daemon_uid, 0o700)
    assert {:ok, :missing} = Storage.load(directory, daemon_uid)

    assert :ok = Storage.publish(directory, daemon_uid, [])
    assert {:ok, []} = Storage.load(directory, daemon_uid)

    assert :ok = Storage.publish(directory, daemon_uid, rows)
    assert {:ok, ^rows} = Storage.load(directory, daemon_uid)
    assert_mode(Path.join(directory, "session-index-v1"), :regular, daemon_uid, 0o600)
    refute File.exists?(Path.join(directory, "session-index-v1.next"))
  end

  test "startup removes only a same-owner regular fixed temporary" do
    root = temporary_root()
    directory = Path.join(root, "daemon")
    daemon_uid = File.stat!(root).uid
    temporary = Path.join(directory, "session-index-v1.next")

    on_exit(fn -> File.rm_rf!(root) end)

    assert :ok = Storage.prepare(directory, daemon_uid)
    File.write!(temporary, "partial")
    assert :ok = Storage.prepare(directory, daemon_uid)
    refute File.exists?(temporary)

    File.ln_s!("missing", temporary)
    assert {:error, :session_index_corrupt} = Storage.prepare(directory, daemon_uid)
    assert {:ok, %File.Stat{type: :symlink}} = File.lstat(temporary)
  end

  test "directory ownership and mode are verified rather than repaired" do
    root = temporary_root()
    directory = Path.join(root, "daemon")
    daemon_uid = File.stat!(root).uid

    on_exit(fn -> File.rm_rf!(root) end)

    File.mkdir!(directory)
    File.chmod!(directory, 0o755)

    assert {:error, :socket_permission_unverified} =
             Storage.prepare(directory, daemon_uid)

    assert {:error, {:session_index_write_failed, :poisoned}} =
             Storage.publish(directory, daemon_uid, [])

    refute File.exists?(Path.join(directory, "session-index-v1.next"))

    File.chmod!(directory, 0o700)

    assert {:error, :socket_permission_unverified} =
             Storage.prepare(directory, daemon_uid + 1)
  end

  test "load distinguishes oversize from corrupt images and follows no symlink" do
    root = temporary_root()
    directory = Path.join(root, "daemon")
    daemon_uid = File.stat!(root).uid
    index = Path.join(directory, "session-index-v1")

    on_exit(fn -> File.rm_rf!(root) end)

    assert :ok = Storage.prepare(directory, daemon_uid)

    File.write!(index, :binary.copy("x", 4 * 1_024 * 1_024 + 1))
    File.chmod!(index, 0o600)
    assert {:error, :session_index_too_large} = Storage.load(directory, daemon_uid)

    File.write!(index, "not an index\n")
    File.chmod!(index, 0o600)
    assert {:error, :session_index_corrupt} = Storage.load(directory, daemon_uid)

    File.rm!(index)
    target = Path.join(root, "target")
    File.write!(target, "outside")
    File.ln_s!(target, index)
    assert {:error, :session_index_corrupt} = Storage.load(directory, daemon_uid)
    assert File.read!(target) == "outside"
  end

  defp temporary_root do
    path =
      Path.join(
        System.tmp_dir!(),
        "loopex-daemon-index-storage-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir!(path)
    path
  end

  defp assert_mode(path, type, uid, permissions) do
    assert {:ok, %File.Stat{type: ^type, uid: ^uid, mode: mode}} = File.lstat(path)
    assert Bitwise.band(mode, 0o777) == permissions
  end
end
