defmodule LoopexCli.M7EvidenceTaskTest do
  use ExUnit.Case, async: false

  # Concept: the validator both check commands run refuses unavailable M7
  # evidence instead of passing it. Technical depth: each case copies the
  # pinned fixture catalog into its own root outside the repository; the Mix
  # shell is process-global, so this file runs alone.

  alias Mix.Tasks.Loopex.M7Evidence, as: Task

  @repository Path.expand("../../..", __DIR__)
  @a String.duplicate("a", 64)
  @b String.duplicate("b", 64)

  setup do
    root = Path.join(System.tmp_dir!(), "m7-evidence-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "docs/plans"))
    File.mkdir_p!(Path.join(root, "test/fixtures"))
    File.cp_r!(Path.join(@repository, "test/fixtures/m7"), Path.join(root, "test/fixtures/m7"))
    # Test owners and the legacy release family are read from the real tree.
    File.ln_s!(Path.join(@repository, "apps"), Path.join(root, "apps"))
    File.mkdir_p!(Path.join(root, "scripts"))
    File.mkdir_p!(Path.join(root, "docs/operator"))
    File.mkdir_p!(Path.join(root, "docs/evidence"))

    File.cp!(
      Path.join(@repository, "docs/evidence/M7-closure-runs.md"),
      Path.join(root, "docs/evidence/M7-closure-runs.md")
    )

    File.cp!(
      Path.join(@repository, "docs/operator/m7-validation.md"),
      Path.join(root, "docs/operator/m7-validation.md")
    )

    File.cp!(
      Path.join(@repository, "scripts/check-release.sh"),
      Path.join(root, "scripts/check-release.sh")
    )

    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  test "the current tree passes the fast validation" do
    assert {:ok, ["committed heads: " <> _, "fixture catalog " <> _, families, pending]} =
             Task.validate(@repository, [])

    assert families =~ "11 legacy release cases" and families =~ "108 operator step keys"
    assert pending =~ "pending:"
  end

  test "each campaign's greatest committed head is selected regardless of order", %{root: root} do
    concept!(root, [
      "Progress",
      "index-head: m7-a 2 #{@a}",
      "index-head: m7-b 7 #{@b}",
      "index-head: m7-a 9 #{@b}",
      "index-head: m7-a 2 #{@a}"
    ])

    assert {:ok, ["committed heads: m7-a 9, m7-b 7" | _]} = Task.validate(root, [])
  end

  test "malformed or conflicting committed heads refuse", %{root: root} do
    for {lines, reason} <- [
          {["index-head: m7-a 2 #{@a}", "index-head: m7-a 2 #{@b}"],
           :conflicting_committed_attempt_heads},
          {[" index-head: m7-a 2 #{@a}"], :invalid_committed_attempt_head_line},
          {["index-head: m7-a 02 #{@a}"], :invalid_committed_attempt_head_line},
          {["index-head: m7-a 2 #{String.upcase(@a)}"], :invalid_committed_attempt_head_line},
          {["index-head: m7-a 2 #{@a} extra"], :invalid_committed_attempt_head_line},
          {["index-head:"], :invalid_committed_attempt_head_line}
        ] do
      concept!(root, lines)
      assert Task.validate(root, []) == {:error, reason}
    end
  end

  test "a missing concept or a changed fixture oracle is unavailable evidence", %{root: root} do
    assert Task.validate(root, []) == {:error, :m7_concept_unavailable}
    concept!(root, [])
    File.write!(Path.join(root, "test/fixtures/m7/repair/oracle.exs"), "changed\n")
    assert Task.validate(root, []) == {:error, :fixture_manifest_unavailable}
  end

  test "release lanes need a retained index outside the checkout and a pinned manifest",
       %{root: root} do
    concept!(root, [])

    for {opts, reason} <- [
          {[lane: "m7-operator", lane: "m7-provider", lane: "m7-rollback"],
           :attempts_index_required},
          {[lane: "m7-provider"], :attempts_index_required},
          {[lane: "m7-rollback", resume_matrix: "matrix-1"], :attempts_index_required},
          {[lane: "m7-rollback"], {:m7_cases_pending, ["m7.rollback"]}},
          {[attempts_index: "relative/index", lane: "m7-provider"],
           :attempts_index_must_be_absolute},
          {[attempts_index: Path.join(root, "index"), lane: "m7-provider"],
           :attempts_index_inside_checkout},
          {[attempts_index: "/retained/index", lane: "m7-operator"], :unknown_m7_lane},
          {[attempts_index: "/retained/index"], :unknown_m7_lane}
        ] do
      assert Task.validate(root, [release: true] ++ opts) == {:error, reason}
    end

    index = [attempts_index: "/retained/index"]

    assert {:error, {:m7_cases_pending, provider}} =
             Task.validate(root, [release: true, lane: "m7-provider"] ++ index)

    assert "m7.pipe-answer" in provider

    assert {:error, {:m7_cases_pending, all}} =
             Task.validate(
               root,
               [release: true, lane: "m7-operator", lane: "m7-provider", lane: "m7-rollback"] ++
                 index
             )

    assert "m7.repair" not in all and "m7.external" not in all and "m7.review" in all
  end

  test "the operator runbook must show exactly the committed step and case ownership",
       %{root: root} do
    concept!(root, [])
    runbook = Path.join(root, "docs/operator/m7-validation.md")
    original = File.read!(runbook)
    assert {:ok, _} = Task.validate(root, [])

    for changed <- [
          String.replace(original, "| `V9.5` | automated |", "| `V9.5` | attended |"),
          String.replace(original, "`ready` |", "`pending:x` |"),
          String.replace(original, "| `V1.1` |", "| `V1.0` |")
        ] do
      refute changed == original
      File.write!(runbook, changed)
      assert Task.validate(root, []) == {:error, :m7_runbook_stale}
    end
  end

  test "the closure scaffold must reserve a row for every committed key", %{root: root} do
    concept!(root, [])
    scaffold = Path.join(root, "docs/evidence/M7-closure-runs.md")
    original = File.read!(scaffold)

    for key <- ["| `V9.5` |", "| `m7.repair` |"] do
      File.write!(scaffold, String.replace(original, key, "| `renamed` |"))
      assert Task.validate(root, []) == {:error, :m7_closure_rows_missing}
    end

    File.rm!(scaffold)
    assert Task.validate(root, []) == {:error, :m7_closure_rows_missing}
  end

  test "the legacy release family must keep its eleven literal cases", %{root: root} do
    concept!(root, [])
    script = Path.join(root, "scripts/check-release.sh")
    original = File.read!(script)

    File.write!(
      script,
      String.replace(
        original,
        "loopex_cli|test/ask_real_test.exs|",
        "loopex_cli|test/absent_test.exs|"
      )
    )

    assert Task.validate(root, []) == {:error, :legacy_release_family_invalid}

    File.write!(
      script,
      String.replace(
        original,
        "<<'EOF'\nloopex_cli|test/foundation",
        "<<'EOF'\nloopex_cli|test/foundation"
      )
    )

    assert {:ok, _} = Task.validate(root, [])
    File.rm!(script)
    assert Task.validate(root, []) == {:error, :legacy_release_family_invalid}
  end

  test "the command reports unavailable evidence with exit status two", %{root: root} do
    concept!(root, [])
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
    Task.run(["--root", root])
    assert_received {:mix_shell, :info, ["m7-evidence: committed heads: none"]}

    assert catch_exit(
             Task.run([
               "--root",
               root,
               "--release",
               "--attempts-index",
               "/retained/index",
               "--lane",
               "m7-rollback"
             ])
           ) == {:shutdown, 2}

    assert_received {:mix_shell, :error,
                     ["m7-evidence: evidence unavailable: m7_cases_pending m7.rollback"]}
  end

  defp concept!(root, lines),
    do: File.write!(Path.join(root, "docs/plans/M7.md"), Enum.join(lines, "\n") <> "\n")
end
