defmodule Mix.Tasks.Loopex.Closure.ArchiveCompare do
  @shortdoc "Compares tested and administrative source-archive manifests"

  @moduledoc """
  ## Concept

  A release may reuse a tested source build only when the administrative
  closure commit changes no shipped source. This task compares the complete
  source archives against their own commits before excluding the governed
  documentation and source-identity differences.

  ## Technical depth

  Both inputs are the exact NUL-delimited output of the archive's manifest
  producer. Their adjacent `.source-identity` files are ordinary files whose
  bytes must match the corresponding Git commit and manifest entry. Complete
  kind/mode/path projections must cover every independently enumerated Git
  archive member and match Git-tree modes, then match each other. Shipped
  tuples are compared after the documented exclusions, and each manifest's
  file digests and link targets are independently bound to its Git blobs. No
  archive or evidence file is written by this task.
  """

  use Mix.Task

  @sha ~r/\A[0-9a-f]{40}\z/
  @digest ~r/\A[0-9a-f]{64}\z/

  @impl Mix.Task
  def run([tested_path, admin_path, tested_sha, admin_sha]) do
    case compare(tested_path, admin_path, tested_sha, admin_sha) do
      :ok -> :ok
      {:error, reason} -> Mix.raise("archive comparison failed: #{reason}")
    end
  end

  def run(_args) do
    Mix.shell().error("FAIL archive-compare arguments: invalid command grammar")

    Mix.raise(
      "usage: mix loopex.closure.archive_compare TESTED_MANIFEST ADMIN_MANIFEST TESTED ADMIN"
    )
  end

  @doc """
  ## Concept

  Checks that two retained archive manifests describe the same shipped source.

  ## Technical depth

  Returns `:ok` or the first failed check. Every attempted check emits one
  `PASS` or `FAIL` line; a failed prerequisite prevents dependent checks from
  pretending they ran. Git is read only and no input is modified.
  """
  @spec compare(Path.t(), Path.t(), String.t(), String.t()) :: :ok | {:error, String.t()}
  def compare(tested_path, admin_path, tested_sha, admin_sha) do
    with {:ok, {tested, admin}} <-
           step("arguments and manifests", fn ->
             with :ok <- valid_sha(tested_sha),
                  :ok <- valid_sha(admin_sha),
                  {:ok, tested} <- read_manifest(tested_path),
                  {:ok, admin} <- read_manifest(admin_path) do
               {:ok, {tested, admin}}
             end
           end),
         {:ok, {tested_identity, admin_identity}} <-
           step("ordinary source-identity sidecars", fn ->
             with {:ok, first} <- read_sidecar(tested_path),
                  {:ok, second} <- read_sidecar(admin_path) do
               {:ok, {first, second}}
             end
           end),
         {:ok, {tested_tree, admin_tree}} <-
           step("independent Git trees", fn ->
             with {:ok, first} <- git_tree(tested_sha),
                  {:ok, second} <- git_tree(admin_sha) do
               {:ok, {first, second}}
             end
           end),
         {:ok, {tested_members, admin_members}} <-
           step("independent archive members", fn ->
             with {:ok, first} <- archive_members(tested_sha),
                  {:ok, second} <- archive_members(admin_sha) do
               {:ok, {first, second}}
             end
           end),
         {:ok, _} <-
           step("complete archive projections", fn ->
             if projection_matches_tree?(tested, tested_tree, tested_members) and
                  projection_matches_tree?(admin, admin_tree, admin_members),
                do: {:ok, :matched},
                else: {:error, "an archive kind/mode/path projection differs from its commit"}
           end),
         {:ok, _} <-
           step("source identities", fn ->
             with :ok <- identity_matches(tested, tested_identity, tested_sha),
                  :ok <- identity_matches(admin, admin_identity, admin_sha) do
               {:ok, :matched}
             end
           end),
         {:ok, _} <-
           step("identical unexcluded projections", fn ->
             if projection(tested) == projection(admin),
               do: {:ok, :matched},
               else: {:error, "the complete archive projections differ"}
           end),
         {:ok, _} <-
           step("identical shipped tuples", fn ->
             if shipped(tested) == shipped(admin),
               do: {:ok, :matched},
               else: {:error, "archive tuples outside the exclusions differ"}
           end),
         {:ok, _} <-
           step("commit-bound archive contents", fn ->
             with :ok <- contents_match_tree(tested, tested_tree),
                  :ok <- contents_match_tree(admin, admin_tree) do
               {:ok, :matched}
             end
           end) do
      :ok
    end
  end

  defp step(label, operation) do
    case operation.() do
      {:ok, value} ->
        Mix.shell().info("PASS archive-compare #{label}")
        {:ok, value}

      {:error, reason} ->
        Mix.shell().error("FAIL archive-compare #{label}: #{reason}")
        {:error, reason}
    end
  end

  defp valid_sha(sha) when is_binary(sha) do
    if Regex.match?(@sha, sha), do: :ok, else: {:error, "commit ID is not a full SHA"}
  end

  defp valid_sha(_), do: {:error, "commit ID is not a full SHA"}

  defp read_manifest(path) when is_binary(path) do
    with {:ok, bytes} <- File.read(path),
         {:ok, records} <- parse_records(bytes) do
      {:ok, records}
    else
      {:error, reason} when is_atom(reason) -> {:error, "manifest unreadable: #{reason}"}
      error -> error
    end
  end

  defp read_manifest(_), do: {:error, "manifest path is invalid"}

  defp parse_records(bytes) do
    fields = :binary.split(bytes, <<0>>, [:global])

    if List.last(fields) != "" or rem(length(fields) - 1, 4) != 0 or length(fields) == 1 do
      {:error, "manifest has malformed NUL framing"}
    else
      records =
        fields
        |> Enum.drop(-1)
        |> Enum.chunk_every(4)
        |> Enum.map(fn [kind, mode, path, value] -> {kind, mode, path, value} end)

      paths = Enum.map(records, &elem(&1, 2))

      cond do
        not Enum.all?(records, &valid_record?/1) ->
          {:error, "manifest has a malformed record"}

        paths != Enum.uniq(paths) ->
          {:error, "manifest has a duplicate path"}

        paths != Enum.sort(paths) ->
          {:error, "manifest paths are not bytewise sorted"}

        true ->
          {:ok, records}
      end
    end
  end

  defp valid_record?({"f", mode, path, digest}) when mode in ["644", "755"] and path != "",
    do: Regex.match?(@digest, digest)

  defp valid_record?({"l", "0", path, target}) when path != "" and target != "", do: true
  defp valid_record?({"d", "0", path, ""}) when path != "", do: true
  defp valid_record?(_), do: false

  defp read_sidecar(manifest) do
    path = manifest <> ".source-identity"

    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} -> File.read(path)
      _ -> {:error, "source-identity sidecar is missing or not an ordinary file"}
    end
  end

  defp git_tree(sha) do
    with {:ok, output} <- git(["ls-tree", "-rz", "-r", "-t", "--full-tree", sha]),
         {:ok, entries} <- parse_git_tree(output) do
      {:ok, entries}
    end
  end

  defp archive_members(sha) do
    case System.cmd("git", ["--no-replace-objects", "archive", "--format=tar", sha]) do
      {archive, 0} ->
        case :erl_tar.table({:binary, archive}, [:verbose]) do
          {:ok, entries} -> archive_paths(entries)
          {:error, _} -> {:error, "Git archive could not be enumerated"}
        end

      {_output, _status} ->
        {:error, "Git archive could not be enumerated"}
    end
  rescue
    _ -> {:error, "Git archive could not be enumerated"}
  end

  defp archive_paths(entries) do
    Enum.reduce_while(entries, {:ok, MapSet.new()}, fn entry, {:ok, paths} ->
      case archive_path(entry) do
        :metadata ->
          {:cont, {:ok, paths}}

        {:ok, path} ->
          if MapSet.member?(paths, path),
            do: {:halt, {:error, "Git archive has a duplicate path"}},
            else: {:cont, {:ok, MapSet.put(paths, path)}}

        :invalid ->
          {:halt, {:error, "Git archive has an unsupported entry"}}
      end
    end)
  end

  defp archive_path({~c"pax_global_header", :unknown, _, _, _, _, _}), do: :metadata

  defp archive_path({name, type, _, _, _, _, _})
       when type in [:regular, :directory, :symlink] and is_list(name) do
    {:ok, List.to_string(name)}
  end

  defp archive_path(_), do: :invalid

  defp parse_git_tree(bytes) do
    entries = :binary.split(bytes, <<0>>, [:global]) |> Enum.reject(&(&1 == ""))

    Enum.reduce_while(entries, {:ok, %{}}, fn entry, {:ok, acc} ->
      case :binary.split(entry, "\t") do
        [metadata, path] when path != "" ->
          case :binary.split(metadata, " ", [:global]) do
            [mode, _type, object] ->
              {:cont, {:ok, Map.put(acc, path, {mode, object})}}

            _ ->
              {:halt, {:error, "Git tree has malformed metadata"}}
          end

        _ ->
          {:halt, {:error, "Git tree has a malformed entry"}}
      end
    end)
  end

  defp git_mode("100644"), do: {:ok, {"f", "644"}}
  defp git_mode("100755"), do: {:ok, {"f", "755"}}
  defp git_mode("120000"), do: {:ok, {"l", "0"}}
  defp git_mode("040000"), do: {:ok, {"d", "0"}}
  defp git_mode(_), do: {:error, "Git tree has an unsupported entry mode"}

  defp projection(records),
    do: Map.new(records, fn {kind, mode, path, _} -> {path, {kind, mode}} end)

  defp projection_matches_tree?(records, tree, members) do
    MapSet.new(records, &elem(&1, 2)) == members and
      Enum.all?(records, fn {kind, mode, path, _} ->
        case Map.fetch(tree, path) do
          {:ok, {git_entry_mode, _object}} -> git_mode(git_entry_mode) == {:ok, {kind, mode}}
          :error -> false
        end
      end)
  end

  defp contents_match_tree(records, tree) do
    Enum.reduce_while(records, :ok, fn
      {"f", _mode, "SOURCE_IDENTITY", _digest}, :ok ->
        {:cont, :ok}

      {"d", _mode, _path, _value}, :ok ->
        {:cont, :ok}

      {kind, _mode, path, value}, :ok when kind in ["f", "l"] ->
        {_mode, object} = Map.fetch!(tree, path)

        case git(["cat-file", "blob", object]) do
          {:ok, bytes} ->
            expected =
              if kind == "f",
                do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower),
                else: bytes

            if value == expected,
              do: {:cont, :ok},
              else: {:halt, {:error, "archive content differs from its commit blob"}}

          {:error, _reason} ->
            {:halt, {:error, "Git could not read one archive blob"}}
        end
    end)
  end

  defp identity_matches(records, sidecar, sha) do
    with {:ok, output} <- git(["show", "-s", "--format=commit %H%ncommitter-date %cI", sha]),
         expected <- String.trim_trailing(output) <> "\n",
         true <- sidecar == expected,
         [{"f", "644", "SOURCE_IDENTITY", digest}] <-
           Enum.filter(records, fn {_, _, path, _} -> path == "SOURCE_IDENTITY" end),
         true <- digest == Base.encode16(:crypto.hash(:sha256, sidecar), case: :lower) do
      :ok
    else
      false -> {:error, "SOURCE_IDENTITY does not name its own commit"}
      _ -> {:error, "SOURCE_IDENTITY is absent or differs from its sidecar"}
    end
  end

  defp shipped(records) do
    Enum.reject(records, fn {_, _, path, _} ->
      path in ["docs", "README.md", "SOURCE_IDENTITY"] or
        :binary.match(path, "docs/") == {0, 5}
    end)
  end

  defp git(args) do
    case System.cmd("git", ["--no-replace-objects" | args], stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {_output, _status} -> {:error, "Git could not read the named commit"}
    end
  rescue
    _ -> {:error, "Git is unavailable"}
  end
end
