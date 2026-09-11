defmodule LoopexComposition.SkillAcquisitionTest do
  use ExUnit.Case, async: true

  alias LoopexComposition.ResourcePacks

  test "pinned Git import retains the exact tree and complete file identities" do
    root = tmp_dir!("discovery")
    workspace = Path.join(root, "workspace")
    state_root = Path.join(root, "state")
    skill = Path.join([workspace, ".agents", "skills", "review"])

    write!(Path.join(skill, "SKILL.md"), """
    ---
    name: review
    description: Review a change before it ships.
    disable-model-invocation: true
    metadata:
      owner: project
    ---
    Read references/checklist.md, then review the change.
    """)

    write!(Path.join(skill, "references/checklist.md"), "Check the actual diff.\n")

    assert {:ok, manifest} =
             ResourcePacks.discover(workspace,
               workspace_ref: "workspace:test",
               state_root: state_root
             )

    assert %{
             "version" => "loopex.resource_pack/1",
             "workspace_ref" => "workspace:test",
             "revision" => nil,
             "packs" => [pack]
           } = manifest

    assert pack["name"] == "review"
    assert pack["description"] == "Review a change before it ships."
    assert pack["manual_only"]
    assert pack["commit"] == nil
    assert pack["tree_digest"] == nil
    assert pack["origin"] == nil

    assert Enum.map(pack["files"], & &1["label"]) == [
             "SKILL.md",
             "references/checklist.md"
           ]

    assert Enum.all?(pack["files"], fn file ->
             file["size"] == byte_size(file["content"]) and
               file["digest"] == LoopexProtocol.Canonical.digest_bytes(file["content"]) and
               file["contained"] == true
           end)

    assert {:ok, digest} = ResourcePacks.retain(manifest, state_root)
    assert {:ok, ^manifest} = ResourcePacks.load(state_root, digest)
  end

  test "import uses the authorized executor with closed configuration and bounded cancellation" do
    root = tmp_dir!("git-import")
    source = Path.join(root, "source")
    workspace = Path.join(root, "workspace")
    state_root = Path.join(root, "state")
    git = System.find_executable("git") || flunk("git is required for this test")

    write!(Path.join(source, "imported/SKILL.md"), """
    ---
    name: imported
    description: Imported through the executor.
    ---
    Use the existing read tool.
    """)

    marker = Path.join(root, "downloaded-script-ran")

    write!(Path.join(source, "imported/scripts/install.sh"), """
    #!/bin/sh
    touch #{marker}
    """)

    File.chmod!(Path.join(source, "imported/scripts/install.sh"), 0o700)

    git!(source, ["init", "--quiet"])
    git!(source, ["add", "."])

    git!(source, [
      "-c",
      "user.name=Loopex Test",
      "-c",
      "user.email=test@loopex.invalid",
      "commit",
      "--quiet",
      "-m",
      "fixture"
    ])

    commit = git!(source, ["rev-parse", "HEAD"])
    tree = git!(source, ["rev-parse", "#{commit}:imported"])

    assert {:ok, pack} =
             ResourcePacks.add(workspace, source,
               workspace_ref: "workspace:test",
               state_root: state_root,
               rev: commit,
               path: "imported",
               git_executable: git,
               executor_authorization: {:host_policy, :allow},
               deadline_ms: 10_000
             )

    assert pack["commit"] == commit
    assert pack["tree_digest"] == tree
    assert pack["origin"] == source
    refute File.exists?(marker)

    assert File.read!(Path.join([workspace, ".agents", "skills", "imported", "SKILL.md"])) =~
             "Imported through the executor"

    assert {:ok, manifest} =
             ResourcePacks.discover(workspace,
               workspace_ref: "workspace:test",
               state_root: state_root
             )

    assert [rediscovered] = manifest["packs"]

    assert Map.take(rediscovered, ["origin", "commit", "tree_digest"]) ==
             Map.take(pack, ["origin", "commit", "tree_digest"])

    assert {:ok, _digest} = ResourcePacks.retain(manifest, state_root)

    conflicting =
      rediscovered
      |> Map.put("source_id", "git:" <> String.duplicate("a", 64))
      |> Map.put("origin", Path.join(root, "different-origin"))

    assert {:error, {:retained_identity_collision, _detail}} =
             ResourcePacks.retain(%{manifest | "packs" => [conflicting]}, state_root)

    assert {:ok, unchanged} =
             ResourcePacks.discover(workspace,
               workspace_ref: "workspace:test",
               state_root: state_root
             )

    assert [unchanged_pack] = unchanged["packs"]
    assert unchanged_pack["origin"] == source

    File.write!(
      Path.join([workspace, ".agents", "skills", "imported", "SKILL.md"]),
      "---\nname: imported\ndescription: Changed locally.\n---\nChanged.\n"
    )

    assert {:ok, changed} =
             ResourcePacks.discover(workspace,
               workspace_ref: "workspace:test",
               state_root: state_root
             )

    assert [local] = changed["packs"]
    assert local["origin"] == nil
    assert local["commit"] == nil
    assert local["tree_digest"] == nil
  end

  test "links escapes unsupported files and exceeded pack limits refuse before publication" do
    root = tmp_dir!("refusals")
    workspace = Path.join(root, "workspace")
    outside = Path.join(root, "outside.txt")
    skill = Path.join([workspace, ".agents", "skills", "unsafe"])
    write!(outside, "outside")
    write!(Path.join(skill, "SKILL.md"), "---\nname: unsafe\ndescription: Unsafe.\n---\nBody\n")
    File.ln_s!(outside, Path.join(skill, "escape"))

    assert {:error, {:unsupported_file, detail}} =
             ResourcePacks.discover(workspace, workspace_ref: "workspace:test")

    assert is_binary(detail) and byte_size(detail) <= 1_024

    limited_workspace = Path.join(root, "limited-workspace")
    limited_skill = Path.join([limited_workspace, ".agents", "skills", "limited"])

    write!(
      Path.join(limited_skill, "SKILL.md"),
      "---\nname: limited\ndescription: Too many files.\n---\nBody\n"
    )

    for index <- 1..64,
        do: write!(Path.join(limited_skill, "references/#{index}.txt"), "x")

    assert {:error, {:pack_file_limit, _detail}} =
             ResourcePacks.discover(limited_workspace, workspace_ref: "workspace:test")

    oversized_workspace = Path.join(root, "oversized-workspace")
    oversized_skill = Path.join([oversized_workspace, ".agents", "skills", "oversized"])

    write!(
      Path.join(oversized_skill, "SKILL.md"),
      "---\nname: oversized\ndescription: Too many bytes.\n---\nBody\n"
    )

    write!(Path.join(oversized_skill, "asset.bin"), :binary.copy(<<0>>, 1_048_576))

    assert {:error, {:pack_byte_limit, _detail}} =
             ResourcePacks.discover(oversized_workspace, workspace_ref: "workspace:test")
  end

  test "interrupted installation preserves the previous pack and executes no downloaded content" do
    root = tmp_dir!("atomic")
    workspace = Path.join(root, "workspace")
    installed = Path.join([workspace, ".agents", "skills", "safe", "SKILL.md"])
    write!(installed, "---\nname: safe\ndescription: Existing.\n---\nKeep me.\n")

    source = Path.join(root, "source")
    marker = Path.join(root, "replacement-script-ran")

    write!(Path.join(source, "safe/SKILL.md"), """
    ---
    name: safe
    description: Replacement.
    ---
    Replacement body.
    """)

    write!(Path.join(source, "safe/scripts/install.sh"), "#!/bin/sh\ntouch #{marker}\n")
    File.chmod!(Path.join(source, "safe/scripts/install.sh"), 0o700)
    git!(source, ["init", "--quiet"])
    git!(source, ["add", "."])

    git!(source, [
      "-c",
      "user.name=Loopex Test",
      "-c",
      "user.email=test@loopex.invalid",
      "commit",
      "--quiet",
      "-m",
      "fixture"
    ])

    commit = git!(source, ["rev-parse", "HEAD"])

    assert {:error, {:pack_already_installed, _detail}} =
             ResourcePacks.add(workspace, source,
               workspace_ref: "workspace:test",
               state_root: Path.join(root, "state"),
               rev: commit,
               path: "safe",
               git_executable: System.find_executable("git"),
               executor_authorization: {:host_policy, :allow}
             )

    assert File.read!(installed) =~ "Keep me."
    refute File.exists?(marker)
  end

  defp tmp_dir!(label) do
    path =
      Path.join(System.tmp_dir!(), "loopex-m3-#{label}-#{System.unique_integer([:positive])}")

    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end

  defp write!(path, contents) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
  end

  defp git!(root, args) do
    {output, status} = System.cmd("git", args, cd: root, stderr_to_stdout: true)
    assert status == 0, output
    String.trim(output)
  end
end
