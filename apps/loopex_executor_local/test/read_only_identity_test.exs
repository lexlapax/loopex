Code.require_file("support/read_only_filesystem_fixture.ex", __DIR__)

defmodule Loopex.Executor.Local.ReadOnlyIdentityTest do
  use ExUnit.Case, async: true
  alias Loopex.Executor.Local.ReadOnlyFilesystemFixture, as: Fixture

  @changed "N\tskipped\tinvalid_name=0\ttoo_large=0\tinvalid_utf8=0\tchanged=1\tunreadable=0\n"

  test "real regular-file replacement before open discards all matches, including the requested file" do
    for requested? <- [false, true] do
      control = Fixture.run(:grep, :before_read, requested?, false)
      assert control.result == {:completed, "M\twatched\t1\tmatch\n"}
      assert control.read_sizes == [6, :eof]
      assert control.before == control.after
      assert control.worker_down
      assert control.gate == %{phase: :before, operation: :open}

      changed = Fixture.run(:grep, :before_read, requested?)
      assert changed.before.inode != changed.after.inode
      assert changed.before.size == changed.after.size
      assert changed.read_sizes == []
      assert changed.worker_down
      assert_changed_result(changed.result, :grep, requested?, @changed)
    end
  end

  test "real regular-file replacement after the complete read discards its staged matches" do
    for requested? <- [false, true] do
      control = Fixture.run(:grep, :after_read, requested?, false)
      assert control.result == {:completed, "M\twatched\t1\tmatch\n"}
      assert control.read_sizes == [6, :eof]
      assert control.before == control.after
      assert control.gate == %{phase: :before, operation: :read_link_info}

      changed = Fixture.run(:grep, :after_read, requested?)
      assert changed.before.inode != changed.after.inode
      assert changed.before.size == changed.after.size
      assert changed.read_sizes == [6, :eof]
      assert changed.worker_down
      assert_changed_result(changed.result, :grep, requested?, @changed)
    end
  end

  test "requested-directory identity and type changes during first enumeration fail without records" do
    for kind <- [:grep, :find, :ls], stage <- [:directory_identity, :directory_type] do
      control = Fixture.run(kind, stage, true, false)
      assert control.result == {:completed, control_output(kind, true)}
      assert control.before == control.after
      assert control.gate == %{phase: :after, operation: :list_dir_all, listed: ["x"]}

      changed = Fixture.run(kind, stage, true)
      assert_identity_changed(changed, stage)
      assert changed.worker_down
      assert_changed_result(changed.result, kind, true, "")
    end
  end

  test "descendant-directory identity and type changes during enumeration count changed and never read children" do
    for kind <- [:grep, :find, :ls], stage <- [:directory_identity, :directory_type] do
      control = Fixture.run(kind, stage, false, false)
      assert control.result == {:completed, control_output(kind, false)}
      assert control.before == control.after

      changed = Fixture.run(kind, stage, false)
      assert_identity_changed(changed, stage)
      assert changed.read_sizes == []
      assert changed.worker_down

      prefix =
        case kind do
          :grep -> ""
          :find -> "P\twatched\n"
          :ls -> "P\twatched/\n"
        end

      assert changed.result == {:completed, prefix <> @changed}
    end
  end

  test "real growth after verified open observes byte 1048577 and counts both too-large and changed" do
    control = Fixture.run(:grep, :growth, false, false)
    assert control.result == {:completed, "M\twatched\t1\tmatch\n"}
    assert Enum.sum(Enum.filter(control.read_sizes, &is_integer/1)) == 1_048_576
    assert List.last(control.read_sizes) == :eof
    assert control.before == control.after
    assert control.gate.observed.size == 1_048_576

    changed = Fixture.run(:grep, :growth, false)
    assert changed.before.inode == changed.after.inode
    assert changed.before.size == 1_048_576
    assert changed.after.size == 1_048_577
    assert Enum.sum(changed.read_sizes) == 1_048_577
    assert List.last(changed.read_sizes) == 1
    assert changed.worker_down

    assert changed.result ==
             {:completed,
              "N\tskipped\tinvalid_name=0\ttoo_large=1\tinvalid_utf8=0\tchanged=1\tunreadable=0\n"}
  end

  defp assert_changed_result(result, kind, true, _) do
    assert result == {:failed, "#{kind} failed: requested path unavailable"}
  end

  defp assert_changed_result(result, _kind, false, notice),
    do: assert(result == {:completed, notice})

  defp assert_identity_changed(changed, :directory_identity) do
    assert changed.before.type == :directory
    assert changed.after.type == :directory
    assert changed.before.inode != changed.after.inode
  end

  defp assert_identity_changed(changed, :directory_type) do
    assert changed.before.type == :directory
    assert changed.after.type == :regular
  end

  defp control_output(:grep, _), do: "M\twatched/x\t1\tmatch\n"
  defp control_output(:find, true), do: "P\twatched/x\n"
  defp control_output(:find, false), do: "P\twatched\nP\twatched/x\n"
  defp control_output(:ls, true), do: "P\twatched/x\n"
  defp control_output(:ls, false), do: "P\twatched/\nP\twatched/x\n"
end
