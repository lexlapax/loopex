defmodule Mix.Tasks.Loopex.Status do
  @shortdoc "Validates paired project documents and the marked status facts they govern"

  @moduledoc """
  ## Concept

  The repository's structural status check. It keeps the visible project state and
  the two-depth documentation complete, connected, and honest: every pair is
  wired together, every directory indexes what it holds, and the canonical
  register and the summaries derived from it agree.

  Run it from the repository root. It validates the current tree only, reads
  nothing but the checked-out documents, and writes nothing, so a reviewer with no
  write access runs the identical command and gets the answer in seconds.

  ## Technical depth

  A thin wrapper: it lists the repository's Markdown documents, calls
  `Loopex.Checks.Status.validate/1`, and raises `Mix.Error` on any message so the
  aggregate and the gate runner see a non-zero exit.
  """

  use Mix.Task

  alias Loopex.Checks.Git
  alias Loopex.Checks.Invalid
  alias Loopex.Checks.Status

  @impl Mix.Task
  def run(args) do
    root = root(args)

    case check(root) do
      :ok -> Mix.shell().info("status check passed")
      {:error, messages} -> Mix.raise(Enum.join(messages, "\n"))
    end
  end

  defp root(["--root", root | _rest]), do: root
  defp root([root]), do: root
  defp root(_args), do: repository_root()

  # Concept: an umbrella child runs with its own directory as the working
  # directory, so the repository root is found rather than assumed.
  defp repository_root do
    case Git.run(File.cwd!(), ["rev-parse", "--show-toplevel"]) do
      {output, 0} -> String.trim(output)
      _other -> File.cwd!()
    end
  end

  @doc """
  ## Concept

  Runs the status check against a repository root and returns `:ok` or the
  messages describing what is wrong.

  ## Technical depth

  Public so a test can exercise the same entrypoint against a real checkout
  rather than reimplementing the wiring. An unavailable document inventory is
  itself a failure message, not an exception, so the caller reports it the same
  way as any structural defect.
  """
  @spec check(Path.t()) :: :ok | {:error, [String.t()]}
  def check(root) do
    case root |> Git.documents() |> Status.validate() do
      [] -> :ok
      found -> {:error, found}
    end
  rescue
    error in Invalid -> {:error, [Exception.message(error)]}
  end
end
