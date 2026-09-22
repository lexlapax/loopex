defmodule LoopexDaemon.ListenerSocketTest do
  use ExUnit.Case, async: true

  alias LoopexDaemon.ListenerSocket

  @socket_kind 0o140000
  @kind_mask 0o170000
  @permission_mask 0o777

  test "a parked listener is verified and close leaves recovery to its successor" do
    directory = temporary_directory()
    path = Path.join(directory, "daemon.sock")
    daemon_uid = File.stat!(directory).uid

    on_exit(fn ->
      _ = File.rm(path)
      _ = File.rmdir(directory)
    end)

    assert {:ok, first} = ListenerSocket.open_parked(path, daemon_uid)
    assert_verified_socket(path, daemon_uid)
    first_identity = file_identity(path)

    assert :ok = ListenerSocket.close(first)
    assert File.exists?(path)
    assert file_identity(path) == first_identity

    assert {:ok, successor} = ListenerSocket.open_parked(path, daemon_uid)
    assert_verified_socket(path, daemon_uid)
    refute file_identity(path) == first_identity

    assert :ok = ListenerSocket.close(successor)
    assert File.exists?(path)
  end

  test "unsafe retained paths are preserved and never bound" do
    directory = temporary_directory()
    regular = Path.join(directory, "regular")
    link = Path.join(directory, "link")
    target = Path.join(directory, "target")
    daemon_uid = File.stat!(directory).uid

    File.write!(regular, "keep")
    File.write!(target, "target")
    File.ln_s!(target, link)

    on_exit(fn -> File.rm_rf!(directory) end)

    assert {:error, {:socket_permission_unverified, :unsafe_existing_path}} =
             ListenerSocket.open_parked(regular, daemon_uid)

    assert File.read!(regular) == "keep"

    assert {:error, {:socket_permission_unverified, :unsafe_existing_path}} =
             ListenerSocket.open_parked(link, daemon_uid)

    assert {:ok, %File.Stat{type: :symlink}} = File.lstat(link)
    assert File.read_link!(link) == target
  end

  test "a retained socket owned by another uid is preserved" do
    directory = temporary_directory()
    path = Path.join(directory, "daemon.sock")
    daemon_uid = File.stat!(directory).uid

    on_exit(fn ->
      _ = File.rm(path)
      _ = File.rmdir(directory)
    end)

    assert {:ok, socket} = ListenerSocket.open_parked(path, daemon_uid)
    assert :ok = ListenerSocket.close(socket)
    identity = file_identity(path)

    assert {:error, {:socket_permission_unverified, :unsafe_existing_path}} =
             ListenerSocket.prepare_path(path, daemon_uid + 1)

    assert file_identity(path) == identity
  end

  defp temporary_directory do
    path =
      Path.join(
        System.tmp_dir!(),
        "loopex-daemon-listener-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir!(path)
    File.chmod!(path, 0o700)
    path
  end

  defp assert_verified_socket(path, daemon_uid) do
    assert {:ok, %File.Stat{uid: ^daemon_uid, type: :other, mode: mode}} = File.lstat(path)
    assert Bitwise.band(mode, @kind_mask) == @socket_kind
    assert Bitwise.band(mode, @permission_mask) == 0o600
  end

  defp file_identity(path) do
    stat = File.lstat!(path)
    {stat.major_device, stat.minor_device, stat.inode}
  end
end
