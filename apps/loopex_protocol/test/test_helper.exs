# Concept: the contract application's tests never touch real user state either.
# Technical depth: it holds no runtime, so it needs no LOOPEX_HOME of its own;
# the guard exists so that adding stateful behaviour here cannot silently inherit
# an operator's directory.
if System.get_env("LOOPEX_HOME") in [nil, ""] do
  root =
    Path.join(System.tmp_dir!(), "loopex-protocol-test-#{System.unique_integer([:positive])}")

  File.mkdir_p!(root)
  System.put_env("LOOPEX_HOME", root)
  System.at_exit(fn _status -> File.rm_rf(root) end)
end

ExUnit.start()
