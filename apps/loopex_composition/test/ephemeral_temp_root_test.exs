defmodule LoopexComposition.Ephemeral.TempRootTest do
  @moduledoc false
  use ExUnit.Case, async: true
  alias LoopexComposition.Ephemeral.TempRoot

  setup do
    tmp =
      Path.join(System.tmp_dir!(), "loopex-temp-root-test-#{System.unique_integer([:positive])}")

    File.mkdir!(tmp)
    Process.put({TempRoot, :dependencies}, %{tmp: fn -> tmp end})
    on_exit(fn -> File.rm_rf!(tmp) end)
    {:ok, tmp: tmp}
  end

  defp dependencies(extra) do
    Process.put(
      {TempRoot, :dependencies},
      Map.merge(Process.get({TempRoot, :dependencies}), extra)
    )
  end

  test "a real candidate is exclusively claimed private and recursively removed" do
    assert {:ok, candidate} = TempRoot.candidate()
    assert byte_size(candidate.nonce) == 32

    assert Path.basename(candidate.path) ==
             "loopex-" <> Base.encode16(candidate.nonce, case: :lower)

    assert {:ok, owned} = TempRoot.claim(candidate)
    on_exit(fn -> TempRoot.remove(owned) end)
    assert {:ok, stat} = File.lstat(owned.path)
    assert stat.type == :directory
    assert Bitwise.band(stat.mode, 0o7777) == 0o700
    assert owned.identity.inode == stat.inode
    assert owned.identity.major_device == stat.major_device
    assert owned.identity.uid == stat.uid
    {uid, 0} = System.cmd("/usr/bin/id", ["-u"])
    assert stat.uid == String.to_integer(String.trim(uid))
    assert {:ok, []} = File.ls(owned.path)
    File.mkdir!(Path.join(owned.path, "receipts"))
    File.write!(Path.join(owned.path, "receipts/entry"), "receipt")
    assert TempRoot.remove(owned) == :ok
    assert File.lstat(owned.path) == {:error, :enoent}
    assert TempRoot.remove(owned) == {:error, :root_removal_unproved}
    assert TempRoot.remove(owned, true) == :ok
  end

  test "collision attempts mkdir once and leave the preexisting directory untouched" do
    assert {:ok, candidate} = TempRoot.candidate()
    File.mkdir!(candidate.path)
    File.chmod!(candidate.path, 0o755)
    marker = Path.join(candidate.path, "marker")
    File.write!(marker, "existing")

    dependencies(%{
      mkdir: fn path ->
        send(self(), {:mkdir, path})
        File.mkdir(path)
      end
    })

    assert TempRoot.claim(candidate) == {:error, :collision}
    assert_received {:mkdir, path}
    assert path == candidate.path
    refute_received {:mkdir, _}
    assert File.read!(marker) == "existing"
    assert Bitwise.band(File.stat!(candidate.path).mode, 0o7777) == 0o755
    assert TempRoot.remove(candidate) == {:error, :root_removal_unproved}
  end

  test "already replaced directories and symlinks confer no removal authority", %{tmp: tmp} do
    assert {:ok, candidate} = TempRoot.candidate()
    assert {:ok, owned} = TempRoot.claim(candidate)
    moved = Path.join(tmp, "moved")
    File.rename!(owned.path, moved)
    File.mkdir!(owned.path)
    File.write!(Path.join(owned.path, "marker"), "replacement")
    assert TempRoot.remove(owned) == {:error, :root_removal_unproved}
    assert TempRoot.remove(owned, true) == {:error, :root_removal_unproved}
    assert File.read!(Path.join(owned.path, "marker")) == "replacement"
    File.rm_rf!(owned.path)
    File.ln_s!(moved, owned.path)
    assert TempRoot.remove(owned) == {:error, :root_removal_unproved}
    assert TempRoot.remove(owned, true) == {:error, :root_removal_unproved}
    assert File.lstat!(owned.path).type == :symlink
    assert File.dir?(moved)
    assert TempRoot.claim(candidate) == {:error, :collision}
  end

  test "candidate rejects bad temporary paths before entropy and bounds the complete path" do
    for tmp <- [nil, "", <<255>>, "a" <> <<0>>, String.duplicate("a", 65_537)] do
      dependencies(%{tmp: fn -> tmp end, entropy: fn _ -> send(self(), :entropy_reached) end})
      assert TempRoot.candidate() == {:error, :temporary_root_unusable}
      refute_received :entropy_reached
    end

    nonce = :binary.copy(<<0>>, 32)

    for {size, expected} <- [{65_463, :ok}, {65_464, :error}] do
      dependencies(%{
        tmp: fn -> "/" <> String.duplicate("a", size) end,
        entropy: fn 32 -> nonce end
      })

      result = TempRoot.candidate()

      if expected == :ok do
        assert {:ok, %{path: path}} = result
        assert byte_size(path) == 65_536
      else
        assert result == {:error, :temporary_root_unusable}
      end
    end
  end

  test "entropy shape and failed lookups produce fixed errors" do
    for value <- [nil, [], "", :binary.copy(<<0>>, 31), :binary.copy(<<0>>, 33)] do
      dependencies(%{entropy: fn 32 -> value end})
      assert TempRoot.candidate() == {:error, :temporary_root_creation_failed}
    end

    dependencies(%{entropy: fn _ -> raise "entropy failure" end})
    assert TempRoot.candidate() == {:error, :temporary_root_creation_failed}
    dependencies(%{tmp: fn -> raise "lookup failure" end})
    assert TempRoot.candidate() == {:error, :temporary_root_unusable}
  end

  test "post-mkdir failures retain candidate and proved identity instead of deleting" do
    assert {:ok, candidate} = TempRoot.candidate()
    dependencies(%{chmod: fn _, _ -> {:error, :eperm} end})
    assert {:error, {:claim_unproved, retained}} = TempRoot.claim(candidate)
    assert retained.candidate == candidate
    assert retained.ownership == :owned
    assert retained.identity.inode == File.lstat!(candidate.path).inode
    assert File.dir?(candidate.path)
    assert TempRoot.remove(Map.put(candidate, :identity, retained.identity)) == :ok
  end

  test "unproved initial identity never authorizes removal" do
    assert {:ok, candidate} = TempRoot.candidate()
    dependencies(%{lstat: fn _ -> {:error, :eacces} end})
    assert {:error, {:claim_unproved, retained}} = TempRoot.claim(candidate)
    assert retained.ownership == :unknown
    assert retained.identity == nil
    assert retained.candidate == candidate
    assert TempRoot.remove(Map.put(candidate, :identity, nil)) == {:error, :root_removal_unproved}
    assert File.dir?(candidate.path)
  end

  test "runtime identity hashes the full successful nonce" do
    nonce = :binary.list_to_bin(Enum.to_list(0..31))
    assert TempRoot.runtime_id(nonce) == "ephemeral-630dcd2966c4336691125448bbb25b4f"
  end

  test "UID probe admits only unsigned decimal output with optional final LF" do
    {actual, 0} = System.cmd("/usr/bin/id", ["-u"])

    for output <- ["+" <> actual, " " <> actual, actual <> "\n", "-1\n", "", "123junk"] do
      assert {:ok, candidate} = TempRoot.candidate()
      dependencies(%{uid: fn -> {output, 0} end})

      assert {:error, {:claim_unproved, %{identity: nil, ownership: :unknown}}} =
               TempRoot.claim(candidate)

      assert File.dir?(candidate.path)
    end
  end

  test "verification and removal errors keep the root" do
    assert {:ok, candidate} = TempRoot.candidate()
    dependencies(%{ls: fn _ -> {:ok, ["unexpected"]} end})
    assert {:error, {:claim_unproved, retained}} = TempRoot.claim(candidate)
    owned = Map.put(candidate, :identity, retained.identity)
    dependencies(%{rm_rf: fn _ -> {:error, :eacces, "private"} end})
    assert TempRoot.remove(owned) == {:error, :root_removal_unproved}
    assert File.dir?(candidate.path)

    assert TempRoot.remove(
             Map.put(owned, :identity, %{owned.identity | uid: owned.identity.uid + 1})
           ) ==
             {:error, :root_removal_unproved}
  end

  test "invalid candidates never attempt mkdir" do
    dependencies(%{mkdir: fn _ -> send(self(), :mkdir_reached) end})

    for candidate <- [
          nil,
          %{},
          %{path: "/tmp/arbitrary", nonce: :binary.copy(<<0>>, 32)},
          %{path: <<255>>, nonce: :binary.copy(<<0>>, 32)},
          %{path: "/tmp/loopex-x", nonce: nil}
        ] do
      assert TempRoot.claim(candidate) == {:error, :temporary_root_creation_failed}
      refute_received :mkdir_reached
    end
  end

  test "initial wrong UID or type does not grant chmod or removal authority" do
    for change <- [%{uid: 0}, %{type: :symlink}] do
      assert {:ok, candidate} = TempRoot.candidate()

      dependencies(%{
        lstat: fn path ->
          {:ok, stat} = File.lstat(path)
          change = if Map.has_key?(change, :uid), do: %{uid: stat.uid + 1}, else: change
          {:ok, struct!(stat, change)}
        end,
        chmod: fn _, _ -> send(self(), :chmod_reached) end
      })

      assert {:error, {:claim_unproved, %{ownership: :unknown, identity: nil}}} =
               TempRoot.claim(candidate)

      refute_received :chmod_reached
      assert File.dir?(candidate.path)
    end
  end

  test "failed chmod and identity-changing post-chmod checks retain the first identity" do
    assert {:ok, candidate} = TempRoot.candidate()
    dependencies(%{chmod: fn _, _ -> raise "failure" end})

    assert {:error, {:claim_unproved, %{identity: identity, ownership: :owned}}} =
             TempRoot.claim(candidate)

    assert identity.inode == File.lstat!(candidate.path).inode
    assert File.dir?(candidate.path)

    assert {:ok, next} = TempRoot.candidate()

    dependencies(%{
      chmod: &File.chmod/2,
      lstat: fn path ->
        {:ok, stat} = File.lstat(path)
        count = Process.get(:temp_root_lstat_count, 0)
        Process.put(:temp_root_lstat_count, count + 1)
        {:ok, if(count == 0, do: stat, else: %{stat | inode: stat.inode + 1})}
      end
    })

    assert {:error, {:claim_unproved, %{identity: first, ownership: :owned}}} =
             TempRoot.claim(next)

    assert first.inode == File.lstat!(next.path).inode
  end
end
