defmodule LoopexComposition.ResourcePacksDirectoriesTest do
  use ExUnit.Case, async: false
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

  test "retained decoders admit actual normalized writer bytes and local manifest provenance", %{
    root: root,
    workspace: workspace
  } do
    directory = skill(Path.join([root, "retained-local", "review"]), "review", "body")
    File.write!(Path.join(directory, "opaque.bin"), <<0, 255, 128>>)

    assert {:ok, %{manifest: manifest}} =
             ResourcePacks.read_directories([directory], workspace: workspace)

    state_root = Path.join(root, "retained-state")
    assert {:ok, digest} = ResourcePacks.retain(manifest, state_root)
    path = Path.join([state_root, "resource-packs", "manifests", digest <> ".etf"])
    bytes = File.read!(path)
    mode = File.stat!(path).mode
    assert {:ok, ^manifest} = ResourcePacks.decode_retained_manifest(bytes, digest)
    [pack] = manifest["packs"]
    assert pack["origin"] == nil
    assert pack["commit"] == nil
    assert pack["tree_digest"] == nil

    assert {:error, {:retained_provenance_invalid, _}} =
             ResourcePacks.decode_retained_provenance(
               retained_bytes(pack),
               content_identity(pack)
             )

    assert File.read!(path) == bytes
    assert File.stat!(path).mode == mode
    refute File.exists?(Path.join([state_root, "resource-packs", "provenance"]))
  end

  test "retained imported packs preserve both native Git widths and every opaque body", %{
    root: root
  } do
    for width <- [40, 64] do
      {manifest, digest, pack, identity} = retained_fixture(width)
      state_root = Path.join(root, "retained-git-#{width}")
      assert {:ok, ^digest} = ResourcePacks.retain(manifest, state_root)
      catalog_path = Path.join([state_root, "resource-packs", "manifests", digest <> ".etf"])
      pack_path = Path.join([state_root, "resource-packs", "provenance", identity <> ".etf"])
      catalog_bytes = File.read!(catalog_path)
      pack_bytes = File.read!(pack_path)
      modes = Enum.map([catalog_path, pack_path], &File.stat!(&1).mode)
      assert pack_bytes == retained_bytes(pack)
      assert {:ok, ^manifest} = ResourcePacks.decode_retained_manifest(catalog_bytes, digest)
      assert {:ok, ^pack} = ResourcePacks.decode_retained_provenance(pack_bytes, identity)
      assert byte_size(pack["commit"]) == width
      assert byte_size(pack["tree_digest"]) == width

      assert Enum.find(pack["files"], &(&1["label"] == "opaque.bin"))["content"] ==
               <<0, 255, 128>>

      assert Enum.map([catalog_path, pack_path], &File.stat!(&1).mode) == modes
      assert File.read!(catalog_path) == catalog_bytes
      assert File.read!(pack_path) == pack_bytes
    end
  end

  test "retained provenance decoder consumes the actual pinned Git import writer", %{
    root: root,
    workspace: workspace
  } do
    source = Path.join(root, "retained-import-source")
    directory = skill(Path.join(source, "imported"), "imported", "body")
    File.write!(Path.join(directory, "opaque.bin"), <<0, 255, 128>>)
    git!(source, ["init", "--quiet", "--object-format=sha1"])
    git!(source, ["add", "."])

    git!(source, [
      "-c",
      "user.name=Test",
      "-c",
      "user.email=test@example.invalid",
      "commit",
      "--quiet",
      "-m",
      "Retained pack"
    ])

    commit = git!(source, ["rev-parse", "HEAD"])
    state_root = Path.join(root, "retained-import-state")

    assert {:ok, pack} =
             ResourcePacks.add(workspace, source,
               workspace_ref: "workspace:retained-import",
               state_root: state_root,
               rev: commit,
               path: "imported",
               git_executable: System.find_executable("git"),
               executor_authorization: {:host_policy, :allow}
             )

    identity = content_identity(pack)
    path = Path.join([state_root, "resource-packs", "provenance", identity <> ".etf"])
    bytes = File.read!(path)
    assert bytes == retained_bytes(pack)
    assert {:ok, ^pack} = ResourcePacks.decode_retained_provenance(bytes, identity)
    assert pack["commit"] == commit
  end

  test "maximum admitted cardinalities fields and bodies fit the derived raw ceilings" do
    instruction_content = String.duplicate("x", 16_384)
    opaque_content = :binary.copy(<<255>>, 16_384)

    files =
      for index <- 0..63 do
        {label, content} =
          if index == 0 do
            {"SKILL.md", instruction_content}
          else
            {String.pad_trailing("asset-#{index}", 1_024, "x"), opaque_content}
          end

        %{
          "label" => label,
          "size" => byte_size(content),
          "digest" => LoopexProtocol.Canonical.digest_bytes(content),
          "content" => content,
          "contained" => true
        }
      end

    packs =
      for index <- 0..63 do
        %{
          "source_id" => String.duplicate("s", 1_024),
          "origin" => String.pad_trailing("https://example.invalid/", 1_024, "x"),
          "commit" => String.duplicate("a", 64),
          "tree_digest" => String.duplicate("b", 64),
          "name" => String.pad_trailing("pack-#{index}", 64, "x"),
          "description" => String.duplicate("d", 1_024),
          "manual_only" => false,
          "files" => files
        }
      end

    manifest = %{
      "version" => "loopex.resource_pack/1",
      "workspace_ref" => String.duplicate("w", 1_024),
      "revision" => String.duplicate("r", 1_024),
      "packs" => packs
    }

    assert {:ok, digest, normalized} = Loopex.ResourcePack.digest(manifest)
    bytes = retained_bytes(normalized)
    assert byte_size(bytes) <= 72_081_510
    assert {:ok, ^normalized} = ResourcePacks.decode_retained_manifest(bytes, digest)
    pack = hd(normalized["packs"])
    pack_bytes = retained_bytes(pack)
    assert byte_size(pack_bytes) <= 1_126_241

    assert {:ok, ^pack} =
             ResourcePacks.decode_retained_provenance(pack_bytes, content_identity(pack))
  end

  test "retained bytes reject raw oversize compression and wrong roots before actual decode" do
    {manifest, digest, pack, identity} = retained_fixture(64)
    compressed_manifest = :erlang.term_to_binary(manifest, [:deterministic, :compressed])
    compressed_pack = :erlang.term_to_binary(pack, [:deterministic, :compressed])
    assert <<131, 80, _::binary>> = compressed_manifest
    assert <<131, 80, _::binary>> = compressed_pack
    oversized_manifest = <<131, 116>> <> :binary.copy(<<0>>, 72_081_509)
    oversized_pack = <<131, 116>> <> :binary.copy(<<0>>, 1_126_240)

    {results, calls} =
      decoder_calls(fn ->
        [
          ResourcePacks.decode_retained_manifest(oversized_manifest, digest),
          ResourcePacks.decode_retained_provenance(oversized_pack, identity),
          ResourcePacks.decode_retained_manifest(compressed_manifest, digest),
          ResourcePacks.decode_retained_provenance(compressed_pack, identity),
          ResourcePacks.decode_retained_manifest(retained_bytes([manifest]), digest),
          ResourcePacks.decode_retained_provenance(retained_bytes({pack}), identity),
          ResourcePacks.decode_retained_manifest(nil, digest),
          ResourcePacks.decode_retained_provenance(<<131>>, identity),
          ResourcePacks.decode_retained_manifest(retained_bytes(manifest), nil),
          ResourcePacks.decode_retained_provenance(retained_bytes(pack), String.upcase(identity))
        ]
      end)

    assert Enum.all?(results, &match?({:error, {_reason, _detail}}, &1))
    assert calls == 0

    # Concept: the trace observes the real decoder, with a positive control.
    # Technical depth: only one finite worker is traced and arity-only call events
    # omit input bytes. Trace delivery is joined before inspecting the collector.
    assert {[{:ok, ^manifest}, {:ok, ^pack}], 2} =
             decoder_calls(fn ->
               [
                 ResourcePacks.decode_retained_manifest(retained_bytes(manifest), digest),
                 ResourcePacks.decode_retained_provenance(retained_bytes(pack), identity)
               ]
             end)
  end

  test "retained decoder trace witness refuses an existing pattern without clearing it" do
    boundary = {:erlang, :binary_to_term, 2}
    assert :erlang.trace_info(boundary, :traced) == {:traced, false}

    try do
      assert :erlang.trace_pattern(boundary, true, [:local]) == 1
      traced = :erlang.trace_info(boundary, :traced)
      match_spec = :erlang.trace_info(boundary, :match_spec)

      assert_raise ExUnit.AssertionError, fn ->
        decoder_calls(fn -> flunk("existing trace pattern must refuse before worker startup") end)
      end

      assert :erlang.trace_info(boundary, :traced) == traced
      assert :erlang.trace_info(boundary, :match_spec) == match_spec
    after
      :erlang.trace_pattern(boundary, false, [:local])
    end
  end

  test "retained decoders refuse trailing noncanonical unsafe and non-normalized data" do
    {manifest, digest, pack, identity} = retained_fixture(64)
    bytes = retained_bytes(manifest)
    pack_bytes = retained_bytes(pack)
    size_key = <<109, 0, 0, 0, 4, "size">>
    noncanonical = :binary.replace(bytes, size_key <> <<97, 3>>, size_key <> <<98, 3::32>>)

    noncanonical_pack =
      :binary.replace(pack_bytes, size_key <> <<97, 3>>, size_key <> <<98, 3::32>>)

    refute noncanonical == bytes
    refute noncanonical_pack == pack_bytes
    assert :erlang.binary_to_term(noncanonical, [:safe]) == manifest
    assert :erlang.binary_to_term(noncanonical_pack, [:safe]) == pack

    aliases = %{
      version: manifest["version"],
      workspace_ref: manifest["workspace_ref"],
      revision: manifest["revision"],
      packs: manifest["packs"]
    }

    for candidate <- [
          bytes <> <<0>>,
          noncanonical,
          <<131, 116, 0, 0>>,
          retained_bytes(aliases),
          retained_bytes(Map.put(manifest, "extra", self())),
          retained_bytes(Map.put(manifest, "extra", fn -> :unsafe end)),
          retained_bytes(Map.delete(manifest, "revision")),
          retained_bytes(%{
            manifest
            | "packs" => [%{pack | "files" => Enum.reverse(pack["files"])}]
          })
        ] do
      assert {:error, {:retained_manifest_invalid, _}} =
               ResourcePacks.decode_retained_manifest(candidate, digest)
    end

    for candidate <- [
          pack_bytes <> <<0>>,
          noncanonical_pack,
          retained_bytes(Map.put(pack, "extra", self())),
          retained_bytes(Map.delete(pack, "commit")),
          retained_bytes(%{pack | "files" => Enum.reverse(pack["files"])})
        ] do
      assert {:error, {:retained_provenance_invalid, _}} =
               ResourcePacks.decode_retained_provenance(candidate, identity)
    end

    second_pack = %{pack | "name" => "second"}

    assert {:ok, two_digest, two_manifest} =
             Loopex.ResourcePack.digest(%{manifest | "packs" => [pack, second_pack]})

    unordered = %{two_manifest | "packs" => Enum.reverse(two_manifest["packs"])}

    assert {:error, {:retained_manifest_invalid, _}} =
             ResourcePacks.decode_retained_manifest(retained_bytes(unordered), two_digest)

    atom_name = "loopex_retained_pack_unknown_#{System.unique_integer([:positive])}"
    assert_raise ArgumentError, fn -> String.to_existing_atom(atom_name) end

    unknown_atom =
      <<131, 116, 0, 0, 0, 1, 109, 0, 0, 0, 5, "extra", 118, byte_size(atom_name)::16,
        atom_name::binary>>

    assert {:error, {:retained_manifest_invalid, _}} =
             ResourcePacks.decode_retained_manifest(unknown_atom, digest)

    assert {:error, {:retained_provenance_invalid, _}} =
             ResourcePacks.decode_retained_provenance(unknown_atom, identity)

    assert_raise ArgumentError, fn -> String.to_existing_atom(atom_name) end
  end

  test "retained identity size digest instruction and Git semantics cannot be forged" do
    {manifest, digest, pack, identity} = retained_fixture(64)
    [instruction, opaque] = pack["files"]

    altered_packs = [
      %{pack | "files" => [%{instruction | "size" => instruction["size"] + 1}, opaque]},
      %{pack | "files" => [%{instruction | "digest" => String.duplicate("0", 64)}, opaque]},
      %{pack | "files" => [%{instruction | "content" => "altered!"}, opaque]},
      %{pack | "files" => [opaque]},
      %{pack | "files" => [%{instruction | "contained" => false}, opaque]},
      %{pack | "tree_digest" => String.duplicate("b", 40)},
      %{pack | "commit" => String.duplicate("A", 64)},
      %{pack | "origin" => nil},
      %{pack | "source_id" => self()}
    ]

    for altered <- altered_packs do
      assert {:error, {:retained_manifest_invalid, _}} =
               ResourcePacks.decode_retained_manifest(
                 retained_bytes(%{manifest | "packs" => [altered]}),
                 digest
               )

      assert {:error, {:retained_provenance_invalid, _}} =
               ResourcePacks.decode_retained_provenance(retained_bytes(altered), identity)
    end

    assert {:error, {:retained_manifest_invalid, _}} =
             ResourcePacks.decode_retained_manifest(
               retained_bytes(manifest),
               String.duplicate("0", 64)
             )

    assert {:error, {:retained_provenance_invalid, _}} =
             ResourcePacks.decode_retained_provenance(
               retained_bytes(pack),
               String.duplicate("0", 64)
             )
  end

  defp retained_fixture(width) do
    files =
      for {label, content} <- [{"SKILL.md", "summary\n"}, {"opaque.bin", <<0, 255, 128>>}] do
        %{
          "label" => label,
          "size" => byte_size(content),
          "digest" => LoopexProtocol.Canonical.digest_bytes(content),
          "content" => content,
          "contained" => true
        }
      end

    pack = %{
      "source_id" => "git:retained-fixture",
      "origin" => "https://example.invalid/skills",
      "commit" => String.duplicate("a", width),
      "tree_digest" => String.duplicate("b", width),
      "name" => "review",
      "description" => "Review retained bytes.",
      "manual_only" => false,
      "files" => files
    }

    manifest = %{
      "version" => "loopex.resource_pack/1",
      "workspace_ref" => "workspace:retained",
      "revision" => nil,
      "packs" => [pack]
    }

    {:ok, digest, normalized} = Loopex.ResourcePack.digest(manifest)
    [normalized_pack] = normalized["packs"]
    {normalized, digest, normalized_pack, content_identity(normalized_pack)}
  end

  defp retained_bytes(term), do: :erlang.term_to_binary(term, [:deterministic])

  defp content_identity(pack) do
    LoopexProtocol.Canonical.digest(%{
      "encoding" => LoopexProtocol.Canonical.version(),
      "kind" => "loopex.retained_resource_content/1",
      "value" => Enum.map(pack["files"], &[&1["label"], &1["digest"]])
    })
  end

  defp git!(directory, arguments) do
    {output, status} = System.cmd("git", arguments, cd: directory, stderr_to_stdout: true)
    assert status == 0, output
    String.trim(output)
  end

  defp decoder_calls(function) do
    parent = self()
    reference = make_ref()
    boundary = {:erlang, :binary_to_term, 2}

    # Concept: this witness never replaces another observer's BIF trace pattern.
    # Technical depth: the process-scoped probe refuses existing tracing before
    # allocating its worker or entering the cleanup that clears its own pattern.
    assert :erlang.trace_info(boundary, :traced) == {:traced, false}

    {worker, monitor} =
      spawn_monitor(fn ->
        receive do
          {:run, ^reference} ->
            send(parent, {reference, function.()})

            receive do
              {:stop, ^reference} -> :ok
            end
        end
      end)

    try do
      assert :erlang.trace_pattern(boundary, true, [:local]) == 1
      assert :erlang.trace(worker, true, [:call, :arity, {:tracer, parent}]) == 1
      send(worker, {:run, reference})
      assert_receive {^reference, result}, 2_000
      delivery = :erlang.trace_delivered(worker)
      assert_receive {:trace_delivered, ^worker, ^delivery}, 2_000
      calls = collect_decoder_calls(worker, 0)
      send(worker, {:stop, reference})
      assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 2_000
      {result, calls}
    after
      :erlang.trace_pattern(boundary, false, [:local])

      if Process.alive?(worker) do
        Process.exit(worker, :kill)
        assert_receive {:DOWN, ^monitor, :process, ^worker, _reason}, 2_000
      else
        Process.demonitor(monitor, [:flush])
      end
    end
  end

  defp collect_decoder_calls(worker, count) when count < 64 do
    receive do
      {:trace, ^worker, :call, {:erlang, :binary_to_term, 2}} ->
        collect_decoder_calls(worker, count + 1)
    after
      0 -> count
    end
  end

  defp collect_decoder_calls(_worker, _count),
    do: flunk("retained decoder trace exceeded its cap")

  defp skill(path, name, body) do
    File.mkdir_p!(path)

    File.write!(
      Path.join(path, "SKILL.md"),
      "---\nname: #{name}\ndescription: test skill\n---\n#{body}\n"
    )

    path
  end
end
