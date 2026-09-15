Code.require_file("../../../scripts/m4-gate-support.exs", __DIR__)

defmodule Loopex.M4GateSupportTest do
  use ExUnit.Case, async: true

  alias Loopex.M4Gate.Support

  @moduletag :m4_gate_support

  @root Path.expand("../../..", __DIR__)
  @real "apps/loopex_app_server/test/external_workflow_real_test.exs"
  @deterministic "apps/loopex_app_server/test/initialization_test.exs"
  @digest "sha256:" <> String.duplicate("d", 64)
  @real_tail "provider=anthropic model=claude-haiku-4-5 endpoint=api " <>
               "adapter_build=loopex_llm_reqllm@0.0.0 executor_build=loopex_executor_local@0.0.0 " <>
               "executor_identity=local tool_identity=write recorded=2026-09-11T00:00:00Z"

  defp report(path, extra \\ "") do
    "noise\nLOOPEX_EXUNIT_REPORT nonce=n1 selector=#{path} seed=3107 executed=1 digest=#{@digest}#{extra}\n"
  end

  # Concept: a real-provider identity that is not a real identity is refused.
  #
  # Concept, continued: the danger this closes is not a malformed report but a
  # well-formed one that says nothing. A lane can be wired, run, and emit every
  # field the grammar demands while those fields carry placeholders, and the
  # evidence would then record that a real provider was exercised when no such
  # thing happened.
  #
  # Technical depth: accepted M4 requires retained evidence to refuse incomplete
  # or stale identities, and the support script enforces three separable rules
  # that nothing exercised until now: a placeholder word standing in for an
  # identity, a byte outside printable ASCII inside one, and a timestamp that is
  # not an exact instant. Each is asserted on its own, because a single case
  # covering all three would pass while two of the rules were missing.
  test "a real report refuses placeholder, unprintable and inexact identities" do
    real = fn tail ->
      assert_raise ArgumentError, fn ->
        Support.verify_report(@root, report(@real, " " <> tail), "n1", @real, 1, true)
      end
    end

    # A placeholder is a field that parses and means nothing.
    for placeholder <- ~w(tbd TODO pending Unknown -) do
      real.(String.replace(@real_tail, "provider=anthropic", "provider=" <> placeholder))
    end

    # An identity is printable ASCII, so a tab or a control byte inside one is
    # not a name a later reader can compare.
    real.(String.replace(@real_tail, "executor_identity=local", "executor_identity=lo\tcal"))
    real.(String.replace(@real_tail, "tool_identity=write", "tool_identity=wr\x7fite"))

    # An empty field is the emptiest placeholder of all.
    real.(String.replace(@real_tail, "model=claude-haiku-4-5", "model="))

    # `recorded` is an exact instant, and an offset that is not zero names a
    # moment whose ordering against another lane's evidence is ambiguous.
    real.(String.replace(@real_tail, "recorded=2026-09-11T00:00:00Z", "recorded=2026-09-11"))

    real.(
      String.replace(@real_tail, "recorded=2026-09-11T00:00:00Z", "recorded=2026-09-11T00:00:00")
    )

    real.(
      String.replace(
        @real_tail,
        "recorded=2026-09-11T00:00:00Z",
        "recorded=2026-09-11T00:00:00+01:00"
      )
    )

    # The unaltered tail is still admitted, so each refusal above is the field
    # it names rather than the shape of the report.
    assert :ok =
             Support.verify_report(@root, report(@real, " " <> @real_tail), "n1", @real, 1, true)
  end

  # Concept: the authoritative report is judged once against its complete
  # schema for its kind; every incomplete or foreign shape is refused.
  test "authoritative reports reject missing duplicate reordered wrong kind and stale version fields" do
    assert :ok =
             Support.verify_report(@root, report(@deterministic), "n1", @deterministic, 1, false)

    assert :ok =
             Support.verify_report(@root, report(@real, " " <> @real_tail), "n1", @real, 1, true)

    rejected = fn log, path, real? ->
      assert_raise ArgumentError, fn ->
        Support.verify_report(@root, log, "n1", path, 1, real?)
      end
    end

    rejected.(report(@real, " " <> @real_tail), @real, false)
    rejected.(report(@real), @real, true)

    rejected.(
      report(@real, " " <> String.replace(@real_tail, " model=claude-haiku-4-5", "")),
      @real,
      true
    )

    rejected.(report(@real, " " <> @real_tail <> " provider=anthropic"), @real, true)
    rejected.(report(@deterministic, " digest=" <> @digest), @deterministic, false)
    rejected.(report(@deterministic, " extra=1"), @deterministic, false)
    rejected.(report(@deterministic) <> report(@deterministic), @deterministic, false)

    rejected.(
      String.replace(report(@deterministic), "nonce=n1", "nonce=n2"),
      @deterministic,
      false
    )

    rejected.(
      String.replace(report(@deterministic), "seed=3107", "seed=1"),
      @deterministic,
      false
    )

    rejected.(
      String.replace(report(@deterministic), "executed=1", "executed=0"),
      @deterministic,
      false
    )

    stale_root =
      Path.join(System.tmp_dir!(), "loopex-m4-stale-#{System.unique_integer([:positive])}")

    File.mkdir_p!(stale_root)
    File.write!(Path.join(stale_root, "VERSION"), "0.1.0\n")
    on_exit(fn -> File.rm_rf!(stale_root) end)

    assert_raise ArgumentError, ~r/another source version/, fn ->
      Support.verify_report(stale_root, report(@real, " " <> @real_tail), "n1", @real, 1, true)
    end

    assert :ok =
             Support.verify_report(
               stale_root,
               report(@real, " " <> String.replace(@real_tail, "@0.0.0", "@0.1.0")),
               "n1",
               @real,
               1,
               true
             )
  end

  # Concept: the retained final line has one grammar and no tolerated variant.
  test "the final report grammar rejects missing duplicated reordered and malformed fields" do
    line =
      "LOOPEX_M4_GATE_REPORT source=#{String.duplicate("a", 40)} tree=#{String.duplicate("f", 40)} " <>
        "archive=sha256:#{String.duplicate("8", 64)} archive_build=sha256:#{String.duplicate("7", 64)} " <>
        "lock=sha256:#{String.duplicate("9", 64)} " <>
        "gate=sha256:#{String.duplicate("b", 64)} " <>
        "version=0.1.0 role=full seed=3107 outcome_ids=1,2,3,4,5,6,7 selectors=10 elapsed_seconds=4200 " <>
        "elixir=1.20.3 otp=29.0.5 erts=17.0.5 platform=aarch64-apple-darwin25.6.0 node_pin=22.12.0 " <>
        "clients=sha256:#{String.duplicate("c", 64)} schema=sha256:#{String.duplicate("e", 64)} " <>
        "inherited=true fresh_source=true real_workflow=true result=PASS"

    assert :ok = Support.verify_final_report(line)
    assert :ok = Support.verify_final_report(line <> "\n")

    for mutant <- [
          String.replace(line, " selectors=10", ""),
          String.replace(line, " tree=#{String.duplicate("f", 40)}", ""),
          String.replace(line, " archive=sha256:#{String.duplicate("8", 64)}", ""),
          String.replace(line, " archive_build=sha256:#{String.duplicate("7", 64)}", ""),
          String.replace(line, " lock=sha256:#{String.duplicate("9", 64)}", ""),
          String.replace(line, " fresh_source=true", ""),
          line <> " selectors=10",
          line <> " archive=sha256:#{String.duplicate("8", 64)}",
          String.replace(line, "fresh_source=true", "fresh_source=false"),
          String.replace(line, "archive=sha256:#{String.duplicate("8", 64)}", "archive=missing"),
          String.replace(line, "role=full seed=3107", "seed=3107 role=full"),
          String.replace(line, "otp=29.0.5", "otp=29"),
          String.replace(line, "version=0.1.0", "version=x"),
          String.replace(line, "result=PASS", "result=RED"),
          String.replace(line, "elapsed_seconds=4200", "elapsed_seconds=fast"),
          String.replace(line, "LOOPEX_M4_GATE_REPORT", "LOOPEX_M3_GATE_REPORT")
        ] do
      assert_raise ArgumentError, fn -> Support.verify_final_report(mutant) end
    end
  end
end
