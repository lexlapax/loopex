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
  alias LoopexProtocol.Canonical
  alias __MODULE__.ResourceReader

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

  A candidate is resolved before it is stated. The earlier `File.regular?/1`
  and `File.read/1` path followed symlinks twice, so a workspace `AGENTS.md`
  pointing at a file outside the root was read from outside and then reported
  `contained: true` from a literal.
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
  def discover(workspace), do: discover(workspace, [])

  @doc false
  @spec runtime_manifest(map() | nil) :: map() | nil
  def runtime_manifest(nil), do: nil

  def runtime_manifest(%{entries: entries} = manifest) when is_list(entries) do
    %{manifest | entries: Enum.map(entries, &Map.drop(&1, [:resolved_path]))}
  end

  @doc false
  @spec discover(Path.t(), keyword()) :: map() | nil
  def discover(workspace, options) when is_list(options) do
    after_containment = Keyword.get(options, :after_containment, fn _resolved -> :ok end)

    with {:ok, root} <- real_path(workspace),
         {:ok, root_identity} <- directory_identity(root) do
      case discover_entries(root, root_identity, after_containment) do
        [] ->
          nil

        found ->
          %{
            entries: found,
            workspace: %{
              workspace_ref: workspace_reference(root, root_identity),
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

  # Concept: discovery retains enough bytes to prove an over-limit resource was
  # present, without making the command hold the whole resource in memory.
  #
  # Technical depth: the extra byte makes the kernel's existing `over_limit`
  # verdict observable rather than trimming an oversized resource into an
  # apparently admissible one. The remaining class budget is carried across the
  # ordered labels, so a future expansion of the permitted set cannot turn the
  # per-file bound into an unbounded class total.
  defp discover_entries(root, root_identity, after_containment) do
    %{per_resource_bytes: per_resource, class_total_bytes: class_total} =
      ProjectResource.limits()

    {entries, _remaining, _over_limit} =
      Enum.reduce(ProjectResource.permitted_labels(), {[], class_total, false}, fn
        _label, state = {_entries, _remaining, true} ->
          state

        label, {entries, remaining, false} ->
          read_limit = min(per_resource, remaining)

          case admit(root, root_identity, label, read_limit, after_containment) do
            [] ->
              {entries, remaining, false}

            [entry] ->
              size = byte_size(entry.content)
              over_limit = size > per_resource or size > remaining
              {[entry | entries], max(remaining - size, 0), over_limit}
          end
      end)

    Enum.reverse(entries)
  end

  # Concept: one candidate, resolved, judged, and read — in that order.
  #
  # Technical depth: the resolved path is carried on the entry rather than
  # recomputed for display, so what the operator is shown is the exact path the
  # bytes were read from and not a second answer to the same question.
  defp admit(root, root_identity, label, read_limit, after_containment) do
    case real_path(Path.join(root, label)) do
      {:ok, resolved} ->
        cond do
          not contained?(resolved, root) ->
            excluded(label, "it resolves to #{resolved}, which is outside #{root}")
            []

          true ->
            # This seam is test-only. It places a deterministic replacement in
            # the exact interval the production reader has to defend: after
            # containment was established and before the candidate is opened.
            _ = after_containment.(resolved)
            read_entry(label, resolved, root, root_identity, read_limit)
        end

      {:error, reason} ->
        excluded(label, "its path could not be resolved (#{inspect(reason)})")
        []
    end
  end

  defp read_entry(label, resolved, root, root_identity, read_limit) do
    case ResourceReader.read_contained(resolved, root, root_identity, read_limit) do
      {:ok, content} ->
        [
          %{
            label: label,
            content: content,
            byte_size: byte_size(content),
            content_digest: Canonical.digest_bytes(content),
            contained: true,
            resolved_path: resolved
          }
        ]

      {:refused, reason} when reason in [:absent, :not_regular] ->
        []

      {:refused, :replaced} ->
        excluded(label, "it was replaced while it was being opened; nothing was read")
        []

      {:error, reason} ->
        excluded(label, "it could not be read (#{inspect(reason)})")
        []
    end
  end

  defp excluded(label, why) do
    IO.puts(:stderr, "loopex: #{label} was excluded from the project resources because #{why}")
  end

  # Concept: containment is a comparison of resolved paths, not of text.
  #
  # Technical depth: the trailing separator stops `/work` from appearing to
  # contain `/workspace-elsewhere`, which a bare prefix test would admit.
  defp contained?(path, "/"), do: String.starts_with?(path, "/")
  defp contained?(path, root), do: path == root or String.starts_with?(path, root <> "/")

  # Concept: core receives an opaque workspace identity, never the host path it
  # would need filesystem authority to interpret.
  #
  # Technical depth: the canonical root and its directory identity are host-side
  # inputs to a deterministic digest. A replacement checkout or different root
  # therefore invalidates the decision, while the value crossing into core
  # reveals no joinable or openable path.
  defp workspace_reference(root, {major_device, inode}) do
    identity = %{
      "canonical_root" => root,
      "major_device" => major_device,
      "inode" => inode
    }

    "workspace:" <> Canonical.digest(identity)
  end

  @doc false
  @spec resolve_path(Path.t()) :: {:ok, Path.t()} | {:error, term()}
  def resolve_path(path), do: real_path(path)

  @doc false
  @spec directory_identity(Path.t()) :: {:ok, {integer(), integer()}} | {:error, term()}
  def directory_identity(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :directory} = stat} ->
        {:ok, {stat.major_device, stat.inode}}

      {:ok, %File.Stat{}} ->
        {:error, :workspace_root_not_directory}

      {:error, reason} ->
        {:error, reason}
    end
  end

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
    case ProjectResource.digest(runtime_manifest(manifest)) do
      {:error, _reason, _detail} ->
        announce(manifest, workspace)
        nil

      {:ok, digest, _resolved} ->
        present(digest, manifest.entries)

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
        decision_source: "interactive_operator",
        issued_at: DateTime.utc_now() |> DateTime.to_iso8601(),
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
          "(#{byte_size(entry.content)} bytes, digest #{entry.content_digest}, " <>
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

  Prints each resolved label, its provenance, size, and content digest, plus the
  manifest digest a decision would bind — then says plainly that this run
  withholds it, because a non-interactive terminal took no decision. Written to
  standard error, beside the rest of the run's commentary, so a redirected
  answer is unaffected.

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
    case ProjectResource.digest(runtime_manifest(manifest)) do
      {:ok, digest, _resolved} ->
        IO.puts(:stderr, "loopex: project resources found, and withheld from this run:")

        for entry <- manifest.entries do
          IO.puts(
            :stderr,
            "  · #{entry.label} at #{shown_path(entry)} " <>
              "(#{byte_size(entry.content)} bytes, digest #{entry.content_digest}, " <>
              "from the workspace root)"
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

  defmodule ResourceReader do
    @moduledoc false

    @type opener :: (Path.t() -> {:ok, File.io_device()} | {:error, File.posix()})

    # Concept: reads the regular file that discovery checked, and no replacement.
    #
    # Technical depth: containment resolves a name and this function must then
    # open that name. Device and inode bind the checked object to the opened
    # handle. A component or final name swapped in between therefore produces a
    # different handle identity and is refused before any content is read.
    #
    # `opener` is injectable so the race boundary can be exercised
    # deterministically. Production uses the default opener below.
    @doc false
    @spec read(Path.t(), non_neg_integer(), opener()) ::
            {:ok, binary()} | {:refused, :absent | :not_regular | :replaced} | {:error, term()}
    def read(path, limit, opener \\ &open/1)

    def read(path, limit, opener)
        when is_binary(path) and is_integer(limit) and limit >= 0 and is_function(opener, 1) do
      with {:ok, expected} <- regular_identity(path),
           {:ok, file} <- opener.(path) do
        try do
          with {:ok, ^expected} <- opened_regular_identity(file) do
            read_bounded(file, limit + 1)
          else
            {:ok, _different} -> {:refused, :replaced}
            {:refused, :not_regular} = refused -> refused
            {:error, reason} -> {:error, reason}
          end
        after
          File.close(file)
        end
      end
    end

    # Concept: reads only an opened object that still belongs to the canonical
    # workspace root the host accepted.
    #
    # Technical depth: containment used to be checked before this reader's
    # `lstat` and open. Replacing the workspace root in that gap made both of
    # those operations see the same outside inode, so their identity comparison
    # passed. This path first refuses a statically non-regular name, then opens
    # the candidate, re-resolves the root and candidate while holding that
    # descriptor, and finally binds the current contained name back to both the
    # pre-open and opened identities before reading. A replacement before open
    # changes one of those identities or the root resolution; one after open
    # changes either the name identity or the root. A replacement after
    # validation cannot change the already-open file. The already-recorded path
    # race still covers a regular file exchanged for a FIFO in the narrow gap
    # between the first identity check and open.
    @doc false
    @spec read_contained(Path.t(), Path.t(), non_neg_integer(), opener()) ::
            {:ok, binary()} | {:refused, :absent | :not_regular | :replaced} | {:error, term()}
    def read_contained(path, root, limit, opener \\ &open/1)

    def read_contained(path, root, limit, opener)
        when is_binary(path) and is_binary(root) and is_integer(limit) and limit >= 0 and
               is_function(opener, 1) do
      with {:ok, root_identity} <- LoopexCli.ProjectResources.directory_identity(root) do
        read_contained(path, root, root_identity, limit, opener)
      else
        _changed -> {:refused, :replaced}
      end
    end

    @doc false
    @spec read_contained(Path.t(), Path.t(), {integer(), integer()}, non_neg_integer(), opener()) ::
            {:ok, binary()} | {:refused, :absent | :not_regular | :replaced} | {:error, term()}
    def read_contained(path, root, root_identity, limit)
        when is_binary(path) and is_binary(root) and is_tuple(root_identity) and
               is_integer(limit) and limit >= 0 do
      read_contained(path, root, root_identity, limit, &open/1)
    end

    def read_contained(path, root, root_identity, limit, opener)
        when is_binary(path) and is_binary(root) and is_tuple(root_identity) and
               is_integer(limit) and limit >= 0 and is_function(opener, 1) do
      with {:ok, expected_identity} <- regular_identity(path) do
        case opener.(path) do
          {:ok, file} ->
            try do
              with {:ok, ^expected_identity} <- opened_regular_identity(file),
                   :ok <-
                     validate_contained_open(path, root, root_identity, expected_identity) do
                read_bounded(file, limit + 1)
              else
                {:ok, _different} -> {:refused, :replaced}
                {:refused, _reason} = refused -> refused
                {:error, reason} -> {:error, reason}
              end
            after
              File.close(file)
            end

          {:error, :enoent} ->
            {:refused, :absent}

          {:error, reason} ->
            {:error, reason}
        end
      end
    end

    defp open(path), do: File.open(path, [:read, :binary, :raw])

    defp regular_identity(path) do
      case File.lstat(path) do
        {:ok, %File.Stat{type: :regular} = stat} -> {:ok, identity(stat)}
        {:ok, %File.Stat{}} -> {:refused, :not_regular}
        {:error, :enoent} -> {:refused, :absent}
        {:error, reason} -> {:error, reason}
      end
    end

    defp opened_regular_identity(file) do
      case :file.read_file_info(file) do
        {:ok, record} ->
          case File.Stat.from_record(record) do
            %File.Stat{type: :regular} = stat -> {:ok, identity(stat)}
            %File.Stat{} -> {:refused, :not_regular}
          end

        {:error, reason} ->
          {:error, reason}
      end
    end

    defp validate_contained_open(path, root, root_identity, opened_identity) do
      with {:ok, ^root} <- LoopexCli.ProjectResources.resolve_path(root),
           {:ok, ^root_identity} <- LoopexCli.ProjectResources.directory_identity(root),
           {:ok, current} <- LoopexCli.ProjectResources.resolve_path(path),
           true <- contained?(current, root),
           {:ok, ^opened_identity} <- regular_identity(current) do
        :ok
      else
        {:refused, :not_regular} = refused -> refused
        _changed -> {:refused, :replaced}
      end
    end

    defp contained?(path, "/"), do: String.starts_with?(path, "/")
    defp contained?(path, root), do: path == root or String.starts_with?(path, root <> "/")

    defp identity(stat), do: {stat.major_device, stat.inode}

    defp read_bounded(file, remaining, chunks \\ [])

    defp read_bounded(_file, 0, chunks),
      do: {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()}

    defp read_bounded(file, remaining, chunks) do
      case :file.read(file, remaining) do
        {:ok, bytes} when is_binary(bytes) and byte_size(bytes) > 0 ->
          read_bounded(file, remaining - byte_size(bytes), [bytes | chunks])

        {:ok, ""} ->
          {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()}

        :eof ->
          {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end
end
