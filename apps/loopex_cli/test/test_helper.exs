# Concept: tests never touch real user state. Every run gets a temporary home
# and workspace, and this helper fails before a single test runs if it cannot
# establish them.
#
# Technical depth: the command resolves its state root from `LOOPEX_HOME` when
# no `--state-root` is passed, so a suite that left the variable alone would
# write an operator's real session directory the first time a case exercised the
# default path.
root = Path.join(System.tmp_dir!(), "loopex-cli-test-#{System.unique_integer([:positive])}")
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

# Concept: a child VM a case starts never spins idle schedulers.
#
# Technical depth: the chat, ask, signal, output and daemon fixtures boot
# separate `elixir` VMs that inherit this environment. Scheduler busy-wait on an
# oversubscribed host stretched such a boot from about 1 s to 12-14 s, past the
# fixtures' bounded waits, so their VMs run with busy-wait off; a fixture that
# builds its own environment passes the same flags itself. Production defaults
# are unchanged.
busy_wait_off = "+sbwt none +sbwtdcpu none +sbwtdio none"
erl_options = System.get_env("ELIXIR_ERL_OPTIONS", "")

unless String.contains?(erl_options, busy_wait_off),
  do: System.put_env("ELIXIR_ERL_OPTIONS", String.trim("#{erl_options} #{busy_wait_off}"))

# Concept: fixtures are loaded by the selectors that use them, not here.
#
# Technical depth: the gate compiles a protected selector on its own, without
# this file, so a fixture loaded here would be present under `mix test` and
# missing under the gate -- which is the difference between a case that passes
# and a case that is proved.

ExUnit.start(exclude: [:real_provider, :node_client])
