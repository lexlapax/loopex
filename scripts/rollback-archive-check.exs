# Concept: a rollback source extraction is the exact released or candidate
# commit supplied by the outer release runner, even though the isolated driver
# has no Git repository.
# Technical depth: the outer runner retains Git's complete NUL-delimited tree
# projection and source identity independently of the archive. This checker
# compares every archive record (including directories, links and modes) to
# that projection before any dependency acquisition or build.
defmodule RollbackArchiveCheck do
  def main([manifest_path, projection_path, identity_path, commit, tree]) do
    records = parse_manifest!(File.read!(manifest_path))
    projected = parse_projection!(File.read!(projection_path))

    actual = Map.new(records, fn {kind, mode, path, _value} -> {path, {kind, mode}} end)

    unless actual == projected do
      fail("archive kind, mode or path projection differs from the commit")
    end

    expected_identity = File.read!(identity_path)
    unless String.starts_with?(expected_identity, "commit #{commit}\n") and
             File.read!(Path.join(tree, "SOURCE_IDENTITY")) == expected_identity do
      fail("SOURCE_IDENTITY differs from the supplied commit identity")
    end

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

        if path == "", do: fail("empty archive path")
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
          mode = meta |> String.split(" ") |> List.first()

          shape =
            case mode do
              "100644" -> {"f", "644"}
              "100755" -> {"f", "755"}
              "120000" -> {"l", "0"}
              "040000" -> {"d", "0"}
              _ -> fail("unsupported Git-tree mode")
            end

          {path, shape}

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

  defp fail(message) do
    IO.puts(:stderr, "rollback-archive-check: " <> message)
    System.halt(1)
  end
end

RollbackArchiveCheck.main(System.argv())
