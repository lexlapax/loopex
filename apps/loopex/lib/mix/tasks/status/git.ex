defmodule Loopex.Checks.Git do
  @moduledoc """
  ## Concept

  Reads the repository's current documents without modifying it. The status check
  needs to know which Markdown files the repository actually carries, and a
  read-only reviewer must be able to run the same check, so nothing here writes to
  the checkout, creates a temporary file, or fetches.

  ## Technical depth

  Every invocation goes through one helper that pins the environment: lazy
  fetching and object replacement are disabled so nothing reaches the network,
  optional locks are disabled so a concurrent Git process cannot make a read fail,
  and the locale is fixed so parsing does not depend on the operator's settings.

  Only the working tree is read. Reachable history is not walked: the checks this
  module serves validate the tree in front of them, which is what keeps the status
  check a seconds-long command rather than a per-revision walk.
  """

  alias Loopex.Checks.Invalid

  @environment [
    {"GIT_NO_LAZY_FETCH", "1"},
    {"GIT_NO_REPLACE_OBJECTS", "1"},
    {"GIT_OPTIONAL_LOCKS", "0"},
    {"LC_ALL", "C"}
  ]

  @doc """
  ## Concept

  Runs one Git command in the repository and returns its output and exit status.

  ## Technical depth

  Returns `{output, status}` rather than raising, because a non-zero status is
  ordinary information here — a directory that is not a repository, for instance —
  and the caller decides whether that means "not found" or "evidence
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
end
