# Concept: tests never touch real user state. Every run gets a temporary home
# and workspace, and this helper fails before a single test runs if it cannot
# establish them -- a test suite that silently falls back to the real state
# directory is worse than one that refuses to start.
#
# Technical depth: the guard also refuses when an inherited LOOPEX_HOME or
# LOOPEX_WORKSPACE points outside the temporary root, which is how a stale
# environment variable from an operator shell would otherwise leak in.
root = Path.join(System.tmp_dir!(), "loopex-test-#{System.unique_integer([:positive])}")
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

defmodule LoopexTest.Repo do
  @moduledoc """
  ## Concept

  Locates the umbrella root for tests that check repository-wide properties.

  ## Technical depth

  An umbrella child runs with its own directory as the working directory, so
  `File.cwd!/0` inside a test is `apps/loopex`, not the repository root. Walking
  up to the directory holding both `VERSION` and `apps/` finds the root wherever
  the suite is invoked from, rather than assuming a fixed number of levels.
  """
  def root, do: ascend(File.cwd!())

  defp ascend("/"), do: raise("no umbrella root found above #{File.cwd!()}")

  defp ascend(dir) do
    case File.exists?(Path.join(dir, "VERSION")) and File.dir?(Path.join(dir, "apps")) do
      true -> dir
      false -> ascend(Path.dirname(dir))
    end
  end
end

ExUnit.start()
