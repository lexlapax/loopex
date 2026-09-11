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
    write!(Path.join(Path.dirname(skill), "README.md"), "Project skill catalog notes.\n")
    write!(Path.join(Path.dirname(skill), ".DS_Store"), <<0, 1, 2, 3>>)

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
    assert length(receipts) == 6
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

    {deadline_git, _deadline_release} =
      holding_git!(root, git, "deadline", deadline_started, deadline_escaped)

    deadline_clock = System.monotonic_time(:millisecond)

    deadline_task =
      Task.async(fn ->
        ResourcePacks.add(deadline_workspace, source,
          workspace_ref: "workspace:deadline",
          state_root: Path.join(root, "deadline-state"),
          rev: commit,
          path: "imported",
          git_executable: deadline_git,
          executor_authorization: {:host_policy, :allow},
          deadline_ms: 10_000
        )
      end)

    try do
      deadline_group =
        deadline_started
        |> await_task_file!(deadline_task)
        |> String.trim()
        |> String.to_integer()

      assert deadline_group > 1
      coordinator = import_coordinator!(deadline_task.pid)
      coordinator_monitor = Process.monitor(coordinator)

      try do
        refute process_group_empty?(deadline_group)

        # The held wrapper is never released. Either deadline owner may report first.
        # The watchdog allows 10s import, 5s cleanup and two existing 5s owner stops.
        result = Task.await(deadline_task, 25_000)
        elapsed = System.monotonic_time(:millisecond) - deadline_clock

        deadline_receipts =
          root
          |> Path.join("deadline-state")
          |> retained_executor_receipts()
          |> Enum.filter(fn receipt ->
            is_binary(receipt.job_id) and
              String.starts_with?(receipt.job_id, "resource-import-clone-")
          end)

        deadline_evidence =
          case result do
            {:error, {:git_failed, "resource import deadline reached"}} ->
              :coordinator_deadline

            {:error, {:executor_failed, detail}}
            when detail in [":cancelled", ":outcome_unknown"] ->
              outcome = if detail == ":cancelled", do: :cancelled, else: :outcome_unknown

              matched =
                Enum.any?(deadline_receipts, fn receipt ->
                  receipt.outcome == outcome and is_binary(receipt.output) and
                    String.contains?(receipt.output, "deadline passed")
                end)

              if matched, do: :executor_deadline, else: :missing_executor_deadline_receipt

            _ ->
              :unexpected_result_shape
          end

        receipt_summary =
          deadline_receipts
          |> Enum.take(4)
          |> Enum.map(fn receipt ->
            receipt
            |> Map.take([
              :outcome,
              :run_deadline_ms,
              :effective_deadline_ms,
              :cleanup_confirmation
            ])
            |> Map.put(
              :deadline_diagnostic,
              is_binary(receipt.output) and String.contains?(receipt.output, "deadline passed")
            )
          end)

        diagnostic =
          "deadline evidence=#{deadline_evidence}; elapsed_ms=#{elapsed}; " <>
            "result=#{inspect(result, limit: 8, printable_limit: 256)}; " <>
            "receipts=#{inspect(receipt_summary, limit: 64, printable_limit: 256)}"

        assert elapsed >= 10_000, diagnostic
        assert deadline_evidence in [:coordinator_deadline, :executor_deadline], diagnostic

        assert process_group_empty?(deadline_group)
        refute File.exists?(deadline_escaped)
        refute File.exists?(Path.join([deadline_workspace, ".agents", "skills", "imported"]))
        assert staging_paths(deadline_workspace) == []

        assert Path.wildcard(Path.join(root, "deadline-state/resource-packs/provenance/*.etf")) ==
                 []
      catch
        kind, reason ->
          stack = __STACKTRACE__
          Task.shutdown(deadline_task, :brutal_kill)

          cleaned =
            receive do
              {:DOWN, ^coordinator_monitor, :process, ^coordinator, _} ->
                process_group_empty?(deadline_group)
            after
              10_000 -> false
            end

          # Failure cleanup cannot supply the successful-path deadline proof.
          try do
            IO.puts(:stderr, "deadline failure teardown observed_group_empty=#{cleaned}")
          catch
            _, _ -> :ok
          end

          :erlang.raise(kind, reason, stack)
      after
        Process.demonitor(coordinator_monitor, [:flush])
      end
    after
      # Before readiness, only the exact caller is owned. Its coordinator observes
      # caller loss; never release the held script or signal a sampled OS group.
      if Process.alive?(deadline_task.pid), do: Task.shutdown(deadline_task, :brutal_kill)
    end

    write!(Path.join(source, "not-a-tree"), "ordinary blob\n")
    blob_commit = commit!(source)

    assert {:error, {:git_identity_mismatch, _detail}} =
             ResourcePacks.add(Path.join(root, "blob-workspace"), source,
               workspace_ref: "workspace:blob",
               state_root: Path.join(root, "blob-state"),
               rev: blob_commit,
               path: "not-a-tree",
               git_executable: git,
               executor_authorization: {:host_policy, :allow}
             )

    refute File.exists?(Path.join([root, "blob-workspace", ".agents", "skills", "not-a-tree"]))

    write!(Path.join(source, "too-large/SKILL.md"), skill("too-large"))
    write!(Path.join(source, "too-large/reference.txt"), :binary.copy("x", 65_537))
    oversized_commit = commit!(source)
    oversized_workspace = Path.join(root, "oversized-import-workspace")
    oversized_state = Path.join(root, "oversized-import-state")

    assert {:error, {:over_limit, _detail}} =
             ResourcePacks.add(oversized_workspace, source,
               workspace_ref: "workspace:oversized",
               state_root: oversized_state,
               rev: oversized_commit,
               path: "too-large",
               git_executable: git,
               executor_authorization: {:host_policy, :allow}
             )

    refute File.exists?(Path.join([oversized_workspace, ".agents", "skills", "too-large"]))

    assert Path.wildcard(Path.join(oversized_state, "resource-packs/provenance/*.etf")) == []

    collision_source = Path.join(root, "collision-source")
    collision_commit = commit_case_collision!(collision_source, root)
    collision_workspace = Path.join(root, "collision-import-workspace")

    assert {:error, {:unsupported_file, _detail}} =
             ResourcePacks.add(collision_workspace, collision_source,
               workspace_ref: "workspace:collision",
               state_root: Path.join(root, "collision-import-state"),
               rev: collision_commit,
               path: "collision",
               git_executable: git,
               executor_authorization: {:host_policy, :allow}
             )

    refute File.exists?(Path.join([collision_workspace, ".agents", "skills", "collision"]))
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
      " ssh://operator:#{secret}@example.invalid/repository",
      "\thttps://operator:#{secret}@example.invalid/repository",
      "ssh://operator%3A#{secret}@example.invalid/repository",
      "git://example.invalid/repository?token=#{secret}",
      "file:///tmp/repository##{secret}",
      "repository?token=#{secret}",
      "-upload-pack=#{secret}"
    ]

    Enum.each(sources, fn source ->
      assert {:error, {:unsupported_source, detail}} =
               ResourcePacks.add(workspace, source,
                 workspace_ref: "workspace:test",
                 state_root: state_root,
                 rev: String.duplicate("a", 40),
                 path: "skill",
                 git_executable: System.find_executable("git"),
                 executor_authorization: {:host_policy, :deny}
               )

      refute detail =~ secret
      refute detail =~ source
    end)

    assert retained_executor_receipts(state_root) == []
    assert staging_paths(workspace) == []

    for source <- [
          "ssh://git@example.invalid/repository",
          "ssh://example.invalid/repository",
          "git@example.invalid:repository"
        ] do
      assert {:error, {:executor_authorization_required, _detail}} =
               ResourcePacks.add(workspace, source,
                 workspace_ref: "workspace:test",
                 state_root: state_root,
                 rev: String.duplicate("a", 40),
                 path: "skill",
                 git_executable: System.find_executable("git"),
                 executor_authorization: {:host_policy, :deny}
               )
    end
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
    assert length(receipts) == 12
    assert receipts |> Enum.map(& &1.executor_identity) |> Enum.uniq() |> length() == 1
    assert receipts |> Enum.map(& &1.job_id) |> Enum.uniq() |> length() == 12
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

    for linked_component <- [".agents", ".agents/skills"] do
      linked_workspace = Path.join(root, "linked-" <> String.replace(linked_component, "/", "-"))

      linked_target =
        Path.join(root, "linked-target-" <> String.replace(linked_component, "/", "-"))

      write!(Path.join([linked_target, "unsafe", "SKILL.md"]), skill("unsafe"))

      link = Path.join(linked_workspace, linked_component)
      File.mkdir_p!(Path.dirname(link))
      File.ln_s!(linked_target, link)

      assert {:error, {:unsupported_file, _detail}} =
               ResourcePacks.discover(linked_workspace, workspace_ref: "workspace:test")
    end

    malformed_frontmatter = [
      "name: malformed\nname: malformed",
      "name: malformed\ndescription: |\n  first\ndescription: second",
      "name: malformed\ndescription: valid\nmetadata:\n  owner: first\n  owner: second",
      "name: malformed\ndescription: *description",
      "name: malformed\ndescription: &description anchored",
      "name: malformed\ndescription: !text tagged",
      "name: malformed\ndescription: ${RUN_ME}",
      "name: malformed\ndescription: $(run-me)",
      "name: malformed\ndescription: {nested: object}",
      "name: malformed\ndescription: valid\nmetadata:\n    nested: object",
      "name: malformed\ndescription: valid\nlicense: true",
      "name: malformed\ndescription: valid\ncompatibility:\n  nested: object"
    ]

    Enum.with_index(malformed_frontmatter, fn frontmatter, index ->
      malformed_workspace = Path.join(root, "malformed-#{index}")

      write!(
        Path.join([malformed_workspace, ".agents", "skills", "malformed", "SKILL.md"]),
        "---\n#{frontmatter}\n---\nBody\n"
      )

      assert {:error, {reason, detail}} =
               ResourcePacks.discover(malformed_workspace, workspace_ref: "workspace:test")

      assert reason in [:invalid_frontmatter, :unsupported_frontmatter]
      assert is_binary(detail) and byte_size(detail) <= 1_024
    end)

    text_workspace = Path.join(root, "text-workspace")
    text_skill = Path.join([text_workspace, ".agents", "skills", "large-text"])
    write!(Path.join(text_skill, "SKILL.md"), skill("large-text"))
    write!(Path.join(text_skill, "reference.txt"), :binary.copy("x", 65_537))

    assert {:error, {:over_limit, _detail}} =
             ResourcePacks.discover(text_workspace, workspace_ref: "workspace:test")

    supported_workspace = Path.join(root, "supported-workspace")

    write!(
      Path.join([supported_workspace, ".agents", "skills", "supported", "SKILL.md"]),
      """
      ---
      name: supported
      description: |
        Supported literal description.
      license: 'MIT'
      compatibility: >
        OTP 28
        Elixir 1.20
      metadata:
        owner: project
      disable-model-invocation: true
      ---
      Body.
      """
    )

    assert {:ok, %{"packs" => [supported]}} =
             ResourcePacks.discover(supported_workspace, workspace_ref: "workspace:test")

    assert supported["description"] == "Supported literal description."
    assert supported["manual_only"]

    invalid_utf8_workspace = Path.join(root, "invalid-utf8-workspace")

    write!(
      Path.join([invalid_utf8_workspace, ".agents", "skills", "invalid-utf8", "SKILL.md"]),
      "---\nname: invalid-utf8\ndescription: " <> <<255>> <> "\n---\nBody\n"
    )

    assert {:error, {:invalid_frontmatter, _detail}} =
             ResourcePacks.discover(invalid_utf8_workspace, workspace_ref: "workspace:test")

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

    linked_workspace = Path.join(root, "linked-publish-workspace")
    linked_target = Path.join(root, "linked-publish-target")
    File.mkdir_p!(linked_workspace)
    File.mkdir_p!(linked_target)
    File.ln_s!(linked_target, Path.join(linked_workspace, ".agents"))

    assert {:error, {:unsupported_file, _detail}} =
             ResourcePacks.add(linked_workspace, source,
               workspace_ref: "workspace:linked",
               state_root: Path.join(root, "linked-state"),
               rev: commit,
               path: "safe",
               git_executable: System.find_executable("git"),
               executor_authorization: {:host_policy, :allow}
             )

    refute File.exists?(Path.join([linked_target, "skills", "safe"]))

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

    {cancel_git, cancel_release} =
      holding_git!(
        root,
        System.find_executable("git"),
        "cancel",
        cancel_started,
        cancel_escaped
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

    group = cancel_started |> await_task_file!(task) |> String.trim() |> String.to_integer()
    refute process_group_empty?(group)
    coordinator = import_coordinator!(task.pid)
    coordinator_monitor = Process.monitor(coordinator)
    Task.shutdown(task, :brutal_kill)
    assert_receive {:DOWN, ^coordinator_monitor, :process, ^coordinator, :normal}, 10_000

    assert process_group_empty?(group)
    File.write!(cancel_release, "release")
    refute File.exists?(cancel_escaped)
    assert File.read!(installed) =~ "Keep me."
    assert staging_paths(workspace) == []
    assert Path.wildcard(Path.join(cancel_state, "resource-packs/provenance/*.etf")) == []

    assert File.regular?(Path.join(cancel_state, "resource-packs/receipts/generation"))
    assert Path.wildcard(Path.join(cancel_state, "resource-packs/receipts/open/*")) == []

    assert_cancellation_before_next_job(root, workspace, source, commit, installed)
  end

  defp assert_cancellation_before_next_job(root, workspace, source, commit, installed) do
    started = Path.join(root, "adoption-started")
    release = Path.join(root, "adoption-release")
    next_job = Path.join(root, "adoption-next-job")
    state_root = Path.join(root, "adoption-state")
    git = Path.join(root, "git-adoption")
    real_git = System.find_executable("git") || flunk("git is required")

    File.write!(git, """
    #!/bin/sh
    for argument in "$@"; do
      if [ "$argument" = clone ]; then
        "#{real_git}" "$@" || exit "$?"
        printf started >"#{started}"
        while [ ! -f "#{release}" ]; do /bin/sleep 0.01; done
        exit 0
      fi
    done
    printf started >"#{next_job}"
    exec "#{real_git}" "$@"
    """)

    File.chmod!(git, 0o700)

    task =
      Task.async(fn ->
        ResourcePacks.add(workspace, source,
          workspace_ref: "workspace:test",
          state_root: state_root,
          rev: commit,
          path: "safe",
          git_executable: git,
          executor_authorization: {:host_policy, :allow},
          deadline_ms: 10_000
        )
      end)

    await_task_file!(started, task)
    coordinator = import_coordinator!(task.pid)
    monitor = Process.monitor(coordinator)
    true = :erlang.suspend_process(coordinator)

    try do
      File.write!(release, "continue")
      await_adoption_wait!(coordinator)
      refute File.exists?(next_job)
    after
      Task.shutdown(task, :brutal_kill)
      true = :erlang.resume_process(coordinator)
    end

    assert_receive {:DOWN, ^monitor, :process, ^coordinator, :normal}, 10_000
    refute File.exists?(next_job)
    assert File.read!(installed) =~ "Keep me."
    assert staging_paths(workspace) == []
    assert length(retained_executor_receipts(state_root)) == 1
    assert Path.wildcard(Path.join(state_root, "resource-packs/provenance/*.etf")) == []
  end

  defp await_adoption_wait!(coordinator, remaining \\ 200)
  defp await_adoption_wait!(_coordinator, 0), do: flunk("Git worker did not await job adoption")

  defp await_adoption_wait!(coordinator, remaining) do
    {:messages, messages} = Process.info(coordinator, :messages)

    waiting? =
      Enum.any?(messages, fn
        {_tag, :job_ready, worker, job_id} when is_pid(worker) and is_binary(job_id) ->
          String.starts_with?(job_id, "resource-import-commit-") and
            Process.info(worker, :current_function) ==
              {:current_function, {ResourcePacks, :adopt_import_job, 2}} and
            Process.info(worker, :status) == {:status, :waiting}

        _other ->
          false
      end)

    if waiting? do
      :ok
    else
      Process.sleep(10)
      await_adoption_wait!(coordinator, remaining - 1)
    end
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

  defp commit_case_collision!(source, root) do
    write!(Path.join(source, "collision/SKILL.md"), skill("collision"))
    first = Path.join(root, "collision-first")
    second = Path.join(root, "collision-second")
    write!(first, "first\n")
    write!(second, "second\n")
    git!(source, ["init", "--quiet"])
    git!(source, ["add", "collision/SKILL.md"])
    first_object = git!(source, ["hash-object", "-w", first])
    second_object = git!(source, ["hash-object", "-w", second])

    git!(source, [
      "update-index",
      "--add",
      "--cacheinfo",
      "100644,#{first_object},collision/A.txt"
    ])

    git!(source, [
      "update-index",
      "--add",
      "--cacheinfo",
      "100644,#{second_object},collision/a.txt"
    ])

    git!(source, [
      "-c",
      "user.name=Loopex Test",
      "-c",
      "user.email=test@loopex.invalid",
      "commit",
      "--quiet",
      "-m",
      "case collision fixture"
    ])

    git!(source, ["rev-parse", "HEAD"])
  end

  defp holding_git!(root, real_git, label, started, escaped) do
    path = Path.join(root, "git-#{label}")
    release = Path.join(root, "git-#{label}-release")

    File.write!(path, """
    #!/bin/sh
    /bin/ps -o pgid= -p "$$" >#{started}
    while [ ! -f "#{release}" ]; do /bin/sleep 0.01; done
    printf escaped >#{escaped}
    exec #{real_git} "$@"
    """)

    File.chmod!(path, 0o700)
    {path, release}
  end

  # Concept: cancellation starts after observed Git readiness.
  # Technical depth: the import's existing deadline bounds this wait. A completed
  # import without its start marker fails with the actual result.
  defp await_task_file!(path, task) do
    case File.read(path) do
      {:ok, content} when byte_size(content) > 0 ->
        content

      {:error, reason} when reason != :enoent ->
        flunk("could not read Git start marker: #{inspect(reason)}")

      _not_yet_published ->
        case Task.yield(task, 10) do
          nil -> await_task_file!(path, task)
          result -> flunk("import ended before Git signalled readiness: #{inspect(result)}")
        end
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
