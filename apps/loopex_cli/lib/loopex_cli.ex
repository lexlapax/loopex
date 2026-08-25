defmodule LoopexCli do
  @moduledoc """
  ## Concept

  `loopex` — the command an operator actually runs. They stand in a Git
  repository, describe a change in ordinary words, and watch the session read
  files, edit them, and run commands until the work is done.

  It is a peer surface, not the product. Every flow it offers is a projection of
  the same embedded API an embedder calls: it owns no loop, no durable session
  truth, no cursor truth, no Store access, and no authority decision. If this
  command disappeared, everything it does would still be reachable.

  ## Technical depth

  The command drives only the public `Loopex` facade and the one composition
  entry point. Beyond those it names only the host policy modules an operator may
  select with `--policy`, which is the host's own decision and the one decision
  the shipped composition deliberately refuses to make for anybody.

  Argument parsing and terminal output use the standard library only. A
  dependency here would be a dependency in the operator's install for the sake of
  flag parsing, which is not a trade this milestone makes.
  """

  alias LoopexCli.Policy.AllowAll

  @doc """
  ## Concept

  The escript entry point.

  ## Technical depth

  Dispatches on the first argument and prints usage for anything it does not
  recognise, rather than guessing. Exit status is set explicitly so a shell
  script wrapping this command can tell success from failure.
  """
  @spec main([binary()]) :: no_return()
  def main(argv) do
    case argv do
      ["run" | rest] -> halt(run(rest))
      ["sessions" | rest] -> halt(sessions(rest))
      ["resume" | rest] -> halt(resume(rest))
      ["cancel" | rest] -> halt(cancel(rest))
      ["artifact" | rest] -> halt(artifact(rest))
      _unrecognised -> halt(usage())
    end
  end

  @doc """
  ## Concept

  The permissive policy this command ships for `--policy allow-all`.

  ## Technical depth

  Named here rather than borrowed from the reference client, because a client may
  not depend on another client. Two shipped permissive policies is the honest
  consequence of that rule; both are selected explicitly and neither is ever an
  implicit fallback.
  """
  @spec policy(binary() | nil) :: {:ok, module()} | {:error, binary()}
  def policy("allow-all"), do: {:ok, AllowAll}
  def policy(nil), do: {:error, "--policy is required; there is no default host authority"}
  def policy(other), do: {:error, "unknown policy #{inspect(other)}"}

  defp run(_argv), do: {:error, "not implemented"}
  defp sessions(_argv), do: {:error, "not implemented"}
  defp resume(_argv), do: {:error, "not implemented"}
  defp cancel(_argv), do: {:error, "not implemented"}
  defp artifact(_argv), do: {:error, "not implemented"}

  defp usage do
    IO.puts("""
    loopex — run a coding task from your terminal

      loopex run --policy allow-all "describe the change"
      loopex sessions
      loopex resume <session>
      loopex cancel <session>
      loopex artifact <reference>
    """)

    :ok
  end

  defp halt(:ok), do: System.halt(0)

  defp halt({:error, message}) do
    IO.puts(:stderr, "loopex: #{message}")
    System.halt(1)
  end
end
