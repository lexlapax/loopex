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
      "LOOPEX_M4_GATE_REPORT source=#{String.duplicate("a", 40)} gate=sha256:#{String.duplicate("b", 64)} " <>
        "version=0.1.0 role=full seed=3107 outcome_ids=1,2,3,4,5,6 selectors=10 elapsed_seconds=4200 " <>
        "elixir=1.20.3 otp=29.0.5 erts=17.0.5 platform=aarch64-apple-darwin25.6.0 node=22.12.0 " <>
        "python=3.12.4 clients=sha256:#{String.duplicate("c", 64)} schema=sha256:#{String.duplicate("e", 64)} " <>
        "inherited=true real_workflow=true result=PASS"

    assert :ok = Support.verify_final_report(line)
    assert :ok = Support.verify_final_report(line <> "\n")

    for mutant <- [
          String.replace(line, " selectors=10", ""),
          line <> " selectors=10",
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
