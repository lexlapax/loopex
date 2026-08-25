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

  The decision is taken here, at the terminal, and only where there is an
  operator at one. An interactive run is shown what was found and asked; a
  non-interactive run is told what was withheld and why, and is never refused
  over it. Failing closed withholds the content, never the runtime.
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

  Shows the operator what was found and, where there is an operator to ask,
  asks them.

  ## Technical depth

  Returns the decision to bind, or `nil` where none was taken. A decision is
  taken only from an answer typed at an interactive terminal: it carries the
  digest of the exact manifest that was displayed, so it is invalid the moment
  the workspace, its revision, the resolved set, or any file's content changes,
  and the kernel refuses it rather than staging content the operator did not
  see.

  Interactivity is read from the input device rather than assumed. A pipe, a
  redirect, a closed descriptor, and anything the runtime cannot classify are
  all non-interactive, because a prompt nobody can answer would either hang the
  run or be answered by whatever happened to be on standard input -- and
  content admitted from the second is content no operator ever consented to.
  """
  @spec decide(map() | nil, Path.t()) :: map() | nil
  def decide(manifest, workspace), do: decide(manifest, workspace, operator_present?())

  @doc """
  ## Concept

  The same decision, told whether there is an operator to ask.

  ## Technical depth

  Operator presence is an argument rather than something this function reads,
  because the two are separate facts and only one of them can be observed
  without a terminal. `decide/2` supplies it from the real input device;
  `operator_present?/0` is what it consults, and it fails closed.
  """
  @spec decide(map() | nil, Path.t(), boolean()) :: map() | nil
  def decide(nil, workspace, _operator_present) do
    announce(nil, workspace)
    nil
  end

  def decide(manifest, workspace, operator_present) do
    case ProjectResource.digest(manifest) do
      {:error, _reason, _detail} ->
        announce(manifest, workspace)
        nil

      {:ok, digest, resolved} ->
        present(digest, resolved)

        if operator_present do
          ask(manifest, digest)
        else
          IO.puts(
            :stderr,
            "loopex: this terminal is not interactive, so no trust decision was taken; " <>
              "the block is staged empty and the run continues without it"
          )

          nil
        end
    end
  end

  @doc """
  ## Concept

  Whether there is somebody at this terminal to ask.

  ## Technical depth

  `:stdin` is the runtime's own view of the input device: `true` only for a
  terminal, `false` for a pipe or a redirect, and an error term for a
  descriptor it cannot interrogate. Only the first is an operator. Everything
  else, the unclassifiable included, is absence -- a prompt nobody can answer
  either hangs the run or is answered by whatever happened to be on standard
  input, and content admitted from the second is content no operator consented
  to.
  """
  @spec operator_present?() :: boolean()
  def operator_present? do
    Keyword.get(:io.getopts(:standard_io), :stdin) == true
  rescue
    _error -> false
  end

  defp ask(manifest, digest) do
    IO.write(:stderr, "loopex: admit these project resources for this run? [y/N] ")

    answer =
      case IO.gets("") do
        text when is_binary(text) -> text |> String.trim() |> String.downcase()
        _eof_or_error -> ""
      end

    if answer in ["y", "yes"] do
      IO.puts(:stderr, "loopex: project resources admitted for this run")

      %{
        manifest_digest: digest,
        workspace_ref: manifest.workspace.workspace_ref,
        trust_scope: "project_resource",
        decision_source: "terminal_prompt",
        revocation_state: "active",
        expires_at: nil
      }
    else
      IO.puts(:stderr, "loopex: project resources withheld from this run")
      nil
    end
  end

  # Technical depth: the trust class is stated beside the provenance class
  # because they are different facts -- where the content came from, and what
  # admitting it would mean -- and an operator deciding needs both.
  defp present(digest, resolved) do
    IO.puts(:stderr, "loopex: project resources found in this workspace:")

    for entry <- resolved do
      IO.puts(
        :stderr,
        "  \u00b7 #{entry.label} (#{byte_size(entry.content)} bytes, " <>
          "provenance workspace_root, trust class project_resource)"
      )
    end

    IO.puts(:stderr, "loopex: manifest digest #{digest}")
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
            "  · #{entry.label} (#{byte_size(entry.content)} bytes, from the workspace root)"
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
