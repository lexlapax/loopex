# Concept: the real-provider lane is opt-in. `real_provider` is excluded here, so
# an ordinary `mix test` never reaches a provider no matter which key sits in the
# operator's environment; only an explicit `--only real_provider` runs it.
#
# Technical depth: the exclusion lives in this application's own helper rather
# than in a root configuration, because the umbrella root runs no tests of its
# own and a root-level setting would not apply when this file is the selector.

# Concept: tests never touch real user state. Every run gets a temporary home and
# workspace, and this helper fails before a single test runs if it cannot
# establish them -- a suite that silently falls back to the real state directory
# is worse than one that refuses to start.
root = Path.join(System.tmp_dir!(), "loopex-llm-test-#{System.unique_integer([:positive])}")
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

ExUnit.start(exclude: [:real_provider])
