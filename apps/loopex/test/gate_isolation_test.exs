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
