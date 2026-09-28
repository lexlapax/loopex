# Concept: the release check's independent reading of a source extraction: it
# proves the archive is exactly the commit it claims, and that building it
# changed nothing but the build's declared outputs.
#
# Technical depth: two modes.
#
#   elixir scripts/source-archive-check.exs verify MANIFEST INVENTORY COMMIT TREE
#
# parses the producer's NUL records, refusing a malformed or duplicate record;
# independently enumerates the extracted tree and requires the same full path
# set, including empty directories;
# requires the regular-file and link path set to equal the `git ls-files -z`
# INVENTORY exactly (which must not be empty); requires every manifest path's
# kind, canonical mode and content to match the commit's own Git tree
# (`100644` f/644, `100755` f/755, `120000` l/0, `040000` d/755 mapped to the
# producer's d/0); each value must also match the extracted file or link;
# Git blob bytes are read independently of the manifest and extraction,
# except SOURCE_IDENTITY, whose archive export substitution is checked against
# the commit identity. Pre-build `deps` and `_build` roots are refused. The
# check requires TREE/SOURCE_IDENTITY to equal the
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
    refuse_prebuild_outputs!(tree)
    manifested_paths = MapSet.new(records, &elem(&1, 2))

    unless MapSet.equal?(manifested_paths, tree_paths!(tree)),
      do: fail("the extracted tree has an unmanifested or missing path")

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

    unless MapSet.equal?(manifested_paths, MapSet.new(Map.keys(git_tree))),
      do: fail("the manifest omits or adds a Git-tree path")

    Enum.each(records, fn {kind, mode, path, value} ->
      case Map.fetch(git_tree, path) do
        {:ok, {^kind, ^mode, object}} ->
          verify_tree!(tree, kind, mode, path, value)

          if path != "SOURCE_IDENTITY" do
            case kind do
              "f" ->
                unless value == digest(git_blob!(object)),
                  do: fail("file content differs from the commit's blob")

              "l" ->
                unless value == git_blob!(object),
                  do: fail("link target differs from the commit's blob")

              "d" ->
                :ok
            end
          end

        _mismatch -> fail("kind or mode of one path differs from the commit's tree")
      end
    end)

    {expected, 0} =
      System.cmd("git", ["show", "-s", "--format=commit %H%ncommitter-date %cI", commit])

    identity = File.read!(Path.join(tree, "SOURCE_IDENTITY"))

    unless identity == String.trim_trailing(expected) <> "\n",
      do: fail("SOURCE_IDENTITY does not name the staged commit")

    unless Enum.any?(records, fn
             {"f", "644", "SOURCE_IDENTITY", value} -> value == digest(identity)
             _ -> false
           end),
      do: fail("SOURCE_IDENTITY manifest digest differs from the staged commit")

    IO.puts("source-archive-check: verified #{length(records)} records for #{commit}")
  end

  def main(["unchanged", before, after_build]) do
    before = parse!(File.read!(before))
    after_build = parse!(File.read!(after_build))

    {excluded, kept} =
      Enum.split_with(after_build, fn {kind, mode, path, _value} ->
        if path in @declared_outputs and {kind, mode} != {"f", "755"},
          do: fail("the declared escript output is not an executable ordinary file")

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
      [mode, _type, object] = String.split(meta, " ")

      projected =
        case mode do
          "100644" -> {"f", "644"}
          "100755" -> {"f", "755"}
          "120000" -> {"l", "0"}
          "040000" -> {"d", "0"}
          _unsupported -> fail("the commit's tree has an unsupported mode")
        end

      {kind, canonical_mode} = projected
      {path, {kind, canonical_mode, object}}
    end)
  end

  defp git_blob!(object) do
    case System.cmd("git", ["cat-file", "blob", object]) do
      {bytes, 0} -> bytes
      _ -> fail("the commit's blob could not be read")
    end
  end

  defp refuse_prebuild_outputs!(tree) do
    Enum.each(["_build", "deps"], fn name ->
      case File.lstat(Path.join(tree, name)) do
        {:error, :enoent} -> :ok
        _ -> fail("build output root exists before the source build")
      end
    end)
  end

  defp tree_paths!(tree) do
    case File.lstat(tree) do
      {:ok, %File.Stat{type: :directory}} -> walk_tree!(tree, "", MapSet.new())
      _ -> fail("the extraction root is not an ordinary directory")
    end
  end

  defp walk_tree!(tree, relative, paths) do
    directory = if relative == "", do: tree, else: Path.join(tree, relative)

    case File.ls(directory) do
      {:ok, names} ->
        Enum.reduce(names, paths, fn name, found ->
          path = if relative == "", do: name, else: Path.join(relative, name)

          case File.lstat(Path.join(tree, path)) do
            {:ok, %File.Stat{type: type}} when type in [:directory, :regular, :symlink] ->
              found = MapSet.put(found, path)
              if type == :directory, do: walk_tree!(tree, path, found), else: found

            _ ->
              fail("the extracted tree has an unsupported or unreadable path")
          end
        end)

      _ ->
        fail("the extracted tree cannot be fully enumerated")
    end
  end

  defp verify_tree!(tree, kind, mode, path, value) do
    full_path = Path.join(tree, path)

    case {kind, File.lstat(full_path)} do
      {"f", {:ok, %File.Stat{type: :regular, mode: bits}}} ->
        observed_mode = if Bitwise.band(bits, 0o111) == 0, do: "644", else: "755"
        if mode != observed_mode, do: fail("file mode differs from the extracted tree")
        unless value == digest(File.read!(full_path)),
          do: fail("file content differs from the extracted tree")

      {"l", {:ok, %File.Stat{type: :symlink}}} ->
        {:ok, target} = File.read_link(full_path)
        unless value == target, do: fail("link target differs from the extracted tree")

      {"d", {:ok, %File.Stat{type: :directory}}} ->
        :ok

      _ ->
        fail("kind differs from the extracted tree")
    end
  end

  defp digest(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

  defp fail(message) do
    IO.puts(:stderr, "source-archive-check: " <> message)
    System.halt(1)
  end
end

SourceArchiveCheck.main(System.argv())
