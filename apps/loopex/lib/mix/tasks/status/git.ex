defmodule Loopex.Checks.Git do
  @moduledoc """
  ## Concept

  Reads the repository and its reachable history without modifying either. Every
  check that anchors a record to history needs Git, and a read-only reviewer must
  be able to run the same check, so nothing here writes to the checkout, creates
  a temporary file, or fetches.

  Unavailable evidence is reported as unavailable. A shallow clone, a grafted
  history, or a rewritten object store cannot support a reachability claim, so the
  history reader returns nothing rather than a partial walk that would silently
  pass.

  ## Technical depth

  Every invocation goes through one helper that pins the environment: lazy
  fetching and object replacement are disabled so a resolved revision is a real
  object in this repository, optional locks are disabled so a concurrent Git
  process cannot make a read fail, and the locale is fixed so parsing does not
  depend on the operator's settings.

  Blob contents are cached by object id across the whole walk. A hundred revisions
  of the same document share one object, so the cache turns a per-revision read
  into a per-version read.
  """

  alias Loopex.Checks.Invalid

  @environment [
    {"GIT_NO_LAZY_FETCH", "1"},
    {"GIT_NO_REPLACE_OBJECTS", "1"},
    {"GIT_OPTIONAL_LOCKS", "0"},
    {"LC_ALL", "C"}
  ]

  @sha ~r/\A[0-9a-f]{40}\z/u

  @doc """
  ## Concept

  Runs one Git command in the repository and returns its output and exit status.

  ## Technical depth

  Returns `{output, status}` rather than raising, because a non-zero status is
  ordinary information here — a revision that does not exist, a path absent from a
  tree — and the caller decides whether that means "not found" or "evidence
  unavailable".
  """
  @spec run(Path.t(), [String.t()]) :: {binary(), non_neg_integer()}
  def run(root, args) do
    System.cmd("git", ["--no-replace-objects" | args],
      cd: root,
      env: @environment,
      stderr_to_stdout: false
    )
  end

  @doc """
  ## Concept

  Every Markdown document the repository currently carries, keyed by
  repository-relative path.

  ## Technical depth

  Reads tracked files plus untracked files Git does not ignore, so a document
  added but not yet committed is validated in the change that adds it rather than
  after it lands. Ignored paths are excluded, which is what keeps a nested
  worktree or a build directory from being read as project documentation.

  A `NUL`-delimited listing is required to terminate correctly; a truncated one
  means the inventory is unavailable and fails rather than validating a subset.
  """
  @spec documents(Path.t()) :: %{String.t() => String.t()}
  def documents(root) do
    {output, status} =
      run(root, ["ls-files", "-z", "--cached", "--others", "--exclude-standard", "--", "*.md"])

    if status != 0 or not String.ends_with?(output, <<0>>) do
      raise Invalid, "repository Markdown inventory is unavailable"
    end

    output
    |> String.trim_trailing(<<0>>)
    |> String.split(<<0>>, trim: true)
    |> Enum.reduce(%{}, fn relative, acc ->
      unless String.valid?(relative) do
        raise Invalid, "repository Markdown paths must be UTF-8"
      end

      case File.read(Path.join(root, relative)) do
        {:ok, text} ->
          unless String.valid?(text) do
            raise Invalid, "#{relative}: governed Markdown must be UTF-8"
          end

          Map.put(acc, relative, text)

        {:error, _posix} ->
          acc
      end
    end)
  end

  @doc """
  ## Concept

  Whether one commit is an ancestor of another.

  ## Technical depth

  The acceptance chain needs this and reachability from `HEAD` is not enough. Two
  unrelated branches both become reachable once anything merges them, so a
  candidate could name a prior candidate it does not descend from and the edge
  would still resolve. A chain is only a lineage if every edge runs backwards along
  actual history.
  """
  @spec ancestor?(Path.t(), String.t(), String.t(), (Path.t(), [String.t()] ->
                                                       {binary(), non_neg_integer()})) ::
          boolean()
  def ancestor?(root, ancestor, descendant, runner \\ &__MODULE__.run/2) do
    match?({_output, 0}, runner.(root, ["merge-base", "--is-ancestor", ancestor, descendant]))
  end

  @doc """
  ## Concept

  A resolver that returns one file's text at one revision, or `nil` when the
  revision is not a reachable commit or the path is absent from it.

  ## Technical depth

  Three conditions must hold before the content is read: the object is a commit,
  it is an ancestor of `HEAD`, and the path exists in its tree. Reachability is
  the one that matters most — a bound candidate that is not an ancestor of the
  integrated history is not part of the project's record, however valid its bytes
  are, and admitting it would let a governance row bind a revision nobody can
  reach.

  The command runner is injectable so a test can prove the reachability rejection
  happens, and that it happens without any command that writes: an unreachable
  candidate must stop after the type and ancestry queries.
  """
  @spec resolver(Path.t(), (Path.t(), [String.t()] -> {binary(), non_neg_integer()})) ::
          (String.t(), String.t() -> String.t() | nil)
  def resolver(root, runner \\ &__MODULE__.run/2) do
    fn sha, path ->
      with {"commit\n", 0} <- runner.(root, ["cat-file", "-t", sha]),
           {_output, 0} <- runner.(root, ["merge-base", "--is-ancestor", sha, "HEAD"]),
           {content, 0} <- runner.(root, ["show", "#{sha}:#{path}"]),
           true <- String.valid?(content) do
        content
      else
        _other -> nil
      end
    end
  end

  @doc """
  ## Concept

  A reader for the complete reachable history of governed documents and bound
  artifacts: one snapshot per commit, with its parents and the file contents that
  commit carried.

  ## Technical depth

  Returns `nil` — meaning evidence unavailable — for a shallow repository, a
  non-empty graft file, an unparsable revision list, an unexpected tree entry
  mode, or any Git failure. Each of those breaks the reachability the walk depends
  on, and a partial walk would pass while leaving exactly the gap the walk exists
  to close.

  Snapshots are emitted in reverse topological order so every parent precedes its
  children, which is what lets the walks propagate state in one pass. Bound
  artifacts may be mode 100755, since a bound runner is executable; governed
  documents must be regular non-executable blobs.
  """
  @spec history_reader(Path.t(), [String.t()]) ::
          (-> {String.t(), [{String.t(), [String.t()], map()}]} | nil)
  def history_reader(root, artifact_paths \\ []) do
    fn ->
      with :ok <- require_complete_history(root),
           {:ok, records} <- revision_records(root) do
        read_snapshots(root, records, artifact_paths)
      else
        _other -> nil
      end
    end
  end

  defp require_complete_history(root) do
    with {"false\n", 0} <- run(root, ["rev-parse", "--is-shallow-repository"]),
         {graft, 0} <- run(root, ["rev-parse", "--git-path", "info/grafts"]),
         :ok <- require_empty_graft(root, String.trim(graft)) do
      :ok
    else
      _other -> :error
    end
  end

  defp require_empty_graft(root, relative) do
    path =
      case Path.type(relative) do
        :absolute -> relative
        _other -> Path.join(root, relative)
      end

    case File.stat(path) do
      {:error, _posix} -> :ok
      {:ok, %File.Stat{type: :regular, size: 0}} -> :ok
      {:ok, _stat} -> :error
    end
  end

  defp revision_records(root) do
    case run(root, ["rev-list", "--parents", "--topo-order", "--reverse", "HEAD"]) do
      {output, 0} ->
        records =
          output |> String.split("\n", trim: true) |> Enum.map(&String.split(&1, " ", trim: true))

        valid =
          records != [] and
            Enum.all?(records, fn record ->
              record != [] and Enum.all?(record, &Regex.match?(@sha, &1))
            end)

        if valid, do: {:ok, records}, else: :error

      _other ->
        :error
    end
  end

  defp read_snapshots(root, records, artifact_paths) do
    result =
      Enum.reduce_while(records, {[], %{}}, fn [sha | parents], {snapshots, cache} ->
        case read_tree(root, sha, artifact_paths, cache) do
          {:ok, files, cache} -> {:cont, {[{sha, parents, files} | snapshots], cache}}
          :error -> {:halt, :error}
        end
      end)

    case result do
      :error ->
        nil

      {snapshots, _cache} ->
        ordered = Enum.reverse(snapshots)
        {head, _parents, _files} = List.last(ordered)
        {head, ordered}
    end
  end

  defp read_tree(root, sha, artifact_paths, cache) do
    case run(
           root,
           ["ls-tree", "-rz", "-r", "--full-tree", sha, "--", "docs/plans", "docs/adr"] ++
             artifact_paths
         ) do
      {output, 0} -> collect_entries(root, output, artifact_paths, cache)
      _other -> :error
    end
  end

  defp collect_entries(root, output, artifact_paths, cache) do
    entries = String.split(output, <<0>>)

    case List.last(entries) do
      "" ->
        entries
        |> Enum.drop(-1)
        |> Enum.reduce_while({:ok, %{}, cache}, fn entry, {:ok, files, cache} ->
          case entry_content(root, entry, artifact_paths, cache) do
            :skip -> {:cont, {:ok, files, cache}}
            :error -> {:halt, :error}
            {:ok, path, content, cache} -> {:cont, {:ok, Map.put(files, path, content), cache}}
          end
        end)

      _other ->
        :error
    end
  end

  defp entry_content(root, entry, artifact_paths, cache) do
    with [metadata, path] <- String.split(entry, "\t", parts: 2),
         [mode, type, object_id] <- String.split(metadata, " ", trim: true),
         true <- String.valid?(path) do
      cond do
        not governed?(path, artifact_paths) ->
          :skip

        type != "blob" or mode not in allowed_modes(path, artifact_paths) ->
          :error

        true ->
          blob(root, object_id, path, cache)
      end
    else
      _other -> :error
    end
  end

  defp allowed_modes(path, artifact_paths) do
    case path in artifact_paths do
      true -> ["100644", "100755"]
      false -> ["100644"]
    end
  end

  defp blob(root, object_id, path, cache) do
    case Map.fetch(cache, object_id) do
      {:ok, content} ->
        {:ok, path, content, cache}

      :error ->
        case run(root, ["cat-file", "blob", object_id]) do
          {content, 0} ->
            case String.valid?(content) do
              true -> {:ok, path, content, Map.put(cache, object_id, content)}
              false -> :error
            end

          _other ->
            :error
        end
    end
  end

  # Concept: only governed documents and declared artifacts are read.
  # Technical depth: plan and ADR Markdown is governed by path shape; an artifact
  # is governed because a gate names it, which is why the caller passes the list.
  # The plans index is read too. It is not a plan pair, but it is the canonical
  # register, and the history walk needs the lifecycle state and the milestone
  # rows as they stood at each revision; excluding it made every historical
  # snapshot indexless, so a check written against the register silently passed
  # over the whole of real history.
  defp governed?(path, artifact_paths) do
    relative = Loopex.Checks.Paths.strip_prefix(path, "docs/plans/")

    plan? =
      String.starts_with?(path, "docs/plans/") and String.ends_with?(relative, ".md")

    adr? =
      Loopex.Checks.Documents.adr_concept?(path) or
        (String.ends_with?(path, "-technical.md") and
           Loopex.Checks.Documents.adr_concept?(Loopex.Checks.Paths.concept(path)))

    plan? or adr? or path in artifact_paths
  end
end
