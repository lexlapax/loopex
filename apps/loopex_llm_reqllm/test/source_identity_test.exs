defmodule Mix.LoopexSourceIdentityTest do
  use ExUnit.Case, async: true

  alias Mix.LoopexSourceIdentity

  @repository Path.expand("../..", File.cwd!())
  @commit String.duplicate("a1", 20)

  setup do
    tree = Path.join(System.tmp_dir!(), "lsi-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(tree, "scripts"))

    File.cp!(
      Path.join([@repository, "scripts", "source-archive-manifest.sh"]),
      Path.join([tree, "scripts", "source-archive-manifest.sh"])
    )

    File.write!(Path.join(tree, "a.txt"), "source")
    on_exit(fn -> File.rm_rf(tree) end)
    %{tree: tree}
  end

  test "the identity grammar is exact" do
    valid = "commit #{@commit}\ncommitter-date 2026-09-22T16:05:00-07:00\n"
    assert LoopexSourceIdentity.parse(valid) == {:ok, @commit}

    for invalid <- [
          "commit $Format:%H$\ncommitter-date $Format:%cI$\n",
          String.upcase(valid),
          String.trim_trailing(valid),
          valid <> "\n",
          valid <> "extra 1\n",
          "committer-date 2026-09-22T16:05:00-07:00\ncommit #{@commit}\n",
          "commit #{@commit}\ncommitter-date 2026-02-30T16:05:00-07:00\n",
          "commit #{@commit}\ncommitter-date 2026-09-22T16:05:00Z\n",
          "commit  #{@commit}\ncommitter-date 2026-09-22T16:05:00-07:00\n",
          "commit #{@commit}\r\ncommitter-date 2026-09-22T16:05:00-07:00\n"
        ] do
      assert LoopexSourceIdentity.parse(invalid) == {:error, :source_identity_invalid},
             inspect(invalid)
    end
  end

  test "an extraction resolves to its commit and source digest and detects a change",
       %{tree: tree} do
    File.write!(
      Path.join(tree, "SOURCE_IDENTITY"),
      "commit #{@commit}\ncommitter-date 2026-09-22T16:05:00-07:00\n"
    )

    assert {:ok, %{commit: @commit, mode: :archive, source_digest: digest} = identity} =
             LoopexSourceIdentity.resolve(tree)

    assert digest =~ ~r/\A[0-9a-f]{64}\z/
    assert LoopexSourceIdentity.verify_unchanged(tree, identity) == :ok

    # The build roots are the one exclusion; anything else written is a change.
    File.mkdir_p!(Path.join([tree, "_build", "dev"]))
    File.write!(Path.join([tree, "_build", "dev", "out"]), "built")
    assert LoopexSourceIdentity.verify_unchanged(tree, identity) == :ok

    File.write!(Path.join(tree, "stray.txt"), "written during the build")

    assert LoopexSourceIdentity.verify_unchanged(tree, identity) ==
             {:error, :source_changed_during_build}
  end

  test "a missing or unsubstituted identity refuses", %{tree: tree} do
    assert LoopexSourceIdentity.resolve(tree) == {:error, :source_identity_missing}

    File.write!(
      Path.join(tree, "SOURCE_IDENTITY"),
      "commit $Format:%H$\ncommitter-date $Format:%cI$\n"
    )

    assert LoopexSourceIdentity.resolve(tree) == {:error, :source_identity_invalid}
  end

  test "the checkout's identity file is the unsubstituted template git archive fills" do
    assert File.read!(Path.join(@repository, "SOURCE_IDENTITY")) ==
             "commit $Format:%H$\ncommitter-date $Format:%cI$\n"

    assert File.read!(Path.join(@repository, ".gitattributes")) =~
             ~r/^SOURCE_IDENTITY export-subst$/m

    {expected, 0} =
      System.cmd("git", ["show", "-s", "--format=commit %H%ncommitter-date %cI", "HEAD"],
        cd: @repository
      )

    {archived, 0} =
      System.cmd("sh", ["-c", "git archive HEAD SOURCE_IDENTITY | tar -xO SOURCE_IDENTITY"],
        cd: @repository
      )

    assert archived == String.trim_trailing(expected) <> "\n"
    assert {:ok, _commit} = LoopexSourceIdentity.parse(archived)
  end
end
