defmodule LoopexCli.Policy.RefuseAll do
  @moduledoc """
  ## Concept

  The authority a reconciling command runs under: none at all.

  `loopex cancel` submits an abort and runs no tool. It still needs a host policy,
  because the runtime refuses to start without one, and the honest policy for a
  command that should run nothing is one that permits nothing.

  ## Technical depth

  The alternative was to fall back to the permissive policy, which would have made
  that policy exactly what it is documented never to be: an implicit default an
  operator did not name. Worse, they would not be told — its notice fires at a tool
  call, and this command makes none — so the one permissive policy in the system
  would have become silently reachable without being named.

  Refusing is both the safe default and the true one. A reconciling run that
  somehow reached a tool call has departed from what `cancel` is for, and a refusal
  is the right answer rather than a surprise permission. An operator who names a
  policy with `--policy` still gets theirs.
  """

  @behaviour Loopex.Policy

  @impl Loopex.Policy
  # A published category, for the reason recorded in `ShellAllowlist`: an
  # invented one now reads to the operator as a broken policy.
  def decide(_request), do: {:deny, :policy_denied}
end
