# Concept: a rollback source extraction is the exact released or candidate
# commit supplied by the outer release runner, even though the isolated driver
# has no Git repository.
# Technical depth: the outer runner retains Git's complete NUL-delimited tree
# projection and source identity independently of the archive. This checker
# independently enumerates the extraction, compares every archive record
# (including directories, links, modes and blob contents) to that projection,
# and refuses preexisting top-level `deps` and
# `_build` roots before any dependency acquisition or build.
defmodule RollbackArchiveCheck do
  def main([manifest_path, projection_path, identity_path, commit, tree]) do
    records = parse_manifest!(File.read!(manifest_path))
    projected = parse_projection!(File.read!(projection_path))
    refuse_prebuild_outputs!(tree)
    manifested_paths = MapSet.new(records, &elem(&1, 2))

    unless MapSet.equal?(manifested_paths, tree_paths!(tree)),
      do: fail("the rollback tree has an unmanifested or missing path")

    actual = Map.new(records, fn {kind, mode, path, _value} -> {path, {kind, mode}} end)

    projected_shapes = Map.new(projected, fn {path, {kind, mode, _object}} -> {path, {kind, mode}} end)

    unless actual == projected_shapes do
      fail("archive kind, mode or path projection differs from the commit")
    end

    expected_identity = File.read!(identity_path)
    unless String.starts_with?(expected_identity, "commit #{commit}\n") and
             File.read!(Path.join(tree, "SOURCE_IDENTITY")) == expected_identity do
      fail("SOURCE_IDENTITY differs from the supplied commit identity")
    end

    Enum.each(records, fn {kind, mode, path, value} ->
      {^kind, ^mode, object} = Map.fetch!(projected, path)
      verify_content!(tree, kind, mode, path, value, object, expected_identity)
    end)

    IO.puts("rollback-archive-check: verified #{map_size(actual)} entries for #{commit}")
  end

  def main(_args), do: fail("usage: rollback-archive-check.exs MANIFEST PROJECTION IDENTITY COMMIT TREE")

  defp parse_manifest!(bytes) do
    fields = :binary.split(bytes, <<0>>, [:global])

    unless List.last(fields) == "" and rem(length(fields) - 1, 4) == 0,
      do: fail("malformed archive manifest")

    records =
      fields
      |> Enum.drop(-1)
      |> Enum.chunk_every(4)
      |> Enum.map(fn [kind, mode, path, value] ->
        case {kind, mode, value} do
          {"f", file_mode, digest} when file_mode in ["644", "755"] ->
            unless digest =~ ~r/\A[0-9a-f]{64}\z/, do: fail("invalid file digest")

          {"l", "0", target} when target != "" ->
            :ok

          {"d", "0", ""} ->
            :ok

          _ ->
            fail("malformed archive record")
        end

        if path == "" or Path.type(path) != :relative or
             Enum.any?(Path.split(path), &(&1 in [".", ".."])),
          do: fail("invalid archive path")
        {kind, mode, path, value}
      end)

    paths = Enum.map(records, &elem(&1, 2))
    unless paths == Enum.sort(Enum.uniq(paths)), do: fail("unsorted or duplicate archive path")
    records
  end

  defp parse_projection!(bytes) do
    entries = :binary.split(bytes, <<0>>, [:global])
    unless List.last(entries) == "", do: fail("unterminated Git-tree projection")

    entries
    |> Enum.drop(-1)
    |> Enum.map(fn entry ->
      case String.split(entry, "\t", parts: 2) do
        [meta, path] when path != "" ->
          [mode, type, object] = String.split(meta, " ")

          unless type in ["blob", "tree"] and object =~ ~r/\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/,
            do: fail("malformed Git-tree object")

          shape =
            case mode do
              "100644" -> {"f", "644"}
              "100755" -> {"f", "755"}
              "120000" -> {"l", "0"}
              "040000" -> {"d", "0"}
              _ -> fail("unsupported Git-tree mode")
            end

          if (elem(shape, 0) == "d") != (type == "tree"),
            do: fail("Git-tree kind differs from its mode")

          {path, {elem(shape, 0), elem(shape, 1), object}}

        _ ->
          fail("malformed Git-tree entry")
      end
    end)
    |> then(fn entries ->
      projected = Map.new(entries)
      if map_size(projected) != length(entries), do: fail("duplicate Git-tree path")
      projected
    end)
  end

  defp verify_content!(tree, kind, mode, path, value, object, expected_identity) do
    full_path = Path.join(tree, path)

    case {kind, File.lstat(full_path)} do
      {"f", {:ok, %File.Stat{type: :regular, mode: bits}}} ->
        observed_mode = if Bitwise.band(bits, 0o111) == 0, do: "644", else: "755"
        if mode != observed_mode, do: fail("archive file mode differs from its manifest")
        bytes = File.read!(full_path)
        if value != digest(bytes), do: fail("archive file digest differs from its bytes")

        if path == "SOURCE_IDENTITY" do
          if bytes != expected_identity, do: fail("SOURCE_IDENTITY differs from the supplied commit identity")
        else
          if object != git_object(bytes, object), do: fail("archive file differs from the commit blob")
        end

      {"l", {:ok, %File.Stat{type: :symlink}}} ->
        {:ok, target} = File.read_link(full_path)
        if value != target, do: fail("archive link target differs from its manifest")
        if object != git_object(target, object), do: fail("archive link differs from the commit blob")

      {"d", {:ok, %File.Stat{type: :directory}}} ->
        :ok

      _ ->
        fail("archive kind differs from its manifest")
    end
  end

  defp refuse_prebuild_outputs!(tree) do
    Enum.each(["_build", "deps"], fn name ->
      case File.lstat(Path.join(tree, name)) do
        {:error, :enoent} -> :ok
        _ -> fail("build output root exists before the rollback build")
      end
    end)
  end

  defp tree_paths!(tree) do
    case File.lstat(tree) do
      {:ok, %File.Stat{type: :directory}} -> walk_tree!(tree, "", MapSet.new())
      _ -> fail("the rollback root is not an ordinary directory")
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
              fail("the rollback tree has an unsupported or unreadable path")
          end
        end)

      _ ->
        fail("the rollback tree cannot be fully enumerated")
    end
  end

  defp git_object(bytes, expected) do
    payload = "blob #{byte_size(bytes)}\0" <> bytes
    algorithm = if byte_size(expected) == 40, do: :sha, else: :sha256
    Base.encode16(:crypto.hash(algorithm, payload), case: :lower)
  end

  defp digest(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

  defp fail(message) do
    IO.puts(:stderr, "rollback-archive-check: " <> message)
    System.halt(1)
  end
end

RollbackArchiveCheck.main(System.argv())
