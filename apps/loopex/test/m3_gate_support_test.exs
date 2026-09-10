Code.require_file("../../../scripts/m3-gate-support.exs", __DIR__)

defmodule Loopex.M3GateSupportTest do
  use ExUnit.Case, async: true
  alias Loopex.M3Gate.Support

  test "checkpoint routing selects all outcomes for unknown and shared paths" do
    assert Support.select_outcomes(["apps/loopex_composition/test/skill_acquisition_test.exs"]) ==
             [1]

    assert Support.select_outcomes(["apps/loopex_composition/lib/importer.ex"]) == [1, 2, 3, 4, 5]

    assert Support.select_outcomes(["apps/loopex_composition/lib/loopex_composition.ex"]) == [
             1,
             2,
             3,
             4,
             5
           ]

    assert Support.select_outcomes(["apps/loopex_cli/test/foundation_workflow_test.exs"]) == [3]

    assert Support.select_outcomes(["apps/loopex/lib/loopex/runtime/context_admission.ex"]) == [
             1,
             2,
             3,
             4,
             5
           ]

    assert Support.select_outcomes(["config/config.exs"]) == [1, 2, 3, 4, 5]

    assert Support.select_outcomes(["apps/loopex/lib/loopex/runtime/session_state.ex"]) == [
             1,
             2,
             3,
             4,
             5
           ]

    assert Support.select_outcomes(["new-unclassified-file"]) == [1, 2, 3, 4, 5]
    assert Support.select_outcomes([]) == []
  end

  test "closed gate prefix excludes the caller and future milestones" do
    register =
      register([
        {"M0", "Closed"},
        {"M1", "Closed"},
        {"M2", "Closed"},
        {"M3", "Closed"},
        {"M4", "Open"}
      ])

    assert Support.closed_prefix(register, "M3") == ["M0", "M1", "M2"]
    assert Support.closed_prefix(register, "M4") == ["M0", "M1", "M2", "M3"]
    assert Support.closed_prefix(register, :all) == ["M0", "M1", "M2", "M3"]
    assert_raise ArgumentError, fn -> Support.closed_prefix(register, "unknown") end

    assert_raise ArgumentError, fn ->
      Support.closed_prefix(register([{"M0", "Open"}, {"M3", "Open"}]), "M3")
    end
  end

  test "closed gate inventory refuses omitted and failed invocation records" do
    assert Support.verify_invocations(["M0", "M1"], [{"M0", 0}, {"M1", 0}]) == :ok

    for records <- [
          [{"M0", 0}],
          [{"M0", 0}, {"M1", 1}],
          [{"M0", 0}, {"M1", 2}],
          [{"M1", 0}, {"M0", 0}],
          [{"M0", 0}, {"M0", 0}]
        ] do
      assert_raise ArgumentError, fn -> Support.verify_invocations(["M0", "M1"], records) end
    end

    assert_raise ArgumentError, fn ->
      Support.gate_command("M3", "```text\nbash scripts/check-m2-gate.sh\n```\n")
    end

    assert_raise ArgumentError, fn ->
      Support.no_bootstrap_backedge!("bash scripts/check-closed-gates.sh\n")
    end

    assert Support.no_bootstrap_backedge!("bash scripts/check-status.sh\n") == :ok
  end

  test "gate commands preserve privileged M1 and reject ambiguous executable forms" do
    assert Support.gate_command("M1", "```text\n/bin/bash -p scripts/check-m1-gate.sh\n```\n") ==
             ["/bin/bash", "-p", "scripts/check-m1-gate.sh"]

    assert_raise ArgumentError, fn ->
      Support.gate_command("M1", "```text\nbash scripts/check-m1-gate.sh\n```\n")
    end

    assert_raise ArgumentError, fn ->
      Support.gate_command("M0", "```text\nbash scripts/check-m0-gate.sh; echo ok\n```\n")
    end
  end

  test "actual aggregate runs the predecessor prefix and propagates a failed gate" do
    root = fixture_root()
    {output, 0} = aggregate(root)
    assert output =~ "LOOPEX_CLOSED_GATES_REPORT caller=M3 complete=true"
    assert File.read!(Path.join(root, "calls")) == "M0\nM1\nM2\n"
    File.write!(Path.join(root, "calls"), "")

    File.write!(
      Path.join(root, "scripts/check-m1-gate.sh"),
      "#!/bin/bash\nprintf 'M1\\n' >> \"$TRACE_FILE\"\nexit 7\n"
    )

    {output, 7} = aggregate(root)
    assert output =~ "Closed gate failed: M1 exit=7"
    assert File.read!(Path.join(root, "calls")) == "M0\nM1\n"
    File.rm!(Path.join(root, "scripts/check-m2-gate.sh"))
    {output, 2} = aggregate(root)
    assert output =~ "closed gate runner absent: M2"
  end

  test "unavailable comparison commits never become an empty change set" do
    root = Path.expand("../../..", __DIR__)
    assert_raise ArgumentError, fn -> Support.changed_paths(root, "HEAD") end
    assert_raise ArgumentError, fn -> Support.changed_paths(root, String.duplicate("0", 40)) end
  end

  test "unknown future gate credential protocols refuse before any invocation" do
    root = fixture_root()

    File.write!(
      Path.join(root, "docs/plans/README.md"),
      register([{"M0", "Closed"}, {"M9", "Closed"}, {"M3", "Open"}])
    )

    File.write!(
      Path.join(root, "docs/plans/M9-gate.md"),
      "```text\nbash scripts/check-m9-gate.sh\n```\n"
    )

    File.write!(
      Path.join(root, "scripts/check-m9-gate.sh"),
      "#!/bin/bash\nprintf 'M9\\n' >> \"$TRACE_FILE\"\n"
    )

    {output, 2} =
      System.cmd(
        "bash",
        [
          "-c",
          "printf 'LOOPEX_M3_PROVIDER_V1\\0synthetic-key\\0' | bash scripts/check-closed-gates.sh --before M3"
        ],
        cd: root,
        env: [{"TRACE_FILE", Path.join(root, "calls")}, {"LOOPEX_PROVIDER_API_KEY", nil}],
        stderr_to_stdout: true
      )

    assert output =~ "credential protocol is undeclared for M9"
    refute output =~ "synthetic-key"
    refute File.exists?(Path.join(root, "calls"))
    {_, 0} = aggregate(root)
    assert File.read!(Path.join(root, "calls")) == "M0\nM9\n"
  end

  test "register names preserve historical version slugs and reject case collisions" do
    assert Support.closed_prefix(
             register([{"0.1.0", "Closed"}, {"v0.2", "Closed"}, {"M3", "Open"}]),
             "M3"
           ) == ["0.1.0", "v0.2"]

    assert_raise ArgumentError, fn ->
      Support.closed_prefix(register([{"M1", "Closed"}, {"m1", "Closed"}, {"M3", "Open"}]), "M3")
    end

    for invalid <- ["UPPER", "-start", "end-", "1..2", "seed", "next-gate", "next-technical"] do
      assert_raise ArgumentError, fn ->
        Support.closed_prefix(register([{invalid, "Closed"}, {"M3", "Open"}]), "M3")
      end
    end
  end

  test "authoritative reports reject missing duplicate mismatched and malformed evidence" do
    nonce = String.duplicate("a", 32)
    path = "apps/loopex/test/m3_gate_support_test.exs"

    report =
      "LOOPEX_EXUNIT_REPORT nonce=#{nonce} selector=#{path} seed=3107 executed=3 digest=sha256:#{String.duplicate("b", 64)}"

    assert Support.verify_report(report, nonce, path, 3, false) == :ok

    for invalid <- [
          "",
          report <> "\n" <> report,
          String.replace(report, nonce, String.duplicate("c", 32)),
          report <> " nonce=#{nonce}",
          String.replace(report, "executed=3", "executed=2"),
          String.replace(report, "seed=3107", "seed=0"),
          String.replace(report, "digest=sha256:", "digest=bad:")
        ] do
      assert_raise ArgumentError, fn -> Support.verify_report(invalid, nonce, path, 3, false) end
    end

    real =
      report <>
        " provider=fixture model=fixture:v1 endpoint=in-process adapter_build=loopex_llm_reqllm@0.0.0 executor_build=loopex_executor_local@0.0.0 executor_identity=local tool_identity=loopex.write recorded=2026-09-10T00:00:00Z"

    assert Support.verify_report(real, nonce, path, 3, true) == :ok

    for invalid <- [
          report,
          String.replace(real, "model=fixture:v1", "model=unknown"),
          String.replace(real, "adapter_build=loopex_llm_reqllm@0.0.0", "adapter_build=other"),
          String.replace(real, "recorded=2026-09-10T00:00:00Z", "recorded=invalid")
        ] do
      assert_raise ArgumentError, fn -> Support.verify_report(invalid, nonce, path, 3, true) end
    end
  end

  test "isolated tool snapshots refuse missing archives links and protected aliases" do
    root = fixture_root()
    tools = Path.join(root, "tools")
    state = Path.join(root, "operator-state")
    File.mkdir_p!(state)
    File.write!(Path.join(state, "private"), "synthetic protected data")
    task = Path.join(root, "task")
    File.mkdir_p!(task)

    assert_raise ArgumentError, ~r/Hex archive unavailable/, fn ->
      Support.prepare_build(task, tools, state, Path.join(root, "absent-workspace"))
    end

    File.mkdir_p!(Path.join(tools, "archives/hex-fixture"))
    File.mkdir_p!(Path.join(tools, "elixir"))
    archive = Path.join(tools, "archives/hex-fixture/tool")
    File.ln!(Path.join(state, "private"), archive)

    assert_raise ArgumentError, ~r/aliases protected/, fn ->
      Support.prepare_build(task, tools, state, Path.join(root, "absent-workspace"))
    end

    File.rm!(archive)
    File.ln_s!(Path.join(state, "private"), archive)

    assert_raise ArgumentError, ~r/symlink or special/, fn ->
      Support.prepare_build(task, tools, state, Path.join(root, "absent-workspace"))
    end

    File.rm!(archive)
    File.write!(archive, "synthetic nonsecret tool")

    assert Support.prepare_build(task, tools, state, Path.join(root, "absent-workspace")) == [
             :ok,
             :ok
           ]

    assert File.read!(Path.join(task, "home/.mix/archives/hex-fixture/tool")) ==
             "synthetic nonsecret tool"

    refute File.read!(Path.join(task, "protected-file-ids")) == ""
  end

  defp aggregate(root) do
    System.cmd("bash", ["-c", "exec bash scripts/check-closed-gates.sh --before M3 </dev/null"],
      cd: root,
      env: [
        {"TRACE_FILE", Path.join(root, "calls")},
        {"OPENAI_API_KEY", "synthetic-provider-sentinel"},
        {"LOOPEX_PROVIDER_API_KEY", nil}
      ],
      stderr_to_stdout: true
    )
  end

  defp fixture_root do
    suffix = Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)
    root = Path.join(System.tmp_dir!(), "m3-aggregate-test-#{System.pid()}-#{suffix}")
    File.mkdir_p!(Path.join(root, "scripts"))
    File.mkdir_p!(Path.join(root, "docs/plans"))
    on_exit(fn -> File.rm_rf!(root) end)
    {_, 0} = System.cmd("git", ["init", "-q", root])
    repository = Path.expand("../../..", __DIR__)

    for file <- ["check-closed-gates.sh", "m3-gate-support.exs"],
        do: File.cp!(Path.join([repository, "scripts", file]), Path.join([root, "scripts", file]))

    File.write!(Path.join(root, "scripts/check-bootstrap.sh"), "#!/bin/bash\nexit 0\n")

    File.write!(
      Path.join(root, "docs/plans/README.md"),
      register([
        {"M0", "Closed"},
        {"M1", "Closed"},
        {"M2", "Closed"},
        {"M3", "Closed"},
        {"M4", "Open"}
      ])
    )

    for name <- ["M0", "M1", "M2", "M3"] do
      script = "scripts/check-#{String.downcase(name)}-gate.sh"
      command = if name == "M1", do: "/bin/bash -p #{script}", else: "bash #{script}"
      File.write!(Path.join(root, "docs/plans/#{name}-gate.md"), "```text\n#{command}\n```\n")

      File.write!(
        Path.join(root, script),
        "#!/bin/bash\n[ -z \"${OPENAI_API_KEY+x}\" ] || exit 79\nprintf '#{name}\\n' >> \"$TRACE_FILE\"\n"
      )
    end

    root
  end

  defp register(rows) do
    "<!-- loopex:milestone-register:start -->\n" <>
      Enum.map_join(rows, "\n", fn {name, state} ->
        "| `#{name}` | #{state} | [concept](#{name}.md) | [technical depth](#{name}-technical.md) | [gate](#{name}-gate.md) |"
      end) <>
      "\n<!-- loopex:milestone-register:end -->\n"
  end
end
