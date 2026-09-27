defmodule Loopex.ClosureConfineTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Loopex.Closure.Confine

  @name "M6"

  setup do
    root = Path.join(System.tmp_dir!(), "closure-confine-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    git!(root, ["init", "--quiet"])
    git!(root, ["config", "user.email", "fixture@example.test"])
    git!(root, ["config", "user.name", "Fixture"])

    for {path, contents} <- tested_files() do
      write(root, path, contents)
    end

    git!(root, ["add", "."])
    git!(root, ["commit", "--quiet", "-m", "tested"])
    tested = git!(root, ["rev-parse", "HEAD"]) |> String.trim()
    %{root: root, tested: tested}
  end

  test "a direct-child administrative commit passes all five content regions and retains exact patch",
       context do
    {admin, patch} = admin!(context)
    assert {:ok, lines} = Confine.check(context.root, context.tested, admin, @name, patch)
    assert length(lines) == 10
    assert Enum.all?(lines, &String.starts_with?(&1, "PASS "))
    assert File.read!(patch) =~ "@@ -"
    assert File.read!(patch) =~ "| Closure |"
    assert {:error, _} = Confine.check(context.root, context.tested, admin, @name, patch)
  end

  test "arguments, missing parent, existing output and missing revision refuse without creating a patch",
       c do
    {admin, _} = admin!(c)

    for {tested, administrative, name, patch} <- [
          {"bad", admin, @name, Path.join(c.root, "bad-ref.patch")},
          {c.tested, "bad", @name, Path.join(c.root, "bad-admin.patch")},
          {c.tested, admin, "bad/name", Path.join(c.root, "bad-name.patch")},
          {c.tested, admin, @name, Path.join(c.root, "absent/out.patch")}
        ] do
      assert {:error, _} = Confine.check(c.root, tested, administrative, name, patch)
      refute File.exists?(patch)
    end

    existing = Path.join(c.root, "existing.patch")
    File.write!(existing, "sentinel")
    assert {:error, _} = Confine.check(c.root, c.tested, admin, @name, existing)
    assert File.read!(existing) == "sentinel"
  end

  test "parent and five-path inventory fail independently", c do
    {_admin, _} = admin!(c)
    extra = Path.join(c.root, "extra")
    write(c.root, "extra.txt", "extra\n")
    git!(c.root, ["add", "."])
    git!(c.root, ["commit", "--quiet", "-m", "extra"])
    grandchild = git!(c.root, ["rev-parse", "HEAD"]) |> String.trim()
    assert_refused(c, grandchild, "parent")
    refute File.exists?(extra)

    other = fixture_admin(c, fn files -> Map.put(files, "extra.txt", "extra\n") end)
    assert_refused(c, other, "paths")
  end

  test "every content region rejects a changed byte outside its allowance", c do
    for {label, mutate} <- [
          {"register",
           fn files ->
             Map.update!(
               files,
               "docs/plans/README.md",
               &String.replace(&1, "unchanged register prose", "changed register prose")
             )
           end},
          {"readme",
           fn files ->
             Map.update!(
               files,
               "README.md",
               &String.replace(&1, "unchanged introduction", "changed introduction")
             )
           end},
          {"closure",
           fn files ->
             Map.update!(
               files,
               "docs/plans/M6.md",
               &String.replace(&1, "unchanged plan prose", "changed plan prose")
             )
           end},
          {"context",
           fn files ->
             Map.update!(
               files,
               "docs/developer/agent-context-map.md",
               &String.replace(&1, "unchanged earlier disposition", "changed earlier disposition")
             )
           end},
          {"evidence",
           fn files ->
             Map.update!(
               files,
               "docs/evidence/M6-closure-runs.md",
               &String.replace(&1, "| Fixed label |", "| Changed label |")
             )
           end}
        ] do
      admin = fixture_admin(c, mutate)
      assert_refused(c, admin, label)
    end
  end

  test "mode change, symlink type and omitted path refuse", c do
    mode =
      fixture_admin(c, fn files -> files end, fn root ->
        File.chmod!(Path.join(root, "README.md"), 0o755)
      end)

    assert_refused(c, mode, "metadata")

    omitted =
      fixture_admin(c, fn files ->
        Map.put(
          files,
          "docs/evidence/M6-closure-runs.md",
          tested_files()["docs/evidence/M6-closure-runs.md"]
        )
      end)

    assert_refused(c, omitted, "paths")

    symlink =
      fixture_admin(c, fn files -> files end, fn root ->
        path = Path.join(root, "README.md")
        File.rm!(path)
        File.ln_s!("docs/plans/README.md", path)
      end)

    assert_refused(c, symlink, "metadata")
  end

  test "a bogus pending replacement cannot insert a row or heading", c do
    admin =
      fixture_admin(c, fn files ->
        Map.update!(
          files,
          "docs/evidence/M6-closure-runs.md",
          &String.replace(&1, "PASS", "PASS\n| Injected | row |")
        )
      end)

    assert_refused(c, admin, "evidence")
  end

  test "a write that fails after a partial write removes only its newly created patch", c do
    {admin, _} = admin!(c)
    patch = Path.join(c.root, "partial.patch")

    writer = fn io, bytes ->
      :ok = IO.binwrite(io, binary_part(bytes, 0, div(byte_size(bytes), 2)))
      {:error, :enospc}
    end

    assert {:error, lines} =
             Confine.check_with_writer(c.root, c.tested, admin, @name, patch, writer)

    assert List.last(lines) =~ "FAIL patch"
    refute File.exists?(patch)
  end

  test "the Mix task accepts its exact grammar and prints one check line each", c do
    {admin, _} = admin!(c)
    patch = Path.join(c.root, "command.patch")

    output =
      File.cd!(c.root, fn ->
        capture_io(fn -> Confine.run([c.tested, admin, "--name", @name, "--patch", patch]) end)
      end)

    assert length(String.split(String.trim(output), "\n")) == 10
    assert String.starts_with?(output, "PASS preflight\n")
    assert File.regular?(patch)

    assert_raise Mix.Error, ~r/usage: mix loopex.closure.confine/, fn ->
      Confine.run([c.tested, admin, "--name", @name])
    end
  end

  test "the appended disposition must name the exact milestone and contain one dated subsection",
       c do
    wrong =
      fixture_admin(c, fn files ->
        Map.update!(
          files,
          "docs/developer/agent-context-map.md",
          &String.replace(&1, "disposition-m6-closure", "disposition-other-closure")
        )
      end)

    assert_refused(c, wrong, "context")

    doubled =
      fixture_admin(c, fn files ->
        Map.update!(
          files,
          "docs/developer/agent-context-map.md",
          &(&1 <> "\n### another closure — 2026-09-27\n")
        )
      end)

    assert_refused(c, doubled, "context")
  end

  test "the closure row binds both tested plan bytes, not plausible-looking digests", c do
    wrong =
      fixture_admin(c, fn files ->
        Map.update!(files, "docs/plans/M6.md", fn plan ->
          String.replace(plan, "concept `sha256:", "concept `sha256:0", global: false)
        end)
      end)

    assert_refused(c, wrong, "closure")
  end

  defp assert_refused(c, admin, check) do
    patch = Path.join(c.root, "#{check}-#{System.unique_integer([:positive])}.patch")
    assert {:error, lines} = Confine.check(c.root, c.tested, admin, @name, patch)
    assert Enum.any?(lines, &String.starts_with?(&1, "FAIL #{check}")), inspect(lines)
    refute File.exists?(patch)
  end

  defp admin!(c) do
    admin = fixture_admin(c, fn files -> files end)
    {admin, Path.join(c.root, "pass.patch")}
  end

  defp fixture_admin(c, mutate, after_write \\ fn _root -> :ok end) do
    git!(c.root, ["checkout", "--quiet", c.tested])

    for {path, contents} <- mutate.(administrative_files(c.tested)) do
      write(c.root, path, contents)
    end

    after_write.(c.root)
    git!(c.root, ["add", "-A"])
    git!(c.root, ["commit", "--quiet", "-m", "admin"])
    git!(c.root, ["rev-parse", "HEAD"]) |> String.trim()
  end

  defp tested_files do
    %{
      "docs/plans/README.md" =>
        "unchanged register prose\n<!-- loopex:current-status:start -->\n## Current Status\nIn review\n<!-- loopex:current-status:end -->\n<!-- loopex:milestone-register:start -->\n| `M6` | In review | [concept](M6.md) | [technical depth](M6-technical.md) | — |\n<!-- loopex:milestone-register:end -->\n",
      "docs/plans/M6.md" =>
        "unchanged plan prose\n| Decision | Authority | Authority evidence | Bound bytes |\n| --- | --- | --- | --- |\n| Closure | — | — | — |\n",
      "docs/plans/M6-technical.md" => "unchanged technical contract\n",
      "docs/developer/agent-context-map.md" => "unchanged earlier disposition\n",
      "docs/evidence/M6-closure-runs.md" =>
        "# Closure runs\n| Fixed label | Value |\n| --- | --- |\n| Check | Pending |\n| Digest | sha256:Pending |\n",
      "README.md" =>
        "unchanged introduction\n<!-- loopex:readme-status:start -->\nM6 In review\n<!-- loopex:readme-status:end -->\n"
    }
  end

  defp administrative_files(tested) do
    concept_digest = digest(tested_files()["docs/plans/M6.md"])
    technical_digest = digest(tested_files()["docs/plans/M6-technical.md"])

    Map.merge(tested_files(), %{
      "docs/plans/README.md" =>
        "unchanged register prose\n<!-- loopex:current-status:start -->\n## Current Status\nM6 Closed\n<!-- loopex:current-status:end -->\n<!-- loopex:milestone-register:start -->\n| `M6` | Closed | [concept](M6.md) | [technical depth](M6-technical.md) | — |\n<!-- loopex:milestone-register:end -->\n",
      "docs/plans/M6.md" =>
        "unchanged plan prose\n| Decision | Authority | Authority evidence | Bound bytes |\n| --- | --- | --- | --- |\n| Closure | Maintainer | recorded | tested implementation `#{tested}`; concept `sha256:#{concept_digest}`; technical `sha256:#{technical_digest}` |\n",
      "docs/developer/agent-context-map.md" =>
        "unchanged earlier disposition\n\n<a id=\"disposition-m6-closure-2026-09-27\"></a>\n### M6 closure — 2026-09-27\n\nThe maintainer closed M6.\n",
      "docs/evidence/M6-closure-runs.md" =>
        "# Closure runs\n| Fixed label | Value |\n| --- | --- |\n| Check | PASS |\n| Digest | sha256:#{String.duplicate("a", 64)} |\n",
      "README.md" =>
        "unchanged introduction\n<!-- loopex:readme-status:start -->\nM6 Closed\n<!-- loopex:readme-status:end -->\n"
    })
  end

  defp write(root, path, contents) do
    full = Path.join(root, path)
    File.mkdir_p!(Path.dirname(full))
    File.write!(full, contents)
  end

  defp digest(bytes), do: bytes |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)

  defp git!(root, args) do
    {out, 0} =
      System.cmd("git", ["--no-replace-objects" | args], cd: root, stderr_to_stdout: true)

    out
  end
end
