defmodule LoopexDaemon.PathsTest do
  use ExUnit.Case, async: true

  alias LoopexDaemon.Paths

  test "invalid root and explicit socket bytes keep their distinct classifications" do
    assert {:error, :state_root_required} = Paths.state_root("")
    assert {:error, :state_root_unusable} = Paths.state_root(<<0xFF>>)
    assert {:error, :state_root_unusable} = Paths.startup(<<0xFF>>, nil)

    root = Path.join(System.tmp_dir!(), "loopex-daemon-paths")
    assert {:error, :invalid_socket_path} = Paths.startup(root, <<0xFF>>)
    assert {:error, :invalid_socket_path} = Paths.startup(root, "")
  end

  test "the default and an override resolve only inside the selected daemon directory" do
    root = Path.join(System.tmp_dir!(), "loopex-daemon-root")
    expanded = Path.expand(root)

    assert {:ok, default} = Paths.startup(root)
    assert default.state_root == expanded
    assert default.daemon_directory == Path.join(expanded, "daemon")
    assert default.socket_path == Path.join([expanded, "daemon", "daemon.sock"])

    override = Path.join([expanded, "daemon", "alternate.sock"])
    assert {:ok, %{socket_path: ^override}} = Paths.startup(root, override)

    assert {:error, :invalid_socket_path} =
             Paths.startup(root, Path.join(expanded, "outside.sock"))

    assert {:error, :invalid_socket_path} =
             Paths.startup(root, Path.join([expanded, "daemon", ".."]))
  end

  # Concept: the socket path limit is the platform's own, stated literally, and
  # a path exactly at it really binds while one byte more is refused.
  #
  # Technical depth: Darwin's `sun_path` holds 103 pathname bytes and Linux's
  # 107. A socket is bound and listened on at exactly that length through the
  # daemon's own parked-listener opener, and the next byte refuses
  # `socket_path_too_long` before anything is bound.
  test "the literal platform limit binds exactly and refuses one byte more" do
    expected =
      case :os.type() do
        {:unix, :darwin} -> 103
        {:unix, :linux} -> 107
      end

    assert {:ok, ^expected} = Paths.socket_path_limit()

    root = Loopex.TestTmp.Daemon.path("lpb-", "", "/tmp")
    on_exit(fn -> File.rm_rf(root) end)
    directory = Path.join(root, "daemon")
    File.mkdir_p!(directory)
    File.chmod!(directory, 0o700)
    at_limit = Path.join(directory, String.duplicate("a", expected - byte_size(directory) - 1))
    assert byte_size(at_limit) == expected

    assert {:ok, %{socket_path: ^at_limit}} = Paths.startup(root, at_limit)
    assert {:ok, socket} = LoopexDaemon.ListenerSocket.open_parked(at_limit, File.stat!(root).uid)
    assert {:ok, %File.Stat{type: :other}} = File.lstat(at_limit)
    :socket.close(socket)

    assert {:error, {:socket_path_too_long, ^expected}} = Paths.startup(root, at_limit <> "b")
    refute File.exists?(at_limit <> "b")
  end

  test "the platform limit is enforced on encoded pathname bytes without truncation" do
    assert {:ok, limit} = Paths.socket_path_limit()
    root_prefix = Path.join(System.tmp_dir!(), "loopex-daemon-bound")
    directory = Path.join(root_prefix, "daemon")
    available = limit - byte_size(directory) - 1

    assert available > 1

    at_limit = Path.join(directory, String.duplicate("a", available))
    over_limit = at_limit <> "b"

    assert byte_size(at_limit) == limit

    assert {:ok, %{socket_path: ^at_limit, socket_path_limit: ^limit}} =
             Paths.startup(root_prefix, at_limit)

    assert {:error, {:socket_path_too_long, ^limit}} =
             Paths.startup(root_prefix, over_limit)
  end
end
