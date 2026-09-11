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

    [first_retain, second_retain] =
      1..2
      |> Enum.map(fn _index ->
        Task.async(fn -> ResourcePacks.retain(manifest, state_root) end)
      end)
      |> Enum.map(&Task.await(&1, 5_000))

    assert {:ok, digest} = first_retain
    assert second_retain == {:ok, digest}
    assert {:ok, ^manifest} = ResourcePacks.load(state_root, digest)
    assert retention_temporaries(state_root) == []
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
    assert Enum.map(pack["files"], & &1["label"]) == ["SKILL.md", "scripts/install.sh"]

    assert Enum.all?(pack["files"], fn file ->
             expected = File.read!(Path.join([source, "imported", file["label"]]))

             file["content"] == expected and file["size"] == byte_size(expected) and
               file["digest"] == LoopexProtocol.Canonical.digest_bytes(expected)
           end)

    refute File.exists?(marker)

    receipts = retained_executor_receipts(state_root)
    assert length(receipts) == 4
    assert Enum.all?(receipts, &(&1.tool_id == "loopex.bash"))
    assert Enum.all?(receipts, &(&1.outcome == :completed))
    assert Enum.all?(receipts, &(&1.child_environment_names == ["PATH"]))
    refute Enum.any?(receipts, & &1.provider_credential_present)
    assert retention_temporaries(state_root) == []

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
      Path.join([workspace, ".agents", "skills", "imported", "scripts/install.sh"]),
      "#!/bin/sh\nprintf changed\n"
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

    deadline_workspace = Path.join(root, "deadline-workspace")
    deadline_started = Path.join(root, "deadline-started")
    deadline_escaped = Path.join(root, "deadline-escaped")

    deadline_git =
      delaying_git!(root, git, "deadline", deadline_started, deadline_escaped, 2)

    assert {:error, {_reason, _detail}} =
             ResourcePacks.add(deadline_workspace, source,
               workspace_ref: "workspace:deadline",
               state_root: Path.join(root, "deadline-state"),
               rev: commit,
               path: "imported",
               git_executable: deadline_git,
               executor_authorization: {:host_policy, :allow},
               deadline_ms: 750
             )

    deadline_group = deadline_started |> await_file!() |> String.trim() |> String.to_integer()
    assert process_group_empty?(deadline_group)
    refute File.exists?(deadline_escaped)
    refute File.exists?(Path.join([deadline_workspace, ".agents", "skills", "imported"]))
    assert staging_paths(deadline_workspace) == []

    assert Path.wildcard(Path.join(root, "deadline-state/resource-packs/provenance/*.etf")) ==
             []
  end

  test "credential-bearing source forms refuse before Git or retention" do
    root = tmp_dir!("source-credentials")
    workspace = Path.join(root, "workspace")
    state_root = Path.join(root, "state")
    secret = "audit-secret-value"

    sources = [
      "http://operator:#{secret}@example.invalid/repository",
      "https://operator:#{secret}@example.invalid/repository",
      "ssh://operator:#{secret}@example.invalid/repository",
      "git://example.invalid/repository?token=#{secret}",
      "file:///tmp/repository##{secret}",
      "repository?token=#{secret}"
    ]

    Enum.each(sources, fn source ->
      assert {:error, {:unsupported_source, detail}} =
               ResourcePacks.add(workspace, source,
                 workspace_ref: "workspace:test",
                 state_root: state_root,
                 rev: String.duplicate("a", 40),
                 path: "skill",
                 git_executable: System.find_executable("git"),
                 executor_authorization: {:host_policy, :allow}
               )

      refute detail =~ secret
      refute detail =~ source
    end)

    assert retained_executor_receipts(state_root) == []
    assert staging_paths(workspace) == []
  end

  test "one retained executor generation accepts repeated distinct imports" do
    root = tmp_dir!("repeated-import")
    workspace = Path.join(root, "workspace")
    state_root = Path.join(root, "state")
    git = System.find_executable("git") || flunk("git is required for this test")

    Enum.each(["first", "second"], fn name ->
      source = Path.join(root, "source-#{name}")
      write!(Path.join(source, "#{name}/SKILL.md"), skill(name))
      commit = commit!(source)

      assert {:ok, %{"name" => ^name}} =
               ResourcePacks.add(workspace, source,
                 workspace_ref: "workspace:test",
                 state_root: state_root,
                 rev: commit,
                 path: name,
                 git_executable: git,
                 executor_authorization: {:host_policy, :allow}
               )
    end)

    receipts = retained_executor_receipts(state_root)
    assert length(receipts) == 8
    assert receipts |> Enum.map(& &1.executor_identity) |> Enum.uniq() |> length() == 1
    assert receipts |> Enum.map(& &1.job_id) |> Enum.uniq() |> length() == 8
    assert retention_temporaries(state_root) == []
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

    cancel_started = Path.join(root, "cancel-started")
    cancel_escaped = Path.join(root, "cancel-escaped")

    cancel_git =
      delaying_git!(
        root,
        System.find_executable("git"),
        "cancel",
        cancel_started,
        cancel_escaped,
        5
      )

    cancel_state = Path.join(root, "cancel-state")

    task =
      Task.async(fn ->
        ResourcePacks.add(workspace, source,
          workspace_ref: "workspace:test",
          state_root: cancel_state,
          rev: commit,
          path: "safe",
          git_executable: cancel_git,
          executor_authorization: {:host_policy, :allow},
          deadline_ms: 10_000
        )
      end)

    group = cancel_started |> await_file!() |> String.trim() |> String.to_integer()
    refute process_group_empty?(group)
    coordinator = import_coordinator!(task.pid)
    coordinator_monitor = Process.monitor(coordinator)
    Task.shutdown(task, :brutal_kill)
    assert_receive {:DOWN, ^coordinator_monitor, :process, ^coordinator, :normal}, 10_000

    assert process_group_empty?(group)
    refute File.exists?(cancel_escaped)
    assert File.read!(installed) =~ "Keep me."
    assert staging_paths(workspace) == []
    assert Path.wildcard(Path.join(cancel_state, "resource-packs/provenance/*.etf")) == []

    assert File.regular?(Path.join(cancel_state, "resource-packs/receipts/generation"))
    assert Path.wildcard(Path.join(cancel_state, "resource-packs/receipts/open/*")) == []
  end

  defp tmp_dir!(label) do
    nonce = Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)
    path = Path.join(System.tmp_dir!(), "loopex-m3-#{label}-#{nonce}")

    case File.mkdir(path) do
      :ok ->
        on_exit(fn -> File.rm_rf!(path) end)
        path

      {:error, :eexist} ->
        tmp_dir!(label)

      {:error, reason} ->
        raise File.Error, reason: reason, action: "make test directory", path: path
    end
  end

  defp write!(path, contents) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
  end

  defp skill(name), do: "---\nname: #{name}\ndescription: #{name} skill.\n---\nBody.\n"

  defp commit!(source) do
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

    git!(source, ["rev-parse", "HEAD"])
  end

  defp delaying_git!(root, real_git, label, started, escaped, seconds) do
    path = Path.join(root, "git-#{label}")

    File.write!(path, """
    #!/bin/sh
    /bin/ps -o pgid= -p "$$" >#{started}
    /bin/sleep #{seconds}
    printf escaped >#{escaped}
    exec #{real_git} "$@"
    """)

    File.chmod!(path, 0o700)
    path
  end

  defp await_file!(path, remaining \\ 200)
  defp await_file!(_path, 0), do: flunk("delayed Git did not start")

  defp await_file!(path, remaining) do
    if File.exists?(path) do
      File.read!(path)
    else
      Process.sleep(10)
      await_file!(path, remaining - 1)
    end
  end

  defp import_coordinator!(caller) do
    reciprocal =
      caller
      |> Process.info(:monitors)
      |> elem(1)
      |> Enum.flat_map(fn
        {:process, pid} ->
          case Process.info(pid, :monitors) do
            {:monitors, monitors} ->
              if Enum.member?(monitors, {:process, caller}), do: [pid], else: []

            _other ->
              []
          end

        _other ->
          []
      end)

    case reciprocal do
      [coordinator] -> coordinator
      other -> flunk("expected one live import coordinator, got: #{inspect(other)}")
    end
  end

  defp process_group_empty?(group) when is_integer(group) do
    case System.cmd("/bin/ps", ["-e", "-o", "pid=", "-o", "pgid="], stderr_to_stdout: true) do
      {output, 0} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.all?(fn line ->
          case String.split(line) do
            [_pid, row_group] -> row_group != Integer.to_string(group)
            _malformed -> false
          end
        end)

      {_output, _status} ->
        false
    end
  end

  defp staging_paths(workspace) do
    case File.ls(Path.join(workspace, ".agents")) do
      {:ok, entries} -> Enum.filter(entries, &String.starts_with?(&1, ".loopex-import-"))
      {:error, :enoent} -> []
    end
  end

  defp retained_executor_receipts(state_root) do
    state_root
    |> Path.join("resource-packs/receipts/**/*")
    |> Path.wildcard()
    |> Enum.filter(&File.regular?/1)
    |> Enum.flat_map(fn path ->
      case File.read(path) do
        {:ok, bytes} ->
          try do
            case :erlang.binary_to_term(bytes, [:safe]) do
              %{tool_id: "loopex.bash", outcome: _outcome} = receipt -> [receipt]
              _other -> []
            end
          rescue
            ArgumentError -> []
          end

        {:error, _reason} ->
          []
      end
    end)
  end

  defp retention_temporaries(state_root) do
    Path.wildcard(Path.join(state_root, "resource-packs/**/*.tmp-*"))
  end

  defp git!(root, args) do
    {output, status} = System.cmd("git", args, cd: root, stderr_to_stdout: true)
    assert status == 0, output
    String.trim(output)
  end
end
