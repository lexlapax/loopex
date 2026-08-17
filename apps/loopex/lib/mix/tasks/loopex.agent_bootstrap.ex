defmodule Mix.Tasks.Loopex.AgentBootstrap do
  @shortdoc "Proves every client adapter defers to the canonical contract"

  @moduledoc """
  ## Concept

  The structural half of the agent bootstrap check. It proves the client adapters
  are entry points rather than sources: each loads `AGENTS.md` first and the
  context map second, none pins an account-specific model or widens a sandbox,
  protected workflows require explicit invocation, hook registration matches what
  the client will actually run, and the hosted wrapper stays a thin caller of the
  repository command.

  Run it from anywhere in the repository. It reads the checkout and writes
  nothing.

  ## Technical depth

  A thin wrapper over `Loopex.Checks.Bootstrap.check/1`, plus the hook-registration
  check, which is the same obligation from the other side: the adapter's
  configuration must invoke each hook under the event and matcher that makes it
  run. Calling the registration command's own function rather than restating the
  mapping keeps one definition of the requirement.

  The shell entrypoint keeps the assertions that are genuinely about the shell —
  command availability, executable bits, syntax, and running each guard against a
  fixture — because the enduring baseline includes shell and POSIX tools and a
  check may remain a shell entrypoint that calls Mix.
  """

  use Mix.Task

  alias Loopex.Checks.Bootstrap
  alias Mix.Tasks.Loopex.HookRegistration

  @impl Mix.Task
  def run(_args) do
    root = root()

    registration =
      case HookRegistration.check(root) do
        :ok -> []
        {:error, reasons} -> reasons
      end

    case Bootstrap.check(root) ++ registration do
      [] ->
        Mix.shell().info("client adapters defer to the canonical contract")

      reasons ->
        Mix.raise("agent bootstrap violated:\n  " <> Enum.join(reasons, "\n  "))
    end
  end

  defp root do
    case System.cmd("git", ["rev-parse", "--show-toplevel"], stderr_to_stdout: false) do
      {output, 0} -> String.trim(output)
      _other -> File.cwd!()
    end
  end
end
