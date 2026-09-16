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

# Concept: the independent JavaScript client is exercised with whatever Node the
# host already has; Node is not a dependency of this suite.
#
# Technical depth: cases that start the Node client carry `:node_client` and are
# left out of an ordinary run, so `mix test` and every inherited gate need no
# Node at all. The M4 gate runs them through its selector runner, which does not
# read this helper, after verifying the pinned interpreter and reporting its
# absence as unavailable; on a host with Node, `mix test --include node_client`
# runs them directly.
ExUnit.start(exclude: [:node_client])
