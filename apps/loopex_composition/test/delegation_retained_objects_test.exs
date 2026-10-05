Code.require_file("support/delegation_genesis_fixture.exs", __DIR__)

defmodule LoopexComposition.DelegationRetainedObjectsTest do
  use ExUnit.Case, async: true

  alias LoopexComposition.Delegation.{GenesisCodec, RetainedObjects}
  alias LoopexComposition.{DelegationGenesisFixture, Placement}
  alias LoopexProtocol.Frame

  setup do
    root =
      Path.join("/private/tmp", "loopex-retained-#{Base.encode16(:crypto.strong_rand_bytes(12))}")

    File.mkdir!(root)
    {:ok, lease} = Placement.acquire(root)

    on_exit(fn ->
      Placement.release(lease)
      File.rm_rf!(root)
    end)

    %{root: root, lease: lease, directory: Path.join([root, "delegation", hash("retained-test")])}
  end

  test "an actual current genesis object installs, repeats exactly and reopens", context do
    genesis = DelegationGenesisFixture.genesis()
    {:ok, object} = GenesisCodec.encode(genesis)
    {:ok, encoded} = Frame.encode(object)
    bytes = encoded |> IO.iodata_to_binary() |> String.trim_trailing("\n")
    owner = open(context)
    assert {:ok, digest} = RetainedObjects.install(owner, bytes)
    path = Path.join(context.directory, digest)
    inode = File.stat!(path).inode
    assert {:ok, ^digest} = RetainedObjects.install(owner, bytes)
    assert File.stat!(path).inode == inode
    assert {:ok, ^bytes} = RetainedObjects.read(owner, digest)
    GenServer.stop(owner)
    reopened = open(context)
    assert {:ok, recovered} = RetainedObjects.read(reopened, digest)
    assert {:ok, decoded} = Frame.decode(recovered, 1_048_576)
    assert {:ok, ^genesis} = GenesisCodec.decode(decoded)
  end

  test "a corrupt complete object is never replaced under its claimed digest", context do
    owner = open(context)
    bytes = ~s({"exact":"original"})
    assert {:ok, digest} = RetainedObjects.install(owner, bytes)
    path = Path.join(context.directory, digest)
    File.write!(path, ~s({"exact":"altered"}))
    assert RetainedObjects.read(owner, digest) == {:error, :invalid_or_corrupt_object}
    assert RetainedObjects.install(owner, bytes) == {:error, :object_integrity_conflict}
    assert File.read!(path) == ~s({"exact":"altered"})
    File.write!(path, "")
    assert RetainedObjects.read(owner, digest) == {:error, :invalid_or_corrupt_object}
  end

  test "the physical ceiling admits exactly one MiB and rejects an extra byte", context do
    owner = open(context)
    prefix = ~s({"padding":")
    suffix = ~s("})
    bytes = prefix <> String.duplicate("a", 1_048_576 - byte_size(prefix <> suffix)) <> suffix
    assert is_map(JSON.decode!(bytes))
    assert byte_size(bytes) == 1_048_576
    assert {:ok, digest} = RetainedObjects.install(owner, bytes)
    assert {:ok, ^bytes} = RetainedObjects.read(owner, digest)
    assert RetainedObjects.install(owner, bytes <> " ") == {:error, :invalid_object_bytes}
    assert RetainedObjects.install(owner, <<255>>) == {:error, :invalid_object_bytes}
    assert RetainedObjects.install(owner, "") == {:error, :invalid_object_bytes}

    assert RetainedObjects.read(owner, "../placement.lock") ==
             {:error, :invalid_or_corrupt_object}

    File.write!(Path.join(context.directory, digest), bytes <> "x")
    assert RetainedObjects.read(owner, digest) == {:error, :invalid_or_corrupt_object}
  end

  test "concurrent installations preserve the one published file", context do
    owner = open(context)
    bytes = ~s({"concurrent":true})

    results =
      1..16
      |> Enum.map(fn _ -> Task.async(fn -> RetainedObjects.install(owner, bytes) end) end)
      |> Enum.map(&Task.await(&1, 5_000))

    assert Enum.uniq(results) == [{:ok, hash(bytes)}]
    inode = File.stat!(Path.join(context.directory, hash(bytes))).inode
    assert {:ok, digest} = RetainedObjects.install(owner, bytes)
    assert File.stat!(Path.join(context.directory, digest)).inode == inode
    assert {:ok, ^bytes} = RetainedObjects.read(owner, digest)
  end

  test "a second physical owner cannot open the live writer", context do
    _owner = open(context)
    assert {:error, _reason} = RetainedObjects.open(context.root, "retained-test", context.lease)

    assert {:error, _reason} =
             RetainedObjects.open(context.root, "retained-test", context.lease,
               recover_stale_writer: true
             )
  end

  test "unheld, released and unrelated placement handles refuse before installation", context do
    assert {:error, :placement_ownership_unavailable} =
             RetainedObjects.open(context.root, "retained-test", "raw")

    other_root = Path.join(context.root, "other")
    File.mkdir!(other_root)
    {:ok, other_lease} = Placement.acquire(other_root)
    on_exit(fn -> Placement.release(other_lease) end)

    assert {:error, :placement_ownership_unavailable} =
             RetainedObjects.open(context.root, "retained-test", other_lease)

    owner = open(context)
    Placement.release(context.lease)
    assert RetainedObjects.install(owner, "{}") == {:error, :placement_ownership_unavailable}
    assert RetainedObjects.read(owner, hash("{}")) == {:error, :placement_ownership_unavailable}
    refute File.exists?(Path.join(context.directory, hash("{}")))
  end

  test "symbolic roots, delegation directories and object files refuse", context do
    link = context.root <> "-link"
    File.ln_s!(context.root, link)
    on_exit(fn -> File.rm!(link) end)

    assert {:error, :invalid_object_root} =
             RetainedObjects.open(link, "retained-test", context.lease)

    outside = Path.join(context.root, "outside")
    File.mkdir!(outside)
    File.ln_s!(outside, Path.join(context.root, "delegation"))

    assert {:error, :invalid_object_root} =
             RetainedObjects.open(context.root, "retained-test", context.lease)

    assert File.ls!(outside) == []
    File.rm!(Path.join(context.root, "delegation"))
    owner = open(context)
    digest = hash("{}")
    target = Path.join(outside, "target")
    File.write!(target, "{}")
    File.ln_s!(target, Path.join(context.directory, digest))
    assert RetainedObjects.install(owner, "{}") == {:error, :invalid_or_corrupt_object}
    assert RetainedObjects.read(owner, digest) == {:error, :invalid_or_corrupt_object}
    assert File.read!(target) == "{}"
  end

  test "a replaced physical runtime directory invalidates an existing owner", context do
    owner = open(context)
    File.rename!(context.directory, context.directory <> "-old")
    File.mkdir!(context.directory)
    assert RetainedObjects.install(owner, "{}") == {:error, :enoent}
    refute File.exists?(Path.join(context.directory, hash("{}")))
  end

  test "an altered writer marker prevents object installation", context do
    owner = open(context)
    marker = Path.join(context.directory, "objects.writer")
    File.write!(marker, String.duplicate("x", 1_048_577))
    assert RetainedObjects.install(owner, "{}") == {:error, :object_writer_changed}
    assert RetainedObjects.read(owner, hash("{}")) == {:error, :object_writer_changed}
    refute File.exists?(Path.join(context.directory, hash("{}")))
  end

  test "actual IO checkpoints precede acknowledgement in fsync publication order", context do
    parent = self()

    owner =
      open(context,
        checkpoint: fn step ->
          send(parent, {:step, step})
          :ok
        end
      )

    assert {:ok, digest} = RetainedObjects.install(owner, "{}")
    assert_receive {:step, :temporary_written}
    assert_receive {:step, :temporary_synced}
    assert_receive {:step, :renamed}
    assert_receive {:step, :directory_synced}
    assert File.read!(Path.join(context.directory, digest)) == "{}"
    assert {:ok, ^digest} = RetainedObjects.install(owner, "{}")
    assert_receive {:step, :existing_synced}
    assert_receive {:step, :directory_synced}
    refute_receive {:step, :renamed}
  end

  test "a fault after temporary sync publishes nothing", context do
    owner =
      open(context,
        checkpoint: fn step ->
          if step == :temporary_synced, do: {:error, :interrupted}, else: :ok
        end
      )

    assert RetainedObjects.install(owner, "{}") == {:error, :interrupted}
    assert RetainedObjects.read(owner, hash("{}")) == {:error, :enoent}
    refute Enum.any?(File.ls!(context.directory), &String.starts_with?(&1, ".tmp-"))
  end

  test "a post-rename fault remains unknown and a later exact install confirms durability",
       context do
    owner =
      open(context,
        checkpoint: fn step -> if step == :renamed, do: {:error, :interrupted}, else: :ok end
      )

    digest = hash("{}")

    assert RetainedObjects.install(owner, "{}") ==
             {:error, {:object_durability_unknown, digest, :interrupted}}

    assert {:ok, "{}"} = RetainedObjects.read(owner, digest)
    assert {:ok, ^digest} = RetainedObjects.install(owner, "{}")
  end

  test "a destination inserted after temporary sync is refused without replacement", context do
    bytes = "{}"
    path = Path.join(context.directory, hash(bytes))

    owner =
      open(context,
        checkpoint: fn step ->
          if step == :temporary_synced, do: File.write!(path, ~s({"foreign":true}))
          :ok
        end
      )

    assert RetainedObjects.install(owner, bytes) == {:error, :object_integrity_conflict}
    assert File.read!(path) == ~s({"foreign":true})
  end

  test "lost confirmation after actual directory sync remains unknown", context do
    owner =
      open(context,
        checkpoint: fn step ->
          if step == :directory_synced, do: {:error, :lost_confirmation}, else: :ok
        end
      )

    digest = hash("{}")

    assert RetainedObjects.install(owner, "{}") ==
             {:error, {:object_durability_unknown, digest, :lost_confirmation}}

    assert {:ok, "{}"} = RetainedObjects.read(owner, digest)
  end

  test "the opening caller's normal exit stops its owner and releases writer exclusion",
       context do
    parent = self()

    {caller, monitor} =
      spawn_monitor(fn ->
        {:ok, owner} = RetainedObjects.open(context.root, "retained-test", context.lease)
        send(parent, {:owned, owner})
        receive do: (:finish -> :ok)
      end)

    assert_receive {:owned, owner}, 5_000
    owner_monitor = Process.monitor(owner)
    send(caller, :finish)
    assert_receive {:DOWN, ^monitor, :process, ^caller, :normal}, 5_000
    assert_receive {:DOWN, ^owner_monitor, :process, ^owner, :normal}, 5_000
    reopened = open(context)
    assert {:ok, _digest} = RetainedObjects.install(reopened, "{}")
  end

  for cut <- [:temporary_synced, :renamed] do
    test "process death at #{cut} never yields an acknowledgement and recovery uses exact published bytes",
         context do
      cut = unquote(cut)
      parent = self()

      owner =
        open(context,
          checkpoint: fn step ->
            if step == cut,
              do:
                (
                  send(parent, {:paused, self()})
                  receive(do: (:continue -> :ok))
                ),
              else: :ok
          end
        )

      Process.unlink(owner)
      monitor = Process.monitor(owner)

      {caller, caller_monitor} =
        spawn_monitor(fn ->
          send(parent, {:call_ended, catch_exit(RetainedObjects.install(owner, "{}"))})
        end)

      assert_receive {:paused, ^owner}, 5_000
      Process.exit(owner, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^owner, :killed}, 5_000
      assert_receive {:call_ended, _exit}, 5_000
      assert_receive {:DOWN, ^caller_monitor, :process, ^caller, :normal}, 5_000
      reopened = open(context, recover_stale_writer: true)
      expected = recovered_at(cut)
      assert RetainedObjects.read(reopened, hash("{}")) == expected
      assert {:ok, digest} = RetainedObjects.install(reopened, "{}")
      assert {:ok, "{}"} = RetainedObjects.read(reopened, digest)

      for name <- File.ls!(context.directory), String.starts_with?(name, ".tmp-") do
        assert RetainedObjects.read(reopened, name) == {:error, :invalid_or_corrupt_object}
      end
    end
  end

  defp open(context, options \\ []) do
    {:ok, owner} = RetainedObjects.open(context.root, "retained-test", context.lease, options)
    on_exit(fn -> if Process.alive?(owner), do: GenServer.stop(owner) end)
    owner
  end

  defp hash(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
  defp recovered_at(:renamed), do: {:ok, "{}"}
  defp recovered_at(:temporary_synced), do: {:error, :enoent}
end
