defmodule LoopexComposition.ResourcePacksDirectoriesTest do
  use ExUnit.Case, async: true
  alias LoopexComposition.ResourcePacks

  defmodule ObservedFiles do
    @moduledoc false
    def ls(path), do: observe(:ls, path, File.ls(path))
    def list_dir_all(path), do: observe(:ls, List.to_string(path), :file.list_dir_all(path))
    def open(path, options), do: observe(:open, path, File.open(path, options))
    def lstat(path), do: observe(:lstat, path, File.lstat(path))

    defp observe(operation, path, result) do
      if observer = Process.get(:named_pack_filesystem_observer), do: observer.(operation, path)
      result
    end
  end

  setup_all do
    # Concept: boundary counters use the production transition, with no impossible pack fixture.
    # Technical depth: compile a test-only copy exposing that one private function.
    # Filesystem calls still reach real files, with mutations observed between checks.
    source = Path.expand("../lib/resource_packs.ex", __DIR__) |> File.read!()
    {:defmodule, metadata, [_name, [do: body]]} = Code.string_to_quoted!(source)

    body =
      Macro.prewalk(body, fn
        {:defp, metadata,
         [{:named_transition, _, [counts, increments, depth]} = head, [do: transition]]} ->
          observation =
            quote do
              if observer = Process.get(:named_pack_counter_observer),
                do: observer.(unquote(counts), unquote(increments), unquote(depth))
            end

          {:def, metadata, [head, [do: {:__block__, [], [observation, transition]}]]}

        {{:., metadata, [:file, :list_dir_all]}, call_metadata, arguments} ->
          {{:., metadata, [ObservedFiles, :list_dir_all]}, call_metadata, arguments}

        {{:., metadata, [{:__aliases__, _, [:File]}, operation]}, call_metadata, arguments}
        when operation in [:ls, :open, :lstat] ->
          {{:., metadata, [ObservedFiles, operation]}, call_metadata, arguments}

        node ->
          node
      end)

    Code.compile_quoted({:defmodule, metadata, [NamedPackWitness, [do: body]]})
    :ok
  end

  setup do
    root =
      Path.join(System.tmp_dir!(), "loopex-named-packs-#{System.unique_integer([:positive])}")

    workspace = Path.join(root, "workspace")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, workspace: workspace}
  end

  test "empty named selection derives its workspace identity without discovery", %{
    workspace: workspace
  } do
    assert {:ok, result} = ResourcePacks.read_directories([], workspace: workspace)
    assert Map.keys(result) |> Enum.sort() == [:manifest, :shadowed_skills]
    assert result.shadowed_skills == []
    assert result.manifest["packs"] == []
    assert {:ok, ref} = LoopexComposition.WorkspaceIdentity.reference(workspace)
    assert result.manifest["workspace_ref"] == ref
    assert {:ok, _, normalized} = Loopex.ResourcePack.digest(result.manifest)
    assert normalized == result.manifest
  end

  test "complete path shape precedes options and workspace", %{workspace: workspace} do
    invalid = [
      nil,
      "path",
      ["x" | :tail],
      [""],
      [<<255>>],
      ["a" <> <<0>>],
      [String.duplicate("x", 65_537)],
      ["x", "x"],
      ~w(a b c d e),
      ["missing", nil]
    ]

    for paths <- invalid, options <- [nil, [workspace: workspace], [workspace: "/missing"]] do
      assert ResourcePacks.read_directories(paths, options) == {:error, :invalid_paths}
    end

    for options <- [
          nil,
          [],
          [workspace: workspace, workspace: workspace],
          [workspace: workspace, other: true],
          [workspace: ""],
          [workspace: <<255>>],
          [workspace: "a" <> <<0>>],
          [workspace: String.duplicate("x", 65_537)],
          [workspace: workspace] ++ [:tail]
        ] do
      assert ResourcePacks.read_directories([], options) == {:error, :invalid_options}
    end

    for paths <- [[], ["missing"]] do
      assert ResourcePacks.read_directories(paths, workspace: "/missing") ==
               {:error, :workspace_unusable}

      refute File.exists?("/missing")
    end
  end

  test "named project and user snapshots normalize and project wins", %{
    root: root,
    workspace: workspace
  } do
    project = skill(Path.join([workspace, ".agents", "skills", "review"]), "review", "project")
    user = skill(Path.join([root, "user", "review"]), "review", "user")
    other = skill(Path.join([root, "user", "other"]), "other", "other")
    paths = [project, user, other]
    assert {:ok, result} = ResourcePacks.read_directories(paths, workspace: workspace)

    assert ResourcePacks.read_directories(Enum.reverse(paths), workspace: workspace) ==
             {:ok, result}

    assert result.shadowed_skills == ["user:review"]

    assert Enum.map(result.manifest["packs"], & &1["source_id"]) == [
             "project:review",
             "user:other"
           ]

    for pack <- result.manifest["packs"] do
      assert Map.take(pack, ["origin", "commit", "tree_digest"]) == %{
               "origin" => nil,
               "commit" => nil,
               "tree_digest" => nil
             }

      for file <- pack["files"] do
        assert file["digest"] == LoopexProtocol.Canonical.digest_bytes(file["content"])
        assert file["size"] == byte_size(file["content"])
      end
    end

    refute inspect(result) =~ root

    assert {:ok, relative} =
             ResourcePacks.read_directories([".agents/skills/review"], workspace: workspace)

    assert relative.manifest["packs"] == [hd(result.manifest["packs"])]

    assert {:ok, discovered} =
             ResourcePacks.discover(workspace, workspace_ref: result.manifest["workspace_ref"])

    assert discovered == relative.manifest
  end

  test "classification and duplicates use real paths", %{root: root, workspace: workspace} do
    project = skill(Path.join([workspace, ".agents", "skills", "review"]), "review", "project")
    user = skill(Path.join([root, "user", "review"]), "review", "user")
    link = Path.join(root, "alias")
    File.ln_s!(project, link)
    assert {:ok, result} = ResourcePacks.read_directories([link], workspace: workspace)
    assert hd(result.manifest["packs"])["source_id"] == "project:review"

    assert ResourcePacks.read_directories([link, project], workspace: workspace) ==
             {:error, :duplicate_skill}

    second = skill(Path.join([root, "second", "review"]), "review", "second")

    assert ResourcePacks.read_directories([user, second], workspace: workspace) ==
             {:error, :duplicate_skill}

    assert ResourcePacks.read_directories([project, project <> "/."], workspace: workspace) ==
             {:error, :duplicate_skill}

    internal = skill(Path.join(workspace, "review"), "review", "wrong location")

    assert ResourcePacks.read_directories([internal], workspace: workspace) ==
             {:error, :unclassified_skill_directory}

    File.ln_s!(user, Path.join(workspace, "external-link"))

    assert {:ok, external} =
             ResourcePacks.read_directories(["external-link"], workspace: workspace)

    assert hd(external.manifest["packs"])["source_id"] == "user:review"
    skill(Path.join([workspace, "~", "review"]), "review", "literal relative path")

    assert ResourcePacks.read_directories(["~/review"], workspace: workspace) ==
             {:error, :unclassified_skill_directory}
  end

  test "bytewise sorted path order fixes first failure", %{root: root, workspace: workspace} do
    bad = skill(Path.join(root, "a-invalid"), "mismatch", "bad")
    absent = Path.join(root, "z-absent")

    for paths <- [[bad, absent], [absent, bad]] do
      assert ResourcePacks.read_directories(paths, workspace: workspace) ==
               {:error, :skill_manifest_invalid}
    end

    early = Path.join(root, "0-absent")

    for paths <- [[early, bad], [bad, early]] do
      assert ResourcePacks.read_directories(paths, workspace: workspace) ==
               {:error, :skill_directory_unusable}
    end

    assert ResourcePacks.read_directories([absent],
             workspace: Path.join(root, "missing-workspace")
           ) == {:error, :workspace_unusable}
  end

  test "one traversal enforces exact file content directory and depth caps", %{
    root: root,
    workspace: workspace
  } do
    files = skill(Path.join(root, "files"), "files", "body")
    for n <- 1..63, do: File.write!(Path.join(files, "file-#{n}"), "")
    assert {:ok, _} = ResourcePacks.read_directories([files], workspace: workspace)
    File.write!(Path.join(files, "file-64"), "")

    assert ResourcePacks.read_directories([files], workspace: workspace) ==
             {:error, :skill_manifest_invalid}

    bytes = skill(Path.join(root, "bytes"), "bytes", "body")
    skill_size = File.stat!(Path.join(bytes, "SKILL.md")).size
    File.write!(Path.join(bytes, "data"), :binary.copy(<<255>>, 1_048_576 - skill_size))
    assert {:ok, _} = ResourcePacks.read_directories([bytes], workspace: workspace)
    File.write!(Path.join(bytes, "extra"), "x")

    assert ResourcePacks.read_directories([bytes], workspace: workspace) ==
             {:error, :skill_manifest_invalid}

    directories = skill(Path.join(root, "directories"), "directories", "body")
    for n <- 1..255, do: File.mkdir!(Path.join(directories, "d-#{n}"))
    assert {:ok, _} = ResourcePacks.read_directories([directories], workspace: workspace)
    File.mkdir!(Path.join(directories, "overflow"))

    assert ResourcePacks.read_directories([directories], workspace: workspace) ==
             {:error, :skill_manifest_invalid}

    depth = skill(Path.join(root, "depth"), "depth", "body")

    last =
      Enum.reduce(1..32, depth, fn _, path ->
        child = Path.join(path, "d")
        File.mkdir!(child)
        child
      end)

    File.write!(Path.join(Path.dirname(last), "at-32"), "")
    assert {:ok, _} = ResourcePacks.read_directories([depth], workspace: workspace)
    File.write!(Path.join(last, "at-33"), "")

    assert ResourcePacks.read_directories([depth], workspace: workspace) ==
             {:error, :skill_manifest_invalid}
  end

  test "symlinks special entries and invalid frontmatter refuse", %{
    root: root,
    workspace: workspace
  } do
    link = skill(Path.join(root, "linked"), "linked", "body")
    File.ln_s!(Path.join(link, "SKILL.md"), Path.join(link, "link"))

    assert ResourcePacks.read_directories([link], workspace: workspace) ==
             {:error, :skill_manifest_invalid}

    special = skill(Path.join(root, "special"), "special", "body")
    assert {_, 0} = System.cmd("mkfifo", [Path.join(special, "fifo")])

    assert ResourcePacks.read_directories([special], workspace: workspace) ==
             {:error, :skill_manifest_invalid}

    absent = Path.join(root, "absent")
    File.mkdir!(absent)

    assert ResourcePacks.read_directories([absent], workspace: workspace) ==
             {:error, :skill_manifest_invalid}

    malformed = skill(Path.join(root, "malformed"), "malformed", "body")
    File.write!(Path.join(malformed, "SKILL.md"), "no frontmatter")

    assert ResourcePacks.read_directories([malformed], workspace: workspace) ==
             {:error, :skill_manifest_invalid}

    assert ResourcePacks.read_directories([Path.join(malformed, "SKILL.md")],
             workspace: workspace
           ) == {:error, :skill_directory_unusable}

    cycle = Path.join(root, "cycle")
    File.ln_s!(cycle, cycle)

    assert ResourcePacks.read_directories([cycle], workspace: workspace) ==
             {:error, :skill_directory_unusable}
  end

  test "actual transition admits equality and refuses each first increment beyond a cap" do
    counts = %{directories: 1, entries: 0, path_bytes: 0, files: 0, content_bytes: 0}

    limits = %{
      directories: 256,
      entries: 4_096,
      path_bytes: 1_048_576,
      files: 64,
      content_bytes: 1_048_576
    }

    for {key, max} <- limits do
      before = Map.put(counts, key, max - 1)

      assert {:ok, admitted} =
               apply(NamedPackWitness, :named_transition, [before, %{key => 1}, 32])

      assert admitted[key] == max

      assert apply(NamedPackWitness, :named_transition, [admitted, %{key => 1}, 32]) ==
               {:error, :skill_manifest_invalid}
    end

    assert {:ok, ^counts} = apply(NamedPackWitness, :named_transition, [counts, %{}, 32])

    assert apply(NamedPackWitness, :named_transition, [counts, %{}, 33]) ==
             {:error, :skill_manifest_invalid}

    # Raw six-byte "a/link" counts even if the next type or name check will refuse.
    seeded = %{counts | entries: 4_095, path_bytes: 1_048_570}

    assert {:ok, %{entries: 4_096, path_bytes: 1_048_576}} =
             apply(NamedPackWitness, :named_transition, [
               seeded,
               %{entries: 1, path_bytes: byte_size("a/link")},
               2
             ])

    refute function_exported?(ResourcePacks, :named_transition, 3)
  end

  test "raw invalid-byte entries reach counters before UTF-8 validation", %{
    root: root,
    workspace: workspace
  } do
    pack = skill(Path.join(root, "raw-name"), "raw-name", "body")
    nested = Path.join(pack, "nested")
    File.mkdir!(nested)
    raw_path = nested <> "/" <> <<255>>

    case :file.write_file(raw_path, "raw content") do
      :ok ->
        assert ResourcePacks.read_directories([pack], workspace: workspace) ==
                 {:error, :skill_manifest_invalid}

        Process.put(:named_pack_counter_observer, fn counts, increments, depth ->
          send(self(), {:counter_candidate, counts, increments, depth})
        end)

        assert apply(NamedPackWitness, :read_directories, [[pack], [workspace: workspace]]) ==
                 {:error, :skill_manifest_invalid}

        expected_bytes = byte_size("nested/" <> <<255>>)

        assert_receive {:counter_candidate, _before, %{entries: 1, path_bytes: ^expected_bytes},
                        2}

      {:error, :eilseq} ->
        assert {:unix, :darwin} = :os.type()

        IO.puts(
          "NAMED_PACK_WITNESS_UNAVAILABLE invalid_name: Darwin filesystem rejected raw invalid UTF-8 filename with eilseq; Linux witness remains required"
        )
    end

    counts = %{directories: 1, entries: 4_095, path_bytes: 1_048_568, files: 0, content_bytes: 0}

    assert {:ok, %{entries: 4_096, path_bytes: 1_048_576}} =
             apply(NamedPackWitness, :named_transition, [
               counts,
               %{entries: 1, path_bytes: byte_size("nested/" <> <<255>>)},
               2
             ])
  end

  test "filesystem identity mutations normalize without retaining changed candidates", %{
    root: root,
    workspace: workspace
  } do
    pack = skill(Path.join(root, "mutating"), "mutating", "body")
    {:ok, pack_real} = LoopexComposition.WorkspaceIdentity.resolve_path(pack)

    Process.put(:named_pack_filesystem_observer, fn
      :ls, ^pack_real ->
        Process.delete(:named_pack_filesystem_observer)
        File.rename!(pack, pack <> "-old")
        File.mkdir!(pack)

      _, _ ->
        :ok
    end)

    assert apply(NamedPackWitness, :read_directories, [[pack], [workspace: workspace]]) ==
             {:error, :skill_directory_unusable}

    file_pack = skill(Path.join(root, "file-change"), "file-change", "body")
    file = Path.join(file_pack, "SKILL.md")
    {:ok, file_real} = LoopexComposition.WorkspaceIdentity.resolve_path(file)

    Process.put(:named_pack_filesystem_observer, fn
      :open, ^file_real ->
        Process.delete(:named_pack_filesystem_observer)
        File.rename!(file, file <> ".old")
        File.write!(file, "replacement")

      _, _ ->
        :ok
    end)

    assert apply(NamedPackWitness, :read_directories, [[file_pack], [workspace: workspace]]) ==
             {:error, :skill_directory_unusable}

    {:ok, resolved} = LoopexComposition.WorkspaceIdentity.resolve_path(workspace)

    Process.put(:named_pack_filesystem_observer, fn
      :lstat, ^resolved ->
        Process.delete(:named_pack_filesystem_observer)
        File.rename!(workspace, workspace <> "-old")
        File.mkdir!(workspace)

      _, _ ->
        :ok
    end)

    assert apply(NamedPackWitness, :read_directories, [[], [workspace: workspace]]) ==
             {:error, :workspace_unusable}
  end

  test "serial inspection never reads a directory after the first failure", %{
    root: root,
    workspace: workspace
  } do
    bad = skill(Path.join(root, "a-bad"), "mismatch", "bad")
    later = skill(Path.join(root, "z-later"), "z-later", "later")

    Process.put(:named_pack_filesystem_observer, fn
      :ls, path -> send(self(), {:directory_read, path})
      _, _ -> :ok
    end)

    assert apply(NamedPackWitness, :read_directories, [[later, bad], [workspace: workspace]]) ==
             {:error, :skill_manifest_invalid}

    {:ok, bad_real} = LoopexComposition.WorkspaceIdentity.resolve_path(bad)
    assert_receive {:directory_read, ^bad_real}
    refute_receive {:directory_read, _}
  end

  test "exact path and text bounds and two sorted shadows", %{root: root, workspace: workspace} do
    assert ResourcePacks.read_directories([String.duplicate("x", 65_536)], workspace: workspace) ==
             {:error, :skill_directory_unusable}

    assert ResourcePacks.read_directories([], workspace: String.duplicate("x", 65_536)) ==
             {:error, :workspace_unusable}

    paths =
      for kind <- ["user", "project"], name <- ["z", "a"] do
        base =
          if kind == "project",
            do: Path.join([workspace, ".agents", "skills"]),
            else: Path.join(root, "user")

        skill(Path.join(base, name), name, "body")
      end

    assert {:ok, result} = ResourcePacks.read_directories(paths, workspace: workspace)
    assert result.shadowed_skills == ["user:a", "user:z"]
    assert Enum.map(result.manifest["packs"], & &1["source_id"]) == ["project:a", "project:z"]
    text = skill(Path.join(root, "text"), "text", "body")
    file = Path.join(text, "SKILL.md")
    padding = 65_536 - File.stat!(file).size
    File.write!(file, String.duplicate("x", padding), [:append])
    assert {:ok, _} = ResourcePacks.read_directories([text], workspace: workspace)
    File.write!(file, "x", [:append])

    assert ResourcePacks.read_directories([text], workspace: workspace) ==
             {:error, :skill_manifest_invalid}
  end

  test "content growth is a pack cap refusal", %{root: root, workspace: workspace} do
    pack = skill(Path.join(root, "growing"), "growing", "body")
    file = Path.join(pack, "data")
    File.write!(file, "x")
    {:ok, resolved} = LoopexComposition.WorkspaceIdentity.resolve_path(file)

    Process.put(:named_pack_filesystem_observer, fn
      :open, ^resolved ->
        Process.delete(:named_pack_filesystem_observer)
        File.write!(file, :binary.copy(<<255>>, 1_048_577))

      _, _ ->
        :ok
    end)

    assert apply(NamedPackWitness, :read_directories, [[pack], [workspace: workspace]]) ==
             {:error, :skill_manifest_invalid}
  end

  defp skill(path, name, body) do
    File.mkdir_p!(path)

    File.write!(
      Path.join(path, "SKILL.md"),
      "---\nname: #{name}\ndescription: test skill\n---\n#{body}\n"
    )

    path
  end
end
