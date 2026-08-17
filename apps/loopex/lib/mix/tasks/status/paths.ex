defmodule Loopex.Checks.Paths do
  @moduledoc """
  ## Concept

  Repository-relative path arithmetic for paired documents and their links. Every
  document path in the checks is a POSIX repository-relative string, never a
  host path, so the same bytes mean the same document on any platform and inside
  a historical Git tree that has no working directory at all.

  ## Technical depth

  Implements the small subset of POSIX path semantics the checks need — join,
  dirname, basename, normalisation, and relative targets — directly rather than
  through `Path`, whose functions resolve against the host filesystem and its
  separator. A historical tree is not on disk, so anything that touches the
  filesystem would answer the wrong question.
  """

  @doc """
  ## Concept

  The technical companion path for a concept document path.

  ## Technical depth

  Suffix arithmetic only. The pair convention is `<name>.md` with
  `<name>-technical.md`, and the topology check rejects a doubled suffix
  separately, so this function does not need to defend against one.
  """
  @spec technical(String.t()) :: String.t()
  def technical(concept_path), do: strip_suffix(concept_path, ".md") <> "-technical.md"

  @doc """
  ## Concept

  The concept document path for a technical companion path.

  ## Technical depth

  The inverse of `technical/1`, used when a discovered `-technical.md` file must
  be classified by the pair it belongs to.
  """
  @spec concept(String.t()) :: String.t()
  def concept(technical_path), do: strip_suffix(technical_path, "-technical.md") <> ".md"

  @doc """
  ## Concept

  Removes `suffix` from the end of `value` when it is present.

  ## Technical depth

  Mirrors Python's `str.removesuffix`, which the retired checker relied on for
  every document-class decision. A value without the suffix is returned
  unchanged rather than raising, because callers use it to normalise a set of
  paths whose membership they have already decided.
  """
  @spec strip_suffix(String.t(), String.t()) :: String.t()
  def strip_suffix(value, suffix) do
    case String.ends_with?(value, suffix) do
      true -> binary_part(value, 0, byte_size(value) - byte_size(suffix))
      false -> value
    end
  end

  @doc """
  ## Concept

  Removes `prefix` from the start of `value` when it is present.

  ## Technical depth

  Mirrors Python's `str.removeprefix`. Used to turn a repository-relative plan
  path into the milestone-local name the register and gate share.
  """
  @spec strip_prefix(String.t(), String.t()) :: String.t()
  def strip_prefix(value, prefix) do
    case String.starts_with?(value, prefix) do
      true -> binary_part(value, byte_size(prefix), byte_size(value) - byte_size(prefix))
      false -> value
    end
  end

  @doc """
  ## Concept

  The directory part of a repository-relative path, or `""` at the top level.

  ## Technical depth

  Returns `""` rather than `"."` for a top-level path, matching
  `posixpath.dirname`, because the topology check uses the result as a directory
  key and `"."` would create a directory that does not exist in the tree.
  """
  @spec dirname(String.t()) :: String.t()
  def dirname(path) do
    case String.split(path, "/") do
      [_single] -> ""
      parts -> parts |> Enum.drop(-1) |> Enum.join("/")
    end
  end

  @doc """
  ## Concept

  The final component of a repository-relative path.

  ## Technical depth

  Plain string arithmetic so a trailing component is returned verbatim,
  including one that is empty because the path names a directory.
  """
  @spec basename(String.t()) :: String.t()
  def basename(path), do: path |> String.split("/") |> List.last()

  @doc """
  ## Concept

  Joins a directory and a relative path into one repository-relative path.

  ## Technical depth

  An empty directory yields the relative path unchanged, which is what a
  top-level source document needs. No normalisation happens here; callers pass
  the result through `normalise/1` when the relative part may contain `.` or
  `..`.
  """
  @spec join(String.t(), String.t()) :: String.t()
  def join("", path), do: path
  def join(directory, path), do: strip_suffix(directory, "/") <> "/" <> path

  @doc """
  ## Concept

  Collapses `.` and `..` components in a repository-relative path.

  ## Technical depth

  Mirrors `posixpath.normpath` for the relative inputs the checks produce: an
  empty result becomes `"."`, and a leading `..` is preserved so the caller can
  reject a link that escapes the repository instead of silently clamping it at
  the root.
  """
  @spec normalise(String.t()) :: String.t()
  def normalise(path) do
    {leading, components} =
      path
      |> String.split("/")
      |> Enum.reduce({[], []}, fn
        "", acc -> acc
        ".", acc -> acc
        "..", {leading, []} -> {[".." | leading], []}
        "..", {leading, [_last | rest]} -> {leading, rest}
        component, {leading, kept} -> {leading, [component | kept]}
      end)

    case Enum.reverse(leading) ++ Enum.reverse(components) do
      [] -> "."
      parts -> Enum.join(parts, "/")
    end
  end

  @doc """
  ## Concept

  The link text one document must use to name another: `target` expressed
  relative to the directory holding `source`.

  ## Technical depth

  Mirrors `posixpath.relpath` against the source's directory, so a companion in
  the same directory resolves to a bare filename and a companion elsewhere
  resolves through `..`. Paired documents always share a directory today, but
  computing the general answer means the reciprocal-link comparison stays exact
  if a pair ever moves.
  """
  @spec relative_target(String.t(), String.t()) :: String.t()
  def relative_target(source, target) do
    from = source |> dirname() |> normalise() |> split_normalised()
    to = target |> normalise() |> split_normalised()
    common = common_length(from, to, 0)

    ups = List.duplicate("..", length(from) - common)
    downs = Enum.drop(to, common)

    case ups ++ downs do
      [] -> "."
      parts -> Enum.join(parts, "/")
    end
  end

  defp split_normalised("."), do: []
  defp split_normalised(""), do: []
  defp split_normalised(path), do: String.split(path, "/")

  defp common_length([head | from], [head | to], count), do: common_length(from, to, count + 1)
  defp common_length(_from, _to, count), do: count
end
