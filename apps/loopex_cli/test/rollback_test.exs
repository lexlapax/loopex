defmodule LoopexCli.RollbackTest do
  @moduledoc """
  ## Concept

  The release rollback lane refuses a source extraction that cannot be tied to
  its separately retained Git-tree and source identity.

  ## Technical depth

  These small cases pin the driver's no-Git validator. The release lane itself
  rebuilds both real archives and crosses real durable roots and processes.
  """
  use ExUnit.Case, async: true

  @checker Path.expand("../../../scripts/rollback-archive-check.exs", __DIR__)
  @commit String.duplicate("a", 40)
  @digest String.duplicate("b", 64)

  setup do
    root =
      Path.join(System.tmp_dir!(), "loopex-rollback-check-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    identity = "commit #{@commit}\ncommitter-date 2026-09-27T00:00:00+00:00\n"
    File.write!(Path.join(root, "SOURCE_IDENTITY"), identity)
    File.write!(Path.join(root, "identity"), identity)
    File.write!(Path.join(root, "manifest"), "f\0" <> "644\0SOURCE_IDENTITY\0#{@digest}\0")
    File.write!(Path.join(root, "projection"), "100644 blob #{@commit}\tSOURCE_IDENTITY\0")
    %{root: root}
  end

  test "the isolated checker accepts matching complete archive and tree projections", %{
    root: root
  } do
    {output, 0} = check(root)
    assert output =~ "verified 1 entries"
  end

  test "the isolated checker rejects a changed tree mode", %{root: root} do
    File.write!(Path.join(root, "projection"), "100755 blob #{@commit}\tSOURCE_IDENTITY\0")
    {output, 1} = check(root)
    assert output =~ "archive kind, mode or path projection differs"
  end

  test "the isolated checker rejects a duplicate manifest path", %{root: root} do
    original = File.read!(Path.join(root, "manifest"))
    File.write!(Path.join(root, "manifest"), original <> original)
    {output, 1} = check(root)
    assert output =~ "unsorted or duplicate archive path"
  end

  test "the isolated checker rejects a source identity mismatch", %{root: root} do
    File.write!(Path.join(root, "identity"), "commit #{String.duplicate("c", 40)}\n")
    {output, 1} = check(root)
    assert output =~ "SOURCE_IDENTITY differs"
  end

  defp check(root) do
    System.cmd(
      System.find_executable("elixir"),
      [
        @checker,
        Path.join(root, "manifest"),
        Path.join(root, "projection"),
        Path.join(root, "identity"),
        @commit,
        root
      ],
      stderr_to_stdout: true
    )
  end
end
