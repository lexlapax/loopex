# Concept: the release check's independent reading of a source extraction: it
# proves the archive is exactly the commit it claims, and that building it
# changed nothing but the build's declared outputs.
#
# Technical depth: two modes.
#
#   elixir scripts/source-archive-check.exs verify MANIFEST INVENTORY COMMIT TREE
#
# parses the producer's NUL records, refusing a malformed or duplicate record;
# requires the regular-file and link path set to equal the `git ls-files -z`
# INVENTORY exactly (which must not be empty); requires every manifest path's
# kind and canonical mode to match the commit's own Git tree
# (`100644` f/644, `100755` f/755, `120000` l/0, `040000` d/755 mapped to the
# producer's d/0); and requires TREE/SOURCE_IDENTITY to equal the
# final-LF-terminated `git show -s --format='commit %H%ncommitter-date %cI'`.
#
#   elixir scripts/source-archive-check.exs unchanged BEFORE AFTER
#
# requires the after-build manifest to equal the pre-build one once the
# declared build outputs are removed. The exclusions are the producer's
# top-level `_build` and `deps` and exactly `apps/loopex_cli/loopex`, the
# command escript the documented build writes beside its application (the
# maintainer's 2026-09-22 disposition). It prints each exclusion it applied.

defmodule SourceArchiveCheck do
  @declared_outputs ["apps/loopex_cli/loopex"]

  def main(["verify", manifest, inventory, commit, tree]) do
    records = parse!(File.read!(manifest))
    listed = inventory |> File.read!() |> String.split(<<0>>, trim: true) |> MapSet.new()
    if MapSet.size(listed) == 0, do: fail("the recorded source inventory is empty")

    tracked =
      for {kind, _mode, path, _value} <- records, kind in ["f", "l"], into: MapSet.new(), do: path

    unless MapSet.equal?(tracked, listed) do
      fail(
        "the extraction's path set differs from the inventory: " <>
          "#{MapSet.size(MapSet.difference(tracked, listed))} extra, " <>
          "#{MapSet.size(MapSet.difference(listed, tracked))} missing"
      )
    end

    git_tree = git_projection(commit)

    Enum.each(records, fn {kind, mode, path, _value} ->
      case Map.fetch(git_tree, path) do
        {:ok, {^kind, ^mode}} -> :ok
        _mismatch -> fail("kind or mode of one path differs from the commit's tree")
      end
    end)

    {expected, 0} =
      System.cmd("git", ["show", "-s", "--format=commit %H%ncommitter-date %cI", commit])

    identity = File.read!(Path.join(tree, "SOURCE_IDENTITY"))

    unless identity == String.trim_trailing(expected) <> "\n",
      do: fail("SOURCE_IDENTITY does not name the staged commit")

    IO.puts("source-archive-check: verified #{length(records)} records for #{commit}")
  end

  def main(["unchanged", before, after_build]) do
    before = parse!(File.read!(before))
    after_build = parse!(File.read!(after_build))

    {excluded, kept} =
      Enum.split_with(after_build, fn {_kind, _mode, path, _value} ->
        path in @declared_outputs
      end)

    Enum.each(excluded, fn {_kind, _mode, path, _value} ->
      IO.puts("source-archive-check: excluded declared output #{path}")
    end)

    unless kept == before,
      do: fail("the build changed the extraction outside its declared outputs")

    IO.puts("source-archive-check: the build left the extraction unchanged")
  end

  def main(_arguments) do
    fail(
      "usage: source-archive-check.exs verify MANIFEST INVENTORY COMMIT TREE | unchanged BEFORE AFTER"
    )
  end

  defp parse!(bytes) do
    fields = :binary.split(bytes, <<0>>, [:global])

    unless List.last(fields) == "" and rem(length(fields) - 1, 4) == 0,
      do: fail("the manifest is not a whole number of records")

    records =
      fields
      |> Enum.drop(-1)
      |> Enum.chunk_every(4)
      |> Enum.map(fn [kind, mode, path, value] -> {kind, mode, path, value} end)

    Enum.each(records, fn
      {"f", mode, path, value} when mode in ["644", "755"] and path != "" ->
        unless value =~ ~r/\A[0-9a-f]{64}\z/, do: fail("a file record has no digest")

      {"l", "0", path, value} when path != "" and value != "" ->
        :ok

      {"d", "0", path, ""} when path != "" ->
        :ok

      _malformed ->
        fail("the manifest has a malformed record")
    end)

    paths = Enum.map(records, &elem(&1, 2))
    if paths != Enum.uniq(paths), do: fail("the manifest has a duplicate record")
    if paths != Enum.sort(paths), do: fail("the manifest is not sorted by path bytes")
    records
  end

  defp git_projection(commit) do
    {listing, 0} = System.cmd("git", ["ls-tree", "-rz", "-r", "-t", "--full-tree", commit])

    listing
    |> String.split(<<0>>, trim: true)
    |> Map.new(fn entry ->
      [meta, path] = String.split(entry, "\t", parts: 2)
      [mode, _type, _object] = String.split(meta, " ")

      projected =
        case mode do
          "100644" -> {"f", "644"}
          "100755" -> {"f", "755"}
          "120000" -> {"l", "0"}
          "040000" -> {"d", "0"}
          _unsupported -> fail("the commit's tree has an unsupported mode")
        end

      {path, projected}
    end)
  end

  defp fail(message) do
    IO.puts(:stderr, "source-archive-check: " <> message)
    System.halt(1)
  end
end

SourceArchiveCheck.main(System.argv())
