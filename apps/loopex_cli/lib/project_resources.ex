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

  Containment is this side's job and nobody else's. `Loopex.ProjectResource`
  records `contained` as the supplier's own statement and says plainly that core
  cannot check it, so a host that asserts it without establishing it has told the
  kernel something it has no way to doubt. This module establishes it: every
  candidate is resolved to the path the kernel would actually open, and only a
  path that still lies inside the resolved workspace root is admitted.
  """

  alias Loopex.ProjectResource

  # Concept: a symlink chain has to end somewhere, and a cycle is a filesystem an
  # operator can create by accident.
  #
  # Technical depth: the walk replaces one component per hop, so the bound is on
  # links followed rather than on path length.
  @symlink_hops 32

  @doc """
  ## Concept

  Discovers the project resources in a workspace and returns a manifest.

  ## Technical depth

  Returns `nil` where nothing was found, which is the same thing the runtime is
  handed when no host looked at all. A resource that exists but exceeds a
  declared ceiling is still carried into the manifest, because the ceiling is the
  kernel's to enforce and reporting it as absent would hide a refusal behind a
  discovery result.

  A candidate is resolved before it is stated: `File.regular?/1` and `File.read/1`
  both follow symlinks, so a workspace `AGENTS.md` pointing at a file outside the
  root was read from outside and then reported `contained: true` from a literal.
  The manifest asserted a containment nothing had checked, the kernel is
  documented as unable to check it, and the outside content reached the model's
  staged project block labelled as coming from the workspace root. Resolution
  first and one comparison afterwards catches a relative escape, an absolute
  path, and a symlink alike; string inspection catches only the first two.

  An escape is reported rather than dropped. Silence is how the operator was
  misled in the first place, and a resource that vanishes from the listing is a
  resource they cannot ask about.
  """
  @spec discover(Path.t()) :: map() | nil
  def discover(workspace) do
    with {:ok, root} <- real_path(workspace) do
      case Enum.flat_map(ProjectResource.permitted_labels(), &admit(root, &1)) do
        [] ->
          nil

        found ->
          %{
            entries: found,
            workspace: %{
              workspace_ref: root,
              repository_origin: nil,
              revision: revision(workspace)
            }
          }
      end
    else
      {:error, reason} ->
        excluded(
          "the workspace #{workspace}",
          "its own path could not be resolved (#{inspect(reason)})"
        )

        nil
    end
  end

  # Concept: one candidate, resolved, judged, and read — in that order.
  #
  # Technical depth: the resolved path is carried on the entry rather than
  # recomputed for display, so what the operator is shown is the exact path the
  # bytes were read from and not a second answer to the same question.
  defp admit(root, label) do
    case real_path(Path.join(root, label)) do
      {:ok, resolved} ->
        cond do
          not contained?(resolved, root) ->
            excluded(label, "it resolves to #{resolved}, which is outside #{root}")
            []

          not regular?(resolved) ->
            []

          true ->
            read_entry(label, resolved)
        end

      {:error, reason} ->
        excluded(label, "its path could not be resolved (#{inspect(reason)})")
        []
    end
  end

  defp read_entry(label, resolved) do
    case File.read(resolved) do
      {:ok, content} ->
        [%{label: label, content: content, contained: true, resolved_path: resolved}]

      {:error, reason} ->
        excluded(label, "it could not be read (#{inspect(reason)})")
        []
    end
  end

  defp excluded(label, why) do
    IO.puts(:stderr, "loopex: #{label} was excluded from the project resources because #{why}")
  end

  # Technical depth: the resolved path has no symlink left in it, so `lstat`
  # and `stat` agree here; `lstat` is used because it is the one that cannot be
  # made to answer about a different file than the one named.
  defp regular?(path) do
    match?({:ok, %File.Stat{type: :regular}}, File.lstat(path))
  end

  # Concept: containment is a comparison of resolved paths, not of text.
  #
  # Technical depth: the trailing separator stops `/work` from appearing to
  # contain `/workspace-elsewhere`, which a bare prefix test would admit.
  defp contained?(path, root), do: path == root or String.starts_with?(path, root <> "/")

  # Concept: the path the kernel would open, without moving the emulator.
  #
  # Technical depth: `Path.expand/1` is textual and would normalise away a `..`
  # that a symlink makes mean something else, so each component is resolved
  # against the filesystem before the next is considered. Nothing here changes
  # the working directory, which is global to the emulator rather than local to
  # this process, so two commands resolving at once do not read each other's
  # answer. A component that does not exist resolves to itself, which is what
  # lets a workspace with no `AGENTS.md` be reported absent rather than refused.
  defp real_path(path), do: walk(Path.split(Path.expand(path)), "/", 0)

  defp walk([], resolved, _hops), do: {:ok, resolved}

  defp walk(_remaining, _resolved, hops) when hops > @symlink_hops,
    do: {:error, :symlink_hops_exhausted}

  defp walk(["/" | rest], resolved, hops), do: walk(rest, resolved, hops)
  defp walk(["." | rest], resolved, hops), do: walk(rest, resolved, hops)
  defp walk([".." | rest], resolved, hops), do: walk(rest, Path.dirname(resolved), hops)

  defp walk([segment | rest], resolved, hops) do
    candidate = Path.join(resolved, segment)

    case File.read_link(candidate) do
      {:ok, target} ->
        absolute =
          case Path.type(target) do
            :absolute -> target
            _relative -> Path.join(resolved, target)
          end

        walk(Path.split(absolute) ++ rest, "/", hops + 1)

      {:error, _not_a_link} ->
        walk(rest, candidate, hops)
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
  #
  # The resolved path is stated for a third reason: consent has to be taken
  # against the fact rather than against the label. A label alone cannot show an
  # operator that `AGENTS.md` is a link, and a listing that hides that is a
  # listing they can agree to without knowing what they agreed to.
  defp present(digest, resolved) do
    IO.puts(:stderr, "loopex: project resources found in this workspace:")

    for entry <- resolved do
      IO.puts(
        :stderr,
        "  \u00b7 #{entry.label} at #{shown_path(entry)} " <>
          "(#{byte_size(entry.content)} bytes, " <>
          "provenance workspace_root, trust class project_resource)"
      )
    end

    IO.puts(:stderr, "loopex: manifest digest #{digest}")
  end

  # Technical depth: an entry this module discovered always carries the path it
  # was read from. One assembled elsewhere may not, and the label is then the
  # only true thing there is to say.
  defp shown_path(%{resolved_path: path}) when is_binary(path), do: path
  defp shown_path(%{label: label}), do: label

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
            "  · #{entry.label} at #{shown_path(entry)} " <>
              "(#{byte_size(entry.content)} bytes, from the workspace root)"
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
