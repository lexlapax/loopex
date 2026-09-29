defmodule Loopex.ClosureArchiveCompareTest do
  @moduledoc """
  ## Concept

  The pre-tag comparison accepts a documentation-only administrative child and
  refuses an archive that changes source, modes, paths, identity or framing.

  ## Technical depth

  A disposable two-commit repository supplies real `git archive` output. Each
  mutation changes a copied retained manifest or sidecar, never the checkout or
  the fixture's source commits.
  """

  use ExUnit.Case, async: false

  alias Mix.Tasks.Loopex.Closure.ArchiveCompare

  setup_all do
    root =
      Path.join(System.tmp_dir!(), "loopex-archive-compare-#{System.unique_integer([:positive])}")

    repo = Path.join(root, "repo")
    File.mkdir_p!(Path.join(repo, "scripts"))
    File.mkdir_p!(Path.join(repo, "docs"))
    on_exit(fn -> File.rm_rf(root) end)

    git!(repo, ["init", "-q"])
    git!(repo, ["config", "user.name", "Loopex Test"])
    git!(repo, ["config", "user.email", "loopex-test@example.invalid"])

    File.write!(
      Path.join(repo, ".gitattributes"),
      "SOURCE_IDENTITY export-subst\nignored.txt export-ignore\n"
    )

    File.write!(
      Path.join(repo, "SOURCE_IDENTITY"),
      "commit $Format:%H$\ncommitter-date $Format:%cI$\n"
    )

    File.write!(Path.join(repo, "README.md"), "tested\n")
    File.write!(Path.join(repo, "docs/README.md"), "tested\n")
    File.write!(Path.join(repo, "source.txt"), "unchanged source\n")
    File.write!(Path.join(repo, "ignored.txt"), "tracked but not archived\n")
    File.ln_s!("target\n", Path.join(repo, "newline-link"))

    producer = Path.join(LoopexTest.Repo.root(), "scripts/source-archive-manifest.sh")
    File.cp!(producer, Path.join(repo, "scripts/source-archive-manifest.sh"))
    git!(repo, ["add", "."])
    git!(repo, ["commit", "-qm", "tested"])
    tested = git!(repo, ["rev-parse", "HEAD"]) |> String.trim()

    File.write!(Path.join(repo, "README.md"), "administrative\n")
    File.write!(Path.join(repo, "docs/README.md"), "administrative\n")
    git!(repo, ["add", "."])
    git!(repo, ["commit", "-qm", "administrative"])
    admin = git!(repo, ["rev-parse", "HEAD"]) |> String.trim()

    stage = Path.join(LoopexTest.Repo.root(), "scripts/stage-archive-manifest.sh")
    tested_path = Path.join(root, "tested.manifest")
    admin_path = Path.join(root, "admin.manifest")
    {_, 0} = System.cmd("bash", [stage, tested, tested_path], cd: repo, stderr_to_stdout: true)
    {_, 0} = System.cmd("bash", [stage, admin, admin_path], cd: repo, stderr_to_stdout: true)

    %{
      root: root,
      repo: repo,
      tested: tested,
      admin: admin,
      tested_path: tested_path,
      admin_path: admin_path
    }
  end

  test "real staged archives accept only the governed documentation difference", fixture do
    assert :nomatch == :binary.match(File.read!(fixture.tested_path), "ignored.txt")
    assert :ok == compare(fixture)
  end

  test "replacement refs cannot make changed source compare as the administrative archive",
       fixture do
    repo = Path.join(fixture.root, "replacement-#{System.unique_integer([:positive])}")
    git!(fixture.repo, ["clone", "-q", fixture.repo, repo])
    git!(repo, ["switch", "-q", "--detach", fixture.admin])
    git!(repo, ["config", "user.name", "Loopex Test"])
    git!(repo, ["config", "user.email", "loopex-test@example.invalid"])
    File.write!(Path.join(repo, "source.txt"), "changed source\n")
    git!(repo, ["add", "source.txt"])
    git!(repo, ["commit", "-qm", "changed source"])
    changed = git!(repo, ["rev-parse", "HEAD"]) |> String.trim()
    git!(repo, ["replace", changed, fixture.admin])

    path = Path.join(fixture.root, "replaced-#{System.unique_integer([:positive])}.manifest")
    stage = Path.join(LoopexTest.Repo.root(), "scripts/stage-archive-manifest.sh")
    {_, 0} = System.cmd("bash", [stage, changed, path], cd: repo, stderr_to_stdout: true)

    assert {:error, "archive tuples outside the exclusions differ"} =
             compare(%{fixture | repo: repo, admin: changed, admin_path: path})
  end

  test "a replaced source blob cannot validate matching forged manifests", fixture do
    repo = Path.join(fixture.root, "blob-replacement-#{System.unique_integer([:positive])}")
    git!(fixture.repo, ["clone", "-q", fixture.repo, repo])
    git!(repo, ["switch", "-q", "--detach", fixture.admin])

    original_blob = git!(repo, ["rev-parse", "#{fixture.admin}:source.txt"]) |> String.trim()
    replacement = Path.join(repo, "replacement-blob.txt")
    File.write!(replacement, "forged source\n")
    replacement_blob = git!(repo, ["hash-object", "-w", replacement]) |> String.trim()
    git!(repo, ["replace", original_blob, replacement_blob])
    assert "forged source\n" == git!(repo, ["cat-file", "blob", original_blob])

    assert "unchanged source\n" ==
             git!(repo, ["--no-replace-objects", "cat-file", "blob", original_blob])

    tested_path = copy_manifest(fixture, fixture.tested_path)
    admin_path = copy_manifest(fixture, fixture.admin_path)
    original_digest = Base.encode16(:crypto.hash(:sha256, "unchanged source\n"), case: :lower)
    replacement_digest = Base.encode16(:crypto.hash(:sha256, "forged source\n"), case: :lower)

    for path <- [tested_path, admin_path] do
      bytes = File.read!(path)
      assert :binary.match(bytes, original_digest) != :nomatch
      File.write!(path, :binary.replace(bytes, original_digest, replacement_digest))
    end

    assert {:error, "archive content differs from its commit blob"} =
             compare(%{fixture | repo: repo, tested_path: tested_path, admin_path: admin_path})
  end

  test "the command requires every argument and exact commit identities", fixture do
    assert_raise Mix.Error, ~r/usage: mix loopex.closure.archive_compare/, fn ->
      ArchiveCompare.run([fixture.tested_path, fixture.admin_path, fixture.tested])
    end

    assert {:error, "commit ID is not a full SHA"} =
             compare(%{fixture | admin: String.slice(fixture.admin, 0, 12)})
  end

  test "a source digest difference is not excused as documentation", fixture do
    path = copy_manifest(fixture)
    bytes = File.read!(path)
    digest = Base.encode16(:crypto.hash(:sha256, "unchanged source\n"), case: :lower)
    assert :binary.match(bytes, digest) != :nomatch
    File.write!(path, String.replace(bytes, digest, String.duplicate("0", 64)))

    assert {:error, "archive tuples outside the exclusions differ"} =
             compare(%{fixture | admin_path: path})
  end

  test "a trailing newline change in a shipped link target is detected", fixture do
    path = copy_manifest(fixture)
    bytes = File.read!(path)
    before = Enum.join(["l", "0", "newline-link", "target\n", ""], <<0>>)
    after_target = Enum.join(["l", "0", "newline-link", "target\n\n", ""], <<0>>)
    assert :binary.match(bytes, before) != :nomatch
    File.write!(path, :binary.replace(bytes, before, after_target))

    assert {:error, "archive tuples outside the exclusions differ"} =
             compare(%{fixture | admin_path: path})
  end

  test "matching forged file digests in both manifests cannot impersonate the commits", fixture do
    tested_copy = copy_manifest(fixture, fixture.tested_path)
    admin_copy = copy_manifest(fixture, fixture.admin_path)
    digest = Base.encode16(:crypto.hash(:sha256, "unchanged source\n"), case: :lower)
    original = Enum.join(["f", "644", "source.txt", digest, ""], <<0>>)
    forged = Enum.join(["f", "644", "source.txt", String.duplicate("0", 64), ""], <<0>>)

    for path <- [tested_copy, admin_copy] do
      bytes = File.read!(path)
      assert :binary.match(bytes, original) != :nomatch
      File.write!(path, :binary.replace(bytes, original, forged))
    end

    assert {:error, "archive content differs from its commit blob"} =
             compare(%{fixture | tested_path: tested_copy, admin_path: admin_copy})
  end

  test "matching forged link targets in both manifests cannot impersonate the commits", fixture do
    tested_copy = copy_manifest(fixture, fixture.tested_path)
    admin_copy = copy_manifest(fixture, fixture.admin_path)
    original = Enum.join(["l", "0", "newline-link", "target\n", ""], <<0>>)
    forged = Enum.join(["l", "0", "newline-link", "forged\n", ""], <<0>>)

    for path <- [tested_copy, admin_copy] do
      bytes = File.read!(path)
      assert :binary.match(bytes, original) != :nomatch
      File.write!(path, :binary.replace(bytes, original, forged))
    end

    assert {:error, "archive content differs from its commit blob"} =
             compare(%{fixture | tested_path: tested_copy, admin_path: admin_copy})
  end

  test "an excluded administrative document still has to match its own Git blob", fixture do
    path = copy_manifest(fixture)
    bytes = File.read!(path)
    digest = Base.encode16(:crypto.hash(:sha256, "administrative\n"), case: :lower)
    original = Enum.join(["f", "644", "docs/README.md", digest, ""], <<0>>)
    forged = Enum.join(["f", "644", "docs/README.md", String.duplicate("0", 64), ""], <<0>>)
    assert :binary.match(bytes, original) != :nomatch
    File.write!(path, :binary.replace(bytes, original, forged))

    assert {:error, "archive content differs from its commit blob"} =
             compare(%{fixture | admin_path: path})
  end

  test "a changed mode fails the complete projection before exclusions", fixture do
    path = copy_manifest(fixture)

    File.write!(
      path,
      String.replace(File.read!(path), "f\0" <> "644\0source.txt", "f\0" <> "755\0source.txt")
    )

    assert {:error, "an archive kind/mode/path projection differs from its commit"} =
             compare(%{fixture | admin_path: path})
  end

  test "the same omitted shipped path in both manifests fails completeness", fixture do
    tested_copy = copy_manifest(fixture, fixture.tested_path)
    admin_copy = copy_manifest(fixture, fixture.admin_path)
    digest = Base.encode16(:crypto.hash(:sha256, "unchanged source\n"), case: :lower)
    record = Enum.join(["f", "644", "source.txt", digest, ""], <<0>>)

    for path <- [tested_copy, admin_copy] do
      bytes = File.read!(path)
      assert :binary.match(bytes, record) != :nomatch
      File.write!(path, :binary.replace(bytes, record, ""))
    end

    assert {:error, "an archive kind/mode/path projection differs from its commit"} =
             compare(%{fixture | tested_path: tested_copy, admin_path: admin_copy})
  end

  test "truncated framing and duplicate paths refuse", fixture do
    path = copy_manifest(fixture)
    bytes = File.read!(path)
    File.write!(path, binary_part(bytes, 0, byte_size(bytes) - 1))
    assert {:error, "manifest has malformed NUL framing"} = compare(%{fixture | admin_path: path})

    File.write!(
      path,
      bytes <> Enum.join(["f", "644", "source.txt", String.duplicate("0", 64), ""], <<0>>)
    )

    assert {:error, "manifest has a duplicate path"} = compare(%{fixture | admin_path: path})
  end

  test "out-of-order records and malformed values refuse", fixture do
    path = copy_manifest(fixture)
    bytes = File.read!(path)
    fields = :binary.split(bytes, <<0>>, [:global]) |> Enum.drop(-1)
    [first, second | rest] = Enum.chunk_every(fields, 4)
    File.write!(path, Enum.join(List.flatten([second, first | rest]) ++ [""], <<0>>))

    assert {:error, "manifest paths are not bytewise sorted"} =
             compare(%{fixture | admin_path: path})

    File.write!(
      path,
      String.replace(bytes, "f\0" <> "644\0source.txt", "f\0" <> "bad\0source.txt")
    )

    assert {:error, "manifest has a malformed record"} = compare(%{fixture | admin_path: path})
  end

  test "the identity tuple must match its exact ordinary sidecar", fixture do
    path = copy_manifest(fixture)
    bytes = File.read!(path)
    identity = File.read!(path <> ".source-identity")
    digest = Base.encode16(:crypto.hash(:sha256, identity), case: :lower)
    File.write!(path, String.replace(bytes, digest, String.duplicate("0", 64)))

    assert {:error, "SOURCE_IDENTITY does not name its own commit"} =
             compare(%{fixture | admin_path: path})
  end

  test "missing, symlinked and altered sidecars refuse", fixture do
    path = copy_manifest(fixture)
    sidecar = path <> ".source-identity"
    File.rm!(sidecar)

    assert {:error, "source-identity sidecar is missing or not an ordinary file"} =
             compare(%{fixture | admin_path: path})

    File.ln_s!(fixture.admin_path <> ".source-identity", sidecar)

    assert {:error, "source-identity sidecar is missing or not an ordinary file"} =
             compare(%{fixture | admin_path: path})

    File.rm!(sidecar)
    File.write!(sidecar, "commit wrong\n")

    assert {:error, "SOURCE_IDENTITY does not name its own commit"} =
             compare(%{fixture | admin_path: path})
  end

  test "a newly added archive path cannot hide behind the documentation exclusion", fixture do
    File.write!(Path.join(fixture.repo, "docs/new.md"), "new document\n")
    git!(fixture.repo, ["add", "docs/new.md"])
    git!(fixture.repo, ["commit", "-qm", "extra path"])
    extra = git!(fixture.repo, ["rev-parse", "HEAD"]) |> String.trim()
    path = Path.join(fixture.root, "extra.manifest")
    stage = Path.join(LoopexTest.Repo.root(), "scripts/stage-archive-manifest.sh")
    {_, 0} = System.cmd("bash", [stage, extra, path], cd: fixture.repo, stderr_to_stdout: true)

    assert {:error, "the complete archive projections differ"} =
             compare(%{fixture | admin: extra, admin_path: path})
  end

  test "a tracked build-output root cannot hide behind the manifest producer's prune", fixture do
    repo = Path.join(fixture.root, "tracked-build-repo")
    git!(fixture.repo, ["clone", "-q", fixture.repo, repo])
    git!(repo, ["switch", "-q", "--detach", fixture.admin])
    git!(repo, ["config", "user.name", "Loopex Test"])
    git!(repo, ["config", "user.email", "loopex-test@example.invalid"])
    File.mkdir_p!(Path.join(repo, "deps"))
    File.write!(Path.join(repo, "deps/tracked.txt"), "tracked build input\n")
    git!(repo, ["add", "-f", "deps/tracked.txt"])
    git!(repo, ["commit", "-qm", "tracked build output"])
    extra = git!(repo, ["rev-parse", "HEAD"]) |> String.trim()
    path = Path.join(fixture.root, "tracked-build.manifest")
    stage = Path.join(LoopexTest.Repo.root(), "scripts/stage-archive-manifest.sh")
    {_, 0} = System.cmd("bash", [stage, extra, path], cd: repo, stderr_to_stdout: true)

    assert {:error, "an archive kind/mode/path projection differs from its commit"} =
             compare(%{fixture | repo: repo, admin: extra, admin_path: path})
  end

  defp compare(%{
         repo: repo,
         tested_path: tested_path,
         admin_path: admin_path,
         tested: tested,
         admin: admin
       }) do
    File.cd!(repo, fn ->
      ExUnit.CaptureIO.capture_io(fn ->
        Process.put(
          :archive_compare_result,
          ArchiveCompare.compare(tested_path, admin_path, tested, admin)
        )
      end)

      result = Process.get(:archive_compare_result)
      Process.delete(:archive_compare_result)
      result
    end)
  end

  defp copy_manifest(fixture, source \\ nil) do
    source = source || fixture.admin_path
    path = Path.join(fixture.root, "copy-#{System.unique_integer([:positive])}.manifest")
    File.cp!(source, path)
    File.cp!(source <> ".source-identity", path <> ".source-identity")
    path
  end

  defp git!(repo, args) do
    case System.cmd("git", args, cd: repo, stderr_to_stdout: true) do
      {output, 0} -> output
      {output, code} -> flunk("fixture Git command #{inspect(args)} failed #{code}: #{output}")
    end
  end
end
