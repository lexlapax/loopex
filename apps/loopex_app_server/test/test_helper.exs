# Concept: tests never touch real user state. Every run gets a temporary home
# and workspace, and this helper fails before a single test runs if it cannot
# establish them.
#
# Technical depth: the app-server's own cases drive a real runtime, and a
# runtime reads its state root from the environment, so the same isolation core
# establishes is established here rather than inherited from a sibling's
# helper.
root =
  Path.join(System.tmp_dir!(), "loopex-app-server-test-#{System.unique_integer([:positive])}")

home = Path.join(root, "home")
workspace = Path.join(root, "workspace")

for dir <- [home, workspace] do
  case File.mkdir_p(dir) do
    :ok ->
      :ok

    {:error, posix} ->
      raise "cannot create isolated test state at #{dir}: #{:file.format_error(posix)}"
  end
end

System.put_env("LOOPEX_HOME", home)
System.put_env("LOOPEX_WORKSPACE", workspace)

unless String.starts_with?(System.get_env("LOOPEX_HOME"), root) do
  raise "LOOPEX_HOME escaped the isolated test root; refusing to run"
end

System.at_exit(fn _status -> File.rm_rf(root) end)

# Concept: the independent JavaScript client is exercised with whatever Node the
# host already has; Node is not a dependency of this suite.
#
# Technical depth: cases that start the Node client carry `:node_client` and are
# left out of an ordinary run, so `mix test` and every inherited gate need no
# Node at all. The M4 gate runs them through its selector runner, which does not
# read this helper, after verifying the pinned interpreter and reporting its
# absence as unavailable; on a host with Node, `mix test --include node_client`
# runs them directly.
#
# The real-provider case carries `:real_provider` and is excluded for a second
# reason: it spends a provider credential. An ordinary run must never do that
# by accident, so it runs only when an operator asks for it by name.
ExUnit.start(exclude: [:node_client, :real_provider])
