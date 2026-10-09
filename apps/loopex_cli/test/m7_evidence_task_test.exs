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
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  test "the current tree passes the fast validation" do
    assert {:ok, ["committed heads: " <> _, "fixture catalog " <> _]} =
             Task.validate(@repository, [])
  end

  test "each campaign's greatest committed head is selected regardless of order", %{root: root} do
    concept!(root, [
      "Progress",
      "index-head: m7-a 2 #{@a}",
      "index-head: m7-b 7 #{@b}",
      "index-head: m7-a 9 #{@b}",
      "index-head: m7-a 2 #{@a}"
    ])

    assert {:ok, ["committed heads: m7-a 9, m7-b 7", _]} = Task.validate(root, [])
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
          {[], :attempts_index_required},
          {[lane: "m7-provider"], :attempts_index_required},
          {[lane: "m7-rollback", resume_matrix: "matrix-1"], :attempts_index_required},
          {[lane: "m7-rollback"], :m7_execution_manifest_pending},
          {[attempts_index: "relative/index"], :attempts_index_must_be_absolute},
          {[attempts_index: Path.join(root, "index")], :attempts_index_inside_checkout},
          {[attempts_index: "/retained/index", lane: "m7-operator"], :unknown_m7_lane},
          {[attempts_index: "/retained/index", lane: "m7-provider"],
           :m7_execution_manifest_pending},
          {[attempts_index: "/retained/index"], :m7_execution_manifest_pending}
        ] do
      assert Task.validate(root, [release: true] ++ opts) == {:error, reason}
    end
  end

  test "the command reports unavailable evidence with exit status two", %{root: root} do
    concept!(root, [])
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
    Task.run(["--root", root])
    assert_received {:mix_shell, :info, ["m7-evidence: committed heads: none"]}

    assert catch_exit(
             Task.run(["--root", root, "--release", "--attempts-index", "/retained/index"])
           ) == {:shutdown, 2}

    assert_received {:mix_shell, :error,
                     ["m7-evidence: evidence unavailable: m7_execution_manifest_pending"]}
  end

  defp concept!(root, lines),
    do: File.write!(Path.join(root, "docs/plans/M7.md"), Enum.join(lines, "\n") <> "\n")
end
