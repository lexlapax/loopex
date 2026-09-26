# Concept: a temporary path a test creates is never one an earlier run left
# behind. A run killed before its `on_exit` leaves its root in place, and a
# later run reusing that name would inherit its Store and files.
#
# Technical depth: names carry 64 random bits instead of a per-VM counter,
# which repeats across fresh VMs, and `path/2` returns only a name that does
# not exist when it is chosen, so the test's own creation of it is the first.
defmodule Loopex.TestTmp.Daemon do
  @moduledoc false

  def token, do: Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

  def path(prefix, suffix \\ "", base \\ System.tmp_dir!()) do
    candidate = Path.join(base, prefix <> token() <> suffix)
    if File.exists?(candidate), do: path(prefix, suffix, base), else: candidate
  end
end

ExUnit.start(exclude: [:cross_uid, :real_provider, :node_client, :long_bound])
