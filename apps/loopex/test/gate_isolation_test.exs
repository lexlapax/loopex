defmodule Loopex.GateIsolationTest do
  @moduledoc false

  use ExUnit.Case, async: false

  # Concept: the gate runner makes a claim about itself, and a claim a runner
  # makes about its own isolation needs a locked definition for the same reason a
  # product claim does.
  #
  # Technical depth: the runner says it compiles and runs outside the checkout.
  # An ambient `MIX_BUILD_PATH` — which Mix resolves ahead of `MIX_BUILD_ROOT` —
  # silently made that claim false, to the point where the opening probe reported
  # itself unavailable instead of observing the loop. Prose in the runner about
  # the runner is not evidence, so both halves are proved here: the hazard is
  # demonstrated against the real Mix that resolves it, and the runner's own
  # bytes are shown to clear the variable everywhere it could still bite.

  @runner "scripts/check-m2-gate.sh"

  # Concept: find the runner from the selector, not from the working directory.
  #
  # Technical depth: the gate compiles a protected selector from the repository
  # root, while `mix test` runs it from the application directory, and the test
  # helper that resolves the root is not loaded under the gate at all. Walking up
  # from this file's own location answers the same in both.
  defp repository_root, do: Path.expand(Path.join([__DIR__, "..", "..", ".."]))

  defp runner_source, do: File.read!(Path.join(repository_root(), @runner))

  defp with_environment(pairs, fun) do
    previous = Map.new(pairs, fn {name, _value} -> {name, System.get_env(name)} end)

    try do
      Enum.each(pairs, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)

      fun.()
    after
      Enum.each(previous, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end
  end

  test "an ambient MIX_BUILD_PATH cannot redirect gate owned compilation out of the owned build root" do
    config = [app: :isolation_probe, build_per_environment: true]
    owned = Path.join(System.tmp_dir!(), "loopex-owned-build")
    ambient = Path.join(System.tmp_dir!(), "loopex-ambient-build")

    # The hazard is real, and it is demonstrated against the same Mix the runner
    # invokes rather than described. With both set, the ambient path wins and the
    # owned root is not where anything would be built.
    #
    # `Mix.Project.build_path/1` is asked where Mix is running, and where the
    # selector was compiled on its own — which is how the gate runs it — the
    # precedence is read from a real `mix` invocation instead. Both answer the
    # same question; neither is a restatement of the runner's comment.
    redirected = build_path_under(config, ambient, owned)
    assert redirected == ambient
    refute String.starts_with?(redirected, owned)

    # Cleared, the owned root is honoured. This is the whole of what the runner's
    # `unset` and its `env -u` buy, stated as a result rather than as intent.
    contained = build_path_under(config, nil, owned)
    assert String.starts_with?(contained, owned)

    # And the runner clears it everywhere it could still bite. The global `unset`
    # covers the locked commands; anything invoking a compiler before that line
    # has to clear the variable for itself, because the export has not happened
    # yet.
    source = runner_source()
    lines = String.split(source, "\n")

    assert Enum.any?(lines, &(String.trim(&1) == "unset MIX_BUILD_PATH")),
           "the runner must clear MIX_BUILD_PATH for the locked commands"

    unset_at = Enum.find_index(lines, &(String.trim(&1) == "unset MIX_BUILD_PATH"))

    early_invocations =
      lines
      |> Enum.take(unset_at)
      |> Enum.with_index()
      |> Enum.filter(fn {line, _index} ->
        trimmed = String.trim(line)

        not String.starts_with?(trimmed, "#") and
          (Regex.match?(~r/(^|\s)mix\s/, trimmed) or Regex.match?(~r/(^|\s)elixir\s/, trimmed))
      end)

    for {line, index} <- early_invocations do
      window =
        lines
        |> Enum.slice(max(index - 4, 0)..index)
        |> Enum.join("\n")

      assert window =~ "env -u MIX_BUILD_PATH",
             "line #{index + 1} invokes a compiler before the global unset " <>
               "without clearing MIX_BUILD_PATH: #{String.trim(line)}"
    end

    assert early_invocations != [],
           "the probe runs before the global unset; a scan finding nothing is not proof"
  end

  defp build_path_under(config, ambient, owned) do
    if Code.ensure_loaded?(Mix.State) and Process.whereis(Mix.State) do
      with_environment([{"MIX_BUILD_PATH", ambient}, {"MIX_BUILD_ROOT", owned}], fn ->
        Mix.Project.build_path(config)
      end)
    else
      # Mix's own resolution order, asked of a real `mix` in a throwaway project
      # rather than reproduced here: a copy of the rule would pass while the rule
      # changed underneath it.
      root =
        Path.join(System.tmp_dir!(), "loopex-mix-probe-#{System.unique_integer([:positive])}")

      File.mkdir_p!(Path.join(root, "lib"))

      File.write!(Path.join(root, "mix.exs"), """
      defmodule IsolationProbe.MixProject do
        use Mix.Project
        def project, do: [app: :isolation_probe, version: "0.0.0", elixir: "~> 1.17"]
      end
      """)

      environment =
        [{"MIX_BUILD_ROOT", owned}] ++
          if(is_nil(ambient), do: [], else: [{"MIX_BUILD_PATH", ambient}])

      {output, 0} =
        System.cmd("mix", ["run", "--no-start", "-e", "IO.puts(Mix.Project.build_path())"],
          cd: root,
          env: environment ++ if(is_nil(ambient), do: [{"MIX_BUILD_PATH", nil}], else: []),
          stderr_to_stdout: true
        )

      File.rm_rf(root)
      output |> String.split("\n", trim: true) |> List.last()
    end
  end

  test "the gate refuses an owned root that resolves inside the checkout or the operator's product state" do
    source = runner_source()

    # The guard is executed, not read. Its exact bytes are lifted from the runner
    # so a rewritten or deleted guard fails here rather than leaving a stale copy
    # of it passing in this file.
    guard =
      Regex.run(
        ~r/case "\$task_root" in\n(?:.*\n)*?esac\n/,
        source
      )

    assert guard, "the runner no longer carries a task-root containment guard"
    [block] = guard

    assert block =~ "resolves inside the operator's product state"
    assert block =~ "resolves inside the checkout"

    root = Path.join(System.tmp_dir!(), "loopex-guard-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)

    script = Path.join(root, "guard.sh")

    File.write!(script, """
    #!/bin/sh
    fail() { printf 'FAIL %s\\n' "$1"; exit 1; }
    repository_root="$1"
    user_state_root="$2"
    task_root="$3"
    #{block}
    printf 'ADMITTED\\n'
    """)

    File.chmod!(script, 0o755)

    run = fn task_root ->
      {output, status} =
        System.cmd("/bin/sh", [script, "/checkout", "/home/user/.loopex", task_root],
          stderr_to_stdout: true
        )

      {String.trim(output), status}
    end

    # Inside the checkout is not isolation, and the runner says so rather than
    # running there.
    assert {refused_checkout, 1} = run.("/checkout/_build/gate")
    assert refused_checkout =~ "checkout"

    assert {refused_root, 1} = run.("/checkout")
    assert refused_root =~ "checkout"

    # The operator's own product state is refused for a stronger reason: a run
    # there would not merely fail to isolate, it would write the sessions an
    # operator keeps.
    assert {refused_state, 1} = run.("/home/user/.loopex/gate")
    assert refused_state =~ "product state"

    assert {refused_exact, 1} = run.("/home/user/.loopex")
    assert refused_exact =~ "product state"

    # A root outside both is admitted, so the guard is a containment check and
    # not a refusal of everything.
    assert {"ADMITTED", 0} = run.("/private/var/tmp/loopex-m2-gate.abc123")

    # A path that merely begins with the same characters is not inside either
    # tree, and a prefix test that admitted it would be refusing real roots.
    assert {"ADMITTED", 0} = run.("/checkout-other/gate")
    assert {"ADMITTED", 0} = run.("/home/user/.loopex-backup")
  end
end

defmodule Loopex.M2EvidenceLifecycleGateTest do
  @moduledoc false

  use ExUnit.Case, async: false

  @runner "scripts/check-m2-gate.sh"
  @evidence_paths [
    "docs/evidence/M2-coding-demonstration.md",
    "docs/evidence/M2-negative-demonstrations.md",
    "docs/evidence/M2-real-call-attestations.md",
    "docs/evidence/M2-toolchain-matrix.md"
  ]
  @digest String.duplicate("a", 64)
  @accepted_candidate String.duplicate("b", 40)

  defp repository_root, do: Path.expand(Path.join([__DIR__, "..", "..", ".."]))
  defp runner_source, do: File.read!(Path.join(repository_root(), @runner))

  defp lifecycle_source do
    case Regex.run(
           ~r/cat <<'LOOPEX_M2_EVIDENCE_LIFECYCLE'\n(.*?)\nLOOPEX_M2_EVIDENCE_LIFECYCLE/s,
           runner_source()
         ) do
      [_, source] -> source
      nil -> flunk("the runner carries no extractable M2 evidence lifecycle validator")
    end
  end

  defp shell_function(source, name) do
    case Regex.run(~r/^#{Regex.escape(name)}\(\) \{(?:[^\n]*\}\n|\n.*?^\}\n)/ms, source) do
      [function] -> function
      nil -> flunk("runner does not define #{name} as a top-level shell function")
    end
  end

  defp git!(root, args) do
    case System.cmd("git", ["-C", root | args], stderr_to_stdout: true) do
      {output, 0} -> output
      {output, status} -> flunk("git #{Enum.join(args, " ")} failed #{status}: #{output}")
    end
  end

  defp commit!(root, message) do
    git!(root, ["add", "-A"])

    git!(root, [
      "-c",
      "commit.gpgsign=false",
      "commit",
      "-q",
      "--allow-empty",
      "-m",
      message
    ])

    root |> git!(["rev-parse", "HEAD"]) |> String.trim()
  end

  defp write!(root, relative, bytes) do
    path = Path.join(root, relative)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, bytes)
  end

  defp write_git_path!(root, relative, bytes) do
    path = root |> git!(["rev-parse", "--git-path", relative]) |> String.trim()
    path = Path.expand(path, root)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, bytes)
  end

  defp source_fixture!(options \\ []) do
    state = Keyword.get(options, :state, "In review")

    root =
      Path.join(System.tmp_dir!(), "m2-lifecycle-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    git!(root, ["init", "-q"])
    git!(root, ["config", "user.name", "Loopex Test"])
    git!(root, ["config", "user.email", "loopex-test@example.invalid"])
    on_exit(fn -> File.rm_rf(root) end)

    write!(root, "docs/plans/M2.md", plan_document(nil))
    write!(root, "docs/plans/README.md", plans_status(state))
    write!(root, "README.md", root_status(state))
    write!(root, "docs/developer/agent-context-map.md", "# Context\n\nExisting record.\n")
    write!(root, "docs/plans/M2-gate.md", "fixture gate generation one\n")
    write!(root, "scripts/check-m2-gate.sh", "fixture runner generation one\n")
    write!(root, "apps/fixture/lib/product.ex", "defmodule Fixture.Product, do: nil\n")

    Enum.each(@evidence_paths, &write!(root, &1, "uncaptured #{&1}\n"))

    %{root: root, candidate: commit!(root, "fixture source candidate")}
  end

  defp commit_evidence!(context, suffix \\ "captured") do
    Enum.each(@evidence_paths, fn path ->
      write!(context.root, path, "#{suffix} #{path}\n")
    end)

    Map.put(context, :evidence, commit!(context.root, "fixture evidence"))
  end

  defp close!(context, options \\ []) do
    anchor = Keyword.get(options, :anchor, "disposition-m2-fixture-closure")
    candidate = Keyword.get(options, :candidate, context.evidence)

    write!(
      context.root,
      "docs/plans/M2.md",
      plan_document(candidate, anchor, options) <> Keyword.get(options, :plan_suffix, "")
    )

    plans_state = Keyword.get(options, :plans_state, "Closed")

    write!(
      context.root,
      "docs/plans/README.md",
      plans_status(plans_state, Keyword.get(options, :plans_current_state, plans_state)) <>
        Keyword.get(options, :plans_suffix, "")
    )

    root_state = Keyword.get(options, :root_state, "Closed")

    write!(
      context.root,
      "README.md",
      root_status(root_state) <> Keyword.get(options, :root_suffix, "")
    )

    context_bytes = File.read!(Path.join(context.root, "docs/developer/agent-context-map.md"))

    write!(
      context.root,
      "docs/developer/agent-context-map.md",
      context_bytes <>
        "\n<a id=\"#{anchor}\"></a>\n" <>
        Keyword.get(
          options,
          :disposition_record,
          "## M2 fixture closure\n\nThe maintainer closed M2.\n"
        )
    )

    if Keyword.get(options, :product, false) do
      write!(context.root, "apps/fixture/lib/bundled.ex", "defmodule Fixture.Bundled, do: nil\n")
    end

    Map.put(context, :transition, commit!(context.root, "fixture closure transition"))
  end

  defp run_lifecycle(context, source \\ lifecycle_source()) do
    System.cmd("elixir", ["-e", source],
      cd: context.root,
      env: [
        {"LOOPEX_M2_SOURCE_CANDIDATE", context.candidate},
        {"ERL_CRASH_DUMP", "/dev/null"},
        {"ERL_CRASH_DUMP_SECONDS", "0"}
      ],
      stderr_to_stdout: true
    )
  end

  defp assert_refused(context, phrase) do
    assert {output, status} = run_lifecycle(context)
    assert status != 0, "invalid history was admitted: #{output}"
    assert output =~ phrase, "expected #{inspect(phrase)} in refusal, got: #{output}"
  end

  defp plan_document(
         closure_candidate,
         anchor \\ "disposition-m2-fixture-closure",
         options \\ []
       ) do
    concept = Keyword.get(options, :concept_digest, @digest)
    technical = Keyword.get(options, :technical_digest, @digest)
    gate = Keyword.get(options, :gate_digest, @digest)

    closure =
      if closure_candidate do
        "| Closure | Maintainer | " <>
          "[disposition](../developer/agent-context-map.md##{anchor}) | " <>
          "candidate `#{closure_candidate}`; concept `sha256:#{concept}`; " <>
          "technical `sha256:#{technical}`; gate `sha256:#{gate}` |"
      else
        "| Closure | — | — | — |"
      end

    """
    # Fixture M2

    ## Governance Records

    | Decision | Authority | Authority evidence | Bound bytes |
    | --- | --- | --- | --- |
    | Acceptance | Maintainer | [disposition](acceptance.md) | candidate `#{@accepted_candidate}`; concept `sha256:#{@digest}`; technical `sha256:#{@digest}`; gate `sha256:#{@digest}` |
    #{closure}
    """
  end

  defp plans_status(state, current_state \\ nil) do
    current_state = current_state || state

    """
    # Plans

    <!-- loopex:current-status:start -->
    ## Current Status

    M2 is #{current_state}.
    <!-- loopex:current-status:end -->

    Stable plans text.

    <!-- loopex:milestone-register:start -->
    ## Milestone Register

    | Milestone | State | Concept | Technical depth | Gate |
    | --- | --- | --- | --- | --- |
    | M2 | #{state} | [Concept](M2.md) | [Technical](M2-technical.md) | [Gate](M2-gate.md) |
    <!-- loopex:milestone-register:end -->
    """
  end

  defp root_status(state) do
    """
    # Loopex

    <!-- loopex:readme-status:start -->
    ## Where Things Stand

    M2 is #{state}.
    <!-- loopex:readme-status:end -->

    Stable root text.
    """
  end

  test "the evidence lifecycle admits its direct evidence closure and later descendants" do
    context = source_fixture!() |> commit_evidence!()
    assert {"M2 evidence lifecycle OK\n", 0} = run_lifecycle(context)

    context = close!(context)
    assert {"M2 evidence lifecycle OK\n", 0} = run_lifecycle(context)

    write!(context.root, "apps/fixture/lib/later.ex", "defmodule Fixture.Later, do: nil\n")
    _later = commit!(context.root, "later product work")
    assert {"M2 evidence lifecycle OK\n", 0} = run_lifecycle(context)

    plan = File.read!(Path.join(context.root, "docs/plans/M2.md"))

    write!(
      context.root,
      "docs/plans/M2.md",
      plan <> "\n## Gate Generations\n\n| 2 | accepted |\n"
    )

    write!(context.root, "docs/plans/M2-gate.md", "fixture gate generation two\n")
    write!(context.root, "scripts/check-m2-gate.sh", "fixture runner generation two\n")
    _generation = commit!(context.root, "later accepted gate generation")
    assert {"M2 evidence lifecycle OK\n", 0} = run_lifecycle(context)

    context_map = File.read!(Path.join(context.root, "docs/developer/agent-context-map.md"))

    write!(
      context.root,
      "docs/developer/agent-context-map.md",
      context_map <>
        "\n<a id=\"disposition-later-milestone\"></a>\n## Later disposition\n\nAccepted.\n"
    )

    _later_disposition = commit!(context.root, "later disposition")
    assert {"M2 evidence lifecycle OK\n", 0} = run_lifecycle(context)
  end

  test "the evidence lifecycle requires one atomic direct four document evidence child" do
    shallow = source_fixture!() |> commit_evidence!()
    write_git_path!(shallow.root, "shallow", "#{shallow.candidate}\n")
    assert_refused(shallow, "history is shallow")

    replacement = source_fixture!() |> commit_evidence!()
    git!(replacement.root, ["replace", replacement.candidate, replacement.evidence])
    assert_refused(replacement, "history uses replacement objects")

    grafted = source_fixture!() |> commit_evidence!()
    write_git_path!(grafted.root, "info/grafts", "#{grafted.evidence} #{grafted.candidate}\n")
    assert_refused(grafted, "history uses grafts")

    missing = source_fixture!()
    Enum.take(@evidence_paths, 3) |> Enum.each(&write!(missing.root, &1, "captured\n"))
    _commit = commit!(missing.root, "incomplete evidence")
    assert_refused(missing, "no direct evidence-only child")

    bundled = source_fixture!()
    Enum.each(@evidence_paths, &write!(bundled.root, &1, "captured\n"))
    write!(bundled.root, "unrelated.txt", "bundled\n")
    _commit = commit!(bundled.root, "bundled evidence")
    assert_refused(bundled, "no direct evidence-only child")

    interposed = source_fixture!()
    write!(interposed.root, "unrelated.txt", "interposed\n")
    _commit = commit!(interposed.root, "interposed work")
    interposed = commit_evidence!(interposed)
    assert_refused(interposed, "no direct evidence-only child")

    empty_interposed = source_fixture!()
    _commit = commit!(empty_interposed.root, "empty interposed work")
    empty_interposed = commit_evidence!(empty_interposed)
    assert_refused(empty_interposed, "no direct evidence-only child")

    nonordinary = source_fixture!()
    Enum.each(@evidence_paths, &write!(nonordinary.root, &1, "captured\n"))
    File.chmod!(Path.join(nonordinary.root, hd(@evidence_paths)), 0o755)
    _commit = commit!(nonordinary.root, "nonordinary evidence")
    assert_refused(nonordinary, "no direct evidence-only child")

    wrong_state = source_fixture!(state: "Accepted") |> commit_evidence!() |> close!()
    assert_refused(wrong_state, "M2 is not In review")

    duplicate = source_fixture!()
    git!(duplicate.root, ["checkout", "-q", "-b", "evidence-one", duplicate.candidate])
    one = commit_evidence!(duplicate, "first").evidence
    git!(duplicate.root, ["checkout", "-q", "-b", "evidence-two", duplicate.candidate])
    duplicate = commit_evidence!(duplicate, "second")
    git!(duplicate.root, ["merge", "-q", "--no-ff", "-s", "ours", "-m", "join evidence", one])
    assert_refused(duplicate, "more than one direct evidence-only child")

    Enum.each(@evidence_paths, fn path ->
      changed = source_fixture!() |> commit_evidence!()
      write!(changed.root, path, "changed after evidence\n")
      _commit = commit!(changed.root, "change retained evidence #{Path.basename(path)}")
      assert_refused(changed, "retained evidence changed")
    end)
  end

  test "closure binds the evidence commit in one transition and changes only derived status bytes" do
    interposed = source_fixture!() |> commit_evidence!()
    write!(interposed.root, "unrelated.txt", "interposed\n")
    _commit = commit!(interposed.root, "interposed work")
    interposed = close!(interposed)
    assert_refused(interposed, "not the direct one-parent child")

    bundled = source_fixture!() |> commit_evidence!() |> close!(product: true)
    assert_refused(bundled, "outside the four allowed paths")

    wrong = source_fixture!() |> commit_evidence!()
    wrong = close!(wrong, candidate: wrong.candidate)
    assert_refused(wrong, "does not bind the evidence commit")

    Enum.each([:concept_digest, :technical_digest, :gate_digest], fn key ->
      options = [{key, String.duplicate("c", 64)}]
      wrong_digest = source_fixture!() |> commit_evidence!() |> close!(options)
      assert_refused(wrong_digest, "does not bind the accepted envelope and gate digests")
    end)

    plan_extra = source_fixture!() |> commit_evidence!() |> close!(plan_suffix: "extra\n")
    assert_refused(plan_extra, "plan changes more than the Closure row")

    reused = source_fixture!()
    anchor = "disposition-m2-reused"

    write!(
      reused.root,
      "docs/developer/agent-context-map.md",
      "# Context\n\n<a id=\"#{anchor}\"></a>\nExisting record.\n"
    )

    reused = %{reused | candidate: commit!(reused.root, "candidate with old disposition")}
    reused = reused |> commit_evidence!() |> close!(anchor: anchor)
    assert_refused(reused, "anchor already existed")

    outside = source_fixture!() |> commit_evidence!() |> close!(plans_suffix: "not derived\n")
    assert_refused(outside, "outside its derived markers")

    one_marker =
      source_fixture!()
      |> commit_evidence!()
      |> close!(plans_state: "Closed", plans_current_state: "In review")

    assert_refused(one_marker, "required derived status marker did not change")

    not_closed =
      source_fixture!()
      |> commit_evidence!()
      |> close!(plans_state: "Accepted", root_state: "Accepted")

    assert_refused(not_closed, "M2 is not Closed")

    rewritten = source_fixture!() |> commit_evidence!()
    path = "docs/developer/agent-context-map.md"
    write!(rewritten.root, path, "# Rewritten context\n")
    rewritten = close!(rewritten)
    assert_refused(rewritten, "rewrites prior disposition bytes")

    prefixed = source_fixture!() |> commit_evidence!()
    path = Path.join(prefixed.root, "docs/developer/agent-context-map.md")

    write!(
      prefixed.root,
      "docs/developer/agent-context-map.md",
      File.read!(path) <> "unrelated\n"
    )

    prefixed = close!(prefixed)
    assert_refused(prefixed, "adds bytes outside its new disposition record")

    empty_disposition = source_fixture!() |> commit_evidence!() |> close!(disposition_record: "")
    assert_refused(empty_disposition, "Closure disposition record is incomplete")

    incomplete =
      source_fixture!()
      |> commit_evidence!()
      |> close!(root_state: "In review", root_suffix: "changed\n")

    assert_refused(incomplete, "required derived status marker did not change")
  end

  test "closed evidence closure and disposition cannot mutate or bypass their reviewed transition" do
    Enum.each(@evidence_paths, fn path ->
      evidence_mutation = source_fixture!() |> commit_evidence!() |> close!()
      original = File.read!(Path.join(evidence_mutation.root, path))
      write!(evidence_mutation.root, path, "temporary mutation\n")
      _changed = commit!(evidence_mutation.root, "mutate evidence #{Path.basename(path)}")
      write!(evidence_mutation.root, path, original)
      _restored = commit!(evidence_mutation.root, "restore evidence #{Path.basename(path)}")
      assert_refused(evidence_mutation, "retained evidence changed")
    end)

    closure_mutation = source_fixture!() |> commit_evidence!() |> close!()
    plan = File.read!(Path.join(closure_mutation.root, "docs/plans/M2.md"))

    changed_plan =
      String.replace(plan, "| Closure | Maintainer |", "| Closure | Delegate: fixture |")

    write!(closure_mutation.root, "docs/plans/M2.md", changed_plan)
    _changed = commit!(closure_mutation.root, "mutate closure")
    write!(closure_mutation.root, "docs/plans/M2.md", plan)
    _restored = commit!(closure_mutation.root, "restore closure")
    assert_refused(closure_mutation, "Closure row changed")

    disposition_mutation = source_fixture!() |> commit_evidence!() |> close!()
    path = "docs/developer/agent-context-map.md"
    record = File.read!(Path.join(disposition_mutation.root, path))
    write!(disposition_mutation.root, path, String.replace(record, "closed M2", "closed it"))
    _changed = commit!(disposition_mutation.root, "mutate disposition")
    write!(disposition_mutation.root, path, record)
    _restored = commit!(disposition_mutation.root, "restore disposition")
    assert_refused(disposition_mutation, "Closure disposition changed")

    disposition_extension = source_fixture!() |> commit_evidence!() |> close!()
    path = "docs/developer/agent-context-map.md"
    record = File.read!(Path.join(disposition_extension.root, path))
    write!(disposition_extension.root, path, record <> "unanchored mutation\n")
    _extended = commit!(disposition_extension.root, "extend closure disposition")
    assert_refused(disposition_extension, "Closure disposition changed")

    side = source_fixture!() |> commit_evidence!()
    git!(side.root, ["checkout", "-q", "-b", "side", side.evidence])
    write!(side.root, "side.txt", "unreviewed\n")
    side_revision = commit!(side.root, "side work")
    git!(side.root, ["checkout", "-q", "-b", "closure", side.evidence])
    side = close!(side)
    git!(side.root, ["merge", "-q", "--no-ff", "-m", "merge side", side_revision])
    assert_refused(side, "bypasses the Closure transition")

    repeated = source_fixture!() |> commit_evidence!() |> close!()
    closed_plan = File.read!(Path.join(repeated.root, "docs/plans/M2.md"))
    write!(repeated.root, "docs/plans/M2.md", plan_document(nil))
    _cleared = commit!(repeated.root, "clear closure")
    write!(repeated.root, "docs/plans/M2.md", closed_plan)
    _reclosed = commit!(repeated.root, "restore closure")
    assert_refused(repeated, "more than one first Closure transition")
  end

  test "candidate scoped retained digests answer for the revision each record names" do
    source = runner_source()

    association_script = """
    GATE_DOCUMENT=docs/plans/M2-gate.md
    #{shell_function(source, "matrix_candidate_digest_artifacts")}
    matrix_candidate_digest_artifacts
    """

    expected_associations = """
    gate_sha256|docs/plans/M2-gate.md
    runner_sha256|scripts/check-m2-gate.sh
    exunit_runner_sha256|scripts/m1-exunit-runner.exs
    exunit_corpus_sha256|apps/loopex/test/m1_exunit_runner_test.exs
    gate_corpus_sha256|apps/loopex/test/gate_isolation_test.exs
    composition_corpus_sha256|apps/loopex_composition/test/kernel_composition_test.exs
    tool_versions_sha256|.tool-versions
    """

    assert {^expected_associations, 0} =
             System.cmd("/bin/bash", ["-c", association_script], stderr_to_stdout: true)

    association_loop =
      case Regex.run(
             ~r/^  local key file\n(  while IFS='\|' read -r key file; do\n.*?^  done < <\(matrix_candidate_digest_artifacts\))/ms,
             source
           ) do
        [_, loop] ->
          loop

        nil ->
          flunk("validate_matrix no longer carries an extractable candidate-association loop")
      end

    candidate = String.duplicate("c", 40)

    association_digests =
      expected_associations
      |> String.split("\n", trim: true)
      |> Enum.with_index(1)
      |> Map.new(fn {association, index} ->
        [key, _path] = String.split(association, "|", parts: 2)
        {key, String.duplicate(Integer.to_string(index), 64)}
      end)

    header =
      ["matrix candidate=#{candidate}"] ++
        Enum.map(String.split(expected_associations, "\n", trim: true), fn association ->
          [key, _path] = String.split(association, "|", parts: 2)
          "#{key}=#{Map.fetch!(association_digests, key)}"
        end)

    loop_script = """
    set -euo pipefail
    GATE_DOCUMENT=docs/plans/M2-gate.md
    fail() { printf 'FAIL %s\n' "$1" >&2; exit 1; }
    #{shell_function(source, "matrix_candidate_digest_artifacts")}
    #{shell_function(source, "matrix_field")}
    require_candidate_digest() {
      printf '%s|%s|%s|%s\n' "$1" "$2" "$3" "$4"
    }
    exercise_associations() {
      local header='#{Enum.join(header, " ")}'
      local candidate='#{candidate}'
      local expect
      local key file
    #{association_loop}
    }
    exercise_associations
    """

    expected_calls =
      expected_associations
      |> String.split("\n", trim: true)
      |> Enum.map_join("\n", fn association ->
        [key, path] = String.split(association, "|", parts: 2)
        "#{candidate}|#{path}|#{Map.fetch!(association_digests, key)}|the retained matrix #{key}"
      end)
      |> Kernel.<>("\n")

    assert {^expected_calls, 0} =
             System.cmd("/bin/bash", ["-c", loop_script], stderr_to_stdout: true)

    root =
      Path.join(System.tmp_dir!(), "m2-candidate-digest-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    git!(root, ["init", "-q"])
    git!(root, ["config", "user.name", "Loopex Test"])
    git!(root, ["config", "user.email", "loopex-test@example.invalid"])
    on_exit(fn -> File.rm_rf(root) end)

    write!(root, "artifact.txt", "candidate bytes\n")
    candidate = commit!(root, "candidate")
    recorded = :crypto.hash(:sha256, "candidate bytes\n") |> Base.encode16(case: :lower)
    write!(root, "artifact.txt", "later bytes\n")
    _later = commit!(root, "later revision")

    dialect = if System.find_executable("shasum"), do: "shasum", else: "sha256sum"

    script = """
    set -uo pipefail
    fail() { printf '%s\n' "$1" >&2; exit 1; }
    digest_dialect=#{dialect}
    #{shell_function(source, "revision_file_digest")}
    #{shell_function(source, "require_candidate_digest")}
    require_candidate_digest "$1" artifact.txt "$2" fixture
    """

    assert {"", 0} =
             System.cmd("/bin/bash", ["-c", script, "candidate-digest", candidate, recorded],
               cd: root,
               stderr_to_stdout: true
             )

    assert {wrong, status} =
             System.cmd(
               "/bin/bash",
               ["-c", script, "candidate-digest", candidate, String.duplicate("0", 64)],
               cd: root,
               stderr_to_stdout: true
             )

    assert status != 0
    assert wrong =~ "candidate #{candidate}'s #{recorded}"

    assert source =~ "require_candidate_digest"
    assert source =~ "\"$candidate\" \"$artifact\" \"$restored\""

    assert source =~ "the retained matrix $key"
    assert source =~ "the M0 $lane re-proof"
    assert source =~ "the M1 re-proof"
    refute source =~ "file_digest \"$artifact\""
    refute source =~ "file_digest docs/plans/M0-gate.md"
  end
end
