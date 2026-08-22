# Concept: ordinary Store tests receive an isolated state root and never infer
# the operator's real LOOPEX_HOME.
#
# Technical depth: the protected selector is also runnable without this helper;
# the M1 standalone runner supplies its own isolated LOOPEX_HOME.
root = Path.join(System.tmp_dir!(), "loopex-store-test-#{System.unique_integer([:positive])}")
home = Path.join(root, "home")

case File.mkdir_p(home) do
  :ok -> :ok
  {:error, reason} -> raise "cannot create isolated Store test root: #{inspect(reason)}"
end

System.put_env("LOOPEX_HOME", home)

unless String.starts_with?(System.fetch_env!("LOOPEX_HOME"), root) do
  raise "LOOPEX_HOME escaped the isolated Store test root; refusing to run"
end

System.at_exit(fn _status -> File.rm_rf(root) end)

ExUnit.start()
