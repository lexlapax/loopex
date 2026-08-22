defmodule Loopex.M1GateEvidenceTest do
  @moduledoc """
  ## Concept

  Adversarially proves the M1-specific evidence, lifecycle, environment, and
  filesystem controls fail closed at the boundaries they claim.

  ## Technical depth

  Genuine cases invoke the standalone verifier as a separate Elixir process
  against temporary Git histories. The mutation corpus compiles those exact
  source bytes without the CLI invocation so exhaustive cases do not each pay
  for a new VM. Neither path imports Matrix, status, Markdown, JSON, register,
  or record readers, so generic checks cannot certify the M1 evidence grammar
  or its C-to-E-to-T ancestry.
  """

  use ExUnit.Case, async: false

  @artifact_blob "restored mechanism bytes\n"
  @identity_fields ~w(provider model endpoint adapter_build executor_build executor_identity tool_identity recorded)
  @capture_bound_fields ~w(os arch limits provider model endpoint adapter_build executor_build executor_identity tool_identity recorded)
  @capture_identity %{
    "provider" => "fixture-provider",
    "model" => "fixture-model",
    "endpoint" => "https://example.invalid/v1",
    "adapter_build" => "loopex_llm_reqllm@0.0.0",
    "executor_build" => "loopex_executor_local@0.0.0",
    "executor_identity" => "local-executor-v1",
    "tool_identity" => "local-tool-v1",
    "recorded" => "2026-08-21T12:34:56Z"
  }
  @negative_records [
    {"## Outcome 2: owner post-commit fence", "current_owner_post_commit_fence",
     "apps/loopex/test/session_lifecycle_test.exs", "apps/loopex/lib/owner.ex"},
    {"## Outcome 3: atomic owner-epoch transaction", "store_atomic_admission_compare",
     "apps/loopex_store_local/test/store_conformance_test.exs",
     "apps/loopex_store_local/lib/store.ex"},
    {"## Outcome 3: commit-unknown domain fence", "commit_unknown_dispatch_fence",
     "apps/loopex_store_local/test/store_conformance_test.exs",
     "apps/loopex_store_local/lib/fence.ex"},
    {"## Outcome 6: final executor validation", "executor_final_prestart_validation",
     "apps/loopex_executor_local/test/executor_test.exs",
     "apps/loopex_executor_local/lib/executor.ex"},
    {"## Outcome 8: no-blind-retry transition", "no_blind_retry_without_receipt",
     "apps/loopex_reference_client/test/end_to_end_recovery_test.exs",
     "apps/loopex_reference_client/lib/recovery.ex"}
  ]

  defp repo_root, do: Path.expand("../../..", __DIR__)
  defp verifier, do: Path.join(repo_root(), "scripts/m1-evidence-verifier.exs")
  defp runner_source, do: File.read!(Path.join(repo_root(), "scripts/check-m1-gate.sh"))
  defp launcher_source, do: File.read!(Path.join(repo_root(), "scripts/m1-gate-launcher.escript"))

  defp shell_function(source, name) do
    case Regex.run(~r/^#{Regex.escape(name)}\(\) \{(?:[^\n]*\}\n|\n.*?^\}\n)/ms, source) do
      [function] -> function
      nil -> flunk("runner does not define #{name} as a top-level shell function")
    end
  end

  defp digest(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp git!(root, args) do
    case System.cmd("git", ["-C", root | args], stderr_to_stdout: true) do
      {output, 0} -> output
      {output, status} -> flunk("git #{Enum.join(args, " ")} failed #{status}: #{output}")
    end
  end

  defp commit!(root, message, paths \\ ["."]) do
    git!(root, ["add" | paths])
    git!(root, ["-c", "commit.gpgsign=false", "commit", "-q", "-m", message])
    root |> git!(["rev-parse", "HEAD"]) |> String.trim()
  end

  defp run_verifier(root, args) do
    System.cmd("elixir", [verifier() | args],
      cd: root,
      env: [{"ERL_CRASH_DUMP", "/dev/null"}, {"ERL_CRASH_DUMP_SECONDS", "0"}],
      stderr_to_stdout: true
    )
  end

  defp load_verifier_for_mutations do
    trailer = "\nLoopex.M1EvidenceVerifier.CLI.main(System.argv())\n"
    source = File.read!(verifier())
    assert 1 == source |> :binary.matches(trailer) |> length()
    Code.compile_string(String.replace(source, trailer, "\n", global: false), verifier())
  end

  defp run_loaded_verifier(root) do
    case apply(Loopex.M1EvidenceVerifier, :all, [
           root,
           "docs/evidence/M1-toolchain-matrix.md",
           "docs/evidence/M1-negative-demonstrations.md"
         ]) do
      :ok -> {"M1 evidence OK\n", 0}
      {:error, reason} -> {"M1 evidence verifier refused: #{reason}\n", 1}
    end
  rescue
    _exception -> {"M1 evidence verifier refused: evidence is unavailable\n", 1}
  catch
    _kind, _reason -> {"M1 evidence verifier refused: evidence is unavailable\n", 1}
  end

  defp evidence_root do
    root = Path.join(System.tmp_dir!(), "m1-evidence-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    git!(root, ["init", "-q"])
    git!(root, ["config", "user.name", "Loopex Test"])
    git!(root, ["config", "user.email", "loopex-test@example.invalid"])
    on_exit(fn -> File.rm_rf(root) end)

    File.write!(Path.join(root, "mix.exs"), "# fixture umbrella\n")

    for {_heading, _mechanism, _selector, artifact} <- @negative_records do
      path = Path.join(root, artifact)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, @artifact_blob)
    end

    base = commit!(root, "fixture mutation base")

    files = %{
      "docs/plans/M1-gate.md" => "# Fixture M1 gate\n",
      "docs/plans/M0-gate.md" => "# Fixture immutable M0 gate\n",
      "scripts/check-m1-gate.sh" => "#!/usr/bin/env bash\nexit 0\n",
      "scripts/m1-gate-launcher.escript" => launcher_source(),
      "scripts/m1-exunit-runner.exs" => "# fixture selector runner\n",
      "scripts/m1-evidence-verifier.exs" => File.read!(verifier()),
      "apps/loopex/lib/mix/tasks/loopex.deps_budget.ex" => "# fixture dependency authority\n",
      ".tool-versions" => File.read!(Path.join(repo_root(), ".tool-versions")),
      "docs/evidence/M1-negative-demonstrations.md" => negative_document(base),
      "docs/evidence/M1-toolchain-matrix.md" => "capture pending\n",
      "docs/plans/M1.md" => plan_document(nil, nil),
      "docs/plans/README.md" => plans_status("In review"),
      "README.md" => root_status("In review")
    }

    Enum.each(files, fn {relative, bytes} ->
      path = Path.join(root, relative)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, bytes)
    end)

    candidate = commit!(root, "fixture capture source")

    context = %{
      root: root,
      base: base,
      candidate: candidate,
      gate_sha256: file_digest(root, "docs/plans/M1-gate.md"),
      m0_gate_sha256: file_digest(root, "docs/plans/M0-gate.md"),
      runner_sha256: file_digest(root, "scripts/check-m1-gate.sh"),
      launcher_sha256: file_digest(root, "scripts/m1-gate-launcher.escript"),
      exunit_runner_sha256: file_digest(root, "scripts/m1-exunit-runner.exs"),
      deps_budget_sha256: file_digest(root, "apps/loopex/lib/mix/tasks/loopex.deps_budget.ex"),
      verifier_sha256: file_digest(root, "scripts/m1-evidence-verifier.exs"),
      tool_versions_sha256: file_digest(root, ".tool-versions"),
      capture_identity: @capture_identity
    }

    File.write!(
      Path.join(root, "docs/evidence/M1-toolchain-matrix.md"),
      matrix_document(context)
    )

    evidence = commit!(root, "fixture evidence", ["docs/evidence/M1-toolchain-matrix.md"])
    Map.put(context, :evidence, evidence)
  end

  defp file_digest(root, relative), do: root |> Path.join(relative) |> File.read!() |> digest()

  defp identity_suffix(identity) do
    Enum.map_join(@identity_fields, " ", fn field ->
      "#{field}=#{Map.fetch!(identity, field)}"
    end)
  end

  defp mutate_capture(bytes, lane, mutate) do
    lines = String.split(bytes, "\n", trim: false)
    index = Enum.find_index(lines, &String.starts_with?(&1, "capture lane=#{lane} "))
    line = Enum.at(lines, index)
    tokens = String.split(line, " ")

    lines
    |> List.replace_at(index, tokens |> mutate.() |> Enum.join(" "))
    |> Enum.join("\n")
  end

  defp capture_field_index(tokens, field),
    do: Enum.find_index(tokens, &String.starts_with?(&1, "#{field}="))

  defp remove_capture_field(bytes, lane, field) do
    mutate_capture(bytes, lane, fn tokens ->
      List.delete_at(tokens, capture_field_index(tokens, field))
    end)
  end

  defp reorder_capture_field(bytes, lane, field) do
    mutate_capture(bytes, lane, fn tokens ->
      index = capture_field_index(tokens, field)
      other_index = if index == length(tokens) - 1, do: index - 1, else: index + 1
      value = Enum.at(tokens, index)
      other = Enum.at(tokens, other_index)

      tokens
      |> List.replace_at(index, other)
      |> List.replace_at(other_index, value)
    end)
  end

  defp replace_capture_field(bytes, lane, field, value) do
    mutate_capture(bytes, lane, fn tokens ->
      List.replace_at(tokens, capture_field_index(tokens, field), "#{field}=#{value}")
    end)
  end

  defp negative_document(candidate) do
    restored = digest(@artifact_blob)

    """
    # M1 Negative Demonstrations

    ## Outcome 2: owner post-commit fence

    ```json
    {"mechanism_disabled":"current_owner_post_commit_fence","selector":"apps/loopex/test/session_lifecycle_test.exs","observed_failure":"locked selector failed after one mechanism was disabled","candidate":"#{candidate}","artifact":"apps/loopex/lib/owner.ex","restored_sha256":"sha256:#{restored}"}
    ```

    ## Outcome 3: atomic owner-epoch transaction

    ```json
    {"mechanism_disabled":"store_atomic_admission_compare","selector":"apps/loopex_store_local/test/store_conformance_test.exs","observed_failure":"locked selector failed after one mechanism was disabled","candidate":"#{candidate}","artifact":"apps/loopex_store_local/lib/store.ex","restored_sha256":"sha256:#{restored}"}
    ```

    ## Outcome 3: commit-unknown domain fence

    ```json
    {"mechanism_disabled":"commit_unknown_dispatch_fence","selector":"apps/loopex_store_local/test/store_conformance_test.exs","observed_failure":"locked selector failed after one mechanism was disabled","candidate":"#{candidate}","artifact":"apps/loopex_store_local/lib/fence.ex","restored_sha256":"sha256:#{restored}"}
    ```

    ## Outcome 6: final executor validation

    ```json
    {"mechanism_disabled":"executor_final_prestart_validation","selector":"apps/loopex_executor_local/test/executor_test.exs","observed_failure":"locked selector failed after one mechanism was disabled","candidate":"#{candidate}","artifact":"apps/loopex_executor_local/lib/executor.ex","restored_sha256":"sha256:#{restored}"}
    ```

    ## Outcome 8: no-blind-retry transition

    ```json
    {"mechanism_disabled":"no_blind_retry_without_receipt","selector":"apps/loopex_reference_client/test/end_to_end_recovery_test.exs","observed_failure":"locked selector failed after one mechanism was disabled","candidate":"#{candidate}","artifact":"apps/loopex_reference_client/lib/recovery.ex","restored_sha256":"sha256:#{restored}"}
    ```
    """
  end

  defp matrix_document(context) do
    floor_identity = identity_suffix(context.capture_identity)

    current_identity =
      context.capture_identity
      |> Map.put("recorded", "2026-08-21T12:34:57Z")
      |> identity_suffix()

    linux_identity =
      context.capture_identity
      |> Map.put("recorded", "2026-08-21T12:34:58Z")
      |> identity_suffix()

    """
    # M1 Toolchain Matrix

    <!-- loopex:m1-matrix:start -->
    ```text
    matrix candidate=#{context.candidate} gate_sha256=#{context.gate_sha256} runner_sha256=#{context.runner_sha256} launcher_sha256=#{context.launcher_sha256} exunit_runner_sha256=#{context.exunit_runner_sha256} deps_budget_sha256=#{context.deps_budget_sha256} verifier_sha256=#{context.verifier_sha256} tool_versions_sha256=#{context.tool_versions_sha256} command=bash-p:scripts/check-m1-gate.sh
    capture lane=floor candidate=#{context.candidate} gate_sha256=#{context.gate_sha256} command=bash-p:scripts/check-m1-gate.sh elixir=1.17.0 otp=26.0 erts=14.0 seed=11 executed=101 verdict=CAPTURE exit=0 wall=1s os=darwin arch=arm64 limits=nofile-256,nproc-709 #{floor_identity}
    capture lane=current candidate=#{context.candidate} gate_sha256=#{context.gate_sha256} command=bash-p:scripts/check-m1-gate.sh elixir=1.20.3 otp=29.0.5 erts=17.0.5 seed=12 executed=102 verdict=CAPTURE exit=0 wall=2s os=darwin arch=x86_64 limits=nofile-unlimited,nproc-709 #{current_identity}
    capture lane=linux-current candidate=#{context.candidate} gate_sha256=#{context.gate_sha256} command=bash-p:scripts/check-m1-gate.sh elixir=1.20.3 otp=29.0.5 erts=17.0.5 seed=13 executed=103 verdict=CAPTURE exit=0 wall=3s os=linux arch=aarch64 limits=nofile-1048576,nproc-unlimited #{linux_identity}
    m0 lane=floor candidate=#{context.candidate} gate_sha256=#{context.m0_gate_sha256} command=bash:scripts/check-m0-gate.sh elixir=1.17.0 otp=26.0 provider=fixture-provider model=fixture-model endpoint=https://example.invalid verdict=GREEN exit=0
    m0 lane=current candidate=#{context.candidate} gate_sha256=#{context.m0_gate_sha256} command=bash:scripts/check-m0-gate.sh elixir=1.20.3 otp=29.0.5 provider=fixture-provider model=fixture-model endpoint=https://example.invalid verdict=GREEN exit=0
    ```
    <!-- loopex:m1-matrix:end -->
    """
  end

  defp plan_document(closure_candidate, gate_digest) do
    digest = String.duplicate("1", 64)
    accepted = String.duplicate("2", 40)

    closure =
      if closure_candidate do
        "| Closure | Maintainer | [disposition](closure.md) | candidate `#{closure_candidate}`; " <>
          "concept `sha256:#{digest}`; technical `sha256:#{digest}`; " <>
          "gate `sha256:#{gate_digest}` |"
      else
        "| Closure | — | — | — |"
      end

    """
    # Fixture M1 Plan

    ## Governance Records

    | Decision | Authority | Authority evidence | Bound bytes |
    | --- | --- | --- | --- |
    | Acceptance | Maintainer | [disposition](acceptance.md) | candidate `#{accepted}`; concept `sha256:#{digest}`; technical `sha256:#{digest}`; gate `sha256:#{digest}` |
    #{closure}
    """
  end

  defp plans_status(state) do
    """
    # Plans

    <!-- loopex:current-status:start -->
    ## Current Status

    M1 is #{state}.
    <!-- loopex:current-status:end -->

    Stable text.

    <!-- loopex:milestone-register:start -->
    ## Milestone Register

    | M1 | #{state} |
    <!-- loopex:milestone-register:end -->
    """
  end

  defp root_status(state) do
    """
    # Loopex

    <!-- loopex:readme-status:start -->
    ## Where Things Stand

    M1 is #{state}.
    <!-- loopex:readme-status:end -->

    Stable root text.
    """
  end

  defp close_m1(context, options \\ []) do
    if Keyword.get(options, :interpose, false) do
      File.write!(Path.join(context.root, "interposed.txt"), "interposed\n")
      commit!(context.root, "fixture interposed commit", ["interposed.txt"])
    end

    candidate = Keyword.get(options, :candidate, context.evidence)

    File.write!(
      Path.join(context.root, "docs/plans/M1.md"),
      plan_document(candidate, context.gate_sha256)
    )

    File.write!(Path.join(context.root, "docs/plans/README.md"), plans_status("Closed"))
    File.write!(Path.join(context.root, "README.md"), root_status("Closed"))

    paths = ["docs/plans/M1.md", "docs/plans/README.md", "README.md"]

    if Keyword.get(options, :product, false) do
      File.write!(Path.join(context.root, "product.ex"), "bundled product byte\n")
      paths = ["product.ex" | paths]
      commit!(context.root, "fixture closure", paths)
    else
      commit!(context.root, "fixture closure", paths)
    end
  end

  test "M1 pair verifier derives only the exact running locked pair" do
    context = evidence_root()
    verifier_source = File.read!(verifier())

    assert verifier_source =~ ~S(@token ~r/\A[\x21-\x7E]+\z/u)
    refute verifier_source =~ ~S(@token ~r/\A[^\x00-\x20\x7f]+\z/u)
    assert verifier_source =~ ":file.native_name_encoding() == :utf8"

    for generic <- [
          "Mix.Tasks.Loopex.Matrix",
          "Loopex.Checks.Markdown",
          "Loopex.Checks.Register",
          "Mix.Tasks.Loopex.Status",
          "Jason"
        ] do
      refute verifier_source =~ generic
    end

    refute File.exists?(Path.join(context.root, "apps/loopex/lib/mix/tasks/loopex.matrix.ex"))
    refute File.exists?(Path.join(context.root, "apps/loopex/lib/loopex/checks/register.ex"))

    assert {output, 0} =
             run_verifier(context.root, ["--pair", "--root", context.root])

    assert output =~
             "LOOPEX_M1_PAIR lane="

    assert output =~ "elixir=#{System.version()}"
    assert output =~ " otp="
    assert output =~ " erts="

    tool_versions = Path.join(context.root, ".tool-versions")
    original = File.read!(tool_versions)
    File.write!(tool_versions, String.replace(original, "erlang 29.0.5", "erlang 29.0.6"))
    assert {_output, status} = run_verifier(context.root, ["--pair", "--root", context.root])
    assert status != 0
    File.write!(tool_versions, original)

    assert {output, status} = run_verifier(context.root, ["--root", context.root])
    assert status != 0
    assert output =~ "usage: m1-evidence-verifier.exs"
  end

  test "M1 evidence verifier requires one exact capture and inherited M0 proof per locked lane" do
    context = evidence_root()

    args = [
      "--root",
      context.root,
      "--matrix",
      "docs/evidence/M1-toolchain-matrix.md",
      "--negative",
      "docs/evidence/M1-negative-demonstrations.md"
    ]

    assert {"M1 evidence OK\n", 0} = run_verifier(context.root, args)
    load_verifier_for_mutations()

    path = Path.join(context.root, "docs/evidence/M1-toolchain-matrix.md")
    original = File.read!(path)

    mutations = [
      &String.replace(&1, "capture lane=current", "capture lane=floor"),
      &String.replace(&1, "capture lane=linux-current", "capture lane=current"),
      &Regex.replace(~r/^capture lane=linux-current.*\n/m, &1, ""),
      &String.replace(&1, "seed=11", "seed=1000000"),
      &String.replace(&1, "executed=101", "executed=0"),
      &String.replace(&1, "verdict=CAPTURE", "verdict=GREEN", global: false),
      &String.replace(&1, "command=bash:scripts/check-m0-gate.sh", "command=bash:other.sh",
        global: false
      ),
      &String.replace(&1, context.runner_sha256, String.duplicate("f", 64), global: false),
      fn bytes -> String.replace(bytes, "m0 lane=floor", "extra field=1\nm0 lane=floor") end,
      &String.replace(
        &1,
        "command=bash-p:scripts/check-m1-gate.sh\n",
        "command=bash-p:scripts/check-m1-gate.sh platform=fixture-platform\n",
        global: false
      ),
      &String.replace(
        &1,
        "command=bash-p:scripts/check-m1-gate.sh\n",
        "command=bash-p:scripts/check-m1-gate.sh limits=fixture-limits\n",
        global: false
      ),
      &String.replace(&1, "\n", "\r\n", global: false),
      &String.trim_trailing(&1, "\n")
    ]

    Enum.each(mutations, fn mutate ->
      File.write!(path, mutate.(original))
      assert {_output, status} = run_loaded_verifier(context.root)
      assert status != 0
    end)

    Enum.each(@capture_bound_fields, fn field ->
      File.write!(path, remove_capture_field(original, "floor", field))
      assert {output, status} = run_loaded_verifier(context.root)
      assert status != 0, "missing capture #{field} unexpectedly passed"
      assert output =~ "capture fields are missing, reordered, or ambiguous"
    end)

    for {label, changed} <- [
          {"reordered", reorder_capture_field(original, "floor", "provider")},
          {"malformed", replace_capture_field(original, "floor", "provider", "")}
        ] do
      File.write!(path, changed)
      assert {output, status} = run_loaded_verifier(context.root)
      assert status != 0, "#{label} capture field unexpectedly passed"
      assert output =~ "capture fields are missing, reordered, or ambiguous"
    end

    for {field, value, expected} <- [
          {"adapter_build", "other_adapter@0.0.0", "floor capture adapter_build"},
          {"executor_build", "other_executor@0.0.0", "floor capture executor_build"},
          {"recorded", "2026-02-30T12:34:56Z", "floor capture recorded"}
        ] do
      File.write!(path, replace_capture_field(original, "floor", field, value))
      assert {output, status} = run_loaded_verifier(context.root)
      assert status != 0, "invalid capture #{field} unexpectedly passed"
      assert output =~ expected
    end

    for {lane, os} <- [{"floor", "linux"}, {"current", "linux"}, {"linux-current", "darwin"}] do
      File.write!(path, replace_capture_field(original, lane, "os", os))
      assert {output, status} = run_loaded_verifier(context.root)
      assert status != 0, "wrong #{lane} os unexpectedly passed"
      assert output =~ "#{lane} capture os"
    end

    File.write!(path, replace_capture_field(original, "linux-current", "arch", "pending"))
    assert {output, status} = run_loaded_verifier(context.root)
    assert status != 0
    assert output =~ "linux-current capture arch"

    for {lane, limits} <- [
          {"floor", "nofile-0256,nproc-709"},
          {"current", "nofile-unlimited,nproc-pending"},
          {"linux-current", "nproc-unlimited,nofile-1048576"}
        ] do
      File.write!(path, replace_capture_field(original, lane, "limits", limits))
      assert {output, status} = run_loaded_verifier(context.root)
      assert status != 0, "malformed #{lane} limits unexpectedly passed"
      assert output =~ "#{lane} capture limits"
    end

    File.write!(path, replace_capture_field(original, "linux-current", "elixir", "1.17.0"))
    assert {output, status} = run_loaded_verifier(context.root)
    assert status != 0
    assert output =~ "linux-current capture Elixir"

    for lane <- ~w(current linux-current),
        field <- ~w(provider model endpoint executor_identity tool_identity) do
      File.write!(path, replace_capture_field(original, lane, field, "different-#{field}"))

      assert {output, status} = run_loaded_verifier(context.root)
      assert status != 0, "lane disagreement for #{lane} #{field} unexpectedly passed"
      assert output =~ "capture lanes disagree about #{field}"
    end

    for {field, value, label} <- [
          {"provider", "fixture-prоvider", "Cyrillic lookalike"},
          {"tool_identity", "local-tool-\u202Eidentity", "right-to-left override"},
          {"endpoint", "https:／／example.invalid/v1", "fullwidth punctuation"}
        ] do
      File.write!(path, replace_capture_field(original, "floor", field, value))
      assert {output, status} = run_loaded_verifier(context.root)
      assert status != 0, "#{label} in capture #{field} unexpectedly passed"
      assert output =~ "printable ASCII"
    end

    File.write!(path, original)

    for {field, value} <- [
          {"gate_sha256", context.gate_sha256},
          {"runner_sha256", context.runner_sha256},
          {"launcher_sha256", context.launcher_sha256},
          {"exunit_runner_sha256", context.exunit_runner_sha256},
          {"deps_budget_sha256", context.deps_budget_sha256},
          {"verifier_sha256", context.verifier_sha256},
          {"tool_versions_sha256", context.tool_versions_sha256}
        ] do
      changed =
        String.replace(
          original,
          "#{field}=#{value}",
          "#{field}=#{String.duplicate("f", 64)}",
          global: false
        )

      File.write!(path, changed)
      assert {_output, status} = run_loaded_verifier(context.root)
      assert status != 0, "#{field} was not bound"
    end

    File.write!(path, original)

    runner = Path.join(context.root, "scripts/check-m1-gate.sh")
    runner_original = File.read!(runner)
    File.write!(runner, runner_original <> "# current drift\n")
    assert {_output, status} = run_loaded_verifier(context.root)
    assert status != 0
    File.write!(runner, runner_original)
  end

  test "M1 evidence verifier binds source evidence and closure transition ancestry" do
    args = fn context ->
      [
        "--root",
        context.root,
        "--matrix",
        "docs/evidence/M1-toolchain-matrix.md",
        "--negative",
        "docs/evidence/M1-negative-demonstrations.md"
      ]
    end

    valid = evidence_root()
    close_m1(valid)
    assert {"M1 evidence OK\n", 0} = run_verifier(valid.root, args.(valid))

    open = evidence_root()
    File.write!(Path.join(open.root, "later.txt"), "open descendant\n")
    commit!(open.root, "fixture open descendant", ["later.txt"])
    assert {output, status} = run_verifier(open.root, args.(open))
    assert status != 0
    assert output =~ "open descendant"

    bundled_evidence = evidence_root()
    File.write!(Path.join(bundled_evidence.root, "unexpected.txt"), "bundled evidence byte\n")
    git!(bundled_evidence.root, ["add", "unexpected.txt"])

    git!(bundled_evidence.root, [
      "-c",
      "commit.gpgsign=false",
      "commit",
      "--amend",
      "-q",
      "--no-edit"
    ])

    assert {output, status} =
             run_verifier(bundled_evidence.root, args.(bundled_evidence))

    assert status != 0
    assert output =~ "no direct evidence-only child E"

    interposed = evidence_root()
    close_m1(interposed, interpose: true)
    assert {output, status} = run_verifier(interposed.root, args.(interposed))
    assert status != 0
    assert output =~ "not a direct child T"

    bundled = evidence_root()
    close_m1(bundled, product: true)
    assert {_output, status} = run_verifier(bundled.root, args.(bundled))
    assert status != 0

    wrong = evidence_root()
    close_m1(wrong, candidate: String.duplicate("f", 40))
    assert {_output, status} = run_verifier(wrong.root, args.(wrong))
    assert status != 0

    changed = evidence_root()
    close_m1(changed)
    matrix = Path.join(changed.root, "docs/evidence/M1-toolchain-matrix.md")
    File.write!(matrix, String.replace(File.read!(matrix), "wall=1s", "wall=9s", global: false))
    commit!(changed.root, "fixture later matrix change", ["docs/evidence/M1-toolchain-matrix.md"])
    assert {_output, status} = run_verifier(changed.root, args.(changed))
    assert status != 0

    changed_closure = evidence_root()
    close_m1(changed_closure)
    plan = Path.join(changed_closure.root, "docs/plans/M1.md")

    File.write!(
      plan,
      String.replace(File.read!(plan), "| Closure | Maintainer |", "| Closure | Operator |")
    )

    commit!(changed_closure.root, "fixture later closure change", ["docs/plans/M1.md"])
    assert {_output, status} = run_verifier(changed_closure.root, args.(changed_closure))
    assert status != 0

    duplicate_evidence = evidence_root()
    first_evidence = duplicate_evidence.evidence

    matrix_bytes =
      File.read!(Path.join(duplicate_evidence.root, "docs/evidence/M1-toolchain-matrix.md"))

    git!(duplicate_evidence.root, [
      "checkout",
      "-q",
      "-b",
      "second-evidence",
      duplicate_evidence.candidate
    ])

    File.write!(
      Path.join(duplicate_evidence.root, "docs/evidence/M1-toolchain-matrix.md"),
      matrix_bytes
    )

    commit!(duplicate_evidence.root, "fixture second evidence", [
      "docs/evidence/M1-toolchain-matrix.md"
    ])

    git!(duplicate_evidence.root, ["checkout", "-q", "-b", "combined-evidence", first_evidence])

    git!(duplicate_evidence.root, [
      "-c",
      "commit.gpgsign=false",
      "merge",
      "--no-ff",
      "-m",
      "fixture merge duplicate evidence",
      "second-evidence"
    ])

    assert {output, status} = run_verifier(duplicate_evidence.root, args.(duplicate_evidence))
    assert status != 0
    assert output =~ "more than one evidence-only child E"

    split = evidence_root()
    git!(split.root, ["checkout", "-q", "-b", "valid-transition"])
    close_m1(split)
    git!(split.root, ["checkout", "-q", "-b", "side-transition", split.evidence])
    File.write!(Path.join(split.root, "interposed.txt"), "interposed\n")
    commit!(split.root, "fixture side interposition", ["interposed.txt"])
    close_m1(split)
    git!(split.root, ["checkout", "-q", "valid-transition"])

    git!(split.root, [
      "-c",
      "commit.gpgsign=false",
      "merge",
      "--no-ff",
      "-m",
      "fixture merge second closure",
      "side-transition"
    ])

    assert {output, status} = run_verifier(split.root, args.(split))
    assert status != 0
    assert output =~ "more than one first closure completion"
  end

  test "M1 evidence verifier binds each negative mechanism to committed and restored bytes" do
    context = evidence_root()

    args = [
      "--root",
      context.root,
      "--negative",
      "docs/evidence/M1-negative-demonstrations.md"
    ]

    path = Path.join(context.root, "docs/evidence/M1-negative-demonstrations.md")
    original = File.read!(path)

    assert {"M1 negative evidence OK\n", 0} = run_verifier(context.root, args)

    mutations = [
      &String.replace(&1, "mechanism_disabled", "mechanism\\u005fdisabled", global: false),
      &String.replace(
        &1,
        ~s({"mechanism_disabled":),
        ~s({"selector":"duplicate", "mechanism_disabled":),
        global: false
      ),
      &String.replace(&1, "current_owner_post_commit_fence", "different_mechanism",
        global: false
      ),
      &String.replace(&1, context.base, String.duplicate("f", 40), global: false),
      &String.replace(&1, "locked selector failed", "locked sélector failed", global: false),
      &String.replace(&1, "\n", "\r\n", global: false),
      &String.trim_trailing(&1, "\n"),
      &String.replace(&1, "## Outcome 8:", "## Outcome 9:", global: false),
      fn bytes -> bytes <> "\n" end
    ]

    Enum.each(mutations, fn mutate ->
      File.write!(path, mutate.(original))
      assert {_output, status} = run_verifier(context.root, args)
      assert status != 0
    end)

    File.write!(path, original)
    {_heading, _mechanism, _selector, artifact} = hd(@negative_records)
    artifact_path = Path.join(context.root, artifact)
    File.write!(artifact_path, "not restored\n")
    assert {_output, status} = run_verifier(context.root, args)
    assert status != 0

    File.rm!(artifact_path)
    File.ln_s!(Path.join(context.root, Enum.at(@negative_records, 1) |> elem(3)), artifact_path)
    assert {_output, status} = run_verifier(context.root, args)
    assert status != 0
  end

  test "the environment preflight removes credential aliases and unrelated ambient state" do
    root = repo_root()
    token = "synthetic-provider-token-#{System.unique_integer([:positive])}"
    bash_env = Path.join(System.tmp_dir!(), "m1-bash-env-#{System.unique_integer([:positive])}")
    File.write!(bash_env, "printf 'BASH_ENV_RAN\\n' >&2\n")
    on_exit(fn -> File.rm(bash_env) end)

    {output, 0} =
      System.cmd(
        "/bin/bash",
        ["-p", "scripts/check-m1-gate.sh", "--environment-fixture"],
        cd: root,
        env: [
          {"LOOPEX_PROVIDER_API_KEY", token},
          {"ANTHROPIC_API_KEY", token},
          {"ALTERNATE_PROVIDER_ALIAS", "another-secret"},
          {"COMPOSITE_PROVIDER_ALIAS", "prefix-#{token}-suffix"},
          {"BASH_ENV", bash_env},
          {"GIT_CONFIG_GLOBAL", "/tmp/ambient-git-config"},
          {"ERL_AFLAGS", "-hidden"},
          {"HTTPS_PROXY", "https://ambient.invalid"},
          {"loopex_m1_attacker", "must-also-disappear"},
          {"UNRELATED_ENVIRONMENT_VALUE", "must-disappear"}
        ],
        stderr_to_stdout: true
      )

    refute output =~ token
    refute output =~ "LOOPEX_PROVIDER_API_KEY="
    refute output =~ "ANTHROPIC_API_KEY="
    refute output =~ "ALTERNATE_PROVIDER_ALIAS="
    refute output =~ "COMPOSITE_PROVIDER_ALIAS="
    refute output =~ "UNRELATED_ENVIRONMENT_VALUE"
    refute output =~ "loopex_m1_attacker"
    refute output =~ "BASH_ENV_RAN"
    refute output =~ "GIT_CONFIG_GLOBAL"
    refute output =~ "ERL_AFLAGS"
    refute output =~ "HTTPS_PROXY"
    assert output =~ "M1 environment preflight OK"
    assert output =~ "HOME=/"
    assert output =~ "GIT_OPTIONAL_LOCKS=0"

    environment_lines = String.split(output, "\n", trim: true)
    assert Enum.count(environment_lines, &(&1 == "LANG=C.UTF-8")) == 1
    assert Enum.count(environment_lines, &(&1 == "LC_ALL=C.UTF-8")) == 1
    refute "LANG=C" in environment_lines
    refute "LC_ALL=C" in environment_lines

    assert [summary, os, arch, locale, stat, sha256, limits] =
             Regex.run(
               ~r/^M1 environment preflight OK os=(darwin|linux) arch=([A-Za-z0-9._-]+) locale=(UTF-8) stat=(bsd|gnu) sha256=(shasum|sha256sum) limits=(nofile-(?:[1-9][0-9]*|unlimited),nproc-(?:[1-9][0-9]*|unlimited))$/m,
               output
             )

    expected_os = if match?({:unix, :darwin}, :os.type()), do: "darwin", else: "linux"
    {expected_arch, 0} = System.cmd("uname", ["-m"])
    assert os == expected_os
    assert arch == String.trim(expected_arch)
    assert locale == "UTF-8"
    assert stat in ["bsd", "gnu"]
    assert sha256 in ["shasum", "sha256sum"]
    assert limits =~ ~r/\Anofile-(?:[1-9][0-9]*|unlimited),nproc-(?:[1-9][0-9]*|unlimited)\z/
    assert summary in environment_lines

    boundary_functions =
      Enum.map_join(
        ["valid_utf8_charmap", "valid_gate_seed"],
        "\n",
        &shell_function(runner_source(), &1)
      )

    boundary_probe =
      boundary_functions <>
        """

        valid_utf8_charmap UTF-8 || exit 1
        valid_utf8_charmap UTF8 && exit 2
        valid_utf8_charmap ANSI_X3.4-1968 && exit 3
        for value in 0 1 999999; do
          valid_gate_seed "$value" || exit 4
        done
        for value in '' 00 000001 1000000 -1 1a; do
          valid_gate_seed "$value" && exit 5
        done
        builtin printf '%s' ok
        """

    assert {"ok", 0} =
             System.cmd("/bin/bash", ["-c", boundary_probe], stderr_to_stdout: true)

    {output, status} =
      System.cmd(
        "/bin/bash",
        ["-p", "scripts/check-m1-gate.sh", "--environment-fixture"],
        cd: root,
        env: [
          {"LOOPEX_PROVIDER_API_KEY", token},
          {"MIX_HOME", "/tmp/#{token}/mix"}
        ],
        stderr_to_stdout: true
      )

    assert status != 0
    assert output =~ "a required runner control contains provider credential bytes"
    refute output =~ token

    {output, status} =
      System.cmd("/bin/bash", ["scripts/check-m1-gate.sh"],
        cd: root,
        stderr_to_stdout: true
      )

    assert status == 1
    assert output == "M1 gate RED: invoke exactly /bin/bash -p scripts/check-m1-gate.sh\n"

    {output, status} =
      System.cmd(
        "/usr/bin/env",
        [
          "BAD-NAME=ambient",
          "/bin/bash",
          "-p",
          "scripts/check-m1-gate.sh",
          "--environment-fixture"
        ],
        cd: root,
        stderr_to_stdout: true
      )

    assert status != 0
    assert output == "M1 gate RED: ambient environment contains a non-identifier shell name\n"
    refute output =~ "M1 environment preflight OK"

    redaction_functions =
      Enum.map_join(["fail", "redacted"], "\n", &shell_function(runner_source(), &1))

    {output, 0} =
      System.cmd(
        "/bin/bash",
        [
          "-c",
          redaction_functions <>
            "\nprovider_key_value=redacted\nredacted '[redacted credential]'\n"
        ],
        stderr_to_stdout: true
      )

    refute output =~ "redacted"

    real_role_functions =
      Enum.map_join(["fail", "run_gate_test"], "\n", &shell_function(runner_source(), &1))

    real_role_probe = """
    #{real_role_functions}
    validate_generated_tree() { :; }
    redacted() { builtin printf '%s\n' "$1"; }
    elixir() {
      case " $* " in
        *" --context "*)
          builtin printf '%s\n' \
            'LOOPEX_DEPENDENCY_CONTEXT owner=loopex_reference_client internal=loopex_reference_client allowed=loopex_reference_client'
          ;;
        *)
          /bin/cat >/dev/null
          builtin printf 'successful provider output prefix-%s-suffix\n' "$provider_key_value"
          ;;
      esac
    }
    repository_root=/tmp
    deps_budget_source=deps-budget.ex
    selector_runner_source=selector-runner.exs
    test_build_path=/tmp
    project_configs=()
    gate_seed=1
    protected_executed=0
    last_gate_executed=0
    provider_key_value=fixture-secret
    run_gate_test real-model apps/loopex_reference_client/test/fixture.exs 1 zero no \
      passed=fixture
    """

    {output, status} =
      System.cmd("/bin/bash", ["-c", real_role_probe], stderr_to_stdout: true)

    assert status != 0
    assert output =~ "emitted provider credential bytes instead of contained evidence"
    refute output =~ "fixture-secret"

    source = runner_source()
    run_gate_body = shell_function(source, "run_gate_test")
    assert run_gate_body =~ "--only-real-provider --real-path model"
    assert run_gate_body =~ "--only-real-provider --real-path combined"
    assert run_gate_body =~ ~S(*"$provider_key_value"*)
    assert source =~ ~S([ "$last_gate_provider" = "$model_provider" ])
    assert source =~ ~S([ "$last_gate_model" = "$model_name" ])
    assert source =~ ~S([ "$last_gate_endpoint" = "$model_endpoint" ])
    assert source =~ ~S([ "$last_gate_adapter_build" = "$model_adapter_build" ])
    assert source =~ ~S(case "$capture_record" in)

    fake_home =
      Path.join(System.tmp_dir!(), "m1-fake-home-#{System.unique_integer([:positive])}")

    File.mkdir_p!(fake_home)
    on_exit(fn -> File.rm_rf(fake_home) end)
    actual_home = System.user_home!()

    {output, status} =
      System.cmd(
        "/bin/bash",
        ["-p", "scripts/check-m1-gate.sh"],
        cd: root,
        env: [
          {"HOME", fake_home},
          {"TMPDIR", Path.join(actual_home, ".loopex")},
          {"MIX_HOME", Path.join(actual_home, ".mix")}
        ],
        stderr_to_stdout: true
      )

    assert status != 0
    assert output =~ "supplied HOME does not physically match"

    protected_state = Path.join(actual_home, ".loopex")

    protected_controls = [
      {"TMPDIR", [{"TMPDIR", protected_state}, {"MIX_HOME", Path.join(actual_home, ".mix")}]},
      {"MIX_HOME", [{"TMPDIR", "/tmp"}, {"MIX_HOME", protected_state}]}
    ]

    Enum.each(protected_controls, fn {name, controls} ->
      {output, status} =
        System.cmd(
          "/bin/bash",
          ["-p", "scripts/check-m1-gate.sh", "--environment-fixture"],
          cd: root,
          env: [{"HOME", actual_home} | controls],
          stderr_to_stdout: true
        )

      assert status != 0, "#{name} unexpectedly passed:\n#{output}"
      assert output =~ "inside the protected user state directory"
      refute output =~ "M1 environment preflight OK"
    end)

    {output, status} =
      System.cmd(
        "/bin/bash",
        [
          "-c",
          "exec /bin/bash -p scripts/check-m1-gate.sh --loopex-m1-sealed-inner --environment-fixture </dev/null"
        ],
        cd: root,
        stderr_to_stdout: true
      )

    assert status != 0
    assert output == "M1 gate RED: sealed launcher input is unavailable\n"

    shadow_root =
      Path.join(System.tmp_dir!(), "loopex-m0-absence.#{System.unique_integer([:positive])}")

    File.mkdir_p!(shadow_root)
    on_exit(fn -> File.rm_rf(shadow_root) end)

    environment_manager = "py" <> "env"

    shadow_names =
      ~w(python python2 python3 jq xcrun uv) ++
        [environment_manager] ++ ~w(pipx poetry conda python3.13)

    Enum.each(shadow_names, fn name ->
      stub =
        "#!/bin/sh\n" <>
          "echo \"#{name} is retired; outcome 8 requires its absence\" >&2\n" <>
          "exit 127\n"

      path = Path.join(shadow_root, name)
      File.write!(path, stub)
      File.chmod!(path, 0o755)
    end)

    incoming_path = System.fetch_env!("PATH")

    {output, 0} =
      System.cmd(
        "/bin/bash",
        ["-p", "scripts/check-m1-gate.sh", "--environment-fixture"],
        cd: root,
        env: [{"PATH", shadow_root <> ":" <> incoming_path}],
        stderr_to_stdout: true
      )

    {physical_shadow_root, 0} =
      System.cmd("/bin/bash", ["-c", "cd -P -- \"$1\" && pwd -P", "_", shadow_root])

    assert output =~ "P" <> "ATH=" <> String.trim(physical_shadow_root) <> ":"
    assert output =~ "M1 environment preflight OK"

    extra = Path.join(shadow_root, "mix")
    File.write!(extra, "#!/bin/sh\nexit 0\n")
    File.chmod!(extra, 0o755)

    {output, status} =
      System.cmd(
        "/bin/bash",
        ["-p", "scripts/check-m1-gate.sh", "--environment-fixture"],
        cd: root,
        env: [{"PATH", shadow_root <> ":" <> incoming_path}],
        stderr_to_stdout: true
      )

    assert status != 0
    assert output =~ "M0 absence root contains an unexpected entry"
    File.rm!(extra)

    File.write!(Path.join(shadow_root, "jq"), "#!/bin/sh\nexit 127\n")

    {output, status} =
      System.cmd(
        "/bin/bash",
        ["-p", "scripts/check-m1-gate.sh", "--environment-fixture"],
        cd: root,
        env: [{"PATH", shadow_root <> ":" <> incoming_path}],
        stderr_to_stdout: true
      )

    assert status != 0
    assert output =~ "M0 absence root contains a noncanonical stub"
  end

  test "the read-only prefix disables optional Git locks before repository inspection" do
    source = runner_source()
    launcher = launcher_source()
    lines = String.split(source, "\n")
    allocation = "isolated_root=\"$(mktemp -d \"$task_tmp_root/loopex-m1-task.XXXXXX\")\" \\"

    allocation_index = Enum.find_index(lines, &(&1 == allocation))
    assert is_integer(allocation_index)

    path_name = "P" <> "ATH"

    direct_mutation =
      Regex.compile!(
        "(^|[[:space:]]|;|\\(|\\{)(export|declare|typeset|local|readonly|unset|read|mapfile|readarray|for|select)" <>
          "([[:space:]]+-[^[:space:]]*)*([[:space:]]+[^[:space:]]+)*[[:space:]]+[\\\"']?" <>
          path_name <>
          "[\\\"']?([^[:alnum:]_]|$)|(^|[[:space:]]|;|\\(|\\{)[\\\"']?" <>
          path_name <>
          "[\\\"']?([[:space:]]*=|\\[)|printf[[:space:]]+([^[:space:]]+[[:space:]]+)*-v[[:space:]]+[\\\"']?" <>
          path_name <>
          "[\\\"']?",
        "m"
      )

    assert Enum.flat_map(String.split(source, "\n"), &Regex.scan(direct_mutation, &1)) == []
    assert Enum.flat_map(String.split(launcher, "\n"), &Regex.scan(direct_mutation, &1)) == []
    refute source =~ "declare -n"
    refute source =~ "local -n"
    refute Regex.match?(~r/eval[^\n]*P(?:ATH)/, source)
    refute Regex.match?(~r/\$\{![A-Za-z_]/, source)

    assert source =~ "PATH) ;;"
    assert launcher =~ "Clear = [{Name, false} || Name <- InheritedNames]"
    assert launcher =~ ~S|{"GIT_OPTIONAL_LOCKS", "0"}|
    assert launcher =~ "{env, Clear ++ Canonical}"
    assert launcher =~ "-define(MAX_CONTROL_BYTES, 262144)."
    assert launcher =~ "file:read(standard_io, 65536)"
    assert launcher =~ "NewSize =< ?MAX_CONTROL_BYTES"
    refute launcher =~ "read_all(<<"
    assert source =~ "/usr/bin/env -i"

    [_, launch_block] = String.split(launcher, "launch(Arguments, Controls =", parts: 2)
    [child_setup, frame_setup] = String.split(launch_block, "inner_frame({", parts: 2)
    refute child_setup =~ "ProviderKey"
    assert frame_setup =~ "ProviderKey"
    assert source =~ ~S|"$provider_key_value"|
    refute source =~ ~r/\/usr\/bin\/env -i[^\n]*provider_key_value/

    git_indices =
      lines
      |> Enum.take(allocation_index)
      |> Enum.with_index()
      |> Enum.reject(fn {line, _index} -> String.starts_with?(String.trim_leading(line), "#") end)
      |> Enum.filter(fn {line, _index} ->
        Regex.match?(~r/(^|[^A-Za-z0-9_])git[[:space:]]/, line)
      end)
      |> Enum.map(&elem(&1, 1))

    assert git_indices != []
    assert Enum.all?(git_indices, &(&1 < allocation_index))
    assert Enum.any?(Enum.take(lines, allocation_index), &String.contains?(&1, "git status"))

    red_index =
      Enum.find_index(
        lines,
        &String.contains?(&1, "require_named_test apps/loopex/test/runtime_test.exs")
      )

    assert is_integer(red_index)

    pre_red = lines |> Enum.take(red_index) |> Enum.join("\n")
    refute pre_red =~ "<<<"
    refute Regex.match?(~r/(^|\n)\s*<<[-]?\s*/, pre_red)
    refute Regex.match?(~r/[<>]\(/, pre_red)

    unwritable_tmp =
      Path.join(System.tmp_dir!(), "m1-read-only-tmp-#{System.unique_integer([:positive])}")

    File.mkdir_p!(unwritable_tmp)
    File.chmod!(unwritable_tmp, 0o555)

    on_exit(fn ->
      File.chmod(unwritable_tmp, 0o700)
      File.rm_rf(unwritable_tmp)
    end)

    {output, status} =
      System.cmd(
        "/bin/bash",
        ["-p", "scripts/check-m1-gate.sh"],
        cd: repo_root(),
        env: [{"TMPDIR", unwritable_tmp}],
        stderr_to_stdout: true
      )

    assert status != 0
    assert output =~ "no apps/loopex/test/runtime_test.exs"
    assert File.ls!(unwritable_tmp) == []
  end

  test "platform filesystem identity and SHA-256 select validated dialects" do
    source = runner_source()

    functions =
      Enum.map_join(
        [
          "valid_node_id",
          "valid_entry_mode",
          "detect_stat_style",
          "node_id",
          "entry_mode"
        ],
        "\n",
        &shell_function(source, &1)
      )

    root = Path.join(System.tmp_dir!(), "m1-stat-#{System.unique_integer([:positive])}")
    bin = Path.join(root, "bin")
    probe = Path.join(root, "probe")
    File.mkdir_p!(bin)
    File.write!(probe, "probe\n")
    on_exit(fn -> File.rm_rf(root) end)

    variants = [
      {"bsd",
       """
       case "$1:$2" in
         '-f:%d:%i') printf '12:34'; exit 0 ;;
         '-f:%Lp') printf '755'; exit 0 ;;
         *) exit 1 ;;
       esac
       """},
      {"gnu",
       """
       case "$1:$2" in
         '-f:%d:%i') printf 'filesystem report\\nnoise'; exit 1 ;;
         '-c:%d:%i') printf '12:34'; exit 0 ;;
         '-c:%a') printf '755'; exit 0 ;;
         *) exit 1 ;;
       esac
       """},
      {"gnu",
       """
       case "$1:$2" in
         '-f:%d:%i') printf 'malformed-success'; exit 0 ;;
         '-c:%d:%i') printf '12:34'; exit 0 ;;
         '-c:%a') printf '755'; exit 0 ;;
         *) exit 1 ;;
       esac
       """}
    ]

    Enum.each(variants, fn {expected, body} ->
      stat = Path.join(bin, "stat")
      File.write!(stat, "#!/bin/bash\n#{body}")
      File.chmod!(stat, 0o700)

      script =
        functions <>
          "\nstat_style=\"$(detect_stat_style)\" || exit 9\n" <>
          "printf '%s|%s|%s' \"$stat_style\" \"$(node_id \"$1\")\" \"$(entry_mode \"$1\")\"\n"

      expected_output = "#{expected}|12:34|755"

      assert {^expected_output, 0} =
               System.cmd("/bin/bash", ["-c", script, "stat-fixture", probe],
                 env: [{"PATH", "#{bin}:/usr/bin:/bin"}],
                 stderr_to_stdout: true
               )
    end)

    sha256_functions =
      Enum.map_join(
        ["detect_sha256_style", "sha256_stream", "sha256_file"],
        "\n",
        &shell_function(source, &1)
      )

    empty_digest = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

    valid_shasum =
      "[ \"$1:$2\" = '-a:256' ] || exit 1\n" <>
        "printf '#{empty_digest}  -\\n'\n"

    valid_sha256sum = "printf '#{empty_digest}  -\\n'\n"
    malformed = "printf 'malformed-success\\n'\n"
    unavailable = "exit 1\n"

    sha256_variants = [
      {:ok, "shasum", valid_shasum, valid_sha256sum},
      {:ok, "sha256sum", unavailable, valid_sha256sum},
      {:ok, "sha256sum", malformed, valid_sha256sum},
      {:error, nil, malformed, malformed}
    ]

    Enum.each(sha256_variants, fn {result, expected, shasum_body, sha256sum_body} ->
      for {name, body} <- [{"shasum", shasum_body}, {"sha256sum", sha256sum_body}] do
        executable = Path.join(bin, name)
        File.write!(executable, "#!/bin/bash\n#{body}")
        File.chmod!(executable, 0o700)
      end

      script =
        sha256_functions <>
          "\nsha256_style=\"$(detect_sha256_style)\" || exit 9\n" <>
          "printf '%s|' \"$sha256_style\"\n" <>
          "printf '' | sha256_stream || exit 10\n" <>
          "printf '|'\nsha256_file \"$1\" || exit 11\n"

      case result do
        :ok ->
          expected_output = "#{expected}|#{empty_digest}|#{empty_digest}"

          assert {^expected_output, 0} =
                   System.cmd("/bin/bash", ["-c", script, "sha256-fixture", probe],
                     env: [{"PATH", "#{bin}:/usr/bin:/bin"}],
                     stderr_to_stdout: true
                   )

        :error ->
          assert {"", 9} =
                   System.cmd("/bin/bash", ["-c", script, "sha256-fixture", probe],
                     env: [{"PATH", "#{bin}:/usr/bin:/bin"}],
                     stderr_to_stdout: true
                   )
      end
    end)
  end

  test "the user-state fingerprint includes every entry identity and a command-line symlink target root" do
    source = runner_source()
    lines = String.split(source, "\n")

    baseline_index =
      Enum.find_index(lines, &String.starts_with?(&1, "user_state_before=\"$(real_user_state)\""))

    first_source_inventory_index =
      Enum.find_index(lines, &String.starts_with?(&1, "validate_source_tree \"$source_mix_home"))

    first_copy_index =
      Enum.find_index(lines, &String.starts_with?(String.trim_leading(&1), "cp -RL "))

    assert is_integer(baseline_index)
    assert is_integer(first_source_inventory_index)
    assert is_integer(first_copy_index)
    assert baseline_index < first_source_inventory_index
    assert baseline_index < first_copy_index

    functions =
      Enum.map_join(
        [
          "resolve_physical",
          "valid_node_id",
          "valid_entry_mode",
          "detect_stat_style",
          "node_id",
          "entry_mode",
          "detect_sha256_style",
          "sha256_stream",
          "sha256_file",
          "manifest_record",
          "root_target_record"
        ],
        "\n",
        &shell_function(source, &1)
      )

    assert source =~ ~s(root_target_record "$real_user_state_path" >> "$manifest")

    root = Path.join(System.tmp_dir!(), "m1-root-link-#{System.unique_integer([:positive])}")
    target = Path.join(root, "target")
    link = Path.join(root, "state")
    File.mkdir_p!(target)
    File.chmod!(target, 0o755)
    :ok = File.ln_s(target, link)
    on_exit(fn -> File.rm_rf(root) end)

    fingerprint = fn ->
      case System.cmd(
             "bash",
             [
               "-c",
               functions <>
                 "\nstat_style=\"$(detect_stat_style)\"\n" <>
                 "sha256_style=\"$(detect_sha256_style)\"\n" <>
                 "root_target_record \"$1\"",
               "--",
               link
             ],
             stderr_to_stdout: true
           ) do
        {output, 0} -> output
        {output, status} -> flunk("root-target fingerprint exited #{status}: #{output}")
      end
    end

    directory_before = fingerprint.()
    File.chmod!(target, 0o700)
    directory_after = fingerprint.()
    refute directory_before == directory_after

    File.rm_rf!(target)
    File.write!(target, "first\n")
    file_before = fingerprint.()
    File.write!(target, "second\n")
    file_after = fingerprint.()
    refute file_before == file_after

    state_root = Path.join(root, "ordinary-state")
    manifest_root = Path.join(root, "manifest")
    state_file = Path.join(state_root, "record")
    replacement = Path.join(root, "replacement")
    File.mkdir_p!(state_root)
    File.mkdir_p!(manifest_root)
    File.write!(state_file, "same bytes\n")
    File.chmod!(state_file, 0o600)

    state_functions =
      Enum.map_join(
        [
          "resolve_physical",
          "valid_node_id",
          "valid_entry_mode",
          "detect_stat_style",
          "node_id",
          "entry_mode",
          "detect_sha256_style",
          "sha256_stream",
          "sha256_file",
          "manifest_record",
          "root_target_record",
          "real_user_state"
        ],
        "\n",
        &shell_function(source, &1)
      )

    state_fingerprint = fn ->
      script =
        state_functions <>
          "\nstat_style=\"$(detect_stat_style)\"\n" <>
          "sha256_style=\"$(detect_sha256_style)\"\n" <>
          "isolated_root=\"$2\"\nprotected_file_ids=\"$2/protected-file-ids\"\n" <>
          "real_user_state_path=\"$1\"\nreal_user_state\n"

      case System.cmd(
             "/bin/bash",
             ["-c", script, "fingerprint", state_root, manifest_root],
             stderr_to_stdout: true
           ) do
        {output, 0} -> output
        {output, status} -> flunk("state fingerprint exited #{status}: #{output}")
      end
    end

    before_replace = state_fingerprint.()
    File.write!(replacement, "same bytes\n")
    File.chmod!(replacement, 0o600)
    File.rename!(replacement, state_file)
    after_replace = state_fingerprint.()
    refute before_replace == after_replace

    weird = Path.join(state_root, "line\ncolumn\tback\\slash")
    renamed = Path.join(state_root, "line\ncolumn\tback\\slash-renamed")
    File.write!(weird, "weird name bytes\n")
    weird_before = state_fingerprint.()
    File.rename!(weird, renamed)
    weird_after = state_fingerprint.()
    refute weird_before == weird_after

    target_one = Path.join(state_root, "target\none\t\\")
    target_two = Path.join(state_root, "target\ntwo\t\\")
    link_name = Path.join(state_root, "link\nname\t\\")
    File.write!(target_one, "same target bytes\n")
    File.write!(target_two, "same target bytes\n")
    :ok = File.ln_s(Path.basename(target_one), link_name)
    target_before = state_fingerprint.()
    File.rm!(link_name)
    :ok = File.ln_s(Path.basename(target_two), link_name)
    target_after = state_fingerprint.()
    refute target_before == target_after
  end

  test "prerequisite copies refuse protected-state hard links and symlinks" do
    source = runner_source()

    functions =
      Enum.map_join(
        [
          "fail",
          "resolve_physical",
          "valid_node_id",
          "valid_entry_mode",
          "detect_stat_style",
          "node_id",
          "lower",
          "outside_protected_state",
          "refuse_protected_file_aliases",
          "validate_source_tree"
        ],
        "\n",
        &shell_function(source, &1)
      )

    root = Path.join(System.tmp_dir!(), "m1-source-links-#{System.unique_integer([:positive])}")
    protected = Path.join(root, "home/.loopex")
    mix_parent = Path.join(root, "home/.mix")
    deps_parent = Path.join(root, "repo")
    descendant = Path.join(root, "ordinary-source")
    external = Path.join(root, "external-source")
    loop_source = Path.join(root, "loop-source")
    hardlink_source = Path.join(root, "hardlink-source")
    safe_source = Path.join(root, "safe-source")
    absent_protected = Path.join(root, "absent-home/.loopex")
    protected_link = Path.join(root, "protected-link")
    inventory = Path.join(root, "inventory")
    File.mkdir_p!(protected)
    File.mkdir_p!(mix_parent)
    File.mkdir_p!(deps_parent)
    File.mkdir_p!(descendant)
    File.mkdir_p!(external)
    File.mkdir_p!(loop_source)
    File.mkdir_p!(hardlink_source)
    File.mkdir_p!(safe_source)
    File.mkdir_p!(inventory)
    protected_file = Path.join(protected, "secret")
    File.write!(protected_file, "protected bytes\n")
    File.ln!(protected_file, Path.join(hardlink_source, "alias"))
    safe_file = Path.join(safe_source, "one")
    File.write!(safe_file, "safe bytes\n")
    File.ln!(safe_file, Path.join(safe_source, "two"))
    :ok = File.ln_s(protected, Path.join(mix_parent, "elixir"))
    :ok = File.ln_s(protected, Path.join(deps_parent, "deps"))
    :ok = File.ln_s(protected, Path.join(descendant, "nested"))
    :ok = File.ln_s("/etc/hosts", Path.join(external, "external"))
    :ok = File.ln_s("loop", Path.join(loop_source, "loop"))
    :ok = File.ln_s(protected, protected_link)
    on_exit(fn -> File.rm_rf(root) end)

    script =
      "set -euo pipefail\n#{functions}\n" <>
        "stat_style=\"$(detect_stat_style)\"\n" <>
        "protected_resolved=\"$(resolve_physical \"$1\")\"\n" <>
        "protected_parent=\"${protected_resolved%/*}\"\n" <>
        "protected_name=\"${protected_resolved##*/}\"\n" <>
        "protected_parent_id=\"$(node_id \"$protected_parent\")\" || protected_parent_id=\"\"\n" <>
        "protected_id=\"$(node_id \"$protected_resolved\")\" || protected_id=\"\"\n" <>
        "protected_lc=\"$(lower \"${protected_resolved%/}\")\"\n" <>
        "protected_name_lc=\"$(lower \"$protected_name\")\"\n" <>
        "isolated_root=\"$3\"\nprotected_file_ids=\"$3/protected-file-ids\"\n" <>
        ": > \"$protected_file_ids\"\n" <>
        "if [ -f \"$1/secret\" ]; then node_id \"$1/secret\" > \"$protected_file_ids\"; fi\n" <>
        "source_validation_index=0\n" <>
        "validate_source_tree \"$2\" \"fixture prerequisite\"\n"

    for path <- [Path.join(mix_parent, "elixir"), Path.join(deps_parent, "deps")] do
      {output, status} =
        System.cmd("/bin/bash", ["-c", script, "containment", protected, path, inventory],
          stderr_to_stdout: true
        )

      assert status != 0
      assert output =~ "protected"
    end

    for path <- [descendant, external, loop_source] do
      {output, status} =
        System.cmd(
          "/bin/bash",
          ["-c", script, "containment", protected, path, inventory],
          stderr_to_stdout: true
        )

      assert status != 0
      assert output =~ "contains a symlink and cannot become isolated owned input"
    end

    for protected_root <- [protected, protected_link] do
      {output, status} =
        System.cmd(
          "/bin/bash",
          ["-c", script, "containment", protected_root, hardlink_source, inventory],
          stderr_to_stdout: true
        )

      assert status != 0
      assert output =~ "hard-link alias of protected user state"
    end

    assert {"", 0} =
             System.cmd(
               "/bin/bash",
               ["-c", script, "containment", protected, safe_source, inventory],
               stderr_to_stdout: true
             )

    assert {"", 0} =
             System.cmd(
               "/bin/bash",
               ["-c", script, "containment", absent_protected, safe_source, inventory],
               stderr_to_stdout: true
             )

    tracked_root = Path.join(root, "tracked")
    File.mkdir_p!(Path.join(tracked_root, "docs/evidence"))
    git!(tracked_root, ["init", "-q"])
    File.write!(Path.join(tracked_root, "target.md"), "ordinary target\n")

    tracked_functions =
      Enum.map_join(["fail", "require_tracked_regular"], "\n", &shell_function(source, &1))

    for {path, label} <- [
          {"docs/evidence/M1-toolchain-matrix.md", "matrix evidence"},
          {"README.md", "closure document"}
        ] do
      link = Path.join(tracked_root, path)
      File.mkdir_p!(Path.dirname(link))

      :ok =
        File.ln_s(
          Path.relative_to(Path.join(tracked_root, "target.md"), Path.dirname(link)),
          link
        )

      git!(tracked_root, ["add", "target.md", path])

      {output, status} =
        System.cmd(
          "/bin/bash",
          [
            "-c",
            tracked_functions <> "\nrequire_tracked_regular \"$1\" \"$2\"\n",
            "tracked",
            path,
            label
          ],
          cd: tracked_root,
          stderr_to_stdout: true
        )

      assert status != 0
      assert output =~ "is not an ordinary regular file"
      File.rm!(link)
      git!(tracked_root, ["rm", "--cached", "-q", path])
    end
  end

  test "owned candidate and generated closures exclude ambient aliases" do
    source = runner_source()
    runner_clone = "git clone --quiet --no-hardlinks --no-checkout -- \\\n"

    mix_home_resolution =
      "source_mix_home=\"$(resolve_physical \"$loopex_m1_source_mix_home_input\")\""

    detached_checkout =
      "git -C \"$candidate_checkout\" checkout --quiet --detach \"$source_candidate\" \\\n" <>
        "  || fail \"the exact source candidate could not be checked out\""

    owned_checkout_entry =
      detached_checkout <>
        "\nrepository_root=\"$(resolve_physical \"$candidate_checkout\")\"" <>
        "\n[ -n \"$repository_root\" ] && [ -d \"$repository_root\" ] \\\n" <>
        "  || fail \"the owned candidate checkout is unavailable\"" <>
        "\ncd -- \"$repository_root\" || fail \"the owned candidate checkout could not be entered\""

    assert 1 ==
             source
             |> String.split("\n")
             |> Enum.count(&(&1 == String.trim_trailing(runner_clone)))

    assert 1 ==
             source
             |> String.split("\n")
             |> Enum.count(&(&1 == mix_home_resolution))

    assert 1 ==
             source
             |> String.split(owned_checkout_entry)
             |> length()
             |> Kernel.-(1)

    allocation_offset =
      :binary.match(source, "isolated_root=\"$(mktemp -d") |> elem(0)

    mix_home_offset = :binary.match(source, mix_home_resolution) |> elem(0)
    clone_offset = :binary.match(source, runner_clone) |> elem(0)
    checkout_offset = :binary.match(source, owned_checkout_entry) |> elem(0)
    assert mix_home_offset < allocation_offset
    assert allocation_offset < clone_offset
    assert clone_offset < checkout_offset

    root = Path.join(System.tmp_dir!(), "m1-owned-#{System.unique_integer([:positive])}")
    source_root = Path.join(root, "source")
    clone_root = Path.join(root, "clone")
    protected = Path.join(root, "home/.loopex")
    isolated = Path.join(root, "isolated")
    File.mkdir_p!(Path.join(source_root, "apps/fixture/lib"))
    File.mkdir_p!(protected)
    File.mkdir_p!(isolated)
    on_exit(fn -> File.rm_rf(root) end)

    protected_file = Path.join(protected, "secret")
    tracked_alias = Path.join(source_root, "apps/fixture/lib/input.ex")
    File.write!(protected_file, "candidate bytes\n")
    File.ln!(protected_file, tracked_alias)
    File.write!(Path.join(source_root, "mix.exs"), "# fixture\n")
    git!(source_root, ["init", "-q"])
    git!(source_root, ["config", "user.name", "Loopex Test"])
    git!(source_root, ["config", "user.email", "loopex-test@example.invalid"])
    commit!(source_root, "fixture source")

    exclude = Path.join(source_root, ".git/info/exclude")
    File.write!(exclude, File.read!(exclude) <> "\napps/rogue/\n")
    rogue = Path.join(source_root, "apps/rogue/mix.exs")
    File.mkdir_p!(Path.dirname(rogue))
    File.write!(rogue, "# ignored rogue project\n")

    assert String.trim(git!(source_root, ["status", "--porcelain=v1", "--untracked-files=all"])) ==
             ""

    assert {_, 0} =
             System.cmd(
               "git",
               [
                 "clone",
                 "--quiet",
                 "--no-hardlinks",
                 "--no-checkout",
                 "--",
                 source_root,
                 clone_root
               ],
               stderr_to_stdout: true
             )

    candidate = source_root |> git!(["rev-parse", "HEAD"]) |> String.trim()
    git!(clone_root, ["checkout", "--quiet", "--detach", candidate])
    refute File.exists?(Path.join(clone_root, "apps/rogue/mix.exs"))
    clone_file = Path.join(clone_root, "apps/fixture/lib/input.ex")
    assert File.read!(clone_file) == File.read!(protected_file)

    source_stat = File.stat!(tracked_alias)
    clone_stat = File.stat!(clone_file)

    refute {source_stat.major_device, source_stat.inode} ==
             {clone_stat.major_device, clone_stat.inode}

    functions =
      Enum.map_join(
        [
          "fail",
          "resolve_physical",
          "valid_node_id",
          "valid_entry_mode",
          "detect_stat_style",
          "node_id",
          "lower",
          "outside_protected_state",
          "refuse_protected_file_aliases",
          "generated_target_allowed",
          "validate_generated_tree"
        ],
        "\n",
        &shell_function(source, &1)
      )

    script =
      "set -euo pipefail\n#{functions}\n" <>
        "stat_style=\"$(detect_stat_style)\"\n" <>
        "protected_resolved=\"$(resolve_physical \"$1\")\"\n" <>
        "protected_parent=\"${protected_resolved%/*}\"\n" <>
        "protected_name=\"${protected_resolved##*/}\"\n" <>
        "protected_parent_id=\"$(node_id \"$protected_parent\")\" || protected_parent_id=\"\"\n" <>
        "protected_id=\"$(node_id \"$protected_resolved\")\" || protected_id=\"\"\n" <>
        "protected_lc=\"$(lower \"${protected_resolved%/}\")\"\n" <>
        "protected_name_lc=\"$(lower \"$protected_name\")\"\n" <>
        "isolated_root=\"$(resolve_physical \"$2\")\"\n" <>
        "protected_file_ids=\"$2/protected-file-ids\"\n" <>
        "node_id \"$1/secret\" > \"$protected_file_ids\"\n" <>
        "source_validation_index=0\nvalidate_generated_tree \"$3\" \"fixture generated tree\"\n"

    nested_one = Path.join(isolated, "nested-one")
    nested_two = Path.join(isolated, "nested-two")
    hardlink_build = Path.join(isolated, "build-hardlink")
    File.mkdir_p!(nested_one)
    File.mkdir_p!(nested_two)
    File.mkdir_p!(hardlink_build)
    File.ln!(protected_file, Path.join(nested_two, "alias"))
    File.ln_s!(nested_two, Path.join(nested_one, "next"))
    File.ln_s!(nested_one, Path.join(hardlink_build, "priv"))

    assert {output, status} =
             System.cmd(
               "/bin/bash",
               ["-c", script, "generated", protected, isolated, hardlink_build],
               stderr_to_stdout: true
             )

    assert status != 0
    assert output =~ "hard-link alias of protected user state"

    outside_build = Path.join(isolated, "build-outside")
    File.mkdir_p!(outside_build)
    File.ln_s!("/etc/hosts", Path.join(outside_build, "priv"))

    assert {output, status} =
             System.cmd(
               "/bin/bash",
               ["-c", script, "generated", protected, isolated, outside_build],
               stderr_to_stdout: true
             )

    assert status != 0
    assert output =~ "outside the isolated task root"

    safe_target = Path.join(isolated, "safe-target")
    safe_build = Path.join(isolated, "safe-build")
    File.mkdir_p!(safe_target)
    File.mkdir_p!(safe_build)
    File.write!(Path.join(safe_target, "value"), "safe\n")
    File.ln_s!(safe_target, Path.join(safe_target, "cycle"))
    File.ln_s!(safe_target, Path.join(safe_build, "priv"))

    assert {"", 0} =
             System.cmd(
               "/bin/bash",
               ["-c", script, "generated", protected, isolated, safe_build],
               stderr_to_stdout: true
             )

    lines = String.split(source, "\n")

    dev_compile =
      Enum.find_index(
        lines,
        &(&1 == "mix compile --warnings-as-errors || fail \"compilation is not warning-free\"")
      )

    dev_validation =
      Enum.find_index(lines, &String.contains?(&1, "compiled development application tree"))

    test_compile =
      Enum.find_index(
        lines,
        &String.starts_with?(&1, "MIX_ENV=test MIX_BUILD_PATH=\"$test_build_path\" mix compile")
      )

    test_validation =
      Enum.find_index(
        lines,
        &String.contains?(&1, "isolated compiled test application tree")
      )

    for index <- [dev_compile, dev_validation, test_compile, test_validation] do
      assert is_integer(index)
    end

    assert dev_compile < dev_validation
    assert dev_validation < test_compile
    assert test_compile < test_validation

    run_gate_body = shell_function(source, "run_gate_test")
    selector_validation = :binary.match(run_gate_body, "before selector consumption") |> elem(0)
    selector_start = :binary.match(run_gate_body, "context_output=\"$(") |> elem(0)
    assert selector_validation < selector_start

    pre_full_suite =
      "validate_generated_tree \"$test_build_path\" \\\n" <>
        "  \"the compiled test application tree before the full suite\""

    assert 1 ==
             source
             |> String.split(pre_full_suite)
             |> length()
             |> Kernel.-(1)

    pre_full_suite_offset = :binary.match(source, pre_full_suite) |> elem(0)
    full_suite = :binary.match(source, "mix test --exclude real_provider") |> elem(0)

    final_dev =
      :binary.match(source, "the final compiled development application tree") |> elem(0)

    final_test = :binary.match(source, "the final compiled test application tree") |> elem(0)
    assert pre_full_suite_offset < full_suite
    assert full_suite < final_dev
    assert final_dev < final_test
  end
end
