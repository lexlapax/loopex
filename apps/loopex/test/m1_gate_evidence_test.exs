defmodule Loopex.M1GateEvidenceTest do
  @moduledoc """
  ## Concept

  Adversarial tests for the two retained-evidence readers added by the M1 gate.
  They prove the readers reject structurally fabricated rows and restoration
  claims rather than merely accepting the intended fixtures.

  ## Technical depth

  Matrix cases exercise the explicit M1 profile and its four adjacency edges.
  Negative-demonstration cases inject committed and current byte readers, so
  each structural or digest rule is reached without depending on ambient Git
  history.
  """

  use ExUnit.Case, async: true

  alias Mix.Tasks.Loopex.M1Evidence
  alias Mix.Tasks.Loopex.Matrix

  @candidate String.duplicate("a", 40)
  @artifact "apps/loopex/lib/loopex/runtime.ex"
  @blob "restored product bytes\n"
  @digest :crypto.hash(:sha256, @blob) |> Base.encode16(case: :lower)
  @pairs [
    %{elixir: "1.17.0", otp: "26", otp_exact: "26.0"},
    %{elixir: "1.20.3", otp: "29", otp_exact: "29.0.5"}
  ]

  defp matrix_root do
    root = Path.join(System.tmp_dir!(), "m1-matrix-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "docs/evidence"))
    File.mkdir_p!(Path.join(root, "docs/plans"))

    git!(root, ["init", "-q"])
    git!(root, ["config", "user.name", "Loopex Test"])
    git!(root, ["config", "user.email", "loopex-test@example.invalid"])

    File.write!(Path.join(root, "README.md"), "# Before the M1 gate\n")
    git!(root, ["add", "README.md"])
    git!(root, ["-c", "commit.gpgsign=false", "commit", "-q", "-m", "test pre-gate"])
    absent_gate_candidate = root |> git!(["rev-parse", "HEAD"]) |> String.trim()

    File.write!(Path.join(root, "docs/plans/M1-gate.md"), "# Stale M1 gate\n")
    git!(root, ["add", "docs/plans/M1-gate.md"])
    git!(root, ["-c", "commit.gpgsign=false", "commit", "-q", "-m", "test stale gate"])
    stale_gate_candidate = root |> git!(["rev-parse", "HEAD"]) |> String.trim()

    gate = "# Test M1 gate\n"
    File.write!(Path.join(root, "docs/plans/M1-gate.md"), gate)
    git!(root, ["add", "docs/plans/M1-gate.md"])
    git!(root, ["-c", "commit.gpgsign=false", "commit", "-q", "-m", "test gate"])

    candidate = root |> git!(["rev-parse", "HEAD"]) |> String.trim()
    on_exit(fn -> File.rm_rf(root) end)

    %{
      root: root,
      candidate: candidate,
      absent_gate_candidate: absent_gate_candidate,
      stale_gate_candidate: stale_gate_candidate,
      gate_sha256: :crypto.hash(:sha256, gate) |> Base.encode16(case: :lower)
    }
  end

  defp git!(root, args) do
    case System.cmd("git", args, cd: root, stderr_to_stdout: true) do
      {output, 0} -> output
      {output, status} -> raise "git #{Enum.join(args, " ")} exited #{status}: #{output}"
    end
  end

  defp runner_source do
    File.read!(Path.expand("../../../scripts/check-m1-gate.sh", __DIR__))
  end

  defp shell_function(source, name) do
    case Regex.run(~r/^#{Regex.escape(name)}\(\) \{\n.*?^\}\n/ms, source) do
      [function] -> function
      nil -> flunk("runner does not define #{name} as a top-level shell function")
    end
  end

  defp metadata(context, overrides \\ %{}) do
    values =
      Map.merge(
        %{
          candidate: context.candidate,
          gate_sha256: context.gate_sha256,
          command: "bash:scripts/check-m1-gate.sh",
          platform: "test-platform",
          limits: "test-limits"
        },
        overrides
      )

    "matrix candidate=#{values.candidate} gate_sha256=#{values.gate_sha256} " <>
      "command=#{values.command} platform=#{values.platform} limits=#{values.limits}"
  end

  defp matrix_document(lines, identity \\ nil) do
    body = if identity, do: [identity | lines], else: lines

    """
    <!-- loopex:matrix-runs:start -->
    ```text
    #{Enum.join(body, "\n")}
    ```
    <!-- loopex:matrix-runs:end -->
    """
  end

  defp run(number, order, lane, verdict \\ "GREEN", exit_code \\ "0") do
    pair = Enum.at(@pairs, lane)

    "run=#{number} order=#{order} elixir=#{pair.elixir} otp=#{pair.otp_exact} " <>
      "erts=retained seed=#{number} executed=100 verdict=#{verdict} exit=#{exit_code} wall=1s"
  end

  defp m0_run(number, lane) do
    pair = Enum.at(@pairs, lane)

    "run=#{number} order=legacy elixir=#{pair.elixir} otp=#{pair.otp_exact} " <>
      "erts=retained verdict=GREEN exit=0 wall=1s"
  end

  defp valid_runs do
    [
      run(1, "first", 0),
      run(2, "second", 0),
      run(3, "third", 1),
      run(4, "fourth", 1),
      run(5, "fifth", 0)
    ]
  end

  defp runs_for(lanes) do
    1..5
    |> Enum.zip(~w(first second third fourth fifth))
    |> Enum.zip(lanes)
    |> Enum.map(fn {{number, order}, lane} -> run(number, order, lane) end)
  end

  defp write_matrix(context, lines, identity \\ nil) do
    identity = identity || metadata(context)

    File.write!(
      Path.join(context.root, "docs/evidence/M1-toolchain-matrix.md"),
      matrix_document(lines, identity)
    )
  end

  defp write_m0_matrix(root, lines) do
    File.write!(Path.join(root, "docs/evidence/M0-toolchain-matrix.md"), matrix_document(lines))
  end

  test "the no-argument M0 record remains the default and M1 never falls back to it" do
    context = matrix_root()
    root = context.root
    m0_runs = [m0_run(8, 0), m0_run(9, 1)]
    write_m0_matrix(root, m0_runs)

    File.write!(
      Path.join(root, ".tool-versions"),
      "elixir 1.17.0-otp-26\nerlang 26.0\nelixir 1.20.3-otp-29\nerlang 29.0.5\n"
    )

    assert :ok = Matrix.both_lanes_recorded(root, @pairs)
    assert {:ok, _running_pair} = Matrix.check(root)

    assert {:error, message} =
             Matrix.both_lanes_recorded(
               root,
               @pairs,
               "docs/evidence/M1-toolchain-matrix.md",
               :m1
             )

    assert message =~ "M1-toolchain-matrix.md"
    assert message =~ "unavailable"
  end

  test "matrix command refuses partial unknown and ambiguous explicit arguments" do
    for args <- [
          ["--profile", "m1"],
          ["--evidence", "docs/evidence/M1-toolchain-matrix.md"],
          ["--evidence", "docs/evidence/M0-toolchain-matrix.md", "--profile", "m1"],
          ["--evidence", "docs/evidence/M1-toolchain-matrix.md", "--profile", "unknown"],
          [
            "--evidence",
            "docs/evidence/M1-toolchain-matrix.md",
            "--evidence",
            "docs/evidence/M1-toolchain-matrix.md",
            "--profile",
            "m1"
          ],
          ["--evidence", "docs/evidence/M1-toolchain-matrix.md", "--profile", "m1", "extra"]
        ] do
      assert_raise Mix.Error, ~r/usage: mix loopex\.matrix/, fn -> Matrix.run(args) end
    end
  end

  test "M1 matrix requires the five-run walk covering all four adjacencies" do
    context = matrix_root()
    root = context.root
    write_matrix(context, valid_runs())

    assert :ok =
             Matrix.both_lanes_recorded(
               root,
               @pairs,
               "docs/evidence/M1-toolchain-matrix.md",
               :m1
             )

    refused = [
      {"one failing row", List.replace_at(valid_runs(), 2, run(3, "third", 1, "NOT_GREEN", "1")),
       "not GREEN with exit 0"},
      {"only four rows", Enum.drop(valid_runs(), -1), "exactly five"},
      {"a sixth row", valid_runs() ++ [run(6, "sixth", 0)], "exactly five"},
      {"duplicate run number", List.replace_at(valid_runs(), 4, run(4, "fifth", 0)),
       "run numbers"},
      {"wrong order label", List.replace_at(valid_runs(), 4, run(5, "last", 0)), "order fields"},
      {"floor-to-floor adjacency missing", runs_for([0, 1, 1, 0, 1]), "all four"},
      {"floor-to-current adjacency missing", runs_for([1, 1, 1, 0, 0]), "all four"},
      {"current-to-floor adjacency missing", runs_for([0, 0, 0, 1, 1]), "all four"},
      {"current-to-current adjacency missing", runs_for([1, 0, 0, 1, 0]), "all four"},
      {"an unlocked pair",
       List.replace_at(
         valid_runs(),
         2,
         "run=3 order=third elixir=1.19.0 otp=28.0 erts=x seed=3 executed=100 verdict=GREEN exit=0 wall=1s"
       ), "either exact locked pair"}
    ]

    for {label, lines, reason} <- refused do
      write_matrix(context, lines)

      assert {:error, message} =
               Matrix.both_lanes_recorded(
                 root,
                 @pairs,
                 "docs/evidence/M1-toolchain-matrix.md",
                 :m1
               )

      assert message =~ reason, "#{label} failed for the wrong reason: #{message}"
    end
  end

  test "M1 matrix metadata binds the reachable candidate current gate command platform and limits" do
    context = matrix_root()
    root = context.root

    refused = [
      {"an unreachable candidate", metadata(context, %{candidate: String.duplicate("b", 40)}),
       "does not carry a reachable gate blob"},
      {"a reachable ancestor without the gate",
       metadata(context, %{candidate: context.absent_gate_candidate}),
       "does not carry a reachable gate blob"},
      {"a reachable ancestor with different gate bytes",
       metadata(context, %{candidate: context.stale_gate_candidate}),
       "candidate gate does not match the recorded digest"},
      {"a wrong gate digest", metadata(context, %{gate_sha256: String.duplicate("0", 64)}),
       "does not match the current gate"},
      {"another command", metadata(context, %{command: "bash:other.sh"}), "required form"},
      {"a missing platform", metadata(context, %{platform: ""}), "required form"},
      {"a missing limits field", metadata(context) |> String.replace(~r/ limits=\S+\z/, ""),
       "required form"},
      {"duplicate metadata", metadata(context) <> "\n" <> metadata(context),
       "exactly one metadata record"}
    ]

    for {label, identity, reason} <- refused do
      write_matrix(context, valid_runs(), identity)

      assert {:error, message} =
               Matrix.both_lanes_recorded(
                 root,
                 @pairs,
                 "docs/evidence/M1-toolchain-matrix.md",
                 :m1
               )

      assert message =~ reason, "#{label} failed for the wrong reason: #{message}"
    end

    malformed_runs = [
      {"a missing seed", String.replace(hd(valid_runs()), ~r/ seed=\d+/, "")},
      {"a nonnumeric executed count",
       String.replace(hd(valid_runs()), "executed=100", "executed=many")},
      {"a zero executed count", String.replace(hd(valid_runs()), "executed=100", "executed=0")}
    ]

    for {label, first} <- malformed_runs do
      write_matrix(context, [first | tl(valid_runs())])

      assert {:error, message} =
               Matrix.both_lanes_recorded(
                 root,
                 @pairs,
                 "docs/evidence/M1-toolchain-matrix.md",
                 :m1
               )

      assert message =~ "run is not in the required form", "#{label} unexpectedly passed"
    end

    write_matrix(context, valid_runs())

    assert :ok =
             Matrix.both_lanes_recorded(
               root,
               @pairs,
               "docs/evidence/M1-toolchain-matrix.md",
               :m1
             )
  end

  defp json_record(overrides \\ %{}) do
    values =
      Map.merge(
        %{
          "mechanism_disabled" => "disable the production transition",
          "observed_failure" => "the named protected assertion failed",
          "candidate" => @candidate,
          "artifact" => @artifact,
          "restored_sha256" => "sha256:#{@digest}"
        },
        overrides
      )

    ~s({"mechanism_disabled":"#{values["mechanism_disabled"]}",) <>
      ~s("observed_failure":"#{values["observed_failure"]}",) <>
      ~s("candidate":"#{values["candidate"]}",) <>
      ~s("artifact":"#{values["artifact"]}",) <>
      ~s("restored_sha256":"#{values["restored_sha256"]}"})
  end

  defp outcome(number, record \\ json_record()) do
    "## Outcome #{number}\n\n```json\n#{record}\n```\n"
  end

  defp evidence(overrides \\ %{}) do
    "# M1 Negative Demonstrations\n\n" <>
      Enum.map_join([2, 3, 6, 8], "\n", fn number ->
        outcome(number, Map.get(overrides, number, json_record()))
      end)
  end

  defp validate(text, committed \\ @blob, current \\ @blob) do
    M1Evidence.validate(
      text,
      "docs/evidence/M1-negative-demonstrations.md",
      fn
        @candidate, @artifact -> committed
        _candidate, _artifact -> nil
      end,
      fn
        @artifact -> {:ok, current}
        artifact -> {:error, "unexpected artifact #{artifact}"}
      end
    )
  end

  test "negative evidence binds one visible JSON record per constitutional outcome" do
    assert :ok = validate(evidence())

    refused = [
      {"a missing outcome", evidence() |> String.replace(outcome(6) <> "\n", ""),
       "canonical fixed"},
      {"a duplicate outcome", evidence() <> "\n" <> outcome(8), "canonical fixed"},
      {"a misleading extra outcome heading", evidence() <> "\n## Outcome summary\n",
       "canonical fixed"},
      {"an outcome at the wrong heading depth",
       String.replace(evidence(), "## Outcome 3", "### Outcome 3"), "canonical fixed"},
      {"an entity-spelled duplicate heading", evidence() <> "\n## Outc&#111;me 2\n",
       "canonical fixed"},
      {"a Setext duplicate heading", evidence() <> "\nOutcome 2\n---------\n", "canonical fixed"},
      {"an outcome heading hidden in a fence",
       String.replace(evidence(), outcome(3), "```text\n" <> outcome(3) <> "```\n"),
       "canonical fixed"},
      {"a prose object outside a fence",
       String.replace(
         evidence(),
         "```json\n#{json_record()}\n```",
         json_record(),
         global: false
       ), "canonical fixed"},
      {"a multiline JSON object",
       String.replace(
         evidence(),
         json_record(),
         String.replace(json_record(), ",", ",\n", global: false),
         global: false
       ), "canonical fixed"},
      {"a duplicate JSON key",
       String.replace(
         evidence(),
         json_record(),
         String.replace(json_record(), "{", ~s({"candidate":"#{@candidate}",), global: false),
         global: false
       ), "duplicate key"},
      {"an extra JSON key",
       String.replace(
         evidence(),
         json_record(),
         String.replace(json_record(), "}", ~s(,"note":"x"}), global: false),
         global: false
       ), "must carry exactly"},
      {"a placeholder mechanism", evidence(%{2 => json_record(%{"mechanism_disabled" => "TBD"})}),
       "not populated"},
      {"an escaped right-to-left override",
       evidence(%{2 => json_record(%{"mechanism_disabled" => "\\u202edisabled mechanism"})}),
       "printable ASCII"},
      {"an escaped newline",
       evidence(%{2 => json_record(%{"observed_failure" => "failed\\nthen passed"})}),
       "printable ASCII"},
      {"a short candidate", evidence(%{2 => json_record(%{"candidate" => "abc"})}),
       "full lowercase"},
      {"an absolute artifact", evidence(%{2 => json_record(%{"artifact" => "/tmp/file"})}),
       "safe repository-relative"},
      {"a traversing artifact", evidence(%{2 => json_record(%{"artifact" => "apps/../secret"})}),
       "safe repository-relative"},
      {"nested Git metadata",
       evidence(%{2 => json_record(%{"artifact" => "apps/example/.git/config"})}),
       "may not name Git metadata"},
      {"a malformed digest", evidence(%{2 => json_record(%{"restored_sha256" => "sha256:abc"})}),
       "malformed"}
    ]

    for {label, text, reason} <- refused do
      assert {:error, message} = validate(text)
      assert message =~ reason, "#{label} failed for the wrong reason: #{message}"
    end
  end

  test "negative evidence requires both the committed and current blob to equal the digest" do
    assert {:error, message} = validate(evidence(), "changed candidate bytes\n", @blob)
    assert message =~ "candidate blob"

    assert {:error, message} = validate(evidence(), @blob, "dirty current bytes\n")
    assert message =~ "current blob"

    assert {:error, message} =
             M1Evidence.validate(
               evidence(),
               "docs/evidence/M1-negative-demonstrations.md",
               fn _candidate, _artifact -> nil end,
               fn _artifact -> {:ok, @blob} end
             )

    assert message =~ "not reachable from HEAD"

    root = Path.join(System.tmp_dir!(), "m1-restoration-#{System.unique_integer([:positive])}")
    outside = "#{root}-outside"
    artifact = "artifacts/restored.ex"
    File.mkdir_p!(Path.join(root, "docs/evidence"))
    File.mkdir_p!(Path.join(root, "artifacts"))
    File.mkdir_p!(outside)
    File.write!(Path.join(root, artifact), @blob)
    File.write!(Path.join(outside, "restored.ex"), @blob)
    git!(root, ["init", "-q"])
    git!(root, ["config", "user.name", "Loopex Test"])
    git!(root, ["config", "user.email", "loopex-test@example.invalid"])
    git!(root, ["add", artifact])
    git!(root, ["-c", "commit.gpgsign=false", "commit", "-q", "-m", "test artifact"])
    candidate = root |> git!(["rev-parse", "HEAD"]) |> String.trim()

    restored_evidence =
      evidence()
      |> String.replace(@candidate, candidate)
      |> String.replace(@artifact, artifact)

    File.write!(Path.join(root, "docs/evidence/M1-negative-demonstrations.md"), restored_evidence)
    {:ok, _removed} = File.rm_rf(Path.join(root, "artifacts"))
    :ok = File.ln_s(outside, Path.join(root, "artifacts"))

    on_exit(fn ->
      File.rm_rf(root)
      File.rm_rf(outside)
    end)

    assert {:error, message} = M1Evidence.check(root)
    assert message =~ "not a tracked regular file"
  end

  test "the read-only prefix disables optional Git locks before repository inspection" do
    lines = String.split(runner_source(), "\n")
    export = "export GIT_OPTIONAL_LOCKS=0"
    allocation = "isolated_root=\"$(mktemp -d \"${TMPDIR:-/tmp}/loopex-m1-task.XXXXXX\")\" \\"

    assert 1 == Enum.count(lines, &(&1 == export))
    export_index = Enum.find_index(lines, &(&1 == export))
    allocation_index = Enum.find_index(lines, &(&1 == allocation))
    assert is_integer(allocation_index)

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
    assert Enum.all?(git_indices, &(&1 > export_index and &1 < allocation_index))
    assert Enum.any?(Enum.take(lines, allocation_index), &String.contains?(&1, "git status"))
    assert export_index < Enum.find_index(lines, &String.contains?(&1, "env_output=\"$(env)\""))

    lock_mutations =
      lines
      |> Enum.take(allocation_index)
      |> Enum.with_index()
      |> Enum.filter(fn {line, _index} ->
        Regex.match?(
          ~r/^\s*(?:(?:export(?: -n)? )?GIT_OPTIONAL_LOCKS=|unset GIT_OPTIONAL_LOCKS)/,
          line
        )
      end)

    assert lock_mutations == [{export, export_index}]
  end

  test "the user-state fingerprint includes a command-line symlink target root" do
    source = runner_source()

    functions =
      Enum.map_join(
        ["resolve_physical", "node_id", "entry_mode", "root_target_record"],
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
             ["-c", functions <> ~s(\nroot_target_record "$1"), "--", link],
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
  end
end
