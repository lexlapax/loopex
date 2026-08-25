defmodule LoopexCli.ProjectResources do
  @moduledoc """
  ## Concept

  What the terminal finds in a workspace that is written to shape how an agent
  behaves, and what it tells the operator about it before the run starts.

  A repository may carry an `AGENTS.md`. Loopex will not put that content in
  front of the model unless the operator decided it should be there, and an
  operator cannot decide about something they were never shown. This is the
  showing.

  ## Technical depth

  Discovery is the host's job, not the kernel's: `Loopex.ProjectResource`
  validates a manifest and binds a decision to it, and never goes looking for
  one. The command is the host here, so the looking lives here.

  It is deliberately shallow — one label, at the root of the workspace, with no
  recursion and no globbing — because a discovery rule an operator cannot predict
  is one they cannot meaningfully consent to.

  This command takes no decision. A run from a terminal that was never asked is
  the declined path, and it is declined by construction rather than by a flag
  someone has to remember not to pass. What the operator gets is the truth about
  it: what was found, what its digest is, and that it was withheld.
  """

  alias Loopex.ProjectResource

  @doc """
  ## Concept

  Discovers the project resources in a workspace and returns a manifest.

  ## Technical depth

  Returns `nil` where nothing was found, which is the same thing the runtime is
  handed when no host looked at all. A resource that exists but exceeds a
  declared ceiling is still carried into the manifest, because the ceiling is the
  kernel's to enforce and reporting it as absent would hide a refusal behind a
  discovery result.
  """
  @spec discover(Path.t()) :: map() | nil
  def discover(workspace) do
    entries =
      for label <- ProjectResource.permitted_labels(),
          path = Path.join(workspace, label),
          File.regular?(path),
          {:ok, content} <- [File.read(path)] do
        %{label: label, content: content, contained: true}
      end

    case entries do
      [] ->
        nil

      found ->
        %{
          entries: found,
          workspace: %{
            workspace_ref: Path.expand(workspace),
            repository_origin: nil,
            revision: revision(workspace)
          }
        }
    end
  end

  @doc """
  ## Concept

  Tells the operator what was found and what became of it.

  ## Technical depth

  Prints each resolved label, its provenance, its size, and the manifest digest
  a decision would bind — then says plainly that this run withholds it, because
  a non-interactive terminal took no decision. Written to standard error, beside
  the rest of the run's commentary, so a redirected answer is unaffected.

  A manifest the kernel refuses is reported with the reason it gave. Failing
  closed withholds content and never the runtime, so the run continues either
  way and the operator is told which of the two happened.
  """
  @spec announce(map() | nil, Path.t()) :: :ok
  def announce(nil, workspace) do
    IO.puts(
      :stderr,
      "loopex: no project resources found in #{workspace} " <>
        "(looked for #{Enum.join(ProjectResource.permitted_labels(), ", ")})"
    )
  end

  def announce(manifest, _workspace) do
    case ProjectResource.digest(manifest) do
      {:ok, digest, resolved} ->
        IO.puts(:stderr, "loopex: project resources found, and withheld from this run:")

        for entry <- resolved do
          IO.puts(
            :stderr,
            "  · #{entry[:label] || entry["label"]} " <>
              "(#{entry[:bytes] || entry["bytes"] || "?"} bytes, from the workspace root)"
          )
        end

        IO.puts(:stderr, "loopex: manifest digest #{digest}")

        IO.puts(
          :stderr,
          "loopex: this terminal took no trust decision, so the block is staged empty " <>
            "and the run continues without it"
        )

      {:error, reason, detail} ->
        IO.puts(
          :stderr,
          "loopex: project resources were refused (#{reason} #{inspect(detail)}); " <>
            "the run continues without them"
        )
    end

    :ok
  end

  # Concept: the revision a decision would be bound to, where there is one.
  #
  # Technical depth: a decision binds the workspace, the revision, the manifest
  # and the content, so a changed revision invalidates it. A workspace that is
  # not a repository has no revision, and `nil` is the honest answer rather than
  # a placeholder that would make two different trees look like one.
  defp revision(workspace) do
    case System.cmd("git", ["-C", workspace, "rev-parse", "HEAD"], stderr_to_stdout: true) do
      {output, 0} -> String.trim(output)
      _absent -> nil
    end
  end
end
