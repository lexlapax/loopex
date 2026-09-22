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
