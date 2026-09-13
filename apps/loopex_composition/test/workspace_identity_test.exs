defmodule LoopexComposition.WorkspaceIdentityTest do
  use ExUnit.Case, async: true
  alias LoopexComposition.WorkspaceIdentity
  alias LoopexProtocol.Canonical

  test "identity preserves the project trust digest and distinguishes physical root replacement" do
    root =
      Path.join(
        System.tmp_dir!(),
        "workspace-identity-#{Base.encode16(:crypto.strong_rand_bytes(12))}"
      )

    File.mkdir!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    workspace = Path.join(root, "workspace")
    File.mkdir!(workspace)
    linked = Path.join(root, "linked")
    File.ln_s!(workspace, linked)
    stat = File.stat!(workspace)
    {:ok, canonical} = WorkspaceIdentity.resolve_path(workspace)

    expected =
      "workspace:" <>
        Canonical.digest(%{
          "canonical_root" => canonical,
          "major_device" => stat.major_device,
          "inode" => stat.inode
        })

    assert {:ok, ^expected} = WorkspaceIdentity.reference(workspace)
    assert {:ok, ^expected} = WorkspaceIdentity.reference(linked)

    assert WorkspaceIdentity.from_verified_root(canonical, {stat.major_device, stat.inode}) ==
             expected

    File.rename!(workspace, Path.join(root, "old-workspace"))
    File.mkdir!(workspace)
    assert {:ok, changed} = WorkspaceIdentity.reference(workspace)
    refute changed == expected
    assert {:ok, ^changed} = WorkspaceIdentity.reference(linked)
    missing = Path.join(root, "missing")
    assert {:error, :enoent} = WorkspaceIdentity.reference(missing)
    refute File.exists?(missing)
  end
end
