defmodule Mix.Tasks.Loopex.Status do
  @shortdoc "Validates paired project documents and the marked status facts they govern"

  @moduledoc """
  ## Concept

  The repository's structural status check. It keeps the visible project state and
  the two-depth documentation complete, connected, and honest: every pair is
  wired together, every directory indexes what it holds, the canonical register
  and the summaries derived from it agree, and every accepted plan, ADR, gate, and
  bound artifact still matches the bytes it was accepted as — at every reachable
  revision, not only in the current tree.

  Run it from the repository root. It reads the checkout and its Git history and
  writes nothing, so a reviewer with no write access runs the identical command.

  ## Technical depth

  A thin wrapper: it assembles the document inventory and the three ways the
  checks reach outside it — a revision resolver, a history reader, and a working-tree
  artifact reader — then calls `Loopex.Checks.Status.validate/2` and raises
  `Mix.Error` on any message so the aggregate and the gate runner see a non-zero
  exit.

  The bound-artifact paths the history reader must fetch are discovered by reading
  every gate's declaration first. A gate whose declaration is malformed is skipped
  here rather than failing: the history walk reports the malformed declaration
  itself with the revision it appeared at, which is the more useful message, and
  failing here would hide it.
  """

  use Mix.Task

  alias Loopex.Checks.Git
  alias Loopex.Checks.Invalid
  alias Loopex.Checks.Plan
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
    documents = Git.documents(root)
    artifacts = declared_artifacts(documents)

    messages =
      Status.validate(documents,
        resolve_file: Git.resolver(root),
        plan_history: Git.history_reader(root, artifacts),
        read_artifact: artifact_reader(root)
      )

    case messages do
      [] -> :ok
      found -> {:error, found}
    end
  rescue
    error in Invalid -> {:error, [Exception.message(error)]}
  end

  defp declared_artifacts(documents) do
    documents
    |> Enum.filter(fn {path, _text} ->
      String.starts_with?(path, "docs/plans/") and String.ends_with?(path, "-gate.md")
    end)
    |> Enum.flat_map(fn {path, text} ->
      try do
        Enum.map(Plan.bound_artifacts(text, path), fn {_digest, target} -> target end)
      rescue
        Invalid -> []
      end
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  # Concept: an artifact is read from inside the repository or not at all.
  # Technical depth: the declared path comes from a document, so it is treated as
  # untrusted input: a path that resolves outside the root reads as missing rather
  # than reaching into the operator's filesystem.
  defp artifact_reader(root) do
    absolute_root = Path.expand(root)

    fn relative ->
      target = Path.expand(relative, absolute_root)

      case String.starts_with?(target, absolute_root <> "/") and File.regular?(target) do
        true -> File.read!(target)
        false -> nil
      end
    end
  end
end
