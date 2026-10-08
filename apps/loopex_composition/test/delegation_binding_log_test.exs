Code.require_file("support/delegation_parent_binding_fixture.exs", __DIR__)

defmodule LoopexComposition.DelegationBindingLogTest do
  use ExUnit.Case, async: false

  alias Loopex.{Runtime, Store}
  alias Loopex.Store.{Local, Memory}
  alias LoopexComposition.Delegation.{LedgerCodec, ParentBinding, RetainedObjects}
  alias LoopexComposition.Placement
  alias LoopexComposition.DelegationParentBindingFixture, as: Fixture

  setup do
    root =
      Path.join("/private/tmp", "loopex-binding-#{Base.encode16(:crypto.strong_rand_bytes(12))}")

    File.mkdir!(root)
    {:ok, lease} = Placement.acquire(root)
    cleanup_guard = :atomics.new(1, [])
    :atomics.put(cleanup_guard, 1, 1)

    on_exit(fn ->
      if :atomics.get(cleanup_guard, 1) == 1 do
        Placement.release(lease)
        File.rm_rf!(root)
      else
        flunk("Original fault actors were not joined; fixture retained at #{root}")
      end
    end)

    %{
      root: root,
      lease: lease,
      cleanup_guard: cleanup_guard,
      directory: Path.join([root, "delegation", Fixture.hash("runtime")])
    }
  end

  test "capture sync and actual header precede prepare with retained completion credit",
       context do
    parent = self()

    owner =
      open(context,
        checkpoint: fn step ->
          send(parent, {:io_step, step})
          :ok
        end
      )

    capture = Fixture.valid_capture()
    assert {:ok, key} = RetainedObjects.open_binding(owner, "create", capture.object_bytes)
    assert key == capture.key
    path = path(context, capture)
    assert File.read!(path) == capture.header
    assert Bitwise.band(File.stat!(Path.dirname(path)).mode, 0o7777) == 0o700
    assert Bitwise.band(File.stat!(path).mode, 0o7777) == 0o600
    assert_receive {:io_step, :temporary_synced}, 5_000
    assert_receive {:io_step, :directory_synced}, 5_000
    assert_receive {:io_step, :binding_header_written}, 5_000
    assert_receive {:io_step, :binding_header_synced}, 5_000
    tx = prepare(capture)
    assert {:ok, result} = RetainedObjects.commit_binding(owner, "create", tx)
    assert result["ledger_version"] == 1
    assert File.read!(path) == capture.header <> frame(tx)
    assert {:ok, state} = RetainedObjects.read_binding(owner, "create")
    assert state.phase == :prepared and state.version == 1 and state.credit == 65_614
    assert state.bytes == byte_size(File.read!(path))
    assert state.bytes + state.credit <= 1_048_576
  end

  for adapter <- [Memory, Local] do
    @adapter adapter
    test "#{inspect(adapter)} actual creation history binds and reopens without activation",
         context do
      capture = Fixture.valid_capture()
      {runtime, session, store_pid, store_path} = history_runtime(context, capture, @adapter)
      owner = open(context)
      assert {:ok, _} = RetainedObjects.open_binding(owner, "create", capture.object_bytes)
      prepare = prepare(capture)
      assert {:ok, _} = RetainedObjects.commit_binding(owner, "create", prepare)
      bind = bind(capture, session)

      assert RetainedObjects.commit_binding(owner, "create", bind) ==
               {:error, :creation_history_unavailable}

      before = store_image(@adapter, store_pid, store_path)

      {:ok, stale} =
        ParentBinding.transaction(capture.key, 0, ParentBinding.bind_mutation(capture, session))

      original_bytes = File.read!(path(context, capture))

      assert RetainedObjects.commit_binding(owner, "create", stale, runtime) ==
               {:error, :stale_binding_version}

      assert File.read!(path(context, capture)) == original_bytes
      assert {:ok, original} = RetainedObjects.commit_binding(owner, "create", bind, runtime)
      assert {:ok, state} = RetainedObjects.read_binding(owner, "create", runtime)
      assert state.phase == :bound and state.parent == session and state.credit == 0
      bytes = File.read!(path(context, capture))
      assert {:ok, ^original} = RetainedObjects.commit_binding(owner, "create", bind, runtime)
      assert File.read!(path(context, capture)) == bytes
      stop_join(owner)
      reopened = open(context)
      assert RetainedObjects.read_binding(reopened, "create", runtime) == {:error, :ledger_fenced}

      assert {:ok, ^original} =
               RetainedObjects.lookup_binding(reopened, "create", bind["tx_id"], runtime)

      assert {:ok, restored} = RetainedObjects.read_binding(reopened, "create", runtime)
      assert restored == state
      assert store_image(@adapter, store_pid, store_path) == before
      assert {:ok, %{sessions: sessions}} = Runtime.children(runtime)
      assert DynamicSupervisor.which_children(sessions) == []
      runtime_monitor = Process.monitor(runtime.supervisor)
      assert :ok = Loopex.stop(runtime)
      assert_receive {:DOWN, ^runtime_monitor, :process, _, _}, 5_000
      stop_join(store_pid)
    end
  end

  test "duplicate presentation does not append and stale or changed reuse refuses", context do
    owner = open(context)
    capture = Fixture.valid_capture()
    assert {:ok, _} = RetainedObjects.open_binding(owner, "create", capture.object_bytes)
    tx = prepare(capture)
    assert {:ok, result} = RetainedObjects.commit_binding(owner, "create", tx)
    bytes = File.read!(path(context, capture))
    assert {:ok, ^result} = RetainedObjects.commit_binding(owner, "create", tx)

    {:ok, changed} =
      ParentBinding.transaction(capture.key, 1, ParentBinding.prepare_mutation(capture))

    assert RetainedObjects.commit_binding(owner, "create", changed) == {:error, :binding_conflict}

    assert RetainedObjects.commit_binding(owner, "create", %{}) ==
             {:error, :invalid_binding_transaction}

    assert RetainedObjects.commit_binding(owner, "create", nil) ==
             {:error, :invalid_binding_transaction}

    assert File.read!(path(context, capture)) == bytes

    assert RetainedObjects.lookup_binding(owner, "missing", tx["tx_id"]) ==
             {:error, :binding_unavailable}
  end

  test "wrong runtime command and object captures cannot be rebound from current inputs",
       context do
    owner = open(context)
    capture = Fixture.valid_capture()

    assert RetainedObjects.open_binding(owner, "other", capture.object_bytes) ==
             {:error, :invalid_parent_capture}

    assert RetainedObjects.open_binding(owner, "create", ["{}", "{}", "{}"]) ==
             {:error, :invalid_parent_capture}

    assert {:ok, _} = RetainedObjects.open_binding(owner, "create", capture.object_bytes)
    tx = prepare(capture)
    assert {:ok, _} = RetainedObjects.commit_binding(owner, "create", tx)
    creation_path = Path.join(context.directory, capture.creation_sha256)
    File.write!(creation_path, "{}")
    assert {:error, :binding_object_unavailable} = RetainedObjects.read_binding(owner, "create")
    assert {:error, _} = RetainedObjects.lookup_binding(owner, "create", tx["tx_id"])
    assert File.read!(path(context, capture)) == capture.header <> frame(tx)
  end

  test "complete malformed framing never becomes a repairable final append", context do
    owner = open(context)
    capture = Fixture.valid_capture()
    assert {:ok, _} = RetainedObjects.open_binding(owner, "create", capture.object_bytes)
    tx = prepare(capture)
    bytes = capture.header <> frame(tx)
    stop_join(owner)
    target = path(context, capture)

    variants = [
      flip(bytes, 0),
      flip(bytes, 8),
      flip(bytes, 14),
      flip(bytes, byte_size(capture.header) - 1),
      capture.header <> flip(frame(tx), 14),
      capture.header <> flip(frame(tx), byte_size(frame(tx)) - 1),
      capture.header <> frame(tx) <> frame(tx),
      capture.header <> frame(tx) <> frame(tx) <> frame(tx),
      capture.header <> "wrong",
      capture.header <> bad_length(65_537)
    ]

    for damaged <- variants do
      File.write!(target, damaged)
      reopened = open(context, recover_stale_writer: true)
      assert {:error, _} = RetainedObjects.lookup_binding(reopened, "create", tx["tx_id"])
      assert File.read!(target) == damaged
      assert RetainedObjects.install(reopened, "{}") == {:error, :ledger_fenced}
      stop_join(reopened)
      # Failed classification retains its writer marker. The next owner uses
      # the actual lock's positive classification of this joined process.
    end
  end

  test "all synthetic torn first headers remain unusable rather than empty", context do
    owner = open(context)
    capture = Fixture.valid_capture()
    assert {:ok, _} = RetainedObjects.open_binding(owner, "create", capture.object_bytes)
    stop_join(owner)
    target = path(context, capture)

    for length <- [0, 1, 9, 13, 45, byte_size(capture.header) - 1] do
      File.write!(target, binary_part(capture.header, 0, length))
      reopened = open(context, recover_stale_writer: true)

      assert {:error, _} =
               RetainedObjects.lookup_binding(reopened, "create", prepare(capture)["tx_id"])

      assert File.read!(target) == binary_part(capture.header, 0, length)
      stop_join(reopened)
    end
  end

  test "synthetic partial tail without a retained old writer cannot be repaired", context do
    owner = open(context)
    capture = Fixture.valid_capture()
    assert {:ok, _} = RetainedObjects.open_binding(owner, "create", capture.object_bytes)
    stop_join(owner)
    tx = prepare(capture)
    bytes = capture.header <> binary_part(frame(tx), 0, 20)
    File.write!(path(context, capture), bytes)
    reopened = open(context, recover_stale_writer: true)

    assert RetainedObjects.lookup_binding(reopened, "create", tx["tx_id"]) ==
             {:error, :binding_recovery_unproved}

    assert File.read!(path(context, capture)) == bytes
  end

  test "raw total ceiling refuses cap plus one without treating it as an empty ledger", context do
    owner = open(context)
    capture = Fixture.valid_capture()
    assert {:ok, _} = RetainedObjects.open_binding(owner, "create", capture.object_bytes)
    stop_join(owner)
    bytes = capture.header <> :binary.copy(<<0>>, 1_048_577 - byte_size(capture.header))
    File.write!(path(context, capture), bytes)
    reopened = open(context)

    assert {:error, :binding_unavailable} =
             RetainedObjects.lookup_binding(reopened, "create", prepare(capture)["tx_id"])

    assert File.read!(path(context, capture)) == bytes
    # This is a hostile synthetic cap image, not a file produced by a legal
    # two-transition writer. Exact retained credit arithmetic remains in the
    # complete parent reducer selection, which uses actual encoded frame sizes.
    assert RetainedObjects.decode_binding(bytes, "runtime", "create") ==
             {:error, :invalid_binding_log}
  end

  for cut <- [
        :binding_header_written,
        :binding_header_synced,
        :binding_partial_written,
        :binding_written,
        :binding_synced,
        :binding_closed,
        :binding_directory_synced
      ] do
    test "actual IO error at #{cut} retains the original unknown transaction", context do
      assert_io_error_scenario(context, unquote(cut))
    end
  end

  for cut <- [:binding_header_synced, :binding_partial_written, :binding_written, :binding_synced] do
    test "actual writer death at #{cut} is joined before exclusive recovery", context do
      assert_writer_death_scenario(context, unquote(cut))
    end
  end

  for cut <- [:binding_before_truncate, :binding_truncated, :binding_repair_synced] do
    test "actual repair error at #{cut} retains recovery exclusion until another joined owner",
         context do
      cut = unquote(cut)
      capture = Fixture.valid_capture()
      tx = prepare(capture)
      armed = :atomics.new(1, [])

      original =
        open(context,
          checkpoint: fn step ->
            if step == :binding_partial_written and
                 :atomics.compare_exchange(armed, 1, 1, 0) == :ok,
               do: {:error, :partial_cut},
               else: :ok
          end
        )

      assert {:ok, _} = RetainedObjects.open_binding(original, "create", capture.object_bytes)
      :atomics.put(armed, 1, 1)

      assert {:error, {:commit_unknown, _}} =
               RetainedObjects.commit_binding(original, "create", tx)

      stop_join(original)
      :atomics.put(armed, 1, 1)

      recovering =
        open(context,
          recover_stale_writer: true,
          checkpoint: fn step ->
            if step == cut and :atomics.compare_exchange(armed, 1, 1, 0) == :ok,
              do: {:error, :repair_cut},
              else: :ok
          end
        )

      assert {:error, _} = RetainedObjects.lookup_binding(recovering, "create", tx["tx_id"])
      assert RetainedObjects.install(recovering, "{}") == {:error, :ledger_fenced}
      stop_join(recovering)
      resumed = open(context, recover_stale_writer: true)
      assert RetainedObjects.lookup_binding(resumed, "create", tx["tx_id"]) == {:ok, :absent}
      assert File.read!(path(context, capture)) == capture.header
    end
  end

  for cut <- [:binding_before_truncate, :binding_truncated, :binding_repair_synced] do
    test "repair writer death at #{cut} is joined before the original lookup resumes", context do
      cut = unquote(cut)
      capture = Fixture.valid_capture()
      tx = prepare(capture)
      armed = :atomics.new(1, [])

      original =
        open(context,
          checkpoint: fn step ->
            if step == :binding_partial_written and
                 :atomics.compare_exchange(armed, 1, 1, 0) == :ok,
               do: {:error, :partial_cut},
               else: :ok
          end
        )

      assert {:ok, _} = RetainedObjects.open_binding(original, "create", capture.object_bytes)
      :atomics.put(armed, 1, 1)

      assert {:error, {:commit_unknown, _}} =
               RetainedObjects.commit_binding(original, "create", tx)

      stop_join(original)
      parent = self()

      recovering =
        open(context,
          recover_stale_writer: true,
          checkpoint: fn step ->
            if step == cut do
              send(parent, {:repair_paused, self()})
              receive do: (:continue -> :ok)
            else
              :ok
            end
          end
        )

      Process.unlink(recovering)
      owner_monitor = Process.monitor(recovering)
      joins = :atomics.new(2, [])
      deadline = System.monotonic_time(:millisecond) + 5_000

      {caller, caller_monitor} =
        spawn_monitor(fn ->
          receive do: (:start_fault -> :ok)
          result = catch_exit(RetainedObjects.lookup_binding(recovering, "create", tx["tx_id"]))
          send(parent, {:repair_ended, result})
        end)

      :atomics.put(context.cleanup_guard, 1, 0)

      try do
        send(caller, :start_fault)
        assert_receive {:repair_paused, ^recovering}, remaining(deadline)
        Process.exit(recovering, :kill)

        assert_receive {:DOWN, ^owner_monitor, :process, ^recovering, :killed},
                       remaining(deadline)

        :atomics.put(joins, 1, 1)
        assert_receive {:repair_ended, _}, remaining(deadline)
        assert_receive {:DOWN, ^caller_monitor, :process, ^caller, :normal}, remaining(deadline)
        :atomics.put(joins, 2, 1)
        resumed = open(context, recover_stale_writer: true)
        assert RetainedObjects.lookup_binding(resumed, "create", tx["tx_id"]) == {:ok, :absent}
        assert File.read!(path(context, capture)) == capture.header
      after
        join_fault_actors(
          context,
          [{recovering, owner_monitor, 1}, {caller, caller_monitor, 2}],
          joins,
          deadline
        )
      end
    end
  end

  test "a recovered successor cannot repair its own newly interrupted append", context do
    capture = Fixture.valid_capture()
    tx = prepare(capture)
    armed = :atomics.new(1, [])

    checkpoint = fn step ->
      if step == :binding_partial_written and :atomics.compare_exchange(armed, 1, 1, 0) == :ok,
        do: {:error, :partial_cut},
        else: :ok
    end

    original = open(context, checkpoint: checkpoint)
    assert {:ok, _} = RetainedObjects.open_binding(original, "create", capture.object_bytes)
    :atomics.put(armed, 1, 1)
    assert {:error, {:commit_unknown, _}} = RetainedObjects.commit_binding(original, "create", tx)
    stop_join(original)
    successor = open(context, recover_stale_writer: true, checkpoint: checkpoint)
    assert RetainedObjects.lookup_binding(successor, "create", tx["tx_id"]) == {:ok, :absent}
    assert File.read!(path(context, capture)) == capture.header
    :atomics.put(armed, 1, 1)

    assert RetainedObjects.commit_binding(successor, "create", tx) ==
             {:error, {:commit_unknown, tx["tx_id"]}}

    actual_tail = File.read!(path(context, capture))
    assert byte_size(actual_tail) > byte_size(capture.header)
    assert Process.alive?(successor)

    assert RetainedObjects.lookup_binding(successor, "create", tx["tx_id"]) ==
             {:error, :binding_recovery_unproved}

    assert File.read!(path(context, capture)) == actual_tail
    assert RetainedObjects.install(successor, "{}") == {:error, :ledger_fenced}
    stop_join(successor)
    final = open(context, recover_stale_writer: true)
    assert RetainedObjects.lookup_binding(final, "create", tx["tx_id"]) == {:ok, :absent}
    assert File.read!(path(context, capture)) == capture.header
    assert {:ok, _} = RetainedObjects.commit_binding(final, "create", tx)
    assert File.read!(path(context, capture)) == capture.header <> frame(tx)
  end

  test "repair compares the exact image again after the real pre-truncate checkpoint", context do
    capture = Fixture.valid_capture()
    tx = prepare(capture)
    armed = :atomics.new(1, [])

    original =
      open(context,
        checkpoint: fn step ->
          partial_cut =
            step == :binding_partial_written and :atomics.compare_exchange(armed, 1, 1, 0) == :ok

          if partial_cut, do: {:error, :partial_cut}, else: :ok
        end
      )

    assert {:ok, _} = RetainedObjects.open_binding(original, "create", capture.object_bytes)
    :atomics.put(armed, 1, 1)
    assert {:error, {:commit_unknown, _}} = RetainedObjects.commit_binding(original, "create", tx)
    stop_join(original)
    target = path(context, capture)
    before = File.read!(target)

    recovering =
      open(context,
        recover_stale_writer: true,
        checkpoint: fn step ->
          if step == :binding_before_truncate, do: File.write!(target, "changed", [:append])
          :ok
        end
      )

    assert {:error, _} = RetainedObjects.lookup_binding(recovering, "create", tx["tx_id"])
    assert File.read!(target) == before <> "changed"
  end

  test "strict synthetic final fragments are classified without invoking repair", context do
    capture = Fixture.valid_capture()
    encoded = frame(prepare(capture))

    for length <- [1, 9, 13, 45, 46, byte_size(encoded) - 33, byte_size(encoded) - 1] do
      bytes = capture.header <> binary_part(encoded, 0, length)
      assert {:ok, decoded} = RetainedObjects.decode_binding(bytes, "runtime", "create")
      assert decoded.transactions == [] and decoded.complete_size == byte_size(capture.header)
      assert decoded.tail == :incomplete
    end

    damaged_prefix = flip(binary_part(encoded, 0, 20), 14)

    damaged_trailer =
      binary_part(flip(encoded, byte_size(encoded) - 17), 0, byte_size(encoded) - 16)

    for fragment <- [damaged_prefix, damaged_trailer] do
      assert {:error, _} =
               RetainedObjects.decode_binding(capture.header <> fragment, "runtime", "create")
    end

    assert {:error, _} =
             RetainedObjects.decode_binding(capture.header <> "LXPHELP9", "runtime", "create")

    assert {:error, _} = RetainedObjects.decode_binding(capture.header, "runtime", "other")
    refute File.exists?(context.directory)
  end

  test "uncertainty in parent A blocks B and retained recovery covers every existing binding",
       context do
    a = Fixture.valid_capture()
    b = Fixture.capture_for("other-create")
    armed = :atomics.new(1, [])

    owner =
      open(context,
        checkpoint: fn step ->
          if step == :binding_synced and :atomics.compare_exchange(armed, 1, 1, 0) == :ok,
            do: {:error, :lost_ack},
            else: :ok
        end
      )

    assert {:ok, _} = RetainedObjects.open_binding(owner, a.command, a.object_bytes)
    assert {:ok, _} = RetainedObjects.open_binding(owner, b.command, b.object_bytes)
    :atomics.put(armed, 1, 1)

    assert {:error, {:commit_unknown, _}} =
             RetainedObjects.commit_binding(owner, a.command, prepare(a))

    assert RetainedObjects.commit_binding(owner, b.command, prepare(b)) ==
             {:error, :ledger_fenced}

    stop_join(owner)
    reopened = open(context, recover_stale_writer: true)
    assert {:ok, _} = RetainedObjects.lookup_binding(reopened, a.command, prepare(a)["tx_id"])

    assert RetainedObjects.commit_binding(reopened, b.command, prepare(b)) ==
             {:error, :ledger_fenced}

    assert RetainedObjects.lookup_binding(reopened, b.command, prepare(b)["tx_id"]) ==
             {:ok, :absent}

    assert {:ok, _} = RetainedObjects.commit_binding(reopened, b.command, prepare(b))
  end

  test "concurrent exact commits serialize into one physical frame", context do
    owner = open(context)
    capture = Fixture.valid_capture()
    assert {:ok, _} = RetainedObjects.open_binding(owner, "create", capture.object_bytes)
    tx = prepare(capture)
    parent = self()

    callers =
      Enum.map(1..8, fn _ ->
        spawn_monitor(fn ->
          result = RetainedObjects.commit_binding(owner, "create", tx)
          send(parent, {:committed, self(), result})
        end)
      end)

    deadline = System.monotonic_time(:millisecond) + 5_000

    results =
      Enum.map(callers, fn {pid, monitor} ->
        assert_receive {:committed, ^pid, result}, remaining(deadline)
        assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, remaining(deadline)
        result
      end)

    assert length(Enum.uniq(results)) == 1
    assert {:ok, _} = hd(results)
    assert File.read!(path(context, capture)) == capture.header <> frame(tx)
    assert {:error, _} = RetainedObjects.open(context.root, "runtime", context.lease)
  end

  test "ledger symlinks hard links and replaced ancestors refuse", context do
    owner = open(context)
    capture = Fixture.valid_capture()
    assert {:ok, _} = RetainedObjects.open_binding(owner, "create", capture.object_bytes)
    target = path(context, capture)
    outside = Path.join(context.root, "outside")
    File.rename!(target, outside)
    File.ln_s!(outside, target)
    assert {:error, _} = RetainedObjects.commit_binding(owner, "create", prepare(capture))
    assert File.read!(outside) == capture.header
    File.rm!(target)
    File.ln!(outside, target)

    assert {:error, _} =
             RetainedObjects.lookup_binding(owner, "create", prepare(capture)["tx_id"])

    File.rm!(target)
    File.rename!(outside, target)

    assert RetainedObjects.lookup_binding(owner, "create", prepare(capture)["tx_id"]) ==
             {:ok, :absent}

    bindings = Path.dirname(target)
    File.rename!(bindings, bindings <> "-old")
    File.mkdir!(bindings)
    assert {:error, _} = RetainedObjects.commit_binding(owner, "create", prepare(capture))
  end

  test "path replacement after real append produces unknown and cannot resolve a successor",
       context do
    capture = Fixture.valid_capture()
    armed = :atomics.new(1, [])
    target = path(context, capture)

    owner =
      open(context,
        checkpoint: fn step ->
          if step == :binding_written and :atomics.compare_exchange(armed, 1, 1, 0) == :ok do
            File.rename!(target, target <> "-original")
            File.write!(target, capture.header)
            File.chmod!(target, 0o600)
          end

          :ok
        end
      )

    assert {:ok, _} = RetainedObjects.open_binding(owner, "create", capture.object_bytes)
    :atomics.put(armed, 1, 1)
    tx = prepare(capture)

    assert RetainedObjects.commit_binding(owner, "create", tx) ==
             {:error, {:commit_unknown, tx["tx_id"]}}

    assert RetainedObjects.lookup_binding(owner, "create", tx["tx_id"]) ==
             {:error, :binding_file_changed}

    assert File.read!(target <> "-original") == capture.header <> frame(tx)
    assert File.read!(target) == capture.header
  end

  test "complete framed caller data cannot forge a creation history witness", context do
    owner = open(context)
    capture = Fixture.valid_capture()
    assert {:ok, _} = RetainedObjects.open_binding(owner, "create", capture.object_bytes)
    assert {:ok, _} = RetainedObjects.commit_binding(owner, "create", prepare(capture))
    forged = %{runtime_id: "runtime", command_id: "create", session_id: "session"}

    assert RetainedObjects.commit_binding(owner, "create", bind(capture, "session"), forged) ==
             {:error, :creation_history_unavailable}

    assert File.read!(path(context, capture)) == capture.header <> frame(prepare(capture))
  end

  defp assert_io_error_scenario(context, cut) do
    armed = :atomics.new(1, [])

    callback = fn step ->
      if step == cut and :atomics.compare_exchange(armed, 1, 1, 0) == :ok,
        do: {:error, :lost_confirmation},
        else: :ok
    end

    owner = open(context, checkpoint: callback)
    capture = Fixture.valid_capture()
    tx = prepare(capture)
    header_cut = cut in [:binding_header_written, :binding_header_synced]
    if header_cut, do: :atomics.put(armed, 1, 1)
    opened = RetainedObjects.open_binding(owner, "create", capture.object_bytes)

    result =
      if header_cut do
        opened
      else
        assert {:ok, _} = opened
        :atomics.put(armed, 1, 1)
        RetainedObjects.commit_binding(owner, "create", tx)
      end

    assert result == {:error, {:commit_unknown, tx["tx_id"]}}
    assert RetainedObjects.install(owner, "{}") == {:error, :ledger_fenced}

    if cut == :binding_partial_written do
      assert RetainedObjects.lookup_binding(owner, "create", tx["tx_id"]) ==
               {:error, :binding_recovery_unproved}

      stop_join(owner)
      reopened = open(context, recover_stale_writer: true)
      assert RetainedObjects.lookup_binding(reopened, "create", tx["tx_id"]) == {:ok, :absent}
      assert {:ok, _} = RetainedObjects.commit_binding(reopened, "create", tx)
    else
      expected =
        if header_cut,
          do: :absent,
          else: %{
            "version" => 1,
            "tx_id" => tx["tx_id"],
            "ledger_version" => 1,
            "mutation_digest" => tx["mutation_digest"]
          }

      assert RetainedObjects.lookup_binding(owner, "create", tx["tx_id"]) == {:ok, expected}
    end
  end

  defp assert_writer_death_scenario(context, cut) do
    capture = Fixture.valid_capture()
    tx = prepare(capture)
    parent = self()
    armed = :atomics.new(1, [])

    owner =
      open(context,
        checkpoint: fn step ->
          if step == cut and :atomics.get(armed, 1) == 1 do
            send(parent, {:paused, self()})
            receive do: (:continue -> :ok)
          else
            :ok
          end
        end
      )

    header_cut = cut == :binding_header_synced

    unless header_cut,
      do: assert({:ok, _} = RetainedObjects.open_binding(owner, "create", capture.object_bytes))

    Process.unlink(owner)
    owner_monitor = Process.monitor(owner)
    joins = :atomics.new(2, [])
    deadline = System.monotonic_time(:millisecond) + 5_000

    {caller, caller_monitor} =
      spawn_monitor(fn ->
        receive do: (:start_fault -> :ok)

        result =
          catch_exit(
            if header_cut,
              do: RetainedObjects.open_binding(owner, "create", capture.object_bytes),
              else: RetainedObjects.commit_binding(owner, "create", tx)
          )

        send(parent, {:ended, result})
      end)

    :atomics.put(context.cleanup_guard, 1, 0)

    try do
      :atomics.put(armed, 1, 1)
      send(caller, :start_fault)
      assert_receive {:paused, ^owner}, remaining(deadline)

      assert {:error, _} =
               RetainedObjects.open(context.root, "runtime", context.lease,
                 recover_stale_writer: true
               )

      Process.exit(owner, :kill)
      assert_receive {:DOWN, ^owner_monitor, :process, ^owner, :killed}, remaining(deadline)
      :atomics.put(joins, 1, 1)
      assert_receive {:ended, _}, remaining(deadline)
      assert_receive {:DOWN, ^caller_monitor, :process, ^caller, :normal}, remaining(deadline)
      :atomics.put(joins, 2, 1)
      reopened = open(context, recover_stale_writer: true)
      assert {:ok, recovered} = RetainedObjects.lookup_binding(reopened, "create", tx["tx_id"])

      if cut in [:binding_header_synced, :binding_partial_written],
        do: assert(recovered == :absent),
        else: assert(is_map(recovered))

      expected = if recovered == :absent, do: capture.header, else: capture.header <> frame(tx)
      assert File.read!(path(context, capture)) == expected
    after
      join_fault_actors(
        context,
        [{owner, owner_monitor, 1}, {caller, caller_monitor, 2}],
        joins,
        deadline
      )
    end
  end

  defp open(context, options \\ []) do
    {:ok, owner} = RetainedObjects.open(context.root, "runtime", context.lease, options)

    on_exit(fn ->
      if :atomics.get(context.cleanup_guard, 1) == 1 and Process.alive?(owner),
        do: stop_join(owner)
    end)

    owner
  end

  # Concept: failed boundary assertions must retire the same original actors.
  # Technical depth: kill only captured live PIDs, consume their original monitor
  # DOWNs within the pre-operation cutoff, and permit fixture deletion only when
  # both original joins succeeded. Success-path receipts avoid waiting twice for
  # an already consumed DOWN. Unproved cleanup retains the fixture and lease.
  defp join_fault_actors(context, actors, joins, deadline) do
    Enum.each(actors, fn {pid, _monitor, _index} ->
      if Process.alive?(pid), do: Process.exit(pid, :kill)
    end)

    proved =
      Enum.map(actors, fn {pid, monitor, index} ->
        if :atomics.get(joins, index) == 1 do
          true
        else
          receive do
            {:DOWN, ^monitor, :process, ^pid, _reason} ->
              :atomics.put(joins, index, 1)
              true
          after
            remaining(deadline) -> false
          end
        end
      end)

    if Enum.all?(proved) do
      :atomics.put(context.cleanup_guard, 1, 1)
    else
      flunk(
        "Original fault actor cleanup exceeded its captured cutoff; retaining #{context.root}"
      )
    end
  end

  defp prepare(capture) do
    {:ok, tx} = ParentBinding.transaction(capture.key, 0, ParentBinding.prepare_mutation(capture))
    tx
  end

  defp bind(capture, session) do
    {:ok, tx} =
      ParentBinding.transaction(capture.key, 1, ParentBinding.bind_mutation(capture, session))

    tx
  end

  defp frame(tx) do
    {:ok, bytes} = LedgerCodec.encode_json(tx, :frame)
    {:ok, frame} = LedgerCodec.encode_frame(bytes)
    frame
  end

  defp path(context, capture),
    do: Path.join([context.directory, "bindings", capture.key <> ".log"])

  defp flip(bytes, offset) do
    <<before::binary-size(^offset), byte, after_bytes::binary>> = bytes
    before <> <<Bitwise.bxor(byte, 1)>> <> after_bytes
  end

  defp bad_length(size) do
    prefix = <<"LXPHELP1", 1::unsigned-big-16, size::unsigned-big-32>>
    prefix <> :crypto.hash(:sha256, prefix)
  end

  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

  defp stop_join(pid) do
    monitor = Process.monitor(pid)
    :ok = GenServer.stop(pid)
    assert_receive {:DOWN, ^monitor, :process, ^pid, _}, 5_000
  end

  defp history_runtime(context, capture, adapter) do
    store_path = Path.join(context.root, "core.log")
    options = if adapter == Local, do: [path: store_path], else: []
    {:ok, first} = adapter.start_link(options)
    {:ok, store} = Store.new(adapter, first)
    {:committed, _, receipt} = Fixture.commit_creation(store, capture)

    store_pid =
      if adapter == Local do
        stop_join(first)
        {:ok, reopened} = Local.start_link(options)
        reopened
      else
        first
      end

    {:ok, selected} = Store.new(adapter, store_pid)

    {:ok, runtime} =
      Loopex.start_link(runtime_id: capture.runtime, context_token_budget: 8_192, store: selected)

    on_exit(fn ->
      if Runtime.alive?(runtime), do: Loopex.stop(runtime)
      if Process.alive?(store_pid), do: stop_join(store_pid)
    end)

    assert :ok = Fixture.await_startup(runtime)
    {runtime, receipt.session_id, store_pid, store_path}
  end

  defp store_image(Local, _pid, path), do: File.read!(path)
  defp store_image(Memory, pid, _path), do: :sys.get_state(pid)
end
